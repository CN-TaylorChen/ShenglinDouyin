// 语音包：本地音频导入、按文件夹分组、裁剪
// 数据落在 Documents/ShenglinDouyin/voicepacks，索引存 NSUserDefaults

#import <Foundation/Foundation.h>

@interface SLVoicePack : NSObject

+ (NSString *)rootDir;

/// 全部语音包（按文件夹、文件名排序）
+ (NSArray<NSDictionary *> *)allPacks;
/// 文件夹名（含新建的空文件夹；「未分组」排最后）
+ (NSArray<NSString *> *)folders;
+ (NSArray<NSDictionary *> *)packsInFolder:(NSString *)folder;

/// 扫描目录，把索引里没有的音频补进来（手工放进目录也能看到）
+ (NSInteger)syncFromDisk;

/// 新建文件夹（已存在则返回 NO）
+ (BOOL)createFolder:(NSString *)name;
/// 删除文件夹（仅空文件夹；非空返回 NO）
+ (BOOL)removeFolder:(NSString *)name;
/// 重命名文件夹（索引里的 folder / rel 一起改）
+ (BOOL)renameFolder:(NSString *)oldName to:(NSString *)newName error:(NSString **)err;
/// 把语音包移到另一个文件夹
+ (BOOL)movePack:(NSDictionary *)pack toFolder:(NSString *)folder error:(NSString **)err;

+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)on;
/// v0.4.40：一次性装填。点一条语音包 = 只为「下一条录音」装一发，
/// 发送成功后自动清空、落回原声（原声就是「没装填」的自然状态）。
/// 内存态：重启陌陌即回原声。
+ (BOOL)isOneShotPending;
+ (void)setOneShotPending:(BOOL)on;

/// v0.4.41：当前这一个槽位里装的是谁。语音包和「#tts 即时合成」共用同一个槽位，
/// 后写的覆盖先写的（不再出现「选了包却发出合成音」这种自相矛盾的状态）。
/// 胶囊文字直接读它 —— 装的是语音包显示包名，装的是合成音显示「AI 语音」。
typedef NS_ENUM(NSInteger, SLArmedSource) {
    SLArmedSourceNone = 0,   // 空槽 = 原声
    SLArmedSourcePack = 1,   // 装了某个语音包
    SLArmedSourceAI   = 2,   // 装了 #tts 现场合成的 AI 语音
};
+ (SLArmedSource)armedSource;
+ (void)setArmedSource:(SLArmedSource)src;
+ (NSDictionary *)activePack;
+ (BOOL)isPackActive:(NSDictionary *)pack;
+ (void)selectPack:(NSDictionary *)pack;

/// 抖音版：把这条包装进「下一条录音」的替换槽。
/// 陌陌版是把包解成 PCM 喂进 AudioStreamBus；抖音是录完落盘、直接换文件，
/// 所以这里必须把**路径**交给 AWECAAudioReplacer。
/// 只置 one-shot 标记而不设路径时，录音结束那一刻 hasArmedLocalAudio 判为 NO，
/// 会掉进 ASR+TTS 分支 —— 用户看到的就是「选了包，发出去还是 AI 音色」。
/// 非 m4a（mp3/wav/amr…）先转一份 m4a 缓存再装：抖音录音器产出的就是 m4a，
/// 换成同容器字节流最不容易被它的播放/上传链路判死。
+ (void)armPack:(NSDictionary *)pack completion:(void (^)(BOOL ok))completion;

/// 撤销这一发，回到原声：槽位清空、替换关掉、球落回灰（或绿，看还有没有别的装填）。
+ (void)disarmArmedAudio;

/// 导入整个文件夹（递归），返回新增条数
+ (NSInteger)importFolderAtURL:(NSURL *)url error:(NSString **)err;
/// 导入单个音频文件到指定文件夹（nil = 未分组）
+ (BOOL)importFileAtURL:(NSURL *)url folder:(NSString *)folder error:(NSString **)err;

+ (BOOL)deletePack:(NSDictionary *)pack;
+ (BOOL)renamePack:(NSDictionary *)pack toName:(NSString *)name;
/// 裁剪（秒），返回新条目；原文件保留
+ (NSDictionary *)trimPack:(NSDictionary *)pack from:(double)start to:(double)end error:(NSString **)err;

+ (NSString *)pathOfPack:(NSDictionary *)pack;
+ (NSString *)displayDuration:(NSDictionary *)pack;

@end

/// v0.4.34：后台把当前语音包解码成 PCM 缓存好。
/// 录音开始那一刻要同步拿到 PCM，现解会在录音线程上卡几百毫秒，所以选中时先热一次。
/// 实现放在 Tweak.x（那里才有编码器和全局状态）。
void SLPackPrewarm(void);
