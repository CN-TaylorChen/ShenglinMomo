// 语音包列表：按文件夹分组、行内试听、点行选中、左滑裁剪/重命名/删除

#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "SLTrimController.h"
#import "AWECAUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入文件夹" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self sl_pickFolder]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入音频文件" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [self sl_pickFiles]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)sl_pickFolder {
    if (@available(iOS 14.0, *)) {
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]
                                                                                                       asCopy:NO];
        p.allowsMultipleSelection = YES;
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    }
}

- (void)sl_pickFiles {
    if (@available(iOS 14.0, *)) {
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio]
                                                                                                       asCopy:NO];
        p.allowsMultipleSelection = YES;
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
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
            added += [SLVoicePack importFolderAtURL:url error:&err];
            if (err.length) lastErr = err;
        } else {
            NSString *err = nil;
            if ([SLVoicePack importFileAtURL:url folder:nil error:&err]) added++;
            else if (err.length) lastErr = err;
        }
    }
    [self sl_reload];
    if (added > 0) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"已导入 %ld 个", (long)added] duration:1.6];
    } else {
        [AWECAUtils showToast:lastErr.length ? lastErr : @"没有可导入的音频" duration:2.2];
    }
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

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return @"语音包";
    return self.folders[section - 1];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv;
    if (section != 0) return nil;
    return @"开启后发「#tts」直接发出所选语音，不再合成\n点行选中 · 右侧圆钮试听 · 左滑可裁剪";
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
    return [UISwipeActionsConfiguration configurationWithActions:@[del, rename, trim]];
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
