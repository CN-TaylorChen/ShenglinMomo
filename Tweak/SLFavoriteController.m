//
//  SLFavoriteController.m
//  收藏命名浮层 + 收藏列表页
//
//  列表页刻意没用 UITableView 的默认分隔线样式：一行一张圆角卡片，
//  和选点页底部的卡片保持同一套视觉，避免两个页面像两个 App。
//

#import "SLFavoriteController.h"
#import "SLVirtualLocation.h"
#import "SLLog.h"
#import "SLGlass.h"

static UIColor *SLFavGold(void) {
    return [UIColor colorWithRed:0.729 green:0.459 blue:0.090 alpha:1.0];
}
static UIColor *SLFavGoldBg(void) {
    return [UIColor colorWithRed:0.980 green:0.933 blue:0.855 alpha:1.0];
}
static UIColor *SLFavPageBg(void) {
    // v0.4.50：原来是米色实底，进页面就把浮窗的毛玻璃整个盖住。改成透明，
    // 底色统一交给 SLInstallGlassBackdrop 铺的超薄毛玻璃。
    return [UIColor clearColor];
}
static UIColor *SLFavChipBg(void) {
    return [UIColor colorWithRed:0.945 green:0.937 blue:0.910 alpha:1.0];
}
static UIColor *SLFavAccent(void) {
    return [UIColor colorWithRed:0.216 green:0.541 blue:0.867 alpha:1.0];
}

#pragma mark - 命名浮层

@interface SLFavoriteEditor () <UITextFieldDelegate>
@end

@implementation SLFavoriteEditor {
    UIView *_card;
    UITextField *_field;
    NSLayoutConstraint *_centerY;
    CLLocationCoordinate2D _coord;
    NSString *_address;
    SLFavoriteItem *_existing;
    void (^_onSave)(NSString *);
    void (^_onDelete)(void);
    NSMutableArray<UIButton *> *_pills;
}

+ (instancetype)showWithCoordinate:(CLLocationCoordinate2D)coord
                           address:(NSString *)address
                          existing:(SLFavoriteItem *)existing
                            onSave:(void (^)(NSString *))onSave
                          onDelete:(void (^)(void))onDelete {
    UIWindow *win = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win) win = ws.windows.firstObject;   // 退一步：取该 scene 的第一个窗口
        if (win) break;
    }
    if (!win) return nil;

    SLFavoriteEditor *v = [[SLFavoriteEditor alloc] initWithFrame:win.bounds];
    v->_coord = coord;
    v->_address = [address copy];
    v->_existing = existing;
    v->_onSave = [onSave copy];
    v->_onDelete = [onDelete copy];
    v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:v];
    [v sl_build];
    [v sl_animateIn];
    [v sl_observeKeyboard];
    return v;
}

- (void)sl_build {
    _pills = [NSMutableArray array];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = SLGlassCellColor();   // v0.4.50：白卡 → 玻璃片，深色下不再一块白
    _card.layer.cornerRadius = 22;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.16;
    _card.layer.shadowRadius = 26;
    _card.layer.shadowOffset = CGSizeMake(0, 12);
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_card];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack];

    UILabel *title = [[UILabel alloc] init];
    title.text = _existing ? @"重命名收藏" : @"收藏这个位置";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    [stack addArrangedSubview:title];

    UILabel *addr = [[UILabel alloc] init];
    addr.text = _address.length ? _address : [NSString stringWithFormat:@"%.6f, %.6f",
                                              _coord.latitude, _coord.longitude];
    addr.font = [UIFont systemFontOfSize:12.5];
    addr.textColor = [UIColor secondaryLabelColor];
    addr.numberOfLines = 2;
    [stack addArrangedSubview:addr];

    UIStackView *pills = [[UIStackView alloc] init];
    pills.axis = UILayoutConstraintAxisHorizontal;
    pills.spacing = 8;
    pills.alignment = UIStackViewAlignmentLeading;
    for (NSString *t in @[@"家", @"公司", @"学校", @"自定义"]) {
        UIButton *b = [self sl_pill:t];
        [b addTarget:self action:@selector(sl_pillTap:) forControlEvents:UIControlEventTouchUpInside];
        [pills addArrangedSubview:b];
        [_pills addObject:b];
    }
    UIStackView *pillWrap = [[UIStackView alloc] init];
    pillWrap.axis = UILayoutConstraintAxisHorizontal;
    [pillWrap addArrangedSubview:pills];
    UIView *spacer = [[UIView alloc] init];
    [pillWrap addArrangedSubview:spacer];
    [stack addArrangedSubview:pillWrap];

    _field = [[UITextField alloc] initWithFrame:CGRectZero];
    _field.font = [UIFont systemFontOfSize:15];
    _field.textColor = [UIColor labelColor];
    _field.placeholder = @"给它起个名字，比如「家」";
    _field.delegate = self;
    _field.returnKeyType = UIReturnKeyDone;
    _field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _field.leftViewMode = UITextFieldViewModeAlways;
    _field.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _field.rightViewMode = UITextFieldViewModeAlways;
    _field.text = _existing.name;
    _field.layer.cornerRadius = 11;
    _field.layer.cornerCurve = kCACornerCurveContinuous;
    _field.layer.borderWidth = 1.5;
    _field.layer.borderColor = SLFavAccent().CGColor;
    [_field.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:_field];

    UIButton *cancel = [self sl_filledButton:@"取消" bg:SLFavChipBg() fg:[UIColor colorWithWhite:0.37 alpha:1]];
    [cancel addTarget:self action:@selector(sl_close) forControlEvents:UIControlEventTouchUpInside];

    UIButton *save = [self sl_filledButton:@"保存" bg:SLFavAccent() fg:[UIColor whiteColor]];
    [save addTarget:self action:@selector(sl_save) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[cancel, save]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.distribution = UIStackViewDistributionFillEqually;
    [row.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:row];

    if (_existing) {
        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        [del setTitle:@"取消收藏" forState:UIControlStateNormal];
        [del setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        del.titleLabel.font = [UIFont systemFontOfSize:14];
        [del addTarget:self action:@selector(sl_delete) forControlEvents:UIControlEventTouchUpInside];
        [del.heightAnchor constraintEqualToConstant:36].active = YES;
        [stack addArrangedSubview:del];
    }

    UILayoutGuide *g = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_card.widthAnchor constraintEqualToConstant:316],
        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-20],
    ]];

    _centerY = [_card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor];
    _centerY.active = YES;

    // 卡片上不能超过安全区
    NSLayoutConstraint *top = [_card.topAnchor constraintGreaterThanOrEqualToAnchor:g.topAnchor constant:16];
    top.active = YES;
}

