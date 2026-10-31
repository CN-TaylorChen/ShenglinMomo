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
static void SLCRDumpStyleOnce(UIView *root, NSString *tag);
static NSAttributedString *SLCRReplaceAttributed(NSAttributedString *src, NSString *repl);
static BOOL SLCRIsLabelLike(id v);
static NSString *SLCRShownTextOf(id v);
static BOOL SLCRSetShownText(id v, NSString *target);
static NSString *SLCRTextAnywhere(UIView *v, NSInteger depth);
static id SLCRMessageOf(id obj);
static NSString *SLCRMsgidOf(id message);

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

BOOL SLMetaHasOverride(NSString *msgid) {
    return SLMetaTimeFor(msgid).length > 0 || SLMetaDistFor(msgid).length > 0;
}

void SLMetaSave(NSString *msgid, NSString *time, NSString *dist) {
    if (![msgid isKindOfClass:[NSString class]] || !msgid.length) return;
    NSString *t = SLTrimmed(time);
    NSString *d = SLTrimmed(dist);
    id raw = SLMetaStore()[msgid];
    NSMutableDictionary *e = [raw isKindOfClass:[NSMutableDictionary class]]
                             ? (NSMutableDictionary *)raw : [NSMutableDictionary dictionary];
    // e[@"o"] 是「这行原本写的是什么」—— 清空两个输入框时靠它复原，别删
    [e removeObjectForKey:@"t"];
    [e removeObjectForKey:@"d"];
    if (t.length) e[@"t"] = t;
    if (d.length) e[@"d"] = d;
    if (e.count == 0) [SLMetaStore() removeObjectForKey:msgid];
    else SLMetaStore()[msgid] = e;
    SLMetaSync();
    SLLog(@"META 保存 %@ 时间=[%@] 距离=[%@]", msgid, t ?: @"-", d ?: @"-");
    // 会话列表 / 搜索结果里的预览也读同一份，这里不管；聊天页当场刷
    dispatch_async(dispatch_get_main_queue(), ^{ SLChatMetaApplyTable(nil); });
}

