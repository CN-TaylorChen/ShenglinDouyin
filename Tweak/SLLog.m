#import "SLLog.h"

#define SL_LOG_MAX_BYTES  (1024 * 1024)
#define SL_LOG_KEEP_BYTES (512 * 1024)

// 真的往这个路径写一次，然后把字节数读回来核对。
// 为什么不能只信 isWritableFileAtPath / createFileAtPath：
// 插件跑在抖音自己的沙盒进程里，/var/mobile/Documents 这类"越狱可见"的路径
// 建文件可能返回成功，随后 writeData 全丢（或干脆抛异常被吞）。日志页于是永远空白，
// 而代码看上是"写成功"的 —— 用户说的「日志功能好像没用」就是这一条。
static BOOL SLLogProbe(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:path]) {
        if (![fm createFileAtPath:path contents:nil attributes:nil]) return NO;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return NO;

    BOOL ok = NO;
    @try {
        unsigned long long before = [fh seekToEndOfFile];
        NSData *probe = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
        [fh writeData:probe];
        [fh synchronizeFile];
        [fh closeFile];
        unsigned long long after =
            [[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue];
        ok = (after >= before + probe.length);
    } @catch (NSException *e) {
        ok = NO;
    }
    return ok;
}

static NSString *SLLogPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只放两个候选：根目录 /var/mobile（有越狱权限时，Filza 直接能看）、
        // rootless 的 /var/jb。App 自己的沙盒永远可写，作为最后一档兜底。
        NSArray<NSString *> *cands = @[
            @"/var/mobile/Documents/ShenglinDouyin/slmomo.log",
            @"/var/jb/var/mobile/Documents/ShenglinDouyin/slmomo.log"
        ];
        for (NSString *c in cands) {
            if (SLLogProbe(c)) { p = c; break; }
        }
        if (!p) {
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *dir = [doc stringByAppendingPathComponent:@"ShenglinDouyin"];
            NSString *fallback = [dir stringByAppendingPathComponent:@"slmomo.log"];
            if (SLLogProbe(fallback)) p = fallback;
        }
        if (!p) {
            // 三个都写不进去：日志页会显示「(不可写)」，至少不是静默失败
            p = @"";
        }
    });
    return p;
}

static NSString *SLTimestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

void SLLogWrite(NSString *line) {
    if (!line.length) return;
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.shenglin.momo.log", DISPATCH_QUEUE_SERIAL); });

    NSString *full = [NSString stringWithFormat:@"%@ %@\n", SLTimestamp(), line];
    dispatch_async(q, ^{
        NSString *path = SLLogPath();
        if (!path.length) return;
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
                unsigned long long end = [fh offsetInFile];
                // 不再每条 fsync：一条一次同步会持续抢磁盘 IO，跳页面和滑动都能感觉到。
                // writeData 已经进了内核缓冲，进程被系统杀掉也不会丢，每 8 条落一次盘足够。
                static NSUInteger sPendingSync = 0;
                if (++sPendingSync >= 8) { sPendingSync = 0; [fh synchronizeFile]; }
                [fh closeFile];
                if (end > SL_LOG_MAX_BYTES) {
                    NSData *d = [NSData dataWithContentsOfFile:path];
                    if (d.length > SL_LOG_MAX_BYTES) {
                        NSData *tail = [d subdataWithRange:NSMakeRange(d.length - SL_LOG_KEEP_BYTES, SL_LOG_KEEP_BYTES)];
                        // 关键：不能从中间切。切在半个中文字上，整份文件就不是合法 UTF-8，
                        // 日志页 decode 会失败 → 返回空串 → 用户看到的是「日志是空的」。
                        // 从第一个换行之后开始留。
                        const uint8_t *b = (const uint8_t *)tail.bytes;
                        NSUInteger start = 0;
                        for (NSUInteger i = 0; i < tail.length && i < 8192; i++) {
                            if (b[i] == '\n') { start = i + 1; break; }
                        }
                        if (start < tail.length) {
                            NSData *clean = [tail subdataWithRange:NSMakeRange(start, tail.length - start)];
                            [clean writeToFile:path atomically:YES];
                        }
                    }
                }
            } else {
                NSData *d = [NSData dataWithContentsOfFile:path];
                NSMutableData *md = d ? [d mutableCopy] : [NSMutableData data];
                [md appendData:[full dataUsingEncoding:NSUTF8StringEncoding]];
                [md writeToFile:path atomically:YES];
            }
        } @catch (NSException *e) { }
    });
}

@implementation SLLog

+ (NSString *)filePath {
    return SLLogPath();
}

+ (NSString *)tailLines:(NSInteger)lines {
    NSData *d = [NSData dataWithContentsOfFile:SLLogPath()];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) {
        // 老版本截断时切在了半个中文字上，整份文件已经不是合法 UTF-8，
        // 一次 decode 失败就是整页空白（以前看到的就是「日志是空的」）。
        // 这里从第一个换行之后重新解 —— 丢掉半行，救回后面全部。
        const uint8_t *b = (const uint8_t *)d.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < d.length && i < 16384; i++) {
            if (b[i] == '\n') { start = i + 1; break; }
        }
        NSData *rest = (start > 0 && start < d.length)
            ? [d subdataWithRange:NSMakeRange(start, d.length - start)] : [NSData data];
        s = [[NSString alloc] initWithData:rest encoding:NSUTF8StringEncoding] ?: @"";
    }
    NSArray<NSString *> *all = [s componentsSeparatedByString:@"\n"];
    NSInteger n = all.count;
    NSInteger start = n > lines ? n - lines : 0;
    NSArray<NSString *> *part = [all subarrayWithRange:NSMakeRange(start, n - start)];
    return [part componentsJoinedByString:@"\n"];
}

/// 文件是不是根本读不出来（用来区分「真没日志」和「解码坏了」）
+ (BOOL)fileReadable {
    NSData *d = [NSData dataWithContentsOfFile:SLLogPath()];
    if (!d.length) return YES;                 // 空文件：正常
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] != nil;
}

+ (void)clear {
    [@"" writeToFile:SLLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end
