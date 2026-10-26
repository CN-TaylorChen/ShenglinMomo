//
//  SLMapPickerController.m
//  地图选点页：悬浮搜索胶囊 + 水滴定位针 + 底部悬浮卡片 + 收藏
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

// 面板内容高度（不含底部安全区）
static const CGFloat kSLPanelBody = 210;

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
@property (nonatomic, strong) UIButton *copyBtn;
@property (nonatomic, strong) UIButton *confirmBtn;
@property (nonatomic, strong) UIButton *starBtn;
@property (nonatomic, strong) UIButton *tuneBtn;

@property (nonatomic, strong) UIView *resultCard;
@property (nonatomic, strong) UITableView *resultTable;

@property (nonatomic, copy) NSArray<MKMapItem *> *results;
@property (nonatomic, strong) MKLocalSearch *search;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, assign) NSUInteger geocodeToken;
@property (nonatomic, copy) NSString *placeName;
@property (nonatomic, copy) NSString *placeShort;

@property (nonatomic, assign) CLLocationCoordinate2D initialCoord;
@property (nonatomic, assign) BOOL hasInitial;

- (void)sl_buildMap;
- (void)sl_buildPin;
- (void)sl_buildSearch;
- (void)sl_buildPanel;
- (void)sl_buildResult;
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
    [self sl_buildResult];

    CLLocationCoordinate2D start = self.hasInitial ? self.initialCoord : kSLDefaultCenter;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(start, 3000, 3000) animated:NO];
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
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self sl_refreshStar];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeBottom = 0, safeTop = 0;
    if (@available(iOS 11.0, *)) {
        safeBottom = self.view.safeAreaInsets.bottom;
        safeTop = self.view.safeAreaInsets.top;
    }

    CGFloat panelH = kSLPanelBody + safeBottom;
    CGFloat panelY = h - panelH - 12;

    // 地图铺到卡片上沿：这样 mapView.centerCoordinate 就是「针尖真正压住的点」
    self.mapView.frame = CGRectMake(0, 0, w, panelY);
    self.pinView.center = CGPointMake(w / 2.0, panelY / 2.0);

    // 搜索胶囊
    CGFloat capsuleY = safeTop + 6;
    self.searchCapsule.frame = CGRectMake(16, capsuleY, w - 32, 48);
    CGFloat capW = self.searchCapsule.bounds.size.width;
    self.searchIcon.frame = CGRectMake(14, 14, 20, 20);
    self.locateBtn.frame = CGRectMake(capW - 8 - 30, 9, 30, 30);
    self.bookmarkBtn.frame = CGRectMake(capW - 8 - 30 - 6 - 30, 9, 30, 30);
    CGFloat fieldX = 42;
    self.searchField.frame = CGRectMake(fieldX, 0, self.bookmarkBtn.frame.origin.x - 8 - fieldX, 48);

    // 搜索结果卡
    self.resultCard.frame = CGRectMake(16, capsuleY + 48 + 8, w - 32,
                                       MIN(232, panelY - (capsuleY + 48 + 8) - 12));
    self.resultTable.frame = self.resultCard.bounds;

    // 底部卡片
    self.panel.frame = CGRectMake(12, panelY, w - 24, panelH);
    CGFloat pw = self.panel.bounds.size.width;
    CGFloat pad = 16;
    CGFloat side = 52, gap = 10;
    CGFloat mainW = pw - pad * 2 - side * 2 - gap * 2;

    self.grabber.frame = CGRectMake(pw / 2 - 18, 12, 36, 5);
    self.iconBadge.frame = CGRectMake(pad, 28, 40, 40);
    self.iconGlyph.frame = CGRectMake(9, 9, 22, 22);
    self.nameLabel.frame = CGRectMake(68, 28, pw - 68 - pad, 22);
    self.subLabel.frame = CGRectMake(68, 52, pw - 68 - pad, 18);
    self.coordChip.frame = CGRectMake(pad, 78, 216, 32);
    self.coordLabel.frame = CGRectMake(10, 0, 216 - 10 - 46, 32);
    self.copyBtn.frame = CGRectMake(216 - 46, 0, 42, 32);

    self.confirmBtn.frame = CGRectMake(pad, 126, mainW, 50);
    self.starBtn.frame = CGRectMake(pad + mainW + gap, 126, side, 50);
    self.tuneBtn.frame = CGRectMake(pad + mainW + gap * 2 + side, 126, side, 50);
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
    cap.backgroundColor = [UIColor whiteColor];
    cap.layer.cornerRadius = 24;
    cap.layer.cornerCurve = kCACornerCurveContinuous;
    cap.layer.borderWidth = 1;
    cap.layer.borderColor = SLHairline().CGColor;
    cap.layer.shadowColor = [UIColor blackColor].CGColor;
    cap.layer.shadowOpacity = 0.10;
    cap.layer.shadowRadius = 14;
    cap.layer.shadowOffset = CGSizeMake(0, 6);
    self.searchCapsule = cap;
    [self.view addSubview:cap];

    self.searchIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    self.searchIcon.tintColor = [UIColor tertiaryLabelColor];
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
    self.locateBtn.backgroundColor = SLChipBg();
    self.locateBtn.layer.cornerRadius = 15;
    [self.locateBtn setImage:[UIImage systemImageNamed:@"location"] forState:UIControlStateNormal];
    self.locateBtn.tintColor = [UIColor colorWithWhite:0.37 alpha:1];
    self.locateBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.locateBtn addTarget:self action:@selector(sl_locate) forControlEvents:UIControlEventTouchUpInside];
    [cap addSubview:self.locateBtn];
}

