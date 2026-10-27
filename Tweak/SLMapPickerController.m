//
//  SLMapPickerController.m
//  地图选点页：悬浮搜索胶囊 + 水滴定位针 + 底部悬浮卡片（含快捷位置）+ 收藏
//
//  v0.4.26 版式改造：
//    1) 地图铺满整屏（含安全区），卡片浮在它上面 —— 原来地图只铺到卡片上沿、
//       卡片又留 12pt 缝，中间那条会露出页面底色，看着像地图断了一截
//    2) 卡片左右各内缩 8pt、统一 18 圆角、0.5pt 描边，贴屏幕底
//    3) 高度按内容自适应（原来写死 210，内容排完还剩一大块空白）
//    4) 新增「快捷位置」行：收藏过的位置一点即达
//    5) 针尖改成落在「可视区中心」—— 地图全屏后屏幕中心会被卡片挡住
//
//  为什么用 frame 而不是自动布局：陌陌的导航控制器会改写 additionalSafeAreaInsets，
//  自动布局在这里算出来的底部高度会随键盘弹出抖动；frame 一次算准，省掉一类问题。
//
//  导航栏：本页把导航栏设成透明，让地图整屏铺开，返回按钮仍然用系统的（不自己造）。
//  必须在 viewWillDisappear 里恢复默认外观，否则 push 进来的收藏页会跟着变透明。
//

#import "SLMapPickerController.h"
#import "SLFavoriteController.h"
#import "SLVirtualLocation.h"
#import <MapKit/MapKit.h>
#import "SLLog.h"

// 没有历史坐标时的落点：北京天安门。只是个起始视野，用户一搜就会跳走。
static const CLLocationCoordinate2D kSLDefaultCenter = {39.90870, 116.39750};

// 卡片版式（v0.4.26 起高度按内容算，不再写死）
static const CGFloat kSLPanelInset = 8;      // 卡片左右内缩
static const CGFloat kSLPanelPad = 16;       // 卡片内容左右内边距
static const CGFloat kSLQuickTop = 112;      // 快捷位置行（坐标芯片下沿 102 + 10）
static const CGFloat kSLQuickH = 34;
static const CGFloat kSLPinTipOffset = 23;   // 水滴尖端相对 pinView 中心的 y 偏移（58 - 35）
static const CGFloat kSLPanelFloat = 16;     // 卡片整体上浮的间距，不再沉到屏幕最底

static UIColor *SLAccent(void) {
    return [UIColor colorWithRed:0.216 green:0.541 blue:0.867 alpha:1.0];
}
static UIColor *SLGold(void) {
    return [UIColor colorWithRed:0.729 green:0.459 blue:0.090 alpha:1.0];
}
static UIColor *SLGoldBg(void) {
    return [UIColor colorWithRed:0.980 green:0.933 blue:0.855 alpha:1.0];
}
static UIColor *SLChipBg(void) {
    return [UIColor colorWithRed:0.945 green:0.937 blue:0.910 alpha:1.0];
}
static UIColor *SLHairline(void) {
    return [UIColor colorWithWhite:0 alpha:0.06];
}

@interface SLMapPickerController () <MKMapViewDelegate, UITextFieldDelegate,
                                    UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UIView *pinView;

@property (nonatomic, strong) UIView *searchCapsule;
@property (nonatomic, strong) UIImageView *searchIcon;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UIButton *bookmarkBtn;
@property (nonatomic, strong) UIButton *locateBtn;

@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *grabber;
@property (nonatomic, strong) UIView *iconBadge;
@property (nonatomic, strong) UIImageView *iconGlyph;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIView *coordChip;
@property (nonatomic, strong) UILabel *coordLabel;
@property (nonatomic, strong) UIButton *coordCopyBtn;
@property (nonatomic, strong) UIButton *confirmBtn;
@property (nonatomic, strong) UIButton *starBtn;
@property (nonatomic, strong) UIButton *tuneBtn;
@property (nonatomic, strong) UIView *brandView;

@property (nonatomic, strong) UIScrollView *quickRow;      // 快捷位置（收藏过的点）
@property (nonatomic, copy) NSArray<SLFavoriteItem *> *quickItems;
@property (nonatomic, strong) UIView *resultCard;
@property (nonatomic, strong) UITableView *resultTable;

// v0.4.26：针尖位置与地图中心的换算状态
@property (nonatomic, assign) BOOL pinLayoutReady;          // 针尖位置是否已算好（布局前不能换坐标）
@property (nonatomic, assign) BOOL slAdjusting;             // 正在做偏移修正，regionDidChange 不要反查地址
@property (nonatomic, assign) CGFloat lastPinTipY;          // 上次布局的针尖 y，用来判断卡片高度是否变了
@property (nonatomic, assign) CLLocationCoordinate2D pendingFocus;   // 首帧布局后要落到的坐标
@property (nonatomic, assign) BOOL hasPendingFocus;

@property (nonatomic, copy) NSArray<MKMapItem *> *results;
// v0.4.19：无结果时不再收键盘，改成卡片里显示一行提示
@property (nonatomic, assign) BOOL emptyHint;
@property (nonatomic, strong) MKLocalSearch *search;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, assign) NSUInteger geocodeToken;
@property (nonatomic, copy) NSString *placeName;
@property (nonatomic, copy) NSString *placeShort;

@property (nonatomic, assign) CLLocationCoordinate2D initialCoord;
@property (nonatomic, assign) BOOL hasInitial;

// 快捷位置：家 / 公司 / 学校 / 最近 四个等宽槽（v0.4.28 起铺满整行）
@property (nonatomic, copy) NSArray<NSString *> *slSlotNames;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *slSlotValid;
@property (nonatomic, strong) NSMutableArray<NSValue *> *slSlotCoords;
@property (nonatomic, copy) NSArray<NSArray<SLFavoriteItem *> *> *slSlotItems;

// 快捷位置多选面板（自绘，替代 UIAlertController 的 action sheet）
@property (nonatomic, strong) UIView *slSheetOverlay;
@property (nonatomic, copy) NSArray<SLFavoriteItem *> *slSheetItems;
@property (nonatomic, copy) NSString *slSheetSlot;

- (void)sl_buildMap;
- (void)sl_buildPin;
- (void)sl_buildSearch;
- (void)sl_buildPanel;
- (void)sl_buildResult;
- (void)sl_buildQuick;
- (void)sl_buildBrand;
- (UILabel *)sl_capLabel:(NSString *)text;
- (void)sl_reloadQuick;
- (CLLocationCoordinate2D)sl_currentCoord;
- (CGPoint)sl_pinTipPoint;
- (void)sl_alignPinToCoord:(CLLocationCoordinate2D)coord;
- (void)sl_focusCoord:(CLLocationCoordinate2D)coord meters:(double)meters;
- (void)sl_quickSlotTap:(UIButton *)btn;
- (void)sl_showSlotSheet:(NSString *)slot items:(NSArray<SLFavoriteItem *> *)items;
- (void)sl_sheetRowTap:(UIButton *)btn;
- (void)sl_hideSlotSheet;
- (void)sl_hideSlotSheetAnimated:(BOOL)animated;
- (void)sl_refreshCoordinate;
- (void)sl_refreshStar;
- (CLLocationCoordinate2D)sl_refCoord;
- (void)sl_reverseGeocode;
- (NSString *)sl_nameOfPlacemark:(CLPlacemark *)p;
- (NSString *)sl_shortOfPlacemark:(CLPlacemark *)p;
- (NSString *)sl_subtitleText;
- (void)sl_runSearch;
- (void)sl_searchTextChanged;
- (void)sl_showResults:(BOOL)show;
- (void)sl_confirm;
- (void)sl_starTap;
- (void)sl_openFavorites;
- (void)sl_locate;
- (void)sl_tune;
- (void)sl_copyCoord;
- (void)sl_toast:(NSString *)text;

