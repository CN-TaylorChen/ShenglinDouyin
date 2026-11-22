// 评论语音 Hook
// CN-TaylorChen | github.com/CN-TaylorChen

#import "AWECAHeaders.h"
#import "AWECAUtils.h"
#import "AWECADownloadManager.h"
#import "AWECAAudioReplacer.h"
#import "AWECACommentHeaderButton.h"
#import "AWECARecordEnhance.h"
#import "AWECATTSManager.h"
#import "SLEntry.h"
#import "SLLog.h"
#import "SLVoicePack.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

static void setupAudioIconElementHook(void);
static void setupAudioInputElementHook(void);

// 悬浮球状态桥：SLEntry 的球只认这四个态，抖音这边在关键节点各推一次。
// 界面细节全在 SLEntry.m，这里只负责「什么时候该是什么颜色」。
static void SLFloatPush(SLFloatState st) {
    if ([NSThread isMainThread]) {
        SLFloatSetState(st);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            SLFloatSetState(st);
        });
    }
}

// 替换结果落定：无论成功失败，替换都已经发生、这一发已经消费掉 → 一律回灰。
// 绿色只在「装填待发」时亮（armPack / SLTTSPageArm），发出去后不再常驻。
static void SLFloatPushResult(BOOL ok) {
    (void)ok;
    SLFloatPush(SLFloatStateIdle);
}

#pragma mark - 设置页 ↔ 替换槽（SLEntry / SLTTSComposeController 的落地桥）

// 陌陌那边这两个函数是把 PCM 喂进自己的 AudioStreamBus；抖音评论区是「录完改文件」，
// 所以同样的语义落到 AWECAAudioReplacer 的替换槽上：装填 = 设好待替换音频并开启替换。

#define kSLDouyinEnabledKey @"SLEnhanceEnabled"

BOOL SLTTSPageIsEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:kSLDouyinEnabledKey] ? [d boolForKey:kSLDouyinEnabledKey] : YES;
}

BOOL SLTTSPageArm(NSString *audioPath, double duration, NSData *pcm16k, NSString *text) {
    (void)duration;
    (void)pcm16k;   // 抖音走文件替换，用不上 16k PCM；参数保留只为兼容原有调用点
    if (![audioPath isKindOfClass:[NSString class]] || audioPath.length == 0) return NO;
    // v0.5.2：不再看「评论录音转音色」开关。用户在文本转语音页主动合成出来的，
    // 语义就是「下一条录音用这段」，不该被自动转换的开关否决（以前私聊装了也用不上，
    // 一部分原因就是评论开关关着，这里直接 return NO，装填静默失败）。

    AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
    // 这里不能用 clearReplacement：它会弹「已关闭语音替换」——
    // 用户刚合成完，先被告知"已关闭"，下一秒又装上了，纯属自打脸。
    replacer.replacementAudioPath = audioPath;
    replacer.ttsAudioPath = nil;
    replacer.enabled = YES;
    [replacer saveState];

    [SLVoicePack setOneShotPending:YES];
    [SLVoicePack setArmedSource:SLArmedSourceAI];   // 胶囊名字显示「AI 语音」而不是包名
    SLFloatPush(SLFloatStateReady);
    SLLog(@"TTS-PAGE armed path=%@ textLen=%lu", audioPath.lastPathComponent, (unsigned long)text.length);

    // 5 分钟没录音就自动解除，避免误替换下一条普通语音。
    // （原来是 60 秒：合成完切出去回条消息就过期了，用户会以为"装填没生效"。）
    NSString *armed = [audioPath copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AWECAAudioReplacer *r = [AWECAAudioReplacer shared];
        if (r.replacementAudioPath && [r.replacementAudioPath isEqualToString:armed]) {
            [SLVoicePack disarmArmedAudio];
            SLLog(@"TTS-PAGE armed expired (5min), cleared");
        }
    });
    return YES;
}

void SLClearArmedAudio(void) {
    // 单点真相：清槽位这件事只有 SLVoicePack 一处实现（球色、one-shot、replacer 一起落）
    [SLVoicePack disarmArmedAudio];
    SLLog(@"armed audio cleared by UI");
}

// 语音包预热：陌陌那边要把包解成 PCM 喂 bus，抖音是文件替换，只需确认包可用，
// 免得第一次录音才发现包坏了。调用点在 SLEntry（球展开 / 启动后各一次）。
void SLPackPrewarm(void) {
    if (![SLVoicePack isEnabled]) return;
    NSDictionary *pack = [SLVoicePack activePack];
    if (!pack) return;
    NSString *path = [SLVoicePack pathOfPack:pack];
    if (!path.length) return;
    double dur = [AWECAUtils audioDurationAtPath:path];
    if (dur <= 0.05) {
        SLLog(@"PACK prewarm 包不可用: %@", path.lastPathComponent);
        return;
    }
    SLLog(@"PACK prewarm ok %@ %.2fs", path.lastPathComponent, dur);
}

