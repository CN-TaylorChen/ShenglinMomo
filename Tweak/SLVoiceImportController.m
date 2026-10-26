// 声临 · Fish 音色导入（v0.4.9）

#import "SLVoiceImportController.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"

#define kSLFishModelURL @"https://api.fish.audio/model"

@interface SLVoiceImportController () <UISearchBarDelegate, UITextViewDelegate>
@property (nonatomic, assign) SLImportMode mode;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, strong) UITextView *pasteView;
@property (nonatomic, strong) UISegmentedControl *sourceSeg;
@end

@implementation SLVoiceImportController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"导入 Fish 音色";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.selected = [NSMutableSet set];
    self.items = @[];
    self.mode = self.initialMode;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"导入"
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(sl_doImport)];

    if (self.mode == SLImportModeMine) [self sl_fetchMine];
    [self sl_syncSearchBar];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.mode == SLImportModeSearch) [self.searchBar becomeFirstResponder];
}

#pragma mark - 搜索栏

- (void)sl_syncSearchBar {
    if (self.mode == SLImportModeSearch) {
        if (!self.searchBar) {
            UISearchBar *sb = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 52)];
            sb.placeholder = @"搜 Fish 公开音色，如：温柔 女声";
            sb.delegate = self;
            sb.showsCancelButton = NO;
            self.searchBar = sb;
        }
        self.tableView.tableHeaderView = self.searchBar;
    } else {
        self.tableView.tableHeaderView = nil;
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    self.searchText = searchBar.text ?: @"";
    [self sl_fetchSearch:self.searchText];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return 1;
    if (self.mode == SLImportModePaste) return 1;
    return MAX((NSInteger)self.items.count, 1);   // 空列表占一行显示状态
}

- (UISegmentedControl *)sourceSeg {
    if (!_sourceSeg) {
        _sourceSeg = [[UISegmentedControl alloc] initWithItems:@[@"我的音色", @"搜公开库", @"粘贴 JSON"]];
        _sourceSeg.selectedSegmentIndex = 0;
        [_sourceSeg addTarget:self action:@selector(sl_modeChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return _sourceSeg;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return nil;   // 卡片里只有一个控件，小标题多余
    if (self.mode == SLImportModePaste) return @"粘贴音色列表 JSON";
    if (self.mode == SLImportModeMine) {
        return self.items.count
            ? [NSString stringWithFormat:@"我的音色 · 共 %lu 个（默认全选）", (unsigned long)self.items.count]
            : @"我的音色";
    }
    return self.searchText.length ? [NSString stringWithFormat:@"搜索结果「%@」", self.searchText] : @"搜索结果";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv;
    if (section != 1) return nil;
    if (self.status.length) return self.status;
    if (self.mode == SLImportModePaste) {
        return @"支持 Fish 接口原样响应（{\"items\":[...]}）、纯数组，以及 {\"分类\":[...]} 结构；非 Fish 引擎条目会自动跳过";
    }
    return @"音色 ID 就是 Fish 的 reference_id；导入后出现在「我导入的音色」分区，不会和内置库混在一起";
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) return 52;   // 分段控件 32 + 上下各 10，不贴边
    if (ip.section == 1 && self.mode == SLImportModePaste) return 240;
    return 44;
}

- (UITextView *)pasteView {
    if (!_pasteView) {
        _pasteView = [[UITextView alloc] initWithFrame:CGRectZero];
        _pasteView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _pasteView.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _pasteView.autocorrectionType = UITextAutocorrectionTypeNo;
        _pasteView.delegate = self;
        _pasteView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        _pasteView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    }
    return _pasteView;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    AWECATTSManager *mgr = [AWECATTSManager shared];

    if (ip.section == 0) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"seg"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"seg"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor clearColor];
            cell.contentView.backgroundColor = [UIColor clearColor];
        }
        // v0.4.9.1：原来挂在 accessoryView 上，系统会把 accessoryView 强制靠右，
        // 分段控件贴着右边缘甚至溢出卡片。改成放进 contentView 用约束居中。
        UISegmentedControl *seg = self.sourceSeg;
        seg.selectedSegmentIndex = self.mode;
        if (seg.superview != cell.contentView) {
            [seg removeFromSuperview];
            seg.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:seg];
            [NSLayoutConstraint activateConstraints:@[
                [seg.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
                [seg.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [seg.heightAnchor constraintEqualToConstant:32],
            ]];
        }
        return cell;
    }

    if (self.mode == SLImportModePaste) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"text"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"text"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        self.pasteView.frame = CGRectMake(12, 8, tv.bounds.size.width - 64, 220);
        if (self.pasteView.superview != cell.contentView) [cell.contentView addSubview:self.pasteView];
        return cell;
    }

    if (!self.items.count) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"empty"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.textLabel.text = self.loading ? @"正在获取..." : (self.status.length ? self.status : @"点 ＋ 里的「粘贴 JSON」也可以导入");
        cell.accessoryView = nil;
        return cell;
    }

    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"row"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"row"];
    NSDictionary *v = self.items[ip.row];
    NSString *vid = v[@"voiceType"];
    NSString *name = v[@"name"];

    BOOL fav = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"AWECFishFavorites"] containsObject:vid];
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.text = fav ? [NSString stringWithFormat:@"★ %@", name] : name;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.text = vid;

    // 已有头像就用头像，否则用名字首字配色（与列表一致）
    UIImage *avatar = [mgr fishAvatarForVoiceID:vid];
    cell.imageView.image = avatar;
    cell.imageView.layer.cornerRadius = 18;
    cell.imageView.layer.masksToBounds = YES;

    cell.accessoryType = [self.selected containsObject:vid] ? UITableViewCellAccessoryCheckmark
                                                           : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1 || self.mode == SLImportModePaste || !self.items.count) return;
    NSString *vid = self.items[ip.row][@"voiceType"];
    if ([self.selected containsObject:vid]) [self.selected removeObject:vid];
    else [self.selected addObject:vid];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - 来源切换

