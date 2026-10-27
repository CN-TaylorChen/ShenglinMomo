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
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"
#import <math.h>
#import "SLLog.h"
#import "SLAMREncoder.h"
#import "SLPCMTool.h"
#import "SLPipeline.h"
#import "SLSettingsPanel.h"
#import "SLVirtualLocation.h"
#import "SLLogViewController.h"
#import "SLEntry.h"
#import "SLVoicePack.h"
#import "SLTTSAuditionPanel.h"

#define SLVersion @"0.4.37"
#define kSLEnabledKey @"SLEnhanceEnabled"
#define kSLCommandKey @"SLCommand"
#define kSLPackCmdKey @"SLPackCommand"

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

// v0.4.37.5：语音包单独一条口令，跟合成口令彻底分开 ——
// 「#yyb」= 直接发所选语音包，「#tts 文字」= 合成，互不抢。
// v0.4.37.9：默认值从 yyb 改成 #yyb，跟合成口令一样带井号，避免两条口令长得不一样。
static NSString *SLPackCommand(void) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPackCmdKey];
    if (v.length == 0) v = @"#yyb";
    return v;
}

// 老用户存的是旧默认值 yyb，一次性迁移成 #yyb；自己改成过别的不动。
static void SLMigratePackCommandDefault(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:@"SLPackCmdMigratedV1"]) return;
    NSString *v = [d stringForKey:kSLPackCmdKey];
    if ([v isEqualToString:@"yyb"]) {
        [d setObject:@"#yyb" forKey:kSLPackCmdKey];
        SLLog(@"pack command migrated: yyb -> #yyb");
    }
    [d setBool:YES forKey:@"SLPackCmdMigratedV1"];
    [d synchronize];
}

// v0.4.37.6：口令严格匹配 —— 只认用户设置的那一条，不再生成「去掉井号」的变体。
// 口令本身可以自定义，靠猜出来的变体只会让「到底哪条生效」变得不可预测。
// 唯一的容错是半角/全角井号互认：中文输入法下「＃」和「#」肉眼一样，属于输入法问题不是口误。
static NSString *SLNormHash(NSString *s) {
    return [s stringByReplacingOccurrencesOfString:@"＃" withString:@"#"];
}

// 命中返回口令占用的字符数（0 = 未命中）；口令以英文字母结尾时要求右边界不是字母
static NSUInteger SLCommandPrefixLength(NSString *text, NSString *cmd) {
    if (![text isKindOfClass:[NSString class]] || ![cmd isKindOfClass:[NSString class]]) return 0;
    if (!text.length || !cmd.length || text.length < cmd.length) return 0;
    if ([SLNormHash([text substringToIndex:cmd.length]) caseInsensitiveCompare:SLNormHash(cmd)] != NSOrderedSame) return 0;
    unichar last = [cmd characterAtIndex:cmd.length - 1];
    BOOL latinEnd = (last < 128) && ((last >= 'a' && last <= 'z') || (last >= 'A' && last <= 'Z'));
    if (latinEnd && text.length > cmd.length) {
        unichar next = [text characterAtIndex:cmd.length];
        if ((next >= 'a' && next <= 'z') || (next >= 'A' && next <= 'Z')) return 0;   // yybxx 不算命中
    }
    return cmd.length;
}

static BOOL SLHasPrefixCommand(NSString *text, NSString *cmd) {
    return SLCommandPrefixLength(text, cmd) > 0;
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

// 找到「真正定义」这个方法的类。
// class_getInstanceMethod 会沿父链返回父类那个 Method，而 method_setImplementation 改的
// 也是父类那份实现。之前拿调用方 cls 做记账 key，埋了两个雷：
//   ① 兄弟子类（同父不同类）走同一份 IMP，沿链查不到 key → orig=NULL → 原实现被静默吞掉；
//   ② 同一个 Method 被二次注册时，第二次读到的 cur 已经是「上一次的钩子」，
//      于是 key 被改写成钩子自己 → 钩子调钩子 → 无限递归爆栈（0.4.37 语音闪退的真因）。
static Class SLClassOwningMethod(Class cls, SEL sel) {
    Class c = cls;
    while (c) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(ms[i]) == sel) {
                free(ms);
                return c;
            }
        }
        if (ms) free(ms);
        c = class_getSuperclass(c);
    }
    return cls;
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

    // ① 同一个 Method 只允许装一次：沿 owner 的父链检查是否已登记。
    // v0.4.37：重试安装时这里会反复命中，原来每次都写一行日志（一次启动刷上百行），
    // 现在静默跳过 —— 只有真正的安装才记账。
    Class owner = SLClassOwningMethod(cls, sel);
    for (Class c = owner; c; c = class_getSuperclass(c)) {
        if (SLOrigIMPs()[SLKey(c, sel)]) {
            return NO;
        }
    }

    IMP cur = method_getImplementation(m);
    if (cur == replacement) {
        return NO;
    }

    // ② 记账 key 用「定义类」，任何子类实例沿父链都能查到，不会再出现 orig=NULL
    SLOrigIMPs()[SLKey(owner, sel)] = [NSValue valueWithPointer:cur];
    method_setImplementation(m, replacement);
    SLLog(@"hook ok %@ %@ type=%s owner=%@", cls, NSStringFromSelector(sel), t, owner);
    return YES;
}

// v0.4.37：NSClassFromString 取不到的兜底。
// 实测（0.4.37 日志）：MDChatUniverseInputBar 能取到并装上钩子，但同一个模块里的
// MDChatUniverseHandler 用 NSClassFromString 却是 nil（懒加载/Swift 暴露类的常见坑），
// 于是 sendTextMessage:/sendAudioMessage: 全部静默跳过。这里直接遍历运行时类表兜底，
// 和 CENSUS 用的是同一条路径（它确实能列出这个类）。
static Class SLClassByName(const char *name) {
    if (!name || !name[0]) return Nil;
    Class c = NSClassFromString([NSString stringWithUTF8String:name]);
    if (c) return c;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return Nil;
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!buf) return Nil;
    n = objc_getClassList(buf, n);
    Class found = Nil;
    for (int i = 0; i < n; i++) {
        const char *nm = class_getName(buf[i]);
        if (nm && strcmp(nm, name) == 0) { found = buf[i]; break; }
    }
    free(buf);
    if (found) SLLog(@"class %s 由运行时表兜底找到（NSClassFromString 为 nil）", name);
    return found;
}

// 通用：给任意「一个对象参数」的方法挂 SLSendTextMessage
static BOOL SLInstallOneObjectHook(Class cls, SEL sel, IMP imp) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;   // 静默：重试安装时不刷日志
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    if (!sig || sig.numberOfArguments < 3) return NO;
    const char *a2 = [sig getArgumentTypeAtIndex:2];
    if (!a2 || a2[0] != '@') return NO;
    return SLRegisterMethod(cls, sel, imp);
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

