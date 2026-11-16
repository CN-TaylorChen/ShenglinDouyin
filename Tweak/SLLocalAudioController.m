// 本地音频库
// CN-TaylorChen | github.com/CN-TaylorChen

#import "SLLocalAudioController.h"
#import "AWECAAudioReplacer.h"
#import "AWECAUtils.h"
#import "SLVoicePack.h"
#import "SLEntry.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>

#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

// 与旧拾音面板共用同一份收藏（NSUserDefaults），升级不丢数据
static NSString *const kSLLocalFavoriteKey = @"AWECAFavoriteAudios";

static BOOL SLLocalPathIsAudio(NSString *p) {
    static NSSet *exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"m4a", @"mp3", @"wav", @"aac", @"caf", @"amr", @"opus", @"ogg", @"flac"]];
    });
    return p.length > 0 && [exts containsObject:p.pathExtension.lowercaseString];
}

@interface SLLocalAudioController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *favorites;
@property (nonatomic, strong) NSArray<NSString *> *dirFiles;
@end

@implementation SLLocalAudioController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"本地音频";
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(sl_import)];

    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kSLLocalFavoriteKey];
    self.favorites = saved ? [saved mutableCopy] : [NSMutableArray array];
    [self sl_dropMissingFiles];
    [self sl_scanDir];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self sl_reload];
}

#pragma mark - 数据

- (void)sl_dropMissingFiles {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *bad = [NSMutableArray array];
    for (NSString *p in self.favorites) {
        if (![fm fileExistsAtPath:p]) [bad addObject:p];
    }
    if (bad.count) {
        [self.favorites removeObjectsInArray:bad];
        [self sl_saveFavorites];
    }
}

- (void)sl_scanDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *feeds = [NSMutableArray array];
    // 插件根目录 + 导入目录：前者放合成产物，后者放用户导入的原始文件
    NSArray *dirs = @[[AWECAUtils audioSavePath], [AWECAUtils importPath]];
    for (NSString *dir in dirs) {
        NSArray *list = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in list) {
            if (!SLLocalPathIsAudio(name)) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            if ([self.favorites containsObject:full]) continue;   // 收藏段已经列过，不重复
            [feeds addObject:full];
        }
    }
    [feeds sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDictionary *fa = [fm attributesOfItemAtPath:a error:nil];
        NSDictionary *fb = [fm attributesOfItemAtPath:b error:nil];
        return [(NSDate *)fb[NSFileModificationDate] compare:(NSDate *)fa[NSFileModificationDate]];
    }];
    self.dirFiles = feeds;
}

- (void)sl_reload {
    [self sl_dropMissingFiles];
    [self sl_scanDir];
    [self.tableView reloadData];
}

- (void)sl_saveFavorites {
    [[NSUserDefaults standardUserDefaults] setObject:[self.favorites copy] forKey:kSLLocalFavoriteKey];
}