// 日志页顶部那行状态摘要。
// 这里必须如实反映「谁挂上了」——按类名动态安装的两个钩子找不到类时是静默跳过的，
// 而它们恰好就是「录音按钮点了没反应」「预览气泡不显示替换结果」的唯二原因。
static BOOL sSLHookPreview = NO;    // generateAudioPreviewBubbleWithRecordedModel:
static BOOL sSLHookIconBtn = NO;    // CommentAudioIconElement 的 viewDidLoad / handleAudioButton

NSString *SLHookStatusSummary(void) {
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    [list addObject:@"录音器"];     // %hook AWECommentAudioRecorderController（编译期挂钩，一定在）
    [list addObject:@"上传管理"];   // %hook AWECommentAudioUploadManager
    [list addObject:@"私聊录音"];   // AWEIM*
    if (sSLHookPreview) [list addObject:@"预览气泡"];
    if (sSLHookIconBtn) [list addObject:@"录音按钮"];
    return [NSString stringWithFormat:@"已装钩子：%@", [list componentsJoinedByString:@"  "]];
}

// 第二行：当前运行态。用户反馈问题时，这一行 + 下面几行日志就能定位八成情况。
NSString *SLRuntimeStateSummary(void) {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
    NSString *slot = replacer.replacementAudioPath;
    unsigned long long sz = 0;
    if (slot.length) {
        sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:slot error:nil][NSFileSize] unsignedLongLongValue];
    }
    NSInteger src = (NSInteger)[SLVoicePack armedSource];
    NSString *srcName = (src == SLArmedSourcePack) ? @"语音包"
                      : (src == SLArmedSourceAI) ? @"AI 语音" : @"无";
    return [NSString stringWithFormat:@"增强 %@ · 替换 %@ · 槽位 %@ · 来源 %@ · %lluKB",
            enhance.enhanceEnabled ? @"开" : @"关",
            replacer.enabled ? @"开" : @"关",
            slot.length ? slot.lastPathComponent : @"空",
            srcName, sz / 1024];
}

// 录音结束替换

%hook AWECommentAudioRecorderController

- (void)audioRecorderStartRecord:(id)recorder error:(id)error {
    %orig;
    if (!error) {
        [[AWECARecordEnhance shared] markCommentTakeStarted];
        SLFloatPush(SLFloatStateRecording);   // 球转红，用户一眼知道正在录
    }
}

- (void)clear {
    [[AWECARecordEnhance shared] markCommentTakeCancelled];
    // 上滑取消也是「原声」：录音红要落回灰，否则球会一直挂在红上。
    SLFloatPush(SLFloatStateIdle);
    %orig;
}

- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success error:(id)error {
    NSString *path = self.audioFilePath.length ? self.audioFilePath : self.recorder.url.path;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];

    // 取消残留：上滑取消时抖音也会以 success:YES 走到这里（文件落盘后被丢弃）。
    // cancelledTake 是状态位：从 clear（取消）起置位，到下一次录音开始（markCommentTakeStarted）才清零，
    // 因此无论取消的完成回调迟到多久都能识别；且取消的 DidFinishRecording 必先于用户下一次录音操作，
    // 不存在"误挡正常录音"的窗口（早期用 0.5s 时间窗，主线程忙时必漏）
    BOOL cancelResidue = enhance.cancelledTake;
    BOOL armedLocal = [enhance hasArmedLocalAudio];

    // 这一行是排查「选了语音包却不替换」的唯一入口：把这一刻的五个开关全摊开。
    SLLog(@"CMT finish success=%d path=%@ exists=%d cancelResidue=%d armedLocal=%d replacerOn=%d slot=%@ enh=%d armed=%d",
          success, path.lastPathComponent ?: @"(nil)",
          (int)(path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]),
          cancelResidue, armedLocal, replacer.enabled,
          replacer.replacementAudioPath.lastPathComponent ?: @"(空)",
          enhance.enhanceEnabled, enhance.armed);

    // ① 语音包 / 本地音频 / 文字合成已经装填：直接换文件。
    // 必须排在最前面 —— 之前装了语音包，录音结束照样被 ASR+TTS 的合成结果覆盖，
    // 用户看到的就是「选了包却还是 AI 音色」，而且白花一次识别和合成额度。
    // v0.5.x：替换挪到 %orig **之前**。抖音在 DidFinish 里就会生成预览气泡并起上传，
    // 等 %orig 返回再换文件，上传可能已经抓着原声走了 —— 表现就是"换了个寂寞"。
    if (success && !cancelResidue && path.length && armedLocal) {
        NSString *target = self.audioFilePath.length ? self.audioFilePath : self.recorder.url.path;
        if (!target.length) target = path;
        if (![[NSFileManager defaultManager] fileExistsAtPath:target]) target = path;
        BOOL done = target.length ? [replacer replaceAudioAtPath:target] : NO;

        %orig;   // 让原生继续（预览气泡 / 上传读的就是刚换好的文件）

        [enhance consumeArmedLocalAudio];   // 一发即用，别让下一条普通录音又被换掉
        SLFloatPushResult(done);
        SLLog(@"CMT direct-replace %@ target=%@", done ? @"ok" : @"失败", target.lastPathComponent);
        if (!done) [AWECAUtils showToast:@"替换失败，保留原声"];
        return;
    }

    if (success && enhance.enhanceEnabled && enhance.armed
        && !armedLocal && ![enhance shouldRunForCommentRecording]) {
        SLLog(@"CMT 跳过合成：凭证缺失");
        [AWECAUtils showToast:@"请先填写火山 API Key"];
        SLFloatPush(SLFloatStateIdle);   // 发原声：录音红必须落回灰
        %orig;
        return;
    }

    if (success && !cancelResidue && [enhance shouldRunForCommentRecording] && path.length) {
        SLFloatPush(SLFloatStateSynthesizing);   // 球转蓝：录音已落盘，正在识别 + 合成
        [enhance beginIfNeededAtPath:path];
        %orig;
        return;
    }

    if (success && [enhance shouldSkipStickyReplaceForPath:path]) {
        // busy 时 SLFloatSetState 的合成闸会挡下这个 Idle（球仍由在飞流水线收尾）；
        // 其余情况都是发原声，红必须落灰。
        SLFloatPush(SLFloatStateIdle);
        %orig;
        return;
    }

    // v0.5.1：认来源标记而非裸 enabled——脏槽（流水线合成残留）不能触发替换，
    // 否则会拿上一条的合成音盖本次录音，且合成流水线本该跑却被跳过（表现成「延迟填充」）。
    if (success && [enhance hasArmedLocalAudio]) {
        NSString *recorderURL = self.recorder.url.path;
        // 同上：先换再 %orig，别等原生已经把文件读走
        NSString *target = self.audioFilePath.length ? self.audioFilePath : recorderURL;
        if (!target.length) target = path;
        BOOL done = target.length ? [[AWECAAudioReplacer shared] replaceAudioAtPath:target] : NO;

        %orig;

        SLFloatPushResult(done);
        SLLog(@"CMT sticky-replace %@ target=%@", done ? @"ok" : @"失败", target.lastPathComponent);
        if (done) [AWECAUtils showToast:@"语音已替换"];
    } else {
        %orig;
        // 纯原声录制（替换关 / 增强关 / 合成未命中）：录音红落回灰。
        SLFloatPush(SLFloatStateIdle);
    }
}

