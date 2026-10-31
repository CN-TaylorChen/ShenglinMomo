//
//  SLChatRewrite.m
//  声临 · 陌陌版 —— 聊天记录修改（仅本机渲染层）
//

#import "SLChatRewrite.h"
#import <objc/runtime.h>
#import <string.h>
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
    // 默认不还原：改聊天记录就是为了截图，一退会话全没 = 白改（用户反馈的「重置」）。
    // 想一退就复原的，去设置里把开关打开。
    if (![d objectForKey:kSLCRResetKey]) return NO;
    return [d boolForKey:kSLCRResetKey];
}

void SLChatRewriteSetEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLCREnabledKey];
}

void SLChatRewriteSetResetOnLeave(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLCRResetKey];
}

#pragma mark - 实拍卡片：时间 / 公里数

// 实拍时刻这类卡片（knock_type28）的 body 是一坨 prerender JSON，
// 屏幕上的 "11:44" 和 "38.62km" 就是里面的字面量。不必知道字段名 ——
// 直接按形态替换：时间认 `H:mm` / `HH:mm`，距离认 `数字km`。
// 边界用前后不挨数字/冒号卡住，免得把 "11:44:00" 这种完整时间戳改成半边。
static NSString *const kSLRealShotTimeKey = @"SLRealShotTime";
static NSString *const kSLRealShotDistKey = @"SLRealShotDistance";
static NSString *const kSLRecallGuardKey  = @"SLRecallGuard";
/// 被我们拦下来的撤回：msgid → 原文（持久，重进仍在）
static NSString *const kSLRecallBlockedKey = @"SLRecallBlocked";
/// 隐藏拦截标记开关
static NSString *const kSLRecallHideKey   = @"SLRecallHide";
static NSInteger gSLRealShotLog = 0;

static NSString *SLTrimmed(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? s : nil;
}

NSString *SLRealShotTime(void) {
    return SLTrimmed([[NSUserDefaults standardUserDefaults] stringForKey:kSLRealShotTimeKey]);
}

NSString *SLRealShotDistance(void) {
    return SLTrimmed([[NSUserDefaults standardUserDefaults] stringForKey:kSLRealShotDistKey]);
}

void SLRealShotSetTime(NSString *v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *t = SLTrimmed(v);
    if (t.length) [d setObject:t forKey:kSLRealShotTimeKey];
    else [d removeObjectForKey:kSLRealShotTimeKey];
}

void SLRealShotSetDistance(NSString *v) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *t = SLTrimmed(v);
    if (t.length) [d setObject:t forKey:kSLRealShotDistKey];
    else [d removeObjectForKey:kSLRealShotDistKey];
}

NSString *SLApplyRealShotEdits(NSString *json) {
    if (![json isKindOfClass:[NSString class]] || json.length < 40) return json;
    unichar c0 = [json characterAtIndex:0];
    if (c0 != '{' && c0 != '[') return json;          // 只动 JSON 卡片，普通文字不碰
    NSString *tt = SLRealShotTime();
    NSString *dd = SLRealShotDistance();
    if (!tt.length && !dd.length) return json;

    NSString *out = json;
    NSInteger nTime = 0, nDist = 0;
    if (tt.length) {
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:@"(?<![0-9:])([0-2]?[0-9]):([0-5][0-9])(?![0-9:])"
                                                      options:0 error:NULL];
        NSRange all = NSMakeRange(0, out.length);
        nTime = (NSInteger)[re numberOfMatchesInString:out options:0 range:all];
        if (nTime > 0) {
            out = [re stringByReplacingMatchesInString:out options:0 range:all withTemplate:tt];
        }
    }
    if (dd.length) {
        NSString *tpl = [dd.lowercaseString hasSuffix:@"km"] ? dd : [dd stringByAppendingString:@"km"];
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:@"[0-9]+(?:\\.[0-9]+)?\\s*km"
                                                      options:NSRegularExpressionCaseInsensitive error:NULL];
        NSRange all = NSMakeRange(0, out.length);
        nDist = (NSInteger)[re numberOfMatchesInString:out options:0 range:all];
        if (nDist > 0) {
            out = [re stringByReplacingMatchesInString:out options:0 range:all withTemplate:tpl];
        }
    }
    if ((nTime || nDist) && gSLRealShotLog < 6) {
        gSLRealShotLog += 1;
        SLLog(@"REALSHOT 卡片改写 时间×%ld→%@ 距离×%ld→%@", (long)nTime, tt ?: @"-",
              (long)nDist, dd ?: @"-");
    }
    return out;
}

#pragma mark - 消息上方那行「时间 + 距离」

// 这几个辅助函数定义在文件后半段，这里先用着，得先声明（C99 隐式声明是 error）
static UIViewController *SLCRTopVC(void);
static UIViewController *SLCRChatVC(UIViewController *start);
static UITableView *SLCRChatTable(UIView *root);
static UITableView *SLCRChatTableAnywhere(void);
static void SLCRDumpStyleOnce(UIView *root, NSString *tag);
static NSAttributedString *SLCRReplaceAttributed(NSAttributedString *src, NSString *repl);
static BOOL SLCRIsLabelLike(id v);
static NSString *SLCRShownTextOf(id v);
static BOOL SLCRSetShownText(id v, NSString *target);
static NSString *SLCRTextAnywhere(UIView *v, NSInteger depth);
static id SLCRMessageOf(id obj);
static NSString *SLCRMsgidOf(id message);
static void SLChatClearVisibleHighlights(void);
NSString *SLCRMsgidAtIndexPath(UITableView *tv, NSIndexPath *ip);

// 聊天界面上每条消息上方那行 `12:48 35.95km` / `5分钟前 96.96km`。
// 它不在任何 JSON 里 —— App 拿这条消息的发送时间和当时的经纬度现场算出来的，
// 所以「改 body」对它一点用没有（v0.5.08 就改错了地方），
// 而且**每条消息都不一样**：给它做成一个全局设置只会把所有气泡刷成同一串（v0.5.10 的错）。
//
// v0.5.11 起改成一条一条改：长按气泡 → 「改时间」→ 只作用于这一条。
// 映射按 msgid 存，渲染时按「这条消息上方最近的那格」贴回去。
static NSRegularExpression *SLMetaPairRE(void) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^\\s*(.+?)\\s+([0-9]+(?:\\.[0-9]+)?\\s*[kK][mM])\\s*$"
                                                       options:0 error:NULL];
    });
    return re;
}

static NSString *const kSLMetaStoreKey = @"SLChatMetaStore";
static NSMutableDictionary *gSLMetaStore = nil;
static NSInteger gSLMetaLog = 0;

static NSMutableDictionary *SLMetaStore(void) {
    if (gSLMetaStore) return gSLMetaStore;
    gSLMetaStore = [NSMutableDictionary dictionary];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSLMetaStoreKey];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        for (id k in saved) {
            id v = saved[k];
            if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSDictionary class]]) {
                gSLMetaStore[k] = [v mutableCopy];
            }
        }
    }
    // v0.5.10 的两个全局值是个错误设计（所有消息会被刷成同一串 3581248454km），
    // 升级上来的一次性清掉，免得残留在老用户机上继续污染。
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kSLRealShotTimeKey] || [d objectForKey:kSLRealShotDistKey]) {
        [d removeObjectForKey:kSLRealShotTimeKey];
        [d removeObjectForKey:kSLRealShotDistKey];
        SLLog(@"META 清掉旧的全局时间/距离设置（改为按条修改）");
    }
    return gSLMetaStore;
}

static void SLMetaSync(void) {
    [[NSUserDefaults standardUserDefaults] setObject:gSLMetaStore ?: @{} forKey:kSLMetaStoreKey];
}

// 用户填的是「哪一天几点」这种绝对时间（2026-10-31 12:00），
// 屏幕上要的是陌陌那种相对说法（10分钟前 / 昨天 12:00）。
// 所以：存绝对时间，每次渲染时按「当前时刻」重新算一遍 ——
// 这样时间行会随着时间自己走，而不是焊死成字符串。
static NSTimeInterval SLMetaParseWhen(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return 0;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return 0;
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^(?:(\\d{2,4})[-/.](\\d{1,2})[-/.](\\d{1,2}))?\\s*(?:(\\d{1,2}):(\\d{1,2}))?$"
                                                     options:0 error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (!m || m.numberOfRanges < 6) return 0;
    NSInteger y = 0, mo = 0, dd = 0, hh = -1, mi = 0;
    if ([m rangeAtIndex:1].location != NSNotFound) y = [[t substringWithRange:[m rangeAtIndex:1]] integerValue];
    if ([m rangeAtIndex:2].location != NSNotFound) mo = [[t substringWithRange:[m rangeAtIndex:2]] integerValue];
    if ([m rangeAtIndex:3].location != NSNotFound) dd = [[t substringWithRange:[m rangeAtIndex:3]] integerValue];
    if ([m rangeAtIndex:4].location != NSNotFound) hh = (NSInteger)[[t substringWithRange:[m rangeAtIndex:4]] integerValue];
    if ([m rangeAtIndex:5].location != NSNotFound) mi = (NSInteger)[[t substringWithRange:[m rangeAtIndex:5]] integerValue];
    if (mo == 0 && hh < 0) return 0;              // 「5分钟前」这种就别硬解析了
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *nc = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                           NSCalendarUnitDay | NSCalendarUnitHour |
                                           NSCalendarUnitMinute) fromDate:now];
    if (mo == 0) { mo = nc.month; dd = nc.day; y = nc.year; }
    if (y < 100) y += 2000;
    if (y < 1970) y = nc.year;
    if (mo < 1 || mo > 12) return 0;
    if (dd < 1 || dd > 31) return 0;
    if (hh < 0) { hh = nc.hour; mi = nc.minute; }
    if (hh > 23) hh = 23;
    if (mi > 59) mi = 59;
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.year = y; c.month = mo; c.day = dd; c.hour = hh; c.minute = mi;
    NSDate *d = [cal dateFromComponents:c];
    return d ? [d timeIntervalSince1970] : 0;
}

// 时间点 → 陌陌那种说法：刚刚 / X分钟前 / X小时前 / 昨天 12:00 / 10-28 15:19
static NSString *SLMetaWhenText(NSTimeInterval ts) {
    if (ts <= 0) return nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    double diff = now - ts;
    if (diff < 0) diff = 0;                        // 填了未来 → 当「刚刚」
    if (diff < 60) return @"刚刚";
    if (diff < 3600) return [NSString stringWithFormat:@"%d分钟前", (int)(diff / 60)];
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDate *nowD = [NSDate dateWithTimeIntervalSince1970:now];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    if ([cal isDate:d inSameDayAsDate:nowD]) {
        // 同一天：一小时内上面的「X分钟前」更贴近陌陌；再往上按小时说
        return [NSString stringWithFormat:@"%d小时前", (int)(diff / 3600)];
    }
    f.dateFormat = @"HH:mm";
    NSString *hm = [f stringFromDate:d];
    NSDate *yday = [cal dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:nowD options:0];
    if (yday && [cal isDate:d inSameDayAsDate:yday]) {
        return [NSString stringWithFormat:@"昨天 %@", hm];
    }
    BOOL sameYear = ([cal component:NSCalendarUnitYear fromDate:d] ==
                     [cal component:NSCalendarUnitYear fromDate:nowD]);
    f.dateFormat = sameYear ? @"MM-dd HH:mm" : @"yyyy-MM-dd HH:mm";
    return [f stringFromDate:d];
}

// 面板「日期」那一栏最终该显示成什么
static NSString *SLMetaHeadFor(NSString *dtRaw, NSString *fallback) {
    if (![dtRaw isKindOfClass:[NSString class]] || !dtRaw.length) return fallback;
    NSTimeInterval ts = SLMetaParseWhen(dtRaw);
    NSString *rel = SLMetaWhenText(ts);
    return rel.length ? rel : dtRaw;               // 解析不出来就按用户写的原样贴
}

NSString *SLMetaTimeFor(NSString *msgid) {
    if (![msgid isKindOfClass:[NSString class]] || !msgid.length) return nil;
    NSDictionary *e = SLMetaStore()[msgid];
    if (![e isKindOfClass:[NSDictionary class]]) return nil;
    return SLTrimmed(e[@"t"]);
}

NSString *SLMetaDistFor(NSString *msgid) {
    if (![msgid isKindOfClass:[NSString class]] || !msgid.length) return nil;
    NSDictionary *e = SLMetaStore()[msgid];
    if (![e isKindOfClass:[NSDictionary class]]) return nil;
    return SLTrimmed(e[@"d"]);
}

NSString *SLMetaDateFor(NSString *msgid) {
    if (![msgid isKindOfClass:[NSString class]] || !msgid.length) return nil;
    NSDictionary *e = SLMetaStore()[msgid];
    if (![e isKindOfClass:[NSDictionary class]]) return nil;
    return SLTrimmed(e[@"dt"]);
}

BOOL SLMetaHasOverride(NSString *msgid) {
    return SLMetaTimeFor(msgid).length > 0 || SLMetaDistFor(msgid).length > 0
        || SLMetaDateFor(msgid).length > 0;
}

void SLMetaSave(NSString *msgid, NSString *time, NSString *dist, NSString *date) {
    if (![msgid isKindOfClass:[NSString class]] || !msgid.length) return;
    NSString *t = SLTrimmed(time);
    NSString *d = SLTrimmed(dist);
    NSString *dt = SLTrimmed(date);
    id raw = SLMetaStore()[msgid];
    NSMutableDictionary *e = [raw isKindOfClass:[NSMutableDictionary class]]
                             ? (NSMutableDictionary *)raw : [NSMutableDictionary dictionary];
    // e[@"o"] 是「这行原本写的是什么」—— 清空输入框时靠它复原，别删
    [e removeObjectForKey:@"t"];
    [e removeObjectForKey:@"d"];
    [e removeObjectForKey:@"dt"];
    if (t.length) e[@"t"] = t;
    if (d.length) e[@"d"] = d;
    if (dt.length) e[@"dt"] = dt;
    if (e.count == 0) [SLMetaStore() removeObjectForKey:msgid];
    else SLMetaStore()[msgid] = e;
    SLMetaSync();
    SLLog(@"META 保存 %@ 时间=[%@] 距离=[%@] 日期=[%@]", msgid, t ?: @"-", d ?: @"-", dt ?: @"-");
    // 这里不再整表刷：调用方（面板）拿着「长按的那一格」，精确刷那一条就够。
    // 整表刷 + cell→msgid 反查不准 = 一改全变，这是 v0.5.19 踩过的坑。
}

