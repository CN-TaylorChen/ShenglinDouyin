//
//  SLProfile.m
//  声临 · 抖音版 —— 本机主页伪装
//
//  静态分析（抖音 39.9.0 脱壳包）确认的链路：
//    AWEProfileTabContainerViewController  -isCurrentUser / -setIsCurrentUser:
//    AWEUserModel  -nickname / -signature / -uniqueIDForShow
//                  -awemeCount / -followingCount / -followerCount / -followerCountStr
//  这些 getter 返回的都是 id（数字也是 NSNumber），所以钩子统一按对象转发。
//  只在「我」页可见期间生效，页面消失立刻还原，评论 / 私信 / 列表都不受影响。
//

#import "SLProfile.h"
#import "SLLog.h"
#import "SLGlass.h"

#import <objc/runtime.h>
#import <objc/message.h>

#define SLProfKeyEnabled   @"SLProf.enabled"
#define SLProfKeyNickname  @"SLProf.nickname"
#define SLProfKeyUID       @"SLProf.uid"
#define SLProfKeySignature @"SLProf.signature"
#define SLProfKeyAweme     @"SLProf.aweme"
#define SLProfKeyFollowing @"SLProf.following"
#define SLProfKeyFollower  @"SLProf.follower"
#define SLProfKeyLike      @"SLProf.like"       // 获赞
#define SLProfKeyFriend    @"SLProf.friend"     // 互关

static volatile BOOL sSLProfOnMePage = NO;   // 「我」页可见期间为 YES
static BOOL sSLProfStarted  = NO;
static int  sSLProfHits     = 0;
static int  sSLProfMissLogged = 0;  // 门未开的诊断日志，最多打几条

#pragma mark - 配置

static NSString *SLProfStr(NSString *key) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return v.length ? v : nil;
}

static void SLProfSetStr(NSString *value, NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (value.length) [d setObject:value forKey:key];
    else [d removeObjectForKey:key];
}

BOOL SLProfileEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:SLProfKeyEnabled];
    return v ? [v boolValue] : NO;
}

NSInteger SLProfileFilledCount(void) {
    NSArray *keys = @[SLProfKeyNickname, SLProfKeyUID, SLProfKeySignature,
                      SLProfKeyAweme, SLProfKeyFollowing, SLProfKeyFollower,
                      SLProfKeyLike, SLProfKeyFriend];
    NSInteger n = 0;
    for (NSString *k in keys) if (SLProfStr(k)) n++;
    return n;
}

void SLProfileClearAll(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (NSString *k in @[SLProfKeyNickname, SLProfKeyUID, SLProfKeySignature,
                          SLProfKeyAweme, SLProfKeyFollowing, SLProfKeyFollower,
                          SLProfKeyLike, SLProfKeyFriend]) {
        [d removeObjectForKey:k];
    }
    SLLog(@"PROF| 已清空全部预设值");
}

// 抖音自己会把数字排成「1.2万」，这里只在它的 Str 字段上补一份同样的格式
static NSString *SLProfFormatCount(long long n) {
    if (n >= 100000000) return [NSString stringWithFormat:@"%.1f亿", n / 100000000.0];
    if (n >= 10000)     return [NSString stringWithFormat:@"%.1f万", n / 10000.0];
    return [NSString stringWithFormat:@"%lld", n];
}