// v0.4.37：安全取字符串 getter —— 先确认方法返回类型是对象（'@'）再调。
// 0.4.37 闪退根因：对「返回结构体/基本类型」的属性盲调 getter，arm64 上返回值 ABI 不匹配，直接崩。
static NSString *SLStringGetter(id obj, NSString *name) {
    if (!obj || !name.length) return nil;
    SEL s = NSSelectorFromString(name);
    if (![obj respondsToSelector:s]) return nil;
    Method m = class_getInstanceMethod([obj class], s);
    if (!m) return nil;
    char ret[16] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    if (ret[0] != '@') return nil;
    @try {
        id v = ((id (*)(id, SEL))objc_msgSend)(obj, s);
        if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    } @catch (NSException *e) { }
    return nil;
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
            NSString *v = SLStringGetter(arg, name);
            if (v.length) return v;
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

// 命中口令时把「去掉口令后的正文」写进 outRest
static BOOL SLMatchCommand(NSString *text, NSString **outRest) {
    NSUInteger n = SLCommandPrefixLength(text, SLCommand());
    if (!n) return NO;
    if (outRest) {
        NSString *rest = [text substringFromIndex:n];
        rest = [rest stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@" :：\t"]];
        *outRest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return YES;
}

static BOOL SLTextHasCommand(NSString *text) {
    return SLMatchCommand(text, NULL);
}

static NSString *SLTextAfterCommand(NSString *text) {
    NSString *rest = @"";
    if (!SLMatchCommand(text, &rest)) return @"";
    return rest;
}

// 合成口令或语音包口令，任一成立就算「带口令」（供输入框扫描用）
static BOOL SLTextHasAnyCommand(NSString *text) {
    return SLTextHasCommand(text) || SLHasPrefixCommand(text, SLPackCommand());
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
        if (t.length && SLTextHasAnyCommand(t)) {
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

// v0.4.37：放宽版 —— 不再要求 ivar 静态类型名以 Hander/Handler 结尾。
// 小宇宙那套页面把发送器可能挂在 id / 协议类型的 ivar 上，只要对象真的响应
// sendAudioMessage:audioTime:audioFileSize: 就认它（这个选择器足够特异）。
static id SLAudioHandlerAnyInObject(id obj) {
    if (!obj) return nil;
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList([obj class], &n);
    id found = nil;
    for (unsigned i = 0; i < n && !found; i++) {
        const char *te = ivar_getTypeEncoding(ivars[i]);
        if (!te || te[0] != '@') continue;
        __unsafe_unretained id v = nil;
        @try { v = object_getIvar(obj, ivars[i]); } @catch (NSException *e) { }
        if (v && [v respondsToSelector:@selector(sendAudioMessage:audioTime:audioFileSize:)]) found = v;
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
        h = SLAudioHandlerAnyInObject(r);
        if (h) {
            SLLog(@"found audio handler(any-ivar) %@ in %@", NSStringFromClass([h class]), NSStringFromClass([r class]));
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
static NSData *gSLTTSPCM16k = nil;      // 合成音频解出来的 16k/mono/s16le PCM
static double gSLTTSPCM16kDur = 0;
// —— v0.4.37：接管陌陌录音的 PCM 流（MDAudioStreamBus → MDOpusEncoder）——
static id gSLBusRef = nil;              // 本次录音的 bus 实例（身份校验，别喂错对象）
static NSData *gSLBusPCM = nil;         // 按 bus 的 ASBD 预处理好的 PCM
static NSUInteger gSLBusOffset = 0;     // 已喂字节数
static BOOL gSLBusActive = NO;          // 正在接管
static BOOL gSLBusFed = NO;             // 至少喂过一块 → 文件里已经是 AI 语音
static int gSLBusSwallowLog = 0;
// —— v0.4.37：通用 PCM 漏斗（编码器入口兜底）——
static BOOL gSLPcmArmed = NO;
static double gSLArmRate = 0;
static unsigned gSLArmCh = 0;
static int gSLFunnelLog = 0;
static NSMutableSet *gSLHookedSels = nil;
// —— v0.4.37：收尾补喂（用户松手比 AI 语音短时，把剩下的 PCM 补进编码器，避免被截断）——
static NSUInteger gSLBusChunkSize = 0;  // 陌陌每次递进来的块大小（补喂按同样粒度，保持帧对齐）
static BOOL gSLDrained = NO;            // 本次录音是否已经补喂过（只补一次）
// v0.4.37：补喂不再自己调编码器，而是走总线自己的 sendPcm:byteSize:。
// 这些字节是我们塞进去的，encodePcm: 钩子必须原样放行（按字节数记账，异步也准）。
static NSUInteger gSLForcePassBytes = 0;
#define kSLFillShortKey @"SLFillShort"   // 短录音补全开关（默认开）
static NSMutableSet *gSLDrainHooked = nil;
static NSTimeInterval gSLArmedAt = 0;   // #tts 装填时刻（锁定“本次录音刚写的文件”）
static int gSLRecDump = 0;
static int gSLModelDump = 0;
static NSString *gSLTempRecPath = nil;  // 陌陌录音机的临时文件路径（setTempAudioPath: 时捕获）
static int gSLMethDump = 0;

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
__attribute__((unused)) static BOOL SLIsAudioPath(NSString *p) {
    if (![p isKindOfClass:[NSString class]] || p.length == 0) return NO;
    if ([p hasPrefix:@"file://"]) p = [p stringByReplacingOccurrencesOfString:@"file://" withString:@""];
    if (![p hasPrefix:@"/var/mobile"] && ![p hasPrefix:@"/private/var/mobile"]) return NO;
    static NSArray *exts = nil;
    if (!exts) exts = @[@"amr",@"m4a",@"caf",@"wav",@"mp3",@"aac",@"pcm",@"opus",@"ogg"];
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
__attribute__((unused)) static BOOL SLFileFreshSince(NSString *p, NSTimeInterval since) {
    if (![p isKindOfClass:[NSString class]] || p.length == 0) return NO;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!a) return NO;
    NSDate *mt = a[NSFileModificationDate];
    if (!mt) return NO;
    return [mt timeIntervalSince1970] >= (since - 1.0);
}

// AMR-NB 自己数帧算时长（AVFoundation 对 .amr 经常返回 0 或 nan，不能依赖）
__attribute__((unused)) static double SLAMRDurationAtPath(NSString *p) {
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
__attribute__((unused)) static NSString *SLFindRecordPathInObject(id obj, NSTimeInterval armedAt, int depth) {
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
__attribute__((unused)) static NSString *SLNewestRecordFileSince(NSTimeInterval since) {
    static NSArray *exts = nil;
    if (!exts) exts = @[@"amr",@"m4a",@"caf",@"wav",@"opus",@"ogg"];
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

// —— v0.4.37：按语音消息 body 里的 file token 精确定位陌陌真实录音文件 ——
//
// 真机日志 MODEL-DEEP 已给出铁证：
//   body = http://www.immomo.com/chataudio?mode=GUID&filesize=0&file=3B9-F2528F92A310
//          &audiotime=14&ext=amr&ft=1&dummy=1
// 这个 file token 就是陌陌给这段录音起的文件名。按它在容器里按文件名搜 → 精确定位，
// 比「扫最新音频文件」可靠得多（v0.3.9 的扫描一个候选都没找到，说明录音既不在
// Documents/Library/Caches/tmp，也可能没有扩展名 → 只能按名字搜）。

// 容器根：自己的沙盒 + 自己可见的 AppGroup（共享容器）
static NSArray *SLSearchRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    [roots addObject:NSHomeDirectory()];
    NSString *shared = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:shared error:nil];
    for (NSString *n in names) {
        if (n.length) [roots addObject:[shared stringByAppendingPathComponent:n]];
    }
    return roots;
}

static NSString *SLMagicAtPath(NSString *path);   // 见下方实现

// 按文件名片段全容器找文件（file token）
static NSString *SLFindFileByToken(NSString *token) {
    if (![token isKindOfClass:[NSString class]] || token.length < 5) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    int scanned = 0;
    for (NSString *root in SLSearchRoots()) {
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
        if (!e) continue;
        NSString *sub;
        while ((sub = [e nextObject])) {
            if (scanned++ > 60000) break;
            NSString *name = [sub lastPathComponent];
            if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            NSString *fp = [root stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fp isDirectory:&isDir] || isDir) continue;
            if (SLIsOurOwnFile(fp)) continue;
            NSDictionary *a = [fm attributesOfItemAtPath:fp error:nil];
            SLLog(@"TOKEN hit %@ name=%@ size=%lld magic=%@",
                  fp, name, (long long)[a fileSize], SLMagicAtPath(fp));
            return fp;
        }
    }
    return nil;
}

// 在指定目录里找「since 之后被写过」的最新音频文件（录音临时目录）
__attribute__((unused)) static NSString *SLNewestAudioInDir(NSString *dir, NSTimeInterval since) {
    if (![dir isKindOfClass:[NSString class]] || dir.length == 0) return nil;
    static NSArray *exts = nil;
    if (!exts) exts = @[@"amr",@"m4a",@"caf",@"wav",@"opus",@"ogg"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    NSTimeInterval bestT = 0;
    for (NSString *n in names) {
        NSString *fp = [dir stringByAppendingPathComponent:n];
        if (![exts containsObject:fp.pathExtension.lowercaseString]) continue;
        if (SLIsOurOwnFile(fp)) continue;
        NSDictionary *a = [fm attributesOfItemAtPath:fp error:nil];
        NSTimeInterval t = [a[NSFileModificationDate] timeIntervalSince1970];
        if (t >= (since - 2.0) && t > bestT) { bestT = t; best = fp; }
    }
    return best;
}

// 诊断：列出自 since 起被改过的「最近 6 个文件」（不限扩展名），
// 用来在「找不到录音文件」时暴露陌陌到底把它写在哪（可能是无扩展名的 GUID 文件）。
static NSString *SLDiagRecentFiles(NSTimeInterval since) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *hits = [NSMutableArray array];   // [mtime, path]
    int scanned = 0;
    for (NSString *root in @[NSHomeDirectory(), NSTemporaryDirectory()]) {
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
        if (!e) continue;
        NSString *sub;
        while ((sub = [e nextObject])) {
            if (scanned++ > 20000) break;
            NSString *fp = [root stringByAppendingPathComponent:sub];
            if ([fp rangeOfString:@"/ShenglinMomo/"].location != NSNotFound) continue;
            NSDictionary *a = [fm attributesOfItemAtPath:fp error:nil];
            if (!a) continue;
            if ([a[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
            NSTimeInterval t = [a[NSFileModificationDate] timeIntervalSince1970];
            if (t < since - 2.0) continue;
            [hits addObject:[NSString stringWithFormat:@"%.0f|%lld|%@", t, (long long)[a fileSize], fp]];
        }
    }
    [hits sortUsingSelector:@selector(compare:)];
    NSUInteger n = hits.count;
    if (n > 6) hits = [[hits subarrayWithRange:NSMakeRange(n - 6, 6)] mutableCopy];
    return hits.count ? [hits componentsJoinedByString:@" ;; "] : @"(none)";
}

// 取 body 里 key=value 的 value（到 & 或结尾）
static NSString *SLBodyValue(NSString *body, NSString *key) {
    if (![body isKindOfClass:[NSString class]] || body.length == 0) return nil;
    NSString *needle = [key stringByAppendingString:@"="];
    NSRange r = [body rangeOfString:needle];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = r.location + r.length;
    if (start >= body.length) return nil;
    NSRange amp = [body rangeOfString:@"&" options:0 range:NSMakeRange(start, body.length - start)];
    NSUInteger end = (amp.location == NSNotFound) ? body.length : amp.location;
    if (end <= start) return nil;
    return [body substringWithRange:NSMakeRange(start, end - start)];
}

// 把 body 里 audiotime=N 改成我们的真实时长
// 单位是 0.1 秒（v0.4.37 日志实测：audiotime=18 显示 1.8 秒），所以要 ×10；
// 早先按「秒」写，2.5 秒写成 2~3 → 对端只显示 0.2~0.3 秒，看起来就是「0 秒」。
static NSString *SLBodySetAudioTime(NSString *body, double dur) {
    if (![body isKindOfClass:[NSString class]] || body.length == 0) return body;
    long long tenths = (long long)llround(dur * 10.0);
    if (tenths < 1) tenths = 1;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"audiotime=\\d+"
                                                                       options:0 error:nil];
    if (!re) return body;
    return [re stringByReplacingMatchesInString:body options:0 range:NSMakeRange(0, body.length)
                                   withTemplate:[NSString stringWithFormat:@"audiotime=%lld", tenths]];
}

// 读文件前 4 字节的十六进制（判断容器：OggS = Ogg Opus，#!AM = AMR）
static NSString *SLMagicAtPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return @"(none)";
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return @"(none)";
    NSData *h = nil;
    @try { h = [fh readDataOfLength:4]; } @catch (NSException *e) {}
    @try { [fh closeFile]; } @catch (NSException *e) {}
    if (h.length < 4) return @"(short)";
    const uint8_t *b = h.bytes;
    return [NSString stringWithFormat:@"%02X%02X%02X%02X", b[0], b[1], b[2], b[3]];
}

// 把 AI 音频原地写进陌陌的真实录音文件（必须 atomically:NO：换 inode 陌陌读到的还是旧内容）
// outSize 返回写入的字节数（要同步给 sendAudioMessage 的 audioFileSize）
__attribute__((unused)) static BOOL SLOverwriteWithAI(NSString *target, NSUInteger *outSize) {
    if (![target isKindOfClass:[NSString class]] || target.length == 0) return NO;
    if (![gSLTTSAudioPath isKindOfClass:[NSString class]] || gSLTTSAudioPath.length == 0) return NO;
    NSData *payload = [NSData dataWithContentsOfFile:gSLTTSAudioPath];
    if (payload.length == 0) {
        SLLog(@"OVERWRITE read AI failed: %@", gSLTTSAudioPath);
        return NO;
    }
    NSString *oldMagic = SLMagicAtPath(target);
    BOOL ok = [payload writeToFile:target atomically:NO];
    if (outSize) *outSize = payload.length;
    SLLog(@"OVERWRITE target=%@ ok=%d aiBytes=%lu aiExt=%@ aiMagic=%@ oldMagic=%@",
          target, ok, (unsigned long)payload.length,
          [gSLTTSAudioPath pathExtension], SLMagicAtPath(gSLTTSAudioPath), oldMagic);
    return ok;
}

// 一次性 dump MDAudioRecorder 的方法名（万一还要再深挖）
static void SLDumpMethodNames(id obj) {
    if (!obj) return;
    Class c = [obj class];
    NSMutableArray *names = [NSMutableArray array];
    while (c && c != [NSObject class] && names.count < 200) {
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned i = 0; i < mc && names.count < 200; i++) {
            [names addObject:NSStringFromSelector(method_getName(ms[i]))];
        }
        free(ms);
        c = class_getSuperclass(c);
    }
    SLLog(@"RECORDER-METHODS %@", [names componentsJoinedByString:@" "]);
}

#pragma mark - #tts 处理（录音替换：装填 AI 音频，等真实录音时覆盖）

// v0.4.37.5：语音包装填 —— yyb 口令专用。返回 NO 表示没装成，并且已经提示过原因。
static BOOL SLArmPackNow(void) {
    if (![SLVoicePack isEnabled]) {
        [AWECAUtils showToast:@"语音包没启用：设置 → 语音包 里打开开关" duration:2.4];
        SLLog(@"yyb: pack disabled");
        return NO;
    }
    NSDictionary *pack = [SLVoicePack activePack];
    if (!pack) {
        [AWECAUtils showToast:@"还没选语音包：去「语音包」里点一条" duration:2.4];
        SLLog(@"yyb: no active pack");
        return NO;
    }
    NSString *packPath = [SLVoicePack pathOfPack:pack];
    if (!packPath.length) {
        [AWECAUtils showToast:@"这条语音包的文件不见了，重新导入" duration:2.4];
        SLLog(@"yyb: missing file rel=%@", pack[@"rel"] ?: @"-");
        return NO;
    }
    double packDur = [AWECAUtils audioDurationAtPath:packPath];
    if (packDur <= 0.05) {
        [AWECAUtils showToast:@"这段音频解不了（iOS 不支持 oga/ogg），先转成 m4a 或 wav" duration:3.0];
        SLLog(@"yyb: undecodable %@", packPath.lastPathComponent);
        return NO;
    }
    if (packDur > 60.0) packDur = 60.0;   // 陌陌语音条上限
    gSLTTSAudioPath = [packPath copy];
    gSLTTSAudioDur = packDur;
    gSLArmedAt = [[NSDate date] timeIntervalSince1970];
    NSData *pcm = [SLAMREncoder pcmMono16AtPath:packPath sampleRate:16000.0];
    NSUInteger cap = (NSUInteger)(60.0 * 16000.0) * 2;
    if (pcm.length > cap) pcm = [pcm subdataWithRange:NSMakeRange(0, cap)];
    if (pcm.length > 1600) {
        gSLTTSPCM16k = pcm;
        gSLTTSPCM16kDur = (double)(pcm.length / 2) / 16000.0;
    } else {
        gSLTTSPCM16k = nil;
        gSLTTSPCM16kDur = 0;
    }
    SLLog(@"armed pack %@ dur=%.2f pcm=%lu — 等待用户录音替换",
          packPath.lastPathComponent, packDur, (unsigned long)pcm.length);
    SLFloatSetState(SLFloatStateReady);   // v0.4.37：蓝环合拢一下表示已就绪
    [AWECAUtils showToast:[NSString stringWithFormat:@"已就绪 · 语音包「%@」（%.1fs）",
                           pack[@"name"] ?: @"", packDur]
                 duration:2.0];
    NSString *armedPack = [gSLTTSAudioPath copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gSLTTSAudioPath && [gSLTTSAudioPath isEqualToString:armedPack]) {
            gSLTTSAudioPath = nil;
            SLLog(@"armed pack expired (60s), cleared");
        }
    });
    return YES;
}

// v0.4.37：这条是「自动装载」——标记本次是语音包自动装填的（不是口令 / 合成），
// 用来在发送时给对提示，也用来在开关关掉后清掉残留。
static BOOL gSLAutoArmed = NO;
static NSString *gSLAutoPackName = nil;

static void SLResetArmedAudio(void) {
    gSLTTSAudioPath = nil;
    gSLTTSPCM16k = nil;
    gSLTTSPCM16kDur = 0;
    gSLTTSAudioDur = 0;
    gSLAutoArmed = NO;
    gSLAutoPackName = nil;
}

// v0.4.37：不靠口令的装载路径。
// 选中语音包之后，按住说话就应该直接发它 —— 所以在「总线要建 PCM」这一刻才装载，
// 这时既拿得到该用的音频、也赶得上接管；用户不需要记任何口令。
// 首次要把音频解码成 16k PCM（几十毫秒），按 rel 缓存，换包才重算。
static NSData *sAutoPackPCM = nil;
static NSString *sAutoPackKey = nil;
static double sAutoPackDur = 0;

// 把某个语音包解码成 16k/mono/s16le PCM 并缓存。加锁是因为预热点在后台队列、
// 真正装载在录音线程，两处可能同时进来。
static BOOL SLPackPCMLoaded(NSString *path, NSString *key, double dur,
                            NSData **outPCM, double *outDur) {
    @synchronized ([SLVoicePack class]) {
        if ([sAutoPackKey isEqualToString:key] && sAutoPackPCM.length >= 1600) {
            if (outPCM) *outPCM = sAutoPackPCM;
            if (outDur) *outDur = sAutoPackDur;
            return YES;
        }
        NSData *pcm = [SLAMREncoder pcmMono16AtPath:path sampleRate:16000.0];
        NSUInteger cap = (NSUInteger)(60.0 * 16000.0) * 2;
        if (pcm.length > cap) pcm = [pcm subdataWithRange:NSMakeRange(0, cap)];
        if (pcm.length < 1600) {
            SLLog(@"AUTO-PACK 解码失败 %@", path.lastPathComponent);
            return NO;
        }
        sAutoPackPCM = pcm;
        sAutoPackKey = [key copy];
        sAutoPackDur = dur;
        if (outPCM) *outPCM = pcm;
        if (outDur) *outDur = dur;
        SLLog(@"AUTO-PACK 缓存 %@ pcm=%lu dur=%.2f", key, (unsigned long)pcm.length, dur);
        return YES;
    }
}

// 预热点：选中语音包时在后台先解好，录音那一刻就不用现解（几百毫秒的解码不在录音线程上做）
void SLPackPrewarm(void) {
    if (![SLVoicePack isAutoReplaceEnabled]) return;
    if (![SLVoicePack isEnabled]) return;
    NSDictionary *pack = [SLVoicePack activePack];
    if (!pack) return;
    NSString *path = [SLVoicePack pathOfPack:pack];
    if (!path.length) return;
    NSString *key = pack[@"rel"] ?: path;
    double dur = [AWECAUtils audioDurationAtPath:path];
    if (dur <= 0.05) return;
    if (dur > 60.0) dur = 60.0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try { SLPackPCMLoaded(path, key, dur, NULL, NULL); } @catch (NSException *e) {}
    });
}

static BOOL SLArmPackAutoQuiet(void) {
    if (!SLIsEnabled()) return NO;
    if (![SLVoicePack isAutoReplaceEnabled]) return NO;
    if ([SLVoicePack isOriginalMode]) return NO;   // v0.4.37：原声 —— 这次不替换
    if (![SLVoicePack isEnabled]) return NO;
    NSDictionary *pack = [SLVoicePack activePack];
    if (!pack) return NO;
    NSString *path = [SLVoicePack pathOfPack:pack];
    if (!path.length) return NO;

    double dur = [AWECAUtils audioDurationAtPath:path];
    if (dur <= 0.05) {
        SLLog(@"AUTO-PACK 跳过：解不了 %@", path.lastPathComponent);
        return NO;
    }
    if (dur > 60.0) dur = 60.0;   // 陌陌语音条上限

    NSData *pcm = nil;
    double useDur = dur;
    if (!SLPackPCMLoaded(path, (pack[@"rel"] ?: path), dur, &pcm, &useDur)) return NO;

    gSLTTSAudioPath = [path copy];
    gSLTTSAudioDur = useDur;
    gSLTTSPCM16k = pcm;
    gSLTTSPCM16kDur = (double)(pcm.length / 2) / 16000.0;
    gSLArmedAt = [[NSDate date] timeIntervalSince1970];
    gSLAutoArmed = YES;
    gSLAutoPackName = [pack[@"name"] copy];
    SLLog(@"AUTO-PACK 装载 %@（%.2fs）→ 本次录音直接替换", gSLAutoPackName ?: @"-", gSLTTSAudioDur);
    return YES;
}

static void SLArmTTS(id handler,
                     NSString *content,
                     void (^fallback)(void)) {
    (void)handler;

    // v0.4.37.5：语音包已改走独立口令（默认 yyb），这里只负责合成，两者不再互相抢。
    SLFloatSetState(SLFloatStateSynthesizing);   // v0.4.37：球变蓝、弧线转圈
    [AWECAUtils showToast:@"合成中..." duration:2.0];
    [[SLPipeline shared] synthesizeMessageText:content completion:^(BOOL ok, NSString *outPath, double dur, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok || !outPath.length) {
                NSString *m = msg.length ? msg : @"合成失败";
                SLLog(@"tts failed: %@", m);
                [AWECAUtils showToast:m duration:2.5];
                SLFloatSetState(SLFloatStateIdle);
                if (fallback) fallback();
                return;
            }
            // 「录音替换」模式：合成后只“装填”，不自动发。
            // 等用户真实录音，audioRecorder 钩子会把录音文件覆盖成这份 AI 音频。
            gSLTTSAudioPath = [outPath copy];
            gSLTTSAudioDur = dur;
            gSLArmedAt = [[NSDate date] timeIntervalSince1970];
            SLLog(@"armed tts path=%@ dur=%.2f — 等待用户录音替换", outPath, dur);
            SLFloatSetState(SLFloatStateReady);   // v0.4.37：合成完，球整圈亮一下

            // —— v0.4.37：不再自己造 Opus 文件 ——
            // v0.4.37 直接调陌陌的 MDAudioStreamBus 构造器会闪退（它在 init 里就用到
            // 陌陌内部才有的 opus 配置，外部 alloc 出来的实例跑不通）。
            // 改成：录音时接管陌陌自己的 PCM 流（见 SLPcmPrepareHook / SLPcmFeedHook），
            // 编码器和容器全部由陌陌自己做 —— 格式必然正确。
            // 这里只把合成音频解码成 16k/mono/s16le 的 PCM 备好。
            NSString *rawPath = [SLPipeline shared].lastRawAudioPath ?: outPath;
            NSData *pcm = [SLAMREncoder pcmMono16AtPath:rawPath sampleRate:16000.0];
            if (pcm.length > 1600) {
                gSLTTSPCM16k = pcm;
                gSLTTSPCM16kDur = (double)(pcm.length / 2) / 16000.0;
                SLLog(@"pcm16k ready bytes=%lu dur=%.2f（录音时接管 PCM 流替换）",
                      (unsigned long)pcm.length, gSLTTSPCM16kDur);
            } else {
                gSLTTSPCM16k = nil;
                gSLTTSPCM16kDur = 0;
                SLLog(@"pcm16k 解码失败 bytes=%lu，本次无法接管", (unsigned long)pcm.length);
            }

            // 60s 内未录音则自动解除，避免误替换普通语音。
            // v0.4.37：倒计时改成「确认使用之后」才启动 —— 否则用户在里面反复试听，
            // 还没听完装填就过期了。
            NSString *armed = outPath;
            void (^startDisarmTimer)(void) = ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gSLTTSAudioPath && [gSLTTSAudioPath isEqualToString:armed]) {
                        gSLTTSAudioPath = nil;
                        SLLog(@"armed tts expired (60s), cleared");
                    }
                });
            };

            if ([SLTTSAuditionPanel isEnabled]) {
                // 试听期间不清空装填：用户点「用这条」才算数，点「取消」才撤销。
                // v0.4.37：把 16k PCM 一起递进去，面板拿它封 WAV 试听（AMR 播不动）
                [SLTTSAuditionPanel presentWithAudioPath:outPath
                                                 pcm16k:gSLTTSPCM16k
                                               duration:dur
                                                   text:content
                                                  onUse:^{
                    [AWECAUtils showToast:[NSString stringWithFormat:@"已就绪 · 现在录音发送 AI 语音（%.1fs）", dur]
                                 duration:2.0];
                    startDisarmTimer();
                }
                                                  onCancel:^{
                    // 只有这次装的还是这条才清，避免误清掉用户已经换成新的一条
                    if (gSLTTSAudioPath && [gSLTTSAudioPath isEqualToString:armed]) {
                        gSLTTSAudioPath = nil;
                        gSLTTSAudioDur = 0;
                        gSLTTSPCM16k = nil;
                        gSLTTSPCM16kDur = 0;
                    }
                    SLLog(@"tts audition cancelled, disarmed");
                }
                                                 onRetry:^{
                    SLLog(@"tts audition retry");
                    SLArmTTS(nil, content, fallback);
                }];
            } else {
                [AWECAUtils showToast:[NSString stringWithFormat:@"已就绪 · 现在录音发送 AI 语音（%.1fs）", dur]
                             duration:2.0];
                startDisarmTimer();
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

    // v0.4.37.5：yyb = 直接发语音包，不联网合成
    if (SLHasPrefixCommand(text, SLPackCommand())) {
        if (!SLClaimText(text)) {
            SLLog(@"sendText yyb duplicate ignored");
            return;
        }
        SLLog(@"yyb hit via %@ -sendText", NSStringFromClass([self class]));
        if (SLArmPackNow()) SLClearTextInView(tv);
        return;
    }

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
        // v0.4.37：小宇宙私聊的发送器 MDChatUniverseHandler 不在输入栏响应链上，
        // 老逻辑会误判「没找到语音发送入口」→ 退回文字，于是私聊口令完全没反应。
        // 实际替换由全局编码器接管（MDAudioStreamBus → MDOpusEncoder），SLArmTTS 不使用
        // handler 实参（只用来判空），所以这里对小宇宙输入栏直接装填，不再退回文字。
        Class ub = NSClassFromString(@"MDChatUniverseInputBar");
        Class uh = NSClassFromString(@"MDChatUniverseHandler");
        if (ub && uh && [self isKindOfClass:ub]) {
            SLLog(@"Universe 输入栏：响应链未命中 handler，但仍装填（录音由全局编码器接管替换）");
            SLArmTTS(self, content, ^{ if (orig) orig(self, _cmd); });
            SLClearTextInView(tv);
            return;
        }
        SLLog(@"no audio handler near input bar -> fallback to text");
        // v0.4.37：不再静默退回文本，给个可见提示。
        [AWECAUtils showToast:@"没找到语音发送入口，这条按文字发了" duration:2.0];
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

    if (!SLIsEnabled()) {
        if (orig) orig(self, _cmd, arg);
        return;
    }
    // v0.4.37.5：yyb = 直接发语音包
    if (SLHasPrefixCommand(text, SLPackCommand())) {
        if (!SLClaimText(text)) return;
        SLLog(@"yyb hit via %@ -sendTextMessage:", NSStringFromClass([self class]));
        if (SLArmPackNow()) SLClearInputBars();
        return;
    }
    if (!SLTextHasCommand(text)) {
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

    if (!SLIsEnabled()) {
        if (orig) orig(self, _cmd, text, targetID, isSingle);
        return;
    }
    // v0.4.37.5：yyb = 直接发语音包
    if (SLHasPrefixCommand(str, SLPackCommand())) {
        if (!SLClaimText(str)) return;
        SLLog(@"yyb hit via MMCommonServiceImpl");
        if (SLArmPackNow()) SLClearInputBars();
        return;
    }
    if (!SLTextHasCommand(str)) {
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

#pragma mark - 钩子 3.5：MDAudioStreamBus 的 PCM 流接管（v0.4.37 核心）

// 陌陌录音链路：MDAudioRecorder → MDAudioStreamBus
//   -sendPcmPrepareWithASBD:（开场）→ -sendPcm:byteSize:（逐块喂 PCM）→ -sendPcmOver（收尾）
//   → MDOpusEncoder → Ogg Opus 文件（Library/Application Support/Chat_Audios_Temp/<token>.opus）
//
// 为什么不在外面自己造 .opus：陌陌语音是 Ogg Opus，AMR 写进去对端解码失败 = 0 秒空语音；
// 而 v0.4.37 试过直接 alloc 陌陌的 MDAudioStreamBus 来自编码，会在 init 阶段闪退
// （它依赖陌陌内部才有的 opus 配置）。所以改成接管「陌陌自己正在用的这条流」：
// 编码器、容器、页结构全部由陌陌自己产出，我们只把 PCM 换成 AI 语音。
// AI 语音喂完就把后续的块全吞掉，等陌陌自己 sendPcmOver 收尾 ——
// 文件时长正好是 AI 语音时长，不需要截断、也不需要补静音。

// 取一块要喂给 bus 的数据：null 表示「AI 语音已喂完，这一块要吞掉」
static NSData *SLBusNextChunk(NSUInteger size) {
    if (!gSLBusActive || gSLBusPCM.length == 0 || size == 0) return nil;
    if (gSLBusOffset >= gSLBusPCM.length) return nil;
    NSUInteger n = MIN(size, gSLBusPCM.length - gSLBusOffset);
    NSMutableData *d = [NSMutableData dataWithLength:size];   // 尾部补零，保持帧对齐
    memcpy(d.mutableBytes, (const char *)gSLBusPCM.bytes + gSLBusOffset, n);
    gSLBusOffset += n;
    gSLBusFed = YES;
    return d;
}

// 为什么要补：喂料节奏是「录音来一块、我换一块」，用户 1 秒就松手的话只剩 1 秒的量，
// 剩下的 AI 语音永远发不出去 → 对端听到的语音被截断。
// v0.4.37：补喂点改到 -stopRecord（主线程、收尾链路之前），并且走总线自己的
// sendPcm:byteSize: —— 就是录音时一直在用的那条公开入口，编码器/文件都还是正常态。
// v0.4.37/0.4.37 在 sendPcmOver 里直接同步调 encodePcm: 会卡死：那时已在收尾态，
// 编码器锁/文件句柄被占，日志停在「PCM-OVER 开始」、后面一条都出不来，最后被看门狗杀掉。
// 实际喂进编码器的时长（秒）：补喂没成功时用它，保证气泡和音频一致
static double SLFedDuration(void) {
    if (gSLArmRate <= 0 || gSLArmCh == 0 || gSLBusPCM.length == 0) return 0;
    double bps = gSLArmRate * (double)gSLArmCh * 2.0;   // 16bit
    if (bps <= 0) return 0;
    double d = (double)gSLBusOffset / bps;
    if (d > gSLTTSAudioDur) d = gSLTTSAudioDur;
    return d;
}

static BOOL SLFillShortEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kSLFillShortKey] == nil) return YES;
    return [d boolForKey:kSLFillShortKey];
}

