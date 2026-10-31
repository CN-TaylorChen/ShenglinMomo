//
//  SLDiagMoment.m
//  声临 · 陌陌版 —— 实拍时刻「图片被放大」只读诊断器
//
//  v0.5.00 修正三处致命缺陷（v0.4.96 连抓两次都抓成聊天页的原因）：
//   1. 原来从 UIWindow 开始遍历 → 相机页在另一个 window（pass-through / 浮层窗口）上，
//      主 window 的聊天 UITableView 先把 200 行预算吃光，相机视图树一行都没打到。
//      现在直接从 topVC.view 出发。
//   2. 原来只认 AVPlayerLayer，漏了 AVCaptureVideoPreviewLayer —— 实拍取景用的正是后者。
//      现在递归扫 sublayers，两种都打，并且打 videoGravity。
//   3. 原来按类名去重只抓一次，而刚 push 进去时视频层还没挂。
//      现在每类抓两次（进入 + 1.6s），并且开头给一段摘要块，一眼能看完关键层。
//

#import "SLDiagMoment.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import "SLLog.h"

// 轮询周期与次数：1.2s × 500 ≈ 10 分钟，足够覆盖一次完整拍摄流程
static const NSInteger kSLDMTickLimit = 500;
static const NSTimeInterval kSLDMInterval = 1.2;
static const NSInteger kSLDMMaxDumps = 10;

static NSInteger gSLDMTicks = 0;
static NSInteger gSLDMDumps = 0;
static NSMutableSet *gSLDMDoneKeys = nil;

static NSString *SLDMContentModeName(UIViewContentMode m) {
    switch (m) {
        case UIViewContentModeScaleToFill:    return @"ScaleToFill";
        case UIViewContentModeScaleAspectFit: return @"AspectFit";
        case UIViewContentModeScaleAspectFill:return @"AspectFill";
        case UIViewContentModeCenter:         return @"Center";
        case UIViewContentModeTop:            return @"Top";
        case UIViewContentModeBottom:         return @"Bottom";
        case UIViewContentModeLeft:           return @"Left";
        case UIViewContentModeRight:          return @"Right";
        default: return [NSString stringWithFormat:@"mode%ld", (long)m];
    }
}

#pragma mark - 视频层扫描

// 递归扫 sublayers：AVCaptureVideoPreviewLayer（取景）与 AVPlayerLayer（回放）都要看，
// videoGravity 就是「画面怎么被塞进这一层」的唯一真相。
// 每个命中层都带上宿主 view 与它在屏幕上的实际位置 —— 放大是几何问题，光看尺寸不够。
static void SLDMLayerScan(CALayer *layer, NSInteger depth, NSString *path,
                          NSMutableArray *lines, NSInteger *hits) {
    if (!layer || depth > 10) return;

    Class playerCls = NSClassFromString(@"AVPlayerLayer");
    Class captureCls = NSClassFromString(@"AVCaptureVideoPreviewLayer");
    NSString *fact = nil;

    if (playerCls && [layer isKindOfClass:playerCls]) {
        AVPlayerLayer *pl = (AVPlayerLayer *)layer;
        fact = [NSString stringWithFormat:@"<AVPlayerLayer %.0fx%.0f gravity=%@ videoRect=%.0fx%.0f>",
                layer.bounds.size.width, layer.bounds.size.height,
                pl.videoGravity ?: @"?",
                pl.videoRect.size.width, pl.videoRect.size.height];
    } else if (captureCls && [layer isKindOfClass:captureCls]) {
        AVCaptureVideoPreviewLayer *cl = (AVCaptureVideoPreviewLayer *)layer;
        fact = [NSString stringWithFormat:@"<CAPTURE-PREVIEW %.0fx%.0f gravity=%@ session=%@>",
                layer.bounds.size.width, layer.bounds.size.height,
                cl.videoGravity ?: @"?", cl.session ? @"yes" : @"no"];
    }

    if (fact) {
        *hits += 1;
        UIView *host = nil;
        if ([layer.delegate isKindOfClass:[UIView class]]) host = (UIView *)layer.delegate;
        NSString *where = @"";
        if (host) {
            CGRect inWin = [host convertRect:layer.bounds toView:nil];
            where = [NSString stringWithFormat:@" host=%@ win=(%.0f,%.0f %.0fx%.0f)",
                     NSStringFromClass([host class]),
                     inWin.origin.x, inWin.origin.y, inWin.size.width, inWin.size.height];
        }
        [lines addObject:[NSString stringWithFormat:@"LAYER %@ %@%@", path ?: @"?", fact, where]];
    }

    NSString *cls = NSStringFromClass([layer class]);
    NSString *next = path.length ? [path stringByAppendingFormat:@".%@", cls] : cls;
    for (CALayer *sub in layer.sublayers) {
        SLDMLayerScan(sub, depth + 1, next, lines, hits);
    }
}

