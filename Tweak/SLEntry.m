#import "SLEntry.h"
#import "SLSettingsPanel.h"
#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "AWECAUtils.h"
#import <PhotosUI/PhotosUI.h>

// ===================== 悬浮球图标 =====================
// v0.4.33：默认图标换成「双声波」品牌图形（代码绘制，黑底 + 六根条：
// 左三根 30% 白表示被替换掉的原声，右三根纯白表示合成声）。
// 存一个字符串：
//   brand            品牌图形（默认）
//   emoji:🎙️        表情
//   image:icon.png   相册选的自定义图片（已裁成圆形，存沙盒）
//   text:xxx         旧版遗留值，读取时自动迁移成默认
#define kSLFloatIconKey @"SLFloatIcon"
#define kSLFloatIconDefault @"brand"

static NSString *SLFloatIconDir(void) {
    NSString *dir = [[AWECAUtils documentsPath] stringByAppendingPathComponent:@"ShenglinMomo/float"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

static NSString *SLFloatIconImagePath(NSString *name) {
    return [SLFloatIconDir() stringByAppendingPathComponent:(name.length ? name : @"icon.png")];
}

static NSString *SLFloatIconValue(void) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLFloatIconKey];
    if (!v.length) return kSLFloatIconDefault;
    if ([v hasPrefix:@"text:"]) return kSLFloatIconDefault;        // 旧版文字图标 → 默认
    if ([v isEqualToString:@"emoji:🎙️"]) return kSLFloatIconDefault;  // 旧默认表情 → 新品牌图形
    return v;
}

NSString *SLFloatIconSummary(void) {
    NSString *v = SLFloatIconValue();
    if ([v isEqualToString:kSLFloatIconDefault]) return @"默认";
    if ([v hasPrefix:@"image:"]) return @"自定义图片";
    if ([v hasPrefix:@"emoji:"]) return [v substringFromIndex:6];
    return @"默认";
}

// 品牌图形：黑底圆 + 六根圆角条。100 单位为画布基准，跟设计稿一一对应，
// 线条宽度、间距、条高都按比例缩放，48pt 球和 20pt 标题栏图标是同一张图。
static UIImage *SLBrandIcon(CGFloat side, UIColor *bg) {
    if (side <= 0) side = 96;
    UIColor *base = bg ?: [UIColor blackColor];
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetFillColorWithColor(c, base.CGColor);
        CGContextFillEllipseInRect(c, CGRectMake(0, 0, side, side));
        CGFloat u = side / 100.0;
        CGFloat xs[6] = {20, 30, 40, 54, 64, 74};
        CGFloat hs[6] = {16, 26, 20, 22, 32, 24};
        CGFloat as[6] = {0.30, 0.30, 0.30, 1.0, 1.0, 1.0};
        for (int i = 0; i < 6; i++) {
            CGFloat w = 6.0 * u;
            CGFloat h = hs[i] * u;
            CGRect bar = CGRectMake(xs[i] * u, (side - h) / 2.0, w, h);
            [[UIColor colorWithWhite:1.0 alpha:as[i]] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:w / 2.0] fill];
        }
    }];
}

UIImage *SLBrandIconImage(CGFloat side) {
    return SLBrandIcon(side, nil);
}

// v0.4.34：只有六根条、没有底色圆的版本，给毛玻璃悬浮球当图形用。
// 前半段 30% 不透明度（被替换掉的原声）、后半段实心（合成声），跟圆形版一致。
static UIImage *SLBrandGlyphImage(CGFloat side, UIColor *color) {
    if (side <= 0) side = 44;
    UIColor *c = color ?: [UIColor labelColor];
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGFloat u = side / 100.0;
        CGFloat xs[6] = {20, 30, 40, 54, 64, 74};
        CGFloat hs[6] = {16, 26, 20, 22, 32, 24};
        CGFloat as[6] = {0.30, 0.30, 0.30, 1.0, 1.0, 1.0};
        for (int i = 0; i < 6; i++) {
            CGFloat w = 6.0 * u;
            CGFloat h = hs[i] * u;
            CGRect bar = CGRectMake(xs[i] * u, (side - h) / 2.0, w, h);
            [[c colorWithAlphaComponent:as[i]] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:w / 2.0] fill];
        }
    }];
}

