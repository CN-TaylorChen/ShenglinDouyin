// 语音替换
// CN-TaylorChen | github.com/CN-TaylorChen

#import <Foundation/Foundation.h>

@interface AWECAAudioReplacer : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *replacementAudioPath;
@property (nonatomic, copy) NSString *ttsAudioPath;
@property (nonatomic, readonly) BOOL isUsingTTS;

- (void)setReplacementFromPath:(NSString *)path completion:(void(^)(BOOL success))completion;

- (void)setReplacementFromTTSPath:(NSString *)path
                             text:(NSString *)text
                        voiceName:(NSString *)voiceName
                       completion:(void(^)(BOOL success))completion;

- (void)clearReplacement;

// 用掉这一发：清空槽位但**不弹提示**、不打扰用户。
// clearReplacement 会 toast「已关闭语音替换」，那是给用户手动关开关用的，
// 装填后成功替换完再弹这句等于每发都报一次错。
- (void)consumeReplacement;
- (BOOL)replaceAudioAtPath:(NSString *)targetPath;
- (void)saveState;
- (void)loadState;

@end
