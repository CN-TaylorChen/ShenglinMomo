#import "SLEntry.h"
#import "SLSettingsPanel.h"
#import "AWECAUtils.h"
#import <PhotosUI/PhotosUI.h>

// ===================== 悬浮球图标 =====================
// 存一个字符串，三种形态：
//   text:声临        纯文字（默认）
//   emoji:🎙️        表情
//   image:icon.png   相册选的自定义图片（已裁成圆形，存沙盒）
#define kSLFloatIconKey @"SLFloatIcon"
#define kSLFloatIconDefault @"text:声临"

static NSString *SLFloatIconDir(void) {
    NSString *dir = [[AWECAUtils documentsPath] stringByAppendingPathComponent:@"ShenglinMomo/float"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

static NSString *SLFloatIconImagePath(NSString *name) {
    return [SLFloatIconDir() stringByAppendingPathComponent:(name.length ? name : @"icon.png")];
}

static NSString *SLFloatIconValue(void) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLFloatIconKey];
    return v.length ? v : kSLFloatIconDefault;
}

NSString *SLFloatIconSummary(void) {
    NSString *v = SLFloatIconValue();
    if ([v hasPrefix:@"image:"]) return @"自定义图片";
    if ([v hasPrefix:@"emoji:"]) return [v substringFromIndex:6];
    if ([v hasPrefix:@"text:"]) {
        return [NSString stringWithFormat:@"文字「%@」", [v substringFromIndex:5]];
    }
    return @"默认";
}

// 把任意图片居中裁成圆形（直接当 backgroundImage 用，省得给按钮加裁剪打断阴影）
static UIImage *SLCircleIcon(UIImage *src) {
    if (!src) return nil;
    CGSize s = CGSizeMake(120, 120);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:s format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextAddEllipseInRect(c, CGRectMake(0, 0, s.width, s.height));
        CGContextClip(c);
        CGFloat iw = src.size.width, ih = src.size.height;
        if (iw <= 0 || ih <= 0) return;
        CGFloat sc = MAX(s.width / iw, s.height / ih);
        CGRect dst = CGRectMake((s.width - iw * sc) / 2.0, (s.height - ih * sc) / 2.0, iw * sc, ih * sc);
        [src drawInRect:dst];
    }];
}

static BOOL SLSaveFloatIconImage(UIImage *img) {
    UIImage *c = SLCircleIcon(img);
    NSData *d = c ? UIImagePNGRepresentation(c) : nil;
    if (!d.length) return NO;
    if (![d writeToFile:SLFloatIconImagePath(@"icon.png") atomically:YES]) return NO;
    [[NSUserDefaults standardUserDefaults] setObject:@"image:icon.png" forKey:kSLFloatIconKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
}

static void SLApplyFloatIcon(UIButton *btn);

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
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self addTarget:self action:@selector(sl_openPanel) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(sl_pan:)];
        [self addGestureRecognizer:pan];
        SLApplyFloatIcon(self);
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