- (void)setAudioFilePath:(NSString *)audioFilePath {
    %orig;
    if (!audioFilePath.length) return;
    if ([[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:audioFilePath]) return;
    // v0.5.1：认来源标记而非裸 enabled——脏槽（流水线合成残留）不能触发替换
    if (![[AWECARecordEnhance shared] hasArmedLocalAudio]) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:audioFilePath]) {
        BOOL done = [[AWECAAudioReplacer shared] replaceAudioAtPath:audioFilePath];
        SLFloatPushResult(done);
        SLLog(@"CMT setAudioFilePath 替换 %@ %@", done ? @"ok" : @"失败", audioFilePath.lastPathComponent);
    }
}

%end

// 私聊（IM）录音转音色
//
// 血泪教训：钩子必须挂到「真正实现该方法的类」上，挂到持有者/调用者类上是死钩（编译通过、运行零反应）。
// 40.8.0 二进制 classlist 反查确认的实现分布：
//   recorderAnimationViewDidTapSendAudio:  -> AWEIMOptimizeAudioInputTouchView（新面板触摸层，UI 事件入口）
//   audioInputTouchView*                   -> AWEIMAudioRecordController / AWEIMFormatAudioRecordController
//   落盘发送：
//     AWEIMAudioRecordController       .sendRecordMessageIfNeededWithFilePath:audioRecorder:   (NSString 路径)
//     AWEIMFormatAudioRecordController .sendRecordMessageIfNeededWithData:audioRecorder:      (NSData，无落盘路径)
//   录音器：AWEIMAudioMessageRecorder.url
//
// 策略：每个流程只在「终局发送点」拦截一次（避免双击重复发），全程打 AWECA-IM 日志自证；
//       拦截后跑完流水线再重放发送，松手即发/面板确认都走同一条终局路径。

#pragma mark - 私聊工具函数

static NSString *AWECAPathFromValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] ? (NSString *)v : nil;
    if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v path];
    return nil;
}

// 运行时安全取值：不依赖编译期类型，避免头文件/类名漂移导致编译失败
static id AWECASafeGet(id obj, NSString *name) {
    if (!obj || !name.length) return nil;
    SEL s = NSSelectorFromString(name);
    if (![obj respondsToSelector:s]) return nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [obj performSelector:s];
#pragma clang diagnostic pop
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *AWECAPrivateTempPath(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"aweca_im"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"im_%.0f.m4a", [[NSDate date] timeIntervalSince1970] * 1000]];
}

// Format 架构直接传 NSData（无落盘路径）：先把原声落地成临时文件，再走同一条流水线
static NSString *AWECAPrivateMaterialize(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    NSString *p = AWECAPrivateTempPath();
    return [data writeToFile:p atomically:YES] ? p : nil;
}

