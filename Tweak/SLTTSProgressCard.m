//
//  SLTTSProgressCard.m
//  声临 · 陌陌版 —— 合成进度卡片（v0.4.81）
//

#import "SLTTSProgressCard.h"
#import "SLGlass.h"

@interface SLTTSProgressCard ()
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, copy) void (^cancelBlock)(void);
@property (nonatomic, assign) NSTimeInterval startAt;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) NSInteger lastShownSec;

@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UIButton *cancelBtn;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation SLTTSProgressCard

+ (instancetype)cardWithTimeout:(NSTimeInterval)timeout cancel:(void (^)(void))cancel {
    SLTTSProgressCard *c = [[SLTTSProgressCard alloc] initWithFrame:CGRectMake(0, 0, 248, 108)];
    c.timeout = timeout > 1.0 ? timeout : 60.0;
    c.cancelBlock = cancel;
    c.startAt = CACurrentMediaTime();
    c.progress = 0.0;
    c.lastShownSec = -1;
    [c sl_start];
    return c;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.layer.cornerRadius = 18.0;
    self.layer.masksToBounds = YES;   // 把毛玻璃与发丝边一起裁成圆角
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = SLGlassHairlineColor().CGColor;

    _blur = SLInstallGlassBackdrop(self);   // 超薄毛玻璃底

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.text = @"正在合成 AI 语音";
    [self addSubview:_titleLabel];

    _countLabel = [[UILabel alloc] init];
    _countLabel.font = [UIFont systemFontOfSize:13];
    _countLabel.textColor = [UIColor secondaryLabelColor];
    _countLabel.textAlignment = NSTextAlignmentRight;
    [self addSubview:_countLabel];

    _track = [[UIView alloc] init];
    _track.backgroundColor = [UIColor secondarySystemFillColor];
    _track.layer.cornerRadius = 4.0;
    _track.layer.masksToBounds = YES;
    [self addSubview:_track];

    _fill = [[UIView alloc] init];
    _fill.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:1.0];   // 合成蓝
    [_track addSubview:_fill];

    _cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _cancelBtn.layer.cornerRadius = 15.0;
    _cancelBtn.layer.masksToBounds = YES;
    _cancelBtn.layer.borderWidth = 1.0;
    _cancelBtn.layer.borderColor = SLGlassHairlineColor().CGColor;
    _cancelBtn.backgroundColor = SLGlassPillFillColor();
    [_cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [_cancelBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    _cancelBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [_cancelBtn addTarget:self action:@selector(sl_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_cancelBtn];

    return self;
}

- (void)sl_start {
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        [weakSelf sl_tick];
    }];
    [self sl_tick];
}

- (void)sl_tick {
    NSTimeInterval elapsed = CACurrentMediaTime() - _startAt;
    CGFloat p = (CGFloat)(elapsed / _timeout);
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    _progress = p;
    [self setNeedsLayout];

    NSInteger remain = (NSInteger)ceil(_timeout - elapsed);
    if (remain < 0) remain = 0;
    if (remain != _lastShownSec) {
        _lastShownSec = remain;
        if (remain <= 0) _countLabel.text = @"即将超时";
        else _countLabel.text = [NSString stringWithFormat:@"剩余 %ld 秒", (long)remain];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat pad = 16.0;
    CGFloat w = b.size.width;

    _blur.frame = b;

    _titleLabel.frame = CGRectMake(pad, 14, w - pad * 2 - 64, 20);
    _countLabel.frame = CGRectMake(w - pad - 64, 14, 64, 20);

    CGFloat trackX = pad, trackY = 46.0, trackW = w - pad * 2, trackH = 8.0;
    _track.frame = CGRectMake(trackX, trackY, trackW, trackH);
    _fill.frame = CGRectMake(0, 0, trackW * _progress, trackH);

    _cancelBtn.frame = CGRectMake(pad, 64.0, w - pad * 2, 30.0);
}

- (void)sl_cancelTapped {
    if (_cancelBlock) _cancelBlock();
    // 真正的移除由调用方经 SLHideTTSProgress 完成；这里先停表，避免重复触发。
    [self sl_stopTimer];
}

- (void)sl_stopTimer {
    if (_timer) {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)dismiss {
    [self sl_stopTimer];
    [self removeFromSuperview];
}

@end
