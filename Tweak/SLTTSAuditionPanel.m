//
//  SLTTSAuditionPanel.m
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

@interface SLTTSAuditionViewController : UIViewController <AVAudioPlayerDelegate>
@property (nonatomic, copy) NSString *audioPath;
@property (nonatomic, copy) NSString *bodyText;
@property (nonatomic, assign) double duration;
@property (nonatomic, copy) void (^onUse)(void);
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic, copy) void (^onRetry)(void);
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, weak) UIProgressView *bar;
@property (nonatomic, weak) UILabel *timeLabel;
@property (nonatomic, weak) UIButton *playButton;
@property (nonatomic, assign) BOOL chosen;
@property (nonatomic, assign) BOOL speakerOverridden;
// v0.4.12：进面板前记下陌陌正在用的音频会话，退出时原样还回去
@property (nonatomic, assign) BOOL sessionSaved;
@property (nonatomic, copy) NSString *savedCategory;
@property (nonatomic, copy) NSString *savedMode;
@property (nonatomic, assign) AVAudioSessionCategoryOptions savedOptions;
@property (nonatomic, assign) double tickStart;
@property (nonatomic, assign) BOOL failed;
@end

@implementation SLTTSAuditionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 18.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"试听 AI 语音";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    UILabel *body = [[UILabel alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *t = self.bodyText.length > 60
        ? [[self.bodyText substringToIndex:60] stringByAppendingString:@"…"]
        : self.bodyText;
    body.text = t.length ? t : @"（无文字）";
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = [UIColor secondaryLabelColor];
    body.numberOfLines = 2;
    body.textAlignment = NSTextAlignmentCenter;
    [card addSubview:body];

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.progressTintColor = self.view.tintColor;
    [card addSubview:bar];
    self.bar = bar;

    UILabel *time = [[UILabel alloc] init];
    time.translatesAutoresizingMaskIntoConstraints = NO;
    time.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    time.textColor = [UIColor tertiaryLabelColor];
    time.textAlignment = NSTextAlignmentCenter;
    time.text = [NSString stringWithFormat:@"0:00.0 / %@", SLFmtTime(self.duration)];
    [card addSubview:time];
    self.timeLabel = time;

    UIButton *play = [UIButton buttonWithType:UIButtonTypeSystem];
    play.translatesAutoresizingMaskIntoConstraints = NO;
    [play setTitle:@"▶ 重听" forState:UIControlStateNormal];
    play.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [play addTarget:self action:@selector(sl_playTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:play];
    self.playButton = play;

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    [retry setTitle:@"重新合成" forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont systemFontOfSize:15];
    [retry addTarget:self action:@selector(sl_retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:retry];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:15];
    [cancel setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(sl_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];

    UIButton *use = [UIButton buttonWithType:UIButtonTypeSystem];
    use.translatesAutoresizingMaskIntoConstraints = NO;
    [use setTitle:@"用这条" forState:UIControlStateNormal];
    use.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    use.backgroundColor = self.view.tintColor;
    [use setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    use.layer.cornerRadius = 10.0;
    use.layer.cornerCurve = kCACornerCurveContinuous;
    [use addTarget:self action:@selector(sl_useTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:use];

    UILayoutGuide *g = card.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:320.0],

        [title.topAnchor constraintEqualToAnchor:g.topAnchor constant:18.0],
        [title.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8.0],
        [body.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [bar.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:16.0],
        [bar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [time.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:4.0],
        [time.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [time.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],

        [play.topAnchor constraintEqualToAnchor:time.bottomAnchor constant:6.0],
        [play.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [play.heightAnchor constraintEqualToConstant:36.0],

        [cancel.topAnchor constraintEqualToAnchor:play.bottomAnchor constant:6.0],
        [cancel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-18.0],
        [cancel.heightAnchor constraintEqualToConstant:40.0],

        [retry.topAnchor constraintEqualToAnchor:cancel.topAnchor],
        [retry.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [retry.heightAnchor constraintEqualToConstant:40.0],

        [use.topAnchor constraintEqualToAnchor:cancel.topAnchor],
        [use.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [use.widthAnchor constraintEqualToConstant:96.0],
        [use.heightAnchor constraintEqualToConstant:40.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self sl_play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self sl_stopTicker];
    [self.player stop];
    self.player = nil;
    if (self.speakerOverridden) {
        // 只撤销我们自己加的输出覆盖，不改 category —— 陌陌可能正握着录音会话
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
        self.speakerOverridden = NO;
    }
    // v0.4.12：把会话还给陌陌。不还的话陌陌下次录音会「录不进去」或音量异常。
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
}

#pragma mark - 播放

// 陌陌刚录完音，会话往往停在 PlayAndRecord/Record 甚至是「已停用」状态；
// 这时直接 play 会返回 NO（声音出不来、进度条也不动）。
// 必须先把 category 切到 Playback 并且 setActive:YES。
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

- (void)sl_markFailed:(NSString *)why {
    self.failed = YES;
    [self sl_stopTicker];
    self.bar.progress = 0;
    [self.playButton setTitle:@"▶ 重听" forState:UIControlStateNormal];
    self.timeLabel.text = why.length ? why : @"播放失败";
    SLLog(@"AUDITION 播放失败：%@", why ?: @"");
}

- (void)sl_play {
    if (!self.audioPath.length) {
        [self sl_markFailed:@"没有音频文件"];
        return;
    }
    self.failed = NO;
    BOOL sessionOK = [self sl_activateSession];
    if (!self.player) {
        NSError *err = nil;
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:self.audioPath]
                                                            error:&err];
        if (!self.player) {
            SLLog(@"AUDITION 打开失败 %@ file=%@", err.localizedDescription ?: @"", self.audioPath);
            [self sl_markFailed:@"音频打不开"];
            return;
        }
        self.player.delegate = self;
        self.player.volume = 1.0;
        BOOL prep = [self.player prepareToPlay];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:self.audioPath error:nil];
        SLLog(@"AUDITION ready session=%d prepare=%d dur=%.2f size=%llu file=%@",
              sessionOK, prep, self.player.duration,
              [attr[NSFileSize] unsignedLongLongValue], self.audioPath.lastPathComponent);
    }
    BOOL ok = [self.player play];
    if (!ok) {
        // 会话可能在这一瞬间被陌陌重新抢走，重激活后再试一次
        [self sl_activateSession];
        ok = [self.player play];
    }
    if (!ok) {
        SLLog(@"AUDITION play 返回 NO dur=%.2f cur=%.2f", self.player.duration, self.player.currentTime);
        [self sl_markFailed:@"无法播放（音频被占用）"];
        return;
    }
    [self.playButton setTitle:@"⟳ 播放中" forState:UIControlStateNormal];
    self.tickStart = CFAbsoluteTimeGetCurrent();
    [self sl_startTicker];
}

- (void)sl_playTapped {
    if (self.player.isPlaying) {
        [self.player pause];
        [self.playButton setTitle:@"▶ 重听" forState:UIControlStateNormal];
        [self sl_stopTicker];
        return;
    }
    self.player.currentTime = 0;
    [self sl_play];
}

- (void)sl_startTicker {
    [self sl_stopTicker];
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        [self sl_refreshProgress];
    }];
}

- (void)sl_stopTicker {
    [self.ticker invalidate];
    self.ticker = nil;
}

- (void)sl_refreshProgress {
    double d = self.player.duration > 0 ? self.player.duration : self.duration;
    double c = self.player.currentTime;
    if (d > 0) self.bar.progress = (float)(c / d);
    self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@", SLFmtTime(c), SLFmtTime(d)];
    // 看门狗：play 返回 YES 但实际不出声（路由被抢）时，进度会一直钉在 0；
    // 1 秒还没动就当作失败，别让界面永远停在「播放中」。
    if (!self.failed && c < 0.001 && !self.player.isPlaying &&
        CFAbsoluteTimeGetCurrent() - self.tickStart > 1.0) {
        [self sl_markFailed:@"无法播放（音频被占用）"];
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self sl_stopTicker];
    self.bar.progress = 0;
    self.timeLabel.text = [NSString stringWithFormat:@"0:00.0 / %@", SLFmtTime(self.duration)];
    [self.playButton setTitle:@"▶ 重听" forState:UIControlStateNormal];
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
                    duration:(double)duration
                        text:(NSString *)text
                       onUse:(void (^)(void))onUse
                    onCancel:(void (^)(void))onCancel
                     onRetry:(void (^)(void))onRetry {
    if (!path.length) {
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
        vc.bodyText = text;
        vc.duration = duration;
        vc.onUse = onUse;
        vc.onCancel = onCancel;
        vc.onRetry = onRetry;
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        sSLShownPanel = vc;
        [top presentViewController:vc animated:YES completion:nil];
        SLLog(@"AUDITION 弹出试听 %@ dur=%.2f", path.lastPathComponent, duration);
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
