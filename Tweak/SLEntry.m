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

UIImage *SLBrandIconImageTinted(CGFloat side, UIColor *bg) {
    return SLBrandIcon(side, bg);
}

// v0.4.36：小尺寸专用的四根条。
// 六根在 48pt 的球里挤成一片，前三根 30% 不透明度几乎看不见（看着像残缺的均衡器）。
// 这一版只留四根、条加粗到 10 单位：左边两根淡（被替换的原声），右边两根实心（合成声）。
static UIImage *SLBrandGlyphCompact(CGFloat side, UIColor *color) {
    if (side <= 0) side = 44;
    UIColor *c = color ?: [UIColor labelColor];
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGFloat u = side / 100.0;
        CGFloat xs[4] = {12, 34, 56, 78};   // 12..88，整体居中
        CGFloat hs[4] = {24, 40, 28, 46};
        CGFloat as[4] = {0.30, 0.30, 1.0, 1.0};
        for (int i = 0; i < 4; i++) {
            CGFloat w = 10.0 * u;
            CGFloat h = hs[i] * u;
            CGRect bar = CGRectMake(xs[i] * u, (side - h) / 2.0, w, h);
            [[c colorWithAlphaComponent:as[i]] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:w / 2.0] fill];
        }
    }];
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

// ===================== 悬浮球：毛玻璃 + 呼吸光晕 + 胶囊下拉 =====================
// v0.4.36 交互重排（用户定稿）：
//   单击球 → 变成胶囊；再单击胶囊（右端箭头除外）→ 收回成球；
//   单击胶囊右端箭头 → 胶囊正下方展开语音包列表（含「原声」一行）；
//   长按球 → 进设置（长按胶囊不做事）。
// 状态：空闲灰白光晕 2.8s / 录音红 0.9s / 合成蓝 1.4s / 就绪蓝常亮到发送完成。
// 就绪不再自动回空闲，发出去的那一刻外扩一圈涟漪再回空闲。

#define SLBallSide 48.0
#define SLPillMaxW 196.0

// v0.4.37：浮窗内导航栏整体下压的留白（设置页 / 语音包页 / 地图页统一）
static const CGFloat kSLPanelTopPad = 14.0;

@interface SLFloatButton : UIButton
@property (nonatomic, assign) BOOL slExpanded;
@property (nonatomic, assign) SLFloatState slState;
- (void)sl_loadIcon;
- (void)sl_applyState:(SLFloatState)state;
- (void)sl_expand:(BOOL)expanded animated:(BOOL)animated;
@end

// v0.4.36：胶囊下方展开的语音包列表（点胶囊右端才出现）。
// 挂在窗口上，和胶囊同一套毛玻璃；点一行即切换，点空白收起。
@interface SLPackMenu : UIView
+ (void)showFromAnchor:(UIView *)anchor;
@end

@interface SLPackMenuRow : UIControl
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UIImageView *check;
@end

@implementation SLPackMenuRow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];

        _title = [[UILabel alloc] initWithFrame:CGRectZero];
        _title.font = [UIFont systemFontOfSize:14.0];
        _title.textColor = [UIColor labelColor];
        _title.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _title.userInteractionEnabled = NO;
        [self addSubview:_title];

        _check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
        _check.contentMode = UIViewContentModeScaleAspectFit;
        _check.tintColor = [UIColor systemBlueColor];
        _check.hidden = YES;
        _check.userInteractionEnabled = NO;
        [self addSubview:_check];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat h = CGRectGetHeight(b);
    // v0.4.37：列表收窄到和胶囊同宽（196），左右内距跟着收紧，把宽度让给文件名
    _icon.frame = CGRectMake(12, (h - 16.0) / 2.0, 16, 16);
    _check.frame = CGRectMake(CGRectGetWidth(b) - 10 - 14, (h - 14.0) / 2.0, 14, 14);
    CGFloat tw = CGRectGetMinX(_check.frame) - 8.0 - 36.0;
    _title.frame = CGRectMake(36, 0, MAX(0, tw), h);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [[UIColor labelColor] colorWithAlphaComponent:0.07] : [UIColor clearColor];
}

