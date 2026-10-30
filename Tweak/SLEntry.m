#import "SLEntry.h"
#import "SLSettingsPanel.h"
#import "SLVoicePackController.h"
#import "SLVoicePack.h"
#import "AWECAUtils.h"
#import "SLLog.h"
#import "SLGlass.h"
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#include <stdlib.h>   // v0.4.75：SLHazeImage 里的 calloc/free

// ===================== 悬浮球图标 =====================
// v0.4.33：默认图标换成「双声波」品牌图形（代码绘制，黑底 + 六根条：
// 左三根 30% 白表示被替换掉的原声，右三根纯白表示合成声）。
// 存一个字符串：
//   brand            品牌图形（默认）
//   image:icon.png   相册选的自定义图片（已裁成圆形，存沙盒）
//   text:xxx         旧版遗留值，读取时自动迁移成默认
#define kSLFloatIconKey @"SLFloatIcon"
#define kSLFloatIconDefault @"brand"

// v0.4.74：自定义图标动效。外圈（光晕 + 26% 状态底色）永远不动，
// 四态差异全部由图标自身的运动表达。
// v0.4.80：动效不再是可选项 —— 设置页里「图标动效」整段删掉，只要当前图标是
// 自定义图片就默认走律动（四态缩放，合成态「泵动」：慢缩 → 急弹 → 缓落）。
// 这个键 v0.4.80 起不再读写，留着只为旧版本存过的值不显得突兀。
#define kSLFloatEffectKey @"SLFloatEffect"

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

// v0.4.75：胶囊底色 = 图标图的「色晕」。
// 把图片降采样成 32×6 再交给 UIImageView 拉伸，靠 layer 的线性插值自己平滑成一条横向色带。
// 只留大块明暗与色相分布、不留任何细节，所以胶囊上不会出现「一张缩略图糊上去」。
// 取景跟 _thumb 的 aspectFill 对齐（中心横条），色晕和图标才是同一段画面。
// v0.4.76：目标网格改成参数 —— 胶囊用 32×6；列表卡片用 6×1（面积大，32 段会拉出竖光带）。
static UIImage *SLHazeImage(UIImage *src, size_t w, size_t h) {
    if (!src.CGImage || w == 0 || h == 0) return nil;
    unsigned char *buf = (unsigned char *)calloc(w * h * 4, sizeof(unsigned char));
    if (!buf) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return nil; }

    CGImageRef cg = src.CGImage;
    CGFloat iw = (CGFloat)CGImageGetWidth(cg), ih = (CGFloat)CGImageGetHeight(cg);
    CGFloat bandH = iw * (CGFloat)h / (CGFloat)w;   // 保持宽高比，别把脸压扁
    if (bandH > ih) bandH = ih;
    CGImageRef part = CGImageCreateWithImageInRect(cg, CGRectMake(0.0, (ih - bandH) * 0.5, iw, bandH));
    if (part) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, (CGFloat)w, (CGFloat)h), part);
        CGImageRelease(part);
    }
    CGImageRef small = CGBitmapContextCreateImage(ctx);
    UIImage *out = small ? [UIImage imageWithCGImage:small scale:1.0 orientation:UIImageOrientationUp] : nil;
    if (small) CGImageRelease(small);
    CGContextRelease(ctx);
    free(buf);
    return out;
}

static NSString *SLFloatIconValue(void) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLFloatIconKey];
    if (!v.length) return kSLFloatIconDefault;
    if ([v hasPrefix:@"text:"]) return kSLFloatIconDefault;        // 旧版文字图标 → 默认
    return v;
}

// v0.4.80：没有「关闭」这一档了。只要图标是自定义图片就走律动，
// 真正决定动不动的是 sl_updateIconMotion 里的「当前有没有图」——
// 默认四杠形态本来就是自己那套逐根动画，不走这里。
static NSInteger SLFloatEffectValue(void) {
    return 1;
}

NSString *SLFloatIconSummary(void) {
    NSString *v = SLFloatIconValue();
    NSString *base = @"默认";
    if ([v hasPrefix:@"image:"]) base = @"自定义图片";
    // v0.4.80：动效固定随图片开启，右侧不再挂「· 律动」后缀
    return base;
}

