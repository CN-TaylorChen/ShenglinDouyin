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
//  v0.8.8：
//    · 背景图：39.9.0 实际走的是 -configWithCoverList:（不是 configWithURLList:），
//      改挂这个入口，别人主页把整组 coverList 模型对象留住，回我页原样喂回去
//    · 头像：我页读 avatarXxx 时直接返回对方 model 的那份对象（类型天然一致），
//      不生效时再把最大那颗方形头像贴成对方的图
//    · 作品：v0.8.7 拿 manager 自己的 uid 去比「想看谁」，永远不相等 —— 改成只看「想看谁」
//    · 换账号不再串：伪装绑定在开启时登录的那个账号上，换号自动收手并还原贴过的图
//    · 「伪装主页」点按反馈改成回弹 + 图标淡入绿对勾，不再硬切文字
//

#import "SLProfile.h"
#import "SLLog.h"
#import "SLGlass.h"
#import "AWECAUtils.h"

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
#define SLProfKeyCover     @"SLProf.coverURL"   // 主页背景图（封面）URL
#define SLProfKeyAvatar    @"SLProf.avatarURL"  // 头像 URL
#define SLProfKeyOwner     @"SLProf.ownerUid"   // 伪装绑定在哪个账号上（换了号就不生效）

static volatile BOOL sSLProfOnMePage = NO;   // 「我」页可见期间为 YES
static BOOL sSLProfStarted  = NO;
static int  sSLProfHits     = 0;
static int  sSLProfMissLogged = 0;  // 门未开的诊断日志，最多打几条

static id SLProfCallObj(id obj, NSString *selName);   // 定义在「页面判定」段，快照要用
static void SLProfForceCover(void);                   // 定义在「封面」段，套用后用
static NSString *sSLWorkWant = nil;                   // 要模拟谁（内存内，重启失效）
static NSString *sSLProfMyUID = nil;                  // 当前登录账号的 uid（在「我」页读到）
static NSMutableDictionary *sSLCoverObjs = nil;       // uid -> 对方真实 coverList（模型对象）
static NSMutableDictionary *sSLFakeUsers = nil;       // uid -> 对方真实 AWEUserModel（头像用）
static void SLProfResetPainted(void);                 // 还原被我们直接改过图的视图
static int sSLWorksGen = 0;                           // 每次套用 +1（作品列表重拉用）
static int sSLWorksReloaded = -1;                     // 已经为哪一代重拉过

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
                          SLProfKeyLike, SLProfKeyFriend, SLProfKeyCover, SLProfKeyAvatar]) {
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
// 所以在别人主页（kind == -1）期间，顺手把字段抄下来落盘成「快照」，
// 设置页点一下、或者在对方主页按 JOKER，就能整套套到自己头上。
//
// v0.8.6 修的四个坑：
//   1) 同一字段原来「只记第一次读到的值」。而列表页传进详情页的 model 数字全是 0，
//      详情接口回来再读也不覆盖 —— 所以套用后粉丝/关注全是 0。改成「非 0 覆盖 0」。
//   2) 获赞 / 互关 / 朋友这些数字不走 AWEUserModel，走统计组件的 displayCountForItem:，
//      只抓 model 永远抓不到。现在组件层也记账（SLCapNoteValue）。
//   3) 落盘原来把可变字典直接塞 NSUserDefaults 且从不同步，重装杀进程就丢。
//      现在 copy 一份 + 主动 synchronize。
//   4) userID 返回 "0" 的空 model 也被当人存下来（日志里的 `?（0）`）。现在直接丢。
//   另外同一 uid 改成「逐字段合并」，残片不会再覆盖掉完整记录。

#define SLProfKeySnaps @"SLProf.snaps"
// SLProfKeyCover 定义在文件顶部（清空逻辑要用）

static BOOL sSLCapOn  = NO;
static NSMutableDictionary *sSLCapCur   = nil;   // 正在看的这个人的字段
static NSMutableDictionary *sSLCapStore = nil;   // uid -> dict，持久化
static NSMutableDictionary *sSLCapPend  = nil;   // 还不知道是谁的字段（组件先于 model 跑到）
static NSString *sSLCapLastKey = nil;            // 最近一次落盘的 uid
static NSTimeInterval sSLCapLastLogAt = 0;

static NSMutableDictionary *SLCapStore(void) {
    if (sSLCapStore) return sSLCapStore;
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:SLProfKeySnaps];
    sSLCapStore = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    return sSLCapStore;
}

static void SLCapPersist(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:[SLCapStore() copy] forKey:SLProfKeySnaps];   // 传不可变副本
    [d synchronize];   // 这个进程随时会被重装杀掉，不主动落盘就会丢
}