@end

@implementation SLFloatButton {
    UIView *_glassHost;
    UIVisualEffectView *_chrome;
    CAShapeLayer *_glassMask;
    UIView *_tint;
    UIImageView *_glyph;
    UIImageView *_thumb;
    UILabel *_emoji;
    UIView *_sep;
    UILabel *_name;
    UIButton *_menuBtn;
    UIImageView *_chev;
    CAShapeLayer *_haloIn;
    CAShapeLayer *_haloOut;
    CAShapeLayer *_pulse;
    UIView *_readyDot;
    CFTimeInterval _longPressAt;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 9;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        // v0.4.36：呼吸光晕。两层同心描边，透明度缓慢交替，球和胶囊共用一条路径
        // （胶囊就是「圆角 = 高一半」的矩形，同一份代码两种情况都成立）。
        _haloOut = [CAShapeLayer layer];
        _haloOut.fillColor = nil;
        _haloOut.lineWidth = 2.0;
        _haloOut.opacity = 0.0;
        [self.layer addSublayer:_haloOut];

        _haloIn = [CAShapeLayer layer];
        _haloIn.fillColor = nil;
        _haloIn.lineWidth = 3.0;
        _haloIn.opacity = 0.0;
        [self.layer addSublayer:_haloIn];

        // v0.4.37：发送完成不再外扩涟漪（那圈会「甩」出去，且位置一歪就很丑），
        // 改成原地光晕脉冲：只在 halo 那一圈上闪一下透明度，全程无位移。
        _pulse = [CAShapeLayer layer];
        _pulse.fillColor = nil;
        _pulse.lineWidth = 3.0;
        _pulse.opacity = 0.0;
        [self.layer addSublayer:_pulse];

        // 玻璃层尺寸固定成最大胶囊，只靠 mask 改外形。
        // 之前让 UIVisualEffectView 跟着 48→196 改宽高，系统按圆形重新采样，
        // 右端会留下一块白圆残影（截图里那个白圆片就是它）。
        _glassHost = [[UIView alloc] initWithFrame:CGRectZero];
        _glassHost.userInteractionEnabled = NO;
        _glassHost.layer.borderWidth = 0.5;
        _glassHost.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
        _glassMask = [CAShapeLayer layer];
        _glassHost.layer.mask = _glassMask;
        [self addSubview:_glassHost];

        _chrome = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        _chrome.frame = CGRectMake(0, 0, SLPillMaxW, SLBallSide);
        [_glassHost addSubview:_chrome];

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
        _sep.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.28];
        _sep.userInteractionEnabled = NO;
        [self addSubview:_sep];

        _name = [[UILabel alloc] initWithFrame:CGRectZero];
        _name.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        _name.textColor = [UIColor labelColor];
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _name.userInteractionEnabled = NO;
        [self addSubview:_name];

        // 右端箭头是独立按钮：只有它弹语音包列表，胶囊其他位置点了就收回成球
        _menuBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _menuBtn.frame = CGRectZero;
        [_menuBtn addTarget:self action:@selector(sl_menuTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_menuBtn];

        _chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
        _chev.contentMode = UIViewContentModeScaleAspectFit;
        _chev.tintColor = [UIColor secondaryLabelColor];
        _chev.userInteractionEnabled = NO;
        [_menuBtn addSubview:_chev];

        // 就绪小蓝点：状态常亮时一直在，提醒「这次说的是包里那条」
        _readyDot = [[UIView alloc] initWithFrame:CGRectZero];
        _readyDot.backgroundColor = [UIColor systemBlueColor];
        _readyDot.layer.borderWidth = 1.5;
        _readyDot.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
        _readyDot.layer.cornerRadius = 4.5;
        _readyDot.hidden = YES;
        _readyDot.userInteractionEnabled = NO;
        [self addSubview:_readyDot];

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
        // 48pt 里六根条太密，前 3 根 30% 的几乎看不见，糊成一团。
        // 球和胶囊上换成四根（两淡两实）、条更粗；大尺寸仍用六根。
        _glyph.image = [SLBrandGlyphCompact(44, [UIColor blackColor]) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _glyph.tintColor = [UIColor labelColor];
        _glyph.hidden = NO;
    }
    _name.text = SLFloatPackName();
    [self setNeedsLayout];
}

