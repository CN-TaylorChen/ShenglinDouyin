//
//  SLTTSComposeController.m
//  声临 · 抖音版 —— 设置里的「生成语音」
//
//  概念图三态：编辑 → 合成中 → 已装填。
//  合成走 SLPipeline（与 #tts 口令完全同一条 pipeline），成功后由 SLTTSPageArm
//  写进共用槽位（实现在 Tweak.x，那里才有 PCM 流钩子的全局状态）。
//  不碰输入框、不动口令链路；只写装填槽位，录音时由 PCM 流自动替换。
//

#import "SLTTSComposeController.h"
#import "SLGlass.h"
#import "SLEntry.h"
#import "SLPipeline.h"
#import "SLAMREncoder.h"
#import "AWECATTSManager.h"
#import "AWECATTSVoiceListController.h"
#import "AWECAUtils.h"
#import "SLVoicePack.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

#define kSLComposeMaxChars   500
#define kSLComposeTextTag    77001
#define kSLComposeHolderTag  77002
#define kSLComposeCountTag   77003
#define kSLComposePasteTag   77004
#define kSLComposeSpeedTag   77011
#define kSLComposeVolumeTag  77012
#define kSLComposeValTag     77013

// v0.5.50：本页改用 InsetGrouped（与设置页 / 音色库 / 语音包同一规格），
// cell.contentView 会左右各缩进约 20pt。页内子控件一律以「卡片内宽」为基准，
// 不能再拿 tableView 全宽算，否则右侧的时长、粘贴按钮会顶出卡片。
#define kSLComposeInset 20.0
static CGFloat SLComposeContentW(UITableView *tv) {
    CGFloat w = CGRectGetWidth(tv.bounds);
    return (w > 0 ? w : 320.0) - kSLComposeInset * 2.0;
}

typedef NS_ENUM(NSInteger, SLComposeState) {
    SLComposeStateEditing = 0,
    SLComposeStateSynthesizing = 1,
    SLComposeStateDone = 2,
};

#pragma mark - 胶囊按钮（容器 + UILabel + UIControl，绕开 UIButtonConfiguration）

@interface SLComposeButton : UIControl
@property (nonatomic, strong) UILabel *lab;
@property (nonatomic, assign) BOOL primary;
@end

@implementation SLComposeButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 12.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.8;
        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:l];
        self.lab = l;
        self.primary = NO;
        [self sl_applyStyle];
    }
    return self;
}

- (void)setPrimary:(BOOL)primary {
    _primary = primary;
    [self sl_applyStyle];
}

- (void)sl_applyStyle {
    if (self.primary) {
        self.backgroundColor = [UIColor systemBlueColor];
        self.layer.borderColor = [[UIColor systemBlueColor] CGColor];
        self.lab.textColor = [UIColor whiteColor];
    } else {
        self.backgroundColor = [UIColor secondarySystemFillColor];
        self.layer.borderColor = [SLGlassHairlineColor() CGColor];
        self.lab.textColor = [UIColor labelColor];
    }
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1.0 : 0.55;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = (self.enabled ? (highlighted ? 0.72 : 1.0) : 0.55);
}

@end

#pragma mark - 工具函数

// 与设置页语速 / 音量滑块同一套对数映射：1.00x 正好落在轨道中点。
static float SLComposeValueForPos(float p) {
    if (p < 0.0f) p = 0.0f;
    if (p > 1.0f) p = 1.0f;
    return powf(2.0f, 2.0f * p - 1.0f);
}

static float SLComposePosForValue(float v) {
    if (v < 0.5f) v = 0.5f;
    if (v > 2.0f) v = 2.0f;
    return (log2f(v) + 1.0f) / 2.0f;
}

static float SLComposeSnap(float v) {
    v = roundf(v * 20.0f) / 20.0f;
    if (v < 0.5f) v = 0.5f;
    if (v > 2.0f) v = 2.0f;
    return v;
}

