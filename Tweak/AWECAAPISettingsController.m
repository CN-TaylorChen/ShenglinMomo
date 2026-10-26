// API 凭证分组设置页（v1.4.6 重设计）
// 旧版是 8 个输入框塞一个 UIAlertController：乱、Key 密文看不见。
// 新版：火山 / Fish / 高级（TOS + 识别资源 ID，默认折叠）三组，
// 每个 Key 右侧眼睛按钮一键明文，每组底部附获取指引。
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECAAPISettingsController.h"
#import "AWECATTSManager.h"
#import "AWECATOSUploader.h"
#import "AWECAUtils.h"

#pragma mark - 输入行 Cell（label + 输入框 + 眼睛按钮）

@interface AWECAAPIFieldCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIButton *eyeBtn;
@property (nonatomic, copy) void (^onEyeToggle)(AWECAAPIFieldCell *cell);
@end

@implementation AWECAAPIFieldCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:14];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [_titleLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self.contentView addSubview:_titleLabel];

        _field = [[UITextField alloc] init];
        _field.font = [UIFont monospacedSystemFontOfSize:13.5 weight:UIFontWeightRegular];
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        [_field setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self.contentView addSubview:_field];

        _eyeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _eyeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [_eyeBtn setTitle:@"显示" forState:UIControlStateNormal];
        [_eyeBtn setTranslatesAutoresizingMaskIntoConstraints:NO];
        [_eyeBtn addTarget:self action:@selector(aweca_toggleEye) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_eyeBtn];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_titleLabel.widthAnchor constraintEqualToConstant:92],
            [_eyeBtn.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_eyeBtn.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_eyeBtn.widthAnchor constraintEqualToConstant:44],
            [_field.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:10],
            [_field.trailingAnchor constraintEqualToAnchor:_eyeBtn.leadingAnchor constant:-6],
            [_field.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_field.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)aweca_toggleEye {
    BOOL secure = !self.field.secureTextEntry;
    self.field.secureTextEntry = secure;
    [self.eyeBtn setTitle:(secure ? @"显示" : @"隐藏") forState:UIControlStateNormal];
    if (self.onEyeToggle) self.onEyeToggle(self);
}

@end

#pragma mark - 设置页

// v0.4.4：系统 footer 在陌陌的 tableView 里会被压成单行、右侧截断，
// 统一改成多行自定义视图（numberOfLines = 0 + 自动高度）
// v0.4.9.6：与主页一致，分组标题 / footer / 单元格文字统一到同一条左基线
// v0.4.9.7：同主页 —— 只读已存在的 cell，不再走 rectForRowAtIndexPath（会和 footer 高度互相递归）
static CGFloat AWECAMeasureLeading(UITableView *tv) {
    for (UITableViewCell *c in tv.visibleCells) {
        UILabel *lab = c.textLabel;
        if (!lab || lab.hidden || !lab.text.length) continue;
        if (c.imageView.image) continue;     // 带图标的行文字被推右，不能当基准
        CGFloat x = CGRectGetMinX(c.frame) + CGRectGetMinX(lab.frame);
        if (x > 0) return x;
    }
    return 36;   // 卡片左缘 20 + 内边距 16
}

static UIView *AWECAMakeFooter(NSString *text, CGFloat x, CGFloat width) {
    if (!text.length) return nil;
    CGFloat w = width > 0 ? width : [UIScreen mainScreen].bounds.size.width;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 0)];
    UILabel *lab = [[UILabel alloc] init];
    lab.translatesAutoresizingMaskIntoConstraints = NO;
    lab.numberOfLines = 0;
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = text;
    [box addSubview:lab];
    [NSLayoutConstraint activateConstraints:@[
        [lab.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:MAX(0, x)],
        [lab.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [lab.topAnchor constraintEqualToAnchor:box.topAnchor constant:5],
        [lab.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-7],
    ]];
    return box;
}

// v0.4.9.2：系统分区头会把英文强制全大写（Fish Audio → FISH AUDIO），改成自定义视图。
// v0.4.9.6：x 与 footer 共用同一个左基线，三者对齐。
static UIView *AWECAMakeHeader(NSString *text, CGFloat x, CGFloat width) {
    if (!text.length) return nil;
    CGFloat w = width > 0 ? width : [UIScreen mainScreen].bounds.size.width;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 22)];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(x, 22 - 19, MAX(0, w - x - 16), 17)];
    lab.font = [UIFont systemFontOfSize:12];
    lab.textColor = [UIColor secondaryLabelColor];
    lab.text = text;
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:lab];
    return box;
}

@implementation AWECAAPISettingsController {

    AWECATTSManager *_mgr;
    BOOL _advancedExpanded;   // v0.4.5：TOS 与识别资源 ID 合并成一组，共用这个折叠开关
    CGFloat _awecaLeading;    // v0.4.9.6：统一左基线（单元格文字左边缘）
}

