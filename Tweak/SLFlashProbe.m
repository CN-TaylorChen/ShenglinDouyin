// v0.5.7：闪图字段勘察（只读探测）
//
// 上一版（v0.5.6）已经定案：闪图 **不是某个字段，而是一个独立的消息类**
//   ===== CONTENT #1  NSKVONotifying_AWEIMWatchOnceImageMessage -setContent: arg=AWEIMEncryptedImageContent =====
// WatchOnce = 只看一次 = 阅后即焚。内容对象 AWEIMEncryptedImageContent 与普通图完全共用
// （同一次测试里 content 的 md5 与普通图 localExt 的 send/image_xxx 完全一致）。
//
// 所以这一版只剩两个问题要回答：
//   ① 普通图片用的是哪个消息类？（对照组类名，决定「把哪个类换成哪个类」）
//   ② AWEIMWatchOnceImageMessage 除了父类的字段，还多带了什么？（有没有必填的过期时间之类）
//
// v0.5.6 的两个失误，这一版都修掉：
//   · 关键词只写了 flash/burn/ephemeral/snapchat，漏了抖音真正用的 WatchOnce —— 现已补上；
//     同时把 "urn"(Return/TurnOn/Journal 全中) 这种垃圾词彻底删掉。
//   · dump 取的是 object_getClass(obj) 这一层，而 KVO 动态子类 NSKVONotifying_xxx 自己
//     没有任何 ivar，真正字段全在父类 —— 现在沿父类链往上走最多 4 层。
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
#define kSLProbePerSelLogs    16    // 同一个 setter 最多记 16 次（要够 A/B 两轮）
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
    PBuf([@"PROBE4| " stringByAppendingString:body]);
}

static NSString *PShort(id v, NSUInteger max) {
    if (!v) return @"(nil)";
    NSString *s = nil;
    @try { s = [v description]; } @catch (NSException *e) { s = @"<description 异常>"; }
    if (!s) return @"(nil)";
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return s;
}

static BOOL PStrHas(const char *s, const char *needle) {
    return s && needle && strstr(s, needle) != NULL;
}

#pragma mark - 整对象 ivar 快照（沿父类链走，不预设字段名）

// 把 obj 的 ivar 打一遍。KVO 动态子类自己没有 ivar，所以从 leaf 一路往上最多 4 层。
// 对象类型且名字像 content/body 的，往里钻一层 —— 闪图标记也可能挂在 content 上。
static void PDumpIvars(id obj, NSString *prefix, NSInteger depth, NSInteger maxIvars);

static void PDumpIvars(id obj, NSString *prefix, NSInteger depth, NSInteger maxIvars) {
    if (!obj || depth < 0 || maxIvars <= 0) return;
    Class leaf = object_getClass(obj);
    if (!leaf) return;

    NSMutableArray<NSValue *> *chain = [NSMutableArray array];
    NSMutableArray<NSString *> *chainNames = [NSMutableArray array];
    for (Class c = leaf; c && c != [NSObject class] && chain.count < 4; c = class_getSuperclass(c)) {
        [chain addObject:[NSValue valueWithPointer:(__bridge const void *)c]];
        [chainNames addObject:NSStringFromClass(c)];
    }
    PLog(@"%@ 类链: %@", prefix, [chainNames componentsJoinedByString:@" < "]);

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<id> *children = [NSMutableArray array];
    NSInteger left = maxIvars, all = 0;

    for (NSValue *v in chain) {
        Class c = (__bridge Class)v.pointerValue;
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(c, &n);
        if (!ivars) continue;
        all += (NSInteger)n;
        for (unsigned int i = 0; i < n && left > 0; i++) {
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
                __unsafe_unretained id v2 = nil;
                memcpy(&v2, base, sizeof(id));
                if (!v2) {
                    val = @"(nil)";
                } else {
                    val = PShort(v2, 320);
                    // 只往「自己家的消息/内容模型」里钻一层；Foundation 容器一律不碰
                    if (depth > 0 &&
                        ([low containsString:@"content"] || [low containsString:@"body"] ||
                         [low containsString:@"msgmodel"])) {
                        const char *ccn = object_getClassName(v2);
                        if (ccn && (PStrHas(ccn, "Message") || PStrHas(ccn, "Msg") ||
                                    PStrHas(ccn, "Content") || !strncmp(ccn, "IESIM", 5) ||
                                    !strncmp(ccn, "TIMX", 4) || !strncmp(ccn, "AWEIM", 5))) {
                            childObj = v2;
                        }
                    }
                }
            } else if (t == 'd') {
                double d = 0; memcpy(&d, base, sizeof(double));
                val = [NSString stringWithFormat:@"%g", d];
            } else if (t == 'f') {
                float f = 0; memcpy(&f, base, sizeof(float));
                val = [NSString stringWithFormat:@"%g", (double)f];
            } else if (strchr("cCsSiIlLqQB", t)) {
                size_t sz = 4;
                switch (t) {
                    case 'c': case 'C': case 'B': sz = 1; break;
                    case 's': case 'S': sz = 2; break;
                    case 'i': case 'I': sz = 4; break;
                    default: sz = 8; break;
                }
                long long ll = 0;
                memcpy(&ll, base, sz);
                val = [NSString stringWithFormat:@"%lld", ll];
            } else {
                continue;   // 结构体/指针一律不展开
            }

            [lines addObject:[NSString stringWithFormat:@"%@ %@ = %@", prefix, name, val]];
            if (childObj) [children addObject:childObj];
            left--;
        }
        free(ivars);
    }

    for (NSString *l in lines) {
        // ★ 打标记：名字或值里带「闪/焚/只看一次」语义的，一眼就能在几十行里挑出来
        NSString *ll = l.lowercaseString;
        BOOL hit = [ll containsString:@"watchonce"] || [ll containsString:@"onceread"] ||
                   [ll containsString:@"readonce"] || [ll containsString:@"flash"] ||
                   [ll containsString:@"burn"] || [ll containsString:@"snap"] ||
                   [ll containsString:@"ephemeral"] || [ll containsString:@"secret"] ||
                   [ll containsString:@"destroy"] || [ll containsString:@"expire"] ||
                   [ll containsString:@"阅后"] || [ll containsString:@"闪"];
        PLog(@"%@%@", hit ? @"★ " : @"", l);
    }
    NSInteger shown = maxIvars - left;
    if (all > shown) {
        PLog(@"%@ …(还有 %ld 个 ivar 未打印)", prefix, (long)(all - shown));
    }

    for (id c in children) {
        PDumpIvars(c, [prefix stringByAppendingString:@" ↳"], depth - 1, maxIvars / 2);
    }
}