// 裸 PCM（16k / mono / s16le）现场封 WAV，AVAudioPlayer 最稳的路径（AMR 播不动）。
static NSData *SLComposeWAV(NSData *pcm) {
    if (pcm.length < 2) return nil;
    uint32_t dataLen = (uint32_t)pcm.length;
    uint32_t riffLen = 36 + dataLen;
    uint32_t sampleRate = 16000;
    uint32_t byteRate = sampleRate * 2;
    uint16_t channels = 1;
    uint16_t blockAlign = 2;
    uint16_t bits = 16;
    uint16_t fmt = 1;
    uint32_t fmtLen = 16;

    NSMutableData *out = [NSMutableData dataWithCapacity:44 + dataLen];
    [out appendBytes:"RIFF" length:4];
    [out appendBytes:&riffLen length:4];
    [out appendBytes:"WAVEfmt " length:8];
    [out appendBytes:&fmtLen length:4];
    [out appendBytes:&fmt length:2];
    [out appendBytes:&channels length:2];
    [out appendBytes:&sampleRate length:4];
    [out appendBytes:&byteRate length:4];
    [out appendBytes:&blockAlign length:2];
    [out appendBytes:&bits length:2];
    [out appendBytes:"data" length:4];
    [out appendBytes:&dataLen length:4];
    [out appendData:pcm];
    return out;
}

// 从 PCM 峰值生成波形条高度，结果卡用。
static NSArray<NSNumber *> *SLComposeWaveHeights(NSData *pcm, NSInteger bars) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(bars, 0)];
    if (bars <= 0) return a;
    NSInteger frames = (NSInteger)(pcm.length / 2);
    if (frames < 1) {
        for (NSInteger i = 0; i < bars; i++) [a addObject:@0.10];
        return a;
    }
    const int16_t *s = (const int16_t *)pcm.bytes;
    NSInteger step = MAX(1, frames / bars);
    for (NSInteger i = 0; i < bars; i++) {
        double peak = 0.0;
        NSInteger st = i * step;
        NSInteger en = MIN(frames, st + step);
        for (NSInteger j = st; j < en; j++) {
            int x = (int)s[j];
            if (x < 0) x = -x;
            double v = (double)x / 32768.0;
            if (v > peak) peak = v;
        }
        double h = MAX(0.08, MIN(1.0, peak * 2.2));
        [a addObject:@(h)];
    }
    return a;
}

#pragma mark - 页面

@interface SLTTSComposeController () <UITextViewDelegate, AVAudioPlayerDelegate>

@property (nonatomic, assign) SLComposeState state;
@property (nonatomic, strong) UITextView *textBox;
@property (nonatomic, strong) UILabel *holderLabel;
@property (nonatomic, strong) UILabel *countLabel;

@property (nonatomic, strong) UIView *statePill;
@property (nonatomic, strong) UILabel *stateText;
@property (nonatomic, strong) UIView *stateDot;

@property (nonatomic, strong) UIView *dock;
@property (nonatomic, strong) SLComposeButton *mainBtn;
@property (nonatomic, strong) SLComposeButton *auditionBtn;
@property (nonatomic, strong) SLComposeButton *regenerateBtn;

@property (nonatomic, copy) NSString *sourceText;
@property (nonatomic, copy) NSString *resultPath;
@property (nonatomic, assign) double resultDuration;
@property (nonatomic, copy) NSString *resultVoice;
@property (nonatomic, copy) NSString *resultEmotion;
@property (nonatomic, strong) NSData *resultPCM;
@property (nonatomic, assign) BOOL settled;

@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy) NSString *savedCategory;

- (void)sl_clearTapped;
- (void)sl_cancelTapped;
- (void)sl_doneTapped;
- (void)sl_pasteTapped;
- (void)sl_engineChanged:(UISegmentedControl *)seg;
- (void)sl_ratioSliding:(UISlider *)sl;
- (void)sl_ratioSettled:(UISlider *)sl;
- (void)sl_mainTapped;
- (void)sl_auditionTapped;
- (void)sl_regenerateTapped;

@end

@implementation SLTTSComposeController

