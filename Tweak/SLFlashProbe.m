// v0.5.5：闪图字段勘察（只读探测）
//
// 要回答的问题只有一个：抖音私聊的「闪图」和普通图片，在模型层到底差在哪？
//   ① 是否存在独立的闪图消息类（名字里带 Flash / Burn / Ephemeral）；
//   ② 闪图标记是 ext 字典里的一个字段，还是消息模型上的独立属性。
//
// v0.5.4 的教训：一口气 dump 上千个类方法、每行日志一次 fsync —— 装完直接卡成 PPT，
// 而且 FLASH 全命中了电商「FlashSale」秒杀业务类，一条有用信息都没有。这一版：
//   · 只打类名，不再全量 dump 方法（最多挑 3 个最相关的类各打 20 行）；
//   · 闪图类必须同时命中 msg/message/image/chat 之类的 IM 词，秒杀类一律排除；
//   · 日志先在内存攒批，40 行或 0.5s 才落一次盘；总行数封顶 400；
//   · 钩子只挂 ext/flash 家族，最多 80 个，单 sel 记 3 次，5 分钟后自动失活（只剩一次转发）。
// 所有 setter 都是「先调原实现，再记一行」，不构造、不修改、不拦截任何业务调用。

#import "SLFlashProbe.h"
#import "SLLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdarg.h>

#define kSLProbeMaxLines     400    // 整份探测日志的上限
#define kSLProbeBatchLines    40    // 攒够这么多行落一次盘
#define kSLProbeMaxHooks      80    // 钩子数量上限
#define kSLProbePerSelLogs     3    // 同一个 setter 最多记 3 次
#define kSLProbeActiveSec    300    // 5 分钟后钩子自动失活

static NSMutableArray<NSString *> *sBuf = nil;
static NSInteger sTotalLines = 0;          // 只在这条串行队列里读写
static BOOL sFlushScheduled = NO;
static volatile BOOL sProbeActive = YES;   // 钩子热路径只看这一个 bool

// 一次 SLLogWrite = 一次 open + write + fsync + close，绝不能每行来一发
static void PFlushLocked(void) {
    if (sBuf.count == 0) return;
    NSString *joined = [sBuf componentsJoinedByString:@"\n"];
    [sBuf removeAllObjects];
    SLLogWrite(joined);
}

static void PBuf(NSString *line) {
    if (!line.length) return;
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.shenglin.probe", DISPATCH_QUEUE_SERIAL);
        sBuf = [NSMutableArray array];
    });
    dispatch_async(q, ^{
        if (sTotalLines >= kSLProbeMaxLines) return;
        sTotalLines++;
        [sBuf addObject:line];
        if (sBuf.count >= kSLProbeBatchLines) { PFlushLocked(); return; }
        if (sFlushScheduled) return;
        sFlushScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), q, ^{
            sFlushScheduled = NO;
            PFlushLocked();
        });
    });
}

static void PLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    PBuf([@"PROBE2| " stringByAppendingString:body]);
}

static NSString *SLProbeTrunc(id v, NSUInteger max) {
    NSString *s = nil;
    @try { s = [v description]; } @catch (NSException *e) { s = @"<description 异常>"; }
    if (!s) s = @"(nil)";
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return s;
}

static BOOL SLProbeHas(NSString *name, NSArray<NSString *> *keys) {
    NSString *low = name.lowercaseString;
    for (NSString *k in keys) {
        if ([low containsString:k]) return YES;
    }
    return NO;
}

// 只认「IM 消息/图片」这一片
static BOOL SLProbeIsIMClass(NSString *n) {
    if ([n containsString:@"Message"] || [n containsString:@"Msg"]) return YES;
    if ([n hasPrefix:@"AWEIM"] || [n hasPrefix:@"IESIM"] || [n hasPrefix:@"TTIM"]) return YES;
    return NO;
}

// 电商秒杀（FlashSale）/ 直播间 / 商品 SKU 这些「Flash」是干扰项，一律不碰
static BOOL SLProbeIsCommerceNoise(NSString *n) {
    return SLProbeHas(n, @[@"sale", @"shop", @"sku", @"commerce", @"product", @"entrance",
                           @"countdown", @"reduction", @"privilege", @"anchor", @"room",
                           @"category", @"banner", @"coupon", @"checkout"]);
}

