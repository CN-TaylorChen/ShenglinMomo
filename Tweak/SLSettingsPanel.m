// 声临·陌陌版 设置面板
// 复用声临的 TTS 引擎设置（火山/Fish）、音色库、情绪标签、API 凭证页

#import "SLSettingsPanel.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import "AWECAAPISettingsController.h"
#import "AWECATTSVoiceListController.h"
#import "SLLogViewController.h"
#import "SLAMREncoder.h"

#define kSLEnabledKey @"SLEnhanceEnabled"
#define kSLCommandKey @"SLCommand"
#define kSLUseAMRKey  @"SLUseAMR"
#define SLVersion @"0.4.3"

@interface SLSettingsPanel ()
@property (nonatomic, strong) UISegmentedControl *engineSeg;
@end

@implementation SLSettingsPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"声临 · 陌陌版 v%@", SLVersion];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(sl_close)];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.tableHeaderView = [self sl_header];
}

- (UIView *)sl_header {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 72)];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(18, 10, v.bounds.size.width - 36, 56)];
    lab.numberOfLines = 3;
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = [NSString stringWithFormat:@"在聊天输入框输入「%@ 要说的话」再点发送，插件会把这段文字转成所选 AI 音色的语音消息发出。\n合成/发送失败会自动退回发送原文。", [self sl_command]];
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
    if (section == 0) return 2;   // 开关 + 引擎
    if (section == 1) return 2;   // 音色库 + 情绪
    if (section == 2) return 2;   // 口令 + 输出格式
    if (section == 3) return 1;   // API 凭证
    return 1;                     // 运行日志
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    return @[@"基本", @"音色与情绪", @"发送方式", @"凭证", @"诊断"][section];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];

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
        } else {
            cell.textLabel.text = @"合成引擎";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"火山引擎", @"FishAudio"]];
            seg.frame = CGRectMake(0, 0, 170, 30);
            seg.selectedSegmentIndex = mgr.fishEngine ? 1 : 0;
            [seg addTarget:self action:@selector(sl_engineChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }

    if (ip.section == 1) {
        if (ip.row == 0) {
            NSString *voice = mgr.fishEngine
                ? (mgr.fishVoiceName.length ? mgr.fishVoiceName : @"未选择，点这里添加")
                : (mgr.voiceName.length ? mgr.voiceName : @"未选择");
            cell.textLabel.text = mgr.fishEngine ? @"FishAudio 音色库" : @"火山音色库";
            cell.detailTextLabel.text = voice;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"情绪标签";
            NSString *note = mgr.fishEmotionSel.count
                ? [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)mgr.fishEmotionSel.count]
                : @"未启用（仅 FishAudio 支持）";
            cell.detailTextLabel.text = note;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (ip.section == 2) {
        if (ip.row == 0) {
            cell.textLabel.text = @"触发口令";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"当前：%@（点此修改）", [self sl_command]];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"语音格式";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"AMR", @"原始音频"]];
            seg.frame = CGRectMake(0, 0, 150, 30);
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            BOOL useAMR = [d objectForKey:kSLUseAMRKey] ? [d boolForKey:kSLUseAMRKey] : YES;
            seg.selectedSegmentIndex = useAMR ? 0 : 1;
            [seg addTarget:self action:@selector(sl_formatChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = seg;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.detailTextLabel.text = [SLAMREncoder available] ? @"陌陌语音消息用 AMR；听不了可改原始音频" : @"未内置 AMR 编码器，将直接发送原始音频";
        }
        return cell;
    }

    if (ip.section == 3) {
        cell.textLabel.text = @"API 凭证";
        cell.detailTextLabel.text = mgr.fishEngine
            ? (mgr.fishAPIKey.length ? @"FishAudio Key 已配置" : @"未配置 FishAudio Key")
            : (mgr.appID.length ? @"火山 Key 已配置" : @"未配置火山凭证");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    cell.textLabel.text = @"运行日志";
    cell.detailTextLabel.text = @"排查 #tts 没反应时点这里，可直接复制";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

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

- (void)sl_engineChanged:(UISegmentedControl *)seg {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    mgr.fishEngine = (seg.selectedSegmentIndex == 1);
    [mgr saveConfig];
    [self.tableView reloadData];
}

- (void)sl_formatChanged:(UISegmentedControl *)seg {
    BOOL useAMR = (seg.selectedSegmentIndex == 0);
    [[NSUserDefaults standardUserDefaults] setBool:useAMR forKey:kSLUseAMRKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
