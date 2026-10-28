#import "SLEntry.h"
#import "SLSettingsPanel.h"
#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "AWECAUtils.h"
#import "SLLog.h"
#import "SLGlass.h"
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
        // v0.4.47：条高改 短长长短（原 短长短长）。左两淡=原声，右两实=合成声，分组不变。
        CGFloat hs[4] = {24, 46, 40, 28};
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

// v0.4.44：下压留白改成 0。
// 之前留 14pt 是为了让搜索栏不压圆角，但导航栏是透明的 —— 那 14pt 成了整张卡片上
// 唯一「没被任何内容盖住」的裸玻璃，比下面被列表染色的区域更亮，就是用户看到的那条白边。
// 改外观、改裁剪都治不了它，因为它根本不是某张图画的，而是「空出来的那块」。
// 现在导航栏贴到卡片顶：44pt 高的内容垂直居中，实际距顶 10pt，26pt 圆角在 y=10 处
// 只向内收 5.5pt，而按钮/搜索胶囊距左右边缘 12~16pt —— 不会压到弧线。
static const CGFloat kSLPanelTopPad = 0.0;

// v0.4.43：1×1 全透明图。
// 老写法 setBackgroundImage:[UIImage new] 传的是 0×0 的空图，UIKit 会**当没设**，
// 于是回落到系统默认的导航栏背景图 —— 那张图是「顶部纯白 → 向下渐隐 + 底部 0.5pt 线」，
// 视觉上就是压不掉的一条顶部白。必须给真图，尺寸 0 的图不算数。
static UIImage *SLTransparentImage(void) {
    static UIImage *img = nil;
    if (img) return img;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    fmt.scale = 1.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1) format:fmt];
    img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;   // 什么都不画 = 全透明
    }];
    return img;
}

@interface SLFloatButton : UIButton
@property (nonatomic, assign) BOOL slExpanded;
@property (nonatomic, assign) SLFloatState slState;
- (void)sl_loadIcon;
- (void)sl_applyState:(SLFloatState)state;
/// v0.4.49：四杠逐根动画（A 均衡器 / C 呼吸，绕中心缩放）
- (void)sl_layoutBars;
- (void)sl_updateBarMotion;
- (void)sl_expand:(BOOL)expanded animated:(BOOL)animated;
/// v0.4.45：回到前台重挂呼吸光晕（后台期间动画会被系统整条移除）
- (void)sl_restartHalo;
/// v0.4.46：拖动中越过中线翻面 / 松手贴边
- (void)sl_updateMirrorDuringDrag;
- (void)sl_settlePillToEdge;
@end

// v0.4.36：胶囊下方展开的语音包列表（点胶囊右端才出现）。
// 挂在窗口上，和胶囊同一套毛玻璃；点一行即切换，点空白收起。
@interface SLPackMenu : UIView <AVAudioPlayerDelegate>
+ (void)showFromAnchor:(UIView *)anchor;
/// v0.4.41：拖动胶囊时让列表跟着走（不重建，只挪位置）
+ (void)sl_repositionForAnchor:(UIView *)anchor;
/// 收球 / 换页时把还开着的列表一起收掉
+ (void)sl_dismissCurrent;
/// v0.4.43：列表开着没有（点箭头第二次要能关掉，不是重开一张）
+ (BOOL)sl_isShowing;
- (void)sl_buildWithAnchor:(UIView *)anchor;
- (void)sl_buildNodes;
- (void)sl_renderRows;
/// v0.4.43：点文件夹分组标题 = 展开 / 收起（类型写成 UIControl，行视图类在这个 @interface 之后才定义）
- (void)sl_groupTapped:(UIControl *)row;
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

// v0.4.43：下拉列表里的文件夹分组头。
// 原来下拉列表把所有包平铺成一长条，包一多就找不着；这个可点的标题行把包按文件夹收拢，
// 点一下展开 / 收起，收起时只留标题，一屏能看全有哪些组。
@interface SLPackGroupRow : UIControl
@property (nonatomic, strong) UIImageView *chev;
@property (nonatomic, strong) UILabel *name;
@property (nonatomic, strong) UILabel *count;
@property (nonatomic, assign) BOOL expanded;
@end

@implementation SLPackGroupRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:9.0 weight:UIImageSymbolWeightBold];
        _chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:cfg]];
        _chev.contentMode = UIViewContentModeScaleAspectFit;
        _chev.tintColor = [UIColor tertiaryLabelColor];
        _chev.userInteractionEnabled = NO;
        [self addSubview:_chev];

        _name = [[UILabel alloc] initWithFrame:CGRectZero];
        _name.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        _name.textColor = [UIColor secondaryLabelColor];
        _name.lineBreakMode = NSLineBreakByTruncatingTail;
        _name.userInteractionEnabled = NO;
        [self addSubview:_name];

        _count = [[UILabel alloc] initWithFrame:CGRectZero];
        _count.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightRegular];
        _count.textColor = [UIColor tertiaryLabelColor];
        _count.userInteractionEnabled = NO;
        [self addSubview:_count];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.bounds), w = CGRectGetWidth(self.bounds);
    _chev.frame = CGRectMake(10.0, (h - 9.0) / 2.0, 9.0, 9.0);
    CGFloat tx = 25.0;
    CGFloat avail = MAX(0.0, w - tx - 12.0);
    CGSize ns = [_name sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    CGFloat nw = MIN(ns.width, avail);
    _name.frame = CGRectMake(tx, 0, nw, h);
    _count.frame = CGRectMake(tx + nw + 6.0, 0, MAX(0.0, avail - nw - 6.0), h);
}

- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    _chev.transform = expanded ? CGAffineTransformMakeRotation((CGFloat)M_PI_2) : CGAffineTransformIdentity;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1.0;
}

@end

