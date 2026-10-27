// 语音包（v0.4.9.6）：真文件夹两级结构
//   一级页 = 启用开关 + 文件夹列表（带个数、可点进去）+ 未分组音频
//   二级页 = 某个文件夹里的音频，点行选中、行内试听、左滑移动/裁剪/重命名/删除
// 数据仍在 Documents/ShenglinMomo/voicepacks，索引存 NSUserDefaults

#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "SLTrimController.h"
#import "AWECAUtils.h"
#import "SLLog.h"
#import "SLAlignBox.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef UIDocumentPickerViewController * _Nullable (^SLPickerMaker)(void);

// 语音包口令跟着设置走（v0.4.9.9 默认改成 #yyb），文案里不再写死
static NSString *SLPackCmdValue(void) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:@"SLPackCommand"];
    return v.length ? v : @"#yyb";
}

// 标题 / footer / 单元格文字统一左基线（跟设置页同一套算法）
// v0.4.9.7：不再调 rectForRowAtIndexPath —— 它内部要算分区总高，而分区总高又要问
// heightForFooterInSection，那个方法反过来要这个值，形成无限递归（0.4.9.6 语音包页闪退的根因）。
// 只读已经存在的 cell，读不到就用 insetGrouped 的固定值。
static CGFloat SLPackMeasureLeading(UITableView *tv) {
    for (UITableViewCell *c in tv.visibleCells) {
        UILabel *lab = c.textLabel;
        if (!lab || lab.hidden || !lab.text.length) continue;
        if (c.imageView.image) continue;     // 带图标的行文字被推右，不能当基准
        CGFloat x = CGRectGetMinX(c.frame) + CGRectGetMinX(lab.frame);
        if (x > 0) return x;
    }
    return 36;   // 卡片左缘 20 + 内边距 16
}

static UIView *SLPackHeader(NSString *text, CGFloat x, CGFloat width) {
    return SLAlignHeader(text, x, width);
}

static UIView *SLPackFooter(NSString *text, CGFloat x, CGFloat width) {
    return SLAlignFooter(text, x, width);
}

@interface SLVoicePackController () <UIDocumentPickerDelegate, AVAudioPlayerDelegate>
@property (nonatomic, copy) NSString *folder;                      // nil = 一级页
@property (nonatomic, strong) NSArray<NSString *> *folderList;     // 一级页：不含「未分组」
@property (nonatomic, strong) NSArray<NSDictionary *> *ungrouped;  // 一级页：未分组音频
@property (nonatomic, strong) NSArray<NSDictionary *> *items;      // 二级页：本文件夹音频
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy) NSString *playingRel;
@property (nonatomic, assign) CGFloat slLeading;
@end

// ===================== 语音包列表单元格 =====================
// v0.4.33：只显示原文件名，一个字都不改。名字比行宽长时，在行内横向缓慢滚动，
// 放得下就静止。用自定义 cell 而不是 Value1：系统的 textLabel 会溢出到右侧试听按钮上。
@interface SLPackCell : UITableViewCell
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UIView *clip;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *durLabel;
- (void)sl_setName:(NSString *)name active:(BOOL)active;
- (void)sl_refreshMarquee;
@end

@implementation SLPackCell {
    NSString *_marqueeText;
    CGFloat _marqueeClipW;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _badge = [[UIView alloc] initWithFrame:CGRectZero];
        _badge.backgroundColor = [UIColor secondarySystemFillColor];
        _badge.layer.cornerRadius = 6.0;
        [self.contentView addSubview:_badge];

        _clip = [[UIView alloc] initWithFrame:CGRectZero];
        _clip.clipsToBounds = YES;
        [self.contentView addSubview:_clip];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont systemFontOfSize:16];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.lineBreakMode = NSLineBreakByClipping;
        [_clip addSubview:_nameLabel];

        _durLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _durLabel.font = [UIFont systemFontOfSize:13];
        _durLabel.textColor = [UIColor secondaryLabelColor];
        _durLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_durLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_nameLabel.layer removeAllAnimations];
    _nameLabel.layer.transform = CATransform3DIdentity;
    _marqueeText = nil;
    _marqueeClipW = 0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat h = CGRectGetHeight(b);
    CGFloat pad = 16.0, badgeW = 22.0, gap = 9.0, durW = 50.0;
    _badge.frame = CGRectMake(pad, (h - badgeW) / 2.0, badgeW, badgeW);
    _durLabel.frame = CGRectMake(CGRectGetWidth(b) - durW - pad, 0, durW, h);
    CGFloat x = CGRectGetMaxX(_badge.frame) + gap;
    CGFloat w = CGRectGetMinX(_durLabel.frame) - gap - x;
    if (w < 0) w = 0;
    _clip.frame = CGRectMake(x, 0, w, h);
    [self sl_refreshMarquee];
}