UIImage *SLBrandIconImageTinted(CGFloat side, UIColor *bg) {
    return SLBrandIcon(side, bg);
}

// 把任意图片居中裁成圆形（直接当 backgroundImage 用，省得给按钮加裁剪打断阴影）
static UIImage *SLCircleIcon(UIImage *src) {
    if (!src) return nil;
    CGSize s = CGSizeMake(120, 120);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextAddEllipseInRect(c, CGRectMake(0, 0, s.width, s.height));
        CGContextClip(c);
        CGFloat iw = src.size.width, ih = src.size.height;
        if (iw <= 0 || ih <= 0) return;
        CGFloat sc = MAX(s.width / iw, s.height / ih);
        CGRect dst = CGRectMake((s.width - iw * sc) / 2.0, (s.height - ih * sc) / 2.0, iw * sc, ih * sc);
        [src drawInRect:dst];
    }];
}

static BOOL SLSaveFloatIconImage(UIImage *img) {
    UIImage *c = SLCircleIcon(img);
    NSData *d = c ? UIImagePNGRepresentation(c) : nil;
    if (!d.length) return NO;
    if (![d writeToFile:SLFloatIconImagePath(@"icon.png") atomically:YES]) return NO;
    [[NSUserDefaults standardUserDefaults] setObject:@"image:icon.png" forKey:kSLFloatIconKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
}

static void SLApplyFloatIcon(UIButton *btn);
static NSString *SLFloatPackName(void);   // 胶囊上显示的当前语音包名

// ===================== 浮动入口 =====================

#define SLBtnTag 20931

// ===================== 设置 / 语音包浮窗 =====================
// v0.4.33：设置页不再用 PageSheet 从底部整页推上来，改成一张固定尺寸的
// 圆角毛玻璃浮窗，浮在陌陌界面中间。尺寸写死，只有窗内内容能滚动。
// v0.4.34：语音包也住进同一个容器（原先还是 PageSheet，跟设置页两套观感）。

@interface SLFloatPanelController : UIViewController
+ (void)presentFrom:(UIViewController *)host root:(UIViewController *)root;
+ (void)presentSettingsFrom:(UIViewController *)host;
+ (void)presentVoicePackFrom:(UIViewController *)host;
@end

// ===================== 悬浮球：毛玻璃 + 三态 + 长按胶囊 =====================
// v0.4.34：
//   1) 球体换成毛玻璃（SystemMaterial + 0.5pt 白描边），图形跟着深浅色反色，不再是一块黑斑；
//   2) 三态：录音红环呼吸 / 合成蓝弧转圈 / 就绪整圈合拢，由 Tweak.x 的钩子驱动；
//   3) 长按球 → 横向展开成胶囊（显示当前语音包名并停住）；
//      胶囊上再长按 → 弹语音包浮窗；单击胶囊 → 收回成球；单击球 → 进设置。
//      语音包界面只有「胶囊形态下长按」这一条入口。

#define SLBallSide 48.0

@interface SLFloatButton : UIButton
@property (nonatomic, assign) BOOL slExpanded;
@property (nonatomic, assign) SLFloatState slState;
- (void)sl_loadIcon;
- (void)sl_applyState:(SLFloatState)state;
- (void)sl_expand:(BOOL)expanded animated:(BOOL)animated;
@end

@implementation SLFloatButton {
    UIVisualEffectView *_chrome;
    UIView *_tint;
    UIImageView *_glyph;
    UIImageView *_thumb;
    UILabel *_emoji;
    UIView *_sep;
    UILabel *_name;
    UIImageView *_chev;
    CAShapeLayer *_ring;
    CAShapeLayer *_ringArc;
    CFTimeInterval _longPressAt;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.20;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        _chrome = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        _chrome.userInteractionEnabled = NO;
        _chrome.layer.cornerRadius = SLBallSide / 2.0;
        _chrome.layer.cornerCurve = kCACornerCurveContinuous;
        _chrome.layer.borderWidth = 0.5;
        _chrome.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        _chrome.clipsToBounds = YES;
        [self addSubview:_chrome];

        _tint = [[UIView alloc] initWithFrame:CGRectZero];
        _tint.userInteractionEnabled = NO;
        _tint.alpha = 0.0;
        [self addSubview:_tint];

        _glyph = [[UIImageView alloc] initWithFrame:CGRectZero];
        _glyph.contentMode = UIViewContentModeScaleAspectFit;
        _glyph.userInteractionEnabled = NO;
        [self addSubview:_glyph];

        _thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.userInteractionEnabled = NO;
        [self addSubview:_thumb];

        _emoji = [[UILabel alloc] initWithFrame:CGRectZero];
        _emoji.textAlignment = NSTextAlignmentCenter;
        _emoji.font = [UIFont systemFontOfSize:22];
        _emoji.userInteractionEnabled = NO;
        [self addSubview:_emoji];

        _sep = [[UIView alloc] initWithFrame:CGRectZero];
        _sep.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.3];
        [self addSubview:_sep];

        _name = [[UILabel alloc] initWithFrame:CGRectZero];
        _name.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        _name.textColor = [UIColor labelColor];
        _name.lineBreakMode = NSLineBreakByTruncatingTail;
        _name.userInteractionEnabled = NO;
        [self addSubview:_name];

        _chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
        _chev.contentMode = UIViewContentModeScaleAspectFit;
        _chev.tintColor = [UIColor secondaryLabelColor];
        [self addSubview:_chev];

        _ring = [CAShapeLayer layer];
        _ring.fillColor = nil;
        _ring.lineWidth = 2.0;
        _ring.hidden = YES;
        [self.layer addSublayer:_ring];

        _ringArc = [CAShapeLayer layer];
        _ringArc.fillColor = nil;
        _ringArc.lineWidth = 2.0;
        _ringArc.lineCap = kCALineCapRound;
        _ringArc.hidden = YES;
        [self.layer addSublayer:_ringArc];

        [self addTarget:self action:@selector(sl_tap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sl_pan:)];
        [self addGestureRecognizer:pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(sl_longPress:)];
        lp.minimumPressDuration = 0.45;
        lp.allowableMovement = 12;   // 拖动换位置时不会误触
        [self addGestureRecognizer:lp];

        [self sl_loadIcon];
        [self sl_applyState:SLFloatStateIdle];
    }
    return self;
}