@end

@implementation SLMapPickerController

- (instancetype)initWithCoordinate:(CLLocationCoordinate2D)coord hasInitial:(BOOL)hasInitial {
    self = [super init];
    if (self) {
        _initialCoord = coord;
        _hasInitial = hasInitial;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"";
    self.results = @[];

    [self sl_buildMap];
    [self sl_buildPin];
    [self sl_buildSearch];
    [self sl_buildPanel];
    [self sl_buildQuick];
    [self sl_buildResult];
    [self sl_buildBrand];
    // 先把快捷位置排出来，第一帧的卡片高度就是最终高度，避免进场后「长高」一下
    [self sl_reloadQuick];

    CLLocationCoordinate2D start = self.hasInitial ? self.initialCoord : kSLDefaultCenter;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(start, 3000, 3000) animated:NO];
    self.pendingFocus = start;
    self.hasPendingFocus = YES;
    [self sl_refreshCoordinate];
    SLLog(@"VLOC 选点页打开 起点 %.6f,%.6f 收藏 %lu 条",
          start.latitude, start.longitude, (unsigned long)[SLFavoriteStore count]);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationBar *nb = self.navigationController.navigationBar;
    if (!nb) return;
    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    nb.standardAppearance = ap;
    nb.scrollEdgeAppearance = ap;
    nb.tintColor = [UIColor labelColor];
    self.navigationItem.title = @"";
    self.navigationItem.titleView = self.brandView;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    UINavigationBar *nb = self.navigationController.navigationBar;
    if (!nb) return;
    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithDefaultBackground];
    nb.standardAppearance = ap;
    nb.scrollEdgeAppearance = ap;
    nb.tintColor = nil;
    self.navigationItem.title = @"";
    self.navigationItem.titleView = nil;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self sl_refreshStar];
    // 从收藏页返回后收藏可能变了，重排一次快捷位置（顺带重算卡片高度）
    [self sl_reloadQuick];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    CGFloat safeBottom = 0, safeTop = 0;
    if (@available(iOS 11.0, *)) {
        safeBottom = self.view.safeAreaInsets.bottom;
        safeTop = self.view.safeAreaInsets.top;
    }

    // 1) 地图铺满整屏（含安全区）。原来只铺到卡片上沿、卡片又留 12pt 缝，
    //    中间那条会露出页面底色（陌陌主题下是透明/灰白），看着像地图断了一截。
    self.mapView.frame = CGRectMake(0, 0, w, h);

    // 2) 卡片：左右内缩 8，整体上浮一截（不再沉到屏幕最底）；高度按内容算（有快捷位置行就多一行）
    BOOL hasQuick = !self.quickRow.hidden;
    CGFloat btnY = hasQuick ? (kSLQuickTop + kSLQuickH + 10) : (kSLQuickTop - 8);
    CGFloat bodyH = btnY + 50 + 12;
    CGFloat panelH = bodyH + safeBottom;
    CGFloat panelY = h - panelH - kSLPanelFloat;

    self.panel.frame = CGRectMake(kSLPanelInset, panelY, w - kSLPanelInset * 2, panelH);
    // 面板是透明底 + 毛玻璃子视图，阴影只能靠 shadowPath 描出轮廓
    self.panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.panel.bounds
                                                             cornerRadius:26].CGPath;
    CGFloat pw = self.panel.bounds.size.width;
    CGFloat pad = kSLPanelPad;

    CGFloat side = 50, gap = 8;
    CGFloat mainW = pw - pad * 2 - side * 2 - gap * 2;

    self.grabber.frame = CGRectMake(pw / 2 - 18, 10, 36, 5);
    self.iconBadge.frame = CGRectMake(pad, 24, 40, 40);
    self.iconGlyph.frame = CGRectMake(9, 9, 22, 22);
    self.nameLabel.frame = CGRectMake(68, 22, pw - 68 - pad, 21);
    self.subLabel.frame = CGRectMake(68, 45, pw - 68 - pad, 17);

    CGFloat chipW = pw - pad * 2;              // 经纬度整行铺满，右侧放「复制」
    self.coordChip.frame = CGRectMake(pad, 70, chipW, 32);
    self.coordLabel.frame = CGRectMake(10, 0, chipW - 10 - 46, 32);
    self.coordCopyBtn.frame = CGRectMake(chipW - 46, 0, 42, 32);

    self.quickRow.frame = CGRectMake(pad, kSLQuickTop, pw - pad * 2, kSLQuickH);
    [self sl_layoutQuick];

    self.confirmBtn.frame = CGRectMake(pad, btnY, mainW, 50);
    self.starBtn.frame = CGRectMake(pad + mainW + gap, btnY, side, 50);
    self.tuneBtn.frame = CGRectMake(pad + mainW + gap * 2 + side, btnY, side, 50);

    // 3) 搜索胶囊（下移，给顶部品牌胶囊让位）
    CGFloat capsuleY = safeTop + 50;
    self.searchCapsule.frame = CGRectMake(16, capsuleY, w - 32, 48);
    CGFloat capW = self.searchCapsule.bounds.size.width;
    self.searchIcon.frame = CGRectMake(14, 14, 20, 20);
    self.locateBtn.frame = CGRectMake(capW - 8 - 30, 9, 30, 30);
    self.bookmarkBtn.frame = CGRectMake(capW - 8 - 30 - 6 - 30, 9, 30, 30);
    CGFloat fieldX = 42;
    self.searchField.frame = CGRectMake(fieldX, 0, self.bookmarkBtn.frame.origin.x - 8 - fieldX, 48);

    // 4) 搜索结果卡
    self.resultCard.frame = CGRectMake(16, capsuleY + 48 + 8, w - 32,
                                       MIN(232, panelY - (capsuleY + 48 + 8) - 12));
    self.resultTable.frame = self.resultCard.bounds;

    // 5) 针尖落在「搜索栏下沿 ~ 卡片上沿」这段可视区的中心，不再是屏幕中心
    //    （地图全屏后屏幕中心会被卡片挡住，针就藏在卡片后面了）
    CLLocationCoordinate2D keep = [self sl_currentCoord];   // 先用旧针位算出当前坐标
    CGFloat visTop = capsuleY + 48 + 6;
    CGFloat visBottom = panelY - 12;
    CGFloat tipY = (visTop + visBottom) / 2.0;
    self.pinView.center = CGPointMake(w / 2.0, tipY - kSLPinTipOffset);

    BOOL hadPin = self.pinLayoutReady;
    self.pinLayoutReady = YES;
    if (!hadPin) {
        if (self.hasPendingFocus) {
            self.hasPendingFocus = NO;
            [self sl_focusCoord:self.pendingFocus meters:3000];
        }
    } else if (fabs(self.lastPinTipY - tipY) > 0.5) {
        // 卡片高度变了（快捷位置行出现 / 消失），针尖跟着移动 —— 把原坐标锚回针下，
        // 否则用户会觉得「什么都没动，坐标却变了」。
        [self sl_alignPinToCoord:keep];
    }
    self.lastPinTipY = tipY;
}