// 形态判据：短串、含 km、无换行 —— 就是那行「时间 距离」。
// 时间 / 距离那行的文字签名：不强制含 "km"（没开定位、或文字还没就位时都没有），
// 只要像「时间 + 距离」就认：含 km/米距离、含冒号的时间、含「前」的相对时间、
// 「刚刚」、或形如 10-28 的日期数字。
static BOOL SLMetaRowLooksLike(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 2) return NO;
    if (s.length > 60) return NO;
    if ([s rangeOfString:@"\n"].location != NSNotFound) return NO;
    if ([s rangeOfString:@"km" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([s rangeOfString:@"米"].location != NSNotFound) return YES;
    if ([s rangeOfString:@":"].location != NSNotFound) return YES;
    if ([s rangeOfString:@"前"].location != NSNotFound) return YES;
    if ([s isEqualToString:@"刚刚"]) return YES;
    if ([s rangeOfString:@"-"].location != NSNotFound &&
        [s rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) return YES;
    return NO;
}

// 在一格 cell 里找「时间 + 距离」那行。
// 判据（按优先级）：
//   1. 文字签名命中（含 km / 米 / : / 前 / 刚刚 / 「-」+数字）—— 最可靠；
//   2. 文字还没就位时，用「层级更深 + 更靠上 + 尺寸像」兜底：
//      时间行嵌在气泡 replay 视图里（tree 实测深度 5），而昵称是 contentView 的直接子视图
//      （深度 1）—— 单看 100x14 的尺寸会把昵称误判成时间行，所以必须比深度。
static id SLMetaRowViewIn(UIView *v, NSInteger depth) {
    if (!v || depth <= 0) return nil;
    __block id best = nil;
    __block NSInteger bestScore = -1;
    __block CGFloat bestY = CGFLOAT_MAX;

    // 递归 block 会捕获自己 → -Warc-retain-cycles 直接挂（本项目 -Werror）。
    // 标准的破环写法：另存一个 __weak 引用，块里只捕获那个弱引用。
    __block void (^scan)(UIView *, NSInteger) = nil;
    __block __weak void (^weakScan)(UIView *, NSInteger) = nil;
    scan = ^(UIView *root, NSInteger d) {
        if (!root || d <= 0) return;
        if (SLCRIsLabelLike(root)) {
            CGRect af = [root convertRect:root.bounds toView:v];
            CGFloat h = CGRectGetHeight(af);
            CGFloat w = CGRectGetWidth(af);
            if (h >= 10.0 && h <= 24.0 && w >= 28.0 && w <= 260.0) {
                BOOL sig = SLMetaRowLooksLike(SLCRShownTextOf(root));
                NSInteger nest = (depth - d);            // 越深越大
                // 第三个信号：时间行是整条水平居中的，气泡文字不是。
                // 短气泡（「好的」）尺寸也落在 10~24 / 28~260 里，靠这个把它排掉。
                CGFloat cellW = CGRectGetWidth(v.bounds);
                BOOL centered = (cellW > 0 &&
                                 fabs(CGRectGetMidX(af) - cellW / 2.0) < 40.0);
                NSInteger score = sig ? (1000 + nest) : (nest + (centered ? 50 : 0));
                CGFloat top = CGRectGetMinY(af);
                if (score > bestScore || (score == bestScore && top < bestY - 1.0)) {
                    bestScore = score;
                    bestY = top;
                    best = root;
                }
            }
        }
        for (UIView *s in root.subviews) weakScan(s, d - 1);
    };
    weakScan = scan;
    scan(v, depth);
    return best;
}

// v0.5.11：全局替换已废弃。这个符号还留着是因为 Tweak.x 的 `UILabel setText:`
// 钩子在用 —— 现在恒等于原样返回（本来也没值可替），真正的替换在
// SLChatMetaApplyTable() 里按 msgid 精确做。
NSString *SLApplyMetaEdits(NSString *s) {
    return s;
}

// 给 Tweak.x 的标签钩子用：文本像「时间 + 距离」就返回 YES
BOOL SLMetaIsTimeRowText(NSString *s) {
    return SLMetaRowLooksLike(s);
}

// 把某条消息的时间行按它的映射刷一遍。返回是否真的改了。
//
// v0.5.12：时间行不是独立 header，它就是这条消息 cell 内部的一个 UILabel（约 100x14），
// 所以「找时间行」只在【本条 cell 内部】找，绝不再往上去抓别的消息的格子。
//
// v0.5.20：msgid 改成**从外面传进来**。之前这里自己 `SLCRMessageOf(cell)` 反查，
// 而 cell 上那个「共享对象」会让一整屏 cell 都反查成同一条 —— 于是改一条、
// 全屏同一条时间都变（用户 v0.5.19 实测「一改所有时间都一样」的真根因）。
// 传进来的 mid 来自「长按的那条」或「indexPath → 数据源」，都是准的。
static BOOL SLMetaApplyOneMid(UITableViewCell *cell, NSString *mid) {
    if (!cell) return NO;
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return NO;
    NSString *tt = SLMetaTimeFor(mid);
    NSString *dd = SLMetaDistFor(mid);
    NSString *dt = SLMetaDateFor(mid);
    NSDictionary *entry = SLMetaStore()[mid];
    NSString *orig = [entry isKindOfClass:[NSDictionary class]] ? entry[@"o"] : nil;
    BOOL hasOverride = (tt.length || dd.length || dt.length);
    // 既没有覆盖、也没历史原文 → 这条就跟我们无关
    if (!hasOverride && !([orig isKindOfClass:[NSString class]] && orig.length)) return NO;
    // 只在 cell 内部找时间行（depth 6 足够覆盖嵌套）
    id rowView = SLMetaRowViewIn(cell, 6);
    if (!rowView) return NO;
    NSString *cur = SLCRShownTextOf(rowView) ?: @"";
    // 把「这行原样是什么」记下来，清空输入框时才能复原
    if (![orig isKindOfClass:[NSString class]] || !orig.length) {
        NSMutableDictionary *e = [entry isKindOfClass:[NSMutableDictionary class]]
                                 ? (NSMutableDictionary *)entry : [NSMutableDictionary dictionary];
        if (cur.length) {
            e[@"o"] = cur;
            SLMetaStore()[mid] = e;
            SLMetaSync();
            orig = cur;
        }
    }
    if (!hasOverride) {
        // 用户把输入框都清空了 → 复原成原文
        if ([orig isKindOfClass:[NSString class]] && orig.length && ![orig isEqualToString:cur]) {
            if (SLCRSetShownText(rowView, orig)) {
                SLLog(@"META 复原 %@ → [%@]", mid, orig);
                return YES;
            }
        }
        return NO;
    }
    NSString *head = cur, *dist = nil;
    NSTextCheckingResult *m = [SLMetaPairRE() firstMatchInString:cur options:0
                                                           range:NSMakeRange(0, cur.length)];
    if (m && m.numberOfRanges >= 3) {
        head = [cur substringWithRange:[m rangeAtIndex:1]];
        dist = [cur substringWithRange:[m rangeAtIndex:2]];
    } else if ([orig isKindOfClass:[NSString class]] && orig.length) {
        NSTextCheckingResult *m2 = [SLMetaPairRE() firstMatchInString:orig options:0
                                                                range:NSMakeRange(0, orig.length)];
        if (m2 && m2.numberOfRanges >= 3) {
            head = [orig substringWithRange:[m2 rangeAtIndex:1]];
            dist = [orig substringWithRange:[m2 rangeAtIndex:2]];
        }
    }
    // 日期优先：填了「2026-10-31 12:00」就按当前时刻算成「X分钟前」/「昨天 12:00」，
    // 而且每次渲染都重算 —— 这样它会随着时间自己往前走，不是死字符串。
    NSString *headOut = dt.length ? SLMetaHeadFor(dt, head) : (tt.length ? tt : head);
    NSString *nd = nil;
    if (dd.length) nd = [dd.lowercaseString hasSuffix:@"km"] ? dd : [dd stringByAppendingString:@"km"];
    else nd = dist;                 // 这一行原本就没有距离，别硬塞一个 "km" 上去
    NSString *out = nd.length ? [NSString stringWithFormat:@"%@ %@", headOut, nd] : headOut;
    if ([out isEqualToString:cur]) return NO;
    if (!SLCRSetShownText(rowView, out)) return NO;
    if (gSLMetaLog < 12) {
        gSLMetaLog += 1;
        SLLog(@"META 时间距离 [%@] → [%@] (msgid=%@)", cur, out, mid);
    }
    return YES;
}

// 单格刷新（willDisplay 走这条）：indexPath → 数据源拿 msgid 最准；
// 拿不到才退回 cell 反查。绝不整表扫，谁出现就刷谁。
void SLChatMetaApplyCellAtIndex(UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (!cell || !SLMetaStore().count) return;
    NSString *mid = SLCRMsgidAtIndexPath(tv, ip);
    if (!mid.length) mid = SLCRMsgidOf(SLCRMessageOf(cell));
    SLMetaApplyOneMid(cell, mid);
}

void SLChatMetaApplyTable(UITableView *tv) {
    if (!SLMetaStore().count) return;
    if (!tv) {
        UIViewController *chat = SLCRChatVC(SLCRTopVC());
        tv = chat ? SLCRChatTable(chat.view) : nil;
    }
    if (!tv) tv = SLCRChatTableAnywhere();
    if (!tv) return;
    NSInteger applied = 0;
    NSMutableSet *used = [NSMutableSet set];
    for (UITableViewCell *cell in tv.visibleCells) {
        NSString *mid = SLCRMsgidAtIndexPath(tv, [tv indexPathForCell:cell]);
        if (!mid.length) mid = SLCRMsgidOf(SLCRMessageOf(cell));
        if (!mid.length) continue;
        // 一条消息只可能占一个 cell。同一个 mid 出现第二遍，说明反查抓到了共享对象，
        // 这时候再刷就是把别人的行也改成同一条 —— 直接丢掉。
        if ([used containsObject:mid]) continue;
        [used addObject:mid];
        if (SLMetaApplyOneMid(cell, mid)) applied += 1;
    }
    if (applied && gSLMetaLog < 20) {
        gSLMetaLog += 1;
        SLLog(@"META 应用 已刷 %ld 行（按 msgid 精确）", (long)applied);
    }
}

// 老的整页扫描入口：留着给「改完立刻刷」调用，内部已经改成按 msgid 走。
void SLChatMetaSweep(UIView *root) {
    (void)root;
    SLChatMetaApplyTable(nil);
}

#pragma mark - 防撤回

// 撤回的最小实现：消息正文正常时按 msgid 记一份；等正文被清空 / 变成撤回提示时，
// 把记下来的原文顶回去。陌陌要是整条消息删掉（连对象都不留），这招救不回来，
// 但只要是「改字段」型的撤回，就能保住内容。
BOOL SLRecallGuardEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:kSLRecallGuardKey]) return YES;   // 默认开
    return [d boolForKey:kSLRecallGuardKey];
}

void SLRecallGuardSetEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLRecallGuardKey];
}

// 隐藏拦截标记：开启后撤回行渲染成普通「对方撤回了一条消息」，不露「已拦截」、不露原文，
// 截图不会暴露拦截行为；关闭时显示甲样式卡片 + 原文（数据仍持久保存）。
BOOL SLRecallHidden(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kSLRecallHideKey];
}
void SLRecallSetHidden(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLRecallHideKey];
}

static NSMutableDictionary *gSLRecallCache = nil;     // 内存：msgid → 最近一次正常正文
static NSMutableDictionary *gSLRecallBlocked = nil;    // 持久：msgid → 原文（被拦的撤回）
static NSInteger gSLRecallLog = 0;
static NSString *SLCRPreview(NSString *s, NSUInteger max);

// 前向声明（这些 static 定义在文件更后面）
static NSInteger SLCRPatchLabelsInView(UIView *v, NSString *orig, NSString *repl,
                                      NSMutableString *inv, NSInteger *seen);
static NSInteger SLCRPatchLayers(CALayer *layer, NSString *orig, NSString *repl,
                                 NSMutableString *inv, NSInteger depth);
static void SLCRClearHighlightDeep(UIView *root);

static void SLRecallLoadBlocked(void) {
    gSLRecallBlocked = [NSMutableDictionary dictionary];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSLRecallBlockedKey];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        for (id k in saved) {
            if ([k isKindOfClass:[NSString class]] && [saved[k] isKindOfClass:[NSString class]]) {
                gSLRecallBlocked[k] = saved[k];
            }
        }
    }
}

static void SLRecallPersistBlocked(void) {
    [[NSUserDefaults standardUserDefaults] setObject:gSLRecallBlocked ?: @{} forKey:kSLRecallBlockedKey];
}

BOOL SLRecallIsBlocked(NSString *mid) {
    if (!gSLRecallBlocked) SLRecallLoadBlocked();
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return NO;
    return ([gSLRecallBlocked objectForKey:mid] != nil);
}

NSString *SLRecallBlockedOriginal(NSString *mid) {
    if (!gSLRecallBlocked) SLRecallLoadBlocked();
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return nil;
    id v = gSLRecallBlocked[mid];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

void SLRecallUnblock(NSString *mid) {
    if (!gSLRecallBlocked) SLRecallLoadBlocked();
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return;
    [gSLRecallBlocked removeObjectForKey:mid];
    SLRecallPersistBlocked();
}

static BOOL SLRecallLooksGone(NSString *s) {
    if (!s.length) return YES;
    return [s containsString:@"撤回"] || [s containsString:@"已失效"];
}

NSString *SLRecallGuardBody(NSString *mid, NSString *body) {
    if (!SLRecallGuardEnabled()) return body;
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return body;
    if (![body isKindOfClass:[NSString class]]) return body;
    if (!gSLRecallCache) gSLRecallCache = [NSMutableDictionary dictionary];
    if (!gSLRecallBlocked) SLRecallLoadBlocked();
    BOOL blocked = (nil != [gSLRecallBlocked objectForKey:mid]);

    if (!SLRecallLooksGone(body)) {
        // 正文正常：记一份原文（内存，供撤回瞬间匹配）；已拦的直接持久保原文
        if (gSLRecallCache.count < 4000) gSLRecallCache[mid] = body;
        if (blocked) {
            NSString *stored = gSLRecallBlocked[mid];
            if (![stored isKindOfClass:[NSString class]] || ![stored isEqualToString:body]) {
                gSLRecallBlocked[mid] = body;
                SLRecallPersistBlocked();
            }
        }
        return body;
    }

    // body 看起来被撤了：手里正好有它的原文 → 永久拦下 + 顶回 + 排一次重绘
    NSString *old = gSLRecallBlocked[mid];
    if (![old isKindOfClass:[NSString class]] || !old.length) old = gSLRecallCache[mid];
    if ([old isKindOfClass:[NSString class]] && old.length) {
        if (!blocked) {
            gSLRecallBlocked[mid] = old;        // 自动把这条撤回永久拦下来
            SLRecallPersistBlocked();
            SLLog(@"RECALL 拦截一条撤回 %@ → 原文[%@]（持久）", mid, SLCRPreview(old, 16));
        }
        if (gSLRecallLog < 8) {
            gSLRecallLog += 1;
            SLLog(@"RECALL-GUARD 顶回原文 %@ → [%@]", mid, SLCRPreview(old, 14));
        }
        static NSString *pendingMid = nil;
        static NSUInteger pendingGen = 0;
        if (![pendingMid isEqualToString:mid]) {
            pendingMid = [mid copy];
            pendingGen += 1;
            NSUInteger gen = pendingGen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (gen != pendingGen) return;
                @try { SLRecallRepaintVisible(); } @catch (NSException *e) { }
            });
        }
        // 甲样式：不回写原文到 getter（那会把长文塞进 7×15 小标签 → 溢出/盖字），
        // 原文只通过卡片显示；0.3s 后刷新可见的被拦行盖卡片即可。
        return body;
    }
    return body;
}

