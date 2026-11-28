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
//  v0.8.9：
//    · 预设按账号分家（SLProf.xxx.<我的uid>）：A 号伪装谁、B 号伪装谁互不影响，切号不清空
//    · 身份硬闸：model.userID 必须等于当前账号才替换 —— 修「进抖音第一个视频的 id 变伪装 id」
//    · 背景图找准真身：profileCover 本身就是 NSArray<AWEProfileCoverURLModel>，
//      之前按 coverList 多挖一层所以永远拿不到；现在 URL 落盘、重启也能重建
//    · 头像补齐 avatarLarger（39.9.0 就叫这个，avatarLarge 根本不存在），重启后用保存的 URL 重建
//    · 作品：换掉 dataSource 后不再只对 collectionView reloadData，
//      改为调作品页自己的 reloadDataWithDataSourceChanged，九宫格才会真的重建
//    · 新增专属会员 / 群聊 / 橱窗：抓对方 model 上的 hasMembership / canShowGroupCard /
//      withShopEntry 等开关，套用时打开
//    · 设置页去掉「从他人主页套用」列表（伪装主页按钮已经覆盖），新增三枚标识开关
//
//  v0.9.0：
//    · 作品改成「联网按对方的 id 拉」：把我的 AWEUserPostsDataManager 请求参数
//      （userID / secUserID / commonParams）换成对方的，服务器直接返回对方那一整套，
//      排序、分页、每条播放量都是原生的；重启也在（不再依赖内存里偷来的 dataSource）
//    · 背景图改成把对方的图直接喂给封面视图（-configWithImage:）。
//      0.8.9 自己 KVC 拼了一个 AWEProfileCoverURLModel 喂回去 —— 渲染链不认，所以看不见；
//      换号时它也是最容易炸的一处，已删掉
//    · 一块伪装：性别 / 年龄 / 城市 / 省份 / 区县 / IP 属地 / 认证信息 / 学校
//    · 删掉专属会员 / 群聊 / 橱窗：这三样交给抖音自己的设置，本插件不再插手
//    · 获赞经常失效：统计组件的门改成「我页出现就一直开着」的闩，不再被页面切换的 0.15s 缓存漏掉
//    · 换号闪退：所有视图树/窗口枚举都先 copy 一份（抖音换号时正在拆窗口，
//      边拆边遍历会抛「collection was mutated」），并加了未捕获异常落盘
//
//  v0.9.1：
//    · 背景图不稳：抖音自己那份封面图也是异步下的，谁后到谁说话 —— 它经常后到，
//      于是闪一下又变回自己的。现在图下完就进内存 + 磁盘缓存，封面视图每次
//      layoutSubviews 之后都再确认一次，不管它什么时候刷回去都能按住
//    · 作品不稳 / 重进就没了 / 播放量不同步：0.9.0 只从自己记的 manager 里挑，
//      而页面用的是 copy 出来的副本（没有 uid 标记），一个都挑不到，刷新压根没发出去。
//      改成直接找 AWEPostWorkViewControllerV2 调 refreshDataWithCompletion:，
//      请求参数在 commonParams 那层换成对方的；拉完再核对首条作者，不对就补一枪
//    · 性别 / 年龄 / 所在地：那一排是 header 的 AgeAndLocation cell 自己拼的标题，
//      不读 model getter。改成在它 configWithHeaderContext: 之后直接改按钮标题
//    · 新增「隐藏私密作品」开关：过滤 dataSource 里的私密条目，并收起「私密作品」入口
//    · 过亿的获赞：在 header 统计 cell 的 updateXxxCount: 再兜一层（最后一环）
//    · 换号后打一行「本账号预设」，一眼能看出这个号到底存了什么
//
//  v0.9.2：这一版只干一件事 —— 让「应用」这件事不依赖某个 callback 恰好触发
//
//    真机日志里最要命的一条：整场都没有 `PROF| 进入本人主页`。
//    也就是说 AWEProfileTabContainerViewController / Merged 的 viewDidAppear:
//    在 39.9.0 这次根本没被调到（页面早就在，或者换了容器），
//    于是挂在它后面的那串「0.55s / 1.45s / 2.35s 补三遍」一次都没跑：
//    背景图没人补、年龄地区没人改、私密入口没人收、作品也没人去踢。
//    v0.9.1 加的那些功能其实都挂上了，就是没人按开关。
//
//    · 新增 0.8s 的驻留巡检（只在「我」页且总开关打开时干活）：
//      封面复贴 / 年龄·地区·学校 / 私密入口 / 头像 / 作品重拉，按需补齐。
//      每条都有「已经对了就不再动」的短路，空转成本约等于一次 subviews 遍历
//    · 背景图改成按账号落一张原图（acct-cover-<我的uid>）：
//      抖音的封面 URL 带签名会过期，重启后旧 URL 下不动 → 背景就没了；
//      点「伪装主页」时就把原图存下来，之后永远从本地这张贴
//    · 年龄 / 地区：不再只认 genderAndAgeButton 这几个名字。
//      拿「我」自己的 model 读真实文本（男 / 女 / 22岁 / 广东 …），
//      在 cell 里按**文本内容**比对替换，改名了也照样对得上
//    · 过亿的获赞：displayCountForItem: 到一定量级返回的是富文本（NSAttributedString），
//      旧代码遇到非 NSString/NSNumber 一律原样放行 —— 所以一亿以上永远同步不过来。
//      现在按原富文本的字体颜色重建一份
//    · 隐藏私密作品：门从「必须正停在我页」放宽到「我页出现过」，
//      面板里一拨开关就立刻生效；「私密」那个小标签也一起收掉
//    · 换号：清掉上个号缓存的我 model / 封面图 / 已应用标记，
//      巡检下一拍就按新号的预设重来；作品那边也不再因为「已刷过」而跳过
//
//  v0.9.6：别再主动去踢作品刷新了
//
//    0.9.5 的日志：11:32:38 进「我」页，同一个 tick 里打完
//    `已让作品页按对方 id（…）重新拉取`，下一秒进程就没了（11:32:40 是新进程）。
//    同一份日志里还有一条更关键的：
//        WORKS| 作品请求改用对方 id 1638739731022221（联网拉取）
//    它出现在「重新拉取」**之前** —— 说明页面自己那次首刷已经把 id 换成对方的了，
//    我们再补一脚纯属多余，而且是「首刷还在飞的时候再来一次」：
//    两个请求回来各改一次同一个 dataSource，IGListKit / collectionView 对不上账，
//    直接硬崩（不是 ObjC 异常，所以连 CRASH| 都没留下）。
//
//    这一版：
//    · 不再「进页就踢」。先看列表：已经是对方的那份 → 什么都不做；
//      还是空的 → 说明首刷在路上，等 8 秒；只有「已经拉回来、但首条作者不是对方」
//      才补一次，且每代只补一次
//    · 补的时候先落一个面包屑文件（.prof_step）。硬崩没有异常栈，
//      下次启动读到它就知道「上一轮死在作品重拉之后」——这一轮干脆不再踢（参数替换照旧）
//    · 0.9.5 里「列表 0 条就 1.2 秒后再补一枪」已删：首刷没回来时那是最容易并发改表的一脚
//

#import "SLProfile.h"
#import "SLLog.h"
#import "SLGlass.h"
#import "AWECAUtils.h"

#import <objc/runtime.h>
#import <objc/message.h>

#define SLProfVersion      @"0.9.8"          // 与 control / SLSettingsPanel 同步
#define SLProfKeyEnabled   @"SLProf.enabled"
#define SLProfKeyNickname  @"SLProf.nickname"
#define SLProfKeyUID       @"SLProf.uid"
#define SLProfKeySignature @"SLProf.signature"
#define SLProfKeyAweme     @"SLProf.aweme"
#define SLProfKeyFollowing @"SLProf.following"
#define SLProfKeyFollower  @"SLProf.follower"
#define SLProfKeyLike      @"SLProf.like"       // 获赞
#define SLProfKeyFriend    @"SLProf.friend"     // 互关
#define SLProfKeyPlay      @"SLProf.play"       // 主页作品播放量（和作品数分开，别混用）
#define SLProfKeyCover     @"SLProf.coverURL"   // 主页背景图（封面）URL
#define SLProfKeyCoverLight @"SLProf.coverLight" // 封面浅色蒙层色（抖音自己算的，原样回传）
#define SLProfKeyCoverDark @"SLProf.coverDark"   // 封面深色蒙层色
#define SLProfKeyAvatar    @"SLProf.avatarURL"  // 头像 URL
#define SLProfKeyWant      @"SLProf.want"       // 这个账号要模拟谁（作品/封面/头像都照这个来）
#define SLProfKeySec       @"SLProf.sec"        // 对方的 sec_user_id（联网拉作品要用）
#define SLProfKeyGender    @"SLProf.gender"     // 性别（1 男 / 2 女）
#define SLProfKeyAge       @"SLProf.age"        // 年龄
#define SLProfKeyGenderTxt @"SLProf.genderText" // 「女 · 22岁」这种现成字符串
#define SLProfKeyExtra     @"SLProf.extra"      // 地区 / 认证 / 学校等一揽子文本字段
#define SLProfKeyWorks     @"SLProf.works"      // 模拟作品与播放量
#define SLProfKeyHidePriv  @"SLProf.hidePrivate" // 隐藏私密作品（我页里不显示自己的私密作品）
#define SLProfKeyOwner     @"SLProf.ownerUid"   // 旧版单账号绑定，仅用于把老预设迁到分账号存储

static volatile BOOL sSLProfOnMePage = NO;   // 「我」页可见期间为 YES
static BOOL sSLProfStarted  = NO;
static int  sSLProfHits     = 0;
static int  sSLProfMissLogged = 0;  // 门未开的诊断日志，最多打几条

static id SLProfCallObj(id obj, NSString *selName);   // 定义在「页面判定」段，快照要用
static BOOL SLProfGate(void);                         // 定义在「页面判定」段，套用快照时要用
static void SLProfForceCover(void);                   // 定义在「封面」段，套用后用
static NSString *sSLWorkWant = nil;                   // 要模拟谁（每个账号各自一份，落盘）
static NSString *sSLProfMyUID = nil;                  // 当前登录账号的 uid（在「我」页读到）
static NSString *sSLCurAcct = nil;                    // 当前生效的账号 uid：所有预设键都按它分家
static NSMutableDictionary *sSLCoverObjs = nil;       // uid -> 对方真实 coverList（模型对象）
static NSMutableDictionary *sSLFakeUsers = nil;       // uid -> 对方真实 AWEUserModel（头像用）
static void SLProfResetPainted(void);                 // 还原被我们直接改过图的视图
static void SLApplySnapExtras(NSDictionary *snap);    // 定义在「性别 / 地区」段，套用快照时要用
static NSString *SLExtraStr(NSString *field);         // 同上，日志里要打地区
static void SLProfCoverPrefetch(void);                // 定义在「封面」段，套用后先把原图存一份
static int sSLWorksGen = 0;                           // 每次套用 +1（作品列表重拉用）
static int sSLPostsMgrLog = 0;                        // 作品管理器记录日志（限几条）
static NSString *sSLCoverWantURL = nil;               // 当前应该显示的封面 URL
static UIImage  *sSLCoverWantImg = nil;               // 下好之后的那张图
static NSString *sSLCoverAcctKey = nil;               // 本机原图对应的文件路径（按 want 分文件）
static UIImage  *sSLCoverAcctImg = nil;               // 本机原图（内存里留一份，别每拍都读盘）
static int sSLCoverMissLog = 0;                        // 「没找到封面视图」的日志上限
static id sSLMyModel = nil;                            // 「我」页那个 model（读真实文本做比对）
static NSTimeInterval sSLOnMeSince = 0;                // 这一轮停在我页的起始时刻（别和首刷撞车）
static BOOL sSLWasOnMe = NO;                           // 上一拍是否停在「我」页
static int  sSLTickCount = 0;                          // 巡检计数
static int  sSLOffTicks = 0;                           // 连续几拍不在我页
static void SLProfTick(void);                          // 定义在「驻留巡检」段
static void SLProfCollectVCs(UIViewController *vc, NSMutableArray *out);   // 定义在「作品」段，header 扫描要用
static void SLProfStep(NSString *name);                // 定义在「面包屑」段，换号时先留记号
static void SLProfStepDone(NSString *name);

#pragma mark - 配置（按账号分家）
//
// v0.8.9 起所有预设都带账号后缀：SLProf.nickname.<我的uid>。
// 换号只是换一组键，A 号伪装成谁、B 号伪装成谁互不影响，也不会互相清空。
// 旧版只有一套全局键 + SLProf.ownerUid，启动时一次性迁到 owner 名下。

static NSString *SLProfRawStr(NSString *key) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return v.length ? v : nil;
}

static NSString *SLProfScopedKey(NSString *key) {
    if (!sSLCurAcct.length) return key;
    return [NSString stringWithFormat:@"%@.%@", key, sSLCurAcct];
}

static NSString *SLProfStr(NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (sSLCurAcct.length) {
        NSString *v = [d stringForKey:SLProfScopedKey(key)];
        if (v.length) return v;
    }
    return SLProfRawStr(key);      // 还没认到账号 / 老数据兜底
}

static void SLProfSetStr(NSString *value, NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *k = SLProfScopedKey(key);
    if (value.length) [d setObject:value forKey:k];
    else [d removeObjectForKey:k];
    if (sSLCurAcct.length) [d removeObjectForKey:key];   // 分账号后老的全局键作废，免得串号
    [d synchronize];
}

// 按**指定账号**读预设，不切换「当前账号」。
// 用途：抖音的账号切换面板会同时渲染好几个号的 model，原来只有当前登录的那个有伪装，
// 其余的（没被切到的号）全还原成真名真头像 —— 用户截图里就是这个现象。
// 这里让每个号都用自己的那份预设，判断依据是「这个 uid 名下有没有存过伪装」。
static NSString *SLProfStrForUID(NSString *key, NSString *uid) {
    if (!key.length || !uid.length) return nil;
    NSString *v = [[NSUserDefaults standardUserDefaults]
                   stringForKey:[NSString stringWithFormat:@"%@.%@", key, uid]];
    return v.length ? v : nil;
}

static BOOL SLProfBool(NSString *key, BOOL def) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = nil;
    if (sSLCurAcct.length) v = [d objectForKey:SLProfScopedKey(key)];
    if (!v) v = [d objectForKey:key];
    return v ? [v boolValue] : def;
}

static void SLProfSetBool(BOOL on, NSString *key) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:@(on) forKey:SLProfScopedKey(key)];
    if (sSLCurAcct.length) [d removeObjectForKey:key];
    [d synchronize];
}

BOOL SLProfileEnabled(void) {
    return SLProfBool(SLProfKeyEnabled, NO);
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
    NSArray *keys = @[SLProfKeyNickname, SLProfKeyUID, SLProfKeySignature,
                      SLProfKeyAweme, SLProfKeyFollowing, SLProfKeyFollower,
                      SLProfKeyLike, SLProfKeyFriend, SLProfKeyCover, SLProfKeyCoverLight,
                      SLProfKeyCoverDark, SLProfKeyAvatar, SLProfKeyWant,
                      SLProfKeySec, SLProfKeyGender, SLProfKeyAge, SLProfKeyGenderTxt,
                      SLProfKeyExtra, SLProfKeyWorks, SLProfKeyHidePriv, SLProfKeyEnabled];
    for (NSString *k in keys) {
        [d removeObjectForKey:SLProfScopedKey(k)];
        [d removeObjectForKey:k];
    }
    [d synchronize];
    sSLWorkWant = nil;
    SLLog(@"PROF| 已清空账号 %@ 的全部预设值", sSLCurAcct ?: @"(未识别)");
}

