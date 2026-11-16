//
//  SLTTSComposeController.h
//  声临 · 抖音版 —— 设置里的「文本转语音」
//
//  输入文字 → 选引擎 / 音色 → 合成 → 写进与 #tts、语音包共用的装填槽位。
//  之后在小宇宙（或私聊）按住录音，PCM 流钩子会自动把录音换成这条 AI 音频。
//

#import <UIKit/UIKit.h>

@interface SLTTSComposeController : UITableViewController
@end
