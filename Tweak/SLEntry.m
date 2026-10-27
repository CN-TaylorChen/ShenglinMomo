#import "SLEntry.h"
#import "SLSettingsPanel.h"
#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "AWECAUtils.h"
#import "SLLog.h"
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>

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
// v0.4.40：位置相关的三个工具（定义在文件后面，拖动手势要用到）
static CGPoint SLClampFloatPos(CGPoint c, CGSize size);
static void SLStoreFloatPos(CGPoint c, CGSize size);
static CGPoint SLLoadFloatPos(CGSize size);

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
@interface SLPackMenu : UIView <AVAudioPlayerDelegate>
+ (void)showFromAnchor:(UIView *)anchor;
/// v0.4.41：拖动胶囊时让列表跟着走（不重建，只挪位置）
+ (void)sl_repositionForAnchor:(UIView *)anchor;
/// 收球 / 换页时把还开着的列表一起收掉
+ (void)sl_dismissCurrent;
- (void)sl_buildWithAnchor:(UIView *)anchor;
- (void)sl_dismiss;
- (CGRect)sl_cardFrameForAnchor:(UIView *)anchor width:(CGFloat)cardW height:(CGFloat)cardH;
@end

@interface SLPackMenuRow : UIControl
@property (nonatomic, strong) UIButton *play;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UIImageView *check;
@end