static void SLProbeDumpMethods(Class cls, NSString *tag, NSArray<NSString *> *onlyKeys, NSInteger maxLines) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        NSString *sn = [NSString stringWithUTF8String:sel_getName(method_getName(ms[i]))];
        if (!sn.length) continue;
        if (onlyKeys.count && !SLProbeHas(sn, onlyKeys)) continue;
        const char *enc = method_getTypeEncoding(ms[i]);
        NSString *es = enc ? [NSString stringWithUTF8String:enc] : @"";
        [lines addObject:[NSString stringWithFormat:@"%@ %@ %@", tag, sn, es]];
    }
    free(ms);
    [lines sortUsingSelector:@selector(compare:)];
    NSInteger shown = 0;
    for (NSString *l in lines) {
        if (shown >= maxLines) break;
        PLog(@"%@", l);
        shown++;
    }
}

#pragma mark - 类清单（只打名字，成本可忽略）

// 类名粗筛：直接在 C 字符串上做，避免给 20 万个类各建一个 NSString
static BOOL SLProbeCStrHas(const char *s, const char *needle) {
    return s && needle && strstr(s, needle) != NULL;
}

static BOOL SLProbeMaybeRelevant(const char *cn) {
    if (!cn) return NO;
    if (SLProbeCStrHas(cn, "lash") || SLProbeCStrHas(cn, "urn") ||
        SLProbeCStrHas(cn, "phemeral") || SLProbeCStrHas(cn, "napchat")) return YES;
    if (SLProbeCStrHas(cn, "Message") || SLProbeCStrHas(cn, "Msg") ||
        SLProbeCStrHas(cn, "AWEIM") || SLProbeCStrHas(cn, "IESIM") ||
        SLProbeCStrHas(cn, "TTIM") || SLProbeCStrHas(cn, "Image") || SLProbeCStrHas(cn, "Picker")) return YES;
    return NO;
}

static void SLProbeInventory(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { PLog(@"classlist 为空"); return; }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) { PLog(@"classlist 内存申请失败"); return; }
    count = objc_getClassList(list, count);

    NSMutableArray<NSString *> *flash = [NSMutableArray array];
    NSMutableArray<NSString *> *imImage = [NSMutableArray array];
    NSMutableArray<NSString *> *imSend = [NSMutableArray array];
    NSMutableArray<NSString *> *picker = [NSMutableArray array];

    NSArray<NSString *> *imWords = @[@"msg", @"message", @"image", @"pic", @"media", @"chat"];

    for (int i = 0; i < count; i++) {
        const char *cn = class_getName(list[i]);
        if (!SLProbeMaybeRelevant(cn)) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n.length) continue;

        if (SLProbeHas(n, @[@"flash", @"burn", @"ephemeral", @"snapchat"]) &&
            SLProbeHas(n, imWords) && !SLProbeIsCommerceNoise(n)) {
            [flash addObject:n];
            continue;
        }
        if (SLProbeIsIMClass(n) && SLProbeHas(n, @[@"image", @"pic", @"media", @"photo", @"album"])) {
            [imImage addObject:n];
            continue;
        }
        if (SLProbeIsIMClass(n) && SLProbeHas(n, @[@"send", @"upload"])) {
            [imSend addObject:n];
            continue;
        }
        if (SLProbeHas(n, @[@"imagepicker", @"photopicker", @"albumpicker", @"mediapicker"])) {
            [picker addObject:n];
        }
    }
    free(list);

    PLog(@"== 类清单：共 %d 类；闪图 %lu / IM图 %lu / IM发送 %lu / 选图器 %lu ==",
         count, (unsigned long)flash.count, (unsigned long)imImage.count,
         (unsigned long)imSend.count, (unsigned long)picker.count);

    [flash sortUsingSelector:@selector(compare:)];
    NSInteger fc = 0;
    for (NSString *n in flash) {
        if (fc++ >= 25) { PLog(@"FLASH-CLASS …(截断)"); break; }
        PLog(@"FLASH-CLASS %@", n);
    }
    // 只挑前 3 个类看方法，够判断「是不是独立消息类」了
    NSInteger dumps = 0;
    for (NSString *n in flash) {
        if (dumps++ >= 3) break;
        Class c = NSClassFromString(n);
        if (c) SLProbeDumpMethods(c, @"FLASH-M", @[@"flash", @"burn", @"send", @"ext", @"content"], 20);
    }

    [imImage sortUsingSelector:@selector(compare:)];
    NSInteger ic = 0;
    for (NSString *n in imImage) {
        if (ic++ >= 45) { PLog(@"IMIMG-CLASS …(截断)"); break; }
        PLog(@"IMIMG-CLASS %@", n);
    }

    [imSend sortUsingSelector:@selector(compare:)];
    NSInteger sc = 0;
    for (NSString *n in imSend) {
        if (sc++ >= 30) { PLog(@"IMSEND-CLASS …(截断)"); break; }
        PLog(@"IMSEND-CLASS %@", n);
    }

    [picker sortUsingSelector:@selector(compare:)];
    NSInteger pc = 0;
    for (NSString *n in picker) {
        if (pc++ >= 15) { PLog(@"PICKER-CLASS …(截断)"); break; }
        PLog(@"PICKER-CLASS %@", n);
    }
}