#pragma mark - 视图树遍历

typedef struct {
    NSInteger budget;
    NSInteger nodes;
    CGFloat screenArea;
} SLDMWalkState;

static void SLDMWalk(UIView *view, NSInteger depth, SLDMWalkState *st,
                     NSMutableArray *lines, NSMutableArray *images, NSMutableArray *squares) {
    if (!view || st->budget <= 0 || depth > 16) return;
    st->budget -= 1;
    st->nodes += 1;

    CGRect f = CGRectZero;
    NSString *cls = NSStringFromClass([view class]);
    NSMutableArray *tags = [NSMutableArray array];

    @try {
        f = view.frame;
        if (view.hidden) [tags addObject:@"hidden"];
        if (view.alpha < 0.99f) [tags addObject:[NSString stringWithFormat:@"a=%.2f", view.alpha]];
        if (view.clipsToBounds) [tags addObject:@"clip"];

        if ([view isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)view).image;
            [tags addObject:[NSString stringWithFormat:@"img=%.0fx%.0f", img.size.width, img.size.height]];
            [tags addObject:[NSString stringWithFormat:@"cm=%@", SLDMContentModeName(view.contentMode)]];
            [tags addObject:[NSString stringWithFormat:@"grav=%@", view.layer.contentsGravity ?: @"?"]];
            // 摘要候选：面积 + 描述，最后取最大的三个
            CGFloat area = f.size.width * f.size.height;
            if (area > 2000.0 && img.size.width > 0) {
                [images addObject:@{
                    @"area": @(area),
                    @"text": [NSString stringWithFormat:@"%@ %.0fx%.0f img=%.0fx%.0f cm=%@ grav=%@",
                              cls, f.size.width, f.size.height,
                              img.size.width, img.size.height,
                              SLDMContentModeName(view.contentMode),
                              view.layer.contentsGravity ?: @"?"],
                }];
            }
        }

        // 视频层不在这里扫：根 view 的 layer 树已经包含所有子 view 的 layer，
        // 每个节点都扫一遍只会把同一层重复打印 N 次（见 SLDMDumpNow 里的 <root> 扫描）。

        // 接近正方形且占屏面积不小 → 「取景框」或「成片画布」
        if (f.size.width > 40 && f.size.height > 40 && st->screenArea > 0) {
            CGFloat ratio = f.size.width / f.size.height;
            if (fabs(ratio - 1.0) < 0.06 && f.size.width * f.size.height > st->screenArea * 0.05) {
                [tags addObject:@"[SQUARE]"];
                [squares addObject:[NSString stringWithFormat:@"%@ %.0fx%.0f", cls, f.size.width, f.size.height]];
            }
        }
    } @catch (NSException *e) {
        [tags addObject:@"<read-fail>"];
    }

    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    [lines addObject:[NSString stringWithFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f)%@",
                      pad, cls,
                      f.origin.x, f.origin.y, f.size.width, f.size.height,
                      tags.count ? [@"  " stringByAppendingString:[tags componentsJoinedByString:@" "]] : @""]];

    // 列表类只记骨架：聊天页的 cell 会把预算全吃掉（v0.4.96 就是死在这）
    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)view;
        NSInteger rows = -1;
        @try { rows = [tv numberOfRowsInSection:0]; } @catch (NSException *e) { }
        NSInteger vis = (NSInteger)tv.indexPathsForVisibleRows.count;
        [lines addObject:[NSString stringWithFormat:@"%@  [TABLE rows=%ld visible=%ld]", pad, (long)rows, (long)vis]];
        NSInteger n = 0;
        for (UITableViewCell *c in tv.visibleCells) {
            if (n++ >= 4) break;
            [lines addObject:[NSString stringWithFormat:@"%@    · %@ (%.0f,%.0f %.0fx%.0f)", pad,
                              NSStringFromClass([c class]), c.frame.origin.x, c.frame.origin.y,
                              c.frame.size.width, c.frame.size.height]];
        }
        return;
    }
    if ([view isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)view;
        [lines addObject:[NSString stringWithFormat:@"%@  [COLLECTION visible=%ld]", pad,
                          (long)cv.indexPathsForVisibleItems.count]];
        return;
    }

    for (UIView *sub in view.subviews) {
        if (st->budget <= 0) break;
        SLDMWalk(sub, depth + 1, st, lines, images, squares);
    }
}