#pragma mark - 判定

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

// 去掉 KVO 动态子类前缀：NSKVONotifying_AWEIMWatchOnceImageMessage → AWEIMWatchOnceImageMessage
static const char *PPlainClassName(Class cls) {
    const char *cn = cls ? class_getName(cls) : NULL;
    if (!cn) return NULL;
    if (!strncmp(cn, "NSKVONotifying_", 15)) cn += 15;
    return cn;
}

// 图片消息模型类：…Image… 且以 Message / Msg 结尾，排除视图与控制器
static BOOL PIsImageMessageClass(Class cls) {
    const char *cn = PPlainClassName(cls);
    if (!cn) return NO;
    if (!PStrHas(cn, "Image") && !PStrHas(cn, "Pic") && !PStrHas(cn, "Photo")) return NO;
    size_t len = strlen(cn);
    BOOL endsMessage = (len > 7 && strcmp(cn + len - 7, "Message") == 0);
    BOOL endsMsg = (len > 3 && strcmp(cn + len - 3, "Msg") == 0);
    if (!endsMessage && !endsMsg) return NO;
    if (PStrHas(cn, "Cell") || PStrHas(cn, "View") || PStrHas(cn, "Controller")) return NO;
    return YES;
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
    const char *cn = PPlainClassName(cls);
    if (!cn) return NO;
    if (strcmp(cn, "IESIMSendMessageModel") == 0) return YES;
    return PStrHas(cn, "MessageContent") || PStrHas(cn, "ImageMsg") ||
           PStrHas(cn, "ImageMessage") || PStrHas(cn, "WatchOnce") ||
           PStrHas(cn, "SendMessageModel");
}

static BOOL PSelIsFlashish(const char *sn) {
    return PStrHas(sn, "WatchOnce") || PStrHas(sn, "Flash") || PStrHas(sn, "Burn") ||
           PStrHas(sn, "Ephemeral") || PStrHas(sn, "Snap") || PStrHas(sn, "Secret") ||
           PStrHas(sn, "OnceRead") || PStrHas(sn, "ReadOnce") || PStrHas(sn, "Destroy");
}

