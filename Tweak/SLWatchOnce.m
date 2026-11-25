// v0.6.0：相册发闪图
//
// 关键点（详见 SLWatchOnce.h）：
//   · 抖音原生已有「相册选图 → 闪图」管线，最终决策点是
//     AWEIMMessageListGalleryEntryComponent -sendAssets:isSendWatchOnce:
//   · 挡住入口的是一串"能力/策略"开关，语义都是「允许不允许」，不是「当前状态」，
//     因此可以安全地在 getter 上把答案改成允许。
//   · 明确**不碰**的东西：AWEIMPhotoPickerModel/AWEIMLocalAsset 的 watchOnce（每张图的状态）、
//     AWEIMSendMessageContext.isClickWatchOnce（点击状态）、任何 setter、任何 ivar 偏移读取。
//     v0.5.7 就是在图片消息 setter 上挂钩子＋裸读 ivar 导致相册选图闪退。
//
// 安全措施：挂之前先用 method_copyReturnType 校验签名 —— 返回类型不是 BOOL / void 的
// 一律跳过并记日志。宁可某个门没挂上，也不让一个签名猜错的钩子把正常发图搞坏。

#import "SLWatchOnce.h"
#import "SLLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

#define kSLOnceEntry @"SLWatchOnceEntry"
#define kSLOnceForce @"SLWatchOnceForce"

#pragma mark - 开关

BOOL SLWatchOnceEntryOn(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLOnceEntry]) return YES;      // 默认放开
    return [d boolForKey:kSLOnceEntry];
}

BOOL SLWatchOnceForceOn(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLOnceForce]) return NO;       // 默认不强制
    return [d boolForKey:kSLOnceForce];
}

void SLWatchOnceSetEntry(BOOL on) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:kSLOnceEntry];
    [d synchronize];
    SLLog(@"ONCE| 开关 相册闪图入口 = %d", on);
}

void SLWatchOnceSetForce(BOOL on) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:kSLOnceForce];
    [d synchronize];
    SLLog(@"ONCE| 开关 相册默认闪图 = %d", on);
}

#pragma mark - 只在"类自己身上"找方法 + 校验返回类型

// class_getInstanceMethod 会顺着父类找到方法，method_setImplementation 改的是父类那份实现，
// 影响面会扩散到一堆子类。这里只取本类 method list，确保钩子只落在目标类上。
static Method SLExactMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    Method found = NULL;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { found = list[i]; break; }
    }
    if (list) free(list);
    return found;
}

// want: 'B' = BOOL / 'c' = char 当 BOOL 用 / 'v' = void
static BOOL SLReturnTypeIs(Method m, char want) {
    char *ret = method_copyReturnType(m);
    BOOL ok = (ret && ret[0] == want);
    if (ret) free(ret);
    return ok;
}

static BOOL SLReturnTypeIsBool(Method m) {
    return SLReturnTypeIs(m, 'B') || SLReturnTypeIs(m, 'c');
}

