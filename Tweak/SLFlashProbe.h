// v0.5.5：闪图字段勘察（只读探测，不改任何发送行为）
#import <Foundation/Foundation.h>

/// 启动后淡入跑一次：轻量枚举 IM 消息/图片相关类名 + 给少量 setter 装记录钩子。
/// 全部输出以 "PROBE|" 开头；内部按批落盘（一次 fsync 写一批），不在热路径碰磁盘。
void SLFlashProbeStart(void);