@implementation SLPackMenuRow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // v0.4.39：左侧那个「装饰图标」改成 30pt 圆形试听键。
        // 它是子控件，自己接走触摸，点它只试听、不选中；点名称那一侧才是切换。
        _play = [UIButton buttonWithType:UIButtonTypeCustom];
        _play.frame = CGRectZero;
        _play.backgroundColor = [UIColor clearColor];
        [self addSubview:_play];

        _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.10];
        _icon.layer.cornerRadius = 15.0;
        _icon.tintColor = [UIColor secondaryLabelColor];
        _icon.userInteractionEnabled = NO;
        [_play addSubview:_icon];

        _title = [[UILabel alloc] initWithFrame:CGRectZero];
        _title.font = [UIFont systemFontOfSize:14.0];
        _title.textColor = [UIColor labelColor];
        _title.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _title.userInteractionEnabled = NO;
        [self addSubview:_title];

        // v0.4.40：原声不再是列表里的一行 —— 撤销靠「再点一次已选中的那条」。
        // v0.4.41：右侧永远有一个圈。以前只在选中时冒出一个圆叉，未选中整条右边空着，
        // 一列名字参差不齐；现在换成标准的单选圈（空圈 / 勾选），一眼看出能选。
        _check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle"]];
        _check.contentMode = UIViewContentModeScaleAspectFit;
        _check.tintColor = [UIColor tertiaryLabelColor];
        _check.hidden = NO;
        _check.userInteractionEnabled = NO;
        [self addSubview:_check];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat h = CGRectGetHeight(b);
    // v0.4.39：左内距 12 + 试听键 30 + 间距 8 → 文字从 50 起，右侧只留 8pt 蓝点
    _play.frame = CGRectMake(0, 0, 48.0, h);
    _icon.frame = CGRectMake(12.0, (h - 30.0) / 2.0, 30.0, 30.0);
    _icon.layer.cornerRadius = 15.0;
    CGFloat right = CGRectGetWidth(b) - 12.0;
    _check.frame = CGRectMake(right - 18.0, (h - 18.0) / 2.0, 18.0, 18.0);
    CGFloat tw = CGRectGetMinX(_check.frame) - 8.0 - 50.0;
    _title.frame = CGRectMake(50.0, 0, MAX(0, tw), h);
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
    UIButton *_homeBtn;
    UIView *_homeHit;
    CAShapeLayer *_haloIn;
    CAShapeLayer *_haloOut;
    CAShapeLayer *_pulse;
    UIView *_readyDot;
    CFTimeInterval _longPressAt;
    // v0.4.40：球在哪半边，胶囊就往哪边「挂」—— 图标端留在球原位，箭头端伸向屏内
    BOOL _mirrored;
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
        // v0.4.40：两端各留 48 热区，名字在中间 100pt 里居中 —— 原来贴左对齐，
        // 右边空一大片，看着像没排好。
        _name.textAlignment = NSTextAlignmentCenter;
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

        // v0.4.39：展开后只有左端这块 48pt 圆形热区能收回成球。
        // 之前整个胶囊都挂了 touchUpInside，点名字中间也会"啪"一下缩回去。
        _homeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _homeBtn.frame = CGRectZero;
        _homeBtn.hidden = YES;
        [_homeBtn addTarget:self action:@selector(sl_homeTap) forControlEvents:UIControlEventTouchUpInside];
        [_homeBtn addTarget:self action:@selector(sl_homeDown) forControlEvents:UIControlEventTouchDown];
        [_homeBtn addTarget:self action:@selector(sl_homeUp)
           forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self addSubview:_homeBtn];

        _homeHit = [[UIView alloc] initWithFrame:CGRectZero];
        _homeHit.backgroundColor = [UIColor clearColor];
        _homeHit.layer.cornerRadius = 24.0;
        _homeHit.userInteractionEnabled = NO;
        [_homeBtn addSubview:_homeHit];

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
    // v0.4.41：状态一变就重读名字。原来只改颜色不改文字，发完那一发胶囊还挂着
    // 刚才的包名 —— 用户以为没发出去，实际问题只是字没刷新。
    _name.text = SLFloatPackName();
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
    BOOL wasMirrored = _mirrored;
    self.slExpanded = expanded;

    CGSize target = expanded ? [self sl_pillSize] : CGSizeMake(SLBallSide, SLBallSide);
    CGRect f = self.frame;
    CGRect nf = f;
    nf.size = target;
    if (expanded) {
        // 贴右边就向左长，贴左边就向右长，尽量不越出屏幕。
        // v0.4.40：这个方向同时决定胶囊内部镜像 —— 图标端永远停在球原来的位置，
        // 否则球在右边时图标被顶到最左、箭头正好压在球原位上，看起来像整颗球瞬移了。
        BOOL growLeft = YES;
        if (self.superview) growLeft = (CGRectGetMidX(f) > CGRectGetMidX(self.superview.bounds));
        _mirrored = growLeft;
        if (growLeft) nf.origin.x = CGRectGetMaxX(f) - target.width;
        if (self.superview) {
            CGFloat minX = 6.0, maxX = CGRectGetWidth(self.superview.bounds) - 6.0;
            if (CGRectGetMaxX(nf) > maxX) nf.origin.x = maxX - target.width;
            if (nf.origin.x < minX) nf.origin.x = minX;
        }
    } else {
        // v0.4.41：收起时球要落回「图标那一端」，不是胶囊的左边缘。
        // 向左长（镜像）的胶囊图标在右端，直接缩 origin.x 会让球无视觉地跳到左边去。
        [SLPackMenu sl_dismissCurrent];   // 球都收了，旁边还挂着列表很怪
        if (wasMirrored) nf.origin.x = CGRectGetMaxX(f) - SLBallSide;
        _mirrored = NO;
        if (self.superview) {
            CGPoint c = SLClampFloatPos(CGPointMake(CGRectGetMidX(nf), CGRectGetMidY(nf)),
                                        self.superview.bounds.size);
            nf.origin = CGPointMake(c.x - SLBallSide / 2.0, c.y - SLBallSide / 2.0);
            // 拖动过的胶囊，收起来之后这个位置就是球以后的新家
            SLStoreFloatPos(c, self.superview.bounds.size);
        }
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
    UIView *sv = self.superview;
    if (!sv) return;
    CGSize sz = sv.bounds.size;

    // v0.4.41：展开态也能拖 —— 按住中间文字那一条拖整条（两端 48pt 是按钮，不参与拖动）。
    // 拖动时不做吸附：胶囊本身就长，硬吸边只会让它一半出屏；收起成球时再按球位置存。
    if (self.slExpanded) {
        if (g.state == UIGestureRecognizerStateChanged) {
            CGPoint t = [g translationInView:sv];
            CGRect f = self.frame;
            f.origin.x += t.x;
            f.origin.y += t.y;
            CGFloat minX = 6.0, maxX = sz.width - 6.0 - f.size.width;
            if (maxX < minX) maxX = minX;
            if (f.origin.x < minX) f.origin.x = minX;
            if (f.origin.x > maxX) f.origin.x = maxX;
            CGFloat minY = 8.0, maxY = sz.height - 8.0 - f.size.height;
            if (maxY < minY) maxY = minY;
            if (f.origin.y < minY) f.origin.y = minY;
            if (f.origin.y > maxY) f.origin.y = maxY;
            self.frame = f;
            [g setTranslation:CGPointZero inView:sv];
            [SLPackMenu sl_repositionForAnchor:self];   // 打开的列表跟着走
        } else if (g.state == UIGestureRecognizerStateEnded
                   || g.state == UIGestureRecognizerStateCancelled) {
            // 只存「球位」：图标那一端收起来后球就落在那里
            CGPoint c = CGPointMake(_mirrored ? (CGRectGetMaxX(self.frame) - SLBallSide / 2.0)
                                              : (CGRectGetMinX(self.frame) + SLBallSide / 2.0),
                                    self.center.y);
            SLStoreFloatPos(SLClampFloatPos(c, sz), sz);
        }
        return;
    }

    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:sv];
        // 原来只做 center += 位移，没有任何边界判断 → 能整颗拖出屏幕，
        // 存下来的又是绝对坐标，换设备/横屏恢复后就在屏外。
        // 现在实时夹在界内（左右各留 4pt，上让状态栏，下让底部安全区）。
        self.center = SLClampFloatPos(CGPointMake(self.center.x + t.x, self.center.y + t.y), sz);
        [g setTranslation:CGPointZero inView:sv];
    } else if (g.state == UIGestureRecognizerStateEnded
               || g.state == UIGestureRecognizerStateCancelled) {
        // 松手吸附到最近的一条边，避免球卡在屏幕中间挡住内容
        CGFloat half = SLBallSide / 2.0;
        CGPoint c = self.center;
        c.x = (c.x < sz.width / 2.0) ? (half + 4.0) : (sz.width - half - 4.0);
        c = SLClampFloatPos(c, sz);
        [UIView animateWithDuration:0.22 delay:0
             usingSpringWithDamping:0.85 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ self.center = c; }
                         completion:nil];
        SLStoreFloatPos(c, sz);
    }
}