// 把任意值按「1.2万 / 1.3亿 / 纯数字」解析成整数；解析不出（昵称这种）返回 NO
static BOOL SLProfNumberFromValue(id v, long long *out) {
    if ([v isKindOfClass:[NSNumber class]]) { *out = [v longLongValue]; return YES; }
    if (![v isKindOfClass:[NSString class]]) return NO;
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return NO;
    if ([s hasSuffix:@"万"] || [s hasSuffix:@"w"] || [s hasSuffix:@"W"]) {
        *out = (long long)([[s substringToIndex:s.length - 1] doubleValue] * 10000.0);
        return YES;
    }
    if ([s hasSuffix:@"亿"]) {
        *out = (long long)([[s substringToIndex:s.length - 1] doubleValue] * 100000000.0);
        return YES;
    }
    NSString *digits = [[s componentsSeparatedByCharactersInSet:
        [[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (!digits.length) return NO;
    *out = [digits longLongValue];
    return YES;
}

// 新值是不是比旧值更值得留：数字只认「大于 0 且变了」，字符串不许用 0/空把好值顶掉
static BOOL SLCapBetter(id oldV, id newV) {
    if (!newV) return NO;
    if (!oldV) return YES;
    NSString *os = [oldV description] ?: @"";
    NSString *ns = [newV description] ?: @"";
    if (!ns.length) return NO;
    long long on = 0, nn = 0;
    BOOL oldNum = SLProfNumberFromValue(oldV, &on);
    BOOL newNum = SLProfNumberFromValue(newV, &nn);
    if (oldNum && newNum) return nn > 0 && nn != on;
    if ([ns isEqualToString:os]) return NO;
    if ([ns isEqualToString:@"0"] && ![os isEqualToString:@"0"]) return NO;   // 别拿 0 覆盖真值
    return YES;
}

// 把「还没认领」的字段并进当前这条记录
static void SLCapAbsorbPend(void) {
    if (!sSLCapPend || !sSLCapCur) return;
    for (NSString *k in sSLCapPend) {
        id nv = sSLCapPend[k];
        id ov = sSLCapCur[k];
        if (!ov || SLCapBetter(ov, nv)) sSLCapCur[k] = nv;
    }
    sSLCapPend = nil;
}

static void SLCapBegin(void) {
    sSLCapOn = YES;
    sSLCapCur = nil;
    sSLCapPend = nil;      // 换人，上一屏挂起的作废
}

// 把手上这份合并进 store（不改变 sSLCapOn）
static void SLCapFlush(void) {
    SLCapAbsorbPend();
    NSMutableDictionary *cap = sSLCapCur;
    sSLCapCur = nil;
    if (!cap) return;

    id keyObj = cap[@"uid"];
    if (![keyObj isKindOfClass:[NSString class]] || ![(NSString *)keyObj length]) keyObj = cap[@"sec"];
    if (![keyObj isKindOfClass:[NSString class]] || ![(NSString *)keyObj length]) return;
    NSString *key = keyObj;
    // 空 model：userID 是 "0"、或者根本没有资料字段，都不该占一个位置
    if ([key isEqualToString:@"0"] || [key isEqualToString:@"(null)"]) return;
    if (cap.count < 3) return;      // 只有 uid + 一个字段的残片

    NSMutableDictionary *store = SLCapStore();
    NSMutableDictionary *merged = store[key] ? [store[key] mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *k in cap) {
        if ([k isEqualToString:@"ts"]) continue;
        id nv = cap[k];
        id ov = merged[k];
        if (!ov || SLCapBetter(ov, nv)) merged[k] = nv;
    }
    merged[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    store[key] = merged;
    sSLCapLastKey = key;

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

    // 同一个人的字段是慢慢补全的，刷屏没意义：每次落盘最多 1 行，2 秒内不重复
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - sSLCapLastLogAt > 2.0) {
        sSLCapLastLogAt = now;
        id nickObj = merged[@"nickname"];
        NSString *nick = [nickObj isKindOfClass:[NSString class]] ? nickObj : nil;
        SLLog(@"SNAP| 已抓取 %@（%@）· 字段 %lu", nick.length ? nick : @"?", key,
              (unsigned long)merged.count);
    }
}

static void SLCapFinish(void) {
    sSLCapOn = NO;
    SLCapFlush();
}

// 组件层（获赞 / 互关 / 封面…）没有 model 可问，直接往当前这条记录里追加。
// 组件往往比 model 的 getter 先跑到，这时还不知道这一屏是谁的 —— 先挂起（sSLCapPend），
// 等 SLCapNote 拿到 uid 再整包认领。v0.8.6 之前是「接着上一条记录补」，
// 结果封面被记到了上一个人的名下，套用时就永远拿不到背景图。
static void SLCapNoteValue(NSString *field, id value) {
    if (!sSLCapOn || !field || !value) return;
    if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) return;
    if (![value description].length) return;

    if (sSLCapCur) {
        id ov = sSLCapCur[field];
        if (!ov || SLCapBetter(ov, value)) sSLCapCur[field] = value;
        return;
    }
    if (!sSLCapPend) sSLCapPend = [NSMutableDictionary dictionary];
    id ov = sSLCapPend[field];
    if (!ov || SLCapBetter(ov, value)) sSLCapPend[field] = value;
}

// 只在别人主页那几秒记账；用 model 的 uid 建条目
// 连续滑到另一个人时（kind 一直是 -1）会先把手上的存掉再开新的
static void SLCapNote(id model, NSString *field, id value) {
    if (!sSLCapOn || !field || !value) return;
    if (![value isKindOfClass:[NSString class]] && ![value isKindOfClass:[NSNumber class]]) return;

    id uidObj = SLProfCallObj(model, @"userID");
    id secObj = SLProfCallObj(model, @"secUserID");
    NSString *uid = [uidObj isKindOfClass:[NSString class]] ? uidObj : nil;
    NSString *sec = [secObj isKindOfClass:[NSString class]] ? secObj : nil;
    if (!uid.length && !sec.length) return;
    if ([uid isEqualToString:@"0"]) uid = nil;      // 空 model，等真身
    if (!uid.length && !sec.length) return;
    NSString *newKey = uid.length ? uid : sec;

    if (sSLCapCur) {
        id curObj = sSLCapCur[@"uid"] ?: sSLCapCur[@"sec"];
        if ([curObj isKindOfClass:[NSString class]] && ![curObj isEqualToString:newKey]) SLCapFlush();
    }
    if (!sSLCapCur) {
        sSLCapCur = [NSMutableDictionary dictionary];
        if (uid.length) sSLCapCur[@"uid"] = uid;
        if (sec.length) sSLCapCur[@"sec"] = sec;
        SLCapAbsorbPend();       // 这一屏的封面 / 数字终于知道是谁的了
    }
    id ov = sSLCapCur[field];
    if (!ov || SLCapBetter(ov, value)) sSLCapCur[field] = value;
}

// 快照按时间倒序，给设置页用
static NSArray<NSDictionary *> *SLSnapList(void) {
    NSMutableDictionary *store = SLCapStore();
    [(NSMutableDictionary *)store removeObjectForKey:@"0"];   // 老版本留下的空条目
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in store.allValues) {
        if (![s isKindOfClass:[NSDictionary class]]) continue;
        if (s.count < 3) continue;
        [out addObject:s];
    }
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
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

// 把一份快照整套写进预设（只写抓到了的字段，缺的不去动原有值）
static void SLApplySnap(NSDictionary *s) {
    SLProfSetStr(SLSnapText(s, @"nickname"),  SLProfKeyNickname);
    SLProfSetStr(SLSnapText(s, @"uniqueID"),  SLProfKeyUID);
    SLProfSetStr(SLSnapText(s, @"signature"), SLProfKeySignature);
    SLProfSetStr(SLSnapText(s, @"aweme"),     SLProfKeyAweme);
    SLProfSetStr(SLSnapText(s, @"following"), SLProfKeyFollowing);
    SLProfSetStr(SLSnapText(s, @"follower"),  SLProfKeyFollower);
    SLProfSetStr(SLSnapText(s, @"like"),      SLProfKeyLike);
    SLProfSetStr(SLSnapText(s, @"friend"),    SLProfKeyFriend);
    SLProfSetStr(SLSnapText(s, @"cover"),     SLProfKeyCover);
    SLProfSetStr(SLSnapText(s, @"avatar"),    SLProfKeyAvatar);
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SLProfKeyEnabled];
    // 绑定到当前登录的这个账号：换号之后自动不套用（否则切号后数据会跟过去）
    if (sSLProfMyUID.length) {
        [[NSUserDefaults standardUserDefaults] setObject:sSLProfMyUID forKey:SLProfKeyOwner];
    }
    NSString *uid = SLSnapText(s, @"uid");
    if (uid.length) sSLWorkWant = uid;          // 作品 / 封面 / 头像都要换成这个人的
    sSLWorksGen++;
    SLLog(@"SNAP| 套用 %@ 的整套资料", SLSnapText(s, @"nickname") ?: @"?");
    SLProfForceCover();                         // 若此刻正停在「我」页，立刻换背景
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

// 在「我」页记下当前登录账号的 uid —— 伪装只对这个账号生效，换号后要自动收手
static void SLProfNoteMyUID(UIViewController *vc) {
    id um = SLProfCallObj(vc, @"userModel");
    id uid = um ? SLProfCallObj(um, @"userID") : nil;
    NSString *s = nil;
    if ([uid isKindOfClass:[NSString class]]) s = uid;
    else if ([uid isKindOfClass:[NSNumber class]]) s = [uid stringValue];
    if (s.length && ![s isEqualToString:@"0"]) sSLProfMyUID = s;
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
                if (SLProfCallBool(p, @"isCurrentUserProfilePage")) {
                    SLProfNoteMyUID(p);
                    return 1;
                }
                // 首次渲染时这个标志可能还没算好；「我」页独有设置入口，有它就是本人页
                if (SLProfCallObj(p, @"profileSettingComponent") != nil) {
                    SLProfNoteMyUID(p);
                    return 1;
                }
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

// 伪装绑定在「开启那一刻登录的账号」上。切换到别的账号后数据不能跟着走 ——
// owner 与当前账号不一致时整条链路关掉，并把自己贴过的图还原。
static BOOL SLProfOwnerOK(void) {
    NSString *owner = [[NSUserDefaults standardUserDefaults] stringForKey:SLProfKeyOwner];
    if (!owner.length) return YES;                 // 还没绑定，第一次进我页时绑
    if (!sSLProfMyUID.length) return YES;          // 这次还没读到自己的 uid，先放行
    if ([owner isEqualToString:sSLProfMyUID]) return YES;

    static NSString *sLastWarn = nil;
    if (![sLastWarn isEqualToString:sSLProfMyUID]) {
        sLastWarn = sSLProfMyUID;
        SLLog(@"PROF| 当前账号 %@ ≠ 伪装绑定账号 %@ → 本账号不套用", sSLProfMyUID, owner);
    }
    SLProfResetPainted();
    return NO;
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
        if (!SLProfOwnerOK()) { sSLProfOnMePage = NO; return NO; }
        sSLProfOnMePage = YES;
        // 第一次确认身份时把 owner 定下来，之后换号就不生效了
        if (sSLProfMyUID.length) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            if (![d stringForKey:SLProfKeyOwner].length) {
                [d setObject:sSLProfMyUID forKey:SLProfKeyOwner];
                SLLog(@"PROF| 已把伪装绑定到当前账号 %@", sSLProfMyUID);
            }
        }
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
// 获赞 / 互关 不走 AWEUserModel 的 getter，是各自组件算好再交给 cell 的：
//   AWEProfileSocialStatisticPraiseComponent  -displayCountForItem:  （获赞）
//   AWEProfileSocialStatisticMutualComponent  -displayCountForItem:  （互关）
//   AWEProfileSocialStatisticFriendComponent  -displayCountForItem:  （朋友）
//   ...Play / Fans / Follow 同理（作品 / 粉丝 / 关注）
//
// v0.8.5 挂上去却完全没生效，根因是返回值判断写错了：
//   if (v && ![v isKindOfClass:[NSString class]]) return v;
// 这个方法返的其实是 NSNumber，于是每次都在这里原样吐回去，静默失败。
// 现在 NSString / NSNumber / nil 三种都接，只在奇怪类型（富文本之类）上放行。

#define SL_PROF_COUNT_HOOK(NAME, KEY, TAG, FIELD)                          \
    static id (*o_##NAME)(id, SEL, id);                                    \
    static id h_##NAME(id self, SEL _cmd, id item) {                       \
        id v = o_##NAME ? o_##NAME(self, _cmd, item) : nil;                \
        if (!SLProfGate()) { SLCapNoteValue(FIELD, v); return v; }         \
        long long n = 0;                                                   \
        if (!SLProfNumber(KEY, &n)) return v;                              \
        if (sSLProfHits < 20) { sSLProfHits++;                             \
            SLLog(@"PROF| 替换 %@ → %lld", TAG, n); }                      \
        if (v && ![v isKindOfClass:[NSString class]] &&                    \
            ![v isKindOfClass:[NSNumber class]]) return v;                 \
        if ([v isKindOfClass:[NSNumber class]]) return @(n);               \
        return SLProfFormatCount(n);                                       \
    }

SL_PROF_COUNT_HOOK(praiseText, SLProfKeyLike,      @"praise",   @"like")
SL_PROF_COUNT_HOOK(mutualText, SLProfKeyFriend,    @"mutual",   @"friend")
SL_PROF_COUNT_HOOK(friendText, SLProfKeyFriend,    @"friend",   @"friend")
SL_PROF_COUNT_HOOK(playText,   SLProfKeyAweme,     @"play",     @"aweme")
SL_PROF_COUNT_HOOK(fansText,   SLProfKeyFollower,  @"fans",     @"follower")
SL_PROF_COUNT_HOOK(followText, SLProfKeyFollowing, @"follow",   @"following")

#pragma mark - 图片下载 / 直接改图（可还原）
//
// 头图和头像有的走 model getter，有的直接由视图自己去拉图。getter 能截就截，
// 截不到就把对方的图下载下来贴到对应 imageView 上 —— 贴之前记下原图，
// 换账号 / 关掉伪装时贴回去，不留残影。

static NSMapTable *sSLPaintOrig = nil;

static NSMapTable *SLPaintOrig(void) {
    if (sSLPaintOrig) return sSLPaintOrig;
    sSLPaintOrig = [NSMapTable mapTableWithKeyOptions:
                    (NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality)
                                        valueOptions:NSPointerFunctionsStrongMemory];
    return sSLPaintOrig;
}

static void SLProfLoadImage(NSString *url, void (^done)(UIImage *img)) {
    if (!url.length || !done) return;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    UIImage *hit = cache[url];
    if (hit) { done(hit); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:u
         completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d.length) return;
        UIImage *img = [UIImage imageWithData:d];
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            cache[url] = img;
            done(img);
        });
    }] resume];
}

