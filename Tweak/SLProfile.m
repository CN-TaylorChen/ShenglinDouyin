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

static id SLProfCallObj(id obj, NSString *selName);   // 定义在「页面判定」段，快照要用

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

#pragma mark - 他人主页快照（A 方案）
//
// 走不了「解析链接去联网抓」这条路（那需要 X-Gorgon 签名 / 自建服务端），
// 但完全可以换个方向：你点开谁的主页，谁的资料就已经完整躺在内存里了。
// 所以在别人主页（kind == -1）期间，顺手把 AWEUserModel 的那几个字段抄下来，
// 落盘成「快照」，设置页里点一下就能整套套用到自己头上。
// 零网络、零签名，成功率 100%，代价只是要先点开对方主页一次。

#define SLProfKeySnaps @"SLProf.snaps"

static BOOL sSLCapOn  = NO;
static NSMutableDictionary *sSLCapCur   = nil;   // 正在看的这个人的字段
static NSMutableDictionary *sSLCapStore = nil;   // uid -> dict，持久化

static NSMutableDictionary *SLCapStore(void) {
    if (sSLCapStore) return sSLCapStore;
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:SLProfKeySnaps];
    sSLCapStore = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    return sSLCapStore;
}

static void SLCapPersist(void) {
    [[NSUserDefaults standardUserDefaults] setObject:SLCapStore() forKey:SLProfKeySnaps];
}

static void SLCapBegin(void) {
    sSLCapOn = YES;
    sSLCapCur = nil;
}

// 把手上这份落盘（不改变 sSLCapOn）
static void SLCapFlush(void) {
    NSMutableDictionary *cap = sSLCapCur;
    sSLCapCur = nil;
    if (!cap) return;

    NSString *key = cap[@"uid"];
    if (!key.length) key = cap[@"sec"];
    if (!key.length) return;

    id nickObj = cap[@"nickname"];
    NSString *nickStr = [nickObj isKindOfClass:[NSString class]] ? nickObj : nil;
    if (!nickStr.length && cap.count < 3) return;   // 啥都没抓到，不留垃圾

    cap[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    NSMutableDictionary *store = SLCapStore();
    store[key] = cap;

    // 最多留 30 个，超了按时间丢最旧的
    if (store.count > 30) {
        NSArray *sorted = [store.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            double ta = [store[a][@"ts"] doubleValue];
            double tb = [store[b][@"ts"] doubleValue];
            return ta < tb ? NSOrderedAscending : (ta > tb ? NSOrderedDescending : NSOrderedSame);
        }];
        for (NSUInteger i = 0; i + 30 < sorted.count; i++) [store removeObjectForKey:sorted[i]];
    }
    SLCapPersist();
    SLLog(@"SNAP| 已抓取 %@（%@）", nickStr.length ? nickStr : @"?", key);
}

static void SLCapFinish(void) {
    sSLCapOn = NO;
    SLCapFlush();
}

// 只在别人主页那几秒记账；同一个人只记第一次读到的值（原始值，不受伪装影响）
// 连续滑到另一个人时（kind 一直是 -1）会先把手上的存掉再开新的
static void SLCapNote(id model, NSString *field, id value) {
    if (!sSLCapOn || !field || !value) return;
    if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) return;

    NSString *uid = SLProfCallObj(model, @"userID");
    NSString *sec = SLProfCallObj(model, @"secUserID");
    if (!uid.length && !sec.length) return;
    NSString *newKey = uid.length ? uid : sec;

    if (sSLCapCur) {
        NSString *curKey = sSLCapCur[@"uid"] ?: sSLCapCur[@"sec"];
        if (curKey && ![curKey isEqualToString:newKey]) SLCapFlush();
    }
    if (!sSLCapCur) {
        sSLCapCur = [NSMutableDictionary dictionary];
        if (uid.length) sSLCapCur[@"uid"] = uid;
        if (sec.length) sSLCapCur[@"sec"] = sec;
    }
    if (!sSLCapCur[field]) sSLCapCur[field] = value;
}

// 快照按时间倒序，给设置页用
static NSArray<NSDictionary *> *SLSnapList(void) {
    NSMutableDictionary *store = SLCapStore();
    return [store.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"ts"] doubleValue], tb = [b[@"ts"] doubleValue];
        return ta > tb ? NSOrderedAscending : (ta < tb ? NSOrderedDescending : NSOrderedSame);
    }];
}

