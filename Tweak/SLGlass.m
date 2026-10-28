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
static UIColor *SLGlassHairline(void) {
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
    v.layer.borderColor = SLGlassHairline().CGColor;
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

UIBarButtonItem *SLPillBarItem(NSString *title, id target, SEL action) {
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    CGSize ts = [title sizeWithAttributes:@{NSFontAttributeName: font}];
    CGFloat h = 32.0;
    CGFloat w = ceil(ts.width) + 26.0;   // 左右各 13pt

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(0, 0, w, h);
    [btn setTitle:title forState:UIControlStateNormal];
    // 用 setTitle + titleLabel.font 而不是 attributedTitle：动态色只有走这条路才会
    // 随深 / 浅色切换自动重解，attributed 里的 labelColor 是赋值那一刻的颜色。
    btn.titleLabel.font = font;
    [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [btn insertSubview:SLMakePillShell(btn.bounds) atIndex:0];
    return [[UIBarButtonItem alloc] initWithCustomView:btn];
}

UIBarButtonItem *SLPillIconBarItem(NSString *systemName, NSString *fallbackTitle, id target, SEL action) {
    if (!systemName.length) return SLPillBarItem(fallbackTitle ?: @"返回", target, action);

    CGFloat h = 32.0;
    CGFloat w = 40.0;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(0, 0, w, h);
    [btn setImage:[UIImage systemImageNamed:systemName] forState:UIControlStateNormal];
    btn.tintColor = [UIColor labelColor];
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [btn insertSubview:SLMakePillShell(btn.bounds) atIndex:0];
    return [[UIBarButtonItem alloc] initWithCustomView:btn];
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
