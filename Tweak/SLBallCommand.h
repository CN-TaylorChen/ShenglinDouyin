// v0.5.7：#ball 口令（输入框里打 #ball 收 / 放悬浮球）
#import <Foundation/Foundation.h>

/// 装一次就够：监听全 App 的 UITextField / UITextView 文本变化，
/// 命中 "#ball" 时清空输入框并切换悬浮球显隐。
void SLBallCommandStart(void);