// 品牌图形：黑底圆 + 六根圆角条。100 单位为画布基准，跟设计稿一一对应，
// 线条宽度、间距、条高都按比例缩放，48pt 球和 20pt 标题栏图标是同一张图。
// v0.4.95：品牌四杠的唯一几何。100 单位为画布基准，短长长短，
// 左两淡 = 被替换的原声，右两实 = 合成声。
//
// 标题栏原先走的是另一套六杠（条宽 6u、间距 4u），可它在标题栏只显示 22pt，
// 折下来条宽 1.32pt、前三根还是 30% 白 —— 3x 屏上就是 4px 的灰雾，
// 跟球的四条看不出是同一个标志。现在两处引用同一份数组，不再分叉。
static const CGFloat kSLBrandBarX[4] = {12, 34, 56, 78};
static const CGFloat kSLBrandBarH[4] = {24, 46, 40, 28};
static const CGFloat kSLBrandBarA[4] = {0.30, 0.30, 1.0, 1.0};
static const CGFloat kSLBrandBarW = 10.0;

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
        CGFloat w = kSLBrandBarW * u;
        for (int i = 0; i < 4; i++) {
            CGFloat h = kSLBrandBarH[i] * u;
            CGRect bar = CGRectMake(kSLBrandBarX[i] * u, (side - h) / 2.0, w, h);
            [[UIColor colorWithWhite:1.0 alpha:kSLBrandBarA[i]] setFill];
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
        // v0.4.95：几何统一走 kSLBrandBar*，与标题栏图标同一份
        CGFloat w = kSLBrandBarW * u;
        for (int i = 0; i < 4; i++) {
            CGFloat h = kSLBrandBarH[i] * u;
            CGRect bar = CGRectMake(kSLBrandBarX[i] * u, (side - h) / 2.0, w, h);
            [[c colorWithAlphaComponent:kSLBrandBarA[i]] setFill];
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

// v0.4.94：球贴边时左右留多少。
// 原来只留 4pt —— 球本体确实在屏内，但呼吸光环是向外扩的（_haloIn +2.5 / _haloOut +7），
// 贴边那一刻外圈有 3pt 被屏幕切平，看上去就是「球的边缘被遮住一点」，
// 而且球本身离屏幕边只隔 4pt，视觉上也像压着边框。统一提到 10pt：
// 外圈光环完整落在屏内（10 - 7 = 3），球体与屏幕之间也有一段干净的呼吸空间。
// 所有「贴边」路径（拖动夹取 / 松手吸附 / 收起落位 / 展开改宽 / 恢复位置）都用这一个值。
static const CGFloat kSLFloatEdgePad = 10.0;

// v0.4.60：合成完成「落定」回弹的静音开关。
// 试听面板那条路本身有卡片弹入动画，「完成」的信号已经给足了，球再缩一下就撞车；
// 所以在面板路径上临时静音，只有「无面板直接就绪」才保留回弹。
static BOOL sSLFloatSettleMuted = NO;

// ===================== 浮动入口 =====================

#define SLBtnTag 20931

// ===================== 设置 / 语音包浮窗 =====================
// v0.4.33：设置页不再用 PageSheet 从底部整页推上来，改成一张固定尺寸的
// 圆角毛玻璃浮窗，浮在陌陌界面中间。尺寸写死，只有窗内内容能滚动。
// v0.4.34：语音包也住进同一个容器（原先还是 PageSheet，跟设置页两套观感）。

@interface SLFloatPanelController : UIViewController
+ (void)presentFrom:(UIViewController *)host root:(UIViewController *)root;
+ (void)presentSettingsFrom:(UIViewController *)host;
+ (BOOL)isSettingsOpen;
+ (void)dismissSettings;
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
// v0.4.84：196 → 218。「最大尺寸」的语义是「毛玻璃层固定多大」，而 v0.4.82 的
// 合成态胶囊做到了 218 —— 比毛玻璃还宽 22pt。那 22pt 没有 blur、也没有 _haze 底色，
// 只剩半透明状态色压着聊天背景，所以左端看起来是半截深色，跟右边硬切开。
// 把毛玻璃的最大宽抬到 218（= 最宽的胶囊），所有形态（48 / 146 / 218）都被完整包住。
// 尺寸一旦恒定，就不会出现「blur 改宽后右端留白圆残影」那个老问题。
#define SLPillMaxW 218.0
#define SLPillMinW 146.0   // v0.4.77：展开态定宽，就是 146 / 218 里最短的那一档
// v0.4.82：合成中的胶囊要装「两行字 + 取消键」，146 塞不下，单独一档更宽。
// 不跟名字走（名字那档由 sl_pillSize 决定），所以合成结束收起时不会有第二段宽度跳变。
// v0.4.84：跟毛玻璃最大宽取同一个数，两者必须相等，否则就会出现「玻璃没铺满」的深色缺口。
// v0.4.88：218 → 196。218 是从「文字 108 + 取消键 46」凑出来的，文字还左对齐，
// 视觉重心偏左 35pt，看着又长又不居中。196 的分配是刚性的：
//   球 48 | 8 | 文字 84 | 8 | 按钮 40 | 8 = 196
// 文字区中心 = 56 + 42 = 98 = 胶囊几何中心，镜像/非镜像都不动位置，天然居中。
// 比 SLPillMaxW(218) 窄，玻璃层照样完整包住（多出的 22pt 溢出被 mask 裁掉，不会有缺口）。
#define SLTtsPillW 196.0
// 语音包列表卡片的最小宽：跟胶囊宽度挂钩，但别跟着毛玻璃最大值一起涨。
#define SLMenuMinW 196.0

// v0.4.44：下压留白改成 0。
// 之前留 14pt 是为了让搜索栏不压圆角，但导航栏是透明的 —— 那 14pt 成了整张卡片上
// 唯一「没被任何内容盖住」的裸玻璃，比下面被列表染色的区域更亮，就是用户看到的那条白边。
// 改外观、改裁剪都治不了它，因为它根本不是某张图画的，而是「空出来的那块」。
// 现在导航栏贴到卡片顶：44pt 高的内容垂直居中，实际距顶 10pt，26pt 圆角在 y=10 处
// 只向内收 5.5pt，而按钮/搜索胶囊距左右边缘 12~16pt —— 不会压到弧线。
static const CGFloat kSLPanelTopPad = 0.0;

// v0.4.89：胶囊 / 球的轮廓路径。高度就是直径，圆角恒为高的一半 ——
// 球是 48×48（圆角 24 正好是正圆），胶囊是 196×48（圆角 24 就是胶囊），
// 同一条公式覆盖两种形态，形变动画才能在两者之间插值。
static CGPathRef SLCapsulePath(CGRect r, CGFloat h) {
    return CGPathCreateWithRoundedRect(r, h / 2.0, h / 2.0, NULL);
}

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

// v0.4.93：只做裁剪、自己不吃触摸的容器。
// _ttsClip 铺满整颗球（48×48），按普通 UIView 参与 hitTest 时，点击会落在它身上 ——
// 事件再也到不了 SLFloatButton 这个 UIControl，touchUpInside 不触发，球就点不开了
// （v0.4.92 加裁剪容器时踩的）。这里把「命中的是我自己」翻译成 nil（穿透），
// 只有真正落在子视图（取消 / 重试键）上才放行。
@interface SLClipPassthroughView : UIView
@end

@implementation SLClipPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

@interface SLFloatButton : UIButton
@property (nonatomic, assign) BOOL slExpanded;
@property (nonatomic, assign) SLFloatState slState;
- (void)sl_loadIcon;
- (void)sl_applyState:(SLFloatState)state;
/// v0.4.49：四杠逐根动画（A 均衡器 / C 呼吸，绕中心缩放）
- (void)sl_layoutBars;
- (void)sl_updateBarMotion;
/// v0.4.74：自定义图片的图标动效（四态律动）
/// v0.4.75：色晕（胶囊底色）挂载与刷新
- (void)sl_updateIconMotion;
- (void)sl_expand:(BOOL)expanded animated:(BOOL)animated;
/// v0.4.76：当前自定义图标（没选图返回 nil）。语音包列表要拿它铺同源底色。
- (UIImage *)sl_customIconImage;
/// v0.4.76：名字滚动 / 换名后重算宽度
- (void)sl_layoutNameMarquee;
- (void)sl_startNameMarquee;
- (void)sl_resizePillForName;
/// v0.4.45：回到前台重挂呼吸光晕（后台期间动画会被系统整条移除）
- (void)sl_restartHalo;
/// v0.4.46：拖动中越过中线翻面 / 松手贴边
- (void)sl_updateMirrorDuringDrag;
- (void)sl_settlePillToEdge;
/// v0.4.82：合成状态直接长在胶囊里（取代 v0.4.81 的独立进度卡片）
- (void)sl_ttsBegin:(NSTimeInterval)limit cancel:(void (^)(void))cancelBlock;
- (void)sl_ttsEnd:(BOOL)success failText:(NSString *)failText retry:(void (^)(void))retryBlock;
/// v0.4.85：合成还没出结论。SLFloatSetState 拿它当闸门，合成中不接受「回灰」。
- (BOOL)sl_ttsBusy;
- (void)sl_ttsReveal;
// 下面几个只在内部互相调用。全部提前声明，省得 clang 因「定义在调用点之后」
// 报 instance method not found（-Werror 下会直接炸 CI）。
- (NSString *)sl_ttsSubTextForElapsed:(NSTimeInterval)elapsed;
- (void)sl_ttsLayout;
- (void)sl_ttsTick;
- (void)sl_ttsAutoCollapse;
// v0.4.88：取消与重试共用同一个按钮，按相位分派
- (void)sl_ttsBtnTapped;
- (void)sl_ttsCancelTapped;
- (void)sl_ttsRetryTapped;
// v0.4.89：合成态内容的进出（统一管理 hidden / alpha / transform）
- (void)sl_ttsFadeInContentAfter:(NSTimeInterval)delay;
- (void)sl_ttsHideContent;
- (void)sl_ttsHideContentDelayed;
// v0.4.90：内容淡完之后的收缩（单独拆出来好延时）
- (void)sl_ttsCollapseShape;
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
- (void)sl_layoutTitleMarquee;
@property (nonatomic, strong) UIButton *play;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UIImageView *check;
@end

@implementation SLPackMenuRow {
    UIView *_titleClip;
}

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
        // v0.4.76：跟胶囊同名处理 —— 放不下就滚，放得下就静止。
        _titleClip = [[UIView alloc] initWithFrame:CGRectZero];
        _titleClip.clipsToBounds = YES;
        _titleClip.userInteractionEnabled = NO;
        [_titleClip addSubview:_title];
        [self addSubview:_titleClip];

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
    _titleClip.frame = CGRectMake(50.0, 0, MAX(0, tw), h);
    [self sl_layoutTitleMarquee];
}

/// v0.4.76：行内名字滚动。规则跟胶囊一样：放不下才滚，26pt/s，两端各停 1.2s。
- (void)sl_layoutTitleMarquee {
    CGFloat cw = CGRectGetWidth(_titleClip.bounds), chh = CGRectGetHeight(_titleClip.bounds);
    if (cw <= 0.0) return;
    [_title.layer removeAnimationForKey:@"slRowMarquee"];
    CGSize sz = [_title sizeThatFits:CGSizeMake(CGFLOAT_MAX, chh)];
    CGFloat tw = ceil(sz.width);
    if (tw <= cw - 6.0) {
        _title.frame = CGRectMake(0, 0, cw, chh);
        _title.lineBreakMode = NSLineBreakByTruncatingMiddle;
        return;
    }
    _title.frame = CGRectMake(0, 0, tw, chh);
    _title.lineBreakMode = NSLineBreakByClipping;
    CGFloat dist = tw - cw + 4.0;
    CGFloat hold = 1.2, move = MAX(1.6, dist / 26.0), total = hold + move + hold;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@0.0, @0.0, @(-dist), @(-dist), @0.0];
    a.keyTimes = @[@0.0, @(hold / total), @((hold + move) / total), @0.999, @1.0];
    a.duration = total;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_title.layer addAnimation:a forKey:@"slRowMarquee"];
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
    // v0.4.76：照片的裁剪路径。跟胶囊遮罩同一条曲线（左端圆头 / 球态正圆），
    // 不再让照片自己 cornerRadius 裁一次，两条边对不齐就会露出半截白线。
    // v0.4.76：白勾边。原来挂在 _glassHost 的 border 上（在照片下面，被吃掉半截），
    // 现在单独一层放在最顶上，底下是玻璃还是照片都画完整一圈。
    CAShapeLayer *_hairline;
    // v0.4.76：名字的裁剪窗口。名字超宽时内层 label 加宽、跑平移动画。
    UIView *_nameClip;
    // v0.4.75：胶囊底色（图标色晕）。铺在毛玻璃内容层之上、状态色之下。
    UIImageView *_haze;
    UILabel *_name;
    UIButton *_menuBtn;
    // v0.4.45：中间文字区热区 —— 只接触摸，点它不做任何事
    UIButton *_midBtn;
    UIImageView *_chev;
    UIButton *_homeBtn;
    UIView *_homeHit;
    CAShapeLayer *_haloIn;
    CAShapeLayer *_haloOut;
    UIView *_readyDot;
    CFTimeInterval _longPressAt;
    // v0.4.40：球在哪半边，胶囊就往哪边「挂」—— 图标端留在球原位，箭头端伸向屏内
    BOOL _mirrored;
    // v0.4.82：合成态内容。平时全部隐藏，只占内存不参与布局。
    UILabel *_ttsTitle;
    UILabel *_ttsSub;
    UIButton *_ttsCancel;
    UIControl *_ttsTapArea;      // 失败态整条胶囊都能点（点一下重试）
    UIView *_ttsTrack;
    UIView *_ttsFill;
    UIView *_ttsStroke;          // 失败态的红色描边（正常态看不见）
    // v0.4.92：合成内容的裁剪容器。遮罩和 _glassMask 用同一条胶囊路径、同一段动画 ——
    // 玻璃长到哪儿，标题 / 计时 / 取消键才露到哪儿。
    // v0.4.90 把 frame 一帧落到 196 之后，这四个控件在形变第一帧就按终态排好了，
    // 而玻璃还要 0.26s 才长到头 —— 中间那 0.1s「取消」就浮在玻璃外面（用户 19:55 截图）。
    UIView *_ttsClip;
    CAShapeLayer *_ttsClipMask;
    NSTimer *_ttsTimer;
    CFTimeInterval _ttsStart;
    NSTimeInterval _ttsLimit;
    NSInteger _ttsPhase;         // 0 = 关闭 / 1 = 合成中 / 2 = 失败提示中
    // v0.4.85：胶囊是否已经铺开。合成开始后的前 3 秒不铺 —— 火山 1.2 秒就完了，
    // 立刻铺开等于「刚展开就收起」，那一下蓝球根本看不见，球形状态白设计。
    BOOL _ttsShown;
    void (^_ttsCancelBlock)(void);
    void (^_ttsRetryBlock)(void);
    // v0.4.90：形变动画锁。动画期间：
    //   1) layoutSubviews 不许写 _glassMask / _hairline / _tint / halo 的路径与尺寸 ——
    //      一旦按 bounds 重写，model 值就跳回「终态」或「旧态」，动画当场被掐断；
    //   2) 内容一律按展开态排 —— 收起时 frame 还没落（宽度仍是 196），若按球态排，
    //      自定义头像会被瞬间拉成 196 宽的长条。
    BOOL _shapeLock;
    // 世代号：快速连点展开/收起时，只让最后一次的 completion 生效。
    NSUInteger _shapeGen;
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

        // 玻璃层尺寸固定成最大胶囊，只靠 mask 改外形。
        // 之前让 UIVisualEffectView 跟着 48→196 改宽高，系统按圆形重新采样，
        // 右端会留下一块白圆残影（截图里那个白圆片就是它）。
        _glassHost = [[UIView alloc] initWithFrame:CGRectZero];
        _glassHost.userInteractionEnabled = NO;
        // v0.4.46：材质变透之后，玻璃的「存在感」全靠这圈高光。
        // v0.4.76：border 挪到 _hairline（见下）—— border 画在子视图下面，
        // 照片一盖就只剩被啃过的半截线，这是那条「残线」的直接原因。
        _glassMask = [CAShapeLayer layer];
        _glassHost.layer.mask = _glassMask;
        [self addSubview:_glassHost];

        // v0.4.46：SystemMaterial → SystemUltraThinMaterial。前者在 iOS 15 上已经相当「实」，
        // 铺在聊天背景上基本看不到背后内容；换成超薄材质后是真正的玻璃感（透 + 轻模糊），
        // 玻璃的边界靠 _glassHost 那圈 0.8pt 高光勾出来。
        _chrome = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
        _chrome.frame = CGRectMake(0, 0, SLPillMaxW, SLBallSide);
        [_glassHost addSubview:_chrome];

        // v0.4.75：胶囊底色。铺在毛玻璃之上、状态色之下：
        // 默认四杠图形没有色晕（胶囊还是纯玻璃），只有选了自定义图片才有。
        // alpha 0.36 等价于「白覆盖 64%」——浅色下胶囊底落在 #B1B4B9 附近，
        // 能看出一条横向色带，文字对比度又还够；深色下同一数值只是略微压暗，不会糊死。
        _haze = [[UIImageView alloc] initWithFrame:CGRectZero];
        _haze.contentMode = UIViewContentModeScaleToFill;
        _haze.userInteractionEnabled = NO;
        _haze.alpha = 0.36;
        [_chrome.contentView addSubview:_haze];

        _tint = [[UIView alloc] initWithFrame:CGRectZero];
        _tint.userInteractionEnabled = NO;
        _tint.alpha = 0.0;
        [self addSubview:_tint];

        _glyph = [[UIImageView alloc] initWithFrame:CGRectZero];
        _glyph.contentMode = UIViewContentModeScaleAspectFit;
        _glyph.userInteractionEnabled = NO;
        [self addSubview:_glyph];

        // v0.4.49：四杠容器。放在 _glyph 之上、_thumb 之下，
        // 位置/显隐跟随 _glyph；用自定义头像时整组隐藏。
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
        // v0.4.79：回退 v0.4.76 的「端帽」遮罩（_thumbMask），照片回到正圆。
        // 端帽把照片右缘裁成一条竖直直边，直边走到上下两头被切成直角 ——
        // 用户圈的就是这条「本该顺着椭圆走、却被裁掉一截」的线。
        // 正圆与胶囊左端圆头半径同为 24，天然贴合，右缘是一整圈连续弧，没有断头。
        _thumb.clipsToBounds = YES;
        _thumb.layer.cornerRadius = SLBallSide / 2.0;
        _thumb.userInteractionEnabled = NO;
        [self addSubview:_thumb];

        // v0.4.76：白勾边。放在 _thumb 之上、其余子视图之下 —— 胶囊边缘没有别的东西压它。
        _hairline = [CAShapeLayer layer];
        _hairline.fillColor = [UIColor clearColor].CGColor;
        _hairline.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.62].CGColor;
        _hairline.lineWidth = 0.8;
        // v0.4.77：必须排在 _thumb 之下 —— 加在最后会盖住所有子视图，
        // 照片上那条「残缺的线」就是它压出来的。放低一层后即使路径溢出 0.x pt
        // 也会被照片吃掉，不会在照片上留边。
        [self.layer insertSublayer:_hairline below:_thumb.layer];


        _name = [[UILabel alloc] initWithFrame:CGRectZero];
        _name.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        _name.textColor = [UIColor labelColor];
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        // v0.4.40：两端各留 48 热区，名字在中间 100pt 里居中 —— 原来贴左对齐，
        // 右边空一大片，看着像没排好。
        _name.textAlignment = NSTextAlignmentCenter;
        _name.userInteractionEnabled = NO;
        // v0.4.76：套一层裁剪窗口。名字放得下就居中静止；放不下就把内层 label 拉宽、
        // 跑 transform.translation.x 的滚动动画（动 transform 而不是 frame，layout 不会拍回去）。
        _nameClip = [[UIView alloc] initWithFrame:CGRectZero];
        _nameClip.clipsToBounds = YES;
        _nameClip.userInteractionEnabled = NO;
        _nameClip.hidden = YES;
        [_nameClip addSubview:_name];
        [self addSubview:_nameClip];

        // v0.4.45：中间文字区只是一块「接住触摸」的空壳，点它不做任何事。
        // 它存在的唯一意义：别让触摸落到 self（本身是 UIButton）上，
        // 否则中间又会被 self 的 touchUpInside 收走。收球只认图标那一端。
        // 按住拖动照样能拖 —— 手势识别器挂在 self 上，子视图接走触摸不影响它。
        _midBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _midBtn.frame = CGRectZero;
        _midBtn.hidden = YES;

        _menuBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _menuBtn.frame = CGRectZero;
        [_menuBtn addTarget:self action:@selector(sl_menuTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_menuBtn];
        // v0.4.79：名字窗口右移后（54 → 111.5）会压到箭头热区的左界（98）。
        // _midBtn 提到 _menuBtn 之上 —— 名字那一段仍然「点了什么都不发生」，
        // 箭头热区实际收窄到 111.5 起（34.5pt；字形 11pt 居中，两侧余量仍够点）。
        [self addSubview:_midBtn];

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

        // ---- v0.4.82：合成态内容（默认全隐藏，只在 #tts 合成期间铺进胶囊）----
        // v0.4.92：整组套进一个裁剪容器，遮罩 = 玻璃当前形状（见 layoutSubviews / sl_expand:）。
        // 这样「内容在玻璃外面」这件事从结构上就不可能发生，不用再靠「等 0.16s 再淡入」去赌时序。
        // v0.4.93：容器本身必须穿透触摸（见 SLClipPassthroughView），否则球态铺满 48pt 的它
        // 会把单击整个吞掉，SLFloatButton 的 touchUpInside 收不到 —— 球点不开。
        _ttsClip = [[SLClipPassthroughView alloc] initWithFrame:CGRectZero];
        _ttsClip.backgroundColor = [UIColor clearColor];
        _ttsClipMask = [CAShapeLayer layer];
        _ttsClipMask.fillColor = [UIColor blackColor].CGColor;
        _ttsClip.layer.mask = _ttsClipMask;
        [self addSubview:_ttsClip];

        _ttsTitle = [[UILabel alloc] initWithFrame:CGRectZero];
        _ttsTitle.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        _ttsTitle.textColor = [UIColor labelColor];
        _ttsTitle.textAlignment = NSTextAlignmentCenter;   // v0.4.88：文字区居中，别再贴左边
        _ttsTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        _ttsTitle.hidden = YES;
        _ttsTitle.userInteractionEnabled = NO;
        [_ttsClip addSubview:_ttsTitle];

        _ttsSub = [[UILabel alloc] initWithFrame:CGRectZero];
        _ttsSub.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        _ttsSub.textColor = [UIColor secondaryLabelColor];
        _ttsSub.textAlignment = NSTextAlignmentCenter;
        _ttsSub.lineBreakMode = NSLineBreakByTruncatingTail;
        _ttsSub.hidden = YES;
        _ttsSub.userInteractionEnabled = NO;
        [_ttsClip addSubview:_ttsSub];

        // 底部时间条：玻璃太透，用 2pt 实色条更清楚（不贴底，避开通胶囊的圆头）
        _ttsTrack = [[UIView alloc] initWithFrame:CGRectZero];
        _ttsTrack.backgroundColor = [UIColor secondarySystemFillColor];
        _ttsTrack.layer.cornerRadius = 1.0;
        _ttsTrack.layer.masksToBounds = YES;
        _ttsTrack.hidden = YES;
        _ttsTrack.userInteractionEnabled = NO;
        [_ttsClip addSubview:_ttsTrack];

        _ttsFill = [[UIView alloc] initWithFrame:CGRectZero];
        _ttsFill.backgroundColor = [UIColor systemBlueColor];
        [_ttsTrack addSubview:_ttsFill];

        _ttsCancel = [UIButton buttonWithType:UIButtonTypeCustom];
        _ttsCancel.layer.cornerRadius = 14.0;
        _ttsCancel.layer.masksToBounds = YES;
        _ttsCancel.layer.borderWidth = 1.0;
        _ttsCancel.layer.borderColor = SLGlassHairlineColor().CGColor;
        _ttsCancel.backgroundColor = SLGlassPillFillColor();
        // v0.4.88：同一个按钮换标题 —— 合成中「取消」、失败「重试」。
        // 位置和尺寸完全一致，切状态不会出现按钮位移；代价是 target 要按相位分派。
        [_ttsCancel setTitle:@"取消" forState:UIControlStateNormal];
        [_ttsCancel setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        _ttsCancel.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        _ttsCancel.hidden = YES;
        [_ttsCancel addTarget:self action:@selector(sl_ttsBtnTapped) forControlEvents:UIControlEventTouchUpInside];
        [_ttsClip addSubview:_ttsCancel];

        // 失败态的红色勾边。挂独立一层而不是改 _hairline —— 那条是 0.8pt 白线，
        // 改色/改宽会把整套玻璃边的观感带偏。
        _ttsStroke = [[UIView alloc] initWithFrame:CGRectZero];
        _ttsStroke.backgroundColor = [UIColor clearColor];
        _ttsStroke.layer.borderWidth = 1.0;
        _ttsStroke.layer.borderColor = [UIColor systemRedColor].CGColor;
        _ttsStroke.layer.cornerRadius = SLBallSide / 2.0;
        _ttsStroke.hidden = YES;
        _ttsStroke.userInteractionEnabled = NO;
        [_ttsClip addSubview:_ttsStroke];

        // 失败提示期间整条胶囊都可以点 = 重来一次合成（运行态隐藏，别挡住「取消」）
        _ttsTapArea = [[UIControl alloc] initWithFrame:CGRectZero];
        _ttsTapArea.backgroundColor = [UIColor clearColor];
        _ttsTapArea.hidden = YES;
        [_ttsTapArea addTarget:self action:@selector(sl_ttsRetryTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_ttsTapArea];

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

- (UIImage *)sl_customIconImage {
    NSString *v = SLFloatIconValue();
    if (![v hasPrefix:@"image:"]) return nil;
    return [UIImage imageWithContentsOfFile:SLFloatIconImagePath([v substringFromIndex:6])];
}

- (void)sl_loadIcon {
    NSString *v = SLFloatIconValue();
    _glyph.hidden = YES;
    _thumb.hidden = YES;

    UIImage *img = nil;
    if ([v hasPrefix:@"image:"]) {
        img = [UIImage imageWithContentsOfFile:SLFloatIconImagePath([v substringFromIndex:6])];
        if (!img) v = kSLFloatIconDefault;
    }
    if (img) {
        _thumb.image = img;
        _thumb.hidden = NO;
        _haze.image = SLHazeImage(img, 32, 6);
        // v0.4.77：色晕不随状态让位，这里也兜一次 —— 换图前若被旧逻辑压到 0 会一直不显。
        _haze.alpha = 0.36;
    } else {
        _haze.image = nil;
        // 48pt 里六根条太密，前 3 根 30% 的几乎看不见，糊成一团。
        // 球和胶囊上换成四根（两淡两实）、条更粗；大尺寸仍用六根。
        _glyph.image = [SLBrandGlyphCompact(44, [UIColor blackColor]) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _glyph.tintColor = [UIColor labelColor];
        _glyph.hidden = NO;
        _glyph.alpha = 0.0;   // v0.4.49：静态图不显示，实际由 _bars 逐根绘制 + 动画
    }
    _name.text = SLFloatPackName();
    [self sl_resizePillForName];
    [self setNeedsLayout];
    // v0.4.74：换图标后要按新形态重挂（换成自定义图片才动，换回四杠就清干净）
    [self sl_updateIconMotion];
}

// v0.4.49：把四根条摆到 _bars 里。几何沿用 SLBrandGlyphCompact：
// 单位 u = 宽度/100，xs 定位置、hs 定高度（短长长短），左两淡=原声、右两实=合成声。
// 用 bounds + center 摆放，锚点天然在正中，缩放就是「绕中心」，不会贴底。
- (void)sl_layoutBars {
    CGFloat side = CGRectGetWidth(_bars.bounds);
    if (side <= 0.0) return;
    CGFloat u = side / 100.0;
    // v0.4.95：条宽 / 位置 / 高度 / 透明度全部走 kSLBrandBar*，与两个图标函数同源
    UIColor *c = _glyph.tintColor ?: [UIColor labelColor];
    CGFloat w = kSLBrandBarW * u;
    for (int i = 0; i < 4; i++) {
        CGFloat hh = kSLBrandBarH[i] * u;
        UIView *bar = _barCell[i];
        bar.bounds = CGRectMake(0, 0, w, hh);
        bar.center = CGPointMake((kSLBrandBarX[i] * u) + w / 2.0, side / 2.0);
        bar.layer.cornerRadius = w / 2.0;
        bar.layer.cornerCurve = kCACornerCurveContinuous;
        bar.backgroundColor = [c colorWithAlphaComponent:kSLBrandBarA[i]];
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

// v0.4.74：自定义图标的四态动效。
// 一条铁律：外圈一律不动 —— 光晕（_haloIn/_haloOut）和内层 26% 状态底色原样保留，
// 不再加环、不加弧。原因：光晕本来就在呼吸（2.8 / 0.9 / 1.4 / 1.6s 半周期），
// 再叠一圈不同频的环会拍频，空闲约 16.8 秒才同相一次、录音每 2.3 秒错一拍，看着像抖。
// 所以这里只让「图标自己」动，而且周期全部对齐光晕的 half，绝不另一套节奏。
- (void)sl_updateIconMotion {
    // 只对自定义图片生效。默认四杠图形本来就有四套逐根动画，再叠一层会打架。
    UIView *target = nil;
    if (!_thumb.hidden) target = _thumb;

    NSInteger fx = SLFloatEffectValue();

    // 先无条件清干净：换图标、关动效、切回四杠形态都走这一条
    [_thumb.layer removeAnimationForKey:@"slIconMotion"];

    if (!target || fx <= 0) return;

    SLFloatState st = self.slState;

    // 半周期与光晕一致：空闲 1.4 / 录音 0.45 / 合成 0.70 / 就绪 0.80
    CGFloat half = 1.4;
    CGFloat lo = 0.96;
    BOOL pump = NO, hop = NO;
    if (st == SLFloatStateRecording) { half = 0.45; lo = 0.94; }
    else if (st == SLFloatStateSynthesizing) { half = 0.70; pump = YES; }
    else if (st == SLFloatStateReady) { half = 0.80; hop = YES; }

    if (pump) {
        // 合成态「泵动」：前一半慢慢蓄到 0.945，14% 的时间急弹到 1.03，再缓落回 1.0。
        // 刻意用不对称曲线 —— 空闲和录音都是正弦来回，合成态一眼就能区分开。
        // 不转、不摇：人像照片旋转或左右晃动都会显得怪。
        CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        k.values = @[@1.0, @0.945, @1.03, @1.005, @1.0];
        k.keyTimes = @[@0.0, @0.50, @0.64, @0.80, @1.0];
        k.duration = half * 2.0;
        k.repeatCount = HUGE_VALF;
        k.fillMode = kCAFillModeBoth;
        k.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [target.layer addAnimation:k forKey:@"slIconMotion"];
    } else if (hop) {
        // 就绪：双跳，和四杠同拍同时长（1.1s）
        CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        k.values = @[@1.0, @1.06, @1.0, @1.06, @1.02, @1.0];
        k.keyTimes = @[@0.0, @0.18, @0.38, @0.56, @0.78, @1.0];
        k.duration = 1.1;
        k.repeatCount = HUGE_VALF;
        k.fillMode = kCAFillModeBoth;
        k.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [target.layer addAnimation:k forKey:@"slIconMotion"];
    } else {
        // 空闲 0.96 / 录音 0.94：只是「轻重」不同，不靠幅度区分，避免人像呼吸过重
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        a.fromValue = @(lo);
        a.toValue = @1.0;
        a.duration = half;
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.fillMode = kCAFillModeBoth;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [target.layer addAnimation:a forKey:@"slIconMotion"];
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

    // v0.4.77：选了自定义图片时，胶囊底永远只铺图色晕，一点状态色都不掺。
    // 原来状态色一来就把色晕让掉（0.36 → 0），剩下 74% 是超薄毛玻璃自己的白，
    // 在浅色聊天背景上就是一片灰白玻璃 —— 从图色跳到白、再跳到状态色，中间硬断一截，
    // 就是「其他形态的背景会变成白色」的来源。
    // 现在：有图 → 底色恒定，状态只靠字形 / 文字 / 箭头 / 外圈光环（有图时四杠本来就隐藏）；
    // 没图（默认 logo）→ 仍然铺 26% 状态色，否则四态根本没有底色谱可用。
    BOOL hasArt = (_thumb != nil && _thumb.hidden == NO);
    BOOL useTint = (accent != nil) && !hasArt;
    UIColor *fill = useTint ? [accent colorWithAlphaComponent:0.26] : [UIColor clearColor];
    // v0.4.57：所有着色元素（胶囊底、分隔线、字形 tint、四杠、名字）一起做 0.26s 交叉淡入淡出。
    // 原来只有 _tint 在动画块里，四杠/字形/名字是瞬间换色，蓝→绿会「啪」地硬切（录屏确认一帧跳变）。
    // 现在把颜色改动全收进同一个动画块，整颗球颜色平滑过渡；光环描边是 CAShapeLayer 属性，
    // UIView 块管不到，单独用 CATransaction 在 sl_startBreath 之后交叉淡出（见下）。
    [UIView animateWithDuration:0.26 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_tint.backgroundColor = fill;
        self->_tint.alpha = useTint ? 1.0 : 0.0;
        // v0.4.77：色晕不再让位（见上），整块胶囊从头到尾是同一个底，没有「白一下」的过渡。
        self->_glyph.tintColor = accent ?: [UIColor labelColor];
        self->_name.textColor = accent ?: [UIColor labelColor];
        // 四杠跟着换色：几何不变，只有背景色随动画块交叉淡入淡出（as[i] 透明度恒定）
        [self sl_layoutBars];
    } completion:nil];
    [self sl_updateBarMotion];
    // v0.4.74：图标动效也跟着状态换节奏。注意不能塞进 sl_updateBarMotion ——
    // 自定义图片时 _bars 是 hidden，那个方法一开始就 return 了，根本走不到这一句。
    [self sl_updateIconMotion];
    // v0.4.57：合成完成→就绪，整颗胶囊轻轻「落定」一下（缩放回弹）。
    // v0.4.60：只在「没有试听面板」时才弹 —— 面板自己有 0.94→1.0 的弹入，
    // 两下缩放同帧叠加会像「球被按了一下」，所以面板路径改走 SLFloatSetStateQuiet 静音。
    if (!sSLFloatSettleMuted && prev == SLFloatStateSynthesizing && state == SLFloatStateReady) {
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
    // v0.4.92：合成期间一律不露这颗点 —— 它是「已装填」的徽标，说的是上一次的结论；
    // 正在合成时挂在胶囊里，用户只会看成「胶囊里怎么有颗绿点」（19:54 录屏 2s 那帧）。
    _readyDot.hidden = (state != SLFloatStateReady) || _ttsPhase != 0;

    // v0.4.57：光环描边是 CAShapeLayer 属性，UIView 动画块管不到，得单独做一条 0.26s 的过渡。
    // v0.4.91：顺序错了整整七个版本 —— 原来先改色、再调 sl_startBreath，
    // 而它开头 removeAllAnimations 会把这条颜色过渡连同形变的 path 动画一起清掉。
    // 结果就是：填充按 0.26s 渐变换色，描边却「啪」地瞬间跳色。用户两张截图里
    // 「绿底配蓝框（展开）」「蓝底配绿框（收起）」全是这一条造成的。
    // 现在先把呼吸挂好，再单独给 strokeColor 挂一条和 UIView 块同时长、同曲线的动画。
    [self sl_startBreath:state];
    UIColor *halo = accent ?: [UIColor colorWithWhite:0.55 alpha:1.0];
    CGColorRef oldIn = (CGColorRef)CFRetain(_haloIn.strokeColor ?: halo.CGColor);
    CGColorRef oldOut = (CGColorRef)CFRetain(_haloOut.strokeColor ?: halo.CGColor);
    _haloIn.strokeColor = halo.CGColor;
    _haloOut.strokeColor = halo.CGColor;
    CAMediaTimingFunction *haloEase = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    CABasicAnimation *hcIn = [CABasicAnimation animationWithKeyPath:@"strokeColor"];
    hcIn.fromValue = (__bridge id)oldIn;
    hcIn.toValue = (__bridge id)halo.CGColor;
    hcIn.duration = 0.26;
    hcIn.timingFunction = haloEase;
    [_haloIn addAnimation:hcIn forKey:@"slColor"];
    CABasicAnimation *hcOut = [CABasicAnimation animationWithKeyPath:@"strokeColor"];
    hcOut.fromValue = (__bridge id)oldOut;
    hcOut.toValue = (__bridge id)halo.CGColor;
    hcOut.duration = 0.26;
    hcOut.timingFunction = haloEase;
    [_haloOut addAnimation:hcOut forKey:@"slColor"];
    CFRelease(oldIn);
    CFRelease(oldOut);
    // v0.4.41：状态一变就重读名字。原来只改颜色不改文字，发完那一发胶囊还挂着
    // 刚才的包名 —— 用户以为没发出去，实际问题只是字没刷新。
    _name.text = SLFloatPackName();
    [self sl_resizePillForName];
    [self setNeedsLayout];
}

- (void)sl_startBreath:(SLFloatState)state {
    // v0.4.91：只清「breath」这一条，别 removeAllAnimations。
    // 全清会把两条顺手带走：① 形变中正在插值的 path（slShape）；② 刚挂上的换色（slColor）。
    // 被清掉之后 CAShapeLayer 直接跳到 model 值 —— 光环瞬间变成终点形状、颜色硬切。
    [_haloIn removeAnimationForKey:@"breath"];
    [_haloOut removeAnimationForKey:@"breath"];

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
    // v0.4.74：图标缩放 / 扫光同样是常驻 CA 动画，一样会被摘掉
    [self sl_updateIconMotion];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    // v0.4.37：原来固定撑满 196，「原声」两个字也占 196，中间空 66pt。
    // v0.4.76：宽度跟着名字走（146~196 自适应）。
    // v0.4.77：定回固定 146 —— 要的是「胶囊最短的那一档」，尺寸恒定，
    // 展开动画、换音色都不再跳。
    // v0.4.79：窗口改成 146 - 54（图标侧）- 34.5（箭头侧）= 57.5pt，
    // 12.5pt 字号下四个汉字（50pt）能完整静止，五个字起才滚。
    // v0.4.82：合成态换一档宽 —— 要同时放两行字和「取消」键，146 不可能塞下。
    // v0.4.85：只有真的铺开了才吃这档宽。没铺开时（合成前 3 秒）它还是颗球，
    // 这里若照样返回 218，一旦被别处（sl_resizePillForName / 手动展开）问一次，
    // 球会瞬间被拉成一条空胶囊。
    if (_ttsShown && _ttsPhase != 0) return CGSizeMake(SLTtsPillW, SLBallSide);
    _name.text = SLFloatPackName();
    return CGSizeMake(SLPillMinW, SLBallSide);
}

/// v0.4.76：名字放得下就居中静止，放不下就把 label 拉宽跑滚动。
/// 动的是 transform.translation.x，layoutSubviews 重排不会把它拍回 0。
- (void)sl_layoutNameMarquee {
    CGFloat cw = CGRectGetWidth(_nameClip.bounds);
    CGFloat chh = CGRectGetHeight(_nameClip.bounds);
    if (cw <= 0.0 || chh <= 0.0) return;
    [_name.layer removeAnimationForKey:@"slNameMarquee"];
    CGSize sz = [_name sizeThatFits:CGSizeMake(CGFLOAT_MAX, chh)];
    CGFloat tw = ceil(sz.width);
    // v0.4.77：窗口窄，不能再要求「左右各留 6pt」—— 本来放得下的名字会被判成
    // 溢出，然后挤出几 pt 的空滚，肉眼看就是「名字抖一下」。放得下就居中，真溢出才滚。
    if (tw <= cw + 0.5) {
        _name.frame = CGRectMake(0, 0, cw, chh);
        _name.textAlignment = NSTextAlignmentCenter;
        _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        return;
    }
    _name.frame = CGRectMake(0, 0, tw, chh);
    _name.textAlignment = NSTextAlignmentLeft;
    _name.lineBreakMode = NSLineBreakByClipping;
    if (!self.slExpanded || self.window == nil) return;
    [self sl_startNameMarquee];
}

- (void)sl_startNameMarquee {
    CGFloat cw = CGRectGetWidth(_nameClip.bounds);
    CGFloat tw = CGRectGetWidth(_name.frame);
    CGFloat dist = tw - cw + 6.0;
    if (dist <= 1.0) return;
    // 停 1.2s → 匀速左移（26pt/s）→ 末尾停 1.2s → 跳回
    // v0.4.77：定宽后需要滚的距离普遍只有十几 pt，原来 MAX(1.6, …) 会把 15pt 拉成 1.6s
    //（≈9pt/s，看着像在爬）。改成按速度算，上下各卡一道：0.9s 下限、2.4s 上限。
    CGFloat hold = 1.2, move = MAX(0.9, MIN(2.4, dist / 26.0)), total = hold + move + hold;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@0.0, @0.0, @(-dist), @(-dist), @0.0];
    a.keyTimes = @[@0.0, @(hold / total), @((hold + move) / total), @0.999, @1.0];
    a.duration = total;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_name.layer addAnimation:a forKey:@"slNameMarquee"];
}

/// v0.4.76：换包 / 状态变化后名字变了，展开态要跟着改宽度（否则会留一段空白或多截一截）
- (void)sl_resizePillForName {
    if (!self.slExpanded || self.window == nil) return;
    CGSize sz = [self sl_pillSize];
    CGRect f = self.frame;
    if (fabs(sz.width - CGRectGetWidth(f)) < 0.5) return;
    CGSize oldSize = f.size;
    if (_mirrored) f.origin.x = CGRectGetMaxX(f) - sz.width;
    f.size = sz;
    if (self.superview) {
        CGFloat minX = kSLFloatEdgePad, maxX = CGRectGetWidth(self.superview.bounds) - kSLFloatEdgePad;
        if (CGRectGetMaxX(f) > maxX) f.origin.x = maxX - sz.width;
        if (f.origin.x < minX) f.origin.x = minX;
    }

    // v0.4.90：宽度变化也走「frame 一帧落终态、形状只由遮罩推」——
    // 原来 frame 用 0.22s 补间、遮罩却被 layout 一帧写成终态，玻璃会比胶囊先探出右端一截。
    // 图标端固定（镜像时贴右、非镜像贴左），所以旧矩形在新坐标里只要对齐那一端。
    CGFloat hh = SLBallSide;
    CGFloat dur = 0.22;
    CGFloat oldW = oldSize.width, newW = sz.width;
    CGRect fromRect = _mirrored ? CGRectMake(newW - oldW, 0, oldW, hh) : CGRectMake(0, 0, oldW, hh);
    CGRect toRect = CGRectMake(0, 0, newW, hh);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.frame = f;
    [CATransaction commit];

    _shapeLock = YES;
    NSUInteger gen = ++_shapeGen;

    CGPathRef maskFrom = SLCapsulePath(fromRect, hh);
    CGPathRef maskTo   = SLCapsulePath(toRect, hh);
    CGPathRef hairFrom = SLCapsulePath(CGRectInset(fromRect, 0.4, 0.4), hh - 0.8);
    CGPathRef hairTo   = SLCapsulePath(CGRectInset(toRect, 0.4, 0.4), hh - 0.8);
    CGPathRef haloInFrom  = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(fromRect, -2.5, -2.5)
                                                       cornerRadius:(hh + 5.0) / 2.0].CGPath;
    CGPathRef haloInTo    = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(toRect, -2.5, -2.5)
                                                       cornerRadius:(hh + 5.0) / 2.0].CGPath;
    CGPathRef haloOutFrom = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(fromRect, -7.0, -7.0)
                                                       cornerRadius:(hh + 14.0) / 2.0].CGPath;
    CGPathRef haloOutTo   = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(toRect, -7.0, -7.0)
                                                       cornerRadius:(hh + 14.0) / 2.0].CGPath;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glassMask.path = maskTo;
    _hairline.path = hairTo;
    _haloIn.path = haloInTo;
    _haloOut.path = haloOutTo;
    _ttsClipMask.path = maskTo;     // v0.4.92：内容裁剪框同玻璃
    [CATransaction commit];

    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    NSArray *layers = @[_glassMask, _hairline, _haloIn, _haloOut];
    NSArray *froms = @[(__bridge id)maskFrom, (__bridge id)hairFrom,
                       (__bridge id)haloInFrom, (__bridge id)haloOutFrom];
    NSArray *tos = @[(__bridge id)maskTo, (__bridge id)hairTo,
                     (__bridge id)haloInTo, (__bridge id)haloOutTo];
    for (NSUInteger i = 0; i < layers.count; i++) {
        CAShapeLayer *layer = layers[i];
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"path"];
        a.fromValue = froms[i];
        a.toValue = tos[i];
        a.duration = dur;
        a.timingFunction = ease;
        [layer removeAnimationForKey:@"slShape"];
        [layer addAnimation:a forKey:@"slShape"];
    }
    // v0.4.92：裁剪框和玻璃走同一组起止矩形（同坐标空间）
    {
        CABasicAnimation *ca = [CABasicAnimation animationWithKeyPath:@"path"];
        ca.fromValue = (__bridge id)maskFrom;
        ca.toValue = (__bridge id)maskTo;
        ca.duration = dur;
        ca.timingFunction = ease;
        [_ttsClipMask removeAnimationForKey:@"slShape"];
        [_ttsClipMask addAnimation:ca forKey:@"slShape"];
    }
    // v0.4.91：和 sl_expand 同一条规矩 —— 状态色的起点显式摆到 fromRect 上。
    // 镜像时 fromRect 是 (newW-oldW, 0, oldW, hh)（图标端贴右），若让 UIView 从「当前 model
    // 值 (0,0,oldW,hh)」开始，右边缘会跟着往右长，而玻璃是靠左边缘往左长的 —— 两条边反向错开。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _tint.frame = fromRect;
    _tint.layer.cornerRadius = hh / 2.0;
    [CATransaction commit];
    [UIView animateWithDuration:dur delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_tint.frame = toRect;
        self->_tint.layer.cornerRadius = hh / 2.0;
    } completion:^(BOOL finished) {
        if (self->_shapeGen != gen) return;
        self->_shapeLock = NO;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
    CGPathRelease(maskFrom);
    CGPathRelease(maskTo);
    CGPathRelease(hairFrom);
    CGPathRelease(hairTo);
    [self setNeedsLayout];
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
            CGFloat minX = kSLFloatEdgePad, maxX = CGRectGetWidth(self.superview.bounds) - kSLFloatEdgePad;
            if (CGRectGetMaxX(nf) > maxX) nf.origin.x = maxX - target.width;
            if (nf.origin.x < minX) nf.origin.x = minX;
        }
    } else {
        // v0.4.41：收起时球要落回「图标那一端」，不是胶囊的左边缘。
        // 向左长（镜像）的胶囊图标在右端，直接缩 origin.x 会让球无视觉地跳到左边去。
        [SLPackMenu sl_dismissCurrent];   // 球都收了，旁边还挂着列表很怪
        if (wasMirrored) nf.origin.x = CGRectGetMaxX(f) - SLBallSide;
        // v0.4.90：这里**不**立刻把 _mirrored 归零 —— 收起动画期间 frame 还是展开态、
        // 内容仍按镜像排（图标在右端）。提前归零会让自定义头像瞬移到左边，
        // 而玻璃这时候才收到一半。归零挪到动画结束、frame 落下去的那一刻。
        if (self.superview) {
            CGPoint c = SLClampFloatPos(CGPointMake(CGRectGetMidX(nf), CGRectGetMidY(nf)),
                                        self.superview.bounds.size);
            nf.origin = CGPointMake(c.x - SLBallSide / 2.0, c.y - SLBallSide / 2.0);
            // 拖动过的胶囊，收起来之后这个位置就是球以后的新家
            SLStoreFloatPos(c, self.superview.bounds.size);
        }
    }

    // ===== v0.4.90：一次形变只让**一套坐标**推动 =====
    // v0.4.89 让 frame 和遮罩 path 一起动，结果两者各推了一遍：
    //   展开 —— frame.origin.x 从 338 走到 190、宽度 48 加到 196，同时 mask 又从「球」往左长。
    //          中段就是「玻璃已经铺满、整条还停在右边」：右端局部 196 映射到屏幕 460，直接顶出
    //          屏幕被裁平（录屏 2.15s / 2.23s 那两帧），里层状态色还只长到一半，成了两层胶囊。
    //   收起 —— frame 在往 338 走，遮罩却从「旧 path 平移 -196」得到 -196..0 的负坐标，
    //          被 _glassHost 左边界整段裁掉，于是「一帧变球」；tint 终点写的是局部 0（左端），
    //          绿球先落在胶囊左段、再横滑 148pt 回右端，外面还挂着没消失的「取消 / 合成中」。
    //
    // 现在分工锁死：
    //   展开 —— frame 一帧落终态（内容全就位，图标端本来就不动），只有 mask / 描边 / 状态色
    //          从「球矩形」插值到「整条矩形」。局部坐标固定，右端永远钉在球原位，不可能出屏。
    //   收起 —— frame 完全不动（坐标系不变，路径全正），mask / 状态色从整条收到球端；
    //          0.18s 后才把 frame 落到球上 —— 那一刻的屏幕坐标与动画末帧完全相同，看不出切换。
    //（当年「不做插值否则玻璃重采样留残影」那句针对的是 _chrome 跟着改宽的旧结构；
    //  现在 blur 层恒定 SLPillMaxW、形状全靠 mask，不存在重采样。）
    CGFloat hh = SLBallSide;
    CGFloat dur = expanded ? 0.26 : 0.18;

    _shapeLock = animated;
    NSUInteger gen = ++_shapeGen;

    // 动画期间的坐标基准：展开用终态 frame，收起用当前（旧）frame。
    CGFloat baseX = expanded ? CGRectGetMinX(nf) : CGRectGetMinX(f);
    CGFloat baseW = expanded ? CGRectGetWidth(nf) : CGRectGetWidth(f);
    // 球在旧坐标系里的屏幕位置：展开前就是球本身；收起时球要落在图标端（镜像在右端）。
    CGFloat orbScreenX = expanded
        ? CGRectGetMinX(f)
        : (wasMirrored ? CGRectGetMaxX(f) - SLBallSide : CGRectGetMinX(f));
    CGRect orbRect  = CGRectMake(orbScreenX - baseX, 0, SLBallSide, hh);
    CGRect fullRect = CGRectMake(0, 0, baseW, hh);
    CGRect fromRect = expanded ? orbRect : fullRect;
    CGRect toRect   = expanded ? fullRect : orbRect;

    // 展开：先把 frame 落到终态（不动动画，避免又推一遍形变）
    if (expanded) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.frame = nf;
        [CATransaction commit];
    }

    CGPathRef maskFrom = SLCapsulePath(fromRect, hh);
    CGPathRef maskTo   = SLCapsulePath(toRect, hh);
    CGPathRef hairFrom = SLCapsulePath(CGRectInset(fromRect, 0.4, 0.4), hh - 0.8);
    CGPathRef hairTo   = SLCapsulePath(CGRectInset(toRect, 0.4, 0.4), hh - 0.8);
    CGPathRef haloInFrom  = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(fromRect, -2.5, -2.5)
                                                      cornerRadius:(hh + 5.0) / 2.0].CGPath;
    CGPathRef haloInTo    = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(toRect, -2.5, -2.5)
                                                      cornerRadius:(hh + 5.0) / 2.0].CGPath;
    CGPathRef haloOutFrom = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(fromRect, -7.0, -7.0)
                                                      cornerRadius:(hh + 14.0) / 2.0].CGPath;
    CGPathRef haloOutTo   = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(toRect, -7.0, -7.0)
                                                      cornerRadius:(hh + 14.0) / 2.0].CGPath;

    // model 值先落终点。_shapeLock 期间 layoutSubviews 不会重写这几样，动画不会被写回打断。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glassMask.path = maskTo;
    _hairline.path = hairTo;
    _haloIn.path = haloInTo;
    _haloOut.path = haloOutTo;
    _ttsClipMask.path = maskTo;     // v0.4.92：内容裁剪框和玻璃同一个终点
    [CATransaction commit];

    [_glassMask removeAnimationForKey:@"slShape"];
    [_hairline removeAnimationForKey:@"slShape"];

    if (animated) {
        CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        CABasicAnimation *ma = [CABasicAnimation animationWithKeyPath:@"path"];
        ma.fromValue = (__bridge id)maskFrom;
        ma.toValue = (__bridge id)maskTo;
        ma.duration = dur;
        ma.timingFunction = ease;
        [_glassMask addAnimation:ma forKey:@"slShape"];

        CABasicAnimation *ha = [CABasicAnimation animationWithKeyPath:@"path"];
        ha.fromValue = (__bridge id)hairFrom;
        ha.toValue = (__bridge id)hairTo;
        ha.duration = dur;
        ha.timingFunction = ease;
        [_hairline addAnimation:ha forKey:@"slShape"];

        // v0.4.92：内容裁剪框跟着玻璃同一条曲线长 / 缩 —— 形变期间字和取消键
        // 只会从胶囊里「露出来」，绝不会浮在玻璃外面。
        CABasicAnimation *ca = [CABasicAnimation animationWithKeyPath:@"path"];
        ca.fromValue = (__bridge id)maskFrom;
        ca.toValue = (__bridge id)maskTo;
        ca.duration = dur;
        ca.timingFunction = ease;
        [_ttsClipMask removeAnimationForKey:@"slShape"];
        [_ttsClipMask addAnimation:ca forKey:@"slShape"];

        // 光环不在 _glassHost 里、遮罩裁不到，不跟一遍就会「球还在、外圈已经拉成胶囊」。
        // 注意：这两条动画必须在 sl_startBreath 之后才挂 —— 它开头会 removeAllAnimations，
        // 提前挂的 path 动画会被一起清掉，光环直接跳到胶囊形状（所以见函数末尾）。

        // 状态色也不在 _glassHost 里，必须跟玻璃走同一条边 —— 否则颜色比玻璃早到 / 晚走，
        // 就是那两层套在一起的胶囊。
        // v0.4.91：起点必须显式摆到 fromRect 上。原来这里直接动画到 toRect，UIView 拿的是
        // 当前 model 值 —— 球态 tint 铺满 48 宽的 bounds，也就是 (0,0,48,48)，永远贴左；
        // 而镜像展开时遮罩是从 (148,0,48,48) 往左长的。一个从左长、一个从右长，
        // 中途就是「绿块和蓝框各错开一个球宽」（用户 19:36 录屏 0.933s 那帧）。
        // 去掉 BeginFromCurrentState：起点由我们指定，不再跟着上一帧的呈现值跑。
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _tint.frame = fromRect;
        _tint.layer.cornerRadius = hh / 2.0;
        [CATransaction commit];
        [UIView animateWithDuration:dur delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_tint.frame = toRect;
            self->_tint.layer.cornerRadius = hh / 2.0;
        } completion:^(BOOL finished) {
            if (self->_shapeGen != gen) return;   // 期间又被切换过，交给后来者收尾
            self->_shapeLock = NO;
            if (!expanded) {
                // 到位后再落 frame：屏幕坐标与动画末帧一致，看不见切换
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                _mirrored = NO;
                self.frame = nf;
                [CATransaction commit];
            }
            [self setNeedsLayout];
            [self layoutIfNeeded];
        }];
        [self setNeedsLayout];
    } else {
        if (!expanded) _mirrored = NO;
        self.frame = nf;
        _tint.frame = toRect;
        _tint.layer.cornerRadius = hh / 2.0;
        _shapeLock = NO;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }
    CGPathRelease(maskFrom);
    CGPathRelease(maskTo);
    CGPathRelease(hairFrom);
    CGPathRelease(hairTo);
    // 上面四个 halo path 来自 [UIBezierPath CGPath]（非持有），不能 release。

    if (animated) {
        _name.alpha = 0.0;
        _chev.alpha = 0.0;
        [UIView animateWithDuration:dur * 0.75 delay:dur * 0.35
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_name.alpha = 1.0;
            self->_chev.alpha = 1.0;
        } completion:nil];
    } else {
        _name.alpha = 1.0;
        _chev.alpha = 1.0;
    }
    [self sl_startBreath:self.slState];

    // v0.4.90：光环的形变动画必须挂在这里 —— sl_startBreath 开头会 removeAllAnimations，
    // 提前挂的话会被一起清掉，光环直接跳到胶囊形状（「球还在、外圈已经拉长」）。
    if (animated) {
        CAMediaTimingFunction *easeHalo = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        for (int i = 0; i < 2; i++) {
            CAShapeLayer *layer = (i == 0) ? _haloIn : _haloOut;
            CABasicAnimation *hb = [CABasicAnimation animationWithKeyPath:@"path"];
            hb.fromValue = (__bridge id)(i == 0 ? haloInFrom : haloOutFrom);
            hb.toValue = (__bridge id)(i == 0 ? haloInTo : haloOutTo);
            hb.duration = dur;
            hb.timingFunction = easeHalo;
            [layer addAnimation:hb forKey:@"slShape"];
        }
    }
}

