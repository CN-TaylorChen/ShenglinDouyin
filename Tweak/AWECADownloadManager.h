// 语音下载
// CN-TaylorChen | github.com/CN-TaylorChen

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AWECAHeaders.h"

@interface AWECADownloadManager : NSObject

+ (instancetype)shared;

- (void)cacheURL:(NSString *)url forVID:(NSString *)vID;
- (NSString *)cachedURLForVID:(NSString *)vID;

- (void)parseAndCacheVideoModelJSON:(NSString *)jsonStr;

- (void)showSaveDialogAndDownload:(AWECommentModel *)comment;

- (NSArray<NSString *> *)downloadedAudioFiles;
- (NSArray<NSString *> *)downloadedAudioDisplayNames;

@end
