// 豆包 TTS 音色
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECATTSVoiceListController.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "SLVoiceImportController.h"
#import "SLGlass.h"
#import <objc/runtime.h>
#import <math.h>
#import <PhotosUI/PhotosUI.h>

#define kAWECARecommendedVoices @"AWECARecommendedVoices"
#define kAWECACustomVoices @"AWECACustomVoices"
#define kAWECFishFavorites @"AWECFishFavorites"   // v0.4.9 收藏音色（存 voiceType 数组）

typedef NS_ENUM(NSInteger, AWECAVoiceSection) {
    AWECAVoiceSectionCustom = 0,
    AWECAVoiceSectionRecommended,
    AWECAVoiceSectionAll,
    AWECAVoiceSectionCount
};

#define kCellFont [UIFont systemFontOfSize:15]

@interface AWECATTSVoiceListController () <UITextFieldDelegate, PHPickerViewControllerDelegate>
// v0.4.53：UISearchBar 换成自绘玻璃胶囊 + UITextField。
// UISearchBar 就算设 Minimal，它那层背景图仍然是系统画的浅灰/白块，压在透明表格上是一块白板；
// 而且它自带上下留白，永远贴不紧导航栏。
@property (nonatomic, strong) UIView *searchHeader;
@property (nonatomic, strong) UIView *searchPill;
@property (nonatomic, assign) CGFloat searchHeaderWidth;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *customVoices;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recommendedVoices;
@property (nonatomic, strong) NSArray<NSDictionary *> *allVoices;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredCustom;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredRecommended;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredAll;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) NSMutableArray<NSString *> *favorites;        // 收藏的 voiceType（顺序即置顶顺序）
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *filteredFavorites;
@property (nonatomic, copy) NSString *pendingAvatarVoiceID;   // 正在为哪个音色选图
// v0.4.54：多选导出。只作用于「我导入的音色」这一分区 —— 那些才是自己的东西。
@property (nonatomic, assign) BOOL multiSelect;
@property (nonatomic, strong) NSMutableSet<NSString *> *multiSel;
@end

@implementation AWECATTSVoiceListController

- (instancetype)init {
    // v0.4.50：Plain → insetGrouped。Plain 下行是满宽直通的方角条，跟设置页的玻璃卡片
    // 完全是两种东西；换成 insetGrouped 才有分组圆角和左右 16pt 边距。
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // v0.4.50：材质先铺，再判断模式 —— 情绪标签分支会提前 return，晚了就漏。
    SLApplyGlassTable(self.tableView);
    if (self.emotionMode) { [self aweca_setupEmotionMode]; return; }
    [self buildVoiceData];
    [self loadCustomVoices];
    [self loadRecommended];
    [self loadFavorites];
    self.multiSel = [NSMutableSet set];

    self.title = [NSString stringWithFormat:@"%@ · 音色", AWECAProductName];   // 两个引擎统一叫「音色」
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"vc"];

    self.navigationItem.rightBarButtonItem =
        SLPillIconBarItem(@"plus", @"添加", self,
                          self.fishMode ? @selector(aweca_showAddPanel) : @selector(addCustomVoice));

    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, self.fishMode ? 56 : 44)];
    UILabel *verLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 20)];
    verLabel.text = [NSString stringWithFormat:@"%@ v%@ / CN-TaylorChen 维护", AWECAProductName, AWECAVersion];
    verLabel.textAlignment = NSTextAlignmentCenter;
    verLabel.font = [UIFont systemFontOfSize:12];
    verLabel.textColor = [UIColor secondaryLabelColor];
    [footer addSubview:verLabel];
    if (self.fishMode) {
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, self.view.bounds.size.width, 20)];
        hint.text = @"左滑收藏 · 右滑换头像 · 长按音色多选导出 · ＋ 添加";
        hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont systemFontOfSize:11];
        hint.textColor = [UIColor tertiaryLabelColor];
        [footer addSubview:hint];
    }
    self.tableView.tableFooterView = footer;

    [self sl_rebuildSearchHeader];

    self.filteredCustom = [self.customVoices mutableCopy];
    self.filteredRecommended = [self.recommendedVoices mutableCopy];
    self.filteredAll = self.allVoices;
    [self rebuildFilteredFavorites];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    // v0.4.50：标题改胶囊。放在这里是因为「音色 / 情绪 / 收藏」几个模式的 title
    // 是在不同分支里赋的，统一在将要出现时按当前 title 重建一次最不容易漏。
    if (self.title.length) self.navigationItem.titleView = SLPillTitleView(self.title);
    SLInstallPillBack(self);   // v0.4.53：返回键胶囊（情绪分支在 viewDidLoad 里提前 return，所以放这）
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self aweca_dismissAddPanel];   // v0.4.57：离开页面时顺手收掉添加面板，免得挂在上一个界面
}

#pragma mark - 搜索框（自绘玻璃胶囊）

// v0.4.54：胶囊改用 SLGlass 的 SLSearchPill。
// 原来图标和文字是「建的时候按 self.view.bounds.width 算死坐标」，而表格真实宽度
// 未必等于它（浮窗里 358 vs 374），宽度一改文字就跑到放大镜底下去 —— 用户看到的就是
// 「搜索栏图标和文字重叠」。现在排布全在 layoutSubviews 里，怎么变都不会压。
- (void)sl_rebuildSearchHeader {
    if (!self.searchHeader) {
        UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
        SLSearchPill *p = [SLSearchPill pillWithPlaceholder:@"搜索音色"];
        p.field.delegate = self;
        [p.field addTarget:self action:@selector(sl_searchChanged) forControlEvents:UIControlEventEditingChanged];
        [head addSubview:p];
        self.searchHeader = head;
        self.searchPill = p;
        self.searchField = p.field;
        self.searchHeaderWidth = 0;
    }
    [self sl_layoutSearchHeader];
    self.tableView.tableHeaderView = self.searchHeader;
}

- (void)sl_layoutSearchHeader {
    UIView *head = self.searchHeader;
    if (!head) return;
    CGFloat w = self.tableView.bounds.size.width;
    if (w <= 0) w = self.view.bounds.size.width;
    CGFloat h = [SLSearchPill pillHeight];
    head.frame = CGRectMake(0, 0, w, h + 8.0);
    self.searchPill.frame = CGRectMake(16.0, 4.0, MAX(0.0, w - 32.0), h);
    if (fabs(w - self.searchHeaderWidth) > 0.5) {
        self.searchHeaderWidth = w;
        self.tableView.tableHeaderView = head;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.searchHeader && !self.emotionMode) [self sl_layoutSearchHeader];
}

- (void)sl_searchChanged {
    self.searchText = self.searchField.text ?: @"";
    [self filterVoices];
    [self.tableView reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

#pragma mark - 情绪标签管理模式

- (void)aweca_setupEmotionMode {
    self.title = [NSString stringWithFormat:@"%@ · 情绪", AWECAProductName];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"vc"];

    self.navigationItem.rightBarButtonItem = SLPillIconBarItem(@"plus", @"新增", self, @selector(aweca_addEmotionTag));

    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    UILabel *hint = [[UILabel alloc] initWithFrame:footer.bounds];
    hint.text = @"点行勾选/取消 · 左滑编辑或删除 · ＋ 新增标签";
    hint.textAlignment = NSTextAlignmentCenter;
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor tertiaryLabelColor];
    [footer addSubview:hint];
    self.tableView.tableFooterView = footer;
    self.tableView.tableHeaderView = nil;   // 不需要搜索栏
}

// 依据当前模型给裸标签加括号：s1 用圆括号，s2 系用方括号；已带括号则原样返回
+ (NSString *)aweca_wrapEmotionTag:(NSString *)raw {
    NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return t;
    if (([t hasPrefix:@"["] && [t hasSuffix:@"]"]) || ([t hasPrefix:@"("] && [t hasSuffix:@")"])) return t;
    NSString *model = [AWECATTSManager shared].fishModel ?: @"";
    return [model isEqualToString:@"s1"] ? [NSString stringWithFormat:@"(%@)", t]
                                         : [NSString stringWithFormat:@"[%@]", t];
}

+ (NSString *)aweca_stripEmotionTag:(NSString *)tag {
    NSString *t = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (([t hasPrefix:@"["] && [t hasSuffix:@"]"]) || ([t hasPrefix:@"("] && [t hasSuffix:@")"])) {
        t = [t substringWithRange:NSMakeRange(1, t.length - 2)];
    }
    return t;
}