#pragma mark - 取顶层

static NSArray<UIWindow *> *SLDMWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.hidden) [out addObject:w];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel < b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

static NSArray<NSString *> *SLDMAllWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            [out addObject:[NSString stringWithFormat:@"%@%@ lvl=%.0f%.0fx%.0f",
                            NSStringFromClass([w class]),
                            w.isKeyWindow ? @"(key)" : (w.hidden ? @"(hidden)" : @""),
                            w.windowLevel, w.bounds.size.width, w.bounds.size.height]];
        }
    }
    return out;
}

static UIViewController *SLDMVisibleVC(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController) return SLDMVisibleVC(vc.presentedViewController);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return SLDMVisibleVC(((UINavigationController *)vc).topViewController);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return SLDMVisibleVC(((UITabBarController *)vc).selectedViewController);
    }
    return vc;
}

#pragma mark - dump

// 上一次抓到的是「主 window 的聊天页」，而相机页根本不在那棵树里。
// 现在把所有 window 都扫一遍：每个 window 的可见 VC 各打一棵树，预算按 window 平摊。
static void SLDMDumpWindow(UIWindow *w, NSUInteger idx, NSInteger budget,
                           NSMutableArray *images, NSMutableArray *squares,
                           NSInteger *totalNodes) {
    UIViewController *vc = SLDMVisibleVC(w.rootViewController);
    UIView *root = vc.viewIfLoaded;
    if (!root) {
        SLLog(@"DIAG-MOMENT W%lu %@ topVC=%@ (没有 view，跳过)",
              (unsigned long)idx, NSStringFromClass([w class]),
              vc ? NSStringFromClass([vc class]) : @"nil");
        return;
    }

    SLLog(@"DIAG-MOMENT W%lu %@ lvl=%.0f %.0fx%.0f", (unsigned long)idx,
          NSStringFromClass([w class]), w.windowLevel, w.bounds.size.width, w.bounds.size.height);
    SLLog(@"DIAG-MOMENT W%lu topVC=%@", (unsigned long)idx,
          vc ? NSStringFromClass([vc class]) : @"nil");

    CGRect vf = root.frame;
    SLLog(@"DIAG-MOMENT W%lu view=(%.0f,%.0f %.0fx%.0f) safeTop=%.0f safeBottom=%.0f",
          (unsigned long)idx, vf.origin.x, vf.origin.y, vf.size.width, vf.size.height,
          root.safeAreaInsets.top, root.safeAreaInsets.bottom);

    NSMutableArray *lines = [NSMutableArray array];

    // 根 view 的 layer 树已经包含所有子 view 的 layer，扫一遍就够
    NSInteger layerHits = 0;
    SLDMLayerScan(root.layer, 0, NSStringFromClass([root class]), lines, &layerHits);
    if (layerHits == 0) {
        [lines addObject:@"LAYER 无 AVPlayerLayer / AVCaptureVideoPreviewLayer"];
    }

    SLDMWalkState st;
    st.budget = budget;
    st.nodes = 0;
    st.screenArea = w.bounds.size.width * w.bounds.size.height;
    SLDMWalk(root, 0, &st, lines, images, squares);

    for (NSString *line in lines) SLLog(@"DIAG-MOMENT W%lu | %@", (unsigned long)idx, line);
    SLLog(@"DIAG-MOMENT W%lu 结束（节点 %ld，预算余 %ld）", (unsigned long)idx,
          (long)st.nodes, (long)st.budget);
    *totalNodes += st.nodes;
}

