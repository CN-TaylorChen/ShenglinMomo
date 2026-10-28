// 声临 · Fish 音色导入
//
// v0.4.60：整页重设计 —— 砍掉「我的 / 公开 / 粘贴」三分段控件。
// 起因：前两个是「浏览列表 + 多选」，第三个是「吃一段文本」，两种交互形态挤在同一个分段里，
// 切换必然整页换掉，所以怎么调边距都还是割裂（v0.4.59 用「固定 44pt 槽位」只是把跳变压小，治不了根）。
//
// 新结构：
//   · 一页只有一个列表。来源用搜索框下方的两个小胶囊切换（我的 / 公开），切换只刷新数据，不换版式。
//   · 「我的」多选 → 底部悬浮主按钮「导入 N 个」；勾选做成行内空圆 / 绿色实心圆。
//   · 「公开」点 ＋ 直接入库，没有多选、没有底部按钮（这页不该有多选噪音）。
//   · 「粘贴」不再是标签页，而是导航栏右侧的胶囊 → 从底部升起一张卡片，列表完全不动。

#import "SLVoiceImportController.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "SLGlass.h"
#import <math.h>

#define kSLFishModelURL @"https://api.fish.audio/model"

// 行右侧的状态圆
typedef NS_ENUM(NSInteger, SLVoiceRowMark) {
    SLVoiceRowMarkNone = 0,   // 空心圆（我的 · 未选）
    SLVoiceRowMarkChecked,    // 绿色实心 ✓（我的 · 已选）
    SLVoiceRowMarkPlus,       // 空心 ＋（公开 · 可加）
    SLVoiceRowMarkAdded,      // 灰色 ✓（公开 · 已在库里）
};

#pragma mark - 列表行

@interface SLVoiceImportCell : UITableViewCell
@property (nonatomic, strong) UIView *avatarBox;
@property (nonatomic, strong) UIImageView *avatarImg;
@property (nonatomic, strong) UILabel *initialLab;
@property (nonatomic, strong) UILabel *nameLab;
@property (nonatomic, strong) UILabel *vidLab;
@property (nonatomic, strong) UILabel *markLab;
- (void)sl_configureName:(NSString *)name
                     vid:(NSString *)vid
                   image:(UIImage *)img
                    mark:(SLVoiceRowMark)mark;
@end

@implementation SLVoiceImportCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    _avatarBox = [[UIView alloc] initWithFrame:CGRectZero];
    _avatarBox.backgroundColor = SLGlassPillFillColor();
    _avatarBox.layer.cornerRadius = 15.0;
    _avatarBox.layer.cornerCurve = kCACornerCurveContinuous;
    _avatarBox.layer.borderWidth = 0.8;
    _avatarBox.layer.borderColor = SLGlassHairlineColor().CGColor;
    [self.contentView addSubview:_avatarBox];

    _initialLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _initialLab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _initialLab.textAlignment = NSTextAlignmentCenter;
    _initialLab.textColor = [UIColor labelColor];
    [_avatarBox addSubview:_initialLab];

    _avatarImg = [[UIImageView alloc] initWithFrame:CGRectZero];
    _avatarImg.contentMode = UIViewContentModeScaleAspectFill;
    _avatarImg.layer.cornerRadius = 15.0;
    _avatarImg.layer.masksToBounds = YES;
    _avatarImg.hidden = YES;
    [self.contentView addSubview:_avatarImg];

    _nameLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _nameLab.textColor = [UIColor labelColor];
    _nameLab.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_nameLab];

    _vidLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _vidLab.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _vidLab.textColor = [UIColor secondaryLabelColor];
    _vidLab.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.contentView addSubview:_vidLab];

    _markLab = [[UILabel alloc] initWithFrame:CGRectZero];
    _markLab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _markLab.textAlignment = NSTextAlignmentCenter;
    _markLab.layer.cornerRadius = 11.0;
    _markLab.layer.cornerCurve = kCACornerCurveContinuous;
    _markLab.layer.masksToBounds = YES;
    [self.contentView addSubview:_markLab];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.contentView.bounds.size.width;
    CGFloat H = self.contentView.bounds.size.height;
    CGFloat av = 30.0;
    CGFloat markS = 22.0;
    _avatarBox.frame = CGRectMake(16.0, (H - av) / 2.0, av, av);
    _avatarImg.frame = _avatarBox.frame;
    _initialLab.frame = _avatarBox.bounds;
    _markLab.frame = CGRectMake(W - 16.0 - markS, (H - markS) / 2.0, markS, markS);
    CGFloat nameX = 16.0 + av + 10.0;
    CGFloat nameW = MAX(0.0, W - nameX - 16.0 - markS - 12.0);
    _nameLab.frame = CGRectMake(nameX, 11.0, nameW, 18.0);
    _vidLab.frame = CGRectMake(nameX, 30.0, nameW, 14.0);
}