#pragma mark 状态

- (void)sl_applyState:(SLFloatState)state {
    SLFloatState prev = self.slState;
    self.slState = state;

    UIColor *accent = nil;
    if (state == SLFloatStateRecording) accent = [UIColor systemRedColor];
    else if (state == SLFloatStateSynthesizing || state == SLFloatStateReady) accent = [UIColor systemBlueColor];

    // v0.4.37：状态色加深到 26% 并铺满整条胶囊（见 layout 里的 _tint.frame），
    // 过渡用 0.26s 淡入淡出，避免蓝 → 白硬切。
    UIColor *fill = accent ? [accent colorWithAlphaComponent:0.26] : [UIColor clearColor];
    [UIView animateWithDuration:0.26 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_tint.backgroundColor = fill;
        self->_tint.alpha = accent ? 1.0 : 0.0;
    } completion:nil];
    _sep.backgroundColor = accent ? [accent colorWithAlphaComponent:0.35]
                                  : [UIColor colorWithWhite:0.5 alpha:0.28];
    _glyph.tintColor = accent ?: [UIColor labelColor];
    _name.textColor = accent ?: [UIColor labelColor];
    _readyDot.hidden = (state != SLFloatStateReady);

    UIColor *halo = accent ?: [UIColor colorWithWhite:0.55 alpha:1.0];
    _haloIn.strokeColor = halo.CGColor;
    _haloOut.strokeColor = halo.CGColor;
    [self sl_startBreath:state];

    // 发出去的那一刻：就绪→空闲，原地闪一下蓝光（不位移、不外扩）
    if (prev == SLFloatStateReady && state == SLFloatStateIdle) {
        [self sl_playPulse:[UIColor systemBlueColor]];
    }
    [self setNeedsLayout];
}

- (void)sl_startBreath:(SLFloatState)state {
    [_haloIn removeAllAnimations];
    [_haloOut removeAllAnimations];

    // 半周期时长：一轮完整呼吸 = 2 倍
    CGFloat half = 1.4;      // 空闲 2.8s
    CGFloat a0 = 0.06, a1 = 0.20;   // 空闲只到 0.20，看着「活」但不抢注意力
    if (state == SLFloatStateRecording) {
        half = 0.45; a0 = 0.28; a1 = 0.85;   // 0.9s，急促
    } else if (state == SLFloatStateSynthesizing) {
        half = 0.70; a0 = 0.22; a1 = 0.70;   // 1.4s
    } else if (state == SLFloatStateReady) {
        half = 0.80; a0 = 0.34; a1 = 0.90;   // 1.6s，一直亮到发出去
    }

    CABasicAnimation *in = [CABasicAnimation animationWithKeyPath:@"opacity"];
    in.fromValue = @(a0);
    in.toValue = @(a1);
    in.duration = half;
    in.autoreverses = YES;
    in.repeatCount = HUGE_VALF;
    in.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_haloIn addAnimation:in forKey:@"breath"];

    CABasicAnimation *out = [CABasicAnimation animationWithKeyPath:@"opacity"];
    out.fromValue = @(a0 * 0.42);
    out.toValue = @(a1 * 0.42);
    out.duration = half;
    out.beginTime = CACurrentMediaTime() + half * 0.45;   // 错开相位，两圈不会同步闪
    out.autoreverses = YES;
    out.repeatCount = HUGE_VALF;
    out.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_haloOut addAnimation:out forKey:@"breath"];
}