static void SLDrainRemainingPCM(NSString *why) {
    if (!gSLBusActive || !gSLBusPCM.length) return;
    if (gSLBusOffset >= gSLBusPCM.length) return;
    if (!gSLBusFed) return;              // 一块都没喂过 = 还没真正接管
    if (gSLDrained) return;
    if (!SLFillShortEnabled()) {
        SLLog(@"PCM-OVER 跳过：短录音补全已关闭（只发录到的那一段）");
        return;
    }
    gSLDrained = YES;

    id bus = gSLBusRef;
    SEL feed = NSSelectorFromString(@"sendPcm:byteSize:");
    BOOL ok = (bus != nil && [bus respondsToSelector:feed]);
    NSUInteger chunk = gSLBusChunkSize;
    if (chunk < 320 || chunk > 32768) chunk = 3200;   // 兜底 100ms@16k/mono/s16
    SLLog(@"PCM-OVER 开始 why=%@ 剩余=%lu bus=%s chunk=%lu ok=%d",
          why ?: @"-", (unsigned long)(gSLBusPCM.length - gSLBusOffset),
          bus ? object_getClassName(bus) : "(nil)", (unsigned long)chunk, ok);
    if (!ok) {
        SLLog(@"PCM-OVER 跳过补喂：总线不响应 %@", NSStringFromSelector(feed));
        return;
    }

    static BOOL draining = NO;
    if (draining) return;
    draining = YES;
    NSUInteger total = 0;
    NSUInteger cap = 320000;   // 单次最多补 10 秒
    int blocks = 0;
    while (gSLBusOffset < gSLBusPCM.length && blocks < 8000 && total < cap) {
        NSData *d = SLBusNextChunk(chunk);
        if (!d) break;
        // 先记账再喂：总线内部可能是异步编码，钩子要按字节数原样放行
        gSLForcePassBytes += d.length;
        ((void (*)(id, SEL, void *, unsigned int))objc_msgSend)(bus, feed, (void *)d.bytes, (unsigned int)d.length);
        total += d.length;
        blocks++;
    }
    SLLog(@"PCM-OVER 补喂 %lu 字节 / %d 块（chunk=%lu why=%@）",
          (unsigned long)total, blocks, (unsigned long)chunk, why ?: @"-");
    draining = NO;
}