#pragma mark - 构建

- (void)sl_buildMap {
    self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.showsCompass = YES;
    self.mapView.showsScale = NO;
    self.mapView.showsUserLocation = NO;   // 开着会走系统定位，而系统定位可能已被虚拟坐标接管，容易看混
    self.mapView.rotateEnabled = NO;
    self.mapView.pitchEnabled = NO;
    [self.view addSubview:self.mapView];
}

- (void)sl_buildPin {
    // 水滴针，尖端落在 (24,58)；view 高 70，中心点对齐地图中心
    UIView *pin = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48, 70)];
    pin.userInteractionEnabled = NO;

    CAShapeLayer *ground = [CAShapeLayer layer];
    ground.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(11, 57, 26, 8)].CGPath;
    ground.fillColor = [UIColor colorWithWhite:0 alpha:0.16].CGColor;
    [pin.layer addSublayer:ground];

    UIBezierPath *drop = [UIBezierPath bezierPath];
    [drop moveToPoint:CGPointMake(24, 58)];
    [drop addCurveToPoint:CGPointMake(6, 22) controlPoint1:CGPointMake(24, 58) controlPoint2:CGPointMake(6, 34)];
    [drop addArcWithCenter:CGPointMake(24, 22) radius:18 startAngle:M_PI endAngle:0 clockwise:YES];
    [drop addCurveToPoint:CGPointMake(24, 58) controlPoint1:CGPointMake(42, 34) controlPoint2:CGPointMake(24, 58)];
    [drop closePath];

    CAShapeLayer *body = [CAShapeLayer layer];
    body.path = drop.CGPath;
    body.fillColor = SLAccent().CGColor;
    body.strokeColor = [UIColor whiteColor].CGColor;
    body.lineWidth = 3;
    [pin.layer addSublayer:body];

    CAShapeLayer *hole = [CAShapeLayer layer];
    hole.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(18, 16, 12, 12)].CGPath;
    hole.fillColor = [UIColor whiteColor].CGColor;
    [pin.layer addSublayer:hole];

    self.pinView = pin;
    [self.view addSubview:pin];
}

- (void)sl_buildSearch {
    UIView *cap = [[UIView alloc] initWithFrame:CGRectZero];
    cap.backgroundColor = [UIColor clearColor];
    cap.layer.cornerRadius = 24;
    cap.layer.cornerCurve = kCACornerCurveContinuous;
    cap.layer.borderWidth = 1;
    cap.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    cap.layer.shadowColor = [UIColor blackColor].CGColor;
    cap.layer.shadowOpacity = 0.12;
    cap.layer.shadowRadius = 16;
    cap.layer.shadowOffset = CGSizeMake(0, 6);
    self.searchCapsule = cap;
    [self.view addSubview:cap];

    // 毛玻璃底板：半透明磨砂，浮在地图上像原生搜索栏
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.layer.cornerRadius = 24;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.masksToBounds = YES;
    blur.frame = cap.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [cap addSubview:blur];

    self.searchIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    self.searchIcon.tintColor = SLAccent();
    self.searchIcon.contentMode = UIViewContentModeScaleAspectFit;
    [cap addSubview:self.searchIcon];

    self.searchField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.searchField.font = [UIFont systemFontOfSize:15];
    self.searchField.placeholder = @"搜索地点、街道或地标";
    self.searchField.delegate = self;
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchField.textColor = [UIColor labelColor];
    [self.searchField addTarget:self action:@selector(sl_searchTextChanged)
               forControlEvents:UIControlEventEditingChanged];
    [cap addSubview:self.searchField];

    self.bookmarkBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.bookmarkBtn.backgroundColor = SLGoldBg();
    self.bookmarkBtn.layer.cornerRadius = 15;
    [self.bookmarkBtn setImage:[UIImage systemImageNamed:@"bookmark"] forState:UIControlStateNormal];
    self.bookmarkBtn.tintColor = SLGold();
    self.bookmarkBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.bookmarkBtn addTarget:self action:@selector(sl_openFavorites) forControlEvents:UIControlEventTouchUpInside];
    [cap addSubview:self.bookmarkBtn];

    self.locateBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.locateBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.locateBtn.layer.cornerRadius = 15;
    [self.locateBtn setImage:[UIImage systemImageNamed:@"location"] forState:UIControlStateNormal];
    self.locateBtn.tintColor = [UIColor colorWithWhite:0.37 alpha:1];
    self.locateBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.locateBtn addTarget:self action:@selector(sl_locate) forControlEvents:UIControlEventTouchUpInside];
    [cap addSubview:self.locateBtn];
}

