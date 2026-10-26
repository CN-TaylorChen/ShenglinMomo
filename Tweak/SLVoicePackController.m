// 语音包列表：按文件夹分组、行内试听、点行选中、左滑裁剪/重命名/删除

#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "SLTrimController.h"
#import "AWECAUtils.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef UIDocumentPickerViewController * _Nullable (^SLPickerMaker)(void);

// 分组标题跟白色卡片左边缘对齐：取第一个可见 cell 的 x，取不到用 insetGrouped 的 20pt
static CGFloat SLCardLeading(UITableView *tv) {
    UITableViewCell *c = tv.visibleCells.firstObject;
    if (c) return CGRectGetMinX(c.frame);
    for (NSInteger s = 0; s < tv.numberOfSections; s++) {
        if ([tv numberOfRowsInSection:s] <= 0) continue;
        UITableViewCell *first = [tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:s]];
        if (first) return CGRectGetMinX(first.frame);
        break;
    }
    return 20;
}

static UIView *SLPackHeader(NSString *text, CGFloat x, CGFloat width) {
    if (!text.length) return nil;
    CGFloat w = width > 0 ? width : [UIScreen mainScreen].bounds.size.width;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 22)];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(x, 3, w - x - 16, 17)];
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = text;
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:lab];
    return box;
}

@interface SLVoicePackController () <UIDocumentPickerDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) NSArray<NSString *> *folders;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *grouped;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy) NSString *playingRel;
@end

@implementation SLVoicePackController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"语音包";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(sl_addTapped)];
    [self sl_reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self sl_reload];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sl_stopPreview];
}

- (void)sl_reload {
    [SLVoicePack syncFromDisk];            // 手工放进目录的音频也能自动出现
    self.folders = [SLVoicePack folders];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *f in self.folders) {
        map[f] = [SLVoicePack packsInFolder:f];
    }
    self.grouped = map;
    [self.tableView reloadData];
}

#pragma mark - 导入

- (void)sl_addTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"新建文件夹" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self sl_newFolder]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入文件夹" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self sl_pickFolder]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入音频文件" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self sl_pickFiles]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

// 菜单收起过程中直接 present 会被 UIKit 丢弃（这就是"点了没反应"），统一延后到消失之后
- (void)sl_presentPicker:(SLPickerMaker)make {
    [self sl_presentPicker:make retry:3];
}

- (void)sl_presentPicker:(SLPickerMaker)make retry:(NSInteger)retry {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.view.window) return;                       // 页面已经不在前台
        if (self.presentedViewController) {                  // 上一个弹窗还没走完，再等一轮
            if (retry > 0) [self sl_presentPicker:make retry:retry - 1];
            else [AWECAUtils showToast:@"打不开文件选择器，稍后重试" duration:2.2];
            return;
        }
        UIDocumentPickerViewController *p = make();
        if (!p) return;
        p.delegate = self;
        SLLog(@"PACK-IMPORT present picker");
        [self presentViewController:p animated:YES completion:nil];
    });
}