static void SLBusArmWithASBD(id bus, AudioStreamBasicDescription asbd) {
    if (!bus) return;
    if (!SLIsEnabled()) return;
    // v0.4.37：先处理「自动装载」。开关关掉后把上一次的残留清掉，
    // 免得关了开关下一句语音还是被替换。
    if (gSLAutoArmed && ![SLVoicePack isAutoReplaceEnabled]) {
        SLLog(@"AUTO-PACK 开关已关，丢弃残留装载");
        SLResetArmedAudio();
    }
    // 没有口令 / 合成装填时，看当前选中的语音包能不能直接用
    if (!gSLTTSAudioPath && !SLArmPackAutoQuiet()) return;
    if (gSLTTSPCM16k.length == 0) { SLLog(@"BUS-PREP 没有 AI PCM，本次不接管"); return; }
    if (asbd.mFormatID != kAudioFormatLinearPCM || asbd.mBitsPerChannel != 16) {
        SLLog(@"BUS-PREP 跳过：非 16bit PCM fmt=%u bits=%u",
              (unsigned)asbd.mFormatID, (unsigned)asbd.mBitsPerChannel);
        return;
    }
    gSLBusPCM = [SLPCMTool convertPCM16kMono:gSLTTSPCM16k
                                      toRate:asbd.mSampleRate
                                    channels:asbd.mChannelsPerFrame];
    gSLBusOffset = 0;
    gSLBusFed = NO;
    gSLBusSwallowLog = 0;
    gSLBusRef = bus;
    gSLBusActive = YES;
    gSLPcmArmed = YES;
    gSLArmRate = asbd.mSampleRate;
    gSLArmCh = asbd.mChannelsPerFrame;
    gSLBusChunkSize = 0;
    gSLDrained = NO;
    NSString *opusPath = nil;
    @try { opusPath = [bus valueForKey:@"opusFilePath"]; } @catch (NSException *e) {}
    SLLog(@"BUS-PREP rate=%.0f ch=%u bits=%u aiPcm=%lu feedBytes=%lu opus=%@（开始接管 PCM 流）",
          asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame, (unsigned)asbd.mBitsPerChannel,
          (unsigned long)gSLTTSPCM16k.length, (unsigned long)gSLBusPCM.length, opusPath ?: @"(nil)");
}

// sendPcmPrepareWithASBD: 结构体按值传
static void SLPcmPrepareByValue(id self, SEL _cmd, AudioStreamBasicDescription asbd) {
    void (*orig)(id, SEL, AudioStreamBasicDescription) =
        (void (*)(id, SEL, AudioStreamBasicDescription))SLGetOrigIMP(self, _cmd);
    if (orig) orig(self, _cmd, asbd);
    @try { SLBusArmWithASBD(self, asbd); } @catch (NSException *e) { SLLog(@"BUS-PREP 异常 %@", e); }
}

// sendPcmPrepareWithASBD: 结构体按指针传（兜底）
static void SLPcmPrepareByPointer(id self, SEL _cmd, AudioStreamBasicDescription *asbd) {
    void (*orig)(id, SEL, AudioStreamBasicDescription *) =
        (void (*)(id, SEL, AudioStreamBasicDescription *))SLGetOrigIMP(self, _cmd);
    if (orig) orig(self, _cmd, asbd);
    if (!asbd) return;
    @try { SLBusArmWithASBD(self, *asbd); } @catch (NSException *e) { SLLog(@"BUS-PREP 异常 %@", e); }
}

// sendPcm:byteSize: —— 参数是 NSData*
static void SLPcmFeedObjC(id self, SEL _cmd, id data, unsigned long long size) {
    void (*orig)(id, SEL, id, unsigned long long) =
        (void (*)(id, SEL, id, unsigned long long))SLGetOrigIMP(self, _cmd);
    if (gSLBusActive && (gSLBusRef == nil || self == gSLBusRef)) {
        if (size > 0) gSLBusChunkSize = (NSUInteger)size;
        NSData *d = SLBusNextChunk((NSUInteger)size);
        if (!d) {
            if (gSLBusSwallowLog++ < 3) SLLog(@"BUS-FEED AI 语音已喂完，吞掉后续 %llu 字节", size);
            return;
        }
        if (orig) orig(self, _cmd, d, (unsigned long long)d.length);
        return;
    }
    if (orig) orig(self, _cmd, data, size);
}

