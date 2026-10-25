// 声临 · 陌陌版 —— 入口钩子与 UI 挂载
//
// 陌陌 9.23（com.wemomo.momoappdemo1）语音消息链路（离线 class-dump 反查确认）：
//   MLVoiceMessageRecorder 负责录音 → 落盘 → 回调
//   MDChatBaseHander -audioRecorder:recordSucessStoreAt:audioTime:     ← 录音完成（拿到文件路径 + 时长）
//   MDChatBaseHander -sendAudioMessage:audioTime:audioFileSize:        ← 真正发送
// 因此本插件不动发送，只在「录音完成 → 发送之前」这一步把文件内容替换掉，
// 再按新音频的时长回调原方法，剩下的上传/发送逻辑全部由陌陌自己完成。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import "SLPipeline.h"
#import "SLSettingsPanel.h"

#define SLVersion @"0.1"
#define kSLEnabledKey @"SLEnhanceEnabled"

static BOOL SLIsEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kSLEnabledKey];
    return v ? [v boolValue] : YES;   // 默认开
}
static void SLSetEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// 等待记账：key=原始路径（已处理、正准备重放的），钩子再见一次就直接放行
static NSMutableSet<NSString *> *SLPendingPaths(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

// 插件工作目录
static NSString *SLWorkDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = [[paths firstObject] stringByAppendingPathComponent:@"ShenglinMomo"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *SLSnapshotPathFor(NSString *srcPath) {
    NSString *ext = [srcPath pathExtension];
    if (!ext.length) ext = @"amr";
    NSString *name = [NSString stringWithFormat:@"take_%@.%@", [[NSUUID UUID] UUIDString], ext];
    return [SLWorkDir() stringByAppendingPathComponent:name];
}

// ===================== 录音完成拦截 =====================

%hook MDChatBaseHander

// 陌陌 9.23 录音成功回调；参数是文件路径 + 时长（秒）
- (void)audioRecorder:(id)recorder recordSucessStoreAt:(NSString *)path audioTime:(double)audioTime {
    NSString *src = [path isKindOfClass:[NSString class]] ? path : (NSString *)[NSString stringWithFormat:@"%@", path];
    NSLog(@"SL-MOMO: recordSucess path=%@ time=%.2f enabled=%d", src, audioTime, SLIsEnabled());

    // 我们自己重放时会再次命中本钩子：命中即放行到原实现，避免对同一路径二次进入流水线
    NSString *pathKey = src ?: @"";
    if ([SLPendingPaths() containsObject:pathKey]) {
        [SLPendingPaths() removeObject:pathKey];
        NSLog(@"SL-MOMO: replay pass-through %@", src);
        %orig;
        return;
    }

    if (!src.length || !SLIsEnabled()) { %orig; return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) { %orig; return; }

    NSString *snap = SLSnapshotPathFor(src);
    NSError *err = nil;
    [fm removeItemAtPath:snap error:nil];
    BOOL copied = [fm copyItemAtPath:src toPath:snap error:&err];
    if (!copied) {
        NSLog(@"SL-MOMO: snapshot copy failed %@", err);
        %orig;
        return;
    }
    NSString *keepSrc = [src copy];
    NSString *keepSnap = [snap copy];
    __weak typeof(self) weakSelf = self;
    void (^replay)(double) = ^(double newTime) {
        [SLPendingPaths() addObject:keepSrc];
        @try {
            ((void (*)(id, SEL, id, id, double))objc_msgSend)(weakSelf,
                @selector(audioRecorder:recordSucessStoreAt:audioTime:), recorder, keepSrc, newTime);
        } @catch (NSException *e) {
            NSLog(@"SL-MOMO: replay exception %@", e);
        }
    };

    [AWECAUtils showToast:@"声临转换中..." duration:2.0];
    [[SLPipeline shared] enhanceRecordedAudioAtPath:keepSnap originalDuration:audioTime completion:^(BOOL ok, NSString *outPath, double outDuration, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok || !outPath.length) {
                NSLog(@"SL-MOMO: pipeline failed: %@", msg);
                if (msg.length) [AWECAUtils showToast:msg duration:2.5];
                replay(audioTime);   // 失败就发原声，绝不丢消息
                return;
            }
            NSFileManager *fm2 = [NSFileManager defaultManager];
            [fm2 removeItemAtPath:keepSrc error:nil];
            NSError *e2 = nil;
            if ([fm2 copyItemAtPath:outPath toPath:keepSrc error:&e2]) {
                NSLog(@"SL-MOMO: replaced ok newTime=%.2f", outDuration);
                [AWECAUtils showToast:@"已转换为 AI 音色" duration:1.5];
                replay(outDuration > 0 ? outDuration : audioTime);
            } else {
                NSLog(@"SL-MOMO: replace failed %@", e2);
                [AWECAUtils showToast:@"替换失败，发送原声" duration:2.0];
                replay(audioTime);
            }
        });
    }];
}

%end

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

static void SLEnsureFloatButton(void) {
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

// 进入聊天页后确保按钮存在
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);
    if ([cls hasPrefix:@"MD"] && ([cls containsString:@"Chat"] || [cls containsString:@"Conversation"])) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { SLEnsureFloatButton(); } @catch (NSException *e) {}
        });
    }
}
%end

%ctor {
    NSLog(@"SL-MOMO: ShenglinMomo v%@ loaded into bundle=%@", SLVersion, [[NSBundle mainBundle] bundleIdentifier]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { [AWECAUtils ensureDirectoriesExist]; SLEnsureFloatButton(); } @catch (NSException *e) {}
    });
}