#pragma mark 图标

- (void)sl_loadIcon {
    NSString *v = SLFloatIconValue();
    _glyph.hidden = YES;
    _thumb.hidden = YES;
    _emoji.hidden = YES;

    UIImage *img = nil;
    if ([v hasPrefix:@"image:"]) {
        img = [UIImage imageWithContentsOfFile:SLFloatIconImagePath([v substringFromIndex:6])];
        if (!img) v = kSLFloatIconDefault;
    }
    if (img) {
        _thumb.image = img;
        _thumb.hidden = NO;
    } else if ([v hasPrefix:@"emoji:"]) {
        _emoji.text = [v substringFromIndex:6];
        _emoji.hidden = NO;
    } else {
        _glyph.image = [SLBrandGlyphImage(44, [UIColor blackColor]) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _glyph.tintColor = [UIColor labelColor];
        _glyph.hidden = NO;
    }
    _name.text = SLFloatPackName();
    [self setNeedsLayout];
}

#pragma mark 状态

- (void)sl_applyState:(SLFloatState)state {
    self.slState = state;
    UIColor *accent = nil;
    if (state == SLFloatStateRecording) accent = [UIColor systemRedColor];
    else if (state == SLFloatStateSynthesizing || state == SLFloatStateReady) accent = [UIColor systemBlueColor];

    _tint.backgroundColor = accent ? [accent colorWithAlphaComponent:0.16] : [UIColor clearColor];
    _tint.alpha = accent ? 1.0 : 0.0;
    _glyph.tintColor = accent ?: [UIColor labelColor];
    _emoji.alpha = 1.0;
    _name.textColor = accent ?: [UIColor labelColor];

    [_ring removeAllAnimations];
    [_ringArc removeAllAnimations];
    _ring.strokeColor = (accent ?: [UIColor clearColor]).CGColor;
    _ringArc.strokeColor = [UIColor systemBlueColor].CGColor;

    if (state == SLFloatStateRecording) {
        _ring.strokeEnd = 1.0;
        _ring.hidden = self.slExpanded;
        _ringArc.hidden = YES;
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @(1.0);
        pulse.toValue = @(0.3);
        pulse.duration = 0.72;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        [_ring addAnimation:pulse forKey:@"pulse"];
    } else if (state == SLFloatStateSynthesizing) {
        _ring.hidden = YES;
        _ringArc.hidden = self.slExpanded;
        _ringArc.strokeStart = 0.0;
        _ringArc.strokeEnd = 0.28;
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(M_PI * 2.0);
        spin.duration = 0.95;
        spin.repeatCount = HUGE_VALF;
        [_ringArc addAnimation:spin forKey:@"spin"];
    } else if (state == SLFloatStateReady) {
        _ring.strokeEnd = 1.0;
        _ring.hidden = self.slExpanded;
        _ringArc.hidden = YES;
    } else {
        _ring.hidden = YES;
        _ringArc.hidden = YES;
        _ring.strokeEnd = 0;
    }
    [self setNeedsLayout];
}

#pragma mark 展开 / 收起

- (CGSize)sl_pillSize {
    [_name sizeToFit];
    CGFloat tw = MIN(_name.bounds.size.width, 92.0);
    CGFloat w = 55.0 + MAX(tw, 26.0) + 26.0;
    return CGSizeMake(MIN(MAX(w, 122.0), 184.0), SLBallSide);
}

- (void)sl_expand:(BOOL)expanded animated:(BOOL)animated {
    if (self.slExpanded == expanded) return;
    if (expanded) _name.text = SLFloatPackName();
    self.slExpanded = expanded;

    CGSize target = expanded ? [self sl_pillSize] : CGSizeMake(SLBallSide, SLBallSide);
    CGRect f = self.frame;
    CGRect nf = f;
    nf.size = target;
    // 贴右边就向左长，贴左边就向右长，尽量不越出屏幕
    BOOL growLeft = NO;
    if (self.superview) growLeft = (CGRectGetMidX(f) > CGRectGetMidX(self.superview.bounds));
    if (growLeft) nf.origin.x = CGRectGetMaxX(f) - target.width;
    if (self.superview) {
        CGFloat minX = 6.0, maxX = CGRectGetWidth(self.superview.bounds) - 6.0;
        if (CGRectGetMaxX(nf) > maxX) nf.origin.x = maxX - target.width;
        if (nf.origin.x < minX) nf.origin.x = minX;
    }

    void (^apply)(void) = ^{
        self.frame = nf;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut animations:apply completion:nil];
    } else {
        apply();
    }
    [self sl_applyState:self.slState];
}