- (void)sl_tap {
    // 长按刚结束时个别机型还会补一次 touchUpInside，这里挡掉，免得胶囊一展开就被收回
    if (CFAbsoluteTimeGetCurrent() - _longPressAt < 0.5) return;
    // v0.4.39：展开态不再"点哪都收回去"，收球只认左端热区（_homeBtn）。
    // 球态时 _homeBtn 是隐藏的，所以点球仍然是展开。
    if (self.slExpanded) return;
    // v0.4.41：关掉「启用语音包」之后点球不再展开 —— 这个开关终于有了实际作用，
    // 而不是一个「开了也不知道变了什么」的装饰。
    if (![SLVoicePack isEnabled]) {
        [AWECAUtils showToast:@"语音包已关闭 · 长按球可打开设置" duration:1.8];
        return;
    }
    [self sl_expand:YES animated:YES];
}

- (void)sl_homeDown {
    _homeHit.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.08];
}

- (void)sl_homeUp {
    _homeHit.backgroundColor = [UIColor clearColor];
}

- (void)sl_homeTap {
    _homeHit.backgroundColor = [UIColor clearColor];
    if (CFAbsoluteTimeGetCurrent() - _longPressAt < 0.5) return;
    [self sl_expand:NO animated:YES];
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
    // v0.4.40：镜像开关。MX(x, wd) 把「距左 x」翻成「距右 x」，宽度不变的居中元素不要用它。
    BOOL mir = exp ? _mirrored : NO;
#define SLMX(x, wd) (mir ? (w - (x) - (wd)) : (x))
    _chrome.frame = CGRectMake(mir ? 0 : (w - SLPillMaxW), 0, SLPillMaxW, h);

    // v0.4.39：左图标与球态同尺寸（22pt，不再缩水到 18），头像 32 → 42
    _glyph.frame = exp ? CGRectMake(SLMX(13.0, 22.0), (h - 22.0) / 2.0, 22.0, 22.0)
                       : CGRectMake((w - 22.0) / 2.0, (h - 22.0) / 2.0, 22.0, 22.0);
    _glyph.hidden = (_thumb.hidden == NO) || (_emoji.hidden == NO);
    CGFloat iconS = 42.0;
    _thumb.frame = exp ? CGRectMake(SLMX(3.0, iconS), (h - iconS) / 2.0, iconS, iconS) : b;
    _thumb.layer.cornerRadius = MIN(CGRectGetWidth(_thumb.bounds), CGRectGetHeight(_thumb.bounds)) / 2.0;
    _emoji.font = [UIFont systemFontOfSize:(exp ? 17.0 : 22.0)];
    _emoji.frame = exp ? CGRectMake(SLMX(3.0, iconS), (h - iconS) / 2.0, iconS, iconS) : b;

    // v0.4.37：状态色铺满整条胶囊。原来展开态只盖左侧 48pt 圆，
    // 球是蓝的、胶囊还是白玻璃，中间像被切断。
    _tint.frame = b;
    _tint.layer.cornerRadius = h / 2.0;

    // v0.4.40：两端各一块 48pt 热区，中间 100pt 给名字（居中）。
    // 镜像时两端互换、中间不动 —— 图标端跟着球走，箭头端永远在远端。
    _sep.frame = CGRectMake(SLMX(48.0, 0.5), (h - 18.0) / 2.0, 0.5, 18.0);
    _name.frame = CGRectMake(48.0, 0, MAX(0, w - 96.0), h);
    _menuBtn.frame = exp ? CGRectMake(SLMX(w - 48.0, 48.0), 0, 48.0, h) : CGRectZero;
    _chev.frame = CGRectMake(18.5, (h - 11.0) / 2.0, 11.0, 11.0);
    _homeBtn.frame = exp ? CGRectMake(SLMX(0.0, 48.0), 0, 48.0, h) : CGRectZero;
    _homeHit.frame = _homeBtn.bounds;
    _readyDot.frame = CGRectMake(mir ? 5.0 : (w - 14.0), 3.0, 9.0, 9.0);
#undef SLMX

    _sep.hidden = !exp;
    _name.hidden = !exp;
    _menuBtn.hidden = !exp;
    _homeBtn.hidden = !exp;

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

// v0.4.41：全场最多一个列表。拖动胶囊时要能让它跟着走，所以要有个引用。
static __weak SLPackMenu *sSLPackMenu = nil;

@implementation SLPackMenu {
    UIControl *_catcher;
    UIView *_card;
    UIVisualEffectView *_blur;
    NSArray<NSDictionary *> *_rows;
    NSMutableArray<SLPackMenuRow *> *_rowViews;
    AVAudioPlayer *_player;
    NSInteger _playingRow;
    __weak UIView *_anchor;
}

+ (void)showFromAnchor:(UIView *)anchor {
    UIWindow *win = anchor.window;
    if (!win || !anchor) return;
    if (sSLPackMenu) [sSLPackMenu sl_dismiss];   // 不叠第二张
    SLPackMenu *m = [[SLPackMenu alloc] initWithFrame:win.bounds];
    m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:m];
    sSLPackMenu = m;
    [m sl_buildWithAnchor:anchor];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _playingRow = -1;
        _catcher = [[UIControl alloc] initWithFrame:self.bounds];
        _catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _catcher.backgroundColor = [UIColor clearColor];
        [_catcher addTarget:self action:@selector(sl_dismiss) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_catcher];
    }
    return self;
}