- (void)sl_buildPanel {
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [UIColor clearColor];   // 底色交给下面的毛玻璃
    panel.layer.cornerRadius = 26;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.borderWidth = 0.5;
    panel.layer.borderColor = SLHairline().CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.12;
    panel.layer.shadowRadius = 22;
    panel.layer.shadowOffset = CGSizeMake(0, 10);
    self.panel = panel;
    [self.view addSubview:panel];

    // 毛玻璃底（v0.4.32）：放最底层，后面所有子视图都盖在它上面。
    // 面板本身是 clear 色，阴影靠 viewDidLayoutSubviews 里设的 shadowPath 撑起来。
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    glass.frame = panel.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.layer.cornerRadius = 26;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;
    glass.userInteractionEnabled = NO;
    [panel addSubview:glass];

    self.grabber = [[UIView alloc] initWithFrame:CGRectZero];
    self.grabber.backgroundColor = [UIColor colorWithWhite:0.83 alpha:1];
    self.grabber.layer.cornerRadius = 2.5;
    [panel addSubview:self.grabber];

    self.iconBadge = [[UIView alloc] initWithFrame:CGRectZero];
    self.iconBadge.backgroundColor = [UIColor colorWithRed:0.902 green:0.945 blue:0.984 alpha:1.0];
    self.iconBadge.layer.cornerRadius = 12;
    self.iconBadge.layer.cornerCurve = kCACornerCurveContinuous;
    [panel addSubview:self.iconBadge];

    self.iconGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mappin.circle.fill"]];
    self.iconGlyph.tintColor = SLAccent();
    self.iconGlyph.contentMode = UIViewContentModeScaleAspectFit;
    [self.iconBadge addSubview:self.iconGlyph];

    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.text = @"拖动地图选择位置";
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [panel addSubview:self.nameLabel];

    self.subLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subLabel.font = [UIFont systemFontOfSize:12.5];
    self.subLabel.textColor = [UIColor secondaryLabelColor];
    self.subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [panel addSubview:self.subLabel];

    self.coordChip = [[UIView alloc] initWithFrame:CGRectZero];
    self.coordChip.backgroundColor = SLChipBg();
    self.coordChip.layer.cornerRadius = 9;
    self.coordChip.layer.cornerCurve = kCACornerCurveContinuous;
    [panel addSubview:self.coordChip];

    self.coordLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.coordLabel.textColor = [UIColor colorWithWhite:0.37 alpha:1];
    self.coordLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.coordChip addSubview:self.coordLabel];

    self.coordCopyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.coordCopyBtn setTitle:@"复制" forState:UIControlStateNormal];
    [self.coordCopyBtn setTitleColor:SLAccent() forState:UIControlStateNormal];
    self.coordCopyBtn.titleLabel.font = [UIFont systemFontOfSize:12.5];
    [self.coordCopyBtn addTarget:self action:@selector(sl_copyCoord) forControlEvents:UIControlEventTouchUpInside];
    [self.coordChip addSubview:self.coordCopyBtn];

    self.confirmBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.confirmBtn.backgroundColor = SLAccent();
    [self.confirmBtn setTitle:@"使用此位置" forState:UIControlStateNormal];
    [self.confirmBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.confirmBtn.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightMedium];
    self.confirmBtn.layer.cornerRadius = 14;
    self.confirmBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [self.confirmBtn addTarget:self action:@selector(sl_confirm) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.confirmBtn];

    self.starBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.starBtn.backgroundColor = SLChipBg();
    self.starBtn.layer.cornerRadius = 14;
    self.starBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [self.starBtn setImage:[UIImage systemImageNamed:@"star"] forState:UIControlStateNormal];
    [self.starBtn setImage:[UIImage systemImageNamed:@"star.fill"] forState:UIControlStateSelected];
    self.starBtn.tintColor = [UIColor colorWithWhite:0.37 alpha:1];
    [self.starBtn addTarget:self action:@selector(sl_starTap) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.starBtn];

    self.tuneBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.tuneBtn.backgroundColor = SLChipBg();
    self.tuneBtn.layer.cornerRadius = 14;
    self.tuneBtn.layer.cornerCurve = kCACornerCurveContinuous;
    [self.tuneBtn setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    self.tuneBtn.tintColor = [UIColor colorWithWhite:0.37 alpha:1];
    [self.tuneBtn addTarget:self action:@selector(sl_tune) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.tuneBtn];

}

- (void)sl_buildResult {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 1;
    card.layer.borderColor = SLHairline().CGColor;
    card.layer.masksToBounds = YES;
    card.hidden = YES;
    self.resultCard = card;
    [self.view addSubview:card];

    UITableView *tb = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tb.dataSource = self;
    tb.delegate = self;
    tb.rowHeight = 54;
    tb.separatorInset = UIEdgeInsetsMake(0, 72, 0, 16);
    tb.separatorColor = SLChipBg();
    tb.contentInset = UIEdgeInsetsMake(8, 0, 8, 0);
    tb.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.resultTable = tb;
    [card addSubview:tb];
}

#pragma mark - 坐标 / 地址

// 针尖（水滴尖端）在 self.view 里的位置。pinView 高 70，尖端在局部 y=58、中心在 y=35。
- (CGPoint)sl_pinTipPoint {
    return CGPointMake(self.pinView.center.x, self.pinView.center.y + kSLPinTipOffset);
}

// 当前选中点 = 针尖压住的那个点。
// v0.4.26：地图铺满整屏后屏幕中心 ≠ 针尖位置，不能再用 mapView.centerCoordinate。
- (CLLocationCoordinate2D)sl_currentCoord {
    if (!self.pinLayoutReady) return self.mapView.centerCoordinate;
    CLLocationCoordinate2D c = [self.mapView convertPoint:[self sl_pinTipPoint] toCoordinateFromView:self.view];
    return CLLocationCoordinate2DIsValid(c) ? c : self.mapView.centerCoordinate;
}

// 只调中心，让 coord 正好落在针尖下，不改缩放。
// 做法：看针尖处当前是什么坐标，把差值加到地图中心上；迭代两次（远距离时经纬度线性近似有误差，二次基本收敛）。
- (void)sl_alignPinToCoord:(CLLocationCoordinate2D)coord {
    if (!self.pinLayoutReady || !CLLocationCoordinate2DIsValid(coord)) return;
    CGPoint tip = [self sl_pinTipPoint];
    self.slAdjusting = YES;
    for (int i = 0; i < 2; i++) {
        CLLocationCoordinate2D atPin = [self.mapView convertPoint:tip toCoordinateFromView:self.view];
        if (!CLLocationCoordinate2DIsValid(atPin)) break;
        double dLat = coord.latitude - atPin.latitude;
        double dLng = coord.longitude - atPin.longitude;
        if (fabs(dLat) < 1e-9 && fabs(dLng) < 1e-9) break;
        CLLocationCoordinate2D c0 = self.mapView.centerCoordinate;
        CLLocationCoordinate2D next = CLLocationCoordinate2DMake(c0.latitude + dLat, c0.longitude + dLng);
        if (!CLLocationCoordinate2DIsValid(next)) break;
        [self.mapView setCenterCoordinate:next animated:NO];
    }
    self.slAdjusting = NO;
}

// 把某个坐标搬到针尖下（必要时连带缩放）
- (void)sl_focusCoord:(CLLocationCoordinate2D)coord meters:(double)meters {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    if (meters < 200) meters = 200;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coord, meters, meters) animated:NO];
    [self sl_alignPinToCoord:coord];
}

#pragma mark - 快捷位置

- (void)sl_buildQuick {
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectZero];
    sv.showsHorizontalScrollIndicator = NO;
    sv.showsVerticalScrollIndicator = NO;
    sv.alwaysBounceHorizontal = NO;
    sv.hidden = NO;          // v0.4.28 起常驻：家/公司/学校/最近 四个等宽槽铺满整行
    self.quickRow = sv;
    [self.panel addSubview:sv];
    self.slSlotNames = @[@"家", @"公司", @"学校", @"最近"];
}