static void SLProbeObjSetter(id self, SEL _cmd, id arg) {
    IMP o = SLProbeOrigIMP(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
    if (!sProbeActive || !SLProbeShouldLog(_cmd)) return;

    const char *sn = sel_getName(_cmd);
    BOOL flashish = PSelIsFlashish(sn);
    BOOL img = !flashish && PLooksLikeImageSend(arg);
    // 图片消息类的 setContent: —— 普通图与闪图的分界线就在这里，两边各抓一份
    BOOL contentish = !flashish && !img && PIsImageMessageClass(object_getClass(self)) &&
                      (PStrHas(sn, "Content") || PStrHas(sn, "Body"));
    if (!flashish && !img && !contentish) return;

    NSString *cls = NSStringFromClass(object_getClass(self));
    const char *plain = PPlainClassName(object_getClass(self));
    BOOL watchOnce = plain && PStrHas(plain, "WatchOnce");
    NSString *mark = watchOnce ? @"★ " : @"";

    if (flashish) {
        PLog(@"%@FLASHISH %@ -%s = %@", mark, cls, sn, PShort(arg, 400));
        PDumpIvars(self, @"  ↳", 1, 60);
    } else if (img) {
        PLog(@"%@===== IMG-SEND #%ld  %@ -%s =====", mark, (long)(++sSendSeq), cls, sn);
        PDumpIvars(self, @"  ↓", 2, 80);
        PLog(@"===== IMG-SEND #%ld end =====", (long)sSendSeq);
    } else {
        PLog(@"%@===== CONTENT #%ld  %@ -%s arg=%@ =====", mark, (long)(++sSendSeq), cls, sn,
             NSStringFromClass(object_getClass(arg)) ?: @"?");
        PDumpIvars(self, @"  ↓", 1, 60);
        PDumpIvars(arg, @"  ↳", 1, 40);
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
               (PStrHas(sn, "Type") || PStrHas(sn, "Scene") || PStrHas(sn, "Mode"));
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

// 只碰「值得看」的 setter：ext 家族 + content 家族 + 只看一次家族
static BOOL SLProbeIsInterestingSetter(const char *sn) {
    if (!sn || strncmp(sn, "set", 3) != 0) return NO;
    const char *rest = sn + 3;
    if (PSelIsFlashish(rest)) return YES;
    static const char *keys[] = { "Ext", "Extra", "Content", "Body", "MsgType", "MessageType" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (PStrHas(rest, keys[i])) return YES;
    }
    return NO;
}

// 只挂 IM 消息模型本体，视图/控制器/管理器一律跳过
static BOOL PIsIMModelClass(const char *cn) {
    if (!cn) return NO;
    BOOL im = (strncmp(cn, "IESIM", 5) == 0) || (strncmp(cn, "TIMX", 4) == 0) ||
              (strncmp(cn, "AWEIM", 5) == 0);
    if (!im) return NO;
    if (PStrHas(cn, "Cell") || PStrHas(cn, "View") || PStrHas(cn, "Controller") ||
        PStrHas(cn, "Manager") || PStrHas(cn, "Tracker")) return NO;
    return PStrHas(cn, "Message") || PStrHas(cn, "Msg");
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

#pragma mark - 类清单（只列真正有用的两组，别再加噪音）

static void SLProbeInventory(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { PLog(@"classlist 为空"); return; }
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) { PLog(@"classlist 内存申请失败"); return; }
    count = objc_getClassList(list, count);

    NSMutableArray<NSString *> *once = [NSMutableArray array];     // 只看一次全家
    NSMutableArray<NSString *> *imgMsg = [NSMutableArray array];   // 图片消息类（含对照组）

    for (int i = 0; i < count; i++) {
        const char *cn = class_getName(list[i]);
        if (!cn) continue;
        if (!strncmp(cn, "NSKVONotifying_", 15)) continue;   // 动态子类不列，省得干扰
        if (PStrHas(cn, "WatchOnce") || PStrHas(cn, "OnceRead") || PStrHas(cn, "ReadOnce") ||
            PStrHas(cn, "BurnAfterRead") || PStrHas(cn, "Ephemeral") || PStrHas(cn, "Snapchat")) {
            NSString *n = [NSString stringWithUTF8String:cn];
            if (n.length) [once addObject:n];
            continue;
        }
        if (PIsImageMessageClass(list[i])) {
            NSString *n = [NSString stringWithUTF8String:cn];
            if (n.length) [imgMsg addObject:n];
        }
    }
    free(list);

    [once sortUsingSelector:@selector(compare:)];
    [imgMsg sortUsingSelector:@selector(compare:)];
    PLog(@"== 类清单：共 %d 类；只看一次系 %lu 个 / 图片消息类 %lu 个 ==",
         count, (unsigned long)once.count, (unsigned long)imgMsg.count);

    NSInteger oc = 0;
    for (NSString *n in once) {
        if (oc++ >= 30) { PLog(@"ONCE-CLASS …(截断)"); break; }
        PLog(@"ONCE-CLASS %@", n);
    }
    NSInteger ic = 0;
    for (NSString *n in imgMsg) {
        if (ic++ >= 30) { PLog(@"IMGMSG-CLASS …(截断)"); break; }
        PLog(@"IMGMSG-CLASS %@", n);
    }
}

static void SLProbeInstallHooks(void) {
    SLProbeEnsureDicts();
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!list) return;
    count = objc_getClassList(list, count);

    // 先把确定在用的（IESIMSendMessageModel / 图片消息类）挂上，再挂其它 IM 模型类
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
            PLog(@"==== 闪图探测 v0.5.7 · 抖音 %@ ====",
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