@implementation SLFloatButton {
    UIView *_glassHost;
    UIVisualEffectView *_chrome;
    CAShapeLayer *_glassMask;
    UIView *_tint;
    UIImageView *_glyph;
    // v0.4.49：四杠改成 4 个可独立动画的条视图（原来是一张静态图，无法逐根错相位跳动）
    UIView *_bars;
    UIView *_barCell[4];
    UIImageView *_thumb;
    UILabel *_emoji;
    UIView *_sep;
    UILabel *_name;
    UIButton *_menuBtn;
    // v0.4.45：中间文字区热区 —— 只接触摸，点它不做任何事
    UIButton *_midBtn;
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
        // v0.4.46：材质变透之后，玻璃的「存在感」全靠这圈高光 —— 0.5/0.5 太淡，
        // 透到背景里就分不出边界在哪。加粗到 0.8、提到 0.62，像一层薄玻璃的边缘反光。
        _glassHost.layer.borderWidth = 0.8;
        _glassHost.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.62].CGColor;
        _glassMask = [CAShapeLayer layer];
        _glassHost.layer.mask = _glassMask;
        [self addSubview:_glassHost];

        // v0.4.46：SystemMaterial → SystemUltraThinMaterial。前者在 iOS 15 上已经相当「实」，
        // 铺在聊天背景上基本看不到背后内容；换成超薄材质后是真正的玻璃感（透 + 轻模糊），
        // 玻璃的边界靠 _glassHost 那圈 0.8pt 高光勾出来。
        _chrome = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
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

        // v0.4.49：四杠容器。放在 _glyph 之上、_thumb/_emoji 之下，
        // 位置/显隐跟随 _glyph；自定义头像或 emoji 时整组隐藏。
        _bars = [[UIView alloc] initWithFrame:CGRectZero];
        _bars.userInteractionEnabled = NO;
        [self addSubview:_bars];
        for (int i = 0; i < 4; i++) {
            UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
            bar.userInteractionEnabled = NO;
            [_bars addSubview:bar];
            _barCell[i] = bar;
        }

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

        // v0.4.45：中间文字区只是一块「接住触摸」的空壳，点它不做任何事。
        // 它存在的唯一意义：别让触摸落到 self（本身是 UIButton）上，
        // 否则中间又会被 self 的 touchUpInside 收走。收球只认图标那一端。
        // 按住拖动照样能拖 —— 手势识别器挂在 self 上，子视图接走触摸不影响它。
        _midBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _midBtn.frame = CGRectZero;
        _midBtn.hidden = YES;
        [self addSubview:_midBtn];

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
        _readyDot.backgroundColor = [UIColor systemGreenColor];   // v0.4.57：就绪态是绿，亮点也跟着绿，别冒出一颗蓝点
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

        // v0.4.45：进后台时 CoreAnimation 会把光晕那两条无限循环动画整条摘掉，
        // 图层 opacity 回到 0 —— 切回来就是「呼吸灯没了」，点一下图标（重设状态）才回来。
        // 回到前台必须自己重挂一次。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sl_restartHalo)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(sl_restartHalo)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

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
        _glyph.alpha = 0.0;   // v0.4.49：静态图不显示，实际由 _bars 逐根绘制 + 动画
    }
    _name.text = SLFloatPackName();
    [self setNeedsLayout];
}

// v0.4.49：把四根条摆到 _bars 里。几何沿用 SLBrandGlyphCompact：
// 单位 u = 宽度/100，xs 定位置、hs 定高度（短长长短），左两淡=原声、右两实=合成声。
// 用 bounds + center 摆放，锚点天然在正中，缩放就是「绕中心」，不会贴底。
- (void)sl_layoutBars {
    CGFloat side = CGRectGetWidth(_bars.bounds);
    if (side <= 0.0) return;
    CGFloat u = side / 100.0;
    static const CGFloat xs[4] = {12, 34, 56, 78};
    static const CGFloat hs[4] = {24, 46, 40, 28};
    static const CGFloat as[4] = {0.30, 0.30, 1.0, 1.0};
    UIColor *c = _glyph.tintColor ?: [UIColor labelColor];
    for (int i = 0; i < 4; i++) {
        CGFloat w = 10.0 * u;
        CGFloat hh = hs[i] * u;
        UIView *bar = _barCell[i];
        bar.bounds = CGRectMake(0, 0, w, hh);
        bar.center = CGPointMake((xs[i] * u) + w / 2.0, side / 2.0);
        bar.layer.cornerRadius = w / 2.0;
        bar.layer.cornerCurve = kCACornerCurveContinuous;
        bar.backgroundColor = [c colorWithAlphaComponent:as[i]];
    }
}

// v0.4.50：四个状态四套节奏，不再两两共用。
//   空闲  → 同步呼吸（一轮 2.4s / 0.86，几乎不动，不抢注意力）
//   录音  → 交叉急抖（一轮 0.64s / 0.30，1·3·2·4 错拍，像电平表）
//   合成  → 波从左向右推（一轮 1.2s / 0.55，0→3 递进，有「正在生成」的方向感）
//   就绪  → 上冲 + 二次回弹（1.1s，唯一超过原高到 1.15，像举起来等你按发送）
// 只动 transform.scale.y，锚点在中心：几何、点击区域、胶囊形状都不变。
- (void)sl_updateBarMotion {
    if (!_bars) return;
    if (_bars.hidden) {
        for (int i = 0; i < 4; i++) [_barCell[i].layer removeAnimationForKey:@"slBar"];
        return;
    }

    static const CGFloat kStagNone[4] = {0.00, 0.00, 0.00, 0.00};
    static const CGFloat kStagRec[4]  = {0.00, 0.26, 0.13, 0.39};   // 1·3·2·4 交叉
    static const CGFloat kStagSyn[4]  = {0.00, 0.15, 0.30, 0.45};   // 左 → 右递进
    static const CGFloat kStagRdy[4]  = {0.00, 0.04, 0.08, 0.12};   // 几乎同相

    SLFloatState st = self.slState;
    const CGFloat *stagger = kStagNone;
    CGFloat half = 1.2;      // 空闲一轮 2.4s
    CGFloat lo = 0.86;
    BOOL keyframe = NO;
    if (st == SLFloatStateRecording) {
        half = 0.32; lo = 0.30; stagger = kStagRec;         // 一轮 0.64s
    } else if (st == SLFloatStateSynthesizing) {
        half = 0.60; lo = 0.55; stagger = kStagSyn;         // 一轮 1.2s
    } else if (st == SLFloatStateReady) {
        keyframe = YES; stagger = kStagRdy;                 // 1.1s 双跳
    }

    CFTimeInterval now = CACurrentMediaTime();
    for (int i = 0; i < 4; i++) {
        CALayer *l = _barCell[i].layer;
        [l removeAnimationForKey:@"slBar"];
        [l removeAnimationForKey:@"slNeutral"];   // v0.4.57：清掉上一轮就绪的缓回动画，避免跨状态残留
        if (keyframe) {
            // 就绪：先 0.16s 把四杠从上一状态的幅度缓回 1.0（fromValue 省略＝从当前
            // 展示值起跳），抹掉「波/抖」直接跳成双跳的硬切；随后再起双跳 keyframe
            // （beginTime 延后 0.16s，此刻 slNeutral 已结束，两段不会打架）。
            CABasicAnimation *neutral = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
            neutral.toValue = @1.0;
            neutral.duration = 0.16;
            neutral.beginTime = now + stagger[i];
            neutral.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            neutral.fillMode = kCAFillModeBoth;
            neutral.removedOnCompletion = NO;
            [l addAnimation:neutral forKey:@"slNeutral"];
            // 就绪：上冲到 1.15 → 回落 → 再冲一次 → 轻微停在 1.02 → 归位。
            // 用 keyframe 才有「双跳」的手感，autoreverses 只会变成单次来回。
            CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
            k.values = @[@1.0, @1.15, @1.0, @1.15, @1.02, @1.0];
            k.keyTimes = @[@0.0, @0.18, @0.38, @0.56, @0.78, @1.0];
            k.duration = 1.1;
            k.repeatCount = HUGE_VALF;
            k.fillMode = kCAFillModeBoth;
            k.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            k.beginTime = now + stagger[i] + 0.16;
            [l addAnimation:k forKey:@"slBar"];
        } else {
            CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
            a.fromValue = @(lo);
            a.toValue = @(1.0);
            a.duration = half;
            a.autoreverses = YES;
            a.repeatCount = HUGE_VALF;
            a.fillMode = kCAFillModeBoth;
            a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            a.beginTime = now + stagger[i];
            [l addAnimation:a forKey:@"slBar"];
        }
    }
}