- (void)sl_setName:(NSString *)name active:(BOOL)active {
    _nameLabel.text = name ?: @"";
    _nameLabel.textColor = active ? [UIColor systemBlueColor] : [UIColor labelColor];
    _badge.backgroundColor = active ? [UIColor systemBlueColor] : [UIColor secondarySystemFillColor];
    [self setNeedsLayout];
}

- (void)sl_refreshMarquee {
    CGFloat cw = CGRectGetWidth(_clip.bounds);
    CGFloat ch = CGRectGetHeight(_clip.bounds);
    if (cw <= 1.0 || ch <= 1.0) return;
    NSString *t = _nameLabel.text ?: @"";
    if ([_marqueeText isEqualToString:t] && fabs(_marqueeClipW - cw) < 0.5) return;
    _marqueeText = [t copy];
    _marqueeClipW = cw;
    [_nameLabel.layer removeAllAnimations];
    _nameLabel.layer.transform = CATransform3DIdentity;

    CGFloat lw = [_nameLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, ch)].width;
    _nameLabel.frame = CGRectMake(0, 0, lw, ch);
    if (lw <= cw + 1.0) return;   // 放得下就不动

    CGFloat d = cw - lw;          // 负值：往左滚
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@(0.0), @(0.0), @(d), @(d)];
    a.keyTimes = @[@(0.0), @(0.14), @(0.86), @(1.0)];
    a.duration = 2.0 + (lw - cw) / 26.0;   // 约 26pt/s，长名字也不会太快
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_nameLabel.layer addAnimation:a forKey:@"marquee"];
}

@end

@implementation SLVoicePackController

- (instancetype)init {
    return [self initInFolder:nil];
}

- (instancetype)initInFolder:(NSString *)folder {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _folder = [folder copy];
    return self;
}

- (BOOL)isRoot {
    return self.folder.length == 0;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isRoot ? @"语音包" : self.folder;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(sl_addTapped)];
    // 留痕：万一还有问题，日志能区分「页面没建完」和「表格结构算错」
    SLLog(@"PACK-PAGE open root=%d folder=%@", (int)self.isRoot, self.folder ?: @"-");
    [self sl_reload];
    SLLog(@"PACK-PAGE ready root=%d", (int)self.isRoot);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // v0.4.33：长按悬浮球会把它当 sheet 弹出，此时是模态根页，需要一个「完成」收起入口
    BOOL modalRoot = self.isRoot && self.navigationController.presentingViewController != nil
                     && self.navigationController.viewControllers.firstObject == self;
    if (modalRoot) {
        if (!self.navigationItem.leftBarButtonItem) {
            self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                                     style:UIBarButtonItemStyleDone
                                                                                    target:self
                                                                                    action:@selector(sl_closeModal)];
        }
    } else {
        self.navigationItem.leftBarButtonItem = nil;
    }
    [self sl_reload];
}

- (void)sl_closeModal {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sl_stopPreview];
}

- (CGFloat)sl_leadingForTableView:(UITableView *)tv {
    if (self.slLeading <= 0) self.slLeading = SLPackMeasureLeading(tv);
    return self.slLeading;
}

// v0.4.9.7：删掉 viewDidLayoutSubviews 里的 reloadData。
// 一级页同时有「文件夹行（带图标，文字 x≈46）」和「开关/音频行（无图标，x≈36）」，
// 逐帧测出来的值会 36↔46 来回跳，于是每次布局都重新加载表格 —— 布局里重建表格正是崩溃来源。
// 现在测量是纯读 cell、值恒定，不需要再校正。

- (void)sl_reload {
    [SLVoicePack syncFromDisk];            // 手工放进目录的音频也能自动出现
    if (self.isRoot) {
        NSMutableArray *fs = [NSMutableArray array];
        for (NSString *f in [SLVoicePack folders]) {
            if (![f isEqualToString:@"未分组"]) [fs addObject:f];
        }
        self.folderList = fs;
        self.ungrouped = [SLVoicePack packsInFolder:@"未分组"];
    } else {
        self.items = [SLVoicePack packsInFolder:self.folder];
    }
    SLLog(@"PACK-PAGE data root=%d folders=%lu ungrouped=%lu items=%lu",
          (int)self.isRoot, (unsigned long)self.folderList.count,
          (unsigned long)self.ungrouped.count, (unsigned long)self.items.count);
    [self.tableView reloadData];
}

