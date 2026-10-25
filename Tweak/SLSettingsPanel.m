// 声临·陌陌版 设置面板
// 复用声临的 TTS 引擎设置（火山/Fish）、音色库、情绪标签、API 凭证页

#import "SLSettingsPanel.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import "AWECAAPISettingsController.h"
#import "AWECATTSVoiceListController.h"

#define kSLEnabledKey @"SLEnhanceEnabled"
#define SLVersion @"0.1"

@interface SLSettingsPanel ()
@property (nonatomic, strong) UISwitch *powerSwitch;
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
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 64)];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, v.bounds.size.width - 36, 40)];
    lab.numberOfLines = 2;
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = @"按住说话后自动把录音转成所选 AI 音色再发送；识别需配置火山 + TOS（见 API 凭证）。";
    [v addSubview:lab];
    return v;
}

- (void)sl_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 2;   // 开关 + 引擎
    if (section == 1) return 2;   // 音色 + 情绪
    return 1;                     // API 凭证
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    return @[@"基本", @"音色与情绪", @"凭证"][section];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];

    for (UIView *sub in cell.contentView.subviews) {
        if ([sub isKindOfClass:[UISwitch class]] || [sub isKindOfClass:[UISegmentedControl class]]) [sub removeFromSuperview];
    }
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
                ? (mgr.fishVoiceName.length ? mgr.fishVoiceName : @"未选择")
                : (mgr.voiceName.length ? mgr.voiceName : @"未选择");
            cell.textLabel.text = @"音色库";
            cell.detailTextLabel.text = voice;
        } else {
            cell.textLabel.text = @"情绪标签";
            NSString *note = mgr.fishEmotionSel.count
                ? [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)mgr.fishEmotionSel.count]
                : @"未启用（仅 FishAudio 支持）";
            cell.detailTextLabel.text = note;
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    cell.textLabel.text = @"API 凭证";
    cell.detailTextLabel.text = [AWECATOSUploader hasCredentials] ? @"已配置识别(TOS)" : @"未配置识别，将无法转换";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && ip.row == 0) {
        AWECATTSVoiceListController *vc = [[AWECATTSVoiceListController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == 1 && ip.row == 1) {
        AWECATTSVoiceListController *vc = [[AWECATTSVoiceListController alloc] init];
        vc.emotionMode = YES;
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == 2) {
        AWECAAPISettingsController *vc = [[AWECAAPISettingsController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - Actions

- (void)sl_powerChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kSLEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [AWECAUtils showToast:sw.on ? @"已启用陌陌语音转换" : @"已关闭，发送原声" duration:1.5];
}

- (void)sl_engineChanged:(UISegmentedControl *)seg {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    mgr.fishEngine = (seg.selectedSegmentIndex == 1);
    [mgr saveConfig];
}

@end
