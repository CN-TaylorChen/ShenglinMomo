// 声临 · 陌陌版 v0.2 —— 文字转语音（#tts 口令）
//
// 陌陌 9.23（com.wemomo.momoappdemo1）相关类（离线 class-dump 反查）：
//   MDChatBaseHander          -sendTextMessage:                      发文本消息
//   MDChatUniverseHandler     -sendTextMessage:                      （另一条链路，同样 hook）
//   MMCommonServiceImpl       -sendTextMessage:withTargetID:isSingle: 服务层文本发送
//   MDChatBaseHander          -sendAudioMessage:audioTime:audioFileSize:  发语音消息
//
// 工作方式：输入框输入 `#tts 要说的话` 点发送 → 拦截这次文本发送 →
// TTS 合成 → 编码成 AMR → 用陌陌自己的发语音接口发出去。
// 合成/发送失败会自动退回「发送原文本」，绝不丢消息。
//
// 为了不依赖方法签名猜测：安装前用 NSMethodSignature 校验参数类型，
// 发语音用 NSInvocation 按真实签名填参，签名不符就不装这个钩子。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import "SLPipeline.h"
#import "SLSettingsPanel.h"
#import "SLEntry.h"

#define SLVersion @"0.2"
#define kSLEnabledKey @"SLEnhanceEnabled"
#define kSLCommandKey @"SLCommand"

#pragma mark - 配置

static BOOL SLIsEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:kSLEnabledKey];
    return v ? [v boolValue] : YES;
}

static NSString *SLCommand(void) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLCommandKey];
    if (v.length == 0) v = @"#tts";
    return v;
}

#pragma mark - 原实现记账

static NSMutableDictionary *SLOrigIMPs(void) {
    static NSMutableDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

// 沿继承链找到被我们替换前的原始 IMP
static void (*SLOrigIMPForObject(id obj))(id, SEL, id) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = SLOrigIMPs()[NSStringFromClass(c)];
        if (v) return (void (*)(id, SEL, id))[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

// 同一条文本短时间内只处理一次（防子类/父类双重命中）
static BOOL SLClaimText(NSString *text) {
    static NSString *last = nil;
    static NSTimeInterval lastT = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (text.length && last && [last isEqualToString:text] && (now - lastT) < 5.0) return NO;
    last = [text copy];
    lastT = now;
    return YES;
}

#pragma mark - 文本解析

static NSString *SLTextFromArgument(id arg) {
    if ([arg isKindOfClass:[NSString class]]) return (NSString *)arg;
    if ([arg isKindOfClass:[NSAttributedString class]]) return ((NSAttributedString *)arg).string;
    if ([arg isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)arg;
        for (NSString *k in @[@"text", @"content", @"msg", @"message"]) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]]) return v;
        }
        return nil;
    }
    if (arg) {
        for (NSString *name in @[@"text", @"content", @"msgContent", @"messageText", @"msg"]) {
            SEL s = NSSelectorFromString(name);
            if (![arg respondsToSelector:s]) continue;
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(arg, s);
                if ([v isKindOfClass:[NSString class]]) return v;
            } @catch (NSException *e) { }
        }
    }
    return nil;
}