- (void)aweca_addEmotionTag {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加情绪"
        message:[NSString stringWithFormat:@"情绪填英文（如 chuckle、whisper），当前模型 %@ 会自动加 %@\n备注填中文，仅用于显示",
                 mgr.fishModel ?: @"s2.1-pro-free",
                 [mgr.fishModel isEqualToString:@"s1"] ? @"圆括号" : @"方括号"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"备注（选填，中文，如：开心 · 活泼一点）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"情绪（英文，如 happy）";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *tag = [self.class aweca_wrapEmotionTag:alert.textFields[1].text ?: @""];
        if (!tag.length) { [AWECAUtils showToast:@"标签不能为空"]; return; }
        NSMutableArray *all = [mgr.fishEmotionAll mutableCopy];
        if ([all containsObject:tag]) { [AWECAUtils showToast:@"该标签已存在"]; return; }
        // v0.4.54：新加的插到第 0 位（原来追加到末尾，内置标签一长串，新加的根本找不到）
        [all insertObject:tag atIndex:0];
        mgr.fishEmotionAll = all;
        // 备注平行数组同步插到第 0 位；先把历史上可能错位的长度补齐/截齐
        NSMutableArray *notes = [mgr.fishEmotionNotes mutableCopy] ?: [NSMutableArray array];
        while (notes.count < all.count - 1) [notes addObject:@""];
        while (notes.count > all.count - 1) [notes removeLastObject];
        [notes insertObject:([alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"")
                    atIndex:0];
        mgr.fishEmotionNotes = notes;
        [mgr saveConfig];
        [self.tableView reloadData];
        if (self.onEmotionsChanged) self.onEmotionsChanged();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)aweca_editEmotionTagAtIndex:(NSInteger)idx {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    if (idx < 0 || idx >= (NSInteger)mgr.fishEmotionAll.count) return;
    NSString *old = mgr.fishEmotionAll[idx];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"编辑情绪"
        message:@"备注填中文，仅用于显示\n情绪填英文，改标签会自动同步已选状态"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [mgr fishEmotionNoteAtIndex:idx];
        tf.placeholder = @"备注（选填，中文，仅显示用）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [self.class aweca_stripEmotionTag:old];
        tf.placeholder = @"情绪（英文）";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *tag = [self.class aweca_wrapEmotionTag:alert.textFields[1].text ?: @""];
        if (!tag.length) { [AWECAUtils showToast:@"标签不能为空"]; return; }
        NSMutableArray *all = [mgr.fishEmotionAll mutableCopy];
        NSMutableArray *sel = [mgr.fishEmotionSel mutableCopy];
        BOOL wasSel = [sel containsObject:old];
        if (wasSel) [sel removeObject:old];
        all[idx] = tag;
        if (wasSel && ![sel containsObject:tag]) [sel addObject:tag];
        mgr.fishEmotionAll = all;
        mgr.fishEmotionSel = sel;
        // 备注同步更新（长度对齐）
        NSMutableArray *notes = [mgr.fishEmotionNotes mutableCopy] ?: [NSMutableArray array];
        while (notes.count < all.count) [notes addObject:@""];
        notes[idx] = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        mgr.fishEmotionNotes = notes;
        [mgr saveConfig];
        [self.tableView reloadData];
        if (self.onEmotionsChanged) self.onEmotionsChanged();
        [AWECAUtils showToast:@"已更新标签"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 自定义音色持久化

- (void)loadCustomVoices {
    if (self.fishMode) {
        self.customVoices = [[AWECATTSManager fishVoices] mutableCopy];
        return;
    }
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kAWECACustomVoices];
    self.customVoices = saved ? [saved mutableCopy] : [NSMutableArray array];
}

- (void)saveCustomVoices {
    if (self.fishMode) {
        [AWECATTSManager saveFishVoices:[self.customVoices copy]];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:[self.customVoices copy] forKey:kAWECACustomVoices];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)addCustomVoice {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加音色"
        message:(self.fishMode
            ? @"填写 fish.audio 音色库（或你克隆的声音）详情页的音色 ID（reference_id）"
            : @"填写火山引擎音色库中的音色 ID（复刻音色为 S_ 开头，商店/默认音色为 BV 或 zh_/en_ 开头）")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"音色名称（如：我的复刻音色）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"音色 ID（voice_type）";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = alert.textFields[0].text ?: @"";
        NSString *type = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (type.length == 0) {
            [AWECAUtils showToast:@"音色 ID 不能为空"];
            return;
        }
        if (name.length == 0) name = type;
        // 同 ID 去重，已存在则更新名称
        BOOL exists = NO;
        for (NSUInteger i = 0; i < self.customVoices.count; i++) {
            if ([self.customVoices[i][@"voiceType"] isEqualToString:type]) {
                self.customVoices[i] = @{@"name": name, @"voiceType": type};
                exists = YES;
                break;
            }
        }
        if (!exists) [self.customVoices addObject:@{@"name": name, @"voiceType": type}];
        [self saveCustomVoices];
        [self filterVoices];
        [self.tableView reloadData];
        [AWECAUtils showToast:exists ? @"已更新音色" : @"已添加音色"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 推荐音色持久化

- (NSArray<NSDictionary *> *)defaultRecommended {
    return @[
        @{@"name": @"知性灿灿 2.0", @"voiceType": @"zh_female_cancan_uranus_bigtts"},
        @{@"name": @"Vivi 2.0", @"voiceType": @"zh_female_vv_uranus_bigtts"},
        @{@"name": @"小何 2.0", @"voiceType": @"zh_female_xiaohe_uranus_bigtts"},
        @{@"name": @"云舟 2.0", @"voiceType": @"zh_male_m191_uranus_bigtts"},
        @{@"name": @"小天 2.0", @"voiceType": @"zh_male_taocheng_uranus_bigtts"},
    ];
}

- (NSString *)recommendedKey {
    return kAWECARecommendedVoices;
}

- (void)loadRecommended {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:[self recommendedKey]];
    if (saved != nil) {
        self.recommendedVoices = [saved mutableCopy];
    } else {
        self.recommendedVoices = [[self defaultRecommended] mutableCopy];
        [self saveRecommended];
    }
}

- (void)saveRecommended {
    [[NSUserDefaults standardUserDefaults] setObject:[self.recommendedVoices copy] forKey:[self recommendedKey]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 搜索

- (void)filterVoices {
    if (!self.searchText || self.searchText.length == 0) {
        self.filteredCustom = [self.customVoices mutableCopy];
        self.filteredRecommended = [self.recommendedVoices mutableCopy];
        self.filteredAll = self.allVoices;
        [self rebuildFilteredFavorites];
        return;
    }
    NSString *q = self.searchText.lowercaseString;
    NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *v, NSDictionary *bindings) {
        return [[v[@"name"] lowercaseString] containsString:q] ||
               [[v[@"voiceType"] lowercaseString] containsString:q];
    }];
    self.filteredCustom = [[self.customVoices filteredArrayUsingPredicate:pred] mutableCopy];
    self.filteredRecommended = [[self.recommendedVoices filteredArrayUsingPredicate:pred] mutableCopy];
    self.filteredAll = [self.allVoices filteredArrayUsingPredicate:pred];
    [self rebuildFilteredFavorites];
}

#pragma mark - 收藏（v0.4.9）

- (void)loadFavorites {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kAWECFishFavorites];
    self.favorites = [saved isKindOfClass:[NSArray class]] ? [saved mutableCopy] : [NSMutableArray array];
    if (!self.filteredFavorites) self.filteredFavorites = [NSMutableArray array];
}

- (void)saveFavorites {
    [[NSUserDefaults standardUserDefaults] setObject:[self.favorites copy] ?: @[] forKey:kAWECFishFavorites];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)isFavorite:(NSString *)vid {
    return vid.length && [self.favorites containsObject:vid];
}

// 收藏分区：按收藏顺序排列（新收藏在前），并跟随搜索过滤
- (void)rebuildFilteredFavorites {
    NSMutableArray *out = [NSMutableArray array];
    if (!self.favorites.count) { self.filteredFavorites = out; return; }

    NSMutableArray *pool = [NSMutableArray array];
    [pool addObjectsFromArray:self.customVoices];
    [pool addObjectsFromArray:self.recommendedVoices];
    NSMutableDictionary *byVid = [NSMutableDictionary dictionary];
    for (NSDictionary *v in pool) {
        NSString *vid = v[@"voiceType"];
        if (vid.length && !byVid[vid]) byVid[vid] = v;
    }
    NSString *q = self.searchText.lowercaseString;
    for (NSString *vid in self.favorites) {
        NSDictionary *v = byVid[vid];
        if (!v) continue;   // 音色已被删除
        if (q.length) {
            NSString *name = [v[@"name"] lowercaseString] ?: @"";
            if (![name containsString:q] && ![[vid lowercaseString] containsString:q]) continue;
        }
        [out addObject:v];
    }
    self.filteredFavorites = out;
}

// 左滑「收藏 / 取消收藏」，收藏后立刻置顶到分区 0
- (void)aweca_toggleFavoriteForVoice:(NSString *)vid {
    if (!vid.length) return;
    if ([self.favorites containsObject:vid]) {
        [self.favorites removeObject:vid];
        [AWECAUtils showToast:@"已取消收藏"];
    } else {
        [self.favorites insertObject:vid atIndex:0];
        [AWECAUtils showToast:@"已收藏，已置顶"];
    }
    [self saveFavorites];
    [self filterVoices];
    [self.tableView reloadData];
}

#pragma mark - 数据源

- (NSArray<NSDictionary *> *)listForSection:(NSInteger)section {
    // Fish 模式：0 = 收藏（置顶） 1 = 我导入的（手动添加 + 导入），与内置库分开
    if (self.fishMode) {
        if (section == 0) return self.filteredFavorites ?: @[];
        if (section == 1) return self.filteredCustom ?: @[];
        return @[];
    }
    switch (section) {
        case AWECAVoiceSectionCustom: return self.filteredCustom;
        case AWECAVoiceSectionRecommended: return self.filteredRecommended;
        case AWECAVoiceSectionAll: return self.filteredAll;
        default: return @[];
    }
}

// v0.4.53：表头高度统一 28（系统默认在 insetGrouped 下会随字体/内容浮动，同一页里两行标题能差 6pt）。
// 收藏空组直接给 0.01 —— 配合上面返回 nil 的标题，整组就彻底消失了。
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (self.fishMode && section == 0 && self.filteredFavorites.count == 0) return 0.01;
    return 28;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.emotionMode) return 1;
    return self.fishMode ? 2 : AWECAVoiceSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.emotionMode) return [AWECATTSManager shared].fishEmotionAll.count;
    return [self listForSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.emotionMode) {
        AWECATTSManager *mgr = [AWECATTSManager shared];
        return [NSString stringWithFormat:@"全部标签 (%lu) · 已选 %lu 个",
                (unsigned long)mgr.fishEmotionAll.count, (unsigned long)mgr.fishEmotionSel.count];
    }
    if (self.fishMode) {
        // v0.4.53：收藏为空时不画「收藏 (0)」这个空壳分组标题 ——
        // 没收藏过的人一进来先看到一行空标题，会以为页面坏了。
        if (section == 0) {
            return self.filteredFavorites.count
                ? [NSString stringWithFormat:@"收藏 (%lu)", (unsigned long)self.filteredFavorites.count]
                : nil;
        }
        NSString *base = [NSString stringWithFormat:@"我导入的音色 (%lu)", (unsigned long)self.filteredCustom.count];
        // v0.4.54：多选态把已选数量挂在分区标题上，省一个表头按钮
        return self.multiSelect
            ? [NSString stringWithFormat:@"%@ · 已选 %lu", base, (unsigned long)self.multiSel.count]
            : base;
    }
    switch (section) {
        case AWECAVoiceSectionCustom: return [NSString stringWithFormat:@"我的音色 (%lu)", (unsigned long)self.filteredCustom.count];
        case AWECAVoiceSectionRecommended: return @"推荐音色";
        case AWECAVoiceSectionAll: return [NSString stringWithFormat:@"全部音色 (%lu)", (unsigned long)self.filteredAll.count];
        default: return nil;
    }
}

// 音色头像（圆）：优先自定义图片，否则 emoji/名称首字 + 底色
- (UIImage *)aweca_avatarImageForVoice:(NSDictionary *)voice size:(CGFloat)sz {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    UIImage *img = [mgr fishAvatarForVoiceID:voice[@"voiceType"]];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(sz, sz), NO, 0);
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, sz, sz)] addClip];
    if (img) {
        [img drawInRect:CGRectMake(0, 0, sz, sz)];
        UIImage *r = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return r;
    }
    static NSArray<UIColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[[UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1],
                    [UIColor colorWithRed:1.0 green:0.58 blue:0.0 alpha:1],
                    [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1],
                    [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1],
                    [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1],
                    [UIColor colorWithRed:0.35 green:0.35 blue:0.40 alpha:1]];
    });
    NSInteger idx = [(voice[@"color"] ?: @0) integerValue];
    if (idx < 0 || idx >= (NSInteger)palette.count) idx = 3;
    [palette[idx] setFill];
    UIBezierPath *oval = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, sz, sz)];
    [oval fill];
    NSString *text = [voice[@"avatar"] isKindOfClass:[NSString class]] && ((NSString *)voice[@"avatar"]).length
        ? voice[@"avatar"]
        : ([voice[@"name"] length] ? [voice[@"name"] substringToIndex:1] : @"♪");
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:sz * 0.42],
                            NSForegroundColorAttributeName: [UIColor whiteColor],
                            NSParagraphStyleAttributeName: ps};
    CGRect tr = CGRectMake(0, (sz - sz * 0.42) / 2 - sz * 0.05, sz, sz * 0.6);
    [text drawInRect:tr withAttributes:attrs];
    UIImage *r = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return r;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"vc" forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    AWECATTSManager *mgr = [AWECATTSManager shared];

    if (self.emotionMode) {
        NSString *tag = mgr.fishEmotionAll[indexPath.row];
        NSString *note = [mgr fishEmotionNoteAtIndex:indexPath.row];
        // 双语显示：有备注 -> 大字中文备注 + 灰色等宽小字英文标签；无备注 -> 标签原文
        if (note.length) {
            NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];
            [as appendAttributedString:[[NSAttributedString alloc] initWithString:note attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor labelColor]}]];
            [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", tag] attributes:@{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular],
                NSForegroundColorAttributeName: [UIColor secondaryLabelColor]}]];
            cell.textLabel.attributedText = as;
            cell.textLabel.numberOfLines = 2;
        } else {
            cell.textLabel.attributedText = [[NSAttributedString alloc] initWithString:tag attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: [UIColor labelColor]}];
            cell.textLabel.numberOfLines = 1;
        }
        if ([mgr.fishEmotionSel containsObject:tag]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
        return cell;
    }

    // v0.4.54：多选导出态 —— 自建音色行只留勾选，播放键让位
    if (self.multiSelect) {
        NSInteger customSec = self.fishMode ? 1 : AWECAVoiceSectionCustom;
        if (indexPath.section == customSec) {
            NSDictionary *mv = [self listForSection:indexPath.section][indexPath.row];
            NSString *mt = mv[@"voiceType"];
            cell.imageView.image = [self aweca_avatarImageForVoice:mv size:40];
            cell.imageView.layer.cornerRadius = 20;
            cell.imageView.layer.masksToBounds = YES;
            cell.textLabel.text = mv[@"name"] ?: mt;
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            cell.accessoryType = [self.multiSel containsObject:mt]
                ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            return cell;
        }
    }

    NSDictionary *voice = [self listForSection:indexPath.section][indexPath.row];
    NSString *name = voice[@"name"];
    NSString *type = voice[@"voiceType"];

    NSString *cur = self.fishMode ? (mgr.fishVoiceType ?: @"") : (mgr.voiceType.length > 0 ? mgr.voiceType : @"zh_female_cancan_uranus_bigtts");

    if (self.fishMode) {
        cell.imageView.image = [self aweca_avatarImageForVoice:voice size:40];
        cell.imageView.layer.cornerRadius = 20;
        cell.imageView.layer.masksToBounds = YES;
        // 收藏的音色加 ★ 前缀（收藏分区本身就置顶，这里做视觉标识）
        cell.textLabel.text = [self isFavorite:type] ? [NSString stringWithFormat:@"★ %@", name] : name;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    } else {
        cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", name, type];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
    }

    if ([type isEqualToString:cur]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }

    UIButton *playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
    [playBtn setImage:[UIImage systemImageNamed:@"play.circle" withConfiguration:cfg] forState:UIControlStateNormal];
    playBtn.frame = CGRectMake(0, 0, 36, 36);
    objc_setAssociatedObject(playBtn, "voiceType", type, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [playBtn addTarget:self action:@selector(previewVoice:) forControlEvents:UIControlEventTouchUpInside];

    if (![type isEqualToString:cur]) {
        cell.accessoryView = playBtn;
    }

    return cell;
}

