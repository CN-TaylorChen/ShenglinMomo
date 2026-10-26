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

#define SLVersion @"0.3.6"
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

// 一次性 dump 消息对象的所有属性（含父类），便于定位文本真实字段
static NSString *SLDumpPropsOnce(id arg) {
    static int done = 0;
    if (done) return nil;
    done = 1;
    NSMutableArray *arr = [NSMutableArray array];
    Class c = [arg class];
    while (c && c != [NSObject class]) {
        unsigned int pc = 0;
        objc_property_t *pl = class_copyPropertyList(c, &pc);
        for (unsigned i = 0; i < pc; i++) {
            const char *pn = property_getName(pl[i]);
            NSString *pname = [NSString stringWithUTF8String:pn];
            id val = nil;
            @try { val = [arg valueForKey:pname]; } @catch (NSException *e) {}
            NSString *vs = nil;
            if ([val isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)val;
                vs = s.length > 80 ? [NSString stringWithFormat:@"\"%@…\"", [s substringToIndex:80]] : [NSString stringWithFormat:@"\"%@\"", s];
            } else if ([val isKindOfClass:[NSNumber class]]) {
                vs = [NSString stringWithFormat:@"#%@", val];
            } else if (val) {
                vs = [NSString stringWithFormat:@"(%@)", NSStringFromClass([val class])];
            } else {
                vs = @"(nil)";
            }
            [arr addObject:[NSString stringWithFormat:@"%@=%@", pname, vs]];
        }
        free(pl);
        c = class_getSuperclass(c);
    }
    SLLog(@"DUMP %@ props: %@", NSStringFromClass([arg class]), [arr componentsJoinedByString:@" | "]);
    return nil;
}

// 命中 #tts 后清空输入栏（避免原文本残留）
static void SLClearInputBars(void) {
    @try {
        NSArray *classes = @[NSClassFromString(@"MDChatInputBar"),
                              NSClassFromString(@"MDNewInputTextBar"),
                              NSClassFromString(@"MDChatUniverseInputBar")];
        UIWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]] &&
                    ((UIWindowScene *)sc).activationState == UISceneActivationStateForegroundActive) {
                    win = ((UIWindowScene *)sc).windows.firstObject;
                    break;
                }
            }
        }
        if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            win = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        }
        if (!win) return;
        NSMutableArray *q = [NSMutableArray arrayWithObject:win];
        while (q.count) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            for (NSString *cn in classes) {
                if (cn && [v isKindOfClass:NSClassFromString(cn)]) {
                    id tv = [v valueForKey:@"inputTextView"];
                    if ([tv isKindOfClass:[UITextView class]]) ((UITextView *)tv).text = @"";
                }
            }
            for (UIView *s in v.subviews) [q addObject:s];
        }
    } @catch (NSException *e) {}
}

