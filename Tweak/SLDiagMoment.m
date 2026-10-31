#import "SLDiagMoment.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import "SLLog.h"

// 轮询周期与次数：1.2s × 500 ≈ 10 分钟，足够覆盖一次完整拍摄流程
static const NSInteger kSLDMTickLimit = 500;
static const NSTimeInterval kSLDMInterval = 1.2;

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

// 只看 AVPlayerLayer：这是「视频/预览填充方式」的唯一真相
static NSString *SLDMLayerFacts(CALayer *layer) {
    if (!layer) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (CALayer *sub in layer.sublayers) {
        if ([sub isKindOfClass:NSClassFromString(@"AVPlayerLayer")]) {
            AVPlayerLayer *pl = (AVPlayerLayer *)sub;
            [parts addObject:[NSString stringWithFormat:@"<AVPlayerLayer %@ %.0fx%.0f>",
                              pl.videoGravity ?: @"?", sub.bounds.size.width, sub.bounds.size.height]];
        }
    }
    return [parts componentsJoinedByString:@" "];
}

static void SLDMWalk(UIView *view, NSInteger depth, NSInteger *budget,
                     NSMutableArray *lines, CGFloat screenArea) {
    if (!view || *budget <= 0 || depth > 14) return;
    *budget -= 1;

    CGRect f = CGRectNull;
    NSString *cls = NSStringFromClass([view class]);
    NSMutableArray *tags = [NSMutableArray array];

    @try {
        f = view.frame;
        if (view.hidden) [tags addObject:@"hidden"];
        if (view.alpha < 0.99f) [tags addObject:[NSString stringWithFormat:@"a=%.2f", view.alpha]];

        if ([view isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)view).image;
            [tags addObject:[NSString stringWithFormat:@"img=%.0fx%.0f", img.size.width, img.size.height]];
            [tags addObject:[NSString stringWithFormat:@"cm=%@", SLDMContentModeName(view.contentMode)]];
        }

        NSString *layerFacts = SLDMLayerFacts(view.layer);
        if (layerFacts.length) [tags addObject:layerFacts];

        // 接近正方形且占屏面积不小 → 很可能是「取景框」或「成片画布」
        if (f.size.width > 40 && f.size.height > 40 && screenArea > 0) {
            CGFloat ratio = f.size.width / f.size.height;
            if (fabs(ratio - 1.0) < 0.06 && f.size.width * f.size.height > screenArea * 0.05) {
                [tags addObject:@"[SQUARE]"];
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

    for (UIView *sub in view.subviews) {
        if (*budget <= 0) break;
        SLDMWalk(sub, depth + 1, budget, lines, screenArea);
    }
}

static UIWindow *SLDMTopWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
            if (!fallback && !w.hidden) fallback = w;
        }
    }
    return fallback;
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

static void SLDMDumpNow(UIWindow *window, NSString *reason) {
    if (!window) return;
    gSLDMDumps += 1;
    if (gSLDMDumps > 8) return;

    UIViewController *vc = SLDMVisibleVC(window.rootViewController);
    CGRect winBounds = window.bounds;
    // 注意：UIWindow.screen 在 iOS 13 起弃用，-Werror 下直接用会编译失败，改走 windowScene
    CGFloat scale = 0.0;
    @try { scale = window.windowScene.screen.scale; } @catch (NSException *e) {}
    SLLog(@"DIAG-MOMENT #%ld %@", (long)gSLDMDumps, reason ?: @"");
    SLLog(@"DIAG-MOMENT window %.0fx%.0f scale=%.2f", winBounds.size.width, winBounds.size.height, scale);

    // 整条控制器链（判断是不是模态盖了一层）
    NSMutableArray *chain = [NSMutableArray array];
    UIViewController *cur = window.rootViewController;
    NSInteger guard = 0;
    while (cur && guard < 12) {
        [chain addObject:NSStringFromClass([cur class])];
        cur = cur.presentedViewController;
        guard += 1;
    }
    SLLog(@"DIAG-MOMENT vcchain %@", [chain componentsJoinedByString:@" -> "]);

    if (vc && vc.viewIfLoaded) {
        CGRect vf = vc.viewIfLoaded.frame;
        SLLog(@"DIAG-MOMENT topVC=%@ view=(%.0f,%.0f %.0fx%.0f) safeTop=%.0f safeBottom=%.0f",
              NSStringFromClass([vc class]), vf.origin.x, vf.origin.y, vf.size.width, vf.size.height,
              vc.viewIfLoaded.safeAreaInsets.top, vc.viewIfLoaded.safeAreaInsets.bottom);
    }

    NSMutableArray *lines = [NSMutableArray array];
    NSInteger budget = 200;
    SLDMWalk(window, 0, &budget, lines, winBounds.size.width * winBounds.size.height);

    for (NSString *line in lines) SLLog(@"DIAG-MOMENT | %@", line);
    SLLog(@"DIAG-MOMENT end (%lu lines, budget left %ld)", (unsigned long)lines.count, (long)budget);
}

static BOOL SLDMIsMomentPage(NSString *name) {
    if (!name.length) return NO;
    NSArray *keys = @[@"Moment", @"Record", @"Camera", @"Album", @"Thumb", @"Publish", @"Snap"];
    for (NSString *k in keys) {
        if ([name containsString:k]) return YES;
    }
    return NO;
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
        UIWindow *window = SLDMTopWindow();
        UIViewController *vc = SLDMVisibleVC(window.rootViewController);
        NSString *name = vc ? NSStringFromClass([vc class]) : nil;

        if (SLDMIsMomentPage(name) && ![gSLDMDoneKeys containsObject:name]) {
            [gSLDMDoneKeys addObject:name];
            // 等布局稳定再抓，立刻抓会拿到 0 尺寸
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SLDMDumpNow(SLDMTopWindow(), [NSString stringWithFormat:@"enter %@", name]);
            });
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