#pragma mark 手势

- (void)sl_pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
        [g setTranslation:CGPointZero inView:self.superview];
        NSString *pos = NSStringFromCGPoint(self.center);
        [[NSUserDefaults standardUserDefaults] setObject:pos forKey:@"SLFloatPos"];
    }
}

- (void)sl_tap {
    // 长按刚结束时个别机型还会补一次 touchUpInside，这里挡掉，免得胶囊一展开就被收回
    if (CFAbsoluteTimeGetCurrent() - _longPressAt < 0.5) return;
    if (self.slExpanded) {   // 胶囊：单击只收回，避免误进设置
        [self sl_expand:NO animated:YES];
        return;
    }
    UIViewController *top = [AWECAUtils topViewController];
    if (!top) return;
    [SLFloatPanelController presentSettingsFrom:top];
}

- (void)sl_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    _longPressAt = CFAbsoluteTimeGetCurrent();
    if (!self.slExpanded) {   // 第一次长按：展开成胶囊并停住
        [self sl_expand:YES animated:YES];
        return;
    }
    // 胶囊形态下再长按：这才是语音包入口
    [self sl_expand:NO animated:YES];
    UIViewController *top = [AWECAUtils topViewController];
    if (!top) return;
    [SLFloatPanelController presentVoicePackFrom:top];
}