#pragma mark - v0.4.82：合成态（进度 / 取消长在胶囊里）

// v0.4.88：「12s / 30s」。原来是「已等 12s · 上限 30s」，11pt 下约 100pt，
// 而文字区只有 84pt —— 一直被截成「已等 12s · 上…」，等于每帧都在报错。
// 上限是固定 30s，用户看两次就记住了，不必每帧重复「上限」二字。
- (NSString *)sl_ttsSubTextForElapsed:(NSTimeInterval)elapsed {
    NSInteger e = (NSInteger)floor(elapsed);
    NSInteger lim = (NSInteger)ceil(_ttsLimit);
    if (e < 0) e = 0;
    if (e > lim) e = lim;
    return [NSString stringWithFormat:@"%lds / %lds", (long)e, (long)lim];
}

- (void)sl_ttsLayout {
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = SLBallSide;
    BOOL mir = _mirrored;

    // v0.4.88：胶囊收窄到 196，各段是硬分配 —— 球 48 / 8 / 文字 84 / 8 / 按钮 40 / 8。
    // 文字区中心固定在 98pt（= 196/2），镜像只换按钮站哪一端，不改变文字位置，
    // 所以两行字永远落在视觉中轴上，不会再出现「三个字贴在左边」。
    CGFloat btnW = 40.0, btnH = 28.0;
    // 取消键跟图标换边：胶囊向左长（球贴右）时图标在右端，取消就得挪到左端。
    _ttsCancel.frame = CGRectMake(mir ? 8.0 : (w - btnW - 8.0), (h - btnH) / 2.0, btnW, btnH);

    // 文字区左右对称留白（球侧 8、按钮侧 8）。
    // 失败态不再隐藏按钮（改成「重试」），所以两种相位的文字区完全一样宽 ——
    // 从「合成中」切到「合成失败」不会有宽度跳变。
    CGFloat textX = 56.0;
    CGFloat textW = MAX(0.0, w - 56.0 - 8.0 - btnW - 8.0);
    if (textW > 84.0) textW = 84.0;
    _ttsTitle.frame = CGRectMake(textX, 8.0, textW, 17.0);
    _ttsSub.frame = CGRectMake(textX, 24.0, textW, 14.0);
    // 失败但没有具体原因时副标是空的，只剩一行标题 —— 那一行要自己垂直居中，
    // 否则会贴着胶囊上沿，下面空出一大片（原来看起来像「文字浮着」）。
    if (_ttsSub.hidden && _ttsPhase == 2) {
        _ttsTitle.frame = CGRectMake(textX, (h - 17.0) / 2.0 - 2.0, textW, 17.0);
    }

    // 时间条跟文字同宽、贴在胶囊下缘往上 7pt：贴到最底会被圆头切掉一截。
    CGFloat trackY = h - 7.0;
    _ttsTrack.frame = CGRectMake(textX, trackY, textW, 2.0);
    CGFloat p = 0.0;
    if (_ttsPhase == 1 && _ttsLimit > 0.5) {
        p = (CGFloat)((CACurrentMediaTime() - _ttsStart) / _ttsLimit);
    } else if (_ttsPhase == 2) {
        p = 1.0;
    }
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    _ttsFill.frame = CGRectMake(0, 0, textW * p, 2.0);

    _ttsStroke.frame = b;
    _ttsStroke.layer.cornerRadius = h / 2.0;
    _ttsTapArea.frame = b;
}