#pragma mark - 少量 setter 钩子（先调原实现，再记一行）

typedef struct {
    Class cls;
    SEL   sel;
    IMP   imp;
} SLProbeHookEntry;

static SLProbeHookEntry sProbeHooks[kSLProbeMaxHooks];
static int sProbeHookCount = 0;
static NSMutableDictionary<NSString *, NSNumber *> *sProbeSelCounts = nil;
static NSMutableDictionary<NSString *, NSNumber *> *sProbeOwnsCache = nil;

static void SLProbeEnsureDicts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sProbeSelCounts = [NSMutableDictionary dictionary];
        sProbeOwnsCache = [NSMutableDictionary dictionary];
    });
}

// 这个类「自己」有没有实现 sel
static BOOL SLProbeClassOwnsSel(Class k, SEL sel) {
    NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(k), sel_getName(sel)];
    @synchronized (sProbeOwnsCache) {
        NSNumber *hit = sProbeOwnsCache[key];
        if (hit) return hit.boolValue;
        BOOL found = NO;
        unsigned int n = 0;
        Method *ms = class_copyMethodList(k, &n);
        for (unsigned int i = 0; i < n; i++) {
            if (sel_isEqual(method_getName(ms[i]), sel)) { found = YES; break; }
        }
        if (ms) free(ms);
        sProbeOwnsCache[key] = @(found);
        return found;
    }
}

// 找「这次调用原本该走的实现」；中间层自己重写了就交给它，不许跳过
static IMP SLProbeOrigIMP(Class cls, SEL sel) {
    for (Class k = cls; k; k = class_getSuperclass(k)) {
        for (int i = 0; i < sProbeHookCount; i++) {
            if (sProbeHooks[i].cls == k && sel_isEqual(sProbeHooks[i].sel, sel)) return sProbeHooks[i].imp;
        }
        if (SLProbeClassOwnsSel(k, sel)) return class_getMethodImplementation(k, sel);
    }
    return NULL;
}

static BOOL SLProbeShouldLog(SEL sel) {
    NSString *key = [NSString stringWithUTF8String:sel_getName(sel)];
    if (!key) return NO;
    @synchronized (sProbeSelCounts) {
        NSInteger c = [sProbeSelCounts[key] integerValue];
        if (c >= kSLProbePerSelLogs) return NO;
        sProbeSelCounts[key] = @(c + 1);
        return YES;
    }
}

static void SLProbeObjSetter(id self, SEL _cmd, id arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
    if (!sProbeActive || !SLProbeShouldLog(_cmd)) return;
    PLog(@"SET %s -%s = %@", class_getName(object_getClass(self)), sel_getName(_cmd), SLProbeTrunc(arg, 500));
}

static void SLProbeIntSetter(id self, SEL _cmd, long arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, long))o)(self, _cmd, arg);
    if (!sProbeActive || !SLProbeShouldLog(_cmd)) return;
    PLog(@"SET %s -%s = %ld", class_getName(object_getClass(self)), sel_getName(_cmd), arg);
}

