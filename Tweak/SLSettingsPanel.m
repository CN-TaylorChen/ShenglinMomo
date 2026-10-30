// 声临·陌陌版 设置面板
// 复用声临的 TTS 引擎设置（火山/Fish）、音色库、情绪标签、API 凭证页
//
// v0.4.52 排版规则（解决长文案被截断）：
//   R1 单元格右侧只放状态词（≤8 字），解释性长句一律下沉到分组 footer
//   R2 footer 全部用自定义视图（UILabel numberOfLines = 0），不再用系统 titleForFooterInSection
//   R3 折叠/跳转统一用系统 chevron，箭头不写进标题文字
// v0.4.52 顺带删除「语音格式 AMR / 原始音频」开关（已是死代码）

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
#import "SLGlass.h"

// v0.4.71：语速/音量改用右侧「数值 + 细轨滑块」，行高仍 44pt、跟开关同一列。
// v0.4.72：系统 thumb 是 30pt 白圆，配 3pt 细轨太重、看着像浮在线上；
// 换成自绘 22pt 白圆（0.5pt 发丝描边），轨道照旧压成 3pt。
static UIImage *SLThinSliderThumb(void) {
    static UIImage *img = nil;
    if (img) return img;
    CGFloat d = 22.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d, d)];
    img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor whiteColor] setFill];
        CGContextFillEllipseInRect(c, CGRectMake(0.5, 0.5, d - 1.0, d - 1.0));
        [[UIColor colorWithWhite:0.0 alpha:0.12] setStroke];
        CGContextSetLineWidth(c, 0.5);
        CGContextStrokeEllipseInRect(c, CGRectMake(0.25, 0.25, d - 0.5, d - 0.5));
    }];
    return img;
}

@interface SLThinSlider : UISlider
@end
@implementation SLThinSlider
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIImage *thumb = SLThinSliderThumb();
        [self setThumbImage:thumb forState:UIControlStateNormal];
        [self setThumbImage:thumb forState:UIControlStateHighlighted];
    }
    return self;
}
- (CGRect)trackRectForBounds:(CGRect)bounds {
    CGRect r = [super trackRectForBounds:bounds];
    r.origin.y = (bounds.size.height - 3.0) / 2.0;
    r.size.height = 3.0;
    return r;
}
@end

#define kSLEnabledKey @"SLEnhanceEnabled"
#define kSLCommandKey @"SLCommand"
#define kSLFillShortKey @"SLFillShort"
// v0.4.85：合成失败 / 取消时把口令写回输入框（跟 Tweak.x 里的 kSLKeepTextKey 同一个键）
#define kSLKeepTextKey @"SLKeepTextOnFail"
#define SLVersion @"0.4.91"

// v0.4.52：单元格玻璃色搬到 SLGlass（全站二级页共用同一个数），这里不再重复定义。

#pragma mark - 分组标题 / 多行 footer：统一左基线

// v0.4.52.6：以前 header 贴白卡片左缘、footer 固定 16pt、单元格文字又是第三个数，
// 三者永远差几像素。现在只认一个基准：单元格文字的真实左边缘（表格坐标系）。
// 首帧 cell 还没生成时用卡片左缘 + 内边距兜底，值恒定，不再逐帧校正。
// v0.4.52.7：只读已存在的 cell，不再调 rectForRowAtIndexPath。
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

// v0.4.52.2：系统分区头（titleForHeaderInSection）自带大留白，且会把英文强制全大写。
// v0.4.52.9：不再把「表格坐标系的 x」当盒子内偏移用，改由 SLAlignBox 按盒子真实位置反推。
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

// v0.4.52：改成 insetGrouped —— UITableViewController 默认走 Plain，行直通屏幕两边、方角，
// 看着像草稿。insetGrouped 自带 16pt 边距 + 每组首尾行圆角，等于系统原生「设置卡片」。
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