static NSString *SLSnapText(NSDictionary *s, NSString *k) {
    id v = s[k];
    if (![v isKindOfClass:[NSString class]] && ![v isKindOfClass:[NSNumber class]]) return nil;
    NSString *str = [v description];
    return str.length ? str : nil;
}

// 把一份快照整套写进预设
static void SLApplySnap(NSDictionary *s) {
    SLProfSetStr(SLSnapText(s, @"nickname"),  SLProfKeyNickname);
    SLProfSetStr(SLSnapText(s, @"uniqueID"),  SLProfKeyUID);
    SLProfSetStr(SLSnapText(s, @"signature"), SLProfKeySignature);
    SLProfSetStr(SLSnapText(s, @"aweme"),     SLProfKeyAweme);
    SLProfSetStr(SLSnapText(s, @"following"), SLProfKeyFollowing);
    SLProfSetStr(SLSnapText(s, @"follower"),  SLProfKeyFollower);
    SLProfSetStr(SLSnapText(s, @"like"),      SLProfKeyLike);
    SLProfSetStr(SLSnapText(s, @"friend"),    SLProfKeyFriend);
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SLProfKeyEnabled];
    SLLog(@"SNAP| 套用 %@ 的整套资料", SLSnapText(s, @"nickname") ?: @"?");
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

