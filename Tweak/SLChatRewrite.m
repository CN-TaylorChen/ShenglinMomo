//
//  SLChatRewrite.m
//  声临 · 陌陌版 —— 聊天记录修改（仅本机渲染层）
//

#import "SLChatRewrite.h"
#import <objc/runtime.h>
#import "SLGlass.h"
#import "SLLog.h"
#import "AWECAUtils.h"

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

// 别名索引缓存（alias -> entry），落盘或改写时失效重建
static NSMutableDictionary *gSLCRIndex = nil;

static void SLCRFlush(NSDictionary *store) {
    gSLCRCache = store ? [NSMutableDictionary dictionaryWithDictionary:store] : [NSMutableDictionary dictionary];
    gSLCRIndex = nil;   // 别名索引下次查询时重建
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (gSLCRCache.count) [d setObject:gSLCRCache forKey:kSLCRStoreKey];
    else [d removeObjectForKey:kSLCRStoreKey];
    [d synchronize];
}

#pragma mark - 别名索引
//
// 陌陌的菜单和消息对象用的不是同一个 id：
//   菜单 msgid = "264-DB201489B738"（seq-uuid 拼的）
//   消息 msgid = 264 / uuid = DB201489B738
// 所以一条改写要挂多个别名，body getter 拿哪个都能命中。
// 用一张 alias -> entry 的表，避免每次 body 读都遍历整个 store。

static void SLCRRebuildIndex(void) {
    NSMutableDictionary *idx = [NSMutableDictionary dictionary];
    NSDictionary *store = SLCRStore();
    [store enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        (void)stop;
        if (![v isKindOfClass:[NSDictionary class]]) return;
        idx[k] = v;
        // 老版本只存了 "264-DB201489B738" 这种主键，没有 ids；
        // 这里顺手把段拆出来，升级前改过的记录也能继续命中。
        for (NSString *part in [(NSString *)k componentsSeparatedByString:@"-"]) {
            if (part.length > 1 && !idx[part]) idx[part] = v;
        }
        NSArray *ids = ((NSDictionary *)v)[@"ids"];
        if (![ids isKindOfClass:[NSArray class]]) return;
        for (id a in ids) {
            if ([a isKindOfClass:[NSString class]] && [(NSString *)a length]) idx[a] = v;
        }
    }];
    gSLCRIndex = idx;
}

static NSDictionary *SLCRLookup(NSString *key) {
    if (!key.length) return nil;
    if (!gSLCRIndex) SLCRRebuildIndex();
    id v = gSLCRIndex[key];
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

static NSString *SLCRTextOfEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSString *t = entry[@"t"];
    return ([t isKindOfClass:[NSString class]] && t.length) ? t : nil;
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
    NSString *text = SLCRTextOfEntry(SLCRLookup(SLCRKeyOf(msgid)));
    return text ?: orig;
}

NSString *SLChatRewriteTextForIds(NSArray *ids, NSString *orig) {
    if (!orig) return orig;
    if (!SLChatRewriteEnabled()) return orig;
    if (![ids isKindOfClass:[NSArray class]] || !ids.count) return orig;
    for (id a in ids) {
        NSString *key = SLCRKeyOf(a);
        NSString *text = SLCRTextOfEntry(SLCRLookup(key));
        if (text) return text;
    }
    return orig;
}

// 一条改写要挂的 id 集合：消息对象上的每个 id 字段 + 菜单给的串 + 串里拆出来的段。
// "264-DB201489B738" 拆成 264 / DB201489B738，body getter 用它拿到的任何一个都能命中。
NSArray *SLChatRewriteAliasesForMessage(id message, NSString *extra) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *keys = @[@"msgid", @"uuid", @"remoteid", @"autoid"];
    for (NSString *k in keys) {
        id v = nil;
        @try { v = [message valueForKey:k]; } @catch (NSException *e) { }
        NSString *s = SLCRKeyOf(v);
        if (s.length && ![out containsObject:s]) [out addObject:s];
    }
    if ([extra isKindOfClass:[NSString class]] && extra.length && ![out containsObject:extra]) {
        [out addObject:extra];
    }
    for (NSString *s in [out copy]) {
        if (![s isKindOfClass:[NSString class]] || ![s containsString:@"-"]) continue;
        for (NSString *part in [s componentsSeparatedByString:@"-"]) {
            if (part.length && ![out containsObject:part]) [out addObject:part];
        }
    }
    return out;
}