// v0.4.52：标题栏 = 品牌图标 + 「声临 · 陌陌版」+ 缩小版版本号。
// 版本号不再跟名字挤在同一句里，改成 11pt 灰字贴在名字右下角，只做标注不抢视线。
- (UIView *)sl_titleView {
    // v0.4.53：24 → 32，跟右边「完成」胶囊等高（原来标题那枚明显矮一截，两个胶囊不齐）
    CGFloat H = 32.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, H)];

    UIImageView *icon = [[UIImageView alloc] initWithImage:SLBrandIconImage(44)];
    icon.frame = CGRectMake(0, (H - 22) / 2.0, 22, 22);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [box addSubview:icon];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = @"声临 · 陌陌版";
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    name.textColor = [UIColor labelColor];
    [name sizeToFit];

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectZero];
    ver.text = [NSString stringWithFormat:@"v%@", SLVersion];
    ver.font = [UIFont systemFontOfSize:11];
    ver.textColor = [UIColor secondaryLabelColor];
    [ver sizeToFit];

    // v0.4.52：标题文字套毛玻璃胶囊（超薄材质 + 发丝高光），和浮窗 / 下拉列表统一语言
    CGFloat padX = 10.0, gap = 5.0;
    CGFloat innerW = name.frame.size.width + gap + ver.frame.size.width;
    CGFloat pillW = innerW + padX * 2.0;
    CGFloat pillX = 28.0;
    UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    pill.frame = CGRectMake(pillX, 0, pillW, H);
    pill.layer.cornerRadius = H / 2.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.masksToBounds = YES;
    pill.layer.borderWidth = 0.8;
    pill.layer.borderColor = SLGlassHairlineColor().CGColor;
    [box addSubview:pill];

    name.frame = CGRectMake(padX, (H - name.frame.size.height) / 2.0, name.frame.size.width, name.frame.size.height);
    [pill.contentView addSubview:name];
    ver.frame = CGRectMake(padX + name.frame.size.width + gap, (H - ver.frame.size.height) / 2.0, ver.frame.size.width, ver.frame.size.height);
    [pill.contentView addSubview:ver];

    box.frame = CGRectMake(0, 0, pillX + pillW, H);
    return box;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // title 只给返回按钮用（子页左上角显示「设置」），标题栏本身走 titleView
    self.title = @"设置";
    self.navigationItem.titleView = [self sl_titleView];
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"完成", self, @selector(sl_close));
    // 表格自身透明，让浮窗底层的毛玻璃透上来
    SLApplyGlassTable(self.tableView);
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
    // v0.4.52.2：删掉顶部说明（tableHeaderView），首个分组直接跟标题栏
}

- (NSString *)sl_command {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCommandKey];
    return v.length ? v : @"#tts";
}

- (CGFloat)sl_leadingForTableView:(UITableView *)tv {
    if (self.slLeading <= 0) self.slLeading = SLMeasureLeading(tv);
    return self.slLeading;
}

// v0.4.52.7：删掉布局回调里的 reloadData（布局中重建表格会反复触发自身布局）