- (UIButton *)sl_pill:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    UIFont *font = [UIFont systemFontOfSize:13];
    b.titleLabel.font = font;
    b.layer.cornerRadius = 16;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    // contentEdgeInsets 在 iOS 15 起标记废弃（配合 UIButtonConfiguration 时被忽略），
    // 这里直接按文字宽度 + 左右留白算宽度，绕开这个属性。
    CGSize ts = [title sizeWithAttributes:@{NSFontAttributeName: font}];
    [b.widthAnchor constraintEqualToConstant:ceil(ts.width) + 32].active = YES;
    [b.heightAnchor constraintEqualToConstant:32].active = YES;
    [self sl_refreshPill:b selected:NO];
    return b;
}

- (void)sl_refreshPill:(UIButton *)b selected:(BOOL)sel {
    b.backgroundColor = sel ? [UIColor colorWithRed:0.902 green:0.945 blue:0.984 alpha:1.0] : SLFavChipBg();
    [b setTitleColor:sel ? [UIColor colorWithRed:0.094 green:0.373 blue:0.647 alpha:1.0]
                       : [UIColor colorWithWhite:0.37 alpha:1]
             forState:UIControlStateNormal];
}

- (UIButton *)sl_filledButton:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = bg;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 12;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    return b;
}

- (void)sl_pillTap:(UIButton *)sender {
    NSString *t = [sender titleForState:UIControlStateNormal];
    BOOL custom = [t isEqualToString:@"自定义"];
    for (UIButton *b in _pills) [self sl_refreshPill:b selected:(b == sender)];
    if (custom) {
        _field.text = @"";
        [_field becomeFirstResponder];
    } else {
        _field.text = t;
        [_field resignFirstResponder];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self sl_save];
    return YES;
}

- (void)sl_save {
    NSString *n = [_field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (n.length == 0) {
        n = _address.length ? _address : [NSString stringWithFormat:@"%.5f, %.5f", _coord.latitude, _coord.longitude];
    }
    void (^cb)(NSString *) = _onSave;
    [self sl_close];
    if (cb) cb(n);
}

- (void)sl_delete {
    void (^cb)(void) = _onDelete;
    [self sl_close];
    if (cb) cb();
}

- (void)sl_animateIn {
    _card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    _card.alpha = 0;
    self.alpha = 0;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.alpha = 1;
        self->_card.transform = CGAffineTransformIdentity;
        self->_card.alpha = 1;
    } completion:nil];
}

- (void)sl_close {
    [_field resignFirstResponder];
    [UIView animateWithDuration:0.16 animations:^{
        self.alpha = 0;
    } completion:^(BOOL f) {
        [self removeFromSuperview];
    }];
    // 延迟一拍再移除，避免移除瞬间正在收键盘导致闪一下
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self removeFromSuperview];
    });
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (t && ![t.view isDescendantOfView:_card]) [self sl_close];
}

