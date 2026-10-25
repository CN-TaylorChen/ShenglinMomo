#import "SLEntry.h"
#import "SLSettingsPanel.h"
#import "AWECAUtils.h"

// ===================== 浮动入口 =====================

#define SLBtnTag 20931

@interface SLFloatButton : UIButton
@end

@implementation SLFloatButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        self.layer.cornerRadius = 24;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 6;
        self.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        [self setTitle:@"声临" forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self addTarget:self action:@selector(sl_openPanel) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sl_pan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)sl_pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.superview];
        self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
        [g setTranslation:CGPointZero inView:self.superview];
        NSString *pos = NSStringFromCGPoint(self.center);
        [[NSUserDefaults standardUserDefaults] setObject:pos forKey:@"SLFloatPos"];
    }
}
- (void)sl_openPanel {
    UIViewController *top = [AWECAUtils topViewController];
    if (!top) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[SLSettingsPanel alloc] init]];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersGrabberVisible = YES;
        }
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}
@end

void SLEnsureFloatButton(void) {
    UIWindow *w = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        if (win.isKeyWindow) { w = win; break; }
    }
    if (!w) return;
    SLFloatButton *btn = (SLFloatButton *)[w viewWithTag:SLBtnTag];
    if (!btn) {
        NSString *pos = [[NSUserDefaults standardUserDefaults] objectForKey:@"SLFloatPos"];
        CGPoint c = pos.length ? CGPointFromString(pos) : CGPointMake(w.bounds.size.width - 36, w.bounds.size.height * 0.55);
        if (c.x < 10 || c.x > w.bounds.size.width - 10) c.x = w.bounds.size.width - 36;
        if (c.y < 120 || c.y > w.bounds.size.height - 160) c.y = w.bounds.size.height * 0.55;
        btn = [[SLFloatButton alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
        btn.center = c;
        btn.tag = SLBtnTag;
        [w addSubview:btn];
        NSLog(@"SL-MOMO: float button mounted at %@", NSStringFromCGPoint(c));
    }
}


// 不用 hook UIViewController：主队列定时检查并挂载（低侵入，避免 Logos 多 hook 嵌套坑）
void SLStartEntryWatcher(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(1.0 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            @try { SLEnsureFloatButton(); } @catch (NSException *e) {}
        });
        dispatch_resume(timer);
        @try { SLEnsureFloatButton(); } @catch (NSException *e) {}
    });
}