- (void)sl_buildPanel {
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [UIColor whiteColor];
    panel.layer.cornerRadius = 26;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = SLHairline().CGColor;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.10;
    panel.layer.shadowRadius = 20;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    self.panel = panel;
    [self.view addSubview:panel];

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

    self.copyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    [self.copyBtn setTitleColor:SLAccent() forState:UIControlStateNormal];
    self.copyBtn.titleLabel.font = [UIFont systemFontOfSize:12.5];
    [self.copyBtn addTarget:self action:@selector(sl_copyCoord) forControlEvents:UIControlEventTouchUpInside];
    [self.coordChip addSubview:self.copyBtn];

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

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    [self sl_refreshCoordinate];
    // 拖动过程中会连续回调，节流后再去反查地址，避免 CLGeocoder 被刷爆（苹果对它有频率限制）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_reverseGeocode) object:nil];
    [self performSelector:@selector(sl_reverseGeocode) withObject:nil afterDelay:0.6];
}

- (void)sl_refreshCoordinate {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    self.coordLabel.text = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
    self.subLabel.text = [self sl_subtitleText];
    [self sl_refreshStar];
}

- (CLLocationCoordinate2D)sl_refCoord {
    if ([SLVirtualLocation hasCoordinate]) return [SLVirtualLocation coordinate];
    return kCLLocationCoordinate2DInvalid;
}

- (NSString *)sl_subtitleText {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
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
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    SLFavoriteItem *near = [SLFavoriteStore itemNear:c within:300];
    self.starBtn.selected = (near != nil);
    self.starBtn.backgroundColor = near ? SLGoldBg() : SLChipBg();
    self.starBtn.tintColor = near ? SLGold() : [UIColor colorWithWhite:0.37 alpha:1];
}

- (void)sl_reverseGeocode {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
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
    NSString *q = [self.searchField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) {
        self.results = @[];
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
    req.region = MKCoordinateRegionMakeWithDistance(self.mapView.centerCoordinate, 120000, 120000);
    self.search = [[MKLocalSearch alloc] initWithRequest:req];

    __weak typeof(self) ws = self;
    [self.search startWithCompletionHandler:^(MKLocalSearchResponse *resp, NSError *err) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        if (err || resp.mapItems.count == 0) {
            self.results = @[];
            [self.resultTable reloadData];
            [self sl_showResults:NO];
            SLLog(@"VLOC 搜索「%@」无结果 %@", q, err.localizedDescription ?: @"");
            return;
        }
        self.results = resp.mapItems;
        [self.resultTable reloadData];
        [self sl_showResults:YES];
        SLLog(@"VLOC 搜索「%@」命中 %lu 条", q, (unsigned long)self.results.count);
    }];
}

- (void)sl_showResults:(BOOL)show {
    self.resultCard.hidden = !show;
    if (!show) [self.searchField resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slmapresult";
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
    MKMapItem *it = self.results[(NSUInteger)ip.row];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(it.placemark.coordinate, 1500, 1500) animated:YES];
    self.placeName = [self sl_nameOfPlacemark:it.placemark];
    self.placeShort = [self sl_shortOfPlacemark:it.placemark];
    self.nameLabel.text = self.placeName.length ? self.placeName : @"已选位置";
    self.subLabel.text = [self sl_subtitleText];
    [self sl_showResults:NO];
    [self.searchField resignFirstResponder];
}

#pragma mark - 收藏

- (void)sl_starTap {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
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
        SLLog(@"VLOC 收藏%s「%@」%.6f,%.6f", added ? "新增" : "更新", name, c.latitude, c.longitude);
        [self sl_toast:added ? [NSString stringWithFormat:@"已收藏「%@」", name]
                             : [NSString stringWithFormat:@"已更新「%@」", name]];
    } onDelete:^{
        __strong typeof(ws) self = ws;
        if (!self) return;
        if (near) [SLFavoriteStore removeItem:near];
        [self sl_refreshStar];
        [self sl_refreshCoordinate];
        [self sl_toast:@"已取消收藏"];
    }];
}

- (void)sl_openFavorites {
    SLFavoriteController *vc = [[SLFavoriteController alloc] init];
    __weak typeof(self) ws = self;
    vc.onPick = ^(CLLocationCoordinate2D coord, NSString *name) {
        __strong typeof(ws) self = ws;
        if (!self) return;
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coord, 1200, 1200) animated:YES];
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
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(c, 1200, 1200) animated:YES];
}

- (void)sl_tune {
    CLLocationCoordinate2D cur = self.mapView.centerCoordinate;
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
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(c, 1200, 1200) animated:YES];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sl_copyCoord {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    NSString *s = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
    [UIPasteboard generalPasteboard].string = s;
    [self sl_toast:@"坐标已复制"];
}

- (void)sl_confirm {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    if (!CLLocationCoordinate2DIsValid(c)) {
        [self sl_toast:@"坐标无效，请重新选择"];
        return;
    }
    SLLog(@"VLOC 选定 %.6f,%.6f %@", c.latitude, c.longitude, self.placeName ?: @"");
    if (self.onPick) self.onPick(c, self.placeName);
    [self.navigationController popViewControllerAnimated:YES];
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

@end