- (instancetype)init {
    // v0.5.50：原来走默认 Plain —— 卡片满宽贴屏幕边缘，段间也没有留白（「四周贴太近」）。
    // 设置页 / 音色库 / 语音包 / 导入页统一都是 InsetGrouped，这里跟随同一规格：
    // 系统给左右边距、分组圆角和段间距，不用自己手算 frame。
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.state = SLComposeStateEditing;
    self.navigationItem.titleView = SLPillTitleView(@"文本转语音");
    SLInstallPillBack(self);
    // v0.5.49：这里原来调的是 SLInstallGlassBackdrop(self.view)。本页是 UITableViewController，
    // self.view 就是 tableView，那块毛玻璃被 insertSubview:atIndex:0 塞进了表格自己的滚动内容里，
    // 结果被单元格插到下面 —— 整页内容全被一层毛玻璃盖住，字全糊成一片（「字都看不见」）。
    // 表格页统一用 backgroundView 铺玻璃（设置页/语音包页/音色库都是这么做的）。
    SLApplyGlassTable(self.tableView);
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // 紧凑一屏：整页不滚动。行高与分段头都压到最小，两态内容都塞进一屏，
    // 底部 dock 常驻可见；输入框内部仍可正常编辑、光标滚动不受影响。
    self.tableView.scrollEnabled = NO;

    [self sl_buildStatePill];
    [self sl_buildDock];
    [self sl_applyState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从音色库 / 情绪页返回时刷新当前值
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sl_stopPlayer];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w <= 0) return;
    if (self.statePill) {
        CGRect f = self.statePill.frame;
        f.size.width = w;
        self.statePill.frame = f;
        self.stateText.frame = CGRectMake(30, 0, w - 40 - 42, 34);
    }
    if (self.dock) {
        CGRect f = self.dock.frame;
        f.size.width = w;
        self.dock.frame = f;
        [self sl_layoutDock];
    }
}

#pragma mark - 状态胶囊 / 底部按钮

- (void)sl_buildStatePill {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w <= 0) w = CGRectGetWidth(self.view.bounds);
    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0)];
    p.backgroundColor = [UIColor clearColor];
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(20, 8, w - 40, 34)];
    card.tag = 77020;
    card.backgroundColor = SLGlassCellColor();
    card.layer.cornerRadius = 12.0;
    card.layer.borderWidth = 0.8;
    card.layer.borderColor = [SLGlassHairlineColor() CGColor];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(13, 13, 8, 8)];
    dot.layer.cornerRadius = 4.0;
    [card addSubview:dot];
    self.stateDot = dot;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(30, 0, w - 40 - 42, 34)];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [card addSubview:l];
    self.stateText = l;
    [p addSubview:card];
    self.statePill = p;
    self.tableView.tableHeaderView = p;
}

- (void)sl_buildDock {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w <= 0) w = CGRectGetWidth(self.view.bounds);
    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 78)];
    d.backgroundColor = [UIColor clearColor];

    SLComposeButton *main = [[SLComposeButton alloc] initWithFrame:CGRectMake(0, 0, 100, 46)];
    main.primary = YES;
    main.lab.text = @"合成并装填";
    [main addTarget:self action:@selector(sl_mainTapped) forControlEvents:UIControlEventTouchUpInside];
    [d addSubview:main];
    self.mainBtn = main;

    SLComposeButton *audition = [[SLComposeButton alloc] initWithFrame:CGRectMake(0, 0, 100, 44)];
    audition.lab.text = @"试听";
    [audition addTarget:self action:@selector(sl_auditionTapped) forControlEvents:UIControlEventTouchUpInside];
    [d addSubview:audition];
    self.auditionBtn = audition;

    SLComposeButton *regenerate = [[SLComposeButton alloc] initWithFrame:CGRectMake(0, 0, 100, 44)];
    regenerate.lab.text = @"重新生成";
    [regenerate addTarget:self action:@selector(sl_regenerateTapped) forControlEvents:UIControlEventTouchUpInside];
    [d addSubview:regenerate];
    self.regenerateBtn = regenerate;

    self.dock = d;
    self.tableView.tableFooterView = d;
    [self sl_layoutDock];
}

- (void)sl_layoutDock {
    if (!self.dock) return;
    CGFloat w = CGRectGetWidth(self.dock.bounds);
    CGFloat pad = kSLComposeInset;
    CGFloat inner = w - pad * 2.0;
    BOOL done = (self.state == SLComposeStateDone);
    if (done) {
        CGFloat half = (inner - 10.0) / 2.0;
        self.auditionBtn.frame = CGRectMake(pad, 8, half, 44);
        self.regenerateBtn.frame = CGRectMake(pad + half + 10.0, 8, half, 44);
        self.mainBtn.frame = CGRectMake(pad, 62, inner, 46);
        self.auditionBtn.hidden = NO;
        self.regenerateBtn.hidden = NO;
        self.mainBtn.primary = YES;
        self.mainBtn.lab.text = @"完成 · 去录音";
    } else {
        self.auditionBtn.hidden = YES;
        self.regenerateBtn.hidden = YES;
        self.mainBtn.frame = CGRectMake(pad, 10, inner, 46);
        self.mainBtn.primary = YES;
        self.mainBtn.lab.text = (self.state == SLComposeStateSynthesizing) ? @"合成中…" : @"合成并装填";
    }
}