// v0.4.41：卡片位置只在这里算一次。拖动胶囊时按同一套规则重算，列表就像挂在胶囊上。
- (CGRect)sl_cardFrameForAnchor:(UIView *)anchor width:(CGFloat)cardW height:(CGFloat)cardH {
    CGRect ar = [anchor convertRect:anchor.bounds toView:self];
    CGFloat winW = CGRectGetWidth(self.bounds);
    CGFloat winH = CGRectGetHeight(self.bounds);
    CGFloat x = CGRectGetMaxX(ar) - cardW;
    x = MAX(12.0, MIN(x, winW - 12.0 - cardW));
    CGFloat y = CGRectGetMaxY(ar) + 14.0;
    CGFloat safeB = 0;
    if (@available(iOS 11.0, *)) safeB = self.safeAreaInsets.bottom;
    if (y + cardH > winH - safeB - 12.0) y = CGRectGetMinY(ar) - 14.0 - cardH;
    if (y < 12.0) y = 12.0;   // 上下都挤的时候至少别顶出屏幕
    return CGRectMake(x, y, cardW, cardH);
}

+ (void)sl_repositionForAnchor:(UIView *)anchor {
    SLPackMenu *m = sSLPackMenu;
    if (!m || !m->_card || !anchor) return;
    CGRect f = [m sl_cardFrameForAnchor:anchor
                                  width:CGRectGetWidth(m->_card.frame)
                                 height:CGRectGetHeight(m->_card.frame)];
    m->_card.frame = f;
}

+ (void)sl_dismissCurrent {
    SLPackMenu *m = sSLPackMenu;
    if (m) [m sl_dismiss];
}

// 列表是全屏遮罩（点空白收起），但胶囊必须还能被按住拖动 ——
// 所以落在胶囊上的触摸原样交回给它自己，其余照旧由遮罩处理。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *anchor = _anchor;
    if (anchor && anchor.window == self.window) {
        CGPoint p = [self convertPoint:point toView:anchor];
        if ([anchor pointInside:p withEvent:event]) return [anchor hitTest:p withEvent:event];
    }
    return [super hitTest:point withEvent:event];
}

