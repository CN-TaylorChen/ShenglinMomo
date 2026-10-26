//
//  SLMapPickerController.m
//  地图选点页：中间十字准星取 mapView.centerCoordinate，顶部搜索框走 MKLocalSearch
//
//  为什么用 frame 而不是自动布局：陌陌的导航控制器会改写 additionalSafeAreaInsets，
//  自动布局在这里算出来的底部高度会随键盘弹出抖动；frame 一次算准，省掉一类问题。
//

#import "SLMapPickerController.h"
#import <MapKit/MapKit.h>
#import "SLLog.h"

// 没有历史坐标时的落点：北京天安门。只是个起始视野，用户一搜就会跳走。
static const CLLocationCoordinate2D kSLDefaultCenter = {39.90870, 116.39750};

@interface SLMapPickerController () <MKMapViewDelegate, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UIView *pinView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *resultTable;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *coordLabel;
@property (nonatomic, strong) UIButton *confirmBtn;

@property (nonatomic, copy) NSArray<MKMapItem *> *results;
@property (nonatomic, strong) MKLocalSearch *search;
@property (nonatomic, strong) CLGeocoder *geocoder;
@property (nonatomic, assign) NSUInteger geocodeToken;
@property (nonatomic, copy) NSString *placeName;

@property (nonatomic, assign) CLLocationCoordinate2D initialCoord;
@property (nonatomic, assign) BOOL hasInitial;

- (void)sl_buildMap;
- (void)sl_buildSearch;
- (void)sl_buildPanel;
- (void)sl_buildResultTable;
- (void)sl_refreshCoordinateLabels;
- (void)sl_reverseGeocode;
- (NSString *)sl_nameOfPlacemark:(CLPlacemark *)p;
- (void)sl_runSearch;
- (void)sl_confirm;
- (void)sl_cancel;
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
    self.title = @"选择位置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.results = @[];

    [self sl_buildMap];
    [self sl_buildSearch];
    [self sl_buildPanel];
    [self sl_buildResultTable];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(sl_cancel)];

    CLLocationCoordinate2D start = self.hasInitial ? self.initialCoord : kSLDefaultCenter;
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(start, 3000, 3000) animated:NO];
    [self sl_refreshCoordinateLabels];
    SLLog(@"VLOC 选点页打开 起点 %.6f,%.6f", start.latitude, start.longitude);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat safeBottom = 0;
    CGFloat safeTop = 0;
    if (@available(iOS 11.0, *)) {
        safeBottom = self.view.safeAreaInsets.bottom;
        safeTop = self.view.safeAreaInsets.top;
    }
    CGFloat panelH = 128 + safeBottom;

    // 地图铺到面板上沿：这样 mapView.centerCoordinate 就是「十字准星真正压住的点」，
    // 不用另外做 contentInset 补偿，拖动到哪里就是哪里。
    self.mapView.frame = CGRectMake(0, 0, w, h - panelH);
    self.pinView.center = CGPointMake(w / 2.0, (h - panelH) / 2.0);
    self.searchBar.frame = CGRectMake(0, safeTop, w, 52);
    self.resultTable.frame = CGRectMake(0, safeTop + 52, w, h - panelH - safeTop - 52);
    self.panel.frame = CGRectMake(0, h - panelH, w, panelH);

    CGFloat pad = 16;
    self.nameLabel.frame = CGRectMake(pad, 12, w - pad * 2, 20);
    self.coordLabel.frame = CGRectMake(pad, 36, w - pad * 2, 18);
    self.confirmBtn.frame = CGRectMake(pad, 64, w - pad * 2, 46);
}

- (void)sl_buildMap {
    self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.showsCompass = YES;
    self.mapView.showsScale = NO;
    self.mapView.showsUserLocation = NO;   // 开着会走系统定位，而系统定位可能已被虚拟坐标接管，容易看混
    self.mapView.rotateEnabled = NO;
    self.mapView.pitchEnabled = NO;
    [self.view addSubview:self.mapView];

    // 十字准星：固定在屏幕中心，地图在下面滑动
    CGFloat s = 26;
    UIView *pin = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s, s)];
    pin.userInteractionEnabled = NO;
    CAShapeLayer *dot = [CAShapeLayer layer];
    dot.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(s / 2 - 5, s / 2 - 5, 10, 10)].CGPath;
    dot.fillColor = [UIColor systemBlueColor].CGColor;
    dot.strokeColor = [UIColor whiteColor].CGColor;
    dot.lineWidth = 2.5;
    [pin.layer addSublayer:dot];
    CAShapeLayer *shadow = [CAShapeLayer layer];
    shadow.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(s / 2 - 7, s / 2 - 7, 14, 14)].CGPath;
    shadow.fillColor = [UIColor colorWithWhite:0 alpha:0.18].CGColor;
    [pin.layer insertSublayer:shadow below:dot];
    self.pinView = pin;
    [self.view addSubview:pin];
}