// 从入口自带值 / 控制器属性里找本次录音的真实文件路径（优先已存在的文件）
static NSString *AWECAPrivateResolvePath(id primary, id ctrl) {
    NSString *p = AWECAPathFromValue(primary);
    if (p.length && [[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    if (ctrl) {
        for (NSString *name in @[@"recordFilePath", @"audioFilePath", @"filePath", @"recordPath"]) {
            NSString *q = AWECAPathFromValue(AWECASafeGet(ctrl, name));
            if (q.length && [[NSFileManager defaultManager] fileExistsAtPath:q]) return q;
        }
    }
    return nil;
}

// 记录本次私聊录音的落盘路径（并按需兜底武装 + 尽早起跑流水线）
// v1.4.6：起跑前先复制快照——抖音私聊每条录音复用同一路径，流水线绝不在活文件上转换
static void AWECAPrivateNotePath(NSString *path) {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (!path.length || !enhance.privateEnhanceEnabled) return;
    // 重放再入护栏：重放带的是插件自有快照路径，不是新录音，绝不能武装/覆盖 privateRecordPath
    if ([AWECARecordEnhance isPluginOwnedPath:path]) return;
    // v0.5.3：重放（skipOnce=YES）时这条文件**已经换好了**，绝不能再起跑投机流水线。
    // 直替换是「就地覆盖」的，路径没变（仍是 audio1.m4a）→ 重放会原样回到本函数，
    // 而那一刻装填已被 consume，hasArmedLocalAudio=NO，于是白跑一遍 ASR+TTS：
    // 胶囊被它顶成「识别中/合成中」、SLFloatPushResult(Idle) 又被合成闸拦掉，
    // 用户看到的就是「语音包明明替换成功，球却一直转蓝、永远不回灰」。
    if (enhance.privateSkipOnce) {
        SLLog(@"IM 重放，跳过预转换 %@", path.lastPathComponent);
        return;
    }
    if (!enhance.privateArmed) [enhance markPrivateTakeStarted];
    enhance.privateRecordPath = path;
    // 装了本地音频（语音包 / 文本转语音）：这一发走直替换，根本不需要识别+合成。
    // 以前照样投机起跑流水线，白花一次 ASR+TTS，还会让球卡在「合成中」抢走直替换的收尾。
    if ([enhance hasArmedLocalAudio]) {
        SLLog(@"IM 已装填，跳过预转换 %@", path.lastPathComponent);
        return;
    }
    [enhance privateBeginForSourcePath:path];   // 趁用户停确认面板上，提前消化数十秒合成耗时
}

static void AWECACall2(id target, SEL sel, id a, id b) {
    if (!target || !sel) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, a, b);
}

// 发送闸门：返回 YES = 已接管（调用方不要再 %orig，由 fire 负责重放），NO = 直接放行。
// fire 在流水线结束后于主线程回调，调用方在其中执行真正的发送。
// replayPath 是「拦截当下」就定好的音频文件；此后即便新录音清掉快照映射，重放仍用这一条。
static BOOL AWECAPrivateGate(const char *tag, NSString *path,
                             void (^fire)(BOOL ok, NSString *message, NSString *replayPath)) {
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: [%s] send path=%@ armed=%d skip=%d",
          tag, path, enhance.privateArmed, enhance.privateSkipOnce);

    if (enhance.privateSkipOnce) {
        enhance.privateSkipOnce = NO;
        NSLog(@"AWECA-IM: [%s] passthrough (already enhanced)", tag);
        return NO;
    }
    if (path.length) enhance.privateRecordPath = path;

    // 装填了本地音频（语音包 / 文本转语音合成的 AI 语音）：私聊链路和评论区不一样 ——
    // 评论区有 setAudioFilePath / 上传前 / 预览气泡三处换文件的钩子，私聊一个都没有，
    // 发送点就是唯一能换的地方。v0.5.1 之前这里直接 passthrough，结果就是
    // 「球是绿的、发出去还是原声」（用户：文本转语音 / 语音包在私聊里用不了）。
    // 现在：先把这一发要发的文件换成装填音，再原样重放一次（重放走 skipOnce 放行）。
    if ([enhance hasArmedLocalAudio]) {
        AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
        NSString *armed = [replacer.replacementAudioPath copy];
        // 就地覆盖：路径不变，抖音后续的上传/转码/时长计算全都读真实内容，
        // 比直接发一个别处的文件稳（评论区也是这么做的）。
        BOOL inPlace = (path.length && [replacer replaceAudioAtPath:path]);
        NSString *replay = inPlace ? path : armed;   // 覆盖失败就改发装填文件本身
        SLLog(@"IM 直替换 %@ target=%@", inPlace ? @"ok" : @"回退装填文件", replay.lastPathComponent);
        [enhance abortSpeculativePipelineForSourcePath:path];   // 收掉可能已在飞的投机流水线
        [enhance consumeArmedLocalAudio];                       // 一发即用
        enhance.privateSkipOnce = YES;                          // 重放不再拦截
        void (^go)(void) = ^{
            @try {
                if (fire) fire(YES, nil, replay);
            } @catch (NSException *e) {
                NSLog(@"AWECA-IM: [%s] armed fire exception: %@", tag, e);
            }
            [enhance resetPrivateTake];
            SLFloatPushResult(YES);   // 替换已发生：球回灰
        };
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
        return YES;
    }

    if (![enhance shouldRunForPrivateRecording]) {
        NSLog(@"AWECA-IM: [%s] passthrough (not eligible)", tag);
        return NO;
    }

    NSString *p = [path copy];
    NSLog(@"AWECA-IM: [%s] INTERCEPT, enhancing %@", tag, p);
    [AWECAUtils showToast:@"识别合成中..." duration:2.0];

    // 关键：在拦截这一刻就把「重放要发的文件」钉死。
    // 旧做法在 fire 里才 snapshotPathForSourcePath:path 回查——连续录制时新的一遍会把
    // snapMap 清掉，回查拿到 nil 就退回抖音复用的活路径（此时是空/下一条的文件），
    // 表现为「0 秒」「录不进去」。提前捕获可彻底避开这个竞态。
    NSString *snapAtIntercept = [enhance snapshotPathForSourcePath:p];
    if (!snapAtIntercept.length) {
        // 极少数直达发送的分支还没建快照：让 privateWait 建好再取。
        [enhance privateBeginForSourcePath:p];
        snapAtIntercept = [enhance snapshotPathForSourcePath:p];
    }
    NSString *replayAtIntercept = (snapAtIntercept.length &&
        [[NSFileManager defaultManager] fileExistsAtPath:snapAtIntercept]) ? snapAtIntercept : p;

    // v1.4.6 快照隔离：流水线只对插件私有副本转换，抖音复用的活路径全程不被触碰；
    // 已取消（message 含"已取消"）绝不补发——取消过程中同步发消息会弄乱抖音录音 UI
    [enhance privateWaitForSourcePath:p completion:^(BOOL ok, NSString *message) {
        NSLog(@"AWECA-IM: [%s] pipeline done ok=%d msg=%@ aborted=%d",
              tag, ok, message, enhance.privateAborted);
        if (message.length) [AWECAUtils showToast:message duration:2.5];
        if (!ok && [message containsString:@"已取消"]) {
            [enhance resetPrivateTake];
            return;
        }
        if (enhance.privateAborted) {
            [enhance resetPrivateTake];
            return;
        }
        enhance.privateSkipOnce = YES;
        void (^safeFire)(void) = ^{
            @try {
                if (fire) fire(ok, message, replayAtIntercept);
            } @catch (NSException *e) {
                NSLog(@"AWECA-IM: [%s] fire exception: %@", tag, e);
            }
            [enhance resetPrivateTake];
        };
        if ([NSThread isMainThread]) safeFire();
        else dispatch_async(dispatch_get_main_queue(), safeFire);
    }];
    return YES;
}

#pragma mark - 私聊声临状态条（v1.4.6）

// ===== 新面板触摸层：UI 事件入口（40.8.0 私聊实际走这条）=====
// 注意：头文件里该类只是 NSObject 前向声明，UIView 属性一律经 id 桥接访问；
// 新增方法必须 %new，钩子内经 objc_msgSend 调用（编译器看不到选择器声明）

%hook AWEIMOptimizeAudioInputTouchView

// 手势开始：武装私聊场景（兜底，控制器 delegate 的 TouchDown 也会武装）
- (void)startRecord {
    %orig;
    NSLog(@"AWECA-IM: touchView startRecord");
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (enhance.privateEnhanceEnabled) [enhance markPrivateTakeStarted];
}

- (void)cancelRecord {
    // 铁律：%orig 必须最先执行——原生取消录音绝不能被插件状态代码挡住
    // （状态代码若抛异常，%orig 不执行，触摸层卡在"正在录音"，必须重进会话才能恢复）
    %orig;
    NSLog(@"AWECA-IM: touchView cancelRecord");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: cancelRecord state exception: %@", e);
    }
}