// 返回对象、一个对象参数
static void SLProfHookOneObj(Class cls, SEL sel, IMP imp, IMP *slot, NSString *tag) {
    if (!cls) { SLLog(@"PROF| 跳过 %@：类不存在", tag); return; }
    Method m = SLProfExact(cls, sel);
    if (!m) { SLLog(@"PROF| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    char *ret = method_copyReturnType(m);
    BOOL isObj = (ret && ret[0] == '@');
    if (ret) free(ret);
    if (!isObj) { SLLog(@"PROF| 跳过 %@：返回值不是对象", tag); return; }
    if (method_getNumberOfArguments(m) != 3) {
        SLLog(@"PROF| 跳过 %@：参数个数不是 1", tag);
        return;
    }
    char at[8] = {0};
    method_getArgumentType(m, 2, at, sizeof(at));
    if (at[0] != '@') { SLLog(@"PROF| 跳过 %@：参数不是对象", tag); return; }
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

// 沿 parent 链判断这一摞 VC 属于哪种页面
static int SLProfKindFromVC(UIViewController *vc) {
    Class home   = objc_getClass("AWEUserHomeViewControllerV2");
    Class tab    = objc_getClass("AWEProfileTabContainerViewController");
    Class merged = objc_getClass("AWEProfileMergedTabContainerViewController");
    Class detail = objc_getClass("AWEUserDetailViewControllerV2");   // 他人资料详情页

    UIViewController *p = vc;
    for (int i = 0; i < 10 && p; i++) {
        if (detail && [p isKindOfClass:detail]) return -1;
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

static int SLProfPageKindSlow(void) {
    UIViewController *vc = SLProfTopVC();
    if (!vc) return 0;

    int kind = SLProfKindFromVC(vc);
    if (kind != 0) return kind;

    // 被模态（分享面板 / 我们自己的浮窗）盖住时，看它下面那一层是什么页
    UIViewController *presenter = vc.presentingViewController;
    if (presenter) return SLProfKindFromVC(presenter);
    return 0;
}

static int            sSLProfKindVal   = 0;
static BOOL           sSLProfTopIsOurs = NO;   // 顶层是不是我们自己的面板/日志页
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
    if (![NSThread isMainThread]) return sSLProfKindVal;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now < sSLProfGateUntil) return sSLProfKindVal;

    int prev = sSLProfKindVal;
    UIViewController *top = SLProfTopVC();
    sSLProfTopIsOurs = top ? [NSStringFromClass([top class]) hasPrefix:@"SL"] : NO;
    sSLProfKindVal = SLProfPageKindSlow();
    sSLProfGateUntil = now + 0.15;

    if (sSLProfKindVal != prev) {
        if (sSLProfKindVal == -1) SLCapBegin();        // 进别人主页，开始记账
        else if (prev == -1) SLCapFinish();            // 离开，落盘
    }
    SLProfNotePageChange(sSLProfKindVal);
    return sSLProfKindVal;
}

// 只在「确认是本人主页」时开门。
// v0.8.4 之前 kind 认不出来时会沿用上一次的状态，结果在信息流/消息页也继续替换，
// 变成「所有人的名字都一样」——这里改成严格模式：认不出来就是关。
// 唯一例外：自己弹出的面板（类名 SL 开头）盖在「我」页上时，沿用上一次的状态，
// 否则面板一开、背后的主页就闪回真实资料。
static BOOL SLProfGate(void) {
    if (!SLProfileEnabled()) return NO;
    if (![NSThread isMainThread]) return (sSLProfKindVal == 1);
    int kind = SLProfPageKind();
    if (kind == 1) {
        sSLProfOnMePage = YES;
        return YES;
    }
    if (kind == 0 && sSLProfOnMePage && sSLProfTopIsOurs) return YES;
    sSLProfOnMePage = NO;
    return NO;
}

// 门没开时记一笔，用来确认 getter 到底有没有在渲染时被调用（限 12 条）
static void SLProfNoteMiss(NSString *tag) {
    if (sSLProfMissLogged >= 12) return;
    sSLProfMissLogged++;
    SLLog(@"PROF| %@ 被调（门未开）", tag);
}

#pragma mark - 字符串字段

#define SL_PROF_STR_HOOK(NAME, KEY, TAG, FIELD)                           \
    static id (*o_##NAME)(id, SEL);                                       \
    static id h_##NAME(id self, SEL _cmd) {                               \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                     \
        if (!SLProfGate()) { SLCapNote(self, FIELD, v);                   \
                             SLProfNoteMiss(TAG); return v; }             \
        NSString *f = SLProfStr(KEY);                                     \
        if (!f.length) return v;                                          \
        if (sSLProfHits < 12) { sSLProfHits++;                            \
            SLLog(@"PROF| 替换 %@ → %@", TAG, f); }                        \
        return f;                                                         \
    }

SL_PROF_STR_HOOK(nickname, SLProfKeyNickname, @"nickname", @"nickname")
SL_PROF_STR_HOOK(signature, SLProfKeySignature, @"signature", @"signature")
SL_PROF_STR_HOOK(uniqueID, SLProfKeyUID, @"uniqueIDForShow", @"uniqueID")

#pragma mark - 数字字段

#define SL_PROF_NUM_HOOK(NAME, KEY, TAG, FIELD)                           \
    static id (*o_##NAME)(id, SEL);                                       \
    static id h_##NAME(id self, SEL _cmd) {                               \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                     \
        if (!SLProfGate()) { SLCapNote(self, FIELD, v);                   \
                             SLProfNoteMiss(TAG); return v; }             \
        long long n = 0;                                                  \
        if (!SLProfNumber(KEY, &n)) return v;                             \
        if (sSLProfHits < 12) { sSLProfHits++;                            \
            SLLog(@"PROF| 替换 %@ → %lld", TAG, n); }                      \
        return @(n);                                                      \
    }

SL_PROF_NUM_HOOK(awemeCount, SLProfKeyAweme, @"awemeCount", @"aweme")
SL_PROF_NUM_HOOK(followingCount, SLProfKeyFollowing, @"followingCount", @"following")
SL_PROF_NUM_HOOK(followerCount, SLProfKeyFollower, @"followerCount", @"follower")
SL_PROF_NUM_HOOK(favoritingCount, SLProfKeyLike, @"favoritingCount", @"like")
SL_PROF_NUM_HOOK(friendCount, SLProfKeyFriend, @"friendCount", @"friend")

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

#pragma mark - 统计数字（组件层）
//
// 获赞 / 互关 不走 AWEUserModel 的 getter，是各自组件算好文本再交给 cell 的：
//   AWEProfileSocialStatisticPraiseComponent  -displayCountForItem:  （获赞）
//   AWEProfileSocialStatisticMutualComponent  -displayCountForItem:  （互关）
//   AWEProfileSocialStatisticFriendComponent  -displayCountForItem:  （朋友）
// 直接在返回值上换成我们自己的数字，显示什么就是什么。

#define SL_PROF_COUNT_HOOK(NAME, KEY, TAG)                                 \
    static id (*o_##NAME)(id, SEL, id);                                    \
    static id h_##NAME(id self, SEL _cmd, id item) {                       \
        id v = o_##NAME ? o_##NAME(self, _cmd, item) : nil;                \
        if (!SLProfGate()) return v;                                       \
        if (v && ![v isKindOfClass:[NSString class]]) return v;            \
        long long n = 0;                                                   \
        if (!SLProfNumber(KEY, &n)) return v;                              \
        return SLProfFormatCount(n);                                       \
    }

SL_PROF_COUNT_HOOK(praiseText, SLProfKeyLike, @"praise")
SL_PROF_COUNT_HOOK(mutualText, SLProfKeyFriend, @"mutual")
SL_PROF_COUNT_HOOK(friendText, SLProfKeyFriend, @"friend")

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

    // 获赞 / 互关 / 朋友：数字由各自的统计组件算成文本，截这里才改得动
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticPraiseComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_praiseText, (IMP *)&o_praiseText, @"praise.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticMutualComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_mutualText, (IMP *)&o_mutualText, @"mutual.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticFriendComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_friendText, (IMP *)&o_friendText, @"friend.displayCount");

    // 「我」页容器：挂 appear / disappear 当第二道门，并留下现场日志
    SLProfHookPageLifecycle(objc_getClass("AWEProfileTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileMergedTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileBaseContainerViewController"));

    SLLog(@"PROF| ==== 主页伪装 v0.8.5 · 开=%d · 已填 %ld 项 · 快照 %lu 个 ====",
          SLProfileEnabled(), (long)SLProfileFilledCount(), (unsigned long)SLSnapList().count);

    UIViewController *top = SLProfTopVC();
    SLLog(@"PROF| 启动时顶层页面 = %@", top ? NSStringFromClass([top class]) : @"nil");
}

#pragma mark - 编辑器

@interface SLSnapListController : UITableViewController
@end

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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 4; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return 1;
    if (s == 1) return 4;
    if (s == 2) return 5;
    return 1;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return nil;
    if (s == 1) return @"资料";
    if (s == 2) return @"数字";
    return @"快捷";
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

    if (ip.section == 3) {
        cell.textLabel.text = @"从他人主页套用";
        NSArray *snaps = SLSnapList();
        cell.detailTextLabel.text = snaps.count
            ? [NSString stringWithFormat:@"%lu 人", (unsigned long)snaps.count]
            : @"先去点开对方主页";
        cell.detailTextLabel.textColor = snaps.count ? [UIColor secondaryLabelColor]
                                                     : [UIColor tertiaryLabelColor];
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

    if (ip.section == 3) {
        SLSnapListController *vc = [[SLSnapListController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }

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

#pragma mark - 快照列表

@implementation SLSnapListController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"套用他人主页";
    self.navigationItem.titleView = SLPillTitleView(@"套用他人主页");
    SLApplyGlassTable(self.tableView);
    SLInstallPillBack(self);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; (void)s;
    NSUInteger n = SLSnapList().count;
    return n ? n : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slsnapcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    cell.backgroundColor = SLGlassCellColor();
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 1;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSArray *snaps = SLSnapList();
    if (!snaps.count) {
        cell.textLabel.text = @"还没有";
        cell.textLabel.textColor = [UIColor tertiaryLabelColor];
        cell.detailTextLabel.text = @"先去点开一次对方主页，回来就有了";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSDictionary *s = snaps[ip.row];
    NSString *nick = SLSnapText(s, @"nickname") ?: @"(无昵称)";
    NSMutableArray *sub = [NSMutableArray array];
    NSString *uid = SLSnapText(s, @"uniqueID");
    if (uid.length) [sub addObject:[NSString stringWithFormat:@"抖音号 %@", uid]];
    NSString *fans = SLSnapText(s, @"follower");
    if (fans.length) [sub addObject:[NSString stringWithFormat:@"粉丝 %@", fans]];
    NSString *aw = SLSnapText(s, @"aweme");
    if (aw.length) [sub addObject:[NSString stringWithFormat:@"作品 %@", aw]];

    cell.textLabel.text = nick;
    cell.detailTextLabel.text = sub.count ? [sub componentsJoinedByString:@" · "] : nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv; (void)s;
    return @"点一下即套用（会自动打开开关）";
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *snaps = SLSnapList();
    if (ip.row >= (NSInteger)snaps.count) return;
    SLApplySnap(snaps[ip.row]);
    [self.navigationController popViewControllerAnimated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    NSArray *snaps = SLSnapList();
    if (ip.row >= (NSInteger)snaps.count) return nil;
    NSDictionary *s = snaps[ip.row];
    NSString *key = SLSnapText(s, @"uid") ?: SLSnapText(s, @"sec");
    if (!key.length) return nil;
    UIContextualAction *a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                   title:@"删除"
                                                                 handler:^(UIContextualAction *act,
                                                                           UIView *v,
                                                                           void (^done)(BOOL)) {
        [SLCapStore() removeObjectForKey:key];
        SLCapPersist();
        [self.tableView reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[a]];
}

@end