- (void)sl_buildWithAnchor:(UIView *)anchor {
    // v0.4.40：原声不在列表里占一行 —— 它就是「没有装填」的默认状态。
    // 想撤销已装好的那一发，再点一次它本身（右侧圆叉）。
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *p in [SLVoicePack allPacks]) {
        [rows addObject:@{@"title": p[@"name"] ?: @"未命名", @"pack": p}];
    }
    if (!rows.count) {
        // 一条包都没有时给一行说明，别弹出一张只有内边距的空卡片
        [rows addObject:@{@"title": @"还没有语音包 · 长按球进设置导入", @"empty": @YES}];
    }
    _rows = rows;

    // v0.4.39：行高 44 → 48，给左侧 30pt 圆形试听键留出上下各 9pt；
    // 卡片与胶囊的间距 6 → 14（呼吸灯外圈是 7pt，留 6 会把光晕整圈盖住）。
    CGFloat rowH = 48.0;
    NSUInteger visible = MIN(_rows.count, (NSUInteger)5);

    _anchor = anchor;
    CGRect ar = [anchor convertRect:anchor.bounds toView:self];
    CGFloat cardW = CGRectGetWidth(ar);
    if (cardW < 120.0) cardW = 196.0;
    CGFloat cardH = visible * rowH + 12.0;

    _card = [[UIView alloc] initWithFrame:[self sl_cardFrameForAnchor:anchor
                                                               width:cardW
                                                              height:cardH]];
    _card.layer.cornerRadius = 22.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.20;
    _card.layer.shadowRadius = 20.0;
    _card.layer.shadowOffset = CGSizeMake(0, 8);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:22.0].CGPath;
    [self addSubview:_card];

    // v0.4.39：原来在卡片顶上画了个旋转 45° 的小方块当"指示小三角"，
    // 实际是一个角穿出卡片、颜色也和玻璃对不上的菱形片 —— 直接去掉。
    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _blur.frame = _card.bounds;
    _blur.layer.cornerRadius = 22.0;
    _blur.layer.cornerCurve = kCACornerCurveContinuous;
    _blur.clipsToBounds = YES;
    [_card addSubview:_blur];

    UIView *hair = [[UIView alloc] initWithFrame:CGRectInset(_card.bounds, 0.5, 0.5)];
    hair.layer.cornerRadius = 21.5;
    hair.layer.cornerCurve = kCACornerCurveContinuous;
    hair.layer.borderWidth = 0.5;
    hair.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    hair.userInteractionEnabled = NO;
    [_card addSubview:hair];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 6, cardW, cardH - 12)];
    sv.showsVerticalScrollIndicator = NO;
    sv.alwaysBounceVertical = NO;
    [_card addSubview:sv];

    _rowViews = [NSMutableArray arrayWithCapacity:_rows.count];
    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                                                       weight:UIImageSymbolWeightSemibold];
    for (NSUInteger i = 0; i < _rows.count; i++) {
        NSDictionary *info = _rows[i];
        SLPackMenuRow *r = [[SLPackMenuRow alloc] initWithFrame:CGRectMake(0, i * rowH, cardW, rowH)];
        r.tag = (NSInteger)i;
        r.title.text = info[@"title"];
        NSDictionary *pack = info[@"pack"];

        // v0.4.40：「选中」= 已装好、等下一录音的那一条（不是「上次用过的那条」）。
        // 发出去之后 pending 被清，这里就不再点亮。
        BOOL on = pack && [SLVoicePack isOneShotPending] && [SLVoicePack isPackActive:pack];

        // 左侧 30pt 圆形试听键：点它只试听、不选中；点名称那侧才是装填 / 撤销
        BOOL placeholder = (pack == nil);
        // v0.4.41：右侧总是有圈（占位行除外），空圈 / 蓝勾一眼看出能不能选
        r.check.hidden = placeholder;
        r.check.image = [UIImage systemImageNamed:(on ? @"checkmark.circle.fill" : @"circle")];
        r.check.tintColor = on ? [UIColor systemBlueColor] : [UIColor tertiaryLabelColor];
        r.play.tag = (NSInteger)i;
        [r.play addTarget:self action:@selector(sl_playTapped:) forControlEvents:UIControlEventTouchUpInside];
        r.play.enabled = !placeholder;
        r.icon.image = [UIImage systemImageNamed:(placeholder ? @"info.circle" : @"play.fill") withConfiguration:symCfg];
        r.icon.backgroundColor = on ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.16]
                                    : [[UIColor labelColor] colorWithAlphaComponent:0.10];
        r.icon.tintColor = on ? [UIColor systemBlueColor] : (placeholder ? [UIColor tertiaryLabelColor] : [UIColor labelColor]);
        if (placeholder) r.title.textColor = [UIColor secondaryLabelColor];
        r.title.textColor = on ? [UIColor systemBlueColor] : [UIColor labelColor];
        r.title.font = [UIFont systemFontOfSize:14.0 weight:(on ? UIFontWeightSemibold : UIFontWeightRegular)];
        [r addTarget:self action:@selector(sl_rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [sv addSubview:r];
        [_rowViews addObject:r];

        if (i + 1 < _rows.count) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(50, (i + 1) * rowH - 0.25, cardW - 50 - 12, 0.5)];
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

#pragma mark 试听

// v0.4.39：点行左侧的圆形键试听这个语音包的第一条音频。
// 只是"听一下是什么味"，不改变当前选择 —— 选中仍然要点名称那一侧。
- (void)sl_playTapped:(UIButton *)btn {
    NSInteger idx = btn.tag;
    if (idx < 0 || idx >= (NSInteger)_rows.count) return;
    NSDictionary *info = _rows[(NSUInteger)idx];

    // 同一行再点一次 = 停
    if (_playingRow == idx && _player && _player.playing) {
        [self sl_stopAudition];
        return;
    }
    [self sl_stopAudition];

    NSString *path = [SLVoicePack pathOfPack:info[@"pack"]];
    if (!path.length) {
        [AWECAUtils showToast:@"这个包里还没有音频" duration:1.6];
        return;
    }

    NSError *err = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!p || err) {
        SLLog(@"PACKMENU 试听打不开：%@ (%@)", path.lastPathComponent, err.localizedDescription);
        [AWECAUtils showToast:@"这条音频放不出来" duration:1.8];
        return;
    }
    p.delegate = self;
    AVAudioSession *ses = [AVAudioSession sharedInstance];
    [ses setCategory:AVAudioSessionCategoryPlayback error:nil];
    [ses setActive:YES error:nil];
    if (![p play]) {
        [AWECAUtils showToast:@"这条音频放不出来" duration:1.8];
        return;
    }
    _player = p;
    _playingRow = idx;
    [self sl_markRow:idx playing:YES];
}