// body 是不是「可以直接当文字改」的那种。
// 卡片 / 小程序 / 礼物 / 火花提示这些消息的 body 是整坨 JSON（prender / icon / images /
// extends ... 一千多字），卡片上显示的文字是从 JSON 里解析出来的，改 body 不会重新渲染，
// 于是「保存成功、界面照旧」—— 上一版就是这么白改的。这类一律拦掉。
BOOL SLChatRewriteMessageIsText(id message) {
    if (!message) return NO;
    NSString *body = nil;
    @try { body = [message valueForKey:@"body"]; } @catch (NSException *e) { }
    if (![body isKindOfClass:[NSString class]]) return NO;
    NSString *t = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return NO;
    if (t.length > 1200) return NO;                       // 卡片配置串远长于正常聊天
    unichar c = [t characterAtIndex:0];
    if (c == '{' || c == '[') return NO;                  // JSON 对象 / 数组
    if ([t rangeOfString:@"\":\""].location != NSNotFound) return NO;   // JSON 片段
    return YES;
}

void SLChatRewriteSave(NSString *msgid, NSArray *aliases, NSString *newText,
                       NSString *orig, NSString *session) {
    NSString *key = SLCRKeyOf(msgid);
    if (!key.length) {
        SLLog(@"REWRITE 保存失败：没有消息号");
        return;
    }
    NSMutableDictionary *store = SLCRStore();
    if (!newText.length) {
        // 还原：主键和别名命中的那条一起删
        NSDictionary *hit = SLCRLookup(key);
        NSString *primary = key;
        if (hit) {
            for (NSString *k in store) {
                if (store[k] == hit) { primary = k; break; }
            }
        }
        [store removeObjectForKey:primary];
        [store removeObjectForKey:key];
        SLCRFlush(store);
        SLLog(@"REWRITE 还原 %@", primary);
        return;
    }
    NSDictionary *old = SLCRLookup(key);
    NSString *keepOrig = orig;
    if ([old isKindOfClass:[NSDictionary class]] && [old[@"o"] isKindOfClass:[NSString class]]) {
        keepOrig = old[@"o"];   // 多次修改时始终保留最初的原文
    }
    NSMutableArray *ids = [NSMutableArray array];
    if ([aliases isKindOfClass:[NSArray class]]) {
        for (id a in aliases) {
            NSString *s = SLCRKeyOf(a);
            if (s.length && ![ids containsObject:s]) [ids addObject:s];
        }
    }
    if (![ids containsObject:key]) [ids insertObject:key atIndex:0];
    store[key] = @{
        @"t": newText,
        @"o": keepOrig ?: @"",
        @"s": session ?: @"",
        @"ts": @([[NSDate date] timeIntervalSince1970]),
        @"ids": ids,
    };
    SLCRFlush(store);
    SLLog(@"REWRITE 保存 %@ 别名 %lu 个 [%@] 会话=%@ 长度 %lu",
          key, (unsigned long)ids.count, [ids componentsJoinedByString:@" "],
          session ?: @"-", (unsigned long)newText.length);
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
@property (nonatomic, copy) NSArray *aliases;
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
        SLChatRewriteSave(self.msgid, self.aliases, text, self.orig, self.session);
    }
    if (self.doneBlock) self.doneBlock(changed);
    [self dismissViewControllerAnimated:YES completion:^{
        if (changed) SLChatRewriteReloadChat();
    }];
}