// 贴图前把原图记下来（同一张视图只记第一次，避免记成我们自己贴的那张）
static void SLPaint(UIImageView *iv, NSString *url) {
    if (!iv || !url.length) return;
    NSMapTable *t = SLPaintOrig();
    if (![t objectForKey:iv] && iv.image) [t setObject:iv.image forKey:iv];
    __weak UIImageView *wiv = iv;
    SLProfLoadImage(url, ^(UIImage *img) {
        UIImageView *v = wiv;
        if (!v || !img) return;
        v.image = img;
        v.contentMode = UIViewContentModeScaleAspectFill;
        v.clipsToBounds = YES;
        [v setNeedsDisplay];
    });
}

static void SLProfResetPainted(void) {
    NSMapTable *t = SLPaintOrig();
    if (!t.count) return;
    NSEnumerator *e = [t keyEnumerator];
    for (UIImageView *iv = [e nextObject]; iv; iv = [e nextObject]) {
        UIImage *old = [t objectForKey:iv];
        if (old) iv.image = old;
    }
    [t removeAllObjects];
    SLLog(@"PAINT| 已还原直接贴过的图");
}

#pragma mark - 主页背景图（封面）
//
// 39.9.0 的封面视图 AWEProfileBannerBGCoverView 有两个入口：
//   -configWithCoverList:                              ← 实际在用的（直接收模型对象）
//   -configWithURLList:lightColorList:darkColorList:   ← 旧入口
// v0.8.7 只挂了后面那个，所以既抓不到也换不上，日志里一直是「无背景」。
//
// 现在的做法：别人主页把 coverList 那一组**真实模型对象**整包留住，
// 回我页时原样喂回去 —— 颜色、裁切、渐变全是抖音自己算的，不存在版式错位。

static void (*o_coverConfig)(id, SEL, id, id, id);
static void (*o_coverList)(id, SEL, id);
static NSString *SLCurViewUID(void);       // 定义在「伪装主页」段

static NSString *SLProfURLString(id x) {
    if ([x isKindOfClass:[NSURL class]]) return [(NSURL *)x absoluteString];
    if ([x isKindOfClass:[NSString class]]) return x;
    return nil;
}

static NSString *SLProfFirstURL(id list) {
    if (![list isKindOfClass:[NSArray class]]) return nil;
    for (id x in (NSArray *)list) {
        NSString *s = SLProfURLString(x);
        if (s.length) return s;
    }
    return nil;
}

// 从 coverList（模型对象数组）里挖出第一张图的 URL
static NSString *SLProfCoverURL(id coverList) {
    if (![coverList isKindOfClass:[NSArray class]]) return nil;
    for (id item in (NSArray *)coverList) {
        NSString *s = SLProfURLString(item);
        if (s.length) return s;
        id um = SLProfCallObj(item, @"urlModel");
        s = SLProfFirstURL(um ? SLProfCallObj(um, @"urlList") : nil);
        if (s.length) return s;
        s = SLProfFirstURL(SLProfCallObj(item, @"urlList"));
        if (s.length) return s;
    }
    return nil;
}

