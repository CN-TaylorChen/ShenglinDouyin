// v0.5.6：闪图字段勘察（只读探测）
//
// 要回答的问题只有一个：抖音私聊的「闪图」和普通图片，在模型层到底差在哪？
//
// v0.5.5 拿到了两条结论，但没拿到答案：
//   ① 全机 24.6 万个类里，跟 IM 闪图有关的类一个都没有 ——
//      命中的 3 个是「直播礼物闪光」「电商直播闪购」「Snapchat 下载配置」，全是干扰项。
//      所以闪图几乎不可能是「独立的闪图消息类」，标记只能藏在消息模型的某个字段里。
//   ② 真正有用的线索来自 IESIMSendMessageModel 的 localExt：普通图片发送时这里是
//      { file_id_dict_str: {image: ...}, file_path_dict_str: {image: send/image_xxx} }。
//      ——但每个 setter 只记 3 次这条规则，被前面几条普通图全吃掉了，
//      用户后发的闪图根本没记上，A/B 对比断了。
//
// 所以这一版只做一件事：**在图片消息装填时，把整个消息模型（含 content 子对象）的
// 所有 ivar 打一份快照**。普通图一份、闪图一份，两份一对比，差的那个字段就是闪图标记。
//
// 相比 v0.5.5 的改动：
//   · 丢掉 IMIMG / IMSEND / PICKER 那 90 行类名清单（一条有用信息都没有，纯噪音）；
//   · 钩子不再「谁先谁上」，改成优先挂 IESIM* / TIMX* / AWEIM* 的消息模型类；
//   · 不再按 setter 名盲挂，改成「图片消息时才 dump 整对象」——不管字段叫什么都能看到；
//   · 单 sel 记录上限 3 → 12，总行数 400 → 900，够记十几次发送；
//   · 探测窗口 5 分钟 → 7 分钟，装完不用赶时间。
// 所有钩子都是「先调原实现，再记日志」，不构造、不修改、不拦截任何业务调用。

#import "SLFlashProbe.h"
#import "SLLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdarg.h>

#define kSLProbeMaxLines     900    // 整份探测日志的上限
#define kSLProbeBatchLines    40    // 攒够这么多行落一次盘
#define kSLProbeMaxHooks     240    // 钩子数量上限
#define kSLProbePerSelLogs    12    // 同一个 setter 最多记 12 次（要够 A/B 两轮）
#define kSLProbeActiveSec    420    // 7 分钟后钩子自动失活

static NSMutableArray<NSString *> *sBuf = nil;
static NSInteger sTotalLines = 0;          // 只在这条串行队列里读写
static BOOL sFlushScheduled = NO;
static NSInteger sSendSeq = 0;
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
    PBuf([@"PROBE3| " stringByAppendingString:body]);
}

static NSString *PShort(id v, NSUInteger max) {
    if (!v) return @"(nil)";
    NSString *s = nil;
    @try { s = [v description]; } @catch (NSException *e) { s = @"<description 异常>"; }
    if (!s) return @"(nil)";
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return s;
}

#pragma mark - 整对象 ivar 快照（核心：不预设字段名）

// 把 obj 的所有实例 ivar 打一遍。对象类型的值顺便在 depth 允许时往里钻一层，
// 专门用来找「content / messageContent / body」这类子模型 —— 闪图标记可能不在外层。
static void PDumpIvars(id obj, NSString *prefix, NSInteger depth, NSInteger maxIvars);

