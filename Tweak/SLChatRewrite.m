//
//  SLChatRewrite.m
//  声临 · 陌陌版 —— 聊天记录修改（仅本机渲染层）
//

#import "SLChatRewrite.h"
#import <objc/runtime.h>
#import "SLGlass.h"
#import "SLLog.h"

static NSString *const kSLCRStoreKey   = @"SLChatRewriteStore";
static NSString *const kSLCREnabledKey = @"SLChatRewriteEnabled";
static NSString *const kSLCRResetKey   = @"SLChatRewriteResetOnLeave";

#pragma mark - 开关

BOOL SLChatRewriteEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLCREnabledKey]) return NO;   // 默认关：不主动介入别人的聊天
    return [d boolForKey:kSLCREnabledKey];
}

BOOL SLChatRewriteResetOnLeave(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLCRResetKey]) return YES;    // 默认开：退出会话即复原，最不容易露
    return [d boolForKey:kSLCRResetKey];
}

void SLChatRewriteSetEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLCREnabledKey];
}

void SLChatRewriteSetResetOnLeave(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLCRResetKey];
}

#pragma mark - 存储

static NSMutableDictionary *gSLCRCache = nil;

static NSMutableDictionary *SLCRStore(void) {
    if (gSLCRCache) return gSLCRCache;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id raw = [d objectForKey:kSLCRStoreKey];
    NSMutableDictionary *store = nil;
    if ([raw isKindOfClass:[NSDictionary class]]) {
        store = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)raw];
    } else if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length]) {
        NSData *data = [(NSString *)raw dataUsingEncoding:NSUTF8StringEncoding];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([obj isKindOfClass:[NSDictionary class]]) {
            store = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)obj];
        }
    }
    gSLCRCache = store ?: [NSMutableDictionary dictionary];
    return gSLCRCache;
}

static void SLCRFlush(NSDictionary *store) {
    gSLCRCache = store ? [NSMutableDictionary dictionaryWithDictionary:store] : [NSMutableDictionary dictionary];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (gSLCRCache.count) [d setObject:gSLCRCache forKey:kSLCRStoreKey];
    else [d removeObjectForKey:kSLCRStoreKey];
    [d synchronize];
}

static NSString *SLCRKeyOf(id msgid) {
    if (!msgid) return nil;
    if ([msgid isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)msgid;
        return s.length ? s : nil;
    }
    if ([msgid isKindOfClass:[NSNumber class]]) return [(NSNumber *)msgid stringValue];
    NSString *s = [msgid description];
    return s.length ? s : nil;
}

NSString *SLChatRewriteTextForMsgid(id msgid, NSString *orig) {
    if (!orig) return orig;
    if (!SLChatRewriteEnabled()) return orig;
    NSString *key = SLCRKeyOf(msgid);
    if (!key.length) return orig;
    NSDictionary *store = SLCRStore();
    NSDictionary *entry = store[key];
    if (![entry isKindOfClass:[NSDictionary class]]) return orig;
    NSString *text = entry[@"t"];
    if (![text isKindOfClass:[NSString class]] || !text.length) return orig;
    return text;
}

void SLChatRewriteSave(NSString *msgid, NSString *newText, NSString *orig, NSString *session) {
    NSString *key = SLCRKeyOf(msgid);
    if (!key.length) {
        SLLog(@"REWRITE 保存失败：没有消息号");
        return;
    }
    NSMutableDictionary *store = SLCRStore();
    if (!newText.length) {
        [store removeObjectForKey:key];
        SLCRFlush(store);
        SLLog(@"REWRITE 还原 %@", key);
        return;
    }
    NSDictionary *old = store[key];
    NSString *keepOrig = orig;
    if ([old isKindOfClass:[NSDictionary class]] && [old[@"o"] isKindOfClass:[NSString class]]) {
        keepOrig = old[@"o"];   // 多次修改时始终保留最初的原文
    }
    store[key] = @{
        @"t": newText,
        @"o": keepOrig ?: @"",
        @"s": session ?: @"",
        @"ts": @([[NSDate date] timeIntervalSince1970]),
    };
    SLCRFlush(store);
    SLLog(@"REWRITE 保存 %@ 会话=%@ 长度 %lu", key, session ?: @"-", (unsigned long)newText.length);
}