- (void)sl_stopAudition {
    if (_player) {
        _player.delegate = nil;
        [_player stop];
        _player = nil;
    }
    if (_playingRow >= 0) {
        [self sl_markRow:_playingRow playing:NO];
        _playingRow = -1;
    }
}

- (void)sl_markRow:(NSInteger)idx playing:(BOOL)on {
    if (idx < 0 || idx >= (NSInteger)_rowViews.count) return;
    SLPackMenuRow *r = _rowViews[(NSUInteger)idx];
    // 停止试听后要回落到「这一行本来该有的样子」：选中行仍然是蓝底，别被刷成灰的
    NSDictionary *info = (idx < (NSInteger)_rows.count) ? _rows[(NSUInteger)idx] : nil;
    NSDictionary *pack = info[@"pack"];
    BOOL sel = pack && [SLVoicePack isOneShotPending] && [SLVoicePack isPackActive:pack];
    BOOL hot = on || sel;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                                                     weight:UIImageSymbolWeightSemibold];
    r.icon.image = [UIImage systemImageNamed:(on ? @"pause.fill" : @"play.fill") withConfiguration:cfg];
    r.icon.backgroundColor = hot ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.16]
                                 : [[UIColor labelColor] colorWithAlphaComponent:0.10];
    r.icon.tintColor = hot ? [UIColor systemBlueColor] : [UIColor labelColor];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player; (void)flag;
    [self sl_stopAudition];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    (void)player; (void)error;
    [self sl_stopAudition];
}

