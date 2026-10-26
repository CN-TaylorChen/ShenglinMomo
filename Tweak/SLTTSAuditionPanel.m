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
#import "SLLog.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static NSString *const kSLTTSPreviewKey = @"SLTTSPreview";
@class SLTTSAuditionViewController;
static SLTTSAuditionViewController *sSLShownPanel = nil;

static NSString *SLFmtTime(double t) {
    if (t < 0 || !isfinite(t)) t = 0;
    int m = (int)(t / 60.0);
    double s = t - m * 60.0;
    return [NSString stringWithFormat:@"%d:%04.1f", m, s];
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
@property (nonatomic, weak) UIView *barTrack;
@property (nonatomic, weak) UIView *barFill;
@property (nonatomic, strong) NSLayoutConstraint *fillWidth;
@property (nonatomic, weak) UILabel *curLabel;
@property (nonatomic, weak) UILabel *totalLabel;
@property (nonatomic, weak) UILabel *hintLabel;
@property (nonatomic, weak) UIButton *playButton;
@property (nonatomic, weak) UIView *card;
@property (nonatomic, assign) BOOL chosen;
@property (nonatomic, assign) BOOL speakerOverridden;
@property (nonatomic, assign) BOOL sessionSaved;
@property (nonatomic, copy) NSString *savedCategory;
@property (nonatomic, copy) NSString *savedMode;
@property (nonatomic, assign) AVAudioSessionCategoryOptions savedOptions;
@property (nonatomic, assign) double tickStart;
@property (nonatomic, assign) BOOL failed;
@end

@implementation SLTTSAuditionViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // 遮罩：模糊 + 压暗，比纯色 0.45 的灰干净很多，且能透出聊天背景
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:blur];
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 26.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.18;
    card.layer.shadowRadius = 26.0;
    card.layer.shadowOffset = CGSizeMake(0, 12);
    [self.view addSubview:card];
    self.card = card;

    UIColor *tint = self.view.tintColor ?: [UIColor systemBlueColor];

    // 顶部音波图标
    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [tint colorWithAlphaComponent:0.14];
    badge.layer.cornerRadius = 26.0;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:badge];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = tint;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [badge addSubview:icon];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"试听 AI 语音";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    UILabel *body = [[UILabel alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *t = self.bodyText.length > 64
        ? [[self.bodyText substringToIndex:64] stringByAppendingString:@"…"]
        : self.bodyText;
    body.text = t.length ? [NSString stringWithFormat:@"「%@」", t] : @"（无文字）";
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = [UIColor secondaryLabelColor];
    body.numberOfLines = 2;
    body.textAlignment = NSTextAlignmentCenter;
    body.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:body];

    // 进度条（自绘，UIProgressView 那根细线太糙）
    UIView *track = [[UIView alloc] init];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.backgroundColor = [UIColor tertiarySystemFillColor];
    track.layer.cornerRadius = 2.5;
    track.layer.cornerCurve = kCACornerCurveContinuous;
    track.clipsToBounds = YES;
    [card addSubview:track];
    self.barTrack = track;

    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = tint;
    [track addSubview:fill];
    self.barFill = fill;

    UILabel *cur = [[UILabel alloc] init];
    cur.translatesAutoresizingMaskIntoConstraints = NO;
    cur.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    cur.textColor = [UIColor tertiaryLabelColor];
    cur.text = @"0:00.0";
    [card addSubview:cur];
    self.curLabel = cur;

    UILabel *total = [[UILabel alloc] init];
    total.translatesAutoresizingMaskIntoConstraints = NO;
    total.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    total.textColor = [UIColor secondaryLabelColor];
    total.textAlignment = NSTextAlignmentRight;
    total.text = SLFmtTime(self.duration);
    [card addSubview:total];
    self.totalLabel = total;

    // 圆形播放键
    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.translatesAutoresizingMaskIntoConstraints = NO;
    play.backgroundColor = tint;
    play.tintColor = [UIColor whiteColor];
    play.layer.cornerRadius = 30.0;
    [play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
    play.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [play addTarget:self action:@selector(sl_playTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:play];
    self.playButton = play;

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.text = @"觉得可以就去录音，录音会被替换成这条";
    hint.numberOfLines = 2;
    [card addSubview:hint];
    self.hintLabel = hint;

    // 主按钮
    UIButton *use = [UIButton buttonWithType:UIButtonTypeSystem];
    use.translatesAutoresizingMaskIntoConstraints = NO;
    [use setTitle:@"用这条，去录音" forState:UIControlStateNormal];
    use.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    use.backgroundColor = tint;
    [use setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    use.layer.cornerRadius = 14.0;
    use.layer.cornerCurve = kCACornerCurveContinuous;
    [use addTarget:self action:@selector(sl_useTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:use];

    // 次要按钮行
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [retry setTitle:@"重新合成" forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont systemFontOfSize:14];
    [retry setTitleColor:tint forState:UIControlStateNormal];
    [retry addTarget:self action:@selector(sl_retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:retry];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:14];
    [cancel setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(sl_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];

    self.fillWidth = [fill.widthAnchor constraintEqualToConstant:0];

    UILayoutGuide *g = card.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:316.0],

        [badge.topAnchor constraintEqualToAnchor:g.topAnchor constant:22.0],
        [badge.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [badge.widthAnchor constraintEqualToConstant:52.0],
        [badge.heightAnchor constraintEqualToConstant:52.0],

        [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:26.0],
        [icon.heightAnchor constraintEqualToConstant:26.0],

        [title.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:12.0],
        [title.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6.0],
        [body.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [cur.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:20.0],
        [cur.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [total.topAnchor constraintEqualToAnchor:cur.topAnchor],
        [total.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [total.leadingAnchor constraintGreaterThanOrEqualToAnchor:cur.trailingAnchor constant:8.0],

        [track.topAnchor constraintEqualToAnchor:cur.bottomAnchor constant:6.0],
        [track.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [track.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [track.heightAnchor constraintEqualToConstant:5.0],

        [fill.leadingAnchor constraintEqualToAnchor:track.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:track.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:track.bottomAnchor],
        self.fillWidth,

        [play.topAnchor constraintEqualToAnchor:track.bottomAnchor constant:16.0],
        [play.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [play.widthAnchor constraintEqualToConstant:60.0],
        [play.heightAnchor constraintEqualToConstant:60.0],

        [hint.topAnchor constraintEqualToAnchor:play.bottomAnchor constant:10.0],
        [hint.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [use.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:14.0],
        [use.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [use.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [use.heightAnchor constraintEqualToConstant:48.0],

        [retry.topAnchor constraintEqualToAnchor:use.bottomAnchor constant:6.0],
        [retry.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [retry.heightAnchor constraintEqualToConstant:42.0],
        [retry.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-14.0],

        [cancel.topAnchor constraintEqualToAnchor:retry.topAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [cancel.heightAnchor constraintEqualToConstant:42.0],
    ]];
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

    CGFloat w = self.barTrack.bounds.size.width;
    if (w > 1) self.fillWidth.constant = w * p;
    self.curLabel.text = SLFmtTime(c);
    self.totalLabel.text = SLFmtTime(d);

    // 看门狗：play 返回 YES 但进度钉死不动，别让界面永远停在播放中
    if (!self.failed && c < 0.001 && !self.player.isPlaying &&
        CFAbsoluteTimeGetCurrent() - self.tickStart > 1.2) {
        [self sl_markFailed:@"这条播不出来，点「重新合成」再试一次"];
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self sl_stopTicker];
    self.fillWidth.constant = 0;
    self.curLabel.text = @"0:00.0";
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
        [top presentViewController:vc animated:NO completion:nil];
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