#pragma mark 状态

- (void)sl_applyState:(SLFloatState)state {
    SLFloatState prev = self.slState;
    self.slState = state;

    UIColor *accent = nil;
    // v0.4.52：四种状态各自一个颜色。原来「合成中」和「已装填」都是蓝，肉眼分不出
    // 到底是在生成还是已经就绪 —— 就绪单独用绿。
    if (state == SLFloatStateRecording) accent = [UIColor systemRedColor];
    else if (state == SLFloatStateSynthesizing) accent = [UIColor systemBlueColor];
    else if (state == SLFloatStateReady) accent = [UIColor systemGreenColor];

    // v0.4.37：状态色加深到 26% 并铺满整条胶囊（见 layout 里的 _tint.frame），
    // 过渡用 0.26s 淡入淡出，避免蓝 → 白硬切。
    UIColor *fill = accent ? [accent colorWithAlphaComponent:0.26] : [UIColor clearColor];
    // v0.4.57：所有着色元素（胶囊底、分隔线、字形 tint、四杠、名字）一起做 0.26s 交叉淡入淡出。
    // 原来只有 _tint 在动画块里，四杠/字形/名字是瞬间换色，蓝→绿会「啪」地硬切（录屏确认一帧跳变）。
    // 现在把颜色改动全收进同一个动画块，整颗球颜色平滑过渡；光环描边是 CAShapeLayer 属性，
    // UIView 块管不到，单独用 CATransaction 在 sl_startBreath 之后交叉淡出（见下）。
    [UIView animateWithDuration:0.26 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_tint.backgroundColor = fill;
        self->_tint.alpha = accent ? 1.0 : 0.0;
        self->_sep.backgroundColor = accent ? [accent colorWithAlphaComponent:0.35]
                                            : [UIColor colorWithWhite:0.5 alpha:0.28];
        self->_glyph.tintColor = accent ?: [UIColor labelColor];
        self->_name.textColor = accent ?: [UIColor labelColor];
        // 四杠跟着换色：几何不变，只有背景色随动画块交叉淡入淡出（as[i] 透明度恒定）
        [self sl_layoutBars];
    } completion:nil];
    [self sl_updateBarMotion];
    // v0.4.57：合成完成→就绪，整颗胶囊轻轻「落定」一下（缩放回弹），
    // 给一个完成的确认感，让蓝→绿是「稳稳完成」而不是「硬切」。只在这一个方向触发。
    if (prev == SLFloatStateSynthesizing && state == SLFloatStateReady) {
        [self sl_playCompletionSettle];
    }
    // v0.4.50：四套节奏的幅度差得远（0.30 / 0.55 / 0.86 / 1.15），硬切会「跳一下」。
    // 状态真变了就让四杠做一次 0.18s 淡入，把新节奏揉进去，不至于突兀。
    if (prev != state && _bars && !_bars.hidden) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @(0.45);
        fade.toValue = @(1.0);
        fade.duration = 0.18;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [_bars.layer addAnimation:fade forKey:@"slFade"];
    }
    _readyDot.hidden = (state != SLFloatStateReady);

    // v0.4.57：光环描边是 CAShapeLayer 属性，UIView 动画块管不到，单独用 CATransaction 交叉淡出。
    // 必须放在 sl_startBreath 之后：后者会 removeAllAnimations，提前加的描边动画会被清掉。
    UIColor *halo = accent ?: [UIColor colorWithWhite:0.55 alpha:1.0];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.26];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    _haloIn.strokeColor = halo.CGColor;
    _haloOut.strokeColor = halo.CGColor;
    [CATransaction commit];
    [self sl_startBreath:state];

    // 发出去的那一刻：就绪→空闲，原地闪一下蓝光（不位移、不外扩）
    if (prev == SLFloatStateReady && state == SLFloatStateIdle) {
        [self sl_playPulse:[UIColor systemGreenColor]];
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

// v0.4.45：回到前台后重挂呼吸光晕。
// 进后台时系统会把图层上的动画整条移除（opacity 回落到 0），所以切回来灯就灭了；
// 这一路只有「状态变化」或「点一下球」才会重设，用户看着就是「要点一下才有」。
- (void)sl_restartHalo {
    if (self.window == nil) return;
    // 路径可能已经跟着展开 / 收起变过，先按当前 bounds 重算一遍再挂动画
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self sl_startBreath:self.slState];
    // v0.4.49：四杠循环动画同样会被系统在后台移除，回前台一并重挂
    [self sl_updateBarMotion];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

// v0.4.57：合成完成→就绪的「落定」反馈。整颗胶囊 0.5s 微涨后回弹
//（1.0 → 1.07 → 1.0），像被轻轻按了一下「好了」，配合绿色淡入，过渡不再硬切。
// 只动 layer.transform.scale，不动 frame，不影响点击区域与布局。
- (void)sl_playCompletionSettle {
    CAKeyframeAnimation *b = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    b.values = @[@1.0, @1.07, @1.0];
    b.keyTimes = @[@0.0, @0.35, @1.0];
    b.duration = 0.5;
    b.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    b.removedOnCompletion = YES;
    [self.layer addAnimation:b forKey:@"slSettle"];
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

    // v0.4.46：展开态拖动 = 「跟手 + 翻面 + 贴边」三件事。
    // v0.4.41 那版故意不吸附、且镜像只在展开那一刻算一次，结果把胶囊拖到另一边时
    // 内部布局一动不动 —— 看着就是「不贴边、不镜像」。
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
            [self sl_updateMirrorDuringDrag];            // 越过中线就翻面
            [SLPackMenu sl_repositionForAnchor:self];    // 打开的列表跟着走
        } else if (g.state == UIGestureRecognizerStateEnded
                   || g.state == UIGestureRecognizerStateCancelled) {
            [self sl_settlePillToEdge];                  // 松手贴到最近那条边
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

// v0.4.46：拖动中翻面。以屏幕中线为界，带 10pt 滞后 ——
// 没有滞回的话，胶囊中心在准线上时手指的微小抖动会让内部布局左右乱跳。
- (void)sl_updateMirrorDuringDrag {
    UIView *sv = self.superview;
    if (!sv) return;
    CGFloat mid = CGRectGetMidX(sv.bounds);
    CGFloat cx = CGRectGetMidX(self.frame);
    static const CGFloat kHyst = 10.0;

    BOOL want = _mirrored;
    if (!_mirrored && cx > mid + kHyst) want = YES;
    else if (_mirrored && cx < mid - kHyst) want = NO;
    if (want == _mirrored) return;

    _mirrored = want;
    // 直接换布局，不做插值：玻璃层跟着重排会留残影，而拖动时手指本身就在动，
    // 瞬间换边看着是「翻了个面」，比插值更像一体的 196pt 条。
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

// v0.4.46：松手贴边。图标那一端就是收起后球的位置，所以贴哪条边由它决定 ——
// 图标端在左半屏就贴左、在右半屏就贴右；镜像状态同时由贴边方向反推。
// 垂直方向不吸附（上下位置保持用户放的样子），只把新球位记下来。
- (void)sl_settlePillToEdge {
    UIView *sv = self.superview;
    if (!sv) return;
    CGSize sz = sv.bounds.size;
    CGRect f = self.frame;
    static const CGFloat kEdgePad = 6.0;

    CGFloat iconX = _mirrored ? (CGRectGetMaxX(f) - SLBallSide / 2.0)
                              : (CGRectGetMinX(f) + SLBallSide / 2.0);
    BOOL toLeft = (iconX < sz.width / 2.0);
    _mirrored = !toLeft;
    // 先把内部翻好再滑动：两步都在一帧里完成，但顺序上「先确定面孔再挪位置」，
    // 不会出现滑到一半内部还在旧朝向。
    [self setNeedsLayout];
    [self layoutIfNeeded];

    CGRect nf = f;
    nf.origin.x = toLeft ? kEdgePad : (sz.width - kEdgePad - f.size.width);
    if (nf.origin.x < kEdgePad) nf.origin.x = kEdgePad;   // 胶囊比屏还宽时只保证左缘不越界

    [UIView animateWithDuration:0.26 delay:0
         usingSpringWithDamping:0.86 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.frame = nf; }
                     completion:nil];

    CGPoint c = CGPointMake(_mirrored ? (CGRectGetMaxX(nf) - SLBallSide / 2.0)
                                      : (CGRectGetMinX(nf) + SLBallSide / 2.0),
                            CGRectGetMidY(nf));
    SLStoreFloatPos(SLClampFloatPos(c, sz), sz);
    [SLPackMenu sl_repositionForAnchor:self];
}

- (void)sl_tap {
    // 长按刚结束时个别机型还会补一次 touchUpInside，这里挡掉，免得胶囊一展开就被收回
    if (CFAbsoluteTimeGetCurrent() - _longPressAt < 0.7) return;
    // v0.4.45：展开态点中间不做任何事 —— 用户要的是「点名字毫无反应，只有按住能拖」。
    // 收回成球只认图标那一端（_homeBtn → sl_homeTap）。
    if (self.slExpanded) return;
    // 关掉「启用语音包」后点球不展开，也不弹任何提示：想让球消失是用户的选择，
    // 不需要每次点都被告知一遍怎么打开设置。
    if (![SLVoicePack isEnabled]) return;
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
    if (CFAbsoluteTimeGetCurrent() - _longPressAt < 0.7) return;
    [self sl_expand:NO animated:YES];
}

- (void)sl_menuTap {
    // v0.4.43：箭头是开关。原来每次点击都「先关旧的再开一张」，看着像点了没反应 ——
    // 关不掉列表，只能点空白处。
    if ([SLPackMenu sl_isShowing]) {
        [SLPackMenu sl_dismissCurrent];
        return;
    }
    [SLPackMenu showFromAnchor:self];
}

- (void)sl_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    _longPressAt = CFAbsoluteTimeGetCurrent();
    // v0.4.47：球态长按任意处进设置；胶囊态仅 logo 端（图标那一端）长按进设置，
    // 中段长按留给拖动——「长按 logo 进设置」与「长按中段拖动」互不冲突。
    if (self.slExpanded) {
        CGPoint p = [g locationInView:self];
        if (!CGRectContainsPoint(_homeBtn.frame, p)) return;
    }
    UIViewController *top = [AWECAUtils topViewController];
    if (!top) return;
    [SLFloatPanelController presentSettingsFrom:top];
    // 重新打时间戳：松手时的 touchUpInside 不会再误触发「展开 / 收起」
    _longPressAt = CFAbsoluteTimeGetCurrent();
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
    // v0.4.49：四杠容器跟随 _glyph 的位置与显隐；自定义头像 / emoji 时自动让位
    _bars.frame = _glyph.frame;
    _bars.hidden = _glyph.hidden;
    [self sl_layoutBars];
    // v0.4.44：自定义图标在球态是铺满 48 的，展开态原来缩到 42，切胶囊时明显小一圈。
    // 改成两种形态都用满 48（左端留出一整块圆形），球和胶囊的图标视觉尺寸就一致了。
    CGFloat iconS = SLBallSide;
    _thumb.frame = exp ? CGRectMake(SLMX(0.0, iconS), 0, iconS, iconS) : b;
    _thumb.layer.cornerRadius = MIN(CGRectGetWidth(_thumb.bounds), CGRectGetHeight(_thumb.bounds)) / 2.0;
    _emoji.font = [UIFont systemFontOfSize:22.0];   // v0.4.44：emoji 图标同样不缩
    _emoji.frame = exp ? CGRectMake(SLMX(0.0, iconS), 0, iconS, iconS) : b;

    // v0.4.37：状态色铺满整条胶囊。原来展开态只盖左侧 48pt 圆，
    // 球是蓝的、胶囊还是白玻璃，中间像被切断。
    _tint.frame = b;
    _tint.layer.cornerRadius = h / 2.0;

    // v0.4.40：两端各一块 48pt 热区，中间 100pt 给名字（居中）。
    // 镜像时两端互换、中间不动 —— 图标端跟着球走，箭头端永远在远端。
    // v0.4.45：分隔线从 48 右移到 57。
    // 自定义图片在展开态铺满左端那一整个 48pt 圆（跟球态同尺寸，切换不缩水），
    // 线正好压在 48 上就等于贴着图片边缘，看着像图片被切了一刀。
    // 名字区跟着线一起让开（下面几行），文字在「线 → 箭头」之间居中。
    _sep.frame = CGRectMake(SLMX(57.0, 0.5), (h - 18.0) / 2.0, 0.5, 18.0);
    {
        CGFloat nx = mir ? 48.0 : 57.0;
        CGFloat nw = MAX(0.0, w - nx - (mir ? 57.0 : 48.0));
        _name.frame = CGRectMake(nx, 0, nw, h);
    }
    // v0.4.45：中间这块必须有个真的控件接走触摸，否则触摸落到 self 上会被收走。
    // 这里只接触摸、不挂 target —— 点名字什么都不该发生。
    _midBtn.frame = exp ? CGRectMake(48.0, 0, MAX(0, w - 96.0), h) : CGRectZero;
    _menuBtn.frame = exp ? CGRectMake(SLMX(w - 48.0, 48.0), 0, 48.0, h) : CGRectZero;
    _chev.frame = CGRectMake(18.5, (h - 11.0) / 2.0, 11.0, 11.0);
    _homeBtn.frame = exp ? CGRectMake(SLMX(0.0, 48.0), 0, 48.0, h) : CGRectZero;
    _homeHit.frame = _homeBtn.bounds;
    _readyDot.frame = CGRectMake(mir ? 5.0 : (w - 14.0), 3.0, 9.0, 9.0);
#undef SLMX

    _sep.hidden = !exp;
    _name.hidden = !exp;
    _midBtn.hidden = !exp;
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

// v0.4.43：哪些文件夹在下拉列表里是展开的。
// 默认全收起（这样一屏能看全有哪几个组），但把「当前已装填那条所在组」自动展开，
// 免得用户打开列表却看不见自己在用的是哪个。
static NSMutableSet<NSString *> *sSLExpandedFolders = nil;
static NSMutableSet<NSString *> *SLExpandedFolderSet(void) {
    if (!sSLExpandedFolders) {
        sSLExpandedFolders = [NSMutableSet set];
        if ([SLVoicePack isOneShotPending]) {
            NSString *f = [SLVoicePack activePack][@"folder"];
            if (f.length) [sSLExpandedFolders addObject:f];
        }
    }
    return sSLExpandedFolders;
}

@implementation SLPackMenu {
    UIControl *_catcher;
    UIView *_card;
    UIVisualEffectView *_blur;
    UIView *_hair;
    UIScrollView *_list;
    NSArray<NSDictionary *> *_nodes;      // 渲染节点：分组头 / 语音包 / 空占位
    NSMutableArray<UIView *> *_rowViews;
    CGFloat _cardW;
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

+ (BOOL)sl_isShowing {
    return sSLPackMenu != nil;
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

// v0.4.43：外壳只建一次（卡片 / 玻璃 / 描边 / 滚动容器）。
// 行视图交给 sl_renderRows —— 折叠切换时只重建行、不动玻璃层，
// 免得 UIVisualEffectView 反复改尺寸又留残影。
- (void)sl_buildWithAnchor:(UIView *)anchor {
    _anchor = anchor;
    CGRect ar = [anchor convertRect:anchor.bounds toView:self];
    CGFloat cardW = CGRectGetWidth(ar);
    if (cardW < 120.0) cardW = 196.0;   // 胶囊还没展开时拿不到宽度
    _cardW = cardW;

    _card = [[UIView alloc] initWithFrame:[self sl_cardFrameForAnchor:anchor width:cardW height:120.0]];
    _card.layer.cornerRadius = 22.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.20;
    _card.layer.shadowRadius = 20.0;
    _card.layer.shadowOffset = CGSizeMake(0, 8);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:22.0].CGPath;
    [self addSubview:_card];

    // v0.4.46：跟胶囊同一套超薄材质，下来时不会「突然变实」。
    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    _blur.frame = _card.bounds;
    _blur.layer.cornerRadius = 22.0;
    _blur.layer.cornerCurve = kCACornerCurveContinuous;
    _blur.clipsToBounds = YES;
    [_card addSubview:_blur];

    // v0.4.46：跟胶囊边缘同一个规格（0.8pt / 0.6）—— 材质透下来之后，
    // 这圈高光是「玻璃」和「背景」之间唯一的界线。
    _hair = [[UIView alloc] initWithFrame:CGRectInset(_card.bounds, 0.4, 0.4)];
    _hair.layer.cornerRadius = 21.6;
    _hair.layer.cornerCurve = kCACornerCurveContinuous;
    _hair.layer.borderWidth = 0.8;
    _hair.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    _hair.userInteractionEnabled = NO;
    [_card addSubview:_hair];

    _list = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _list.showsVerticalScrollIndicator = NO;
    _list.alwaysBounceVertical = NO;
    _list.backgroundColor = [UIColor clearColor];
    [_card addSubview:_list];

    [self sl_buildNodes];
    [self sl_renderRows];

    _card.alpha = 0.0;
    _card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    _card.transform = CGAffineTransformTranslate(_card.transform, 0, -6);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_card.alpha = 1.0;
        self->_card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

// v0.4.43：把包按文件夹摊成节点序列。
// 只有一个组时不出标题（多一行纯属浪费）；多个组时每组一行可点的标题，默认收起。
- (void)sl_buildNodes {
    NSMutableArray<NSDictionary *> *nodes = [NSMutableArray array];
    NSArray<NSDictionary *> *all = [SLVoicePack allPacks];
    if (!all.count) {
        // 一条包都没有时给一行说明，别弹出一张只有内边距的空卡片
        _nodes = @[@{@"kind": @"empty", @"title": @"还没有语音包 · 长按球进设置导入"}];
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray *> *byFolder = [NSMutableDictionary dictionary];
    for (NSString *f in [SLVoicePack folders]) {
        if ([f isEqualToString:@"未分组"]) continue;      // 未分组永远排最后
        NSArray *packs = [SLVoicePack packsInFolder:f];
        if (!packs.count) continue;
        [names addObject:f];
        byFolder[f] = packs;
    }
    NSArray *ungrouped = [SLVoicePack packsInFolder:@"未分组"];
    NSInteger groups = (NSInteger)names.count + (ungrouped.count ? 1 : 0);

    // 就一个组的时候，标题行纯属多余，直接平铺
    if (groups <= 1) {
        NSArray *flat = ungrouped.count ? ungrouped
                       : (names.count ? byFolder[names.firstObject] : all);
        for (NSDictionary *p in flat) {
            [nodes addObject:@{@"kind": @"pack", @"title": p[@"name"] ?: @"未命名", @"pack": p}];
        }
        _nodes = nodes;
        return;
    }

    NSMutableSet<NSString *> *expanded = SLExpandedFolderSet();
    for (NSString *f in names) {
        NSArray *packs = byFolder[f];
        BOOL exp = [expanded containsObject:f];
        [nodes addObject:@{@"kind": @"group", @"title": f, @"key": f,
                           @"count": @(packs.count), @"expanded": @(exp)}];
        if (!exp) continue;
        for (NSDictionary *p in packs) {
            [nodes addObject:@{@"kind": @"pack", @"title": p[@"name"] ?: @"未命名", @"pack": p}];
        }
    }
    if (ungrouped.count) {
        NSString *key = @"未分组";
        BOOL exp = [expanded containsObject:key];
        [nodes addObject:@{@"kind": @"group", @"title": key, @"key": key,
                           @"count": @(ungrouped.count), @"expanded": @(exp)}];
        if (exp) {
            for (NSDictionary *p in ungrouped) {
                [nodes addObject:@{@"kind": @"pack", @"title": p[@"name"] ?: @"未命名", @"pack": p}];
            }
        }
    }
    _nodes = nodes;
}

// v0.4.43：按 _nodes 重建行，并重算卡片高度（折叠时行数会变）。
- (void)sl_renderRows {
    for (UIView *v in _list.subviews) [v removeFromSuperview];
    _rowViews = [NSMutableArray array];

    // v0.4.39：行高 44 → 48，给左侧 30pt 圆形试听键留出上下各 9pt
    static const CGFloat kRowH = 48.0;
    static const CGFloat kGroupH = 34.0;
    CGFloat w = _cardW;
    CGFloat y = 0.0;

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                                                       weight:UIImageSymbolWeightSemibold];
    for (NSUInteger i = 0; i < _nodes.count; i++) {
        NSDictionary *info = _nodes[i];
        BOOL isGroup = [info[@"kind"] isEqualToString:@"group"];
        CGFloat h = isGroup ? kGroupH : kRowH;

        if (isGroup) {
            SLPackGroupRow *g = [[SLPackGroupRow alloc] initWithFrame:CGRectMake(0, y, w, h)];
            g.tag = (NSInteger)i;
            g.name.text = info[@"title"];
            g.count.text = [NSString stringWithFormat:@"%ld", (long)[info[@"count"] integerValue]];
            g.expanded = [info[@"expanded"] boolValue];
            [g addTarget:self action:@selector(sl_groupTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_list addSubview:g];
            [_rowViews addObject:g];
            y += h;
            continue;
        }

        NSDictionary *pack = info[@"pack"];
        SLPackMenuRow *r = [[SLPackMenuRow alloc] initWithFrame:CGRectMake(0, y, w, h)];
        r.tag = (NSInteger)i;
        r.title.text = info[@"title"];

        // v0.4.40：「选中」= 已装好、等下一录音的那一条（不是「上次用过的那条」）。
        // 发出去之后 pending 被清，这里就不再点亮。
        BOOL on = pack && [SLVoicePack isOneShotPending] && [SLVoicePack isPackActive:pack];
        // 左侧 30pt 圆形试听键：点它只试听、不选中；点名称那侧才是装填 / 撤销
        BOOL placeholder = (pack == nil);
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
        r.title.textColor = on ? [UIColor systemBlueColor] : (placeholder ? [UIColor secondaryLabelColor] : [UIColor labelColor]);
        r.title.font = [UIFont systemFontOfSize:14.0 weight:(on ? UIFontWeightSemibold : UIFontWeightRegular)];
        [r addTarget:self action:@selector(sl_rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_list addSubview:r];
        [_rowViews addObject:r];

        NSDictionary *next = (i + 1 < _nodes.count) ? _nodes[i + 1] : nil;
        BOOL nextIsGroup = (next != nil) && [next[@"kind"] isEqualToString:@"group"];
        if (next && !nextIsGroup && !placeholder) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(50, y + h - 0.25, w - 50 - 12, 0.5)];
            line.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.10];
            line.userInteractionEnabled = NO;
            [_list addSubview:line];
        }
        y += h;
    }

    if (y < 1.0) y = kRowH;
    _list.contentSize = CGSizeMake(w, y);

    // 最多露 5 行的高度，再多就在卡片内部滚
    CGFloat cardH = MIN(y, kRowH * 5.0) + 12.0;
    _card.frame = [self sl_cardFrameForAnchor:_anchor width:w height:cardH];
    _blur.frame = _card.bounds;
    _hair.frame = CGRectInset(_card.bounds, 0.4, 0.4);
    _list.frame = CGRectMake(0, 6, w, cardH - 12.0);
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:22.0].CGPath;
}

- (void)sl_groupTapped:(UIControl *)row {
    if (row.tag < 0 || row.tag >= (NSInteger)_nodes.count) return;
    NSString *key = _nodes[(NSUInteger)row.tag][@"key"];
    if (!key.length) return;
    NSMutableSet<NSString *> *set = SLExpandedFolderSet();
    if ([set containsObject:key]) [set removeObject:key];
    else [set addObject:key];
    [self sl_buildNodes];
    [self sl_renderRows];
}

#pragma mark 试听

// v0.4.39：点行左侧的圆形键试听这个语音包的第一条音频。
// 只是"听一下是什么味"，不改变当前选择 —— 选中仍然要点名称那一侧。
- (void)sl_playTapped:(UIButton *)btn {
    NSInteger idx = btn.tag;
    if (idx < 0 || idx >= (NSInteger)_nodes.count) return;
    NSDictionary *info = _nodes[(NSUInteger)idx];
    if (!info[@"pack"]) return;   // 分组头 / 空占位没有音频可试听

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
    UIView *v = _rowViews[(NSUInteger)idx];
    if (![v isKindOfClass:[SLPackMenuRow class]]) return;   // 分组标题没有试听态
    SLPackMenuRow *r = (SLPackMenuRow *)v;
    // 停止试听后要回落到「这一行本来该有的样子」：选中行仍然是蓝底，别被刷成灰的
    NSDictionary *info = (idx < (NSInteger)_nodes.count) ? _nodes[(NSUInteger)idx] : nil;
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
    if (row.tag < 0 || row.tag >= (NSInteger)_nodes.count) return;
    NSDictionary *pack = _nodes[(NSUInteger)row.tag][@"pack"];
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
/// v0.4.44：卡片圆角的硬裁剪（mask 比 clipsToBounds 可靠，contentView 是系统私有类）
@property (nonatomic, strong) CAShapeLayer *cardMask;
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UINavigationController *nav;
@property (nonatomic, strong) UIViewController *rootVC;
- (void)sl_applyNavTransparency;
- (void)sl_clearOpaqueBackdrops:(UIView *)view depth:(NSInteger)depth;
- (void)sl_fixScrollInsetsIn:(UIView *)view top:(CGFloat)top;
@end

// v0.4.55：记住当前浮窗实例，避免长按球等在设置已开时又叠第二层
static SLFloatPanelController *sSLFloatPanel = nil;

@implementation SLFloatPanelController

+ (void)presentFrom:(UIViewController *)host root:(UIViewController *)root {
    if (!host || !root) return;
    // v0.4.55：设置已开时长按球，topViewController 返回的是设置页本身（它没再 present 东西），
    // 旧判断 host.presentedViewController 拦不住，会叠第二层。改用全局实例判断。
    if (sSLFloatPanel && sSLFloatPanel.presentingViewController) return;
    // 已经有浮窗开着就不叠第二层，避免连点两次出现两张卡片
    if (host.presentedViewController) return;
    SLFloatPanelController *vc = [[SLFloatPanelController alloc] init];
    sSLFloatPanel = vc;
    vc.rootVC = root;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    // v0.4.54：浮窗盖上来之后把球重新抬到最上层，别让卡片压住它
    [host presentViewController:vc animated:YES completion:^{
        SLRaiseFloatButton();
    }];
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
    // v0.4.46：0.16 → 0.10。卡片本身变透了，压暗层太重会把透出来的背景压成一片灰。
    self.dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.10];
    [self.dim addTarget:self action:@selector(sl_dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dim];

    // 尺寸在 viewWillLayoutSubviews 里算：viewDidLoad 时 bounds 还没定下来
    self.cardWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.cardWrap.layer.shadowColor = [UIColor blackColor].CGColor;
    self.cardWrap.layer.shadowOpacity = 0.22;
    self.cardWrap.layer.shadowRadius = 24;
    self.cardWrap.layer.shadowOffset = CGSizeMake(0, 10);
    // v0.4.46：材质换成超薄之后整体更透了，玻璃的「厚度」靠这圈边缘高光交代。
    // 0.8pt 而不是 1pt：再粗就成了画框，不像玻璃边。深色下用低透白，否则在暗背景上会发灰。
    self.cardWrap.layer.cornerRadius = 26.0;
    self.cardWrap.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardWrap.layer.borderWidth = 0.8;
    self.cardWrap.layer.borderColor =
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.16]
                : [UIColor colorWithWhite:1.0 alpha:0.58];
        }].CGColor;
    [self.view addSubview:self.cardWrap];

    // v0.4.46：设置浮窗同样换成超薄材质 —— 三页共用这个容器，一处改完全透。
    self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    self.blur.layer.cornerRadius = 26;
    self.blur.layer.cornerCurve = kCACornerCurveContinuous;
    self.blur.clipsToBounds = YES;
    // v0.4.43：圆角裁剪必须同时设在 contentView 上。
    // UIVisualEffectView 只在「玻璃层」裁，contentView 里的子视图（导航栏、搜索栏、白背板）
    // 照样能画到圆角外面 —— 这就是白条两端变成直角、戳在弧线外的原因。
    self.blur.contentView.clipsToBounds = YES;
    self.blur.contentView.layer.cornerRadius = 26;
    self.blur.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    [self.cardWrap addSubview:self.blur];

    // v0.4.44：兜底裁剪交给 mask。
    // contentView 是系统私有类（_UIVisualEffectContentView），clipsToBounds 不一定听话；
    // mask 是硬约束，卡片里任何东西都出不了这个圆角矩形。
    // 注意 mask 挂在 blur 上而不是 cardWrap 上 —— cardWrap 还要投阴影，mask 会把阴影一起裁掉。
    self.cardMask = [CAShapeLayer layer];
    self.blur.layer.mask = self.cardMask;

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
    UIImage *clear1x1 = SLTransparentImage();
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithTransparentBackground];
        ap.backgroundColor = [UIColor clearColor];
        ap.backgroundEffect = nil;
        ap.shadowColor = [UIColor clearColor];
        // v0.4.43：必须显式给一张「真」透明背景图。configureWithTransparentBackground 只清
        // backgroundColor，backgroundImage 为 nil 时系统会自己补一张默认图 ——
        // 那张图顶部纯白、向下渐隐，正是「顶部一条白边」的形状。
        ap.backgroundImage = clear1x1;
        nb.standardAppearance = ap;
        nb.compactAppearance = ap;
        nb.scrollEdgeAppearance = ap;
        if (@available(iOS 15.0, *)) nb.compactScrollEdgeAppearance = ap;
    }
    // 老接口一起上：部分页面（自带背景图 / 自定义返回按钮）会走这条路，
    // 新老两条都设成空，哪条生效都不会再有白底。
    nb.translucent = YES;
    nb.backgroundColor = [UIColor clearColor];
    nb.opaque = NO;
    [nb setBackgroundImage:clear1x1 forBarMetrics:UIBarMetricsDefault];
    [nb setBackgroundImage:clear1x1 forBarMetrics:UIBarMetricsCompact];
    nb.shadowImage = clear1x1;
    // v0.4.43：UINavigationController 会在布局周期里把自己的 view 底色刷回 systemBackground，
    // 只在 viewDidLoad 设一次 clear 是不够的 —— 顶部露出的那一条白很可能就是它。
    self.nav.view.backgroundColor = [UIColor clearColor];
    self.nav.view.opaque = NO;
}