#pragma mark - 列表代理

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    AWECATTSManager *mgr = [AWECATTSManager shared];

    if (self.emotionMode) {
        NSString *tag = mgr.fishEmotionAll[indexPath.row];
        NSMutableArray *sel = [mgr.fishEmotionSel mutableCopy];
        if ([sel containsObject:tag]) [sel removeObject:tag];
        else [sel addObject:tag];
        mgr.fishEmotionSel = sel;
        [mgr saveConfig];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        if (self.onEmotionsChanged) self.onEmotionsChanged();
        return;
    }

    // v0.4.54：多选态点行＝勾选/取消勾选，不切音色
    if (self.multiSelect) {
        NSInteger customSec = self.fishMode ? 1 : AWECAVoiceSectionCustom;
        if (indexPath.section != customSec) return;
        NSArray *rows = [self listForSection:indexPath.section];
        if (indexPath.row >= (NSInteger)rows.count) return;
        NSString *t = rows[indexPath.row][@"voiceType"];
        if (!t.length) return;
        if ([self.multiSel containsObject:t]) [self.multiSel removeObject:t];
        else [self.multiSel addObject:t];
        [tableView reloadData];   // 分区标题里的「已选 N」也要跟着变
        return;
    }

    NSDictionary *voice = [self listForSection:indexPath.section][indexPath.row];

    if (self.fishMode) {
        mgr.fishVoiceType = voice[@"voiceType"];
        mgr.fishVoiceName = voice[@"name"];
    } else {
        mgr.voiceType = voice[@"voiceType"];
        mgr.voiceName = voice[@"name"];
    }
    [mgr saveConfig];

    if (self.onVoiceSelected) {
        self.onVoiceSelected(voice[@"voiceType"], voice[@"name"]);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - 推荐编辑

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.emotionMode) return YES;
    if (self.multiSelect) return NO;   // v0.4.54：多选态不允许左滑，免得勾选和滑动动作打架
    if (self.searchText.length > 0) return NO;
    return YES;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.searchText.length > 0) return nil;
    if (self.multiSelect) return nil;   // v0.4.54：多选态左滑关掉

    // 情绪标签模式：左滑编辑 / 删除
    if (self.emotionMode) {
        AWECATTSManager *mgr = [AWECATTSManager shared];
        NSInteger idx = indexPath.row;
        NSString *tag = mgr.fishEmotionAll[idx];
        UIContextualAction *editAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:@"编辑" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self aweca_editEmotionTagAtIndex:idx];
            completionHandler(NO);
        }];
        editAction.backgroundColor = [UIColor systemBlueColor];
        UIContextualAction *removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
            title:@"删除" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            NSMutableArray *all = [mgr.fishEmotionAll mutableCopy];
            NSMutableArray *sel = [mgr.fishEmotionSel mutableCopy];
            [all removeObject:tag];
            [sel removeObject:tag];
            mgr.fishEmotionAll = all;
            mgr.fishEmotionSel = sel;
            // 备注平行数组同步删除
            if (idx < (NSInteger)mgr.fishEmotionNotes.count) {
                NSMutableArray *notes = [mgr.fishEmotionNotes mutableCopy];
                [notes removeObjectAtIndex:idx];
                mgr.fishEmotionNotes = notes;
            }
            [mgr saveConfig];
            [tableView performBatchUpdates:^{
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } completion:nil];
            if (self.onEmotionsChanged) self.onEmotionsChanged();
            [AWECAUtils showToast:[NSString stringWithFormat:@"已删除: %@", tag]];
            completionHandler(YES);
        }];
        return [UISwipeActionsConfiguration configurationWithActions:@[removeAction, editAction]];
    }

    // 收藏分区：只提供「取消收藏」
    if (self.fishMode && indexPath.section == 0) {
        return [self aweca_configActions:@[] forIndexPath:indexPath];
    }

    NSInteger customSec = self.fishMode ? 1 : AWECAVoiceSectionCustom;
    if (indexPath.section == customSec) {
        NSDictionary *voice = self.filteredCustom[indexPath.row];
        NSString *name = voice[@"name"];
        NSString *vid = voice[@"voiceType"];
        NSInteger row = indexPath.row;

        UIContextualAction *editAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:@"编辑" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"编辑音色"
                message:nil preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                tf.text = name;
                tf.placeholder = @"音色名称";
            }];
            [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                tf.text = vid;
                tf.placeholder = @"音色 ID";
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) {
                NSString *newName = alert.textFields[0].text ?: @"";
                NSString *newVid = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (newVid.length == 0) { [AWECAUtils showToast:@"音色 ID 不能为空"]; return; }
                if (newName.length == 0) newName = newVid;
                BOOL vidChanged = ![newVid isEqualToString:vid];
                // 音色库内 ID 查重（排除自身）
                if (vidChanged) {
                    for (NSUInteger i = 0; i < self.customVoices.count; i++) {
                        if ((NSInteger)i != row && [self.customVoices[i][@"voiceType"] isEqualToString:newVid]) {
                            [AWECAUtils showToast:@"该音色 ID 已存在"];
                            return;
                        }
                    }
                }
                self.customVoices[row] = @{@"name": newName, @"voiceType": newVid};
                [self saveCustomVoices];
                // 若编辑的是当前选中音色，同步更新选中引用与头像
                AWECATTSManager *m = [AWECATTSManager shared];
                if (self.fishMode) {
                    if ([m.fishVoiceType isEqualToString:vid]) {
                        m.fishVoiceType = newVid;
                        m.fishVoiceName = newName;
                        [m saveConfig];
                    }
                    if (vidChanged) {
                        UIImage *oldAv = [m fishAvatarForVoiceID:vid];
                        if (oldAv) {
                            [m saveFishAvatarImage:oldAv forVoiceID:newVid];
                            [m deleteFishAvatarForVoiceID:vid];
                        }
                    }
                } else if ([m.voiceType isEqualToString:vid]) {
                    m.voiceType = newVid;
                    m.voiceName = newName;
                    [m saveConfig];
                }
                [self filterVoices];
                [self.tableView reloadData];
                if (self.onVoiceSelected) self.onVoiceSelected(newVid, newName);
                [AWECAUtils showToast:@"已更新音色"];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
            completionHandler(NO);
        }];
        editAction.backgroundColor = [UIColor systemBlueColor];

        UIContextualAction *removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
            title:@"删除" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self.customVoices removeObjectAtIndex:indexPath.row];
            [self saveCustomVoices];
            if (self.fishMode) [[AWECATTSManager shared] deleteFishAvatarForVoiceID:vid];
            [self filterVoices];
            [tableView performBatchUpdates:^{
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } completion:nil];
            [AWECAUtils showToast:[NSString stringWithFormat:@"已删除: %@", name]];
            completionHandler(YES);
        }];
        // v0.4.54：自建音色可以分享出去（只有 Fish 音色的 ID 是跨账号可用的）
        NSMutableArray *acts = [NSMutableArray arrayWithObjects:removeAction, editAction, nil];
        if (self.fishMode) {
            UIContextualAction *shareAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                title:@"分享" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
                [self sl_shareVoices:@[@{ @"name": name ?: vid, @"voiceType": vid }] fromView:sourceView];
                completionHandler(YES);
            }];
            shareAction.backgroundColor = [UIColor systemTealColor];
            [acts addObject:shareAction];
        }
        return [self aweca_configActions:acts forIndexPath:indexPath];

    } else if (indexPath.section == AWECAVoiceSectionRecommended) {
        UIContextualAction *removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
            title:@"移除" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self.recommendedVoices removeObjectAtIndex:indexPath.row];
            [self saveRecommended];
            self.filteredRecommended = [self.recommendedVoices mutableCopy];
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            completionHandler(YES);
        }];
        return [self aweca_configActions:@[removeAction] forIndexPath:indexPath];

    } else if (indexPath.section == AWECAVoiceSectionAll) {
        NSDictionary *voice = self.filteredAll[indexPath.row];
        NSString *vt = voice[@"voiceType"];
        for (NSDictionary *r in self.recommendedVoices) {
            if ([r[@"voiceType"] isEqualToString:vt]) return nil;
        }

        UIContextualAction *addAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:@"加入推荐" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self.recommendedVoices addObject:voice];
            [self saveRecommended];
            self.filteredRecommended = [self.recommendedVoices mutableCopy];
            NSIndexPath *newIP = [NSIndexPath indexPathForRow:self.recommendedVoices.count - 1 inSection:AWECAVoiceSectionRecommended];
            [tableView insertRowsAtIndexPaths:@[newIP] withRowAnimation:UITableViewRowAnimationAutomatic];
            [AWECAUtils showToast:[NSString stringWithFormat:@"已加入推荐: %@", voice[@"name"]]];
            completionHandler(YES);
        }];
        addAction.backgroundColor = [UIColor systemBlueColor];
        return [self aweca_configActions:@[addAction] forIndexPath:indexPath];
    }
    return nil;
}

#pragma mark - 左滑动作组装 / 导入入口（v0.4.9）

// 统一在左侧插入「收藏 / 取消收藏」（仅 Fish 模式）
- (UISwipeActionsConfiguration *)aweca_configActions:(NSArray<UIContextualAction *> *)actions
                                        forIndexPath:(NSIndexPath *)ip {
    NSMutableArray *list = [actions mutableCopy] ?: [NSMutableArray array];
    if (self.fishMode) {
        NSArray *rows = [self listForSection:ip.section];
        if (ip.row < (NSInteger)rows.count) {
            NSDictionary *voice = rows[ip.row];
            NSString *vid = voice[@"voiceType"];
            BOOL fav = [self isFavorite:vid];
            UIContextualAction *favAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                title:(fav ? @"取消收藏" : @"收藏")
                handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
                [self aweca_toggleFavoriteForVoice:vid];
                completionHandler(YES);
            }];
            favAction.backgroundColor = fav ? [UIColor systemGrayColor] : [UIColor systemOrangeColor];
            [list insertObject:favAction atIndex:0];
        }
    }
    return [UISwipeActionsConfiguration configurationWithActions:list];
}

#pragma mark - 添加面板（v0.4.57 玻璃小面板，仅两项）

// v0.4.57：把原来 UIAlertAction 的 action sheet 换成锚定在 ＋ 按钮下方的小玻璃面板，
// 只留两项——「从 Fish 导入」「手动添加」。点面板外即关，弹簧进场。
- (void)aweca_showAddPanel {
    [self aweca_dismissAddPanel];
    UIView *host = self.navigationController.view ?: self.view;
    __weak typeof(self) ws = self;

    // 背景暗化，点按即关
    UIView *dim = [[UIView alloc] initWithFrame:host.bounds];
    dim.backgroundColor = [UIColor blackColor];
    dim.alpha = 0;
    dim.tag = 99218;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(aweca_dismissAddPanel)]];
    [host addSubview:dim];
    [UIView animateWithDuration:0.2 animations:^{ dim.alpha = 0.16; }];

    // 面板载体
    // v0.4.64：统一音色库玻璃语言 —— 圆角走 kCACornerCurveContinuous（和音色库卡片一致），
    // 底色透出背后的超薄毛玻璃，行卡片也统一成同款玻璃 chip。
    UIView *panel = [[UIView alloc] init];
    panel.tag = 99217;
    panel.layer.cornerRadius = 16;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    panel.layer.borderColor = [SLGlassHairlineColor() CGColor];
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.22;
    panel.layer.shadowRadius = 18;
    panel.layer.shadowOffset = CGSizeMake(0, 8);
    UIVisualEffectView *blur = SLInstallGlassBackdrop(panel);
    blur.layer.cornerRadius = 16;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.layer.masksToBounds = YES;
    blur.userInteractionEnabled = NO;

    CGFloat pw = 224, rowW = pw - 12, rowH = 52;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, pw - 32, 20)];
    title.text = @"添加音色";
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    [panel addSubview:title];

    UIView *fishRow = [self aweca_panelRowWithIcon:[UIImage systemImageNamed:@"icloud.and.arrow.down"]
                                              width:rowW title:@"从 Fish 导入" subtitle:@"我的音色 / 搜公开库" tap:^{
        [ws aweca_pushImportWithMode:SLImportModeMine];
    }];
    fishRow.frame = CGRectMake(6, 38, rowW, rowH);
    [panel addSubview:fishRow];

    UIView *manualRow = [self aweca_panelRowWithIcon:[UIImage systemImageNamed:@"plus"]
                                                width:rowW title:@"手动添加" subtitle:@"填写音色 ID" tap:^{
        [ws addCustomVoice];
    }];
    manualRow.frame = CGRectMake(6, 38 + rowH + 2, rowW, rowH);
    [panel addSubview:manualRow];

    CGFloat ph = 38 + rowH * 2 + 2 + 10;
    CGRect btnRect = [self aweca_addButtonRectInView:host];
    CGFloat px = CGRectGetMaxX(btnRect) - pw;
    if (px < 8) px = 8;
    if (px + pw > host.bounds.size.width - 8) px = host.bounds.size.width - pw - 8;
    CGFloat py = CGRectGetMaxY(btnRect) + 8;
    if (py + ph > host.bounds.size.height - 8) py = CGRectGetMinY(btnRect) - ph - 8; // 下方不够翻到上方
    panel.frame = CGRectMake(px, py, pw, ph);

    panel.alpha = 0;
    panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [host addSubview:panel];
    [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.7 options:0 animations:^{
        panel.alpha = 1;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)aweca_dismissAddPanel {
    UIView *host = self.navigationController.view ?: self.view;
    UIView *dim = [host viewWithTag:99218];
    UIView *panel = [host viewWithTag:99217];
    if (!dim && !panel) return;
    [UIView animateWithDuration:0.18 animations:^{
        dim.alpha = 0;
        panel.alpha = 0;
        panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL f){
        [dim removeFromSuperview];
        [panel removeFromSuperview];
    }];
}

- (CGRect)aweca_addButtonRectInView:(UIView *)view {
    UIBarButtonItem *bbi = self.navigationItem.rightBarButtonItem;
    UIView *bbv = [bbi valueForKey:@"view"];
    if (bbv) return [bbv convertRect:bbv.bounds toView:view];
    return CGRectMake(view.bounds.size.width - 56, 8, 44, 44);
}

- (UIView *)aweca_panelRowWithIcon:(UIImage *)icon width:(CGFloat)rowW title:(NSString *)title subtitle:(NSString *)subtitle tap:(void(^)(void))tap {
    // v0.4.64：行变成玻璃 chip（SLGlassCellColor + 连续圆角），跟音色库列表单元格同款。
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rowW, 52)];
    row.backgroundColor = SLGlassCellColor();
    row.layer.cornerRadius = 12;
    row.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(10, 11, 30, 30)];
    iv.image = icon; iv.tintColor = [UIColor labelColor]; iv.contentMode = UIViewContentModeCenter;
    [row addSubview:iv];
    UILabel *t1 = [[UILabel alloc] initWithFrame:CGRectMake(50, 9, rowW - 60, 18)];
    t1.text = title; t1.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; t1.textColor = [UIColor labelColor];
    [row addSubview:t1];
    UILabel *t2 = [[UILabel alloc] initWithFrame:CGRectMake(50, 29, rowW - 60, 15)];
    t2.text = subtitle; t2.font = [UIFont systemFontOfSize:11]; t2.textColor = [UIColor tertiaryLabelColor];
    [row addSubview:t2];
    row.userInteractionEnabled = YES;
    if (tap) objc_setAssociatedObject(row, "awecaPanelAction", tap, OBJC_ASSOCIATION_COPY);
    [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(aweca_panelRowTapped:)]];
    return row;
}