// sendPcm:byteSize: —— 参数是裸指针
static void SLPcmFeedRaw(id self, SEL _cmd, void *data, unsigned long long size) {
    void (*orig)(id, SEL, void *, unsigned long long) =
        (void (*)(id, SEL, void *, unsigned long long))SLGetOrigIMP(self, _cmd);
    if (gSLBusActive && (gSLBusRef == nil || self == gSLBusRef)) {
        if (size > 0) gSLBusChunkSize = (NSUInteger)size;
        NSData *d = SLBusNextChunk((NSUInteger)size);
        if (!d) {
            if (gSLBusSwallowLog++ < 3) SLLog(@"BUS-FEED AI 语音已喂完，吞掉后续 %llu 字节", size);
            return;
        }
        if (orig) orig(self, _cmd, (void *)d.bytes, (unsigned long long)d.length);
        return;
    }
    if (orig) orig(self, _cmd, data, size);
}

// 注意：这里**不要**再补 uint32（'I'）分支。
// sendPcm:byteSize: 内部会调用 MDOpusEncoder encodePcm:，而那一层已经由 SLEncodePcmDataHook 做替换了。
// 两层同时接管 = 同一块录音被换两次，每块消耗两块 AI 数据，音素被跳读 → 发出去是乱码噪音
//（v0.4.37.7 就是这样坏掉的）。只保留编码器单层替换。

static NSMethodSignature *SLSigOf(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return nil;
    const char *t = method_getTypeEncoding(m);
    if (!t) return nil;
    @try { return [NSMethodSignature signatureWithObjCTypes:t]; } @catch (NSException *e) { return nil; }
}

// v0.4.37：收尾点补喂 —— 在「关文件 / 收尾」前把 AI 语音剩下的部分喂完。
// 不同版本陌陌收尾选择子不完全一样，所以按名单探测（只钩无参方法）：
//   sendPcmOver / close / closeFile / finish / flush / stop / end / over
// 补喂只会发生一次，且必须已经喂过至少一块（否则说明还没真正接管）。
// v0.4.37：这里只直通，绝对不喂数据（收尾态调编码器必卡死）
static void SLDrainThenOrigHook(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))SLGetOrigIMP(self, _cmd);
    if (gSLBusActive && (gSLBusRef == nil || self == gSLBusRef)) {
        SLLog(@"PCM-OVER pass-through %@ drained=%d fed=%lu/%lu",
              NSStringFromSelector(_cmd), (int)gSLDrained,
              (unsigned long)gSLBusOffset, (unsigned long)gSLBusPCM.length);
    }
    if (orig) orig(self, _cmd);
}

// v0.4.37：补喂入口 —— 录音机停止时（主线程、收尾之前）
static void SLStopRecordHook(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))SLGetOrigIMP(self, _cmd);
    @try { SLDrainRemainingPCM(NSStringFromSelector(_cmd)); } @catch (NSException *e) {
        SLLog(@"PCM-OVER 异常 %@", e);
    }
    if (orig) orig(self, _cmd);
}

static void SLInstallStopRecordHook(Class cls) {
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"stopRecord");
    NSMethodSignature *sig = SLSigOf(cls, sel);
    if (!sig || sig.numberOfArguments != 2) return;
    if (SLRegisterMethod(cls, sel, (IMP)SLStopRecordHook)) {
        SLLog(@"DRAIN-HOOK %s -> stopRecord", class_getName(cls));
    }
}

static void SLInstallDrainHooksOnClass(Class cls) {
    if (!cls) return;
    if (!gSLDrainHooked) gSLDrainHooked = [NSMutableSet set];
    NSString *key = [NSString stringWithUTF8String:class_getName(cls)];
    if ([gSLDrainHooked containsObject:key]) return;
    [gSLDrainHooked addObject:key];
    NSArray *names = @[@"sendPcmOver", @"closeFile", @"close", @"finish", @"over", @"stop", @"end"];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *n in names) {
        SEL sel = NSSelectorFromString(n);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        NSMethodSignature *sig = SLSigOf(cls, sel);
        if (!sig || sig.numberOfArguments != 2) continue;          // 只钩无参的
        if (method_getImplementation(m) == (IMP)SLDrainThenOrigHook) continue;
        if (SLRegisterMethod(cls, sel, (IMP)SLDrainThenOrigHook)) [hits addObject:n];
    }
    if (hits.count) {
        SLLog(@"DRAIN-HOOK %s -> %@", class_getName(cls), [hits componentsJoinedByString:@" "]);
    }
}

static BOOL SLInstallBusPCMHooks(void) {
    Class cls = NSClassFromString(@"MDAudioStreamBus");
    if (!cls) { SLLog(@"BUS 没有 MDAudioStreamBus 类"); return NO; }

    static int dumped = 0;
    if (dumped++ < 1) {
        NSMutableArray *names = [NSMutableArray array];
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        for (unsigned i = 0; i < mc && names.count < 120; i++) {
            [names addObject:NSStringFromSelector(method_getName(ms[i]))];
        }
        if (ms) free(ms);
        SLLog(@"BUS-METHODS %@", [names componentsJoinedByString:@" "]);
    }

    // ① sendPcmPrepareWithASBD:
    SEL prep = NSSelectorFromString(@"sendPcmPrepareWithASBD:");
    NSMethodSignature *psig = SLSigOf(cls, prep);
    if (psig) {
        const char *a2 = psig.numberOfArguments > 2 ? [psig getArgumentTypeAtIndex:2] : NULL;
        SLLog(@"BUS sig prep arg2=%s", a2 ?: "(null)");
        if (a2 && a2[0] == '{') SLRegisterMethod(cls, prep, (IMP)SLPcmPrepareByValue);
        else if (a2 && a2[0] == '^') SLRegisterMethod(cls, prep, (IMP)SLPcmPrepareByPointer);
        else SLLog(@"BUS prep 参数类型不认识，不装");
    } else {
        SLLog(@"BUS 没有 sendPcmPrepareWithASBD:");
    }

    // ② sendPcm:byteSize:
    SEL feed = NSSelectorFromString(@"sendPcm:byteSize:");
    NSMethodSignature *fsig = SLSigOf(cls, feed);
    if (fsig) {
        const char *a2 = fsig.numberOfArguments > 2 ? [fsig getArgumentTypeAtIndex:2] : NULL;
        const char *a3 = fsig.numberOfArguments > 3 ? [fsig getArgumentTypeAtIndex:3] : NULL;
        SLLog(@"BUS sig feed arg2=%s arg3=%s", a2 ?: "(null)", a3 ?: "(null)");
        if (a2 && a2[0] == '@' && a3 && a3[0] == 'Q') SLRegisterMethod(cls, feed, (IMP)SLPcmFeedObjC);
        else if (a2 && a2[0] == '^' && a3 && a3[0] == 'Q') SLRegisterMethod(cls, feed, (IMP)SLPcmFeedRaw);
        // 'I'（uint32）故意不装：会和编码器钩子重复替换，见上方注释
        else SLLog(@"BUS feed 参数类型 %s/%s，不装（编码器层已接管）", a2 ?: "?", a3 ?: "?");
    } else {
        SLLog(@"BUS 没有 sendPcm:byteSize:");
    }

    // ③ 收尾点（sendPcmOver 等）：在这里补喂剩余 AI 语音，否则录音短于 AI 语音就被截断
    SLInstallDrainHooksOnClass(cls);
    return YES;
}

#pragma mark - 钩子 3.6：通用 PCM 漏斗接管（v0.4.37）

// 为什么要再加一层：
// v0.4.37 只钩了 MDAudioStreamBus 的 sendPcm*，但如果聊天语音实际上不走这个对象
// （或被包装成别的类），钩子就永远不触发 —— 表现出来就是「一点没变，还是原声」。
// 而不管中间绕多少层，语音最终一定要经过 MDOpusEncoder -encodePcm: 才会变成 opus。
// 所以这里在「编码器入口」再兜一层：谁把 PCM 递给编码器，就在那一刻换成 AI 语音。
// 编码器、容器、页结构仍然全部由陌陌自己产出，格式一定正确。

static BOOL SLReadASBDValue(id obj, AudioStreamBasicDescription *out) {
    if (!obj || !out) return NO;
    memset(out, 0, sizeof(*out));
    @try {
        id v = nil;
        @try { v = [obj valueForKey:@"asbd"]; } @catch (NSException *e) { v = nil; }
        if ([v isKindOfClass:[NSValue class]]) {
            NSValue *vv = (NSValue *)v;
            const char *t = [vv objCType];
            if (t && t[0] == '{' && strlen(t) > 24) {
                [vv getValue:out size:sizeof(*out)];
                return YES;
            }
        }
    } @catch (NSException *e) {}
    @try {
        Ivar iv = class_getInstanceVariable([obj class], "asbd");
        if (!iv) iv = class_getInstanceVariable([obj class], "_asbd");
        if (iv) {
            const char *t = ivar_getTypeEncoding(iv);
            if (t && t[0] == '{' && strlen(t) > 24) {
                memcpy(out, (char *)(__bridge void *)obj + ivar_getOffset(iv), sizeof(*out));
                return YES;
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

static BOOL SLFeedArm(id obj, AudioStreamBasicDescription asbd, NSString *tag) {
    if (!SLIsEnabled() || !gSLTTSAudioPath) return NO;
    if (gSLTTSPCM16k.length == 0) return NO;
    if (asbd.mFormatID != kAudioFormatLinearPCM || asbd.mBitsPerChannel != 16) {
        if (gSLFunnelLog++ < 4) {
            SLLog(@"PCM-ARM %@ 跳过：fmt=%u bits=%u", tag,
                  (unsigned)asbd.mFormatID, (unsigned)asbd.mBitsPerChannel);
        }
        return NO;
    }
    // 已经按同格式接管过就别重来（重来会把已喂进度清零 → AI 语音从头再说一遍）
    if (gSLPcmArmed && gSLBusPCM.length > 0 &&
        fabs(asbd.mSampleRate - gSLArmRate) < 1.0 && asbd.mChannelsPerFrame == gSLArmCh) {
        return YES;
    }
    NSData *pcm = [SLPCMTool convertPCM16kMono:gSLTTSPCM16k
                                        toRate:asbd.mSampleRate
                                      channels:asbd.mChannelsPerFrame];
    if (pcm.length == 0) return NO;
    gSLBusPCM = pcm;
    gSLBusOffset = 0;
    gSLBusFed = NO;
    gSLBusSwallowLog = 0;
    gSLBusActive = YES;
    gSLBusRef = obj;
    gSLPcmArmed = YES;
    gSLArmRate = asbd.mSampleRate;
    gSLArmCh = asbd.mChannelsPerFrame;
    gSLBusChunkSize = 0;
    gSLDrained = NO;
    SLInstallDrainHooksOnClass([obj class]);
    SLLog(@"PCM-ARM %@ rate=%.0f ch=%u bits=%u aiPcm=%lu feed=%lu（开始接管）",
          tag, asbd.mSampleRate, (unsigned)asbd.mChannelsPerFrame,
          (unsigned)asbd.mBitsPerChannel, (unsigned long)gSLTTSPCM16k.length,
          (unsigned long)pcm.length);
    return YES;
}

// MDOpusEncoder -encodePcm:（参数 NSData*）
static void SLEncodePcmDataHook(id self, SEL _cmd, id data) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))SLGetOrigIMP(self, _cmd);
    // 我们自己补喂的字节：原样放行，否则会被再换一遍变成无限套
    if (gSLForcePassBytes > 0 && [data isKindOfClass:[NSData class]]) {
        NSUInteger n = [data length];
        gSLForcePassBytes = (n >= gSLForcePassBytes) ? 0 : (gSLForcePassBytes - n);
        if (orig) orig(self, _cmd, data);
        return;
    }
    BOOL handled = NO;
    if (SLIsEnabled() && gSLTTSAudioPath && [data isKindOfClass:[NSData class]] && [data length] > 0) {
        AudioStreamBasicDescription a;
        BOOL gotASBD = SLReadASBDValue(self, &a);
        if (!gotASBD) {
            // 读不到就按陌陌录音机的默认格式兜底（Recorder 的 _sampleRate 就是 16000 单声道 16bit）
            memset(&a, 0, sizeof(a));
            a.mSampleRate = 16000.0;
            a.mFormatID = kAudioFormatLinearPCM;
            a.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            a.mBitsPerChannel = 16;
            a.mChannelsPerFrame = 1;
            a.mBytesPerFrame = 2;
            a.mBytesPerPacket = 2;
            a.mFramesPerPacket = 1;
            if (gSLFunnelLog++ < 3) SLLog(@"ENC asbd 读不到，按 16k/mono/s16 兜底");
        }
        {
            SLFeedArm(self, a, @"MDOpusEncoder.encodePcm");
            if (gSLBusActive) {
                if ([data length] > 0) gSLBusChunkSize = [data length];
                NSData *chunk = SLBusNextChunk([data length]);
                if (chunk) {
                    if (orig) orig(self, _cmd, chunk);
                } else if (gSLBusSwallowLog++ < 3) {
                    SLLog(@"PCM-FEED 编码器：AI 语音已喂完，丢弃后续 %lu 字节",
                          (unsigned long)[data length]);
                }
                handled = YES;
            }
        }
    }
    if (!handled && orig) orig(self, _cmd, data);
}

// 给任意「录音总线类」装 PCM 钩子：凡是方法名带 pcm、且形如 xxx:byteSize: 的都接管
static void SLInstallPcmHooksOnClass(Class cls) {
    if (!cls) return;
    if (!gSLHookedSels) gSLHookedSels = [NSMutableSet set];
    unsigned int mc = 0;
    Method *ms = class_copyMethodList(cls, &mc);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned i = 0; i < mc; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *sn = NSStringFromSelector(sel);
        if ([sn rangeOfString:@"pcm" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSMethodSignature *sig = nil;
        @try {
            const char *t = method_getTypeEncoding(ms[i]);
            if (t) sig = [NSMethodSignature signatureWithObjCTypes:t];
        } @catch (NSException *e) { sig = nil; }
        if (!sig || sig.numberOfArguments < 4) continue;
        const char *a2 = [sig getArgumentTypeAtIndex:2];
        const char *a3 = [sig getArgumentTypeAtIndex:3];
        if (!a2 || !a3 || a3[0] != 'Q') continue;
        IMP imp = NULL;
        if (a2[0] == '@') imp = (IMP)SLPcmFeedObjC;
        else if (a2[0] == '^') imp = (IMP)SLPcmFeedRaw;
        if (!imp) continue;
        NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
        if ([gSLHookedSels containsObject:key]) continue;
        [gSLHookedSels addObject:key];
        if (SLRegisterMethod(cls, sel, imp)) [hits addObject:sn];
    }
    if (ms) free(ms);
    if (hits.count) {
        SLLog(@"PCM-HOOK %s -> %@", class_getName(cls), [hits componentsJoinedByString:@" "]);
    }
}

// 录音机 addBus: —— 亲眼看看它到底把哪些对象塞进了 busArray
static void SLAddBusHook(id self, SEL _cmd, id bus) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))SLGetOrigIMP(self, _cmd);
    if (bus && gSLFunnelLog++ < 8) {
        SLLog(@"ADD-BUS %@ <- %@",
              NSStringFromClass([bus class]), NSStringFromClass([self class]));
        SLInstallPcmHooksOnClass([bus class]);
    }
    if (orig) orig(self, _cmd, bus);
}

