// v0.5.4：闪图字段勘察（只读探测）
//
// 要回答的问题只有一个：抖音私聊的「闪图」和普通图片，在模型层到底差在哪？
//   ① 是否存在独立的闪图消息类（名字里带 Flash / Burn / Ephemeral）；
//   ② 闪图标记是 ext 字典里的一个字段，还是消息模型上的独立属性（setFlash: / setBurnAfterRead:）。
//
// 只要拿到 ①②，就能判断「相册选图」能不能在原地上包一层闪图发出去。
// 本文件只做三件事：枚举类名、打印候选方法、给候选 setter 挂一个「记完就转交」的钩子。
// 不构造、不修改、不拦截任何业务调用 —— 所有 setter 都先调原实现，再写日志。

#import "SLFlashProbe.h"
#import "SLLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdarg.h>

#define kSLProbeLineCap     1800   // 防止一次刷爆日志文件
#define kSLProbeMaxHooks    1024
#define kSLProbePerSelLogs    40   // 同一个 setter 最多记 40 次，避免高频属性刷屏

static NSInteger sProbeLines = 0;

static void PLog(NSString *fmt, ...) {
    if (sProbeLines >= kSLProbeLineCap) return;
    sProbeLines++;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    SLLog(@"PROBE| %@", body);
}

static NSString *SLProbeTrunc(id v, NSUInteger max) {
    NSString *s = nil;
    @try { s = [v description]; } @catch (NSException *e) { s = @"<description 异常>"; }
    if (!s) s = @"(nil)";
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return s;
}

static BOOL SLProbeNameHas(NSString *name, NSArray<NSString *> *keys) {
    if (!name.length) return NO;
    NSString *low = name.lowercaseString;
    for (NSString *k in keys) {
        if ([low containsString:k]) return YES;
    }
    return NO;
}

// 只认「IM 消息/图片」这一片，避免把整个 App 的类都翻一遍
static BOOL SLProbeIsIMClass(NSString *n) {
    if ([n containsString:@"Message"] || [n containsString:@"Msg"]) return YES;
    if ([n hasPrefix:@"AWEIM"] || [n hasPrefix:@"IESIM"] || [n hasPrefix:@"TTIM"]) return YES;
    return NO;
}

static void SLProbeDumpMethods(Class cls, NSString *tag, NSArray<NSString *> *onlyKeys, NSInteger maxLines) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    if (!ms) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *sn = [NSString stringWithUTF8String:sel_getName(sel)];
        if (!sn) continue;
        if (onlyKeys.count && !SLProbeNameHas(sn, onlyKeys)) continue;
        const char *enc = method_getTypeEncoding(ms[i]);
        NSString *es = enc ? [NSString stringWithUTF8String:enc] : @"";
        [lines addObject:[NSString stringWithFormat:@"%@ %@ %@", tag, sn, es]];
    }
    free(ms);
    [lines sortUsingSelector:@selector(compare:)];
    NSInteger shown = 0;
    for (NSString *l in lines) {
        if (shown >= maxLines) {
            PLog(@"%@ …(还有 %lu 条未打印)", tag, (unsigned long)(lines.count - (NSUInteger)shown));
            break;
        }
        PLog(@"%@", l);
        shown++;
    }
}

#pragma mark - 类清单

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

    for (int i = 0; i < count; i++) {
        Class c = list[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n.length) continue;

        if (SLProbeNameHas(n, @[@"flash", @"burn", @"ephemeral", @"snapchat", @"yuehou"])) {
            [flash addObject:n];
            continue;
        }
        if (SLProbeIsIMClass(n) && SLProbeNameHas(n, @[@"image", @"pic", @"media", @"photo", @"album"])) {
            [imImage addObject:n];
            continue;
        }
        if (SLProbeIsIMClass(n) && SLProbeNameHas(n, @[@"send", @"upload"])) {
            [imSend addObject:n];
            continue;
        }
        if (SLProbeNameHas(n, @[@"imagepicker", @"photopicker", @"albumpicker", @"mediapicker"])) {
            [picker addObject:n];
        }
    }
    free(list);

    PLog(@"== 类清单：总计 %d 个；闪图候选 %lu；IM 图片 %lu；IM 发送 %lu；选图器 %lu ==",
         count, (unsigned long)flash.count, (unsigned long)imImage.count,
         (unsigned long)imSend.count, (unsigned long)picker.count);

    [flash sortUsingSelector:@selector(compare:)];
    for (NSString *n in flash) {
        PLog(@"FLASH-CLASS %@", n);
    }
    for (NSString *n in flash) {
        Class c = NSClassFromString(n);
        if (c) SLProbeDumpMethods(c, @"FLASH-M", nil, 60);
    }

    [imImage sortUsingSelector:@selector(compare:)];
    for (NSString *n in imImage) PLog(@"IMIMG-CLASS %@", n);
    for (NSString *n in imImage) {
        Class c = NSClassFromString(n);
        if (c) SLProbeDumpMethods(c, @"IMIMG-M", @[@"send", @"image", @"flash", @"upload", @"ext", @"content"], 30);
    }

    [imSend sortUsingSelector:@selector(compare:)];
    for (NSString *n in imSend) PLog(@"IMSEND-CLASS %@", n);
    for (NSString *n in imSend) {
        Class c = NSClassFromString(n);
        if (c) SLProbeDumpMethods(c, @"IMSEND-M", @[@"send", @"upload", @"flash", @"image"], 30);
    }

    [picker sortUsingSelector:@selector(compare:)];
    for (NSString *n in picker) PLog(@"PICKER-CLASS %@", n);
}