- (void)sl_reloadQuick {
    for (UIView *v in [self.quickRow.subviews copy]) [v removeFromSuperview];
    if (!self.slSlotNames) self.slSlotNames = @[@"家", @"公司", @"学校", @"最近"];

    NSArray<SLFavoriteItem *> *all = [SLFavoriteStore items];
    NSMutableArray *valid = [NSMutableArray array];
    NSMutableArray *coords = [NSMutableArray array];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in self.slSlotNames) {
        CLLocationCoordinate2D c = kCLLocationCoordinate2DInvalid;
        BOOL ok = NO;
        NSMutableArray *hit = [NSMutableArray array];
        if ([name isEqualToString:@"最近"]) {
            if ([SLVirtualLocation hasCoordinate]) { c = [SLVirtualLocation coordinate]; ok = YES; }
        } else {
            NSString *low = [name lowercaseString];
            for (SLFavoriteItem *it in all) {
                NSString *fn = [it.name lowercaseString];
                if (fn.length && ([fn containsString:low] || [low containsString:fn])) {
                    [hit addObject:it];
                    if (!ok) { c = it.coordinate; ok = YES; }
                }
            }
        }
        [items addObject:hit];
        [valid addObject:@(ok)];
        [coords addObject:[NSValue valueWithMKCoordinate:ok ? c : kCLLocationCoordinate2DInvalid]];
    }
    self.slSlotItems = items;
    self.slSlotValid = valid;
    self.slSlotCoords = coords;

    UIFont *f = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    for (NSInteger i = 0; i < (NSInteger)self.slSlotNames.count; i++) {
        BOOL on = [valid[i] boolValue];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        b.backgroundColor = on ? SLGoldBg() : SLChipBg();
        b.layer.cornerRadius = kSLQuickH / 2.0;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        [b addTarget:self action:@selector(sl_quickSlotTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.quickRow addSubview:b];

        // 名字用独立 label（不用 button title）：这样名字和角标能当一个整体居中，
        // 角标也能完整待在 chip 里面 —— v0.4.31 的角标挂在 y=-6，被 quickRow 上边界裁掉了一半。
        UILabel *nm = [[UILabel alloc] initWithFrame:CGRectZero];
        nm.tag = 201;
        nm.font = f;
        nm.textAlignment = NSTextAlignmentCenter;
        nm.text = self.slSlotNames[i];
        nm.textColor = on ? SLGold() : [UIColor colorWithWhite:0.45 alpha:1];
        nm.userInteractionEnabled = NO;
        [b addSubview:nm];

        NSArray *hit = items[i];
        if (hit.count > 1) {
            UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
            badge.tag = 99;
            badge.backgroundColor = [UIColor colorWithRed:0.84 green:0.23 blue:0.23 alpha:1];
            badge.textColor = [UIColor whiteColor];
            badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
            badge.textAlignment = NSTextAlignmentCenter;
            badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)hit.count];
            badge.layer.cornerRadius = 8;
            badge.layer.masksToBounds = YES;
            badge.layer.borderWidth = 1.5;
            badge.layer.borderColor = (on ? SLGoldBg() : SLChipBg()).CGColor;
            badge.userInteractionEnabled = NO;
            [b addSubview:badge];
        }
    }
    if (self.quickRow.bounds.size.width > 0) [self sl_layoutQuick];
    else [self.view setNeedsLayout];
}

- (void)sl_layoutQuick {
    CGFloat rowW = self.quickRow.bounds.size.width;
    if (rowW <= 0) return;
    NSArray *btns = self.quickRow.subviews;
    NSInteger n = (NSInteger)btns.count;
    if (n == 0) return;
    CGFloat gap = 8;
    CGFloat bw = (rowW - gap * (n - 1)) / (CGFloat)n;
    CGFloat x = 0;
    for (NSInteger i = 0; i < n; i++) {
        UIView *b = btns[i];
        [b setFrame:CGRectMake(x, 0, bw, kSLQuickH)];

        // 名字 + 角标当成一个整体在 chip 里水平居中，角标垂直居中、完整可见
        UILabel *nm = (UILabel *)[b viewWithTag:201];
        UILabel *badge = (UILabel *)[b viewWithTag:99];
        CGFloat nameW = 0;
        if (nm.text.length) {
            nameW = ceil([nm.text sizeWithAttributes:@{NSFontAttributeName: nm.font}].width);
        }
        CGFloat badgeH = 16.0;
        CGFloat badgeW = 0;
        if (badge.text.length) {
            CGFloat tw = ceil([badge.text sizeWithAttributes:@{NSFontAttributeName: badge.font}].width);
            badgeW = MAX(badgeH, tw + 9.0);
        }
        CGFloat inner = nameW + (badgeW > 0 ? (4.0 + badgeW) : 0.0);
        CGFloat sx = MAX(6.0, (bw - inner) / 2.0);
        nm.frame = CGRectMake(sx, 0, nameW, kSLQuickH);
        if (badgeW > 0) {
            badge.frame = CGRectMake(sx + nameW + 4.0, (kSLQuickH - badgeH) / 2.0, badgeW, badgeH);
        }
        x += bw + gap;
    }
    self.quickRow.contentSize = CGSizeMake(rowW, kSLQuickH);
}

- (void)sl_quickSlotTap:(UIButton *)btn {
    NSInteger i = btn.tag;
    if (i < 0 || i >= (NSInteger)self.slSlotNames.count) return;
    NSString *slot = self.slSlotNames[i];
    BOOL ok = (i < (NSInteger)self.slSlotValid.count) && [self.slSlotValid[i] boolValue];
    if (!ok) {
        [self sl_toast:[NSString stringWithFormat:@"未收藏「%@」", slot]];
        return;
    }
    if ([slot isEqualToString:@"最近"]) {
        CLLocationCoordinate2D c = [self.slSlotCoords[i] MKCoordinateValue];
        if (!CLLocationCoordinate2DIsValid(c)) return;
        [self sl_focusCoord:c meters:1200];
        self.placeShort = @"最近使用";
        [self sl_refreshCoordinate];
        [self sl_reverseGeocode];
        return;
    }
    NSArray *hit = (i < (NSInteger)self.slSlotItems.count) ? self.slSlotItems[i] : @[];
    CLLocationCoordinate2D c = [self.slSlotCoords[i] MKCoordinateValue];
    if (!CLLocationCoordinate2DIsValid(c)) return;
    if (hit.count <= 1) {
        [self sl_focusCoord:c meters:1200];
        self.placeShort = slot;
        [self sl_refreshCoordinate];
        [self sl_reverseGeocode];
        SLLog(@"VLOC 快捷位置「%@」%.6f,%.6f", slot, c.latitude, c.longitude);
        return;
    }
    [self sl_showSlotSheet:slot items:hit];
}

#pragma mark - 地址

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    [self sl_refreshCoordinate];
    // 自己在做针尖偏移修正时，这一串回调不代表用户拖动，不必反复反查地址
    if (self.slAdjusting) return;
    // 拖动过程中会连续回调，节流后再去反查地址，避免 CLGeocoder 被刷爆（苹果对它有频率限制）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_reverseGeocode) object:nil];
    [self performSelector:@selector(sl_reverseGeocode) withObject:nil afterDelay:0.6];
}

- (void)sl_refreshCoordinate {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    self.coordLabel.text = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
    self.subLabel.text = [self sl_subtitleText];
    [self sl_refreshStar];
}

- (CLLocationCoordinate2D)sl_refCoord {
    if ([SLVirtualLocation hasCoordinate]) return [SLVirtualLocation coordinate];
    return kCLLocationCoordinate2DInvalid;
}

- (NSString *)sl_subtitleText {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    CLLocationCoordinate2D ref = [self sl_refCoord];
    NSString *dist = @"";
    if (CLLocationCoordinate2DIsValid(ref)) {
        CLLocation *a = [[CLLocation alloc] initWithLatitude:ref.latitude longitude:ref.longitude];
        CLLocation *b = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
        double m = [b distanceFromLocation:a];
        dist = m < 1000 ? [NSString stringWithFormat:@"距此 %.0f 米", m]
                        : [NSString stringWithFormat:@"距此 %.1f 公里", m / 1000.0];
    }
    SLFavoriteItem *near = [SLFavoriteStore itemNear:c within:300];
    NSString *head = near.name.length ? near.name : self.placeShort;
    if (head.length && dist.length) return [NSString stringWithFormat:@"%@ · %@", head, dist];
    if (head.length) return head;
    return dist.length ? dist : @"拖动地图选择位置";
}