// 把别人的封面记到这个 uid 名下（对象留内存，URL 进快照落盘）
// 只在「正在看别人主页」期间生效（sSLCapOn），避免把我页的封面记到别人名下
static void SLCoverRemember(NSString *uid, id coverList, NSString *url) {
    if (!sSLCapOn || !uid.length) return;
    if (coverList) {
        if (!sSLCoverObjs) sSLCoverObjs = [NSMutableDictionary dictionary];
        if (sSLCoverObjs.count > 12) [sSLCoverObjs removeAllObjects];
        sSLCoverObjs[uid] = coverList;
    }
    if (url.length) {
        if (!sSLCapCur) {
            sSLCapCur = [NSMutableDictionary dictionary];
            sSLCapCur[@"uid"] = uid;
        }
        sSLCapCur[@"cover"] = url;
    }
}

// 封面钩子里统一走这个：URL 认不出人时自动挂起，等 model 那一下认领
static void SLCoverCapture(id coverList, NSString *url) {
    if (!sSLCapOn) return;
    if (SLProfPageKind() == 1) return;      // 已经回到我页：绝不能把我自己的封面记到别人名下
    if (url.length) SLCapNoteValue(@"cover", url);
    NSString *uid = SLCurViewUID();
    if (uid.length) SLCoverRemember(uid, coverList, nil);
}

static NSArray *sCoverLastURLs  = nil;   // 「我」页最近一次下发的参数，强制刷新时原样回传
static NSArray *sCoverLastLight = nil;
static NSArray *sCoverLastDark  = nil;

// 我页换封面：优先喂对方那组模型对象，退而求其次用 URL
static BOOL SLProfApplyCoverTo(id view) {
    if (!view) return NO;
    NSArray *objs = sSLWorkWant.length ? sSLCoverObjs[sSLWorkWant] : nil;
    if (objs.count && o_coverList) {
        o_coverList(view, NSSelectorFromString(@"configWithCoverList:"), objs);
        return YES;
    }
    NSString *url = SLProfStr(SLProfKeyCover);
    if (!url.length || !o_coverConfig) return NO;
    id first = sCoverLastURLs.firstObject;
    id neu = [first isKindOfClass:[NSURL class]] ? [NSURL URLWithString:url] : url;
    o_coverConfig(view, NSSelectorFromString(@"configWithURLList:lightColorList:darkColorList:"),
                  @[neu], sCoverLastLight ?: @[], sCoverLastDark ?: @[]);
    return YES;
}

// 把 URL 直接贴到封面视图自己的 imageView 上（最后一道保险）
static void SLProfPaintCoverView(id view, NSString *url) {
    if (!view || !url.length) return;
    id iv = SLProfCallObj(view, @"imageView");
    if ([iv isKindOfClass:[UIImageView class]]) SLPaint(iv, url);
}

static void h_coverConfig(id self, SEL _cmd, id urls, id light, id dark) {
    if (!SLProfGate()) {
        NSString *u = SLProfFirstURL(urls);
        id list = nil;
        if (!u.length) { list = urls; u = SLProfCoverURL(urls); }
        SLCoverCapture(list, u);
        if (o_coverConfig) o_coverConfig(self, _cmd, urls, light, dark);
        return;
    }

    if ([urls isKindOfClass:[NSArray class]])  sCoverLastURLs  = [(NSArray *)urls copy];
    if ([light isKindOfClass:[NSArray class]]) sCoverLastLight = [(NSArray *)light copy];
    if ([dark isKindOfClass:[NSArray class]])  sCoverLastDark  = [(NSArray *)dark copy];

    if (SLProfApplyCoverTo(self)) {
        static BOOL sCoverLogged = NO;
        if (!sCoverLogged) { sCoverLogged = YES; SLLog(@"COVER| 已把背景换成对方的"); }
        return;
    }
    if (o_coverConfig) o_coverConfig(self, _cmd, urls, light, dark);
}

static void h_coverList(id self, SEL _cmd, id coverList) {
    if (!SLProfGate()) {
        SLCoverCapture(coverList, SLProfCoverURL(coverList));
        if (o_coverList) o_coverList(self, _cmd, coverList);
        return;
    }

    if ([coverList isKindOfClass:[NSArray class]]) sCoverLastURLs = [coverList copy];
    if (SLProfApplyCoverTo(self)) {
        static BOOL sCoverListLogged = NO;
        if (!sCoverListLogged) { sCoverListLogged = YES; SLLog(@"COVER| 已把背景换成对方的（coverList）"); }
        return;
    }
    if (o_coverList) o_coverList(self, _cmd, coverList);
}

// 封面视图只在页面初次配置时被调一次。如果那次调用发生在「我」页还没被识别出来之前，
// 替换就漏了，之后也不会重来 —— 这里主动在窗口里把封面视图找出来重喂一遍。
static void SLProfFindCoverViews(UIView *root, NSMutableArray *out) {
    if (!root || !out) return;
    if ([NSStringFromClass([root class]) isEqualToString:@"AWEProfileBannerBGCoverView"]) {
        [out addObject:root];
        return;
    }
    for (UIView *v in root.subviews) SLProfFindCoverViews(v, out);
}

static void SLProfForceCover(void) {
    if (!SLProfileEnabled()) return;
    NSString *url = SLProfStr(SLProfKeyCover);
    NSArray *objs = sSLWorkWant.length ? sSLCoverObjs[sSLWorkWant] : nil;
    if (!url.length && !objs.count) return;

    NSMutableArray *views = [NSMutableArray array];
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) SLProfFindCoverViews(w, views);
    }
    if (!views.count) { SLLog(@"COVER| 没找到封面视图，跳过"); return; }

    NSUInteger n = 0;
    for (UIView *v in views) {
        if (SLProfApplyCoverTo(v)) n++;
        SLProfPaintCoverView(v, url.length ? url : SLProfCoverURL(objs));
        [v setNeedsLayout];
    }
    SLLog(@"COVER| 已强制刷新 %lu 处封面（%@）", (unsigned long)n,
          objs.count ? @"模型对象" : @"URL");
}

#pragma mark - 作品列表 + 播放量
//
// 主页那个九宫格（以及每张封面右下角的播放量）不走 AWEUserModel 的任何 getter，
// 它是 AWEUserPostsDataManager 持有一份 dataSource（作品数组），由 cell 自己渲染。
// 想「模拟对方的作品」，唯一的办法就是把那份 dataSource 换成对方的。
//
// 不需要联网：你点开对方主页时，对方那份 dataSource 已经完整躺在内存里了。
// 这里把它按 uid 强引用住，等我回自己主页时交给我的 data manager 用。
// 只在内存里，重启即失效 —— 与快照本身的设计一致。

#define SLProfKeyWorks  @"SLProf.works"

static BOOL SLProfWorksEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:SLProfKeyWorks];
    return v ? [v boolValue] : YES;      // 默认开
}

static NSMutableDictionary *sSLWorkSrc = nil;   // uid -> dataSource（强引用）
static char kSLPostsUIDKey;