NSInteger SLChatRewriteCount(void) {
    return (NSInteger)SLCRStore().count;
}

NSArray<NSDictionary *> *SLChatRewriteEntries(void) {
    NSDictionary *store = SLCRStore();
    NSMutableArray *out = [NSMutableArray array];
    [store enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        (void)stop;
        if (![v isKindOfClass:[NSDictionary class]]) return;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"id"] = k;
        m[@"text"] = v[@"t"] ?: @"";
        m[@"orig"] = v[@"o"] ?: @"";
        m[@"session"] = v[@"s"] ?: @"";
        m[@"time"] = v[@"ts"] ?: @(0);
        [out addObject:m];
    }];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"time"] doubleValue], tb = [b[@"time"] doubleValue];
        if (ta == tb) return NSOrderedSame;
        return ta > tb ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

void SLChatRewriteRemove(NSString *msgid) {
    NSString *key = SLCRKeyOf(msgid);
    if (!key.length) return;
    NSMutableDictionary *store = SLCRStore();
    [store removeObjectForKey:key];
    SLCRFlush(store);
}

void SLChatRewriteClearAll(void) {
    SLCRFlush(@{});
    SLLog(@"REWRITE 全部还原");
}

void SLChatRewriteClearSession(NSString *session) {
    if (!session.length) return;
    NSMutableDictionary *store = SLCRStore();
    NSMutableArray *drop = [NSMutableArray array];
    [store enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        (void)stop;
        if (![v isKindOfClass:[NSDictionary class]]) return;
        NSString *s = v[@"s"];
        if ([s isKindOfClass:[NSString class]] && [s isEqualToString:session]) [drop addObject:k];
    }];
    if (!drop.count) return;
    for (NSString *k in drop) [store removeObjectForKey:k];
    SLCRFlush(store);
    SLLog(@"REWRITE 离开会话清理 %lu 条 (%@)", (unsigned long)drop.count, session);
}

#pragma mark - 会话标识

static UIViewController *SLCRTopVC(void) {
    UIWindow *win = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { win = w; break; }
            if (!win && !w.hidden) win = w;
        }
        if (win) break;
    }
    UIViewController *vc = win.rootViewController;
    NSInteger guard = 0;
    while (vc && guard < 24) {
        guard += 1;
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *t = ((UINavigationController *)vc).topViewController;
            if (t) { vc = t; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *t = ((UITabBarController *)vc).selectedViewController;
            if (t) { vc = t; continue; }
        }
        break;
    }
    return vc;
}

static UIViewController *SLCRChatVC(UIViewController *start) {
    UIViewController *vc = start;
    NSInteger guard = 0;
    while (vc && guard < 16) {
        guard += 1;
        if ([vc isKindOfClass:NSClassFromString(@"MDChatBaseViewController")]) return vc;
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *t = ((UINavigationController *)vc).topViewController;
            if (t) { vc = t; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *t = ((UITabBarController *)vc).selectedViewController;
            if (t) { vc = t; continue; }
        }
        break;
    }
    return nil;
}