- (void)aweca_panelRowTapped:(UITapGestureRecognizer *)gr {
    void(^act)(void) = objc_getAssociatedObject(gr.view, "awecaPanelAction");
    [self aweca_dismissAddPanel];
    if (act) act();
}

#pragma mark - 右滑换头像（v0.4.57：从头像长按迁移过来）

// v0.4.57：长按手势改去驱动多选导出，头像更换就挪到右滑（leading）这一格，
// 功能不丢、手势也不打架。
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.fishMode) return nil;
    if (self.multiSelect) return nil;
    if (self.searchText.length > 0) return nil;
    NSDictionary *voice = [self listForSection:indexPath.section][indexPath.row];
    NSString *vid = voice[@"voiceType"];
    if (!vid.length) return nil;
    UIContextualAction *avatar = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"换头像" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        self.pendingAvatarVoiceID = vid;
        [self aweca_presentPhotoPicker];
        completionHandler(YES);
    }];
    avatar.backgroundColor = [UIColor systemPurpleColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[avatar]];
}

#pragma mark - 分享 / 从剪贴板导入（v0.4.54）

// 分享格式＝一行标题 + 标准音色 JSON 数组。
// 解析器（sl_parseVoiceJSONText:）会自己找第一个 [ ，所以对方无论走
// 「从剪贴板导入」还是「粘贴 JSON 导入」都能直接吃下来，不用删标题行。
- (NSString *)sl_shareTextForVoices:(NSArray<NSDictionary *> *)voices {
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *v in voices) {
        if (![v isKindOfClass:[NSDictionary class]]) continue;
        NSString *vid = v[@"voiceType"];
        if (!vid.length) continue;
        [arr addObject:@{ @"name": (v[@"name"] ?: vid), @"voiceType": vid }];
    }
    if (!arr.count) return nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (!json.length) return nil;
    return [NSString stringWithFormat:@"声临 · 音色分享（%lu 个）\n%@", (unsigned long)arr.count, json];
}

- (void)sl_shareVoices:(NSArray<NSDictionary *> *)voices fromView:(UIView *)anchor {
    if (!self.fishMode) {
        // 火山引擎的音色 ID 只在自己账号下有效，分享出去别人也用不了
        [AWECAUtils showToast:@"只有 Fish 音色可以分享" duration:2.0];
        return;
    }
    NSString *text = [self sl_shareTextForVoices:voices];
    if (!text.length) { [AWECAUtils showToast:@"没有可分享的音色"]; return; }

    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    if (av.popoverPresentationController) {
        UIView *src = anchor ?: self.view;
        av.popoverPresentationController.sourceView = src;
        av.popoverPresentationController.sourceRect =
            anchor ? anchor.bounds : CGRectMake(src.bounds.size.width / 2.0, src.bounds.size.height / 2.0, 1, 1);
    }
    [self presentViewController:av animated:YES completion:nil];
}

- (void)sl_importFromPasteboard {
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (!text.length) {
        [AWECAUtils showToast:@"剪贴板是空的" duration:1.5];
        return;
    }
    NSInteger skipped = 0;
    NSArray<NSDictionary *> *items = [AWECATTSManager sl_parseVoiceJSONText:text skipped:&skipped];
    if (!items.count) {
        [AWECAUtils showToast:@"剪贴板里没找到音色 JSON" duration:2.0];
        return;
    }
    NSDictionary *r = [AWECATTSManager sl_importFishVoices:items];
    [self loadCustomVoices];
    [self filterVoices];
    [self.tableView reloadData];
    [AWECAUtils showToast:[NSString stringWithFormat:@"导入 %ld 个，更新 %ld 个",
                           (long)[r[@"added"] integerValue], (long)[r[@"updated"] integerValue]]
                 duration:2.0];
}

#pragma mark - 多选导出（v0.4.54）

// 多选只作用于「我导入的音色」：勾一堆 → 导出成同一段分享文本。
// 进口这一侧本来就能多选（导入页的勾选 + 全选 / 全取消），所以两端都齐了。
- (void)sl_beginMultiSelect {
    if (!self.fishMode) { [AWECAUtils showToast:@"只有 Fish 音色可以导出" duration:1.8]; return; }
    if (!self.customVoices.count) { [AWECAUtils showToast:@"还没有自建音色" duration:1.5]; return; }
    self.multiSelect = YES;
    [self.multiSel removeAllObjects];
    [self sl_updateMultiChrome];
    [self.tableView reloadData];
}

- (void)sl_endMultiSelect {
    self.multiSelect = NO;
    [self.multiSel removeAllObjects];
    [self sl_updateMultiChrome];
    [self.tableView reloadData];
}

- (void)sl_updateMultiChrome {
    if (self.multiSelect) {
        // rightBarButtonItems[0] 在最右边：导出 / 全选 / 取消
        self.navigationItem.rightBarButtonItems = @[
            SLPillBarItem(@"导出", self, @selector(sl_exportSelected)),
            SLPillBarItem(@"全选", self, @selector(sl_toggleSelectAll)),
            SLPillBarItem(@"取消", self, @selector(sl_endMultiSelect)),
        ];
    } else {
        self.navigationItem.rightBarButtonItems = nil;
        self.navigationItem.rightBarButtonItem =
            SLPillIconBarItem(@"plus", @"添加", self,
                              self.fishMode ? @selector(aweca_showAddPanel) : @selector(addCustomVoice));
    }
}

- (void)sl_toggleSelectAll {
    NSArray<NSDictionary *> *rows = self.filteredCustom;
    if (rows.count && self.multiSel.count >= rows.count) {
        [self.multiSel removeAllObjects];
    } else {
        for (NSDictionary *v in rows) {
            NSString *t = v[@"voiceType"];
            if (t.length) [self.multiSel addObject:t];
        }
    }
    [self.tableView reloadData];
}

- (void)sl_exportSelected {
    NSMutableArray<NSDictionary *> *picked = [NSMutableArray array];
    for (NSDictionary *v in self.filteredCustom) {
        if ([self.multiSel containsObject:v[@"voiceType"]]) [picked addObject:v];
    }
    if (!picked.count) { [AWECAUtils showToast:@"先勾选要导出的音色" duration:1.5]; return; }
    [self sl_shareVoices:picked fromView:nil];
}

- (void)aweca_pushImportWithMode:(SLImportMode)mode {
    SLVoiceImportController *vc = [[SLVoiceImportController alloc] init];
    vc.initialMode = mode;
    __weak typeof(self) ws = self;
    vc.onImported = ^(NSInteger added, NSInteger updated) {
        [ws loadCustomVoices];
        [ws filterVoices];
        [ws.tableView reloadData];
        [AWECAUtils showToast:[NSString stringWithFormat:@"导入 %ld 个，更新 %ld 个", (long)added, (long)updated]
                     duration:2.0];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 试听

- (void)previewVoice:(UIButton *)btn {
    NSString *type = objc_getAssociatedObject(btn, "voiceType");
    if (!type) return;

    AWECATTSManager *mgr = [AWECATTSManager shared];

    if ([mgr isPlaying]) {
        [mgr stopPlayback];
        return;
    }

    if (self.fishMode) {
        NSString *origType = mgr.fishVoiceType;
        NSString *origName = mgr.fishVoiceName;
        mgr.fishVoiceType = type;
        BOOL origEngine = mgr.fishEngine;
        mgr.fishEngine = YES;
        [AWECAUtils showToast:@"正在试听..."];
        [mgr synthesizeFishText:@"你好，这是语音试听" previewOnly:YES completion:^(BOOL success, NSString *audioPath, NSString *error) {
            mgr.fishVoiceType = origType;
            mgr.fishVoiceName = origName;
            mgr.fishEngine = origEngine;
            if (success && audioPath) {
                [mgr playAudioAtPath:audioPath];
            } else {
                [AWECAUtils showToast:error ?: @"试听失败"];
            }
        }];
        return;
    }

    NSString *origType = mgr.voiceType;
    NSString *origName = mgr.voiceName;

    mgr.voiceType = type;

    [AWECAUtils showToast:@"正在试听..."];
    [mgr previewText:@"你好，这是语音试听" completion:^(BOOL success, NSString *audioPath, NSString *error) {
        mgr.voiceType = origType;
        mgr.voiceName = origName;

        if (success && audioPath) {
            [mgr playAudioAtPath:audioPath];
        } else {
            [AWECAUtils showToast:error ?: @"试听失败"];
        }
    }];
}

#pragma mark - 头像自定义（长按音色 → 相册选图）

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // v0.4.50：表格透明后统一刷玻璃片底色（两种模式都走这里，不用逐分支追）
    cell.backgroundColor = SLGlassCellColor();
    if (!self.fishMode) return;
    if (![cell.gestureRecognizers count]) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(aweca_longPressCell:)];
        [cell addGestureRecognizer:lp];
    }
}

- (void)aweca_longPressCell:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    if (self.multiSelect) return;            // 已在多选态，忽略
    if (!self.fishMode) { [AWECAUtils showToast:@"只有 Fish 音色可以导出"]; return; }
    UITableViewCell *cell = (UITableViewCell *)gr.view;
    NSIndexPath *ip = [self.tableView indexPathForCell:cell];
    if (!ip) return;
    NSDictionary *voice = [self listForSection:ip.section][ip.row];
    NSString *vid = voice[@"voiceType"];
    if (!vid.length) return;
    // v0.4.57：长按音色＝进入多选导出态，并预选长按的那一个
    //（仅「我导入的音色」section 0 可导出；头像更换已移到右滑）。
    self.multiSelect = YES;
    [self.multiSel removeAllObjects];
    if (ip.section == 0) [self.multiSel addObject:vid];
    [self sl_updateMultiChrome];
    [self.tableView reloadData];
}

- (void)aweca_presentPhotoPicker {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSString *vid = self.pendingAvatarVoiceID;
    self.pendingAvatarVoiceID = nil;
    if (!vid.length || results.count == 0) return;
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:[UIImage class]]) return;
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> obj, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![obj isKindOfClass:[UIImage class]]) {
                [AWECAUtils showToast:@"读取图片失败"];
                return;
            }
            BOOL ok = [[AWECATTSManager shared] saveFishAvatarImage:(UIImage *)obj forVoiceID:vid];
            [AWECAUtils showToast:ok ? @"头像已更新" : @"头像保存失败"];
            [weakSelf.tableView reloadData];
        });
    }];
}

#pragma mark - 音色数据

