// v0.5.7：闪图字段勘察（只读探测，不改任何发送行为）
#import <Foundation/Foundation.h>

/// 启动后淡入跑一次：只盯 IM 图片消息模型，装 content 时把整对象（含父类）的 ivar dump 一遍，
/// 用来对比「普通图」与「闪图（AWEIMWatchOnceImageMessage）」的消息类与字段差异。
/// 全部输出以 "PROBE4|" 开头；内部按批落盘（一次 fsync 写一批），不在热路径碰磁盘。
void SLFlashProbeStart(void);