// v0.4.85：合成开始后多久才把胶囊铺开。
// 火山实测 1.2 秒就完了，立刻铺开等于「刚展开就收起」，蓝球根本看不见；
// Fish 慢的时候 3~12 秒，超过这个点才值得把进度条和取消键亮出来。
// 定 3.0：快的全程只有球，慢的才等到胶囊。
static const NSTimeInterval kSLTTSRevealDelay = 3.0;

- (void)sl_ttsBegin:(NSTimeInterval)limit cancel:(void (^)(void))cancelBlock {
    // v0.4.88：正在开着胶囊时（从失败态点「重试」）不能再走 `_ttsShown = NO` 那条路。
    // 那一刻 sl_pillSize 会按 phase 回到 146，形变 + 再展开 = 胶囊先缩一下又长回来，
    // 宽度其实一直是 196，肉眼看到的却是闪。直接沿用「已铺开」状态，一次形变都不做。
    BOOL stayOpen = self.slExpanded;

    _ttsPhase = 1;
    _ttsShown = stayOpen;   // v0.4.85：先当球，等 3 秒还没完再铺开；重试时保持铺开
    _ttsLimit = (limit > 1.0) ? limit : 30.0;
    _ttsStart = CACurrentMediaTime();
    _ttsCancelBlock = [cancelBlock copy];
    _ttsRetryBlock = nil;

    _ttsTitle.text = @"合成中";
    _ttsTitle.textColor = [UIColor labelColor];
    _ttsSub.textColor = [UIColor secondaryLabelColor];
    _ttsSub.text = [self sl_ttsSubTextForElapsed:0];
    _ttsFill.backgroundColor = [UIColor systemBlueColor];
    // 从失败态点「重试」进来时按钮还写着「重试」，这里必须切回「取消」
    [_ttsCancel setTitle:@"取消" forState:UIControlStateNormal];

    // v0.4.85：没铺开之前这些控件一律藏着 —— 球只有 48pt，塞两行字会溢到球外面。
    // 到 sl_ttsReveal / 失败态才一起放出来。v0.4.89 起顺带复位 alpha / transform。
    [self sl_ttsHideContent];

    [_ttsTimer invalidate];
    // 0.1s 一档足够了：进度条 84pt 宽，30s 上限下 0.1s 只走 0.28pt，肉眼看是连续的。
    _ttsTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                 target:self
                                               selector:@selector(sl_ttsTick)
                                               userInfo:nil
                                                repeats:YES];

    // v0.4.85：延迟展开（3.0s）。这之前只有球在转 —— 合成够快的话用户只会看到
    // 「蓝球转一下 → 绿」，胶囊全程不出现；真卡住了才把进度条和取消键铺出来。
    // 例外：从失败态点「重试」时胶囊本来就开着，不能等 3 秒，也不能缩一次再长回来。
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsReveal) object:nil];
    if (stayOpen) {
        // 重试：胶囊本来开着，没有形变要等，直接让内容淡回来
        _ttsTitle.hidden = NO;
        _ttsSub.hidden = NO;
        _ttsTrack.hidden = NO;
        _ttsCancel.hidden = NO;
        _ttsStroke.hidden = YES;
        _ttsTitle.alpha = 0.0;
        _ttsSub.alpha = 0.0;
        _ttsTrack.alpha = 0.0;
        _ttsCancel.alpha = 0.0;
        [self sl_resizePillForName];
        [self setNeedsLayout];
        [self sl_ttsFadeInContentAfter:0.0];
    } else {
        [self performSelector:@selector(sl_ttsReveal) withObject:nil afterDelay:kSLTTSRevealDelay];
    }
    [self setNeedsLayout];
}