- (void)sl_playPulse:(UIColor *)color {
    // 只改透明度：0 → 0.85 → 落回 0.28 → 0，0.55s。路径不动，所以不可能出现偏心。
    _pulse.strokeColor = color.CGColor;
    CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    op.values = @[@(0.0), @(0.85), @(0.30), @(0.0)];
    op.keyTimes = @[@(0.0), @(0.16), @(0.52), @(1.0)];
    op.duration = 0.55;
    op.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    op.removedOnCompletion = YES;
    [_pulse addAnimation:op forKey:@"pulse"];
}

#pragma mark 展开 / 收起

- (CGSize)sl_pillSize {
    // v0.4.37：胶囊宽度不再跟着包名长度变，统一撑满 196。
    // 下拉列表要和它严格等宽，宽度固定后两条边才永远共线。
    _name.text = SLFloatPackName();
    return CGSizeMake(SLPillMaxW, SLBallSide);
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
    BOOL growLeft = YES;
    if (self.superview) growLeft = (CGRectGetMidX(f) > CGRectGetMidX(self.superview.bounds));
    if (growLeft) nf.origin.x = CGRectGetMaxX(f) - target.width;
    if (self.superview) {
        CGFloat minX = 6.0, maxX = CGRectGetWidth(self.superview.bounds) - 6.0;
        if (CGRectGetMaxX(nf) > maxX) nf.origin.x = maxX - target.width;
        if (nf.origin.x < minX) nf.origin.x = minX;
    }

    // 直接换尺寸，不做插值：形变过程中玻璃层会被系统重新采样，反而留残影。
    // 手感靠文字淡入补回来。
    self.frame = nf;
    [self setNeedsLayout];
    [self layoutIfNeeded];

    if (animated) {
        _name.alpha = 0.0;
        _sep.alpha = 0.0;
        _chev.alpha = 0.0;
        [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_name.alpha = 1.0;
            self->_sep.alpha = 1.0;
            self->_chev.alpha = 1.0;
        } completion:nil];
    } else {
        _name.alpha = 1.0;
        _sep.alpha = 1.0;
        _chev.alpha = 1.0;
    }
    [self sl_startBreath:self.slState];
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
    // 点球 → 胶囊；点胶囊（右端箭头除外，那个是独立按钮）→ 收回成球
    [self sl_expand:!self.slExpanded animated:YES];
}

- (void)sl_menuTap {
    [SLPackMenu showFromAnchor:self];
}

- (void)sl_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    _longPressAt = CFAbsoluteTimeGetCurrent();
    if (self.slExpanded) return;   // 胶囊上长按不做事
    UIViewController *top = [AWECAUtils topViewController];
    if (!top) return;
    [SLFloatPanelController presentSettingsFrom:top];
}

#pragma mark 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = SLBallSide;
    BOOL exp = self.slExpanded;

    _glassHost.frame = b;
    _glassHost.layer.cornerRadius = h / 2.0;
    _glassHost.layer.cornerCurve = kCACornerCurveContinuous;
    _glassMask.path = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:h / 2.0].CGPath;
    // 玻璃始终是最大尺寸，只靠 mask 露出当前形状，右对齐
    _chrome.frame = CGRectMake(w - SLPillMaxW, 0, SLPillMaxW, h);

    _glyph.frame = exp ? CGRectMake(15.0, (h - 18.0) / 2.0, 18.0, 18.0)
                       : CGRectMake((w - 22.0) / 2.0, (h - 22.0) / 2.0, 22.0, 22.0);
    _glyph.hidden = (_thumb.hidden == NO) || (_emoji.hidden == NO);
    CGFloat iconS = 32.0;
    _thumb.frame = exp ? CGRectMake(8.0, (h - iconS) / 2.0, iconS, iconS) : b;
    _thumb.layer.cornerRadius = MIN(CGRectGetWidth(_thumb.bounds), CGRectGetHeight(_thumb.bounds)) / 2.0;
    _emoji.font = [UIFont systemFontOfSize:(exp ? 17.0 : 22.0)];
    _emoji.frame = exp ? CGRectMake(8.0, (h - iconS) / 2.0, iconS, iconS) : b;

    // v0.4.37：状态色铺满整条胶囊。原来展开态只盖左侧 48pt 圆，
    // 球是蓝的、胶囊还是白玻璃，中间像被切断。
    _tint.frame = b;
    _tint.layer.cornerRadius = h / 2.0;

    _sep.frame = CGRectMake(47.0, (h - 18.0) / 2.0, 0.5, 18.0);
    _name.frame = CGRectMake(56.0, 0, MAX(0, w - 56.0 - 46.0), h);
    _menuBtn.frame = exp ? CGRectMake(w - 46.0, 0, 46.0, h) : CGRectZero;
    _chev.frame = CGRectMake(30.0, (h - 11.0) / 2.0, 11.0, 11.0);
    _readyDot.frame = CGRectMake(w - 14.0, 3.0, 9.0, 9.0);

    _sep.hidden = !exp;
    _name.hidden = !exp;
    _menuBtn.hidden = !exp;

    // 光晕路径：胶囊就是「圆角 = 高一半」的矩形，球是它的特例
    _haloIn.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -2.5, -2.5)
                                              cornerRadius:(h + 5.0) / 2.0].CGPath;
    _haloOut.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -7.0, -7.0)
                                               cornerRadius:(h + 14.0) / 2.0].CGPath;
    _pulse.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -5.0, -5.0)
                                             cornerRadius:(h + 10.0) / 2.0].CGPath;
}

