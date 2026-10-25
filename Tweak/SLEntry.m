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

