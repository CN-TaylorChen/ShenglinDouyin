// v0.5.8：闪图勘察（无钩子版）
//
// v0.5.4 ~ v0.5.7 是「真钩子」探测：在 IM 消息模型的 setter 上替换 IMP、发送当口逐 ivar 读内存。
// 结论已经拿到了（闪图 = AWEIMWatchOnceImageMessage + messageType 91 + localExt 多一个 has_token），
// 但代价是从相册选图发送会闪退 —— 那条路径上正好全是这些 setter，钩子一旦落到签名不符的方法、
// 或者读到尚未初始化完的对象，就是 EXC_BAD_ACCESS。
//
// 所以这一版**一行 method_setImplementation 都没有**，只做两件纯读的事：
//   ① 把「只看一次」相关类和图片消息类的**方法名**打出来（class_copyMethodList + sel_getName）；
//   ② 全库扫一遍，把所有**选择器名里带 WatchOnce** 的方法连同类名打出来。
//      —— 这就是我们要找的东西：抖音把普通图变成闪图时调用的那个 API，
//         名字里几乎必然带 WatchOnce，拿到名字就能定点处理，不用再猜。
//
// 纯读操作 + 分批落盘，对发送路径零侵入。

#import "SLFlashProbe.h"
#import "SLLog.h"
#import <objc/runtime.h>
#import <string.h>
#include <stdarg.h>

#define kSLProbeMaxLines    1400    // 整份探测日志上限
#define kSLProbeBatchLines    40    // 攒够这么多行落一次盘
#define kSLProbePerClass      70    // 单个类最多打多少个方法名

static NSMutableArray<NSString *> *sBuf = nil;
static NSInteger sTotalLines = 0;           // 只在这条串行队列里读写
static BOOL sFlushScheduled = NO;

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
    PBuf([@"PROBE5| " stringByAppendingString:body]);
}

static BOOL PStrHas(const char *s, const char *needle) {
    return s && needle && strstr(s, needle) != NULL;
}

#pragma mark - ① 指定类的方法名

static void PDumpClassMethods(const char *clsName, NSInteger cap) {
    Class cls = objc_getClass(clsName);
    if (!cls) { PLog(@"CLS %s = 不存在", clsName); return; }

    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (Class c = cls; c && c != [NSObject class] && chain.count < 5; c = class_getSuperclass(c)) {
        [chain addObject:NSStringFromClass(c)];
    }

    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    PLog(@"==== CLS %s  <  %@  （本类方法 %u 个）====", clsName,
         [chain componentsJoinedByString:@" < "], ms ? n : 0u);
    if (!ms) return;

    NSInteger shown = 0;
    for (unsigned int i = 0; i < n; i++) {
        if (shown >= cap) { PLog(@"  …(还有 %u 个未打印)", n - (unsigned int)shown); break; }
        const char *sn = sel_getName(method_getName(ms[i]));
        if (!sn) continue;
        PLog(@"  -%s", sn);
        shown++;
    }
    free(ms);
}

// 只挑和「图 / 发」有关的类，别把整个工程打出来
static const char *kProbeClasses[] = {
    "AWEIMWatchOnceDataManager",
    "AWEIMWatchOnceMessageManager",
    "AWEIMWatchOnceImageMessage",
    "AWEIMWatchOnceImageDetailInfo",
    "AWEIMWatchOnceImageResourceInfo",
    "AWEIMWatchOnceResourceInfo",
    "AWEIMWatchOnceShowInfo",
    "AWEIMWatchOnceContentComponent",
    "AWEIMEncryptedImageMessage",
    "AWEIMImageMessage",
    "AWEIMBigImageMessage",
};

#pragma mark - ② 全库扫：选择器名带 WatchOnce / BurnAfterRead

// 这是这一版的重头戏。只要抖音存在「把普通图转成闪图」的入口，方法名里就一定有 WatchOnce；
// 扫出来连类名一起打印，等于直接告诉我们该盯哪个类、哪个方法。
static void PScanOnceSelectors(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { PLog(@"classlist 为空"); return; }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) { PLog(@"classlist 内存申请失败"); return; }
    count = objc_getClassList(list, count);

    NSInteger classes = 0, hits = 0;
    for (int i = 0; i < count; i++) {
        const char *cn = class_getName(list[i]);
        if (!cn) continue;
        if (!strncmp(cn, "NSKVONotifying_", 15)) continue;
        // 只扫抖音/字节自家命名空间：24.6 万类里过滤到几千个，
        // 既省掉遍历开销，也避开系统类在并发初始化时被强行 realize 的风险
        BOOL mine = !strncmp(cn, "AWE", 3) || !strncmp(cn, "IES", 3) ||
                    !strncmp(cn, "TIM", 3) || !strncmp(cn, "ACC", 3) ||
                    !strncmp(cn, "BD", 2)  || PStrHas(cn, "WatchOnce");
        if (!mine) continue;

        unsigned int mn = 0;
        Method *ms = class_copyMethodList(list[i], &mn);
        if (!ms) continue;
        BOOL counted = NO;
        for (unsigned int k = 0; k < mn; k++) {
            const char *sn = sel_getName(method_getName(ms[k]));
            if (!sn) continue;
            if (!PStrHas(sn, "WatchOnce") && !PStrHas(sn, "watchOnce") &&
                !PStrHas(sn, "BurnAfterRead")) continue;
            if (!counted) { classes++; counted = YES; }
            hits++;
            PLog(@"SEL-ONCE %s -%s", cn, sn);
        }
        free(ms);
    }
    free(list);
    PLog(@"== 扫描完成：命中类 %ld 个 / 方法 %ld 个 ==", (long)classes, (long)hits);
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
            PLog(@"==== 闪图勘察 v0.5.8（无钩子）· 抖音 %@ ====",
                 [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
            @try {
                PScanOnceSelectors();
            } @catch (NSException *e) {
                PLog(@"扫描异常: %@", e.reason ?: @"?");
            }
            @try {
                size_t n = sizeof(kProbeClasses) / sizeof(kProbeClasses[0]);
                for (size_t i = 0; i < n; i++) PDumpClassMethods(kProbeClasses[i], kSLProbePerClass);
            } @catch (NSException *e) {
                PLog(@"方法清单异常: %@", e.reason ?: @"?");
            }
            PLog(@"==== 勘察完成（%.2fs），无需发图 ====", CFAbsoluteTimeGetCurrent() - t0);
        }
    });
}