@end

#pragma mark - 胶囊下拉：语音包列表

@implementation SLPackMenu {
    UIControl *_catcher;
    UIView *_card;
    UIVisualEffectView *_blur;
    NSArray<NSDictionary *> *_rows;
}

+ (void)showFromAnchor:(UIView *)anchor {
    UIWindow *win = anchor.window;
    if (!win || !anchor) return;
    SLPackMenu *m = [[SLPackMenu alloc] initWithFrame:win.bounds];
    m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:m];
    [m sl_buildWithAnchor:anchor];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _catcher = [[UIControl alloc] initWithFrame:self.bounds];
        _catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _catcher.backgroundColor = [UIColor clearColor];
        [_catcher addTarget:self action:@selector(sl_dismiss) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_catcher];
    }
    return self;
}

- (void)sl_buildWithAnchor:(UIView *)anchor {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{@"title": @"原声", @"orig": @YES}];
    for (NSDictionary *p in [SLVoicePack allPacks]) {
        [rows addObject:@{@"title": p[@"name"] ?: @"未命名", @"pack": p, @"orig": @NO}];
    }
    _rows = rows;

    // v0.4.37：列表宽度 = 胶囊宽度（方案 A，胶囊固定 196），右端严格对齐，
    // 两条边共线；行高 44、圆角 22 更贴近胶囊的 24。
    CGFloat rowH = 44.0;
    NSUInteger visible = MIN(_rows.count, (NSUInteger)5);

    CGRect ar = [anchor convertRect:anchor.bounds toView:self];
    CGFloat cardW = CGRectGetWidth(ar);
    if (cardW < 120.0) cardW = 196.0;
    CGFloat cardH = visible * rowH + 12.0;

    CGFloat winW = CGRectGetWidth(self.bounds);
    CGFloat winH = CGRectGetHeight(self.bounds);
    CGFloat x = CGRectGetMaxX(ar) - cardW;
    x = MAX(12.0, MIN(x, winW - 12.0 - cardW));
    CGFloat y = CGRectGetMaxY(ar) + 6.0;
    CGFloat safeB = 0;
    if (@available(iOS 11.0, *)) safeB = self.safeAreaInsets.bottom;
    if (y + cardH > winH - safeB - 12.0) y = CGRectGetMinY(ar) - 6.0 - cardH;

    _card = [[UIView alloc] initWithFrame:CGRectMake(x, y, cardW, cardH)];
    _card.layer.cornerRadius = 22.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.20;
    _card.layer.shadowRadius = 20.0;
    _card.layer.shadowOffset = CGSizeMake(0, 8);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:22.0].CGPath;
    [self addSubview:_card];

    // 顶部小三角：对准胶囊右端那个箭头，说明「这是它下面弹出来的」
    UIView *tip = [[UIView alloc] initWithFrame:CGRectMake(cardW - 23.0 - 5.5, -4.5, 11.0, 11.0)];
    if (@available(iOS 13.0, *)) {
        tip.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
                ? [UIColor colorWithWhite:0.20 alpha:0.92]
                : [UIColor colorWithWhite:0.97 alpha:0.92];
        }];
    } else {
        tip.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.92];
    }
    tip.layer.borderWidth = 0.5;
    tip.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    tip.transform = CGAffineTransformMakeRotation(M_PI_4);
    tip.userInteractionEnabled = NO;
    [_card addSubview:tip];

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _blur.frame = _card.bounds;
    _blur.layer.cornerRadius = 22.0;
    _blur.layer.cornerCurve = kCACornerCurveContinuous;
    _blur.clipsToBounds = YES;
    [_card insertSubview:_blur belowSubview:tip];

    UIView *hair = [[UIView alloc] initWithFrame:CGRectInset(_card.bounds, 0.5, 0.5)];
    hair.layer.cornerRadius = 21.5;
    hair.layer.cornerCurve = kCACornerCurveContinuous;
    hair.layer.borderWidth = 0.5;
    hair.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    hair.userInteractionEnabled = NO;
    [_card insertSubview:hair belowSubview:tip];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 6, cardW, cardH - 12)];
    sv.showsVerticalScrollIndicator = NO;
    sv.alwaysBounceVertical = NO;
    [_card insertSubview:sv belowSubview:tip];

    for (NSUInteger i = 0; i < _rows.count; i++) {
        NSDictionary *info = _rows[i];
        SLPackMenuRow *r = [[SLPackMenuRow alloc] initWithFrame:CGRectMake(0, i * rowH, cardW, rowH)];
        r.tag = (NSInteger)i;
        r.title.text = info[@"title"];
        BOOL orig = [info[@"orig"] boolValue];
        NSDictionary *pack = info[@"pack"];

        BOOL on = orig ? [SLVoicePack isOriginalMode] : (![SLVoicePack isOriginalMode] && pack && [SLVoicePack isPackActive:pack]);
        r.check.hidden = !on;
        r.icon.image = [UIImage systemImageNamed:(orig ? @"mic.fill" : @"waveform")];
        r.icon.tintColor = on ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
        r.title.textColor = on ? [UIColor systemBlueColor] : [UIColor labelColor];
        r.title.font = [UIFont systemFontOfSize:14.0 weight:(on ? UIFontWeightSemibold : UIFontWeightRegular)];
        [r addTarget:self action:@selector(sl_rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [sv addSubview:r];

        if (i + 1 < _rows.count) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(36, (i + 1) * rowH - 0.25, cardW - 36 - 12, 0.5)];
            line.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.10];
            line.userInteractionEnabled = NO;
            [sv addSubview:line];
        }
    }
    sv.contentSize = CGSizeMake(cardW, _rows.count * rowH);

    _card.alpha = 0.0;
    _card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    _card.transform = CGAffineTransformTranslate(_card.transform, 0, -6);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_card.alpha = 1.0;
        self->_card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)sl_rowTapped:(SLPackMenuRow *)row {
    if (row.tag < 0 || row.tag >= (NSInteger)_rows.count) return;
    NSDictionary *info = _rows[(NSUInteger)row.tag];
    if ([info[@"orig"] boolValue]) {
        [SLVoicePack setOriginalMode:YES];
        [SLVoicePack setEnabled:YES];
        [AWECAUtils showToast:@"原声：这次用你自己录的" duration:1.8];
    } else {
        NSDictionary *pack = info[@"pack"];
        [SLVoicePack setOriginalMode:NO];
        [SLVoicePack selectPack:pack];
        [SLVoicePack setEnabled:YES];
        SLPackPrewarm();
        [AWECAUtils showToast:[NSString stringWithFormat:@"已选「%@」", pack[@"name"] ?: @""] duration:1.6];
    }
    SLRefreshFloatButton();
    [self sl_dismiss];
}