// 形态判据：短串、含 km、无换行 —— 就是那行「时间 距离」。
static BOOL SLMetaRowLooksLike(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    if (s.length < 6 || s.length > 44) return NO;
    if ([s rangeOfString:@"\n"].location != NSNotFound) return NO;
    return [s rangeOfString:@"km" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// 在一格 cell 里找「形态像时间行」的那个可写标签（UILabel / MDMixLabel 都算）
static id SLMetaRowViewIn(UIView *v, NSInteger depth) {
    if (!v || depth <= 0) return nil;
    if (SLCRIsLabelLike(v) && SLMetaRowLooksLike(SLCRShownTextOf(v))) return v;
    for (UIView *sub in v.subviews) {
        id r = SLMetaRowViewIn(sub, depth - 1);
        if (r) return r;
    }
    return nil;
}

// 这条消息的时间行贴在哪一格：往上找最近的、能认出形态的那格。
// 陌陌的时间行通常紧贴在消息上方（ip.row-1），但连续同一时段的消息会共用几格，
// 所以最多往上找 4 格 —— 找到谁算谁，不往下找（往下就是下一条消息的了）。
static id SLMetaRowViewAbove(UITableView *tv, NSIndexPath *ip) {
    if (!tv || !ip) return nil;
    for (NSInteger k = 1; k <= 4; k++) {
        NSInteger r = ip.row - k;
        if (r < 0) break;
        NSIndexPath *prev = [NSIndexPath indexPathForRow:r inSection:ip.section];
        UITableViewCell *pc = [tv cellForRowAtIndexPath:prev];
        if (!pc) continue;
        id v = SLMetaRowViewIn(pc, 6);
        if (v) return v;
    }
    return nil;
}

// v0.5.11：全局替换已废弃。这个符号还留着是因为 Tweak.x 的 `UILabel setText:`
// 钩子在用 —— 现在恒等于原样返回（本来也没值可替），真正的替换在
// SLChatMetaApplyTable() 里按 msgid 精确做。
NSString *SLApplyMetaEdits(NSString *s) {
    return s;
}

// 把某条消息的时间行按它的映射刷一遍。返回是否真的改了。
static BOOL SLMetaApplyOne(UITableView *tv, NSIndexPath *ip, BOOL *outFound) {
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    if (!cell) return NO;
    NSString *mid = SLCRMsgidOf(SLCRMessageOf(cell));
    if (!mid.length) return NO;
    NSString *tt = SLMetaTimeFor(mid);
    NSString *dd = SLMetaDistFor(mid);
    NSDictionary *entry = SLMetaStore()[mid];
    NSString *orig = [entry isKindOfClass:[NSDictionary class]] ? entry[@"o"] : nil;
    BOOL hasOverride = (tt.length || dd.length);
    // 既没有覆盖、也没历史原文 → 这条就跟我们无关
    if (!hasOverride && !([orig isKindOfClass:[NSString class]] && orig.length)) return NO;
    id rowView = SLMetaRowViewAbove(tv, ip);
    if (!rowView) {
        if (outFound) *outFound = NO;
        return NO;
    }
    if (outFound) *outFound = YES;
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
    } else if (hasOverride && [orig isKindOfClass:[NSString class]] && ![orig isEqualToString:cur]) {
        // 已经换过一次了：cur 是被我们改过的串，原文仍在 orig 里
    }
    if (!hasOverride) {
        // 用户把两个框都清空了 → 复原成原文
        if (![orig isKindOfClass:[NSString class]] || ![orig isEqualToString:cur]) {
            if ([orig isKindOfClass:[NSString class]] && orig.length) {
                if (SLCRSetShownText(rowView, orig)) {
                    SLLog(@"META 复原 %@ → [%@]", mid, orig);
                    return YES;
                }
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
        // 现在是原文（形态对得上也拆一次，拆不出就用原文的头）
        NSTextCheckingResult *m2 = [SLMetaPairRE() firstMatchInString:orig options:0
                                                                range:NSMakeRange(0, orig.length)];
        if (m2 && m2.numberOfRanges >= 3) {
            head = [orig substringWithRange:[m2 rangeAtIndex:1]];
            dist = [orig substringWithRange:[m2 rangeAtIndex:2]];
        }
    }
    NSString *nd = nil;
    if (dd.length) nd = [dd.lowercaseString hasSuffix:@"km"] ? dd : [dd stringByAppendingString:@"km"];
    else nd = dist ?: @"km";
    NSString *out = [NSString stringWithFormat:@"%@ %@", tt.length ? tt : head, nd];
    if ([out isEqualToString:cur]) return NO;
    if (!SLCRSetShownText(rowView, out)) return NO;
    if (gSLMetaLog < 12) {
        gSLMetaLog += 1;
        SLLog(@"META 时间距离 [%@] → [%@] (msgid=%@)", cur, out, mid);
    }
    return YES;
}

void SLChatMetaApplyTable(UITableView *tv) {
    if (!SLMetaStore().count) return;
    if (!tv) {
        UIViewController *chat = SLCRChatVC(SLCRTopVC());
        tv = chat ? SLCRChatTable(chat.view) : nil;
    }
    if (!tv) return;
    NSInteger applied = 0, misses = 0;
    for (NSIndexPath *ip in tv.indexPathsForVisibleRows) {
        BOOL found = YES;
        if (SLMetaApplyOne(tv, ip, &found)) applied += 1;
        else if (!found) misses += 1;
    }
    if ((applied || misses) && gSLMetaLog < 20) {
        gSLMetaLog += 1;
        SLLog(@"META 应用 已刷 %ld 行 / 未找到时间行 %ld", (long)applied, (long)misses);
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

static NSMutableDictionary *gSLRecallCache = nil;
static NSInteger gSLRecallLog = 0;
static NSString *SLCRPreview(NSString *s, NSUInteger max);

static BOOL SLRecallLooksGone(NSString *s) {
    if (!s.length) return YES;
    return [s containsString:@"撤回"] || [s containsString:@"已失效"];
}

NSString *SLRecallGuardBody(NSString *mid, NSString *body) {
    if (!SLRecallGuardEnabled()) return body;
    if (![mid isKindOfClass:[NSString class]] || !mid.length) return body;
    if (![body isKindOfClass:[NSString class]]) return body;
    if (!gSLRecallCache) gSLRecallCache = [NSMutableDictionary dictionary];
    if (!SLRecallLooksGone(body) && gSLRecallCache.count < 2000) {
        gSLRecallCache[mid] = body;
        return body;
    }
    NSString *old = gSLRecallCache[mid];
    if ([old isKindOfClass:[NSString class]] && old.length) {
        if (gSLRecallLog < 8) {
            gSLRecallLog += 1;
            SLLog(@"RECALL-GUARD 顶回原文 %@ → [%@]", mid, SLCRPreview(old, 14));
        }
        // 顶回 body 只是「模型里对了」。屏幕还是那行撤回提示 ——
        // 得走一遍「跟改文字同样的重绑」才画得出来（v0.5.10 就是只顶不刷）。
        // 同一条消息一次撤回会走七八遍 getter，这里按 mid 节流，只排一次重绘。
        static NSString *pendingMid = nil;
        static NSUInteger pendingGen = 0;
        if (![pendingMid isEqualToString:mid]) {
            pendingMid = [mid copy];
            pendingGen += 1;
            NSUInteger gen = pendingGen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (gen != pendingGen) return;      // 期间又撤回了别的，交给后来那次
                @try { SLRecallRepaintVisible(); } @catch (NSException *e) { }
            });
        }
        return old;
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
    [self sl_addRow:@"时间" placeholder:@"12:01 / 5分钟前 / 10-28 15:19" value:self.initialTime];
    [self sl_addRow:@"距离" placeholder:@"96.96（km 会自动补）" value:self.initialDist];
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
    _card.frame = CGRectMake(16, top, w, rowH * 2.0);
    _divider.frame = CGRectMake(14, rowH, w - 28.0, 0.5);
    for (NSInteger i = 0; i < 2; i++) {
        CGFloat y = rowH * (CGFloat)i;
        _labels[i].frame = CGRectMake(14, y, 44, rowH);
        _fields[i].frame = CGRectMake(62, y, w - 62 - 14, rowH);
    }
}

- (void)sl_cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)sl_trim:(NSString *)s {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)sl_save {
    NSString *t = [self sl_trim:_fields.count > 0 ? _fields[0].text : @""];
    NSString *d = [self sl_trim:_fields.count > 1 ? _fields[1].text : @""];
    NSString *mid = [self.msgid copy];
    SLMetaSave(mid, t, d);
    [self dismissViewControllerAnimated:YES completion:^{
        SLChatMetaApplyTable(nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SLChatMetaApplyTable(nil); });
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

    // 预填：优先用「这条消息已经改过的值」，否则用屏幕上那行的真实值
    UITableView *table = SLCRChatTableAnywhere();
    NSIndexPath *ip = (cell && table) ? [table indexPathForCell:cell] : nil;
    NSString *cur = @"";
    if (ip) {
        id rv = SLMetaRowViewAbove(table, ip);
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
    // 记下原文：面板里清空两个框 = 复原成这串
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

    SLLog(@"META 打开面板 msgid=%@ 当前行=[%@] 预填 时间=[%@] 距离=[%@] cell=%@ ip=%@",
          mid, SLCRPreview(cur, 20), t0, d0,
          cell ? NSStringFromClass([cell class]) : @"nil",
          ip ? [NSString stringWithFormat:@"%ld-%ld", (long)ip.section, (long)ip.row] : @"nil");

    SLChatMetaEditorController *editor = [[SLChatMetaEditorController alloc] init];
    editor.msgid = mid;
    editor.initialTime = t0;
    editor.initialDist = d0;

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
    NSInteger fixed = SLCRRestoreBackgrounds(cell, bgSnap);
    if (fixed > 0) {
        SLLog(@"REWRITE 重绑后底色还原 %ld 处（白↔蓝）", (long)fixed);
    }
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
        // 模型改完立刻重绑：bindWithItem: 才是「退出会话重进」真正走的入口，
        // 只调 setDataItem: 这种属性 setter 不会重排（v0.5.07 就是这么白改的）
        NSString *how = SLCRTryRebindCell(cell, dataItem);
        [cell setNeedsLayout];
        [cell layoutIfNeeded];
        // 重绑会把模型里的字再抄一份到排版对象上，所以再补一遍
        mh += SLCRPatchModelStrings(cell, 5, orig, repl, nil);
        NSMutableString *inventory = [NSMutableString string];
        NSInteger seenLabels = 0;
        NSInteger lh = SLCRPatchLabelsInView(cell, orig, repl, inventory, &seenLabels);
        NSMutableString *layerInv = [NSMutableString string];
        NSInteger ly = SLCRPatchLayers(cell.layer, orig, repl, layerInv, 6);
        if (lh == 0 && ly == 0) {
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
    SLRecallStyleSweep();
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
static const NSInteger kSLRecallBadgeTag = 0x5EC1;

static UIView *SLCRBubbleViewIn(UIView *root) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 400;
    while (q.count && budget-- > 0) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        if (v != root && ![v isKindOfClass:[UILabel class]]) {
            CGFloat area = v.frame.size.width * v.frame.size.height;
            if (v.layer.cornerRadius >= 6.0 && area > bestArea && area > 600.0) {
                best = v;
                bestArea = area;
            }
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return best;
}

static void SLRecallAttachBadge(UITableViewCell *cell) {
    if (!cell) return;
    if ([cell.contentView viewWithTag:kSLRecallBadgeTag]) return;
    UIView *bubble = SLCRBubbleViewIn(cell.contentView);
    if (!bubble) return;
    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
    badge.tag = kSLRecallBadgeTag;
    badge.text = @"已拦截";
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [UIColor colorWithRed:1.0 green:0.29 blue:0.25 alpha:1.0];
    badge.layer.cornerRadius = 7.0;
    badge.layer.masksToBounds = YES;
    CGSize ts = [badge.text sizeWithAttributes:@{NSFontAttributeName: badge.font}];
    CGRect bf = [bubble convertRect:bubble.bounds toView:cell.contentView];
    CGFloat h = 14.0;
    CGFloat w = ts.width + 12.0;
    CGFloat x = bf.origin.x + 3.0;
    CGFloat y = bf.origin.y - h - 2.0;
    if (y < 1.0) y = bf.origin.y + 4.0;          // 顶到 cell 上沿就贴在内侧
    CGFloat maxX = cell.contentView.bounds.size.width - w - 2.0;
    if (x > maxX) x = maxX;
    if (x < 2.0) x = 2.0;
    badge.frame = CGRectMake(x, y, w, h);
    [cell.contentView addSubview:badge];
}

void SLRecallRepaintVisible(void) {
    if (!SLRecallGuardEnabled()) return;
    if (!gSLRecallCache.count) return;
    UIViewController *chat = SLCRChatVC(SLCRTopVC());
    UITableView *tv = chat ? SLCRChatTable(chat.view) : nil;
    if (!tv) {
        SLLog(@"RECALL-REPAINT 没找到聊天列表");
        return;
    }
    // 复用会串：先把上一次贴的标全摘掉，再按当前可见内容重新贴
    for (UITableViewCell *c in tv.visibleCells) {
        UIView *old = [c.contentView viewWithTag:kSLRecallBadgeTag];
        if (old) [old removeFromSuperview];
    }
    NSInteger n = 0;
    for (UITableViewCell *cell in tv.visibleCells) {
        id m = SLCRMessageOf(cell);
        NSString *mid = SLCRMsgidOf(m);
        if (!mid.length) continue;
        NSString *orig = gSLRecallCache[mid];
        if (![orig isKindOfClass:[NSString class]] || !orig.length) continue;
        NSString *shown = SLCRTextAnywhere(cell, 6);
        NSString *trimmed = [shown stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL same = (trimmed.length && [trimmed isEqualToString:orig]);
        if (!same) {
            id dataItem = nil;
            @try { dataItem = [cell valueForKey:@"dataItem"]; } @catch (NSException *e) { }
            gSLCRPatchBudget = 500;
            NSString *how = SLCRTryRebindCell(cell, dataItem);
            [cell setNeedsLayout];
            [cell layoutIfNeeded];
            // 重绑之后还留着「撤回」这种提示字的话，按形态直接换成原文
            if (trimmed.length && ![trimmed isEqualToString:orig]) {
                SLCRPatchLabelsInView(cell, trimmed, orig, nil, NULL);
                SLCRPatchLayers(cell.layer, trimmed, orig, nil, 5);
            }
            if (gSLRecallRepaintLog < 8) {
                gSLRecallRepaintLog += 1;
                SLLog(@"RECALL-REPAINT %@ 重绑=%@ 前=[%@] 后=[%@]", mid, how,
                      SLCRPreview(trimmed, 12),
                      SLCRPreview(SLCRTextAnywhere(cell, 4), 12));
            }
            n += 1;
        }
        SLRecallAttachBadge(cell);
    }
    if (n && gSLRecallRepaintLog < 12) {
        gSLRecallRepaintLog += 1;
        SLLog(@"RECALL-REPAINT 共重绘 %ld 条", (long)n);
    }
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