// v0.4.43：把导航栏链路上仍不透明的系统背板（_UIBarBackground / TransitionView 之类）清掉。
// 只认类名，不碰表格和滚动视图，避免把页面自己的底色误伤。
- (void)sl_clearOpaqueBackdrops:(UIView *)view depth:(NSInteger)depth {
    if (depth > 4 || !view) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIScrollView class]]) continue;   // 表格 / 地图自己管自己
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"Transition"] || [cls containsString:@"Wrapper"]
            || [cls containsString:@"BarBackground"]) {
            if (sub.backgroundColor && ![sub.backgroundColor isEqual:[UIColor clearColor]]) {
                sub.backgroundColor = [UIColor clearColor];
            }
            sub.opaque = NO;
        }
        [self sl_clearOpaqueBackdrops:sub depth:depth + 1];
    }
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // 系统在布局周期会重置导航栏外观，这里是必须补刷的一次
    [self sl_applyNavTransparency];
    [self sl_clearOpaqueBackdrops:self.nav.view depth:0];
    CGSize ss = self.view.bounds.size;
    if (ss.width < 1.0 || ss.height < 1.0) return;
    self.dim.frame = self.view.bounds;
    // 宽度留 12pt 边，高度固定占屏幕 66%（上限 560），不做拖拽
    CGFloat w = MIN(ss.width - 24.0, 380.0);
    CGFloat h = MIN(ss.height * 0.66, 560.0);
    CGRect r = CGRectMake(round((ss.width - w) / 2.0), round((ss.height - h) / 2.0) - 18.0, w, h);
    if (!CGRectEqualToRect(self.cardWrap.frame, r)) self.cardWrap.frame = r;
    self.blur.frame = self.cardWrap.bounds;
    // v0.4.44：尺寸变了就重画 mask，否则圆角裁在旧尺寸上（会裁掉一侧）
    self.cardMask.frame = self.blur.bounds;
    self.cardMask.path = [UIBezierPath bezierPathWithRoundedRect:self.blur.bounds
                                                   cornerRadius:26.0].CGPath;
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
        // 底色必须是透的，滚动时露出的是浮窗那层毛玻璃。
        // v0.4.43：表格设了 backgroundView 时 backgroundColor 会被它盖住，
        // 那个 backgroundView 默认就是一块浅白 —— 一并去掉。
        if ([sv isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)sv;
            if (tv.backgroundView) tv.backgroundView = nil;
        }
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
    // v0.4.54：卡片进场动画结束时再抬一次球（present 的 completion 有时早于最后一次布局）
    SLRaiseFloatButton();
}