- (void)sl_dismiss {
    [UIView animateWithDuration:0.14 animations:^{
        self->_card.alpha = 0.0;
        self->_card.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
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
    // v0.4.37：导航栏原来紧贴卡片圆角顶（搜索栏顶只低 2pt，压着弧线），
    // 整体下压 14pt；设置页、语音包页、地图页共用这一个容器，顶部留白自动统一。
    CGRect navF = self.blur.contentView.bounds;
    self.nav.view.frame = CGRectMake(navF.origin.x, navF.origin.y + kSLPanelTopPad,
                                     navF.size.width, MAX(0.0, navF.size.height - kSLPanelTopPad));
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

// 胶囊上显示的当前选择（原声 / 语音包名）
static NSString *SLFloatPackName(void) {
    if ([SLVoicePack isOriginalMode]) return @"原声";
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
    // v0.4.36：就绪不再 1.6 秒后自己退回空闲 —— 它要一直亮着，
    // 直到语音真正发出去（发送完成那一刻会走 Ready → Idle，顺带外扩一圈涟漪）。
    [b sl_applyState:state];
}

// 浮窗内部是子控制器，点「完成」时先向上找真正的呈现者
void SLCloseHostingPanel(UIViewController *vc) {
    if (!vc) return;
    UIViewController *c = vc;
    while (c && !c.presentingViewController) c = c.parentViewController;
    if (c) [c dismissViewControllerAnimated:YES completion:nil];
    else [vc dismissViewControllerAnimated:YES completion:nil];
}

// 键盘 / 状态栏 / 文本特效这些私有窗口不能挂球：挂上去要么看不见，要么跟着窗口一起消失
static BOOL SLIsSystemOverlayWindow(UIWindow *w) {
    NSString *cn = NSStringFromClass([w class]);
    if (cn.length == 0) return NO;
    return [cn containsString:@"TextEffects"] || [cn containsString:@"Keyboard"]
        || [cn containsString:@"StatusBar"] || [cn containsString:@"Selection"];
}

// iOS15 SDK 起 -[UIApplication windows] 被弃用，工程开了 -Werror，这里局部抑制并优先走场景 API。
// v0.4.37：不再只认 ForegroundActive + isKeyWindow。陌陌启动早期常是启动页 / 广告窗，
// 球挂上去那窗一关就跟着没了；另一种是球被更高层的窗压住，viewWithTag 还能找到，
// 于是永不重建、也永不可见。现在改成「所有场景里挑最顶层且可见的那个窗」，球永远住最上面。
static UIWindow *SLKeyWindow(void) {
    NSMutableArray<UIWindow *> *list = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (!w || w.hidden || w.alpha < 0.02) continue;
                if (SLIsSystemOverlayWindow(w)) continue;
                [list addObject:w];
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (list.count == 0) {
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw && !kw.hidden && !SLIsSystemOverlayWindow(kw)) [list addObject:kw];
        id del = [UIApplication sharedApplication].delegate;
        if ([del respondsToSelector:NSSelectorFromString(@"window")]) {
            id dw = [del valueForKey:@"window"];
            if ([dw isKindOfClass:[UIWindow class]]) {
                UIWindow *w = (UIWindow *)dw;
                if (!w.hidden && ![list containsObject:w]) [list addObject:w];
            }
        }
    }
#pragma clang diagnostic pop
    UIWindow *best = nil;
    for (UIWindow *w in list) {
        if (!best) { best = w; continue; }
        if (w.windowLevel > best.windowLevel) { best = w; continue; }
        if (w.windowLevel < best.windowLevel) continue;
        // 同层级：先看 keyWindow，再看面积（主窗口总是最大的，别把球挂到某个小浮窗上）
        if (w.isKeyWindow != best.isKeyWindow) {
            if (w.isKeyWindow) best = w;
        } else {
            CGSize a = w.bounds.size, b = best.bounds.size;
            if (a.width * a.height > b.width * b.height) best = w;
        }
    }
    return best;
}

void SLRefreshFloatButton(void) {
    SLFloatButton *btn = sSLFloatBtn;
    if (!btn) {
        UIWindow *w = SLKeyWindow();
        btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
    }
    SLApplyFloatIcon(btn);
}

static CGPoint SLClampFloatPos(CGPoint c, CGSize size) {
    if (c.x < 24.0 || c.x > size.width - 24.0) c.x = size.width - 36.0;
    if (c.y < 120.0 || c.y > size.height - 160.0) c.y = size.height * 0.55;
    return c;
}

void SLEnsureFloatButton(void) {
    UIWindow *w = SLKeyWindow();
    if (!w) {
        // 一直拿不到窗口就静默失败了，下次再出现「没有球」根本查不到原因 —— 限频记一条
        static CFAbsoluteTime last = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last > 30.0) {
            last = now;
            SLLog(@"SL-MOMO: no host window yet, float button not mounted");
        }
        return;
    }
    SLFloatButton *btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
    if (!btn) btn = sSLFloatBtn;   // 可能还挂在已经被换下去的旧窗口上
    if (btn && btn.superview != w) {
        // v0.4.37：窗口被换（启动页 / 广告窗关掉、场景重建）时把球迁到新的顶层窗口，
        // 否则球跟着旧窗一起消失，而且在新窗口里找不到 tag、只能等下次冷启动。
        [btn removeFromSuperview];
        btn.center = SLClampFloatPos(btn.center, w.bounds.size);
        [w addSubview:btn];
        SLLog(@"SL-MOMO: float button moved to top window (%@)", NSStringFromClass([w class]));
    }
    if (!btn) {
        NSString *pos = [[NSUserDefaults standardUserDefaults] objectForKey:@"SLFloatPos"];
        CGPoint c = pos.length ? CGPointFromString(pos) : CGPointMake(w.bounds.size.width - 36, w.bounds.size.height * 0.55);
        c = SLClampFloatPos(c, w.bounds.size);
        btn = [[SLFloatButton alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        btn.center = c;
        btn.tag = SLBtnTag;
        [w addSubview:btn];
        SLLog(@"SL-MOMO: float button mounted at %@", NSStringFromCGPoint(c));
        SLPackPrewarm();   // v0.4.34：启动后就把当前语音包解好，第一次录音也不用等
    }
    sSLFloatBtn = btn;
}

// 统一入口：异常不再静默吞掉（限频 30s 一条，避免轮询刷屏）
static void SLEnsureFloatButtonSafe(NSString *tag) {
    @try {
        SLEnsureFloatButton();
    } @catch (NSException *e) {
        static CFAbsoluteTime last = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last > 30.0) {
            last = now;
            SLLog(@"SL-MOMO: ensure float button failed (%@): %@", tag ?: @"?", e.reason);
        }
    }
}


// 不用 hook UIViewController：主队列定时检查并挂载（低侵入，避免 Logos 多 hook 嵌套坑）
void SLStartEntryWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(1.0 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            SLEnsureFloatButtonSafe(@"timer");
        });
        dispatch_resume(timer);

        // v0.4.37：窗口一变就立刻重排，不用干等下一次轮询。
        // 这几种情况就是「球突然没了」的高发时刻：广告窗关掉、回前台换窗口、场景重建。
        void (^kick)(NSNotification *) = ^(NSNotification *n) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SLEnsureFloatButtonSafe(n.name ?: @"notify");
            });
        };
        for (NSString *name in @[UIWindowDidBecomeVisibleNotification,
                                 UIWindowDidBecomeKeyNotification,
                                 UIApplicationDidBecomeActiveNotification,
                                 UIApplicationWillEnterForegroundNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:kick];
        }
        if (@available(iOS 13.0, *)) {
            [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:kick];
        }
        SLEnsureFloatButtonSafe(@"launch");
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