/// v0.4.85：合成还没出结论。SLFloatSetState 拿它当闸门，合成中不接受「回灰」。
- (BOOL)sl_ttsBusy {
    return _ttsPhase == 1;
}

/// v0.4.85：把合成态铺开成 196pt 胶囊。延迟到点、用户主动点球、或直接失败时调用。
/// 重复调用无害（_ttsShown 挡住），取消时由 sl_ttsAutoCollapse 撤掉排队的这次。
- (void)sl_ttsReveal {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsReveal) object:nil];
    if (_ttsPhase == 0 || _ttsShown) return;
    _ttsShown = YES;
    _ttsStroke.hidden = YES;
    _ttsTapArea.hidden = YES;

    // v0.4.89：内容先摆好位置但透明 —— 等胶囊长到一半再浮出来。
    // 原来这里是 hidden = NO + 立刻 sl_expand，四个控件「啪」地出现在刚长出来的胶囊上，
    // 跟玻璃的形变一点关系都没有，看着就是硬贴上去的。
    // 只用 alpha 淡入、不做位移：这几个控件在 sl_ttsLayout 里是按 frame 排的，
    // 带非单位 transform 再设 frame 属于未定义行为（会跳位）。
    BOOL alreadyOpen = self.slExpanded;
    _ttsTitle.hidden = NO;
    _ttsSub.hidden = NO;
    _ttsTrack.hidden = NO;
    _ttsCancel.hidden = NO;
    _ttsTitle.alpha = 0.0;
    _ttsSub.alpha = 0.0;
    _ttsTrack.alpha = 0.0;
    _ttsCancel.alpha = 0.0;

    // 已经展开着（用户自己点开过）就不能再走 sl_expand: —— 那个方法见 slExpanded==YES 直接 return，
    // 宽度会停在 146，两行字和取消键全挤成一条。这里按名字那套 resize 逻辑重排一次。
    if (alreadyOpen) [self sl_resizePillForName];
    else [self sl_expand:YES animated:YES];
    [self setNeedsLayout];

    // 0.26s 的形变里，前 0.12s 只长玻璃，剩下的时间字才浮上来 —— 两件事错开才有「先张开、
    // 内容再落进来」的次序。已经展开的情况没有形变可等，直接淡入。
    // v0.4.90：形变改成「只由遮罩推」之后，内容更要晚一点才出来。
    // v0.4.92：0.16s 还是太早 —— 玻璃那一刻只走到七成，而内容已经按 196 排好位置，
    // 「取消」就浮在玻璃右端外面（用户 19:55 那张截图）。改成等形变整段走完（0.26s）
    // 再淡入，0.28s 起、0.12s 淡完。裁剪容器是第二道保险，两个一起上。
    [self sl_ttsFadeInContentAfter:(alreadyOpen ? 0.0 : 0.28)];
}