- (void)sl_applyState {
    BOOL done = (self.state == SLComposeStateDone);
    BOOL busy = (self.state == SLComposeStateSynthesizing);
    NSString *right = done ? @"完成" : (busy ? @"取消" : @"清空");
    SEL act = done ? @selector(sl_doneTapped) : (busy ? @selector(sl_cancelTapped) : @selector(sl_clearTapped));
    self.navigationItem.rightBarButtonItem = SLPillBarItem(right, self, act);

    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w <= 0) w = CGRectGetWidth(self.view.bounds);
    CGFloat h = (self.state == SLComposeStateEditing) ? 0.0 : 50.0;
    CGRect f = self.statePill.frame;
    f.size.width = w;
    f.size.height = h;
    self.statePill.frame = f;
    self.statePill.hidden = (h == 0.0);
    UIView *card = [self.statePill viewWithTag:77020];
    card.frame = CGRectMake(20, 8, w - 40, 34);
    self.stateText.frame = CGRectMake(30, 0, w - 40 - 42, 34);

    if (busy) {
        self.stateDot.backgroundColor = [UIColor systemBlueColor];
        // 状态文字用主标签色，不再整行着蓝（用户：「文字颜色不要蓝色」）。
        self.stateText.textColor = [UIColor labelColor];
        NSString *v = [self sl_currentVoiceName];
        self.stateText.text = [NSString stringWithFormat:@"正在用「%@」合成 · 完成后自动装填", v];
    } else if (done) {
        self.stateDot.backgroundColor = [UIColor systemGreenColor];
        self.stateText.textColor = [UIColor systemGreenColor];
        self.stateText.text = @"已装填 · 下一条录音自动替换";
    } else {
        self.stateText.text = nil;
    }

    CGRect d = self.dock.frame;
    d.size.width = w;
    d.size.height = done ? 130.0 : 78.0;
    self.dock.frame = d;
    self.tableView.tableFooterView = self.dock;
    [self sl_layoutDock];
    self.mainBtn.enabled = !busy;
    self.tableView.tableHeaderView = self.statePill;
    [self.tableView reloadData];
}

#pragma mark - 表数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    // 完成态砍掉「基于这段文字」那一段（纯回显、占地方），只留结果 + 状态两节，
    // 配合整页不滚动，保证底部按钮在小屏上也常驻可见。
    return (self.state == SLComposeStateDone) ? 2 : 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (self.state == SLComposeStateDone) {
        if (section == 0) return 1;
        return 4;
    }
    if (section == 0) return 1;
    if (section == 1) return 5;
    return 0;
}

- (NSString *)sl_titleForSection:(NSInteger)section {
    if (self.state == SLComposeStateDone) {
        return @[@"合成结果", @"装填状态"][section];
    }
    return @[@"输入文字", @"引擎与音色", @""][section];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    NSString *t = [self sl_titleForSection:section];
    if (!t.length) return [[UIView alloc] initWithFrame:CGRectZero];
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(tv.bounds), 28)];
    v.backgroundColor = [UIColor clearColor];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, 6, CGRectGetWidth(tv.bounds) - 36, 20)];
    l.text = t;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    l.textColor = [UIColor secondaryLabelColor];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv;
    NSString *t = [self sl_titleForSection:section];
    return t.length ? 22.0 : 0.01;   // 紧凑：28→22
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    if (self.state == SLComposeStateDone) {
        if (ip.section == 0) return 96.0;    // 结果波形 116→96
        if (ip.section == 1) return 36.0;    // 状态行 44→36
        // 来源文字：整页不滚动，这里封顶 4 行，避免长文本把底部按钮顶出屏幕
        NSString *s = self.sourceText ?: @"";
        CGRect r = [s boundingRectWithSize:CGSizeMake(SLComposeContentW(tv) - 60, CGFLOAT_MAX)
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14]}
                                   context:nil];
        return MIN(88.0, MAX(44.0, ceil(CGRectGetHeight(r)) + 20.0));
    }
    if (ip.section == 0) return 108.0;       // 输入框 132→108
    return (ip.row >= 3) ? 44.0 : 38.0;      // 参数行 44/50→38/44
}

