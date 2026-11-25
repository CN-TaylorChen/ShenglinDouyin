#import <UIKit/UIKit.h>

// 陌陌版浮动入口按钮（可拖动，位置记忆）
void SLEnsureFloatButton(void);
void SLStartEntryWatcher(void);

// v0.4.5：悬浮球图标可换（文字 / 表情 / 自选图片）
void SLRefreshFloatButton(void);        // 改完设置后立刻刷新已挂载的按钮
NSString *SLFloatIconSummary(void);     // 设置页右侧显示当前图标

// v0.4.54：把球抬到最上层。
// 设置浮窗 / 试听卡片都是 OverFullScreen 呈现，会盖在球上面（球一半被卡片压住）。
// 面板每次出现后调一次：球若换了窗口先迁过去，再在同一个窗口里 bringSubviewToFront。
void SLRaiseFloatButton(void);

// v0.4.33：品牌图标（黑底 + 六根声波条），代码绘制，不依赖任何图片资源。
// 设置页标题栏和悬浮球共用同一张，保证两处视觉一致。
UIImage *SLBrandIconImage(CGFloat side);
UIImage *SLBrandIconImageTinted(CGFloat side, UIColor *bg);

// v0.4.34：悬浮球三态。录音红 / 合成蓝 / 就绪绿（直到语音真正发出去）。
// v0.4.36：就绪不再自动回空闲；Ready → Idle 的切换会外扩一圈涟漪。
// Tweak.x 只在钩子里调这个，界面细节全部留在 SLEntry.m。
typedef NS_ENUM(NSInteger, SLFloatState) {
    SLFloatStateIdle = 0,          // 灰：槽位空，原声
    SLFloatStateRecording = 1,     // 红：正在录
    SLFloatStateSynthesizing = 2,  // 蓝：识别 / 合成中
    SLFloatStateReady = 3,         // 绿：槽位里装好了东西
};
void SLFloatSetState(SLFloatState state);

// v0.4.60：同上，但不触发「合成完成」的缩放回弹。
// 试听面板呈现时用这个：面板自己有弹入动画，球再缩一下会撞车。
void SLFloatSetStateQuiet(SLFloatState state);

// v0.4.82：合成状态并进悬浮胶囊，不再有独立进度卡片（原来那张浮在球上方，遮聊天记录）。
// 合成开始 → 胶囊自动展开：左端图标保持状态色，中间「合成中 / 已等 12s · 上限 30s」，
// 右端一个「取消」小胶囊，底部一条 2pt 时间条按「已等待 / 上限」推进。
// 取消块由调用方提供；约定「取消后球回落灰、不发送」。
void SLFloatTTSBegin(NSTimeInterval limitSec, void (^cancelBlock)(void));

// 同上，但主行文字自己给（「识别中」/「合成中」）。抖音的链路是识别 → 合成两段，
// 两段共用同一条胶囊，靠 SLFloatTTSPhase 换字，不重开计时。
void SLFloatTTSBeginWithTitle(NSString *title, NSTimeInterval limitSec, void (^cancelBlock)(void));
void SLFloatTTSPhase(NSString *title);

// success=YES：0.2s 收起回球，不弹任何提示。
// success=NO ：胶囊原地转红，主行 failText、副行原因，停 2.6s 收球；
//              期间点胶囊 / 右端「重试」会执行 retryBlock（重来一次合成）。
void SLFloatTTSEnd(BOOL success, NSString *failText, void (^retryBlock)(void));

// 用户点了胶囊上的「取消」：立刻收球，球按槽位状态落定（装了 → 绿，没装 → 灰），
// 停在失败态再收会让球挂在合成蓝上。hint 非空时弹一次短 toast。
void SLFloatTTSAbort(NSString *hint);

// v0.5.x：「合成后先试听」整段删除。抖音语音松手即发送，替换后再听只是
// "事后回放"，改不了已经发出去的那条 —— 留着是假入口。

// v0.4.34：设置 / 语音包都装在浮窗里，内部是子控制器，
// 点「完成」要先向上找到真正的呈现者，否则 dismiss 自己什么也不会发生。
void SLCloseHostingPanel(UIViewController *vc);

// 顶栏波形按钮的入口：直接开唯一的那套设置页。
// 实现在 SLEntry.m（SLFloatPanelController 是私有类，外面拿不到）。
void SLPresentSettings(UIViewController *host);

// v0.5.7：#ball 口令控制显隐。
// 隐藏只是 hidden = YES —— 位置、图标、当前状态全部保留，再打一次 #ball 原样回来。
BOOL SLFloatIsHidden(void);
void SLSetFloatHidden(BOOL hidden);

// v0.4.41：清掉当前装填的那一发（语音包 / 生成语音都算）。
// 语音包和「生成语音」共用同一个槽位，后写覆盖先写 —— 选包时调它把合成音赶走，
// 否则会出现「明明选了包，发出去却是刚才那段合成音」。实现放在 Tweak.x。
void SLClearArmedAudio(void);

// 设置页「生成语音」的装填桥接。实现在 Tweak.x（那里才有替换钩子的全局状态）。
// 合成成功后只写槽位，不碰输入框 / 胶囊进度；录音时钩子自动替换成这条 AI 音频。
// pcm16k 为兼容旧调用保留，抖音走文件级替换，用不上。
BOOL SLTTSPageIsEnabled(void);
BOOL SLTTSPageArm(NSString *audioPath, double duration, NSData *pcm16k, NSString *text);

@interface SLFloatIconController : UITableViewController
@end
