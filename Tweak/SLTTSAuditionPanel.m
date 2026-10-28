//
//  SLTTSAuditionPanel.m
//
//  v0.4.13
//  - 试听改成播 WAV（16k/mono/s16le PCM 现场封装），彻底绕开 AMR 解码：
//    0.4.11/0.4.12 的日志是  prepare=0、play=NO，原因是 AVAudioPlayer 备不好 AMR 这路，
//    不是「音频被占用」。会话侧（setCategory:Playback + setActive:YES）本身是成功的。
//  - 界面重做：模糊遮罩 + 卡片 + 圆形播放键 + 细进度条 + 主按钮。
//

#import "SLTTSAuditionPanel.h"
#import "AWECAUtils.h"
#import "SLEntry.h"
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static NSString *const kSLTTSPreviewKey = @"SLTTSPreview";
@class SLTTSAuditionViewController;
static SLTTSAuditionViewController *sSLShownPanel = nil;

static NSString *SLFmtTime(double t) {
    if (t < 0 || !isfinite(t)) t = 0;
    int m = (int)(t / 60.0);
    int s = (int)(t + 0.5) - m * 60;
    if (s >= 60) { s = 0; m++; }
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

// 把裸 PCM（16k / mono / s16le，小端）封成 WAV。
// AVAudioPlayer 对 WAV PCM 是最稳的，完全不走 AMR 解码器。
static NSData *SLWavFromPCM(NSData *pcm, uint32_t sampleRate, uint16_t channels, uint16_t bits) {
    if (pcm.length < 2) return nil;
    uint32_t dataLen = (uint32_t)pcm.length;
    uint32_t riffLen = 36 + dataLen;
    uint32_t byteRate = sampleRate * channels * (bits / 8);
    uint16_t blockAlign = (uint16_t)(channels * (bits / 8));
    uint16_t fmt = 1;   // PCM

    NSMutableData *out = [NSMutableData dataWithCapacity:44 + dataLen];
    [out appendBytes:"RIFF" length:4];
    [out appendBytes:&riffLen length:4];
    [out appendBytes:"WAVEfmt " length:8];
    uint32_t fmtLen = 16;
    [out appendBytes:&fmtLen length:4];
    [out appendBytes:&fmt length:2];
    [out appendBytes:&channels length:2];
    [out appendBytes:&sampleRate length:4];
    [out appendBytes:&byteRate length:4];
    [out appendBytes:&blockAlign length:2];
    [out appendBytes:&bits length:2];
    [out appendBytes:"data" length:4];
    [out appendBytes:&dataLen length:4];
    [out appendData:pcm];
    return out;
}

#pragma mark - 声波条

// 自绘声波：按 PCM 振幅生成一串圆角竖条，播过的填主色、没播的浅灰。
// 宽度在 layoutSubviews 里现算，卡片换尺寸也不会像原来那样「条挤在一角」。
@interface SLWaveBarView : UIView
@property (nonatomic, assign) CGFloat progress;   // 0..1
- (void)setHeights:(NSArray<NSNumber *> *)heights played:(UIColor *)played idle:(UIColor *)idle;
@end

@implementation SLWaveBarView {
    NSMutableArray<UIView *> *_bars;
    NSArray<NSNumber *> *_heights;
    UIColor *_played;
    UIColor *_idle;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bars = [NSMutableArray array];
        _played = [UIColor systemBlueColor];
        _idle = [UIColor colorWithWhite:0.76 alpha:1];
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (void)setHeights:(NSArray<NSNumber *> *)heights played:(UIColor *)played idle:(UIColor *)idle {
    if (played) _played = played;
    if (idle) _idle = idle;
    _heights = [heights copy];
    for (UIView *v in _bars) [v removeFromSuperview];
    [_bars removeAllObjects];
    for (NSUInteger i = 0; i < _heights.count; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectZero];
        [_bars addObject:b];
        [self addSubview:b];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    NSUInteger n = _bars.count;
    if (n == 0 || w < 4 || h < 4) return;
    CGFloat gap = 2.0;
    CGFloat bw = (w - gap * (CGFloat)(n - 1)) / (CGFloat)n;
    if (bw < 1.2) {
        gap = 0.6;
        bw = (w - gap * (CGFloat)(n - 1)) / (CGFloat)n;
    }
    if (bw < 0.8) bw = 0.8;
    for (NSUInteger i = 0; i < n; i++) {
        double ratio = MAX(0.16, [_heights[i] doubleValue]);
        CGFloat bh = MAX(3.0, (CGFloat)ratio * h);
        UIView *b = _bars[i];
        b.frame = CGRectMake((CGFloat)i * (bw + gap), (h - bh) / 2.0, bw, bh);
        b.layer.cornerRadius = MIN(bw, 4.0) / 2.0;
    }
    [self sl_recolor];
}

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
    [self sl_recolor];
}

- (void)sl_recolor {
    NSUInteger n = _bars.count;
    if (n == 0) return;
    CGFloat p = _progress;
    if (p < 0) p = 0;
    if (p > 1) p = 1;
    for (NSUInteger i = 0; i < n; i++) {
        UIView *b = _bars[i];
        double edge = ((double)i + 0.5) / (double)n;
        b.backgroundColor = (edge <= p) ? _played : _idle;
    }
}

@end

#pragma mark - 图文按钮

// UIButton 的 imageEdgeInsets / titleEdgeInsets 在新 SDK 是弃用 error，
// 这里自己排：图标 + 固定间距 + 文字，整体水平居中。
@interface SLIconTextButton : UIButton
@property (nonatomic, assign) CGFloat sl_iconSize;
@property (nonatomic, assign) CGFloat sl_spacing;
@end

@implementation SLIconTextButton

- (void)layoutSubviews {
    [super layoutSubviews];
    UIImageView *iv = self.imageView;
    UILabel *tl = self.titleLabel;
    if (!iv.image || tl.text.length == 0) return;
    CGFloat is = self.sl_iconSize > 0 ? self.sl_iconSize : 18.0;
    CGFloat sp = self.sl_spacing > 0 ? self.sl_spacing : 6.0;
    CGSize ts = [tl sizeThatFits:CGSizeMake(CGFLOAT_MAX, self.bounds.size.height)];
    CGFloat total = is + sp + ts.width;
    CGFloat x = MAX(0.0, (self.bounds.size.width - total) / 2.0);
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.frame = CGRectMake(x, (self.bounds.size.height - is) / 2.0, is, is);
    tl.frame = CGRectMake(x + is + sp, (self.bounds.size.height - ts.height) / 2.0, ts.width, ts.height);
}

@end

@interface SLTTSAuditionViewController : UIViewController <AVAudioPlayerDelegate>
@property (nonatomic, copy) NSString *audioPath;        // 最终发出去的 .amr（兜底）
@property (nonatomic, strong) NSData *pcm16k;           // 试听用 PCM
@property (nonatomic, copy) NSString *playbackPath;     // 实际播放的文件
@property (nonatomic, copy) NSString *tempWavPath;      // 自己写的临时 WAV，退出要删
@property (nonatomic, copy) NSString *bodyText;
@property (nonatomic, assign) double duration;
@property (nonatomic, copy) void (^onUse)(void);
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic, copy) void (^onRetry)(void);
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, strong) SLWaveBarView *wave;
@property (nonatomic, weak) UILabel *curLabel;
@property (nonatomic, weak) UILabel *totalLabel;
@property (nonatomic, weak) UILabel *hintLabel;
@property (nonatomic, weak) UIButton *playButton;
@property (nonatomic, strong) CAShapeLayer *ringTrack;
@property (nonatomic, strong) CAShapeLayer *ringFill;
@property (nonatomic, weak) UIView *card;
@property (nonatomic, assign) BOOL chosen;
@property (nonatomic, assign) BOOL speakerOverridden;
@property (nonatomic, assign) BOOL sessionSaved;
@property (nonatomic, copy) NSString *savedCategory;
@property (nonatomic, copy) NSString *savedMode;
@property (nonatomic, assign) AVAudioSessionCategoryOptions savedOptions;
@property (nonatomic, assign) double tickStart;
@property (nonatomic, assign) BOOL failed;