- (NSString *)sl_currentVoiceName {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    NSString *v = mgr.fishEngine ? mgr.fishVoiceName : mgr.voiceName;
    return v.length ? v : @"默认音色";
}

- (NSString *)sl_currentEmotionText {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    return mgr.fishEmotionSel.count
        ? [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)mgr.fishEmotionSel.count]
        : @"未启用";
}

- (UITableViewCell *)sl_plainCell:(UITableView *)tv identifier:(NSString *)rid {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
        cell.backgroundColor = SLGlassCellColor();
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.textAlignment = NSTextAlignmentRight;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = nil;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.state == SLComposeStateDone) return [self sl_doneCell:tv indexPath:ip];
    if (ip.section == 0) return [self sl_inputCell:tv];
    return [self sl_paramCell:tv row:ip.row];
}

- (UITableViewCell *)sl_inputCell:(UITableView *)tv {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"sltts_input"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sltts_input"];
        cell.backgroundColor = SLGlassCellColor();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        CGFloat cw = SLComposeContentW(tv);
        UITextView *box = [[UITextView alloc] initWithFrame:CGRectMake(14, 6, cw - 28, 62)];
        box.tag = kSLComposeTextTag;
        box.font = [UIFont systemFontOfSize:15];
        box.backgroundColor = [UIColor clearColor];
        box.textColor = [UIColor labelColor];
        box.autocorrectionType = UITextAutocorrectionTypeDefault;
        box.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        box.delegate = self;
        [cell.contentView addSubview:box];
        self.textBox = box;

        UILabel *holder = [[UILabel alloc] initWithFrame:CGRectMake(19, 12, cw - 38, 20)];
        holder.tag = kSLComposeHolderTag;
        holder.text = @"在这里输入要合成的内容…";
        holder.font = [UIFont systemFontOfSize:15];
        holder.textColor = [UIColor tertiaryLabelColor];
        holder.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:holder];
        self.holderLabel = holder;

        SLComposeButton *paste = [[SLComposeButton alloc] initWithFrame:CGRectMake(cw - 14 - 62, 74, 62, 26)];
        paste.tag = kSLComposePasteTag;
        paste.lab.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        paste.lab.text = @"粘贴";
        paste.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [paste addTarget:self action:@selector(sl_pasteTapped) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:paste];

        UILabel *cnt = [[UILabel alloc] initWithFrame:CGRectMake(18, 76, 120, 20)];
        cnt.tag = kSLComposeCountTag;
        cnt.font = [UIFont systemFontOfSize:12];
        cnt.textColor = [UIColor tertiaryLabelColor];
        [cell.contentView addSubview:cnt];
        self.countLabel = cnt;
        [self sl_syncInputChrome];
    } else {
        self.textBox = (UITextView *)[cell.contentView viewWithTag:kSLComposeTextTag];
        self.holderLabel = (UILabel *)[cell.contentView viewWithTag:kSLComposeHolderTag];
        self.countLabel = (UILabel *)[cell.contentView viewWithTag:kSLComposeCountTag];
        self.textBox.delegate = self;
    }
    // 状态切换会 reloadData；cell 万一被重建，把上一次的文字接回来，别让用户白打一遍
    if (self.sourceText.length && self.textBox.text.length == 0) self.textBox.text = self.sourceText;
    [self sl_syncInputChrome];
    return cell;
}