- (void)sl_configureName:(NSString *)name
                     vid:(NSString *)vid
                   image:(UIImage *)img
                    mark:(SLVoiceRowMark)mark {
    self.nameLab.text = name.length ? name : @"未命名音色";
    self.vidLab.text = vid ?: @"";
    self.avatarImg.image = img;
    self.avatarImg.hidden = (img == nil);
    self.initialLab.hidden = (img != nil);
    self.initialLab.text = name.length ? [name substringToIndex:1] : @"?";

    self.markLab.layer.borderWidth = 0.0;
    self.markLab.layer.borderColor = [UIColor clearColor].CGColor;
    self.markLab.backgroundColor = [UIColor clearColor];
    self.markLab.text = nil;

    switch (mark) {
        case SLVoiceRowMarkChecked:
            self.markLab.backgroundColor = [UIColor systemGreenColor];
            self.markLab.textColor = [UIColor whiteColor];
            self.markLab.text = @"✓";
            break;
        case SLVoiceRowMarkPlus:
            self.markLab.layer.borderWidth = 1.0;
            self.markLab.layer.borderColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.55].CGColor;
            self.markLab.textColor = [UIColor systemBlueColor];
            self.markLab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            self.markLab.text = @"+";
            break;
        case SLVoiceRowMarkAdded:
            self.markLab.layer.borderWidth = 1.0;
            self.markLab.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.30].CGColor;
            self.markLab.textColor = [UIColor tertiaryLabelColor];
            self.markLab.text = @"✓";
            break;
        case SLVoiceRowMarkNone:
        default:
            self.markLab.layer.borderWidth = 1.2;
            self.markLab.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.35].CGColor;
            break;
    }
    self.markLab.font = (mark == SLVoiceRowMarkPlus) ? [UIFont systemFontOfSize:15 weight:UIFontWeightMedium]
                                                     : [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
}

@end

#pragma mark - 导入页

@interface SLVoiceImportController () <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, assign) SLImportMode mode;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@property (nonatomic, strong) NSMutableSet<NSString *> *importedIDs;   // 已在「我导入的音色」里的 vid

// 顶部：搜索胶囊 + 来源小胶囊（我的 / 公开）
@property (nonatomic, strong) UIView *topSlot;
@property (nonatomic, strong) SLSearchPill *searchPill;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UIView *srcWrap;
@property (nonatomic, strong) UIButton *srcMineBtn;
@property (nonatomic, strong) UIButton *srcPublicBtn;
@property (nonatomic, assign) CGFloat topSlotWidth;
@property (nonatomic, assign) CGFloat topSlotInset;

@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, copy) NSString *status;

// 底部悬浮主按钮（只在「我的」出现）
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *importBtn;
@property (nonatomic, assign) CGFloat lastBottomInset;

// 粘贴卡片
@property (nonatomic, strong) UIView *pasteOverlay;
@property (nonatomic, strong) UIView *pasteCard;
@property (nonatomic, strong) UITextView *pasteView;
@property (nonatomic, strong) UILabel *pastePlaceholder;
@property (nonatomic, strong) UILabel *pasteCountLab;
@property (nonatomic, strong) UIButton *pasteImportBtn;
@property (nonatomic, strong) NSArray<NSDictionary *> *pasteParsed;
@property (nonatomic, assign) CGFloat pasteCardH;

@property (nonatomic, assign) BOOL wantsPasteOnAppear;
@end

