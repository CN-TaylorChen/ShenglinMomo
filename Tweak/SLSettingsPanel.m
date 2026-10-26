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
#import "SLVoicePack.h"
#import "SLVoicePackController.h"
#import "SLAlignBox.h"
#import "SLVirtualLocation.h"
#import "SLMapPickerController.h"
#import "SLTTSAuditionPanel.h"

// 定义在 Tweak.x 里（音波侦察探针，默认关）
extern BOOL SLWaveProbeEnabled(void);
extern void SLSetWaveProbeEnabled(BOOL on);
extern void SLRunWaveProbeScan(void);

#define kSLEnabledKey @"SLEnhanceEnabled"
#define kSLCommandKey @"SLCommand"
#define kSLPackCmdKey @"SLPackCommand"
#define kSLFillShortKey @"SLFillShort"
#define SLVersion @"0.4.15"

#pragma mark - 分组标题 / 多行 footer：统一左基线

// v0.4.9.6：以前 header 贴白卡片左缘、footer 固定 16pt、单元格文字又是第三个数，
// 三者永远差几像素。现在只认一个基准：单元格文字的真实左边缘（表格坐标系）。
// 首帧 cell 还没生成时用卡片左缘 + 内边距兜底，值恒定，不再逐帧校正。
// v0.4.9.7：只读已存在的 cell，不再调 rectForRowAtIndexPath。
// 那个 API 内部要算分区总高 → 回调 heightForFooterInSection → 又要这个值，会无限递归。
static CGFloat SLMeasureLeading(UITableView *tv) {
    for (UITableViewCell *c in tv.visibleCells) {
        UILabel *lab = c.textLabel;
        if (!lab || lab.hidden || !lab.text.length) continue;
        if (c.imageView.image) continue;     // 带图标的行文字被推右，不能当基准
        CGFloat x = CGRectGetMinX(c.frame) + CGRectGetMinX(lab.frame);
        if (x > 0) return x;
    }
    return 36;   // 卡片左缘 20 + 内边距 16
}

// 系统 footer 在陌陌的 tableView 里会被算成单行并右侧截断，
// 所以自己撑一个多行 label；左基线交给 SLAlignBox 自校正（见 SLAlignBox.h 里的说明）。
static UIView *SLMakeFooter(NSString *text, CGFloat x, CGFloat width) {
    return SLAlignFooter(text, x, width);
}

// v0.4.9.2：系统分区头（titleForHeaderInSection）自带大留白，且会把英文强制全大写。
// v0.4.9.9：不再把「表格坐标系的 x」当盒子内偏移用，改由 SLAlignBox 按盒子真实位置反推。
static UIView *SLMakeHeader(NSString *text, CGFloat x, CGFloat width) {
    return SLAlignHeader(text, x, width);
}

@interface SLSettingsPanel ()
@property (nonatomic, strong) UISegmentedControl *engineSeg;
@property (nonatomic, assign) CGFloat slLeading;

// 前置声明：这些方法定义在 didSelect 之后，先声明免得 -Werror 因「方法未找到」中断构建
- (void)sl_virtualLocSwitchChanged:(UISwitch *)sw;
- (void)sl_applyVirtualLoc:(BOOL)on;
- (void)sl_pickLocation;
- (void)sl_clearLocation;
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
    // v0.4.9.2：删掉顶部说明（tableHeaderView），首个分组直接跟标题栏
}

- (NSString *)sl_command {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCommandKey];
    return v.length ? v : @"#tts";
}

// v0.4.9.6：语音包口令也开放自定义，跟合成口令彻底分开，互不抢
// v0.4.9.9：默认值改成 #yyb
- (NSString *)sl_packCommand {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPackCmdKey];
    return v.length ? v : @"#yyb";
}

- (CGFloat)sl_leadingForTableView:(UITableView *)tv {
    if (self.slLeading <= 0) self.slLeading = SLMeasureLeading(tv);
    return self.slLeading;
}

