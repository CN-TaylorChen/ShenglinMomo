// 语音包裁剪：波形 + 双手柄选段 + 循环试听 + 另存新文件

#import "SLTrimController.h"
#import "SLVoicePack.h"
#import "SLAMREncoder.h"
#import "AWECAUtils.h"
#import "SLGlass.h"
#import <AVFoundation/AVFoundation.h>

#define kSLTrimMinLen 0.3

#pragma mark - 波形视图

@interface SLWaveView : UIView
@property (nonatomic, strong) NSArray<NSNumber *> *samples;   // 0..1
@property (nonatomic, assign) double startRatio;
@property (nonatomic, assign) double endRatio;
@property (nonatomic, assign) double minGapRatio;
@property (nonatomic, copy) void (^onChange)(double startRatio, double endRatio);
@end

@implementation SLWaveView {
    NSInteger _dragHandle;   // 0 = 起点, 1 = 终点, -1 = 无
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = SLGlassCellColor();   // v0.4.50：波形底也走玻璃片
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;
        self.startRatio = 0;
        self.endRatio = 1;
        self.minGapRatio = 0.02;
        _dragHandle = -1;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sl_pan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (CGFloat)sl_xForRatio:(double)r {
    return (CGFloat)(r * CGRectGetWidth(self.bounds));
}

- (void)sl_pan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:self];
    CGFloat w = CGRectGetWidth(self.bounds);
    if (w <= 0) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        CGFloat ds = fabs(p.x - [self sl_xForRatio:self.startRatio]);
        CGFloat de = fabs(p.x - [self sl_xForRatio:self.endRatio]);
        _dragHandle = (ds <= de) ? 0 : 1;
    }

    double r = MAX(0.0, MIN(1.0, (double)p.x / (double)w));
    if (_dragHandle == 0) {
        double maxStart = self.endRatio - self.minGapRatio;
        self.startRatio = MIN(r, MAX(0.0, maxStart));
    } else if (_dragHandle == 1) {
        double minEnd = self.startRatio + self.minGapRatio;
        self.endRatio = MAX(r, MIN(1.0, minEnd));
    }
    [self setNeedsDisplay];
    if (self.onChange) self.onChange(self.startRatio, self.endRatio);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat w = CGRectGetWidth(rect), h = CGRectGetHeight(rect);
    if (w <= 0 || h <= 0) return;

    NSArray<NSNumber *> *s = self.samples;
    NSInteger n = s.count;
    if (n <= 0) return;

    CGFloat gap = 1.0;
    CGFloat barW = MAX(1.0, (w - 8 - (n - 1) * gap) / (CGFloat)n);
    CGFloat midY = h / 2.0;
    CGFloat maxBarH = h - 16;

    double startX = self.startRatio * w;
    double endX = self.endRatio * w;

    for (NSInteger i = 0; i < n; i++) {
        CGFloat x = 4 + i * (barW + gap);
        CGFloat amp = MAX(0.06, MIN(1.0, s[i].doubleValue));
        CGFloat bh = MAX(3.0, amp * maxBarH);
        CGRect r = CGRectMake(x, midY - bh / 2.0, barW, bh);
        BOOL inside = (x + barW / 2.0) >= startX && (x + barW / 2.0) <= endX;
        UIColor *c = inside ? [UIColor colorWithRed:0.114 green:0.620 blue:0.459 alpha:1.0]
                            : [UIColor colorWithWhite:0.72 alpha:1.0];
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextFillRect(ctx, r);
    }

    // 选区两侧压暗
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.55].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, startX, h));
    CGContextFillRect(ctx, CGRectMake(endX, 0, w - endX, h));

    // 两个手柄
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.114 green:0.620 blue:0.459 alpha:1.0].CGColor);
    CGContextFillRect(ctx, CGRectMake(startX - 2, 0, 4, h));
    CGContextFillRect(ctx, CGRectMake(endX - 2, 0, 4, h));
    CGContextFillRect(ctx, CGRectMake(startX - 1.5, 0, 9, 14));
    CGContextFillRect(ctx, CGRectMake(endX - 7.5, 0, 9, 14));
}

@end

#pragma mark - 裁剪页

@interface SLTrimController () <AVAudioPlayerDelegate>
@property (nonatomic, strong) NSDictionary *pack;
@property (nonatomic, strong) SLWaveView *wave;
@property (nonatomic, strong) UILabel *rangeLabel;
@property (nonatomic, strong) UIButton *playBtn;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double startSec;
@property (nonatomic, assign) double endSec;
@end

@implementation SLTrimController