@implementation SLVoiceImportController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"导入 Fish 音色";
    // 与设置页统一：毛玻璃底 + 胶囊标题 + 胶囊返回
    self.navigationItem.titleView = SLPillTitleView(@"导入音色");
    SLInstallPillBack(self);
    SLApplyGlassTable(self.tableView);

    self.selected = [NSMutableSet set];
    self.importedIDs = [NSMutableSet set];
    self.items = @[];
    self.status = nil;
    self.searchText = @"";

    // 粘贴不再是标签页：老入口若传了 Paste，落到「我的」并顺手弹出粘贴卡片
    self.mode = (self.initialMode == SLImportModeSearch) ? SLImportModeSearch : SLImportModeMine;
    self.wantsPasteOnAppear = (self.initialMode == SLImportModePaste);

    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"粘贴", self, @selector(sl_openPasteSheet));

    [self sl_buildTopSlot];
    [self sl_buildBottomBar];
    [self sl_reloadImportedIDs];
    [self sl_refreshChrome];

    if (self.mode == SLImportModeMine) [self sl_fetchMine];
    else [self sl_fetchSearch:@""];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 底部按钮 / 粘贴卡片要挂在导航控制器的视图上：本页的 self.view 就是 tableView，
    // 挂进去会跟着内容一起滚。没有导航控制器时退回 self.view（极少见，居中的弹层场景）。
    UIView *host = [self sl_hostView];
    if (self.bottomBar.superview != host) [host addSubview:self.bottomBar];
    if (self.pasteOverlay && self.pasteOverlay.superview != host) [host addSubview:self.pasteOverlay];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 挂在外层视图上的东西必须自己摘掉，否则 pop 之后按钮会一直浮在别的页面上
    [self.bottomBar removeFromSuperview];
    [self.pasteOverlay removeFromSuperview];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.wantsPasteOnAppear) {
        self.wantsPasteOnAppear = NO;
        [self sl_openPasteSheet];
    } else if (self.mode == SLImportModeSearch) {
        [self.searchField becomeFirstResponder];
    }
}

- (UIView *)sl_hostView {
    UIView *v = self.navigationController.view;
    if (v) return v;
    v = self.view.window;
    if (v) return v;
    return self.view;
}

#pragma mark - 对齐基线

// 单元格（卡片）左边距。表头 / 底部按钮 / 粘贴卡片都按「卡片 + 16」对齐，
// 这样列表文字、搜索框、主按钮才会落在同一条竖线上（原来表头按整屏 16 算，差 ~20pt）。
- (CGFloat)sl_cardInsetX {
    UITableViewCell *c = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    if (c && c.frame.origin.x > 0.5) return c.frame.origin.x;
    return 20.0;
}

#pragma mark - 顶部槽（搜索 + 来源）

- (void)sl_buildTopSlot {
    CGFloat W = self.view.bounds.size.width;
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 78.0)];

    SLSearchPill *p = [SLSearchPill pillWithPlaceholder:@"搜索我的音色"];
    p.field.delegate = self;
    [p.field addTarget:self action:@selector(sl_searchChanged) forControlEvents:UIControlEventEditingChanged];
    [head addSubview:p];
    self.searchPill = p;
    self.searchField = p.field;

    UIView *wrap = [[UIView alloc] initWithFrame:CGRectZero];
    wrap.backgroundColor = SLGlassPillFillColor();
    wrap.layer.cornerRadius = 13.0;
    wrap.layer.cornerCurve = kCACornerCurveContinuous;
    wrap.layer.borderWidth = 0.8;
    wrap.layer.borderColor = SLGlassHairlineColor().CGColor;
    [head addSubview:wrap];
    self.srcWrap = wrap;

    UIButton *mine = [UIButton buttonWithType:UIButtonTypeCustom];
    mine.layer.cornerRadius = 11.0;
    mine.layer.cornerCurve = kCACornerCurveContinuous;
    [mine addTarget:self action:@selector(sl_srcMineTapped) forControlEvents:UIControlEventTouchUpInside];
    [wrap addSubview:mine];
    self.srcMineBtn = mine;

    UIButton *pub = [UIButton buttonWithType:UIButtonTypeCustom];
    pub.layer.cornerRadius = 11.0;
    pub.layer.cornerCurve = kCACornerCurveContinuous;
    [pub addTarget:self action:@selector(sl_srcPublicTapped) forControlEvents:UIControlEventTouchUpInside];
    [wrap addSubview:pub];
    self.srcPublicBtn = pub;

    self.topSlot = head;
    self.topSlotWidth = 0;
    self.topSlotInset = 0;
    self.tableView.tableHeaderView = head;
}

