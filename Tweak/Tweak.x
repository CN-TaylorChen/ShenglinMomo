// 声临 · 陌陌版 v0.3 —— 文字转语音（#tts 口令）
//
// 陌陌 9.23（com.wemomo.momoappdemo1）相关类（离线 class-dump 反查）：
//   输入栏：MDChatInputBar / MDNewInputTextBar / MDChatUniverseInputBar / MDBaseInputBar  -sendText
//   发文本：MDChatBaseHander / MDChatUniverseHandler  -sendTextMessage:
//           MMCommonServiceImpl  -sendTextMessage:withTargetID:isSingle:
//   发语音：MDChatBaseHander  -sendAudioMessage:audioTime:audioFileSize:
//
// 工作方式：输入框输入 `#tts 要说的话` 点发送 → 拦掉文本 → 合成 AI 语音并「装填」→
// 用户真实录音时，audioRecorder 钩子把录音文件覆盖成 AI 音频 → 陌陌照常发出（录音替换）。
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
#import <math.h>
#import "SLLog.h"
#import "SLAMREncoder.h"
#import "SLPipeline.h"
#import "SLSettingsPanel.h"
#import "SLLogViewController.h"
#import "SLEntry.h"

#define SLVersion @"0.3.9"
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


// （v0.3.7 起不再使用假录音机：改为「录音替换」——见 SLArmTTS / audioRecorder 钩子）

#pragma mark - 全局：#tts 待发送的合成音频

static NSString *gSLTTSAudioPath = nil;
static double gSLTTSAudioDur = 0;
static NSTimeInterval gSLArmedAt = 0;   // #tts 装填时刻（锁定“本次录音刚写的文件”）
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

// —— v0.3.9 真实录音文件定位 ——
//
// 真机日志 RECORDER-DEEP 给出的结构：
//   MDAudioRecorder ivars = _manualCanceled(B) _timeTooShort(B) _startingRecord(B) _keepActive(B)
//                           _peak(f) _innerRecorder(@"Recorder") _audioTime(Q)
//                           _tempAudioPath(@"NSString") _timer(@"NSTimer")
// 事实：回调那一刻 _tempAudioPath 是 nil，真正的录音机是 _innerRecorder（类名 Recorder），
// 文件路径在它里面。v0.3.8 之前的「安全类型白名单」只放行 @"NSString"/@"NSURL"，
// 把 _innerRecorder 整个跳过了 → 取不到路径 → 兜底扫描扫到我们自己刚写的 TTS 文件
// → 覆盖空转 → 发出去还是原声。

// 只认「声明了具体类名」的对象 ivar（@"NSString"、@"Recorder"…）。
// 裸 @(id) 里可能塞了 AudioQueueRef 之类 C 指针，对它发消息会 EXC_BAD_ACCESS（@try 抓不住）。
static BOOL SLTypeIsNamedObj(const char *te) {
    return te && te[0] == '@' && te[1] == '"';
}

static BOOL SLTypeIsSafeObj(const char *te) {
    if (!SLTypeIsNamedObj(te)) return NO;
    static const char *safe[] = {"@\"NSString\"","@\"NSMutableString\"","@\"NSURL\"",
                                 "@\"NSNumber\"","@\"NSData\"","@\"NSMutableData\""};
    for (int i = 0; i < 6; i++) {
        if (strncmp(te, safe[i], strlen(safe[i])) == 0) return YES;
    }
    return NO;
}

// 这个字符串像不像一条录音文件
static BOOL SLIsAudioPath(NSString *p) {
    if (![p isKindOfClass:[NSString class]] || p.length == 0) return NO;
    if ([p hasPrefix:@"file://"]) p = [p stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    if (![p hasPrefix:@"/var/mobile"] && ![p hasPrefix:@"/private/var/mobile"]) return NO;
    static NSArray *exts = nil;
    if (!exts) exts = @[@"amr",@"m4a",@"caf",@"wav",@"mp3",@"aac",@"pcm"];
    return [exts containsObject:p.pathExtension.lowercaseString];
}

// 是不是我们自己产出的文件（TTS 结果 / 临时 AMR / 导入音频）——绝不能当成陌陌录音
static BOOL SLIsOurOwnFile(NSString *p) {
    if (![p isKindOfClass:[NSString class]] || p.length == 0) return YES;
    if (gSLTTSAudioPath && [p isEqualToString:gSLTTSAudioPath]) return YES;
    if ([p rangeOfString:@"/ShenglinMomo/"].location != NSNotFound) return YES;
    if ([p rangeOfString:@"Ai合成"].location != NSNotFound) return YES;
    if ([p rangeOfString:@"导入音频"].location != NSNotFound) return YES;
    if ([p rangeOfString:@"tts_result"].location != NSNotFound) return YES;
    return NO;
}

// 文件是否「在 armed（#tts 装填）之后」被写过 —— 这条能精准锁定本次录音刚写的那个文件
static BOOL SLFileFreshSince(NSString *p, NSTimeInterval since) {
    if (![p isKindOfClass:[NSString class]] || p.length == 0) return NO;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!a) return NO;
    NSDate *mt = a[NSFileModificationDate];
    if (!mt) return NO;
    return [mt timeIntervalSince1970] >= (since - 1.0);
}