static BOOL SLProfNumber(NSString *key, long long *out) {
    NSString *s = SLProfStr(key);
    if (!s.length) return NO;
    // 允许输入「12.5万」这种，按万换算，避免用户还得自己数零
    if ([s hasSuffix:@"万"] || [s hasSuffix:@"w"] || [s hasSuffix:@"W"]) {
        double v = [[s substringToIndex:s.length - 1] doubleValue];
        *out = (long long)(v * 10000);
        return YES;
    }
    if ([s hasSuffix:@"亿"]) {
        double v = [[s substringToIndex:s.length - 1] doubleValue];
        *out = (long long)(v * 100000000);
        return YES;
    }
    NSString *digits = [[s componentsSeparatedByCharactersInSet:
        [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (!digits.length) return NO;
    *out = [digits longLongValue];
    return YES;
}

#pragma mark - 钩子基座

// 只取本类 method list：class_getInstanceMethod 会顺父类找，
// method_setImplementation 改的是父类那份，会扩散到一堆子类。
static Method SLProfExact(Class cls, SEL sel) {
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

// 返回对象、无参数
static void SLProfHookGetter(Class cls, SEL sel, IMP imp, IMP *slot, NSString *tag) {
    if (!cls) { SLLog(@"PROF| 跳过 %@：类不存在", tag); return; }
    Method m = SLProfExact(cls, sel);
    if (!m) { SLLog(@"PROF| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    char *ret = method_copyReturnType(m);
    BOOL isObj = (ret && ret[0] == '@');
    if (ret) free(ret);
    if (!isObj) { SLLog(@"PROF| 跳过 %@：返回值不是对象", tag); return; }
    if (method_getNumberOfArguments(m) != 2) {
        SLLog(@"PROF| 跳过 %@：参数个数不是 0", tag);
        return;
    }
    *slot = method_getImplementation(m);
    method_setImplementation(m, imp);
    SLLog(@"PROF| 已挂 %@ @ %@", tag, NSStringFromClass(cls));
}

// 返回 BOOL、无参数
static void SLProfHookBoolGetter(Class cls, SEL sel, IMP imp, IMP *slot, NSString *tag) {
    if (!cls) { SLLog(@"PROF| 跳过 %@：类不存在", tag); return; }
    Method m = SLProfExact(cls, sel);
    if (!m) { SLLog(@"PROF| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    char *ret = method_copyReturnType(m);
    BOOL isBool = (ret && (ret[0] == 'B' || ret[0] == 'c'));
    if (ret) free(ret);
    if (!isBool) { SLLog(@"PROF| 跳过 %@：返回值不是 BOOL", tag); return; }
    if (method_getNumberOfArguments(m) != 2) {
        SLLog(@"PROF| 跳过 %@：参数个数不是 0", tag);
        return;
    }
    *slot = method_getImplementation(m);
    method_setImplementation(m, imp);
    SLLog(@"PROF| 已挂 %@ @ %@", tag, NSStringFromClass(cls));
}

#pragma mark - 页面判定
//
// 39.9.0 真机日志证实两件事：
//   1) -setIsCurrentUser: / -isCurrentUserProfilePage 在进「我」页时都没被调用，
//      挂它们的 setter/getter 等不到，不代表方法不存在；
//   2) 「我」页和别人的主页共用同一个 AWEUserHomeViewControllerV2，
//      单看类名区分不了（v0.8.2 把 UserHome 一律判成他人主页，正好把「我」页排除了）。
// 所以改成：找到当前页面，主动调它自己的 isCurrentUserProfilePage / isCurrentUser 来问。

// 从 keyWindow 一路下沉：presented > nav.top > tab.selected
// 走 UIWindowScene（部署目标 15.0），避免 -windows / -keyWindow 的弃用警告
static UIViewController *SLProfTopVC(void) {
    UIWindow *win = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        BOOL active = (s.activationState == UISceneActivationStateForegroundActive);
        UIWindow *cand = nil;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { cand = w; break; }
        }
        if (!cand) {
            for (UIWindow *w in ws.windows) {
                if (!w.isHidden) { cand = w; break; }
            }
        }
        if (cand) {
            win = cand;
            if (active) break;          // 前台那个优先，别被后台窗口盖掉
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!win) {                          // 极早期 scene 还没 active 时的兜底
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (!w.isHidden) { win = w; break; }
            }
        }
    }
#pragma clang diagnostic pop
    if (!win) return nil;

    UIViewController *vc = win.rootViewController;
    for (int i = 0; i < 16 && vc; i++) {
        UIViewController *next = nil;
        if (vc.presentedViewController) next = vc.presentedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]])
            next = [(UINavigationController *)vc topViewController];
        else if ([vc isKindOfClass:[UITabBarController class]])
            next = [(UITabBarController *)vc selectedViewController];
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

// 顺着 parent 链往上找，直接问页面自己「你是不是本人主页」：
//   AWEUserHomeViewControllerV2  -isCurrentUserProfilePage   （我页与别人主页共用这个 VC）
//   AWEProfileTabContainerViewController / Merged  -isCurrentUser
// 这两个方法在 39.9.0 都存在（已从脱壳包方法表确认），主动调比猜类名可靠得多。
// 用 IMP 调用而不是 objc_msgSend：ARC 下把 objc_msgSend 转成自定义签名会被编译器拦。
// class_getInstanceMethod 会沿父类找，这里只是读取，不会改到父类实现。
static BOOL SLProfCallBool(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || !sel || ![obj respondsToSelector:sel]) return NO;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) return NO;
    return ((BOOL (*)(id, SEL))method_getImplementation(m))(obj, sel);
}

static id SLProfCallObj(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) return nil;
    return ((id (*)(id, SEL))method_getImplementation(m))(obj, sel);
}

static int SLProfPageKindSlow(void) {
    UIViewController *vc = SLProfTopVC();
    if (!vc) return 0;

    Class home   = objc_getClass("AWEUserHomeViewControllerV2");
    Class tab    = objc_getClass("AWEProfileTabContainerViewController");
    Class merged = objc_getClass("AWEProfileMergedTabContainerViewController");

    UIViewController *p = vc;
    for (int i = 0; i < 10 && p; i++) {
        if (home && [p isKindOfClass:home]) {
            if ([p respondsToSelector:NSSelectorFromString(@"isCurrentUserProfilePage")]) {
                if (SLProfCallBool(p, @"isCurrentUserProfilePage")) return 1;
                // 首次渲染时这个标志可能还没算好；「我」页独有设置入口，有它就是本人页
                if (SLProfCallObj(p, @"profileSettingComponent") != nil) return 1;
                return -1;
            }
        }
        if ((tab && [p isKindOfClass:tab]) || (merged && [p isKindOfClass:merged])) {
            if ([p respondsToSelector:NSSelectorFromString(@"isCurrentUser")]) {
                return SLProfCallBool(p, @"isCurrentUser") ? 1 : -1;
            }
        }
        p = p.parentViewController;
    }
    return 0;
}

static int            sSLProfKindVal   = 0;
static NSTimeInterval sSLProfGateUntil = 0;

// 页面一变就记一行（只在变化时打，不刷屏），用来确认「我」页到底走到哪一步
static void SLProfNotePageChange(int kind) {
    static int  lastKind = -99;
    static char lastName[160] = {0};
    UIViewController *vc = SLProfTopVC();
    const char *cur = vc ? class_getName([vc class]) : "nil";
    if (kind == lastKind && strcmp(lastName, cur) == 0) return;
    lastKind = kind;
    strncpy(lastName, cur, sizeof(lastName) - 1);
    lastName[sizeof(lastName) - 1] = '\0';
    SLLog(@"PROF| 页面 → %s（kind=%d）", cur, kind);
}

// 0.15s 缓存：getter 一屏几十次调用，不能每次都爬一遍视图树
static int SLProfPageKind(void) {
    if (![NSThread isMainThread]) return 0;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now < sSLProfGateUntil) return sSLProfKindVal;
    sSLProfKindVal = SLProfPageKindSlow();
    sSLProfGateUntil = now + 0.15;
    SLProfNotePageChange(sSLProfKindVal);
    return sSLProfKindVal;
}