// 每个 data manager 建出来时就知道它属于谁，挂到自己身上带走
static id (*o_postsInit)(id, SEL, id, id);
static id h_postsInit(id self, SEL _cmd, id uid, id sec) {
    id r = o_postsInit ? o_postsInit(self, _cmd, uid, sec) : nil;
    if ([uid isKindOfClass:[NSString class]] && [(NSString *)uid length]) {
        objc_setAssociatedObject(self, &kSLPostsUIDKey, uid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return r;
}

static id (*o_postsDS)(id, SEL);          // dataSource 原实现
static void (*o_postsSetDS)(id, SEL, id);
static void h_postsSetDS(id self, SEL _cmd, id ds) {
    // 只记录别人主页那份；「我」页那份绝不在这里注入 ——
    // 一旦把别人的数组塞进我自己的 manager，换账号/关掉伪装后就会残留
    NSString *uid = objc_getAssociatedObject(self, &kSLPostsUIDKey);
    if (uid.length && ds && (SLProfPageKind() == -1 || sSLCapOn)) {
        if (!sSLWorkSrc) sSLWorkSrc = [NSMutableDictionary dictionary];
        sSLWorkSrc[uid] = ds;                       // 强引用：列表对象跟 model 一起留着
        NSUInteger n = [ds respondsToSelector:@selector(count)] ? [(NSArray *)ds count] : 0;
        if (n) SLLog(@"WORKS| 记住 %@ 的作品列表（%@，%lu 条）", uid,
                     NSStringFromClass([ds class]), (unsigned long)n);
    }
    if (o_postsSetDS) o_postsSetDS(self, _cmd, ds);
}

static id h_postsDS(id self, SEL _cmd) {
    id orig = o_postsDS ? o_postsDS(self, _cmd) : nil;
    if (!sSLWorkWant.length || !SLProfWorksEnabled()) return orig;
    if (!(SLProfGate() || sSLProfOnMePage)) return orig;   // 只在「我」页换，别人主页不动
    id cached = sSLWorkSrc[sSLWorkWant];
    if (!cached) return orig;
    // 类型不一致就别硬塞，宁可显示自己的
    if (orig && [cached class] != [orig class]) return orig;

    static BOOL sWorksLogged = NO;
    if (!sWorksLogged) {
        sWorksLogged = YES;
        NSUInteger n = [cached respondsToSelector:@selector(count)] ? [(NSArray *)cached count] : 0;
        SLLog(@"WORKS| 已把「我」页作品列表换成 %@ 的（%lu 条）", sSLWorkWant, (unsigned long)n);
    }
    return cached;
}

// 作品九宫格是列表视图自己缓存的，换掉 dataSource 之后得让它重拉一次。
// 只在「我」页刚出现、并且真的套用过别人作品时才做，且每次套用只做一次。
static UIView *SLProfBiggestCollection(UIView *root) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:[UICollectionView class]]) {
            CGFloat a = v.bounds.size.width * v.bounds.size.height;
            if (a > bestArea && a > 10000) { bestArea = a; best = v; }
        }
        UIView *deep = SLProfBiggestCollection(v);
        if (deep) {
            CGFloat a = deep.bounds.size.width * deep.bounds.size.height;
            if (a > bestArea) { bestArea = a; best = deep; }
        }
    }
    return best;
}

static void SLProfReloadListOnce(void) {
    if (sSLWorksGen == sSLWorksReloaded) return;
    if (!sSLWorkWant.length || !sSLWorkSrc[sSLWorkWant]) return;
    if (!SLProfWorksEnabled() || !SLProfGate()) return;

    UIViewController *top = SLProfTopVC();
    if (!top.isViewLoaded) return;
    UIView *cv = SLProfBiggestCollection(top.view);
    if (!cv) return;
    sSLWorksReloaded = sSLWorksGen;
    [(UICollectionView *)cv reloadData];
    SLLog(@"WORKS| 已让「我」页作品列表重新拉一次");
}

#pragma mark - 头像
//
// 头像是 AWEUserModel 上的一组 getter（avatarThumb / avatarMedium / avatarLarge …）给出来的，
// header 里的 AWEAvatarImageView 也是拿着 user model 去读。所以最稳的办法不是自己造 URL，
// 而是把**对方那个真实 model** 存下来，我页读头像时原样返回对方的对象 —— 类型天然一致。
// 万一某条链路不读 getter，回我页时再把窗口里最大的那颗方形头像直接贴成对方的图。

static BOOL sSLAvatarBusy = NO;      // 防止 getter 里再回调自己

static id SLProfAvatarDo(id model, id orig, NSString *getter) {
    if (sSLAvatarBusy) return orig;
    if (!sSLWorkWant.length || !SLProfGate()) return orig;
    id other = sSLFakeUsers[sSLWorkWant];
    if (!other || other == model) return orig;
    sSLAvatarBusy = YES;
    id fake = SLProfCallObj(other, getter);
    sSLAvatarBusy = NO;
    if (!fake) return orig;
    if (orig && [fake class] != [orig class]) return orig;   // 类型不一致宁可不动
    static BOOL sAvLogged = NO;
    if (!sAvLogged) { sAvLogged = YES; SLLog(@"AVATAR| model.%@ 已返回对方的头像对象", getter); }
    return fake;
}

#define SL_AVATAR_HOOK(NAME, GETTER)                                   \
    static id (*o_##NAME)(id, SEL);                                    \
    static id h_##NAME(id self, SEL _cmd) {                            \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                  \
        return SLProfAvatarDo(self, v, GETTER);                        \
    }

SL_AVATAR_HOOK(avThumb,  @"avatarThumb")
SL_AVATAR_HOOK(avMedium, @"avatarMedium")
SL_AVATAR_HOOK(avLarge,  @"avatarLarge")
SL_AVATAR_HOOK(av168,    @"avatar168")
SL_AVATAR_HOOK(av300,    @"avatar300")

// 从 model 里挑一张最清晰的头像 URL（抓快照 / 贴图兜底用）
static NSString *SLProfAvatarURL(id model) {
    if (!model) return nil;
    for (NSString *n in @[@"avatarLarge", @"avatar300", @"avatarMedium",
                          @"avatar168", @"avatarThumb"]) {
        id v = SLProfCallObj(model, n);
        NSString *s = SLProfURLString(v);
        if (!s.length) s = SLProfFirstURL(SLProfCallObj(v, @"urlList"));
        if (s.length) return s;
    }
    return SLProfFirstURL(SLProfCallObj(model, @"avatarURLs"));
}

// 在页面里找「最像头像」的那张图：接近正方形、尺寸 44~200、位于上半屏
static UIImageView *SLProfBigSquareImage(UIView *root, UIView *win, CGFloat *outW) {
    UIImageView *best = nil;
    CGFloat bestW = 0;
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:[UIImageView class]]) {
            CGRect r = [v convertRect:v.bounds toView:win];
            CGFloat w = r.size.width, h = r.size.height;
            CGFloat diff = (w > h) ? (w - h) : (h - w);
            BOOL square = (diff < 6.0) && w >= 44.0 && w <= 200.0;
            BOOL upper  = (r.origin.y >= 0) && (CGRectGetMidY(r) < win.bounds.size.height * 0.45);
            if (square && upper && w > bestW) { bestW = w; best = (UIImageView *)v; }
        }
        CGFloat subW = 0;
        UIImageView *deep = SLProfBigSquareImage(v, win, &subW);
        if (deep && subW > bestW) { bestW = subW; best = deep; }
    }
    if (outW) *outW = bestW;
    return best;
}

static void SLProfPaintAvatar(void) {
    if (!SLProfileEnabled() || !SLProfGate()) return;
    NSString *url = SLProfStr(SLProfKeyAvatar);
    if (!url.length) url = SLProfAvatarURL(sSLWorkWant.length ? sSLFakeUsers[sSLWorkWant] : nil);
    if (!url.length) return;

    UIViewController *top = SLProfTopVC();
    UIView *win = top.view.window;
    if (!win || !top.isViewLoaded) return;

    CGFloat w = 0;
    UIImageView *iv = SLProfBigSquareImage(top.view, win, &w);
    if (!iv || w < 44.0) return;
    SLPaint(iv, url);
    static BOOL sPainted = NO;
    if (!sPainted) { sPainted = YES; SLLog(@"AVATAR| 已把 %.0fpt 的头像换成对方的", w); }
}