// AMR-NB 自己数帧算时长（AVFoundation 对 .amr 经常返回 0 或 nan，不能依赖）
static double SLAMRDurationAtPath(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (d.length < 7) return 0;
    const unsigned char *b = (const unsigned char *)d.bytes;
    NSUInteger i = 0;
    if (memcmp(b, "#!AMR\n", 6) == 0) i = 6;
    else if (memcmp(b, "#!AMR-WB\n", 9) == 0) return (double)(d.length - 9) / 61.0 * 0.02;
    else return 0;
    static const int sz[16] = {12,13,15,17,19,20,26,31, 0,0,0,0,0,0,0,0};
    NSUInteger frames = 0;
    while (i < d.length) {
        int ft = (b[i] >> 3) & 0x0F;
        NSUInteger step = (ft == 15) ? 1 : (NSUInteger)(sz[ft] + 1);
        if (step == 0 || i + step > d.length) break;
        i += step;
        frames++;
    }
    return (double)frames * 0.02;
}

// 在对象里（含 _innerRecorder 递归）找「本次录音刚写好的音频文件路径」
static NSString *SLFindRecordPathInObject(id obj, NSTimeInterval armedAt, int depth) {
    if (!obj || depth > 3) return nil;

    // 1) 常见 getter
    static NSArray *getters = nil;
    if (!getters) {
        getters = @[@"url",@"filePath",@"recordFilePath",@"audioFilePath",@"path",
                    @"currentFilePath",@"recordPath",@"audioPath",@"fileURL",
                    @"recordFileURL",@"audioFileURL",@"outputURL",@"outputPath"];
    }
    for (NSString *selName in getters) {
        SEL s = NSSelectorFromString(selName);
        if (![obj respondsToSelector:s]) continue;
        @try {
            id v = ((id(*)(id,SEL))objc_msgSend)(obj, s);
            NSString *p = nil;
            if ([v isKindOfClass:[NSURL class]]) p = [(NSURL *)v path];
            else if ([v isKindOfClass:[NSString class]]) p = (NSString *)v;
            if (SLIsAudioPath(p) && !SLIsOurOwnFile(p) && SLFileFreshSince(p, armedAt)) return p;
        } @catch (NSException *e) {}
    }

    // 2) ivar：只读「命名对象类型」，并递归进去（_innerRecorder 里才有真路径）
    Class c = [obj class];
    while (c && c != [NSObject class]) {
        unsigned int pc = 0;
        Ivar *list = class_copyIvarList(c, &pc);
        NSString *hit = nil;
        for (unsigned i = 0; i < pc && !hit; i++) {
            const char *te = ivar_getTypeEncoding(list[i]);
            if (!SLTypeIsNamedObj(te)) continue;
            id v = nil;
            @try { v = object_getIvar(obj, list[i]); } @catch (NSException *e) { continue; }
            if (!v) continue;
            if ([v isKindOfClass:[NSString class]]) {
                NSString *p = (NSString *)v;
                if (SLIsAudioPath(p) && !SLIsOurOwnFile(p) && SLFileFreshSince(p, armedAt)) hit = [p copy];
            } else if ([v isKindOfClass:[NSURL class]]) {
                NSString *p = [(NSURL *)v path];
                if (SLIsAudioPath(p) && !SLIsOurOwnFile(p) && SLFileFreshSince(p, armedAt)) hit = [p copy];
            } else if (depth < 2) {
                hit = SLFindRecordPathInObject(v, armedAt, depth + 1);
            }
        }
        free(list);
        if (hit) return hit;
        c = class_getSuperclass(c);
    }
    return nil;
}