static NSString *SLTextFromArgument(id arg) {
    if ([arg isKindOfClass:[NSString class]]) return (NSString *)arg;
    if ([arg isKindOfClass:[NSAttributedString class]]) return ((NSAttributedString *)arg).string;
    if ([arg isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)arg;
        for (NSString *k in @[@"text", @"content", @"msg", @"message", @"body"]) {
            id v = d[k];
            if ([v isKindOfClass:[NSString class]]) return v;
        }
        return nil;
    }
    if (arg) {
        // 陌陌文本消息字段（离线 class-dump 确认 MDBaseMessage 无纯 text getter）
        NSArray *names = @[@"text", @"textv2", @"content", @"body", @"instantMessageText",
                           @"msgContent", @"messageText", @"msg", @"title", @"noreplyText",
                           @"additionalText", @"extraDataString", @"msgExtraInfo"];
        for (NSString *name in names) {
            SEL s = NSSelectorFromString(name);
            if (![arg respondsToSelector:s]) continue;
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(arg, s);
                if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            } @catch (NSException *e) { }
        }
        for (NSString *name in names) {
            @try {
                id v = [arg valueForKey:name];
                if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            } @catch (NSException *e) { }
        }
        SLDumpPropsOnce(arg);
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

// 无条件取输入框原始文本（不要求带口令），用于判断要不要拦截
static NSString *SLFirstInputText(UIView *bar) {
    if (![bar isKindOfClass:[UIView class]]) return nil;
    // 1) inputTextView 属性（最常见）
    SEL iv = @selector(inputTextView);
    if ([bar respondsToSelector:iv]) {
        @try {
            id tv = ((id (*)(id, SEL))objc_msgSend)(bar, iv);
            if ([tv isKindOfClass:[UITextView class]]) {
                NSString *t = ((UITextView *)tv).text;
                if (t.length) return t;
                NSAttributedString *a = ((UITextView *)tv).attributedText;
                if (a.length) return a.string;
            }
        } @catch (NSException *e) { }
    }
    // 2) inputText / text 属性
    for (NSString *name in @[@"inputText", @"text", @"inputString"]) {
        SEL s = NSSelectorFromString(name);
        if (![bar respondsToSelector:s]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(bar, s);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        } @catch (NSException *e) { }
    }
    // 3) 扫描子视图
    NSString *t = nil;
    SLFindViewWithCommand(bar, &t);
    if (t.length) return t;
    SLFindViewWithCommand(bar.superview, &t);
    return t;
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
        NSString *tn = [[NSString stringWithUTF8String:te + 2] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
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


#pragma mark - 假录音机（让陌陌读取我们合成的音频，而不是它自己的原声）

@interface SLFakeRecorder : NSObject
@property (nonatomic, copy) NSString *slAudioPath;
@property (nonatomic) double slDuration;
@end

@implementation SLFakeRecorder

- (NSURL *)url { SLLog(@"fakeRec url -> %@", self.slAudioPath); return [NSURL fileURLWithPath:self.slAudioPath]; }
- (NSURL *)fileURL { return [self url]; }
- (NSURL *)recordFileURL { return [self url]; }
- (NSURL *)audioFileURL { return [self url]; }
- (NSString *)filePath { return self.slAudioPath; }
- (NSString *)recordFilePath { return self.slAudioPath; }
- (NSString *)audioFilePath { return self.slAudioPath; }
- (NSString *)path { return self.slAudioPath; }
- (NSTimeInterval)currentTime { return self.slDuration; }
- (NSTimeInterval)duration { return self.slDuration; }
- (BOOL)isRecording { return NO; }
- (BOOL)recording { return NO; }
- (BOOL)isMeteringEnabled { return NO; }
- (BOOL)prepareToRecord { return YES; }
- (BOOL)record { SLLog(@"fakeRec record (ignored)"); return NO; }
- (void)stop { SLLog(@"fakeRec stop (ignored)"); }
- (void)pause {}
- (BOOL)deleteRecording { SLLog(@"fakeRec deleteRecording (ignored, keep our file)"); return NO; }
- (void)updateMeters {}
- (float)averagePowerForChannel:(NSUInteger)channel { (void)channel; return -160.0f; }
- (float)peakPowerForChannel:(NSUInteger)channel { (void)channel; return -160.0f; }

@end

#pragma mark - 全局：#tts 待发送的合成音频

static NSString *gSLTTSAudioPath = nil;
static double gSLTTSAudioDur = 0;
static int gSLRecDump = 0;
static int gSLModelDump = 0;

// 深层 dump model：含父类 ivar + 所有 property 值
static void SLDumpModelDeep(id model) {
    if (!model) return;
    Class c = [model class];
    NSMutableArray *ivs = [NSMutableArray array];
    Class cc = c;
    while (cc && cc != [NSObject class]) {
        unsigned int pc = 0;
        Ivar *list = class_copyIvarList(cc, &pc);
        for (unsigned i = 0; i < pc; i++) {
            const char *te = ivar_getTypeEncoding(list[i]);
            [ivs addObject:[NSString stringWithFormat:@"%s:%s", ivar_getName(list[i]), te ?: ""]];
        }
        free(list);
        cc = class_getSuperclass(cc);
    }
    NSMutableArray *props = [NSMutableArray array];
    Class c2 = c;
    while (c2 && c2 != [NSObject class]) {
        unsigned int pc = 0;
        objc_property_t *pl = class_copyPropertyList(c2, &pc);
        for (unsigned i = 0; i < pc; i++) {
            NSString *pname = [NSString stringWithUTF8String:property_getName(pl[i])];
            id val = nil;
            @try { val = [model valueForKey:pname]; } @catch (NSException *e) {}
            NSString *vs = nil;
            if ([val isKindOfClass:[NSString class]]) {
                vs = (NSString *)val;
            } else if ([val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSArray class]]) {
                NSString *full = [NSString stringWithFormat:@"%@", val];
                vs = full.length > 300 ? [full substringToIndex:300] : full;
            } else if (val) {
                vs = [NSString stringWithFormat:@"(%@)", NSStringFromClass([val class])];
            } else {
                vs = @"(nil)";
            }
            [props addObject:[NSString stringWithFormat:@"%@=%@", pname, vs]];
        }
        free(pl);
        c2 = class_getSuperclass(c2);
    }
    SLLog(@"MODEL-DEEP class=%@ ivars=[%@] props=[%@]", NSStringFromClass(c),
          [ivs componentsJoinedByString:@","], [props componentsJoinedByString:@" | "]);
}

// dump self 的字符串 ivar（定位陌陌内部录音文件路径）
static void SLDumpSelfIvars(id selfObj) {
    Class c = [selfObj class];
    while (c && c != [NSObject class]) {
        unsigned int pc = 0;
        Ivar *list = class_copyIvarList(c, &pc);
        for (unsigned i = 0; i < pc; i++) {
            const char *te = ivar_getTypeEncoding(list[i]);
            if (!te || te[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(selfObj, list[i]); } @catch (NSException *e) { continue; }
            if ([v isKindOfClass:[NSString class]]) {
                SLLog(@"SELF-IVAR %s = %@", ivar_getName(list[i]), (NSString *)v);
            } else if (v && [v respondsToSelector:@selector(url)]) {
                @try { NSURL *u = [v url]; if (u) SLLog(@"SELF-IVAR %s.(url) = %@", ivar_getName(list[i]), [u path]); } @catch (NSException *e) {}
            }
        }
        free(list);
        c = class_getSuperclass(c);
    }
}

// 收集所有可能的「陌陌即将读取的录音文件路径」（self 内部录音机文件优先）
static NSArray *SLAudioCandidatePaths(id selfObj, id recorder, NSString *pathArg) {
    NSMutableArray *arr = [NSMutableArray array];
    NSArray *exts = @[@"amr",@"m4a",@"caf",@"wav",@"mp3",@"mp4",@"aac"];
    void (^addStr)(NSString *) = ^(NSString *s){
        if (![s isKindOfClass:[NSString class]] || s.length == 0) return;
        if ([s hasPrefix:@"/var/mobile"] || [s hasPrefix:@"/private/var/mobile"]) {
            if ([exts containsObject:s.pathExtension.lowercaseString]) [arr addObject:s];
        }
    };
    void (^addRec)(id) = ^(id r){
        if (!r) return;
        for (NSString *sel in @[@"url",@"filePath",@"recordFilePath",@"audioFileURL",@"fileURL",@"recordFileURL",@"currentPath",@"audioFilePath"]) {
            SEL s = NSSelectorFromString(sel);
            if (![r respondsToSelector:s]) continue;
            @try {
                id u = ((id(*)(id,SEL))objc_msgSend)(r, s);
                if ([u isKindOfClass:[NSURL class]]) addStr([u path]);
                else if ([u isKindOfClass:[NSString class]]) addStr(u);
            } @catch (NSException *e) {}
        }
    };
    addStr(pathArg);
    addRec(recorder);
    // self 的全部对象/字符串 ivar（含父类），优先命中真正的录音机文件
    Class c = [selfObj class];
    while (c && c != [NSObject class]) {
        unsigned int pc = 0;
        Ivar *list = class_copyIvarList(c, &pc);
        for (unsigned i = 0; i < pc; i++) {
            const char *te = ivar_getTypeEncoding(list[i]);
            if (!te || te[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(selfObj, list[i]); } @catch (NSException *e) { continue; }
            if ([v isKindOfClass:[NSString class]]) addStr((NSString *)v);
            else if (v) addRec(v);
        }
        free(list);
        c = class_getSuperclass(c);
    }
    return arr;
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
            // 伪装一次「录制完成」：把合成音频当录音文件，交给陌陌自己的
            // audioRecorder:recordSucessStoreAt:audioTime: 去构造语音消息 model 并发送。
            // 这样完全绕开 sendAudioMessage:audioTime:audioFileSize: 的私有 model
            // （它的第一参数是带 cate 属性的消息对象，直接 NSInvocation 调必崩）。
            BOOL sent = NO;
            SEL recSel = @selector(audioRecorder:recordSucessStoreAt:audioTime:);
            if ([handler respondsToSelector:recSel]) {
                @try {
                    // 关键修复：之前 audioRecorder: 传 nil，陌陌回退读「自己的录音机」原声文件 → 发出去是真人声音。
                    // 现在造一个假 recorder，把 url 指向我们合成的音频，陌陌就会读我们的文件来发语音。
                    SLFakeRecorder *fake = [[SLFakeRecorder alloc] init];
                    fake.slAudioPath = outPath;
                    fake.slDuration = dur;
                    gSLTTSAudioPath = [outPath copy];
                    gSLTTSAudioDur = dur;
                    SLLog(@"fakeRecord use SLFakeRecorder path=%@ dur=%.2f", outPath, dur);
                    ((void(*)(id,SEL,id,id,unsigned long long))objc_msgSend)(handler, recSel, fake, outPath, (unsigned long long)(dur * 1000.0));
                    sent = YES;
                    SLLog(@"fakeRecord ok path=%@ dur=%.2f fmt=%@", outPath, dur, [outPath pathExtension]);
                } @catch (NSException *e) {
                    SLLog(@"fakeRecord exception %@", e);
                }
            } else {
                SLLog(@"handler 无 audioRecorder:recordSucessStoreAt:audioTime: 方法");
            }
            // 诊断：发完后看我们的文件是否还在（若被陌陌删/覆盖，说明它读的是自己的录音机文件而非我们的）
            {
                BOOL ex = [[NSFileManager defaultManager] fileExistsAtPath:outPath];
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:nil];
                SLLog(@"afterSend outPath exists=%d size=%lld", ex, (long long)[attrs fileSize]);
            }
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
    NSString *text = SLFirstInputText(bar);
    UIView *tv = SLFindViewWithCommandNear(bar, &text);

    SLLog(@"%@ -sendText text=%@", NSStringFromClass([self class]), SLShorten(text, 50));

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
    SLHandleTTS(self, content, ^{ if (orig) orig(self, _cmd, arg); }, ^{ SLClearInputBars(); });
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
    SLHandleTTS(self, content, ^{ if (orig) orig(self, _cmd, text, targetID, isSingle); }, ^{ SLClearInputBars(); });
}

#pragma mark - 钩子 4：MDChatBaseHander -sendAudioMessage:audioTime:audioFileSize:（诊断用，抓语音 model 结构）

static void SLSendAudioMessageHook(id self, SEL _cmd, id model, double t, double size) {
    void (*orig)(id, SEL, id, double, double) = (void (*)(id, SEL, id, double, double))SLGetOrigIMP(self, _cmd);
    if (!gSLModelDump) {
        gSLModelDump = 1;
        SLDumpModelDeep(model);
    }
    if (orig) orig(self, _cmd, model, t, size);
}

static BOOL SLInstallSendAudioHook(Class cls) {
    if (!cls) return NO;
    SEL sel = @selector(sendAudioMessage:audioTime:audioFileSize:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    if (!sig || sig.numberOfArguments < 5) return NO;
    const char *a2 = [sig getArgumentTypeAtIndex:2];
    if (!a2 || a2[0] != '@') return NO;
    return SLRegisterMethod(cls, sel, (IMP)SLSendAudioMessageHook);
}

#pragma mark - 钩子 5：audioRecorder:recordSucessStoreAt:audioTime:（覆盖陌陌即将发送的录音文件为合成音）

static void SLAudioRecordDoneHook(id self, SEL _cmd, id recorder, NSString *path, unsigned long long time) {
    void (*orig)(id, SEL, id, id, unsigned long long) = (void (*)(id, SEL, id, id, unsigned long long))SLGetOrigIMP(self, _cmd);
    if (gSLRecDump < 4) {
        gSLRecDump++;
        NSString *recUrl = (recorder && [recorder respondsToSelector:@selector(url)]) ? [[recorder url] path] : @"(?)";
        SLLog(@"REC-DONE self=%@ recorderClass=%@ recorderUrl=%@ pathArg=%@",
              NSStringFromClass([self class]),
              recorder ? NSStringFromClass([recorder class]) : @"(nil)", recUrl, path);
        SLDumpSelfIvars(self);
    }
    if (gSLTTSAudioPath) {
        NSData *d = [NSData dataWithContentsOfFile:gSLTTSAudioPath];
        NSArray *cands = SLAudioCandidatePaths(self, recorder, path);
        SLLog(@"TTS candidates=%lu size=%lu", (unsigned long)cands.count, (unsigned long)d.length);
        BOOL anyOk = NO;
        for (NSString *tp in cands) {
            // 只覆盖「已存在」的录音文件（陌陌真实录音机此刻应已写好的那个）
            if ([[NSFileManager defaultManager] fileExistsAtPath:tp]) {
                BOOL ok = [d writeToFile:tp atomically:YES];
                SLLog(@"TTS write target=%@ ok=%d", tp, ok);
                if (ok) anyOk = YES;
            } else {
                SLLog(@"TTS skip(not exist) %@", tp);
            }
        }
        if (!anyOk) SLLog(@"TTS NO EXISTING TARGET recorderClass=%@ pathArg=%@",
                          recorder ? NSStringFromClass([recorder class]) : @"(nil)", path);
        gSLTTSAudioPath = nil;
    }
    if (orig) orig(self, _cmd, recorder, path, time);
}

static BOOL SLInstallAudioRecordHook(Class cls) {
    if (!cls) return NO;
    SEL sel = @selector(audioRecorder:recordSucessStoreAt:audioTime:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    if (!sig || sig.numberOfArguments < 5) return NO;
    const char *a2 = [sig getArgumentTypeAtIndex:2];
    const char *a3 = [sig getArgumentTypeAtIndex:3];
    const char *a4 = [sig getArgumentTypeAtIndex:4];
    // audioTime: 在陌陌里是 Q/q（无符号长整型，毫秒），也兼容 d（double）
    if (!a2 || a2[0] != '@' || !a3 || a3[0] != '@' || !a4 || (a4[0] != 'd' && a4[0] != 'Q' && a4[0] != 'q')) {
        SLLog(@"skip %@ audioRecorder:recordSucessStoreAt: (types %s %s %s)", cls, a2 ?: "", a3 ?: "", a4 ?: "");
        return NO;
    }
    return SLRegisterMethod(cls, sel, (IMP)SLAudioRecordDoneHook);
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
    SLInstallSendAudioHook(NSClassFromString(@"MDChatBaseHander"));
    SLInstallSendAudioHook(NSClassFromString(@"MDChatUniverseHandler"));
    SLInstallSendAudioHook(NSClassFromString(@"MDChatSingleHandler"));
    SLInstallAudioRecordHook(NSClassFromString(@"MDChatSingleHandler"));
    SLInstallAudioRecordHook(NSClassFromString(@"MDChatBaseHander"));
    SLInstallAudioRecordHook(NSClassFromString(@"MDChatUniverseHandler"));
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