#pragma mark - 撤回态整形

// 陌陌把撤回的消息压成一个灰底小胶囊（11 号字、缩得很窄、居中），
// 用户要的是「原文照样待在原气泡里、正常字号，再给一句提示」。
// 做法：灰底刷回白色、字号提回正文，然后在气泡上沿贴一行「对方撤回了一条消息」
// （上沿没空间就贴右侧，绝不改行高 —— 改高度要动数据源，得不偿失）。
static NSInteger gSLRecallStyleLog = 0;

void SLRecallStyleSweep(void) {
    if (!SLRecallGuardEnabled()) return;
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *tv = chat ? SLCRChatTable(chat.view) : nil;
    if (!tv) return;
    for (UITableViewCell *cell in tv.visibleCells) {
        BOOL recalled = NO;
        for (UIView *v in cell.contentView.subviews) {
            if (![v isKindOfClass:[UILabel class]]) continue;
            NSString *t = ((UILabel *)v).text ?: ((UILabel *)v).attributedText.string;
            if (t.length && [t containsString:@"撤回"]) { recalled = YES; break; }
        }
        if (!recalled) {
            NSMutableArray *q = [NSMutableArray arrayWithArray:cell.contentView.subviews];
            NSInteger budget = 300;
            while (q.count && budget-- > 0 && !recalled) {
                UIView *v = q.firstObject;
                [q removeObjectAtIndex:0];
                if ([v isKindOfClass:[UILabel class]]) {
                    NSString *t = ((UILabel *)v).text ?: ((UILabel *)v).attributedText.string;
                    if (t.length && [t containsString:@"撤回"]) { recalled = YES; break; }
                }
                for (UIView *s in v.subviews) [q addObject:s];
            }
        }
        if (!recalled) continue;
        if (gSLRecallStyleLog < 6) {
            gSLRecallStyleLog += 1;
            SLCRDumpStyleOnce(cell, @"recall");
        }
        UIView *bubble = nil;
        CGFloat bestArea = 0;
        NSMutableArray *q = [NSMutableArray arrayWithObject:cell];
        NSInteger budget = 300;
        while (q.count && budget-- > 0) {
            UIView *v = q.firstObject;
            [q removeObjectAtIndex:0];
            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)v;
                NSString *t = l.text ?: l.attributedText.string;
                // 撤回提示本身别放大，只有正文才提字号
                if (t.length && ![t containsString:@"撤回"] && l.font.pointSize > 0 &&
                    l.font.pointSize < 14.5) {
                    l.font = [UIFont systemFontOfSize:16];
                }
            } else {
                CGSize sz = v.frame.size;
                CGFloat area = sz.width * sz.height;
                UIColor *bg = v.backgroundColor;
                if (v.layer.cornerRadius >= 4 && area > bestArea && area > 900 &&
                    bg && CGColorGetAlpha(bg.CGColor) > 0.3) {
                    bubble = v;
                    bestArea = area;
                }
            }
            for (UIView *s in v.subviews) [q addObject:s];
        }
        if (!bubble) continue;
        // 灰底 → 白底。彩色气泡（自己发的绿/紫）不动，只认真的灰。
        UIColor *bg = bubble.backgroundColor;
        size_t nc = CGColorGetNumberOfComponents(bg.CGColor);
        const CGFloat *c = CGColorGetComponents(bg.CGColor);
        BOOL isGray = (nc == 2);        // white / gray 色彩空间天生就是灰
        if (nc >= 4 && c) {
            CGFloat mx = MAX(c[0], MAX(c[1], c[2])), mn = MIN(c[0], MIN(c[1], c[2]));
            isGray = (mx - mn < 0.06);
        }
        if (isGray) bubble.backgroundColor = [UIColor whiteColor];

        NSString *tip = @"对方撤回了一条消息";
        BOOL hasTip = NO;
        for (UIView *s in cell.contentView.subviews) {
            if ([s isKindOfClass:[UILabel class]] && [((UILabel *)s).text isEqualToString:tip]) {
                hasTip = YES;
                break;
            }
        }
        if (hasTip) continue;
        UILabel *lab = [[UILabel alloc] init];
        lab.text = tip;
        lab.font = [UIFont systemFontOfSize:10];
        lab.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
        CGSize ts = [tip sizeWithAttributes:@{NSFontAttributeName: lab.font}];
        CGRect bf = bubble.frame;
        if (bf.origin.y >= 15) {
            lab.frame = CGRectMake(bf.origin.x + 2, bf.origin.y - 15, ts.width + 2, 13);
        } else {
            lab.frame = CGRectMake(CGRectGetMaxX(bf) + 6, bf.origin.y + 4, ts.width + 2, 13);
        }
        [cell.contentView addSubview:lab];
    }
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

// 「原文 -> 新文」映射，给渲染层兜底用（气泡标签 / 排版模型只认字面，拿不到消息对象）
static NSMutableDictionary *gSlcOrigMap = nil;

static BOOL SLCRAliasLooksUnique(NSString *s);

static void SLCRRebuildIndex(void) {
    NSMutableDictionary *idx = [NSMutableDictionary dictionary];
    NSMutableDictionary *om = [NSMutableDictionary dictionary];
    NSDictionary *store = SLCRStore();
    [store enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        (void)stop;
        if (![v isKindOfClass:[NSDictionary class]]) return;
        idx[k] = v;
        NSString *orig = ((NSDictionary *)v)[@"o"];
        NSString *text = ((NSDictionary *)v)[@"t"];
        if ([orig isKindOfClass:[NSString class]] && orig.length &&
            [text isKindOfClass:[NSString class]] && text.length) {
            om[orig] = text;
        }
        // 老版本只存了 "264-DB201489B738" 这种主键，没有 ids；
        // 这里顺手把段拆出来，升级前改过的记录也能继续命中。
        for (NSString *part in [(NSString *)k componentsSeparatedByString:@"-"]) {
            if (SLCRAliasLooksUnique(part) && !idx[part]) idx[part] = v;
        }
        NSArray *ids = ((NSDictionary *)v)[@"ids"];
        if (![ids isKindOfClass:[NSArray class]]) return;
        NSString *session = ((NSDictionary *)v)[@"s"];
        for (id a in ids) {
            if (![a isKindOfClass:[NSString class]] || ![(NSString *)a length]) continue;
            // v0.5.05 存进去的别名里有会话号（对方 uid），共用会把整会话的改写串成一锅，
            // 这里按会话号剔掉，旧记录不用手动清。
            if ([session isKindOfClass:[NSString class]] && session.length &&
                [a isEqualToString:session]) continue;
            if (!SLCRAliasLooksUnique(a) && ![a isEqualToString:k]) continue;
            idx[a] = v;
        }
    }];
    gSlcOrigMap = om;
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

// 纯字符串替换：气泡标签最后拿到的就是一段字面，认不出是哪条消息，只能按原文对。
// 返回 nil 表示没命中（调用方保留原值）。
NSString *SLChatRewriteTextForPlainString(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return nil;
    if (!SLChatRewriteEnabled()) return nil;
    if (!gSLCRIndex) SLCRRebuildIndex();
    id v = gSlcOrigMap[s];
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    // 气泡上的字可能把首尾空白/换行吃掉，再按 trim 后的比一次
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length && ![t isEqualToString:s]) {
        v = gSlcOrigMap[t];
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    }
    return nil;
}

// 一条改写要挂的 id 集合。
//
// **只能挂「这条消息独有」的字段** —— v0.5.05 把 remoteid / autoid 也挂上去了，代价是
// 同一会话里所有消息共享 remoteid（对方 uid），于是：
//   别名=[CFD-3E044B82E531 1173080448 211 CFD 3E044B82E531]
//   另一条消息 05B 查表 → msgid 没中 → 落到 1173080448 → 命中了 CFD 那条改写
// 表现就是「改 A，B 的字也变了」「改第二条，第一条像被重置」。
// 现在只留 msgid / uuid（完整的 12 位以上串），外加菜单给的那串（本身就是完整 msgid）；
// 拆段只在长度 ≥8 时才收（"CFD"/"05B" 这种 3 位序号撞车概率太高）。
static BOOL SLCRAliasLooksUnique(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    if ([s containsString:@"-"]) return YES;          // 完整 msgid（seq-uuid）
    return s.length >= 8;                             // uuid 段 / 老版本纯 uuid
}

NSArray *SLChatRewriteAliasesForMessage(id message, NSString *extra) {
    NSMutableArray *out = [NSMutableArray array];
    // msgid 永远第一个：改写记录就是按它存的，查表必中
    id mid = nil;
    @try { mid = [message valueForKey:@"msgid"]; } @catch (NSException *e) { }
    NSString *midKey = SLCRKeyOf(mid);
    if (midKey.length) [out addObject:midKey];
    id uid = nil;
    @try { uid = [message valueForKey:@"uuid"]; } @catch (NSException *e) { }
    NSString *uuidKey = SLCRKeyOf(uid);
    if (SLCRAliasLooksUnique(uuidKey) && ![out containsObject:uuidKey]) [out addObject:uuidKey];
    if ([extra isKindOfClass:[NSString class]] && extra.length && ![out containsObject:extra]) {
        [out addObject:extra];
    }
    for (NSString *s in [out copy]) {
        if (![s containsString:@"-"]) continue;
        for (NSString *part in [s componentsSeparatedByString:@"-"]) {
            if (SLCRAliasLooksUnique(part) && ![out containsObject:part]) [out addObject:part];
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
/// 这条消息「当前显示」的字（第二次修改时是上次改完的结果，不是最初原文）
@property (nonatomic, copy) NSString *current;
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
    _textView.text = self.current.length ? self.current : (self.orig ?: @"");
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
    NSString *shown = self.current.length ? self.current : (self.orig ?: @"");
    NSString *current = [shown stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *origStr = self.orig ?: @"";
    NSString *origTrim = [origStr stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL changed = ![text isEqualToString:current];
    if (changed) {
        SLChatRewriteSave(self.msgid, self.aliases, text, origStr, self.session);
        // 光 reloadData 不会重算气泡（字是建会话数据时解析进 cellViewModel 的），
        // 必须把新文本直接写进活着的模型和标签。
        // 两趟：原文一趟、上一次改完的字一趟 —— 第二次修改时模型里存的是后者。
        SLChatRewritePatchLiveText(self.aliases, origStr, text);
        if (![current isEqualToString:origTrim]) {
            SLChatRewritePatchLiveText(self.aliases, current, text);
        }
    }
    if (self.doneBlock) self.doneBlock(changed);
    // 补丁要在 reload 之后再补一次：reloadData 会重新绑 cell，绑的时候如果又拿到旧排版，
    // 刚才换上去的字会被盖回去。所以顺序是 先补 → 关面板 → 刷新 → 再补 → 回读。
    NSArray *aliases = [self.aliases copy];
    NSString *session = [self.session copy];
    NSString *msgid = [self.msgid copy];
    (void)session; (void)msgid;
    NSString *origCopy = [origStr copy];
    NSString *curCopy = [current copy];
    NSString *textCopy = [text copy];
    [self dismissViewControllerAnimated:YES completion:^{
        if (!changed || !aliases) return;
        SLChatRewriteReloadChat();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLChatRewritePatchLiveText(aliases, origCopy, textCopy);
            if (![curCopy isEqualToString:origTrim]) {
                SLChatRewritePatchLiveText(aliases, curCopy, textCopy);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLChatRewriteDumpVisibleText();
        });
    }];
}

@end

#pragma mark - 时间 / 距离面板（一条一条改，不是全局设置）

// 每条消息发出的时刻、离你多远都不一样，所以这必须跟着消息走：
// 长按哪条就改哪条，存的是 msgid → 「时间 + 距离」。
// 界面上只有两个输入框，和「修改文字」是同一套毛玻璃样式，不额外造一套视觉。
@interface SLChatMetaEditorController : UIViewController <UITextFieldDelegate>
@property (nonatomic, copy) NSString *msgid;
@property (nonatomic, copy) NSString *initialTime;
@property (nonatomic, copy) NSString *initialDist;
@property (nonatomic, copy) NSString *initialDate;
/// 长按的那一格。保存后只刷它 —— 这是「只改我按的那条」的唯一可靠锚点。
@property (nonatomic, weak) UITableViewCell *sourceCell;
- (void)sl_cancel;
- (void)sl_save;
- (UITextField *)sl_addRow:(NSString *)title placeholder:(NSString *)ph value:(NSString *)v;
- (NSString *)sl_trim:(NSString *)s;
@end

@implementation SLChatMetaEditorController {
    UIView *_card;
    NSMutableArray<UILabel *> *_labels;
    NSMutableArray<UITextField *> *_fields;
    UIView *_divider;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    SLInstallGlassBackdrop(self.view);
    self.navigationItem.titleView = SLPillTitleView(@"时间 / 距离");
    self.navigationItem.leftBarButtonItem = SLPillBarItem(@"取消", self, @selector(sl_cancel));
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"保存", self, @selector(sl_save));

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = SLGlassCellColor();
    _card.layer.cornerRadius = 14.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderWidth = 0.8;
    _card.layer.borderColor = SLGlassHairlineColor().CGColor;
    _card.layer.masksToBounds = YES;
    [self.view addSubview:_card];

    _divider = [[UIView alloc] initWithFrame:CGRectZero];
    _divider.backgroundColor = SLGlassHairlineColor();
    [_card addSubview:_divider];

    _labels = [NSMutableArray array];
    _fields = [NSMutableArray array];
    [self sl_addRow:@"时间" placeholder:@"12:01 / 5分钟前" value:self.initialTime];
    [self sl_addRow:@"距离" placeholder:@"96.96（km 会自动补）" value:self.initialDist];
    [self sl_addRow:@"日期" placeholder:@"2026-10-31 12:00" value:self.initialDate];
}

- (UITextField *)sl_addRow:(NSString *)title placeholder:(NSString *)ph value:(NSString *)v {
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
    lab.text = title;
    lab.font = [UIFont systemFontOfSize:14];
    lab.textColor = [UIColor secondaryLabelColor];
    [_card addSubview:lab];
    [_labels addObject:lab];

    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectZero];
    tf.font = [UIFont systemFontOfSize:15];
    tf.textColor = [UIColor labelColor];
    tf.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:ph
                                        attributes:@{NSForegroundColorAttributeName:
                                                         [UIColor tertiaryLabelColor]}];
    tf.text = v.length ? v : @"";
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.spellCheckingType = UITextSpellCheckingTypeNo;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    [_card addSubview:tf];
    [_fields addObject:tf];
    return tf;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat top = safe.top + 14.0;
    CGFloat w = b.size.width - 32.0;
    CGFloat rowH = 48.0;
    NSInteger rows = (NSInteger)_fields.count;
    _card.frame = CGRectMake(16, top, w, rowH * (CGFloat)rows);
    _divider.frame = CGRectMake(14, rowH, w - 28.0, 0.5);
    for (NSInteger i = 0; i < rows; i++) {
        CGFloat y = rowH * (CGFloat)i;
        _labels[i].frame = CGRectMake(14, y, 44, rowH);
        _fields[i].frame = CGRectMake(62, y, w - 62 - 14, rowH);
    }
}