- (void)sl_layoutTopSlot {
    UIView *head = self.topSlot;
    if (!head) return;
    CGFloat W = self.tableView.bounds.size.width;
    if (W <= 0) W = self.view.bounds.size.width;
    CGFloat inset = [self sl_cardInsetX];
    CGFloat x = inset + 16.0;
    CGFloat w = MAX(0.0, W - 2.0 * x);

    head.frame = CGRectMake(0, 0, W, 78.0);
    self.searchPill.frame = CGRectMake(x, 2.0, w, 36.0);
    self.srcWrap.frame = CGRectMake(x, 44.0, w, 26.0);
    CGFloat inner = MAX(0.0, (w - 4.0) / 2.0);
    self.srcMineBtn.frame = CGRectMake(2.0, 2.0, inner, 22.0);
    self.srcPublicBtn.frame = CGRectMake(2.0 + inner, 2.0, inner, 22.0);

    if (fabs(W - self.topSlotWidth) > 0.5 || fabs(inset - self.topSlotInset) > 0.5) {
        self.topSlotWidth = W;
        self.topSlotInset = inset;
        self.tableView.tableHeaderView = head;
    }
}

- (void)sl_refreshSrcButtons {
    BOOL mine = (self.mode == SLImportModeMine);
    UIButton *btns[2] = { self.srcMineBtn, self.srcPublicBtn };
    NSString *titles[2] = { @"我的", @"公开" };
    for (NSInteger i = 0; i < 2; i++) {
        UIButton *b = btns[i];
        BOOL on = (i == 0) ? mine : !mine;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:(on ? UIFontWeightSemibold : UIFontWeightRegular)];
        [b setTitleColor:(on ? [UIColor labelColor] : [UIColor secondaryLabelColor]) forState:UIControlStateNormal];
        b.backgroundColor = on ? [[UIColor labelColor] colorWithAlphaComponent:0.10] : [UIColor clearColor];
    }
}

- (void)sl_srcMineTapped {
    [self sl_switchToMode:SLImportModeMine];
}

- (void)sl_srcPublicTapped {
    [self sl_switchToMode:SLImportModeSearch];
}

- (void)sl_switchToMode:(SLImportMode)mode {
    if (self.mode == mode) return;
    self.mode = mode;
    self.items = @[];
    self.status = nil;
    self.searchText = @"";
    self.searchField.text = @"";
    [self.selected removeAllObjects];
    if (mode != SLImportModeSearch && self.searchField.isFirstResponder) {
        [self.searchField resignFirstResponder];
    }
    self.searchField.placeholder = (mode == SLImportModeMine) ? @"搜索我的音色" : @"搜公开音色";
    [self sl_refreshChrome];

    // 版式不再换，只做一次淡入淡出，避免内容硬闪
    [UIView transitionWithView:self.tableView
                      duration:0.2
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        [self.tableView reloadData];
    } completion:nil];

    if (mode == SLImportModeMine) {
        [self sl_fetchMine];
    } else {
        [self.searchField becomeFirstResponder];
        [self sl_fetchSearch:self.searchText];
    }
}

#pragma mark - 底部主按钮

- (void)sl_buildBottomBar {
    self.bottomBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.bottomBar.backgroundColor = [UIColor clearColor];
    self.bottomBar.hidden = YES;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    btn.layer.cornerRadius = 14.0;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    [btn addTarget:self action:@selector(sl_doImport) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBar addSubview:btn];
    self.importBtn = btn;
}

- (void)sl_layoutFloatingChrome {
    UIView *host = self.bottomBar.superview;
    if (!host) return;
    CGFloat W = host.bounds.size.width;
    CGFloat H = host.bounds.size.height;
    CGFloat safeB = host.safeAreaInsets.bottom;
    CGFloat barH = 46.0 + 10.0 + safeB;
    self.bottomBar.frame = CGRectMake(0, H - barH, W, barH);
    CGFloat x = [self sl_cardInsetX] + 16.0;
    self.importBtn.frame = CGRectMake(x, 0.0, MAX(0.0, W - 2.0 * x), 46.0);
}