static BOOL SLInstallFunnelHooks(void) {
    Class enc = NSClassFromString(@"MDOpusEncoder");
    if (enc) {
        Method m = class_getInstanceMethod(enc, NSSelectorFromString(@"encodePcm:"));
        if (m) {
            const char *t = method_getTypeEncoding(m);
            NSMethodSignature *sig = nil;
            @try { if (t) sig = [NSMethodSignature signatureWithObjCTypes:t]; } @catch (NSException *e) {}
            const char *a2 = (sig && sig.numberOfArguments > 2) ? [sig getArgumentTypeAtIndex:2] : NULL;
            SLLog(@"ENC sig encodePcm arg2=%s", a2 ?: "(null)");
            if (a2 && a2[0] == '@') {
                SLRegisterMethod(enc, NSSelectorFromString(@"encodePcm:"), (IMP)SLEncodePcmDataHook);
            } else {
                SLLog(@"ENC encodePcm: 参数不是对象，跳过（%s）", a2 ?: "(null)");
            }
        } else {
            SLLog(@"ENC 没有 encodePcm:");
        }
        // 编码器上的收尾点（不同版本叫法不一），用于补喂剩余 AI 语音
        SLInstallDrainHooksOnClass(enc);
    } else {
        SLLog(@"ENC 没有 MDOpusEncoder 类");
    }

    NSArray *names = @[@"MDAudioRecorder", @"MLAudioRecorder", @"MLVoiceMessageRecorder", @"Recorder"];
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        SLRegisterMethod(c, NSSelectorFromString(@"addBus:"), (IMP)SLAddBusHook);
        SLInstallStopRecordHook(c);
    }
    return YES;
}

#pragma mark - 钩子 4：MDChatBaseHander -sendAudioMessage:audioTime:audioFileSize:（诊断用，抓语音 model 结构）

// 注意：真实签名是 v40@0:8@16Q24Q32 —— audioTime / audioFileSize 都是 Q（unsigned long long）。
// v0.3.9 这里写成了 double，读的时候从 d0 取垃圾值、调 orig 时又把值塞进 d0/d1（orig 要 x2/x3），
// 结果陌陌拿到的时长/文件大小全被污染 → 这就是「语音条秒数乱」的真因（连原生录音也被改坏）。
static void SLSendAudioMessageHook(id self, SEL _cmd, id model, unsigned long long t, unsigned long long size) {
    void (*orig)(id, SEL, id, unsigned long long, unsigned long long) =
        (void (*)(id, SEL, id, unsigned long long, unsigned long long))SLGetOrigIMP(self, _cmd);
    unsigned long long newT = t;
    unsigned long long newSize = size;

    if (!gSLModelDump) {
        gSLModelDump = 1;
        SLDumpModelDeep(model);
    }

    // 发送前的最后一步（v0.4.37）：录音阶段已把陌陌的 PCM 流换成 AI 语音，
    // 这里只需要把时长（气泡秒数）改成 AI 语音的真实时长。
    // bus 没接管成功时绝不覆盖文件 —— 往 .opus 里写 AMR 只会得到「0 秒空语音」，比原声更糟。
    if (gSLTTSAudioPath) {
        @try {
            NSString *body = nil;
            @try { body = [model valueForKey:@"body"]; } @catch (NSException *e) {}
            if (![body isKindOfClass:[NSString class]] || body.length == 0) body = nil;
            NSString *token = SLBodyValue(body, @"file");
            SLLog(@"AUDIO-SEND model=%@ t=%llu size=%llu token=%@ busFed=%d busOn=%d aiDur=%.2f",
                  NSStringFromClass([model class]), t, size, token ?: @"(nil)",
                  (int)gSLBusFed, (int)gSLBusActive, gSLTTSAudioDur);

            if (gSLBusFed) {
                // 文件内容已由陌陌自己的编码器写成 AI 语音 → 只改 audiotime / audioTime
                // 两个值都用 0.1 秒为单位（和陌陌 body 里的 audiotime 一致）
                double useDur = SLFedDuration();
                if (useDur < 0.05) useDur = gSLTTSAudioDur;
                SLLog(@"AUDIO-SEND 实际喂入 %.2f 秒（AI 全长 %.2f 秒）", useDur, gSLTTSAudioDur);
                if (useDur > 0.05) {
                    long long tenths = (long long)llround(useDur * 10.0);
                    if (tenths < 1) tenths = 1;
                    newT = (unsigned long long)tenths;
                    if (body) {
                        NSString *nb = SLBodySetAudioTime(body, useDur);
                        BOOL set = NO;
                        SEL bs = NSSelectorFromString(@"setBody:");
                        if ([model respondsToSelector:bs]) {
                            @try { ((void(*)(id,SEL,id))objc_msgSend)(model, bs, nb); set = YES; } @catch (NSException *e) {}
                        }
                        if (!set) { @try { [model setValue:nb forKey:@"body"]; set = YES; } @catch (NSException *e) {} }
                        SLLog(@"AUDIO-SEND body audiotime -> %lld（=%.2f 秒）set=%d (%@)", tenths, useDur, set,
                              nb.length > 160 ? [nb substringToIndex:160] : nb);
                    }
                    SLLog(@"AUDIO-SEND bus 已接管，时长 %llu（0.1 秒单位）= %.2f 秒，原 t=%llu", newT, useDur, t);
                }
                // 只做诊断：补喂后文件真实字节数 vs 陌陌原始 size 参数
                NSString *fp = token.length ? SLFindFileByToken(token) : nil;
                if (fp) {
                    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:fp error:nil];
                    SLLog(@"AUDIO-SEND fileBytes=%llu sizeParam=%llu file=%@",
                          (unsigned long long)[at fileSize], size, fp.lastPathComponent);
                }
                [AWECAUtils showToast:(gSLAutoPackName.length
                                       ? [NSString stringWithFormat:@"已发送语音包 · %@", gSLAutoPackName]
                                       : @"已发送 AI 语音")
                             duration:1.5];
            } else {
                SLLog(@"AUDIO-SEND bus 未接管（BUS-PREP 没触发？）——本次不覆盖，避免 0 秒空语音");
                NSString *target = token.length ? SLFindFileByToken(token) : nil;
                if (target) {
                    SLLog(@"AUDIO-SEND 目标文件 ext=%@ magic=%@，跳过覆盖",
                          [target pathExtension], SLMagicAtPath(target));
                }
            }
            gSLTTSAudioPath = nil;
            gSLBusActive = NO;
            gSLBusRef = nil;
            gSLBusPCM = nil;
            gSLBusOffset = 0;
            gSLBusFed = NO;
            gSLPcmArmed = NO;
            gSLArmRate = 0;
            gSLArmCh = 0;
            gSLBusChunkSize = 0;
            gSLDrained = NO;
            gSLAutoArmed = NO;
            gSLAutoPackName = nil;
            SLFloatSetState(SLFloatStateIdle);
        } @catch (NSException *e) {
            SLLog(@"AUDIO-SEND exception %@", e);
        }
    }

    if (orig) orig(self, _cmd, model, newT, newSize);
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

#pragma mark - 钩子 4.5：MDAudioRecorder -setTempAudioPath:（捕获录音临时文件路径）

// 回调那一刻 _tempAudioPath 已被置 nil，但录音开始时它一定被赋过值。
// 钩住 setter 就能拿到「这次录音写到哪个文件/哪个目录」，比事后瞎猜可靠。
static void SLSetTempAudioPathHook(id self, SEL _cmd, NSString *p) {
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))SLGetOrigIMP(self, _cmd);
    if ([p isKindOfClass:[NSString class]] && p.length) {
        gSLTempRecPath = [p copy];
        SLLog(@"TEMP-PATH set %@", p);
        SLFloatSetState(SLFloatStateRecording);   // v0.4.37：球变红 = 正在录
    } else {
        BOOL ex = NO;
        long long sz = -1;
        if (gSLTempRecPath.length) {
            ex = [[NSFileManager defaultManager] fileExistsAtPath:gSLTempRecPath];
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:gSLTempRecPath error:nil];
            sz = (long long)[a fileSize];
        }
        SLLog(@"TEMP-PATH cleared (prev=%@ exists=%d size=%lld)", gSLTempRecPath ?: @"(nil)", ex, sz);
        // v0.4.37：如果这次要替换（AI 已合成好 / 语音包已装载），录音收尾直接进「就绪」并一直亮着，
        // 等发送完成那一刻才回空闲；没有可替换的内容才回空闲。
        SLFloatSetState(gSLTTSAudioPath.length ? SLFloatStateReady : SLFloatStateIdle);
    }
    if (orig) orig(self, _cmd, p);
}