- (void)sl_refreshStar {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    SLFavoriteItem *near = [SLFavoriteStore itemNear:c within:300];
    self.starBtn.selected = (near != nil);
    self.starBtn.backgroundColor = near ? SLGoldBg() : SLChipBg();
    self.starBtn.tintColor = near ? SLGold() : [UIColor colorWithWhite:0.37 alpha:1];
}

- (void)sl_reverseGeocode {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    if (!CLLocationCoordinate2DIsValid(c)) return;
    if (!self.geocoder) self.geocoder = [[CLGeocoder alloc] init];
    if (self.geocoder.isGeocoding) [self.geocoder cancelGeocode];

    NSUInteger token = ++self.geocodeToken;
    CLLocation *loc = [[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude];
    __weak typeof(self) ws = self;
    [self.geocoder reverseGeocodeLocation:loc completionHandler:^(NSArray<CLPlacemark *> *pm, NSError *err) {
        __strong typeof(ws) self = ws;
        if (!self || token != self.geocodeToken) return;   // 结果过期（用户又拖了地图）直接丢弃
        CLPlacemark *p = pm.firstObject;
        NSString *name = [self sl_nameOfPlacemark:p];
        NSString *shortName = [self sl_shortOfPlacemark:p];
        self.placeName = name;
        self.placeShort = shortName;
        self.nameLabel.text = name.length ? name : @"已选位置";
        self.iconGlyph.image = [UIImage systemImageNamed:@"mappin.circle.fill"];
        self.subLabel.text = [self sl_subtitleText];
    }];
}

- (NSString *)sl_nameOfPlacemark:(CLPlacemark *)p {
    if (!p) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    // 逐级拼：省 → 市 → 区 → 路名，跳过重复和空值
    for (NSString *s in @[p.administrativeArea ?: @"", p.locality ?: @"", p.subLocality ?: @"", p.name ?: @""]) {
        if (s.length && ![parts containsObject:s]) [parts addObject:s];
    }
    return parts.count ? [parts componentsJoinedByString:@""] : nil;
}

- (NSString *)sl_shortOfPlacemark:(CLPlacemark *)p {
    if (!p) return nil;
    for (NSString *s in @[p.name ?: @"", p.subLocality ?: @"", p.locality ?: @""]) {
        if (s.length) return s;
    }
    return nil;
}

#pragma mark - 搜索

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    [self sl_runSearch];
    return YES;
}

- (void)sl_searchTextChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_runSearch) object:nil];
    NSString *raw = self.searchField.text ?: @"";
    // v0.4.19：把每次输入的内容和「是否处于组合态」都记下来。
    // 中文输不进去到底是「字没进来」还是「进来了但被收键盘打掉」，这条日志一眼就能分清。
    BOOL composing = (self.searchField.markedTextRange != nil);
    SLLog(@"VLOC 搜索输入 text=%@ len=%lu marked=%d",
          raw, (unsigned long)raw.length, composing ? 1 : 0);
    if (composing) return;   // 拼音还没上屏，不发查询、不动键盘

    NSString *q = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) {
        self.results = @[];
        self.emptyHint = NO;
        [self.resultTable reloadData];
        [self sl_showResults:NO];
        return;
    }
    [self performSelector:@selector(sl_runSearch) withObject:nil afterDelay:0.35];
}

- (void)sl_runSearch {
    NSString *q = [self.searchField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) return;

    [self.search cancel];
    MKLocalSearchRequest *req = [[MKLocalSearchRequest alloc] init];
    req.naturalLanguageQuery = q;
    // 限定在当前视野周边，否则搜「便利店」可能返回外地的同名 POI
    req.region = MKCoordinateRegionMakeWithDistance([self sl_currentCoord], 120000, 120000);
    self.search = [[MKLocalSearch alloc] initWithRequest:req];

    __weak typeof(self) ws = self;
    [self.search startWithCompletionHandler:^(MKLocalSearchResponse *resp, NSError *err) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        if (err || resp.mapItems.count == 0) {
            self.results = @[];
            // v0.4.19：没有结果也要留在卡片里显示一行，绝对不能收键盘
            self.emptyHint = YES;
            [self.resultTable reloadData];
            [self sl_showResults:YES];
            SLLog(@"VLOC 搜索「%@」无结果 %@", q, err.localizedDescription ?: @"");
            return;
        }
        self.results = resp.mapItems;
        self.emptyHint = NO;
        [self.resultTable reloadData];
        [self sl_showResults:YES];
        SLLog(@"VLOC 搜索「%@」命中 %lu 条", q, (unsigned long)self.results.count);
    }];
}

- (void)sl_showResults:(BOOL)show {
    self.resultCard.hidden = !show;
    // v0.4.19：这里原来会在「无结果」时 resignFirstResponder，导致中文组合到一半键盘就被收走、
    // 候选字永远上不了屏。收键盘只由用户动作触发（点结果、按搜索键、返回），不由搜索结果触发。
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.emptyHint ? 1 : self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slmapresult";
    if (self.emptyHint) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"slmapempty"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"slmapempty"];
            cell.backgroundColor = [UIColor clearColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:14];
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
            cell.textLabel.text = @"没有找到相关地点，换个词试试";
            cell.imageView.image = [[UIImage systemImageNamed:@"magnifyingglass"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            cell.imageView.tintColor = [UIColor tertiaryLabelColor];
        }
        return cell;
    }
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    MKMapItem *it = self.results[(NSUInteger)ip.row];
    UIImage *icon = [[UIImage systemImageNamed:@"mappin.circle.fill"]
                     imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    cell.imageView.image = icon;
    cell.imageView.tintColor = (ip.row == 0) ? SLAccent() : [UIColor colorWithWhite:0.7 alpha:1];
    cell.textLabel.text = it.name;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = [self sl_shortOfPlacemark:it.placemark];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    CLLocationCoordinate2D ref = [self sl_refCoord];
    if (CLLocationCoordinate2DIsValid(ref)) {
        CLLocation *a = [[CLLocation alloc] initWithLatitude:ref.latitude longitude:ref.longitude];
        CLLocation *b = [[CLLocation alloc] initWithLatitude:it.placemark.coordinate.latitude
                                                   longitude:it.placemark.coordinate.longitude];
        double m = [b distanceFromLocation:a];
        UILabel *dist = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 64, 20)];
        dist.font = [UIFont systemFontOfSize:12];
        dist.textAlignment = NSTextAlignmentRight;
        dist.textColor = [UIColor tertiaryLabelColor];
        dist.text = m < 1000 ? [NSString stringWithFormat:@"%.0f m", m]
                             : [NSString stringWithFormat:@"%.1f km", m / 1000.0];
        cell.accessoryView = dist;
    } else {
        cell.accessoryView = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.emptyHint || (NSUInteger)ip.row >= self.results.count) return;
    MKMapItem *it = self.results[(NSUInteger)ip.row];
    [self sl_focusCoord:it.placemark.coordinate meters:1500];
    self.placeName = [self sl_nameOfPlacemark:it.placemark];
    self.placeShort = [self sl_shortOfPlacemark:it.placemark];
    self.nameLabel.text = self.placeName.length ? self.placeName : @"已选位置";
    self.subLabel.text = [self sl_subtitleText];
    [self sl_showResults:NO];
    [self.searchField resignFirstResponder];
}