#pragma mark 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat h = SLBallSide;
    CGFloat top = (CGRectGetHeight(b) - h) / 2.0;
    BOOL exp = self.slExpanded;

    _chrome.frame = CGRectMake(0, top, CGRectGetWidth(b), h);
    _chrome.layer.cornerRadius = h / 2.0;

    CGFloat iconS = exp ? 34.0 : h;
    CGFloat iconY = top + (h - iconS) / 2.0;
    _glyph.frame = exp ? CGRectMake(8.0 + (34.0 - 18.0) / 2.0, top + (h - 18.0) / 2.0, 18.0, 18.0)
                       : CGRectMake((CGRectGetWidth(b) - 22.0) / 2.0, (CGRectGetHeight(b) - 22.0) / 2.0, 22.0, 22.0);
    _thumb.frame = exp ? CGRectMake(8.0, iconY, iconS, iconS)
                       : CGRectMake((CGRectGetWidth(b) - h) / 2.0, top, h, h);
    _thumb.layer.cornerRadius = MIN(CGRectGetWidth(_thumb.bounds), CGRectGetHeight(_thumb.bounds)) / 2.0;
    _emoji.frame = exp ? CGRectMake(8.0, iconY, iconS, iconS) : CGRectMake(0, top, CGRectGetWidth(b), h);

    _tint.frame = exp ? CGRectMake(0, top, 48.0, h) : CGRectMake(0, top, CGRectGetWidth(b), h);
    _tint.layer.cornerRadius = CGRectGetWidth(_tint.bounds) / 2.0;

    _sep.frame = CGRectMake(47.0, top + (h - 18.0) / 2.0, 0.5, 18.0);
    _name.frame = CGRectMake(55.0, top, CGRectGetWidth(b) - 55.0 - 22.0, h);
    _chev.frame = CGRectMake(CGRectGetWidth(b) - 17.0, top + (h - 10.0) / 2.0, 10.0, 10.0);
    _sep.hidden = !exp;
    _name.hidden = !exp;
    _chev.hidden = !exp;

    CGFloat cx = CGRectGetWidth(b) / 2.0;
    CGFloat cy = CGRectGetHeight(b) / 2.0;
    CGFloat r = (h - 3.0) / 2.0;
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy) radius:r
                                                    startAngle:-M_PI_2
                                                      endAngle:-M_PI_2 + M_PI * 2.0
                                                     clockwise:YES];
    _ring.path = path.CGPath;
    _ringArc.path = path.CGPath;
    if (exp || self.slState == SLFloatStateIdle) _ring.hidden = YES;
    if (exp || self.slState != SLFloatStateSynthesizing) _ringArc.hidden = YES;
}

@end

@interface SLFloatPanelController ()
@property (nonatomic, strong) UIControl *dim;
@property (nonatomic, strong) UIView *cardWrap;
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) UIViewController *rootVC;
@end

@implementation SLFloatPanelController

+ (void)presentFrom:(UIViewController *)host root:(UIViewController *)root {
    if (!host || !root) return;
    // 已经有浮窗开着就不叠第二层，避免连点两次出现两张卡片
    if (host.presentedViewController) return;
    SLFloatPanelController *vc = [[SLFloatPanelController alloc] init];
    vc.rootVC = root;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:vc animated:YES completion:nil];
}

+ (void)presentSettingsFrom:(UIViewController *)host {
    [self presentFrom:host root:[[SLSettingsPanel alloc] init]];
}