- (void)buildVoiceData {
    self.allVoices = @[
        @{@"name": @"Vivi 2.0", @"voiceType": @"zh_female_vv_uranus_bigtts"},
        @{@"name": @"小何 2.0", @"voiceType": @"zh_female_xiaohe_uranus_bigtts"},
        @{@"name": @"云舟 2.0", @"voiceType": @"zh_male_m191_uranus_bigtts"},
        @{@"name": @"小天 2.0", @"voiceType": @"zh_male_taocheng_uranus_bigtts"},
        @{@"name": @"刘飞 2.0", @"voiceType": @"zh_male_liufei_uranus_bigtts"},
        @{@"name": @"魅力苏菲 2.0", @"voiceType": @"zh_female_sophie_uranus_bigtts"},
        @{@"name": @"清新女声 2.0", @"voiceType": @"zh_female_qingxinnvsheng_uranus_bigtts"},
        @{@"name": @"知性灿灿 2.0", @"voiceType": @"zh_female_cancan_uranus_bigtts"},
        @{@"name": @"撒娇学妹 2.0", @"voiceType": @"zh_female_sajiaoxuemei_uranus_bigtts"},
        @{@"name": @"甜美小源 2.0", @"voiceType": @"zh_female_tianmeixiaoyuan_uranus_bigtts"},
        @{@"name": @"甜美桃子 2.0", @"voiceType": @"zh_female_tianmeitaozi_uranus_bigtts"},
        @{@"name": @"爽快思思 2.0", @"voiceType": @"zh_female_shuangkuaisisi_uranus_bigtts"},
        @{@"name": @"佩奇猪 2.0", @"voiceType": @"zh_female_peiqi_uranus_bigtts"},
        @{@"name": @"邻家女孩 2.0", @"voiceType": @"zh_female_linjianvhai_uranus_bigtts"},
        @{@"name": @"少年梓辛 2.0", @"voiceType": @"zh_male_shaonianzixin_uranus_bigtts"},
        @{@"name": @"猴哥 2.0", @"voiceType": @"zh_male_sunwukong_uranus_bigtts"},
        @{@"name": @"Tina老师 2.0", @"voiceType": @"zh_female_yingyujiaoxue_uranus_bigtts"},
        @{@"name": @"暖阳女声 2.0", @"voiceType": @"zh_female_kefunvsheng_uranus_bigtts"},
        @{@"name": @"儿童绘本 2.0", @"voiceType": @"zh_female_xiaoxue_uranus_bigtts"},
        @{@"name": @"大壹 2.0", @"voiceType": @"zh_male_dayi_uranus_bigtts"},
        @{@"name": @"黑猫侦探社咪仔 2.0", @"voiceType": @"zh_female_mizai_uranus_bigtts"},
        @{@"name": @"鸡汤女 2.0", @"voiceType": @"zh_female_jitangnv_uranus_bigtts"},
        @{@"name": @"魅力女友 2.0", @"voiceType": @"zh_female_meilinvyou_uranus_bigtts"},
        @{@"name": @"流畅女声 2.0", @"voiceType": @"zh_female_liuchangnv_uranus_bigtts"},
        @{@"name": @"儒雅逸辰 2.0", @"voiceType": @"zh_male_ruyayichen_uranus_bigtts"},
        @{@"name": @"Tim", @"voiceType": @"en_male_tim_uranus_bigtts"},
        @{@"name": @"Dacey", @"voiceType": @"en_female_dacey_uranus_bigtts"},
        @{@"name": @"Stokie", @"voiceType": @"en_female_stokie_uranus_bigtts"},
        @{@"name": @"温柔妈妈 2.0", @"voiceType": @"zh_female_wenroumama_uranus_bigtts"},
        @{@"name": @"解说小明 2.0", @"voiceType": @"zh_male_jieshuoxiaoming_uranus_bigtts"},
        @{@"name": @"TVB女声 2.0", @"voiceType": @"zh_female_tvbnv_uranus_bigtts"},
        @{@"name": @"译制片男 2.0", @"voiceType": @"zh_male_yizhipiannan_uranus_bigtts"},
        @{@"name": @"俏皮女声 2.0", @"voiceType": @"zh_female_qiaopinv_uranus_bigtts"},
        @{@"name": @"直率英子 2.0", @"voiceType": @"zh_female_zhishuaiyingzi_uranus_bigtts"},
        @{@"name": @"邻家男孩 2.0", @"voiceType": @"zh_male_linjiananhai_uranus_bigtts"},
        @{@"name": @"四郎 2.0", @"voiceType": @"zh_male_silang_uranus_bigtts"},
        @{@"name": @"儒雅青年 2.0", @"voiceType": @"zh_male_ruyaqingnian_uranus_bigtts"},
        @{@"name": @"擎苍 2.0", @"voiceType": @"zh_male_qingcang_uranus_bigtts"},
        @{@"name": @"熊二 2.0", @"voiceType": @"zh_male_xionger_uranus_bigtts"},
        @{@"name": @"樱桃丸子 2.0", @"voiceType": @"zh_female_yingtaowanzi_uranus_bigtts"},
        @{@"name": @"温暖阿虎 2.0", @"voiceType": @"zh_male_wennuanahu_uranus_bigtts"},
        @{@"name": @"奶气萌娃 2.0", @"voiceType": @"zh_male_naiqimengwa_uranus_bigtts"},
        @{@"name": @"婆婆 2.0", @"voiceType": @"zh_female_popo_uranus_bigtts"},
        @{@"name": @"高冷御姐 2.0", @"voiceType": @"zh_female_gaolengyujie_uranus_bigtts"},
        @{@"name": @"傲娇霸总 2.0", @"voiceType": @"zh_male_aojiaobazong_uranus_bigtts"},
        @{@"name": @"懒音绵宝 2.0", @"voiceType": @"zh_male_lanyinmianbao_uranus_bigtts"},
        @{@"name": @"反卷青年 2.0", @"voiceType": @"zh_male_fanjuanqingnian_uranus_bigtts"},
        @{@"name": @"温柔淑女 2.0", @"voiceType": @"zh_female_wenroushunv_uranus_bigtts"},
        @{@"name": @"古风少御 2.0", @"voiceType": @"zh_female_gufengshaoyu_uranus_bigtts"},
        @{@"name": @"活力小哥 2.0", @"voiceType": @"zh_male_huolixiaoge_uranus_bigtts"},
        @{@"name": @"霸气青叔 2.0", @"voiceType": @"zh_male_baqiqingshu_uranus_bigtts"},
        @{@"name": @"悬疑解说 2.0", @"voiceType": @"zh_male_xuanyijieshuo_uranus_bigtts"},
        @{@"name": @"萌丫头 2.0", @"voiceType": @"zh_female_mengyatou_uranus_bigtts"},
        @{@"name": @"贴心女声 2.0", @"voiceType": @"zh_female_tiexinnvsheng_uranus_bigtts"},
        @{@"name": @"鸡汤妹妹 2.0", @"voiceType": @"zh_female_jitangmei_uranus_bigtts"},
        @{@"name": @"磁性解说男声 2.0", @"voiceType": @"zh_male_cixingjieshuonan_uranus_bigtts"},
        @{@"name": @"亮嗓萌仔 2.0", @"voiceType": @"zh_male_liangsangmengzai_uranus_bigtts"},
        @{@"name": @"开朗姐姐 2.0", @"voiceType": @"zh_female_kailangjiejie_uranus_bigtts"},
        @{@"name": @"高冷沉稳 2.0", @"voiceType": @"zh_male_gaolengchenwen_uranus_bigtts"},
        @{@"name": @"深夜播客 2.0", @"voiceType": @"zh_male_shenyeboke_uranus_bigtts"},
        @{@"name": @"鲁班七号 2.0", @"voiceType": @"zh_male_lubanqihao_uranus_bigtts"},
        @{@"name": @"娇喘女声 2.0", @"voiceType": @"zh_female_jiaochuannv_uranus_bigtts"},
        @{@"name": @"林潇 2.0", @"voiceType": @"zh_female_linxiao_uranus_bigtts"},
        @{@"name": @"玲玲姐姐 2.0", @"voiceType": @"zh_female_lingling_uranus_bigtts"},
        @{@"name": @"春日部姐姐 2.0", @"voiceType": @"zh_female_chunribu_uranus_bigtts"},
        @{@"name": @"唐僧 2.0", @"voiceType": @"zh_male_tangseng_uranus_bigtts"},
        @{@"name": @"庄周 2.0", @"voiceType": @"zh_male_zhuangzhou_uranus_bigtts"},
        @{@"name": @"开朗弟弟 2.0", @"voiceType": @"zh_male_kailangdidi_uranus_bigtts"},
        @{@"name": @"猪八戒 2.0", @"voiceType": @"zh_male_zhubajie_uranus_bigtts"},
        @{@"name": @"感冒电音姐姐 2.0", @"voiceType": @"zh_female_ganmaodianyin_uranus_bigtts"},
        @{@"name": @"谄媚女声 2.0", @"voiceType": @"zh_female_chanmeinv_uranus_bigtts"},
        @{@"name": @"女雷神 2.0", @"voiceType": @"zh_female_nvleishen_uranus_bigtts"},
        @{@"name": @"亲切女声 2.0", @"voiceType": @"zh_female_qinqienv_uranus_bigtts"},
        @{@"name": @"快乐小东 2.0", @"voiceType": @"zh_male_kuailexiaodong_uranus_bigtts"},
        @{@"name": @"开朗学长 2.0", @"voiceType": @"zh_male_kailangxuezhang_uranus_bigtts"},
        @{@"name": @"悠悠君子 2.0", @"voiceType": @"zh_male_youyoujunzi_uranus_bigtts"},
        @{@"name": @"文静毛毛 2.0", @"voiceType": @"zh_female_wenjingmaomao_uranus_bigtts"},
        @{@"name": @"知性女声 2.0", @"voiceType": @"zh_female_zhixingnv_uranus_bigtts"},
        @{@"name": @"清爽男大 2.0", @"voiceType": @"zh_male_qingshuangnanda_uranus_bigtts"},
        @{@"name": @"渊博小叔 2.0", @"voiceType": @"zh_male_yuanboxiaoshu_uranus_bigtts"},
        @{@"name": @"阳光青年 2.0", @"voiceType": @"zh_male_yangguangqingnian_uranus_bigtts"},
        @{@"name": @"清澈梓梓 2.0", @"voiceType": @"zh_female_qingchezizi_uranus_bigtts"},
        @{@"name": @"甜美悦悦 2.0", @"voiceType": @"zh_female_tianmeiyueyue_uranus_bigtts"},
        @{@"name": @"心灵鸡汤 2.0", @"voiceType": @"zh_female_xinlingjitang_uranus_bigtts"},
        @{@"name": @"温柔小哥 2.0", @"voiceType": @"zh_male_wenrouxiaoge_uranus_bigtts"},
        @{@"name": @"柔美女友 2.0", @"voiceType": @"zh_female_roumeinvyou_uranus_bigtts"},
        @{@"name": @"东方浩然 2.0", @"voiceType": @"zh_male_dongfanghaoran_uranus_bigtts"},
        @{@"name": @"温柔小雅 2.0", @"voiceType": @"zh_female_wenrouxiaoya_uranus_bigtts"},
        @{@"name": @"天才童声 2.0", @"voiceType": @"zh_male_tiancaitongsheng_uranus_bigtts"},
        @{@"name": @"武则天 2.0", @"voiceType": @"zh_female_wuzetian_uranus_bigtts"},
        @{@"name": @"顾姐 2.0", @"voiceType": @"zh_female_gujie_uranus_bigtts"},
        @{@"name": @"广告解说 2.0", @"voiceType": @"zh_male_guanggaojieshuo_uranus_bigtts"},
        @{@"name": @"少儿故事 2.0", @"voiceType": @"zh_female_shaoergushi_uranus_bigtts"},
        @{@"name": @"Charlie 2.0", @"voiceType": @"ICL_uranus_en_female_charlie_tob"},
        @{@"name": @"Ethan 2.0", @"voiceType": @"ICL_uranus_en_male_ethan_tob"},
        @{@"name": @"Alastor 2.0", @"voiceType": @"ICL_uranus_en_male_alastor_tob"},
        @{@"name": @"Chucky 2.0", @"voiceType": @"ICL_uranus_en_male_chucky_tob"},
        @{@"name": @"Noah 2.0", @"voiceType": @"ICL_uranus_en_male_noah_tob"},
        @{@"name": @"Jigsaw 2.0", @"voiceType": @"ICL_uranus_en_male_jigsaw_tob"},
        @{@"name": @"Clown Man 2.0", @"voiceType": @"ICL_uranus_en_male_clown_man_tob"},
        @{@"name": @"Cartoon Chef 2.0", @"voiceType": @"ICL_uranus_en_male_cartoon_chef_tob"},
        @{@"name": @"Frosty Man 2.0", @"voiceType": @"ICL_uranus_en_male_frosty_man_tob"},
        @{@"name": @"The Grinch 2.0", @"voiceType": @"ICL_uranus_en_male_the_grinch_tob"},
        @{@"name": @"Kevin McCallister 2.0", @"voiceType": @"ICL_uranus_en_male_kevin_mccallister_tob"},
        @{@"name": @"Michael 2.0", @"voiceType": @"ICL_uranus_en_male_michael_tob"},
        @{@"name": @"Big Boogie 2.0", @"voiceType": @"ICL_uranus_en_male_big_boogie_tob"},
        @{@"name": @"Xavier 2.0", @"voiceType": @"ICL_uranus_en_male_xavier_tob"},
        @{@"name": @"Zayne 2.0", @"voiceType": @"ICL_uranus_en_male_zayne_tob"},
        @{@"name": @"客服婉君 2.0", @"voiceType": @"ICL_uranus_zh_female_kefuwanjun_tob"},
        @{@"name": @"营销小楠 2.0", @"voiceType": @"ICL_uranus_zh_female_yingxiaokefu_v2_tob"},
        @{@"name": @"傲娇女友 2.0", @"voiceType": @"ICL_uranus_zh_female_aojiaonvyou_tob"},
        @{@"name": @"傲慢娇声 2.0", @"voiceType": @"ICL_uranus_zh_female_aomanjiaosheng_tob"},
        @{@"name": @"邪魅女王 2.0", @"voiceType": @"ICL_uranus_zh_female_xiemeinvwang_tob"},
        @{@"name": @"病娇姐姐 2.0", @"voiceType": @"ICL_uranus_zh_female_bingjiaojiejie_tob"},
        @{@"name": @"病娇萌妹 2.0", @"voiceType": @"ICL_uranus_zh_female_bingjiaomengmei_tob"},
        @{@"name": @"病弱少女 2.0", @"voiceType": @"ICL_uranus_zh_female_bingruoshaonv_tob"},
        @{@"name": @"成熟温柔 2.0", @"voiceType": @"ICL_uranus_zh_female_chengshuwenrou_tob"},
        @{@"name": @"成熟姐姐 2.0", @"voiceType": @"ICL_uranus_zh_female_chengshujiejie_tob"},
        @{@"name": @"纯真少女 2.0", @"voiceType": @"ICL_uranus_zh_female_chunzhenshaonv_tob"},
        @{@"name": @"纯澈女生 2.0", @"voiceType": @"ICL_uranus_zh_female_chunchenvsheng_tob"},
        @{@"name": @"妩媚可人 2.0", @"voiceType": @"ICL_uranus_zh_female_wumeikeren_tob"},
        @{@"name": @"乖巧可儿 2.0", @"voiceType": @"ICL_uranus_zh_female_guaiqiaokeer_tob"},
        @{@"name": @"和蔼奶奶 2.0", @"voiceType": @"ICL_uranus_zh_female_heainainai_tob"},
        @{@"name": @"活泼刁蛮 2.0", @"voiceType": @"ICL_uranus_zh_female_huopodiaoman_tob"},
        @{@"name": @"活泼女孩 2.0", @"voiceType": @"ICL_uranus_zh_female_huoponvhai_tob"},
        @{@"name": @"娇憨女王 2.0", @"voiceType": @"ICL_uranus_zh_female_jiaohannvwang_tob"},
        @{@"name": @"娇弱萝莉 2.0", @"voiceType": @"ICL_uranus_zh_female_jiaoruoluoli_tob"},
        @{@"name": @"假小子 2.0", @"voiceType": @"ICL_uranus_zh_female_jiaxiaozi_tob"},
        @{@"name": @"精灵向导 2.0", @"voiceType": @"ICL_uranus_zh_female_jinglingxiangdao_tob"},
        @{@"name": @"开朗婷婷 2.0", @"voiceType": @"ICL_uranus_zh_female_kailangtingting_tob"},
        @{@"name": @"开心小鸿 2.0", @"voiceType": @"ICL_uranus_zh_female_kaixinxiaohong_tob"},
        @{@"name": @"可爱女生 2.0", @"voiceType": @"ICL_uranus_zh_female_keainvsheng_tob"},
        @{@"name": @"灵动欣欣 2.0", @"voiceType": @"ICL_uranus_zh_female_lingdongxinxin_tob"},
        @{@"name": @"邻居阿姨 2.0", @"voiceType": @"ICL_uranus_zh_female_linjuayi_tob"},
        @{@"name": @"甜美娇俏 2.0", @"voiceType": @"ICL_uranus_zh_female_tianmeijiaoqiao_tob"},
        @{@"name": @"清冷高雅 2.0", @"voiceType": @"ICL_uranus_zh_female_qinglenggaoya_tob"},
        @{@"name": @"理性圆子 2.0", @"voiceType": @"ICL_uranus_zh_female_lixingyuanzi_tob"},
        @{@"name": @"性感魅惑 2.0", @"voiceType": @"ICL_uranus_zh_female_xingganmeihuo_tob"},
        @{@"name": @"暖心茜茜 2.0", @"voiceType": @"ICL_uranus_zh_female_nuanxinqianqian_tob"},
        @{@"name": @"暖心学姐 2.0", @"voiceType": @"ICL_uranus_zh_female_nuanxinxuejie_tob"},
        @{@"name": @"清甜莓莓 2.0", @"voiceType": @"ICL_uranus_zh_female_qingtianmeimei_tob"},
        @{@"name": @"清甜桃桃 2.0", @"voiceType": @"ICL_uranus_zh_female_qingtiantaotao_tob"},
        @{@"name": @"清晰小雪 2.0", @"voiceType": @"ICL_uranus_zh_female_qingxixiaoxue_tob"},
        @{@"name": @"倾心少女 2.0", @"voiceType": @"ICL_uranus_zh_female_qingxinshaonv_tob"},
        @{@"name": @"柔骨魂师 2.0", @"voiceType": @"ICL_uranus_zh_female_rouguhunshi_tob"},
        @{@"name": @"软萌糖糖 2.0", @"voiceType": @"ICL_uranus_zh_female_ruanmengtangtang_tob"},
        @{@"name": @"软萌团子 2.0", @"voiceType": @"ICL_uranus_zh_female_ruanmengtuanzi_tob"},
        @{@"name": @"甜美活泼 2.0", @"voiceType": @"ICL_uranus_zh_female_tianmeihuopo_tob"},
        @{@"name": @"甜美小橘 2.0", @"voiceType": @"ICL_uranus_zh_female_tianmeixiaoju_tob"},
        @{@"name": @"甜美小雨 2.0", @"voiceType": @"ICL_uranus_zh_female_tianmeixiaoyu_tob"},
        @{@"name": @"调皮公主 2.0", @"voiceType": @"ICL_uranus_zh_female_tiaopigongzhu_tob"},
        @{@"name": @"贴心女友 2.0", @"voiceType": @"ICL_uranus_zh_female_tiexinnvyou_tob"},
        @{@"name": @"温柔女神 2.0", @"voiceType": @"ICL_uranus_zh_female_wenrounvshen_tob"},
        @{@"name": @"温柔文雅 2.0", @"voiceType": @"ICL_uranus_zh_female_wenrouwenya_tob"},
        @{@"name": @"知心姐姐 2.0", @"voiceType": @"ICL_uranus_zh_female_zhixinjiejie_tob"},
        @{@"name": @"妩媚御姐 2.0", @"voiceType": @"ICL_uranus_zh_female_wumeiyujie_tob"},
        @{@"name": @"元气甜妹 2.0", @"voiceType": @"ICL_uranus_zh_female_yuanqitianmei_tob"},
        @{@"name": @"邪魅御姐 2.0", @"voiceType": @"ICL_uranus_zh_female_xiemeiyujie_tob"},
        @{@"name": @"性感御姐 2.0", @"voiceType": @"ICL_uranus_zh_female_xingganyujie_tob"},
        @{@"name": @"秀丽倩倩 2.0", @"voiceType": @"ICL_uranus_zh_female_xiuliqianqian_tob"},
        @{@"name": @"贴心闺蜜 2.0", @"voiceType": @"ICL_uranus_zh_female_tiexinguimi_tob"},
        @{@"name": @"贴心妹妹 2.0", @"voiceType": @"ICL_uranus_zh_female_tiexinmeimei_tob"},
        @{@"name": @"温柔白月光 2.0", @"voiceType": @"ICL_uranus_zh_female_wenroubaiyueguang_tob"},
        @{@"name": @"初恋女友 2.0", @"voiceType": @"ICL_uranus_zh_female_chuliannvyou_tob"},
        @{@"name": @"知性温婉 2.0", @"voiceType": @"ICL_uranus_zh_female_zhixingwenwan_tob"},
        @{@"name": @"傲气凌人 2.0", @"voiceType": @"ICL_uranus_zh_male_aoqilingren_tob"},
        @{@"name": @"黯刃秦主 2.0", @"voiceType": @"ICL_uranus_zh_male_anrenqinzhu_tob"},
        @{@"name": @"傲娇公子 2.0", @"voiceType": @"ICL_uranus_zh_male_aojiaogongzi_tob"},
        @{@"name": @"傲娇精英 2.0", @"voiceType": @"ICL_uranus_zh_male_aojiaojingying_tob"},
        @{@"name": @"傲慢青年 2.0", @"voiceType": @"ICL_uranus_zh_male_aomanqingnian_tob"},
        @{@"name": @"傲慢少爷 2.0", @"voiceType": @"ICL_uranus_zh_male_aomanshaoye_tob"},
        @{@"name": @"枕边低语 2.0", @"voiceType": @"ICL_uranus_zh_male_zhenbiandiyu_tob"},
        @{@"name": @"霸道少爷 2.0", @"voiceType": @"ICL_uranus_zh_male_badaoshaoye_tob"},
        @{@"name": @"霸道总裁 2.0", @"voiceType": @"ICL_uranus_zh_male_badaozongcai_tob"},
        @{@"name": @"病娇白莲 2.0", @"voiceType": @"ICL_uranus_zh_male_bingjiaobailian_tob"},
        @{@"name": @"病娇弟弟 2.0", @"voiceType": @"ICL_uranus_zh_male_bingjiaodidi_tob"},
        @{@"name": @"病娇哥哥 2.0", @"voiceType": @"ICL_uranus_zh_male_bingjiaogege_tob"},
        @{@"name": @"病娇男友 2.0", @"voiceType": @"ICL_uranus_zh_male_bingjiaonanyou_tob"},
        @{@"name": @"病娇少年 2.0", @"voiceType": @"ICL_uranus_zh_male_bingjiaoshaonian_tob"},
        @{@"name": @"病弱公子 2.0", @"voiceType": @"ICL_uranus_zh_male_bingruogongzi_tob"},
        @{@"name": @"病弱少年 2.0", @"voiceType": @"ICL_uranus_zh_male_bingruoshaonian_tob"},
        @{@"name": @"不羁青年 2.0", @"voiceType": @"ICL_uranus_zh_male_bujiqingnian_tob"},
        @{@"name": @"醇厚低音 2.0", @"voiceType": @"ICL_uranus_zh_male_chunhoudiyin_tob"},
        @{@"name": @"咆哮小哥 2.0", @"voiceType": @"ICL_uranus_zh_male_paoxiaoxiaoge_tob"},
        @{@"name": @"炀炀 2.0", @"voiceType": @"ICL_uranus_zh_male_yangyang_tob"},
        @{@"name": @"孱弱少爷 2.0", @"voiceType": @"ICL_uranus_zh_male_chanruoshaoye_tob"},
        @{@"name": @"成熟总裁 2.0", @"voiceType": @"ICL_uranus_zh_male_chengshuzongcai_tob"},
        @{@"name": @"沉稳明仔 2.0", @"voiceType": @"ICL_uranus_zh_male_chenwenmingzai_tob"},
        @{@"name": @"清逸苏感 2.0", @"voiceType": @"ICL_uranus_zh_male_qingyisugan_tob"},
        @{@"name": @"纯真学弟 2.0", @"voiceType": @"ICL_uranus_zh_male_chunzhenxuedi_tob"},
        @{@"name": @"磁性男嗓 2.0", @"voiceType": @"ICL_uranus_zh_male_cixingnansang_tob"},
        @{@"name": @"醋精男生 2.0", @"voiceType": @"ICL_uranus_zh_male_cujingnansheng_tob"},
        @{@"name": @"醋精男友 2.0", @"voiceType": @"ICL_uranus_zh_male_cujingnanyou_tob"},
        @{@"name": @"低音沉郁 2.0", @"voiceType": @"ICL_uranus_zh_male_diyinchenyu_tob"},
        @{@"name": @"风发少年 2.0", @"voiceType": @"ICL_uranus_zh_male_fengfashaonian_tob"},
        @{@"name": @"儒雅公子 2.0", @"voiceType": @"ICL_uranus_zh_male_ruyagongzi_tob"},
        @{@"name": @"腹黑公子 2.0", @"voiceType": @"ICL_uranus_zh_male_fuheigongzi_tob"},
        @{@"name": @"干净少年 2.0", @"voiceType": @"ICL_uranus_zh_male_ganjingshaonian_tob"},
        @{@"name": @"高冷总裁 2.0", @"voiceType": @"ICL_uranus_zh_male_gaolengzongcai_tob"},
        @{@"name": @"孤傲公子 2.0", @"voiceType": @"ICL_uranus_zh_male_guaogongzi_tob"},
        @{@"name": @"孤高公子 2.0", @"voiceType": @"ICL_uranus_zh_male_gugaogongzi_tob"},
        @{@"name": @"诡异神秘 2.0", @"voiceType": @"ICL_uranus_zh_male_guiyishenmi_tob"},
        @{@"name": @"固执病娇 2.0", @"voiceType": @"ICL_uranus_zh_male_guzhibingjiao_tob"},
        @{@"name": @"憨厚敦实 2.0", @"voiceType": @"ICL_uranus_zh_male_hanhoudunshi_tob"},
        @{@"name": @"活力青年 2.0", @"voiceType": @"ICL_uranus_zh_male_huoliqingnian_tob"},
        @{@"name": @"活泼男友 2.0", @"voiceType": @"ICL_uranus_zh_male_huoponanyou_tob"},
        @{@"name": @"活泼爽朗 2.0", @"voiceType": @"ICL_uranus_zh_male_huoposhuanglang_tob"},
        @{@"name": @"胡子叔叔 2.0", @"voiceType": @"ICL_uranus_zh_male_huzishushu_tob"},
        @{@"name": @"机甲智能 2.0", @"voiceType": @"ICL_uranus_zh_male_jijiazhineng_tob"},
        @{@"name": @"精英青年 2.0", @"voiceType": @"ICL_uranus_zh_male_jingyingqingnian_tob"},
        @{@"name": @"俊逸公子 2.0", @"voiceType": @"ICL_uranus_zh_male_junyigongzi_tob"},
        @{@"name": @"开朗轻快 2.0", @"voiceType": @"ICL_uranus_zh_male_kailangqingkuai_tob"},
        @{@"name": @"开朗青年 2.0", @"voiceType": @"ICL_uranus_zh_male_kailangqingnian_tob"},
        @{@"name": @"蓝银草魂师 2.0", @"voiceType": @"ICL_uranus_zh_male_lanyincaohunshi_tob"},
        @{@"name": @"冷傲总裁 2.0", @"voiceType": @"ICL_uranus_zh_male_lengaozongcai_tob"},
        @{@"name": @"冷淡疏离 2.0", @"voiceType": @"ICL_uranus_zh_male_lengdanshuli_tob"},
        @{@"name": @"冷峻高智 2.0", @"voiceType": @"ICL_uranus_zh_male_lengjungaozhi_tob"},
        @{@"name": @"冷峻上司 2.0", @"voiceType": @"ICL_uranus_zh_male_lengjunshangsi_tob"},
        @{@"name": @"冷酷哥哥 2.0", @"voiceType": @"ICL_uranus_zh_male_lengkugege_tob"},
        @{@"name": @"冷脸兄长 2.0", @"voiceType": @"ICL_uranus_zh_male_lenglianxiongzhang_tob"},
        @{@"name": @"冷脸学霸 2.0", @"voiceType": @"ICL_uranus_zh_male_lenglianxueba_tob"},
        @{@"name": @"冷漠男友 2.0", @"voiceType": @"ICL_uranus_zh_male_lengmonanyou_tob"},
        @{@"name": @"冷漠兄长 2.0", @"voiceType": @"ICL_uranus_zh_male_lengmoxiongzhang_tob"},
        @{@"name": @"凌云青年 2.0", @"voiceType": @"ICL_uranus_zh_male_lingyunqingnian_tob"},
        @{@"name": @"清冷矜贵 2.0", @"voiceType": @"ICL_uranus_zh_male_qinglengjingui_tob"},
        @{@"name": @"绿茶小哥 2.0", @"voiceType": @"ICL_uranus_zh_male_lvchaxiaoge_tob"},
        @{@"name": @"懵懂青年 2.0", @"voiceType": @"ICL_uranus_zh_male_mengdongqingnian_tob"},
        @{@"name": @"闷油瓶小哥 2.0", @"voiceType": @"ICL_uranus_zh_male_menyoupingxiaoge_tob"},
        @{@"name": @"嚣张小哥 2.0", @"voiceType": @"ICL_uranus_zh_male_xiaozhangxiaoge_tob"},
        @{@"name": @"粘人男友 2.0", @"voiceType": @"ICL_uranus_zh_male_nianrennanyou_tob"},
        @{@"name": @"内敛才俊 2.0", @"voiceType": @"ICL_uranus_zh_male_neiliancaijun_tob"},
        @{@"name": @"暖心体贴 2.0", @"voiceType": @"ICL_uranus_zh_male_nuanxintitie_tob"},
        @{@"name": @"翩翩公子 2.0", @"voiceType": @"ICL_uranus_zh_male_pianpiangongzi_tob"},
        @{@"name": @"沉稳优雅 2.0", @"voiceType": @"ICL_uranus_zh_male_chenwenyouya_tob"},
        @{@"name": @"青涩小生 2.0", @"voiceType": @"ICL_uranus_zh_male_qingsexiaosheng_tob"},
        @{@"name": @"青涩青年 2.0", @"voiceType": @"ICL_uranus_zh_male_qingseqingnian_tob"},
        @{@"name": @"清爽少年 2.0", @"voiceType": @"ICL_uranus_zh_male_qingshuangshaonian_tob"},
        @{@"name": @"清新波波 2.0", @"voiceType": @"ICL_uranus_zh_male_qingxinbobo_tob"},
        @{@"name": @"亲切青年 2.0", @"voiceType": @"ICL_uranus_zh_male_qinqieqingnian_tob"},
        @{@"name": @"亲切小卓 2.0", @"voiceType": @"ICL_uranus_zh_male_qinqiexiaozhuo_tob"},
        @{@"name": @"清朗温润 2.0", @"voiceType": @"ICL_uranus_zh_male_qinglangwenrun_tob"},
        @{@"name": @"热血少年 2.0", @"voiceType": @"ICL_uranus_zh_male_rexueshaonian_tob"},
        @{@"name": @"儒雅才俊 2.0", @"voiceType": @"ICL_uranus_zh_male_ruyacaijun_tob"},
        @{@"name": @"儒雅君子 2.0", @"voiceType": @"ICL_uranus_zh_male_ruyajunzi_tob"},
        @{@"name": @"儒雅总裁 2.0", @"voiceType": @"ICL_uranus_zh_male_ruyazongcai_tob"},
        @{@"name": @"撒娇男生 2.0", @"voiceType": @"ICL_uranus_zh_male_sajiaonansheng_tob"},
        @{@"name": @"撒娇男友 2.0", @"voiceType": @"ICL_uranus_zh_male_sajiaonanyou_tob"},
        @{@"name": @"撒娇粘人 2.0", @"voiceType": @"ICL_uranus_zh_male_sajiaonianren_tob"},
        @{@"name": @"洒脱青年 2.0", @"voiceType": @"ICL_uranus_zh_male_satuoqingnian_tob"},
        @{@"name": @"少年将军 2.0", @"voiceType": @"ICL_uranus_zh_male_shaonianjiangjun_tob"},
        @{@"name": @"深沉总裁 2.0", @"voiceType": @"ICL_uranus_zh_male_shenchenzongcai_tob"},
        @{@"name": @"机灵小伙 2.0", @"voiceType": @"ICL_uranus_zh_male_jilingxiaohuo_tob"},
        @{@"name": @"神秘法师 2.0", @"voiceType": @"ICL_uranus_zh_male_shenmifashi_tob"},
        @{@"name": @"率真小伙 2.0", @"voiceType": @"ICL_uranus_zh_male_shuaizhenxiaohuo_tob"},
        @{@"name": @"爽朗小阳 2.0", @"voiceType": @"ICL_uranus_zh_male_shuanglangxiaoyang_tob"},
        @{@"name": @"低沉缱绻 2.0", @"voiceType": @"ICL_uranus_zh_male_dichenqianquan_tob"},
        @{@"name": @"斯文青年 2.0", @"voiceType": @"ICL_uranus_zh_male_siwenqingnian_tob"},
        @{@"name": @"甜系男友 2.0", @"voiceType": @"ICL_uranus_zh_male_tianxinanyou_tob"},
        @{@"name": @"贴心男友 2.0", @"voiceType": @"ICL_uranus_zh_male_tiexinnanyou_tob"},
        @{@"name": @"温柔男同桌 2.0", @"voiceType": @"ICL_uranus_zh_male_wenrounantongzhuo_tob"},
        @{@"name": @"温柔男友 2.0", @"voiceType": @"ICL_uranus_zh_male_wenrounanyou_tob"},
        @{@"name": @"温柔学长 2.0", @"voiceType": @"ICL_uranus_zh_male_wenrouxuezhang_tob"},
        @{@"name": @"温润学者 2.0", @"voiceType": @"ICL_uranus_zh_male_wenrunxuezhe_tob"},
        @{@"name": @"温顺少年 2.0", @"voiceType": @"ICL_uranus_zh_male_wenshunshaonian_tob"},
        @{@"name": @"寡言小哥 2.0", @"voiceType": @"ICL_uranus_zh_male_guayanxiaoge_tob"},
        @{@"name": @"小侯爷 2.0", @"voiceType": @"ICL_uranus_zh_male_xiaohouye_tob"},
        @{@"name": @"奶气小生 2.0", @"voiceType": @"ICL_uranus_zh_male_naiqixiaosheng_tob"},
        @{@"name": @"潇洒随性 2.0", @"voiceType": @"ICL_uranus_zh_male_xiaosasuixing_tob"},
        @{@"name": @"温柔内敛 2.0", @"voiceType": @"ICL_uranus_zh_male_wenrouneilian_tob"},
        @{@"name": @"学霸男同桌 2.0", @"voiceType": @"ICL_uranus_zh_male_xuebanantongzhuo_tob"},
        @{@"name": @"学霸同桌 2.0", @"voiceType": @"ICL_uranus_zh_male_xuebatongzhuo_tob"},
        @{@"name": @"阳光洋洋 2.0", @"voiceType": @"ICL_uranus_zh_male_yangguangyangyang_tob"},
        @{@"name": @"温暖少年 2.0", @"voiceType": @"ICL_uranus_zh_male_wennuanshaonian_tob"},
        @{@"name": @"意气少年 2.0", @"voiceType": @"ICL_uranus_zh_male_yiqishaonian_tob"},
        @{@"name": @"油腻大叔 2.0", @"voiceType": @"ICL_uranus_zh_male_younidashu_tob"},
        @{@"name": @"幽默大爷 2.0", @"voiceType": @"ICL_uranus_zh_male_youmodaye_tob"},
        @{@"name": @"幽默叔叔 2.0", @"voiceType": @"ICL_uranus_zh_male_youmoshushu_tob"},
        @{@"name": @"优柔帮主 2.0", @"voiceType": @"ICL_uranus_zh_male_youroubangzhu_tob"},
        @{@"name": @"优柔公子 2.0", @"voiceType": @"ICL_uranus_zh_male_yourougongzi_tob"},
        @{@"name": @"元气少年 2.0", @"voiceType": @"ICL_uranus_zh_male_yuanqishaonian_tob"},
        @{@"name": @"仗剑君子 2.0", @"voiceType": @"ICL_uranus_zh_male_zhangjianjunzi_tob"},
        @{@"name": @"仗剑侠客 2.0", @"voiceType": @"ICL_uranus_zh_male_zhangjianxiake_tob"},
        @{@"name": @"正直青年 2.0", @"voiceType": @"ICL_uranus_zh_male_zhengzhiqingnian_tob"},
        @{@"name": @"直率青年 2.0", @"voiceType": @"ICL_uranus_zh_male_zhishuaiqingnian_tob"},
        @{@"name": @"中二青年 2.0", @"voiceType": @"ICL_uranus_zh_male_zhongerqingnian_tob"},
        @{@"name": @"自负青年 2.0", @"voiceType": @"ICL_uranus_zh_male_zifuqingnian_tob"},
        @{@"name": @"自信青年 2.0", @"voiceType": @"ICL_uranus_zh_male_zixinqingnian_tob"},
        @{@"name": @"天才同桌 2.0", @"voiceType": @"ICL_uranus_zh_male_tiancaitongzhuo_tob"},
        @{@"name": @"清新沐沐 2.0", @"voiceType": @"ICL_uranus_zh_male_qingxinmumu_tob"},
        @{@"name": @"温婉珊珊 2.0", @"voiceType": @"ICL_uranus_zh_female_wenwanshanshan_tob"},
        @{@"name": @"热情艾娜 2.0", @"voiceType": @"ICL_uranus_zh_female_reqingaina_tob"},
        @{@"name": @"爽朗少年 2.0", @"voiceType": @"ICL_uranus_zh_male_shuanglangshaonian_tob"},
        @{@"name": @"轻盈朵朵 2.0", @"voiceType": @"ICL_uranus_zh_female_qingyingduoduo_tob"},
        @{@"name": @"Dina", @"voiceType": @"ar_female_dina_uranus_bigtts"},
        @{@"name": @"Fatma", @"voiceType": @"ar_female_fatma_uranus_bigtts"},
        @{@"name": @"Youssef", @"voiceType": @"ar_male_youssef_uranus_bigtts"},
        @{@"name": @"Stella", @"voiceType": @"de_female_bv081_uranus_bigtts"},
        @{@"name": @"Sven", @"voiceType": @"de_male_sven_uranus_bigtts"},
        @{@"name": @"Rowan", @"voiceType": @"en_male_adam-imitation_uranus_bigtts"},
        @{@"name": @"Alberto", @"voiceType": @"en_male_alberto_uranus_bigtts"},
        @{@"name": @"Alex", @"voiceType": @"en_male_alex_uranus_bigtts"},
        @{@"name": @"Allison", @"voiceType": @"en_female_allison_uranus_bigtts"},
        @{@"name": @"Charlotte", @"voiceType": @"en_female_authoritative-british_uranus_bigtts"},
        @{@"name": @"Margaret", @"voiceType": @"en_female_authoritative-informative_uranus_bigtts"},
        @{@"name": @"Jones", @"voiceType": @"en_male_bill-jones_uranus_bigtts"},
        @{@"name": @"Bill", @"voiceType": @"en_male_bill_jones_corey_uranus_bigtts"},
        @{@"name": @"Brad_Pitt", @"voiceType": @"en_male_brad_pitt_p1_uranus_bigtts"},
        @{@"name": @"Brittney", @"voiceType": @"en_female_brittney_uranus_bigtts"},
        @{@"name": @"Zoe", @"voiceType": @"en_female_brittney_pimintel_uranus_bigtts"},
        @{@"name": @"Adrian", @"voiceType": @"en_male_bruce_uranus_bigtts"},
        @{@"name": @"Leo", @"voiceType": @"en_male_chandler_p1_uranus_bigtts"},
        @{@"name": @"Bob", @"voiceType": @"en_male_cowboy-bob_uranus_bigtts"},
        @{@"name": @"John", @"voiceType": @"en_male_cowboy_john_b_uranus_bigtts"},
        @{@"name": @"David", @"voiceType": @"en_male_david_uranus_bigtts"},
        @{@"name": @"Orion", @"voiceType": @"en_male_deep-voice_uranus_bigtts"},
        @{@"name": @"Julian", @"voiceType": @"en_male_diyuwenrounan_uranus_bigtts"},
        @{@"name": @"Harrison", @"voiceType": @"en_male_evil-guy-oxley_uranus_bigtts"},
        @{@"name": @"Jasper", @"voiceType": @"en_male_excited-male-voice_uranus_bigtts"},
        @{@"name": @"Alfred", @"voiceType": @"en_male_father-christmas_uranus_bigtts"},
        @{@"name": @"Holly", @"voiceType": @"en_female_female_tutor_ms-jenny_uranus_bigtts"},
        @{@"name": @"Felix", @"voiceType": @"en_male_fernando-martinez_uranus_bigtts"},
        @{@"name": @"Godfather", @"voiceType": @"en_male_godfather_uranus_bigtts"},
        @{@"name": @"Gollum", @"voiceType": @"en_male_gollum_uranus_bigtts"},
        @{@"name": @"Beau", @"voiceType": @"en_male_hades_uranus_bigtts"},
        @{@"name": @"Hayley", @"voiceType": @"en_female_hayley_uranus_bigtts"},
        @{@"name": @"Jamie", @"voiceType": @"en_male_jamie_uranus_bigtts"},
        @{@"name": @"Jane", @"voiceType": @"en_female_jane_uranus_bigtts"},
        @{@"name": @"Jenny", @"voiceType": @"en_female_jenny_uranus_bigtts"},
        @{@"name": @"Blaze", @"voiceType": @"en_male_jidongchuanjiaoshi_uranus_bigtts"},
        @{@"name": @"Jimmy", @"voiceType": @"en_male_jimmy_uranus_bigtts"},
        @{@"name": @"Joanne", @"voiceType": @"en_female_joanne_uranus_bigtts"},
        @{@"name": @"Joker", @"voiceType": @"en_male_joker_uranus_bigtts"},
        @{@"name": @"Josh", @"voiceType": @"en_male_josh_uranus_bigtts"},
        @{@"name": @"Josiah", @"voiceType": @"en_male_josh_coery_uranus_bigtts"},
        @{@"name": @"Kevin", @"voiceType": @"en_male_kevin_uranus_bigtts"},
        @{@"name": @"Knightley", @"voiceType": @"en_male_knightley_uranus_bigtts"},
        @{@"name": @"Lynn", @"voiceType": @"en_female_lana_del_rey_kelley_d_p1_uranus_bigtts"},
        @{@"name": @"Ivy", @"voiceType": @"en_female_lana_del_rey_parky_s_p1_uranus_bigtts"},
        @{@"name": @"Marcus", @"voiceType": @"en_male_marcus_uranus_bigtts"},
        @{@"name": @"Mel", @"voiceType": @"en_female_mel_uranus_bigtts"},
        @{@"name": @"Hank", @"voiceType": @"en_male_michael_uranus_bigtts"},
        @{@"name": @"Chip", @"voiceType": @"en_male_michael-mouse_uranus_bigtts"},
        @{@"name": @"Michael_Kevin", @"voiceType": @"en_male_michael_kevin_uranus_bigtts"},
        @{@"name": @"Rory", @"voiceType": @"en_male_motivational-coach_uranus_bigtts"},
        @{@"name": @"Myra", @"voiceType": @"en_female_myra_uranus_bigtts"},
        @{@"name": @"Sunny", @"voiceType": @"en_female_myra_cmb_uranus_bigtts"},
        @{@"name": @"Blair", @"voiceType": @"en_female_nadia_uranus_bigtts"},
        @{@"name": @"Natasha", @"voiceType": @"en_female_natasha_uranus_bigtts"},
        @{@"name": @"Elaine", @"voiceType": @"en_female_pleasant-female_uranus_bigtts"},
        @{@"name": @"Rachel", @"voiceType": @"en_female_rachel_p1_uranus_bigtts"},
        @{@"name": @"Ronald", @"voiceType": @"en_male_ronald_uranus_bigtts"},
        @{@"name": @"Russell", @"voiceType": @"en_male_russell_uranus_bigtts"},
        @{@"name": @"Scarlet", @"voiceType": @"en_female_scarlet_p1_uranus_bigtts"},
        @{@"name": @"Sharron", @"voiceType": @"en_female_sharron_uranus_bigtts"},
        @{@"name": @"Simba", @"voiceType": @"en_male_simba_p1_uranus_bigtts"},
        @{@"name": @"Skye", @"voiceType": @"en_female_skye_uranus_bigtts"},
        @{@"name": @"Tom", @"voiceType": @"en_male_tom_hiddleston_p1_uranus_bigtts"},
        @{@"name": @"Valentino", @"voiceType": @"en_male_valentino_uranus_bigtts"},
        @{@"name": @"Clark", @"voiceType": @"en_male_valentino_corey_uranus_bigtts"},
        @{@"name": @"Megan", @"voiceType": @"en_female_wenrouzhishijieshuonv_uranus_bigtts"},
        @{@"name": @"Kayla", @"voiceType": @"en_female_xinwenjieshuonv_uranus_bigtts"},
        @{@"name": @"Dylan", @"voiceType": @"en_male_yangguangjieshuonan_uranus_bigtts"},
        @{@"name": @"Zendaya", @"voiceType": @"en_female_zendaya_p1_uranus_bigtts"},
        @{@"name": @"Gracie", @"voiceType": @"es_female_bv084_uranus_bigtts"},
        @{@"name": @"Dani", @"voiceType": @"es_male_dani_uranus_bigtts"},
        @{@"name": @"Guillem", @"voiceType": @"es_male_guillem_uranus_bigtts"},
        @{@"name": @"Marisol", @"voiceType": @"es_female_ht_mx_f6_uranus_bigtts"},
        @{@"name": @"Simone", @"voiceType": @"fr_female_fr_bv078_uranus_bigtts"},
        @{@"name": @"Camille", @"voiceType": @"fr_female_fr_f47_uranus_bigtts"},
        @{@"name": @"Maurice", @"voiceType": @"fr_male_fr_m29_uranus_bigtts"},
        @{@"name": @"Usseau", @"voiceType": @"fr_male_usseau_uranus_bigtts"},
        @{@"name": @"Rocco", @"voiceType": @"id_male_bv160_uranus_bigtts"},
        @{@"name": @"Jude", @"voiceType": @"id_male_bv160dialogue_uranus_bigtts"},
        @{@"name": @"Hugo", @"voiceType": @"id_male_bv160narration_uranus_bigtts"},
        @{@"name": @"Clara", @"voiceType": @"id_female_bv161_uranus_bigtts"},
        @{@"name": @"Sylvia", @"voiceType": @"id_female_bv161dialogue_uranus_bigtts"},
        @{@"name": @"Celeste", @"voiceType": @"id_female_bv161narration_uranus_bigtts"},
        @{@"name": @"Crew", @"voiceType": @"id_female_bv164_uranus_bigtts"},
        @{@"name": @"Elian", @"voiceType": @"id_male_bv164dialogue_uranus_bigtts"},
        @{@"name": @"Ronan", @"voiceType": @"id_male_bv164narration_uranus_bigtts"},
        @{@"name": @"Chloe", @"voiceType": @"id_female_f20_uranus_bigtts"},
        @{@"name": @"Han", @"voiceType": @"id_male_han_uranus_bigtts"},
        @{@"name": @"Kyle", @"voiceType": @"id_male_m08_uranus_bigtts"},
        @{@"name": @"Phulia", @"voiceType": @"id_female_phulia_uranus_bigtts"},
        @{@"name": @"Bonnie", @"voiceType": @"ja_female_bv024_uranus_bigtts"},
        @{@"name": @"Poppy", @"voiceType": @"ja_female_bv520_uranus_bigtts"},
        @{@"name": @"Aoi", @"voiceType": @"ja_female_bv521_uranus_bigtts"},
        @{@"name": @"Hana", @"voiceType": @"ja_female_bv522_uranus_bigtts"},
        @{@"name": @"Lily", @"voiceType": @"ja_female_bv523_uranus_bigtts"},
        @{@"name": @"Ken", @"voiceType": @"ja_male_bv524_uranus_bigtts"},
        @{@"name": @"Minimi", @"voiceType": @"ja_female_minimi_uranus_bigtts"},
        @{@"name": @"Shirou", @"voiceType": @"ja_female_shirou_uranus_bigtts"},
        @{@"name": @"Jay", @"voiceType": @"ko_male_bv545_uranus_bigtts"},
        @{@"name": @"Momo", @"voiceType": @"ko_female_bv546_uranus_bigtts"},
        @{@"name": @"Minho", @"voiceType": @"ko_male_m03_uranus_bigtts"},
        @{@"name": @"Shane", @"voiceType": @"ko_male_shane_uranus_bigtts"},
        @{@"name": @"Ham", @"voiceType": @"ms_male_ham_uranus_bigtts"},
        @{@"name": @"Naim", @"voiceType": @"ms_male_naim_uranus_bigtts"},
        @{@"name": @"Irene", @"voiceType": @"mx_female_bv065_uranus_bigtts"},
        @{@"name": @"Diego", @"voiceType": @"mx_male_bv165dialogue_uranus_bigtts"},
        @{@"name": @"Marcos", @"voiceType": @"mx_male_bv165narrator_uranus_bigtts"},
        @{@"name": @"Lucy", @"voiceType": @"mx_female_bv166dialogue_uranus_bigtts"},
        @{@"name": @"Rosa", @"voiceType": @"mx_female_bv166emotion_uranus_bigtts"},
        @{@"name": @"Freya", @"voiceType": @"mx_female_bv166narrator_uranus_bigtts"},
        @{@"name": @"Felipe", @"voiceType": @"mx_male_felipe_uranus_bigtts"},
        @{@"name": @"Derek", @"voiceType": @"mx_male_ht_mx_m012_uranus_bigtts"},
        @{@"name": @"Leslie", @"voiceType": @"mx_female_leslie_uranus_bigtts"},
        @{@"name": @"Marcelo", @"voiceType": @"mx_male_marcelo_uranus_bigtts"},
        @{@"name": @"Sam", @"voiceType": @"pt_male_bv172_uranus_bigtts"},
        @{@"name": @"Walter", @"voiceType": @"pt_male_bv172dialogue_uranus_bigtts"},
        @{@"name": @"Vincent", @"voiceType": @"pt_male_bv172emotion_uranus_bigtts"},
        @{@"name": @"Miles", @"voiceType": @"pt_male_bv172narrator_uranus_bigtts"},
        @{@"name": @"Diana", @"voiceType": @"pt_female_bv173_uranus_bigtts"},
        @{@"name": @"Elena", @"voiceType": @"pt_female_bv173dialogue_uranus_bigtts"},
        @{@"name": @"Lola", @"voiceType": @"pt_female_bv173emotion_uranus_bigtts"},
        @{@"name": @"Emma", @"voiceType": @"pt_female_bv173narrator_uranus_bigtts"},
        @{@"name": @"Sofia", @"voiceType": @"pt_female_bv530_uranus_bigtts"},
        @{@"name": @"Arthur", @"voiceType": @"pt_male_bv531_uranus_bigtts"},
        @{@"name": @"Mari", @"voiceType": @"pt_female_mari_uranus_bigtts"},
        @{@"name": @"Toby", @"voiceType": @"pt_male_martins_uranus_bigtts"},
        @{@"name": @"Rael", @"voiceType": @"pt_male_rael_uranus_bigtts"},
        @{@"name": @"Amelia", @"voiceType": @"ru_female_af07_uranus_bigtts"},
        @{@"name": @"Irinae", @"voiceType": @"ru_female_irinae_uranus_bigtts"},
        @{@"name": @"Pavel", @"voiceType": @"ru_male_pavel_uranus_bigtts"},
        @{@"name": @"Ksenia", @"voiceType": @"ru_female_sophie_uranus_bigtts"},
        @{@"name": @"Silas", @"voiceType": @"ru_male_vlad_uranus_bigtts"},
        @{@"name": @"Valeria", @"voiceType": @"th_female_bv568_angry_uranus_bigtts"},
        @{@"name": @"Iris", @"voiceType": @"th_female_bv568_fear_uranus_bigtts"},
        @{@"name": @"Zara", @"voiceType": @"th_female_bv568_happy_uranus_bigtts"},
        @{@"name": @"Valentina", @"voiceType": @"th_female_bv568_hate_uranus_bigtts"},
        @{@"name": @"Mildred", @"voiceType": @"th_female_bv568_neutral_uranus_bigtts"},
        @{@"name": @"Lydia", @"voiceType": @"th_female_bv568_sad_uranus_bigtts"},
        @{@"name": @"Phoebe", @"voiceType": @"th_female_bv568_suprise_uranus_bigtts"},
        @{@"name": @"Annika", @"voiceType": @"tl_female_annika_uranus_bigtts"},
        @{@"name": @"Ed", @"voiceType": @"tl_male_ed_uranus_bigtts"},
        @{@"name": @"Hervie", @"voiceType": @"tl_female_hervie_uranus_bigtts"},
        @{@"name": @"Hong", @"voiceType": @"vi_female_hong_uranus_bigtts"},
        @{@"name": @"Ling", @"voiceType": @"vi_female_ling_uranus_bigtts"},
        @{@"name": @"Linh", @"voiceType": @"vi_female_linh_uranus_bigtts"},
        @{@"name": @"Partner", @"voiceType": @"vi_female_partner_uranus_bigtts"},
        @{@"name": @"Ruan", @"voiceType": @"vi_female_ruan_uranus_bigtts"},
        @{@"name": @"Wu", @"voiceType": @"vi_female_wu_uranus_bigtts"},
        @{@"name": @"Wumg", @"voiceType": @"vi_male_wumg_uranus_bigtts"},
        @{@"name": @"Enzo", @"voiceType": @"it_male_enzo_uranus_bigtts"},
    ];
}

@end
