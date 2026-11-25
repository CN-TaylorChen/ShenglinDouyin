// v0.6.0：相册发闪图
// 结论来自 v0.5.8 勘察：抖音本身就有一条「相册 → 闪图」的原生发送链，
// 只是被几个能力开关挡住。这里只把开关放开，让原生按钮出现，**不伪造任何消息**。
#import <Foundation/Foundation.h>

/// 装配闪图钩子（幂等，重复调用无副作用）。
/// 全部是 getter 层：只改返回值，不调 setter、不按偏移读 ivar、不碰图片消息类。
void SLWatchOnceStart(void);

/// 相册闪图入口（默认开）：放开 disableSendWatchOnce / needSupportWatchOnce 等限制
BOOL SLWatchOnceEntryOn(void);
void SLWatchOnceSetEntry(BOOL on);

/// 相册发图默认闪图（默认关）：从相册选图后直接按闪图发送，不给选择
BOOL SLWatchOnceForceOn(void);
void SLWatchOnceSetForce(BOOL on);