- (NSArray<NSNumber *> *)sl_waveHeights:(NSData *)pcm bars:(NSInteger)n;
- (NSArray<NSNumber *> *)sl_fakeHeights:(NSInteger)n;
@end

@implementation SLTTSAuditionViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // v0.4.54：去掉整屏遮罩（原来是毛玻璃 + 16% 压暗）。
    // 试听只在卡片上发生，没必要把背后的聊天糊成一片灰；现在背景保持原样，
    // 只靠卡片自己的阴影和毛玻璃把层次撑起来。
    // 空出来的区域仍然吞掉触摸（view 本身透明但可命中），不会误触到下面的聊天。

    UIColor *tint = self.view.tintColor ?: [UIColor systemBlueColor];

    // v0.4.34：卡片再收一档。原来 320×436，屏幕中间糊一大块，
    // 播放键单独占一行、两边全空。现在 300×300：播放键并进播放条左侧，
    // 右边接满波形和时间；标题组跟图标同一条垂直中线，文字统一左对齐。
    CGFloat cardW = MIN(300.0, self.view.bounds.size.width - 40.0);
    CGFloat cardH = 300.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((self.view.bounds.size.width - cardW) / 2.0,
                                                          (self.view.bounds.size.height - cardH) / 2.0,
                                                          cardW, cardH)];
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.layer.cornerRadius = 24.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.22;   // v0.4.54：遮罩去掉后，卡片的层次全靠这层阴影
    card.layer.shadowRadius = 28.0;
    card.layer.shadowOffset = CGSizeMake(0, 12);
    card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:card.bounds cornerRadius:24.0].CGPath;
    [self.view addSubview:card];
    self.card = card;

    // 卡片本体毛玻璃，不再是死白底
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    glass.frame = card.bounds;
    glass.layer.cornerRadius = 24.0;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;
    [card addSubview:glass];

    UIView *hair = [[UIView alloc] initWithFrame:CGRectMake(0.5, 0.5, cardW - 1.0, cardH - 1.0)];
    hair.layer.cornerRadius = 23.5;
    hair.layer.cornerCurve = kCACornerCurveContinuous;
    hair.layer.borderWidth = 0.5;
    hair.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    hair.userInteractionEnabled = NO;
    [card addSubview:hair];

    CGFloat ix = 18.0;              // 内容左右内缩（所有文字共用这一条左基线）
    CGFloat cw = cardW - ix * 2.0;  // 内容宽

    // —— 头部：图标 + 标题 + 一句话，整组按图标中线居中 ——
    UIView *iconChip = [[UIView alloc] initWithFrame:CGRectMake(ix, 18, 38, 38)];
    iconChip.backgroundColor = [tint colorWithAlphaComponent:0.13];
    iconChip.layer.cornerRadius = 12.0;
    iconChip.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:iconChip];

    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
    glyph.tintColor = tint;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    glyph.frame = CGRectMake(10, 10, 18, 18);
    [iconChip addSubview:glyph];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(ix + 50, 19, cw - 50, 20)];
    title.text = @"试听 AI 语音";
    title.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    [card addSubview:title];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(ix + 50, 41, cw - 50, 16)];
    NSString *t = self.bodyText.length > 26
        ? [[self.bodyText substringToIndex:26] stringByAppendingString:@"…"]
        : self.bodyText;
    // v0.4.34：不再用「」包住，用户明确说下面这行小字不要带括号
    body.text = t.length ? t : @"没有文字内容";
    body.font = [UIFont systemFontOfSize:12];
    body.textColor = [UIColor secondaryLabelColor];
    body.numberOfLines = 1;
    body.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:body];

    // —— 播放条：左边播放键（带小进度环），右边整条波形 + 时间 ——
    UIView *player = [[UIView alloc] initWithFrame:CGRectMake(ix, 72, cw, 74)];
    player.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.08];
    player.layer.cornerRadius = 16.0;
    player.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:player];

    UIView *playWrap = [[UIView alloc] initWithFrame:CGRectMake(12, 14, 46, 46)];
    playWrap.backgroundColor = [UIColor clearColor];
    [player addSubview:playWrap];

    UIButton *play = [UIButton buttonWithType:UIButtonTypeCustom];
    play.frame = CGRectMake(5, 5, 36, 36);
    play.backgroundColor = tint;
    play.tintColor = [UIColor whiteColor];
    play.layer.cornerRadius = 18.0;
    play.layer.cornerCurve = kCACornerCurveContinuous;
    [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    play.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [play addTarget:self action:@selector(sl_playTapped) forControlEvents:UIControlEventTouchUpInside];
    [playWrap addSubview:play];
    self.playButton = play;

    UIBezierPath *ringPath = [UIBezierPath bezierPathWithArcCenter:CGPointMake(23, 23) radius:21
                                                          startAngle:-M_PI_2
                                                            endAngle:-M_PI_2 + M_PI * 2
                                                           clockwise:YES];
    CAShapeLayer *rt = [CAShapeLayer layer];
    rt.lineWidth = 2.5;
    rt.fillColor = nil;
    rt.strokeColor = [tint colorWithAlphaComponent:0.18].CGColor;
    rt.path = ringPath.CGPath;
    [playWrap.layer addSublayer:rt];
    self.ringTrack = rt;

    CAShapeLayer *rf = [CAShapeLayer layer];
    rf.lineWidth = 2.5;
    rf.fillColor = nil;
    rf.strokeColor = tint.CGColor;
    rf.lineCap = kCALineCapRound;
    rf.path = ringPath.CGPath;
    rf.strokeEnd = 0;
    [playWrap.layer addSublayer:rf];
    self.ringFill = rf;

    CGFloat waveX = 70.0;
    CGFloat waveW = cw - waveX - 14.0;
    SLWaveBarView *wave = [[SLWaveBarView alloc] initWithFrame:CGRectMake(waveX, 15, waveW, 26)];
    NSArray<NSNumber *> *hs = [self sl_waveHeights:self.pcm16k bars:40];
    if (hs.count < 8) hs = [self sl_fakeHeights:40];   // 没有 PCM（退回播原文件）时别留一块空白
    [wave setHeights:hs
              played:tint
                idle:[UIColor colorWithWhite:0.78 alpha:1]];
    [player addSubview:wave];
    self.wave = wave;

    UILabel *cur = [[UILabel alloc] initWithFrame:CGRectMake(waveX, 44, 56, 14)];
    cur.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    cur.textColor = [UIColor secondaryLabelColor];
    cur.text = @"0:00";
    [player addSubview:cur];
    self.curLabel = cur;

    UILabel *total = [[UILabel alloc] initWithFrame:CGRectMake(waveX + waveW - 64, 44, 64, 14)];
    total.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    total.textColor = [UIColor secondaryLabelColor];
    total.textAlignment = NSTextAlignmentRight;
    total.text = SLFmtTime(self.duration);
    [player addSubview:total];
    self.totalLabel = total;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(ix, 154, cw, 15)];
    hint.font = [UIFont systemFontOfSize:11.5];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.textAlignment = NSTextAlignmentLeft;
    hint.text = @"觉得可以就去录音，录音会被替换成这条";
    hint.numberOfLines = 1;
    [card addSubview:hint];
    self.hintLabel = hint;

    // 主按钮：自定义图文按钮，图标与文字之间留 7pt，不再挤成一坨
    SLIconTextButton *use = [SLIconTextButton buttonWithType:UIButtonTypeCustom];
    use.frame = CGRectMake(ix, 181, cw, 46);
    [use setTitle:@"用这条，去录音" forState:UIControlStateNormal];
    use.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    use.backgroundColor = tint;
    [use setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    use.tintColor = [UIColor whiteColor];
    use.layer.cornerRadius = 14.0;
    use.layer.cornerCurve = kCACornerCurveContinuous;
    [use setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
    use.sl_iconSize = 16.0;
    use.sl_spacing = 7.0;
    [use addTarget:self action:@selector(sl_useTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:use];

    // 次要按钮行：两个等宽胶囊
    CGFloat halfW = (cw - 10.0) / 2.0;
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeCustom];
    retry.frame = CGRectMake(ix, 237, halfW, 42);
    [retry setTitle:@"重新合成" forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [retry setTitleColor:tint forState:UIControlStateNormal];
    retry.backgroundColor = [tint colorWithAlphaComponent:0.13];
    retry.layer.cornerRadius = 12.0;
    retry.layer.cornerCurve = kCACornerCurveContinuous;
    [retry addTarget:self action:@selector(sl_retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:retry];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(ix + halfW + 10.0, 237, halfW, 42);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [cancel setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    cancel.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.13];
    cancel.layer.cornerRadius = 12.0;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    [cancel addTarget:self action:@selector(sl_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 卡片弹入
    self.card.alpha = 0.0;
    self.card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.card.alpha = 1.0;
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
    [self sl_play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sl_stopTicker];
    [self.player stop];
    self.player = nil;
    if (self.speakerOverridden) {
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
        self.speakerOverridden = NO;
    }
    if (self.sessionSaved) {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        NSError *e = nil;
        BOOL ok = [s setCategory:self.savedCategory ?: AVAudioSessionCategorySoloAmbient
                            mode:self.savedMode ?: AVAudioSessionModeDefault
                         options:self.savedOptions
                           error:&e];
        SLLog(@"AUDITION 还原会话 cat=%@/%d %@", self.savedCategory, ok, e.localizedDescription ?: @"");
        self.sessionSaved = NO;
    }
    if (self.tempWavPath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.tempWavPath error:nil];
        self.tempWavPath = nil;
    }
}

#pragma mark - 准备可播放的文件

// 优先用 PCM 现场封 WAV；没有 PCM 才退回陌陌那个 .amr（大概率还是播不了，但别丢功能）。
- (NSString *)sl_preparePlaybackFile {
    if (self.playbackPath.length) return self.playbackPath;

    if (self.pcm16k.length > 1600) {
        NSData *wav = SLWavFromPCM(self.pcm16k, 16000, 1, 16);
        if (wav.length > 44) {
            NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"sl_audition_%@.wav", [[NSUUID UUID] UUIDString]]];
            if ([wav writeToFile:p atomically:YES]) {
                self.playbackPath = p;
                self.tempWavPath = p;
                SLLog(@"AUDITION 试听用 WAV pcm=%lu wav=%lu dur=%.2f",
                      (unsigned long)self.pcm16k.length, (unsigned long)wav.length,
                      (double)(self.pcm16k.length / 2) / 16000.0);
                return p;
            }
            SLLog(@"AUDITION WAV 写盘失败 %@", p);
        } else {
            SLLog(@"AUDITION WAV 封装失败 pcm=%lu", (unsigned long)self.pcm16k.length);
        }
    } else {
        SLLog(@"AUDITION 没有 PCM（%lu），退回直接播原文件", (unsigned long)self.pcm16k.length);
    }

    self.playbackPath = self.audioPath;
    return self.playbackPath;
}

#pragma mark - 会话

- (BOOL)sl_activateSession {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (!self.sessionSaved) {
        self.savedCategory = s.category;
        self.savedMode = s.mode;
        self.savedOptions = s.categoryOptions;
        self.sessionSaved = YES;
        SLLog(@"AUDITION 原会话 cat=%@ mode=%@ opt=%lu otherAudio=%d",
              self.savedCategory, self.savedMode, (unsigned long)self.savedOptions,
              (int)s.otherAudioPlaying);
    }
    NSError *e = nil;
    BOOL ok = [s setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeDefault
                     options:AVAudioSessionCategoryOptionDuckOthers
                       error:&e];
    if (!ok) SLLog(@"AUDITION setCategory 失败 %@", e.localizedDescription ?: @"");
    e = nil;
    BOOL act = [s setActive:YES
                withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                      error:&e];
    if (!act) {
        e = nil;
        act = [s setActive:YES error:&e];
    }
    if (!act) SLLog(@"AUDITION 激活会话失败 %@", e.localizedDescription ?: @"");
    return act;
}

#pragma mark - 播放

- (void)sl_setPlayingLook:(BOOL)playing {
    UIImage *img = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
    [self.playButton setImage:img forState:UIControlStateNormal];
}

- (void)sl_markFailed:(NSString *)why {
    self.failed = YES;
    [self sl_stopTicker];
    [self sl_setPlayingLook:NO];
    self.hintLabel.text = why.length ? why : @"播放失败，点 ▶ 重试";
    self.hintLabel.textColor = [UIColor systemOrangeColor];
    SLLog(@"AUDITION 播放失败：%@", why ?: @"");
}

- (void)sl_play {
    if (!self.audioPath.length && !self.pcm16k.length) {
        [self sl_markFailed:@"没有音频"];
        return;
    }
    self.failed = NO;
    self.hintLabel.textColor = [UIColor tertiaryLabelColor];
    self.hintLabel.text = @"觉得可以就去录音，录音会被替换成这条";

    BOOL sessionOK = [self sl_activateSession];
    NSString *file = [self sl_preparePlaybackFile];

    if (!self.player) {
        NSError *err = nil;
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:file]
                                                            error:&err];
        if (!self.player) {
            SLLog(@"AUDITION 打开失败 %@ file=%@", err.localizedDescription ?: @"", file.lastPathComponent);
            [self sl_markFailed:@"音频打不开，点「重新合成」再试一次"];
            return;
        }
        self.player.delegate = self;
        self.player.volume = 1.0;
        BOOL prep = [self.player prepareToPlay];
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:file error:nil];
        SLLog(@"AUDITION ready file=%@ session=%d prepare=%d dur=%.2f size=%llu cat=%@ sr=%.0f",
              file.lastPathComponent, sessionOK, prep, self.player.duration,
              [attr[NSFileSize] unsignedLongLongValue], s.category, s.sampleRate);
        if (!prep) {
            // prepare 失败不直接判死，play 有时还能成；真不行下面会兜
            SLLog(@"AUDITION prepareToPlay=NO（格式或硬件就绪失败）");
        }
    }
    BOOL ok = [self.player play];
    if (!ok) {
        [self sl_activateSession];
        ok = [self.player play];
    }
    if (!ok) {
        SLLog(@"AUDITION play=NO dur=%.2f cur=%.2f", self.player.duration, self.player.currentTime);
        [self sl_markFailed:@"这条播不出来，点「重新合成」再试一次"];
        return;
    }
    [self sl_setPlayingLook:YES];
    self.tickStart = CFAbsoluteTimeGetCurrent();
    [self sl_startTicker];
}