static NSString *SLCRSessionOfVC(UIViewController *vc) {
    if (!vc) return nil;
    NSArray *keys = @[@"sessionId", @"sessionID", @"chatSessionId", @"conversationId",
                      @"conversationID", @"sessionKey", @"innerSessionKey", @"targetId", @"toUid"];
    for (NSString *k in keys) {
        @try {
            id v = [vc valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
            if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
        } @catch (NSException *e) { }
    }
    // 退路：用控制器地址当会话标识，同一页面内稳定
    return [NSString stringWithFormat:@"vc-%p", vc];
}

NSString *SLChatRewriteCurrentSessionKey(void) {
    UIViewController *vc = SLCRChatVC(SLCRTopVC());
    return SLCRSessionOfVC(vc);
}

#pragma mark - 刷新

static void SLCRWalkTables(UIView *v, NSMutableArray *out) {
    if (!v) return;
    if ([v isKindOfClass:[UITableView class]]) [out addObject:v];
    for (UIView *sub in v.subviews) SLCRWalkTables(sub, out);
}

void SLChatRewriteReloadChat(void) {
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    if (!chat) return;
    NSMutableArray *tables = [NSMutableArray array];
    SLCRWalkTables(chat.view, tables);
    for (UITableView *tv in tables) [tv reloadData];
    SLLog(@"REWRITE 刷新聊天页 %lu 张表", (unsigned long)tables.count);
}

#pragma mark - 编辑面板

@interface SLChatRewriteEditorController : UIViewController
@property (nonatomic, copy) NSString *msgid;
@property (nonatomic, copy) NSString *orig;
@property (nonatomic, copy) NSString *session;
@property (nonatomic, copy) void (^doneBlock)(BOOL changed);
@end

@implementation SLChatRewriteEditorController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"修改";
    SLInstallGlassBackdrop(self.view);
    self.navigationItem.titleView = SLPillTitleView(@"修改消息");
    self.navigationItem.leftBarButtonItem = SLPillBarItem(@"取消", self, @selector(sl_cancel));
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"保存", self, @selector(sl_save));

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.backgroundColor = SLGlassCellColor();
    _textView.layer.cornerRadius = 12.0;
    _textView.layer.cornerCurve = kCACornerCurveContinuous;
    _textView.layer.borderWidth = 0.8;
    _textView.layer.borderColor = SLGlassHairlineColor().CGColor;
    _textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    _textView.font = [UIFont systemFontOfSize:15];
    _textView.textColor = [UIColor labelColor];
    _textView.text = self.orig ?: @"";
    _textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_textView];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_textView becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat top = safe.top + 12.0;
    CGFloat h = MAX(120.0, b.size.height - top - safe.bottom - 12.0);
    _textView.frame = CGRectMake(16, top, MAX(0.0, b.size.width - 32.0), h);
}