- (UITableViewCell *)sl_paramCell:(UITableView *)tv row:(NSInteger)row {
    UITableViewCell *cell = [self sl_plainCell:tv identifier:@"sltts_param"];
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (row == 0) {
        cell.textLabel.text = @"合成引擎";
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"火山引擎", @"Fish Audio"]];
        seg.frame = CGRectMake(0, 0, 186, 30);
        seg.selectedSegmentIndex = mgr.fishEngine ? 1 : 0;
        [seg addTarget:self action:@selector(sl_engineChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = seg;
    } else if (row == 1) {
        cell.textLabel.text = @"音色";
        cell.detailTextLabel.text = [self sl_currentVoiceName];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (row == 2) {
        cell.textLabel.text = @"情绪";
        cell.detailTextLabel.text = [self sl_currentEmotionText];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        BOOL speed = (row == 3);
        cell.textLabel.text = speed ? @"语速" : @"音量";
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 178, 34)];
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 2, 118, 30)];
        sl.tag = speed ? kSLComposeSpeedTag : kSLComposeVolumeTag;
        float v = speed ? mgr.speedRatio : mgr.volumeRatio;
        if (v < 0.5f) v = 0.5f;
        if (v > 2.0f) v = 2.0f;
        sl.value = SLComposePosForValue(v);
        [sl addTarget:self action:@selector(sl_ratioSliding:) forControlEvents:UIControlEventValueChanged];
        [sl addTarget:self action:@selector(sl_ratioSettled:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [box addSubview:sl];
        UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(124, 0, 54, 34)];
        val.tag = kSLComposeValTag;
        val.font = [UIFont systemFontOfSize:13];
        val.textColor = [UIColor secondaryLabelColor];
        val.textAlignment = NSTextAlignmentRight;
        val.text = [NSString stringWithFormat:@"%.2fx", v];
        [box addSubview:val];
        cell.accessoryView = box;
    }
    return cell;
}