#pragma mark - 「伪装主页」（别人主页左上角那颗胶囊）
//
// 挂在 AWEProfileNavigationContainerView 里、贴着返回按钮右边，滚动时跟着导航栏一起淡出。
// 点一下 = 把这个人的整套资料写进预设 + 打开总开关。
//
// v0.8.7 修的关键问题：点下去数据不全。
// 原来是「先读 store[uid]」，而 store 里那份很可能是先前在关注/粉丝列表里瞥一眼留下的
// 残片（只有 uid + 昵称），真正完整的还在内存里的 sSLCapCur 里没落盘。
// 现在：先 SLCapFlush 落盘，再从当前页面的 userModel 现场抄一遍，最后合并。

#define SLFakeTag 0x5A0B20

static __weak UIViewController *sSLFakeVC = nil;
static NSString *sSLFakeUID = nil;

static NSString *SLFakeNumText(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%lld", [v longLongValue]];
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length || [s isEqualToString:@"0"] || [s isEqualToString:@"(null)"]) return nil;
    return s;
}

// 当前详情页是谁（封面那几个钩子比这个函数先定义，所以在这里给出实现）
static NSString *SLCurViewUID(void) {
    return sSLFakeUID.length ? sSLFakeUID : nil;
}

// 现场从 model 抄一份：点下去那一刻详情接口早回来了，数字都是真的
static NSDictionary *SLFakeHarvest(id model) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!model) return out;
    NSArray *pairs = @[@"uid:userID", @"sec:secUserID", @"nickname:nickname",
                       @"signature:signature", @"uniqueID:uniqueIDForShow",
                       @"aweme:awemeCount", @"following:followingCount", @"follower:followerCount",
                       @"like:favoritingCount", @"friend:friendCount"];
    for (NSString *p in pairs) {
        NSArray *kv = [p componentsSeparatedByString:@":"];
        if (kv.count != 2) continue;
        id v = SLProfCallObj(model, kv[1]);
        NSString *t = SLFakeNumText(v);
        if (t.length) out[(NSString *)kv[0]] = t;
    }

    // 背景图：model 里就有真身，不用等封面视图被调
    //   AWEUserModel.profileCover -> AWEProfileCoverInfoModel.coverList
    //     -> 每项 AWEProfileCoverURLModel.urlModel -> AWEURLModel.urlList
    id cover = SLProfCallObj(model, @"profileCover");
    if (cover) {
        id list = SLProfCallObj(cover, @"coverList");
        if ([list isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)list) {
                id um2 = SLProfCallObj(item, @"urlModel");
                id urls = um2 ? SLProfCallObj(um2, @"urlList") : nil;
                NSString *u = SLProfFirstURL(urls);
                if (u.length) { out[@"cover"] = u; break; }
            }
        }
    }
    NSString *cov2 = SLProfCoverURL(SLProfCallObj(cover, @"coverList"));
    if (cov2.length && !out[@"cover"]) out[@"cover"] = cov2;

    // 头像：header 用的那几张里挑最清晰的存一份 URL（重启后靠它兜底贴图）
    NSString *av = SLProfAvatarURL(model);
    if (av.length) out[@"avatar"] = av;
    return out;
}

static void SLFakeMerge(NSMutableDictionary *into, NSDictionary *from) {
    if (!into || !from) return;
    for (NSString *k in from) {
        if ([k isEqualToString:@"ts"]) continue;
        id nv = from[k];
        id ov = into[k];
        if (!ov || SLCapBetter(ov, nv)) into[k] = nv;
    }
}

// 把现场抄到的字段并进快照库（不覆盖更好的值），列表里也能立刻看到
static void SLFakeStore(NSString *uid, NSDictionary *fields) {
    if (!uid.length || !fields.count) return;
    NSMutableDictionary *store = SLCapStore();
    id old = store[uid];
    NSMutableDictionary *merged = [old isKindOfClass:[NSDictionary class]]
        ? [old mutableCopy] : [NSMutableDictionary dictionary];
    SLFakeMerge(merged, fields);
    if (merged.count < 2) return;
    merged[@"uid"] = uid;
    merged[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    store[uid] = merged;
    SLCapPersist();
}

static NSDictionary *SLFakeSnapshot(UIViewController *vc) {
    SLCapFlush();                              // 先把内存里那份落盘，别再读旧残片

    NSString *uid = sSLFakeUID;
    id um = vc ? SLProfCallObj(vc, @"userModel") : nil;
    if (!uid.length) uid = SLFakeNumText(um ? SLProfCallObj(um, @"userID") : nil);
    if (!uid.length && sSLCapLastKey.length) uid = sSLCapLastKey;

    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    if (uid.length) {
        NSDictionary *old = SLCapStore()[uid];
        if ([old isKindOfClass:[NSDictionary class]]) [snap addEntriesFromDictionary:old];
    }
    SLFakeMerge(snap, SLFakeHarvest(um));      // model 现场值最权威，压在上面
    if (sSLCapPend.count) SLFakeMerge(snap, sSLCapPend);
    if (snap.count < 2) return nil;

    if (uid.length) SLFakeStore(uid, snap);     // 列表里也能看到这份完整的
    return snap;
}

@interface SLFakeTarget : NSObject
+ (instancetype)shared;
- (void)tap:(UIButton *)b;
@end

@implementation SLFakeTarget
+ (instancetype)shared {
    static SLFakeTarget *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[SLFakeTarget alloc] init]; });
    return s;
}

// 反馈：按下收缩 → 松手回弹；图标淡入一枚绿对勾，1.1 秒后淡回原样。
// 旧版是把文字整个换成 ✓ 再换回来，硬切两下，看着很割裂。
- (void)celebrate:(UIButton *)b {
    UIImpactFeedbackGenerator *hap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [hap prepare];
    [hap impactOccurred];

    [UIView animateWithDuration:0.10 delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ b.transform = CGAffineTransformMakeScale(0.94, 0.94); }
                     completion:^(BOOL finished) {
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.9
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ b.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }];

    UIImageView *icon = (UIImageView *)[b viewWithTag:SLFakeTag + 3];
    if (!icon) return;
    UIImage *orig = icon.image;
    UIColor *origTint = icon.tintColor;
    UIImage *tick = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    if (!tick) return;

    __weak UIImageView *wicon = icon;
    [UIView transitionWithView:icon duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        icon.image = tick;
        icon.tintColor = [UIColor colorWithRed:0.30 green:0.92 blue:0.56 alpha:1.0];
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIImageView *v = wicon;
            if (!v) return;
            [UIView transitionWithView:v duration:0.22
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{
                v.image = orig;
                v.tintColor = origTint ?: [UIColor whiteColor];
            } completion:nil];
        });
    }];
}

- (void)tap:(UIButton *)b {
    NSDictionary *snap = SLFakeSnapshot(sSLFakeVC);
    if (!snap) {
        [AWECAUtils showToast:@"还没抓到这个人，等一下再点"];
        return;
    }

    SLApplySnap(snap);
    sSLWorkWant = SLSnapText(snap, @"uid") ?: sSLFakeUID;

    NSString *nick = SLSnapText(snap, @"nickname") ?: @"对方";
    SLLog(@"FAKE| 套用 %@ · 字段 %lu · 作品源 %@", nick, (unsigned long)snap.count,
          sSLWorkWant.length ? (sSLWorkSrc[sSLWorkWant] ? @"有" : @"无") : @"无");
    [AWECAUtils showToast:[NSString stringWithFormat:@"已套用 %@ · 回我页查看", nick]];

    [self celebrate:b];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (SLProfGate() || sSLProfOnMePage) {
            SLProfForceCover();
            SLProfPaintAvatar();
        }
    });
}
@end