#pragma mark - 收藏

- (void)sl_starTap {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    if (!CLLocationCoordinate2DIsValid(c)) {
        [self sl_toast:@"坐标无效，请重新选择"];
        return;
    }
    SLFavoriteItem *near = [SLFavoriteStore itemNear:c within:300];
    NSString *addr = self.placeName ?: self.placeShort;
    __weak typeof(self) ws = self;

    [SLFavoriteEditor showWithCoordinate:c
                                 address:addr
                                existing:near
                                  onSave:^(NSString *name) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        BOOL added = [SLFavoriteStore saveName:name coordinate:c address:addr];
        [self sl_refreshStar];
        [self sl_refreshCoordinate];
        [self sl_reloadQuick];
        SLLog(@"VLOC 收藏%s「%@」%.6f,%.6f", added ? "新增" : "更新", name, c.latitude, c.longitude);
        [self sl_toast:added ? [NSString stringWithFormat:@"已收藏「%@」", name]
                             : [NSString stringWithFormat:@"已更新「%@」", name]];
    } onDelete:^{
        __strong typeof(ws) self = ws;
        if (!self) return;
        if (near) [SLFavoriteStore removeItem:near];
        [self sl_refreshStar];
        [self sl_refreshCoordinate];
        [self sl_reloadQuick];
        [self sl_toast:@"已取消收藏"];
    }];
}

- (void)sl_openFavorites {
    SLFavoriteController *vc = [[SLFavoriteController alloc] init];
    __weak typeof(self) ws = self;
    vc.onPick = ^(CLLocationCoordinate2D coord, NSString *name) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        [self sl_focusCoord:coord meters:1200];
        if (name.length) {
            self.placeShort = name;
            self.nameLabel.text = name;
        }
        [self sl_refreshCoordinate];
        [self sl_reverseGeocode];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 按钮

- (void)sl_locate {
    CLLocationCoordinate2D c = [self sl_refCoord];
    if (!CLLocationCoordinate2DIsValid(c)) c = self.hasInitial ? self.initialCoord : kSLDefaultCenter;
    [self sl_focusCoord:c meters:1200];
}

- (void)sl_tune {
    CLLocationCoordinate2D cur = [self sl_currentCoord];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"手动输入坐标"
                                                               message:@"纬度在前，经度在后"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"纬度，例如 31.240000";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.text = [NSString stringWithFormat:@"%.6f", cur.latitude];
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"经度，例如 121.490000";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.text = [NSString stringWithFormat:@"%.6f", cur.longitude];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"定位" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        double lat = [ac.textFields.firstObject.text doubleValue];
        double lng = [ac.textFields.lastObject.text doubleValue];
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake(lat, lng);
        if (!CLLocationCoordinate2DIsValid(c) || (lat == 0 && lng == 0)) {
            [self sl_toast:@"坐标无效"];
            return;
        }
        [self sl_focusCoord:c meters:1200];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sl_copyCoord {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    NSString *s = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
    [UIPasteboard generalPasteboard].string = s;
    [self sl_toast:@"坐标已复制"];
}

- (void)sl_confirm {
    CLLocationCoordinate2D c = [self sl_currentCoord];
    if (!CLLocationCoordinate2DIsValid(c)) {
        [self sl_toast:@"坐标无效，请重新选择"];
        return;
    }
    SLLog(@"VLOC 选定 %.6f,%.6f %@", c.latitude, c.longitude, self.placeName ?: @"");
    if (self.onPick) self.onPick(c, self.placeName);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)sl_showSlotSheet:(NSString *)slot items:(NSArray<SLFavoriteItem *> *)items {
    if (items.count == 0) return;
    [self sl_hideSlotSheetAnimated:NO];
    self.slSheetSlot = slot;
    self.slSheetItems = items;

    UIView *host = self.navigationController.view ?: self.view;   // 盖住导航栏，整屏压暗
    CGFloat W = host.bounds.size.width;
    CGFloat H = host.bounds.size.height;
    CGFloat side = 10.0;
    CGFloat cardW = W - side * 2.0;
    CGFloat rowH = 64.0;
    CGFloat headH = 64.0;
    CGFloat listH = MIN((CGFloat)items.count * rowH, H * 0.46);
    CGFloat cardH = headH + listH;
    CGFloat cancelH = 52.0;
    CGFloat gap = 8.0;
    CGFloat bottomGap = 14.0;
    if (@available(iOS 11.0, *)) bottomGap += self.view.safeAreaInsets.bottom;
    CGFloat totalH = cardH + gap + cancelH + bottomGap;
    CGFloat topY = H - totalH;

    UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.24];
    overlay.alpha = 0.0;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:overlay];
    self.slSheetOverlay = overlay;

    UIButton *backdrop = [UIButton buttonWithType:UIButtonTypeCustom];
    backdrop.frame = overlay.bounds;
    backdrop.backgroundColor = [UIColor clearColor];
    [backdrop addTarget:self action:@selector(sl_hideSlotSheet) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:backdrop];

    UIColor *tint = SLAccent();

    // 主卡片
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(side, topY, cardW, cardH)];
    card.tag = 301;
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.18;
    card.layer.shadowRadius = 24;
    card.layer.shadowOffset = CGSizeMake(0, 10);
    card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:card.bounds cornerRadius:22].CGPath;
    [overlay addSubview:card];

    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    glass.frame = card.bounds;
    glass.layer.cornerRadius = 22;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;
    glass.userInteractionEnabled = NO;
    [card addSubview:glass];

    UIView *grab = [[UIView alloc] initWithFrame:CGRectMake(cardW / 2.0 - 16, 8, 32, 5)];
    grab.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.45];
    grab.layer.cornerRadius = 2.5;
    [card addSubview:grab];

    UILabel *ttl = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, cardW, 20)];
    ttl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    ttl.textColor = [UIColor labelColor];
    ttl.textAlignment = NSTextAlignmentCenter;
    ttl.text = [NSString stringWithFormat:@"选择「%@」", slot];
    [card addSubview:ttl];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 43, cardW, 16)];
    sub.font = [UIFont systemFontOfSize:11.5];
    sub.textColor = [UIColor tertiaryLabelColor];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.text = [NSString stringWithFormat:@"共 %lu 个位置，点一个跳过去", (unsigned long)items.count];
    [card addSubview:sub];

    UIScrollView *list = [[UIScrollView alloc] initWithFrame:CGRectMake(0, headH, cardW, listH)];
    list.showsVerticalScrollIndicator = NO;
    list.alwaysBounceVertical = ((CGFloat)items.count * rowH > listH);
    list.backgroundColor = [UIColor clearColor];
    [card addSubview:list];

    CLLocationCoordinate2D ref = [self sl_currentCoord];
    CLLocation *a = [[CLLocation alloc] initWithLatitude:ref.latitude longitude:ref.longitude];
    CGFloat contentH = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        SLFavoriteItem *it = items[i];
        CGFloat y = (CGFloat)i * rowH;

        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(0, y, cardW, rowH);
        row.tag = (NSInteger)i;
        row.backgroundColor = [UIColor clearColor];
        [row addTarget:self action:@selector(sl_sheetRowTap:) forControlEvents:UIControlEventTouchUpInside];
        [list addSubview:row];

        UIView *ic = [[UIView alloc] initWithFrame:CGRectMake(14, (rowH - 34) / 2.0, 34, 34)];
        ic.backgroundColor = [tint colorWithAlphaComponent:0.11];
        ic.layer.cornerRadius = 11;
        ic.layer.cornerCurve = kCACornerCurveContinuous;
        ic.userInteractionEnabled = NO;
        [row addSubview:ic];

        UIImageView *g = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mappin"]];
        g.tintColor = tint;
        g.contentMode = UIViewContentModeScaleAspectFit;
        g.frame = CGRectMake(8, 8, 18, 18);
        [ic addSubview:g];

        UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(60, 12, cardW - 60 - 80, 20)];
        nm.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        nm.textColor = [UIColor labelColor];
        nm.text = it.name.length ? it.name : @"未命名";
        nm.lineBreakMode = NSLineBreakByTruncatingTail;
        nm.userInteractionEnabled = NO;
        [row addSubview:nm];

        UILabel *ad = [[UILabel alloc] initWithFrame:CGRectMake(60, 33, cardW - 60 - 80, 16)];
        ad.font = [UIFont systemFontOfSize:11.5];
        ad.textColor = [UIColor tertiaryLabelColor];
        ad.text = it.address.length ? it.address : @"未记录地址";
        ad.lineBreakMode = NSLineBreakByTruncatingTail;
        ad.userInteractionEnabled = NO;
        [row addSubview:ad];

        CLLocation *b = [[CLLocation alloc] initWithLatitude:it.coordinate.latitude
                                                  longitude:it.coordinate.longitude];
        double m = [b distanceFromLocation:a];
        UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 14 - 68, 0, 68, rowH)];
        dl.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        dl.textColor = [UIColor secondaryLabelColor];
        dl.textAlignment = NSTextAlignmentRight;
        dl.text = m < 1000 ? [NSString stringWithFormat:@"%.0f 米", m]
                           : [NSString stringWithFormat:@"%.1f 公里", m / 1000.0];
        dl.userInteractionEnabled = NO;
        [row addSubview:dl];

        if (i + 1 < items.count) {
            UIView *ln = [[UIView alloc] initWithFrame:CGRectMake(60, rowH - 0.5, cardW - 60 - 14, 0.5)];
            ln.backgroundColor = SLHairline();
            ln.userInteractionEnabled = NO;
            [row addSubview:ln];
        }
        contentH = y + rowH;
    }
    list.contentSize = CGSizeMake(cardW, contentH);

    // 取消：独立一个毛玻璃胶囊，和 iOS 的 action sheet 分层逻辑一致
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(side, topY + cardH + gap, cardW, cancelH);
    cancel.tag = 302;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cancel.layer.cornerRadius = 16;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    [cancel addTarget:self action:@selector(sl_hideSlotSheet) forControlEvents:UIControlEventTouchUpInside];
    [overlay addSubview:cancel];

    UIVisualEffectView *cglass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    cglass.frame = cancel.bounds;
    cglass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cglass.layer.cornerRadius = 16;
    cglass.layer.cornerCurve = kCACornerCurveContinuous;
    cglass.clipsToBounds = YES;
    cglass.userInteractionEnabled = NO;
    [cancel insertSubview:cglass atIndex:0];

    CGAffineTransform off = CGAffineTransformMakeTranslation(0, totalH + 24);
    card.transform = off;
    cancel.transform = off;
    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.25
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        overlay.alpha = 1.0;
        card.transform = CGAffineTransformIdentity;
        cancel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)sl_sheetRowTap:(UIButton *)btn {
    NSInteger i = btn.tag;
    if (i < 0 || i >= (NSInteger)self.slSheetItems.count) return;
    SLFavoriteItem *it = self.slSheetItems[(NSUInteger)i];
    NSString *slot = self.slSheetSlot;
    [self sl_hideSlotSheet];
    [self sl_focusCoord:it.coordinate meters:1200];
    self.placeShort = it.name;
    [self sl_refreshCoordinate];
    [self sl_reverseGeocode];
    SLLog(@"VLOC 快捷位置「%@」选「%@」%.6f,%.6f", slot, it.name, it.coordinate.latitude, it.coordinate.longitude);
}