- (void)sl_refreshChrome {
    BOOL mine = (self.mode == SLImportModeMine);
    self.bottomBar.hidden = !mine;

    NSUInteger n = self.selected.count;
    NSString *title = (n > 0) ? [NSString stringWithFormat:@"导入 %lu 个", (unsigned long)n] : @"导入";
    [self.importBtn setTitle:title forState:UIControlStateNormal];
    BOOL on = (n > 0);
    self.importBtn.enabled = on;
    self.importBtn.backgroundColor = on ? [UIColor systemGreenColor]
                                       : [UIColor colorWithWhite:0.5 alpha:0.16];
    [self.importBtn setTitleColor:(on ? [UIColor whiteColor] : [UIColor secondaryLabelColor])
                         forState:UIControlStateNormal];

    [self sl_refreshSrcButtons];
    [self sl_syncBottomInset];
}

// 底部按钮占掉的高度要补成 contentInset，否则最后一行会被压在按钮下面
- (void)sl_syncBottomInset {
    CGFloat barH = 46.0 + 10.0 + self.view.safeAreaInsets.bottom;
    CGFloat want = (self.mode == SLImportModeMine) ? (barH + 10.0) : 0.0;
    if (fabs(want - self.lastBottomInset) <= 0.5) return;
    self.lastBottomInset = want;
    UIEdgeInsets in = self.tableView.contentInset;
    in.bottom = want;
    self.tableView.contentInset = in;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self sl_layoutTopSlot];
    [self sl_layoutFloatingChrome];
    [self sl_syncBottomInset];
}

#pragma mark - 数据

- (NSArray<NSDictionary *> *)sl_visibleItems {
    if (self.mode == SLImportModeMine && self.searchText.length) {
        NSString *q = self.searchText.lowercaseString;
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        for (NSDictionary *v in self.items) {
            NSString *n = [v[@"name"] isKindOfClass:[NSString class]] ? [v[@"name"] lowercaseString] : @"";
            if ([n containsString:q]) [out addObject:v];
        }
        return out;
    }
    return self.items;
}

- (void)sl_reloadImportedIDs {
    NSMutableSet<NSString *> *s = [NSMutableSet set];
    for (NSDictionary *v in [AWECATTSManager fishVoices]) {
        NSString *vid = v[@"voiceType"];
        if ([vid isKindOfClass:[NSString class]] && vid.length) [s addObject:vid];
    }
    self.importedIDs = s;
}