static void PDumpIvars(id obj, NSString *prefix, NSInteger depth, NSInteger maxIvars) {
    if (!obj || depth < 0 || maxIvars <= 0) return;
    Class cls = object_getClass(obj);
    if (!cls) return;
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(cls, &n);
    if (!ivars) {
        PLog(@"%@ <%@ 无 ivar>", prefix, NSStringFromClass(cls));
        return;
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<NSString *> *children = [NSMutableArray array];
    NSInteger shown = 0;

    for (unsigned int i = 0; i < n && shown < (unsigned)maxIvars; i++) {
        const char *iname = ivar_getName(ivars[i]);
        const char *itype = ivar_getTypeEncoding(ivars[i]);
        if (!iname || !itype || !itype[0]) continue;
        NSString *name = [NSString stringWithUTF8String:iname];
        if (!name.length) continue;

        NSString *low = name.lowercaseString;
        // 这些要么是噪音，要么是绝对不能碰的（ARC weak 表、锁对象）
        if ([low containsString:@"delegate"] || [low containsString:@"observer"] ||
            [low containsString:@"lock"] || [low containsString:@"weak"]) continue;

        ptrdiff_t off = ivar_getOffset(ivars[i]);
        if (off <= 0) continue;
        char *base = (char *)(__bridge void *)obj + off;

        char t = itype[0];
        NSString *val = nil;
        id childObj = nil;

        if (t == '@') {
            __unsafe_unretained id v = nil;
            memcpy(&v, base, sizeof(id));
            if (!v) {
                val = @"(nil)";
            } else {
                val = PShort(v, 320);
                // 只往「自己家的消息/内容模型」里钻一层；Foundation 容器和第三方对象一律不碰
                if (depth > 0 &&
                    ([low containsString:@"content"] || [low containsString:@"body"] ||
                     [low containsString:@"msgmodel"])) {
                    const char *ccn = object_getClassName(v);
                    if (ccn && (strstr(ccn, "Message") || strstr(ccn, "Msg") ||
                                strstr(ccn, "Content") || strncmp(ccn, "IESIM", 5) == 0 ||
                                strncmp(ccn, "TIMX", 4) == 0 || strncmp(ccn, "AWEIM", 5) == 0)) {
                        childObj = v;
                    }
                }
            }
        } else if (t == 'd') {
            double v = 0; memcpy(&v, base, sizeof(double));
            val = [NSString stringWithFormat:@"%g", v];
        } else if (t == 'f') {
            float v = 0; memcpy(&v, base, sizeof(float));
            val = [NSString stringWithFormat:@"%g", (double)v];
        } else if (strchr("cCsSiIlLqQB", t)) {
            size_t sz = 4;
            switch (t) {
                case 'c': case 'C': case 'B': sz = 1; break;
                case 's': case 'S': sz = 2; break;
                case 'i': case 'I': sz = 4; break;
                default: sz = 8; break;
            }
            long long v = 0;
            memcpy(&v, base, sz);
            val = [NSString stringWithFormat:@"%lld", v];
        } else {
            continue;   // 结构体/指针一律不展开
        }

        [lines addObject:[NSString stringWithFormat:@"%@ %@ = %@", prefix, name, val]];
        if (childObj) [children addObject:childObj];
        shown++;
    }
    if (ivars) free(ivars);

    for (NSString *l in lines) {
        // ★ 打标记：名字或值里带「闪/焚/一次性」语义的，一眼就能在几十行里挑出来
        NSString *ll = l.lowercaseString;
        BOOL hit = [ll containsString:@"flash"] || [ll containsString:@"burn"] ||
                   [ll containsString:@"snap"] || [ll containsString:@"ephemeral"] ||
                   [ll containsString:@"secret"] || [ll containsString:@"destroy"] ||
                   [ll containsString:@"onceread"] || [ll containsString:@"readonce"] ||
                   [ll containsString:@"expire"] || [ll containsString:@"ttl"] ||
                   [ll containsString:@"阅后"] || [ll containsString:@"闪"];
        PLog(@"%@%@", hit ? @"★ " : @"", l);
    }
    if ((NSInteger)n > shown) PLog(@"%@ …(还有 %ld 个 ivar 未打印)", prefix, (long)((NSInteger)n - shown));

    for (id c in children) {
        PDumpIvars(c, [prefix stringByAppendingString:@" ↳"], depth - 1, maxIvars / 2);
    }
}

#pragma mark - 判定：这次 setter 是不是「在装一条图片消息」

// localExt 里同时有 file_id_dict_str / file_path_dict_str 且带 image 键 —— 这就是图片发送。
static BOOL PLooksLikeImageSend(id arg) {
    if (!arg) return NO;
    if (![arg isKindOfClass:[NSDictionary class]] && ![arg isKindOfClass:[NSString class]] &&
        ![arg isKindOfClass:[NSArray class]]) return NO;
    NSString *d = PShort(arg, 3000);
    if (!d.length) return NO;
    if (![d containsString:@"file_id_dict_str"] && ![d containsString:@"file_path_dict_str"]) return NO;
    return [d containsString:@"image"];
}

#pragma mark - 钩子表

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

// 消息模型本体：msgType / contentType 这类整数是最便宜的判别器，一定要记
static BOOL PIsHotModelClass(Class cls) {
    const char *cn = class_getName(cls);
    if (!cn) return NO;
    if (strcmp(cn, "IESIMSendMessageModel") == 0) return YES;
    return strstr(cn, "MessageContent") != NULL || strstr(cn, "ImageMsg") != NULL ||
           strstr(cn, "ImageMessage") != NULL || strstr(cn, "SendMessageModel") != NULL;
}

static BOOL PSelIsFlashish(const char *sn) {
    return strstr(sn, "Flash") || strstr(sn, "Burn") || strstr(sn, "Ephemeral") ||
           strstr(sn, "Snap") || strstr(sn, "Secret") || strstr(sn, "OnceRead") ||
           strstr(sn, "ReadOnce") || strstr(sn, "Destroy");
}

static void SLProbeObjSetter(id self, SEL _cmd, id arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
    if (!sProbeActive || !SLProbeShouldLog(_cmd)) return;

    const char *sn = sel_getName(_cmd);
    BOOL flashish = PSelIsFlashish(sn);
    BOOL img = !flashish && PLooksLikeImageSend(arg);
    // content 装配也是关键节点：闪图标记很可能挂在 content 子对象或其 ext 上，
    // 而 setLocalExt 未必在 content 之后才调，所以两处都要抓一份快照。
    BOOL contentish = !flashish && !img && PIsHotModelClass(object_getClass(self)) &&
                      (strstr(sn, "Content") != NULL || strstr(sn, "Body") != NULL);
    if (!flashish && !img && !contentish) return;

    NSString *cls = NSStringFromClass(object_getClass(self));
    if (flashish) {
        PLog(@"FLASHISH %@ -%s = %@", cls, sn, PShort(arg, 400));
        PDumpIvars(self, @"  ↳", 1, 60);
    } else if (img) {
        PLog(@"===== IMG-SEND #%ld  %@ -%s =====", (long)(++sSendSeq), cls, sn);
        PDumpIvars(self, @"  ↓", 2, 80);
        PLog(@"===== IMG-SEND #%ld end =====", (long)sSendSeq);
    } else {
        PLog(@"===== CONTENT #%ld  %@ -%s arg=%@ =====", (long)(++sSendSeq), cls, sn,
             NSStringFromClass(object_getClass(arg)) ?: @"?");
        PDumpIvars(self, @"  ↓", 1, 50);
        PDumpIvars(arg, @"  ↳", 1, 50);
        PLog(@"===== CONTENT #%ld end =====", (long)sSendSeq);
    }
}

static void SLProbeIntSetter(id self, SEL _cmd, long arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, long))o)(self, _cmd, arg);
    if (!sProbeActive) return;

    const char *sn = sel_getName(_cmd);
    BOOL flashish = PSelIsFlashish(sn);
    BOOL hot = PIsHotModelClass(object_getClass(self)) &&
               (strstr(sn, "Type") || strstr(sn, "Scene") || strstr(sn, "Mode"));
    if (!flashish && !hot) return;
    if (!SLProbeShouldLog(_cmd)) return;
    PLog(@"SETINT %@ -%s = %ld", NSStringFromClass(object_getClass(self)), sn, arg);
}