- (void)sl_playTapped {
    if (self.player.isPlaying) {
        [self.player pause];
        [self sl_setPlayingLook:NO];
        [self sl_stopTicker];
        return;
    }
    if (self.player && self.player.duration > 0 &&
        self.player.currentTime >= self.player.duration - 0.05) {
        self.player.currentTime = 0;
    }
    [self sl_play];
}

- (void)sl_startTicker {
    [self sl_stopTicker];
    __weak typeof(self) weakSelf = self;
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        [weakSelf sl_refreshProgress];
    }];
}

- (void)sl_stopTicker {
    [self.ticker invalidate];
    self.ticker = nil;
}

- (void)sl_refreshProgress {
    double d = self.player.duration > 0 ? self.player.duration : self.duration;
    double c = self.player.currentTime;
    double p = (d > 0) ? (c / d) : 0;
    if (p < 0) p = 0;
    if (p > 1) p = 1;

    self.wave.progress = p;
    self.curLabel.text = SLFmtTime(c);
    self.totalLabel.text = SLFmtTime(d);
    if (self.ringFill) self.ringFill.strokeEnd = p;

    // 看门狗：play 返回 YES 但进度钉死不动，别让界面永远停在播放中
    if (!self.failed && c < 0.001 && !self.player.isPlaying &&
        CFAbsoluteTimeGetCurrent() - self.tickStart > 1.2) {
        [self sl_markFailed:@"这条播不出来，点「重新合成」再试一次"];
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self sl_stopTicker];
    self.wave.progress = 0;
    self.curLabel.text = @"0:00";
    if (self.ringFill) self.ringFill.strokeEnd = 0;
    [self sl_setPlayingLook:NO];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    SLLog(@"AUDITION 解码错误 %@", error.localizedDescription ?: @"");
    [self sl_markFailed:@"这条播不出来，点「重新合成」再试一次"];
}