- (void)sl_searchChanged {
    self.searchText = self.searchField.text ?: @"";
    [self.tableView reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    self.searchText = tf.text ?: @"";
    if (self.mode == SLImportModeSearch) [self sl_fetchSearch:self.searchText];
    else [self.tableView reloadData];
    return YES;
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv; (void)section;
    return MAX((NSInteger)[self sl_visibleItems].count, 1);
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    return [self sl_visibleItems].count ? 56.0 : 64.0;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)section {
    (void)section;
    CGFloat w = tv.bounds.size.width;
    CGFloat x = [self sl_cardInsetX] + 16.0;
    NSArray *vis = [self sl_visibleItems];
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 40)];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(x, 0, MAX(0.0, w - x - 16.0 - 64.0), 40)];
    lab.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    lab.textColor = [UIColor secondaryLabelColor];
    if (self.loading) {
        lab.text = @"正在获取…";
    } else if (self.mode == SLImportModeMine) {
        lab.text = [NSString stringWithFormat:@"%lu 个音色", (unsigned long)vis.count];
    } else {
        lab.text = vis.count ? [NSString stringWithFormat:@"找到 %lu 个", (unsigned long)vis.count] : @"搜公开音色";
    }
    [head addSubview:lab];

    // 「我的」给一个全选 / 全取消；「公开」不需要多选，就不放
    if (self.mode == SLImportModeMine && vis.count) {
        BOOL all = (self.selected.count >= vis.count);
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        [b setTitle:(all ? @"全取消" : @"全选") forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
        [b setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        CGFloat bw = all ? 56.0 : 40.0;
        b.frame = CGRectMake(w - x - bw, 0.0, bw, 40.0);
        [b addTarget:self action:@selector(sl_toggleSelectAll) forControlEvents:UIControlEventTouchUpInside];
        [head addSubview:b];
    }
    return head;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)section {
    (void)tv; (void)section;
    return 40.0;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    (void)tv; (void)section;
    if (self.status.length && [self sl_visibleItems].count) return self.status;
    if (self.mode == SLImportModeMine) {
        return @"点一行选中，可多选；勾好后用底部按钮导入。导入的音色进「我导入的音色」分区";
    }
    return @"公开库点 ＋ 直接加入，不需要多选";
}

- (void)sl_toggleSelectAll {
    NSArray *vis = [self sl_visibleItems];
    if (self.selected.count >= vis.count) {
        [self.selected removeAllObjects];
    } else {
        for (NSDictionary *v in vis) {
            NSString *vid = v[@"voiceType"];
            if ([vid isKindOfClass:[NSString class]] && vid.length) [self.selected addObject:vid];
        }
    }
    [self.tableView reloadData];
    [self sl_refreshChrome];
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLGlassCellColor();
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSArray *vis = [self sl_visibleItems];

    if (!vis.count) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"empty"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:13.5];
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
            cell.textLabel.numberOfLines = 2;
        }
        NSString *msg = nil;
        if (self.loading) {
            msg = @"正在获取…";
        } else if (self.status.length) {
            msg = self.status;
        } else if (self.searchText.length) {
            msg = [NSString stringWithFormat:@"没有匹配「%@」的音色", self.searchText];
        } else if (self.mode == SLImportModeMine) {
            msg = @"这个账号下还没有音色，先去 Fish 建一个再回来";
        } else {
            msg = @"输入关键词，搜 Fish 公开音色库";
        }
        cell.textLabel.text = msg;
        return cell;
    }

    SLVoiceImportCell *cell = [tv dequeueReusableCellWithIdentifier:@"row"];
    if (!cell) cell = [[SLVoiceImportCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"row"];

    NSDictionary *v = vis[ip.row];
    NSString *vid = v[@"voiceType"];
    NSString *name = v[@"name"];
    UIImage *avatar = [[AWECATTSManager shared] fishAvatarForVoiceID:vid];

    SLVoiceRowMark mark = SLVoiceRowMarkNone;
    if (self.mode == SLImportModeMine) {
        mark = [self.selected containsObject:vid] ? SLVoiceRowMarkChecked : SLVoiceRowMarkNone;
    } else {
        mark = [self.importedIDs containsObject:vid] ? SLVoiceRowMarkAdded : SLVoiceRowMarkPlus;
    }
    [cell sl_configureName:name vid:vid image:avatar mark:mark];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *vis = [self sl_visibleItems];
    if (!vis.count || ip.row >= (NSInteger)vis.count) return;
    NSDictionary *v = vis[ip.row];
    NSString *vid = v[@"voiceType"];
    if (![vid isKindOfClass:[NSString class]] || !vid.length) return;

    if (self.mode == SLImportModeMine) {
        if ([self.selected containsObject:vid]) [self.selected removeObject:vid];
        else [self.selected addObject:vid];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        [self sl_refreshChrome];
        return;
    }

    // 公开库：点一下就入库，不入多选
    if ([self.importedIDs containsObject:vid]) {
        [AWECAUtils showToast:@"这个音色已经在库里了" duration:1.5];
        return;
    }
    [AWECATTSManager sl_importFishVoices:@[v]];
    [self sl_downloadAvatarsForItems:@[v]];
    [self sl_reloadImportedIDs];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
    if (self.onImported) self.onImported(1, 0);
    [AWECAUtils showToast:[NSString stringWithFormat:@"已加入：%@", v[@"name"] ?: vid] duration:1.6];
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
                self2.status = parsed.count ? nil : @"这个账号下没有音色";
            }
            [self2 sl_reloadImportedIDs];
            [self2 sl_refreshChrome];
            [self2.tableView reloadData];
        });
    }] resume];
}

#pragma mark - 粘贴卡片