@end

#pragma mark - 反查被长按的那条消息

static NSString *SLCRMsgidOf(id message);
static NSString *SLCRPreview(NSString *s, NSUInteger max);

// 消息对象身上一定有 body 这个字符串。反过来用就是最稳的识别方式 ——
// 不认类名，只认「谁身上有 body」。
static NSString *SLCRBodyOf(id obj) {
    if (!obj) return nil;
    id v = nil;
    @try {
        if ([obj respondsToSelector:NSSelectorFromString(@"body")]) v = [obj valueForKey:@"body"];
    } @catch (NSException *e) { }
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

// 真的是「消息」而不只是「有个 body 字段的模型」：消息一定有 msgid / uuid。
// 少了这道判断，一个文本排版模型也会被当成消息收下，改完照样不生效。
static BOOL SLCRLooksMessage(id obj) {
    if (!SLCRBodyOf(obj)) return NO;
    id mid = nil;
    @try {
        if ([obj respondsToSelector:NSSelectorFromString(@"msgid")]) mid = [obj valueForKey:@"msgid"];
        if (!mid && [obj respondsToSelector:NSSelectorFromString(@"uuid")]) {
            mid = [obj valueForKey:@"uuid"];
        }
    } @catch (NSException *e) { }
    return mid != nil;
}

// 一个视图（或任何对象）身上挂的消息。
//
// 文本气泡 cell 是 Swift 的 MDChatBusinessBase.MDSChatType1Cell：
// 它既没有 message（基类 MDChatBaseCell 那个 getter 是空实现），也没有 mixItem，
// 真正的模型在 ivar `dataItem` 里（v0.5.04 把 ivar 名打出来才看见：
// $__lazy_storage_$_contentLabel 一大堆懒加载控件 + delegate + dataItem）。
// 所以这里既按名字试最常见的几个 key，也直接枚举对象型 ivar —— 不写死名字，
// 深度 2 正好够 cell → item → message。
static id SLCRMessageOfDepth(id obj, NSInteger depth);

static id SLCRMessageViaIvars(id obj, NSInteger depth) {
    if (!obj || depth <= 0 || [obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSData class]]) return nil;
    Class cls = object_getClass(obj);
    NSInteger guard = 0;
    id found = nil;
    while (cls && cls != [NSObject class] && guard < 8 && !found) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n && !found; i++) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (!t || t[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(obj, ivars[i]); } @catch (NSException *e) { }
            if (!v || v == obj) continue;
            found = SLCRMessageOfDepth(v, depth - 1);
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
        guard += 1;
    }
    return found;
}

static id SLCRMessageOfDepth(id obj, NSInteger depth) {
    if (!obj) return nil;
    if (SLCRLooksMessage(obj)) return obj;
    for (NSString *k in @[@"message", @"mixItem", @"dataItem"]) {
        id v = nil;
        @try {
            if ([obj respondsToSelector:NSSelectorFromString(k)]) v = [obj valueForKey:k];
        } @catch (NSException *e) { }
        if (!v || v == obj) continue;
        id m = SLCRMessageOfDepth(v, depth - 1);
        if (m) return m;
    }
    return SLCRMessageViaIvars(obj, depth);
}

static id SLCRMessageOf(id obj) {
    return SLCRMessageOfDepth(obj, 2);
}

// 在子树里收集挂着消息的视图。@try 必须包在单个视图上：
// 陌陌里大量 Swift 类，valueForKey 撞到不存在的 key 会抛 NSUnknownKeyException，
// 整个 BFS 外面只包一层的话，一条不认的视图就能把整趟扫描吞掉。
static void SLCRCollectMessageViews(UIView *v, NSInteger depth, NSInteger *budget,
                                    NSMutableArray *out) {
    if (!v || *budget <= 0 || depth > 24) return;
    *budget -= 1;
    if (SLCRMessageOf(v)) [out addObject:v];
    for (UIView *sub in v.subviews) {
        if (*budget <= 0) break;
        SLCRCollectMessageViews(sub, depth + 1, budget, out);
    }
}