// 旧版只有一套全局预设 + ownerUid。第一次跑新版时整体搬到 owner 名下，
// 之后每个账号只认自己那份，换号不会把数据带走，也不会清掉。
static void SLProfMigrateLegacy(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *owner = [d stringForKey:SLProfKeyOwner];
    if (!owner.length) return;
    NSString *guard = [NSString stringWithFormat:@"SLProf.migrated.%@", owner];
    if ([d boolForKey:guard]) return;
    [d setBool:YES forKey:guard];

    NSArray *keys = @[SLProfKeyNickname, SLProfKeyUID, SLProfKeySignature,
                      SLProfKeyAweme, SLProfKeyFollowing, SLProfKeyFollower,
                      SLProfKeyLike, SLProfKeyFriend, SLProfKeyCover, SLProfKeyAvatar,
                      SLProfKeyEnabled, SLProfKeyWorks];
    NSUInteger n = 0;
    for (NSString *k in keys) {
        id v = [d objectForKey:k];
        if (!v) continue;
        [d setObject:v forKey:[NSString stringWithFormat:@"%@.%@", k, owner]];
        [d removeObjectForKey:k];
        n++;
    }
    [d synchronize];
    if (n) SLLog(@"PROF| 已把 %lu 项旧预设迁到账号 %@ 名下", (unsigned long)n, owner);
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

// 把一份快照整套写进**当前账号**的预设（只写抓到了的字段，缺的不去动原有值）
static void SLApplySnap(NSDictionary *s) {
    SLProfSetStr(SLSnapText(s, @"nickname"),  SLProfKeyNickname);
    SLProfSetStr(SLSnapText(s, @"uniqueID"),  SLProfKeyUID);
    SLProfSetStr(SLSnapText(s, @"signature"), SLProfKeySignature);
    SLProfSetStr(SLSnapText(s, @"aweme"),     SLProfKeyAweme);
    SLProfSetStr(SLSnapText(s, @"following"), SLProfKeyFollowing);
    SLProfSetStr(SLSnapText(s, @"follower"),  SLProfKeyFollower);
    SLProfSetStr(SLSnapText(s, @"like"),      SLProfKeyLike);
    SLProfSetStr(SLSnapText(s, @"friend"),    SLProfKeyFriend);
    SLProfSetStr(SLSnapText(s, @"play"),      SLProfKeyPlay);
    SLProfSetStr(SLSnapText(s, @"cover"),     SLProfKeyCover);
    SLProfSetStr(SLSnapText(s, @"coverLight"), SLProfKeyCoverLight);
    SLProfSetStr(SLSnapText(s, @"coverDark"), SLProfKeyCoverDark);
    SLProfSetStr(SLSnapText(s, @"avatar"),    SLProfKeyAvatar);
    SLProfSetStr(SLSnapText(s, @"sec"),       SLProfKeySec);      // 联网拉作品要用
    // 0.9.8：性别 / 年龄以**设置页手填的**为准。
    // 别人的主页现在基本不公开这几项（只有「+ 添加性别等标签」和 IP 属地），
    // 从那边抓回来的多半是空，却把手填的值一并覆盖了 —— 所以只在本地没设过时才补。
    if (!SLProfStr(SLProfKeyGender).length)
        SLProfSetStr(SLSnapText(s, @"gender"), SLProfKeyGender);
    if (!SLProfStr(SLProfKeyAge).length)
        SLProfSetStr(SLSnapText(s, @"age"), SLProfKeyAge);
    if (!SLProfStr(SLProfKeyGenderTxt).length)
        SLProfSetStr(SLSnapText(s, @"genderText"), SLProfKeyGenderTxt);
    SLApplySnapExtras(s);                                       // 地区 / 认证 / 学校
    NSString *uid = SLSnapText(s, @"uid");
    if (uid.length) SLProfSetStr(uid, SLProfKeyWant);   // 作品/封面/头像都照这个人的来
    sSLWorkWant = uid;

    SLProfSetBool(YES, SLProfKeyEnabled);

    sSLWorksGen++;
    SLLog(@"SNAP| 套用 %@ 的整套资料（账号 %@）", SLSnapText(s, @"nickname") ?: @"?", sSLCurAcct ?: @"?");
    if (SLProfGate()) SLProfForceCover();               // 若此刻正停在「我」页，立刻换背景
    SLProfCoverPrefetch();                              // 顺手把原图存到本机（封面的 URL 会过期）
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

// 返回整数、无参数
static void SLProfHookIntGetter(Class cls, SEL sel, IMP imp, IMP *slot, NSString *tag) {
    if (!cls) { SLLog(@"PROF| 跳过 %@：类不存在", tag); return; }
    Method m = SLProfExact(cls, sel);
    if (!m) { SLLog(@"PROF| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    char *ret = method_copyReturnType(m);
    char c = ret ? ret[0] : 0;
    if (ret) free(ret);
    if (c != 'q' && c != 'Q' && c != 'i' && c != 'I' && c != 'l' && c != 'L') {
        SLLog(@"PROF| 跳过 %@：返回值不是整数", tag);
        return;
    }
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
        for (UIWindow *w in [ws.windows copy]) {
            if (w.isKeyWindow) { cand = w; break; }
        }
        if (!cand) {
            for (UIWindow *w in [ws.windows copy]) {
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

// 读一个返回 NSInteger 的 getter（性别 / 年龄都是这种）
static NSInteger SLProfCallInt(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || !sel || ![obj respondsToSelector:sel]) return 0;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) return 0;
    return ((NSInteger (*)(id, SEL))method_getImplementation(m))(obj, sel);
}

// 读到「我」页 model 的 uid 就切换当前账号：预设按账号各存一份，换号不会串也不会清。
static void SLProfSetAcct(NSString *uid) {
    if (!uid.length || [uid isEqualToString:@"0"]) return;
    if ([sSLCurAcct isEqualToString:uid]) return;
    sSLCurAcct = [uid copy];
    SLProfStep(@"acct.switch");     // 换号是目前最容易硬崩的一下，先留记号（崩了下次启动能看到）

    // 老版本没写过 owner（更早的安装）：第一次认到账号时把全局预设归到它名下
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d stringForKey:SLProfKeyOwner].length) {
        [d setObject:uid forKey:SLProfKeyOwner];
        SLProfMigrateLegacy();
    }

    // 这个账号自己要模拟谁 —— 落盘过，重启也还在（作品源仍需本次运行里看过对方主页）
    sSLWorkWant = SLProfStr(SLProfKeyWant);
    sSLWorksGen++;                 // 换号后作品列表也要按新账号重判一次
    sSLPostsMgrLog = 0;
    // 换号那一刻抖音正在重建整页；这里同步去「还原被我们改过的图」很容易撞在渲染中途，
    // 用户反馈的「切换账号刷新主页会闪退」有一半可能出在这。改成延后一拍。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SLProfResetPainted(); });
    sSLProfHits = 0;
    sSLCoverWantURL = nil;
    sSLCoverWantImg = nil;
    sSLCoverAcctKey = nil;          // 封面原图按账号分文件，换号必须丢掉上一个号的
    sSLCoverAcctImg = nil;
    sSLCoverMissLog = 0;
    sSLMyModel = nil;               // 换号了，上一个号的真实资料不能拿来比对
    sSLWasOnMe = NO;                // 巡检下一拍按新号重来

    SLLog(@"PROF| 已切到账号 %@（预设按账号独立，互不清空）", uid);
    SLLog(@"PROF| 本账号预设：昵称=%@ 赞=%@ 性别=%@ 年龄=%@ 地区=%@ 背景=%@ 头像=%@ 作品源=%@",
          SLProfStr(SLProfKeyNickname) ?: @"无",
          SLProfStr(SLProfKeyLike) ?: @"无",
          SLProfStr(SLProfKeyGender) ?: @"无",
          SLProfStr(SLProfKeyAge) ?: @"无",
          SLExtraStr(@"city") ?: SLExtraStr(@"location") ?: @"无",
          SLProfStr(SLProfKeyCover) ?: @"无",
          SLProfStr(SLProfKeyAvatar) ?: @"无",
          sSLWorkWant ?: @"无");

    // 换号后马上按新号补一轮，不用等用户离开再回来
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SLProfTick(); });
    // 页面重建大概 1~2 秒，过了这个窗口还没崩才算安全
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SLProfStepDone(@"acct.switch"); });
}

// 在「我」页记下当前登录账号的 uid
static void SLProfNoteMyUID(UIViewController *vc) {
    id um = SLProfCallObj(vc, @"userModel");
    id uid = um ? SLProfCallObj(um, @"userID") : nil;
    NSString *s = nil;
    if ([uid isKindOfClass:[NSString class]]) s = uid;
    else if ([uid isKindOfClass:[NSNumber class]]) s = [uid stringValue];
    if (s.length && ![s isEqualToString:@"0"]) {
        sSLProfMyUID = s;
        SLProfSetAcct(s);
        // 注意顺序：SLProfSetAcct 内部会清 sSLMyModel（换号了，旧 model 不能拿来比对），
        // 所以必须在它之后再把这一次的 model 存下来。
        // 原来写在前面，首次进「我」页时刚存就被清掉 —— 于是「按真实文本比对」永远
        // 拿不到真实值，年龄 / 地区 / 学校一条都改不动。
        if (um && sSLMyModel != um) sSLMyModel = um;
    }
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
    static BOOL sInKind = NO;
    if (sInKind) return sSLProfKindVal;      // 防止 isCurrentUserProfilePage 内部回调 getter 时递归
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now < sSLProfGateUntil) return sSLProfKindVal;

    int prev = sSLProfKindVal;
    UIViewController *top = SLProfTopVC();
    sSLProfTopIsOurs = top ? [NSStringFromClass([top class]) hasPrefix:@"SL"] : NO;
    sSLProfGateUntil = now + 0.15;           // 先占住缓存窗口，再往下问页面
    sInKind = YES;
    sSLProfKindVal = SLProfPageKindSlow();
    sInKind = NO;

    if (sSLProfKindVal != prev) {
        if (sSLProfKindVal == -1) SLCapBegin();        // 进别人主页，开始记账
        else if (prev == -1) SLCapFinish();            // 离开，落盘
    }
    SLProfNotePageChange(sSLProfKindVal);
    return sSLProfKindVal;
}

// 这个 model 是不是「我自己」。
//
// v0.8.9 加的硬闸：getter 是全局的，只靠「当前页面是本人主页」判断，
// 信息流预加载 / 首刷视频的作者 model 也会被替换 —— 用户反馈的
// 「进抖音第一个视频的 id 变成伪装的」就是这么来的。
// 现在要求 model.userID == 当前登录账号，别人的 model 一律原样返回。
static BOOL SLProfIsMe(id model) {
    if (!model || !sSLProfMyUID.length) return NO;
    id uidObj = SLProfCallObj(model, @"userID");
    NSString *uid = nil;
    if ([uidObj isKindOfClass:[NSString class]]) uid = uidObj;
    else if ([uidObj isKindOfClass:[NSNumber class]]) uid = [uidObj stringValue];
    return uid.length > 0 && [uid isEqualToString:sSLProfMyUID];
}

// 只在「确认是本人主页」时开门。
// v0.8.4 之前 kind 认不出来时会沿用上一次的状态，结果在信息流/消息页也继续替换，
// 变成「所有人的名字都一样」——这里改成严格模式：认不出来就是关。
// 唯一例外：自己弹出的面板（类名 SL 开头）盖在「我」页上时，沿用上一次的状态，
// 否则面板一开、背后的主页就闪回真实资料。
static BOOL SLProfGate(void) {
    // 先认页面 —— 顺带把「当前登录的是哪个账号」认出来。
    // 顺序很重要：预设按账号分家，没认出账号就读不到本账号的「启用」开关，
    // 一旦先判开关就会永远关着（0.8.9 初版的坑）。
    int kind = [NSThread isMainThread] ? SLProfPageKind() : sSLProfKindVal;
    if (!SLProfileEnabled()) return NO;
    if (kind == 1) {
        sSLProfOnMePage = YES;
        // 换号后第一次进我页：把「要模拟谁」换成本账号自己的那份
        if (!sSLWorkWant.length) sSLWorkWant = SLProfStr(SLProfKeyWant);
        return YES;
    }
    if (kind == 0 && sSLProfOnMePage && sSLProfTopIsOurs) return YES;
    sSLProfOnMePage = NO;
    return NO;
}

// 统计组件 / 模型字段用的松门：只要「我页出现过、还没离开」就算开着。
// 严格门要每次现算页面，页面切换那 0.15 秒缓存里会返回 0，
// 而获赞那种一屏只渲染一次的字段一旦赶上就永远是真实值 —— 这就是「获赞经常失效」。
static BOOL SLProfGateLoose(void) {
    if ([NSThread isMainThread]) SLProfPageKind();   // 顺带把账号认出来
    if (!SLProfileEnabled()) return NO;
    // 明确站在别人主页上：立刻收手。
    // 原来只看「我页出现过」的闩，滑到别人主页后闩还开着 ——
    // 别人的作品会被按伪装对象再换一次，切回自己号时数据就串了。
    if (sSLProfKindVal == -1) { sSLProfOnMePage = NO; return NO; }
    return sSLProfOnMePage || sSLProfKindVal == 1;
}

// 门没开时记一笔，用来确认 getter 到底有没有在渲染时被调用（限 12 条）
static void SLProfNoteMiss(NSString *tag) {
    if (sSLProfMissLogged >= 12) return;
    sSLProfMissLogged++;
    SLLog(@"PROF| %@ 被调（门未开）", tag);
}

#pragma mark - 字符串字段

// 从 model 上取 uid（NSString / NSNumber 两种都接）
static NSString *SLProfModelUID(id model) {
    id u = SLProfCallObj(model, @"userID");
    if ([u isKindOfClass:[NSString class]]) return [(NSString *)u length] ? u : nil;
    if ([u isKindOfClass:[NSNumber class]]) return [(NSNumber *)u stringValue];
    return nil;
}

// 不是当前登录号、但自己名下也存过伪装 —— 抖音的账号切换面板会同时渲染好几个号的 model，
// 原来只有「当前这个」有伪装，没切到的号全还原成真名真头像（用户截图就是这个）。
// 这里只对「这个 uid 名下真的存过这个字段」的 model 生效，别人的 model 一律原样放行。
static id SLProfAltAccountStr(id model, NSString *key, id orig) {
    NSString *uid = SLProfModelUID(model);
    if (!uid.length) return orig;
    if (sSLCurAcct.length && [uid isEqualToString:sSLCurAcct]) return orig;
    NSString *v = SLProfStrForUID(key, uid);
    return v.length ? v : orig;
}

#define SL_PROF_STR_HOOK(NAME, KEY, TAG, FIELD)                           \
    static id (*o_##NAME)(id, SEL);                                       \
    static id h_##NAME(id self, SEL _cmd) {                               \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                     \
        if (!SLProfGateLoose()) { SLCapNote(self, FIELD, v);              \
                                  SLProfNoteMiss(TAG);                    \
                                  return SLProfAltAccountStr(self, KEY, v); } \
        if (!SLProfIsMe(self)) return SLProfAltAccountStr(self, KEY, v);  \
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
        if (!SLProfGateLoose()) { SLCapNote(self, FIELD, v);              \
                                  SLProfNoteMiss(TAG); return v; }        \
        if (!SLProfIsMe(self)) return v;                                  \
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
    if (!SLProfGateLoose() || !SLProfIsMe(self)) return v;
    long long n = 0;
    if (!SLProfNumber(SLProfKeyFollower, &n)) return v;
    return SLProfFormatCount(n);
}

// 获赞的字符串版本（totalFavoriteStr），同理
static id (*o_totalFavoriteStr)(id, SEL);
static id h_totalFavoriteStr(id self, SEL _cmd) {
    id v = o_totalFavoriteStr ? o_totalFavoriteStr(self, _cmd) : nil;
    if (!SLProfGateLoose() || !SLProfIsMe(self)) return v;
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
    if (!f.length || !SLProfGateLoose()) return v;
    return f;
}

// 账号没设抖音号时 APP 会显示短 ID，这个开关打开才会走「抖音号：」那一行
static BOOL (*o_shouldShowUniqueID)(id, SEL);
static BOOL h_shouldShowUniqueID(id self, SEL _cmd) {
    BOOL v = o_shouldShowUniqueID ? o_shouldShowUniqueID(self, _cmd) : NO;
    if (SLProfGateLoose() && SLProfStr(SLProfKeyUID).length) return YES;
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

// 过亿的数字抖音会用富文本（数字一段、"亿"一段，字号和颜色都不一样）——
// 原来遇到非 NSString/NSNumber 就原样放行，所以一亿以上永远同步不过来。
//
// 0.9.7：不再「新建一个 NSAttributedString 套第一段属性」——那样会把抖音自己的
// 私有富文本类换成普通 NSMutableAttributedString，部分 cell 会按类判断后直接忽略。
// 现在就地改原对象的可变副本，长度不够时单位单独沿用原串最后一段的属性（"亿"保持小字号）。
static id SLProfAttrCount(id v, long long n) {
    NSString *s = SLProfFormatCount(n);
    if (![v isKindOfClass:[NSAttributedString class]] || ![v length]) return s;
    NSAttributedString *src = (NSAttributedString *)v;
    NSDictionary *a0 = [src attributesAtIndex:0 effectiveRange:NULL];
    NSDictionary *aLast = [src attributesAtIndex:src.length - 1 effectiveRange:NULL];
    @try {
        NSMutableAttributedString *m = [src mutableCopy];
        if (m && [m isKindOfClass:[NSMutableAttributedString class]]) {
            [m replaceCharactersInRange:NSMakeRange(0, m.length) withString:s];
            if (a0.count) [m setAttributes:a0 range:NSMakeRange(0, s.length)];
            if (aLast.count && s.length >= 2 &&
                ([s hasSuffix:@"亿"] || [s hasSuffix:@"万"])) {
                [m setAttributes:aLast range:NSMakeRange(s.length - 1, 1)];
            }
            if (m.length == s.length) return m;
        }
    } @catch (NSException *e) {
        static BOOL sOnce = NO;
        if (!sOnce) { sOnce = YES;
            SLLog(@"STAT| 富文本就地替换失败（%@），改用重建", e.reason ?: @"?"); }
    }
    // 就地改不动就重建一份：样式照抄第一段，单位沿用最后一段
    NSMutableAttributedString *m2 = [[NSMutableAttributedString alloc] initWithString:s];
    if (a0.count) [m2 setAttributes:a0 range:NSMakeRange(0, s.length)];
    if (aLast.count && s.length >= 2 && ([s hasSuffix:@"亿"] || [s hasSuffix:@"万"]))
        [m2 setAttributes:aLast range:NSMakeRange(s.length - 1, 1)];
    return m2;
}

// 计数接口返回了认不出的类型（抖音的私有富文本 / 展示模型之类）时记一笔类名。
// 「一亿以上换不了」多半就卡在这里 —— 有这个类名，下一轮就能按类名精准处理。
static void SLProfNoteCountType(NSString *tag, id v) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];
    NSString *cn = v ? NSStringFromClass([v class]) : @"nil";
    NSString *k = [NSString stringWithFormat:@"%@|%@", tag, cn];
    if ([seen containsObject:k]) return;
    [seen addObject:k];
    SLLog(@"STAT| %@ 返回 %@，类型没认出来 → 原样放行", tag, cn);
}