- (void)sl_rowTapped:(SLPackMenuRow *)row {
    if (row.tag < 0 || row.tag >= (NSInteger)_rows.count) return;
    NSDictionary *pack = _rows[(NSUInteger)row.tag][@"pack"];
    if (!pack) return;

    BOOL on = [SLVoicePack isOneShotPending] && [SLVoicePack isPackActive:pack];
    if (on) {
        // 再点一次已装好的那条 = 撤销这一发，回到原声（不用发出去消耗掉）
        [SLVoicePack setOneShotPending:NO];
        SLClearArmedAudio();
        [AWECAUtils showToast:@"已切回原声" duration:1.5];
        SLLog(@"one-shot cancelled by re-tap");
    } else {
        [SLVoicePack selectPack:pack];
        [SLVoicePack setOneShotPending:YES];
        [SLVoicePack setArmedSource:SLArmedSourcePack];
        [SLVoicePack setEnabled:YES];
        // v0.4.41：槽位只有一个 —— 之前用 #tts 合成的音必须在这里让位，
        // 否则会出现「明明选了包，发出去却是刚才那段合成音」。
        SLClearArmedAudio();
        SLPackPrewarm();
        [AWECAUtils showToast:[NSString stringWithFormat:@"已装好「%@」· 下一条语音发它", pack[@"name"] ?: @""]
                     duration:1.8];
        SLLog(@"one-shot armed %@", pack[@"name"] ?: @"-");
    }
    SLRefreshFloatButton();
    [self sl_dismiss];
}

- (void)sl_dismiss {
    [self sl_stopAudition];
    if (sSLPackMenu == self) sSLPackMenu = nil;
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
- (void)sl_applyNavTransparency;
- (void)sl_fixScrollInsetsIn:(UIView *)view top:(CGFloat)top;
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

    [self sl_applyNavTransparency];
}

// v0.4.40：导航栏透明化收成一个方法，viewDidLoad / viewWillAppear / viewWillLayoutSubviews 各刷一次。
// iOS 15 起导航栏有两套外观：内容贴顶用 scrollEdgeAppearance（透明），一旦下方开始滚动就换成
// standardAppearance（不透明浅底 + 0.5pt 投影线）—— 表现是「一滑顶部冒出一条白」。
// 只在 viewDidLoad 设一次是不够的：系统会在 layout 周期里把它重置回去，所以每次布局都补一遍。
- (void)sl_applyNavTransparency {
    UINavigationBar *nb = self.nav.navigationBar;
    if (!nb) return;
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithTransparentBackground];
        ap.backgroundColor = [UIColor clearColor];
        ap.backgroundEffect = nil;
        ap.shadowColor = [UIColor clearColor];
        nb.standardAppearance = ap;
        nb.compactAppearance = ap;
        nb.scrollEdgeAppearance = ap;
        if (@available(iOS 15.0, *)) nb.compactScrollEdgeAppearance = ap;
    }
    // 老接口一起上：部分页面（自带背景图 / 自定义返回按钮）会走这条路，
    // 新老两条都设成空，哪条生效都不会再有白底。
    nb.translucent = YES;
    nb.backgroundColor = [UIColor clearColor];
    [nb setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    nb.shadowImage = [UIImage new];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // 系统在布局周期会重置导航栏外观，这里是必须补刷的一次
    [self sl_applyNavTransparency];
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

// v0.4.41：顶部那条白的真正根因（这次是真的）。
// 导航栏是透明的，表格一旦滚动，内容会钻到导航栏底下 —— 而列表底色是浅灰白，
// 那块区域于是露出一条实心白带，跟四周的毛玻璃完全不是一种材质，看着就是「冒出一条白」。
// 改外观（四套 UINavigationBarAppearance）治不了它，因为白带根本不是导航栏画的。
// 解法：内容永远不进导航栏区域 —— 表格顶内边距 = 导航栏下沿，并关掉系统的自动内边距
// （否则它会把安全区再算一遍，留白翻倍）。三个页面（设置 / 语音包 / 地图）共用这一处。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UINavigationBar *nb = self.nav.navigationBar;
    if (!nb || !self.nav.view) return;
    CGFloat top = CGRectGetMaxY(nb.frame);
    if (top < 44.0) top = 44.0;      // 有些状态（转场中）拿到的还是 0
    [self sl_fixScrollInsetsIn:self.nav.view top:top];
}