static BOOL SLProfGate(void) {
    if (!SLProfileEnabled()) return NO;
    if (![NSThread isMainThread]) return sSLProfOnMePage;
    int kind = SLProfPageKind();
    if (kind < 0) {                       // 明确站在别人主页上，强制退出，防止串页
        sSLProfOnMePage = NO;
        return NO;
    }
    if (kind > 0) return YES;
    return sSLProfOnMePage;               // 页面认不出来时，退回容器 appear 的记录
}

// 门没开时记一笔，用来确认 getter 到底有没有在渲染时被调用（限 12 条）
static void SLProfNoteMiss(NSString *tag) {
    if (sSLProfMissLogged >= 12) return;
    sSLProfMissLogged++;
    SLLog(@"PROF| %@ 被调（门未开）", tag);
}

#pragma mark - 字符串字段

#define SL_PROF_STR_HOOK(NAME, KEY, TAG)                                  \
    static id (*o_##NAME)(id, SEL);                                       \
    static id h_##NAME(id self, SEL _cmd) {                               \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                     \
        if (!SLProfGate()) { SLProfNoteMiss(TAG); return v; }             \
        NSString *f = SLProfStr(KEY);                                     \
        if (!f.length) return v;                                          \
        if (sSLProfHits < 12) { sSLProfHits++;                            \
            SLLog(@"PROF| 替换 %@ → %@", TAG, f); }                        \
        return f;                                                         \
    }