#define SL_PROF_COUNT_HOOK(NAME, KEY, TAG, FIELD)                          \
    static id (*o_##NAME)(id, SEL, id);                                    \
    static id h_##NAME(id self, SEL _cmd, id item) {                       \
        id v = o_##NAME ? o_##NAME(self, _cmd, item) : nil;                \
        if (!SLProfGateLoose()) { SLCapNoteValue(FIELD, v); return v; }    \
        long long n = 0;                                                   \
        if (!SLProfNumber(KEY, &n)) return v;                              \
        if (sSLProfHits < 20) { sSLProfHits++;                             \
            SLLog(@"PROF| 替换 %@ → %lld", TAG, n); }                      \
        if ([v isKindOfClass:[NSAttributedString class]])                  \
            return SLProfAttrCount(v, n);                                  \
        if (v && ![v isKindOfClass:[NSString class]] &&                    \
            ![v isKindOfClass:[NSNumber class]]) {                         \
            SLProfNoteCountType(TAG, v); return v; }                       \
        if ([v isKindOfClass:[NSString class]]) return SLProfFormatCount(n); \
        return @(n);                                                       \
    }

SL_PROF_COUNT_HOOK(praiseText, SLProfKeyLike,      @"praise",   @"like")
SL_PROF_COUNT_HOOK(mutualText, SLProfKeyFriend,    @"mutual",   @"friend")
SL_PROF_COUNT_HOOK(friendText, SLProfKeyFriend,    @"friend",   @"friend")
// 播放量以前借用「作品数」的键 —— 用户填作品数=70，播放量就跟着变成 70，
// 看起来像「播放量没同步」。现在有独立的 SLProfKeyPlay。
SL_PROF_COUNT_HOOK(playText,   SLProfKeyPlay,      @"play",     @"play")
SL_PROF_COUNT_HOOK(fansText,   SLProfKeyFollower,  @"fans",     @"follower")
SL_PROF_COUNT_HOOK(followText, SLProfKeyFollowing, @"follow",   @"following")


