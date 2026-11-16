// 合成与本地面板
// CN-TaylorChen | github.com/CN-TaylorChen

#import <UIKit/UIKit.h>

@interface AWECAAudioPickerController : UIViewController <UIDocumentPickerDelegate>

+ (instancetype)shared;

@property (nonatomic, assign) BOOL embeddedInCommentTab;

- (void)showPickerFromViewController:(UIViewController *)vc;

@end
