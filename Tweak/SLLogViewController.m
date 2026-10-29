#import "SLLogViewController.h"
#import "SLLog.h"
#import "SLGlass.h"

@interface SLLogViewController ()
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UITextView *status;
@end

@implementation SLLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";

    // v0.4.50：跟设置页统一材质。原来这里是实心 systemBackground 的纯白页，
    // 从毛玻璃设置页点进来像跳到了另一个 App；现在铺超薄毛玻璃 + 胶囊标题 + 胶囊按钮。
    SLInstallGlassBackdrop(self.view);
    self.navigationItem.titleView = SLPillTitleView(@"运行日志");
    SLInstallPillBack(self);   // v0.4.53：系统返回键换胶囊，否则这一页顶部只有右边三颗胶囊
    self.navigationItem.rightBarButtonItems = @[
        SLPillBarItem(@"刷新", self, @selector(sl_reload)),
        SLPillBarItem(@"复制", self, @selector(sl_copy)),
        SLPillBarItem(@"清空", self, @selector(sl_clear))
    ];

    // v0.4.63：原来是 UILabel numberOfLines=0，会把「已装钩子：…」整串 30+ 方法名全展开，
    // 占掉约 40% 屏高。改成高度受限的可滚动 UITextView，完整列表仍在（可滚动 / 复制时也能拿到）。
    self.status = [[UITextView alloc] initWithFrame:CGRectZero];
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    self.status.editable = NO;
    self.status.selectable = NO;
    self.status.scrollEnabled = YES;
    self.status.font = [UIFont systemFontOfSize:11];
    self.status.textColor = [UIColor secondaryLabelColor];
    self.status.backgroundColor = [UIColor clearColor];
    self.status.textContainerInset = UIEdgeInsetsMake(0, 0, 0, 0);

    // 状态卡：钩子摘要 + 日志文件路径。玻璃片垫底，压在模糊背景上才读得清。
    UIView *statusCard = [[UIView alloc] initWithFrame:CGRectZero];
    statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    statusCard.backgroundColor = SLGlassCellColor();
    statusCard.layer.cornerRadius = 12.0;
    statusCard.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:statusCard];
    [statusCard addSubview:self.status];

    self.tv = [[UITextView alloc] initWithFrame:CGRectZero];
    self.tv.translatesAutoresizingMaskIntoConstraints = NO;
    self.tv.editable = NO;
    self.tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:11];
    self.tv.textColor = [UIColor labelColor];
    self.tv.backgroundColor = [UIColor clearColor];
    self.tv.alwaysBounceVertical = YES;

    // 日志本体同样贴一块玻璃片，否则一片字直接浮在模糊上，深色下几乎糊成一片。
    UIView *logCard = [[UIView alloc] initWithFrame:CGRectZero];
    logCard.translatesAutoresizingMaskIntoConstraints = NO;
    logCard.backgroundColor = SLGlassCellColor();
    logCard.layer.cornerRadius = 12.0;
    logCard.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:logCard];
    [logCard addSubview:self.tv];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [statusCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [statusCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [statusCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],

        [self.status.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:12],
        [self.status.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-12],
        [self.status.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:10],
        [self.status.heightAnchor constraintEqualToConstant:150],

        [logCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [logCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [logCard.topAnchor constraintEqualToAnchor:statusCard.bottomAnchor constant:10],
        [logCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],

        [self.tv.leadingAnchor constraintEqualToAnchor:logCard.leadingAnchor constant:8],
        [self.tv.trailingAnchor constraintEqualToAnchor:logCard.trailingAnchor constant:-8],
        [self.tv.topAnchor constraintEqualToAnchor:logCard.topAnchor constant:8],
        [self.tv.bottomAnchor constraintEqualToAnchor:logCard.bottomAnchor constant:-8]
    ]];

    [self sl_reload];
}

- (void)sl_reload {
    NSString *summary = @"没有装上任何钩子（类名/方法签名不匹配，把日志发给开发者）";
    @try { NSString *s = SLHookStatusSummary(); if (s.length) summary = s; } @catch (NSException *e) { }
    // v0.4.68：状态卡改为可滚动、限高 ~150pt；顶部显示「已装钩子 N 个」并展示完整列表（滚动看全），不再显空
    NSString *head = summary;
    if ([summary hasPrefix:@"已装钩子："]) {
        NSString *body = [summary substringFromIndex:@"已装钩子：".length];
        NSInteger n = (NSInteger)[[body componentsSeparatedByString:@"  "] count];
        head = [NSString stringWithFormat:@"已装钩子 %ld 个\n%@", (long)n, body];
    }
    self.status.text = [NSString stringWithFormat:@"%@\n文件：%@", head, [SLLog filePath] ?: @"(不可写)"];
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
