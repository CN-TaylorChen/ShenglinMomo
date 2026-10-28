//
//  SLGlass.m
//  见 SLGlass.h 的说明：把设置页那套玻璃材质 + 胶囊控件抽成全站基座。
//

#import "SLGlass.h"

#pragma mark - 材质

UIColor *SLGlassCellColor(void) {
    // 与设置页 / 语音包页同一个数：深色 6% 白提亮，浅色 34% 白压住。
    // 深了会把底下的毛玻璃盖死（看着像白板），浅了文字对比度又不够。
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.06]
            : [UIColor colorWithWhite:1.0 alpha:0.34];
    }];
}

// 发丝高光边：玻璃的「厚度」全靠这一圈，0.8pt 以上就成画框了。
UIColor *SLGlassHairlineColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.16]
            : [UIColor colorWithWhite:1.0 alpha:0.55];
    }];
}

// 胶囊外壳：超薄毛玻璃 + 全圆角 + 发丝边，与设置页标题胶囊同一套参数。
static UIVisualEffectView *SLMakePillShell(CGRect frame) {
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    v.frame = frame;
    v.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.masksToBounds = YES;
    v.layer.borderWidth = 0.8;
    v.layer.borderColor = SLGlassHairlineColor().CGColor;
    v.userInteractionEnabled = NO;   // 触摸要落到外壳底下的按钮上
    return v;
}

#pragma mark - 表格 / 页面

void SLApplyGlassTable(UITableView *tv) {
    if (!tv) return;
    // 表格自身透明，底下的浮窗毛玻璃才能透上来（原来铺 systemGroupedBackground 会全盖住）
    tv.backgroundColor = [UIColor clearColor];
    UIVisualEffectView *veil = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    tv.backgroundView = veil;
}

UIVisualEffectView *SLInstallGlassBackdrop(UIView *host) {
    if (!host) return nil;
    host.backgroundColor = [UIColor clearColor];
    UIVisualEffectView *veil = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    veil.frame = host.bounds;
    veil.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    veil.userInteractionEnabled = NO;
    [host insertSubview:veil atIndex:0];
    return veil;
}

#pragma mark - 胶囊控件

// v0.4.51：这一层原来直接是 UIButton + setTitle:forState: / setImage:forState:。
// 装进导航栏后文字和图标一起消失，只剩一颗空胶囊（语音包页的「＋」也是空的）。
// 原因是 iOS 15 起按钮一旦带 UIButtonConfiguration，老 API 会被整体忽略，
// 于是只有我们 insertSubview 插进去的毛玻璃外壳还在、titleLabel / imageView 都不画。
// 现在改成「容器 + UILabel / UIImageView + 透明 UIControl 收点击」，完全不走
// UIButton 的文字图片渲染路径，configuration 那套就绕开了。
static UIControl *SLMakePillHit(CGRect bounds, id target, SEL action) {
    UIControl *hit = [[UIControl alloc] initWithFrame:bounds];
    hit.backgroundColor = [UIColor clearColor];
    if (target && action) {
        [hit addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
    return hit;
}

UIBarButtonItem *SLPillBarItem(NSString *title, id target, SEL action) {
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CGSize ts = [title sizeWithAttributes:@{NSFontAttributeName: font}];
    CGFloat h = 32.0;
    CGFloat w = ceil(ts.width) + 26.0;   // 左右各 13pt

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    UIVisualEffectView *shell = SLMakePillShell(box.bounds);
    [box addSubview:shell];

    UILabel *lab = [[UILabel alloc] initWithFrame:shell.bounds];
    lab.text = title;
    lab.font = font;
    lab.textColor = [UIColor labelColor];
    lab.textAlignment = NSTextAlignmentCenter;
    [shell.contentView addSubview:lab];

    // 点击层最后加，压在最上面：透明但对触摸有效，文字跟着一起可点。
    [box addSubview:SLMakePillHit(box.bounds, target, action)];
    return [[UIBarButtonItem alloc] initWithCustomView:box];
}

UIBarButtonItem *SLPillIconBarItem(NSString *systemName, NSString *fallbackTitle, id target, SEL action) {
    if (!systemName.length) return SLPillBarItem(fallbackTitle ?: @"返回", target, action);

    CGFloat h = 32.0;
    CGFloat w = 40.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    UIVisualEffectView *shell = SLMakePillShell(box.bounds);
    [box addSubview:shell];

    CGFloat side = 17.0;
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:systemName]];
    iv.tintColor = [UIColor labelColor];    // 显式给色，避免被导航栏 tint 冲掉
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.frame = CGRectMake((w - side) / 2.0, (h - side) / 2.0, side, side);
    [shell.contentView addSubview:iv];

    [box addSubview:SLMakePillHit(box.bounds, target, action)];
    return [[UIBarButtonItem alloc] initWithCustomView:box];
}

UIView *SLPillTitleView(NSString *text) {
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CGSize ts = [text sizeWithAttributes:@{NSFontAttributeName: font}];
    CGFloat H = 24.0;
    CGFloat padX = 12.0;
    CGFloat tw = ceil(ts.width);
    CGFloat W = tw + padX * 2.0;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    UIVisualEffectView *pill = SLMakePillShell(box.bounds);
    [box addSubview:pill];

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(padX, (H - ceil(ts.height)) / 2.0, tw, ceil(ts.height))];
    lab.text = text;
    lab.font = font;
    lab.textColor = [UIColor labelColor];
    [pill.contentView addSubview:lab];
    return box;
}