// 按当前设置把图标套到按钮上
static void SLApplyFloatIcon(UIButton *btn) {
    if (!btn) return;
    NSString *v = SLFloatIconValue();
    if ([v hasPrefix:@"image:"]) {
        UIImage *img = [UIImage imageWithContentsOfFile:SLFloatIconImagePath([v substringFromIndex:6])];
        if (img) {
            btn.backgroundColor = [UIColor clearColor];
            [btn setBackgroundImage:img forState:UIControlStateNormal];
            [btn setTitle:nil forState:UIControlStateNormal];
            return;
        }
        v = kSLFloatIconDefault;   // 图片丢了就退回默认文字
    }
    btn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    [btn setBackgroundImage:nil forState:UIControlStateNormal];
    if ([v hasPrefix:@"emoji:"]) {
        [btn setTitle:[v substringFromIndex:6] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:24];
    } else {
        NSString *t = [v hasPrefix:@"text:"] ? [v substringFromIndex:5] : v;
        [btn setTitle:(t.length ? t : @"声临") forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    }
}

// iOS15 SDK 起 -[UIApplication windows] 被弃用，工程开了 -Werror，这里局部抑制并优先走场景 API
static UIWindow *SLKeyWindow(void) {
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

void SLRefreshFloatButton(void) {
    UIWindow *w = SLKeyWindow();
    UIButton *btn = (UIButton *)[w viewWithTag:SLBtnTag];
    SLApplyFloatIcon(btn);
}

void SLEnsureFloatButton(void) {
    UIWindow *w = SLKeyWindow();
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

#pragma mark - 图标选择页

@interface SLFloatIconController () <PHPickerViewControllerDelegate>
@end

@implementation SLFloatIconController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"悬浮球图标";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self
                                                                                          action:@selector(sl_done)];
}

- (void)sl_done {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (NSArray<NSString *> *)sl_textItems {
    return @[@"声临", @"AI", @"TTS", @"语"];
}

- (NSArray<NSString *> *)sl_emojiItems {
    return @[@"🎙️", @"🔊", @"✨", @"🐻"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    (void)tv;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return [self sl_textItems].count;
    if (section == 1) return [self sl_emojiItems].count;
    return 2;   // 从相册选择 / 恢复默认
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    (void)tv;
    if (section == 0) return @"文字";
    if (section == 1) return @"表情";
    return @"自定义";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"icon";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    cell.accessoryType = UITableViewCellAccessoryNone;

    NSString *cur = SLFloatIconValue();
    if (ip.section == 0) {
        NSString *t = [self sl_textItems][ip.row];
        cell.textLabel.text = t;
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        if ([cur isEqualToString:[@"text:" stringByAppendingString:t]]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else if (ip.section == 1) {
        NSString *e = [self sl_emojiItems][ip.row];
        cell.textLabel.text = e;
        cell.textLabel.font = [UIFont systemFontOfSize:22];
        if ([cur isEqualToString:[@"emoji:" stringByAppendingString:e]]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else {
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        if (ip.row == 0) {
            cell.textLabel.text = @"从相册选择图片";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"恢复默认（文字「声临」）";
            if ([cur isEqualToString:kSLFloatIconDefault]) {
                cell.accessoryType = UITableViewCellAccessoryCheckmark;
            }
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    if (ip.section == 0) {
        [d setObject:[@"text:" stringByAppendingString:[self sl_textItems][ip.row]] forKey:kSLFloatIconKey];
        [d synchronize];
        [self sl_applied];
        return;
    }
    if (ip.section == 1) {
        [d setObject:[@"emoji:" stringByAppendingString:[self sl_emojiItems][ip.row]] forKey:kSLFloatIconKey];
        [d synchronize];
        [self sl_applied];
        return;
    }
    if (ip.row == 0) {
        [self sl_pickPhoto];
        return;
    }
    [d setObject:kSLFloatIconDefault forKey:kSLFloatIconKey];
    [d synchronize];
    [[NSFileManager defaultManager] removeItemAtPath:SLFloatIconImagePath(@"icon.png") error:nil];
    [self sl_applied];
}

- (void)sl_applied {
    SLRefreshFloatButton();
    [self.tableView reloadData];
    [AWECAUtils showToast:@"图标已更新" duration:1.2];
}

- (void)sl_pickPhoto {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    vc.delegate = self;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *p = results.firstObject.itemProvider;
    if (![p canLoadObjectOfClass:[UIImage class]]) {
        [AWECAUtils showToast:@"这张图片读不出来" duration:1.5];
        return;
    }
    __weak typeof(self) ws = self;
    [p loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *img = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
            if (img && SLSaveFloatIconImage(img)) {
                [ws sl_applied];
            } else {
                [AWECAUtils showToast:@"保存失败，换一张试试" duration:1.5];
            }
        });
    }];
}

@end