- (void)sl_pickFolder {
    [AWECAUtils showToast:@"正在打开文件…" duration:1.2];
    [self sl_presentPicker:^UIDocumentPickerViewController * _Nullable {
        if (@available(iOS 14.0, *)) {
            // 文件夹用「引用原文件」：复制整个目录太慢，靠 security scope 读
            UIDocumentPickerViewController *p =
                [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
            p.allowsMultipleSelection = YES;
            return p;
        }
        return nil;
    }];
}

- (void)sl_pickFiles {
    [AWECAUtils showToast:@"正在打开文件…" duration:1.2];
    [self sl_presentPicker:^UIDocumentPickerViewController * _Nullable {
        if (@available(iOS 14.0, *)) {
            // 音频文件用「复制副本」：系统直接给临时文件，不依赖外部读权限
            UIDocumentPickerViewController *p =
                [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
            p.allowsMultipleSelection = YES;
            return p;
        }
        return nil;
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    SLLog(@"PACK-IMPORT picked %lu url(s)", (unsigned long)urls.count);
    if (!urls.count) return;
    NSInteger added = 0;
    NSString *lastErr = nil;
    for (NSURL *url in urls) {
        BOOL isDir = url.hasDirectoryPath;
        if (!isDir) {
            NSNumber *dirFlag = nil;
            [url getResourceValue:&dirFlag forKey:NSURLIsDirectoryKey error:nil];
            isDir = dirFlag.boolValue;
        }
        if (isDir) {
            NSString *err = nil;
            NSInteger n = [SLVoicePack importFolderAtURL:url error:&err];
            SLLog(@"PACK-IMPORT folder %@ -> %ld %@", url.lastPathComponent, (long)n, err ?: @"");
            added += n;
            if (err.length && !n) lastErr = err;
        } else {
            NSString *err = nil;
            if ([SLVoicePack importFileAtURL:url folder:nil error:&err]) {
                added++;
            } else {
                SLLog(@"PACK-IMPORT file fail %@ / %@", url.lastPathComponent, err ?: @"");
                if (err.length) lastErr = err;
            }
        }
    }
    [self sl_reload];
    if (added > 0) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"已导入 %ld 个", (long)added] duration:1.6];
    } else {
        [AWECAUtils showToast:lastErr.length ? lastErr : @"没有可导入的音频" duration:2.2];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    SLLog(@"PACK-IMPORT cancelled");
}

#pragma mark - 文件夹

- (void)sl_newFolder {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹"
                                                                   message:@"建好后可在音频上左滑「移动」放进去"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"文件夹名，如 搞怪、方言";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        if ([SLVoicePack createFolder:name]) {
            [self sl_reload];
            [AWECAUtils showToast:[NSString stringWithFormat:@"已新建「%@」", name] duration:1.6];
        } else {
            [AWECAUtils showToast:@"建不了：名字重复或为空" duration:2.0];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sl_movePack:(NSDictionary *)pack {
    NSString *cur = pack[@"folder"] ?: @"未分组";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"移动到"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *f in self.folders) {
        if ([f isEqualToString:cur]) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:f style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *err = nil;
            if ([SLVoicePack movePack:pack toFolder:f error:&err]) {
                [self sl_reload];
                [AWECAUtils showToast:[NSString stringWithFormat:@"已移到「%@」", f] duration:1.6];
            } else {
                [AWECAUtils showToast:err.length ? err : @"移动失败" duration:2.0];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"新建文件夹并移过去" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self sl_newFolderThenMove:pack]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)sl_newFolderThenMove:(NSDictionary *)pack {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹"
                                                                   message:@"建好后立刻把这条音频移进去"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"文件夹名";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        if (![SLVoicePack createFolder:name]) {
            [AWECAUtils showToast:@"建不了：名字重复或为空" duration:2.0];
            return;
        }
        NSString *err = nil;
        if ([SLVoicePack movePack:pack toFolder:name error:&err]) {
            [self sl_reload];
            [AWECAUtils showToast:[NSString stringWithFormat:@"已移到「%@」", name] duration:1.6];
        } else {
            [AWECAUtils showToast:err.length ? err : @"移动失败" duration:2.0];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sl_deleteFolder:(NSString *)folder {
    if ([folder isEqualToString:@"未分组"]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
                                    [NSString stringWithFormat:@"删除文件夹「%@」？", folder]
                                                                   message:@"只能删空文件夹，里面的音频先移走"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        if ([SLVoicePack removeFolder:folder]) {
            [self sl_reload];
        } else {
            [AWECAUtils showToast:@"文件夹里还有音频，先移走" duration:2.2];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 1 + self.folders.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 1;   // 启用开关
    NSString *f = self.folders[section - 1];
    return self.grouped[f].count;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv;
    return section == 0 ? 26 : 22;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    NSString *text = section == 0 ? @"语音包" : self.folders[section - 1];
    UIView *v = SLPackHeader(text, SLCardLeading(tv), tv.bounds.size.width);
    if (section > 0 && ![text isEqualToString:@"未分组"]) {
        v.userInteractionEnabled = YES;
        v.tag = section;
        [v addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(sl_folderLongPress:)]];
    }
    return v;
}

- (void)sl_folderLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSInteger section = g.view.tag;
    if (section <= 0 || section > (NSInteger)self.folders.count) return;
    [self sl_deleteFolder:self.folders[section - 1]];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv;
    if (section != 0) return nil;
    return @"开启后发「#tts」直接发出所选语音，不再合成\n点行选中 · 右侧圆钮试听 · 左滑移动/裁剪 · 长按文件夹可删除";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"pack";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = [UIColor labelColor];

    if (ip.section == 0) {
        cell.textLabel.text = @"启用语音包";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.on = [SLVoicePack isEnabled];
        [sw addTarget:self action:@selector(sl_switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    NSDictionary *pack = [self sl_packAt:ip];
    BOOL active = [SLVoicePack isPackActive:pack];
    NSString *name = pack[@"name"] ?: @"未命名";
    cell.textLabel.text = active ? [@"✓ " stringByAppendingString:name] : name;
    cell.detailTextLabel.text = [SLVoicePack displayDuration:pack];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    // 试听按钮
    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.frame = CGRectMake(0, 0, 30, 30);
    play.layer.cornerRadius = 15;
    play.backgroundColor = [UIColor secondarySystemFillColor];
    BOOL playing = self.playingRel.length && [self.playingRel isEqualToString:pack[@"rel"]];
    [play setTitle:(playing ? @"■" : @"▶") forState:UIControlStateNormal];
    play.titleLabel.font = [UIFont systemFontOfSize:12];
    play.tag = ip.section * 10000 + ip.row;
    [play addTarget:self action:@selector(sl_playTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = play;
    return cell;
}

- (NSDictionary *)sl_packAt:(NSIndexPath *)ip {
    if (ip.section == 0) return nil;
    NSString *f = self.folders[ip.section - 1];
    NSArray *list = self.grouped[f];
    return ip.row < list.count ? list[ip.row] : nil;
}

- (void)sl_switchChanged:(UISwitch *)sw {
    [SLVoicePack setEnabled:sw.on];
    if (sw.on && ![SLVoicePack activePack]) {
        [AWECAUtils showToast:@"还没选语音包，先点一条" duration:2.0];
    }
}

#pragma mark - 选择

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) return;
    NSDictionary *pack = [self sl_packAt:ip];
    if (!pack) return;
    [SLVoicePack selectPack:pack];
    [SLVoicePack setEnabled:YES];
    [self.tableView reloadData];
    [AWECAUtils showToast:[NSString stringWithFormat:@"已选中「%@」· 发 #tts 直接发出", pack[@"name"] ?: @""] duration:2.0];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) return nil;
    NSDictionary *pack = [self sl_packAt:ip];
    if (!pack) return nil;

    UIContextualAction *move = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                      title:@"移动"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        done(YES);
        [self sl_movePack:pack];
    }];
    move.backgroundColor = [UIColor systemTealColor];

    UIContextualAction *trim = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                       title:@"裁剪"
                                                                     handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        done(YES);
        [self sl_trimPack:pack];
    }];
    trim.backgroundColor = [UIColor systemOrangeColor];

    UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                         title:@"重命名"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        done(YES);
        [self sl_renamePack:pack];
    }];
    rename.backgroundColor = [UIColor systemBlueColor];

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"删除"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        done(YES);
        if (self.playingRel && [self.playingRel isEqualToString:pack[@"rel"]]) [self sl_stopPreview];
        [SLVoicePack deletePack:pack];
        [self sl_reload];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, move, rename, trim]];
}