- (void)sl_fixScrollInsetsIn:(UIView *)view top:(CGFloat)top {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)view;
        // 只处理「顶在导航栏底下」的表格。地图页的列表是自己手算 frame 避让过的
        // （从导航栏下沿才开始），再给它塞一份顶内边距只会白空一截。
        CGFloat y = [sv convertPoint:CGPointZero toView:self.nav.view].y;
        if (y > top - 1.0) return;
        if (@available(iOS 11.0, *)) {
            if (sv.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
                sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
            }
        }
        // 幂等：值没变就不写，避免 contentInset 变化引发的布局回环
        UIEdgeInsets in = sv.contentInset;
        if (fabs(in.top - top) > 0.5) {
            in.top = top;
            sv.contentInset = in;
        }
        // 滚动条也跟着让开导航栏。v0.4.42：老接口 scrollIndicatorInsets 在 iOS 13 已弃用，
        // 而这里开着 -Werror → 直接编译失败；改用 verticalScrollIndicatorInsets。
        if (@available(iOS 13.0, *)) {
            UIEdgeInsets si = sv.verticalScrollIndicatorInsets;
            if (fabs(si.top - top) > 0.5) {
                si.top = top;
                sv.verticalScrollIndicatorInsets = si;
            }
        }
        // 底色必须是透的，滚动时露出的是浮窗那层毛玻璃
        if (sv.backgroundColor && ![sv.backgroundColor isEqual:[UIColor clearColor]]) {
            sv.backgroundColor = [UIColor clearColor];
        }
        return;   // 不再往列表内部钻：cell 里的横向滚动视图不该被改
    }
    for (UIView *sub in view.subviews) [self sl_fixScrollInsetsIn:sub top:top];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 从地图页 / 语音包页返回时也重刷一遍，防止子页把外观改回去
    [self sl_applyNavTransparency];    self.cardWrap.alpha = 0.0;
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

// 胶囊上显示的当前选择（原声 / 语音包名 / AI 语音）
// v0.4.40：原声 = 没有装填。不再有「原声开关」，只看有没有待发的那一发。
// v0.4.41：槽位里可能是语音包，也可能是 #tts 现场合成的音 —— 后者以前会谎报成「原声」，
// 用户以为没装东西，发出去却是合成音。现在按来源如实显示。
static NSString *SLFloatPackName(void) {
    if (![SLVoicePack isOneShotPending]) return @"原声";
    if ([SLVoicePack armedSource] == SLArmedSourceAI) return @"AI 语音";
    NSDictionary *pack = [SLVoicePack activePack];
    NSString *n = pack[@"name"];
    return n.length ? n : @"原声";
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
    // v0.4.40：装填了就亮成蓝的、撤销了回空闲 —— 名字（sl_loadIcon）和颜色一起走，
    // 否则会出现「名字写原声、球还是蓝的」这种自相矛盾。
    if (btn) [btn sl_applyState:([SLVoicePack isOneShotPending] ? SLFloatStateReady : SLFloatStateIdle)];
}

// 把中心点夹在「不会被屏幕边缘切掉」的范围内。
// 原来那版是「越界就重置」—— 拖到边上会突然跳回中间，而且重置值本身也可能越界。
static CGPoint SLClampFloatPos(CGPoint c, CGSize size) {
    if (size.width <= 0 || size.height <= 0) return c;
    CGFloat half = SLBallSide / 2.0;
    CGFloat minX = half + 4.0;
    CGFloat maxX = size.width - half - 4.0;
    CGFloat minY = half + 56.0;                 // 让开状态栏 / 刘海
    CGFloat maxY = size.height - half - 34.0;   // 让开底部安全区
    if (maxX < minX) { c.x = size.width / 2.0; }
    else { if (c.x < minX) c.x = minX; if (c.x > maxX) c.x = maxX; }
    if (maxY < minY) { c.y = size.height / 2.0; }
    else { if (c.y < minY) c.y = minY; if (c.y > maxY) c.y = maxY; }
    return c;
}

// 位置存「中心点占屏幕的比例」而不是绝对坐标：换设备、横竖屏、分屏之后
// 同样的比例仍然落在同一个相对位置，不会跑到屏外。
static void SLStoreFloatPos(CGPoint c, CGSize size) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (size.width > 0 && size.height > 0) {
        [d setObject:[NSString stringWithFormat:@"%.4f,%.4f", c.x / size.width, c.y / size.height]
              forKey:@"SLFloatPosRel"];
    }
    [d setObject:NSStringFromCGPoint(c) forKey:@"SLFloatPos"];   // 兼容旧版读法
}

static CGPoint SLLoadFloatPos(CGSize size) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *rel = [d stringForKey:@"SLFloatPosRel"];
    if (rel.length) {
        NSArray *p = [rel componentsSeparatedByString:@","];
        if (p.count == 2) {
            double rx = [p[0] doubleValue], ry = [p[1] doubleValue];
            if (rx > 0.03 && rx < 0.97 && ry > 0.03 && ry < 0.97) {
                return CGPointMake(rx * size.width, ry * size.height);
            }
        }
    }
    NSString *old = [d objectForKey:@"SLFloatPos"];
    if (old.length) return CGPointFromString(old);
    return CGPointMake(size.width - 36.0, size.height * 0.55);
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
        CGPoint c = SLClampFloatPos(SLLoadFloatPos(w.bounds.size), w.bounds.size);
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