- (void)sl_observeKeyboard {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sl_keyboard:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_field becomeFirstResponder];
    });
}

- (void)sl_keyboard:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inSelf = [self convertRect:kb fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.bounds) - CGRectGetMinY(inSelf);
    CGFloat dy = overlap > 0 ? -(overlap / 2.0) : 0;
    _centerY.constant = dy;
    [UIView animateWithDuration:0.22 animations:^{ [self layoutIfNeeded]; }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

#pragma mark - 列表 cell

@interface SLFavoriteCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *iconBox;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UIImageView *star;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *addrLabel;
@property (nonatomic, strong) UILabel *distLabel;
@property (nonatomic, strong) UILabel *badge;
@property (nonatomic, strong) UIImageView *chev;
@end

@implementation SLFavoriteCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = SLGlassCellColor();   // v0.4.50：白卡 → 玻璃片，深色下不再一块白
    _card.layer.cornerRadius = 18;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderWidth = 1;
    _card.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    [self.contentView addSubview:_card];

    _iconBox = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBox.layer.cornerRadius = 13;
    _iconBox.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_iconBox];

    _star = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"star.fill"]];
    _star.tintColor = SLFavGold();
    _star.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBox addSubview:_star];

    _dot = [[UIView alloc] initWithFrame:CGRectZero];
    _dot.backgroundColor = SLFavAccent();
    _dot.layer.cornerRadius = 8;
    _dot.hidden = YES;
    [_iconBox addSubview:_dot];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [_card addSubview:_nameLabel];

    _addrLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _addrLabel.font = [UIFont systemFontOfSize:12.5];
    _addrLabel.textColor = [UIColor secondaryLabelColor];
    _addrLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_card addSubview:_addrLabel];

    _distLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _distLabel.font = [UIFont systemFontOfSize:12];
    _distLabel.textColor = [UIColor tertiaryLabelColor];
    _distLabel.textAlignment = NSTextAlignmentRight;
    [_card addSubview:_distLabel];

    _badge = [[UILabel alloc] initWithFrame:CGRectZero];
    _badge.font = [UIFont systemFontOfSize:12];
    _badge.textAlignment = NSTextAlignmentCenter;
    _badge.textColor = [UIColor colorWithRed:0.094 green:0.373 blue:0.647 alpha:1.0];
    _badge.backgroundColor = [UIColor colorWithRed:0.902 green:0.945 blue:0.984 alpha:1.0];
    _badge.layer.cornerRadius = 13;
    _badge.layer.masksToBounds = YES;
    _badge.hidden = YES;
    [_card addSubview:_badge];

    _chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chev.tintColor = [UIColor colorWithWhite:0.83 alpha:1];
    _chev.contentMode = UIViewContentModeScaleAspectFit;
    [_card addSubview:_chev];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    _card.frame = CGRectMake(16, 6, w - 32, 84);
    _iconBox.frame = CGRectMake(16, 20, 44, 44);
    _star.frame = CGRectMake(10, 10, 24, 24);
    _dot.frame = CGRectMake(14, 14, 16, 16);

    CGFloat right = _card.bounds.size.width - 16;
    if (_badge.hidden) {
        _chev.frame = CGRectMake(right - 7, 36, 7, 12);
        _distLabel.frame = CGRectMake(right - 92, 20, 75, 18);
        _distLabel.hidden = NO;
    } else {
        _chev.frame = CGRectZero;
        _distLabel.frame = CGRectZero;
        _distLabel.hidden = YES;
        _badge.frame = CGRectMake(right - 74, 21, 74, 26);
    }

    CGFloat textRight = (_badge.hidden ? right - 16 : right - 82);
    _nameLabel.frame = CGRectMake(72, 20, textRight - 72, 21);
    _addrLabel.frame = CGRectMake(72, 44, textRight - 72, 18);
}

- (void)sl_configureName:(NSString *)name
                   addr:(NSString *)addr
                   dist:(NSString *)dist
                current:(BOOL)isCurrent {
    _nameLabel.text = name;
    _addrLabel.text = addr;
    _distLabel.text = dist;
    _dot.hidden = !isCurrent;
    _star.hidden = isCurrent;
    _badge.hidden = !isCurrent;
    _badge.text = isCurrent ? @"使用中" : nil;
    _iconBox.backgroundColor = isCurrent ? [UIColor colorWithRed:0.902 green:0.945 blue:0.984 alpha:1.0]
                                         : SLFavGoldBg();
    _nameLabel.textColor = isCurrent ? [UIColor colorWithRed:0.094 green:0.373 blue:0.647 alpha:1.0]
                                     : [UIColor labelColor];
    _card.layer.borderWidth = isCurrent ? 1.5 : 1;
    _card.layer.borderColor = isCurrent ? [UIColor colorWithRed:0.710 green:0.831 blue:0.957 alpha:1.0].CGColor
                                        : [UIColor colorWithWhite:0 alpha:0.06].CGColor;
    [self setNeedsLayout];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    [UIView animateWithDuration:0.12 animations:^{
        self.card.backgroundColor = highlighted ? [UIColor colorWithWhite:0.96 alpha:1] : SLGlassCellColor();
    }];
}

