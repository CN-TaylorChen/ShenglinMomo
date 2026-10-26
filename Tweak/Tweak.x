// 声临 · 陌陌版 v0.3 —— 文字转语音（#tts 口令）
//
// 陌陌 9.23（com.wemomo.momoappdemo1）相关类（离线 class-dump 反查）：
//   输入栏：MDChatInputBar / MDNewInputTextBar / MDChatUniverseInputBar / MDBaseInputBar  -sendText
//   发文本：MDChatBaseHander / MDChatUniverseHandler  -sendTextMessage:
//           MMCommonServiceImpl  -sendTextMessage:withTargetID:isSingle:
//   发语音：MDChatBaseHander  -sendAudioMessage:audioTime:audioFileSize:
//
// 工作方式：输入框输入 `#tts 要说的话` 点发送 → 拦掉这次发送 →
// TTS 合成 → 编码成 AMR → 用陌陌自己的发语音接口发出去。
// 任一步失败都会退回「发送原文本」，绝不丢消息。
//
// 所有钩子安装前都用 NSMethodSignature 校验签名，签名不符就不装（避免猜错崩溃）；
// 发语音统一走 NSInvocation，按真实类型填参。
// 日志：SLLog 同时写 NSLog 与 /var/mobile/Documents/ShenglinMomo/slmomo.log，设置里有「运行日志」页。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import "SLLog.h"
#import "SLPipeline.h"
#import "SLSettingsPanel.h"
#import "SLLogViewController.h"
#import "SLEntry.h"

#define SLVersion @"0.3"
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

#pragma mark - 原实现记账（key = 类名#selector）