// 视图此刻是不是真看得见。cell 里常年挂着一堆复用视图（hidden / alpha=0 / 已移出 window），
// 它们的 message 还留着上一次渲染的值 —— 这正是「长按哪条都认成同一张卡片」的来源。
static BOOL SLCRViewVisible(UIView *v) {
    if (!v) return NO;
    if (v.hidden || v.alpha < 0.05) return NO;
    if (!v.window) return NO;
    return YES;
}

// 聊天页里面积最大的 UITableView
static UITableView *SLCRChatTable(UIView *root) {
    if (!root) return nil;
    UITableView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 600;
    while (stack.count && budget-- > 0) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) {
            CGFloat area = v.bounds.size.width * v.bounds.size.height;
            if (area > bestArea) { bestArea = area; best = (UITableView *)v; }
            continue;   // 不进列表内部，免得撞上 cell 里的二级列表
        }
        if ([v isKindOfClass:[UICollectionView class]]) continue;
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return best;
}

// cell 上最长的可见文字。文字气泡里那就是气泡本身，用来兜原文、也用来
// 校验「按坐标取到的 cell 到底是不是用户按的那条」。
static NSString *SLCRLongestText(UIView *v) {
    if (!v) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:v];
    NSString *best = nil;
    NSInteger budget = 400;
    while (stack.count && budget-- > 0) {
        UIView *cur = [stack lastObject];
        [stack removeLastObject];
        if (cur.hidden || cur.alpha < 0.05) continue;
        NSString *t = nil;
        if ([cur isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)cur;
            t = l.attributedText.length ? l.attributedText.string : l.text;
        } else if ([cur isKindOfClass:[UITextView class]]) {
            t = ((UITextView *)cur).text;
        }
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length && (!best || t.length > best.length)) best = t;
        for (UIView *sub in cur.subviews) [stack addObject:sub];
    }
    return best;
}

// 认不出消息时把 cell 的 ivar 名打出来。下一版就不用再猜它把数据放哪了。
static NSString *SLCRIvarNames(id obj) {
    if (!obj) return @"-";
    NSMutableArray *out = [NSMutableArray array];
    Class cls = object_getClass(obj);
    NSInteger guard = 0;
    while (cls && cls != [NSObject class] && guard < 6) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n && out.count < 48; i++) {
            const char *nm = ivar_getName(ivars[i]);
            if (!nm) continue;
            [out addObject:[NSString stringWithUTF8String:nm]];
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
        guard += 1;
    }
    return out.count ? [out componentsJoinedByString:@" "] : @"-";
}

// 找聊天列表：先问聊天页，认不出来再在所有窗口里挑面积最大的
static UITableView *SLCRChatTableAnywhere(void) {
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *table = chat ? SLCRChatTable(chat.view) : nil;
    if (table) return table;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden) continue;
            table = SLCRChatTable(w);
            if (table) return table;
        }
    }
    return nil;
}