static BOOL SLInstallTempPathHook(Class cls) {
    if (!cls) return NO;
    SEL sel = @selector(setTempAudioPath:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        SLLog(@"%@ 没有 setTempAudioPath:", NSStringFromClass(cls));
        return NO;
    }
    const char *t = method_getTypeEncoding(m);
    NSMethodSignature *sig = t ? [NSMethodSignature signatureWithObjCTypes:t] : nil;
    if (!sig || sig.numberOfArguments < 3) return NO;
    const char *a2 = [sig getArgumentTypeAtIndex:2];
    if (!a2 || a2[0] != '@') return NO;
    return SLRegisterMethod(cls, sel, (IMP)SLSetTempAudioPathHook);
}

#pragma mark - 钩子 5：audioRecorder:recordSucessStoreAt:audioTime:（覆盖陌陌即将发送的录音文件为合成音）

static void SLAudioRecordDoneHook(id self, SEL _cmd, id recorder, NSString *path, unsigned long long time) {
    void (*orig)(id, SEL, id, id, unsigned long long) = (void (*)(id, SEL, id, id, unsigned long long))SLGetOrigIMP(self, _cmd);
    unsigned long long newTime = time;

    if (gSLRecDump < 3) {
        gSLRecDump++;
        SLLog(@"REC-DONE self=%@ recorderClass=%@ pathArg=%@ timeRaw=%llu armed=%d tempPath=%@",
              NSStringFromClass([self class]),
              recorder ? NSStringFromClass([recorder class]) : @"(nil)", path, time,
              gSLTTSAudioPath ? 1 : 0, gSLTempRecPath ?: @"(nil)");
        if (recorder) SLDumpRecorderDeep(recorder);
        SLDumpSelfIvars(self);
    }
    if (gSLMethDump < 1 && recorder) {
        gSLMethDump = 1;
        SLDumpMethodNames(recorder);
    }

    // v0.4.37：这里不再覆盖文件。
    // 录音过程中陌陌自己的编码器已经把 AI 语音写进 .opus（见 SLPcmFeedObjC），
    // 此刻再往 .opus 里写 AMR 反而会把刚生成的好文件毁掉（= 0 秒空语音）。
    // 只剩诊断：录音结束后 bus 是否真的接管过。
    if (gSLTTSAudioPath) {
        SLLog(@"REC-DONE busFed=%d busOn=%d aiDur=%.2f timeRaw=%llu pathArg=%@",
              (int)gSLBusFed, (int)gSLBusActive, gSLTTSAudioDur, time, path ?: @"(nil)");
        if (!gSLBusFed) {
            NSTimeInterval armedAt = gSLArmedAt > 0 ? gSLArmedAt
                                                    : ([[NSDate date] timeIntervalSince1970] - 300.0);
            if (gSLRecDump <= 3) SLLog(@"DIAG-RECENT %@", SLDiagRecentFiles(armedAt));
        }
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

#pragma mark - 虚拟定位（v0.4.37）

// 只在「开关开 + 已选点」时返回非 nil；返回 nil 就原样透传，对陌陌现状零影响。
static CLLocation *SLVirtualLocationNow(void) {
    @try {
        return [SLVirtualLocation fakeLocation];
    } @catch (NSException *e) {
        return nil;
    }
}

// 陌陌所有业务读坐标都过这个 getter（MomoLocationManager 的 location 属性）
static NSUInteger sSLMomoLocHits = 0;
static NSUInteger sSLCLLocHits = 0;

static CLLocation *SLMomoLocationGetHook(id self, SEL _cmd) {
    CLLocation *fake = SLVirtualLocationNow();
    if (fake) {
        // 每 200 次记一条：用来证明钩子确实被业务调用，而不是「装了但没人走」
        if (++sSLMomoLocHits % 200 == 1) SLLog(@"VLOC MomoLocationManager 取坐标第 %lu 次", (unsigned long)sSLMomoLocHits);
        return fake;
    }
    CLLocation *(*orig)(id, SEL) = (CLLocation *(*)(id, SEL))SLGetOrigIMP(self, _cmd);
    return orig ? orig(self, _cmd) : nil;
}

// 兜底：万一某模块自己 new 了一个 CLLocationManager 直接取位置，这层也拦住
static CLLocation *SLCLLocationGetHook(id self, SEL _cmd) {
    CLLocation *fake = SLVirtualLocationNow();
    if (fake) {
        if (++sSLCLLocHits % 200 == 1) SLLog(@"VLOC CLLocationManager 取坐标第 %lu 次", (unsigned long)sSLCLLocHits);
        return fake;
    }
    CLLocation *(*orig)(id, SEL) = (CLLocation *(*)(id, SEL))SLGetOrigIMP(self, _cmd);
    return orig ? orig(self, _cmd) : nil;
}

// 只打一次：把定位相关类的真实方法名全部写进日志。
// 离线解析方法表在陌陌这个包里不可靠（Swift 类没有 OC 方法表 / 相对方法列表编码特殊），
// 所以宁可运行时 dump 一次，下一轮改钩子就不用猜 selector 了。
static void SLDumpLocationClassesOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSArray<NSString *> *names = @[@"MomoLocationManager", @"MILLocationManager", @"MDLocation",
                                   @"MDLocationClient", @"IMJClientLocationManager", @"BUSDKLocation"];
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c) {
            SLLog(@"VLOC 无此 %@", n);
            continue;
        }
        unsigned int cnt = 0;
        Method *ms = class_copyMethodList(c, &cnt);
        NSMutableArray *out = [NSMutableArray array];
        for (unsigned int i = 0; i < cnt && i < 150; i++) {
            [out addObject:NSStringFromSelector(method_getName(ms[i]))];
        }
        if (ms) free(ms);
        SLLog(@"VLOC %@ 方法%u: %@", n, cnt, [out componentsJoinedByString:@" | "]);
    }
}

static void SLInstallVirtualLocationHooks(void) {
    SLDumpLocationClassesOnce();
    SLRegisterMethod(NSClassFromString(@"MomoLocationManager"), NSSelectorFromString(@"location"),
                     (IMP)SLMomoLocationGetHook);
    SLRegisterMethod([CLLocationManager class], NSSelectorFromString(@"location"),
                     (IMP)SLCLLocationGetHook);
    SLLog(@"VLOC 当前 %@", [SLVirtualLocation summary]);
}

// v0.4.37：音波发布后闪退的兜底。
// iOS 15 起，给「老式构造」的 UIButton（buttonWithType:）设 configurationUpdateHandler
// 会直接 NSAssert：Invalid parameter not satisfying: configuration != nil。
// 陌陌音波发布页在自己那套旧按钮上就是这么干的，所以一发布就闪退（栈里只有 MomoChat + UIKitCore）。
// 这里把这种情况拦下来：按钮没有 configuration 就忽略这次设置，其它情况原样透传。
static void SLSetConfigurationUpdateHandlerHook(id self, SEL _cmd, id handler) {
    @try {
        if (handler && [self isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)self;
            if (!b.configuration) {
                SLLog(@"UI-GUARD %@ 没有 configuration，忽略 setConfigurationUpdateHandler:（否则 UIKit 断言崩）",
                      NSStringFromClass([self class]));
                return;
            }
        }
    } @catch (NSException *e) {}
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))SLGetOrigIMP(self, _cmd);
    if (orig) orig(self, _cmd, handler);
}

static void SLInstallUIButtonGuard(void) {
    static BOOL done = NO;
    if (done) return;
    SEL sel = @selector(setConfigurationUpdateHandler:);
    Method m = class_getInstanceMethod([UIButton class], sel);
    if (!m) return;          // iOS < 15 没这个 API，不用兜底
    done = YES;
    if (SLRegisterMethod([UIButton class], sel, (IMP)SLSetConfigurationUpdateHandlerHook)) {
        SLLog(@"UI-GUARD 已装 UIButton setConfigurationUpdateHandler: 兜底");
    }
}

// v0.4.37：小宇宙私聊发口令时日志「零记录」—— 说明它的发送链完全不经过我们钩的
// sendText / sendTextMessage:。不再猜类名，直接钩事件分发：任何按钮点下去都会过
// -[UIApplication sendAction:to:from:forEvent:]，日志里就能看到真实的 target 类 + action 名。
// 只记录，不改变任何行为。
static void SLAppSendActionHook(id self, SEL _cmd, SEL action, id target, id sender, id event) {
    @try {
        static NSMutableSet *seen = nil;
        static int count = 0;
        if (!seen) seen = [NSMutableSet set];
        if (count < 400) {
            Class tc = target ? object_getClass(target) : Nil;
            NSString *key = [NSString stringWithFormat:@"%@#%@",
                             tc ? NSStringFromClass(tc) : @"nil",
                             action ? NSStringFromSelector(action) : @"?"];
            if (![seen containsObject:key]) {
                [seen addObject:key];
                count++;
                SLLog(@"ACTION %@ <- %@", key,
                      sender ? NSStringFromClass([sender class]) : @"nil");
            }
        }
    } @catch (NSException *e) {}
    void (*orig)(id, SEL, SEL, id, id, id) = (void (*)(id, SEL, SEL, id, id, id))SLGetOrigIMP(self, _cmd);
    if (orig) orig(self, _cmd, action, target, sender, event);
}

// 一次性普查：把类名带 Universe 的类连同它的 send*/Text/Input 方法全打出来。
// 目的只有一个 —— 知道小宇宙的输入栏/发送器到底叫什么，别再靠猜。
static void SLDumpUniverseClassesOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *buf = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!buf) return;
    n = objc_getClassList(buf, n);
    NSMutableArray *hits = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        const char *nm = class_getName(buf[i]);
        if (!nm) continue;
        NSString *cn = [NSString stringWithUTF8String:nm];
        if (![cn containsString:@"Universe"]) continue;
        NSMutableArray *sels = [NSMutableArray array];
        unsigned int c = 0;
        Method *ms = class_copyMethodList(buf[i], &c);
        for (unsigned int k = 0; k < c && k < 80; k++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[k]));
            if ([sn hasPrefix:@"send"] || [sn containsString:@"Text"] || [sn containsString:@"Input"]) {
                [sels addObject:sn];
            }
        }
        if (ms) free(ms);
        [hits addObject:sels.count ? [NSString stringWithFormat:@"%@{%@}", cn, [sels componentsJoinedByString:@","]]
                                   : cn];
    }
    free(buf);
    SLLog(@"CENSUS Universe 类 %lu 个：%@", (unsigned long)hits.count,
          [hits componentsJoinedByString:@" | "]);
}

static void SLInstallActionProbe(void) {
    SEL sel = NSSelectorFromString(@"sendAction:to:from:forEvent:");
    Method m = class_getInstanceMethod([UIApplication class], sel);
    if (!m) {
        SLLog(@"ACTION 探针没找到 UIApplication sendAction:to:from:forEvent:");
        return;
    }
    if (method_getNumberOfArguments(m) != 6) return;
    SLRegisterMethod([UIApplication class], sel, (IMP)SLAppSendActionHook);
}