- (void)sl_dismiss {
    sSLFloatPanel = nil;
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
    sSLFloatPanel = nil;
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

// v0.4.54：把球抬到最上层。
// 设置浮窗与试听卡片都是 OverFullScreen 呈现，直接盖在球上面 —— 用户看到的是
// 「球被卡片压掉一半」。这里在面板每次出现后调一次：球若落在别的窗口就先迁到最顶层窗口，
// 再在同一个窗口里 bringSubviewToFront；转场结束后补抬一次（系统重排图层会把它压回去）。
void SLRaiseFloatButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SLFloatButton *btn = sSLFloatBtn;
        if (!btn) {
            UIWindow *w0 = SLKeyWindow();
            btn = (SLFloatButton *)[w0 viewWithTag:SLBtnTag];
        }
        if (!btn) return;

        UIWindow *top = SLKeyWindow();
        UIWindow *host = btn.window;
        if (top && host && top != host && top.windowLevel >= host.windowLevel) {
            [btn removeFromSuperview];
            [top addSubview:btn];
            host = top;
        }
        [host bringSubviewToFront:btn];

        __weak SLFloatButton *weakBtn = btn;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLFloatButton *b = weakBtn;
            if (!b || !b.superview) return;
            [b.superview bringSubviewToFront:b];
        });
    });
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
    // v0.4.50：跟设置页统一 —— 毛玻璃底 + 胶囊标题 + 胶囊「完成」
    self.navigationItem.titleView = SLPillTitleView(@"悬浮球图标");
    SLInstallPillBack(self);   // v0.4.53：返回键胶囊
    SLApplyGlassTable(self.tableView);
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"完成", self, @selector(sl_done));
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

// v0.4.50：单元格底色统一刷玻璃片（表格透明后不刷就是纯灰行）
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv; (void)ip;
    cell.backgroundColor = SLGlassCellColor();
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