// 按屏幕坐标取被长按的那条消息。
// targetView 是整个聊天页、targetViewFrame 才是气泡矩形，所以坐标这条路是唯一可靠的定位；
// 之前从 targetView 子树里翻候选，翻到的全是页面里常驻的旧卡片。
static id SLCRHitAtScreenPoint(CGPoint pt, UITableViewCell **outCell, NSString **outText) {
    if (outCell) *outCell = nil;
    if (outText) *outText = nil;
    if (CGPointEqualToPoint(pt, CGPointZero)) return nil;
    UITableView *table = SLCRChatTableAnywhere();
    if (!table) {
        SLLog(@"REWRITE 坐标反查：没找到聊天列表");
        return nil;
    }
    CGPoint p = [table convertPoint:pt fromView:nil];
    NSIndexPath *ip = [table indexPathForRowAtPoint:p];
    SLLog(@"REWRITE 坐标反查 pt=(%.0f,%.0f) → 表内 (%.0f,%.0f) ip=%@ 表=%@",
          pt.x, pt.y, p.x, p.y,
          ip ? [NSString stringWithFormat:@"%ld-%ld", (long)ip.section, (long)ip.row] : @"nil",
          NSStringFromClass([table class]));
    if (!ip) return nil;

    UITableViewCell *cell = [table cellForRowAtIndexPath:ip];
    if (!cell) {
        SLLog(@"REWRITE 坐标命中 ip 但 cell 为空");
        return nil;
    }
    if (outCell) *outCell = cell;
    NSString *text = SLCRLongestText(cell);
    if (outText) *outText = text;

    id m = SLCRMessageOf(cell);
    if (m) {
        SLLog(@"REWRITE 坐标命中 cell=%@ 消息=%@ 文字=%@",
              NSStringFromClass([cell class]), NSStringFromClass([m class]),
              SLCRPreview(text, 18));
        return m;
    }

    // cell 自己不挂消息时，回到它子树里找，并且只认看得见的
    NSMutableArray *hits = [NSMutableArray array];
    NSInteger budget = 300;
    SLCRCollectMessageViews(cell, 0, &budget, hits);
    UIView *best = nil;
    CGFloat bestD = CGFLOAT_MAX;
    for (UIView *v in hits) {
        if (!SLCRViewVisible(v)) continue;
        CGRect r = [v convertRect:v.bounds toView:nil];
        CGFloat d = fabs(CGRectGetMidY(r) - pt.y) + fabs(CGRectGetMidX(r) - pt.x);
        if (d < bestD) { bestD = d; best = v; }
    }
    if (!best) {
        SLLog(@"REWRITE 坐标命中 cell=%@ 但挖不出消息（候选 %lu / 文字=%@）ivars=%@",
              NSStringFromClass([cell class]), (unsigned long)hits.count,
              SLCRPreview(text, 18), SLCRIvarNames(cell));
        return nil;
    }
    SLLog(@"REWRITE 坐标命中 cell=%@ 子视图=%@ 偏 %.0f",
          NSStringFromClass([cell class]), NSStringFromClass([best class]), bestD);
    return SLCRMessageOf(best);
}

