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
}

#pragma mark - 播放

- (void)sl_play {
    if (!self.audioPath.length) return;
    if (!self.player) {
        NSError *err = nil;
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:self.audioPath]
                                                            error:&err];
        if (!self.player) {
            SLLog(@"AUDITION 打开失败 %@", err.localizedDescription ?: @"");
            [self.timeLabel setText:@"音频打不开"];
            return;
        }
        self.player.delegate = self;
        [self.player prepareToPlay];
        // 录音/播放会话常常默认走听筒，试听要能听清 → 临时切扬声器
        if ([[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                                                              error:nil]) {
            self.speakerOverridden = YES;
        }
    }
    [self.player play];
    [self.playButton setTitle:@"⟳ 播放中" forState:UIControlStateNormal];
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