+ (void)presentVoicePackFrom:(UIViewController *)host {
    [self presentFrom:host root:[[SLVoicePackController alloc] init]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // 背板：轻压暗，点空白处收起。不做全黑，背后的聊天内容还要看得见
    self.dim = [[UIControl alloc] initWithFrame:CGRectZero];
    self.dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.16];
    [self.dim addTarget:self action:@selector(sl_dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dim];

    // 尺寸在 viewWillLayoutSubviews 里算：viewDidLoad 时 bounds 还没定下来
    self.cardWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.cardWrap.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardWrap.layer.shadowOpacity = 0.22;
    self.cardWrap.layer.shadowRadius = 24;
    self.cardWrap.layer.shadowOffset = CGSizeMake(0, 10);
    [self.view addSubview:self.cardWrap];

    self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    self.blur.layer.cornerRadius = 26;
    self.blur.layer.cornerCurve = kCACornerCurveContinuous;
    self.blur.clipsToBounds = YES;
    [self.cardWrap addSubview:self.blur];

    SLSettingsPanel *root = [[SLSettingsPanel alloc] init];
    self.nav = [[UINavigationController alloc] initWithRootViewController:(self.rootVC ?: root)];
    self.nav.view.backgroundColor = [UIColor clearColor];
    [self addChildViewController:self.nav];
    [self.blur.contentView addSubview:self.nav.view];
    [self.nav didMoveToParentViewController:self];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGSize ss = self.view.bounds.size;
    if (ss.width < 1.0 || ss.height < 1.0) return;
    self.dim.frame = self.view.bounds;
    // 宽度留 12pt 边，高度固定占屏幕 66%（上限 560），不做拖拽
    CGFloat w = MIN(ss.width - 24.0, 380.0);
    CGFloat h = MIN(ss.height * 0.66, 560.0);
    CGRect r = CGRectMake(round((ss.width - w) / 2.0), round((ss.height - h) / 2.0) - 18.0, w, h);
    if (!CGRectEqualToRect(self.cardWrap.frame, r)) self.cardWrap.frame = r;
    self.blur.frame = self.cardWrap.bounds;
    self.nav.view.frame = self.blur.contentView.bounds;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.cardWrap.alpha = 0.0;
    self.cardWrap.transform = CGAffineTransformMakeScale(0.94, 0.94);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.cardWrap.alpha = 1.0;
        self.cardWrap.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)sl_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// 胶囊上显示的当前语音包名（没选就写「未选语音包」，省得胶囊空着一条）
static NSString *SLFloatPackName(void) {
    NSDictionary *pack = [SLVoicePack activePack];
    NSString *n = pack[@"name"];
    return n.length ? n : @"未选语音包";
}

// 按当前设置把图标套到按钮上
static void SLApplyFloatIcon(UIButton *btn) {
    if (![btn isKindOfClass:[SLFloatButton class]]) return;
    [(SLFloatButton *)btn sl_loadIcon];
}

// v0.4.34：三态入口。Tweak.x 在录音 / 合成钩子里调用，界面只改颜色和环，不做任何业务判断。
static __weak SLFloatButton *sSLFloatBtn = nil;

void SLFloatSetState(SLFloatState state) {
    // 录音 / 合成的钩子不一定在主线程，碰 UI 一律回主队列
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SLFloatSetState(state); });
        return;
    }
    SLFloatButton *b = sSLFloatBtn;
    if (!b) return;
    [b sl_applyState:state];
    if (state == SLFloatStateReady) {
        // 就绪只是「亮一下」，1.6 秒后自己退回空闲
        __weak SLFloatButton *wb = b;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLFloatButton *bb = wb;
            if (bb && bb.slState == SLFloatStateReady) [bb sl_applyState:SLFloatStateIdle];
        });
    }
}

// 浮窗内部是子控制器，点「完成」时先向上找真正的呈现者
void SLCloseHostingPanel(UIViewController *vc) {
    if (!vc) return;
    UIViewController *c = vc;
    while (c && !c.presentingViewController) c = c.parentViewController;
    if (c) [c dismissViewControllerAnimated:YES completion:nil];
    else [vc dismissViewControllerAnimated:YES completion:nil];
}

// iOS15 SDK 起 -[UIApplication windows] 被弃用，工程开了 -Werror，这里局部抑制并优先走场景 API
static UIWindow *SLKeyWindow(void) {
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

void SLRefreshFloatButton(void) {
    SLFloatButton *btn = sSLFloatBtn;
    if (!btn) {
        UIWindow *w = SLKeyWindow();
        btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
    }
    SLApplyFloatIcon(btn);
}

void SLEnsureFloatButton(void) {
    UIWindow *w = SLKeyWindow();
    if (!w) return;
    SLFloatButton *btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
    if (!btn) {
        NSString *pos = [[NSUserDefaults standardUserDefaults] objectForKey:@"SLFloatPos"];
        CGPoint c = pos.length ? CGPointFromString(pos) : CGPointMake(w.bounds.size.width - 36, w.bounds.size.height * 0.55);
        if (c.x < 10 || c.x > w.bounds.size.width - 10) c.x = w.bounds.size.width - 36;
        if (c.y < 120 || c.y > w.bounds.size.height - 160) c.y = w.bounds.size.height * 0.55;
        btn = [[SLFloatButton alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        btn.center = c;
        btn.tag = SLBtnTag;
        [w addSubview:btn];
        NSLog(@"SL-MOMO: float button mounted at %@", NSStringFromCGPoint(c));
        SLPackPrewarm();   // v0.4.34：启动后就把当前语音包解好，第一次录音也不用等
    }
    sSLFloatBtn = btn;
}


// 不用 hook UIViewController：主队列定时检查并挂载（低侵入，避免 Logos 多 hook 嵌套坑）
void SLStartEntryWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(1.0 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            @try { SLEnsureFloatButton(); } @catch (NSException *e) {}
        });
        dispatch_resume(timer);
        @try { SLEnsureFloatButton(); } @catch (NSException *e) {}
    });
}