- (UITableViewCell *)sl_doneCell:(UITableView *)tv indexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"sltts_result"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sltts_result"];
            cell.backgroundColor = SLGlassCellColor();
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UIView *wave = [[UIView alloc] initWithFrame:CGRectMake(16, 8, SLComposeContentW(tv) - 48, 40)];
            wave.tag = 77030;
            wave.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [cell.contentView addSubview:wave];
            UILabel *voice = [[UILabel alloc] initWithFrame:CGRectMake(16, 58, SLComposeContentW(tv) - 180, 20)];
            voice.tag = 77031;
            voice.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            voice.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [cell.contentView addSubview:voice];
            UILabel *dur = [[UILabel alloc] initWithFrame:CGRectMake(SLComposeContentW(tv) - 134, 58, 118, 20)];
            dur.tag = 77032;
            dur.font = [UIFont systemFontOfSize:13];
            dur.textColor = [UIColor secondaryLabelColor];
            dur.textAlignment = NSTextAlignmentRight;
            dur.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [cell.contentView addSubview:dur];
        }
        UIView *wave = [cell.contentView viewWithTag:77030];
        for (UIView *v in [wave.subviews copy]) [v removeFromSuperview];
        NSArray<NSNumber *> *hs = SLComposeWaveHeights(self.resultPCM, 28);
        CGFloat bw = CGRectGetWidth(wave.bounds);
        CGFloat gap = 3.0;
        CGFloat barW = MAX(2.0, (bw - gap * 27.0) / 28.0);
        for (NSInteger i = 0; i < (NSInteger)hs.count; i++) {
            CGFloat h = MAX(3.0, (CGFloat)hs[i].doubleValue * 40.0);
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(i * (barW + gap), 20 - h / 2.0, barW, h)];
            bar.backgroundColor = [UIColor systemGreenColor];
            bar.layer.cornerRadius = barW / 2.0;
            [wave addSubview:bar];
        }
        UILabel *voice = [cell.contentView viewWithTag:77031];
        NSString *emo = self.resultEmotion.length ? self.resultEmotion : @"默认";
        voice.text = [NSString stringWithFormat:@"%@ · %@", self.resultVoice ?: @"默认音色", emo];
        UILabel *dur = [cell.contentView viewWithTag:77032];
        dur.text = [NSString stringWithFormat:@"%.1fs · 16k PCM", self.resultDuration];
        return cell;
    }

    if (ip.section == 1) {
        UITableViewCell *cell = [self sl_plainCell:tv identifier:@"sltts_status"];
        NSArray *keys = @[@"槽位", @"生效范围", @"有效时间", @"悬浮球"];
        NSArray *vals = @[@"AI 语音 · 就绪", @"下一条录音", @"5 分钟", @"装填绿 · 发出后灰"];
        cell.textLabel.text = keys[ip.row];
        cell.detailTextLabel.text = vals[ip.row];
        return cell;
    }

    UITableViewCell *cell2 = [tv dequeueReusableCellWithIdentifier:@"sltts_source"];
    if (!cell2) {
        cell2 = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sltts_source"];
        cell2.backgroundColor = SLGlassCellColor();
        cell2.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, SLComposeContentW(tv) - 46, 40)];
        l.tag = 77040;
        l.numberOfLines = 0;
        l.font = [UIFont systemFontOfSize:14];
        l.textColor = [UIColor secondaryLabelColor];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell2.contentView addSubview:l];
    }
    UILabel *l = [cell2.contentView viewWithTag:77040];
    l.text = self.sourceText ?: @"";
    CGRect f = l.frame;
    f.size.width = SLComposeContentW(tv) - 46;
    f.size.height = MAX(40.0, [self tableView:tv heightForRowAtIndexPath:ip] - 24.0);
    l.frame = f;
    return cell2;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.state == SLComposeStateDone) return;
    if (ip.section != 1) return;
    if (ip.row == 1) {
        AWECATTSVoiceListController *vc = [[AWECATTSVoiceListController alloc] init];
        vc.fishMode = [AWECATTSManager shared].fishEngine;
        [self.navigationController pushViewController:vc animated:YES];
    } else if (ip.row == 2) {
        AWECATTSVoiceListController *vc = [[AWECATTSVoiceListController alloc] init];
        vc.emotionMode = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - 输入

- (void)sl_syncInputChrome {
    NSString *t = self.textBox.text ?: @"";
    if ((NSInteger)t.length > kSLComposeMaxChars) {
        t = [t substringToIndex:kSLComposeMaxChars];
        self.textBox.text = t;
    }
    self.holderLabel.hidden = t.length > 0;
    self.countLabel.text = [NSString stringWithFormat:@"%lu / %d", (unsigned long)t.length, kSLComposeMaxChars];
}

- (void)textViewDidChange:(UITextView *)textView {
    (void)textView;
    [self sl_syncInputChrome];
}

- (void)sl_pasteTapped {
    NSString *p = [UIPasteboard generalPasteboard].string;
    if (!p.length) {
        [AWECAUtils showToast:@"剪贴板是空的" duration:1.4];
        return;
    }
    NSString *t = self.textBox.text ?: @"";
    t = [t stringByAppendingString:p];
    self.textBox.text = t;
    [self sl_syncInputChrome];
}

- (void)sl_clearTapped {
    self.textBox.text = @"";
    self.sourceText = nil;
    [self sl_syncInputChrome];
    [self.textBox resignFirstResponder];
}

#pragma mark - 引擎 / 语速 / 音量

- (void)sl_engineChanged:(UISegmentedControl *)seg {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    mgr.fishEngine = (seg.selectedSegmentIndex == 1);
    [mgr saveConfig];
    [self.tableView reloadData];
}

- (void)sl_ratioSliding:(UISlider *)sl {
    BOOL speed = (sl.tag == kSLComposeSpeedTag);
    float v = SLComposeValueForPos(sl.value);
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (speed) mgr.speedRatio = v; else mgr.volumeRatio = v;
    UILabel *val = (UILabel *)[sl.superview viewWithTag:kSLComposeValTag];
    val.text = [NSString stringWithFormat:@"%.2fx", v];
}

- (void)sl_ratioSettled:(UISlider *)sl {
    BOOL speed = (sl.tag == kSLComposeSpeedTag);
    float raw = SLComposeValueForPos(sl.value);
    float v = (fabsf(raw - 1.0f) < 0.06f) ? 1.0f : SLComposeSnap(raw);
    sl.value = SLComposePosForValue(v);
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (speed) mgr.speedRatio = v; else mgr.volumeRatio = v;
    [mgr saveConfig];
    UILabel *val = (UILabel *)[sl.superview viewWithTag:kSLComposeValTag];
    val.text = [NSString stringWithFormat:@"%.2fx", v];
}

#pragma mark - 合成 / 装填

- (void)sl_mainTapped {
    if (self.state == SLComposeStateDone) { [self sl_doneTapped]; return; }
    if (self.state == SLComposeStateSynthesizing) return;
    NSString *text = [self.textBox.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) {
        [AWECAUtils showToast:@"先输入要合成的文字" duration:1.6];
        return;
    }
    if (!SLTTSPageIsEnabled()) {
        [AWECAUtils showToast:@"请先在设置里打开「录音转音色」" duration:2.0];
        return;
    }
    self.sourceText = text;
    self.settled = NO;
    [self.textBox resignFirstResponder];
    self.state = SLComposeStateSynthesizing;
    [self sl_applyState];
    SLLog(@"TTS-PAGE start len=%lu engine=%@", (unsigned long)text.length,
          [AWECATTSManager shared].fishEngine ? @"fish" : @"volcano");

    __weak typeof(self) weakSelf = self;
    [[SLPipeline shared] synthesizeMessageText:text completion:^(BOOL ok, NSString *outPath, double dur, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2 || self2.settled) return;
            self2.settled = YES;
            if (!ok || !outPath.length) {
                self2.state = SLComposeStateEditing;
                [self2 sl_applyState];
                [AWECAUtils showToast:[NSString stringWithFormat:@"合成失败 · %@", message ?: @"请重试"] duration:2.4];
                SLLog(@"TTS-PAGE failed: %@", message ?: @"-");
                return;
            }
            NSString *raw = [SLPipeline shared].lastRawAudioPath ?: outPath;
            NSData *pcm = [SLAMREncoder pcmMono16AtPath:raw sampleRate:16000.0];
            self2.resultPath = outPath;
            self2.resultDuration = dur;
            self2.resultPCM = pcm;
            self2.resultVoice = [self2 sl_currentVoiceName];
            self2.resultEmotion = [self2 sl_currentEmotionText];
            BOOL armed = SLTTSPageArm(outPath, dur, pcm, text);
            self2.state = SLComposeStateDone;
            [self2 sl_applyState];
            SLLog(@"TTS-PAGE armed=%d path=%@ dur=%.2f pcm=%lu", armed ? 1 : 0,
                  outPath, dur, (unsigned long)pcm.length);
            if (!armed) [AWECAUtils showToast:@"合成成功，但装填失败" duration:2.0];
        });
    }];
}