static NSMutableDictionary *SLOrigIMPs(void) {
    static NSMutableDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

static NSString *SLKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@#%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static IMP SLGetOrigIMP(id obj, SEL sel) {
    Class c = object_getClass(obj);
    while (c) {
        NSValue *v = SLOrigIMPs()[SLKey(c, sel)];
        if (v) return (IMP)[v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static BOOL SLRegisterMethod(Class cls, SEL sel, IMP replacement) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        SLLog(@"probe %@：无 %@", cls, NSStringFromSelector(sel));
        return NO;
    }
    const char *t = method_getTypeEncoding(m) ?: "";
    IMP cur = method_getImplementation(m);
    if (cur == replacement) {
        SLLog(@"probe %@ %@：已装过（继承自父类）", cls, NSStringFromSelector(sel));
        return NO;
    }
    SLOrigIMPs()[SLKey(cls, sel)] = [NSValue valueWithPointer:cur];
    method_setImplementation(m, replacement);
    SLLog(@"hook ok %@ %@ type=%s", cls, NSStringFromSelector(sel), t);
    return YES;
}

// 同一条文本短时间内只处理一次（防多个钩子重复命中）
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

static BOOL SLTextHasCommand(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSString *cmd = SLCommand();
    NSRange r = [text rangeOfString:cmd options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (r.location != 0) {
        NSString *alt = [cmd stringByReplacingOccurrencesOfString:@"#" withString:@"＃"];
        r = [text rangeOfString:alt options:NSCaseInsensitiveSearch | NSAnchoredSearch];
        if (r.location != 0) return NO;
    }
    return YES;
}

static NSString *SLTextAfterCommand(NSString *text) {
    NSString *cmd = SLCommand();
    NSRange r = [text rangeOfString:cmd options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (r.location != 0) {
        NSString *alt = [cmd stringByReplacingOccurrencesOfString:@"#" withString:@"＃"];
        r = [text rangeOfString:alt options:NSCaseInsensitiveSearch | NSAnchoredSearch];
        if (r.location != 0) return @"";
    }
    NSString *rest = [text substringFromIndex:r.length];
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" :：\t"]];
    return [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SLShorten(NSString *s, NSUInteger max) {
    if (![s isKindOfClass:[NSString class]]) return @"(nil)";
    if (s.length <= max) return s;
    return [NSString stringWithFormat:@"%@…(%lu字)", [s substringToIndex:max], (unsigned long)s.length];
}

#pragma mark - 视图扫描（从输入栏找出含口令的输入框）

static UIView *SLFindViewWithCommand(UIView *root, NSString **outText) {
    if (!root) return nil;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    NSInteger n = 0;
    while (q.count && n < 3000) {
        UIView *v = q.firstObject;
        [q removeObjectAtIndex:0];
        n++;
        NSString *t = nil;
        if ([v isKindOfClass:[UITextView class]]) t = ((UITextView *)v).text;
        else if ([v isKindOfClass:[UITextField class]]) t = ((UITextField *)v).text;
        if (t.length && SLTextHasCommand(t)) {
            if (outText) *outText = t;
            return v;
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return nil;
}

static UIView *SLFindViewWithCommandNear(UIView *bar, NSString **outText) {
    UIView *v = SLFindViewWithCommand(bar, outText);
    if (v) return v;
    return SLFindViewWithCommand(bar.superview, outText);
}

static void SLClearTextInView(UIView *v) {
    @try {
        if ([v isKindOfClass:[UITextView class]]) ((UITextView *)v).text = @"";
        else if ([v isKindOfClass:[UITextField class]]) ((UITextField *)v).text = @"";
    } @catch (NSException *e) { }
}

#pragma mark - 找能发语音的 handler

static id SLAudioHandlerInObject(id obj) {
    if (!obj) return nil;
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([obj class], &n);
    id found = nil;
    for (unsigned i = 0; i < n && !found; i++) {
        const char *te = ivar_getTypeEncoding(ivars[i]);
        if (!te || te[0] != '@' || te[1] != '"') continue;
        NSString *tn = [[NSString stringWithUTF8String:te + 2] stringByTrimmingCharactersInString:@"\""];
        if (!([tn hasSuffix:@"Hander"] || [tn hasSuffix:@"Handler"])) continue;
        __unsafe_unretained id v = nil;
        @try { v = object_getIvar(obj, ivars[i]); } @catch (NSException *e) { }
        if (v && [v methodSignatureForSelector:@selector(sendAudioMessage:audioTime:audioFileSize:)]) found = v;
    }
    free(ivars);
    return found;
}

// 沿响应链往上找（输入栏 → 聊天 VC → …）
static id SLFindAudioHandlerNear(UIView *view) {
    UIResponder *r = view;
    NSInteger hops = 0;
    while (r && hops++ < 15) {
        id h = SLAudioHandlerInObject(r);
        if (h) {
            SLLog(@"found audio handler %@ in %@", NSStringFromClass([h class]), NSStringFromClass([r class]));
            return h;
        }
        r = [r nextResponder];
    }
    return nil;
}

#pragma mark - 发送语音消息（按真实签名填参）

static BOOL SLSendAudioMessage(id handler, NSString *path, double duration) {
    if (!handler || path.length == 0) return NO;
    SEL sel = @selector(sendAudioMessage:audioTime:audioFileSize:);
    NSMethodSignature *sig = [handler methodSignatureForSelector:sel];
    if (!sig) {
        SLLog(@"%@ 无 sendAudioMessage:audioTime:audioFileSize:", NSStringFromClass([handler class]));
        return NO;
    }
    NSUInteger n = sig.numberOfArguments;
    SLLog(@"sendAudioMessage sig=%@ args=%lu", sig, (unsigned long)n);
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
        SLLog(@"sendAudioMessage exception %@", e);
        return NO;
    }
    return YES;
}

#pragma mark - #tts 处理

static void SLHandleTTS(id handler,
                       NSString *content,
                       void (^fallback)(void),
                       void (^onSuccess)(void)) {
    [AWECAUtils showToast:@"声临合成中..." duration:2.0];
    [[SLPipeline shared] synthesizeMessageText:content completion:^(BOOL ok, NSString *outPath, double dur, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok || !outPath.length) {
                NSString *m = msg.length ? msg : @"合成失败";
                SLLog(@"tts failed: %@", m);
                [AWECAUtils showToast:m duration:2.5];
                if (fallback) fallback();
                return;
            }
            BOOL sent = SLSendAudioMessage(handler, outPath, dur);
            SLLog(@"audio sent=%d path=%@ dur=%.2f", sent, outPath, dur);
            if (!sent) {
                [AWECAUtils showToast:@"发送语音失败，已改发文本" duration:2.5];
                if (fallback) fallback();
            } else {
                [AWECAUtils showToast:@"已发送 AI 语音" duration:1.5];
                if (onSuccess) onSuccess();
            }
        });
    }];
}

#pragma mark - 钩子 1：输入栏 -sendText（无参，最稳）

static void SLSendText(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))SLGetOrigIMP(self, _cmd);

    if (!SLIsEnabled() || ![self isKindOfClass:[UIView class]]) {
        if (orig) orig(self, _cmd);
        return;
    }

    UIView *bar = (UIView *)self;
    NSString *text = nil;
    UIView *tv = SLFindViewWithCommandNear(bar, &text);

    if (!SLTextHasCommand(text)) {
        if (orig) orig(self, _cmd);
        return;
    }
    if (!SLClaimText(text)) {
        SLLog(@"sendText duplicate ignored");
        return;
    }

    NSString *content = SLTextAfterCommand(text);
    if (!content.length) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"用法：%@ 要转成语音的话", SLCommand()] duration:2.5];
        if (orig) orig(self, _cmd);
        return;
    }

    SLLog(@"#tts hit via %@ -sendText, text=%@", NSStringFromClass([self class]), SLShorten(text, 40));
    id handler = SLFindAudioHandlerNear(bar);
    if (!handler) {
        SLLog(@"no audio handler near input bar -> fallback to text");
        if (orig) orig(self, _cmd);
        return;
    }

    SLHandleTTS(handler, content, ^{ if (orig) orig(self, _cmd); }, ^{ SLClearTextInView(tv); });
}