// dump 一个对象的全部 ivar：名字 + 类型 +（安全时）值。
// primitive 用偏移直接读内存，不发任何消息，绝对安全。
static void SLDumpIvarsShallow(id obj, NSString *tag) {
    if (!obj) return;
    Class c = [obj class];
    NSMutableArray *arr = [NSMutableArray array];
    while (c && c != [NSObject class]) {
        unsigned int pc = 0;
        Ivar *list = class_copyIvarList(c, &pc);
        for (unsigned i = 0; i < pc; i++) {
            Ivar iv = list[i];
            const char *te = ivar_getTypeEncoding(iv);
            const char *nm = ivar_getName(iv);
            NSString *vs = @"";
            if (SLTypeIsSafeObj(te)) {
                id v = nil;
                @try { v = object_getIvar(obj, iv); } @catch (NSException *e) {}
                if ([v isKindOfClass:[NSURL class]]) vs = [NSString stringWithFormat:@"=%@", [(NSURL *)v path]];
                else if ([v isKindOfClass:[NSString class]]) vs = [NSString stringWithFormat:@"=%@", v];
                else if ([v isKindOfClass:[NSNumber class]]) vs = [NSString stringWithFormat:@"=#%@", v];
            } else if (SLTypeIsNamedObj(te)) {
                id v = nil;
                @try { v = object_getIvar(obj, iv); } @catch (NSException *e) {}
                vs = v ? [NSString stringWithFormat:@"=<%@>", NSStringFromClass([v class])] : @"=(nil)";
            } else if (te) {
                char t0 = te[0];
                char *base = (char *)(__bridge void *)obj + ivar_getOffset(iv);
                if (t0 == 'Q') vs = [NSString stringWithFormat:@"=%llu", *(unsigned long long *)base];
                else if (t0 == 'q') vs = [NSString stringWithFormat:@"=%lld", *(long long *)base];
                else if (t0 == 'i' || t0 == 'I') vs = [NSString stringWithFormat:@"=%d", *(int *)base];
                else if (t0 == 'd') vs = [NSString stringWithFormat:@"=%.3f", *(double *)base];
                else if (t0 == 'f') vs = [NSString stringWithFormat:@"=%.2f", *(float *)base];
                else if (t0 == 'B' || t0 == 'c') vs = [NSString stringWithFormat:@"=%d", (int)(*(BOOL *)base)];
            }
            [arr addObject:[NSString stringWithFormat:@"%s(%s)%@", nm, te ?: "", vs]];
        }
        free(list);
        c = class_getSuperclass(c);
    }
    SLLog(@"%@ class=%@ [%@]", tag, NSStringFromClass([obj class]), [arr componentsJoinedByString:@" | "]);
}

// 录音机 dump：自身 + 深挖 _innerRecorder
static void SLDumpRecorderDeep(id rec) {
    if (!rec) return;
    SLDumpIvarsShallow(rec, @"RECORDER-DEEP");
    Ivar inner = class_getInstanceVariable([rec class], "_innerRecorder");
    if (inner) {
        id v = nil;
        @try { v = object_getIvar(rec, inner); } @catch (NSException *e) {}
        if (v) SLDumpIvarsShallow(v, @"INNER-RECORDER");
    }
}