SL_PROF_STR_HOOK(nickname, SLProfKeyNickname, @"nickname")
SL_PROF_STR_HOOK(signature, SLProfKeySignature, @"signature")
SL_PROF_STR_HOOK(uniqueID, SLProfKeyUID, @"uniqueIDForShow")

#pragma mark - 数字字段

#define SL_PROF_NUM_HOOK(NAME, KEY, TAG)                                  \
    static id (*o_##NAME)(id, SEL);                                       \
    static id h_##NAME(id self, SEL _cmd) {                               \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                     \
        if (!SLProfGate()) { SLProfNoteMiss(TAG); return v; }             \
        long long n = 0;                                                  \
        if (!SLProfNumber(KEY, &n)) return v;                             \
        if (sSLProfHits < 12) { sSLProfHits++;                            \
            SLLog(@"PROF| 替换 %@ → %lld", TAG, n); }                      \
        return @(n);                                                      \
    }

SL_PROF_NUM_HOOK(awemeCount, SLProfKeyAweme, @"awemeCount")
SL_PROF_NUM_HOOK(followingCount, SLProfKeyFollowing, @"followingCount")
SL_PROF_NUM_HOOK(followerCount, SLProfKeyFollower, @"followerCount")
SL_PROF_NUM_HOOK(favoritingCount, SLProfKeyLike, @"favoritingCount")
SL_PROF_NUM_HOOK(friendCount, SLProfKeyFriend, @"friendCount")

// 粉丝数字还有一份字符串版本，喂给不自己格式化的 cell
static id (*o_followerCountStr)(id, SEL);
static id h_followerCountStr(id self, SEL _cmd) {
    id v = o_followerCountStr ? o_followerCountStr(self, _cmd) : nil;
    if (!SLProfGate()) return v;
    long long n = 0;
    if (!SLProfNumber(SLProfKeyFollower, &n)) return v;
    return SLProfFormatCount(n);
}

// 获赞的字符串版本（totalFavoriteStr），同理
static id (*o_totalFavoriteStr)(id, SEL);
static id h_totalFavoriteStr(id self, SEL _cmd) {
    id v = o_totalFavoriteStr ? o_totalFavoriteStr(self, _cmd) : nil;
    if (!SLProfGate()) return v;
    long long n = 0;
    if (!SLProfNumber(SLProfKeyLike, &n)) return v;
    return SLProfFormatCount(n);
}

#pragma mark - 抖音号（header 组件层）
//
// 真机日志里 uniqueIDForShow 明明被替换了，页面上「抖音号」还是原值 ——
// 说明这行字不是现读 model，而是 header 的 id 组件自己拼的：
//   AWEProfileHeaderIdContentComponent_NEWAPI  -idPrefixStr（"抖音号："）+ -idStr
// -idStr 是计算属性（该类没有 setIdStr:），所以直接截它最稳。

static id (*o_headerIDStr)(id, SEL);
static id h_headerIDStr(id self, SEL _cmd) {
    id v = o_headerIDStr ? o_headerIDStr(self, _cmd) : nil;
    NSString *f = SLProfStr(SLProfKeyUID);
    if (!f.length || !SLProfGate()) return v;
    return f;
}

// 账号没设抖音号时 APP 会显示短 ID，这个开关打开才会走「抖音号：」那一行
static BOOL (*o_shouldShowUniqueID)(id, SEL);
static BOOL h_shouldShowUniqueID(id self, SEL _cmd) {
    BOOL v = o_shouldShowUniqueID ? o_shouldShowUniqueID(self, _cmd) : NO;
    if (SLProfGate() && SLProfStr(SLProfKeyUID).length) return YES;
    return v;
}

#pragma mark - 容器进退（第二道门）
//
// 主判据是上面那个按可见页面判断的实时逻辑。这里再把「我」页容器的
// appear / disappear 挂上：万一以后版本类名不再是 Profile 开头，这条还能兜住，
// 而且日志里能直接看到容器有没有真的出现。

typedef struct { Class cls; SEL sel; IMP orig; } SLProfSlot;
static SLProfSlot sSLProfSlots[8];
static int sSLProfSlotCount = 0;