// 兜底：在 root 子树里找带 message 的可见视图。
// anchor 是屏幕坐标，比较时也得把候选换到 window 坐标 —— 之前拿屏幕坐标比 root 坐标，
// 量纲都不一样，距离算出来是废的。
static id SLCRMessageNearPoint(UIView *root, NSString *wantKey, CGPoint screenAnchor, BOOL hasAnchor) {
    if (!root) return nil;
    NSMutableArray *hits = [NSMutableArray array];
    NSInteger budget = 900;
    SLCRCollectMessageViews(root, 0, &budget, hits);
    SLLog(@"REWRITE 子树扫描 %@：带 message 的视图 %lu 个（预算余 %ld）want=%@",
          NSStringFromClass([root class]), (unsigned long)hits.count, (long)budget, wantKey ?: @"-");
    if (!hits.count) return nil;

    NSMutableArray *live = [NSMutableArray array];
    for (UIView *v in hits) {
        if (SLCRViewVisible(v)) [live addObject:v];
    }
    if (live.count != hits.count) {
        SLLog(@"REWRITE 过滤不可见候选 %lu → %lu", (unsigned long)hits.count, (unsigned long)live.count);
    }
    if (!live.count) return nil;

    // 1) 精确匹配：菜单给的 "264-DB201489B738" 拆成 264 / DB201489B738，
    //    和每条 message 的 msgid / uuid / remoteid / autoid 逐一比。
    if (wantKey.length) {
        NSMutableArray *wantAliases = [NSMutableArray arrayWithObject:wantKey];
        for (NSString *part in [wantKey componentsSeparatedByString:@"-"]) {
            if (part.length && ![wantAliases containsObject:part]) [wantAliases addObject:part];
        }
        for (UIView *v in live) {
            id m = SLCRMessageOf(v);
            if (!m) continue;
            NSArray *ids = SLChatRewriteAliasesForMessage(m, nil);
            for (NSString *a in ids) {
                if (![a isKindOfClass:[NSString class]]) continue;
                if ([wantAliases containsObject:a]) {
                    SLLog(@"REWRITE 按 id 命中 %@ 类=%@ ids=[%@]", NSStringFromClass([v class]),
                          NSStringFromClass([m class]), [ids componentsJoinedByString:@" "]);
                    return m;
                }
            }
        }
        // 不再「唯一候选直接用」：那条兜底会把复用池里的旧卡片当成结果，
        // 于是长按哪条都变成同一张卡片（v0.5.02 实测就是这样）。
        SLLog(@"REWRITE %lu 个可见候选都对不上 id=%@，放弃（宁可打不开也不改错人）",
              (unsigned long)live.count, wantKey);
        return nil;
    }

    UIView *best = nil;
    CGFloat bestD = CGFLOAT_MAX;
    CGFloat bestArea = 0;
    for (UIView *v in live) {
        CGRect r = [v convertRect:v.bounds toView:nil];
        if (CGRectIsEmpty(r)) continue;
        if (!hasAnchor) {
            CGFloat area = r.size.width * r.size.height;
            if (area > bestArea) { bestArea = area; best = v; }
            continue;
        }
        CGFloat dx = CGRectGetMidX(r) - screenAnchor.x;
        CGFloat dy = CGRectGetMidY(r) - screenAnchor.y;
        CGFloat d = dx * dx + dy * dy;
        if (d < bestD) { bestD = d; best = v; }
    }
    if (!best) best = live.firstObject;
    SLLog(@"REWRITE 选中 %@ frame=%@ 离锚点 %.0f",
          NSStringFromClass([best class]),
          NSStringFromCGRect([best convertRect:best.bounds toView:nil]),
          (hasAnchor && bestD < CGFLOAT_MAX) ? sqrt(bestD) : -1.0);

    id m = SLCRMessageOf(best);
    return m;
}

static NSString *SLCRMsgidOf(id message) {
    if (!message) return nil;
    id mid = nil;
    @try { mid = [message valueForKey:@"msgid"]; } @catch (NSException *e) { }
    if (!SLCRKeyOf(mid)) { @try { mid = [message valueForKey:@"uuid"]; } @catch (NSException *e) { } }
    return SLCRKeyOf(mid);
}

// SLLog 一行一条，body 里的换行会把日志撑乱；这里压成单行并截断
static NSString *SLCRPreview(NSString *s, NSUInteger max) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return @"";
    NSString *t = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    t = [t stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (t.length <= max) return t;
    return [[t substringToIndex:max] stringByAppendingString:@"…"];
}