- (void)sl_close {
    // v0.4.52：设置页跑在浮窗里（子控制器），直接 dismiss 自己不会关窗
    SLCloseHostingPanel(self);
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
    if (section == 2) return 4;   // 合成口令 + 短录音补全 + 合成后先试听 + 失败时放回输入框
    if (section == 3) return 1;   // API 凭证
    if (section == 4) return 3;   // 虚拟定位：开关 + 选点 + 清除
    if (section == 5) return 1;   // 运行日志（v0.4.54 去掉「动画预览」入口）
    return 1;
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
// v0.4.52：一条都不留了（连「凭证」那句也删）。这些开关的语义一看就懂，
// 旁白纯占地方；分组间距改由固定的 footer 高度撑开。
- (NSString *)sl_footerForSection:(NSInteger)section {
    (void)section;
    return nil;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    if (!text.length) return nil;
    return SLMakeFooter(text, [self sl_leadingForTableView:tv], tv.bounds.size.width);
}

// 高度按文本实算（宽 = 表宽 - 左基线 - 右 16），不依赖自动布局估算，避免出现压字 / 半行
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)section {
    NSString *text = [self sl_footerForSection:section];
    // 没有文案时这段高度纯粹当分组间距用：返回 0 会让相邻两组贴在一起
    if (!text.length) return 16.0;
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
    cell.backgroundColor = SLGlassCellColor();
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
            // v0.4.52：恢复成正常的「语音包」入口（上一版把它删了，用户要求加回来）。
            // 右侧只显示状态词，「直发」那个开关搬到「发送方式」里。
            cell.textLabel.text = @"语音包";
            // v0.4.52：显示「这一发装的是谁」。没装填就是原声（默认状态）。
            if (![SLVoicePack isOneShotPending]) {
                cell.detailTextLabel.text = @"原声";
            } else {
                NSDictionary *active = [SLVoicePack activePack];
                cell.detailTextLabel.text = active ? (active[@"name"] ?: @"已装填") : @"原声";
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
            cell.accessoryView = [self sl_ratioAccessory:YES];
        } else {
            cell.textLabel.text = @"音量";
            cell.accessoryView = [self sl_ratioAccessory:NO];
        }
        return cell;
    }

    if (ip.section == 2) {
        if (ip.row == 0) {
            cell.textLabel.text = @"合成口令";
            cell.detailTextLabel.text = [self sl_command];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            // v0.4.52：语音包口令与「直发」开关都删了 ——
            // 现在点一条包就装好一发，发完自动回原声，不需要任何开关或口令。
            cell.textLabel.text = @"短录音补全";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            sw.on = [d objectForKey:kSLFillShortKey] ? [d boolForKey:kSLFillShortKey] : YES;
            [sw addTarget:self action:@selector(sl_fillChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (ip.row == 2) {
            cell.textLabel.text = @"合成后先试听";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            sw.on = [SLTTSAuditionPanel isEnabled];
            [sw addTarget:self action:@selector(sl_auditionChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            // v0.4.85：合成失败 / 取消时把口令写回输入框（默认开）。
            // 关掉就只复制到剪贴板 —— 有人嫌它会抢输入框、把刚打的字顶掉。
            cell.textLabel.text = @"失败时放回输入框";
            UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            sw.on = [d objectForKey:kSLKeepTextKey] ? [d boolForKey:kSLKeepTextKey] : YES;
            [sw addTarget:self action:@selector(sl_keepTextChanged:) forControlEvents:UIControlEventValueChanged];
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
    if (ip.section == 2 && (ip.row == 1 || ip.row == 2)) return;   // 两个开关行
    if (ip.section == 5) {
        SLLogViewController *vc = [[SLLogViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
}

- (void)sl_auditionChanged:(UISwitch *)sw {
    [SLTTSAuditionPanel setEnabled:sw.on];
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

// v0.4.71：语速/音量 → 右侧「数值 + 细轨滑块」；点整行仍走 sl_editRatio 精修（要填 1.37 这种值时用）
- (UIView *)sl_ratioAccessory:(BOOL)speed {
    // v0.4.72：宽度 188→192，是为了让轨道右端离卡片右缘多留 4pt（对齐其它行的右缘 16pt）。
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 192, 32)];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 52, 32)];
    val.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    val.textColor = [UIColor secondaryLabelColor];
    val.textAlignment = NSTextAlignmentRight;
    val.tag = speed ? 99201 : 99202;
    val.userInteractionEnabled = YES;
    [val addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sl_ratioReset:)]];
    [box addSubview:val];

    // 滑块内部只走 0..1 的「位置」，倍率由 sl_ratioValueForPos: 对数换算（见下）。
    SLThinSlider *sl = [[SLThinSlider alloc] initWithFrame:CGRectMake(62, 0, 126, 32)];
    sl.minimumValue = 0.0f;
    sl.maximumValue = 1.0f;
    sl.tag = speed ? 99211 : 99212;
    sl.minimumTrackTintColor = [UIColor labelColor];
    sl.maximumTrackTintColor = [UIColor tertiaryLabelColor];
    [sl addTarget:self action:@selector(sl_ratioSliding:) forControlEvents:UIControlEventValueChanged];
    [sl addTarget:self action:@selector(sl_ratioSettled:) forControlEvents:UIControlEventTouchUpInside |
                                                                  UIControlEventTouchUpOutside |
                                                                  UIControlEventTouchCancel];
    [box addSubview:sl];

    AWECATTSManager *mgr = [AWECATTSManager shared];
    float cur = speed ? mgr.speedRatio : mgr.volumeRatio;
    if (cur < 0.5f) cur = 0.5f;
    if (cur > 2.0f) cur = 2.0f;
    sl.value = [self sl_ratioPosForValue:cur];   // 1.00x → 位置 0.5，正好落在轨道正中
    val.text = [NSString stringWithFormat:@"%.2fx", cur];
    return box;
}

- (float)sl_ratioSnap:(float)v {
    v = roundf(v * 20.0f) / 20.0f;          // 0.05 一档，130pt 轨道约 4pt 一档
    if (v < 0.5f) v = 0.5f;
    if (v > 2.0f) v = 2.0f;
    return v;
}

- (void)sl_ratioShowValue:(UISlider *)sl value:(float)v {
    UILabel *val = [sl.superview viewWithTag:(sl.tag == 99211 ? 99201 : 99202)];
    val.text = [NSString stringWithFormat:@"%.2fx", v];
}

// v0.4.72：位置 p(0..1) 与倍率 v(0.5~2.0) 之间走对数映射 v = 2^(2p-1)。
// 线性刻度下 1.00x 只占全长 1/3，手柄永远偏左；对数刻度让 1.00x 正好落在 p=0.5，
// 且 0.5→1.0 与 1.0→2.0 的手感幅度对称（各一个八度）。
- (float)sl_ratioValueForPos:(float)p {
    if (p < 0.0f) p = 0.0f;
    if (p > 1.0f) p = 1.0f;
    return powf(2.0f, 2.0f * p - 1.0f);
}

- (float)sl_ratioPosForValue:(float)v {
    if (v < 0.5f) v = 0.5f;
    if (v > 2.0f) v = 2.0f;
    return (log2f(v) + 1.0f) / 2.0f;
}

- (void)sl_ratioSliding:(UISlider *)sl {
    BOOL speed = (sl.tag == 99211);
    float v = [self sl_ratioValueForPos:sl.value];   // 拖动中不吸附档位，保证跟手顺滑
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (speed) mgr.speedRatio = v; else mgr.volumeRatio = v;   // 只改内存，不写盘
    [self sl_ratioShowValue:sl value:v];
}

- (void)sl_ratioSettled:(UISlider *)sl {
    BOOL speed = (sl.tag == 99211);
    float raw = [self sl_ratioValueForPos:sl.value];
    BOOL hitCenter = (fabsf(raw - 1.0f) < 0.06f);   // 靠近原声就吸回 1.00x
    float v = hitCenter ? 1.0f : [self sl_ratioSnap:raw];
    sl.value = [self sl_ratioPosForValue:v];        // 手柄落到吸附后的档位上
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (speed) mgr.speedRatio = v; else mgr.volumeRatio = v;
    [mgr saveConfig];
    [self sl_ratioShowValue:sl value:v];
    if (hitCenter) {   // 只有吸附回 1.00x 才轻震一次，普通松手不震
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }
}

- (void)sl_ratioReset:(UITapGestureRecognizer *)g {
    BOOL speed = (g.view.tag == 99201);
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (speed) mgr.speedRatio = 1.0f; else mgr.volumeRatio = 1.0f;
    [mgr saveConfig];
    [self.tableView reloadData];
    [AWECAUtils showToast:(speed ? @"语速已回到 1.00x" : @"音量已回到 1.00x") duration:1.4];
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

// v0.4.85：关掉后合成失败只复制到剪贴板，不再动陌陌的输入框。
- (void)sl_keepTextChanged:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:kSLKeepTextKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [AWECAUtils showToast:sw.on ? @"失败时把口令放回输入框" : @"失败时只复制到剪贴板" duration:1.5];
}

- (void)sl_engineChanged:(UISegmentedControl *)seg {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    mgr.fishEngine = (seg.selectedSegmentIndex == 1);
    [mgr saveConfig];
    [self.tableView reloadData];
}

@end