/// v0.4.89：合成态四个控件一起淡入（0.14s）。
- (void)sl_ttsFadeInContentAfter:(NSTimeInterval)delay {
    for (UIView *v in @[_ttsTitle, _ttsSub, _ttsTrack, _ttsCancel]) {
        [UIView animateWithDuration:0.12 delay:delay
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            v.alpha = 1.0;
        } completion:nil];
    }
}

/// v0.4.89：统一收掉合成态内容。alpha 一并复位 —— 只 hidden 不复位的话，
/// 下次展开会带着上一次淡入被打断时留下的半透明值出来。
- (void)sl_ttsHideContent {
    for (UIView *v in @[_ttsTitle, _ttsSub, _ttsTrack, _ttsCancel]) {
        [v.layer removeAllAnimations];
        v.hidden = YES;
        v.alpha = 1.0;
    }
    _ttsStroke.hidden = YES;
    _ttsTapArea.hidden = YES;
}

- (void)sl_ttsTick {
    if (_ttsPhase != 1) return;
    NSTimeInterval elapsed = CACurrentMediaTime() - _ttsStart;
    _ttsSub.text = [self sl_ttsSubTextForElapsed:elapsed];
    CGFloat p = (CGFloat)(elapsed / _ttsLimit);
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    CGFloat tw = CGRectGetWidth(_ttsTrack.bounds);
    _ttsFill.frame = CGRectMake(0, 0, tw * p, 2.0);
}

- (void)sl_ttsEnd:(BOOL)success failText:(NSString *)failText retry:(void (^)(void))retryBlock {
    [_ttsTimer invalidate];
    _ttsTimer = nil;

    if (!success && failText.length) {
        // 失败：原地转红停 2.6s，不走「先收球再弹一下」那条路 —— 收球会把提示也一起收掉。
        _ttsPhase = 2;
        // v0.4.85：合成没撑到 3 秒就失败（网络直接 401 之类）时胶囊还没铺开，
        // 这里必须立刻铺 —— 否则红字提示根本没地方显示，用户只看到球闪了一下。
        _ttsShown = YES;
        _ttsRetryBlock = [retryBlock copy];
        // v0.4.88：调用方传的是「合成失败 · 网络错误」一整串，17 个字挤在 84pt 里必然截断。
        // 这里按「 · 」拆成两行：标题只留结论，原因挪到副标。拆不开就整串当标题、副标空着。
        NSString *title = failText;
        NSString *detail = nil;
        NSRange sp = [failText rangeOfString:@" · "];
        if (sp.location != NSNotFound && sp.location > 0 && sp.location + sp.length < failText.length) {
            title = [failText substringToIndex:sp.location];
            detail = [failText substringFromIndex:sp.location + sp.length];
        }
        _ttsTitle.text = title;
        _ttsTitle.textColor = [UIColor systemRedColor];
        _ttsSub.textColor = [UIColor secondaryLabelColor];
        _ttsSub.text = detail;   // 没原因就不显示，别再填「已放回输入框」这种废话
        _ttsFill.backgroundColor = [UIColor systemRedColor];
        // v0.4.89：先复位 alpha / transform（可能正卡在淡入中途），再按失败态摆出来 ——
        // 否则红字会以半透明或带 3pt 位移的样子停在那里。
        [self sl_ttsHideContent];
        _ttsTitle.hidden = NO;
        _ttsSub.hidden = (detail.length == 0);
        _ttsTrack.hidden = NO;
        // 同一个按钮换标题：右端不再空出一块，也不用整条胶囊可点（那会跟拖动手势打架）。
        [_ttsCancel setTitle:@"重试" forState:UIControlStateNormal];
        _ttsCancel.hidden = NO;
        _ttsStroke.hidden = NO;
        _ttsTapArea.hidden = YES;
        if (!self.slExpanded) [self sl_expand:YES animated:YES];
        [self setNeedsLayout];

        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsAutoCollapse) object:nil];
        [self performSelector:@selector(sl_ttsAutoCollapse) withObject:nil afterDelay:2.6];
        return;
    }
    [self sl_ttsAutoCollapse];
}