static void SLDMDumpNow(NSString *reason) {
    gSLDMDumps += 1;
    if (gSLDMDumps > kSLDMMaxDumps) return;

    NSArray<UIWindow *> *wins = SLDMWindows();
    SLLog(@"DIAG-MOMENT #%ld %@", (long)gSLDMDumps, reason ?: @"");
    SLLog(@"DIAG-MOMENT window 共 %lu 个: %@", (unsigned long)wins.count,
          [SLDMAllWindows() componentsJoinedByString:@" | "]);

    NSMutableArray *images = [NSMutableArray array];
    NSMutableArray *squares = [NSMutableArray array];
    NSInteger totalNodes = 0;
    NSUInteger n = wins.count < 4 ? wins.count : 4;
    for (NSUInteger i = 0; i < n; i++) {
        @try {
            SLDMDumpWindow(wins[i], i, 90, images, squares, &totalNodes);
        } @catch (NSException *e) {
            SLLog(@"DIAG-MOMENT W%lu dump 异常 %@", (unsigned long)i, e.reason);
        }
    }

    // ---- 摘要块：先看这三段就够定位「谁把图放大了」----
    [images sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"area"] compare:a[@"area"]];
    }];
    NSMutableArray *topImages = [NSMutableArray array];
    NSUInteger lim = images.count < 3 ? images.count : 3;
    for (NSUInteger i = 0; i < lim; i++) [topImages addObject:images[i][@"text"]];
    SLLog(@"DIAG-MOMENT SUM 最大的图: %@", topImages.count ? [topImages componentsJoinedByString:@" ## "] : @"无");
    SLLog(@"DIAG-MOMENT SUM 方形视图 %lu 个: %@", (unsigned long)squares.count,
          squares.count ? [squares componentsJoinedByString:@" , "] : @"无");
    SLLog(@"DIAG-MOMENT end (共 %ld 个节点)", (long)totalNodes);
}

#pragma mark - 轮询

static BOOL SLDMIsMomentPage(NSString *name) {
    if (!name.length) return NO;
    NSArray *keys = @[@"Moment", @"Record", @"Camera", @"Album", @"Thumb", @"Publish", @"Snap", @"Edit"];
    for (NSString *k in keys) {
        if ([name containsString:k]) return YES;
    }
    return NO;
}

// 遍历所有 window 找命中页：相机页可能在独立 window（浮层窗口）上，只看 keyWindow 会漏
static UIViewController *SLDMFindMomentVC(void) {
    for (UIWindow *w in SLDMWindows()) {
        UIViewController *vc = SLDMVisibleVC(w.rootViewController);
        if (vc && SLDMIsMomentPage(NSStringFromClass([vc class]))) return vc;
    }
    return nil;
}

static void SLDMTick(void);

static void SLDMScheduleNextTick(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSLDMInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SLDMTick();
    });
}

static void SLDMTick(void) {
    gSLDMTicks += 1;
    if (gSLDMTicks > kSLDMTickLimit) return;

    @try {
        UIViewController *hit = SLDMFindMomentVC();
        NSString *name = hit ? NSStringFromClass([hit class]) : nil;

        if (name.length) {
            NSString *k1 = [name stringByAppendingString:@"#1"];
            NSString *k2 = [name stringByAppendingString:@"#2"];
            BOOL need1 = ![gSLDMDoneKeys containsObject:k1];
            BOOL need2 = ![gSLDMDoneKeys containsObject:k2];

            if (need1) {
                [gSLDMDoneKeys addObject:k1];
                // 立刻抓一次：抓「刚进来」的样子（此时视频层可能还没挂）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    SLDMDumpNow([NSString stringWithFormat:@"enter %@ (+0.15s)", name]);
                });
            }
            if (need2) {
                [gSLDMDoneKeys addObject:k2];
                // 再抓一次：等布局 / 预览层稳定（这一份才是主证据）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIViewController *now = SLDMFindMomentVC();
                    NSString *nowName = now ? NSStringFromClass([now class]) : nil;
                    if (![nowName isEqualToString:name]) {
                        SLLog(@"DIAG-MOMENT 跳过 +1.6s 抓取：当前命中 %@", nowName ?: @"nil");
                        return;
                    }
                    SLDMDumpNow([NSString stringWithFormat:@"enter %@ (+1.6s)", name]);
                });
            }
        }
    } @catch (NSException *e) {
        SLLog(@"DIAG-MOMENT tick exception %@", e.reason);
    }

    SLDMScheduleNextTick();
}

void SLDiagMomentInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    if (!gSLDMDoneKeys) gSLDMDoneKeys = [NSMutableSet set];

    SLLog(@"DIAG-MOMENT watcher armed (%.1fs x %ld)", kSLDMInterval, (long)kSLDMTickLimit);
    SLDMScheduleNextTick();
}