- (void)stopRecordWithInTranslate:(BOOL)inTranslate {
    %orig;
    NSLog(@"AWECA-IM: touchView stopRecord inTranslate=%d", inTranslate);
    if (inTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

// 取消：撤装，防止误拦截后续的发送
- (void)recorderAnimationViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: touchView DidTapCancel");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: DidTapCancel state exception: %@", e);
    }
}

// 点「发送语音」：本层只放行，真正的拦截放在控制器终局发送点（避免双击重复发）
- (void)recorderAnimationViewDidTapSendAudio:(id)view {
    NSLog(@"AWECA-IM: touchView DidTapSendAudio (passthrough)");
    %orig;
}

%end

// ===== 老控制器（文件路径架构）=====
%hook AWEIMAudioRecordController

// 录音结束：记下路径并尽早起跑流水线
- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success action:(NSInteger)action error:(id)error {
    %orig;
    NSString *path = self.recordFilePath;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: CtrlDidFinish(action) success=%d action=%ld path=%@ armed=%d",
          success, (long)action, path, enhance.privateArmed);
    if (!success) return;
    if (!path.length) path = AWECAPathFromValue(AWECASafeGet(recorder, @"url"));
    AWECAPrivateNotePath(path);
}

// 手指按下：武装
- (void)audioInputTouchViewTouchDownInside:(id)view {
    %orig;
    NSLog(@"AWECA-IM: CtrlTouchDown");
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (enhance.privateEnhanceEnabled) [enhance markPrivateTakeStarted];
}