static void SLProbeDblSetter(id self, SEL _cmd, double arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, double))o)(self, _cmd, arg);
    if (!sProbeActive || !PSelIsFlashish(sel_getName(_cmd))) return;
    if (!SLProbeShouldLog(_cmd)) return;
    PLog(@"SETDBL %@ -%s = %f", NSStringFromClass(object_getClass(self)), sel_getName(_cmd), arg);
}

// 只碰「值得看」的 setter：ext 家族 + content 家族 + flash 家族
static BOOL SLProbeIsInterestingSetter(const char *sn) {
    if (!sn || strncmp(sn, "set", 3) != 0) return NO;
    const char *rest = sn + 3;
    if (PSelIsFlashish(rest)) return YES;
    static const char *keys[] = { "Ext", "Extra", "Content", "Body", "MsgType", "MessageType" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (strstr(rest, keys[i])) return YES;
    }
    return NO;
}

// 只挂 IM 消息模型本体，视图/控制器/管理器一律跳过（v0.5.5 挂了 756 个候选类，
// 结果 80 个额度被乱七八糟的类抢走，真正在用的 IESIMSendMessageModel 只勉强挤进去）
static BOOL PIsIMModelClass(const char *cn) {
    if (!cn) return NO;
    BOOL im = (strncmp(cn, "IESIM", 5) == 0) || (strncmp(cn, "TIMX", 4) == 0) ||
              (strncmp(cn, "AWEIM", 5) == 0);
    if (!im) return NO;
    if (strstr(cn, "Cell") || strstr(cn, "View") || strstr(cn, "Controller") ||
        strstr(cn, "Manager") || strstr(cn, "Tracker")) return NO;
    return strstr(cn, "Message") != NULL || strstr(cn, "Msg") != NULL;
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

#pragma mark - 类清单（v0.5.5 那 90 行 IMIMG/IMSEND/PICKER 全删了，零信息量）

static void SLProbeInventory(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { PLog(@"classlist 为空"); return; }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) { PLog(@"classlist 内存申请失败"); return; }
    count = objc_getClassList(list, count);

    NSMutableArray<NSString *> *flash = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        const char *cn = class_getName(list[i]);
        if (!cn) continue;
        if (!(strstr(cn, "lash") || strstr(cn, "urn") || strstr(cn, "phemeral") || strstr(cn, "napchat"))) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n.length) continue;
        [flash addObject:n];
    }
    free(list);
    [flash sortUsingSelector:@selector(compare:)];
    PLog(@"== 类清单：共 %d 类；名字带 flash/burn/ephemeral/snapchat 的 %lu 个 ==",
         count, (unsigned long)flash.count);
    for (NSString *n in flash) PLog(@"FLASH-CLASS %@", n);
}