- (void)sl_cancel {
    [self dismissViewControllerAnimated:YES completion:^{
        SLChatClearVisibleHighlights();
    }];
}

- (NSString *)sl_trim:(NSString *)s {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)sl_save {
    NSString *t = [self sl_trim:_fields.count > 0 ? _fields[0].text : @""];
    NSString *d = [self sl_trim:_fields.count > 1 ? _fields[1].text : @""];
    NSString *dt = [self sl_trim:_fields.count > 2 ? _fields[2].text : @""];
    NSString *mid = [self.msgid copy];
    UITableViewCell *src = self.sourceCell;
    SLMetaSave(mid, t, d, dt);
    [self dismissViewControllerAnimated:YES completion:^{
        // 长按弹菜单那一刻陌陌会把气泡刷成按下态，菜单被模态盖住后它常常收不回来，
        // 于是「改完看着是蓝的」。关窗后连清两次，把它按回正常态。
        SLChatClearVisibleHighlights();
        // 只刷「长按的那一条」。全表刷会把整屏同一条时间都改掉（反查抓错对象的锅）。
        if (!src) return;
        SLMetaApplyOneMid(src, mid);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLChatClearVisibleHighlights();
            if (src) SLMetaApplyOneMid(src, mid);
        });
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

// 对外暴露：给 Tweak.x 在运行时探测「真正的 table delegate」用
UITableView *SLChatFindTable(void) {
    return SLCRChatTableAnywhere();
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
    editor.current = initial;      // 面板里显示「现在这条消息的字」，不是最初原文
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

// 弹编辑器前先把聊天页所有可见 cell 的「按下 / 选中」态清掉。
// 长按气泡时 Momo 会把那条刷成蓝色按下态，菜单被我们的模态盖住后它常常收不回来，
// 于是改完字一看气泡还是蓝的。清在弹窗前，蓝就从源头没了。
static void SLChatClearVisibleHighlights(void) {
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *t = chat ? SLCRChatTable(chat.view) : nil;
    if (!t) t = SLCRChatTableAnywhere();
    if (!t) return;
    for (UITableViewCell *c in t.visibleCells) {
        @try { [c setHighlighted:NO animated:NO]; } @catch (NSException *e) { }
        @try { [c setSelected:NO animated:NO]; } @catch (NSException *e) { }
        SLCRClearHighlightDeep(c);
    }
}

void SLChatRewriteBeginFromMenu(UIView *menuView) {
    if (!menuView) return;
    if (!SLChatRewriteEnabled()) {
        SLLog(@"REWRITE 未开启，忽略菜单入口");
        return;
    }
    SLChatClearVisibleHighlights();

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

#pragma mark - 改时间 / 距离（长按菜单第二项）

// 和「修改」共用同一套锚点反查：菜单只记得 targetView / targetViewFrame /
// targetViewCenter / msgid，气泡本身不在菜单的视图链上。
// 这里只多一步 —— 顺手把这行「时间 + 距离」拆开，当作面板的预填值。
void SLChatMetaBeginFromMenu(UIView *menuView) {
    if (!menuView) return;
    if (!SLChatRewriteEnabled()) {
        SLLog(@"META 未开启，忽略菜单入口");
        return;
    }
    SLChatClearVisibleHighlights();

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

    if (!hasCenter && tv) {
        if (!CGRectIsNull(tvFrame) && !CGRectIsEmpty(tvFrame)) {
            CGPoint c = CGPointMake(CGRectGetMidX(tvFrame), CGRectGetMidY(tvFrame));
            if (CGRectContainsRect(tv.bounds, tvFrame)) c = [tv convertPoint:c toView:nil];
            tvCenter = c;
        } else {
            tvCenter = [tv convertPoint:CGPointMake(CGRectGetMidX(tv.bounds),
                                                   CGRectGetMidY(tv.bounds)) toView:nil];
        }
        hasCenter = YES;
    }

    UITableViewCell *cell = nil;
    NSString *hint = nil;
    id message = nil;
    if (hasCenter) message = SLCRHitAtScreenPoint(tvCenter, &cell, &hint);
    if (!message) message = SLCRMessageNearPoint(tv, menuMid, tvCenter, hasCenter);
    NSString *mid = SLCRMsgidOf(message) ?: menuMid;
    if (!mid.length) {
        SLLog(@"META 反查失败：拿不到 msgid，不打开面板");
        [AWECAUtils showToast:@"没认出这条消息，再试一次" duration:2.0];
        return;
    }

    // 预填：优先用「这条消息已经改过的值」，否则用屏幕上那行的真实值。
    // 时间行就在本条 cell 内部（约 100x14 的 UILabel），直接在本 cell 找，不往上去抓。
    NSString *cur = @"";
    if (cell) {
        id rv = SLMetaRowViewIn(cell, 6);
        cur = SLCRShownTextOf(rv) ?: @"";
    }
    NSString *head = cur, *dist = nil;
    if (cur.length) {
        NSTextCheckingResult *m = [SLMetaPairRE() firstMatchInString:cur options:0
                                                               range:NSMakeRange(0, cur.length)];
        if (m && m.numberOfRanges >= 3) {
            head = [cur substringWithRange:[m rangeAtIndex:1]];
            dist = [cur substringWithRange:[m rangeAtIndex:2]];
        }
    }
    // 记下原文：面板里清空输入框 = 复原成这串
    if (cur.length) {
        NSMutableDictionary *e = SLMetaStore()[mid];
        if (![e isKindOfClass:[NSMutableDictionary class]]) e = [NSMutableDictionary dictionary];
        NSString *o = e[@"o"];
        if (![o isKindOfClass:[NSString class]] || !o.length) {
            e[@"o"] = cur;
            SLMetaStore()[mid] = e;
            SLMetaSync();
        }
    }

    NSString *t0 = SLMetaTimeFor(mid) ?: (head.length ? head : @"");
    NSString *d0 = SLMetaDistFor(mid) ?: (dist.length ? dist : @"");
    NSString *dt0 = SLMetaDateFor(mid) ?: @"";

    SLLog(@"META 打开面板 msgid=%@ 当前行=[%@] 预填 时间=[%@] 距离=[%@] 日期=[%@] cell=%@",
          mid, SLCRPreview(cur, 20), t0, d0, dt0,
          cell ? NSStringFromClass([cell class]) : @"nil");

    SLChatMetaEditorController *editor = [[SLChatMetaEditorController alloc] init];
    editor.msgid = mid;
    editor.initialTime = t0;
    editor.initialDist = d0;
    editor.initialDate = dt0;
    editor.sourceCell = cell;

    UIViewController *host = SLCRTopVC();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        if (nav.sheetPresentationController) {
            nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
            nav.sheetPresentationController.prefersGrabberVisible = YES;
        }
    }
    [host presentViewController:nav animated:YES completion:nil];
}

// 从「长按时间行本身」进入：直接拿这条 cell，零坐标反查误差。
// 长按时间行（UILabel）时，手势已经把 cell 传过来了，msgid 当场就能算准。
void SLChatMetaBeginFromCell(UITableViewCell *cell) {
    if (!cell) return;
    if (!SLChatRewriteEnabled()) {
        SLLog(@"META 未开启，忽略长按入口");
        return;
    }
    SLChatClearVisibleHighlights();
    // 标签钩子会给所有「像时间行」的标签挂长按，通知栏/其它列表里的「10:30」也会命中。
    // 认不出消息就安静退出，别弹「没认出这条消息」的提示去打扰。
    if (!SLCRMessageOf(cell)) return;
    // msgid 优先走「indexPath → 数据源」：cell 上那个共享对象会让反查整体错位。
    UITableView *ownerTV = nil;
    for (UIView *p = cell.superview; p; p = p.superview) {
        if ([p isKindOfClass:[UITableView class]]) { ownerTV = (UITableView *)p; break; }
    }
    NSString *mid = ownerTV ? SLCRMsgidAtIndexPath(ownerTV, [ownerTV indexPathForCell:cell]) : nil;
    if (!mid.length) mid = SLCRMsgidOf(SLCRMessageOf(cell));
    if (!mid.length) {
        SLLog(@"META 长按时间行：拿不到 msgid，放弃");
        [AWECAUtils showToast:@"没认出这条消息，再试一次" duration:2.0];
        return;
    }
    // 预填：屏幕时间行原文 + 已存的覆盖值
    NSString *cur = @"";
    id rv = SLMetaRowViewIn(cell, 6);
    cur = SLCRShownTextOf(rv) ?: @"";
    NSString *head = cur, *dist = nil;
    if (cur.length) {
        NSTextCheckingResult *m = [SLMetaPairRE() firstMatchInString:cur options:0
                                                               range:NSMakeRange(0, cur.length)];
        if (m && m.numberOfRanges >= 3) {
            head = [cur substringWithRange:[m rangeAtIndex:1]];
            dist = [cur substringWithRange:[m rangeAtIndex:2]];
        }
    }
    if (cur.length) {
        NSMutableDictionary *e = SLMetaStore()[mid];
        if (![e isKindOfClass:[NSMutableDictionary class]]) e = [NSMutableDictionary dictionary];
        if (![e[@"o"] isKindOfClass:[NSString class]] || !((NSString *)e[@"o"]).length) {
            e[@"o"] = cur;
            SLMetaStore()[mid] = e;
            SLMetaSync();
        }
    }
    NSString *t0 = SLMetaTimeFor(mid) ?: (head.length ? head : @"");
    NSString *d0 = SLMetaDistFor(mid) ?: (dist.length ? dist : @"");
    NSString *dt0 = SLMetaDateFor(mid) ?: @"";

    SLLog(@"META 长按时间行进入 msgid=%@ 当前行=[%@] 预填 时间=[%@] 距离=[%@] 日期=[%@]",
          mid, SLCRPreview(cur, 20), t0, d0, dt0);

    SLChatMetaEditorController *editor = [[SLChatMetaEditorController alloc] init];
    editor.msgid = mid;
    editor.initialTime = t0;
    editor.initialDist = d0;
    editor.initialDate = dt0;
    editor.sourceCell = cell;

    UIViewController *host = SLCRTopVC();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        if (nav.sheetPresentationController) {
            nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
            nav.sheetPresentationController.prefersGrabberVisible = YES;
        }
    }
    [host presentViewController:nav animated:YES completion:nil];
}

// 时间行长按 → 打开「改时间 / 距离 / 日期」。
// 手势挂在时间行 UILabel 上（只认形态像的那一个），零坐标反查误差；
// 用户要的就是「长按时间那行本身」，而不是长按气泡再从菜单选。
// 注意：label 是 cell 复用时重用的，手势只挂一次（按 label 实例记），
// 它永远作用在当前所在的 cell 上 —— 这正是我们想要的「长按哪条改哪条」。
//
// 为什么要当 delegate：Momo 自己的 cell 上挂着上下文菜单长按（`_setupMenuGesture`），
// 默认两个长按互斥、谁先 Began 谁赢，实测里经常是它赢 → 我们的编辑器根本不弹。
// 返回 YES 允许「同时识别」，我们这条就一定能收到 Began；随后把 Momo 的菜单收掉。
@interface SLMetaTimeLPRelay : NSObject <UIGestureRecognizerDelegate>
- (void)sl_handle:(UIGestureRecognizer *)g;
@end
@implementation SLMetaTimeLPRelay
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)sl_handle:(UIGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // 热区和标签可能同时挂着，一次长按只准开一次面板
    static NSTimeInterval lastOpen = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (lastOpen > 0 && now - lastOpen < 0.8) return;
    lastOpen = now;
    UIView *v = g.view;
    UITableViewCell *cell = nil;
    for (UIView *p = v; p; p = p.superview) {
        if ([p isKindOfClass:[UITableViewCell class]]) { cell = (UITableViewCell *)p; break; }
    }
    if (!cell) return;
    // 顺手把 Momo 弹出的上下文菜单收掉，免得挡在编辑器后面
    [self sl_dismissMomoMenu];
    SLChatMetaBeginFromCell(cell);
}
- (void)sl_dismissMomoMenu {
    Class menuC = NSClassFromString(@"MDChatUIMenuView");
    if (!menuC) return;
    // 别用 UIApplication.windows（iOS15 起弃用，本项目 -Werror 会直接编译失败），
    // 从当前顶层 VC 的 window 往上找就够。
    UIWindow *win = SLCRTopVC().view.window ?: SLCRChatTableAnywhere().window;
    if (!win) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:win];
    NSInteger budget = 300;
    while (q.count && budget-- > 0) {
        UIView *x = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([x isKindOfClass:menuC]) {
            [x removeFromSuperview];
            return;
        }
        for (UIView *s in x.subviews) [q addObject:s];
    }
}
@end
static SLMetaTimeLPRelay *gSLMetaLPRelay = nil;
static const void *kSLMetaTimeLPKey = &kSLMetaTimeLPKey;