static void SLInstall(Class cls, SEL sel, IMP imp, IMP *origSlot, NSString *tag) {
    if (!cls) { SLLog(@"ONCE| 跳过 %@：类不存在", tag); return; }
    Method m = SLExactMethod(cls, sel);
    if (!m) { SLLog(@"ONCE| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    IMP old = method_getImplementation(m);
    if (old == imp) return;
    if (origSlot) *origSlot = old;
    method_setImplementation(m, imp);
    SLLog(@"ONCE| 已挂 %@ @ %@", tag, NSStringFromClass(cls));
}

static void SLInstallBool(Class cls, SEL sel, IMP imp, IMP *origSlot, NSString *tag) {
    if (!cls) { SLLog(@"ONCE| 跳过 %@：类不存在", tag); return; }
    Method m = SLExactMethod(cls, sel);
    if (!m) { SLLog(@"ONCE| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    if (!SLReturnTypeIsBool(m)) {
        char *r = method_copyReturnType(m);
        SLLog(@"ONCE| 跳过 %@：返回类型是 %s，不是 BOOL", tag, r ?: "?");
        if (r) free(r);
        return;
    }
    SLInstall(cls, sel, imp, origSlot, tag);
}

static void SLInstallVoid(Class cls, SEL sel, IMP imp, IMP *origSlot, NSString *tag) {
    if (!cls) { SLLog(@"ONCE| 跳过 %@：类不存在", tag); return; }
    Method m = SLExactMethod(cls, sel);
    if (!m) { SLLog(@"ONCE| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    if (!SLReturnTypeIs(m, 'v')) {
        char *r = method_copyReturnType(m);
        SLLog(@"ONCE| 跳过 %@：返回类型是 %s，不是 void", tag, r ?: "?");
        if (r) free(r);
        return;
    }
    SLInstall(cls, sel, imp, origSlot, tag);
}

#pragma mark - 门 1：disableSendWatchOnce → 一律 NO

#define SL_ONCE_ALLOW_HOOK(NAME, TAG)                       \
    static BOOL (*o_##NAME)(id, SEL);                        \
    static BOOL h_##NAME(id self, SEL _cmd) {                \
        BOOL orig = o_##NAME ? o_##NAME(self, _cmd) : NO;    \
        if (!SLWatchOnceEntryOn()) return orig;              \
        static BOOL once = NO;                               \
        if (!once) { once = YES;                             \
            SLLog(@"ONCE| %@ 原生=%d → 0", TAG, orig); }      \
        return NO;                                           \
    }

SL_ONCE_ALLOW_HOOK(galleryDisable,  @"gallery.disableSendWatchOnce")     // AWEIMMessageListGalleryEntryComponent
SL_ONCE_ALLOW_HOOK(quickDisable,    @"quick.disableSendWatchOnce")       // AWEIMQuickSelectPhotoInteractor
SL_ONCE_ALLOW_HOOK(previewDisable,  @"preview.disableSendWatchOnce")     // AWEIMPhotoPreviewEditorCollectionView

#pragma mark - 门 2：能力/策略判定 → 一律 YES

#define SL_ONCE_SUPPORT_HOOK(NAME, TAG)                     \
    static BOOL (*o_##NAME)(id, SEL);                        \
    static BOOL h_##NAME(id self, SEL _cmd) {                \
        BOOL orig = o_##NAME ? o_##NAME(self, _cmd) : NO;    \
        if (!SLWatchOnceEntryOn()) return orig;              \
        static BOOL once = NO;                               \
        if (!once) { once = YES;                             \
            SLLog(@"ONCE| %@ 原生=%d → 1", TAG, orig); }      \
        return YES;                                          \
    }

SL_ONCE_SUPPORT_HOOK(feedAdapter,     @"feedAdapter.needSupportWatchOnce")   // IESIMInputVCFeedDetailAdapter
SL_ONCE_SUPPORT_HOOK(defaultAdapter,  @"defaultAdapter.needSupportWatchOnce") // IESIMInputVCDefaultAdapter
SL_ONCE_SUPPORT_HOOK(optStrategy,     @"contextRecommend.enableOptWatchOnceStrategy")

// 相册选择器的自定义配置：CustomConfig 上的 watchOnce 是"这个选择器支不支持闪图"（配置），
// 不是"这张图发不发闪图"（那是 PhotoPickerModel / LocalAsset 上的同名属性，一处都没碰）。
static BOOL (*o_pickerConfig)(id, SEL);
static BOOL h_pickerConfig(id self, SEL _cmd) {
    BOOL orig = o_pickerConfig ? o_pickerConfig(self, _cmd) : NO;
    if (!SLWatchOnceEntryOn()) return orig;
    static BOOL once = NO;
    if (!once) { once = YES; SLLog(@"ONCE| pickerConfig.watchOnce 原生=%d → 1", orig); }
    return YES;
}

// 带参数的：-supportWatchOnce:（入参是会话/uid，只判断支不支持）
static BOOL (*o_supportSvc)(id, SEL, id);
static BOOL h_supportSvc(id self, SEL _cmd, id arg) {
    BOOL orig = o_supportSvc ? o_supportSvc(self, _cmd, arg) : NO;
    if (!SLWatchOnceEntryOn()) return orig;
    static BOOL once = NO;
    if (!once) { once = YES; SLLog(@"ONCE| studio.supportWatchOnce: 原生=%d → 1", orig); }
    return YES;
}

#pragma mark - 保底那条：直接改写发送决策

// 原生按钮万一没出现，打开「相册默认闪图」后这里保证能发出去。
// 只在真要改写时打日志，平时静默。
static void (*o_sendAssets)(id, SEL, id, BOOL);
static void h_sendAssets(id self, SEL _cmd, id assets, BOOL once) {
    if (SLWatchOnceEntryOn() && SLWatchOnceForceOn() && !once) {
        SLLog(@"ONCE| sendAssets 改写为闪图 class=%@", [assets class]);
        once = YES;
    }
    if (o_sendAssets) o_sendAssets(self, _cmd, assets, once);
}

#pragma mark - v0.6.1 定位：相册到底用哪个类

// 依据：v0.6.0 日志里 9 个钩子全部挂上，但除了 enableOptWatchOnceStrategy（本来就是 1）
// 一个都没被调用 —— 说明 41.2.0 的「相册 → 发送」不走那条链。
// 这里只做一件事：把用户真正打开的相册类抓出来（类名 + 方法名 + ivar 名 + 子视图类），
// 不钩发送、不读对象内存、不扫全库，打开一次相册就出结果。

static NSInteger sSLPickDumps = 0;
static NSMutableSet *sSLPickSeen = nil;
static NSMutableSet *sSLViewSeen = nil;

static BOOL SLNameHas(NSString *s, NSArray *keys) {
    if (!s.length) return NO;
    for (NSString *k in keys) if ([s containsString:k]) return YES;
    return NO;
}

static void SLDumpMethods(Class cls, NSString *tag, NSArray *keys, NSInteger cap) {
    if (!cls) { SLLog(@"PICK| %@ 类不存在", tag); return; }
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    NSInteger shown = 0;
    for (unsigned int i = 0; i < n && shown < cap; i++) {
        NSString *sn = NSStringFromSelector(method_getName(list[i]));
        if (keys.count && !SLNameHas(sn, keys)) continue;
        SLLog(@"PICK| %@  -%@", tag, sn);
        shown++;
    }
    if (list) free(list);
    SLLog(@"PICK| %@  共 %u 个本类方法（列出 %ld 个）", tag, n, (long)shown);
}

// 只打名字，不碰内存：类链上每层的 ivar 名里带 watch/once/send/disable 的
static void SLDumpIvars(Class cls, NSString *tag) {
    int depth = 0;
    for (Class c = cls; c && c != [NSObject class] && depth < 4; c = class_getSuperclass(c), depth++) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *in = [NSString stringWithUTF8String:ivar_getName(ivars[i]) ?: ""];
            if (SLNameHas(in, @[@"watch", @"Watch", @"once", @"Once", @"send", @"Send", @"disable", @"Disable"])) {
                SLLog(@"PICK| %@  ivar %@.%@", tag, NSStringFromClass(c), in);
            }
        }
        if (ivars) free(ivars);
    }
}

static void SLDumpViews(UIView *v, NSString *tag, NSInteger depth, NSInteger *budget) {
    if (!v || depth > 3 || *budget <= 0) return;
    for (UIView *sub in v.subviews) {
        if (*budget <= 0) return;
        NSString *cn = NSStringFromClass([sub class]);
        if (SLNameHas(cn, @[@"Watch", @"Once", @"Button", @"Bar", @"Toolbar"])) {
            SLLog(@"PICK| %@  视图 %@ hidden=%d", tag, cn, sub.hidden);
            (*budget)--;
        }
        SLDumpViews(sub, tag, depth + 1, budget);
    }
}

static void SLDumpViewController(UIViewController *vc) {
    NSString *cn = NSStringFromClass([vc class]);
    if (!sSLPickSeen) sSLPickSeen = [NSMutableSet set];
    if (!sSLViewSeen) sSLViewSeen = [NSMutableSet set];

    if (![sSLPickSeen containsObject:cn] && sSLPickDumps < 12) {
        [sSLPickSeen addObject:cn];
        sSLPickDumps++;
        SLLog(@"PICK| == VC %@  父类 %@ ==", cn, NSStringFromClass(class_getSuperclass([vc class])));
        SLDumpMethods([vc class], cn, @[@"send", @"Send", @"watch", @"Watch", @"once", @"Once",
                                       @"confirm", @"Confirm", @"select", @"Select",
                                       @"done", @"Done", @"album", @"Album"], 40);
        SLDumpIvars([vc class], cn);
    }

    // 视图树要等 loadView 之后才有，present 那一刻先记类名，出现时再补一次子视图
    if ([vc isViewLoaded] && ![sSLViewSeen containsObject:cn]) {
        [sSLViewSeen addObject:cn];
        NSInteger budget = 24;
        SLLog(@"PICK| -- %@ 子视图 --", cn);
        SLDumpViews(vc.view, cn, 0, &budget);
        if (budget == 24) SLLog(@"PICK| -- %@ 子视图里没有 Button/Bar/Watch 命名的 --", cn);
    }
}

// 打开哪些页会进这里：只要类名像相册 / 选图 / 预览就 dump 一次
static void SLInstallOnceButton(UIViewController *vc);   // v0.7.0：相册页那颗闪图按钮

static void (*o_vcAppear)(id, SEL, BOOL);
static void h_vcAppear(id self, SEL _cmd, BOOL animated) {
    o_vcAppear(self, _cmd, animated);
    @try {
        NSString *cn = NSStringFromClass([self class]);
        if (SLNameHas(cn, @[@"Picker", @"Album", @"Gallery", @"Photo", @"Asset",
                            @"Preview", @"Selection", @"IMInput", @"InputVC"])) {
            SLDumpViewController(self);
        }
        // 就是它：私聊相册页
        if ([cn isEqualToString:@"AWEIMPickerViewController"]) {
            SLInstallOnceButton((UIViewController *)self);
        }
    } @catch (NSException *e) { (void)e; }
}

static void (*o_vcLoad)(id, SEL);
static void h_vcLoad(id self, SEL _cmd) {
    o_vcLoad(self, _cmd);
    @try {
        NSString *cn = NSStringFromClass([self class]);
        if (SLNameHas(cn, @[@"Picker", @"Album", @"Gallery", @"Photo", @"Asset", @"Preview"])) {
            SLDumpViewController(self);
        }
    } @catch (NSException *e) { (void)e; }
}

// 相册很多是 present 出来的：不管它自己覆没覆写 viewDidAppear，present 这一跳一定过
static void (*o_vcPresent)(id, SEL, UIViewController *, BOOL, id);
static void h_vcPresent(id self, SEL _cmd, UIViewController *vc, BOOL animated, id completion) {
    o_vcPresent(self, _cmd, vc, animated, completion);
    @try {
        SLLog(@"PICK| present %@ ← %@", NSStringFromClass([vc class]), NSStringFromClass([self class]));
        SLDumpViewController(vc);
    } @catch (NSException *e) { (void)e; }
}

// 新版相册工具栏：闪图发送按钮就在这个 view 上，看看它到底有没有、隐没隐
static void (*o_barLayout)(id, SEL);
static void h_barLayout(id self, SEL _cmd) {
    o_barLayout(self, _cmd);
    static BOOL once = NO;
    if (once) return;
    once = YES;
    @try {
        id btn = [self performSelector:@selector(watchOnceSendButton)];
        SLLog(@"PICK| NewPhotoPickerToolbar watchOnceSendButton = %@", btn);
        if (btn && [btn isKindOfClass:[UIView class]]) {
            SLLog(@"PICK| NewPhotoPickerToolbar 按钮 hidden=%d", ((UIView *)btn).hidden);
        }
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - v0.6.2 真身：AWEIMPickerViewController + AWEIMPhotoPickerToolbarViewV2

// v0.6.1 的日志给到答案：
//   PICK| == VC AWEIMPickerViewController  父类 AWEIMComponentViewController
//   PICK| AWEIMPickerViewController  视图 AWEIMPhotoPickerToolbarViewV2 hidden=0
// 也就是：私聊相册 = AWEIMPickerViewController，工具栏是 …ToolbarViewV2（V1 那个
// AWEIMNewPhotoPickerToolbarView 在这条路上根本不存在，所以上一版钩子全是空转）。
//
// 这一版做两件事，都不改发送逻辑：
//   ① 把这两个类的方法名全列出来（VC 只有 22 个，很小）；
//   ② 给名字里带 send/watch/once/select/confirm/tap… 的无参/单参 void 方法装一个
//      只打日志的追踪钩子 —— 你点一次发送，日志就会按顺序写出到底走了哪几个方法。

typedef struct {
    SEL sel;
    IMP orig;
    int argc;
} SLTraceSlot;

static SLTraceSlot sSLSlots[128];
static int sSLSlotCount = 0;
static int sSLTraceLines = 0;

static IMP SLTraceOrigIMP(SEL sel) {
    for (int i = 0; i < sSLSlotCount; i++) {
        if (sSLSlots[i].sel == sel) return sSLSlots[i].orig;
    }
    return NULL;
}

static void sl_trace0(id self, SEL _cmd) {
    if (sSLTraceLines < 220) {
        sSLTraceLines++;
        SLLog(@"V2| call -%s  (%@)", sel_getName(_cmd), NSStringFromClass([self class]));
    }
    IMP o = SLTraceOrigIMP(_cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
}

static void sl_trace1(id self, SEL _cmd, id a1) {
    if (sSLTraceLines < 220) {
        sSLTraceLines++;
        SLLog(@"V2| call -%s  arg=%@", sel_getName(_cmd), NSStringFromClass([a1 class]));
    }
    IMP o = SLTraceOrigIMP(_cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, a1);
}

static void SLTraceClass(Class cls, NSString *tag) {
    if (!cls) { SLLog(@"V2| 没有类 %@", tag); return; }
    NSArray *keys = @[@"send", @"Send", @"watch", @"Watch", @"once", @"Once",
                      @"select", @"Select", @"confirm", @"Confirm", @"commit", @"Commit",
                      @"done", @"Done", @"tap", @"Tap", @"press", @"Press",
                      @"finish", @"Finish", @"choose", @"Choose"];
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    int hooked = 0;
    for (unsigned int i = 0; i < n && sSLSlotCount < 128; i++) {
        SEL s = method_getName(list[i]);
        NSString *sn = NSStringFromSelector(s);
        if ([sn hasPrefix:@"set"]) continue;
        if (!SLNameHas(sn, keys)) continue;

        char *ret = method_copyReturnType(list[i]);
        BOOL isVoid = (ret && ret[0] == 'v');
        if (ret) free(ret);
        if (!isVoid) continue;

        int argc = 0;
        for (const char *p = sel_getName(s); *p; p++) if (*p == ':') argc++;
        if (argc > 1) continue;

        // 单参的必须是对象或整数，浮点/结构体会走寄存器不同位置，硬套签名会把参数传坏
        if (argc == 1) {
            char at[8] = {0};
            method_getArgumentType(list[i], 2, at, sizeof(at));
            char t = at[0];
            BOOL ok = (t == '@' || t == '#' || t == ':' || t == 'i' || t == 'I' ||
                       t == 'q' || t == 'Q' || t == 'B' || t == 'c' || t == 'l');
            if (!ok) continue;
        }

        IMP orig = method_getImplementation(list[i]);
        sSLSlots[sSLSlotCount].sel = s;
        sSLSlots[sSLSlotCount].orig = orig;
        sSLSlots[sSLSlotCount].argc = argc;
        sSLSlotCount++;
        method_setImplementation(list[i], argc == 0 ? (IMP)sl_trace0 : (IMP)sl_trace1);
        hooked++;
    }
    if (list) free(list);
    SLLog(@"V2| %@：本类 %u 个方法，追踪 %d 个", tag, n, hooked);
}

// 工具栏上到底有没有「闪图 / 阅后即焚」按钮：按标题和无障碍文案找，找到就点亮
static BOOL sSLRevealed = NO;
static void SLScanWatchControls(UIView *v, NSString *tag) {
    if (!v) return;
    for (UIView *sub in v.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        NSString *title = nil;
        if ([sub isKindOfClass:[UIButton class]]) {
            title = [(UIButton *)sub titleForState:UIControlStateNormal];
        }
        NSString *acc = sub.accessibilityLabel ?: @"";
        NSString *hay = [NSString stringWithFormat:@"%@ %@", title ?: @"", acc];

        if (SLNameHas(hay, @[@"闪", @"阅后", @"一次性", @"看完"])) {
            SLLog(@"V2| 命中闪图按钮 %@ title=%@ hidden=%d", cls, title, sub.hidden);
            if (sub.hidden && !sSLRevealed) {
                sub.hidden = NO;
                sSLRevealed = YES;
                SLLog(@"V2| 已把它放出来（title=%@）", title);
            }
        } else if (SLNameHas(cls, @[@"Watch", @"Once"])) {
            SLLog(@"V2| 闪图相关视图 %@ hidden=%d alpha=%.2f", cls, sub.hidden, sub.alpha);
        }
        SLScanWatchControls(sub, tag);
    }
}

static void (*o_v2Layout)(id, SEL);
static void h_v2Layout(id self, SEL _cmd) {
    o_v2Layout(self, _cmd);
    static BOOL once = NO;
    if (once) return;
    once = YES;
    @try {
        SLLog(@"V2| ToolbarViewV2 布局完成，开始找闪图按钮");
        SLScanWatchControls(self, @"toolbarV2");
        // 工具栏自己的 ivar 里有没有 watch/once 相关字段（只打名字）
        SLDumpIvars([self class], @"toolbarV2");
    } @catch (NSException *e) { (void)e; }
}

#pragma mark - v0.7.0 在相册页加一个「闪图」按钮

// 用户要的是「相册里多一个闪图按钮，点它才发闪图」。
// 抖音原生的「仅看一次」藏在发送按钮的长按菜单里，位置不固定；这里自己放一个按钮，
// 点它就去调原生的闪图发送入口（找到就发，找不到就把现场状态写进日志，一次定位）。

static UIButton *sSLOctBtn = nil;

static UIViewController *SLParentVC(UIView *v) {
    for (UIResponder *r = v.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
    }
    return nil;
}

static UIView *SLFindByClass(UIView *root, NSString *cls, int depth) {
    if (!root || depth > 12) return nil;
    if ([NSStringFromClass([root class]) isEqualToString:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *hit = SLFindByClass(sub, cls, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIButton *SLFindButtonWithTitle(UIView *root, NSString *needle, int depth) {
    if (!root || depth > 12) return nil;
    if ([root isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)root titleForState:UIControlStateNormal];
        if (t.length && [t containsString:needle]) return (UIButton *)root;
    }
    for (UIView *sub in root.subviews) {
        UIButton *hit = SLFindButtonWithTitle(sub, needle, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

__attribute__((unused))
static void SLScanButtons(UIView *v, int depth, int *budget) {
    if (!v || depth > 12 || *budget <= 0) return;
    if ([v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UIControl class]]) {
        NSString *t = [v isKindOfClass:[UIButton class]]
            ? [(UIButton *)v titleForState:UIControlStateNormal] : nil;
        SLLog(@"BTN|   %@ title=%@ hidden=%d frame=%@", NSStringFromClass([v class]),
              t ?: @"", v.hidden, NSStringFromCGRect(v.frame));
        (*budget)--;
    }
    for (UIView *sub in v.subviews) SLScanButtons(sub, depth + 1, budget);
}

static void SLOnceTapped(UIButton *b);
static void SLFireWatchOnce(UIView *source);
static void SLShowOnceMenu(UIView *source);

@interface SLOnceTarget : NSObject
@end
@implementation SLOnceTarget
- (void)tap:(UIButton *)b { SLOnceTapped(b); }
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    SLShowOnceMenu(g.view);
}
@end

// UIButton 不持有 target，得自己留一个，否则点一下就野指针
static SLOnceTarget *sSLOctTarget = nil;
static BOOL sSLOncePending = NO;    // 点了「闪图」之后、这次发送结束之前为 YES
static BOOL sSLBarDumped   = NO;    // delegate 方法名只 dump 一次

// 长按「发送」时的选择菜单：普通 / 仅看一次。这是不依赖任何布局的兜底入口。
static void SLShowOnceMenu(UIView *source) {
    UIViewController *vc = SLParentVC(source) ?: SLParentVC(sSLOctBtn);
    if (!vc) return;
    if (vc.presentedViewController) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"发送方式"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"普通图片"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    UIView *anchor = source;
    [sheet addAction:[UIAlertAction actionWithTitle:@"仅看一次（闪图）"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { SLFireWatchOnce(anchor); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    // iPad / 弹层必须给 source，否则直接崩
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = source ?: vc.view;
        pop.sourceRect = source ? source.bounds
                                : CGRectMake(vc.view.bounds.size.width / 2,
                                             vc.view.bounds.size.height / 2, 1, 1);
        pop.permittedArrowDirections = 0;
    }
    [vc presentViewController:sheet animated:YES completion:nil];
}

// 真正触发一次闪图发送：挂上 pending 标志，然后走抖音自己的发送动作。
// pending 期间 AWEIMSendMessageContext / IESIMSendMessageModel 的 setter 钩子会把
// isClickWatchOnce 置 1 —— 抖音内部据此走「仅看一次」拿一次性凭证，消息类型自然变成 91。
static void SLFireWatchOnce(UIView *source) {
    UIViewController *vc = SLParentVC(source) ?: SLParentVC(sSLOctBtn);
    UIView *root = (vc && vc.isViewLoaded) ? vc.view : nil;
    UIView *bar = root ? SLFindByClass(root, @"AWEIMPhotoPickerToolbarViewV2", 0) : nil;

    UIButton *send = nil;
    if (bar) send = SLFindButtonWithTitle(bar, @"发送", 0);
    if (!send && root) send = SLFindButtonWithTitle(root, @"发送", 0);

    if (!bar && !send) {
        SLLog(@"BTN| 触发失败：页面里既没有工具栏也没有发送按钮");
        return;
    }

    sSLOncePending = YES;
    SLLog(@"BTN| 触发闪图发送 pending=1");

    // v0.7.2：日志证明工具栏 delegate = AWEIMMessageListGalleryEntryComponent，
    // 它身上就有 watchOnceSendButtonInPickerPressed: / sendAsWatchOnce / sendAsNormal。
    // 之前调 onSendButtonTapped = 普通发送，所以发出去的是普通图。
    id del = nil;
    if (bar && [bar respondsToSelector:@selector(delegate)]) {
        @try { del = [bar performSelector:@selector(delegate)]; } @catch (NSException *e) { (void)e; }
    }
    if (del) SLLog(@"BTN| delegate = %@", NSStringFromClass([del class]));

    // 第一步：把 delegate 切到「闪图」模式
    if (del) {
        if ([del respondsToSelector:@selector(setSendAsWatchOnce:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(del, @selector(setSendAsWatchOnce:), YES);
            SLLog(@"BTN| delegate.sendAsWatchOnce → 1");
        }
        if ([del respondsToSelector:@selector(setSendAsNormal:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(del, @selector(setSendAsNormal:), NO);
            SLLog(@"BTN| delegate.sendAsNormal → 0");
        }
        if ([del respondsToSelector:@selector(setDisableSendWatchOnce:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(del, @selector(setDisableSendWatchOnce:), NO);
            SLLog(@"BTN| delegate.disableSendWatchOnce → 0");
        }
    }

    // 第二步：按优先级真正触发一次发送
    BOOL fired = NO;
    if (del && [del respondsToSelector:@selector(watchOnceSendButtonInPickerPressed:)]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(del,
                @selector(watchOnceSendButtonInPickerPressed:), (id)(send ?: bar));
            fired = YES;
            SLLog(@"BTN| 已调 -watchOnceSendButtonInPickerPressed:");
        } @catch (NSException *e) { SLLog(@"BTN| 闪图发送异常 %@", e); }
    }
    if (!fired && del && [del respondsToSelector:@selector(sendButtonInPickerPressed:)]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(del,
                @selector(sendButtonInPickerPressed:), (id)(send ?: bar));
            fired = YES;
            SLLog(@"BTN| 已调 -sendButtonInPickerPressed:（delegate 已置闪图模式）");
        } @catch (NSException *e) { SLLog(@"BTN| 发送异常 %@", e); }
    }
    if (!fired && bar && [bar respondsToSelector:@selector(onSendButtonTapped)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(bar, @selector(onSendButtonTapped));
            fired = YES;
            SLLog(@"BTN| 已调 -onSendButtonTapped（兜底）");
        } @catch (NSException *e) { SLLog(@"BTN| 兜底异常 %@", e); }
    }
    if (!fired) SLLog(@"BTN| 没有任何可用发送入口");

    // 第三步：3 秒后把 delegate 复位，免得下一次点普通发送也变成闪图
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!del) return;
        @try {
            if ([del respondsToSelector:@selector(setSendAsWatchOnce:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(del, @selector(setSendAsWatchOnce:), NO);
            if ([del respondsToSelector:@selector(setSendAsNormal:)])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(del, @selector(setSendAsNormal:), YES);
            SLLog(@"BTN| delegate 已复位（sendAsWatchOnce=0 / sendAsNormal=1）");
        } @catch (NSException *e) { (void)e; }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sSLOncePending) {
            sSLOncePending = NO;
            SLLog(@"BTN| pending 超时清除（这次发送没有走到 context/model 钩子）");
        }
    });
}

static void SLOnceTapped(UIButton *b) {
    SLLog(@"BTN| == 点了闪图按钮 ==");
    UIViewController *vc = SLParentVC(b);
    SLLog(@"BTN| 所在页面 %@", NSStringFromClass([vc class]));

    UIView *bar = vc.isViewLoaded
        ? SLFindByClass(vc.view, @"AWEIMPhotoPickerToolbarViewV2", 0) : nil;
    UIButton *send = bar ? SLFindButtonWithTitle(bar, @"发送", 0) : nil;
    SLLog(@"BTN| 工具栏 %@ · 发送按钮 %@", bar ? @"找到" : @"没找到", send ? @"找到" : @"没找到");

    // 工具栏的 delegate 就是发图的执行者，方法名只 dump 一次，用来接发送链路
    if (bar && !sSLBarDumped && [bar respondsToSelector:@selector(delegate)]) {
        sSLBarDumped = YES;
        id del = nil;
        @try { del = [bar performSelector:@selector(delegate)]; } @catch (NSException *e) { (void)e; }
        if (del) {
            NSString *dn = NSStringFromClass([del class]);
            SLLog(@"BTN| 工具栏 delegate = %@", dn);
            SLDumpMethods([del class], [NSString stringWithFormat:@"delegate(%@)", dn], @[], 80);
        }
    }

    SLFireWatchOnce(b);
}

// 把所有坐标都换算到页面根视图坐标系里，再夹到可见范围内 —— 这一步是 v0.7.0 失败的根因：
// viewDidAppear 时组件布局还没跑，toolbar 与发送按钮的 frame 都是 0，按钮被算到了屏幕外。
static void SLLayoutOnceButton(UIViewController *vc, BOOL verbose) {
    if (!vc || !vc.isViewLoaded) return;
    UIView *root = vc.view;
    UIButton *b = sSLOctBtn;
    if (!b) return;

    if (b.superview != root) {
        [b removeFromSuperview];
        [root addSubview:b];
    }
    [root bringSubviewToFront:b];
    b.layer.zPosition = 3000;
    b.hidden = NO;

    // v0.7.2：不再换坐标系算位置 —— 日志证明 toolbar 高度是 0、发送按钮 y=940 已经超出页面 926，
    // 任何 convertRect 都会算歪。直接挂到「发送」按钮的父视图上，用同一套本地坐标，天然对齐同一行。
    UIButton *send = SLFindButtonWithTitle(root, @"发送", 0);
    UIView *p = send.superview;
    CGRect sr = send.frame;
    BOOL ok = (p != nil) && (sr.size.height > 1) && (sr.size.width > 1);

    if (ok) {
        if (b.superview != p) {
            [b removeFromSuperview];
            [p addSubview:b];
        }
        [p bringSubviewToFront:b];
        b.layer.zPosition = 3000;
        CGFloat h = sr.size.height > 22 ? sr.size.height : 30;
        CGFloat w = 40;
        CGFloat x = sr.origin.x - w - 8;
        if (x < 2) x = CGRectGetMaxX(sr) + 8;          // 左边放不下就放右边
        b.frame = CGRectMake(x, CGRectGetMidY(sr) - h / 2, w, h);
        b.layer.cornerRadius = h / 2;
        if (verbose) {
            SLLog(@"BTN| 摆位 %@ 方式=与发送同一行 父=%@ 发送=%@",
                  NSStringFromCGRect(b.frame), NSStringFromClass([p class]),
                  NSStringFromCGRect(sr));
        }
        return;
    }

    // 兜底：发送按钮还没建出来，先贴页面右下角，后面几次重排会纠正
    if (b.superview != root) {
        [b removeFromSuperview];
        [root addSubview:b];
    }
    [root bringSubviewToFront:b];
    b.layer.zPosition = 3000;
    CGSize ss = root.bounds.size;
    b.layer.cornerRadius = 20;
    b.frame = CGRectMake(ss.width - 60, ss.height - 140, 40, 40);
    if (verbose) {
        SLLog(@"BTN| 摆位 %@ 方式=右下角兜底 根=%@ 发送=%@",
              NSStringFromCGRect(b.frame), NSStringFromCGRect(root.bounds), send ? @"有" : @"无");
    }
}

static void SLInstallOnceButton(UIViewController *vc) {
    if (!vc.isViewLoaded) return;

    if (!sSLOctBtn) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, 40, 40);
        b.backgroundColor = [UIColor colorWithRed:0.47 green:0.33 blue:0.96 alpha:0.95];
        b.layer.cornerRadius = 20;
        b.layer.shadowColor = [UIColor colorWithRed:0.35 green:0.2 blue:0.9 alpha:0.6].CGColor;
        b.layer.shadowRadius = 6;
        b.layer.shadowOpacity = 1;
        b.layer.shadowOffset = CGSizeZero;
        [b setTitle:@"闪" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        if (!sSLOctTarget) sSLOctTarget = [SLOnceTarget new];
        [b addTarget:sSLOctTarget action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        sSLOctBtn = b;
    }

    SLLayoutOnceButton(vc, YES);

    // 组件化布局在 viewDidAppear 之后才完成，多次重排，以最后一次为准（幂等，不会加出第二个）
    for (NSNumber *d in @[@0.15, @0.45, @1.0, @1.8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (sSLOctBtn.superview == vc.view) SLLayoutOnceButton(vc, NO);
        });
    }

    // 兜底入口：长按工具栏「发送」，直接弹「普通 / 仅看一次」。不依赖按钮摆位。
    // 用关联标记判断这个按钮是否已经加过，工具栏重建后能自动补上。
    UIView *bar = SLFindByClass(vc.view, @"AWEIMPhotoPickerToolbarViewV2", 0);
    UIButton *send = bar ? SLFindButtonWithTitle(bar, @"发送", 0) : nil;
    static const void *kSLLongPressKey = &kSLLongPressKey;
    if (send && !objc_getAssociatedObject(send, kSLLongPressKey)) {
        objc_setAssociatedObject(send, kSLLongPressKey, @1, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:sSLOctTarget
                                                          action:@selector(longPress:)];
        lp.minimumPressDuration = 0.45;
        [send addGestureRecognizer:lp];
        SLLog(@"BTN| 已给「发送」加长按菜单（普通 / 仅看一次）");
    }
}

// 聊天窗口图片的「发闪图」操作条（这条原生一定能用，作为参照）
static void (*o_actionBarLayout)(id, SEL);
static void h_actionBarLayout(id self, SEL _cmd) {
    o_actionBarLayout(self, _cmd);
    static BOOL once = NO;
    if (once) return;
    once = YES;
    @try {
        SLLog(@"PICK| ExchangeAndSendImageActionBar init 完成");
        SLDumpIvars([self class], @"ExchangeBar");
    } @catch (NSException *e) { (void)e; }
}

// ---- v0.7.1：点了「闪图」之后，把这次发送标成 watch-once ----
// AWEIMSendMessageContext.isClickWatchOnce 是抖音自己的字段，读它的地方会去拿一次性凭证。
// 只在 sSLOncePending 期间改，普通发送完全不受影响。
static void SLMarkWatchOnce(id ctx, NSString *tag) {
    if (!ctx) return;
    @try {
        SEL s = NSSelectorFromString(@"setIsClickWatchOnce:");
        if ([ctx respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(ctx, s, YES);
            SLLog(@"BTN| %@.isClickWatchOnce → 1", tag);
        } else {
            SLLog(@"BTN| %@ 没有 setIsClickWatchOnce:", tag);
        }
    } @catch (NSException *e) {
        SLLog(@"BTN| %@ 置位失败 %@", tag, e);
    }
}

static void (*o_ctxSendFrom)(id, SEL, id);
static void h_ctxSendFrom(id self, SEL _cmd, id from) {
    if (o_ctxSendFrom) o_ctxSendFrom(self, _cmd, from);
    if (sSLOncePending) SLMarkWatchOnce(self, @"SendMessageContext");
}

// 比改字段更硬的一层：pending 期间谁读这个值，就给 YES。
// 抖音内部据此决定走不走「仅看一次」的一次性凭证流程。
static BOOL (*o_ctxIsClick)(id, SEL);
static BOOL h_ctxIsClick(id self, SEL _cmd) {
    BOOL orig = o_ctxIsClick ? o_ctxIsClick(self, _cmd) : NO;
    if (!sSLOncePending) return orig;
    static BOOL once = NO;
    if (!once) { once = YES; SLLog(@"BTN| 读 isClickWatchOnce：原生=%d → 1", orig); }
    return YES;
}

static void (*o_modelSetCtx)(id, SEL, id);
static void h_modelSetCtx(id self, SEL _cmd, id ctx) {
    if (o_modelSetCtx) o_modelSetCtx(self, _cmd, ctx);
    if (sSLOncePending) SLMarkWatchOnce(ctx, @"SendMessageModel.sendContext");
}

#pragma mark - 装配

void SLWatchOnceStart(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    SLLog(@"ONCE| ==== 相册闪图 v0.7.2 · 入口=%d · 默认闪图=%d ====",
          SLWatchOnceEntryOn(), SLWatchOnceForceOn());

    // v0.6.0 那两个开关没有生效（钩子从未被调用），设置页已撤掉；
    // 万一用户当时把「默认闪图」打开了，值还在 defaults 里，这里清掉，避免以后误触发。
    if (SLWatchOnceForceOn()) {
        SLWatchOnceSetForce(NO);
        SLLog(@"ONCE| 已清除 v0.6.0 遗留的「默认闪图」开关值");
    }

    Class c = Nil;

    // 相册选择器配置
    c = objc_getClass("AWEIMAssetGalleryPickerCustomConfig");
    SLInstallBool(c, @selector(watchOnce), (IMP)h_pickerConfig, (IMP *)&o_pickerConfig,
                  @"pickerConfig.watchOnce");

    // 从相册选图 → 发送 的主入口
    c = objc_getClass("AWEIMMessageListGalleryEntryComponent");
    SLInstallBool(c, @selector(disableSendWatchOnce), (IMP)h_galleryDisable, (IMP *)&o_galleryDisable,
                  @"gallery.disableSendWatchOnce");
    SLInstallVoid(c, @selector(sendAssets:isSendWatchOnce:), (IMP)h_sendAssets, (IMP *)&o_sendAssets,
                  @"gallery.sendAssets:isSendWatchOnce:");

    // 快捷选图（输入框旁边的相册小入口）
    c = objc_getClass("AWEIMQuickSelectPhotoInteractor");
    SLInstallBool(c, @selector(disableSendWatchOnce), (IMP)h_quickDisable, (IMP *)&o_quickDisable,
                  @"quick.disableSendWatchOnce");

    // 预览页的发送按钮
    c = objc_getClass("AWEIMPhotoPreviewEditorCollectionView");
    SLInstallBool(c, @selector(disableSendWatchOnce), (IMP)h_previewDisable, (IMP *)&o_previewDisable,
                  @"preview.disableSendWatchOnce");

    // 会话能力判定：判成不支持就不给入口
    c = objc_getClass("IESIMInputVCFeedDetailAdapter");
    SLInstallBool(c, @selector(needSupportWatchOnce), (IMP)h_feedAdapter, (IMP *)&o_feedAdapter,
                  @"feedAdapter.needSupportWatchOnce");

    c = objc_getClass("IESIMInputVCDefaultAdapter");
    SLInstallBool(c, @selector(needSupportWatchOnce), (IMP)h_defaultAdapter, (IMP *)&o_defaultAdapter,
                  @"defaultAdapter.needSupportWatchOnce");

    c = objc_getClass("AWEStudioIMModuleServiceImpl");
    SLInstallBool(c, @selector(supportWatchOnce:), (IMP)h_supportSvc, (IMP *)&o_supportSvc,
                  @"studio.supportWatchOnce:");

    // 灰度策略：不开就等于没这个功能
    c = objc_getClass("AWEIMContextRecommendUtil");
    SLInstallBool(c, @selector(enableOptWatchOnceStrategy), (IMP)h_optStrategy, (IMP *)&o_optStrategy,
                  @"contextRecommend.enableOptWatchOnceStrategy");

    // v0.7.1：点了闪图按钮后，把这次发送的上下文标成 watch-once（只在 pending 期间生效）
    c = objc_getClass("AWEIMSendMessageContext");
    SLInstallBool(c, @selector(isClickWatchOnce), (IMP)h_ctxIsClick, (IMP *)&o_ctxIsClick,
                  @"context.isClickWatchOnce");
    SLInstallVoid(c, @selector(setSendFrom:), (IMP)h_ctxSendFrom, (IMP *)&o_ctxSendFrom,
                  @"context.setSendFrom:");

    c = objc_getClass("IESIMSendMessageModel");
    SLInstallVoid(c, @selector(setSendContext:), (IMP)h_modelSetCtx, (IMP *)&o_modelSetCtx,
                  @"model.setSendContext:");

    // ---- v0.6.1 定位相册：只观察，不改任何值 ----
    // 三个锚点覆盖三种可能：present（一定能过）、viewDidLoad、viewDidAppear
    SLInstallVoid([UIViewController class], @selector(viewDidLoad), (IMP)h_vcLoad,
                  (IMP *)&o_vcLoad, @"vc.viewDidLoad");
    SLInstallVoid([UIViewController class], @selector(viewDidAppear:), (IMP)h_vcAppear,
                  (IMP *)&o_vcAppear, @"vc.viewDidAppear:");
    SLInstallVoid([UIViewController class],
                  @selector(presentViewController:animated:completion:), (IMP)h_vcPresent,
                  (IMP *)&o_vcPresent, @"vc.presentViewController:");

    c = objc_getClass("AWEIMNewPhotoPickerToolbarView");
    SLInstallVoid(c, @selector(layoutSubviews), (IMP)h_barLayout, (IMP *)&o_barLayout,
                  @"newPickerToolbar.layoutSubviews");

    c = objc_getClass("AWEIMExchangeAndSendImageActionBarView");
    SLInstallVoid(c, @selector(layoutSubviews), (IMP)h_actionBarLayout, (IMP *)&o_actionBarLayout,
                  @"exchangeBar.layoutSubviews");

    // 已知一定在发图链路上的模型类：直接把方法名摊开，找有没有闪图相关入口
    SLDumpMethods(objc_getClass("IESIMSendMessageModel"), @"IESIMSendMessageModel", @[], 100);
    SLDumpMethods(objc_getClass("AWEIMSendMessageContext"), @"AWEIMSendMessageContext",
                  @[@"watch", @"Watch", @"send", @"Send", @"image", @"Image", @"model", @"Model"], 60);

    // ---- v0.6.2 真身：私聊相册 = AWEIMPickerViewController，工具栏 = …ToolbarViewV2 ----
    for (NSString *name in @[@"AWEIMPickerViewController",
                             @"AWEIMPhotoPickerToolbarViewV2",
                             @"AWEIMPhotoPickerToolbarView"]) {
        Class k = objc_getClass(name.UTF8String);
        if (!k) { SLLog(@"V2| 没有类 %@", name); continue; }
        SLDumpMethods(k, name, @[], 90);
        SLTraceClass(k, name);
    }

    c = objc_getClass("AWEIMPhotoPickerToolbarViewV2");
    SLInstallVoid(c, @selector(layoutSubviews), (IMP)h_v2Layout, (IMP *)&o_v2Layout,
                  @"toolbarV2.layoutSubviews");

    SLLog(@"ONCE| 装配完成");
}