static UIButton *SLFakeMake(void) {
    NSString *text = @"伪装主页";
    UIFont *font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    UIImage *icon = [[UIImage systemImageNamed:@"theatermasks.fill"]
                     imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!icon) {
        icon = [[UIImage systemImageNamed:@"theatermasks"]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    CGFloat iconW = icon ? 15.0 : 0.0;
    CGFloat gap = icon ? 4.0 : 0.0;
    CGSize ts = [text sizeWithAttributes:@{NSFontAttributeName: font}];
    CGFloat w = 10.0 + iconW + gap + ceil(ts.width) + 10.0;
    CGFloat h = 30.0;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = SLFakeTag;
    b.frame = CGRectMake(0, 0, w, h);
    b.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.frame = b.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    blur.layer.cornerRadius = h / 2.0;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.borderWidth = 0.5;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    blur.clipsToBounds = YES;
    [b addSubview:blur];

    CGFloat x = 10.0;
    if (icon) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
        iv.tag = SLFakeTag + 3;                 // 点按反馈时换成绿对勾
        iv.frame = CGRectMake(x, (h - iconW) / 2.0, iconW, iconW);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.tintColor = [UIColor whiteColor];
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];
        x += iconW + gap;
    }
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(x, 0, w - x - 10.0, h)];
    lab.tag = SLFakeTag + 1;
    lab.text = text;
    lab.textColor = [UIColor whiteColor];
    lab.font = font;
    lab.userInteractionEnabled = NO;
    [b addSubview:lab];

    [b addTarget:[SLFakeTarget shared] action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UIView *SLProfFindNavContainer(UIView *root) {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) isEqualToString:@"AWEProfileNavigationContainerView"]) return root;
    for (UIView *v in root.subviews) {
        UIView *r = SLProfFindNavContainer(v);
        if (r) return r;
    }
    return nil;
}

// 找导航容器里最靠左的那颗可点控件（就是返回按钮）
static UIView *SLProfFindLeftControl(UIView *root, UIView *host) {
    UIView *best = nil;
    CGFloat bestX = CGFLOAT_MAX;
    for (UIView *v in root.subviews) {
        if (v.tag == SLFakeTag) continue;
        CGRect r = [v convertRect:v.bounds toView:host];
        BOOL clickable = ([v isKindOfClass:[UIButton class]] || [v isKindOfClass:[UIControl class]]);
        if (clickable && !v.hidden && r.size.width >= 18 && r.size.width <= 130 && r.size.height >= 18) {
            if (r.origin.x < bestX) { bestX = r.origin.x; best = v; }
        }
        UIView *deep = SLProfFindLeftControl(v, host);
        if (deep) {
            CGRect dr = [deep convertRect:deep.bounds toView:host];
            if (dr.origin.x < bestX) { bestX = dr.origin.x; best = deep; }
        }
    }
    return best;
}

static void SLFakeRelayout(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            UIButton *pill = (UIButton *)[w viewWithTag:SLFakeTag];
            if (!pill || !pill.superview) continue;
            UIView *host = pill.superview;
            UIView *nav = SLProfFindNavContainer(host);
            UIView *anchor = nav ? SLProfFindLeftControl(nav, host) : nil;
            if (!anchor) continue;
            CGRect ar = [anchor convertRect:anchor.bounds toView:host];
            if (ar.size.height <= 0 || ar.size.width <= 0) continue;
            pill.frame = CGRectMake(CGRectGetMaxX(ar) + 8.0,
                                    CGRectGetMidY(ar) - pill.frame.size.height / 2.0,
                                    pill.frame.size.width, pill.frame.size.height);
        }
    }
}

static void SLFakeMount(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return;
    UIView *host = vc.view;
    if (!host.window) return;
    if ([host viewWithTag:SLFakeTag]) return;

    // 挂在页面根视图上（导航容器重写了 hitTest:，塞进去可能点不到），
    // 但位置跟着返回按钮走。
    UIButton *pill = SLFakeMake();
    [host addSubview:pill];

    UIView *nav = SLProfFindNavContainer(host);
    UIView *anchor = nav ? SLProfFindLeftControl(nav, host) : nil;
    if (anchor) {
        CGRect ar = [anchor convertRect:anchor.bounds toView:host];
        pill.frame = CGRectMake(CGRectGetMaxX(ar) + 8.0, CGRectGetMidY(ar) - 15.0,
                                pill.frame.size.width, 30.0);
    } else {
        pill.frame = CGRectMake(52.0, host.safeAreaInsets.top + 6.0,
                                pill.frame.size.width, 30.0);
    }

    SLLog(@"FAKE| 已挂「伪装主页」（anchor=%@ frame=%@）",
          anchor ? NSStringFromClass([anchor class]) : @"nil",
          NSStringFromCGRect(pill.frame));

    // 导航栏这一刻通常还没布局完，稍后再对一次位
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SLFakeRelayout(); });
}

// 导航栏滚动淡出时，自己那颗按钮跟着一起淡
static void (*o_navAlpha)(id, SEL, double, BOOL);
static void h_navAlpha(id self, SEL _cmd, double alpha, BOOL force) {
    if (o_navAlpha) o_navAlpha(self, _cmd, alpha, force);
    UIView *nav = (UIView *)self;
    UIView *pill = [nav.window viewWithTag:SLFakeTag];
    if (pill) pill.alpha = alpha;
}

