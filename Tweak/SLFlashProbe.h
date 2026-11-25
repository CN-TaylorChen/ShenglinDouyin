// v0.5.6：闪图字段勘察（只读探测，不改任何发送行为）
#import <Foundation/Foundation.h>

/// 启动后淡入跑一次：只盯 IM 消息模型，图片消息时整对象 dump 一次 ivar，
/// 用来对比「普通图」与「闪图」的字段差异。
/// 全部输出以 "PROBE3|" 开头；内部按批落盘（一次 fsync 写一批），不在热路径碰磁盘。
void SLFlashProbeStart(void);