static void SLCROpenEditor(id message, NSString *fallbackKey, NSString *cellCls, NSString *hint) {
    NSString *key = SLCRMsgidOf(message) ?: fallbackKey;
    if (!key.length) {
        SLLog(@"REWRITE 打不开：既没有 message 也没有 msgid");
        return;
    }

    // 一条改写挂上全套 id：消息对象的 msgid / uuid / remoteid / autoid，
    // 再加上菜单给的串。body getter 拿其中任何一个都能命中。
    NSArray *aliases = SLChatRewriteAliasesForMessage(message, fallbackKey);

    NSString *body = nil;
    @try { body = [message valueForKey:@"body"]; } @catch (NSException *e) { }
    if (![body isKindOfClass:[NSString class]]) body = @"";
    // body 拿不到时用 cell 上最长的那行文字兜底 —— 至少编辑器里不会是空的
    NSString *display = body.length ? body : (hint.length ? hint : @"");

    // 类型探针：这一段是「改了没变」时的唯一证据源。
    // cell 类名 + type/contentType 一起打，下一版就能按白名单精确放行。
    NSString *typeStr = @"-";
    NSString *cateStr = @"-";
    NSString *ctStr = @"-";
    @try { typeStr = [[message valueForKey:@"type"] description] ?: @"-"; } @catch (NSException *e) { }
    @try { cateStr = [[message valueForKey:@"cate"] description] ?: @"-"; } @catch (NSException *e) { }
    @try { ctStr = [[message valueForKey:@"contentType"] description] ?: @"-"; } @catch (NSException *e) { }
    SLLog(@"REWRITE 类型 cls=%@ cell=%@ type=%@ cate=%@ contentType=%@ body=%@",
          message ? NSStringFromClass([message class]) : @"nil",
          cellCls ?: @"-", typeStr, cateStr, ctStr, SLCRPreview(body, 32));

    if (message && body.length && !SLChatRewriteMessageIsText(message)) {
        SLLog(@"REWRITE 拒绝：非文字消息（body 长度 %lu，看上面类型行）", (unsigned long)body.length);
        [AWECAUtils showToast:@"这条不是文字消息，改不了" duration:2.0];
        return;
    }

    NSString *orig = display;
    NSString *initial = display;
    NSDictionary *entry = SLCRLookup(key);
    if ([entry isKindOfClass:[NSDictionary class]]) {
        NSString *o = entry[@"o"];
        NSString *t = entry[@"t"];
        if ([o isKindOfClass:[NSString class]] && [o length]) orig = o;
        if ([t isKindOfClass:[NSString class]] && [t length]) initial = t;
    }

    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    NSString *session = SLCRSessionOfVC(chat);
    SLLog(@"REWRITE 打开修改 key=%@ 别名=[%@] 会话=%@ 现长 %lu",
          key, [aliases componentsJoinedByString:@" "], session ?: @"-", (unsigned long)initial.length);

    SLChatRewriteEditorController *editor = [[SLChatRewriteEditorController alloc] init];
    editor.msgid = key;
    editor.aliases = aliases;
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

// 从锚点视图往上找宿主 cell。类是 Swift 的（MDChatBusinessBase.MDSChatType2Cell），
// 类名能直接看出消息类型：Type2 文本、Type3 语音、Type28 卡片 —— 日志里一眼能对。
static NSString *SLCRHostCellClass(UIView *v) {
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard < 20) {
        guard += 1;
        if ([cur isKindOfClass:[UITableViewCell class]] ||
            [cur isKindOfClass:[UICollectionViewCell class]]) {
            return NSStringFromClass([cur class]);
        }
        cur = cur.superview;
    }
    return nil;
}

void SLChatRewriteBeginFromBubble(UIView *view) {
    if (!view) return;
    if (!SLChatRewriteEnabled()) {
        SLLog(@"REWRITE 未开启，忽略长按入口");
        return;
    }

    // 先从气泡往上爬（原生多数版本气泡自身就挂 message）
    id message = nil;
    UIView *cur = view;
    NSInteger guard = 0;
    while (cur && guard < 12) {
        guard += 1;
        id m = SLCRMessageOf(cur);
        if (m) { message = m; break; }
        if (![cur isKindOfClass:[UIView class]]) break;
        cur = [cur superview];
    }
    if (!message) message = SLCRMessageNearPoint(view, nil, CGPointZero, NO);
    if (!message) {
        SLLog(@"REWRITE 找不到消息对象（气泡链与子树都没有 message）");
        return;
    }
    SLCROpenEditor(message, nil, SLCRHostCellClass(view), nil);
}

