#import <UIKit/UIKit.h>

// 插件内日志查看页（读 /var/mobile/Documents/ShenglinDouyin/slmomo.log 尾部）
@interface SLLogViewController : UIViewController
@end

// 由 Tweak.x 提供：钩子安装情况摘要
NSString *SLHookStatusSummary(void);
// 由 Tweak.x 提供：当前运行态（增强开关 / 槽位内容 / 装填来源 / 文件大小）
NSString *SLRuntimeStateSummary(void);