- (void)sl_hideSlotSheet {
    [self sl_hideSlotSheetAnimated:YES];
}

- (void)sl_hideSlotSheetAnimated:(BOOL)animated {
    UIView *overlay = self.slSheetOverlay;
    if (!overlay) return;
    self.slSheetOverlay = nil;
    self.slSheetItems = nil;
    if (!animated) {
        [overlay removeFromSuperview];
        return;
    }
    UIView *card = [overlay viewWithTag:301];
    UIView *cancel = [overlay viewWithTag:302];
    CGFloat down = overlay.bounds.size.height;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        overlay.alpha = 0.0;
        card.transform = CGAffineTransformMakeTranslation(0, down);
        cancel.transform = CGAffineTransformMakeTranslation(0, down);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)sl_toast:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13.5];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 1;
    l.layer.cornerRadius = 18;
    l.layer.masksToBounds = YES;
    CGSize sz = [text sizeWithAttributes:@{NSFontAttributeName: l.font}];
    CGFloat w = sz.width + 36;
    CGFloat panelY = self.panel.frame.origin.y;
    CGFloat toastY = panelY > 160 ? panelY - 56 : self.view.bounds.size.height * 0.5;
    l.frame = CGRectMake((self.view.bounds.size.width - w) / 2, toastY, w, 36);
    l.alpha = 0;
    [self.view addSubview:l];
    [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.22 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f) { [l removeFromSuperview]; }];
    });
}

#pragma mark - 品牌 / 轨迹占位

- (void)sl_buildBrand {
    // 顶部导航栏品牌胶囊：定位针 + 「虚拟定位」（v0.4.28 起，不再显示「声临 陌陌版」）。
    // 白底蓝边，和整体蓝主色统一；底部卡片显示地点名，品牌不占底部空间。
    UIView *b = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 120, 30)];
    b.userInteractionEnabled = NO;
    b.backgroundColor = [UIColor whiteColor];
    b.layer.cornerRadius = 15;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 1;
    b.layer.borderColor = SLAccent().CGColor;
    UIImageView *g = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mappin.fill"]];
    g.tintColor = SLAccent();
    g.contentMode = UIViewContentModeScaleAspectFit;
    g.frame = CGRectMake(12, 7, 16, 16);
    [b addSubview:g];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(30, 0, 84, 30)];
    t.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    t.textColor = SLAccent();
    t.text = @"虚拟定位";
    [b addSubview:t];
    self.brandView = b;
}

- (UILabel *)sl_capLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = [UIFont systemFontOfSize:11];
    l.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    l.textAlignment = NSTextAlignmentCenter;
    l.text = text;
    return l;
}

@end