@end

#pragma mark - 列表页

@interface SLFavoriteController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, copy) NSArray<SLFavoriteItem *> *items;
// v0.4.50：定义在 viewDidLoad 之后，先声明免得 -Werror 因「方法未找到」中断构建
- (void)sl_toggleEdit;
@end

@implementation SLFavoriteController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"收藏的位置";
    // v0.4.50：跟设置页统一 —— 毛玻璃底 + 胶囊标题 + 胶囊「编辑 / 完成」
    self.navigationItem.titleView = SLPillTitleView(@"收藏的位置");
    SLInstallPillBack(self);   // v0.4.53：返回键胶囊
    SLInstallGlassBackdrop(self.view);
    self.view.backgroundColor = SLFavPageBg();
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"编辑", self, @selector(sl_toggleEdit));

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 96;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.backgroundColor = SLFavPageBg();
    _table.contentInset = UIEdgeInsetsMake(4, 0, 24, 0);
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_table];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sl_reload)
                                                 name:SLFavoriteStoreChanged
                                               object:nil];
    [self sl_reload];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.table.frame = self.view.bounds;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)sl_hasCurrent {
    return [SLVirtualLocation hasCoordinate];
}

- (void)sl_reload {
    self.items = [SLFavoriteStore items];
    [self.table reloadData];
    [self sl_updateEmpty];
    // v0.4.50：胶囊按钮是 customView，barButtonItem.enabled 管不到它，得直接控按钮本身
    BOOL has = self.items.count > 0;
    UIView *right = self.navigationItem.rightBarButtonItem.customView;
    right.userInteractionEnabled = has;
    right.alpha = has ? 1.0 : 0.45;
}

// v0.4.50：替换系统的 editButtonItem —— 系统那颗是蓝字，跟胶囊按钮不搭，
// 自己维护「编辑 / 完成」两态，点完重建一次按钮。
- (void)sl_toggleEdit {
    BOOL on = !self.table.editing;
    [self.table setEditing:on animated:YES];
    self.navigationItem.rightBarButtonItem = SLPillBarItem(on ? @"完成" : @"编辑", self, @selector(sl_toggleEdit));
}

- (void)sl_updateEmpty {
    if (self.items.count > 0) {
        self.table.backgroundView = nil;
        return;
    }
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:13.5];
    l.textColor = [UIColor secondaryLabelColor];
    l.text = @"还没有收藏的位置\n在选点页点右下角的星标就能收藏";
    self.table.backgroundView = l;
}

- (CLLocationCoordinate2D)sl_refCoord {
    if ([SLVirtualLocation hasCoordinate]) return [SLVirtualLocation coordinate];
    return kCLLocationCoordinate2DInvalid;
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [self sl_hasCurrent] ? 1 : 0;
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slfav";
    SLFavoriteCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[SLFavoriteCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];

    if (ip.section == 0) {
        CLLocationCoordinate2D c = [SLVirtualLocation coordinate];
        [cell sl_configureName:@"当前虚拟坐标"
                          addr:[NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude]
                          dist:@""
                       current:YES];
        return cell;
    }

    SLFavoriteItem *it = self.items[(NSUInteger)ip.row];
    NSString *dist = [it distanceTextFrom:[self sl_refCoord]];
    [cell sl_configureName:it.name
                      addr:it.address.length ? it.address : it.coordText
                      dist:dist
                   current:NO];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.editing) return;

    CLLocationCoordinate2D c;
    NSString *name = nil;
    if (ip.section == 0) {
        c = [SLVirtualLocation coordinate];
        name = @"当前虚拟坐标";
    } else {
        SLFavoriteItem *it = self.items[(NSUInteger)ip.row];
        c = it.coordinate;
        name = it.name;
    }
    SLLog(@"VLOC 收藏夹选中 %@ %.6f,%.6f", name ?: @"", c.latitude, c.longitude);
    if (self.onPick) self.onPick(c, name);
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1;
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete || ip.section != 1) return;
    SLFavoriteItem *it = self.items[(NSUInteger)ip.row];
    SLLog(@"VLOC 收藏删除 %@", it.name);
    [SLFavoriteStore removeItem:it];
}

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1 && self.items.count > 1;
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.section != 1 || to.section != 1) return;
    [SLFavoriteStore moveFrom:(NSUInteger)from.row to:(NSUInteger)to.row];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 1 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tv shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)ip {
    return NO;
}

@end