- (void)sl_buildPasteSheetIfNeeded {
    if (self.pasteOverlay) return;

    UIView *host = [self sl_hostView];
    UIView *ov = [[UIView alloc] initWithFrame:host.bounds];
    ov.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.30];
    ov.alpha = 0.0;
    ov.hidden = YES;
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(sl_overlayTapped:)];
    [ov addGestureRecognizer:tap];
    [host addSubview:ov];
    self.pasteOverlay = ov;

    CGFloat W = host.bounds.size.width;
    CGFloat cw = W - 32.0;
    CGFloat ch = 272.0;
    self.pasteCardH = ch;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16.0, CGRectGetHeight(host.bounds), cw, ch)];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = SLGlassHairlineColor().CGColor;
    [ov addSubview:card];
    self.pasteCard = card;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16.0, 16.0, cw - 32.0 - 40.0, 20.0)];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.text = @"粘贴音色 JSON";
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(cw - 16.0 - 30.0, 12.0, 30.0, 30.0);
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
    [close setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(sl_closePasteSheet) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    self.pasteView = [[UITextView alloc] initWithFrame:CGRectMake(16.0, 46.0, cw - 32.0, 96.0)];
    self.pasteView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    self.pasteView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.pasteView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.pasteView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.pasteView.layer.cornerRadius = 10.0;
    self.pasteView.layer.cornerCurve = kCACornerCurveContinuous;
    self.pasteView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    self.pasteView.delegate = self;
    [card addSubview:self.pasteView];

    self.pastePlaceholder = [[UILabel alloc] initWithFrame:CGRectMake(22.0, 52.0, cw - 44.0, 16.0)];
    self.pastePlaceholder.font = [UIFont systemFontOfSize:12];
    self.pastePlaceholder.textColor = [UIColor tertiaryLabelColor];
    self.pastePlaceholder.text = @"把「声临 · 音色分享」的文本粘到这里";
    self.pastePlaceholder.userInteractionEnabled = NO;
    [card addSubview:self.pastePlaceholder];

    self.pasteCountLab = [[UILabel alloc] initWithFrame:CGRectMake(16.0, 150.0, cw - 32.0, 16.0)];
    self.pasteCountLab.font = [UIFont systemFontOfSize:12];
    self.pasteCountLab.textColor = [UIColor secondaryLabelColor];
    self.pasteCountLab.lineBreakMode = NSLineBreakByTruncatingTail;
    self.pasteCountLab.text = @"粘贴后自动识别";
    [card addSubview:self.pasteCountLab];

    UIButton *clip = [UIButton buttonWithType:UIButtonTypeCustom];
    clip.frame = CGRectMake(16.0, 176.0, 112.0, 28.0);
    [clip setTitle:@"从剪贴板读取" forState:UIControlStateNormal];
    clip.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [clip setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
    clip.layer.cornerRadius = 14.0;
    clip.layer.cornerCurve = kCACornerCurveContinuous;
    clip.layer.borderWidth = 0.8;
    clip.layer.borderColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.45].CGColor;
    [clip addTarget:self action:@selector(sl_readClipboard) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:clip];

    UIButton *imp = [UIButton buttonWithType:UIButtonTypeCustom];
    imp.frame = CGRectMake(16.0, 216.0, cw - 32.0, 42.0);
    imp.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    imp.layer.cornerRadius = 13.0;
    imp.layer.cornerCurve = kCACornerCurveContinuous;
    [imp setTitle:@"导入" forState:UIControlStateNormal];
    [imp addTarget:self action:@selector(sl_pasteImport) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:imp];
    self.pasteImportBtn = imp;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sl_keyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [self sl_syncPastePreview];
}

- (CGFloat)sl_pasteCardY:(CGFloat)overlap {
    UIView *host = self.pasteOverlay.superview;
    CGFloat H = host ? host.bounds.size.height : self.view.bounds.size.height;
    CGFloat safeB = host ? host.safeAreaInsets.bottom : self.view.safeAreaInsets.bottom;
    CGFloat y = H - self.pasteCardH - 10.0 - safeB - overlap;
    return MAX(48.0, y);
}

- (void)sl_overlayTapped:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.pasteOverlay];
    if (CGRectContainsPoint(self.pasteCard.frame, p)) return;
    [self sl_closePasteSheet];
}

- (void)sl_openPasteSheet {
    [self sl_buildPasteSheetIfNeeded];
    [self sl_syncPastePreview];

    UIView *host = self.pasteOverlay.superview;
    self.pasteOverlay.hidden = NO;
    self.pasteOverlay.frame = host.bounds;
    self.pasteCard.frame = CGRectMake(16.0, CGRectGetHeight(host.bounds), CGRectGetWidth(self.pasteCard.bounds), self.pasteCardH);

    [UIView animateWithDuration:0.28 delay:0
         usingSpringWithDamping:0.88 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.pasteOverlay.alpha = 1.0;
        self.pasteCard.frame = CGRectMake(16.0, [self sl_pasteCardY:0.0],
                                          CGRectGetWidth(self.pasteCard.bounds), self.pasteCardH);
    } completion:nil];
}

