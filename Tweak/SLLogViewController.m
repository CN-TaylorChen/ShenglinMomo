#import "SLLogViewController.h"
#import "SLLog.h"

@interface SLLogViewController ()
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UILabel *status;
@end

@implementation SLLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(sl_reload)],
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(sl_copy)],
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(sl_clear)]
    ];

    self.status = [[UILabel alloc] initWithFrame:CGRectZero];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont systemFontOfSize:11];
    self.status.textColor = [UIColor secondaryLabelColor];

    self.tv = [[UITextView alloc] initWithFrame:CGRectZero];
    self.tv.editable = NO;
    self.tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:11];
    self.tv.textColor = [UIColor labelColor];
    self.tv.backgroundColor = [UIColor systemBackgroundColor];
    self.tv.alwaysBounceVertical = YES;

    UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:@[self.status, self.tv]];
    sv.axis = UILayoutConstraintAxisVertical;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];

    CGFloat top = 8;
    [NSLayoutConstraint activateConstraints:@[
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [sv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:top],
        [sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8]
    ]];
    [self sl_reload];
}

- (void)sl_reload {
    NSString *st = @"钩子状态：未知";
    @try { NSString *s = SLHookStatusSummary(); if (s.length) st = s; } @catch (NSException *e) { }
    self.status.text = [NSString stringWithFormat:@"%@\n文件：%@",
                        st, [SLLog filePath] ?: @"(不可写)"];
    self.tv.text = [SLLog tailLines:400] ?: @"(暂无日志)";
    if (self.tv.text.length > 1) {
        [self.tv scrollRangeToVisible:NSMakeRange(self.tv.text.length - 1, 1)];
    }
}

- (void)sl_copy {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = [NSString stringWithFormat:@"%@\n---\n%@", self.status.text, self.tv.text];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已复制"
                                                               message:@"粘贴给开发者即可定位问题"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sl_clear {
    [SLLog clear];
    [self sl_reload];
}

@end