#pragma mark - 按钮

- (void)sl_dismissWith:(void (^)(void))cb {
    [self dismissViewControllerAnimated:YES completion:^{
        if (sSLShownPanel == self) sSLShownPanel = nil;
        if (cb) cb();
    }];
}

- (void)sl_useTapped {
    self.chosen = YES;
    [self sl_dismissWith:self.onUse];
}

- (void)sl_cancelTapped {
    self.chosen = YES;
    [self sl_dismissWith:self.onCancel];
}

- (void)sl_retryTapped {
    self.chosen = YES;
    [self sl_dismissWith:self.onRetry];
}

// 没有 PCM 时给一条「看起来像语音」的假声波，纯粹为了界面不空着
- (NSArray<NSNumber *> *)sl_fakeHeights:(NSInteger)n {
    if (n <= 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        double a = sin((double)i * 0.62) * 0.32 + sin((double)i * 1.37 + 1.1) * 0.22;
        double v = 0.46 + a;
        if (v < 0.14) v = 0.14;
        if (v > 1.0) v = 1.0;
        [out addObject:@(v)];
    }
    return out;
}

- (NSArray<NSNumber *> *)sl_waveHeights:(NSData *)pcm bars:(NSInteger)n {
    if (pcm.length < 2 || n <= 0) return @[];
    NSInteger total = pcm.length / 2;
    if (total < n) n = total;
    int16_t *buf = (int16_t *)pcm.bytes;
    NSInteger step = total / n;
    if (step < 1) step = 1;
    double max = 1;
    NSMutableArray *raw = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        NSInteger s = i * step, e = (i + 1) * step;
        if (e <= s) e = s + 1;
        double sum = 0;
        for (NSInteger j = s; j < e; j++) {
            double v = buf[j] / 32768.0;
            sum += v * v;
        }
        double r = sqrt(sum / (e - s));
        [raw addObject:@(r)];
        if (r > max) max = r;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *r in raw) [out addObject:@(MAX(0.12, r.doubleValue / max))];
    return out;
}