// v0.4.37：小宇宙 sendContent: 正式接管（0.4.37 探针实测确认它就是私聊发送入口）。
// 坑：发送时刻拿到的条目对象，其 text 字段往往只剩「正文」，口令已被上层剥掉，
// 所以不能只读 text —— SLCommandTextIn 会把对象上的字符串字段全扫一遍，捞出带口令的那份。
static NSString *SLCommandTextIn(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) {
        return SLTextHasAnyCommand((NSString *)obj) ? (NSString *)obj : nil;
    }
    NSMutableArray *names = [NSMutableArray arrayWithObjects:
        @"text", @"textv2", @"originText", @"rawText", @"inputText",
        @"msgContent", @"messageText", @"body", nil];
    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList([obj class], &pc);
    for (unsigned int i = 0; i < pc; i++) {
        // 只认「声明为 NSString 的属性」。对 imageInfo/siteinfo 这类非字符串属性调 getter
        // 会踩 ABI（返回结构体时尤其致命），0.4.37 就是死在这里。
        const char *attrs = property_getAttributes(props[i]);
        if (!attrs || strncmp(attrs, "T@\"NSString\"", 12) != 0) continue;
        const char *nm = property_getName(props[i]);
        if (nm) [names addObject:[NSString stringWithUTF8String:nm]];
    }
    if (props) free(props);
    for (NSString *name in names) {
        NSString *v = SLStringGetter(obj, name);
        if (v.length && SLTextHasAnyCommand(v)) return v;
    }
    return nil;
}

// v0.4.37：小宇宙语音气泡秒数对齐。
// 小宇宙不发 sendAudioMessage:audioTime:audioFileSize:，发送时只给一个 MDSendContentItem，
// 秒数写在它的 audioSecs 上 —— 实测单位是 0.1 秒（和陌陌 body 里的 audiotime 一致）：
//   AI 2.24s + 录音尾巴 0.37s -> audioSecs=26（2.6 秒）；AI 0.94s + 0.32s -> 13（1.3 秒）
// 也就是说陌陌按「本次录音总共写进文件的时长」填，AI 语音比它短，气泡就偏长、和实际播放对不上。
// 这里改成 AI 真正喂进编码器的时长，跟普通聊天那条路径（AUDIO-SEND 改 audiotime）保持一致。
static BOOL SLUniverseFixAudioDuration(id item) {
    if (!item || !gSLTTSAudioPath || !gSLBusFed) return NO;
    // 只处理音频 content：没有 audioUUID 的（文本/图片/表情）直接跳过
    NSString *uuid = SLStringGetter(item, @"audioUUID");
    if (!uuid.length) return NO;

    SEL setSel = NSSelectorFromString(@"setAudioSecs:");
    if (![item respondsToSelector:setSel]) return NO;
    Method sm = class_getInstanceMethod([item class], setSel);
    if (!sm) return NO;

    double useDur = SLFedDuration();
    if (useDur < 0.05) useDur = gSLTTSAudioDur;
    if (useDur <= 0.05) return NO;
    long long tenths = (long long)llround(useDur * 10.0);   // 0.1 秒单位
    if (tenths < 1) tenths = 1;

    // 读旧值只做日志（类型不对就跳过，绝不错位调用 —— 0.4.37 就是踩在这上面崩的）
    unsigned long long oldSecs = 0;
    BOOL hasOld = NO;
    SEL getSel = NSSelectorFromString(@"audioSecs");
    if ([item respondsToSelector:getSel]) {
        Method gm = class_getInstanceMethod([item class], getSel);
        if (gm) {
            char rt[8] = {0};
            method_getReturnType(gm, rt, sizeof(rt));
            if (rt[0] == 'Q' || rt[0] == 'q' || rt[0] == 'I' || rt[0] == 'i') {
                @try {
                    oldSecs = ((unsigned long long (*)(id, SEL))objc_msgSend)(item, getSel);
                    hasOld = YES;
                } @catch (NSException *e) { }
            }
        }
    }

    // setter 的入参类型先确认：整数就直接传，对象就包成 NSNumber，其余一律不动
    char at[8] = {0};
    method_getArgumentType(sm, 2, at, sizeof(at));
    @try {
        if (at[0] == 'Q' || at[0] == 'q' || at[0] == 'I' || at[0] == 'i') {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(item, setSel, (unsigned long long)tenths);
        } else if (at[0] == '@') {
            ((void (*)(id, SEL, id))objc_msgSend)(item, setSel, @(tenths));
        } else {
            SLLog(@"UNIV-AUDIO audioSecs setter 类型 %s，跳过", at);
            return NO;
        }
    } @catch (NSException *e) {
        SLLog(@"UNIV-AUDIO 设置 audioSecs 异常 %@", e);
        return NO;
    }

    if (hasOld) {
        SLLog(@"UNIV-AUDIO audioSecs %llu -> %lld（AI 实际 %.2f 秒）uuid=%@",
              oldSecs, tenths, useDur, uuid);
    } else {
        SLLog(@"UNIV-AUDIO audioSecs -> %lld（AI 实际 %.2f 秒）uuid=%@",
              tenths, useDur, uuid);
    }
    return YES;
}

static void SLUniverseContentHook(id self, SEL _cmd, id arg) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))SLGetOrigIMP(self, _cmd);
    if (orig == NULL) return;

    if (!SLIsEnabled()) { orig(self, _cmd, arg); return; }

    // v0.4.37：语音消息（content 无文本、带 audioUUID）先把气泡秒数改成 AI 语音的真实时长。
    // 必须在「无文本直接透传」之前，否则永远走不到这里。
    SLUniverseFixAudioDuration(arg);

    NSString *shown = SLTextFromArgument(arg);
    // 音频 / 图片 / 表情这类 content 没有文本：立刻透传，绝不进字段扫描。
    // 小宇宙发语音时 arg 就是这种对象（text=nil），0.4.37 在这里扫属性扫崩了。
    if (!shown.length) { orig(self, _cmd, arg); return; }
    NSString *full = SLTextHasAnyCommand(shown) ? shown : SLCommandTextIn(arg);

    if (!SLIsEnabled() || !full.length) {
        static int quiet = 0;
        if (!full.length && shown.length && quiet < 20) {
            quiet++;
            SLLog(@"UNIV sendContent: 无口令，原样发送 text=%@", SLShorten(shown, 30));
        }
        orig(self, _cmd, arg);
        return;
    }

    // #yyb：直接发语音包，不联网合成
    if (SLHasPrefixCommand(full, SLPackCommand())) {
        if (!SLClaimText(full)) { SLLog(@"UNIV sendContent yyb duplicate ignored"); return; }
        SLLog(@"yyb hit via %@ -sendContent:", NSStringFromClass([self class]));
        if (SLArmPackNow()) SLClearInputBars();
        return;
    }
    if (!SLTextHasCommand(full)) { orig(self, _cmd, arg); return; }
    if (!SLClaimText(full)) { SLLog(@"UNIV sendContent duplicate ignored"); return; }

    NSString *content = SLTextAfterCommand(full);
    if (!content.length) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"用法：%@ 要转成语音的话", SLCommand()] duration:2.5];
        orig(self, _cmd, arg);
        return;
    }

    SLLog(@"#tts hit via %@ -sendContent:, text=%@", NSStringFromClass([self class]), SLShorten(full, 40));
    // 拦下文字、装填 AI 语音；只有合成失败才退回原样发送
    SLArmTTS(self, content, ^{ orig(self, _cmd, arg); });
    SLClearInputBars();
}

static void SLInstallHooks(void) {
    // v0.4.37：去掉「只装 3 轮」的硬上限。
    // 0.4.37 为了少刷日志把窗口从 6 轮/10 秒砍到 3 轮/3 秒，代价是：
    // 小宇宙这类懒加载模块的类在启动 3 秒后才 realize，就永远装不上钩子（0.4.37.9 能用、0.4.37 不能的真因）。
    // 现在改成按时间节流 + 永不过期：定时轮次、App 回前台都会补装，已装的静默跳过。
    static NSTimeInterval lastT = 0;
    NSTimeInterval nowT = [[NSDate date] timeIntervalSince1970];
    if (lastT > 0 && nowT - lastT < 0.8) return;
    lastT = nowT;

    // 输入栏（优先级最高：不依赖任何消息对象结构）
    SLInstallSendTextHook(SLClassByName("MDChatInputBar"));
    SLInstallSendTextHook(SLClassByName("MDNewInputTextBar"));
    SLInstallSendTextHook(SLClassByName("MDChatUniverseInputBar"));
    SLInstallSendTextHook(SLClassByName("MDBaseInputBar"));
    // handler 层
    SLInstallSendTextMessageHook(SLClassByName("MDChatBaseHander"));
    SLInstallSendTextMessageHook(SLClassByName("MDChatUniverseHandler"));
    SLInstallSendTextMessageHook(SLClassByName("MDChatSingleHandler"));
    SLInstallSendAudioHook(SLClassByName("MDChatBaseHander"));
    SLInstallSendAudioHook(SLClassByName("MDChatUniverseHandler"));
    SLInstallSendAudioHook(SLClassByName("MDChatSingleHandler"));
    SLInstallAudioRecordHook(SLClassByName("MDChatSingleHandler"));
    SLInstallAudioRecordHook(SLClassByName("MDChatBaseHander"));
    SLInstallAudioRecordHook(SLClassByName("MDChatUniverseHandler"));
    // v0.4.37：小宇宙 handler 诊断（只打一次）+ sendContent: 正式接管
    {
        Class uh = SLClassByName("MDChatUniverseHandler");
        static BOOL loggedUH = NO;
        if (!loggedUH) {
            loggedUH = YES;
            if (uh) {
                SLLog(@"UNIV-HANDLER cls=%s sendTextMessage=%d sendAudio=%d sendContent=%d",
                      class_getName(uh),
                      class_getInstanceMethod(uh, @selector(sendTextMessage:)) != NULL,
                      class_getInstanceMethod(uh, @selector(sendAudioMessage:audioTime:audioFileSize:)) != NULL,
                      class_getInstanceMethod(uh, NSSelectorFromString(@"sendContent:")) != NULL);
            } else {
                SLLog(@"UNIV-HANDLER 取不到 MDChatUniverseHandler（NSClassFromString 与运行时表都没有）");
            }
        }
        SLLog(@"UNIV 口令 cmd=%@ pack=%@", SLCommand(), SLPackCommand());
        if (uh) SLInstallOneObjectHook(uh, NSSelectorFromString(@"sendContent:"), (IMP)SLUniverseContentHook);
    }
    // 录音机临时路径（拿得到就直接命中真实录音文件）
    SLInstallTempPathHook(NSClassFromString(@"MDAudioRecorder"));
    // v0.4.37 核心：接管陌陌录音的 PCM 流（AI 语音替换的落地位置）
    SLInstallBusPCMHooks();
    SLInstallFunnelHooks();
    SLInstallServiceHook();
    // v0.4.37：虚拟定位（不开时全透传）
    @try { SLInstallVirtualLocationHooks(); } @catch (NSException *e) {}
    // v0.4.37：UIButton configuration 断言兜底
    @try { SLInstallUIButtonGuard(); } @catch (NSException *e) {}
    // v0.4.37：事件探针（抓小宇宙私聊的真实发送入口，只记录不改行为）
    @try { SLInstallActionProbe(); } @catch (NSException *e) {}
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
    @try { SLMigratePackCommandDefault(); } @catch (NSException *e) {}
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [AWECAUtils ensureDirectoriesExist]; } @catch (NSException *e) {}
        @try { SLStartEntryWatcher(); } @catch (NSException *e) {}
        SLInstallHooks();
        // v0.4.37：轮次从 2 次拉回 6 次（覆盖启动后 12 秒）。状态摘要仍只在最后一轮打一次。
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { SLInstallHooks(); } @catch (NSException *e) {}
                if (i == 6) SLLog(@"%@", SLHookStatusSummary());
            });
        }
        // v0.4.37：App 每次回前台都补装一次。小宇宙这些模块是「第一次点进去才加载类」，
        // 只在启动那几秒装钩子必然漏；回前台 = 模块已加载，这一轮就能补上。
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            @try { SLInstallHooks(); } @catch (NSException *e) {}
            @try { SLDumpUniverseClassesOnce(); } @catch (NSException *e) {}
        }];
    });
}