- (void)sl_modeChanged:(UISegmentedControl *)seg {
    self.mode = (SLImportMode)seg.selectedSegmentIndex;
    self.items = @[];
    self.status = nil;
    self.searchText = @"";
    [self.selected removeAllObjects];
    [self sl_syncSearchBar];
    [self.tableView reloadData];
    if (self.mode == SLImportModeMine) {
        [self sl_fetchMine];
    } else if (self.mode == SLImportModeSearch) {
        [self.searchBar becomeFirstResponder];
    }
}

#pragma mark - 拉取

- (void)sl_fetchMine {
    [self sl_fetchWithQuery:nil selfOnly:YES];
}

- (void)sl_fetchSearch:(NSString *)query {
    [self sl_fetchWithQuery:query selfOnly:NO];
}

- (void)sl_fetchWithQuery:(NSString *)query selfOnly:(BOOL)selfOnly {
    NSString *key = [[AWECATTSManager shared].fishAPIKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!key.length) {
        self.status = @"还没填 Fish Audio Key，先去「API 凭证」里配置";
        [self.tableView reloadData];
        return;
    }

    NSMutableString *url = [NSMutableString stringWithFormat:@"%@?page_size=50&page_number=1", kSLFishModelURL];
    if (selfOnly) {
        [url appendString:@"&self=true"];
    } else {
        if (query.length) {
            NSString *enc = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            if (enc.length) [url appendFormat:@"&title=%@", enc];
        }
        [url appendString:@"&sort_by=task_count"];
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 30;
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];

    self.loading = YES;
    self.status = nil;
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSArray *parsed = @[];
        NSString *msg = nil;
        if (err) {
            msg = [NSString stringWithFormat:@"网络错误：%@", err.localizedDescription];
        } else if (http.statusCode == 401) {
            msg = @"Fish Key 无效或已过期（401）";
        } else if (http.statusCode != 200) {
            msg = [NSString stringWithFormat:@"取列表失败（HTTP %ld）", (long)http.statusCode];
        } else if (data.length) {
            NSInteger skipped = 0;
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            parsed = [AWECATTSManager sl_parseVoiceJSONText:text skipped:&skipped];
            // 带数字的报错：能直接看出是「没数据」还是「数据被过滤掉了」
            if (!parsed.count) {
                msg = skipped > 0
                    ? [NSString stringWithFormat:@"返回 %ld 条，但都不符合 Fish 格式（已全部跳过）", (long)skipped]
                    : @"接口返回里没有音色";
            }
        } else {
            msg = @"服务器没有返回内容";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2) return;
            self2.loading = NO;
            if (msg.length) {
                self2.status = msg;
            } else {
                self2.items = parsed;
                [self2.selected removeAllObjects];
                for (NSDictionary *v in parsed) {
                    NSString *vid = v[@"voiceType"];
                    if (vid.length) [self2.selected addObject:vid];
                }
                self2.status = parsed.count ? nil : @"这个账号下没有音色";
            }
            [self2.tableView reloadData];
        });
    }] resume];
}

#pragma mark - 导入

- (void)sl_doImport {
    if (self.mode == SLImportModePaste) {
        NSString *text = self.pasteView.text ?: @"";
        if (!text.length) {
            [AWECAUtils showToast:@"先粘贴音色列表 JSON" duration:1.5];
            return;
        }
        NSInteger skipped = 0;
        NSArray<NSDictionary *> *items = [AWECATTSManager sl_parseVoiceJSONText:text skipped:&skipped];
        if (!items.count) {
            [AWECAUtils showToast:@"没解析出音色，检查 JSON 结构" duration:2.0];
            return;
        }
        NSDictionary *result = [AWECATTSManager sl_importFishVoices:items];
        [self sl_downloadAvatarsForItems:items];
        [self sl_finishWithResult:result skipped:skipped];
        return;
    }

    if (!self.selected.count) {
        [AWECAUtils showToast:@"先勾选要导入的音色" duration:1.5];
        return;
    }
    NSMutableArray<NSDictionary *> *picked = [NSMutableArray array];
    for (NSDictionary *v in self.items) {
        if ([self.selected containsObject:v[@"voiceType"]]) [picked addObject:v];
    }
    NSDictionary *result = [AWECATTSManager sl_importFishVoices:picked];
    [self sl_downloadAvatarsForItems:picked];
    [self sl_finishWithResult:result skipped:0];
}

- (void)sl_downloadAvatarsForItems:(NSArray<NSDictionary *> *)items {
    for (NSDictionary *v in items) {
        NSString *img = v[@"img"];
        if (![img isKindOfClass:[NSString class]] || !img.length) continue;
        [AWECATTSManager sl_downloadAvatarForVoice:v[@"voiceType"] fromURL:img];
    }
}

- (void)sl_finishWithResult:(NSDictionary *)result skipped:(NSInteger)skipped {
    NSInteger added = [result[@"added"] integerValue];
    NSInteger updated = [result[@"updated"] integerValue];
    if (skipped > 0) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"导入 %ld 个，更新 %ld 个，跳过 %ld 个", (long)added, (long)updated, (long)skipped]
                     duration:2.5];
    }
    if (self.onImported) self.onImported(added, updated);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