// 抬起（取消 / 转文字）→ 撤装
- (void)audioInputTouchViewTouchUpInside:(id)view cancelled:(BOOL)cancelled isInTranslate:(BOOL)isInTranslate {
    %orig;
    NSLog(@"AWECA-IM: CtrlTouchUp cancelled=%d isInTranslate=%d", cancelled, isInTranslate);
    if (cancelled || isInTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewTouchUpOutside:(id)view cancelled:(BOOL)cancelled {
    %orig;
    NSLog(@"AWECA-IM: CtrlTouchUpOutside cancelled=%d", cancelled);
    if (cancelled) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: CtrlDidTapCancel");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: CtrlDidTapCancel state exception: %@", e);
    }
}

// 点「发送语音」（面板确认）：放行，由终局发送点统一拦截
- (void)audioInputTouchViewDidTapSendAudio:(id)view {
    NSLog(@"AWECA-IM: CtrlDidTapSendAudio (passthrough)");
    %orig;
}

// 终局发送点（松手即发 / 面板确认都会走到这里）：拦截 → 跑流水线 → 重放
- (void)sendRecordMessageIfNeededWithFilePath:(id)filePath audioRecorder:(id)recorder {
    __weak id wctrl = self;   // 流水线数十秒，期间用户可能退出会话：弱引用防重放消息到已析构对象
    NSString *path = AWECAPrivateResolvePath(filePath, self);
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: CtrlSend(file) raw=%@ path=%@ armed=%d", filePath, path, enhance.privateArmed);
    @try { AWECAPrivateNotePath(path); } @catch (NSException *e) {}
    if (AWECAPrivateGate("ctrl-file", path, ^(BOOL ok, NSString *m, NSString *replayPath) {
        // v1.4.6 快照重放：发的是拦截当下钉死的副本路径（成功=合成音频，失败=原声副本）。
        // 旧做法在 fire 时才回查 snapMap，连续录制下一条会清掉映射、退回抖音复用的活路径，
        // 发出去的就是空/下一条的声音（0 秒、录不进去）。replayPath 由 gate 提前定好。
        void (^go)(void) = ^{
            __strong id sctrl = wctrl;
            if (!sctrl) { NSLog(@"AWECA-IM: ctrl-file replay skipped (controller gone)"); return; }
            AWECACall2(sctrl, @selector(sendRecordMessageIfNeededWithFilePath:audioRecorder:), replayPath, recorder);
        };
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    })) return;
    %orig;
}

%end

// ===== 新控制器（Format / NSData 架构）=====
%hook AWEIMFormatAudioRecordController

- (void)audioRecorderDidFinishRecording:(id)recorder success:(BOOL)success action:(NSInteger)action error:(id)error {
    %orig;
    NSString *path = AWECAPathFromValue(AWECASafeGet(recorder, @"url"));
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: FormatDidFinish success=%d path=%@ armed=%d", success, path, enhance.privateArmed);
    if (!success) return;
    AWECAPrivateNotePath(path);
}

- (void)audioInputTouchViewTouchDownInside:(id)view {
    %orig;
    NSLog(@"AWECA-IM: FormatTouchDown");
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    if (enhance.privateEnhanceEnabled) [enhance markPrivateTakeStarted];
}

- (void)audioInputTouchViewTouchUpInside:(id)view cancelled:(BOOL)cancelled isInTranslate:(BOOL)isInTranslate {
    %orig;
    NSLog(@"AWECA-IM: FormatTouchUp cancelled=%d isInTranslate=%d", cancelled, isInTranslate);
    if (cancelled || isInTranslate) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewTouchUpOutside:(id)view cancelled:(BOOL)cancelled {
    %orig;
    NSLog(@"AWECA-IM: FormatTouchUpOutside cancelled=%d", cancelled);
    if (cancelled) [[AWECARecordEnhance shared] markPrivateTakeCancelled];
}

- (void)audioInputTouchViewDidTapCancel:(id)view {
    %orig;
    NSLog(@"AWECA-IM: FormatDidTapCancel");
    @try {
        [[AWECARecordEnhance shared] markPrivateTakeCancelled];
    } @catch (NSException *e) {
        NSLog(@"AWECA-IM: FormatDidTapCancel state exception: %@", e);
    }
}

- (void)audioInputTouchViewDidTapSendAudio:(id)view {
    NSLog(@"AWECA-IM: FormatDidTapSendAudio (passthrough)");
    %orig;
}

// 终局发送点：直接传 NSData（无落盘路径）→ 落地临时文件再走同一条流水线，
// 流水线结束后读回文件内容，重新发送（失败则发原声）
- (void)sendRecordMessageIfNeededWithData:(id)data audioRecorder:(id)recorder {
    __weak id wctrl = self;   // 流水线数十秒，期间用户可能退出会话：弱引用防重放消息到已析构对象
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSString *path = AWECAPrivateMaterialize(data);
    NSLog(@"AWECA-IM: FormatSend(data) len=%lu path=%@ armed=%d",
          (unsigned long)([data isKindOfClass:[NSData class]] ? ((NSData *)data).length : 0),
          path, enhance.privateArmed);
    @try { AWECAPrivateNotePath(path); } @catch (NSException *e) {}
    if (AWECAPrivateGate("format-data", path, ^(BOOL ok, NSString *m, NSString *replayPath) {
        // 读拦截当下钉死的快照，而不是 fire 时可能已被下一条改写的 path。
        NSData *outData = ok ? [NSData dataWithContentsOfFile:replayPath] : nil;
        NSData *final = (outData.length ? outData
                         : ([data isKindOfClass:[NSData class]] ? (NSData *)data : nil));
        void (^go)(void) = ^{
            __strong id sctrl = wctrl;
            if (!sctrl) { NSLog(@"AWECA-IM: format-data replay skipped (controller gone)"); return; }
            AWECACall2(sctrl, @selector(sendRecordMessageIfNeededWithData:audioRecorder:), final, recorder);
        };
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    })) return;
    %orig;
}

%end

// ===== 录音器层：兜底记录落盘路径 + 武装 =====
%hook AWEIMAudioMessageRecorder

- (void)audioRecorderDidFinishRecording:(id)recorder successfully:(BOOL)success action:(NSInteger)action {
    %orig;
    NSString *path = self.url.path;
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];
    NSLog(@"AWECA-IM: RecorderFinish success=%d path=%@ armed=%d", success, path, enhance.privateArmed);
    if (!success || !path.length) return;
    AWECAPrivateNotePath(path);
}