- (void)sl_renamePack:(NSDictionary *)pack {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = pack[@"name"];
        tf.placeholder = @"语音包名字";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        [SLVoicePack renamePack:pack toName:name];
        [self sl_reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sl_trimPack:(NSDictionary *)pack {
    NSString *path = [SLVoicePack pathOfPack:pack];
    if (!path.length) return;
    [self sl_stopPreview];
    SLTrimController *vc = [[SLTrimController alloc] initWithPack:pack];
    __weak typeof(self) weakSelf = self;
    vc.onSaved = ^{
        [weakSelf sl_reload];
        [AWECAUtils showToast:@"已保存裁剪结果" duration:1.8];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 试听

- (void)sl_playTapped:(UIButton *)btn {
    NSInteger section = btn.tag / 10000;
    NSInteger row = btn.tag % 10000;
    NSDictionary *pack = [self sl_packAt:[NSIndexPath indexPathForRow:row inSection:section]];
    if (!pack) return;
    NSString *rel = pack[@"rel"];
    if (self.playingRel && [self.playingRel isEqualToString:rel]) {
        [self sl_stopPreview];
        [self.tableView reloadData];
        return;
    }
    [self sl_stopPreview];
    NSString *path = [SLVoicePack pathOfPack:pack];
    NSURL *url = path.length ? [NSURL fileURLWithPath:path] : nil;
    if (!url) return;
    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (err || !self.player) {
        [AWECAUtils showToast:@"这段音频放不了" duration:1.8];
        return;
    }
    self.player.delegate = self;
    self.playingRel = rel;
    [self.player play];
    [self.tableView reloadData];
}

- (void)sl_stopPreview {
    if (self.player) {
        [self.player stop];
        self.player = nil;
    }
    self.playingRel = nil;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player; (void)flag;
    [self sl_stopPreview];
    [self.tableView reloadData];
}

@end