#pragma mark - 导入

- (void)sl_addTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
    if (self.isRoot) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"新建文件夹" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self sl_newFolder:nil]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"导入文件夹" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self sl_pickFolder]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"导入音频文件" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self sl_pickFiles]; }]];
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"导入到「%@」", self.folder]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) { [self sl_pickFiles]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"导入文件夹" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [self sl_pickFolder]; }]];
    }
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
            // 二级页里导入 = 直接落进当前文件夹
            if ([SLVoicePack importFileAtURL:url folder:(self.isRoot ? nil : self.folder) error:&err]) {
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

- (void)sl_newFolder:(NSDictionary *)thenMoveTo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹"
                                                                   message:(thenMoveTo ? @"建好后立刻把这条音频移进去" : @"建好后点进去可以导入音频")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"文件夹名，如 搞怪、方言";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        if (![SLVoicePack createFolder:name]) {
            [AWECAUtils showToast:@"建不了：名字重复或为空" duration:2.0];
            return;
        }
        if (thenMoveTo) {
            NSString *err = nil;
            if ([SLVoicePack movePack:thenMoveTo toFolder:name error:&err]) {
                [AWECAUtils showToast:[NSString stringWithFormat:@"已移到「%@」", name] duration:1.6];
            } else {
                [AWECAUtils showToast:err.length ? err : @"移动失败" duration:2.0];
            }
        } else {
            [AWECAUtils showToast:[NSString stringWithFormat:@"已新建「%@」", name] duration:1.6];
        }
        [self sl_reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sl_renameFolder:(NSString *)folder {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名文件夹"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = folder;
        tf.placeholder = @"文件夹名";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = alert.textFields.firstObject.text;
        if (!name.length) return;
        NSString *err = nil;
        if ([SLVoicePack renameFolder:folder to:name error:&err]) {
            [self sl_reload];
        } else {
            [AWECAUtils showToast:err.length ? err : @"改名失败" duration:2.0];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sl_deleteFolder:(NSString *)folder {
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

- (void)sl_movePack:(NSDictionary *)pack {
    NSString *cur = pack[@"folder"] ?: @"未分组";
    NSMutableArray *targets = [NSMutableArray array];
    for (NSString *f in [SLVoicePack folders]) {
        if (![targets containsObject:f]) [targets addObject:f];
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"移动到"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *f in targets) {
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
                                            handler:^(UIAlertAction *a) { [self sl_newFolder:pack]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 表格结构

- (NSInteger)sl_folderSection {
    return self.folderList.count ? 1 : -1;
}

- (NSInteger)sl_ungroupedSection {
    if (!self.ungrouped.count) return -1;
    return self.folderList.count ? 2 : 1;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    if (!self.isRoot) return 1;
    return 1 + (self.folderList.count ? 1 : 0) + (self.ungrouped.count ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (!self.isRoot) return self.items.count;
    if (section == 0) return 1;
    if (section == [self sl_folderSection]) return self.folderList.count;
    return self.ungrouped.count;
}

- (NSString *)sl_headerTextForSection:(NSInteger)section {
    if (!self.isRoot) return nil;
    if (section == [self sl_folderSection]) return @"文件夹";
    if (section == [self sl_ungroupedSection]) return @"未分组";
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    NSString *t = [self sl_headerTextForSection:section];
    if (!t.length) return nil;
    return SLPackHeader(t, [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv;
    return [self sl_headerTextForSection:section].length ? 22 : 8;
}

- (NSString *)sl_footerTextForSection:(NSInteger)section {
    if (!self.isRoot) {
        return section == 0
            ? [NSString stringWithFormat:@"发「%@」直接发出所选语音 · 点行选中发送\n右上＋导入到此文件夹 · 左滑移动 / 裁剪 / 重命名 / 删除", SLPackCmdValue()]
            : nil;
    }
    if (section == 0) {
        return [NSString stringWithFormat:@"发「%@」直接发出所选语音，不走合成\n点文件夹进入 · 左滑文件夹可重命名 / 删除", SLPackCmdValue()];
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    NSString *t = [self sl_footerTextForSection:section];
    if (!t.length) return nil;
    return SLPackFooter(t, [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    NSString *t = [self sl_footerTextForSection:section];
    if (!t.length) return 0;
    // 固定留出「左基线 36 + 右边距 16 + 余量」，不在这里调测量函数：
    // 测量一旦走 rectForRow 就和本方法互相递归。宁可多留一点高度，也不能压字。
    CGFloat w = tv.bounds.size.width - 68;
    if (w <= 0) return UITableViewAutomaticDimension;
    CGRect r = [t boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                               options:NSStringDrawingUsesLineFragmentOrigin
                            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}
                               context:nil];
    // v0.4.9.9：footer 内边距统一为「上 5 + 下 7」（跟设置页同一个盒子），这里补足 14
    return ceil(r.size.height) + 14;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.isRoot && ip.section == 0) {
        static NSString *sid = @"switch";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:sid];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sid];
        cell.textLabel.text = @"启用语音包";
        cell.textLabel.textColor = [UIColor labelColor];
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.on = [SLVoicePack isEnabled];
        [sw addTarget:self action:@selector(sl_switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (self.isRoot && ip.section == [self sl_folderSection]) {
        static NSString *fid = @"folder";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:fid];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:fid];
        NSString *name = self.folderList[ip.row];
        NSUInteger n = [SLVoicePack packsInFolder:name].count;
        cell.textLabel.text = name;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个", (unsigned long)n];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    static NSString *rid = @"pack";
    SLPackCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[SLPackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSDictionary *pack = [self sl_packAt:ip];
    if (!pack) {
        [cell sl_setName:@"" active:NO];
        cell.durLabel.text = nil;
        return cell;
    }
    BOOL active = [SLVoicePack isPackActive:pack];
    [cell sl_setName:(pack[@"name"] ?: @"未命名") active:active];
    cell.durLabel.text = [SLVoicePack displayDuration:pack];

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
    if (!self.isRoot) {
        return ip.row < self.items.count ? self.items[ip.row] : nil;
    }
    if (ip.section == [self sl_ungroupedSection]) {
        return ip.row < self.ungrouped.count ? self.ungrouped[ip.row] : nil;
    }
    return nil;
}

- (void)sl_switchChanged:(UISwitch *)sw {
    [SLVoicePack setEnabled:sw.on];
    if (sw.on && ![SLVoicePack activePack]) {
        [AWECAUtils showToast:@"还没选语音包，先点一条" duration:2.0];
    }
}

#pragma mark - 选择 / 进入文件夹

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.isRoot && ip.section == 0) return;

    if (self.isRoot && ip.section == [self sl_folderSection]) {
        NSString *name = self.folderList[ip.row];
        [self sl_stopPreview];
        [self.navigationController pushViewController:[[SLVoicePackController alloc] initInFolder:name] animated:YES];
        return;
    }

    NSDictionary *pack = [self sl_packAt:ip];
    if (!pack) return;
    [SLVoicePack selectPack:pack];
    [SLVoicePack setEnabled:YES];
    [self.tableView reloadData];
    [AWECAUtils showToast:[NSString stringWithFormat:@"已选中「%@」· 发「%@」直接发出",
                           pack[@"name"] ?: @"", SLPackCmdValue()] duration:2.0];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.isRoot && ip.section == 0) return nil;

    // 文件夹行：重命名 / 删除
    if (self.isRoot && ip.section == [self sl_folderSection]) {
        NSString *name = self.folderList[ip.row];
        UIContextualAction *rename = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                            title:@"重命名"
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            done(YES);
            [self sl_renameFolder:name];
        }];
        rename.backgroundColor = [UIColor systemBlueColor];

        UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:@"删除"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            done(YES);
            [self sl_deleteFolder:name];
        }];
        return [UISwipeActionsConfiguration configurationWithActions:@[del, rename]];
    }

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
        NSString *ext = path.pathExtension.lowercaseString;
        BOOL ogg = [@[@"ogg", @"oga", @"opus", @"webm"] containsObject:ext];
        [AWECAUtils showToast:(ogg ? @"iOS 解不了 oga/ogg，先转成 m4a 或 wav"
                                   : @"这段音频放不了，换个格式试试")
                     duration:2.4];
        SLLog(@"pack preview fail %@ / %@", path.lastPathComponent, err.localizedDescription ?: @"nil player");
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
