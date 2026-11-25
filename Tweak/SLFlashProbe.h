// v0.5.4：闪图字段勘察（只读探测，不改任何发送行为）
#import <Foundation/Foundation.h>

/// 启动后延迟跑一次：枚举 IM 图片/消息相关类 + 给「ext / flash 类」setter 装记录钩子。
/// 全部输出以 "PROBE|" 开头，方便在日志页筛选。
void SLFlashProbeStart(void);