#pragma mark - 图标选择页

@interface SLFloatIconController () <PHPickerViewControllerDelegate>
@end

@implementation SLFloatIconController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"悬浮球图标";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(sl_done)];
}

- (void)sl_done {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (NSArray<NSString *> *)sl_emojiItems {
    return @[@"🎙️", @"🔊", @"✨", @"🐻", @"🌸", @"🎀"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 1;   // v0.4.9：删掉表情预设，只留自定义图片
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    (void)section;
    return 2;   // 从相册选择 / 恢复默认
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    (void)section;
    return @"自定义图标";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"icon";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:rid];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.text = nil;

    NSString *cur = SLFloatIconValue();
    if (ip.row == 0) {
        cell.textLabel.text = @"从相册选择图片";
        cell.detailTextLabel.text = [cur hasPrefix:@"image:"] ? @"已设置" : @"";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text = @"恢复默认图标";
        if ([cur isEqualToString:kSLFloatIconDefault]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (ip.row == 0) {
        [self sl_pickPhoto];
        return;
    }
    [d setObject:kSLFloatIconDefault forKey:kSLFloatIconKey];
    [d synchronize];
    [[NSFileManager defaultManager] removeItemAtPath:SLFloatIconImagePath(@"icon.png") error:nil];
    [self sl_applied];
}

// 自定义表情：弹框输入，最多取前 2 个组合字符（emoji 由多个 code point 组成，不能按字节切）
- (void)sl_askCustomEmoji {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自定义表情"
                                                               message:@"输入一个表情或 1~2 个字符，显示在悬浮球上"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"🎙️";
        tf.textAlignment = NSTextAlignmentCenter;
        tf.font = [UIFont systemFontOfSize:22];
        NSString *cur = SLFloatIconValue();
        if ([cur hasPrefix:@"emoji:"]) tf.text = [cur substringFromIndex:6];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *v = [ws sl_firstChars:ac.textFields.firstObject.text count:2];
        if (!v.length) {
            [AWECAUtils showToast:@"至少输入一个字符" duration:1.5];
            return;
        }
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:[@"emoji:" stringByAppendingString:v] forKey:kSLFloatIconKey];
        [d synchronize];
        [ws sl_applied];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSString *)sl_firstChars:(NSString *)text count:(NSUInteger)count {
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, n = 0;
    while (i < t.length && n < count) {
        NSRange r = [t rangeOfComposedCharacterSequenceAtIndex:i];
        if (r.length == 0) break;
        [out appendString:[t substringWithRange:r]];
        i = r.location + r.length;
        n++;
    }
    return out;
}

- (void)sl_applied {
    SLRefreshFloatButton();
    [self.tableView reloadData];
    [AWECAUtils showToast:@"图标已更新" duration:1.2];
}

- (void)sl_pickPhoto {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    vc.delegate = self;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *p = results.firstObject.itemProvider;
    if (![p canLoadObjectOfClass:[UIImage class]]) {
        [AWECAUtils showToast:@"这张图片读不出来" duration:1.5];
        return;
    }
    __weak typeof(self) ws = self;
    [p loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *img = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
            if (img && SLSaveFloatIconImage(img)) {
                [ws sl_applied];
            } else {
                [AWECAUtils showToast:@"保存失败，换一张试试" duration:1.5];
            }
        });
    }];
}

@end