- (void)sl_closePasteSheet {
    if (!self.pasteOverlay || self.pasteOverlay.hidden) return;
    [self.pasteView resignFirstResponder];
    UIView *host = self.pasteOverlay.superview;
    [UIView animateWithDuration:0.2 animations:^{
        self.pasteOverlay.alpha = 0.0;
        self.pasteCard.frame = CGRectMake(16.0, CGRectGetHeight(host.bounds),
                                          CGRectGetWidth(self.pasteCard.bounds), self.pasteCardH);
    } completion:^(BOOL ok) {
        self.pasteOverlay.hidden = YES;
        self.pasteOverlay.alpha = 0.0;
    }];
}

- (void)sl_keyboardChanged:(NSNotification *)n {
    if (!self.pasteOverlay || self.pasteOverlay.hidden) return;
    UIView *host = self.pasteOverlay.superview;
    if (!host) return;
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInHost = [host convertRect:kb fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetHeight(host.bounds) - CGRectGetMinY(kbInHost));
    [UIView animateWithDuration:0.24 animations:^{
        self.pasteCard.frame = CGRectMake(16.0, [self sl_pasteCardY:overlap],
                                          CGRectGetWidth(self.pasteCard.bounds), self.pasteCardH);
    }];
}

- (void)sl_readClipboard {
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (!text.length) {
        [AWECAUtils showToast:@"剪贴板是空的" duration:1.5];
        return;
    }
    self.pasteView.text = text;
    [self sl_syncPastePreview];
}

- (void)textViewDidChange:(UITextView *)tv {
    (void)tv;
    [self sl_syncPastePreview];
}

- (void)sl_syncPastePreview {
    if (!self.pasteView) return;
    NSString *text = self.pasteView.text ?: @"";
    self.pastePlaceholder.hidden = (text.length > 0);

    NSArray *parsed = @[];
    if (text.length) {
        NSInteger skipped = 0;
        parsed = [AWECATTSManager sl_parseVoiceJSONText:text skipped:&skipped];
    }
    self.pasteParsed = parsed;

    if (!parsed.count) {
        if (text.length) {
            self.pasteCountLab.text = @"没解析出音色，检查 JSON 结构";
            self.pasteCountLab.textColor = [UIColor systemOrangeColor];
        } else {
            self.pasteCountLab.text = @"粘贴后自动识别";
            self.pasteCountLab.textColor = [UIColor secondaryLabelColor];
        }
    } else {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSDictionary *v in parsed) {
            NSString *n = v[@"name"];
            [names addObject:(n.length ? n : @"未命名")];
        }
        NSString *joined = [names componentsJoinedByString:@" · "];
        if (joined.length > 24) joined = [[joined substringToIndex:24] stringByAppendingString:@"…"];
        self.pasteCountLab.text = [NSString stringWithFormat:@"识别到 %lu 个：%@",
                                   (unsigned long)parsed.count, joined];
        self.pasteCountLab.textColor = [UIColor systemGreenColor];
    }

    BOOL on = (parsed.count > 0);
    self.pasteImportBtn.enabled = on;
    self.pasteImportBtn.backgroundColor = on ? [UIColor systemGreenColor]
                                             : [UIColor colorWithWhite:0.5 alpha:0.16];
    NSString *t = on ? [NSString stringWithFormat:@"导入 %lu 个", (unsigned long)parsed.count] : @"导入";
    [self.pasteImportBtn setTitle:t forState:UIControlStateNormal];
    [self.pasteImportBtn setTitleColor:(on ? [UIColor whiteColor] : [UIColor secondaryLabelColor])
                              forState:UIControlStateNormal];
}

- (void)sl_pasteImport {
    NSArray *items = self.pasteParsed;
    if (!items.count) {
        [AWECAUtils showToast:@"先粘贴音色列表 JSON" duration:1.5];
        return;
    }
    [self sl_closePasteSheet];
    NSDictionary *result = [AWECATTSManager sl_importFishVoices:items];
    [self sl_downloadAvatarsForItems:items];
    [self sl_finishWithResult:result skipped:0];
}

#pragma mark - 导入

- (void)sl_doImport {
    if (self.mode != SLImportModeMine) return;
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
        [AWECAUtils showToast:[NSString stringWithFormat:@"导入 %ld 个，更新 %ld 个，跳过 %ld 个",
                               (long)added, (long)updated, (long)skipped]
                     duration:2.5];
    }
    if (self.onImported) self.onImported(added, updated);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