- (void)sl_cancelTapped {
    self.settled = YES;
    self.state = SLComposeStateEditing;
    [self sl_applyState];
    SLLog(@"TTS-PAGE cancelled by user");
}

- (void)sl_doneTapped {
    // v0.5.50：装填完成后点「完成」应该直接回聊天页录音，而不是退回设置页再点一次「完成」。
    // 设置页自己的「完成」用的就是 SLCloseHostingPanel —— 沿 parentViewController 找到浮窗
    // 的呈现者，dismiss 整个设置面板并清掉单例。右上角胶囊与底部「完成 · 去录音」都走这里。
    SLCloseHostingPanel(self);
}

#pragma mark - 完成态：试听 / 重新生成

- (void)sl_auditionTapped {
    if (self.resultPCM.length < 1600) {
        [AWECAUtils showToast:@"这段音频没有可播放的 PCM" duration:1.8];
        return;
    }
    NSData *wav = SLComposeWAV(self.resultPCM);
    if (!wav.length) {
        [AWECAUtils showToast:@"试听文件生成失败" duration:1.8];
        return;
    }
    [self sl_stopPlayer];
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    self.savedCategory = sess.category;
    [sess setCategory:AVAudioSessionCategoryPlayback error:nil];
    [sess setActive:YES error:nil];
    NSError *err = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:wav fileTypeHint:AVFileTypeWAVE error:&err];
    if (!p || err) {
        [AWECAUtils showToast:@"无法播放" duration:1.6];
        [self sl_restoreSession];
        return;
    }
    p.delegate = self;
    [p prepareToPlay];
    [p play];
    self.player = p;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player;
    (void)flag;
    [self sl_stopPlayer];
}

- (void)sl_stopPlayer {
    [self.player stop];
    self.player = nil;
    [self sl_restoreSession];
}

- (void)sl_restoreSession {
    if (!self.savedCategory.length) return;
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:self.savedCategory error:nil];
    [sess setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    self.savedCategory = nil;
}

- (void)sl_regenerateTapped {
    // 回到合成前的编辑页：文字原样留着，只清掉这一发的装填与结果。
    // 槽位必须一起清 —— 否则退回编辑后那发旧音频还挂在替换槽里，下次录音会被它替换掉。
    [self sl_stopPlayer];
    self.settled = NO;
    self.resultPath = nil;
    self.resultDuration = 0;
    self.resultPCM = nil;
    self.resultVoice = nil;
    self.resultEmotion = nil;
    SLClearArmedAudio();
    self.state = SLComposeStateEditing;
    [self sl_applyState];
    SLLog(@"TTS-PAGE regenerate: back to editing, text kept len=%lu",
          (unsigned long)self.textBox.text.length);
}

@end