- (instancetype)initWithPack:(NSDictionary *)pack {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _pack = pack;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"裁剪";
    // v0.4.50：跟设置页统一 —— 毛玻璃底 + 胶囊标题 + 胶囊「保存」
    self.navigationItem.titleView = SLPillTitleView(@"裁剪");
    SLInstallPillBack(self);   // v0.4.53：返回键胶囊
    SLInstallGlassBackdrop(self.view);
    self.navigationItem.rightBarButtonItem = SLPillBarItem(@"保存", self, @selector(sl_save));

    NSString *path = [SLVoicePack pathOfPack:self.pack];
    self.duration = path.length ? [AWECAUtils audioDurationAtPath:path] : 0;
    if (self.duration <= 0.3) self.duration = 0.3;
    self.startSec = 0;
    self.endSec = self.duration;

    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat pad = 16;

    self.wave = [[SLWaveView alloc] initWithFrame:CGRectMake(pad, 20, w - pad * 2, 96)];
    self.wave.minGapRatio = kSLTrimMinLen / self.duration;
    __weak typeof(self) weakSelf = self;
    self.wave.onChange = ^(double s, double e) { [weakSelf sl_updateRangeFromRatios:s end:e]; };
    [self.view addSubview:self.wave];

    self.rangeLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, 124, w - pad * 2, 20)];
    self.rangeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.rangeLabel.textColor = [UIColor secondaryLabelColor];
    self.rangeLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.rangeLabel];

    self.playBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playBtn.frame = CGRectMake(pad, 158, w - pad * 2, 44);
    self.playBtn.backgroundColor = SLGlassCellColor();
    self.playBtn.layer.cornerRadius = 10;
    self.playBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [self.playBtn setTitle:@"循环试听选区" forState:UIControlStateNormal];
    [self.playBtn addTarget:self action:@selector(sl_togglePlay) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.playBtn];

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad + 4, 212, w - pad * 2 - 8, 60)];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.text = @"拖动两个绿色手柄选段，最短 0.3 秒\n保存后另存为「原名-裁剪」，原文件保留";
    [self.view addSubview:self.hintLabel];

    [self sl_updateRangeLabel];

    // 波形采样放后台，避免长音频卡住首屏
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *pcm = path.length ? [SLAMREncoder pcmMono16AtPath:path sampleRate:16000.0] : nil;
        NSArray<NSNumber *> *samples = [SLTrimController sl_samplesFromPCM:pcm buckets:140];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.wave.samples = samples;
            [weakSelf.wave setNeedsDisplay];
        });
    });
}

// 取每段 RMS 做归一化，得到 0..1 的波形
+ (NSArray<NSNumber *> *)sl_samplesFromPCM:(NSData *)pcm buckets:(NSInteger)buckets {
    if (!pcm.length || buckets <= 0) return @[];
    const int16_t *p = (const int16_t *)pcm.bytes;
    NSUInteger total = pcm.length / 2;
    if (!total) return @[];
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)buckets];
    NSUInteger step = MAX(1, total / (NSUInteger)buckets);
    double peak = 1.0;
    for (NSInteger i = 0; i < buckets; i++) {
        NSUInteger from = (NSUInteger)i * step;
        if (from >= total) break;
        NSUInteger to = MIN(total, from + step);
        double sum = 0;
        for (NSUInteger j = from; j < to; j++) {
            double v = (double)p[j] / 32768.0;
            sum += v * v;
        }
        double rms = sqrt(sum / (double)MAX(1, (to - from)));
        if (rms > peak) peak = rms;
        [out addObject:@(rms)];
    }
    double scale = peak > 0.02 ? peak : 0.02;
    NSMutableArray<NSNumber *> *norm = [NSMutableArray arrayWithCapacity:out.count];
    for (NSNumber *n in out) [norm addObject:@(MIN(1.0, n.doubleValue / scale))];
    return norm;
}

- (void)sl_updateRangeFromRatios:(double)s end:(double)e {
    self.startSec = s * self.duration;
    self.endSec = e * self.duration;
    if (self.endSec - self.startSec < kSLTrimMinLen) {
        self.endSec = MIN(self.duration, self.startSec + kSLTrimMinLen);
    }
    [self sl_updateRangeLabel];
    [self sl_loopIfNeeded];
}

- (void)sl_updateRangeLabel {
    self.rangeLabel.text = [NSString stringWithFormat:@"%.1fs – %.1fs · 选区 %.1fs",
                            self.startSec, self.endSec, MAX(0.0, self.endSec - self.startSec)];
}

#pragma mark - 试听

- (void)sl_togglePlay {
    if (self.player.isPlaying) {
        [self sl_stop];
        return;
    }
    NSString *path = [SLVoicePack pathOfPack:self.pack];
    if (!path.length) return;
    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (err || !self.player) {
        [AWECAUtils showToast:@"这段音频放不了" duration:1.8];
        return;
    }
    self.player.delegate = self;
    self.player.currentTime = self.startSec;
    [self.player play];
    [self.playBtn setTitle:@"停止试听" forState:UIControlStateNormal];

    [self.timer invalidate];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [weakSelf sl_loopIfNeeded];
    }];
}

- (void)sl_loopIfNeeded {
    if (!self.player.isPlaying) return;
    if (self.player.currentTime >= self.endSec - 0.02) {
        self.player.currentTime = self.startSec;
        [self.player play];
    }
}

- (void)sl_stop {
    [self.timer invalidate];
    self.timer = nil;
    [self.player stop];
    self.player = nil;
    [self.playBtn setTitle:@"循环试听选区" forState:UIControlStateNormal];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player; (void)flag;
    [self sl_stop];
}

#pragma mark - 保存

- (void)sl_save {
    [self sl_stop];
    NSString *err = nil;
    NSDictionary *newPack = [SLVoicePack trimPack:self.pack from:self.startSec to:self.endSec error:&err];
    if (!newPack) {
        [AWECAUtils showToast:(err.length ? err : @"裁剪失败") duration:2.2];
        return;
    }
    [SLVoicePack selectPack:newPack];
    if (self.onSaved) self.onSaved();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