// v0.4.6：跟主面板一致，改用 insetGrouped 圆角卡片样式
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _mgr = [AWECATTSManager shared];
    self.title = @"API 凭证";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    self.tableView.estimatedSectionFooterHeight = 28;
    self.tableView.estimatedSectionHeaderHeight = 26;
    [self.tableView registerClass:[AWECAAPIFieldCell class] forCellReuseIdentifier:@"field"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(aweca_saveAll)];
    _advancedExpanded = NO;
}

- (CGFloat)aweca_leading:(UITableView *)tv {
    if (_awecaLeading <= 0) _awecaLeading = AWECAMeasureLeading(tv);
    return _awecaLeading;
}

// v0.4.9.7：删掉布局回调里的 reloadData（布局中重建表格会反复触发自身布局）

#pragma mark - 字段读写

static NSString *AWECATrimStr(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

// 行模型：tag 标识字段；扩展区的行 index 从固定行之后线性排布
- (void)aweca_applyField:(NSInteger)fieldIndex text:(NSString *)text {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *v = AWECATrimStr(text);
    switch (fieldIndex) {
        case 0: _mgr.appID = v; break;
        case 1: _mgr.accessToken = v; break;
        case 2: _mgr.fishAPIKey = v; break;
        case 3: [ud setObject:v forKey:kAWECATOSAccessKey]; break;
        case 4: [ud setObject:v forKey:kAWECATOSSecretKey]; break;
        case 5: [ud setObject:v forKey:kAWECATOSBucket]; break;
        case 6: [ud setObject:v forKey:kAWECATOSRegion]; break;
        case 7: [ud setObject:v forKey:kAWECAASRResourceId]; break;
        default: break;
    }
}

- (NSString *)aweca_valueForField:(NSInteger)fieldIndex {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    switch (fieldIndex) {
        case 0: return _mgr.appID ?: @"";
        case 1: return _mgr.accessToken ?: @"";
        case 2: return _mgr.fishAPIKey ?: @"";
        case 3: return [ud stringForKey:kAWECATOSAccessKey] ?: @"";
        case 4: return [ud stringForKey:kAWECATOSSecretKey] ?: @"";
        case 5: return [ud stringForKey:kAWECATOSBucket] ?: @"";
        case 6: return [ud stringForKey:kAWECATOSRegion] ?: @"";
        case 7: return [ud stringForKey:kAWECAASRResourceId] ?: @"";
        default: return @"";
    }
}

// 扩展区的第 idx 个字段 -> 全局字段编号（无则 -1）
- (NSInteger)aweca_fieldIndexInExtraRow:(NSInteger)row {
    if (!_advancedExpanded) return -1;
    if (row < 1) return -1;                 // 第 0 行是折叠行本身
    if (row <= 4) return 3 + (row - 1);     // 1..4 → AK / SK / Bucket / Region
    if (row == 5) return 7;                 // 5 → 识别资源 ID
    return -1;
}

- (NSString *)aweca_placeholderForField:(NSInteger)f {
    switch (f) {
        case 0: return @"数字 ID";
        case 1: return @"以 AKLT 开头的 Key";
        case 2: return @"Fish Audio 的 Key";
        case 3: return @"AccessKey ID";
        case 4: return @"SecretAccessKey";
        case 5: return @"私有桶名称";
        case 6: return @"留空 = cn-beijing";
        case 7: return @"留空 = volc.seedasr.auc";
        default: return @"";
    }
}

- (NSString *)aweca_titleForField:(NSInteger)f {
    switch (f) {
        case 0: return @"App ID";
        case 1: return @"API Key";
        case 2: return @"API Key";
        case 3: return @"AK ID";
        case 4: return @"SK";
        case 5: return @"Bucket";
        case 6: return @"区域";
        case 7: return @"资源 ID";
        default: return @"";
    }
}

- (BOOL)aweca_isSecureField:(NSInteger)f {
    return (f == 1) || (f == 2) || (f == 4);
}

#pragma mark - 保存

- (void)aweca_saveAll {
    [self.view endEditing:YES];
    // 从所有可见 cell 收集当前值（不可见折叠区的值在编辑结束回调里已即时落库，不会丢）
    for (AWECAAPIFieldCell *cell in [self.tableView visibleCells]) {
        if (![cell isKindOfClass:[AWECAAPIFieldCell class]]) continue;
        [self aweca_applyField:cell.eyeBtn.tag text:cell.field.text];
    }
    [_mgr saveConfig];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if ([AWECATOSUploader hasCredentials]) {
        [AWECAUtils showToast:@"已保存" duration:1.5];
    } else {
        [AWECAUtils showToast:@"已保存（TOS 配置不完整时，语音转音色不可用）" duration:2.0];
    }
}

#pragma mark - 表格数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;                       // 火山：App ID + API Key
    if (section == 1) return 1;                       // Fish：API Key
    return 1 + (_advancedExpanded ? 5 : 0);   // 高级：1 个折叠行 + 5 个字段（TOS 4 个 + 识别资源 ID）
}

