// 声临·陌陌版 设置面板
// 复用声临的 TTS 引擎设置（火山/Fish）、音色库、情绪标签、API 凭证页
//
// v0.4.4 排版规则（解决长文案被截断）：
//   R1 单元格右侧只放状态词（≤8 字），解释性长句一律下沉到分组 footer
//   R2 footer 全部用自定义视图（UILabel numberOfLines = 0），不再用系统 titleForFooterInSection
//   R3 折叠/跳转统一用系统 chevron，箭头不写进标题文字
// v0.4.4 顺带删除「语音格式 AMR / 原始音频」开关（已是死代码）

#import "SLSettingsPanel.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import "AWECAAPISettingsController.h"
#import "AWECATTSVoiceListController.h"
#import "SLLogViewController.h"
#import "SLEntry.h"

#define kSLEnabledKey @"SLEnhanceEnabled"
#define kSLCommandKey @"SLCommand"
#define kSLFillShortKey @"SLFillShort"
#define SLVersion @"0.4.7"

#pragma mark - 多行 footer

// 系统 footer 在陌陌的 tableView 里会被算成单行并右侧截断，
// 所以这里自己撑一个多行 label，高度交给自动布局。
static UIView *SLMakeFooter(NSString *text) {
    if (!text.length) return nil;
    UIView *box = [[UIView alloc] initWithFrame:CGRectZero];
    UILabel *lab = [[UILabel alloc] init];
    lab.translatesAutoresizingMaskIntoConstraints = NO;
    lab.numberOfLines = 0;
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = text;
    [box addSubview:lab];
    [NSLayoutConstraint activateConstraints:@[
        [lab.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [lab.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [lab.topAnchor constraintEqualToAnchor:box.topAnchor constant:5],
        [lab.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-7],
    ]];
    return box;
}

@interface SLSettingsPanel ()
@property (nonatomic, strong) UISegmentedControl *engineSeg;
@end

@implementation SLSettingsPanel

// v0.4.6：改成 insetGrouped —— UITableViewController 默认走 Plain，行直通屏幕两边、方角，
// 看着像草稿。insetGrouped 自带 16pt 边距 + 每组首尾行圆角，等于系统原生「设置卡片」。
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"声临 · 陌陌版 v%@", SLVersion];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(sl_close)];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
    self.tableView.tableHeaderView = [self sl_header];
}

// 顶部说明：两行讲完，高度按实际文本算，避免压字
- (UIView *)sl_header {
    CGFloat w = self.view.bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;
    NSString *text = [NSString stringWithFormat:@"输入框发「%@ 要说的话」，会自动换成 AI 音色语音发出；失败退回原文。", [self sl_command]];
    CGFloat textW = w - 36;
    UIFont *font = [UIFont systemFontOfSize:12];
    CGRect r = [text boundingRectWithSize:CGSizeMake(textW, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: font}
                                  context:nil];
    CGFloat h = ceil(r.size.height);
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h + 24)];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, textW, h)];
    lab.numberOfLines = 0;
    lab.font = font;
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = text;
    [v addSubview:lab];
    return v;
}

- (NSString *)sl_command {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCommandKey];
    return v.length ? v : @"#tts";
}

- (void)sl_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.tableView.tableHeaderView = [self sl_header];
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 5;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 3;   // 开关 + 引擎 + 悬浮球图标
    if (section == 1) return 2;   // 音色库 + 情绪
    if (section == 2) return 2;   // 口令 + 短录音补全
    if (section == 3) return 1;   // API 凭证
    return 1;                     // 运行日志
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    return @[@"基本", @"音色与情绪", @"发送方式", @"凭证", @"诊断"][section];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv;
    (void)section;
    return nil;   // 全部改走 viewForFooterInSection
}

// footer 文案集中在一处，view 和高度用同一份，保证不压字
// 每组都带 footer：既解释状态，也撑出分组间距（footer 高度为 0 时分组会粘在一起）
- (NSString *)sl_footerForSection:(NSInteger)section {
    if (section == 0) return @"切换引擎后需要在下方重新选择音色";
    if (section == 1) return @"仅 Fish Audio 引擎支持情绪标签";
    if (section == 2) return @"以该口令开头才转语音；关闭「短录音补全」时只发录到的那一段";
    if (section == 3) return @"Key 只保存在本机，不会上传";
    if (section == 4) return @"#tts 没反应时先看这里";
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    (void)tv;
    return SLMakeFooter([self sl_footerForSection:section]);
}