static void SLProbeDblSetter(id self, SEL _cmd, double arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, double))o)(self, _cmd, arg);
    if (!sProbeActive || !SLProbeShouldLog(_cmd)) return;
    PLog(@"SET %s -%s = %f", class_getName(object_getClass(self)), sel_getName(_cmd), arg);
}

// 只碰 ext / flash 家族；MessageType 这类超高频属性不碰（信息量低、影响大）
static BOOL SLProbeIsInterestingSetter(const char *sn) {
    if (!sn || strncmp(sn, "set", 3) != 0) return NO;
    static const char *keys[] = { "Ext", "Extra", "Flash", "Burn", "Snap", "Ephemeral" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (strstr(sn + 3, keys[i])) return YES;
    }
    return NO;
}

static BOOL SLProbeHookableClass(NSString *n) {
    if (!( [n containsString:@"Message"] || [n containsString:@"Msg"] )) return NO;
    if (SLProbeIsCommerceNoise(n)) return NO;
    return !SLProbeHas(n, @[@"cell", @"view", @"controller", @"banner", @"card", @"label", @"button"]);
}

static void SLProbeHookSetter(Class cls, Method m) {
    if (sProbeHookCount >= kSLProbeMaxHooks) return;
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:enc];
    if (sig.numberOfArguments < 3) return;

    char t = [sig getArgumentTypeAtIndex:2][0];
    BOOL obj = (t == '@');
    BOOL dbl = (t == 'd');
    BOOL intg = (strchr("cCsSiIlLqQB", t) != NULL);
    if (!obj && !dbl && !intg) return;   // 结构体/指针/float 一律不碰

    IMP repl = obj ? (IMP)SLProbeObjSetter : (dbl ? (IMP)SLProbeDblSetter : (IMP)SLProbeIntSetter);
    IMP orig = method_setImplementation(m, repl);
    if (!orig) return;
    sProbeHooks[sProbeHookCount].cls = cls;
    sProbeHooks[sProbeHookCount].sel = method_getName(m);
    sProbeHooks[sProbeHookCount].imp = orig;
    sProbeHookCount++;
}

static void SLProbeInstallHooks(void) {
    SLProbeEnsureDicts();
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) return;
    count = objc_getClassList(list, count);

    int classes = 0;
    for (int i = 0; i < count && sProbeHookCount < kSLProbeMaxHooks; i++) {
        const char *cn = class_getName(list[i]);
        if (!SLProbeCStrHas(cn, "Message") && !SLProbeCStrHas(cn, "Msg")) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n.length || !SLProbeHookableClass(n)) continue;
        classes++;

        unsigned int mn = 0;
        Method *ms = class_copyMethodList(list[i], &mn);
        if (!ms) continue;
        for (unsigned int k = 0; k < mn && sProbeHookCount < kSLProbeMaxHooks; k++) {
            if (SLProbeIsInterestingSetter(sel_getName(method_getName(ms[k])))) {
                SLProbeHookSetter(list[i], ms[k]);
            }
        }
        free(ms);
    }
    free(list);
    PLog(@"== setter 钩子：候选类 %d 个，挂上 %d 个（%d 秒后自动失活）==",
         classes, sProbeHookCount, kSLProbeActiveSec);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSLProbeActiveSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sProbeActive = NO;
        PLog(@"== 探测窗口结束，钩子已失活（只保留转发）==");
    });
}

#pragma mark - 入口

void SLFlashProbeStart(void) {
    static BOOL sStarted = NO;
    if (sStarted) return;
    sStarted = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        @autoreleasepool {
            CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
            PLog(@"==== 闪图探测 v0.5.5 · 抖音 %@ ====",
                 [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
            @try {
                SLProbeInventory();
            } @catch (NSException *e) {
                PLog(@"类清单异常: %@", e.reason ?: @"?");
            }
            @try {
                SLProbeInstallHooks();
            } @catch (NSException *e) {
                PLog(@"装钩异常: %@", e.reason ?: @"?");
            }
            PLog(@"==== 探测就绪（%.2fs）：请发一条普通图片、再发一条闪图 ====",
                 CFAbsoluteTimeGetCurrent() - t0);
        }
    });
}
