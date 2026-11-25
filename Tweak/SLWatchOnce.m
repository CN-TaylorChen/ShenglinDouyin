// v0.6.0：相册发闪图
//
// 关键点（详见 SLWatchOnce.h）：
//   · 抖音原生已有「相册选图 → 闪图」管线，最终决策点是
//     AWEIMMessageListGalleryEntryComponent -sendAssets:isSendWatchOnce:
//   · 挡住入口的是一串"能力/策略"开关，语义都是「允许不允许」，不是「当前状态」，
//     因此可以安全地在 getter 上把答案改成允许。
//   · 明确**不碰**的东西：AWEIMPhotoPickerModel/AWEIMLocalAsset 的 watchOnce（每张图的状态）、
//     AWEIMSendMessageContext.isClickWatchOnce（点击状态）、任何 setter、任何 ivar 偏移读取。
//     v0.5.7 就是在图片消息 setter 上挂钩子＋裸读 ivar 导致相册选图闪退。
//
// 安全措施：挂之前先用 method_copyReturnType 校验签名 —— 返回类型不是 BOOL / void 的
// 一律跳过并记日志。宁可某个门没挂上，也不让一个签名猜错的钩子把正常发图搞坏。

#import "SLWatchOnce.h"
#import "SLLog.h"
#import <objc/runtime.h>

#define kSLOnceEntry @"SLWatchOnceEntry"
#define kSLOnceForce @"SLWatchOnceForce"

#pragma mark - 开关

BOOL SLWatchOnceEntryOn(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLOnceEntry]) return YES;      // 默认放开
    return [d boolForKey:kSLOnceEntry];
}

BOOL SLWatchOnceForceOn(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLOnceForce]) return NO;       // 默认不强制
    return [d boolForKey:kSLOnceForce];
}

void SLWatchOnceSetEntry(BOOL on) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:kSLOnceEntry];
    [d synchronize];
    SLLog(@"ONCE| 开关 相册闪图入口 = %d", on);
}

void SLWatchOnceSetForce(BOOL on) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:kSLOnceForce];
    [d synchronize];
    SLLog(@"ONCE| 开关 相册默认闪图 = %d", on);
}

#pragma mark - 只在"类自己身上"找方法 + 校验返回类型