// 兜底：在沙盒里找「armed 之后才写」的音频文件（排除我们自己产出的）
static NSString *SLNewestRecordFileSince(NSTimeInterval since) {
    static NSArray *exts = nil;
    if (!exts) exts = @[@"amr",@"m4a",@"caf",@"wav"];
    NSString *home = NSHomeDirectory();
    NSArray *roots = @[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library/Caches"],
        NSTemporaryDirectory()
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    NSTimeInterval bestT = 0;
    for (NSString *root in roots) {
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
        if (!e) continue;
        NSString *sub;
        int count = 0;
        while ((sub = [e nextObject]) && count++ < 3000) {
            if (![exts containsObject:sub.pathExtension.lowercaseString]) continue;
            NSString *fp = [root stringByAppendingPathComponent:sub];
            if (SLIsOurOwnFile(fp)) continue;
            NSDictionary *a = [fm attributesOfItemAtPath:fp error:nil];
            NSDate *mt = a[NSFileModificationDate];
            NSTimeInterval t = [mt timeIntervalSince1970];
            if (t >= (since - 1.0) && t > bestT) { bestT = t; best = fp; }
        }
    }
    return best;
}

#pragma mark - #tts 处理（录音替换：装填 AI 音频，等真实录音时覆盖）

static void SLArmTTS(id handler,
                     NSString *content,
                     void (^fallback)(void)) {
    (void)handler;
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
            // 「录音替换」模式：合成后只“装填”，不自动发。
            // 等用户真实录音，audioRecorder 钩子会把录音文件覆盖成这份 AI 音频。
            gSLTTSAudioPath = [outPath copy];
            gSLTTSAudioDur = dur;
            gSLArmedAt = [[NSDate date] timeIntervalSince1970];
            SLLog(@"armed tts path=%@ dur=%.2f — 等待用户录音替换", outPath, dur);
            [AWECAUtils showToast:@"声临已就绪：现在录音将发 AI 语音" duration:2.0];
            // 60s 内未录音则自动解除，避免误替换普通语音
            NSString *armed = outPath;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gSLTTSAudioPath && [gSLTTSAudioPath isEqualToString:armed]) {
                    gSLTTSAudioPath = nil;
                    SLLog(@"armed tts expired (60s), cleared");
                }
            });
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

    SLArmTTS(handler, content, ^{ if (orig) orig(self, _cmd); });
    SLClearTextInView(tv);
    return;
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
    SLArmTTS(self, content, ^{ if (orig) orig(self, _cmd, arg); });
    SLClearInputBars();
    return;
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
    SLArmTTS(self, content, ^{ if (orig) orig(self, _cmd, text, targetID, isSingle); });
    SLClearInputBars();
    return;
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
    unsigned long long newTime = time;

    if (gSLRecDump < 4) {
        gSLRecDump++;
        SLLog(@"REC-DONE self=%@ recorderClass=%@ pathArg=%@ timeRaw=%llu armed=%d",
              NSStringFromClass([self class]),
              recorder ? NSStringFromClass([recorder class]) : @"(nil)", path, time,
              gSLTTSAudioPath ? 1 : 0);
        if (recorder) SLDumpRecorderDeep(recorder);
        SLDumpSelfIvars(self);
    }

    // 「录音替换」：把本次真实录音文件覆盖成 AI 音频，再让陌陌发送。
    if (gSLTTSAudioPath) {
        NSTimeInterval armedAt = gSLArmedAt > 0 ? gSLArmedAt : ([[NSDate date] timeIntervalSince1970] - 300.0);
        NSString *target = nil;
        NSString *via = @"(none)";

        // ① path 参数（通常是 nil）
        if (SLIsAudioPath(path) && !SLIsOurOwnFile(path) && SLFileFreshSince(path, armedAt)) {
            target = path; via = @"pathArg";
        }
        // ② 录音机内部（含 _innerRecorder 递归）
        if (!target) {
            NSString *p = SLFindRecordPathInObject(recorder, armedAt, 0);
            if (p) { target = p; via = @"recorder"; }
        }
        // ③ 兜底扫描：只接受 armed 之后写的文件
        if (!target) {
            NSString *p = SLNewestRecordFileSince(armedAt);
            if (p) { target = p; via = @"scan"; }
        }

        double ttsDur = gSLTTSAudioDur;
        double origDur = 0;
        if (target) {
            if ([[target pathExtension].lowercaseString isEqualToString:@"amr"]) origDur = SLAMRDurationAtPath(target);
            if (origDur <= 0.01) origDur = [AWECAUtils audioDurationAtPath:target];
        }
        SLLog(@"REPLACE target=%@ via=%@ origDur=%.2f ttsDur=%.2f timeRaw=%llu",
              target ?: @"(nil)", via, origDur, ttsDur, time);

        if (target) {
            NSMutableData *payload = [NSMutableData dataWithContentsOfFile:gSLTTSAudioPath];
            BOOL padded = NO;
            NSString *ttsExt = [gSLTTSAudioPath pathExtension].lowercaseString;
            if (payload.length && ttsDur > 0 && origDur > ttsDur + 0.06 && [ttsExt isEqualToString:@"amr"]) {
                // AI 音频比真实录音短 → 补静音帧补到同长，语音条秒数就与音频一致
                NSUInteger frames = (NSUInteger)llround((origDur - ttsDur) / 0.02);
                NSData *sil = [SLAMREncoder amrSilenceForFrames:frames];
                if (sil.length) { [payload appendData:sil]; padded = YES; }
            }
            if (payload.length) {
                // 关键：必须原地覆盖（atomically:NO）。
                // 陌陌可能还持有这个文件的 fd，原子写是换 inode，它读到的还是旧内容。
                BOOL ok = [payload writeToFile:target atomically:NO];
                SLLog(@"REPLACE write target=%@ ok=%d size=%lu padded=%d targetExt=%@ ttsExt=%@",
                      target, ok, (unsigned long)payload.length, padded,
                      [target pathExtension].lowercaseString, ttsExt);
                if (ok) {
                    if (!padded && origDur > 0.1 && ttsDur > origDur + 0.06) {
                        // AI 音频比录音长：按同一比例改时长（单位无关）
                        newTime = (unsigned long long)llround((double)time * (ttsDur / origDur));
                        SLLog(@"REPLACE time adjusted %llu -> %llu", time, newTime);
                    }
                    [AWECAUtils showToast:@"已发送 AI 语音" duration:1.5];
                }
            } else {
                SLLog(@"REPLACE read armed audio failed: %@", gSLTTSAudioPath);
            }
        } else {
            SLLog(@"REPLACE skip: 没找到本次录音文件（armed=%.0f）", armedAt);
        }
        gSLTTSAudioPath = nil;
    }

    if (orig) orig(self, _cmd, recorder, path, newTime);
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