static IMP SLProfFindOrig(id self, SEL sel) {
    Class c = object_getClass(self);
    for (int i = 0; i < sSLProfSlotCount; i++)
        if (sSLProfSlots[i].sel == sel && sSLProfSlots[i].cls == c) return sSLProfSlots[i].orig;
    for (int i = 0; i < sSLProfSlotCount; i++)
        if (sSLProfSlots[i].sel == sel) return sSLProfSlots[i].orig;
    return NULL;
}

static void h_profEnterPage(id self, SEL _cmd, BOOL animated) {
    if (!sSLProfOnMePage) SLLog(@"PROF| 进入本人主页（%@）", NSStringFromClass([self class]));
    sSLProfOnMePage = YES;
    sSLProfGateUntil = 0;
    IMP o = SLProfFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
}

static void h_profLeavePage(id self, SEL _cmd, BOOL animated) {
    if (sSLProfOnMePage) SLLog(@"PROF| 离开本人主页，恢复原样");
    sSLProfOnMePage = NO;
    sSLProfGateUntil = 0;
    IMP o = SLProfFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
}

static void SLProfHookPageLifecycle(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    Method a = SLProfExact(cls, @selector(viewDidAppear:));
    if (a) {
        if (sSLProfSlotCount < 8)
            sSLProfSlots[sSLProfSlotCount++] = (SLProfSlot){ cls, @selector(viewDidAppear:), method_getImplementation(a) };
        method_setImplementation(a, (IMP)h_profEnterPage);
        SLLog(@"PROF| 已挂 viewDidAppear: @ %@", name);
    }
    Method d = SLProfExact(cls, @selector(viewWillDisappear:));
    if (d) {
        if (sSLProfSlotCount < 8)
            sSLProfSlots[sSLProfSlotCount++] = (SLProfSlot){ cls, @selector(viewWillDisappear:), method_getImplementation(d) };
        method_setImplementation(d, (IMP)h_profLeavePage);
        SLLog(@"PROF| 已挂 viewWillDisappear: @ %@", name);
    }
}

#pragma mark - 装配

void SLProfileStart(void) {
    if (sSLProfStarted) return;
    sSLProfStarted = YES;

    Class user = objc_getClass("AWEUserModel");
    SLProfHookGetter(user, @selector(nickname), (IMP)h_nickname, (IMP *)&o_nickname, @"nickname");
    SLProfHookGetter(user, @selector(signature), (IMP)h_signature, (IMP *)&o_signature, @"signature");
    SLProfHookGetter(user, NSSelectorFromString(@"uniqueIDForShow"),
                     (IMP)h_uniqueID, (IMP *)&o_uniqueID, @"uniqueIDForShow");
    SLProfHookGetter(user, NSSelectorFromString(@"awemeCount"),
                     (IMP)h_awemeCount, (IMP *)&o_awemeCount, @"awemeCount");
    SLProfHookGetter(user, NSSelectorFromString(@"followingCount"),
                     (IMP)h_followingCount, (IMP *)&o_followingCount, @"followingCount");
    SLProfHookGetter(user, NSSelectorFromString(@"followerCount"),
                     (IMP)h_followerCount, (IMP *)&o_followerCount, @"followerCount");
    SLProfHookGetter(user, NSSelectorFromString(@"followerCountStr"),
                     (IMP)h_followerCountStr, (IMP *)&o_followerCountStr, @"followerCountStr");
    SLProfHookGetter(user, NSSelectorFromString(@"favoritingCount"),
                     (IMP)h_favoritingCount, (IMP *)&o_favoritingCount, @"favoritingCount");
    SLProfHookGetter(user, NSSelectorFromString(@"friendCount"),
                     (IMP)h_friendCount, (IMP *)&o_friendCount, @"friendCount");
    SLProfHookGetter(user, NSSelectorFromString(@"totalFavoriteStr"),
                     (IMP)h_totalFavoriteStr, (IMP *)&o_totalFavoriteStr, @"totalFavoriteStr");
    SLProfHookBoolGetter(user, NSSelectorFromString(@"shouldShowUniqueID"),
                         (IMP)h_shouldShowUniqueID, (IMP *)&o_shouldShowUniqueID, @"shouldShowUniqueID");

    // header 里那行「抖音号：xxx」由 id 组件自己拼，不读 model 的 getter
    Class idComp = objc_getClass("AWEProfileHeaderIdContentComponent_NEWAPI");
    SLProfHookGetter(idComp, @selector(idStr), (IMP)h_headerIDStr, (IMP *)&o_headerIDStr, @"header.idStr");

    // 「我」页容器：挂 appear / disappear 当第二道门，并留下现场日志
    SLProfHookPageLifecycle(objc_getClass("AWEProfileTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileMergedTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileBaseContainerViewController"));

    SLLog(@"PROF| ==== 主页伪装 v0.8.4 · 开=%d · 已填 %ld 项 ====",
          SLProfileEnabled(), (long)SLProfileFilledCount());

    UIViewController *top = SLProfTopVC();
    SLLog(@"PROF| 启动时顶层页面 = %@", top ? NSStringFromClass([top class]) : @"nil");
}