void SLChatRewriteBeginFromMenu(UIView *menuView) {
    if (!menuView) return;
    if (!SLChatRewriteEnabled()) {
        SLLog(@"REWRITE 未开启，忽略菜单入口");
        return;
    }

    // 气泡不在菜单的视图链上（菜单是挂在根 VC 上的浮层），
    // 只能靠菜单自己记下的锚点：targetView + targetViewFrame / targetViewCenter。
    UIView *tv = nil;
    CGRect tvFrame = CGRectNull;
    CGPoint tvCenter = CGPointZero;
    BOOL hasCenter = NO;
    NSString *menuMid = nil;

    @try {
        id v = [menuView valueForKey:@"targetView"];
        if ([v isKindOfClass:[UIView class]]) tv = (UIView *)v;
    } @catch (NSException *e) { }
    @try {
        id v = [menuView valueForKey:@"targetViewFrame"];
        if ([v isKindOfClass:[NSValue class]]) tvFrame = [(NSValue *)v CGRectValue];
    } @catch (NSException *e) { }
    @try {
        id v = [menuView valueForKey:@"targetViewCenter"];
        if ([v isKindOfClass:[NSValue class]]) {
            tvCenter = [(NSValue *)v CGPointValue];
            hasCenter = (tvCenter.x != 0.0 || tvCenter.y != 0.0);
        }
    } @catch (NSException *e) { }
    @try { menuMid = SLCRKeyOf([menuView valueForKey:@"msgid"]); } @catch (NSException *e) { }

    SLLog(@"REWRITE 菜单锚点 targetView=%@ frame=%@ center=%@ msgid=%@",
          tv ? NSStringFromClass([tv class]) : @"nil",
          CGRectIsNull(tvFrame) ? @"-" : NSStringFromCGRect(tvFrame),
          hasCenter ? NSStringFromCGPoint(tvCenter) : @"-",
          menuMid ?: @"-");

    // 统一成屏幕坐标再往下走：targetViewCenter 本身就是屏幕坐标（跟 targetViewFrame
    // 中心对得上），别拿它跟 root 局部坐标混着比，那样算出来的距离是废的。
    if (!hasCenter && tv) {
        CGPoint c = CGPointZero;
        if (!CGRectIsNull(tvFrame) && !CGRectIsEmpty(tvFrame)) {
            c = CGPointMake(CGRectGetMidX(tvFrame), CGRectGetMidY(tvFrame));
            if (CGRectContainsRect(tv.bounds, tvFrame)) {
                c = [tv convertPoint:c toView:nil];      // frame 是局部坐标，转到屏幕
            }
        } else {
            c = [tv convertPoint:CGPointMake(CGRectGetMidX(tv.bounds), CGRectGetMidY(tv.bounds))
                          toView:nil];
        }
        tvCenter = c;
        hasCenter = YES;
    }

    // 先按坐标问列表要那条消息，再退回子树扫描。
    // cell 里的复用视图会让子树扫描翻到「上一次渲染的那条」，坐标路径没有这个毛病。
    id message = nil;
    UITableViewCell *cell = nil;
    NSString *hint = nil;
    if (hasCenter) message = SLCRHitAtScreenPoint(tvCenter, &cell, &hint);
    if (!message) {
        // 坐标这条路走不通时，才退回「在 targetView 子树里按 id 找」。
        // 注意 targetView 其实是整个聊天页，页里常驻的旧卡片也会被扫到，所以必须 id 匹配。
        message = SLCRMessageNearPoint(tv, menuMid, tvCenter, hasCenter);
    }
    if (!message) {
        SLLog(@"REWRITE 反查失败：坐标与子树都没拿到消息，不打开面板（msgid=%@ 文字=%@）",
              menuMid ?: @"-", SLCRPreview(hint, 18));
        return;
    }
    NSString *cellCls = cell ? NSStringFromClass([cell class]) : SLCRHostCellClass(tv);
    SLCROpenEditor(message, menuMid, cellCls, hint);
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