// 给某一颗标签挂长按（按 label 实例去重）。不需要此刻就在 cell 里 ——
// 手势触发时再从 g.view 沿父链找 cell，那会儿它一定已经挂上去了。
static void SLMetaAttachLPToLabel(UIView *lab, NSString *why) {
    if (![lab isKindOfClass:[UIView class]]) return;
    if (objc_getAssociatedObject(lab, kSLMetaTimeLPKey)) return;   // 这个 label 实例已经挂过
    objc_setAssociatedObject(lab, kSLMetaTimeLPKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gSLMetaLPRelay) gSLMetaLPRelay = [[SLMetaTimeLPRelay alloc] init];
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gSLMetaLPRelay
                                                     action:@selector(sl_handle:)];
    lp.minimumPressDuration = 0.45;
    lp.cancelsTouchesInView = NO;     // 别吞掉 Momo 自己的触摸
    lp.delegate = gSLMetaLPRelay;     // 允许与 Momo 的菜单长按同时识别（否则会被抢）
    [lab addGestureRecognizer:lp];
    lab.userInteractionEnabled = YES;
    SLLog(@"META 给时间行挂长按手势 label=%@ 来源=%@", NSStringFromClass([lab class]), why);
}

// 从「标签文本落地」这条路上挂。这是唯一确定装得上的时机 ——
// willDisplayCell 那对钩子在 Momo 上根本没装到（真正的 delegate 不是 VC），
// 靠它挂手势等于永远挂不上。
void SLChatMetaAttachTimeLongPressForLabel(UIView *label) {
    if (!label || !SLChatRewriteEnabled()) return;
    SLMetaAttachLPToLabel(label, @"labelText");
}

// 常驻热区：透明，直接盖在「时间 + 距离」那一行上，吃触摸。
//
// 为什么不能只挂在标签上：时间行的字其实落在一颗 UITextFieldLabel 里（UITextField
// 内部的标签），文本框自带的文本交互（日志里那条 UITextSelectionInteraction
// #_handleMultiTapGesture）会在部分时机把我们的长按抢走 —— 实测就是「有时候能按、
// 有时候按了没反应」。热区挂在 contentView 最上层，先接到触摸，稳。
static const NSInteger kSLMetaHotTag = 0x5EC3;

static void SLMetaInstallHotZone(UITableViewCell *cell, UIView *row) {
    if (!cell || !row) return;
    UIView *con = cell.contentView;
    if (!con) return;
    CGRect r = [row convertRect:row.bounds toView:con];
    if (CGRectGetWidth(r) < 8.0 || CGRectGetHeight(r) < 6.0) return;
    r = CGRectInset(r, -14.0, -10.0);
    // 别超出 cell，免得盖到相邻行上去（会抢别的消息的长按）
    CGRect b = con.bounds;
    r = CGRectIntersection(r, b);
    if (CGRectGetWidth(r) < 8.0) return;

    UIView *hot = [con viewWithTag:kSLMetaHotTag];
    if (!hot) {
        hot = [[UIView alloc] initWithFrame:r];
        hot.tag = kSLMetaHotTag;
        hot.backgroundColor = [UIColor clearColor];
        hot.opaque = NO;
        if (!gSLMetaLPRelay) gSLMetaLPRelay = [[SLMetaTimeLPRelay alloc] init];
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:gSLMetaLPRelay
                                                         action:@selector(sl_handle:)];
        lp.minimumPressDuration = 0.45;
        lp.cancelsTouchesInView = NO;
        lp.delaysTouchesBegan = NO;
        lp.delaysTouchesEnded = NO;
        lp.delegate = gSLMetaLPRelay;
        [hot addGestureRecognizer:lp];
        hot.userInteractionEnabled = YES;
    } else {
        hot.frame = r;
    }
    // 必须压在最上层：cell 复用后新加的子视图会跑到它上面，每次显示都提一下
    [con bringSubviewToFront:hot];
}

void SLChatMetaAttachTimeLongPress(UITableViewCell *cell) {
    if (!cell || !SLChatRewriteEnabled()) return;
    id lab = SLMetaRowViewIn(cell, 6);
    if (![lab isKindOfClass:[UIView class]]) {
        // 这格没有时间行（图片 / 语音 / 系统消息）→ 把复用时带过来的热区收起来，
        // 不然它会停在老位置盖住别的行
        UIView *staleHot = [cell.contentView viewWithTag:kSLMetaHotTag];
        if (staleHot) staleHot.hidden = YES;
        return;
    }
    SLMetaAttachLPToLabel((UIView *)lab, @"willDisplay");
    SLMetaInstallHotZone(cell, (UIView *)lab);
    UIView *hot = [cell.contentView viewWithTag:kSLMetaHotTag];
    if (hot) hot.hidden = NO;
}

#pragma mark - 渲染层补丁
//
// 为什么光靠 body getter 不够：气泡的字是在会话数据建好那一刻、由 mixItem 的
// cellViewModel 解析成排版的（MDMixLabel 自绘表情混排），模型里存的是**解析好的字符串**。
// reloadData 只是重新绑 cell，模型里的字没动，屏幕上就原样 ——
// 这就是 v0.5.05「保存成功、界面照旧」的真正原因。
// 所以保存后直接去改活着的对象图：模型里的字符串 + 已经排好版的气泡标签。

// 替换物得留个强引用：object_setIvar 是裸存，不 retain
static NSMutableArray *gSLCRPatchKeep = nil;

static NSString *SLCRPropertyNameForIvar(const char *name) {
    if (!name) return nil;
    NSString *s = [NSString stringWithUTF8String:name];
    if ([s hasPrefix:@"$__lazy_storage_$_"]) s = [s substringFromIndex:19];
    while ([s hasPrefix:@"_"]) s = [s substringFromIndex:1];
    return s.length ? s : nil;
}

static NSAttributedString *SLCRReplaceAttributed(NSAttributedString *src, NSString *repl) {
    if (![src isKindOfClass:[NSAttributedString class]] || !repl.length) return nil;
    NSDictionary *attrs = src.length ? [src attributesAtIndex:0 effectiveRange:NULL] : nil;
    NSAttributedString *na = [[NSMutableAttributedString alloc] initWithString:repl attributes:attrs];
    if (na && !gSLCRPatchKeep) gSLCRPatchKeep = [NSMutableArray array];
    if (na) [gSLCRPatchKeep addObject:na];
    return na;
}

static BOOL SLCRStringIs(NSString *a, NSString *b) {
    if (![a isKindOfClass:[NSString class]] || ![b isKindOfClass:[NSString class]]) return NO;
    if ([a isEqualToString:b]) return YES;
    NSString *ta = [a stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *tb = [b stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ta.length && [ta isEqualToString:tb];
}

static NSInteger gSLCRPatchBudget = 0;

static NSInteger SLCRPatchModelStrings(id obj, NSInteger depth, NSString *orig, NSString *repl,
                                       NSMutableString *trace) {
    if (!obj || depth <= 0 || gSLCRPatchBudget <= 0) return 0;
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] ||
        [obj isKindOfClass:[NSData class]] || [obj isKindOfClass:[NSArray class]] ||
        [obj isKindOfClass:[NSDictionary class]] || [obj isKindOfClass:[UIImage class]]) return 0;
    gSLCRPatchBudget -= 1;
    NSInteger hits = 0;
    Class cls = object_getClass(obj);
    NSInteger guard = 0;
    while (cls && cls != [NSObject class] && guard < 12 && gSLCRPatchBudget > 0) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n && gSLCRPatchBudget > 0; i++) {
            const char *tn = ivar_getName(ivars[i]);
            const char *te = ivar_getTypeEncoding(ivars[i]);
            if (!te || te[0] != '@' || !tn || strstr(tn, "delegate")) continue;
            id v = nil;
            @try { v = object_getIvar(obj, ivars[i]); } @catch (NSException *e) { }
            if (!v || v == obj) continue;
            BOOL isView = [v isKindOfClass:[UIView class]] || [v isKindOfClass:[CALayer class]];
            // 视图/图层不许整个跳过 —— v0.5.08 的树证明气泡是 UIView(54,0 93x58) 这种
            // 光杆叶子：字不在任何 label 上，就在它自己的私有属性里。
            // 只浅扫「自己这一层」（depth=1 时不会再往下走，否则会顺着 superview 无限递归）。
            if (isView) {
                if (depth > 1) hits += SLCRPatchModelStrings(v, 1, orig, repl, trace);
                continue;
            }
            NSString *prop = SLCRPropertyNameForIvar(tn);
            if ([v isKindOfClass:[NSString class]]) {
                if (!SLCRStringIs((NSString *)v, orig)) continue;
                BOOL ok = NO;
                if (prop.length) { @try { [obj setValue:repl forKey:prop]; ok = YES; } @catch (NSException *e) { } }
                if (!ok) { @try { object_setIvar(obj, ivars[i], repl); ok = YES; } @catch (NSException *e) { } }
                if (ok) { hits += 1; if (trace) [trace appendFormat:@"%s ", tn]; }
            } else if ([v isKindOfClass:[NSAttributedString class]]) {
                if (!SLCRStringIs([(NSAttributedString *)v string], orig)) continue;
                NSAttributedString *na = SLCRReplaceAttributed((NSAttributedString *)v, repl);
                if (!na) continue;
                BOOL ok = NO;
                if (prop.length) { @try { [obj setValue:na forKey:prop]; ok = YES; } @catch (NSException *e) { } }
                if (!ok) { @try { object_setIvar(obj, ivars[i], na); ok = YES; } @catch (NSException *e) { } }
                if (ok) { hits += 1; if (trace) [trace appendFormat:@"%s ", tn]; }
            } else {
                hits += SLCRPatchModelStrings(v, depth - 1, orig, repl, trace);
            }
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
        guard += 1;
    }
    return hits;
}

// 已经排好版的气泡标签：MDMixLabel 里 text / attributedString 就是屏幕上那行字。
//
// **别再对 MDMixLabel 用 valueForKey**（v0.5.06 的坑）：它是 Swift 类，属性不是
// @objc dynamic，valueForKey:@"text" 直接抛 NSUnknownKeyException。外面套着 @catch，
// 于是日志打「标签 0 处」——标签明明在屏幕上，只是读不出来，补丁就只改模型不改显示，
// 要退出会话重进（重进走的是 setAttributedString: 钩子）才刷新。
// 这里声明一个同签名的探针接口，直接发消息，绕开 KVC。
@interface SLCRMixLabelProbe : NSObject
- (id)text;
- (id)attributedString;
- (void)setText:(id)text;
- (void)setAttributedString:(id)as;
@end

static BOOL SLCRIsLabelLike(id v) {
    if (![v isKindOfClass:[UIView class]]) return NO;
    if ([v isKindOfClass:[UILabel class]]) return YES;
    if ([NSStringFromClass([v class]) containsString:@"MixLabel"]) return YES;
    return [v respondsToSelector:@selector(setAttributedString:)] ||
           [v respondsToSelector:@selector(setText:)];
}

// 屏幕上这行字。MDMixLabel 只认 attributedString（自绘表情混排），普通 UILabel 反过来先看 attributedText。
static NSString *SLCRShownTextOf(id v) {
    if (!v) return nil;
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        t = l.attributedText.length ? l.attributedText.string : l.text;
    } else {
        if ([v respondsToSelector:@selector(attributedString)]) {
            @try {
                id as = [(SLCRMixLabelProbe *)v attributedString];
                if ([as isKindOfClass:[NSAttributedString class]]) t = [(NSAttributedString *)as string];
            } @catch (NSException *e) { }
        }
        if (!t.length && [v respondsToSelector:@selector(text)]) {
            @try {
                id x = [(SLCRMixLabelProbe *)v text];
                if ([x isKindOfClass:[NSString class]]) t = (NSString *)x;
            } @catch (NSException *e) { }
        }
    }
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length ? t : nil;
}

static BOOL SLCRSetShownText(id v, NSString *target) {
    if (!v || ![target isKindOfClass:[NSString class]] || !target.length) return NO;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.attributedText.length) {
            NSAttributedString *na = SLCRReplaceAttributed(l.attributedText, target);
            if (na) { l.attributedText = na; return YES; }
        }
        l.text = target;
        return YES;
    }
    if ([v respondsToSelector:@selector(attributedString)] &&
        [v respondsToSelector:@selector(setAttributedString:)]) {
        NSAttributedString *as = nil;
        @try {
            id x = [(SLCRMixLabelProbe *)v attributedString];
            if ([x isKindOfClass:[NSAttributedString class]]) as = (NSAttributedString *)x;
        } @catch (NSException *e) { }
        if (as.length) {
            NSAttributedString *na = SLCRReplaceAttributed(as, target);
            if (na) {
                @try { [(SLCRMixLabelProbe *)v setAttributedString:na]; return YES; }
                @catch (NSException *e) { }
            }
        }
    }
    if ([v respondsToSelector:@selector(setText:)]) {
        @try { [(SLCRMixLabelProbe *)v setText:target]; return YES; }
        @catch (NSException *e) { }
    }
    return NO;
}

// 一个 cell 子树里的所有标签：换字，顺手把清单记下来（下一版排错靠它）
static NSInteger SLCRPatchLabelsInView(UIView *v, NSString *orig, NSString *repl,
                                       NSMutableString *inventory, NSInteger *seen) {
    if (!v) return 0;
    NSInteger hits = 0;
    if (SLCRIsLabelLike(v)) {
        NSString *shown = SLCRShownTextOf(v);
        if (shown.length) {
            if (seen) *seen += 1;
            if (inventory && inventory.length < 240) {
                [inventory appendFormat:@"%@«%@» ", NSStringFromClass([v class]), SLCRPreview(shown, 10)];
            }
            // 这串字本身是不是某条改写的原文（跟 setText: 钩子同一个判据）；
            // 不是的话再按本次要改的原文对一次，对上就直接换成本次的新文。
            NSString *mapped = SLChatRewriteTextForPlainString(shown);
            NSString *target = mapped.length ? mapped : (SLCRStringIs(shown, orig) ? repl : nil);
            if (target.length && ![target isEqualToString:shown]) {
                if (SLCRSetShownText(v, target)) {
                    hits += 1;
                    [v setNeedsDisplay];
                    [v setNeedsLayout];
                }
            }
        }
    }
    for (UIView *sub in v.subviews) {
        hits += SLCRPatchLabelsInView(sub, orig, repl, inventory, seen);
    }
    return hits;
}