#pragma mark - 钩子 2：handler -sendTextMessage:

static int SLTextMsgLogCount = 0;

static void SLSendTextMessage(id self, SEL _cmd, id arg) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))SLGetOrigIMP(self, _cmd);
    NSString *text = SLTextFromArgument(arg);

    if (SLTextMsgLogCount < 25) {
        SLTextMsgLogCount++;
        SLLog(@"sendTextMessage: called on %@ argClass=%@ text=%@",
              NSStringFromClass([self class]), NSStringFromClass([arg class]), SLShorten(text, 40));
    }

    if (!SLIsEnabled() || !SLTextHasCommand(text)) {
        if (orig) orig(self, _cmd, arg);
        return;
    }
    if (!SLClaimText(text)) {
        SLLog(@"sendTextMessage: duplicate ignored");
        return;
    }

    NSString *content = SLTextAfterCommand(text);
    if (!content.length) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"用法：%@ 要转成语音的话", SLCommand()] duration:2.5];
        if (orig) orig(self, _cmd, arg);
        return;
    }

    SLLog(@"#tts hit via %@ -sendTextMessage:", NSStringFromClass([self class]));
    SLHandleTTS(self, content, ^{ if (orig) orig(self, _cmd, arg); }, nil);
}

#pragma mark - 钩子 3：MMCommonServiceImpl -sendTextMessage:withTargetID:isSingle:

static void SLSendTextMessageService(id self, SEL _cmd, id text, id targetID, BOOL isSingle) {
    void (*orig)(id, SEL, id, id, BOOL) = (void (*)(id, SEL, id, id, BOOL))SLGetOrigIMP(self, _cmd);
    NSString *str = SLTextFromArgument(text);

    if (!SLIsEnabled() || !SLTextHasCommand(str)) {
        if (orig) orig(self, _cmd, text, targetID, isSingle);
        return;
    }
    if (!SLClaimText(str)) return;
    NSString *content = SLTextAfterCommand(str);
    if (!content.length) {
        if (orig) orig(self, _cmd, text, targetID, isSingle);
        return;
    }
    SLLog(@"#tts hit via MMCommonServiceImpl");
    SLHandleTTS(self, content, ^{ if (orig) orig(self, _cmd, text, targetID, isSingle); }, nil);
}