// 支持 #tts / ＃tts / #TTS，后接空格或中文冒号
static BOOL SLTextHasCommand(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSString *cmd = SLCommand();
    NSRange r = [text rangeOfString:cmd options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (r.location != 0) {
        // 全角 ＃ 兼容
        NSString *alt = [cmd stringByReplacingOccurrencesOfString:@"#" withString:@"＃"];
        r = [text rangeOfString:alt options:NSCaseInsensitiveSearch | NSAnchoredSearch];
        if (r.location != 0) return NO;
    }
    return YES;
}

static NSString *SLTextAfterCommand(NSString *text) {
    NSString *cmd = SLCommand();
    NSString *rest = text;
    NSRange r = [rest rangeOfString:cmd options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (r.location != 0) {
        NSString *alt = [cmd stringByReplacingOccurrencesOfString:@"#" withString:@"＃"];
        r = [rest rangeOfString:alt options:NSCaseInsensitiveSearch | NSAnchoredSearch];
        if (r.location != 0) return @"";
    }
    rest = [rest substringFromIndex:r.length];
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" :：\t"]];
    return [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - 发送语音消息（按真实签名填参）

static BOOL SLSendAudioMessage(id handler, NSString *path, double duration) {
    if (!handler || path.length == 0) return NO;
    SEL sel = @selector(sendAudioMessage:audioTime:audioFileSize:);
    NSMethodSignature *sig = [handler methodSignatureForSelector:sel];
    if (!sig) {
        NSLog(@"SL-MOMO: %@ 无 sendAudioMessage:audioTime:audioFileSize:", NSStringFromClass([handler class]));
        return NO;
    }
    NSUInteger n = sig.numberOfArguments;
    NSLog(@"SL-MOMO: sendAudioMessage signature=%@ args=%lu", sig, (unsigned long)n);
    if (n < 5) return NO;
    if ([sig getArgumentTypeAtIndex:2][0] != '@') return NO;

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = attr ? [attr fileSize] : 0;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = handler;
    inv.selector = sel;

    id p = path;
    [inv setArgument:&p atIndex:2];

    for (NSUInteger i = 3; i < n; i++) {
        const char *ty = [sig getArgumentTypeAtIndex:i];
        char c = ty[0];
        if (c == '@') {
            id o = nil;
            [inv setArgument:&o atIndex:i];
        } else if (c == 'd') {
            double v = (i == 3) ? duration : (double)size;
            [inv setArgument:&v atIndex:i];
        } else if (c == 'f') {
            float v = (float)((i == 3) ? duration : (double)size);
            [inv setArgument:&v atIndex:i];
        } else if (c == 'q' || c == 'Q' || c == 'l' || c == 'L') {
            long long v = (i == 3) ? (long long)llround(duration) : (long long)size;
            [inv setArgument:&v atIndex:i];
        } else {
            int v = (int)((i == 3) ? (long long)llround(duration) : (long long)size);
            [inv setArgument:&v atIndex:i];
        }
    }

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        NSLog(@"SL-MOMO: sendAudioMessage exception %@", e);
        return NO;
    }
    return YES;
}

#pragma mark - #tts 处理

static void SLHandleTTS(id handler, NSString *content, void (^fallback)(void)) {
    [AWECAUtils showToast:@"声临合成中..." duration:2.0];
    [[SLPipeline shared] synthesizeMessageText:content completion:^(BOOL ok, NSString *outPath, double dur, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok || !outPath.length) {
                NSString *m = msg.length ? msg : @"合成失败";
                NSLog(@"SL-MOMO: tts failed: %@", m);
                [AWECAUtils showToast:m duration:2.5];
                if (fallback) fallback();
                return;
            }
            BOOL sent = SLSendAudioMessage(handler, outPath, dur);
            NSLog(@"SL-MOMO: audio sent=%d path=%@ dur=%.2f", sent, outPath, dur);
            if (!sent) {
                [AWECAUtils showToast:@"发送语音失败，已改发文本" duration:2.5];
                if (fallback) fallback();
            } else {
                [AWECAUtils showToast:@"已发送 AI 语音" duration:1.5];
            }
        });
    }];
}

#pragma mark - 钩子实现

static void SLSendTextMessage(id self, SEL _cmd, id arg) {
    void (*orig)(id, SEL, id) = SLOrigIMPForObject(self);
    NSString *text = SLTextFromArgument(arg);

    if (!SLIsEnabled() || !SLTextHasCommand(text)) {
        if (orig) orig(self, _cmd, arg);
        return;
    }

    if (!SLClaimText(text)) {
        NSLog(@"SL-MOMO: duplicate sendTextMessage ignored");
        return;
    }

    NSString *content = SLTextAfterCommand(text);
    if (!content.length) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"用法：%@ 要转成语音的话", SLCommand()] duration:2.5];
        if (orig) orig(self, _cmd, arg);
        return;
    }

    NSLog(@"SL-MOMO: #tts hit, content=%@", content);
    SLHandleTTS(self, content, ^{
        if (orig) orig(self, _cmd, arg);
    });
}

// MMCommonServiceImpl -sendTextMessage:withTargetID:isSingle:
static void (*SLOrigIMPService)(id, SEL, id, id, BOOL) = NULL;