// 图层这一趟：气泡的字既不在 UILabel 也不在 MDMixLabel 上时，就在 layer 里。
// CATextLayer 的 string / attributedString 就是屏幕上画的那行字；
// 还有一类是自家 CALayer 子类，靠 drawInContext 用 CoreText 画，数据源是它自己的属性 ——
// 那种只能靠 SLCRPatchModelStrings 扫 self 拿下来，这里只负责「有 string 的」。
static NSInteger SLCRPatchLayers(CALayer *layer, NSString *orig, NSString *repl,
                                 NSMutableString *inventory, NSInteger depth) {
    if (!layer || depth <= 0) return 0;
    NSInteger hits = 0;
    NSString *cn = NSStringFromClass([layer class]);
    BOOL textLayer = [layer isKindOfClass:[CATextLayer class]];
    id str = nil;
    @try {
        if (textLayer) str = ((CATextLayer *)layer).string;
        else if ([layer respondsToSelector:NSSelectorFromString(@"string")]) {
            SEL sel = NSSelectorFromString(@"string");
            NSMethodSignature *sig = [layer methodSignatureForSelector:sel];
            if (sig && sig.methodReturnType[0] == '@' && sig.numberOfArguments == 2) {
                id (*fn)(id, SEL) = (id (*)(id, SEL))[layer methodForSelector:sel];
                if (fn) str = fn(layer, sel);
            }
        }
    } @catch (NSException *e) { }

    NSString *shown = nil;
    if ([str isKindOfClass:[NSAttributedString class]]) shown = [(NSAttributedString *)str string];
    else if ([str isKindOfClass:[NSString class]]) shown = str;
    shown = [shown stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (shown.length) {
        if (inventory && inventory.length < 300) {
            [inventory appendFormat:@"%@«%@» ", cn, SLCRPreview(shown, 10)];
        }
        NSString *mapped = SLChatRewriteTextForPlainString(shown);
        NSString *target = mapped.length ? mapped : (SLCRStringIs(shown, orig) ? repl : nil);
        if (target.length && ![target isEqualToString:shown]) {
            @try {
                if ([str isKindOfClass:[NSAttributedString class]]) {
                    NSAttributedString *na = SLCRReplaceAttributed((NSAttributedString *)str, target);
                    if (na) {
                        if (textLayer) ((CATextLayer *)layer).string = na;
                        else [layer setValue:na forKey:@"string"];
                        hits += 1;
                    }
                } else {
                    if (textLayer) ((CATextLayer *)layer).string = target;
                    else [layer setValue:target forKey:@"string"];
                    hits += 1;
                }
                [layer setNeedsDisplay];
            } @catch (NSException *e) { }
        }
    }
    for (CALayer *sub in layer.sublayers) {
        hits += SLCRPatchLayers(sub, orig, repl, inventory, depth - 1);
    }
    return hits;
}

// 排错用：把 layer 树打一行（类名 + 有字的「字」），每个 cell 类只打一次。
// v0.5.08 只打了视图树，看不出 CATextLayer —— 这次两棵树一起打。
static void SLCRDumpLayerTreeOnce(UIView *root, NSString *tag) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"L|%@|%@", tag ?: @"-", NSStringFromClass([root class])];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root.layer];
    NSInteger depth = 0;
    NSInteger budget = 60;
    while (queue.count && budget-- > 0 && depth < 5) {
        NSInteger n = (NSInteger)queue.count;
        for (NSInteger i = 0; i < n && budget > 0; i++) {
            CALayer *l = queue.firstObject;
            [queue removeObjectAtIndex:0];
            NSString *desc = NSStringFromClass([l class]);
            if ([l isKindOfClass:[CATextLayer class]]) {
                id s = ((CATextLayer *)l).string;
                NSString *t = [s isKindOfClass:[NSAttributedString class]]
                              ? [(NSAttributedString *)s string] : (NSString *)s;
                desc = [desc stringByAppendingFormat:@"(%.0fx%.0f)«%@»",
                        l.frame.size.width, l.frame.size.height, SLCRPreview(t, 14)];
            } else if (l.contents) {
                desc = [desc stringByAppendingFormat:@"(%.0fx%.0f)contents",
                        l.frame.size.width, l.frame.size.height];
            }
            [out addObject:desc];
            for (CALayer *sub in l.sublayers) [queue addObject:sub];
        }
        depth += 1;
    }
    SLLog(@"REWRITE-LAYER %@ 层 %lu：%@", tag ?: @"-", (unsigned long)out.count,
          [out componentsJoinedByString:@" | "]);
}

// 排错用：把 cell 里所有 label 的字号/字色/底色列一行 —— 撤回态要「复原成正常气泡」
// 全靠这张表（哪个 view 是那层灰底、哪个 label 被缩成了 11 号）。
static void SLCRDumpStyleOnce(UIView *root, NSString *tag) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"S|%@|%@", tag ?: @"-", NSStringFromClass([root class])];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 60;
    while (queue.count && budget-- > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass([v class]);
        UIColor *bg = v.backgroundColor;
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)v;
            [out addObject:[NSString stringWithFormat:@"%@(%.0f) %.1fpt«%@»",
                            cn, l.frame.size.width, l.font.pointSize,
                            SLCRPreview(l.text ?: l.attributedText.string, 8)]];
        } else if (bg && CGColorGetAlpha(bg.CGColor) > 0.01) {
            const CGFloat *c = CGColorGetComponents(bg.CGColor);
            [out addObject:[NSString stringWithFormat:@"%@(%.0fx%.0f) r=%.0f rgb=%.2f/%.2f/%.2f",
                            cn, v.frame.size.width, v.frame.size.height,
                            v.layer.cornerRadius, c ? c[0] : 0, c ? c[1] : 0, c ? c[2] : 0]];
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    SLLog(@"REWRITE-STYLE %@ 样式 %lu：%@", tag ?: @"-", (unsigned long)out.count,
          [out componentsJoinedByString:@" | "]);
}

// 重绑前先把「排好版的中间产物」扔了，否则 bindWithItem: 会直接复用旧排版。
// 名字不统一，常见的几个都试一遍；KVC 不认就跳过，不影响主流程。
static void SLCRDropLayoutCache(id dataItem, UITableViewCell *cell) {
    NSArray *keys = @[@"cellViewModel", @"viewModel", @"cellModel", @"layoutModel",
                      @"cellLayout", @"layout", @"contentModel", @"itemLayout"];
    for (NSString *k in keys) {
        if (dataItem) {
            @try {
                if ([dataItem valueForKey:k]) { [dataItem setValue:nil forKey:k]; }
            } @catch (NSException *e) { }
        }
        if (cell) {
            @try {
                if ([cell valueForKey:k]) { [cell setValue:nil forKey:k]; }
            } @catch (NSException *e) { }
        }
    }
}

// 没标签时让 cell 自己按新模型重绑一次（下面 SLCRTryRebindCell 干的活）。

// 重绑会让 cell 走一遍「高亮 / 选中」的配色流程，于是对方那条白气泡会被刷成蓝色
// （v0.5.10 用户实测：改完字气泡变蓝、还停在右侧样式）。
// 修法不猜实现：重绑前把整棵子树的底色按「遍历顺序 + 类名」记一份，重绑后逐一还原。
// 顺序稳定（同一棵树同样的子视图层级），所以按下标对得上。
static NSArray *SLCRSnapshotBackgrounds(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    if (!root) return out;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 500;
    while (q.count && budget-- > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        UIColor *bg = v.backgroundColor;
        if (bg && CGColorGetAlpha(bg.CGColor) > 0.01) {
            [out addObject:@[NSStringFromClass([v class]), bg]];
        } else {
            [out addObject:@[NSStringFromClass([v class])]];
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return out;
}

// 把整棵子树的高亮态清干净：cell 的 highlighted / selected，以及内部控件、图片的
// highlighted。长按弹菜单那一刻 Momo 会把气泡刷成「按下」配色（蓝），若此时直接
// 快照，快照到的就是蓝色 —— 之后「还原」反而把蓝还回去，这就是「改完字一直蓝」的根。
static void SLCRClearHighlightDeep(UIView *root) {
    if (!root) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 500;
    while (q.count && budget-- > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UIControl class]]) {
            @try { ((UIControl *)v).highlighted = NO; } @catch (NSException *e) { }
            @try { ((UIControl *)v).selected = NO; } @catch (NSException *e) { }
        }
        if ([v isKindOfClass:[UIImageView class]]) {
            @try { ((UIImageView *)v).highlighted = NO; } @catch (NSException *e) { }
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
}

// 是不是「被选中/按下」那种蓝：蓝通道明显压过红绿
static BOOL SLCRColorIsBlueish(UIColor *c) {
    if (![c isKindOfClass:[UIColor class]]) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return (b > 0.55 && b - r > 0.12 && b - g > 0.06);
}

// 气泡底色不是 UIView 的 backgroundColor，而是 MDAsyncDisplayLayer 异步画上去的位图。
// 光改 UIView 底色它不会重画，屏幕上的蓝还在 —— 必须逐层 setNeedsDisplay 逼它重绘。
static void SLCRForceRedraw(UIView *root) {
    if (!root) return;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 400;
    while (q.count && budget-- > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        NSString *cls = NSStringFromClass([v.layer class]);
        if ([cls rangeOfString:@"Async" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"MD" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [v.layer setNeedsDisplay];
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    [root.layer setNeedsDisplay];
}

static NSInteger SLCRRestoreBackgrounds(UIView *root, NSArray *snap) {
    if (!root || !snap.count) return 0;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 500, i = 0, fixed = 0;
    while (q.count && budget-- > 0 && i < (NSInteger)snap.count) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        id item = snap[i];
        i += 1;
        if ([item isKindOfClass:[NSArray class]]) {
            NSArray *pair = (NSArray *)item;
            if (pair.count >= 2 && [pair[0] isKindOfClass:[NSString class]]) {
                UIColor *want = pair[1];
                // 快照本身可能就是蓝的（长按按下态）→ 别把蓝还回去，一律刷白
                if (SLCRColorIsBlueish(want)) want = [UIColor whiteColor];
                if ([NSStringFromClass([v class]) isEqualToString:pair[0]] &&
                    v.backgroundColor != want) {
                    v.backgroundColor = want;
                    fixed += 1;
                }
            }
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return fixed;
}

// 标签换不动时的正解：让 cell 按「改过的模型」重绑一次。
//
// v0.5.07 日志打出来 cell 的方法表：`bindWithItem:` / `rebindCustomViewModel` /
// `itemMessage` —— 这就是退出会话重进时数据源干的事。我们之前只调属性 setter
// （`setDataItem:` 其实调成功了，但没触发重排），所以模型改了、屏幕不动。
// 现在按优先级调真正的绑数据入口；签名必须是「一个对象参数、返回 void」。
static NSString *SLCRTryRebindCell(UITableViewCell *cell, id dataItem) {
    if (!cell) return @"-";
    // 关键：重绑（bindWithItem:）会让 cell 走一遍「高亮 / 选中」的配色流程，
    // 对方那条白气泡就被刷成蓝色。所以 bind 之前先把选中 / 高亮态清掉，
    // 让重绑按「正常态」画 —— 这步放在 bind 之前才是关键（之前放在之后没用，
    // 因为 bind 那一刻已经把蓝色画进异步 layer 了）。
    @try { [cell setHighlighted:NO animated:NO]; } @catch (NSException *e) { }
    @try { [cell setSelected:NO animated:NO]; } @catch (NSException *e) { }
    SLCRClearHighlightDeep(cell);
    // 选中底色是 UITableViewCell 自己那层（selectedBackgroundView），
    // 它会盖在 contentView 底下再"透"出来，清 backgroundColor 是清不掉的。
    // 重绑期间直接关掉选中样式与选中背景，重绑完再还原。
    UITableViewCellSelectionStyle selStyle = cell.selectionStyle;
    UIView *selBG = cell.selectedBackgroundView;
    @try { cell.selectionStyle = UITableViewCellSelectionStyleNone; } @catch (NSException *e) { }
    @try { cell.selectedBackgroundView = nil; } @catch (NSException *e) { }
    // v0.5.14：快照必须在「清完高亮之后」拍。之前是进函数第一件事就拍，
    // 而那一刻 cell 还是长按按下态（蓝）→ 快照存的是蓝 → 还原等于把蓝还回去。
    [cell setNeedsLayout];
    [cell layoutIfNeeded];
    NSArray *bgSnap = SLCRSnapshotBackgrounds(cell);
    // 先扔旧排版产物：不扔的话 bindWithItem: 会原样复用，改多少遍屏幕都不动
    SLCRDropLayoutCache(dataItem, cell);
    NSMutableArray *tried = [NSMutableArray array];
    if (dataItem) {
        NSArray *oneArg = @[@"bindWithItem:", @"bindHelloCellWithItem:",
                            @"setDataItem:", @"configureWithItem:", @"updateWithItem:"];
        for (NSString *name in oneArg) {
            SEL sel = NSSelectorFromString(name);
            if (![cell respondsToSelector:sel]) continue;
            NSMethodSignature *sig = [cell methodSignatureForSelector:sel];
            if (!sig || sig.numberOfArguments != 3) continue;
            const char *at = [sig getArgumentTypeAtIndex:2];
            if (!at || at[0] != '@') continue;
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:cell];
                [inv setSelector:sel];
                __unsafe_unretained id arg = dataItem;
                [inv setArgument:&arg atIndex:2];
                [inv invoke];
                [tried addObject:name];
                break;                 // 只走第一个能用的，反复绑会闪
            } @catch (NSException *e) { }
        }
    }
    NSArray *noArg = @[@"rebindCustomViewModel", @"updateLeftBubble", @"updateRightBubble"];
    for (NSString *name in noArg) {
        SEL sel = NSSelectorFromString(name);
        if (![cell respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [cell methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2) continue;
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:cell];
            [inv setSelector:sel];
            [inv invoke];
            [tried addObject:name];
        } @catch (NSException *e) { }
    }
    // 重绑把长按时的「高亮 / 选中」状态留在了 cell 上，先按正常态收回来
    @try { [cell setHighlighted:NO animated:NO]; } @catch (NSException *e) { }
    @try { [cell setSelected:NO animated:NO]; } @catch (NSException *e) { }
    SLCRClearHighlightDeep(cell);
    NSInteger fixed = SLCRRestoreBackgrounds(cell, bgSnap);
    // 选中样式 / 选中背景还原回去（下次长按还要正常表现）
    @try { cell.selectionStyle = selStyle; } @catch (NSException *e) { }
    @try { cell.selectedBackgroundView = selBG; } @catch (NSException *e) { }
    if (fixed > 0) {
        SLLog(@"REWRITE 重绑后底色还原 %ld 处（白↔蓝）", (long)fixed);
    }
    // 异步 layer 会把「按下态」的位图缓存住，光改 UIView 底色不会重画 ——
    // 逐层逼它重绘，白底才真正落到屏幕上。
    SLCRForceRedraw(cell);
    // 再兜一次：Momo 的 bind 是异步排版的，0.12s 后才真正画完，
    // 那时如果又染上按下态，这一遍把它按住。只做一次，不会循环。
    __weak UITableViewCell *weakCell = cell;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UITableViewCell *c = weakCell;
        if (!c) return;
        @try { [c setHighlighted:NO animated:NO]; } @catch (NSException *e) { }
        @try { [c setSelected:NO animated:NO]; } @catch (NSException *e) { }
        SLCRClearHighlightDeep(c);
        SLCRRestoreBackgrounds(c, bgSnap);
        SLCRForceRedraw(c);
    });
    return tried.count ? [tried componentsJoinedByString:@","] : @"-";
}

// 任何能读出字的地方都试一遍。v0.5.07 的「显示 → [-]」就是只认 UILabel 吃的亏。
static NSString *SLCRTextAnywhere(UIView *v, NSInteger depth) {
    if (!v || depth <= 0) return nil;
    NSString *best = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        best = l.attributedText.length ? l.attributedText.string : l.text;
    } else if ([v isKindOfClass:[UITextView class]]) {
        best = ((UITextView *)v).text;
    } else if ([v isKindOfClass:[UITextField class]]) {
        best = ((UITextField *)v).text;
    } else {
        for (NSString *key in @[@"attributedString", @"text", @"title", @"string", @"content"]) {
            SEL sel = NSSelectorFromString(key);
            if (![v respondsToSelector:sel]) continue;
            // 返回值必须是对象：performSelector 在 ARC 下会告警（-Werror 直接挂），走 IMP 稳一点
            NSMethodSignature *sig = [v methodSignatureForSelector:sel];
            if (!sig || sig.methodReturnType[0] != '@' || sig.numberOfArguments != 2) continue;
            @try {
                id (*fn)(id, SEL) = (id (*)(id, SEL))[v methodForSelector:sel];
                if (!fn) continue;
                id x = fn(v, sel);
                if ([x isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)x length]) {
                    best = [(NSAttributedString *)x string];
                } else if ([x isKindOfClass:[NSString class]] && [(NSString *)x length]) {
                    best = (NSString *)x;
                }
            } @catch (NSException *e) { }
            if (best.length) break;
        }
    }
    best = [best stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (UIView *sub in v.subviews) {
        NSString *s = SLCRTextAnywhere(sub, depth - 1);
        if (s.length > best.length) best = s;
    }
    return best.length ? best : nil;
}