static void SLProbeInstallHooks(void) {
    SLProbeEnsureDicts();
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) return;
    count = objc_getClassList(list, count);

    // 先把 IESIMSendMessageModel 这类「确定在用」的类挂上，再挂其它 IM 模型类
    NSMutableArray<NSString *> *hot = [NSMutableArray array];
    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        const char *cn = class_getName(list[i]);
        if (!PIsIMModelClass(cn)) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n) continue;
        if (PIsHotModelClass(list[i])) [hot addObject:n];
        else [rest addObject:n];
    }
    free(list);

    [hot sortUsingSelector:@selector(compare:)];
    [rest sortUsingSelector:@selector(compare:)];
    NSArray<NSString *> *ordered = [hot arrayByAddingObjectsFromArray:rest];

    NSMutableArray<NSString *> *touched = [NSMutableArray array];
    for (NSString *n in ordered) {
        if (sProbeHookCount >= kSLProbeMaxHooks) break;
        Class cls = NSClassFromString(n);
        if (!cls) continue;
        int before = sProbeHookCount;
        unsigned int mn = 0;
        Method *ms = class_copyMethodList(cls, &mn);
        if (!ms) continue;
        for (unsigned int k = 0; k < mn && sProbeHookCount < kSLProbeMaxHooks; k++) {
            if (SLProbeIsInterestingSetter(sel_getName(method_getName(ms[k])))) {
                SLProbeHookSetter(cls, ms[k]);
            }
        }
        free(ms);
        if (sProbeHookCount > before) [touched addObject:n];
    }

    PLog(@"== 钩子：IM 模型类 %lu 个，挂上 %d 个方法，涉及类 %lu 个（%d 秒后失活）==",
         (unsigned long)ordered.count, sProbeHookCount, (unsigned long)touched.count, kSLProbeActiveSec);
    NSInteger tc = 0;
    for (NSString *n in touched) {
        if (tc++ >= 30) { PLog(@"HOOK-CLASS …(截断)"); break; }
        PLog(@"HOOK-CLASS %@", n);
    }

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
            PLog(@"==== 闪图探测 v0.5.6 · 抖音 %@ ====",
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
            PLog(@"==== 探测就绪（%.2fs）：请先发一条普通图，再发一条闪图 ====",
                 CFAbsoluteTimeGetCurrent() - t0);
        }
    });
}