#pragma mark - 安装

static BOOL SLInstallSendTextMessageHook(Class cls) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, @selector(sendTextMessage:));
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    if (!sig || sig.numberOfArguments < 3) {
        SLLog(@"skip %@ sendTextMessage: (no signature)", cls);
        return NO;
    }
    const char *a = [sig getArgumentTypeAtIndex:2];
    if (!a || a[0] != '@') {
        SLLog(@"skip %@ sendTextMessage: (first arg not object: %s)", cls, a ?: "");
        return NO;
    }
    return SLRegisterMethod(cls, @selector(sendTextMessage:), (IMP)SLSendTextMessage);
}

static BOOL SLInstallSendTextHook(Class cls) {
    if (!cls) return NO;
    SEL sel = @selector(sendText);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) {
        SLLog(@"skip %@ sendText (not zero-arg, args=%u)", cls, method_getNumberOfArguments(m));
        return NO;
    }
    return SLRegisterMethod(cls, sel, (IMP)SLSendText);
}

static BOOL SLInstallServiceHook(void) {
    Class cls = NSClassFromString(@"MMCommonServiceImpl");
    if (!cls) return NO;
    SEL sel = @selector(sendTextMessage:withTargetID:isSingle:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    if (!sig || sig.numberOfArguments < 5) return NO;
    const char *a2 = [sig getArgumentTypeAtIndex:2];
    const char *a3 = [sig getArgumentTypeAtIndex:3];
    if (!a2 || a2[0] != '@' || !a3 || a3[0] != '@') {
        SLLog(@"skip MMCommonServiceImpl (arg types)");
        return NO;
    }
    return SLRegisterMethod(cls, sel, (IMP)SLSendTextMessageService);
}

static void SLInstallHooks(void) {
    static int attempts = 0;
    if (attempts++ > 8) return;   // 幂等：已装的会跳过，多试几次等类加载

    // 输入栏（优先级最高：不依赖任何消息对象结构）
    SLInstallSendTextHook(NSClassFromString(@"MDChatInputBar"));
    SLInstallSendTextHook(NSClassFromString(@"MDNewInputTextBar"));
    SLInstallSendTextHook(NSClassFromString(@"MDChatUniverseInputBar"));
    SLInstallSendTextHook(NSClassFromString(@"MDBaseInputBar"));
    // handler 层
    SLInstallSendTextMessageHook(NSClassFromString(@"MDChatBaseHander"));
    SLInstallSendTextMessageHook(NSClassFromString(@"MDChatUniverseHandler"));
    SLInstallSendTextMessageHook(NSClassFromString(@"MDChatSingleHandler"));
    SLInstallServiceHook();
}

NSString *SLHookStatusSummary(void) {
    NSArray *keys = [[SLOrigIMPs() allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *k in keys) [a addObject:[k stringByReplacingOccurrencesOfString:@"#" withString:@"."]];
    if (!a.count) return @"没有装上任何钩子（类名/方法签名不匹配，把日志发给开发者）";
    return [NSString stringWithFormat:@"已装钩子：%@", [a componentsJoinedByString:@"  "]];
}

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    SLLog(@"==== ShenglinMomo v%@ loaded into %@ ====", SLVersion, bid ?: @"(nil)");
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [AWECAUtils ensureDirectoriesExist]; } @catch (NSException *e) {}
        @try { SLStartEntryWatcher(); } @catch (NSException *e) {}
        SLInstallHooks();
        SLLog(@"%@", SLHookStatusSummary());
        for (int i = 1; i <= 5; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { SLInstallHooks(); } @catch (NSException *e) {}
            });
        }
    });
}