- (void)sl_buildSearch {
    UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectZero];
    sb.delegate = self;
    sb.placeholder = @"搜索地点，例如「上海外滩」";
    sb.searchBarStyle = UISearchBarStyleMinimal;
    sb.backgroundColor = [UIColor systemBackgroundColor];
    sb.translucent = NO;
    self.searchBar = sb;
    [self.view addSubview:sb];
}

- (void)sl_buildPanel {
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [UIColor systemBackgroundColor];
    self.panel = panel;
    [self.view addSubview:panel];

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 0.5)];
    line.backgroundColor = [UIColor separatorColor];
    line.tag = 9001;
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:line];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    name.textColor = [UIColor labelColor];
    name.text = @"拖动地图选择位置";
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nameLabel = name;
    [panel addSubview:name];

    UILabel *coord = [[UILabel alloc] initWithFrame:CGRectZero];
    coord.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    coord.textColor = [UIColor secondaryLabelColor];
    self.coordLabel = coord;
    [panel addSubview:coord];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.backgroundColor = [UIColor systemBlueColor];
    [btn setTitle:@"使用此位置" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    btn.layer.cornerRadius = 10;
    [btn addTarget:self action:@selector(sl_confirm) forControlEvents:UIControlEventTouchUpInside];
    self.confirmBtn = btn;
    [panel addSubview:btn];
}

- (void)sl_buildResultTable {
    UITableView *tb = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tb.dataSource = self;
    tb.delegate = self;
    tb.rowHeight = 52;
    tb.hidden = YES;
    tb.backgroundColor = [UIColor systemBackgroundColor];
    tb.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.resultTable = tb;
    [self.view addSubview:tb];
}

#pragma mark - 坐标 / 地址

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    [self sl_refreshCoordinateLabels];
    // 拖动过程中会连续回调，节流后再去反查地址，避免 CLGeocoder 被刷爆（苹果对它有频率限制）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_reverseGeocode) object:nil];
    [self performSelector:@selector(sl_reverseGeocode) withObject:nil afterDelay:0.6];
}

- (void)sl_refreshCoordinateLabels {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    self.coordLabel.text = [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
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
        if (name.length) {
            self.placeName = name;
            self.nameLabel.text = name;
        } else {
            self.placeName = nil;
            self.nameLabel.text = @"已选位置";
        }
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

#pragma mark - 搜索

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [searchBar setShowsCancelButton:NO animated:YES];
    self.resultTable.hidden = YES;
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self sl_runSearch];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_runSearch) object:nil];
    if (searchText.length == 0) {
        self.results = @[];
        [self.resultTable reloadData];
        self.resultTable.hidden = YES;
        return;
    }
    [self performSelector:@selector(sl_runSearch) withObject:nil afterDelay:0.35];
}

- (void)sl_runSearch {
    NSString *q = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
            self.resultTable.hidden = YES;
            SLLog(@"VLOC 搜索「%@」无结果 %@", q, err.localizedDescription ?: @"");
            return;
        }
        self.results = resp.mapItems;
        [self.resultTable reloadData];
        self.resultTable.hidden = NO;
        SLLog(@"VLOC 搜索「%@」命中 %lu 条", q, (unsigned long)self.results.count);
    }];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"slmapresult";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    MKMapItem *it = self.results[ip.row];
    cell.textLabel.text = it.name;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.text = [self sl_nameOfPlacemark:it.placemark];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MKMapItem *it = self.results[ip.row];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(it.placemark.coordinate, 1500, 1500) animated:YES];
    self.placeName = it.name;
    self.nameLabel.text = it.name.length ? it.name : @"已选位置";
    self.resultTable.hidden = YES;
    [self.searchBar resignFirstResponder];
    [self.searchBar setShowsCancelButton:NO animated:YES];
}

#pragma mark - 确认 / 取消

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

- (void)sl_cancel {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)sl_toast:(NSString *)text {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