// v0.4.9.2：三处叫法统一为「语音转音色」，与本页可见功能名一致
- (NSString *)aweca_headerForSection:(NSInteger)section {
    if (section == 0) return @"火山引擎（豆包音色）";
    if (section == 1) return @"Fish Audio";
    return @"语音转音色";
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return AWECAMakeHeader([self aweca_headerForSection:section], [self aweca_leading:tableView], tableView.bounds.size.width);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 26 : 22;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;   // 全部改走 viewForFooterInSection（多行，不截断）
}

- (NSString *)aweca_footerForSection:(NSInteger)section {
    if (section == 0) return @"控制台 → API Key 管理获取，仅存本机";
    if (section == 1) return @"Fish Audio 官网 → 左侧「开发者」 → 创建 API 密钥";
    // v0.4.9.1：原句用「；」串了三件事，一行读不下来；按分号拆行，句末不再加句号
    return @"对象存储（TOS）用于「语音转音色」功能的音频存储\n音频上传至存储桶后，再执行音色替换处理\n识别资源 ID 留空即标准版，一般不需要修改";
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return AWECAMakeFooter([self aweca_footerForSection:section], [self aweca_leading:tableView], tableView.bounds.size.width);
}

// 按文本实算高度，保证多行说明完整显示（系统默认单行会截断）
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSString *text = [self aweca_footerForSection:section];
    if (!text.length) return 0;
    CGFloat w = tableView.bounds.size.width - 68;   // 左基线 36 + 右 16 + 余量，不在此处调测量（会递归）
    if (w <= 0) return UITableViewAutomaticDimension;
    CGRect r = [text boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}
                                  context:nil];
    return ceil(r.size.height) + 14;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 高级区的折叠入口行（TOS 上传 + 识别资源 ID 合成一组，一次展开）
    if (indexPath.section == 2 && indexPath.row == 0) {
        static NSString *foldId = @"fold";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:foldId];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:foldId];
        BOOL expanded = _advancedExpanded;
        // 标题只留主干，箭头交给右侧系统 chevron（不再把「›」写进文字里）
        cell.textLabel.text = @"TOS 设置";
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.textColor = [UIColor labelColor];
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        UIView *chev = [self aweca_chevronExpanded:expanded];
        if (chev) {
            cell.accessoryView = chev;
        } else if (!expanded) {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    NSInteger f = -1;
    if (indexPath.section == 0) f = indexPath.row;                 // 0/1
    else if (indexPath.section == 1) f = 2;                        // Fish Key
    else f = [self aweca_fieldIndexInExtraRow:indexPath.row];

    AWECAAPIFieldCell *cell = [tableView dequeueReusableCellWithIdentifier:@"field" forIndexPath:indexPath];
    cell.titleLabel.text = [self aweca_titleForField:f];
    cell.field.placeholder = [self aweca_placeholderForField:f];
    cell.field.text = [self aweca_valueForField:f];
    cell.field.secureTextEntry = [self aweca_isSecureField:f];
    cell.eyeBtn.hidden = ![self aweca_isSecureField:f];
    cell.eyeBtn.tag = f;                    // 字段编号随 cell 走，保存时按编号落库
    cell.field.tag = f;
    // 注意：不能 removeTarget（会清掉 cell 内部的明文切换 handler）；
    // UIControl 对相同 target/action 自动去重，重复 addTarget 安全
    [cell.eyeBtn addTarget:self action:@selector(aweca_eyeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [cell.field addTarget:self action:@selector(aweca_fieldEdited:) forControlEvents:UIControlEventEditingDidEnd];
    return cell;
}

- (void)aweca_eyeTapped:(UIButton *)sender {
    (void)sender;   // cell 内部已切换明文；此处仅保留目标-动作链路
}

// 折叠指示箭头（展开朝下，收起朝右）；取不到系统图标时返回 nil 由调用方降级
- (UIView *)aweca_chevronExpanded:(BOOL)expanded {
    UIImage *img = [UIImage systemImageNamed:(expanded ? @"chevron.down" : @"chevron.right")];
    if (!img) return nil;
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = CGRectMake(0, 0, 13, 13);
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tintColor = [UIColor tertiaryLabelColor];
    return iv;
}

- (void)aweca_fieldEdited:(UITextField *)field {
    [self aweca_applyField:field.tag text:field.text];
    [_mgr saveConfig];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2 && indexPath.row == 0) {
        _advancedExpanded = !_advancedExpanded;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

@end