- (void)sl_cancel {
    if (self.doneBlock) self.doneBlock(NO);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sl_save {
    NSString *text = _textView.text ?: @"";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *current = [self.orig ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL changed = ![text isEqualToString:current];
    if (changed) {
        SLChatRewriteSave(self.msgid, text, self.orig, self.session);
    }
    if (self.doneBlock) self.doneBlock(changed);
    [self dismissViewControllerAnimated:YES completion:^{
        if (changed) SLChatRewriteReloadChat();
    }];
}

@end

void SLChatRewriteBeginFromBubble(UIView *view) {
    if (!view) return;
    if (!SLChatRewriteEnabled()) {
        SLLog(@"REWRITE 未开启，忽略长按入口");
        return;
    }

    // 从气泡往上找持有 message 的 cell
    id message = nil;
    UIView *cur = view;
    NSInteger guard = 0;
    while (cur && guard < 12) {
        guard += 1;
        if ([cur respondsToSelector:NSSelectorFromString(@"message")]) {
            @try {
                id m = [cur valueForKey:@"message"];
                if (m) { message = m; break; }
            } @catch (NSException *e) { }
        }
        if (![cur isKindOfClass:[UIView class]]) break;
        cur = [cur superview];
    }
    if (!message) {
        SLLog(@"REWRITE 找不到消息对象（气泡链上没有 message）");
        return;
    }

    id msgid = nil;
    NSString *body = nil;
    @try { msgid = [message valueForKey:@"msgid"]; } @catch (NSException *e) { }
    @try { body = [message valueForKey:@"body"]; } @catch (NSException *e) { }
    if (!SLCRKeyOf(msgid)) {
        @try { msgid = [message valueForKey:@"uuid"]; } @catch (NSException *e) { }
    }
    if (![body isKindOfClass:[NSString class]]) body = @"";

    NSString *key = SLCRKeyOf(msgid);
    NSString *orig = body;
    NSString *initial = body;
    if (key.length) {
        NSDictionary *entry = SLCRStore()[key];
        if ([entry isKindOfClass:[NSDictionary class]]) {
            NSString *o = entry[@"o"];
            NSString *t = entry[@"t"];
            if ([o isKindOfClass:[NSString class]] && [o length]) orig = o;
            if ([t isKindOfClass:[NSString class]] && [t length]) initial = t;
        }
    }

    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    NSString *session = SLCRSessionOfVC(chat);
    SLLog(@"REWRITE 打开修改 msgid=%@ 会话=%@ 现长 %lu", key ?: @"-", session ?: @"-", (unsigned long)initial.length);

    SLChatRewriteEditorController *editor = [[SLChatRewriteEditorController alloc] init];
    editor.msgid = key;
    editor.orig = orig;
    editor.session = session;
    editor.doneBlock = ^(BOOL changed) {
        SLLog(@"REWRITE 面板关闭 changed=%d", changed ? 1 : 0);
    };

    UIViewController *host = SLCRTopVC();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        if (nav.sheetPresentationController) {
            nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent],
                                                        [UISheetPresentationControllerDetent largeDetent]];
        }
    }
    [host presentViewController:nav animated:YES completion:nil];
}

void SLChatRewriteHandleLeave(UIViewController *vc) {
    if (!SLChatRewriteResetOnLeave()) return;
    NSString *session = SLCRSessionOfVC(SLCRChatVC(vc) ?: vc);
    if (session.length) SLChatRewriteClearSession(session);
}

#pragma mark - 已修改列表

@implementation SLChatRewriteListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"已修改";
    self.navigationItem.titleView = SLPillTitleView(@"已修改的消息");
    SLApplyGlassTable(self.tableView);
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"全部还原", self, @selector(sl_clearAll));
    SLInstallPillBack(self);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)sl_clearAll {
    if (!SLChatRewriteCount()) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"全部还原"
                                                               message:@"所有被修改过的消息都会恢复原文。"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"全部还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        SLChatRewriteClearAll();
        [self.tableView reloadData];
        SLChatRewriteReloadChat();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv; (void)section;
    NSInteger n = SLChatRewriteCount();
    return n > 0 ? n : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"slcr"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"slcr"];
    cell.backgroundColor = SLGlassCellColor();
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:15];

    NSArray *items = SLChatRewriteEntries();
    if (!items.count) {
        cell.textLabel.text = @"还没有修改过的消息";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = @"开启开关后，长按任意文本气泡即可修改";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (ip.row >= (NSInteger)items.count) return cell;
    NSDictionary *e = items[(NSUInteger)ip.row];
    cell.textLabel.text = e[@"text"] ?: @"";
    cell.textLabel.textColor = [UIColor labelColor];
    NSString *o = e[@"orig"] ?: @"";
    cell.detailTextLabel.text = o.length ? [@"原文：" stringByAppendingString:o] : @"原文：—";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *items = SLChatRewriteEntries();
    if (ip.row >= (NSInteger)items.count) return;
    NSDictionary *e = items[(NSUInteger)ip.row];
    NSString *mid = e[@"id"];
    if (!mid.length) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"还原这条？"
                                                               message:@"恢复成陌陌里的原文。"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        SLChatRewriteRemove(mid);
        [self.tableView reloadData];
        SLChatRewriteReloadChat();
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = tv;
    ac.popoverPresentationController.sourceRect = [tv rectForRowAtIndexPath:ip];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
