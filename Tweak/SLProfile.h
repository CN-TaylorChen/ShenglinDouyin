//
//  SLProfile.h
//  声临 · 抖音版 —— 本机主页伪装
//
//  只改本机渲染：hook AWEUserModel 的展示字段，在「我」页可见期间返回预设值。
//  不碰登录态、不碰接口、不碰数据库，退出页面立刻恢复。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 装配钩子。在 %ctor 里调一次即可，重复调用无害。
void SLProfileStart(void);

/// 伪装总开关状态。
BOOL SLProfileEnabled(void);

/// 已填内容条目数（给设置页右侧显示 "已填 3 项" 用）。
NSInteger SLProfileFilledCount(void);

/// 清空全部预设值（不影响开关）。
void SLProfileClearAll(void);

/// 编辑器（昵称 / 抖音号 / 简介 / 三个数字）。
@interface SLProfileEditorController : UITableViewController
@end

NS_ASSUME_NONNULL_END