#pragma mark - 候选 setter 钩子（先调原实现，再记一行）

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

// 这个类「自己」有没有实现 sel（class_copyMethodList 只返回本类方法）
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

// 沿继承链找「这次调用原本该走的实现」。
// 只认我们钩过的类是不够的：中间层若自己重写了 setter，直接跳到祖先实现会把中间层逻辑吞掉。
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
    if (!SLProbeShouldLog(_cmd)) return;
    PLog(@"SET %s -%s = %@", class_getName(object_getClass(self)), sel_getName(_cmd), SLProbeTrunc(arg, 600));
}

static void SLProbeIntSetter(id self, SEL _cmd, long arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, long))o)(self, _cmd, arg);
    if (!SLProbeShouldLog(_cmd)) return;
    PLog(@"SET %s -%s = %ld", class_getName(object_getClass(self)), sel_getName(_cmd), arg);
}

static void SLProbeDblSetter(id self, SEL _cmd, double arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, double))o)(self, _cmd, arg);
    if (!SLProbeShouldLog(_cmd)) return;
    PLog(@"SET %s -%s = %f", class_getName(object_getClass(self)), sel_getName(_cmd), arg);
}

// 只碰这几种 setter：ext 家族（大概率装闪图标记）+ 名字里直接带 flash/burn
static BOOL SLProbeIsInterestingSetter(const char *sn) {
    if (!sn || strncmp(sn, "set", 3) != 0) return NO;
    static const char *keys[] = { "Ext", "Extra", "Flash", "Burn", "Snap", "Ephemeral", "MessageType", "MsgType" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (strstr(sn + 3, keys[i])) return YES;
    }
    return NO;
}

static void SLProbeHookSetter(Class cls, Method m) {
    if (sProbeHookCount >= kSLProbeMaxHooks) return;
    SEL sel = method_getName(m);
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:enc];
    if (sig.numberOfArguments < 3) return;

    char t = [sig getArgumentTypeAtIndex:2][0];
    BOOL obj = (t == '@');
    BOOL dbl = (t == 'd');
    BOOL intg = (strchr("cCsSiIlLqQB", t) != NULL);
    if (!obj && !dbl && !intg) return;   // 结构体/指针/float 一律不碰，宁缺勿错

    IMP repl = obj ? (IMP)SLProbeObjSetter : (dbl ? (IMP)SLProbeDblSetter : (IMP)SLProbeIntSetter);
    IMP orig = method_setImplementation(m, repl);
    if (!orig) return;
    sProbeHooks[sProbeHookCount].cls = cls;
    sProbeHooks[sProbeHookCount].sel = sel;
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
    for (int i = 0; i < count; i++) {
        Class c = list[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n.length || !SLProbeIsIMClass(n)) continue;
        classes++;

        unsigned int mn = 0;
        Method *ms = class_copyMethodList(c, &mn);
        if (!ms) continue;
        for (unsigned int k = 0; k < mn; k++) {
            if (SLProbeIsInterestingSetter(sel_getName(method_getName(ms[k])))) {
                SLProbeHookSetter(c, ms[k]);
            }
        }
        free(ms);
    }
    free(list);
    PLog(@"== setter 钩子：候选类 %d 个，实际挂上 %d 个 ==", classes, sProbeHookCount);
}

#pragma mark - 入口

void SLFlashProbeStart(void) {
    static BOOL sStarted = NO;
    if (sStarted) return;
    sStarted = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
            PLog(@"==== 闪图探测开始 v0.5.4 · 抖音 %@ ====",
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
            PLog(@"==== 闪图探测就绪（%.2fs）：现在发一条普通图片、再发一条闪图 ====",
                 CFAbsoluteTimeGetCurrent() - t0);
        }
    });
}