// 过亿的获赞有时候不走上面的组件，直接由 header 的统计 cell 收文本。
// 这里在最后一环再兜一次：参数是什么类型就还回什么类型，认不出类型（富文本）就不动。
static void SLProfHookOneObjVoid(Class cls, NSString *selName, IMP imp, IMP *slot, NSString *tag) {
    if (!cls) { SLLog(@"PROF| 跳过 %@：类不存在", tag); return; }
    SEL sel = NSSelectorFromString(selName);
    Method m = SLProfExact(cls, sel);
    if (!m) { SLLog(@"PROF| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    char *ret = method_copyReturnType(m);
    BOOL isVoid = (ret && ret[0] == 'v');
    if (ret) free(ret);
    if (!isVoid) { SLLog(@"PROF| 跳过 %@：返回值不是 void", tag); return; }
    if (method_getNumberOfArguments(m) != 3) { SLLog(@"PROF| 跳过 %@：参数个数不是 1", tag); return; }
    char at[8] = {0};
    method_getArgumentType(m, 2, at, sizeof(at));
    if (at[0] != '@') { SLLog(@"PROF| 跳过 %@：参数不是对象", tag); return; }
    *slot = method_getImplementation(m);
    method_setImplementation(m, imp);
    SLLog(@"PROF| 已挂 %@ @ %@", tag, NSStringFromClass(cls));
}

#define SL_PROF_CELLCOUNT_HOOK(NAME, KEY, TAG)                              \
    static void (*o_##NAME)(id, SEL, id);                                   \
    static void h_##NAME(id self, SEL _cmd, id v) {                         \
        id nv = v;                                                          \
        long long n = 0;                                                    \
        if (SLProfGateLoose() && SLProfNumber(KEY, &n) && n > 0) {          \
            if ([v isKindOfClass:[NSNumber class]]) nv = @(n);              \
            else if ([v isKindOfClass:[NSString class]]) nv = SLProfFormatCount(n); \
            else if ([v isKindOfClass:[NSAttributedString class]]) nv = SLProfAttrCount(v, n); \
            else if (v) {                                                   \
                static BOOL sTypeLogged = NO;                               \
                if (!sTypeLogged) { sTypeLogged = YES;                      \
                    SLLog(@"STAT| %@ 参数是 %@，暂不动", TAG,                \
                          NSStringFromClass([v class])); }                  \
            }                                                               \
        }                                                                   \
        if (o_##NAME) o_##NAME(self, _cmd, nv);                             \
    }

SL_PROF_CELLCOUNT_HOOK(cellFav,    SLProfKeyLike,      @"stat.praise")
SL_PROF_CELLCOUNT_HOOK(cellFans,   SLProfKeyFollower,  @"stat.fans")
SL_PROF_CELLCOUNT_HOOK(cellFollow, SLProfKeyFollowing, @"stat.follow")
SL_PROF_CELLCOUNT_HOOK(cellFriend, SLProfKeyFriend,    @"stat.friend")

#pragma mark - 性别 / 年龄 / 地区 / 认证 / 学校
//
// 昵称下面那行「女 · 22岁 · 广东」和认证、学校这些，都是 AWEUserModel 自己给的：
//   -gender（1 男 / 2 女，0 未设）、-userAge、-genderDisplayString
//   -city / -province / -district / -ipLocation / -location
//   -verifyInfo / -customVerifyInfo / -schoolName
// 统一按账号存一份，只在我页替换 —— 页面上看得见的资料全跟着对方走。
// （专属会员 / 群聊 / 橱窗交给抖音自己的设置，插件不再插手。）

// 一揽子文本字段存在同一个词典里：SLProf.extra.<我的uid> -> { city: "广东", ... }
static NSArray *SLExtraFields(void) {
    return @[@"city", @"province", @"district", @"ipLocation", @"location",
             @"verifyInfo", @"customVerifyInfo", @"schoolName"];
}

static NSString *SLExtraStr(NSString *field) {
    if (!field.length) return nil;
    NSDictionary *d = [[NSUserDefaults standardUserDefaults]
                       dictionaryForKey:SLProfScopedKey(SLProfKeyExtra)];
    id v = [d isKindOfClass:[NSDictionary class]] ? d[field] : nil;
    if (![v isKindOfClass:[NSString class]] || ![(NSString *)v length]) return nil;
    return v;
}

// 单个 extra 字段的写入（设置页手动填地区时用）
static void SLProfSetExtra(NSString *field, NSString *value) {
    if (!field.length) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *k = SLProfScopedKey(SLProfKeyExtra);
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    id cur = [ud dictionaryForKey:k];
    if ([cur isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:cur];
    if (value.length) d[field] = value;
    else [d removeObjectForKey:field];
    if (d.count) [ud setObject:[d copy] forKey:k];
    else [ud removeObjectForKey:k];
    [ud synchronize];
}

// 从快照里把这几个字段抽出来整包写进去（对方没有的就不写，避免凭空多出认证）
static void SLApplySnapExtras(NSDictionary *snap) {
    NSUserDefaults *ud0 = [NSUserDefaults standardUserDefaults];
    id cur = [ud0 dictionaryForKey:SLProfScopedKey(SLProfKeyExtra)];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if ([cur isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:cur];
    for (NSString *f in SLExtraFields()) {
        if ([d[f] isKindOfClass:[NSString class]] && [(NSString *)d[f] length]) continue;   // 手填优先
        NSString *v = SLSnapText(snap, f);
        if (v.length) d[f] = v;
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *k = SLProfScopedKey(SLProfKeyExtra);
    if (d.count) [ud setObject:[d copy] forKey:k];
    else [ud removeObjectForKey:k];
    [ud synchronize];
}

static id (*o_genderText)(id, SEL);
static id h_genderText(id self, SEL _cmd) {
    id v = o_genderText ? o_genderText(self, _cmd) : nil;
    if (!SLProfGateLoose() || !SLProfIsMe(self)) return v;
    NSString *f = SLProfStr(SLProfKeyGenderTxt);
    return f.length ? f : v;
}

#define SL_PROF_INT_HOOK(NAME, KEY)                                        \
    static NSInteger (*o_##NAME)(id, SEL);                                 \
    static NSInteger h_##NAME(id self, SEL _cmd) {                         \
        NSInteger v = o_##NAME ? o_##NAME(self, _cmd) : 0;                 \
        if (!SLProfGateLoose() || !SLProfIsMe(self)) return v;             \
        long long n = 0;                                                   \
        if (!SLProfNumber(KEY, &n) || n <= 0) return v;                    \
        return (NSInteger)n;                                               \
    }

SL_PROF_INT_HOOK(gender,  SLProfKeyGender)
SL_PROF_INT_HOOK(userAge, SLProfKeyAge)

#define SL_PROF_EXTRA_HOOK(NAME, FIELD)                                    \
    static id (*o_##NAME)(id, SEL);                                        \
    static id h_##NAME(id self, SEL _cmd) {                                \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                      \
        if (!SLProfGateLoose() || !SLProfIsMe(self)) return v;             \
        NSString *f = SLExtraStr(FIELD);                                   \
        return f.length ? f : v;                                           \
    }

SL_PROF_EXTRA_HOOK(city,       @"city")
SL_PROF_EXTRA_HOOK(province,   @"province")
SL_PROF_EXTRA_HOOK(district,   @"district")
SL_PROF_EXTRA_HOOK(ipLocation, @"ipLocation")
SL_PROF_EXTRA_HOOK(location,   @"location")
SL_PROF_EXTRA_HOOK(verifyInfo, @"verifyInfo")
SL_PROF_EXTRA_HOOK(customVerifyInfo, @"customVerifyInfo")
SL_PROF_EXTRA_HOOK(schoolName, @"schoolName")


// 主页上「女 · 22岁 · 广东 · 学校」这一排，是
//   AWEProfileHeaderAgeAndLocationCollectionViewCell -configWithHeaderContext:
// 自己按 headerContext 里的 model 拼按钮标题的 —— 不读我们挂的那几个 getter，
// 所以性别年龄一直不跟着变。在它配好之后把标题直接改成对方的。
static void SLProfSetBtnText(id btn, NSString *text) {
    if (!btn || !text.length) return;
    if ([btn isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)btn;
        if ([[b titleForState:UIControlStateNormal] isEqualToString:text]) return;
        [b setAttributedTitle:nil forState:UIControlStateNormal];
        [b setTitle:text forState:UIControlStateNormal];
        return;
    }
    if (![btn isKindOfClass:[UIView class]]) return;
    for (UIView *v in [((UIView *)btn).subviews copy]) {
        if ([v isKindOfClass:[UILabel class]]) { ((UILabel *)v).text = text; return; }
    }
}

static NSString *SLProfAgeGenderText(void) {
    long long g = 0, a = 0;
    BOOL hasG = SLProfNumber(SLProfKeyGender, &g);
    BOOL hasA = SLProfNumber(SLProfKeyAge, &a);
    // 两个都有就拼成一整条（抖音那排就是「女 · 22岁」）
    if (hasG && g > 0 && hasA && a > 0)
        return [NSString stringWithFormat:@"%@ · %lld岁", (g == 2 ? @"女" : @"男"), a];
    NSString *t = SLProfStr(SLProfKeyGenderTxt);
    if (t.length) return t;
    if (hasA && a > 0) return [NSString stringWithFormat:@"%lld岁", a];
    if (hasG && g > 0) return (g == 2) ? @"女" : @"男";
    return nil;
}

// 读「我」自己 model 的**真实**值（绕过我们自己的钩子，直接调原实现）
static NSString *SLProfRealStr(id model, id (*orig)(id, SEL), NSString *selName) {
    if (!model || !orig) return nil;
    id v = orig(model, NSSelectorFromString(selName));
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}

// 「男 · 22岁」这种组合文本，抖音不一定会给 genderDisplayString，自己拼一份
static NSString *SLProfRealCombo(id model) {
    if (!model) return nil;
    NSInteger g = o_gender ? o_gender(model, @selector(gender)) : 0;
    NSInteger a = o_userAge ? o_userAge(model, NSSelectorFromString(@"userAge")) : 0;
    NSString *sx = (g == 2) ? @"女" : (g == 1 ? @"男" : nil);
    if (sx.length && a > 0) return [NSString stringWithFormat:@"%@ · %ld岁", sx, (long)a];
    if (a > 0) return [NSString stringWithFormat:@"%ld岁", (long)a];
    return sx;
}

// 「真实文本 → 要显示的文本」。cell 是拿模型现拼的标题，我们不知道它拼成什么样，
// 但知道**我自己的**真实值长什么样：按内容比对，比按 ivar 名字找稳得多。
static NSDictionary *SLProfRealTextMap(void) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSString *ageTxt = SLProfAgeGenderText();
    if (ageTxt.length) {
        NSString *rt = SLProfRealStr(sSLMyModel, o_genderText, @"genderDisplayString");
        if (rt.length) m[rt] = ageTxt;
        NSString *combo = SLProfRealCombo(sSLMyModel);
        if (combo.length) m[combo] = ageTxt;
        NSInteger g = o_gender ? o_gender(sSLMyModel, @selector(gender)) : 0;
        if (g == 2) m[@"女"] = ageTxt;
        else if (g == 1) m[@"男"] = ageTxt;
        // 真值读不到（model 还没来 / 对方没公开）也照样换：
        // 页面上那颗 chip 只可能是「男」或「女」，两个都指向我们要显示的文本。
        // 0.9.7 之前这里因为拿不到真值，整条 map 是空的 —— 设置里填了也一点不动。
        if (!rt.length && !combo.length) {
            m[@"男"] = ageTxt;
            m[@"女"] = ageTxt;
        }
    }

    NSString *loc = SLExtraStr(@"city") ?: SLExtraStr(@"location");
    NSString *ip  = SLExtraStr(@"ipLocation");
    NSString *sch = SLExtraStr(@"schoolName");
    NSArray *pairs = @[@[@"city", loc ?: @""], @[@"province", loc ?: @""],
                       @[@"district", loc ?: @""], @[@"location", loc ?: @""],
                       @[@"ipLocation", ip ?: @""], @[@"schoolName", sch ?: @""]];
    id (*origs[6])(id, SEL) = { o_city, o_province, o_district, o_location, o_ipLocation, o_schoolName };
    NSArray *sels = @[@"city", @"province", @"district", @"location", @"ipLocation", @"schoolName"];
    for (NSUInteger i = 0; i < pairs.count; i++) {
        NSString *want = pairs[i][1];
        if (!want.length) continue;
        NSString *real = SLProfRealStr(sSLMyModel, origs[i], sels[i]);
        if (real.length && ![real isEqualToString:want]) m[real] = want;
    }
    return m;
}

static NSString *SLProfTextOfView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return ((UILabel *)v).text;
    if ([v isKindOfClass:[UIButton class]])
        return [((UIButton *)v) titleForState:UIControlStateNormal];
    return nil;
}

static BOOL SLProfSetTextOfView(UIView *v, NSString *text) {
    if (!text.length) return NO;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if ([l.text isEqualToString:text]) return NO;
        l.text = text;
        return YES;
    }
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        if ([[b titleForState:UIControlStateNormal] isEqualToString:text]) return NO;
        [b setAttributedTitle:nil forState:UIControlStateNormal];
        [b setTitle:text forState:UIControlStateNormal];
        return YES;
    }
    return NO;
}

// 在 cell 里按文本内容替换（含「IP属地：广东」这种带前缀的写法）
// v0.9.3：加深度上限 + 重入闸。改标题会触发一轮 layout，某些 cell 在 layout 里又会配一遍，
// 没有闸就是「改 → layout → 再配 → 再改」的无限套娃，真机上就是一闪退。
static BOOL sSLTextMapBusy = NO;

// 「26岁」「女 · 26岁」这种才认。0.9.6 之前用 [t containsString:@"岁"] 判，
// 作品标题里带个「岁」字就被改成伪装值；更早还有 `[t containsString:@"男"]` 的泛匹配，
// 含「男」的任何文案都会被整段替换 —— 全页扫的时候这就是灾难。
static BOOL SLProfLooksLikeAge(NSString *t) {
    if (!t.length || t.length > 10 || ![t hasSuffix:@"岁"]) return NO;
    NSString *head = [t substringToIndex:t.length - 1];
    if ([head hasPrefix:@"女"] || [head hasPrefix:@"男"]) {
        NSRange sp = [head rangeOfString:@"·"];
        if (sp.location == NSNotFound) return head.length == 1;
        head = [[head substringFromIndex:sp.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    if (!head.length || head.length > 3) return NO;
    NSCharacterSet *notDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [head rangeOfCharacterFromSet:notDigit].location == NSNotFound;
}

static BOOL SLProfLooksLikeIP(NSString *t) {
    return [t hasPrefix:@"IP属地"] && t.length <= 20;
}

static BOOL SLProfApplyTextMapDepth(UIView *root, NSDictionary *map, NSString *ageTxt, int depth) {
    if (!root || depth > 8 || sSLTextMapBusy) return NO;
    BOOL hit = NO;
    for (UIView *v in [root.subviews copy]) {
        NSString *t = SLProfTextOfView(v);
        if (t.length) {
            NSString *nv = map[t];
            if (!nv.length && ageTxt.length && SLProfLooksLikeAge(t)) nv = ageTxt;
            if (nv.length && ![nv isEqualToString:t]) {
                if (SLProfSetTextOfView(v, nv)) hit = YES;
            }
        }
        if (SLProfApplyTextMapDepth(v, map, ageTxt, depth + 1)) hit = YES;
    }
    return hit;
}

static BOOL SLProfApplyTextMap(UIView *root, NSDictionary *map, NSString *ageTxt) {
    if (!root || sSLTextMapBusy) return NO;
    sSLTextMapBusy = YES;
    BOOL hit = SLProfApplyTextMapDepth(root, map, ageTxt, 0);
    sSLTextMapBusy = NO;
    return hit;
}

static void SLProfApplyAgeLocation(id cell) {
    if (!SLProfGateLoose()) return;
    if (sSLProfKindVal != 1 && !sSLProfOnMePage) return;

    NSString *ageTxt = SLProfAgeGenderText();
    // 先按老名字改（38/39 早期版本就是这几个 ivar，最快最准）
    SLProfSetBtnText(SLProfCallObj(cell, @"genderAndAgeButton"), ageTxt);
    NSString *loc = SLExtraStr(@"city") ?: SLExtraStr(@"location");
    SLProfSetBtnText(SLProfCallObj(cell, @"locationBtn"), loc);
    SLProfSetBtnText(SLProfCallObj(cell, @"ipLocationBtn"), SLExtraStr(@"ipLocation"));
    SLProfSetBtnText(SLProfCallObj(cell, @"schoolBtn"), SLExtraStr(@"schoolName"));

    // 再按内容改：版本换了控件名 / 换成纯 label 也照样对得上
    if (![cell isKindOfClass:[UIView class]]) return;
    NSDictionary *map = SLProfRealTextMap();
    if (!map.count && !ageTxt.length) return;
    if (SLProfApplyTextMap(cell, map, ageTxt)) {
        static BOOL sLogged = NO;
        if (!sLogged) { sLogged = YES; SLLog(@"PROF| 已按文本改写年龄 / 地区 / 学校"); }
    }
}

static int sSLAgeLocHooks = 0;      // configWithHeaderContext: 被调了几次（诊断用）

static void (*o_ageLocConfig)(id, SEL, id);
static void h_ageLocConfig(id self, SEL _cmd, id ctx) {
    sSLAgeLocHooks++;
    if (o_ageLocConfig) o_ageLocConfig(self, _cmd, ctx);
    SLProfApplyAgeLocation(self);
}

// cell 往往比「认出我页」先配好，进页后再按类名找一遍补上
static void SLProfFindAgeLocCells(UIView *root, NSMutableArray *out) {
    if (!root || out.count > 20) return;
    NSString *cn = NSStringFromClass([root class]);
    // 类名换过几次（AgeAndLocation / AgeLocation），按关键词认
    if ([cn containsString:@"AgeAndLocation"] || [cn containsString:@"AgeLocation"]) {
        [out addObject:root];
        return;
    }
    for (UIView *v in [root.subviews copy]) SLProfFindAgeLocCells(v, out);
}

// 「我」页顶部那一块（header）才允许改写文本：作品网格里的标题、文案一律不碰。
// 0.9.6 之前是全窗口扫 + 泛匹配，作品标题里带「岁」「男」「女」都会被误改。
static BOOL SLProfInHeaderArea(UIView *v, UIWindow *win) {
    if (!v || !win || !v.window) return NO;
    CGRect r = [v convertRect:v.bounds toView:win];
    if (r.size.width <= 1 || r.size.height <= 1) return NO;
    return CGRectGetMinY(r) < CGRectGetHeight(win.bounds) * 0.58;
}

// header 以下的子树直接剪掉（作品网格有几百个 cell，每 0.8 秒全量递归太重）。
// 滚动容器本身要下去 —— header 就躺在 collectionView 里。
static BOOL SLProfShouldDescend(UIView *v, UIWindow *win) {
    if (!v || !v.window) return NO;
    if ([v isKindOfClass:[UIScrollView class]]) return YES;
    CGRect r = [v convertRect:v.bounds toView:win];
    if (r.size.height <= 0) return YES;
    return CGRectGetMinY(r) < CGRectGetHeight(win.bounds) * 0.58;
}

static void SLProfDumpHeaderTexts(UIView *root, UIWindow *win, NSMutableArray *out, int depth) {
    if (!root || !win || depth > 14 || out.count >= 14) return;
    for (UIView *v in [root.subviews copy]) {
        if ([NSStringFromClass([v class]) hasPrefix:@"SL"]) continue;
        NSString *t = SLProfTextOfView(v);
        if (t.length && t.length <= 14 && SLProfInHeaderArea(v, win) && ![out containsObject:t])
            [out addObject:t];
        if (SLProfShouldDescend(v, win)) SLProfDumpHeaderTexts(v, win, out, depth + 1);
    }
}

static BOOL SLProfApplyAgeLocTextDepth(UIView *root, NSDictionary *map, NSString *ageTxt,
                                       NSString *ipTxt, UIWindow *win, int depth) {
    if (!root || !win || depth > 14) return NO;
    BOOL hit = NO;
    for (UIView *v in [root.subviews copy]) {
        if ([NSStringFromClass([v class]) hasPrefix:@"SL"]) continue;
        NSString *t = SLProfTextOfView(v);
        if (t.length && SLProfInHeaderArea(v, win)) {
            NSString *nv = map[t];
            if (!nv.length && ageTxt.length && SLProfLooksLikeAge(t)) nv = ageTxt;
            if (!nv.length && ipTxt.length && SLProfLooksLikeIP(t)) nv = ipTxt;
            if (nv.length && ![nv isEqualToString:t] && SLProfSetTextOfView(v, nv)) hit = YES;
        }
        if (SLProfShouldDescend(v, win) &&
            SLProfApplyAgeLocTextDepth(v, map, ageTxt, ipTxt, win, depth + 1)) hit = YES;
    }
    return hit;
}

// 39.9.0 的「我」页里，性别 / 地区根本不是 AgeAndLocation 那个 cell（日志里永远是 0 个），
// 而是昵称下面那一排 chips：
//     [中国台湾]  [+ 添加性别等标签]
//     [女]        [+ 添加所在地等标签]
// 这些小方块是抖音按 model 现拼的，拼完就缓存成标题，所以我们挂的 getter 追不上。
// 这里换个思路：找到「+ 添加XX等标签」那颗按钮，它和资料 chip 是同一个父视图下的兄弟，
// 把兄弟里不是按钮的那几个按内容认出来直接改字。
//   · 文本是「男 / 女 / NN岁 / 女 · NN岁」→ 换成设置里的性别年龄
//   · 其余短文本 → 换成设置里的地区
static NSString *SLProfFirstTextIn(UIView *v, int depth) {
    NSString *t = SLProfTextOfView(v);
    if (t.length) return t;
    if (depth <= 0) return nil;
    for (UIView *s in v.subviews) {
        NSString *r = SLProfFirstTextIn(s, depth - 1);
        if (r.length) return r;
    }
    return nil;
}

static BOOL SLProfSetFirstTextIn(UIView *v, NSString *text, int depth) {
    if (!text.length) return NO;
    if (SLProfSetTextOfView(v, text)) return YES;
    if (depth <= 0) return NO;
    for (UIView *s in v.subviews) if (SLProfSetFirstTextIn(s, text, depth - 1)) return YES;
    return NO;
}

static BOOL SLProfLooksLikeGenderChip(NSString *t) {
    return [t isEqualToString:@"男"] || [t isEqualToString:@"女"] || SLProfLooksLikeAge(t);
}

static BOOL SLProfFixHeaderChips(UIView *root, NSString *ageTxt, NSString *regionTxt, int depth) {
    if (!root || depth > 16 || sSLTextMapBusy) return NO;
    BOOL hit = NO;
    for (UIView *v in [root.subviews copy]) {
        if ([NSStringFromClass([v class]) hasPrefix:@"SL"]) continue;
        NSString *t = SLProfTextOfView(v);
        if (t.length && [t containsString:@"添加"] && [t containsString:@"标签"]) {
            UIView *row = v.superview;
            if (row) {
                for (UIView *chip in [row.subviews copy]) {
                    if (chip == v) continue;
                    NSString *ct = SLProfFirstTextIn(chip, 3);
                    if (!ct.length || [ct containsString:@"添加"]) continue;
                    NSString *want = SLProfLooksLikeGenderChip(ct) ? ageTxt : regionTxt;
                    if (!want.length || [want isEqualToString:ct]) continue;
                    if (SLProfSetFirstTextIn(chip, want, 3)) hit = YES;
                }
            }
        }
        if (SLProfFixHeaderChips(v, ageTxt, regionTxt, depth + 1)) hit = YES;
    }
    return hit;
}

static BOOL sSLAgelocBusy = NO;

static void SLProfApplyAgeLocationNow(void) {
    if (!SLProfGateLoose()) return;
    if (sSLAgelocBusy) return;
    sSLAgelocBusy = YES;

    NSMutableArray *cells = [NSMutableArray array];
    @try {
        for (UIScene *sce in [[UIApplication sharedApplication].connectedScenes copy]) {
            if (![sce isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in [((UIWindowScene *)sce).windows copy]) SLProfFindAgeLocCells(w, cells);
        }
        for (id c in [cells copy]) SLProfApplyAgeLocation(c);

        // 真机 39.9.0 上那个 AgeAndLocation cell 根本没被创建（日志：cell 0 个 · 回调 0 次），
        // 所以不能只认类名。这里直接在「我页」header 区域按**内容**改：
        // 只有整串等于真实值、或者长得像「26岁 / 女 · 26岁 / IP属地」的文本才动。
        UIWindow *win = nil;
        for (UIScene *sce in [[UIApplication sharedApplication].connectedScenes copy]) {
            if (![sce isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sce).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
        UIViewController *meVC = nil;
        for (UIScene *sce in [[UIApplication sharedApplication].connectedScenes copy]) {
            if (![sce isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in [((UIWindowScene *)sce).windows copy]) {
                NSMutableArray *vcs = [NSMutableArray array];
                SLProfCollectVCs(w.rootViewController, vcs);
                for (UIViewController *vc in vcs) {
                    if (SLProfKindFromVC(vc) == 1 && vc.isViewLoaded) { meVC = vc; break; }
                }
                if (meVC) break;
            }
            if (meVC) break;
        }

        NSString *ageTxt = SLProfAgeGenderText();
        NSString *ipTxt = SLExtraStr(@"ipLocation");
        if (ipTxt.length && ![ipTxt hasPrefix:@"IP属地"])
            ipTxt = [@"IP属地：" stringByAppendingString:ipTxt];
        NSString *regionTxt = SLExtraStr(@"city") ?: SLExtraStr(@"location");
        NSDictionary *map = SLProfRealTextMap();
        if (meVC && win && (map.count || ageTxt.length)) {
            if (SLProfApplyAgeLocTextDepth(meVC.view, map, ageTxt, ipTxt, win, 0)) {
                static BOOL sWriteLogged = NO;
                if (!sWriteLogged) { sWriteLogged = YES;
                    SLLog(@"PROF| 已在 header 按文本改写年龄 / 地区 / IP"); }
            }
        }
        // chips 那一排（截图里的「中国台湾 / + 添加性别等标签」）
        if (meVC && (ageTxt.length || regionTxt.length)) {
            BOOL chips = SLProfFixHeaderChips(meVC.view, ageTxt, regionTxt, 0);
            if (chips) {
                static BOOL sChipLogged = NO;
                if (!sChipLogged) { sChipLogged = YES;
                    SLLog(@"PROF| 已改写资料标签（性别=%@ 地区=%@）",
                          ageTxt ?: @"不动", regionTxt ?: @"不动"); }
            }
        }

        // 诊断：cells=0 说明那个类没被创建；把 header 里的短文本 dump 出来，
        // 下次就能看到页面到底显示的是「女 · 26岁」还是别的写法，不用再猜。
        static BOOL sLogged = NO;
        if (!sLogged && (cells.count > 0 || sSLTickCount > 10)) {
            sLogged = YES;
            NSMutableArray *texts = [NSMutableArray array];
            if (meVC && win) SLProfDumpHeaderTexts(meVC.view, win, texts, 0);
            SLLog(@"PROF| 年龄地区 cell %lu 个 · 配置回调 %d 次 · 性别=%@ 年龄=%@ 地区=%@ IP=%@ 学校=%@",
                  (unsigned long)cells.count, sSLAgeLocHooks,
                  SLProfStr(SLProfKeyGender) ?: @"无", SLProfStr(SLProfKeyAge) ?: @"无",
                  SLExtraStr(@"city") ?: @"无", SLExtraStr(@"ipLocation") ?: @"无",
                  SLExtraStr(@"schoolName") ?: @"无");
            SLLog(@"PROF| header 文本样本：%@", texts.count ? [texts componentsJoinedByString:@" | "] : @"（空）");
        }
    } @finally {
        sSLAgelocBusy = NO;
    }
}

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
// 39.9.0 的真身（脱壳包 ivar 确认）：AWEUserModel.profileCover 本身就是
// NSArray<AWEProfileCoverURLModel *>，每个元素带 urlModel / lightCoverColor / darkCoverColor。
// v0.8.7/0.8.8 一直按 profileCover → coverList 去挖，多跳了一层，所以永远「无背景」。
//
// 现在的做法：
//   1) 截 -profileCover：别人主页把这份数组整包留住（颜色/裁切/渐变都是抖音算的）；
//   2) 我页时直接返回一份用保存的 URL 重建的同款数组 —— 重启后照样有背景；
//   3) 再挂封面视图的 configWithCoverList: / configWithURLList:… 兜底，
//      就算哪天 model 那条链不读了，视图层也能换。

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

// AWEURLModel 的取图数组方法名是 -URLList（大写 URL），不是 urlList ——
// 两个都试，免得哪天版本改回来又落空。
static NSString *SLProfModelFirstURL(id m) {
    if (!m) return nil;
    NSString *s = SLProfFirstURL(SLProfCallObj(m, @"URLList"));
    if (!s.length) s = SLProfFirstURL(SLProfCallObj(m, @"urlList"));
    if (!s.length) s = SLProfFirstURL(SLProfCallObj(m, @"originURLList"));
    return s;
}

// 从 coverList（模型对象数组）里挖出第一张图的 URL
static NSString *SLProfCoverURL(id coverList) {
    if (![coverList isKindOfClass:[NSArray class]]) return nil;
    for (id item in (NSArray *)coverList) {
        NSString *s = SLProfURLString(item);
        if (s.length) return s;
        s = SLProfModelFirstURL(SLProfCallObj(item, @"urlModel"));
        if (s.length) return s;
        s = SLProfModelFirstURL(item);
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
    if ([coverList isKindOfClass:[NSArray class]]) {
        id first = [(NSArray *)coverList firstObject];
        id lc = SLProfCallObj(first, @"lightCoverColor");
        id dc = SLProfCallObj(first, @"darkCoverColor");
        if ([lc isKindOfClass:[NSString class]] && [(NSString *)lc length]) SLCapNoteValue(@"coverLight", lc);
        if ([dc isKindOfClass:[NSString class]] && [(NSString *)dc length]) SLCapNoteValue(@"coverDark", dc);
    }
    if (url.length) SLCapNoteValue(@"cover", url);
    NSString *uid = SLCurViewUID();
    if (uid.length) SLCoverRemember(uid, coverList, nil);
}

// 造一个和抖音同款的 AWEURLModel（只要 urlList 就够 SDWebImage 拉图）。
// 这里不用 -initWithURLList:（ARC 下通过 IMP 调 init 家族容易多释放一次），
// 直接 alloc/init 再用 KVC 落到 URLList 这个 ivar 上。
static id SLProfURLModelFrom(NSString *url) {
    if (!url.length) return nil;
    Class c = objc_getClass("AWEURLModel");
    if (!c) return nil;
    id um = [[c alloc] init];
    @try {
        [um setValue:@[url] forKey:@"URLList"];
        [um setValue:@[url] forKey:@"originURLList"];
    } @catch (__unused NSException *e) {
        return nil;
    }
    return um;
}

// 把对方的封面图直接喂给封面视图。
//
// 0.8.9 是自己 KVC 拼一个 AWEProfileCoverURLModel 再喂回 -configWithCoverList:，
// 结果两头不讨好：抖音的渲染链不认这个拼装对象（日志说换了、屏幕没变），
// 换号时它还是最容易炸的一处（自己拼的对象缺字段，抖音拿去当真的用）。
// 现在改喂真图：-configWithImage: 就是封面视图自己收图的那个入口。
static void (*o_coverImage)(id, SEL, id);
static BOOL sSLCoverBusy = NO;

// 封面图缓存：内存一份（本次启动）、磁盘一份（重启后第一帧就能贴上）。
//
// 只靠「下载完再贴」有个必输的竞态：抖音自己那份封面图也是异步下的，
// 谁后到谁说话 —— 它经常后到，于是背景闪一下又变回自己的。
// 现在改成：拿到图就存起来，之后每次封面视图 layout 都再确认一次，
// 不管抖音什么时候把图刷回去，最后留在屏幕上的都是对方的封面。
static NSMutableDictionary *sSLCoverImgs = nil;   // url -> UIImage

static NSString *SLProfCacheDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject;
    if (!base.length) return nil;
    NSString *dir = [base stringByAppendingPathComponent:@"ShenglinDouyin"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

// URL 太脏不能当文件名，压成一个稳定短哈希
static NSString *SLProfURLKey(NSString *url) {
    if (!url.length) return nil;
    uint64_t h = 1469598103934665603ULL;
    const char *p = url.UTF8String;
    for (; p && *p; p++) { h ^= (unsigned char)*p; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"cover-%016llx", h];
}

static UIImage *SLProfCoverCached(NSString *url) {
    if (!url.length) return nil;
    if (!sSLCoverImgs) sSLCoverImgs = [NSMutableDictionary dictionary];
    UIImage *img = sSLCoverImgs[url];
    if (img) return img;
    NSString *dir = SLProfCacheDir(), *k = SLProfURLKey(url);
    if (!dir || !k.length) return nil;
    NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:k]];
    if (!d.length) return nil;
    img = [UIImage imageWithData:d];
    if (img) {
        if (sSLCoverImgs.count > 8) [sSLCoverImgs removeAllObjects];
        sSLCoverImgs[url] = img;
    }
    return img;
}

static void SLProfCoverCachePut(NSString *url, UIImage *img) {
    if (!url.length || !img) return;
    if (!sSLCoverImgs) sSLCoverImgs = [NSMutableDictionary dictionary];
    if (sSLCoverImgs.count > 8) [sSLCoverImgs removeAllObjects];
    sSLCoverImgs[url] = img;
    NSString *dir = SLProfCacheDir(), *k = SLProfURLKey(url);
    if (!dir || !k.length) return;
    NSData *d = UIImageJPEGRepresentation(img, 0.92);
    if (d.length) [d writeToFile:[dir stringByAppendingPathComponent:k] atomically:YES];
}

// 按账号再存一张原图。
// 抖音的封面 URL 是带签名的，过期之后同一个链接就下不动了 —— 而重启后我们手上只有这个
// URL，于是「背景图重启就失效」。点「伪装主页」那一刻顺手把图存成本地文件，之后只认它。
// 按账号 + 当前要伪装的那张封面，各存一张原图。
//
// 0.9.6 及以前只按账号存一张（acct-cover-<我的uid>.jpg）—— 同一个账号先后伪装两个人时，
// 文件永远是先存的那张：ForceCover 一看到「本机有图」就直接贴，新对象的封面根本不下载。
// 用户看到的就是「背景有的时候没同步，补一下反而把别人的背景贴过来了」。
// 文件名带上封面 URL 的哈希后，换人即换文件，旧图再也贴不上来。
static NSString *SLProfCoverAcctPathFor(NSString *url) {
    if (!sSLCurAcct.length || !url.length) return nil;
    NSString *dir = SLProfCacheDir();
    if (!dir.length) return nil;
    NSString *k = SLProfURLKey(url);
    if (!k.length) return nil;
    return [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"acct-cover-%@-%@.jpg", sSLCurAcct, k]];
}

static NSString *SLProfCoverAcctPath(void) {
    return SLProfCoverAcctPathFor(SLProfStr(SLProfKeyCover));
}


static UIImage *SLProfCoverAcctImage(void) {
    NSString *p = SLProfCoverAcctPath();
    if (!p.length) return nil;
    if (sSLCoverAcctImg && [sSLCoverAcctKey isEqualToString:p]) return sSLCoverAcctImg;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d.length) return nil;
    UIImage *img = [UIImage imageWithData:d];
    if (img) { sSLCoverAcctKey = [p copy]; sSLCoverAcctImg = img; }
    return img;
}

static void SLProfCoverPersistAcct(NSString *uid, UIImage *img) {
    if (!uid.length || !img) return;
    if (!sSLCurAcct.length || ![uid isEqualToString:sSLCurAcct]) return;   // 只存当前账号的
    NSString *p = SLProfCoverAcctPath();
    if (!p.length) return;
    sSLCoverAcctKey = [p copy];
    sSLCoverAcctImg = img;

    NSFileManager *fm = [NSFileManager defaultManager];
    // 旧版那份不分对象的图留着只会误事，顺手删掉
    NSString *dir = SLProfCacheDir();
    if (dir.length) {
        NSString *legacy = [dir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"acct-cover-%@.jpg", sSLCurAcct]];
        if ([fm fileExistsAtPath:legacy]) [fm removeItemAtPath:legacy error:NULL];
    }
    // 已经存过这张就收手。0.9.6 是每 0.8 秒重写一次 82KB，日志刷了六十多行，
    // 闪存和电量全白耗，且掩盖了「其实一直在写同一张旧图」这个事实。
    if ([fm fileExistsAtPath:p]) return;

    NSData *d = UIImageJPEGRepresentation(img, 0.92);
    if (d.length && [d writeToFile:p atomically:YES]) {
        static NSString *sLoggedPath = nil;
        if (![sLoggedPath isEqualToString:p]) {
            sLoggedPath = [p copy];
            SLLog(@"COVER| 已把封面原图存到本机（账号 %@ · %luKB）",
                  uid, (unsigned long)(d.length / 1024));
        }
    }
}

// 本地还没有这张原图时，按当前账号的封面 URL 下一份存下来
static void SLProfCoverPrefetch(void) {
    NSString *url = SLProfStr(SLProfKeyCover);
    if (!url.length) return;
    if (SLProfCoverAcctImage()) return;
    UIImage *hit = SLProfCoverCached(url);
    if (hit) { SLProfCoverPersistAcct(sSLCurAcct, hit); return; }
    // 巡检每拍都会进来：URL 过期时别每 0.8s 就重下一遍
    static NSTimeInterval sLastTry = 0;
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (now - sLastTry < 10.0) return;
    sLastTry = now;
    NSString *uid = [sSLCurAcct copy];
    SLProfLoadImage(url, ^(UIImage *img) {
        if (!img) return;
        SLProfCoverCachePut(url, img);
        SLProfCoverPersistAcct(uid, img);
    });
}

// 把一张现成的图按抖音自己的入口装进封面视图，再兜底贴一次 imageView。
// 返回 YES 表示这次真的换了图（巡检靠它决定要不要打日志）。
static BOOL SLProfPutCoverOn(id view, UIImage *img) {
    if (!view || !img) return NO;
    if (sSLCoverBusy) return NO;
    // 已经是这张了就不折腾（巡检每 0.8s 一次，没必要反复重建封面）
    id cur = SLProfCallObj(view, @"imageView");
    if ([cur isKindOfClass:[UIImageView class]] && ((UIImageView *)cur).image == img) return NO;
    sSLCoverBusy = YES;
    @try {
        if (o_coverImage) o_coverImage(view, NSSelectorFromString(@"configWithImage:"), img);
    } @catch (__unused NSException *e) { }
    id iv = SLProfCallObj(view, @"imageView");
    if ([iv isKindOfClass:[UIImageView class]]) {
        UIImageView *v = iv;
        NSMapTable *t = SLPaintOrig();
        if (![t objectForKey:v] && v.image) [t setObject:v.image forKey:v];
        v.image = img;
        v.contentMode = UIViewContentModeScaleAspectFill;
        v.clipsToBounds = YES;
    }
    sSLCoverBusy = NO;
    return YES;
}

static void SLProfApplyCoverImage(id view) {
    NSString *url = SLProfStr(SLProfKeyCover);
    if (!view || !url.length) return;
    sSLCoverWantURL = url;
    UIImage *hit = SLProfCoverAcctImage() ?: SLProfCoverCached(url);
    if (hit) {
        sSLCoverWantImg = hit;
        SLProfPutCoverOn(view, hit);
        return;
    }
    SLProfLoadImage(url, ^(UIImage *img) {
        if (!img) return;
        SLProfCoverCachePut(url, img);
        SLProfCoverPersistAcct(sSLCurAcct, img);
        if (![sSLCoverWantURL isEqualToString:url]) return;   // 期间又换人了
        sSLCoverWantImg = img;
        SLProfPutCoverOn(view, img);
    });
}

static void h_coverImage(id self, SEL _cmd, id img) {
    if (o_coverImage) o_coverImage(self, _cmd, img);
    if (SLProfGateLoose()) SLProfApplyCoverImage(self);
}

// 封面视图的两个配置入口：先让抖音照原样配好，再把图换成对方的。
// 顺序不能反 —— 反了就被抖音自己那次配置盖回去。
static void h_coverConfig(id self, SEL _cmd, id urls, id light, id dark) {
    if (o_coverConfig) o_coverConfig(self, _cmd, urls, light, dark);
    if (!SLProfGateLoose()) {
        NSString *u = SLProfFirstURL(urls);
        if (!u.length) u = SLProfCoverURL(urls);
        SLCoverCapture(urls, u);
        return;
    }
    SLProfApplyCoverImage(self);
    static BOOL sLogged = NO;
    if (!sLogged) { sLogged = YES; SLLog(@"COVER| 已把对方的封面图贴到背景上（URL 入口）"); }
}

static void h_coverList(id self, SEL _cmd, id coverList) {
    if (o_coverList) o_coverList(self, _cmd, coverList);
    if (!SLProfGateLoose()) {
        SLCoverCapture(coverList, SLProfCoverURL(coverList));
        return;
    }
    SLProfApplyCoverImage(self);
    static BOOL sLogged = NO;
    if (!sLogged) { sLogged = YES; SLLog(@"COVER| 已把对方的封面图贴到背景上（coverList 入口）"); }
}

// 每次布局之后确认一次。抖音的图后到、cell 复用、切换分页，最后都会被这一手按住。
static void (*o_coverLayout)(id, SEL);
static void h_coverLayout(id self, SEL _cmd) {
    if (o_coverLayout) o_coverLayout(self, _cmd);
    if (!sSLCoverWantImg || sSLCoverBusy) return;
    if (!SLProfGateLoose()) return;
    id iv = SLProfCallObj(self, @"imageView");
    if (![iv isKindOfClass:[UIImageView class]]) return;
    if (((UIImageView *)iv).image == sSLCoverWantImg) return;
    SLProfPutCoverOn(self, sSLCoverWantImg);
}

// AWEUserModel -profileCover / -whiteProfileCover：别人主页只记账，我页不再改返回值
// （改返回值等于骗抖音「我的封面是这张」，它自己还会再下载一次；直接贴图更干净）
static id (*o_profileCover)(id, SEL);
static id h_profileCover(id self, SEL _cmd) {
    id v = o_profileCover ? o_profileCover(self, _cmd) : nil;
    if (!SLProfGate() && [v isKindOfClass:[NSArray class]] && [(NSArray *)v count]) {
        NSString *u = SLProfCoverURL(v);
        SLCoverCapture(v, u);
        static BOOL sCapLogged = NO;
        if (!sCapLogged && u.length) {
            sCapLogged = YES;
            SLLog(@"COVER| 已从 model.profileCover 记下对方封面");
        }
    }
    return v;
}

static id (*o_whiteProfileCover)(id, SEL);
static id h_whiteProfileCover(id self, SEL _cmd) {
    id v = o_whiteProfileCover ? o_whiteProfileCover(self, _cmd) : nil;
    if (!SLProfGate() && [v isKindOfClass:[NSArray class]] && [(NSArray *)v count])
        SLCoverCapture(v, SLProfCoverURL(v));
    return v;
}

// 封面视图只在页面初次配置时被调一次。那次如果发生在认出「我」页之前，
// 替换就漏了，之后也不会重来 —— 主动在窗口里把封面视图找出来重贴一遍。
static void SLProfFindCoverViews(UIView *root, NSMutableArray *out) {
    if (!root || !out) return;
    if ([NSStringFromClass([root class]) isEqualToString:@"AWEProfileBannerBGCoverView"]) {
        [out addObject:root];
        return;
    }
    for (UIView *v in [root.subviews copy]) SLProfFindCoverViews(v, out);
}

static void SLProfForceCover(void) {
    if (!SLProfileEnabled() || !SLProfGateLoose()) return;   // 别人主页上绝不改背景
    NSString *url = SLProfStr(SLProfKeyCover);
    if (!url.length) {
        sSLCoverWantURL = nil;
        sSLCoverWantImg = nil;
        return;
    }

    // 换人了（同一个账号先后伪装两个对象）就必须把内存里旧那张丢掉，
    // 否则下面「sSLCoverWantImg 有图就直接贴」会把上一个人的封面又盖回去 ——
    // 这就是「补一下反而把别的背景同步过来」的另一半原因。
    if (![sSLCoverWantURL isEqualToString:url]) sSLCoverWantImg = nil;

    // 先把图拿到手：本机存过的那张最优先（URL 过期也照样有），其次内存/磁盘缓存
    sSLCoverWantURL = url;
    UIImage *cached = SLProfCoverAcctImage() ?: SLProfCoverCached(url);
    if (cached) {
        sSLCoverWantImg = cached;
        SLProfCoverPersistAcct(sSLCurAcct, cached);     // 顺手补一份本地原图
    } else {
        SLProfCoverPrefetch();                          // 内部限流，下好后下一拍就贴
    }

    NSMutableArray *views = [NSMutableArray array];
    for (UIScene *sce in [[UIApplication sharedApplication].connectedScenes copy]) {
        if (![sce isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [((UIWindowScene *)sce).windows copy]) SLProfFindCoverViews(w, views);
    }
    if (!views.count) {
        if (sSLCoverMissLog < 6) { sSLCoverMissLog++; SLLog(@"COVER| 没找到封面视图，跳过"); }
        return;
    }

    NSUInteger changed = 0;
    if (sSLCoverWantImg) {
        for (UIView *v in [views copy]) {
            if (SLProfPutCoverOn(v, sSLCoverWantImg)) changed++;
            [v setNeedsLayout];
        }
        if (changed) SLLog(@"COVER| 已重贴 %lu 处封面", (unsigned long)changed);
    } else {
        // 图还没下好：先让每个封面视图都发起下载，回调到了会自动贴上
        for (UIView *v in [views copy]) SLProfApplyCoverImage(v);
    }
}

#pragma mark - 作品列表 + 播放量（按对方的 id 联网拉）
//
// 主页九宫格由 AWEUserPostsDataManager 自己请求服务器再渲染。要它显示别人的作品，
// 最还原的办法不是「偷 dataSource 塞过去」，而是把这次请求里的 user_id / sec_user_id
// 换成对方的 —— 服务器直接返回对方那一整套：排序、分页、每条播放量、封面全是真的。
//
// 0.8.9 之前塞 dataSource 为什么没用：
//   ① 只在内存里，重启就没了；② 九宫格是 IGListKit，塞进去也不会重建 section；
//   ③ 换号时那份数组还挂在别人的 model 上，最容易串数据。
//
// 现在三层：请求参数换 id（主路）→ dataSource 兜底（万一某版本不读 getter）→ 页面重建。

static BOOL SLProfWorksEnabled(void) {
    return SLProfBool(SLProfKeyWorks, YES);      // 默认开
}

static NSMutableDictionary *sSLWorkSrc = nil;    // uid -> dataSource（内存兜底，可选）
static NSHashTable *sSLMyMgrs = nil;             // 我页的作品数据管理器（弱引用，不持有）
static char kSLPostsUIDKey;

static NSString *SLProfObjText(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}

// 私密作品不再从 dataSource 里删（条数一变 IGListKit 就炸），
// 所以判私密这件事挪到界面上做，这里不再需要。

static BOOL SLProfHidePrivateOn(void) {
    return SLProfBool(SLProfKeyHidePriv, NO);
}

// 每个 data manager 建出来时就知道它属于谁，挂到自己身上带走
static id (*o_postsInit)(id, SEL, id, id);
static id h_postsInit(id self, SEL _cmd, id uid, id sec) {
    id r = o_postsInit ? o_postsInit(self, _cmd, uid, sec) : nil;
    NSString *s = SLProfObjText(uid);
    if (s.length && ![s isEqualToString:@"0"]) {
        objc_setAssociatedObject(self, &kSLPostsUIDKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sSLMyMgrs) {
            // 按指针认，别用 isEqual: —— 这个类自己重写过比较，能力上也不需要「相等」语义
            sSLMyMgrs = [[NSHashTable alloc] initWithOptions:
                         (NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality)
                                                capacity:4];
        }
        [sSLMyMgrs addObject:self];
        if (sSLPostsMgrLog < 3) {
            sSLPostsMgrLog++;
            SLLog(@"WORKS| 记下作品管理器（uid=%@ · 共 %lu 个）", s,
                  (unsigned long)sSLMyMgrs.count);
        }
    }
    return r;
}

static id (*o_postsDS)(id, SEL);
static void (*o_postsSetDS)(id, SEL, id);
static void h_postsSetDS(id self, SEL _cmd, id ds) {
    // 只记录别人主页那份；「我」页那份绝不在这里注入
    NSString *uid = objc_getAssociatedObject(self, &kSLPostsUIDKey);
    if (uid.length && ds && (SLProfPageKind() == -1 || sSLCapOn)) {
        if (!sSLWorkSrc) sSLWorkSrc = [NSMutableDictionary dictionary];
        if (sSLWorkSrc.count > 12) [sSLWorkSrc removeAllObjects];
        sSLWorkSrc[uid] = ds;                       // 强引用：列表对象跟 model 一起留着
        NSUInteger n = [ds respondsToSelector:@selector(count)] ? [(NSArray *)ds count] : 0;
        if (n) SLLog(@"WORKS| 记住 %@ 的作品列表（%@，%lu 条）", uid,
                     NSStringFromClass([ds class]), (unsigned long)n);
    }
    if (o_postsSetDS) o_postsSetDS(self, _cmd, ds);
}

// 这个 manager 是不是「我」的。
// 认不出归属时按「我的」处理 —— 页面内部会 copy/重建 manager，
// 那些副本身上没有我们挂的标记，之前一律被当成别人的，于是请求参数没换、作品还是自己的。
static BOOL SLProfPostsIsMine(id mgr) {
    if (!mgr) return NO;
    NSString *owner = objc_getAssociatedObject(mgr, &kSLPostsUIDKey);
    if (!owner.length) return YES;
    if (!sSLProfMyUID.length) return YES;
    return [owner isEqualToString:sSLProfMyUID];
}

// 这个管理器「属于哪个账号」→ 读那一份预设。
// 换号那一下，作品管理器可能比 sSLCurAcct 先建出来（页面比 model 先走），
// 用全局的 sSLWorkWant 就会拿到上一个号的伪装对象，或者干脆还没切过来 → 直接拉回自己的作品。
static NSString *SLProfPostsOwner(id mgr) {
    return objc_getAssociatedObject(mgr, &kSLPostsUIDKey);
}

static NSString *SLProfWorkWantFor(id mgr) {
    NSString *owner = SLProfPostsOwner(mgr);
    if (owner.length) return SLProfStrForUID(SLProfKeyWant, owner);
    return sSLWorkWant;
}

static NSString *SLProfWorkSecFor(id mgr) {
    NSString *owner = SLProfPostsOwner(mgr);
    if (owner.length) return SLProfStrForUID(SLProfKeySec, owner);
    return SLProfStr(SLProfKeySec);
}

// 0.9.8：不再要求「此刻正站在我页」。
// 换号后的首刷往往发生在我们认出账号之前，用页面门去卡就会永远卡在「拉回自己的作品」，
// 只能重启才好 —— 这就是「切号作品不同步」的真正原因。
// 改成认归属：只有「这个管理器属于我们自己某个账号、而且那个账号存过伪装对象」才换参数。
// 别人主页的管理器 owner 里存的是对方的 uid，永远没有预设，天然不会被误换。
static BOOL SLProfPostsSpoofOn(id mgr) {
    if (!SLProfWorksEnabled()) return NO;
    if (sSLProfKindVal == -1) return NO;                 // 明确站在别人主页：立刻收手
    NSString *want = SLProfWorkWantFor(mgr);
    if (!want.length) return NO;
    NSString *owner = SLProfPostsOwner(mgr);
    if (owner.length) return ![want isEqualToString:owner];
    // 认不出归属（页面自己 copy 出来的副本）：退回老规则，但只要有伪装对象就干
    if (!SLProfPostsIsMine(mgr)) return NO;
    if (sSLProfMyUID.length && [want isEqualToString:sSLProfMyUID]) return NO;
    return sSLProfMyUID.length > 0;
}

static id (*o_postsUID)(id, SEL);
static id h_postsUID(id self, SEL _cmd) {
    id v = o_postsUID ? o_postsUID(self, _cmd) : nil;
    if (!SLProfPostsSpoofOn(self)) return v;
    NSString *want = SLProfWorkWantFor(self) ?: sSLWorkWant;
    static BOOL sLogged = NO;
    if (!sLogged) {
        sLogged = YES;
        SLLog(@"WORKS| 作品请求改用对方 id %@（联网拉取）", want);
    }
    return want;
}

static id (*o_postsSec)(id, SEL);
static id h_postsSec(id self, SEL _cmd) {
    id v = o_postsSec ? o_postsSec(self, _cmd) : nil;
    if (!SLProfPostsSpoofOn(self)) return v;
    NSString *sec = SLProfWorkSecFor(self);
    return sec.length ? sec : v;
}

// 有的版本请求参数是 -commonParams 现拼的，两个 id 都在里面
static id (*o_postsParams)(id, SEL);
static id h_postsParams(id self, SEL _cmd) {
    id v = o_postsParams ? o_postsParams(self, _cmd) : nil;
    if (!SLProfPostsSpoofOn(self) || ![v isKindOfClass:[NSDictionary class]]) return v;
    NSMutableDictionary *d = [(NSDictionary *)v mutableCopy];
    static BOOL sKeysLogged = NO;
    if (!sKeysLogged) {
        sKeysLogged = YES;
        SLLog(@"WORKS| 作品请求参数键：%@", [[d allKeys] componentsJoinedByString:@","]);
    }
    NSString *want = SLProfWorkWantFor(self) ?: sSLWorkWant;
    NSString *sec = SLProfWorkSecFor(self);
    for (NSString *k in @[@"user_id", @"uid", @"userID", @"author_id", @"to_user_id"]) {
        id old = d[k];
        if (!old) continue;
        d[k] = [old isKindOfClass:[NSNumber class]] ? @([want longLongValue]) : want;
    }
    if (sec.length) {
        for (NSString *k in @[@"sec_user_id", @"sec_uid", @"secUid", @"sec_user_uid"]) {
            if (d[k]) d[k] = sec;
        }
    }
    return d;
}

// 内存兜底：某个版本万一不读上面两个 getter，还能把记忆里的那份顶上。
//
// v0.9.2 的坑（0.9.3 修）：这里一度放宽成「总开关开 + 我页」就在 dataSource 里过滤私密作品，
// 甚至拿内存快照替换整个列表。dataSource 的条数要跟 collectionView 的 section 对得上，
// IGListKit 做 diff 时前后两次对象数量冷不丁变了，UICollectionView 直接抛
// 「Invalid update: invalid number of items」把进程带走 —— 表现就是「点开我的就闪退」。
//
// 结论：这个 getter 不再改任何东西，一律原样返回。
// 作品靠 h_postsParams 换 id 让服务器直接返回对方那份（条数由服务器给，天然一致）；
// 私密作品只在界面上藏，绝不动 dataSource。
static id h_postsDS(id self, SEL _cmd) {
    id orig = o_postsDS ? o_postsDS(self, _cmd) : nil;
    // 只留一行诊断：确认这个 manager 认的是谁
    if (orig && sSLPostsMgrLog < 6 && sSLWorkWant.length && SLProfPostsIsMine(self)) {
        sSLPostsMgrLog++;
        SLLog(@"WORKS| dataSource 原样返回 %lu 条（不在这里换列表）",
              (unsigned long)([orig isKindOfClass:[NSArray class]] ? [(NSArray *)orig count] : 0));
    }
    return orig;
}

static void SLProfCollectVCs(UIViewController *vc, NSMutableArray *out) {
    if (!vc || out.count > 200) return;
    [out addObject:vc];
    for (UIViewController *c in [vc.childViewControllers copy]) SLProfCollectVCs(c, out);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in [((UINavigationController *)vc).viewControllers copy])
            SLProfCollectVCs(c, out);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
        if (sel) SLProfCollectVCs(sel, out);
    }
    if (vc.presentedViewController) SLProfCollectVCs(vc.presentedViewController, out);
}

// （SLProfIMP 随「主动刷新作品」一起删掉了：0.9.8 起不再直接调页面的 refresh）

#pragma mark - 面包屑（硬崩没有异常栈，只能留个记号）
//
// 0.9.3 挂的 NSSetUncaughtExceptionHandler 只能抓到 ObjC 异常。
// 真机上这几次闪退一条 CRASH| 都没有 —— 属于信号级硬崩（野指针 / 栈溢出 / 库内部 assert），
// 那种死法什么都不留，日志就停在最后一行，只能靠猜。
// 所以做危险动作之前先把「我正在干嘛」写进文件，正常走完再抹掉。
// 下次启动读到它还躺在那儿，就知道上一轮死在这一步了。

static NSString *sSLStep = nil;

static NSString *SLProfStepPath(void) {
    NSString *dir = SLProfCacheDir();
    if (!dir.length) return nil;
    return [dir stringByAppendingPathComponent:@".prof_step"];
}

static void SLProfStep(NSString *name) {
    sSLStep = [name copy];
    NSString *p = SLProfStepPath();
    if (!p.length || !name.length) return;
    [name writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void SLProfStepDone(NSString *name) {
    if (name.length && ![sSLStep isEqualToString:name]) return;   // 已经是另一件事了，别误抹
    sSLStep = nil;
    NSString *p = SLProfStepPath();
    if (p.length) [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
}

// 启动时看一眼：上一轮是不是死在某个我们知道的危险动作上
static void SLProfCheckStepMark(void) {
    NSString *p = SLProfStepPath();
    if (!p.length) return;
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return;
    SLLog(@"PROF| 上次进程死在「%@」之后（没有 ObjC 异常，属于硬崩）", s);
    if ([s isEqualToString:@"acct.switch"]) {
        SLLog(@"PROF| 崩在换号那一下：这轮换号后的自动补一轮已延后，且不碰页面刷新");
    }
}

// 找到「我」页里的作品页 —— 只返回**一个**，而且必须是已经显示出来的那个。
//
// 0.9.3 的闪退就是这里：抖音「我」页把「作品 / 私密 / 喜欢」各挂了一个
// AWEPostWorkViewControllerV2，全都躺在 nav 栈里。一把踢到 4 个 = 4 个并发请求，
// 1.1 秒后又对 4 个页面各调一次 reloadDataWithDataSourceChanged 重建 section，
// IGListKit 发现 section 数和 collectionView 对不上，直接抛
// 「Invalid update: invalid number of items」把进程带走。
// 日志就停在「已让作品页按对方 id（…）重新拉取 · 4 处」那一行。
//
// 现在只刷当前真正显示的那一个；别的 tab 被选中时抖音自己会加载。
static NSArray *SLProfWorksVCs(void) {
    NSMutableArray *vcs = [NSMutableArray array];
    for (UIScene *sce in [[UIApplication sharedApplication].connectedScenes copy]) {
        if (![sce isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [((UIWindowScene *)sce).windows copy])
            SLProfCollectVCs(w.rootViewController, vcs);
    }

    UIViewController *pick = nil;
    for (UIViewController *vc in vcs) {
        if (![NSStringFromClass([vc class]) containsString:@"PostWork"]) continue;
        // 没加载 view / 不在窗口上的页面，调 refresh 等于替它硬开水，最容易出问题
        if (!vc.isViewLoaded || !vc.view.window) continue;
        pick = vc;
        break;
    }
    // 类名换了也不至于瞎：认「在我页里、能被要求重刷」的那个页面
    if (!pick) {
        for (UIViewController *vc in vcs) {
            if (SLProfKindFromVC(vc) != 1) continue;
            if (!vc.isViewLoaded || !vc.view.window) continue;
            if ([vc respondsToSelector:NSSelectorFromString(@"refreshDataWithCompletion:")] ||
                [vc respondsToSelector:NSSelectorFromString(@"refreshDataIsPullRefresh:completion:")]) {
                pick = vc;
                break;
            }
        }
    }
    return pick ? @[ pick ] : @[];
}

// 读一眼作品页现在的列表：条数 + 首条作者
static void SLProfWorksSnapshot(UIViewController *vc, NSUInteger *outN, NSString **outWho) {
    if (outN) *outN = 0;
    if (outWho) *outWho = nil;
    if (!vc) return;
    id dm = SLProfCallObj(vc, @"dataManager");
    id ds = dm ? SLProfCallObj(dm, @"dataSource") : nil;
    if (![ds isKindOfClass:[NSArray class]]) return;
    NSUInteger n = [(NSArray *)ds count];
    if (outN) *outN = n;
    if (!n) return;
    id first = [(NSArray *)ds firstObject];
    id author = SLProfCallObj(first, @"author");
    if (!author) author = SLProfCallObj(SLProfCallObj(first, @"awemeModel"), @"author");
    if (outWho) *outWho = SLProfObjText(author ? SLProfCallObj(author, @"userID") : nil);
}

// 作品同步：**只靠请求参数换 id**，一次 refresh 都不主动调。
//
// 两次血的教训：
//   0.9.5 进页就踢一次 refreshDataWithCompletion: —— 日志里踢完 1 秒进程消失；
//   0.9.7 改成每代最多补 3 次 —— 用户反馈「切换账号刷新主页会闪退」。
// 两次是同一个原因：我们那次 refresh 和页面自己的首刷 / 下拉刷新撞在同一个 dataSource 上，
// IGListKit 前后账对不上，直接是信号级崩溃（连 ObjC 异常都来不及抛，日志一条 CRASH| 都没有）。
//
// 0.9.8 起彻底不碰页面。作品换不换得对，全靠 userID / secUserID / commonParams 这三个 getter，
// 而它们现在按「这个管理器属于哪个账号」去读预设，换号那一下不用等 sSLCurAcct 先切过来。
// 这里只做只读观察：列表对不对、首条作品的播放量是多少，打一行给下一轮定位用。
static void SLProfWorksWatch(void) {
    if (!sSLWorkWant.length || !SLProfWorksEnabled() || !SLProfGateLoose()) return;
    static int sWatchedGen = -1;
    if (sWatchedGen == sSLWorksGen) return;

    NSArray *vcs = SLProfWorksVCs();
    if (!vcs.count) return;                                     // 作品页还没建出来
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    if (sSLOnMeSince <= 0 || now - sSLOnMeSince < 2.5) return;   // 让首刷先回来，别抢

    NSUInteger n = 0;
    NSString *who = nil;
    SLProfWorksSnapshot(vcs.firstObject, &n, &who);
    if (!n) return;                                             // 还在路上，下一拍再看
    sWatchedGen = sSLWorksGen;
    BOOL ok = [who isEqualToString:sSLWorkWant];
    SLLog(@"WORKS| 列表 %lu 条 · 首条作者 %@ · 想要 %@ · %@（不主动刷新）",
          (unsigned long)n, who ?: @"?", sSLWorkWant, ok ? @"对上" : @"没对上");

    // 作品封面上的播放量是服务器给的。抖音对「不是本人发的作品」经常直接回 0，
    // 这一行把服务端给的值打出来 —— 到底是它给的 0，还是被我们改成了 0，一看就知道。
    id dm = SLProfCallObj(vcs.firstObject, @"dataManager");
    id ds = dm ? SLProfCallObj(dm, @"dataSource") : nil;
    id first = ([ds isKindOfClass:[NSArray class]] && [(NSArray *)ds count])
               ? [(NSArray *)ds firstObject] : nil;
    id stats = SLProfCallObj(first, @"statistics") ?: SLProfCallObj(first, @"stats");
    id pc = stats ? SLProfCallObj(stats, @"playCount") : nil;
    SLLog(@"WORKS| 首条作品 播放=%@（服务端原值）· %@",
          SLProfObjText(pc) ?: @"nil",
          first ? NSStringFromClass([first class]) : @"nil");
}

#pragma mark - 头像
//
// 头像是 AWEUserModel 上的一组 getter（avatarThumb / avatarMedium / avatarLarger …）给出来的，
// header 里的 AWEAvatarImageView 也是拿着 user model 去读。所以最稳的办法不是自己造 URL，
// 而是把**对方那个真实 model** 存下来，我页读头像时原样返回对方的对象 —— 类型天然一致。
//
// v0.8.9：39.9.0 的头像字段叫 avatarLarger（不是 avatarLarge，后者根本不存在），
// 之前漏挂最大的那张，所以页面上一直是自己的头像。
// 另外重启后内存里没有对方的 model，这里再用保存的 URL 重建一个同款 AWEURLModel。
// 万一某条链路不读 getter，回我页时再把窗口里最大的那颗方形头像直接贴成对方的图。

static BOOL sSLAvatarBusy = NO;      // 防止 getter 里再回调自己

// 不是当前号、但自己也存过伪装头像（账号切换面板里的其他号）→ 按那份 URL 重建
static id SLProfAltAvatar(id model, id orig, NSString *getter) {
    if (sSLAvatarBusy) return orig;
    NSString *uid = SLProfModelUID(model);
    if (!uid.length) return orig;
    if (sSLCurAcct.length && [uid isEqualToString:sSLCurAcct]) return orig;
    NSString *url = SLProfStrForUID(SLProfKeyAvatar, uid);
    if (!url.length) return orig;
    Class uc = objc_getClass("AWEURLModel");
    if (!uc || (orig && ![orig isKindOfClass:uc])) return orig;
    sSLAvatarBusy = YES;
    id rb = SLProfURLModelFrom(url);
    sSLAvatarBusy = NO;
    if (!rb) return orig;
    static BOOL sAltLogged = NO;
    if (!sAltLogged) { sAltLogged = YES;
        SLLog(@"AVATAR| 另一个已伪装的号（%@）按预设重建头像", uid); }
    return rb;
}

static id SLProfAvatarDo(id model, id orig, NSString *getter) {
    if (sSLAvatarBusy) return orig;
    if (!SLProfGate()) return SLProfAltAvatar(model, orig, getter);
    if (!SLProfIsMe(model)) return SLProfAltAvatar(model, orig, getter);

    id other = sSLWorkWant.length ? sSLFakeUsers[sSLWorkWant] : nil;
    if (other && other != model) {
        sSLAvatarBusy = YES;
        id fake = SLProfCallObj(other, getter);
        sSLAvatarBusy = NO;
        if (fake && (!orig || [fake class] == [orig class])) {
            static BOOL sAvLogged = NO;
            if (!sAvLogged) { sAvLogged = YES; SLLog(@"AVATAR| model.%@ 已返回对方的头像对象", getter); }
            return fake;
        }
    }

    // 重启后 / 对方 model 已被回收：用保存的 URL 重建一份
    NSString *url = SLProfStr(SLProfKeyAvatar);
    if (!url.length) return orig;
    Class uc = objc_getClass("AWEURLModel");
    if (!uc || (orig && ![orig isKindOfClass:uc])) return orig;
    static NSString *sCachedKey = nil;
    static id sCachedModel = nil;
    id rebuilt = nil;
    if (sCachedModel && [sCachedKey isEqualToString:url]) {
        rebuilt = sCachedModel;
    } else {
        rebuilt = SLProfURLModelFrom(url);
        if (rebuilt) { sCachedKey = [url copy]; sCachedModel = rebuilt; }
    }
    if (!rebuilt) return orig;
    static BOOL sAvUrlLogged = NO;
    if (!sAvUrlLogged) {
        sAvUrlLogged = YES;
        SLLog(@"AVATAR| model.%@ 已用保存的 URL 重建头像（%@）", getter, url);
    }
    return rebuilt;
}

#define SL_AVATAR_HOOK(NAME, GETTER)                                   \
    static id (*o_##NAME)(id, SEL);                                    \
    static id h_##NAME(id self, SEL _cmd) {                            \
        id v = o_##NAME ? o_##NAME(self, _cmd) : nil;                  \
        return SLProfAvatarDo(self, v, GETTER);                        \
    }

SL_AVATAR_HOOK(avThumb,  @"avatarThumb")
SL_AVATAR_HOOK(avMedium, @"avatarMedium")
SL_AVATAR_HOOK(avLarger, @"avatarLarger")
SL_AVATAR_HOOK(av168,    @"avatar168")
SL_AVATAR_HOOK(av300,    @"avatar300")

// 从 model 里挑一张最清晰的头像 URL（抓快照 / 贴图兜底用）
static NSString *SLProfAvatarURL(id model) {
    if (!model) return nil;
    for (NSString *n in @[@"avatarLarger", @"avatar300", @"avatarMedium",
                          @"avatar168", @"avatarThumb"]) {
        id v = SLProfCallObj(model, n);
        NSString *s = SLProfURLString(v);
        if (!s.length) s = SLProfModelFirstURL(v);
        if (s.length) return s;
    }
    return SLProfFirstURL(SLProfCallObj(model, @"avatarURLs"));
}

// 在页面里找「最像头像」的那张图：接近正方形、尺寸 44~200、位于上半屏
static UIImageView *SLProfBigSquareImage(UIView *root, UIView *win, CGFloat *outW) {
    UIImageView *best = nil;
    CGFloat bestW = 0;
    for (UIView *v in [root.subviews copy]) {
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


// 「隐藏私密作品」除了过滤 dataSource，页面上那个「私密作品」入口也要收起，
// 否则点进去还是自己真实的私密列表。
static int sSLPrivHits = 0;         // 这一轮扫到几个含「私密」的控件（诊断用）
static void SLProfHidePrivateIn(UIView *root);
static void SLProfHidePrivateUI(void) {
    if (!SLProfHidePrivateOn()) return;
    // 面板拨开关时页面正被我们自己的浮窗盖着（kind 会被算成 0），
    // 所以这里用「我页出现过」的松门，别只认 kind==1
    if (!sSLProfOnMePage && sSLProfKindVal != 1) return;
    sSLPrivHits = 0;
    for (UIScene *sce in [[UIApplication sharedApplication].connectedScenes copy]) {
        if (![sce isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [((UIWindowScene *)sce).windows copy]) SLProfHidePrivateIn(w);
    }
    // 开关开着却一条都没命中，说明界面上那排根本没有「私密」这两个字
    // （账号没有私密作品时抖音就不显示这个 tab）—— 不是我们没干活。
    static BOOL sScanLogged = NO;
    if (!sScanLogged && sSLPrivHits == 0) {
        sScanLogged = YES;
        SLLog(@"PROF| 私密扫描：界面上没有带「私密」的控件（可能这个账号没有私密作品）");
    }
}

// 我们自己面板里的「隐藏私密作品」这一行也带「私密」两个字 —— 别把自己的开关藏了
static BOOL SLProfInOwnView(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        if ([NSStringFromClass([p class]) hasPrefix:@"SL"]) return YES;
        UIResponder *r = p.nextResponder;
        if ([r isKindOfClass:[UIViewController class]] &&
            [NSStringFromClass([r class]) hasPrefix:@"SL"]) return YES;
    }
    return NO;
}

// 只设 hidden 会留一个空洞（那个 tab 仍占着宽度）。
// 这里把宽度压到 0，并挂一次父容器的 layoutSubviews —— 否则它下次重排又把宽度算回来，
// 屏幕上就是「藏一下 → 闪回来 → 再藏」，比不藏还难看。
static char kSLPrivVictimKey;
static char kSLPrivOrigWKey;
static BOOL sSLPrivBusy = NO;
static NSMutableDictionary *sSLPrivOrigIMPs = nil;   // 类名 -> 原 layoutSubviews

static void (*SLPrivOrigLayout(Class c))(id, SEL) {
    if (!sSLPrivOrigIMPs) return NULL;
    NSValue *v = sSLPrivOrigIMPs[NSStringFromClass(c)];
    return v ? (void (*)(id, SEL))[v pointerValue] : NULL;
}

static void SLProfCollapseVictim(UIView *container) {
    UIView *victim = objc_getAssociatedObject(container, &kSLPrivVictimKey);
    if (!victim || victim.superview != container) return;
    if (!victim.hidden) victim.hidden = YES;
    victim.alpha = 0;
    victim.userInteractionEnabled = NO;
    CGRect r = victim.frame;
    if (r.size.width > 0.5) victim.frame = CGRectMake(r.origin.x, r.origin.y, 0, r.size.height);
}

static void h_privContainerLayout(id self, SEL _cmd) {
    void (*orig)(id, SEL) = SLPrivOrigLayout(object_getClass(self));
    if (orig) orig(self, _cmd);
    if (sSLPrivBusy) return;
    if (!objc_getAssociatedObject(self, &kSLPrivVictimKey)) return;
    sSLPrivBusy = YES;
    @try { SLProfCollapseVictim(self); } @catch (__unused NSException *e) { }
    sSLPrivBusy = NO;
}

static void SLProfHookPrivContainer(Class c) {
    if (!c) return;
    if (!sSLPrivOrigIMPs) sSLPrivOrigIMPs = [NSMutableDictionary dictionary];
    NSString *cn = NSStringFromClass(c);
    if (sSLPrivOrigIMPs[cn]) return;
    Method m = SLProfExact(c, @selector(layoutSubviews));
    if (!m) return;
    IMP o = method_getImplementation(m);
    if (o == (IMP)h_privContainerLayout) return;
    sSLPrivOrigIMPs[cn] = [NSValue valueWithPointer:o];
    method_setImplementation(m, (IMP)h_privContainerLayout);
}

static void SLProfHidePrivateInDepth(UIView *root, int depth) {
    if (!root || root.hidden || depth > 40) return;
    if (SLProfInOwnView(root)) return;
    NSString *t = nil;
    if ([root isKindOfClass:[UILabel class]]) t = ((UILabel *)root).text;
    else if ([root isKindOfClass:[UIButton class]])
        t = [((UIButton *)root) titleForState:UIControlStateNormal];
    if (t.length && [t containsString:@"私密"]) {
        sSLPrivHits++;
        UIView *anc = root, *target = nil;
        for (int i = 0; i < 6 && anc.superview; i++) {
            anc = anc.superview;
            if ([anc isKindOfClass:NSClassFromString(@"UICollectionViewCell")] ||
                [anc isKindOfClass:NSClassFromString(@"UITableViewCell")]) { target = anc; break; }
            // 不是 cell 的话，退到「只包着这一小截」的容器就停（比如「作品 / 私密」那个分段）
            if (!target && CGRectGetWidth(anc.bounds) < 220 && CGRectGetHeight(anc.bounds) < 90)
                target = anc;
        }
        UIView *hide = target ?: root.superview ?: root;
        hide.hidden = YES;
        hide.alpha = 0;
        // 只藏不留洞：整行的那种连高度一起压 0（只压宽度会留下一条空白横带，很难看）；
        // 分段控件里的 tab 只压宽度，压高度会把整条挤没。
        CGRect hf = hide.frame;
        if (CGRectGetWidth(hf) > 260) {
            hide.frame = CGRectMake(hf.origin.x, hf.origin.y, 0, 0);
        } else if (CGRectGetWidth(hf) > 0.5) {
            hide.frame = CGRectMake(hf.origin.x, hf.origin.y, 0, hf.size.height);
        }
        // 小容器（「作品 / 私密」那种分段条）额外盯住父容器的每次 layout
        UIView *box = hide.superview;
        if (box && ![box isKindOfClass:[UIStackView class]] &&
            CGRectGetHeight(box.bounds) < 140 && CGRectGetWidth(box.bounds) < 500) {
            objc_setAssociatedObject(hide, &kSLPrivOrigWKey,
                                     @(CGRectGetWidth(hide.frame)), OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(box, &kSLPrivVictimKey, hide, OBJC_ASSOCIATION_ASSIGN);
            SLProfHookPrivContainer(object_getClass(box));
            SLProfCollapseVictim(box);
        }
        static BOOL sLogged = NO;
        if (!sLogged) { sLogged = YES; SLLog(@"PROF| 已隐起「私密作品」入口（整行压平，不留空洞）"); }
        return;
    }
    for (UIView *v in [root.subviews copy]) SLProfHidePrivateInDepth(v, depth + 1);
}

static void SLProfHidePrivateIn(UIView *root) {
    @try {
        SLProfHidePrivateInDepth(root, 0);
    } @catch (NSException *e) {
        SLLog(@"PROF| 隐藏私密作品时出了点问题：%@", e.reason ?: @"?");
    }
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

    // 背景图：model.profileCover 本身就是 NSArray<AWEProfileCoverURLModel *>，
    // 元素里带 urlModel（AWEURLModel.urlList）+ 浅色/深色蒙层色。
    // v0.8.8 还按 profileCover.coverList 多挖了一层，所以日志里一直是「无背景」。
    id covers = SLProfCallObj(model, @"profileCover");
    if (![covers isKindOfClass:[NSArray class]] || [(NSArray *)covers count] == 0)
        covers = SLProfCallObj(model, @"whiteProfileCover");
    if ([covers isKindOfClass:[NSArray class]]) {
        NSString *cu = SLProfCoverURL(covers);
        if (cu.length) out[@"cover"] = cu;
        id first = [(NSArray *)covers firstObject];
        id lc = SLProfCallObj(first, @"lightCoverColor");
        id dc = SLProfCallObj(first, @"darkCoverColor");
        if ([lc isKindOfClass:[NSString class]] && [(NSString *)lc length]) out[@"coverLight"] = lc;
        if ([dc isKindOfClass:[NSString class]] && [(NSString *)dc length]) out[@"coverDark"] = dc;
    }

    // 主页标识：专属会员 / 群聊 / 橱窗 —— 对方有的才记下来，套用时按需打开
    if (SLProfCallBool(model, @"hasMembership")) out[@"member"] = @"1";
    if (SLProfCallBool(model, @"canShowGroupCard")) out[@"group"] = @"1";
    if (SLProfCallBool(model, @"withShopEntry") ||
        SLProfCallBool(model, @"withFusionShopEntry") ||
        SLProfCallBool(model, @"withTaobaoShopEntry") ||
        SLProfCallBool(model, @"hasAwemeGoodsEntry")) out[@"shop"] = @"1";

    // 头像：header 用的那几张里挑最清晰的存一份 URL（重启后靠它兜底重建）
    NSString *av = SLProfAvatarURL(model);
    if (av.length) out[@"avatar"] = av;

    // 性别 / 年龄 / 现成的「女 · 22岁」
    NSInteger g = SLProfCallInt(model, @"gender");
    if (g > 0) out[@"gender"] = [NSString stringWithFormat:@"%ld", (long)g];
    NSInteger age = SLProfCallInt(model, @"userAge");
    if (age > 0) out[@"age"] = [NSString stringWithFormat:@"%ld", (long)age];
    id gt = SLProfCallObj(model, @"genderDisplayString");
    if ([gt isKindOfClass:[NSString class]] && [(NSString *)gt length]) out[@"genderText"] = gt;

    // 地区 / IP 属地 / 认证 / 学校 —— 主页上看得见的都抄过来
    for (NSString *f in SLExtraFields()) {
        id ev = SLProfCallObj(model, f);
        if ([ev isKindOfClass:[NSString class]] && [(NSString *)ev length]) out[f] = ev;
    }
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
    for (UIView *v in [root.subviews copy]) {
        UIView *r = SLProfFindNavContainer(v);
        if (r) return r;
    }
    return nil;
}

// 找导航容器里最靠左的那颗可点控件（就是返回按钮）
static UIView *SLProfFindLeftControl(UIView *root, UIView *host) {
    UIView *best = nil;
    CGFloat bestX = CGFLOAT_MAX;
    for (UIView *v in [root.subviews copy]) {
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
        for (UIWindow *w in [((UIWindowScene *)s).windows copy]) {
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
            if (![pf isKindOfClass:[NSArray class]] || ![(NSArray *)pf count])
                pf = SLProfCallObj(um, @"whiteProfileCover");
            if ([pf isKindOfClass:[NSArray class]] && [(NSArray *)pf count])
                SLCoverRemember(uid, pf, SLProfCoverURL(pf));
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
    sSLWasOnMe = YES;
    // 每次进来都算新的一代：作品要重新按对方 id 拉，不能因为「这个号刷过」就跳过
    sSLWorksGen++;
    IMP o = SLProfFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);

    // 头图 / 头像 / 九宫格在页面出现时可能已经按真实资料配好了，这里补几遍：
    // 页面渲染、接口回填、列表复用都发生在这两三秒里，只补一次经常赶不上。
    // （真机上这个回调有时根本不触发，所以真正的兜底是 SLProfTick 的巡检）
    for (int i = 0; i < 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((0.55 + 0.9 * i) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLProfTick();
        });
    }
}

static void h_profLeavePage(id self, SEL _cmd, BOOL animated) {
    if (sSLProfOnMePage) SLLog(@"PROF| 离开本人主页，恢复原样");
    sSLProfOnMePage = NO;
    sSLProfGateUntil = 0;
    IMP o = SLProfFindOrig(self, _cmd);
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
}

#pragma mark - 驻留巡检（v0.9.2 的核心）
//
// 0.9.1 把「背景图 / 年龄地区 / 私密入口 / 作品重拉」全挂在容器的 viewDidAppear: 后面。
// 真机日志：整场都没有 `PROF| 进入本人主页` —— 39.9.0 这次根本没触发那个回调
// （容器早就在，或者压根走的是另一个类），于是这一整串静默不生效：
// 背景重启没图、年龄地区不动、私密入口还在、作品没人去踢。
//
// 不再赌回调：只要「我」页在，就每 0.8 秒确认一遍，缺什么补什么。
// 每一步内部都有「已经对了就立刻返回」的短路，稳定之后几乎不产生开销。

// v0.9.3：上一轮如果是被我们的异常带崩的，这一轮先保守一点 ——
// 只保留「只改值、不动结构」的活（封面上图 / 头像 / 数字），
// 文本改写、私密隐藏、作品重拉先停一轮，别再一进「我的」就闪退。
static BOOL sSLProfSafeMode = NO;

static NSString *SLProfCrashMarkPath(void) {
    NSString *dir = SLProfCacheDir();
    if (!dir.length) return nil;
    return [dir stringByAppendingPathComponent:@".prof_crash"];
}

static void SLProfWriteCrashMark(void) {
    NSString *p = SLProfCrashMarkPath();
    if (!p.length) return;
    [@"1" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void SLProfCheckCrashMark(void) {
    NSString *p = SLProfCrashMarkPath();
    if (!p.length) return;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
    if (!a) return;
    NSDate *d = a[NSFileModificationDate];
    NSTimeInterval age = d ? -[d timeIntervalSinceNow] : 1e9;
    [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    if (age >= 0 && age < 1800) {
        sSLProfSafeMode = YES;
        SLLog(@"PROF| 上次异常退出（%d 分钟前），本次先走保守模式", (int)(age / 60));
    }
}

static void SLProfTick(void) {
    if (![NSThread isMainThread]) return;
    static BOOL sInTick = NO;
    if (sInTick) return;              // 定时器在 CommonModes 里，滚动时会重入，必须挡一下
    sInTick = YES;

    if (!SLProfileEnabled()) { sSLWasOnMe = NO; sInTick = NO; return; }

    int kind = SLProfPageKind();
    // 「我页出现过」这个闩只有严格门会放下；离开后如果没人再走严格门，它会一直开着，
    // 于是在别的 tab 上也继续替换。连续三拍看不见我页就自己收掉（页面切换那 1~2 拍不算）。
    if (kind == 0 && !sSLProfTopIsOurs) {
        if (++sSLOffTicks >= 3) sSLProfOnMePage = NO;
    } else {
        sSLOffTicks = 0;
    }
    BOOL onMe = (kind == 1) || (sSLProfKindVal == 1) || sSLProfOnMePage;
    if (!onMe || !SLProfGateLoose()) {
        if (sSLWasOnMe) { sSLWasOnMe = NO; SLLog(@"PROF| 我页不在，巡检待机"); }
        sInTick = NO;
        return;
    }
    if (!sSLWasOnMe) {
        sSLWasOnMe = YES;
        // 每次回到「我」页都算新的一代：作品要按对方 id 重新判一次
        sSLWorksGen++;
        // 作品那边「页面站稳了没有」从这一刻起算，别跟首刷抢
        sSLOnMeSince = [NSProcessInfo processInfo].systemUptime;
        SLLog(@"PROF| 我页在，开始驻留巡检（缺什么补什么）%@", sSLProfSafeMode ? @"· 保守模式" : @"");
    }

    sSLTickCount++;

    // 每一步单独兜异常：万一抖音某个版本在某个环节抛异常，
    // 顶多是这一项不生效，不能把整个 App 带走。
#define SL_TICK_STEP(NAME, CODE)                                          \
    @try { CODE; }                                                        \
    @catch (NSException *e) {                                             \
        static BOOL sOnce_##NAME = NO;                                     \
        if (!sOnce_##NAME) { sOnce_##NAME = YES;                           \
            SLLog(@"PROF| 巡检「%s」出异常：%@", #NAME, e.reason ?: @"?"); } \
    }

    SL_TICK_STEP(cover,   SLProfCoverPrefetch(); SLProfForceCover());
    if (!sSLProfSafeMode) SL_TICK_STEP(ageloc, SLProfApplyAgeLocationNow());
    if (!sSLProfSafeMode && (sSLTickCount % 2 == 0)) SL_TICK_STEP(priv, SLProfHidePrivateUI());
    if (!sSLProfSafeMode) SL_TICK_STEP(works, SLProfWorksWatch());
    if (sSLTickCount % 4 == 0) SL_TICK_STEP(avatar, SLProfPaintAvatar());
#undef SL_TICK_STEP

    sInTick = NO;
}

static void SLProfStartTicker(void) {
    static BOOL sStarted = NO;
    if (sStarted) return;
    sStarted = YES;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.8 repeats:YES
                                          block:^(NSTimer *timer) { (void)timer; SLProfTick(); }];
    // CommonModes：滚动时也要跑，不然一滑就停摆
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
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

// 换号闪退如果真是我们引起的，至少要留下是什么异常、炸在哪一行。
// 只挂未捕获异常（ObjC 异常都能抓到），不改信号处理。
static void SLProfUncaught(NSException *e) {
    NSString *name = e.name ?: @"?";
    NSString *reason = e.reason ?: @"?";
    NSString *stack = [[e callStackSymbols] componentsJoinedByString:@"\n"];
    SLLog(@"CRASH| %@: %@\n%@", name, reason, stack);
    // 留个记号：下次启动先走保守模式，别一进「我的」就再崩一遍
    SLProfWriteCrashMark();
}

void SLProfileStart(void) {
    if (sSLProfStarted) return;
    sSLProfStarted = YES;
    NSSetUncaughtExceptionHandler(&SLProfUncaught);
    SLProfCheckCrashMark();    // 上次挂在我们的异常里？这轮先保守
    SLProfCheckStepMark();     // 上次是硬崩？看看死在哪个危险动作上

    SLProfMigrateLegacy();     // 老版本的单账号预设搬到 owner 名下，只做一次

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

    // 主页背景图：profileCover 是真正的数据源；视图层两个入口也兜住
    {
        SLProfHookGetter(user, NSSelectorFromString(@"profileCover"),
                         (IMP)h_profileCover, (IMP *)&o_profileCover, @"profileCover");
        SLProfHookGetter(user, NSSelectorFromString(@"whiteProfileCover"),
                         (IMP)h_whiteProfileCover, (IMP *)&o_whiteProfileCover, @"whiteProfileCover");

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
        // 直接收图的那个入口：换成对方的图最稳的一条路
        Method ci = cover ? SLProfExact(cover, NSSelectorFromString(@"configWithImage:")) : NULL;
        if (ci && method_getNumberOfArguments(ci) == 3) {
            o_coverImage = (void (*)(id, SEL, id))method_getImplementation(ci);
            method_setImplementation(ci, (IMP)h_coverImage);
            SLLog(@"PROF| 已挂 cover.configImage @ AWEProfileBannerBGCoverView");
        } else {
            SLLog(@"PROF| 跳过 cover.configImage：类或方法不存在");
        }
        // 每次布局后再确认一次：抖音自己那张图后到也不会把我们盖掉
        Method ly = cover ? SLProfExact(cover, @selector(layoutSubviews)) : NULL;
        if (ly && method_getNumberOfArguments(ly) == 2) {
            o_coverLayout = (void (*)(id, SEL))method_getImplementation(ly);
            method_setImplementation(ly, (IMP)h_coverLayout);
            SLLog(@"PROF| 已挂 cover.layoutSubviews @ AWEProfileBannerBGCoverView");
        } else {
            SLLog(@"PROF| 跳过 cover.layoutSubviews：类或方法不存在");
        }
    }

    // 头像：我页读头像时返回对方 model 的那份对象（没有就用保存的 URL 重建）
    {
        Class user2 = objc_getClass("AWEUserModel");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatarThumb"),
                         (IMP)h_avThumb, (IMP *)&o_avThumb, @"avatarThumb");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatarMedium"),
                         (IMP)h_avMedium, (IMP *)&o_avMedium, @"avatarMedium");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatarLarger"),
                         (IMP)h_avLarger, (IMP *)&o_avLarger, @"avatarLarger");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatar168"),
                         (IMP)h_av168, (IMP *)&o_av168, @"avatar168");
        SLProfHookGetter(user2, NSSelectorFromString(@"avatar300"),
                         (IMP)h_av300, (IMP *)&o_av300, @"avatar300");
    }

    // 性别 / 年龄 / 地区 / 认证 / 学校：昵称下面那行和认证标识，全部跟着对方走
    {
        Class u3 = objc_getClass("AWEUserModel");
        SLProfHookIntGetter(u3, NSSelectorFromString(@"gender"),
                            (IMP)h_gender, (IMP *)&o_gender, @"gender");
        SLProfHookIntGetter(u3, NSSelectorFromString(@"userAge"),
                            (IMP)h_userAge, (IMP *)&o_userAge, @"userAge");
        SLProfHookGetter(u3, NSSelectorFromString(@"genderDisplayString"),
                         (IMP)h_genderText, (IMP *)&o_genderText, @"genderDisplayString");
        SLProfHookGetter(u3, NSSelectorFromString(@"city"),
                         (IMP)h_city, (IMP *)&o_city, @"city");
        SLProfHookGetter(u3, NSSelectorFromString(@"province"),
                         (IMP)h_province, (IMP *)&o_province, @"province");
        SLProfHookGetter(u3, NSSelectorFromString(@"district"),
                         (IMP)h_district, (IMP *)&o_district, @"district");
        SLProfHookGetter(u3, NSSelectorFromString(@"ipLocation"),
                         (IMP)h_ipLocation, (IMP *)&o_ipLocation, @"ipLocation");
        SLProfHookGetter(u3, NSSelectorFromString(@"location"),
                         (IMP)h_location, (IMP *)&o_location, @"location");
        SLProfHookGetter(u3, NSSelectorFromString(@"verifyInfo"),
                         (IMP)h_verifyInfo, (IMP *)&o_verifyInfo, @"verifyInfo");
        SLProfHookGetter(u3, NSSelectorFromString(@"customVerifyInfo"),
                         (IMP)h_customVerifyInfo, (IMP *)&o_customVerifyInfo, @"customVerifyInfo");
        SLProfHookGetter(u3, NSSelectorFromString(@"schoolName"),
                         (IMP)h_schoolName, (IMP *)&o_schoolName, @"schoolName");
    }

    // 性别 / 年龄 / 地区：主页那一排按钮是 cell 自己拼的标题，配好之后改成对方的
    SLProfHookOneObjVoid(objc_getClass("AWEProfileHeaderAgeAndLocationCollectionViewCell"),
                         @"configWithHeaderContext:",
                         (IMP)h_ageLocConfig, (IMP *)&o_ageLocConfig, @"header.ageLocation");

    // 获赞 / 粉丝 / 关注 / 互关：header 统计 cell 收文本的那一环（大数字兜底）
    for (NSString *cn in @[@"AWEProfileHeaderSocialStatisticCollectionViewCell",
                           @"AWEProfileHeaderSocialStatisticCollectionViewCellV2"]) {
        Class cc = objc_getClass(cn.UTF8String);
        if (!cc) continue;
        SLProfHookOneObjVoid(cc, @"updateFavoritedCount:",
                             (IMP)h_cellFav, (IMP *)&o_cellFav, @"statCell.praise");
        SLProfHookOneObjVoid(cc, @"updateFansCount:",
                             (IMP)h_cellFans, (IMP *)&o_cellFans, @"statCell.fans");
        SLProfHookOneObjVoid(cc, @"updateFollowCount:",
                             (IMP)h_cellFollow, (IMP *)&o_cellFollow, @"statCell.follow");
        SLProfHookOneObjVoid(cc, @"updateFriendsCount:",
                             (IMP)h_cellFriend, (IMP *)&o_cellFriend, @"statCell.friend");
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
            // 请求里的那两个人：换成对方的，服务器就按对方 id 返回作品
            SLProfHookGetter(posts, NSSelectorFromString(@"userID"),
                             (IMP)h_postsUID, (IMP *)&o_postsUID, @"posts.userID");
            SLProfHookGetter(posts, NSSelectorFromString(@"secUserID"),
                             (IMP)h_postsSec, (IMP *)&o_postsSec, @"posts.secUserID");
            SLProfHookGetter(posts, NSSelectorFromString(@"commonParams"),
                             (IMP)h_postsParams, (IMP *)&o_postsParams, @"posts.commonParams");
        } else {
            SLLog(@"PROF| 跳过作品列表：AWEUserPostsDataManager 不存在");
        }
    }

    // 「我」页容器：挂 appear / disappear 当第二道门，并留下现场日志
    SLProfHookPageLifecycle(objc_getClass("AWEProfileTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileMergedTabContainerViewController"));
    SLProfHookPageLifecycle(objc_getClass("AWEProfileBaseContainerViewController"));

    SLLog(@"PROF| ==== 主页伪装 v%@ · 已挂载 · 快照 %lu 个 ====", SLProfVersion, (unsigned long)SLSnapList().count);
    SLProfStartTicker();       // 0.8s 驻留巡检：不依赖任何一次 viewDidAppear 恰好触发
    // 账号要等我页出现才认得出，晚点再打一行状态，免得开局那行永远是「账号 ?」
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SLLog(@"PROF| 状态：开=%d · 账号 %@ · 已填 %ld 项 · 作品源 %@",
              SLProfileEnabled(), sSLCurAcct ?: @"?", (long)SLProfileFilledCount(),
              sSLWorkWant.length ? sSLWorkWant : @"无");
    });

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
    SLProfPageKind();          // 顺便认出当前账号，写预设才落到正确的账号名下
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return 3;
    if (s == 1) return 6;      // 昵称/抖音号/简介/性别/年龄/地区
    return 6;                  // 作品/关注/粉丝/获赞/互关/播放量
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv;
    if (s == 0) return sSLCurAcct.length ? [NSString stringWithFormat:@"账号 %@", sSLCurAcct] : nil;
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
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.tag = ip.row;
        if (ip.row == 0) sw.on = SLProfileEnabled();
        else if (ip.row == 1) sw.on = SLProfWorksEnabled();
        else sw.on = SLProfHidePrivateOn();
        [sw addTarget:self action:@selector(sl_toggle:) forControlEvents:UIControlEventValueChanged];
        cell.textLabel.text = (ip.row == 0) ? @"启用"
                            : (ip.row == 1) ? @"模拟作品" : @"隐藏私密作品";
        if (ip.row != 0) {
            cell.detailTextLabel.text = (ip.row == 1) ? @"按对方 id 联网拉取" : @"我页不显示自己的私密";
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        }
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (ip.section == 1) {
        NSArray *titles = @[@"昵称", @"抖音号", @"简介", @"性别", @"年龄", @"地区"];
        cell.textLabel.text = titles[ip.row];
        NSString *v = nil;
        if (ip.row == 3) {
            NSString *g = SLProfStr(SLProfKeyGender);
            v = [g isEqualToString:@"1"] ? @"男" : ([g isEqualToString:@"2"] ? @"女" : nil);
        } else if (ip.row == 4) {
            v = SLProfStr(SLProfKeyAge);
        } else if (ip.row == 5) {
            v = SLExtraStr(@"city") ?: SLExtraStr(@"location");
        } else {
            NSArray *keys = @[SLProfKeyNickname, SLProfKeyUID, SLProfKeySignature];
            v = SLProfStr(keys[ip.row]);
        }
        cell.detailTextLabel.text = v.length ? v : @"未设置";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    NSArray *titles = @[@"作品", @"关注", @"粉丝", @"获赞", @"互关", @"播放量"];
    NSString *key = @[SLProfKeyAweme, SLProfKeyFollowing, SLProfKeyFollower,
                      SLProfKeyLike, SLProfKeyFriend, SLProfKeyPlay][ip.row];
    cell.textLabel.text = titles[ip.row];
    NSString *v = SLProfStr(key);
    cell.detailTextLabel.text = v.length ? v : @"未设置";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)sl_toggle:(UISwitch *)sw {
    switch (sw.tag) {
        case 0: SLProfSetBool(sw.on, SLProfKeyEnabled);  SLLog(@"PROF| 总开关 = %d", sw.on); break;
        case 1: SLProfSetBool(sw.on, SLProfKeyWorks);    SLLog(@"PROF| 模拟作品 = %d", sw.on); break;
        case 2: SLProfSetBool(sw.on, SLProfKeyHidePriv); SLLog(@"PROF| 隐藏私密作品 = %d", sw.on);
                if (sw.on) SLProfHidePrivateUI();
                break;
        default: break;
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) return;

    // 性别：给三个选项，别让用户去记「1 男 2 女」
    if (ip.section == 1 && ip.row == 3) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"性别"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        void (^setG)(NSString *) = ^(NSString *v) {
            SLProfSetStr(v, SLProfKeyGender);
            SLProfSetStr(nil, SLProfKeyGenderTxt);      // 清掉旧拼接串，按新数字重算
            [self.tableView reloadData];
            SLLog(@"PROF| 设置 性别 = %@", v.length ? v : @"不显示");
        };
        [sheet addAction:[UIAlertAction actionWithTitle:@"男" style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *a) { setG(@"1"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"女" style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *a) { setG(@"2"); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"不显示" style:UIAlertActionStyleDestructive
                                               handler:^(__unused UIAlertAction *a) { setG(nil); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = tv;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }

    NSString *title = nil, *key = nil;
    BOOL isArea = NO;
    UIKeyboardType kb = UIKeyboardTypeDefault;

    if (ip.section == 1) {
        if (ip.row == 0) { title = @"昵称"; key = SLProfKeyNickname; }
        else if (ip.row == 1) { title = @"抖音号"; key = SLProfKeyUID; }
        else if (ip.row == 2) { title = @"简介"; key = SLProfKeySignature; }
        else if (ip.row == 4) { title = @"年龄"; key = SLProfKeyAge; kb = UIKeyboardTypeNumberPad; }
        else { title = @"地区"; isArea = YES; }
    } else {
        if (ip.row == 0) { title = @"作品数"; key = SLProfKeyAweme; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 1) { title = @"关注数"; key = SLProfKeyFollowing; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 2) { title = @"粉丝数"; key = SLProfKeyFollower; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 3) { title = @"获赞数"; key = SLProfKeyLike; kb = UIKeyboardTypeNumberPad; }
        else if (ip.row == 4) { title = @"互关数"; key = SLProfKeyFriend; kb = UIKeyboardTypeNumberPad; }
        else { title = @"播放量"; key = SLProfKeyPlay; kb = UIKeyboardTypeNumberPad; }
    }
    if (!key && !isArea) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = isArea ? (SLExtraStr(@"city") ?: SLExtraStr(@"location")) : SLProfStr(key);
        tf.keyboardType = kb;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = ac.textFields.firstObject.text;
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length > 120) text = [text substringToIndex:120];
        if (isArea) {
            // 地区同时写 city / province / location：页面上那一排可能读其中任何一个
            SLProfSetExtra(@"city", text);
            SLProfSetExtra(@"province", text);
            SLProfSetExtra(@"district", nil);
            SLProfSetExtra(@"location", text);
        } else {
            SLProfSetStr(text, key);
        }
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