// 排错专用：把 cell 的视图树打一次（每个 cell 类只打一次），
// 这样「气泡的字到底由谁画」不用再猜。
static void SLCRDumpViewTreeOnce(UIView *root, NSString *tag) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%@|%@", tag ?: @"-", NSStringFromClass([root class])];
    if ([seen containsObject:key]) return;
    [seen addObject:key];

    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    NSInteger budget = 40;
    while (queue.count && budget-- > 0) {
        UIView *cur = queue.firstObject;
        NSInteger d = [depths.firstObject integerValue];
        [queue removeObjectAtIndex:0];
        [depths removeObjectAtIndex:0];
        if (d > 3) continue;
        NSString *t = SLCRTextAnywhere(cur, 3) ?: @"-";
        [out addObject:[NSString stringWithFormat:@"%*s%@(%.0f,%.0f %.0fx%.0f)«%@»",
                        (int)(d * 2), "", NSStringFromClass([cur class]),
                        cur.frame.origin.x, cur.frame.origin.y,
                        cur.frame.size.width, cur.frame.size.height,
                        SLCRPreview(t, 12)]];
        for (UIView *sub in cur.subviews) {
            [queue addObject:sub];
            [depths addObject:@(d + 1)];
        }
    }
    SLLog(@"REWRITE-TREE %@ 节点 %lu：%@", tag ?: @"-", (unsigned long)out.count,
          [out componentsJoinedByString:@" | "]);
}

// 排错用：把某个类（含父类）里跟「重新加载/重排版」沾边的方法名打一行。
// 同一个类只打一次，别每保存一遍刷屏。
static void SLCRProbeSelectorsOnce(Class cls, NSString *tag) {
    if (!cls) return;
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%@|%@", tag, NSStringFromClass(cls)];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSArray *kws = @[@"reload", @"refresh", @"update", @"load", @"setup", @"config",
                     @"item", @"message", @"cell", @"render", @"bind"];
    NSMutableArray *out = [NSMutableArray array];
    Class c = cls;
    NSInteger guard = 0;
    while (c && c != [NSObject class] && guard < 6 && out.count < 70) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n && out.count < 70; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            if ([sel hasPrefix:@"."]) continue;
            for (NSString *kw in kws) {
                if ([sel rangeOfString:kw].location != NSNotFound) { [out addObject:sel]; break; }
            }
        }
        if (ms) free(ms);
        c = class_getSuperclass(c);
        guard += 1;
    }
    SLLog(@"REWRITE-PROBE %@ %@ 候选 %lu：%@", tag, NSStringFromClass(cls),
          (unsigned long)out.count, [out componentsJoinedByString:@" | "]);
}

void SLChatRewritePatchLiveText(NSArray *aliases, NSString *orig, NSString *repl) {
    if (!orig.length || !repl.length || [orig isEqualToString:repl]) return;
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *tv = chat ? SLCRChatTable(chat.view) : nil;
    if (!tv) tv = SLCRChatTableAnywhere();
    if (!tv) {
        SLLog(@"REWRITE 渲染补丁：没找到聊天列表");
        return;
    }
    NSInteger cells = 0, modelHits = 0, labelHits = 0;
    for (UITableViewCell *cell in tv.visibleCells) {
        id m = SLCRMessageOf(cell);
        if (!m) continue;
        NSArray *ids = SLChatRewriteAliasesForMessage(m, nil);
        BOOL hit = NO;
        for (NSString *a in ids) {
            if ([aliases containsObject:a]) { hit = YES; break; }
        }
        if (!hit) {
            NSString *mid = SLCRMsgidOf(m);
            if (mid.length && [aliases containsObject:mid]) hit = YES;
        }
        if (!hit) continue;
        cells += 1;

        id dataItem = nil;
        @try { dataItem = [cell valueForKey:@"dataItem"]; } @catch (NSException *e) { }
        NSString *itemCls = dataItem ? NSStringFromClass([dataItem class]) : @"nil";

        gSLCRPatchBudget = 900;
        NSMutableString *trace = [NSMutableString string];
        NSInteger mh = SLCRPatchModelStrings(cell, 5, orig, repl, trace);
        // v0.5.20：先试着直接改活着的标签（不动 bind）。蓝色气泡的唯一来源就是
        // bindWithItem: 走的那遍高亮配色 —— 只要不重绑，就绝不可能变蓝。
        NSMutableString *inventory = [NSMutableString string];
        NSInteger seenLabels = 0;
        NSInteger lh = SLCRPatchLabelsInView(cell, orig, repl, inventory, &seenLabels);
        NSMutableString *layerInv = [NSMutableString string];
        NSInteger ly = SLCRPatchLayers(cell.layer, orig, repl, layerInv, 6);
        NSString *how = @"未重绑";
        if (lh == 0 && ly == 0) {
            // 标签确实换不动（排版对象里没有原文），这时才让 cell 按新模型重绑一次。
            // 这是兜底路径，不常走；走了也未必能彻底躲掉蓝色，但至少不再是每条都蓝。
            how = SLCRTryRebindCell(cell, dataItem);
            [cell setNeedsLayout];
            [cell layoutIfNeeded];
            mh += SLCRPatchModelStrings(cell, 5, orig, repl, nil);
            lh = SLCRPatchLabelsInView(cell, orig, repl, inventory, &seenLabels);
            ly = SLCRPatchLayers(cell.layer, orig, repl, layerInv, 6);
            SLCRDumpViewTreeOnce(cell, @"cell");
            SLCRDumpLayerTreeOnce(cell, @"cell");
        }
        NSString *shownNow = SLCRTextAnywhere(cell, 5) ?: @"-";
        modelHits += mh;
        labelHits += lh + ly;
        SLLog(@"REWRITE 渲染补丁 cell=%@ dataItem=%@ 模型 %ld 处 [%@] 标签 %ld 处/%ld 个 [%@] 图层 %ld 处 [%@] 重绑=%@ 现在=[%@]",
              NSStringFromClass([cell class]), itemCls, (long)mh,
              trace.length ? trace : @"-", (long)lh, (long)seenLabels,
              inventory.length ? inventory : @"-", (long)ly,
              layerInv.length ? layerInv : @"-", how, SLCRPreview(shownNow, 14));
        if (lh > 0 || mh > 0) {
            SLCRProbeSelectorsOnce([cell class], @"cell");
            // 聊天页认不出来时拿 table 的 delegate 顶一下 —— 上次 vc 那行一直没打出来，
            // 就是因为 SLCRChatVC 没认出来，白白少了「整页刷新方法名」这张表
            id vcObj = chat;
            if (!vcObj) {
                id dg = tv.delegate;
                if ([dg isKindOfClass:[UIViewController class]]) vcObj = dg;
            }
            if (!vcObj) {
                for (UIView *v = tv.superview; v && !vcObj; v = v.superview) {
                    id nr = v.nextResponder;
                    if ([nr isKindOfClass:[UIViewController class]]) vcObj = nr;
                }
            }
            if (vcObj) SLCRProbeSelectorsOnce([vcObj class], @"vc");
        }
    }
    if (!cells) SLLog(@"REWRITE 渲染补丁：可见 cell 里没找到这条消息（orig=%@）", SLCRPreview(orig, 16));
    else {
        SLLog(@"REWRITE 渲染补丁合计 %ld 个 cell，模型 %ld 处 / 标签 %ld 处",
              (long)cells, (long)modelHits, (long)labelHits);
        // 字变长了气泡得跟着长，不然新字被旧高度裁掉一截
        if (labelHits > 0 || modelHits > 0) {
            [tv beginUpdates];
            [tv endUpdates];
        }
    }
}

// 刷新后回读：屏幕上真正显示的字是什么。下次再出问题，这一行就能定性。
void SLChatRewriteDumpVisibleText(void) {
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *tv = chat ? SLCRChatTable(chat.view) : nil;
    if (!tv) return;
    // 刷新之后顺带把「时间 + 距离」那行也按每条消息的映射刷一遍
    SLChatMetaApplyTable(tv);
    NSInteger n = 0;
    for (UITableViewCell *cell in tv.visibleCells) {
        if (n >= 12) break;
        id m = SLCRMessageOf(cell);
        NSString *mid = SLCRMsgidOf(m) ?: @"-";
        NSString *shown = SLCRTextAnywhere(cell, 6) ?: @"-";
        NSArray *ids = m ? SLChatRewriteAliasesForMessage(m, nil) : nil;
        // 空串当「没有记录」：这个函数拿它当 orig 原样返回，正好用来判有没有改写
        NSString *want = SLChatRewriteTextForIds(ids, @"");
        SLLog(@"REWRITE 显示 %@ → [%@]%@", mid, SLCRPreview(shown, 20),
              want.length ? [NSString stringWithFormat:@" 应为[%@]%@", SLCRPreview(want, 20),
                             [want isEqualToString:shown] ? @" ✓" : @" ✗"] : @"");
        n += 1;
    }
}

void SLChatRewriteHandleLeave(UIViewController *vc) {
    if (!SLChatRewriteResetOnLeave()) return;
    NSString *session = SLCRSessionOfVC(SLCRChatVC(vc) ?: vc);
    if (session.length) SLChatRewriteClearSession(session);
}

#pragma mark - 撤回重绘：原文画回气泡 + 「已拦截」标

// 陌陌撤回的最终表现是「整条气泡被替换成一行居中的小灰字」，
// 只在 body getter 上顶回原文是改不到显示的（v0.5.10 打了 7 次 RECALL-GUARD，
// 屏幕照旧）。这里做两件事：
//   1. 跟「修改文字」走完全一样的重绑路 —— body 已经是原文，重绑画出来就是原文；
//   2. 在画回来的气泡上贴一枚「已拦截」小标，让人一眼看出这条是被我们拦下的。
// 系统原来那行「对方撤回了一条消息」不动，就留在上面。
static NSInteger gSLRecallRepaintLog = 0;
static const NSInteger kSLRecallCardTag = 0x5EC2;

