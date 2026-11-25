// v0.5.8：闪图勘察（无钩子版，纯读）
#import <Foundation/Foundation.h>

/// 启动 6 秒后在后台跑一次，只做两件纯读的事：
///   ① 全库扫选择器名里带 WatchOnce / BurnAfterRead 的方法（限定 AWE / IES / TIM / ACC / BD 命名空间）；
///   ② 打几个关键类的方法名清单（AWEIMWatchOnce* 全家 + 图片消息类）。
/// **不装任何钩子、不改任何实现、不读对象内存**，对发送路径零侵入。
/// 输出以 "PROBE5|" 开头，按批落盘（一次 fsync 写一批），不在热路径碰磁盘。
void SLFlashProbeStart(void);