- (NSString *)sl_pathAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        return (ip.row < (NSInteger)self.favorites.count) ? self.favorites[ip.row] : nil;
    }
    return (ip.row < (NSInteger)self.dirFiles.count) ? self.dirFiles[ip.row] : nil;
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    return section == 0 ? (NSInteger)self.favorites.count : (NSInteger)self.dirFiles.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return self.favorites.count ? @"收藏" : nil;
    return self.dirFiles.count ? @"插件目录" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv;
    if (section != 1) return nil;
    NSString *now = [AWECAAudioReplacer shared].replacementAudioPath;

    NSMutableArray *lines = [NSMutableArray array];
    if (now.length) {
        [lines addObject:[NSString stringWithFormat:@"已装填：%@", now.lastPathComponent]];
    }
    [lines addObject:@"点一条装填，下次录音直接替换成它，不走识别合成。"];
    if (self.favorites.count == 0 && self.dirFiles.count == 0) {
        [lines addObject:@"还没有音频，点右上角导入。"];
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"SLLocalAudioCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    NSString *path = [self sl_pathAtIndexPath:ip];
    cell.textLabel.text = path.lastPathComponent;

    BOOL isCurrent = [path isEqualToString:[AWECAAudioReplacer shared].replacementAudioPath];
    NSTimeInterval dur = [AWECAUtils audioDurationAtPath:path];
    NSString *size = nil;
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr[NSFileSize] unsignedLongLongValue] > 0) {
        double mb = [attr[NSFileSize] doubleValue] / 1048576.0;
        size = mb >= 0.1 ? [NSString stringWithFormat:@"%.1f MB", mb] : nil;
    }
    NSMutableArray *subs = [NSMutableArray array];
    if (dur > 0.05) [subs addObject:[NSString stringWithFormat:@"%.1f 秒", dur]];
    if (size) [subs addObject:size];
    if (isCurrent) [subs addObject:@"当前装填"];
    cell.detailTextLabel.text = [subs componentsJoinedByString:@" · "];
    cell.detailTextLabel.textColor = isCurrent ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.accessoryType = isCurrent ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *path = [self sl_pathAtIndexPath:ip];
    if (!path.length) return;

    __weak typeof(self) weakSelf = self;
    [[AWECAAudioReplacer shared] setReplacementFromPath:path completion:^(BOOL success) {
        if (!success) {
            [AWECAUtils showToast:@"装填失败，文件可能已损坏"];
            return;
        }
        [SLVoicePack setOneShotPending:YES];   // 让设置页那行显示成「已装填」
        [SLVoicePack setArmedSource:SLArmedSourcePack];
        SLRefreshFloatButton();                // 球跟着变绿，否则「装好了球还是灰的」
        SLLog(@"LOCAL armed %@", path.lastPathComponent);
        [weakSelf sl_reload];
        NSTimeInterval dur = [AWECAUtils audioDurationAtPath:path];
        [AWECAUtils showToast:[NSString stringWithFormat:@"已装填 %.1f 秒，下次录音直接换成它", dur]
                     duration:2.2];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0) return nil;   // 目录里的文件不在这里删，避免误删插件产物
    NSString *path = [self sl_pathAtIndexPath:ip];
    if (!path.length) return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"移出收藏"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [weakSelf.favorites removeObject:path];
        [weakSelf sl_saveFavorites];
        [weakSelf sl_reload];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

#pragma mark - 导入

- (void)sl_import {
    // iOS 14 的 initWithDocumentTypes:inMode: 已弃用，项目开 -Werror 会直接炸；
    // 本插件最低 iOS 15，只用新初始化器。
    if (@available(iOS 14.0, *)) {
        NSMutableArray *types = [NSMutableArray array];
        UTType *audio = [UTType typeWithIdentifier:@"public.audio"];
        if (audio) [types addObject:audio];
        UTType *zip = [UTType typeWithIdentifier:@"public.zip-archive"];
        if (zip) [types addObject:zip];
        if (!types.count) { [AWECAUtils showToast:@"系统不支持音频选择"]; return; }
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        p.delegate = self;
        p.allowsMultipleSelection = YES;
        [self presentViewController:p animated:YES completion:nil];
    } else {
        [AWECAUtils showToast:@"系统版本过低，无法导入音频"];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [AWECAUtils ensureDirectoriesExist];
    NSString *dir = [AWECAUtils audioSavePath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger added = 0;

    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *name = url.lastPathComponent;
        NSString *dest = [dir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:dest]) {
            NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
            dest = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@-%@.%@", name.stringByDeletingPathExtension, stamp, name.pathExtension]];
        }
        NSError *err = nil;
        if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&err]) {
            [self.favorites insertObject:dest atIndex:0];
            added++;
        }
        if (scoped) [url stopAccessingSecurityScopedResource];
    }

    if (added) {
        [self sl_saveFavorites];
        [self sl_reload];
        [AWECAUtils showToast:[NSString stringWithFormat:@"已导入 %lu 个音频", (unsigned long)added] duration:1.8];
    } else {
        [AWECAUtils showToast:@"导入失败"];
    }
}

@end