#pragma mark - 编辑器

@implementation SLProfileEditorController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"主页伪装";
    self.navigationItem.titleView = SLPillTitleView(@"主页伪装");
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"完成", self, @selector(sl_close));
    SLApplyGlassTable(self.tableView);
    SLInstallPillBack(self);
}

- (void)sl_close {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return 1;
    if (s == 1) return 4;
    return 5;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return nil;
    if (s == 1) return @"资料";
    return @"数字";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slprofcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    cell.backgroundColor = SLGlassCellColor();
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.textAlignment = NSTextAlignmentRight;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (ip.section == 0) {
        cell.textLabel.text = @"启用";
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.on = SLProfileEnabled();
        [sw addTarget:self action:@selector(sl_toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (ip.section == 1) {
        NSArray *titles = @[@"昵称", @"抖音号", @"简介", @"头像"];
        NSArray *keys = @[SLProfKeyNickname, SLProfKeyUID, SLProfKeySignature, @""];
        cell.textLabel.text = titles[ip.row];
        if (ip.row == 3) {
            cell.detailTextLabel.text = @"后续";
            cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
            cell.textLabel.textColor = [UIColor tertiaryLabelColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSString *v = SLProfStr(keys[ip.row]);
        cell.detailTextLabel.text = v.length ? v : @"未设置";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    NSArray *titles = @[@"作品", @"关注", @"粉丝", @"获赞", @"互关"];
    NSString *key = @[SLProfKeyAweme, SLProfKeyFollowing, SLProfKeyFollower,
                      SLProfKeyLike, SLProfKeyFriend][ip.row];
    cell.textLabel.text = titles[ip.row];
    NSString *v = SLProfStr(key);
    cell.detailTextLabel.text = v.length ? v : @"未设置";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)sl_toggle:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:SLProfKeyEnabled];
    SLLog(@"PROF| 总开关 = %d", sw.on);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) return;
    if (ip.section == 1 && ip.row == 3) return;

    NSString *title = nil, *key = nil;
    UIKeyboardType kb = UIKeyboardTypeDefault;

    if (ip.section == 1) {
        if (ip.row == 0) { title = @"昵称"; key = SLProfKeyNickname; }
        else if (ip.row == 1) { title = @"抖音号"; key = SLProfKeyUID; }
        else { title = @"简介"; key = SLProfKeySignature; }
    } else {
        if (ip.row == 0) { title = @"作品数"; key = SLProfKeyAweme; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 1) { title = @"关注数"; key = SLProfKeyFollowing; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 2) { title = @"粉丝数"; key = SLProfKeyFollower; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 3) { title = @"获赞数"; key = SLProfKeyLike; kb = UIKeyboardTypeNumberPad; }
        else { title = @"互关数"; key = SLProfKeyFriend; kb = UIKeyboardTypeNumberPad; }
    }
    if (!key) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = SLProfStr(key);
        tf.keyboardType = kb;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = ac.textFields.firstObject.text;
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length > 120) text = [text substringToIndex:120];
        SLProfSetStr(text, key);
        [self.tableView reloadData];
        SLLog(@"PROF| 设置 %@ = %@", title, text.length ? text : @"(空)");
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// 长按「启用」清空全部预设
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    if (ip.section != 0) return nil;
    UIContextualAction *a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                   title:@"清空"
                                                                 handler:^(UIContextualAction *act,
                                                                           UIView *v,
                                                                           void (^done)(BOOL)) {
        SLProfileClearAll();
        [self.tableView reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[a]];
}

@end