@end

@implementation SLTTSAuditionPanel

+ (BOOL)isEnabled {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSLTTSPreviewKey];
    return v ? [v boolValue] : YES;   // 默认开
}

+ (void)setEnabled:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLTTSPreviewKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    SLLog(@"AUDITION 开关 -> %@", on ? @"开" : @"关");
}

+ (BOOL)isShowing {
    return sSLShownPanel != nil && sSLShownPanel.presentingViewController != nil;
}

+ (void)presentWithAudioPath:(NSString *)path
                      pcm16k:(NSData *)pcm16k
                    duration:(double)duration
                        text:(NSString *)text
                       onUse:(void (^)(void))onUse
                    onCancel:(void (^)(void))onCancel
                     onRetry:(void (^)(void))onRetry {
    if (!path.length && pcm16k.length < 1600) {
        if (onUse) onUse();   // 没有音频就没法试听，直接按「用这条」继续
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [AWECAUtils topViewController];
        if (!top || top.presentedViewController) {
            SLLog(@"AUDITION 没有可用的顶层页面，跳过试听");
            if (onUse) onUse();
            return;
        }
        SLTTSAuditionViewController *vc = [[SLTTSAuditionViewController alloc] init];
        vc.audioPath = path;
        vc.pcm16k = pcm16k;
        vc.bodyText = text;
        vc.duration = duration;
        vc.onUse = onUse;
        vc.onCancel = onCancel;
        vc.onRetry = onRetry;
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        sSLShownPanel = vc;
        [top presentViewController:vc animated:NO completion:^{
            // v0.4.54：卡片出现后把球抬到最上层，别被试听卡片压住
            SLRaiseFloatButton();
        }];
        SLLog(@"AUDITION 弹出试听 %@ dur=%.2f pcm=%lu",
              path.lastPathComponent, duration, (unsigned long)pcm16k.length);
    });
}

+ (void)stopAndDismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        SLTTSAuditionViewController *vc = sSLShownPanel;
        if (!vc || !vc.presentingViewController) return;
        vc.chosen = YES;   // 外部关闭不触发任何回调
        [vc dismissViewControllerAnimated:YES completion:nil];
        sSLShownPanel = nil;
    });
}

@end