// v0.4.9.7：删掉布局回调里的 reloadData（布局中重建表格会反复触发自身布局）

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
    return 6;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 4;   // 开关 + 引擎 + 语音包 + 悬浮球图标
    if (section == 1) return 4;   // 音色库 + 情绪 + 语速 + 音量
    if (section == 2) return 4;   // 合成口令 + 语音包口令 + 短录音补全 + 合成后先试听
    if (section == 3) return 1;   // API 凭证
    if (section == 4) return 3;   // 虚拟定位：开关 + 选点 + 清除
    return 2;                     // 音波探针 + 运行日志
}

- (NSString *)sl_headerForSection:(NSInteger)section {
    return @[@"基本设置", @"音色与情绪", @"发送方式", @"凭证", @"虚拟定位", @"诊断"][section];
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    return SLMakeHeader([self sl_headerForSection:section], [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

// 中文一行 12pt 足够；首个分组离标题栏留 10pt，其余分组靠上一个 footer 自然撑开
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv;
    return section == 0 ? 26 : 22;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv;
    (void)section;
    return nil;   // 全部改走 viewForFooterInSection
}

// footer 文案集中在一处，view 和高度用同一份，保证不压字
// 每组都带 footer：既解释状态，也撑出分组间距（footer 高度为 0 时分组会粘在一起）
- (NSString *)sl_footerForSection:(NSInteger)section {
    if (section == 0) {
        // v0.4.9.6：口令可自定义，文案跟着实际设置走，不再写死 yyb / #tts
        return [NSString stringWithFormat:@"语音包：发「%@」直接发出所选语音，不走合成\n合成语音：发「%@」正常联网合成\n切换引擎后需要在下方重新选择音色",
                [self sl_packCommand], [self sl_command]];
    }
    if (section == 1) return @"仅 Fish Audio 引擎支持情绪";
    if (section == 2) return @"合成口令：以这个口令开头发的文字才会转语音\n语音包口令：单独一条，命中后直接发所选语音\n短录音补全：录音比 AI 语音短时自动补足全长，不必录完\n合成后先试听：合成完先弹一张卡片，听满意了再录";
    if (section == 3) return @"Key 只保存在本机，不会上传";
    if (section == 4) return @"开启后陌陌上报的坐标会替换为你选的点\n只影响本机陌陌，不改系统定位\n坐标与 IP 归属地差太远时可能触发风控，建议固定一个常用位置";
    if (section == 5) return @"音波探针：只挂陌陌自己的音波类并写日志，用来定位音波录音落盘在哪\n会影响性能，采完日志记得关掉并重启陌陌\n没反应时先看运行日志";
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    return SLMakeFooter([self sl_footerForSection:section], [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

// 高度按文本实算（宽 = 表宽 - 左基线 - 右 16），不依赖自动布局估算，避免出现压字 / 半行
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    if (!text.length) return 0;
    CGFloat w = tv.bounds.size.width - 68;   // 左基线 36 + 右 16 + 余量，不在此处调测量（会递归）
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
    // 复用池里上一行可能把颜色改过（比如「清除位置」置灰），这里必须复位
    cell.textLabel.textColor = [UIColor labelColor];

    AWECATTSManager *mgr = [AWECATTSManager shared];

    if (ip.section == 0) {
        if (ip.row == 0) {
            cell.textLabel.text = @"文字转语音";
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
        } else if (ip.row == 2) {
            cell.textLabel.text = @"语音包";
            NSDictionary *active = [SLVoicePack activePack];
            if (!active) {
                cell.detailTextLabel.text = @"未启用";
            } else if ([SLVoicePack isEnabled]) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 已启用", active[@"name"] ?: @""];
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 已关闭", active[@"name"] ?: @""];
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
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
        } else if (ip.row == 1) {
            cell.textLabel.text = @"情绪";
            cell.detailTextLabel.text = mgr.fishEmotionSel.count
                ? [NSString stringWithFormat:@"已选 %lu 个", (unsigned long)mgr.fishEmotionSel.count]
                : @"未启用";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 2) {
            cell.textLabel.text = @"语速";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2fx", mgr.speedRatio];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"音量";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.2fx", mgr.volumeRatio];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (ip.section == 2) {
        if (ip.row == 0) {
            cell.textLabel.text = @"合成口令";
            cell.detailTextLabel.text = [self sl_command];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            cell.textLabel.text = @"语音包口令";
            cell.detailTextLabel.text = [self sl_packCommand];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 2) {
            cell.textLabel.text = @"短录音补全";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            sw.on = [d objectForKey:kSLFillShortKey] ? [d boolForKey:kSLFillShortKey] : YES;
            [sw addTarget:self action:@selector(sl_fillChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = @"合成后先试听";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            sw.on = [SLTTSAuditionPanel isEnabled];
            [sw addTarget:self action:@selector(sl_auditionChanged:) forControlEvents:UIControlEventValueChanged];
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

    if (ip.section == 4) {
        if (ip.row == 0) {
            cell.textLabel.text = @"虚拟定位";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            sw.on = [SLVirtualLocation isOn];
            [sw addTarget:self action:@selector(sl_virtualLocSwitchChanged:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (ip.row == 1) {
            cell.textLabel.text = @"选择位置";
            cell.detailTextLabel.text = [SLVirtualLocation coordinateText] ?: @"未设置";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        cell.textLabel.text = @"清除位置";
        BOOL has = [SLVirtualLocation hasCoordinate];
        cell.detailTextLabel.text = has ? @"恢复真实定位" : @"—";
        cell.textLabel.textColor = has ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
        cell.selectionStyle = has ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (ip.section == 5) {
        if (ip.row == 0) {
            cell.textLabel.text = @"音波探针";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            sw.on = SLWaveProbeEnabled();
            [sw addTarget:self action:@selector(sl_waveProbeChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        cell.textLabel.text = @"运行日志";
        cell.detailTextLabel.text = @"点此查看";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0 && ip.row == 2) {
        [self.navigationController pushViewController:[[SLVoicePackController alloc] init] animated:YES];
        return;
    }
    if (ip.section == 0 && ip.row == 3) {
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
    if (ip.section == 1 && ip.row == 2) {
        [self sl_editRatio:YES];
        return;
    }
    if (ip.section == 1 && ip.row == 3) {
        [self sl_editRatio:NO];
        return;
    }
    if (ip.section == 2 && ip.row == 0) {
        [self sl_editCommand];
        return;
    }
    if (ip.section == 2 && ip.row == 1) {
        [self sl_editPackCommand];
        return;
    }
    if (ip.section == 3) {
        AWECAAPISettingsController *vc = [[AWECAAPISettingsController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (ip.section == 4) {
        if (ip.row == 0) {
            [self sl_applyVirtualLoc:![SLVirtualLocation isOn]];
            return;
        }
        if (ip.row == 1) {
            [self sl_pickLocation];
            return;
        }
        [self sl_clearLocation];
        return;
    }
    if (ip.section == 2 && ip.row == 3) return;   // 「合成后先试听」是开关行
    if (ip.section == 5) {
        if (ip.row == 0) return;                  // 「音波探针」是开关行
        SLLogViewController *vc = [[SLLogViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)sl_auditionChanged:(UISwitch *)sw {
    [SLTTSAuditionPanel setEnabled:sw.on];
}

- (void)sl_waveProbeChanged:(UISwitch *)sw {
    SLSetWaveProbeEnabled(sw.on);
    if (sw.on) {
        [AWECAUtils showToast:@"重启陌陌后生效；录一段音波，再去「运行日志」看 SWAVE 行" duration:3.4];
    } else {
        [AWECAUtils showToast:@"重启陌陌后完全停用" duration:2.4];
    }
}

#pragma mark - 虚拟定位

- (void)sl_virtualLocSwitchChanged:(UISwitch *)sw {
    [self sl_applyVirtualLoc:sw.on];
}

- (void)sl_applyVirtualLoc:(BOOL)on {
    // 只有开关没有坐标等于没开，先引导去选点，别让用户以为生效了
    if (on && ![SLVirtualLocation hasCoordinate]) {
        [AWECAUtils showToast:@"请先选择一个位置" duration:1.8];
        [self.tableView reloadData];
        [self sl_pickLocation];
        return;
    }
    [SLVirtualLocation setOn:on];
    [AWECAUtils showToast:on ? @"虚拟定位已开启" : @"虚拟定位已关闭" duration:1.5];
    [self.tableView reloadData];
}

- (void)sl_pickLocation {
    SLMapPickerController *vc =
        [[SLMapPickerController alloc] initWithCoordinate:[SLVirtualLocation coordinate]
                                              hasInitial:[SLVirtualLocation hasCoordinate]];
    __weak typeof(self) weakSelf = self;
    vc.onPick = ^(CLLocationCoordinate2D coord, NSString *name) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [SLVirtualLocation setCoordinate:coord];
        if (![SLVirtualLocation isOn]) [SLVirtualLocation setOn:YES];   // 选完直接开，省一步
        [self.tableView reloadData];
        NSString *shown = name.length ? name : [SLVirtualLocation coordinateText];
        [AWECAUtils showToast:[NSString stringWithFormat:@"已设为 %@", shown] duration:2.0];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)sl_clearLocation {
    if (![SLVirtualLocation hasCoordinate]) {
        [AWECAUtils showToast:@"还没有设置过位置" duration:1.5];
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清除位置"
                                                               message:@"清除后陌陌会恢复使用真实定位"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [SLVirtualLocation clearCoordinate];
        [SLVirtualLocation setOn:NO];
        [self.tableView reloadData];
        [AWECAUtils showToast:@"已恢复真实定位" duration:1.8];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Actions

- (void)sl_editCommand {
    [self sl_editCommandForKey:kSLCommandKey
                         title:@"合成口令"
                       message:@"以这个口令开头时，文字会被转成语音消息发送"
                      fallback:@"#tts"];
}

// v0.4.9.6：语音包口令也开放自定义（存 SLPackCommand），跟合成口令各走各的
- (void)sl_editPackCommand {
    [self sl_editCommandForKey:kSLPackCmdKey
                         title:@"语音包口令"
                       message:@"单独一条口令，命中后直接发出所选语音，不走合成"
                      fallback:@"#yyb"];
}

- (void)sl_editCommandForKey:(NSString *)key
                       title:(NSString *)title
                     message:(NSString *)message
                    fallback:(NSString *)fallback {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *cur = [d stringForKey:key];
    if (!cur.length) cur = fallback;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.placeholder = fallback;
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *v = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (v.length == 0) v = fallback;
        // 两条口令撞了就等于其中一条永远抢不到，直接拦下来
        NSString *otherKey = [key isEqualToString:kSLCommandKey] ? kSLPackCmdKey : kSLCommandKey;
        NSString *other = [d stringForKey:otherKey];
        if (other.length && [v.lowercaseString isEqualToString:other.lowercaseString]) {
            [AWECAUtils showToast:@"跟另一条口令重复了，换一个" duration:2.2];
            return;
        }
        [d setObject:v forKey:key];
        [d synchronize];
        [weakSelf.tableView reloadData];
        [AWECAUtils showToast:[NSString stringWithFormat:@"%@已改为 %@", title, v] duration:1.5];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// 语速/音量：0.5~2.0 倍，1.0 = 原声。
// 火山走 speech_rate/loudness_rate（已在 AWECATTSManager 映射），Fish 走 prosody.speed/volume
- (void)sl_editRatio:(BOOL)speed {
    NSString *title = speed ? @"语速" : @"音量";
    AWECATTSManager *mgr = [AWECATTSManager shared];
    float cur = speed ? mgr.speedRatio : mgr.volumeRatio;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:@"范围 0.5 ~ 2.0，填 1.0 恢复原声"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [NSString stringWithFormat:@"%.2f", cur];
        tf.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *t = [ac.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"x" withString:@""];
        float v = t.floatValue;
        if (v < 0.01f) v = 1.0f;   // 空输入 / 0 回默认
        if (v < 0.5f) v = 0.5f;
        if (v > 2.0f) v = 2.0f;
        if (speed) mgr.speedRatio = v; else mgr.volumeRatio = v;
        [mgr saveConfig];
        [weakSelf.tableView reloadData];
        [AWECAUtils showToast:[NSString stringWithFormat:@"%@已改为 %.2fx", title, v] duration:1.5];
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