// 被拦的撤回在陌陌里是系统消息 cell（MDSChatsystemProCell 之类），不是气泡。
// 甲样式：在这类 cell 上盖一张居中浅灰卡片，红色「已拦截」小徽章（不压字）+ 浅灰
// 「对方撤回」+ 深灰原文（自动换行、行高自适应）。不再事后重绑气泡 → 顺手灭掉蓝色死循环。
static BOOL SLRecallIsSystemCell(UITableViewCell *cell) {
    NSString *cls = NSStringFromClass([cell class]);
    return ([cls rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"recall" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

// 隐藏系统撤回行原本的内容（那颗「X 撤回了一条消息」灰色胶囊）。
// 实测它的结构是 contentView → UIView(29x24 胶囊底) → MDMixLabel(7x15)，
// 标签是**嵌套**的，所以不能只看直接子视图；整块内容都得让位给我们的卡片。
static const void *kSLRecallHidKey = &kSLRecallHidKey;

static void SLRecallHideSystemContent(UITableViewCell *cell) {
    if (!cell) return;
    NSMutableArray *hid = objc_getAssociatedObject(cell, kSLRecallHidKey);
    if (![hid isKindOfClass:[NSMutableArray class]]) {
        hid = [NSMutableArray array];
        objc_setAssociatedObject(cell, kSLRecallHidKey, hid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *sub in cell.contentView.subviews) {
        if (sub.tag == kSLRecallCardTag) continue;
        if (sub.isHidden) continue;
        sub.hidden = YES;
        [hid addObject:sub];
    }
}

static void SLRecallShowSystemContent(UITableViewCell *cell) {
    if (!cell) return;
    NSMutableArray *hid = objc_getAssociatedObject(cell, kSLRecallHidKey);
    if (![hid isKindOfClass:[NSMutableArray class]] || !hid.count) return;
    for (UIView *v in hid) {
        if (v.superview == cell.contentView) v.hidden = NO;
    }
    [hid removeAllObjects];
}

// 原文比窗口高 → 让它自己慢慢上下滚（12pt/s，走到底停一下再回来）。
// 用 layer 动画而不是 UIView 动画：cell 反复复用、列表动来动去都不会打断它。
static void SLRecallStartScroll(UILabel *body, UIView *clip) {
    if (!body || !clip) return;
    [body.layer removeAnimationForKey:@"sl_scroll"];
    CGFloat contentH = CGRectGetHeight(body.frame);
    CGFloat winH = CGRectGetHeight(clip.bounds);
    if (winH < 6.0 || contentH <= winH + 1.0) return;      // 装得下就不滚
    CGFloat dist = contentH - winH;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    a.fromValue = @(0);
    a.toValue = @(-dist);
    a.duration = MAX(2.4, (double)dist / 12.0);
    a.autoreverses = YES;
    a.repeatCount = 1.0e9f;
    a.beginTime = CACurrentMediaTime() + 1.0;   // 先让人读到第一行，再开始走
    a.fillMode = kCAFillModeBoth;
    a.removedOnCompletion = NO;
    [body.layer addAnimation:a forKey:@"sl_scroll"];
}

// 建 / 更新甲卡片。卡片高度按原文估算，行高不够时顶对齐（高度 hook 生效后居中显示更多）。
static void SLRecallBuildCard(UITableViewCell *cell, NSString *orig) {
    if (!cell || ![orig isKindOfClass:[NSString class]] || !orig.length) return;
    UIView *card = [cell.contentView viewWithTag:kSLRecallCardTag];
    if (!card) {
        card = [[UIView alloc] initWithFrame:CGRectZero];
        card.tag = kSLRecallCardTag;
        card.layer.cornerRadius = 14.0;
        card.backgroundColor = [UIColor colorWithRed:0.988 green:0.922 blue:0.922 alpha:1.0];
        card.layer.borderWidth = 0.5;
        card.layer.borderColor = [[UIColor colorWithRed:0.941 green:0.600 blue:0.478 alpha:1.0] CGColor];
        card.clipsToBounds = YES;

        UILabel *badge = [[UILabel alloc] init];
        badge.tag = 11;
        badge.text = @"已拦截";
        badge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        badge.textColor = [UIColor whiteColor];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.backgroundColor = [UIColor colorWithRed:0.886 green:0.290 blue:0.290 alpha:1.0];
        badge.layer.cornerRadius = 10.0;
        badge.layer.masksToBounds = YES;
        [card addSubview:badge];

        UILabel *pre = [[UILabel alloc] init];
        pre.tag = 12;
        pre.text = @"对方撤回";
        pre.font = [UIFont systemFontOfSize:12];
        pre.textColor = [UIColor colorWithRed:0.706 green:0.698 blue:0.663 alpha:1.0];
        [card addSubview:pre];

        // 原文放进裁剪容器：字多的时候容器高不够，就让这行字在里面慢慢上下滚
        // （严格 one-line 的窗口也照样能看全文，不再「多的看不到」）
        UIView *clip = [[UIView alloc] init];
        clip.tag = 14;
        clip.clipsToBounds = YES;
        clip.backgroundColor = [UIColor clearColor];
        [card addSubview:clip];

        UILabel *body = [[UILabel alloc] init];
        body.tag = 13;
        body.font = [UIFont systemFontOfSize:13];
        body.textColor = [UIColor colorWithRed:0.173 green:0.173 blue:0.165 alpha:1.0];
        body.numberOfLines = 0;
        body.lineBreakMode = NSLineBreakByWordWrapping;
        [clip addSubview:body];

        [cell.contentView addSubview:card];
    }
    UILabel *badge = [card viewWithTag:11];
    UILabel *pre   = [card viewWithTag:12];
    UILabel *body  = [card viewWithTag:13];
    UIView  *clip  = [card viewWithTag:14];
    body.text = orig;

    CGFloat cw = CGRectGetWidth(cell.contentView.bounds) - 32.0;
    if (cw < 120.0) cw = 120.0;
    CGFloat cellH = CGRectGetHeight(cell.contentView.bounds);
    CGFloat cardW = cw;

    CGSize badgeSz = [badge.text sizeWithAttributes:@{NSFontAttributeName: badge.font}];
    CGFloat badgeW = badgeSz.width + 16.0;

    // 行高能不能撑开决定了排版走哪条：
    //   行高够 → 两行（徽章行 + 原文自动换行）；
    //   行高不够（heightForRow 拿不到、还是 42pt 的系统行高）→ 单行紧凑，
    //   徽章 + 「对方撤回 · 原文…」，保证原文至少看得见，绝不出现「只有对方撤回」。
    CGFloat avail = (cellH > 20.0) ? (cellH - 6.0) : 36.0;
    BOOL compact = (avail < 92.0);

    if (compact) {
        CGFloat pad = 10.0, rowH = 18.0;
        CGFloat cardH = (avail > 36.0) ? 36.0 : avail;
        if (cardH < 28.0) cardH = 28.0;
        CGFloat y = (cardH - rowH) / 2.0;

        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        CGSize bsz = [badge.text sizeWithAttributes:@{NSFontAttributeName: badge.font}];
        badgeW = bsz.width + 14.0;
        badge.frame = CGRectMake(pad, y, badgeW, rowH);
        badge.layer.cornerRadius = 9.0;

        CGFloat preX = pad + badgeW + 8.0;
        CGFloat preW = 56.0;
        pre.frame = CGRectMake(preX, y, preW, rowH);
        pre.font = [UIFont systemFontOfSize:11];

        CGFloat bodyX = preX + preW + 4.0;
        CGFloat bodyW = cardW - bodyX - pad;
        if (bodyW < 24.0) bodyW = 24.0;
        // 不再单行截断（用户实测「长文字只剩一行，多的看不到」）。
        // label 按全文长度铺开，容器只露一行高 —— 超出就滚。
        body.numberOfLines = 0;
        body.lineBreakMode = NSLineBreakByWordWrapping;
        body.font = [UIFont systemFontOfSize:12];
        CGFloat naturalH = ceil([body sizeThatFits:CGSizeMake(bodyW, CGFLOAT_MAX)].height);
        if (naturalH < rowH) naturalH = rowH;
        clip.frame = CGRectMake(bodyX, y, bodyW, rowH);
        body.frame = CGRectMake(0, 0, bodyW, naturalH);
        SLRecallStartScroll(body, clip);

        CGFloat cardY = (cellH > cardH) ? (cellH - cardH) / 2.0 : 2.0;
        if (cardY < 0) cardY = 0;
        card.frame = CGRectMake(16.0, cardY, cardW, cardH);
        return;
    }

    // 两行布局
    CGFloat pad = 12.0, badgeH = 20.0;
    badge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    badge.layer.cornerRadius = 10.0;
    pre.font = [UIFont systemFontOfSize:12];
    body.numberOfLines = 0;
    body.lineBreakMode = NSLineBreakByWordWrapping;
    body.font = [UIFont systemFontOfSize:13];

    badge.frame = CGRectMake(pad, pad, badgeW, badgeH);
    pre.frame = CGRectMake(pad + badgeW + 8.0, pad + 1.0, cw - badgeW - 8.0 - pad, badgeH);

    CGFloat bodyW = cw - pad * 2.0;
    CGFloat naturalH = ceil([body sizeThatFits:CGSizeMake(bodyW, CGFLOAT_MAX)].height);
    if (naturalH < 16.0) naturalH = 16.0;
    CGFloat bodyY = pad + badgeH + 8.0;
    CGFloat winH = naturalH;
    CGFloat cardH = bodyY + naturalH + pad;
    if (cardH > avail) {                       // 再兜一层：绝不越过本行
        cardH = avail;
        winH = cardH - bodyY - pad;
        if (winH < 14.0) winH = 14.0;
    }
    clip.frame = CGRectMake(pad, bodyY, bodyW, winH);
    body.frame = CGRectMake(0, 0, bodyW, naturalH);
    SLRecallStartScroll(body, clip);

    CGFloat cardY = (cellH > cardH) ? (cellH - cardH) / 2.0 : 3.0;
    if (cardY < 0) cardY = 0;
    card.frame = CGRectMake(16.0, cardY, cardW, cardH);
}

// 估算甲卡片高度（供行高 hook 使用）
CGFloat SLRecallCardHeight(NSString *orig, CGFloat tableWidth) {
    if (![orig isKindOfClass:[NSString class]] || !orig.length) return 44.0;
    CGFloat cw = tableWidth - 32.0;
    if (cw < 120.0) cw = 120.0;
    CGFloat pad = 12.0, badgeH = 20.0;
    CGFloat bodyW = cw - pad * 2.0;
    UIFont *f = [UIFont systemFontOfSize:13];
    CGRect r = [orig boundingRectWithSize:CGSizeMake(bodyW, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                               attributes:@{NSFontAttributeName:f} context:nil];
    CGFloat bodyH = (CGFloat)ceil(r.size.height);
    // 最多给三行高度，再长就在卡片里自己滚（以前是「一行截断」或「撑满半屏」两种极端）
    CGFloat maxH = ceil(f.lineHeight * 3.0 + 2.0);
    if (bodyH > maxH) bodyH = maxH;
    return pad + badgeH + 8.0 + bodyH + pad + 4.0;
}

// 刷新可见的被拦撤回行（无重绑：直接按卡片渲染，杜绝 bindWithItem 触发的蓝色死循环）
void SLRecallRepaintVisible(void) {
    if (!SLRecallGuardEnabled()) return;
    if (!gSLRecallBlocked) SLRecallLoadBlocked();
    if (!gSLRecallBlocked.count) return;
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *tv = chat ? SLCRChatTable(chat.view) : nil;
    if (!tv) tv = SLCRChatTableAnywhere();          // 认不出聊天页时兜底（日志里常见这种）
    if (!tv) { SLLog(@"RECALL-REPAINT 没找到聊天列表"); return; }
    NSInteger n = 0;
    for (UITableViewCell *cell in tv.visibleCells) {
        @try {
            NSString *mid = SLCRMsgidOf(SLCRMessageOf(cell));
            if (mid.length && SLRecallIsBlocked(mid)) { SLRecallApplyCell(cell); n += 1; }
        } @catch (NSException *e) {}
    }
    if (n && gSLRecallRepaintLog < 24) {
        gSLRecallRepaintLog += 1;
        SLLog(@"RECALL-REPAINT 共刷新 %ld 条（仅被拦的，无重绑）", (long)n);
    }
    // 卡片比原来那行高：让 table 重算一次行高（不 reloadData，不重绑，不会闪蓝）
    static BOOL inUpdate = NO;
    if (n && !inUpdate) {
        inUpdate = YES;
        @try { [tv beginUpdates]; [tv endUpdates]; } @catch (NSException *e) { }
        inUpdate = NO;
    }
}

// 单格渲染层拦截：被拦的那条盖甲卡片 + 隐藏原小标签；非拦截（含被复用）清卡片还原。
// 只对被拦 mid 生效 —— 别的消息一律不动（解决「贴满屏」）；持久名单让重进后还在。
void SLRecallApplyCell(UITableViewCell *cell) {
    if (!SLRecallGuardEnabled()) return;
    if (!cell) return;
    if (!gSLRecallBlocked) SLRecallLoadBlocked();
    UIView *oldCard = [cell.contentView viewWithTag:kSLRecallCardTag];
    NSString *mid = SLCRMsgidOf(SLCRMessageOf(cell));
    BOOL blocked = (mid.length && SLRecallIsBlocked(mid));
    if (!blocked) {
        if (oldCard) [oldCard removeFromSuperview];
        SLRecallShowSystemContent(cell);
        return;
    }
    NSString *orig = SLRecallBlockedOriginal(mid);
    if (![orig isKindOfClass:[NSString class]] || !orig.length) return;
    if (SLRecallHidden()) {
        // 隐藏模式：恢复普通撤回外观，不露「已拦截」、不露原文（截图不外泄）
        if (oldCard) [oldCard removeFromSuperview];
        SLRecallShowSystemContent(cell);
        return;
    }
    if (SLRecallIsSystemCell(cell)) {
        SLRecallHideSystemContent(cell);
        SLRecallBuildCard(cell, orig);
    }
    if (gSLRecallRepaintLog < 30) {
        gSLRecallRepaintLog += 1;
        SLLog(@"RECALL-APPLY 卡片 %@ 原文=[%@] 隐藏=%d", mid, SLCRPreview(orig, 16), (int)SLRecallHidden());
    }
}

// 由 indexPath 取到对应消息的 msgid（供行高 hook 判断这条是不是被拦的撤回）。
// 各 VC 的消息数组属性名不一，先试一批常见 key，命中后缓存，没命中就退化为不撑高。
NSString *SLCRMsgidAtIndexPath(UITableView *tv, NSIndexPath *ip) {
    if (!tv || !ip) return nil;
    id ds = (id)tv.dataSource;
    if (!ds) ds = (id)tv.delegate;
    if (!ds) return nil;
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"chatMessages", @"messages", @"dataArray", @"messageList",
                 @"msgList", @"items", @"msgModels", @"modelList", @"dataSourceArray",
                 @"displayMessages", @"datas", @"list", @"rows", @"cellItems"];
    });

    id m = nil;
    // 1) 常见属性名
    for (NSString *k in keys) {
        @try {
            id a = [ds valueForKey:k];
            if ([a isKindOfClass:[NSArray class]] && [a count] > (NSUInteger)ip.row) {
                id cand = a[(NSUInteger)ip.row];
                NSString *mid = SLCRMsgidOf(cand);
                if (mid.length) { m = cand; break; }
            }
        } @catch (NSException *e) {}
    }
    // 2) 属性名猜不到就直接翻 ivar —— 陌陌的 helper 是 Swift 类，属性名不一定对得上。
    //    只认「能取出一条真消息（有 body + msgid）」的那个数组，别的一律跳过。
    if (!m) {
        Class cls = object_getClass(ds);
        NSInteger guard = 0;
        while (cls && cls != [NSObject class] && guard < 8 && !m) {
            unsigned int n = 0;
            Ivar *ivars = class_copyIvarList(cls, &n);
            for (unsigned int i = 0; i < n && !m; i++) {
                const char *t = ivar_getTypeEncoding(ivars[i]);
                if (!t || t[0] != '@') continue;
                id v = nil;
                @try { v = object_getIvar(ds, ivars[i]); } @catch (NSException *e) { }
                if (![v isKindOfClass:[NSArray class]]) continue;
                NSArray *a = (NSArray *)v;
                if ([a count] <= (NSUInteger)ip.row) continue;
                id cand = nil;
                @try { cand = a[(NSUInteger)ip.row]; } @catch (NSException *e) { }
                if (!cand) continue;
                if (SLCRMsgidOf(cand).length) m = cand;
            }
            if (ivars) free(ivars);
            cls = class_getSuperclass(cls);
            guard += 1;
        }
        if (m) SLLog(@"RECALL-HEIGHT 数据源 ivar 兜底命中（row=%ld）", (long)ip.row);
    }
    return SLCRMsgidOf(m);
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
