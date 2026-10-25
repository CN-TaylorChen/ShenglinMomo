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
#import "SLEntry.h"

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

%ctor {
    NSLog(@"SL-MOMO: ShenglinMomo v%@ loaded into bundle=%@", SLVersion, [[NSBundle mainBundle] bundleIdentifier]);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [AWECAUtils ensureDirectoriesExist]; SLStartEntryWatcher(); } @catch (NSException *e) {}
    });
}