static void SLSendTextMessageService(id self, SEL _cmd, id text, id targetID, BOOL isSingle) {
    NSString *str = SLTextFromArgument(text);
    if (!SLIsEnabled() || !SLTextHasCommand(str)) {
        if (SLOrigIMPService) SLOrigIMPService(self, _cmd, text, targetID, isSingle);
        return;
    }
    if (!SLClaimText(str)) return;
    NSString *content = SLTextAfterCommand(str);
    if (!content.length) {
        if (SLOrigIMPService) SLOrigIMPService(self, _cmd, text, targetID, isSingle);
        return;
    }
    NSLog(@"SL-MOMO: #tts hit(service) content=%@", content);
    SLHandleTTS(self, content, ^{
        if (SLOrigIMPService) SLOrigIMPService(self, _cmd, text, targetID, isSingle);
    });
}

#pragma mark - 安装

static BOOL SLInstallSendTextHook(Class cls) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, @selector(sendTextMessage:));
    if (!m) {
        NSLog(@"SL-MOMO: %@ 无 sendTextMessage:", cls);
        return NO;
    }
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    NSLog(@"SL-MOMO: probe %@ sendTextMessage: type=%s", cls, t ?: "(null)");
    if (!sig || sig.numberOfArguments < 3) return NO;
    const char *a = [sig getArgumentTypeAtIndex:2];
    if (!a || a[0] != '@') {
        NSLog(@"SL-MOMO: skip %@ (first arg not an object)", cls);
        return NO;
    }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)SLSendTextMessage) return NO;   // 已装过（子类继承父类实现时）
    SLOrigIMPs()[NSStringFromClass(cls)] = [NSValue valueWithPointer:cur];
    method_setImplementation(m, (IMP)SLSendTextMessage);
    NSLog(@"SL-MOMO: hooked sendTextMessage: on %@", cls);
    return YES;
}

static BOOL SLInstallServiceHook(void) {
    Class cls = NSClassFromString(@"MMCommonServiceImpl");
    if (!cls) return NO;
    SEL sel = @selector(sendTextMessage:withTargetID:isSingle:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    NSLog(@"SL-MOMO: probe MMCommonServiceImpl sendTextMessage:withTargetID:isSingle: type=%s", t ?: "(null)");
    if (!sig || sig.numberOfArguments < 5) return NO;
    const char *a2 = [sig getArgumentTypeAtIndex:2];
    const char *a3 = [sig getArgumentTypeAtIndex:3];
    if (!a2 || a2[0] != '@' || !a3 || a3[0] != '@') {
        NSLog(@"SL-MOMO: skip service hook (arg types)");
        return NO;
    }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)SLSendTextMessageService) return NO;
    SLOrigIMPService = (void (*)(id, SEL, id, id, BOOL))cur;
    method_setImplementation(m, (IMP)SLSendTextMessageService);
    NSLog(@"SL-MOMO: hooked service sendTextMessage:withTargetID:isSingle:");
    return YES;
}

static void SLInstallHooks(void) {
    static int attempts = 0;
    if (attempts++ > 6) return;   // 幂等：已装的类会被跳过，最多重试几次等类加载
    NSInteger hit = 0;
    hit += SLInstallSendTextHook(NSClassFromString(@"MDChatBaseHander")) ? 1 : 0;
    hit += SLInstallSendTextHook(NSClassFromString(@"MDChatUniverseHandler")) ? 1 : 0;
    hit += SLInstallSendTextHook(NSClassFromString(@"MDChatSingleHandler")) ? 1 : 0;
    hit += SLInstallServiceHook() ? 1 : 0;
    NSLog(@"SL-MOMO: hooks installed=%ld (attempt #%d)", (long)hit, attempts);
}

%ctor {
    NSLog(@"SL-MOMO: ShenglinMomo v%@ loaded into %@", SLVersion, [[NSBundle mainBundle] bundleIdentifier]);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [AWECAUtils ensureDirectoriesExist]; } @catch (NSException *e) {}
        @try { SLStartEntryWatcher(); } @catch (NSException *e) {}
        SLInstallHooks();
        // 类可能尚未加载，重试几次
        for (int i = 1; i <= 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { SLInstallHooks(); } @catch (NSException *e) {}
            });
        }
    });
}