- (void)sl_ttsAutoCollapse {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsAutoCollapse) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsReveal) object:nil];
    [_ttsTimer invalidate];
    _ttsTimer = nil;
    _ttsPhase = 0;
    // v0.4.91：_ttsShown 不能在这里清。清掉之后 layoutSubviews 里 showChrome 立刻变真，
    // 语音包名字会趁「内容淡出 0.10s」这段空档冒出来，和还没淡完的「合成中 / 2s·30s」
    // 叠成一团（用户第二张截图里三个词组同时可见）。挪到 sl_ttsCollapseShape，和收缩同帧清。
    _ttsCancelBlock = nil;
    _ttsRetryBlock = nil;
    // v0.4.89：先让内容跟着一起收（0.08s 淡出），再走 0.18s 的收缩形变。
    // 原来内容是一帧消失、胶囊一帧缩回，两件事同时硬切。现在至少有个「收」的过程。
    for (UIView *v in @[_ttsTitle, _ttsSub, _ttsTrack, _ttsCancel]) {
        if (v.hidden) continue;
        [UIView animateWithDuration:0.08 delay:0
                            options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ v.alpha = 0.0; }
                         completion:nil];
    }
    [self sl_ttsHideContentDelayed];
    // v0.4.90：先把字淡掉，再收形状。原来两件事同时开始 —— 玻璃已经在往里缩，字还挂在外面，
    // 录屏 3.85s 那帧「绿球落在左段 + 取消 / 合成中 的残影」就是它。0.10s 淡完再收，总 0.28s。
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsCollapseShape) object:nil];
    [self performSelector:@selector(sl_ttsCollapseShape) withObject:nil afterDelay:0.10];
    [self setNeedsLayout];
}

/// v0.4.90：内容淡完之后的收缩（拆出来只是为了能延时调用）。
- (void)sl_ttsCollapseShape {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsCollapseShape) object:nil];
    // v0.4.91：见到这里才允许名字回来 —— 此刻合成内容已经淡完（0.10s），
    // 而且紧接着 sl_expand:NO 会把 slExpanded 置 NO，layout 下一次跑的时候
    // showChrome 已经是假，名字不会冒出来。
    _ttsShown = NO;
    [self sl_expand:NO animated:YES];
}

/// v0.4.89：给淡出留出 0.08s，再把控件真正藏起来（否则 hidden 会立刻掐掉正在跑的淡出）。
- (void)sl_ttsHideContentDelayed {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsHideContent) object:nil];
    [self performSelector:@selector(sl_ttsHideContent) withObject:nil afterDelay:0.09];
}

/// v0.4.88：右侧那个按钮在两个相位下含义不同 —— 合成中取消，失败重试。
/// 位置尺寸完全一样，只是换了标题，所以入口在这里按相位分派。
- (void)sl_ttsBtnTapped {
    if (_ttsPhase == 1) [self sl_ttsCancelTapped];
    else if (_ttsPhase == 2) [self sl_ttsRetryTapped];
}

- (void)sl_ttsCancelTapped {
    if (_ttsPhase != 1) return;
    void (^cb)(void) = _ttsCancelBlock;
    _ttsPhase = 0;                  // 先落态，避免 cancel 回调里再回头改一轮
    [self sl_ttsAutoCollapse];
    if (cb) cb();
}

- (void)sl_ttsRetryTapped {
    if (_ttsPhase != 2) return;
    void (^rb)(void) = _ttsRetryBlock;
    _ttsRetryBlock = nil;
    // 不先收球：原地退回「合成中」再由 sl_ttsBegin 重铺。收球再展开会缩一下又长回来，
    // 宽度明明一样（196），肉眼却像闪了一下。
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sl_ttsAutoCollapse) object:nil];
    // v0.4.88：这里**不清** _ttsPhase。清成 0 之后 sl_pillSize 会按「没合成」返回 146，
    // 万一在 rb() 之前插进一次 layout，胶囊就缩成 146 再长回 196 —— 又是一次闪。
    // 保持相位 2（宽度 196 不变），紧接着 sl_ttsBegin 会把它推到 1。
    _ttsCancelBlock = nil;
    // 重试前先把上一轮的内容收干净（alpha / transform 一并复位），紧接着 rb() 会用
    // sl_ttsBegin 从「已铺开」的状态重新淡回来
    [self sl_ttsHideContent];
    if (rb) rb();
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
            CGFloat minX = kSLFloatEdgePad, maxX = sz.width - kSLFloatEdgePad - f.size.width;
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
        c.x = (c.x < sz.width / 2.0) ? (half + kSLFloatEdgePad) : (sz.width - half - kSLFloatEdgePad);
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

// v0.4.46：松手贴边，贴哪条边由图标端决定（图标端就是收起后球的位置）。
// v0.4.80：回退 v0.4.79 的「离边 40pt 内才吸 / 中心判定 / 0.2s 无过冲」，
// 恢复一律贴边 + 弹簧回弹。垂直方向不吸附（上下位置保持用户放的样子），
// 只把新球位记下来。
- (void)sl_settlePillToEdge {
    UIView *sv = self.superview;
    if (!sv) return;
    CGSize sz = sv.bounds.size;
    CGRect f = self.frame;
    // v0.4.94：6 → 10，光环不再被屏幕切。注意不能写 static const ——
    // C 里 const 变量不是编译期常量，static 初始化会报 non-constant initializer。
    const CGFloat kEdgePad = kSLFloatEdgePad;
    CGFloat leftX = kEdgePad;
    CGFloat rightX = sz.width - kEdgePad - f.size.width;
    if (rightX < leftX) rightX = leftX;   // 胶囊比屏还宽时只保证左缘不越界

    BOOL wasMirrored = _mirrored;
    // 图标端落在哪半屏就贴哪条边 —— 收起后球就长在图标端，看着是「球滑到最近的边」
    CGFloat iconX = _mirrored ? (CGRectGetMaxX(f) - SLBallSide / 2.0)
                              : (CGRectGetMinX(f) + SLBallSide / 2.0);
    BOOL toLeft = (iconX < sz.width / 2.0);
    _mirrored = !toLeft;

    CGRect nf = f;
    nf.origin.x = toLeft ? leftX : rightX;

    if (_mirrored != wasMirrored) {
        // 先把内部翻好再滑动：两步都在一帧里完成，但顺序上「先确定面孔再挪位置」，
        // 不会出现滑到一半内部还在旧朝向。
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }

    [UIView animateWithDuration:0.22 delay:0
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
    // v0.4.85：合成中球是「只有蓝球」那一档，点它就是「现在就想看进度」——
    // 直接铺开，不用等满 3 秒。这一档不看语音包开关（关了包也会走 #tts 合成）。
    if (_ttsPhase == 1) {
        [self sl_ttsReveal];
        return;
    }
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
    // v0.4.65：设置已开着时长按球 = 关闭设置（不必再点「完成」）
    if ([SLFloatPanelController isSettingsOpen]) {
        [SLFloatPanelController dismissSettings];
        _longPressAt = CFAbsoluteTimeGetCurrent();
        return;
    }
    UIViewController *top = [AWECAUtils topViewController];
    if (!top) return;
    [SLFloatPanelController presentSettingsFrom:top];
    // 重新打时间戳：松手时的 touchUpInside 不会再误触发「展开 / 收起」
    _longPressAt = CFAbsoluteTimeGetCurrent();
}

#pragma mark 布局

// v0.4.77：只画「看得见玻璃」的那一段轮廓。
// 照片当端帽时，它朝外那一侧与胶囊轮廓是同一条曲线 —— 线画上去只会压在照片上，
// 所以从照片直边起笔、绕到另一端再收在直边；球态照片铺满整颗球，没有玻璃可勾，返回 nil
// （边界交给外圈光环）。半圆用两段三次贝塞尔拼，避开 addArc 的 clockwise 方向坑。
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = SLBallSide;
    // v0.4.90：形变动画期间内容一律按展开态排。
    // 收起时 frame 还没落（宽度仍是 196），若按球态排，_thumb 会被瞬间拉成 196 宽的圆角长条、
    // 名字和箭头也会提前归位 —— 而玻璃这时候才刚开始往里收。锁定成展开态就没有这一下。
    BOOL exp = self.slExpanded || _shapeLock;

    // v0.4.89：玻璃容器固定成最大宽，不再跟着 bounds 走。
    // 收起动画时 bounds 已经是 48，若容器也缩成 48，遮罩里那条还在收缩的胶囊会被裁在
    // 48 宽内 —— 等于「一帧变球」，动画白做。容器给足宽度，形状完全由遮罩决定，
    // 溢出的部分被遮罩裁掉，看不见。userInteractionEnabled 是 NO，不影响触摸。
    _glassHost.frame = CGRectMake(0, 0, MAX(SLPillMaxW, w), h);
    _glassHost.layer.cornerRadius = h / 2.0;
    // v0.4.76：去掉 cornerCurve = continuous。描边曾经走连续曲率、遮罩走正圆，
    // 两条曲线在圆头两端差 0.3~0.5pt，正是「白线只剩中间一段」的另一半原因。
    // v0.4.89：遮罩路径统一走 SLCapsulePath —— 形变动画是在两条 path 之间
    // 插值，起点和终点必须由同一个函数生成（UIBezierPath 与 CGPathCreateWithRoundedRect
    // 的元素序列不保证一致，序列不一致时 CoreAnimation 会直接跳到终点，动画等于没有）。
    // v0.4.90：形状四样（遮罩 / 描边 / 状态色 / 光环）在形变动画期间一律不碰 ——
    // 按 bounds 重写会把 model 值改回「终态或旧态」，正在跑的 path 动画当场被掐断。
    // 动画结束后 completion 会解除锁并立刻重排一次，那时候写进去的就是最终值。
    if (!_shapeLock) {
        CGPathRef maskPath = SLCapsulePath(b, h);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _glassMask.path = maskPath;
        _ttsClipMask.path = maskPath;   // v0.4.92：合成内容跟着玻璃同一个形状
        [CATransaction commit];
        CGPathRelease(maskPath);
    }
    // v0.4.92：裁剪容器的坐标基准和 _glassHost 完全一致（都在 0,0），
    // 所以上面那条 maskPath 可以直接复用，不用换算。
    _ttsClip.frame = b;
    // 玻璃始终是最大尺寸，只靠 mask 露出当前形状，右对齐
    // v0.4.40：镜像开关。MX(x, wd) 把「距左 x」翻成「距右 x」，宽度不变的居中元素不要用它。
    BOOL mir = exp ? _mirrored : NO;
#define SLMX(x, wd) (mir ? (w - (x) - (wd)) : (x))
    // v0.4.84：SLPillMaxW 已经 ≥ 所有胶囊宽度，这里两个方向都必然覆盖整条
    //（非镜像 w-218 ≤ 0，镜像 0 起），不用再按镜像右对齐。
    // v0.4.89：干脆钉死在 [0, SLPillMaxW]，别再按 w 算 —— 形变动画期间 w 已经是终态，
    // 按 w 算会让模糊层在收起时先缩到左边 48，右端那条还没收完的胶囊就没有玻璃了。
    _chrome.frame = CGRectMake(0, 0, SLPillMaxW, h);

    // v0.4.39：左图标与球态同尺寸（22pt，不再缩水到 18），头像 32 → 42
    _glyph.frame = exp ? CGRectMake(SLMX(13.0, 22.0), (h - 22.0) / 2.0, 22.0, 22.0)
                       : CGRectMake((w - 22.0) / 2.0, (h - 22.0) / 2.0, 22.0, 22.0);
    _glyph.hidden = (_thumb.hidden == NO);
    // v0.4.49：四杠容器跟随 _glyph 的位置与显隐；自定义头像时自动让位
    _bars.frame = _glyph.frame;
    _bars.hidden = _glyph.hidden;
    [self sl_layoutBars];
    // v0.4.44：自定义图标在球态是铺满 48 的，展开态原来缩到 42，切胶囊时明显小一圈。
    // 改成两种形态都用满 48（左端留出一整块圆形），球和胶囊的图标视觉尺寸就一致了。
    CGFloat iconS = SLBallSide;
    _thumb.frame = exp ? CGRectMake(SLMX(0.0, iconS), 0, iconS, iconS) : b;
    // v0.4.79：端帽遮罩已回退，这里不再重建 thumbMask，只给 _hairline 换路径。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // v0.4.76：勾边路径跟着胶囊外形走，内缩 0.4 让 0.8pt 描边正好压在边界上。
    // v0.4.79：照片回正圆后不再需要「绕开照片」的开放路径 —— 正圆和胶囊圆头是
    // 同一条曲线，那个「直边起点」不存在了，硬用开放路径会让照片右侧空出 20pt 没描边。
    // 现在一律画整圈圆角矩形；_hairline 排在 _thumb 之下，左端那半圈被照片吃掉，
    // 只露出照片外面 0.4pt 那一环 —— 既不会白线压脸，也不会有断头。
    _hairline.frame = b;
    // v0.4.89：同 _glassMask，描边 path 也走统一生成函数，才能和形变动画的起点插值
    if (!_shapeLock) {
        CGPathRef hairPath = SLCapsulePath(CGRectInset(b, 0.4, 0.4), h - 0.8);
        _hairline.path = hairPath;
        CGPathRelease(hairPath);
    }
    [CATransaction commit];
    // v0.4.75：色晕跟玻璃同尺寸铺满（球态被 _glassMask 裁成圆）。
    // v0.4.78：色晕必须铺满整块玻璃（196），不能只铺「可见的那 146」。
    // v0.4.77 曾把左边界对齐到可见区起点 —— 那个点在 _chrome 坐标里正好是胶囊最左端，
    // 也就是照片圆头的最左切点，色晕在切线处断成一条竖直硬边，放大就是照片边上那道细线。
    // 铺满 196 后硬边落在 _glassMask 之外（玻璃左边被裁掉的那 50pt），永远看不见。
    _haze.frame = CGRectMake(0, 0, SLPillMaxW, h);

    // v0.4.37：状态色铺满整条胶囊。原来展开态只盖左侧 48pt 圆，
    // 球是蓝的、胶囊还是白玻璃，中间像被切断。
    if (!_shapeLock) {
        _tint.frame = b;
        _tint.layer.cornerRadius = h / 2.0;
    }

    // v0.4.40：两端各一块 48pt 热区，中间 100pt 给名字（居中）。
    // 镜像时两端互换、中间不动 —— 图标端跟着球走，箭头端永远在远端。
    // v0.4.79：删掉 57 那条竖分隔线（0.5pt 宽、和底色只差 4 个色阶，本来就看不见，
    // 却正好贴在文字左边界上，把名字往图片那边推）。
    // 名字窗口 54 → 111.5（宽 57.5）：原来右边界卡在箭头热区的左界 98，而箭头字形
    // 116.5 才起笔 —— 中间 18.5pt 全空，看着就是「离图标太近、右边太空」。
    // 现在两侧留白对称（靠图标 54 / 靠箭头 34.5），文字中心 82.75 落在视觉中轴上。
    const CGFloat kNearIcon = 54.0;    // 靠图标那一侧的留白
    const CGFloat kNearChev = 34.5;    // 靠箭头那一侧的留白（箭头字形 18.5 起笔、11pt 宽）
    const CGFloat kNameW = MAX(0.0, w - kNearIcon - kNearChev);
    {
        CGFloat nx = mir ? kNearChev : kNearIcon;
        _nameClip.frame = CGRectMake(nx, 0, kNameW, h);
        [self sl_layoutNameMarquee];
    }
    // v0.4.45：中间这块必须有个真的控件接走触摸，否则触摸落到 self 上会被收走。
    // 这里只接触摸、不挂 target —— 点名字什么都不该发生。
    // v0.4.79：范围从「48 → w-48」改成「图标端余量 → 名字窗口右界」，跟着窗口走。
    {
        CGFloat midX0 = mir ? kNearChev : 48.0;
        CGFloat midX1 = mir ? (w - 48.0) : (kNearIcon + kNameW);
        _midBtn.frame = exp ? CGRectMake(midX0, 0, MAX(0.0, midX1 - midX0), h) : CGRectZero;
    }
    _menuBtn.frame = exp ? CGRectMake(SLMX(w - 48.0, 48.0), 0, 48.0, h) : CGRectZero;
    _chev.frame = CGRectMake(18.5, (h - 11.0) / 2.0, 11.0, 11.0);
    _homeBtn.frame = exp ? CGRectMake(SLMX(0.0, 48.0), 0, 48.0, h) : CGRectZero;
    _homeHit.frame = _homeBtn.bounds;
    // v0.4.92：小绿点钉在**图标那一端**（球心那一端），不再用 w-14 去贴胶囊远端。
    // 原来贴的是「当前宽度」的右端：胶囊一铺开，点就跟着跑到 148 之外；收起时宽度先不动、
    // 玻璃却已经缩成球，点就孤零零留在外面往里追（19:54 录屏最后两秒、用户第二张截图）。
    // 图标端在展开 / 收起两种形态里都不动，钉在这里就永远不会跑出形状。
    {
        CGFloat iconMaxX = mir ? w : SLBallSide;
        _readyDot.frame = CGRectMake(iconMaxX - 14.0, 3.0, 9.0, 9.0);
        _readyDot.hidden = (self.slState != SLFloatStateReady) || _ttsPhase != 0;
    }
#undef SLMX

    // v0.4.90：显隐用**真实**展开态，不用上面那个被 _shapeLock 抬起来的 exp ——
    // 收起动画期间 exp 还是 YES（为了别让内容跳位），但名字和箭头这时候必须已经消失，
    // 否则会挂在正在收缩的玻璃外面。
    // _ttsShown 也要算进去：合成结束到真正开始收缩之间有 0.10s 的空档，
    // 那段时间 _ttsPhase 已经是 0、名字会趁虚冒出来。
    BOOL showChrome = self.slExpanded && !_ttsShown;
    _nameClip.hidden = !showChrome;
    _midBtn.hidden = !showChrome;
    _menuBtn.hidden = !showChrome;
    _homeBtn.hidden = !showChrome;
    // v0.4.82：合成态把「名字 + 箭头 + 两端热区」整套让出来，胶囊里只留进度和取消。
    // 这里必须放在上面四行之后 —— 否则那四行会把 hidden 改回去，合成态里同时冒出名字和取消键。
    if (exp && _ttsPhase != 0) {
        _nameClip.hidden = YES;
        _midBtn.hidden = YES;
        _menuBtn.hidden = YES;
        _homeBtn.hidden = YES;
        [self sl_ttsLayout];
    }

    // 光晕路径：胶囊就是「圆角 = 高一半」的矩形，球是它的特例
    // v0.4.90：形变期间交给动画，这里不能重写（否则外圈会在第一帧就跳成胶囊）
    if (!_shapeLock) {
        _haloIn.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -2.5, -2.5)
                                                  cornerRadius:(h + 5.0) / 2.0].CGPath;
        _haloOut.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, -7.0, -7.0)
                                                   cornerRadius:(h + 14.0) / 2.0].CGPath;
    }
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
    UIImageView *_haze;     // v0.4.76：跟胶囊同源的色晕
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
    // v0.4.76：胶囊宽度改成跟名字走、最窄 146。列表不跟着缩 ——
    // 行内固定占掉 88pt（试听键 48 + 间距 8 + 右侧圈 18 + 内边距），
    // 卡片再跟着收到 146，名字只剩 58pt，滚起来也读不下去。
    if (cardW < SLMenuMinW) cardW = SLMenuMinW;
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

    // v0.4.76：列表底跟胶囊同源。同一条色带，但压到 6×1 再拉满 ——
    // 32×6 直接铺到 190pt 高会拉出一道竖光带（像刷了金属漆），
    // 降到 6 段只剩「哪边偏冷、哪边偏暖」的大块走向；面积大，浓度也从 0.36 收到 0.22。
    if ([anchor isKindOfClass:[SLFloatButton class]]) {
        UIImage *icon = [(SLFloatButton *)anchor sl_customIconImage];
        UIImage *hz = icon ? SLHazeImage(icon, 6, 1) : nil;
        if (hz) {
            _haze = [[UIImageView alloc] initWithFrame:_blur.contentView.bounds];
            _haze.image = hz;
            _haze.contentMode = UIViewContentModeScaleToFill;
            _haze.alpha = 0.22;
            _haze.userInteractionEnabled = NO;
            _haze.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [_blur.contentView addSubview:_haze];
        }
    }

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

