// SLPCMTool —— PCM 采样率/声道转换
//
// v0.4.2 起不再自己造 Opus 文件：直接把 AI 语音的 PCM 喂进陌陌自己的
// MDAudioStreamBus（→ MDOpusEncoder），容器/编码参数完全由陌陌决定。
// 但陌陌 bus 的 ASBD 可能是 16k/8k、单/双声道，喂之前要对齐。

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface SLPCMTool : NSObject

/// 把 16kHz / mono / s16le 的 PCM 转成 targetRate + targetChannels（16bit）。
/// 相同时直接返回原数据（不拷贝）。
+ (NSData *)convertPCM16kMono:(NSData *)pcm
                       toRate:(double)targetRate
                     channels:(UInt32)targetChannels;

/// 首尾各 frames 帧线性淡入淡出（每声道独立），消除 PCM 接上/截断时的硬切。
/// 返回副本，不修改入参；frames=0 或数据过短时原样返回。
+ (NSData *)fadeEdges:(NSData *)pcm
              frames:(NSUInteger)frames
            channels:(UInt32)channels;

@end