// class_getInstanceMethod 会顺着父类找到方法，method_setImplementation 改的是父类那份实现，
// 影响面会扩散到一堆子类。这里只取本类 method list，确保钩子只落在目标类上。
static Method SLExactMethod(Class cls, SEL sel) {
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

// want: 'B' = BOOL / 'c' = char 当 BOOL 用 / 'v' = void
static BOOL SLReturnTypeIs(Method m, char want) {
    char *ret = method_copyReturnType(m);
    BOOL ok = (ret && ret[0] == want);
    if (ret) free(ret);
    return ok;
}

static BOOL SLReturnTypeIsBool(Method m) {
    return SLReturnTypeIs(m, 'B') || SLReturnTypeIs(m, 'c');
}

static void SLInstall(Class cls, SEL sel, IMP imp, IMP *origSlot, NSString *tag) {
    if (!cls) { SLLog(@"ONCE| 跳过 %@：类不存在", tag); return; }
    Method m = SLExactMethod(cls, sel);
    if (!m) { SLLog(@"ONCE| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    IMP old = method_getImplementation(m);
    if (old == imp) return;
    if (origSlot) *origSlot = old;
    method_setImplementation(m, imp);
    SLLog(@"ONCE| 已挂 %@ @ %@", tag, NSStringFromClass(cls));
}

static void SLInstallBool(Class cls, SEL sel, IMP imp, IMP *origSlot, NSString *tag) {
    if (!cls) { SLLog(@"ONCE| 跳过 %@：类不存在", tag); return; }
    Method m = SLExactMethod(cls, sel);
    if (!m) { SLLog(@"ONCE| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    if (!SLReturnTypeIsBool(m)) {
        char *r = method_copyReturnType(m);
        SLLog(@"ONCE| 跳过 %@：返回类型是 %s，不是 BOOL", tag, r ?: "?");
        if (r) free(r);
        return;
    }
    SLInstall(cls, sel, imp, origSlot, tag);
}

static void SLInstallVoid(Class cls, SEL sel, IMP imp, IMP *origSlot, NSString *tag) {
    if (!cls) { SLLog(@"ONCE| 跳过 %@：类不存在", tag); return; }
    Method m = SLExactMethod(cls, sel);
    if (!m) { SLLog(@"ONCE| 跳过 %@：%@ 未实现该 selector", tag, NSStringFromClass(cls)); return; }
    if (!SLReturnTypeIs(m, 'v')) {
        char *r = method_copyReturnType(m);
        SLLog(@"ONCE| 跳过 %@：返回类型是 %s，不是 void", tag, r ?: "?");
        if (r) free(r);
        return;
    }
    SLInstall(cls, sel, imp, origSlot, tag);
}

#pragma mark - 门 1：disableSendWatchOnce → 一律 NO

#define SL_ONCE_ALLOW_HOOK(NAME, TAG)                       \
    static BOOL (*o_##NAME)(id, SEL);                        \
    static BOOL h_##NAME(id self, SEL _cmd) {                \
        BOOL orig = o_##NAME ? o_##NAME(self, _cmd) : NO;    \
        if (!SLWatchOnceEntryOn()) return orig;              \
        static BOOL once = NO;                               \
        if (!once) { once = YES;                             \
            SLLog(@"ONCE| %@ 原生=%d → 0", TAG, orig); }      \
        return NO;                                           \
    }

SL_ONCE_ALLOW_HOOK(galleryDisable,  @"gallery.disableSendWatchOnce")     // AWEIMMessageListGalleryEntryComponent
SL_ONCE_ALLOW_HOOK(quickDisable,    @"quick.disableSendWatchOnce")       // AWEIMQuickSelectPhotoInteractor
SL_ONCE_ALLOW_HOOK(previewDisable,  @"preview.disableSendWatchOnce")     // AWEIMPhotoPreviewEditorCollectionView

#pragma mark - 门 2：能力/策略判定 → 一律 YES

#define SL_ONCE_SUPPORT_HOOK(NAME, TAG)                     \
    static BOOL (*o_##NAME)(id, SEL);                        \
    static BOOL h_##NAME(id self, SEL _cmd) {                \
        BOOL orig = o_##NAME ? o_##NAME(self, _cmd) : NO;    \
        if (!SLWatchOnceEntryOn()) return orig;              \
        static BOOL once = NO;                               \
        if (!once) { once = YES;                             \
            SLLog(@"ONCE| %@ 原生=%d → 1", TAG, orig); }      \
        return YES;                                          \
    }

SL_ONCE_SUPPORT_HOOK(feedAdapter,     @"feedAdapter.needSupportWatchOnce")   // IESIMInputVCFeedDetailAdapter
SL_ONCE_SUPPORT_HOOK(defaultAdapter,  @"defaultAdapter.needSupportWatchOnce") // IESIMInputVCDefaultAdapter
SL_ONCE_SUPPORT_HOOK(optStrategy,     @"contextRecommend.enableOptWatchOnceStrategy")

// 相册选择器的自定义配置：CustomConfig 上的 watchOnce 是"这个选择器支不支持闪图"（配置），
// 不是"这张图发不发闪图"（那是 PhotoPickerModel / LocalAsset 上的同名属性，一处都没碰）。
static BOOL (*o_pickerConfig)(id, SEL);
static BOOL h_pickerConfig(id self, SEL _cmd) {
    BOOL orig = o_pickerConfig ? o_pickerConfig(self, _cmd) : NO;
    if (!SLWatchOnceEntryOn()) return orig;
    static BOOL once = NO;
    if (!once) { once = YES; SLLog(@"ONCE| pickerConfig.watchOnce 原生=%d → 1", orig); }
    return YES;
}

// 带参数的：-supportWatchOnce:（入参是会话/uid，只判断支不支持）
static BOOL (*o_supportSvc)(id, SEL, id);
static BOOL h_supportSvc(id self, SEL _cmd, id arg) {
    BOOL orig = o_supportSvc ? o_supportSvc(self, _cmd, arg) : NO;
    if (!SLWatchOnceEntryOn()) return orig;
    static BOOL once = NO;
    if (!once) { once = YES; SLLog(@"ONCE| studio.supportWatchOnce: 原生=%d → 1", orig); }
    return YES;
}

#pragma mark - 保底那条：直接改写发送决策

// 原生按钮万一没出现，打开「相册默认闪图」后这里保证能发出去。
// 只在真要改写时打日志，平时静默。
static void (*o_sendAssets)(id, SEL, id, BOOL);
static void h_sendAssets(id self, SEL _cmd, id assets, BOOL once) {
    if (SLWatchOnceEntryOn() && SLWatchOnceForceOn() && !once) {
        SLLog(@"ONCE| sendAssets 改写为闪图 class=%@", [assets class]);
        once = YES;
    }
    if (o_sendAssets) o_sendAssets(self, _cmd, assets, once);
}

#pragma mark - 装配

void SLWatchOnceStart(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    SLLog(@"ONCE| ==== 相册闪图 v0.6.0 · 入口=%d · 默认闪图=%d ====",
          SLWatchOnceEntryOn(), SLWatchOnceForceOn());

    Class c = Nil;

    // 相册选择器配置
    c = objc_getClass("AWEIMAssetGalleryPickerCustomConfig");
    SLInstallBool(c, @selector(watchOnce), (IMP)h_pickerConfig, (IMP *)&o_pickerConfig,
                  @"pickerConfig.watchOnce");

    // 从相册选图 → 发送 的主入口
    c = objc_getClass("AWEIMMessageListGalleryEntryComponent");
    SLInstallBool(c, @selector(disableSendWatchOnce), (IMP)h_galleryDisable, (IMP *)&o_galleryDisable,
                  @"gallery.disableSendWatchOnce");
    SLInstallVoid(c, @selector(sendAssets:isSendWatchOnce:), (IMP)h_sendAssets, (IMP *)&o_sendAssets,
                  @"gallery.sendAssets:isSendWatchOnce:");

    // 快捷选图（输入框旁边的相册小入口）
    c = objc_getClass("AWEIMQuickSelectPhotoInteractor");
    SLInstallBool(c, @selector(disableSendWatchOnce), (IMP)h_quickDisable, (IMP *)&o_quickDisable,
                  @"quick.disableSendWatchOnce");

    // 预览页的发送按钮
    c = objc_getClass("AWEIMPhotoPreviewEditorCollectionView");
    SLInstallBool(c, @selector(disableSendWatchOnce), (IMP)h_previewDisable, (IMP *)&o_previewDisable,
                  @"preview.disableSendWatchOnce");

    // 会话能力判定：判成不支持就不给入口
    c = objc_getClass("IESIMInputVCFeedDetailAdapter");
    SLInstallBool(c, @selector(needSupportWatchOnce), (IMP)h_feedAdapter, (IMP *)&o_feedAdapter,
                  @"feedAdapter.needSupportWatchOnce");

    c = objc_getClass("IESIMInputVCDefaultAdapter");
    SLInstallBool(c, @selector(needSupportWatchOnce), (IMP)h_defaultAdapter, (IMP *)&o_defaultAdapter,
                  @"defaultAdapter.needSupportWatchOnce");

    c = objc_getClass("AWEStudioIMModuleServiceImpl");
    SLInstallBool(c, @selector(supportWatchOnce:), (IMP)h_supportSvc, (IMP *)&o_supportSvc,
                  @"studio.supportWatchOnce:");

    // 灰度策略：不开就等于没这个功能
    c = objc_getClass("AWEIMContextRecommendUtil");
    SLInstallBool(c, @selector(enableOptWatchOnceStrategy), (IMP)h_optStrategy, (IMP *)&o_optStrategy,
                  @"contextRecommend.enableOptWatchOnceStrategy");

    SLLog(@"ONCE| 装配完成");
}