%end

// 播放时缓存地址

%hook AWECommentAudioPlayerManager

- (void)playAudioWithVideoModel:(id)videoModel startTime:(double)startTime audioEffectExternInfo:(id)info {
    if (videoModel && [videoModel isKindOfClass:[NSString class]]) {
        NSString *jsonStr = (NSString *)videoModel;
        [[AWECADownloadManager shared] parseAndCacheVideoModelJSON:jsonStr];
    }
    %orig;
}

- (void)playAudioWithVideoModel:(id)videoModel startTime:(double)startTime {
    if (videoModel && [videoModel isKindOfClass:[NSString class]]) {
        [[AWECADownloadManager shared] parseAndCacheVideoModelJSON:(NSString *)videoModel];
    }
    %orig;
}

%end

// 长按保存语音

%hook AWECommentLongPressPanelAdaptar

- (void)showLongPressPanelWithParam:(id)param config:(id)config showSheetCompletion:(id)showCompletion dismissSheetCompletion:(id)dismissCompletion {
    %orig;

    AWECommentModel *comment = nil;
    if ([param respondsToSelector:@selector(selectdComment)]) {
        comment = [(AWECommentLongPressPanelParam *)param selectdComment];
    }

    if (!comment || !comment.audioModel) {
        return;
    }

    AWECommentModel *savedComment = comment;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[AWECADownloadManager shared] showSaveDialogAndDownload:savedComment];
    });
}

%end

// 上传前再次替换

%hook AWECommentAudioUploadManager

- (void)startUploadAudioWithFilePath:(id)filePath {
    NSString *path = (NSString *)filePath;
    BOOL skip = [[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:path];
    BOOL on = [[AWECARecordEnhance shared] hasArmedLocalAudio];   // v0.5.1：认来源标记，脏槽不替换
    BOOL exist = path.length && [[NSFileManager defaultManager] fileExistsAtPath:path];
    SLLog(@"UPLOAD startUpload path=%@ exist=%d replacerOn=%d skip=%d", path.lastPathComponent ?: @"(nil)",
          (int)exist, (int)on, (int)skip);
    if (!skip && on && exist) {
        BOOL done = [[AWECAAudioReplacer shared] replaceAudioAtPath:path];
        SLLog(@"UPLOAD 上传前替换 %@", done ? @"ok" : @"失败");
    }
    %orig;
}

- (void)uploadAudioWithFilePath:(id)filePath completion:(id)completion {
    NSString *path = (NSString *)filePath;
    if (![[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:path] &&
        [[AWECARecordEnhance shared] hasArmedLocalAudio] && path.length) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            BOOL done = [[AWECAAudioReplacer shared] replaceAudioAtPath:path];
            SLLog(@"UPLOAD uploadAudio 替换 %@ %@", done ? @"ok" : @"失败", path.lastPathComponent);
        }
    }
    %orig;
}

- (void)uploadAudioWithFilePath:(id)filePath authCompletion:(id)authCompletion completion:(id)completion {
    NSString *path = (NSString *)filePath;
    if (![[AWECARecordEnhance shared] shouldSkipStickyReplaceForPath:path] &&
        [[AWECARecordEnhance shared] hasArmedLocalAudio] && path.length) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            BOOL done = [[AWECAAudioReplacer shared] replaceAudioAtPath:path];
            SLLog(@"UPLOAD uploadAudio(auth) 替换 %@ %@", done ? @"ok" : @"失败", path.lastPathComponent);
        }
    }
    %orig;
}

%end


// 预览气泡替换