+ (BOOL)isSettingsOpen {
    return sSLFloatPanel && sSLFloatPanel.presentingViewController != nil;
}

+ (void)dismissSettings {
    if (sSLFloatPanel && sSLFloatPanel.presentingViewController) {
        [sSLFloatPanel sl_dismiss];
    }
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
    // v0.4.87：合成期间球**只许是蓝的**。v0.4.85 只拦了 Idle，结果录音开场那句
    // SLFloatSetState(Recording) 照样能把蓝刷成红，而录音结束的 Idle 又被拦 ——
    // 球就卡在红里直到 30s 超时（日志 17:26:21 点亮录音态 → 17:26:22 idle suppressed）。
    // 只堵出口不堵入口，等于没堵。现在反过来：合成没出结论时，除「合成中」以外
    // 一切状态（Recording / Idle / Ready）都不接受，颜色完全由合成回调决定
    //（成功绿 / 失败红）。取消路径不受影响：它先把相位清成 0 才回灰。
    if ([b sl_ttsBusy] && state != SLFloatStateSynthesizing) {
        SLLog(@"state %ld suppressed: tts still synthesizing", (long)state);
        return;
    }
    // v0.4.36：就绪不再 1.6 秒后自己退回空闲 —— 它要一直亮着，
    // 直到语音真正发出去（发送完成那一刻会走 Ready → Idle，顺带外扩一圈涟漪）。
    [b sl_applyState:state];
}

// v0.4.60：同 SLFloatSetState，但不触发「落定」缩放回弹。
// 用途只有一个：试听面板弹出后把球点成 Ready 绿 —— 那一刻面板自己在弹入，
// 球再缩一下就成了两个动画撞车。静音范围严格限定在这次 apply 之内。
void SLFloatSetStateQuiet(SLFloatState state) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ SLFloatSetStateQuiet(state); });
        return;
    }
    SLFloatButton *b = sSLFloatBtn;
    if (!b) return;
    BOOL prevMuted = sSLFloatSettleMuted;
    sSLFloatSettleMuted = YES;
    [b sl_applyState:state];
    sSLFloatSettleMuted = prevMuted;
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
        UIWindow *cur = btn.window;
        if (top && cur && top != cur && top.windowLevel >= cur.windowLevel) {
            [btn removeFromSuperview];
            [top addSubview:btn];
        }
        // v0.4.61：present 的呈现容器是在球之后才加到 window 上的，对 window 自己
        // bringSubviewToFront 抬不动球 —— 以前真正生效的是那次 0.4s 补抬，
        // 录屏里就是「卡片先出来、球被压在下层，0.4s 后才窜上去」。改成对球自己的
        // superview 提，并把补抬从 0.4s 提前到 0.05 / 0.18s（仍在系统重排之后）。
        [btn.superview bringSubviewToFront:btn];

        __weak SLFloatButton *weakBtn = btn;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SLFloatButton *b = weakBtn;
            if (!b || !b.superview) return;
            [b.superview bringSubviewToFront:b];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
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
    // v0.4.87：合成中只换图标、颜色不动。这条是直接调 sl_applyState，绕开了
    // SLFloatSetState 的闸门 —— 合成时进设置页调个外观，蓝球就会被刷成灰或绿。
    if (btn && ![btn sl_ttsBusy]) {
        [btn sl_applyState:([SLVoicePack isOneShotPending] ? SLFloatStateReady : SLFloatStateIdle)];
    }
}

#pragma mark - v0.4.82：合成态桥接（进度条直接长在胶囊里）

void SLFloatTTSBegin(NSTimeInterval limitSec, void (^cancelBlock)(void)) {
    // v0.4.87：已在主线程就直接执行 —— 见 SLFloatTTSEnd 里的说明，异步排队会让
    // 调用方紧跟着写的那句同步状态设置抢在前面。
    void (^work)(void) = ^{
        SLFloatButton *btn = sSLFloatBtn;
        if (!btn) {
            UIWindow *w = SLKeyWindow();
            btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
        }
        if (!btn) return;
        [btn sl_ttsBegin:limitSec cancel:cancelBlock];
        // 胶囊可能刚从球展开，铺到顶层免得被面板压住
        [btn.superview bringSubviewToFront:btn];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

void SLFloatTTSEnd(BOOL success, NSString *failText, void (^retryBlock)(void)) {
    // v0.4.87：同样改成「主线程就直接跑」。
    // 原来无条件 dispatch_async，而 Tweak.x 里「先 SLFloatTTSEnd 再 SLFloatSetState(Idle)」
    // 是同步连着写的 —— Idle 抢在 TTSEnd 前面执行，那一刻相位还是 1，被闸门拦掉，
    // 结果球停在蓝、胶囊却在报失败（日志 17:26:30 tts timeout 之后紧跟的那行
    // 「idle suppressed」就是它）。改顺序没用，得让 TTSEnd 真的先落地。
    void (^work)(void) = ^{
        SLFloatButton *btn = sSLFloatBtn;
        if (!btn) {
            UIWindow *w = SLKeyWindow();
            btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
        }
        if (!btn) return;
        [btn sl_ttsEnd:success failText:failText retry:retryBlock];
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// 把中心点夹在「不会被屏幕边缘切掉」的范围内。
// 原来那版是「越界就重置」—— 拖到边上会突然跳回中间，而且重置值本身也可能越界。
// v0.4.94：左右边距改用 kSLFloatEdgePad（原来是 4pt，光环贴着屏幕会被切）。
static CGPoint SLClampFloatPos(CGPoint c, CGSize size) {
    if (size.width <= 0 || size.height <= 0) return c;
    CGFloat half = SLBallSide / 2.0;
    CGFloat minX = half + kSLFloatEdgePad;
    CGFloat maxX = size.width - half - kSLFloatEdgePad;
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    // v0.4.9：删掉表情预设，只留自定义图片
    // v0.4.80：删掉「图标动效」整段（关闭 / 律动 + 段尾说明）
    return 1;
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
