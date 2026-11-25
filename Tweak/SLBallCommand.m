// v0.5.7：#ball 口令 —— 在任意输入框里打 #ball，立刻把悬浮球收起来 / 叫出来。
//
// 为什么用「输入框监听」而不是钩某个发送按钮：
//   抖音的输入框有聊天、评论、搜索、资料好几套，各自不同的类，钩发送键要一个个找；
//   而「文本变化」这件事全 App 只有一个来源 —— UITextField / UITextView 的两条通知。
//   监听它，等于一次覆盖所有输入框，也不用碰任何发送逻辑（永不误发消息）。
//
// 命中之后不是直接 setText:，而是逐字 deleteBackward：
//   走的是正常输入通道，抖音自己的草稿、发送键可用状态、@ 高亮都会跟着更新；
//   直接赋空串会让它内部的 attributedText / draft 状态和外层显示不一致。
#import "SLBallCommand.h"
#import "SLEntry.h"
#import "SLLog.h"
#import <UIKit/UIKit.h>

#define kSLBallToken @"#ball"

static BOOL sSLBallBusy = NO;

// 输入框里的原文（UITextField / UITextView 都走 text；自绘输入框退回 KVC 兜底）
static NSString *SLBallRawText(id obj) {
    if ([obj isKindOfClass:[UITextField class]]) return [(UITextField *)obj text];
    if ([obj isKindOfClass:[UITextView class]]) return [(UITextView *)obj text];
    @try {
        id v = [obj valueForKey:@"text"];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

// 逐字回删，走正常输入通道
static BOOL SLBallErase(id obj, NSUInteger count) {
    if (!count || count > 64) return NO;
    if (![obj conformsToProtocol:@protocol(UIKeyInput)]) return NO;
    id<UIKeyInput> ki = (id<UIKeyInput>)obj;
    for (NSUInteger i = 0; i < count; i++) [ki deleteBackward];
    return YES;
}

static void SLBallHandleChange(NSNotification *note) {
    if (sSLBallBusy) return;   // 回删本身会再触发通知，别递归
    id obj = note.object;
    if (!obj) return;

    NSString *raw = SLBallRawText(obj);
    if (!raw.length) return;

    // 只认「#ball 出现在末尾」：#ball 后面必须干净（允许空格）。
    // 这样 "#balloon" 不会误触发，输入框里已有草稿时也能用。
    NSString *scan = [raw stringByReplacingOccurrencesOfString:@"＃" withString:@"#"];
    NSRange r = [scan rangeOfString:kSLBallToken
                            options:(NSBackwardsSearch | NSCaseInsensitiveSearch)];
    if (r.location == NSNotFound) return;
    NSString *tail = [scan substringFromIndex:NSMaxRange(r)];
    if ([tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) return;

    // 从 token 起到末尾一起删掉：连同后面可能多打的空格
    NSUInteger n = raw.length - r.location;

    sSLBallBusy = YES;
    @try {
        if (!SLBallErase(obj, n)) {
            // 实在删不动就退回直接清空，至少别让 "#ball" 留在框里被发出去
            if ([obj isKindOfClass:[UITextField class]]) ((UITextField *)obj).text = @"";
            else if ([obj isKindOfClass:[UITextView class]]) ((UITextView *)obj).text = @"";
        }
        BOOL hidden = !SLFloatIsHidden();
        SLSetFloatHidden(hidden);
        SLLog(@"SL-MOMO: #ball command -> %@", hidden ? @"hidden" : @"shown");
    } @finally {
        sSLBallBusy = NO;
    }
}

void SLBallCommandStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (NSString *name in @[UITextFieldTextDidChangeNotification,
                                 UITextViewTextDidChangeNotification]) {
            [nc addObserverForName:name
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                            @try { SLBallHandleChange(n); } @catch (NSException *e) {
                                SLLog(@"#ball 处理异常: %@", e.reason);
                            }
                        }];
        }
        SLLog(@"SL-MOMO: #ball command ready");
    });
}