static void (*o_detailAppear)(id, SEL, BOOL);
static void h_detailAppear(id self, SEL _cmd, BOOL animated) {
    if (o_detailAppear) o_detailAppear(self, _cmd, animated);
    __weak UIViewController *wvc = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *vc = wvc;
        if (!vc) return;
        id um = SLProfCallObj(vc, @"userModel");
        NSString *uid = SLFakeNumText(um ? SLProfCallObj(um, @"userID") : nil);
        sSLFakeUID = uid.length ? uid : nil;   // 取不到就清空，绝不沿用上一个人的
        sSLFakeVC = vc;
        // 详情页已经出现了，确保记账是开着的（封面/头像那几条都靠它判断「现在在谁的主页」）
        if (!sSLCapOn && SLProfPageKindSlow() == -1) sSLCapOn = YES;
        if (uid.length && um) {
            // 把对方真实 model 留一份：头像直接拿它的对象，类型天然对
            if (!sSLFakeUsers) sSLFakeUsers = [NSMutableDictionary dictionary];
            if (sSLFakeUsers.count > 12) [sSLFakeUsers removeAllObjects];
            sSLFakeUsers[uid] = um;
            // 封面那组模型对象也顺手抄一份（这一屏此刻就是他的）
            id pf = SLProfCallObj(um, @"profileCover");
            id cl = pf ? SLProfCallObj(pf, @"coverList") : nil;
            if ([cl isKindOfClass:[NSArray class]] && [(NSArray *)cl count]) {
                SLCoverRemember(uid, cl, SLProfCoverURL(cl));
            }
            SLFakeStore(uid, SLFakeHarvest(um));
        }
        SLFakeMount(vc);

        // 详情接口回来得晚，1.5 秒后再抄一遍，数字/背景图才齐
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *v2 = wvc;
            if (!v2) return;
            NSString *u2 = sSLFakeUID;
            if (!u2.length) return;
            id m2 = SLProfCallObj(v2, @"userModel");
            if (!m2) return;
            NSDictionary *hv = SLFakeHarvest(m2);
            if (hv.count) {
                SLFakeStore(u2, hv);
                SLLog(@"FAKE| 补抓 %@：%@ 项（%@）", u2, @(hv.count), hv[@"cover"] ? @"含背景" : @"无背景");
            }
        });
    });
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

    // 头图 / 头像在页面出现时可能已经按真实资料配好了，这里补一次：
    // 先让页面把数据渲染完，再换成对方的（只在我页且门开着时才动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!SLProfGate()) return;
        SLProfForceCover();
        SLProfPaintAvatar();
        SLProfReloadListOnce();
    });
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

    // 获赞 / 互关 / 朋友 / 作品 / 粉丝 / 关注：数字由各自的统计组件算，截这里才改得动
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticPraiseComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_praiseText, (IMP *)&o_praiseText, @"praise.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticMutualComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_mutualText, (IMP *)&o_mutualText, @"mutual.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticFriendComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_friendText, (IMP *)&o_friendText, @"friend.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticPlayComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_playText, (IMP *)&o_playText, @"play.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticFansComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_fansText, (IMP *)&o_fansText, @"fans.displayCount");
    SLProfHookOneObj(objc_getClass("AWEProfileSocialStatisticFollowComponent"),
                     NSSelectorFromString(@"displayCountForItem:"),
                     (IMP)h_followText, (IMP *)&o_followText, @"follow.displayCount");

    // 主页背景图：别人主页把 coverList 模型对象留住，自己主页原样喂回去
    {
        Class cover = objc_getClass("AWEProfileBannerBGCoverView");
        Method l = cover ? SLProfExact(cover, NSSelectorFromString(@"configWithCoverList:")) : NULL;
        if (l && method_getNumberOfArguments(l) == 3) {
            o_coverList = (void (*)(id, SEL, id))method_getImplementation(l);
            method_setImplementation(l, (IMP)h_coverList);
            SLLog(@"PROF| 已挂 cover.configCoverList @ AWEProfileBannerBGCoverView");
        } else {
            SLLog(@"PROF| 跳过 cover.configCoverList：类或方法不存在");
        }
        Method m = cover ? SLProfExact(cover, NSSelectorFromString(@"configWithURLList:lightColorList:darkColorList:")) : NULL;
        if (m && method_getNumberOfArguments(m) == 5) {
            o_coverConfig = (void (*)(id, SEL, id, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)h_coverConfig);
            SLLog(@"PROF| 已挂 cover.configURLList @ AWEProfileBannerBGCoverView");
        } else {
            SLLog(@"PROF| 跳过 cover.configURLList：类或方法不存在");
        }
    }

    // 头像：我页读头像时返回对方 model 的那份对象
    {
        Class user2 = objc_getClass("AWEUserModel");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatarThumb"),
                         (IMP)h_avThumb, (IMP *)&o_avThumb, @"avatarThumb");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatarMedium"),
                         (IMP)h_avMedium, (IMP *)&o_avMedium, @"avatarMedium");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatarLarge"),
                         (IMP)h_avLarge, (IMP *)&o_avLarge, @"avatarLarge");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatar168"),
                         (IMP)h_av168, (IMP *)&o_av168, @"avatar168");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatar300"),
                         (IMP)h_av300, (IMP *)&o_av300, @"avatar300");
    }

    // 别人主页：挂 viewDidAppear:，把「伪装主页」胶囊挂上去
    {
        Class detail = objc_getClass("AWEUserDetailViewControllerV2");
        Method m = detail ? SLProfExact(detail, @selector(viewDidAppear:)) : NULL;
        if (m) {
            o_detailAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
            method_setImplementation(m, (IMP)h_detailAppear);
            SLLog(@"PROF| 已挂 viewDidAppear: @ AWEUserDetailViewControllerV2（伪装主页）");
        } else {
            SLLog(@"PROF| 跳过伪装主页：AWEUserDetailViewControllerV2 无 viewDidAppear:");
        }
        // 导航栏淡出时把我们的按钮一起带走
        Class nav = objc_getClass("AWEProfileNavigationContainerView");
        Method nm = nav ? SLProfExact(nav, NSSelectorFromString(@"updateWithAlpha:force:")) : NULL;
        if (nm && method_getNumberOfArguments(nm) == 4) {
            o_navAlpha = (void (*)(id, SEL, double, BOOL))method_getImplementation(nm);
            method_setImplementation(nm, (IMP)h_navAlpha);
            SLLog(@"PROF| 已挂 nav.updateWithAlpha:force:");
        } else {
            SLLog(@"PROF| 跳过 nav.opacity：没有 updateWithAlpha:force:");
        }
    }

    // 作品列表（含每条封面的播放量）：别人主页记住 dataSource，我页换成他的
    {
        Class posts = objc_getClass("AWEUserPostsDataManager");
        if (posts) {
            // 记下这个 data manager 属于谁
            Method im = SLProfExact(posts, NSSelectorFromString(@"initWithUserID:secUserID:"));
            if (im && method_getNumberOfArguments(im) == 4) {
                o_postsInit = (id (*)(id, SEL, id, id))method_getImplementation(im);
                method_setImplementation(im, (IMP)h_postsInit);
                SLLog(@"PROF| 已挂 posts.initWithUserID:secUserID:");
            }
            Method sd = SLProfExact(posts, NSSelectorFromString(@"setDataSource:"));
            if (sd && method_getNumberOfArguments(sd) == 3) {
                o_postsSetDS = (void (*)(id, SEL, id))method_getImplementation(sd);
                method_setImplementation(sd, (IMP)h_postsSetDS);
                SLLog(@"PROF| 已挂 posts.setDataSource:");
            }
            Method gd = SLProfExact(posts, NSSelectorFromString(@"dataSource"));
            if (gd) {
                SLProfHookGetter(posts, NSSelectorFromString(@"dataSource"),
                                 (IMP)h_postsDS, (IMP *)&o_postsDS, @"posts.dataSource");
            }
        } else {
            SLLog(@"PROF| 跳过作品列表：AWEUserPostsDataManager 不存在");
        }
    }

    // 「我」页容器：挂 appear / disappear 当第二道门，并留下现场日志
    SLProfHookPageLifecycle(objc_getClass("AWEProfileTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileMergedTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileBaseContainerViewController"));

    SLLog(@"PROF| ==== 主页伪装 v0.8.8 · 开=%d · 已填 %ld 项 · 快照 %lu 个 ====",
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
    if (s == 0) return 2;
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
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.tag = ip.row;
        sw.on = (ip.row == 0) ? SLProfileEnabled() : SLProfWorksEnabled();
        [sw addTarget:self action:@selector(sl_toggle:) forControlEvents:UIControlEventValueChanged];
        cell.textLabel.text = (ip.row == 0) ? @"启用" : @"模拟作品与播放量";
        if (ip.row == 1) {
            cell.detailTextLabel.text = @"需先看过对方主页";
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        }
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
    if (sw.tag == 1) {
        [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:SLProfKeyWorks];
        SLLog(@"PROF| 模拟作品与播放量 = %d", sw.on);
        return;
    }
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
    if (ip.section != 0 || ip.row != 0) return nil;
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
    NSString *v = nil;
    if ((v = SLSnapText(s, @"follower")))  [sub addObject:[NSString stringWithFormat:@"粉 %@", v]];
    if ((v = SLSnapText(s, @"following"))) [sub addObject:[NSString stringWithFormat:@"关 %@", v]];
    if ((v = SLSnapText(s, @"aweme")))     [sub addObject:[NSString stringWithFormat:@"作 %@", v]];
    if ((v = SLSnapText(s, @"like")))      [sub addObject:[NSString stringWithFormat:@"赞 %@", v]];
    if ((v = SLSnapText(s, @"friend")))    [sub addObject:[NSString stringWithFormat:@"互 %@", v]];
    if (SLSnapText(s, @"cover"))           [sub addObject:@"带背景"];
    NSString *uid = SLSnapText(s, @"uniqueID");
    if (uid.length) [sub addObject:[NSString stringWithFormat:@"号 %@", uid]];

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