// 高度按文本实算（宽 = 表宽 - 左右各 18pt），不依赖自动布局估算，避免出现压字 / 半行
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    if (!text.length) return 0;
    CGFloat w = tv.bounds.size.width - 64;   // insetGrouped：分组左右各 16 + 文本左右各 16
    if (w <= 0) return UITableViewAutomaticDimension;
    CGRect r = [text boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}
                                  context:nil];
    return ceil(r.size.height) + 14;   // 上 5 + 下 7 + 2pt 余量
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    // Value1：标题左、状态右、同一条基线（Subtitle 会把状态压到第二行左对齐，看着就错位）
    cell.detailTextLabel.textAlignment = NSTextAlignmentRight;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    AWECATTSManager *mgr = [AWECATTSManager shared];

    if (ip.section == 0) {
        if (ip.row == 0) {
            cell.textLabel.text = @"启用转换";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            sw.on = [d objectForKey:kSLEnabledKey] ? [d boolForKey:kSLEnabledKey] : YES;
            [sw addTarget:self action:@selector(sl_powerChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (ip.row == 1) {
            cell.textLabel.text = @"合成引擎";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"火山引擎", @"Fish Audio"]];
            seg.frame = CGRectMake(0, 0, 186, 30);
            seg.selectedSegmentIndex = mgr.fishEngine ? 1 : 0;
            [seg addTarget:self action:@selector(sl_engineChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"悬浮球图标";
            cell.detailTextLabel.text = SLFloatIconSummary();
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (ip.section == 1) {
        if (ip.row == 0) {
            NSString *voice = mgr.fishEngine
                ? (mgr.fishVoiceName.length ? mgr.fishVoiceName : @"未选择，点这里添加")
                : (mgr.voiceName.length ? mgr.voiceName : @"未选择");
            cell.textLabel.text = @"音色库";
            cell.detailTextLabel.text = voice;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"情绪标签";
            cell.detailTextLabel.text = mgr.fishEmotionSel.count
                ? [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)mgr.fishEmotionSel.count]
                : @"未启用";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (ip.section == 2) {
        if (ip.row == 0) {
            cell.textLabel.text = @"触发口令";
            cell.detailTextLabel.text = [self sl_command];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"短录音补全";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            sw.on = [d objectForKey:kSLFillShortKey] ? [d boolForKey:kSLFillShortKey] : YES;
            [sw addTarget:self action:@selector(sl_fillChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }

    if (ip.section == 3) {
        cell.textLabel.text = @"API 凭证";
        cell.detailTextLabel.text = mgr.fishEngine
            ? (mgr.fishAPIKey.length ? @"Fish Audio 已配置" : @"未配置 Fish Audio")
            : (mgr.appID.length ? @"火山已配置" : @"未配置火山");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    cell.textLabel.text = @"运行日志";
    cell.detailTextLabel.text = @"点此查看";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0 && ip.row == 2) {
        [self.navigationController pushViewController:[[SLFloatIconController alloc] init] animated:YES];
        return;
    }
    if (ip.section == 1 && ip.row == 0) {
        AWECATTSVoiceListController *vc = [[AWECATTSVoiceListController alloc] init];
        vc.fishMode = [AWECATTSManager shared].fishEngine;   // 关键：跟着引擎走，否则只能看到火山音色
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == 1 && ip.row == 1) {
        AWECATTSVoiceListController *vc = [[AWECATTSVoiceListController alloc] init];
        vc.emotionMode = YES;
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == 2 && ip.row == 0) {
        [self sl_editCommand];
        return;
    }
    if (ip.section == 3) {
        AWECAAPISettingsController *vc = [[AWECAAPISettingsController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == 4) {
        SLLogViewController *vc = [[SLLogViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - Actions

- (void)sl_editCommand {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"触发口令"
                                                               message:@"输入框以这个口令开头时，文字会被转成语音消息发送"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [self sl_command];
        tf.placeholder = @"#tts";
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *v = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (v.length == 0) v = @"#tts";
        [[NSUserDefaults standardUserDefaults] setObject:v forKey:kSLCommandKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [weakSelf.tableView reloadData];
        [AWECAUtils showToast:[NSString stringWithFormat:@"口令已改为 %@", v] duration:1.5];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sl_powerChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kSLEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [AWECAUtils showToast:sw.on ? @"已启用文字转语音" : @"已关闭，只发文本" duration:1.5];
}

- (void)sl_fillChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kSLFillShortKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [AWECAUtils showToast:sw.on ? @"短录音会补全 AI 语音" : @"只发录到的那一段" duration:1.5];
}

- (void)sl_engineChanged:(UISegmentedControl *)seg {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    mgr.fishEngine = (seg.selectedSegmentIndex == 1);
    [mgr saveConfig];
    [self.tableView reloadData];
}

@end