static void (*orig_generateAudioPreviewBubble)(id self, SEL _cmd, id recordedModel);
static void hook_generateAudioPreviewBubble(id self, SEL _cmd, id recordedModel) {
    NSString *audioPath = [recordedModel valueForKey:@"audioFilePath"];
    AWECARecordEnhance *enhance = [AWECARecordEnhance shared];

    if (recordedModel && [enhance shouldRunForCommentRecording] && audioPath.length) {
        [enhance waitForEnhancedPath:audioPath completion:^(BOOL ok, NSString *message) {
            if (ok) {
                double realDur = [AWECAUtils audioDurationAtPath:audioPath];
                [recordedModel setValue:@((long long)(realDur * 1000)) forKey:@"duration"];
            }
            orig_generateAudioPreviewBubble(self, _cmd, recordedModel);
            if (message.length) [AWECAUtils showToast:message duration:2.5];
        }];
        return;
    }

    if (recordedModel && ![enhance shouldSkipStickyReplaceForPath:audioPath] && [enhance hasArmedLocalAudio]) {
        if (audioPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:audioPath]) {
            BOOL ok = [[AWECAAudioReplacer shared] replaceAudioAtPath:audioPath];
            SLLog(@"PREVIEW 气泡前替换 %@ %@", ok ? @"ok" : @"失败", audioPath.lastPathComponent);

            if (ok) {
                double realDur = [AWECAUtils audioDurationAtPath:audioPath];
                long long realMs = (long long)(realDur * 1000);
                [recordedModel setValue:@(realMs) forKey:@"duration"];
            }
        }
    }
    orig_generateAudioPreviewBubble(self, _cmd, recordedModel);
}

static void setupAudioInputElementHook(void) {
    Class cls = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentInputAudioInputElement");
    if (!cls) {
        SLLog(@"HOOK 预览气泡：找不到 CommentInputAudioInputElement（类名变了，替换仍会在录音结束/上传前生效）");
        return;
    }
    SEL sel = @selector(generateAudioPreviewBubbleWithRecordedModel:);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        orig_generateAudioPreviewBubble = (void (*)(id, SEL, id))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_generateAudioPreviewBubble);
        sSLHookPreview = YES;
        SLLog(@"HOOK 预览气泡 ok");
    } else {
        SLLog(@"HOOK 预览气泡：方法不在 %@ 上", cls);
    }
}

// 麦克风原生录音

static void (*orig_audioIconViewDidLoad)(id self, SEL _cmd);
static void hook_audioIconViewDidLoad(id self, SEL _cmd) {
    orig_audioIconViewDidLoad(self, _cmd);

    UIView *elementView = nil;
    if ([self respondsToSelector:@selector(view)]) {
        elementView = [self performSelector:@selector(view)];
    }
    if (!elementView) return;

    UIView *redDot = [[UIView alloc] initWithFrame:CGRectMake(elementView.bounds.size.width - 8, 2, 6, 6)];
    redDot.backgroundColor = [UIColor redColor];
    redDot.layer.cornerRadius = 3;
    redDot.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    redDot.hidden = ![AWECARecordEnhance shouldShowStatusDot];
    redDot.tag = kAWECAStatusDotTag;
    [elementView addSubview:redDot];
}

static void (*orig_handleAudioButton)(id self, SEL _cmd);
static void hook_handleAudioButton(id self, SEL _cmd) {
    [[AWECARecordEnhance shared] armFromCommentButton];
    orig_handleAudioButton(self, _cmd);
}

static void setupAudioIconElementHook(void) {
    Class cls = NSClassFromString(@"AWECommentInputViewSwiftImpl.CommentAudioIconElement");
    if (!cls) {
        SLLog(@"HOOK 录音按钮：找不到 CommentAudioIconElement（顶栏按钮与红点不会出现）");
        return;
    }
    SEL sel = @selector(viewDidLoad);
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        orig_audioIconViewDidLoad = (void (*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_audioIconViewDidLoad);
    }

    SEL btnSel = @selector(handleAudioButton);
    Method btnMethod = class_getInstanceMethod(cls, btnSel);
    if (btnMethod) {
        orig_handleAudioButton = (void (*)(id, SEL))method_getImplementation(btnMethod);
        method_setImplementation(btnMethod, (IMP)hook_handleAudioButton);
        sSLHookIconBtn = YES;
        SLLog(@"HOOK 录音按钮 ok");
    } else {
        SLLog(@"HOOK 录音按钮：handleAudioButton 不在 %@ 上", cls);
    }
}

// 插件初始化

%ctor {
    @autoreleasepool {
        [AWECAUtils ensureDirectoriesExist];

        [AWECAAudioReplacer shared];
        [AWECARecordEnhance shared];

        setupAudioInputElementHook();
        setupAudioIconElementHook();
        AWECASetupCommentHeaderButton();

        // 陌陌那套悬浮球原样搬过来：长按进设置、单击展开胶囊、拖动贴边记忆。
        // 入口保留两条路 —— 球（随时可开）+ 评论顶栏按钮（在评论区里更顺手）。
        SLLog(@"==== 声临·抖音版 loaded into %@ ====",
              [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)");
        // 第一行就把日志落在哪打出来：日志页那一栏显示的就是这个路径。
        // 「日志功能好像没用」八成是先写失败（沙盒）又没人说，这里自证一次。
        SLLog(@"log file = %@", [SLLog filePath] ?: @"(不可写)");
        SLLog(@"bundle container = %@", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]);
        @try { SLStartEntryWatcher(); } @catch (NSException *e) {
            SLLog(@"悬浮球装配失败: %@", e);
        }
    }
}
