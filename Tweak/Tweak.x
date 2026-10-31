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
#import "SLChatRewrite.h"
#import "SLVirtualLocation.h"
#import "SLLogViewController.h"
#import "SLEntry.h"
#import "SLVoicePack.h"
#import "SLTTSAuditionPanel.h"
#import "SLDiagMoment.h"

#define SLVersion @"0.5.15"
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

// v0.4.52.6：口令严格匹配 —— 只认用户设置的那一条，不再生成「去掉井号」的变体。
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
//      于是 key 被改写成钩子自己 → 钩子调钩子 → 无限递归爆栈（0.4.52 语音闪退的真因）。
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
    // v0.4.52：重试安装时这里会反复命中，原来每次都写一行日志（一次启动刷上百行），
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

// v0.4.52：NSClassFromString 取不到的兜底。
// 实测（0.4.52 日志）：MDChatUniverseInputBar 能取到并装上钩子，但同一个模块里的
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
static NSString *gSLClaimLast = nil;
static NSTimeInterval gSLClaimLastT = 0;
static BOOL SLClaimText(NSString *text) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (text.length && gSLClaimLast && [gSLClaimLast isEqualToString:text] && (now - gSLClaimLastT) < 5.0) return NO;
    gSLClaimLast = [text copy];
    gSLClaimLastT = now;
    return YES;
}

// 合成失败 / 用法错误时释放去重锁，允许用户在输入框里重试同一条口令
static void SLReleaseClaim(void) {
    gSLClaimLast = nil;
    gSLClaimLastT = 0;
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
// v0.4.82：加了「写回」分支 —— 合成失败 / 用户取消时要把口令原样放回输入框。
// 陌陌自己在调 sendTextMessage: 之前就已经把框清空了，不补这一步，所谓的「留在输入框」是空的。
// v0.4.84：v0.4.83 的回填实际一次都没成功过（见 SLApplyInputBarsText 注释），整段重写。
static BOOL SLSetTextInView(UIView *v, NSString *text);
static BOOL SLWriteTextToBar(UIView *bar, NSString *text);
// v0.4.86：定义在下面（v0.4.84 加的），但 v0.4.85 的全窗口兜底要先用到它 ——
// 缺这行就是「call to undeclared function」+「static declaration follows non-static」。
static BOOL SLFillTextView(UITextView *tv, NSString *text);

// v0.4.84：最近一次成功写过的输入框。输入栏被换成语音模式 / 页面重建时，
// 窗口里可能一时扫不到它，留一手兜底。
static __weak UITextView *sSLLastInputTextView = nil;

static BOOL SLApplyInputBarsText(NSString *text) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w && !w.hidden && ![wins containsObject:w]) [wins addObject:w];
            }
        }
    } @catch (NSException *e) { }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    if (kw && ![wins containsObject:kw]) [wins insertObject:kw atIndex:0];

    // v0.4.85：一趟 BFS 同时收两样东西 ——
    //   bars：认得出的输入栏（优先写它：能连带触发陌陌自己的 delegate 和布局）
    //   tvs ：全窗口所有「可编辑」的 UITextView（兜底）
    // v0.4.84 的致命毛病是「只有 looksBar 成立才去写」：认不出类名就等于整趟白跑，
    // 日志里的 hit=0 就是这么来的 —— 输入栏明明是别的类，我们连碰都没碰过它。
    // 每个视图单独 try：v0.4.83 把整趟包在一个 try 里，一条 NSUnknownKeyException
    // 就能把整窗扫描连结果一起丢掉。
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    NSMutableArray<UITextView *> *tvs = [NSMutableArray array];
    Class c1 = NSClassFromString(@"MDChatInputBar");
    Class c2 = NSClassFromString(@"MDNewInputTextBar");
    Class c3 = NSClassFromString(@"MDChatUniverseInputBar");

    for (UIWindow *win in wins) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:win];
        while (q.count) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            @try {
                if ([v isKindOfClass:[UITextView class]]) {
                    UITextView *t = (UITextView *)v;
                    if (t.isEditable) [tvs addObject:t];
                } else {
                    NSString *cn = NSStringFromClass([v class]);
                    BOOL looksBar = [cn hasSuffix:@"InputBar"] || [cn hasSuffix:@"InputTextBar"] ||
                                    [cn hasSuffix:@"TextInputBar"] || [cn hasSuffix:@"ChatInputBar"];
                    if (!looksBar) {
                        looksBar = (c1 && [v isKindOfClass:c1]) || (c2 && [v isKindOfClass:c2]) ||
                                   (c3 && [v isKindOfClass:c3]);
                    }
                    if (looksBar) [bars addObject:v];
                }
            } @catch (NSException *e) { }
            for (UIView *s in v.subviews) [q addObject:s];
        }
    }

    // 兜底顺序：正拿着焦点的那个最可能就是用户刚用的框；其次面积最大的
    //（输入栏切到语音模式时文本框会被收成 0 尺寸，这些排在最后）。
    // 参数写成 id：NSComparator 的签名就是 (id, id)，写具体类型会撞
    //「incompatible block pointer types」，-Werror 下直接挂。
    [tvs sortUsingComparator:^NSComparisonResult(id a, id b) {
        UITextView *va = (UITextView *)a;
        UITextView *vb = (UITextView *)b;
        BOOL fa = va.isFirstResponder, fb = vb.isFirstResponder;
        if (fa != fb) return fa ? NSOrderedAscending : NSOrderedDescending;
        CGFloat sa = CGRectGetWidth(va.bounds) * CGRectGetHeight(va.bounds);
        CGFloat sb = CGRectGetWidth(vb.bounds) * CGRectGetHeight(vb.bounds);
        if (sa > sb) return NSOrderedAscending;
        if (sa < sb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSInteger hit = 0;
    for (UIView *bar in bars) {
        if (SLWriteTextToBar(bar, text)) { hit++; break; }
    }
    // v0.4.85：全窗口兜底只用于「回填」。清空（text=nil）必须保守 ——
    // 同一个窗口里还有搜索框、备注框，乱清一气比清不掉更糟。
    if (hit == 0 && text.length) {
        for (UITextView *t in tvs) {
            if (SLFillTextView(t, text)) { hit++; break; }
        }
    }
    // 扫描没命中就退回上次成功写过的那个框（页面重建前的引用一般还活着）。
    // 注意这条只在真写成功过之后才有值 —— 首次就是 MISS 的话它救不了场，
    // 所以主力必须是上面那条全窗口兜底。
    if (hit == 0 && text.length) {
        UITextView *last = sSLLastInputTextView;   // __weak 先落成强引用再传参
        if (last && last.window && SLFillTextView(last, text)) hit++;
    }
    // v0.4.85：日志带全计数。只有 hit 一个数字的话，「没扫到」和「扫到了写不进」
    // 打出的是同一行字，没法定位。
    SLLog(@"input bar %@: %@ (%lu chars) hit=%ld wins=%lu bars=%lu tvs=%lu",
          text.length ? @"restore" : @"clear", hit ? @"ok" : @"MISS",
          (unsigned long)text.length, (long)hit,
          (unsigned long)wins.count, (unsigned long)bars.count, (unsigned long)tvs.count);
    return hit > 0;
}

static BOOL SLClearInputBars(void) { return SLApplyInputBarsText(nil); }
static BOOL SLRestoreInputBarsText(NSString *text) { return SLApplyInputBarsText(text); }

// v0.4.52：安全取字符串 getter —— 先确认方法返回类型是对象（'@'）再调。
// 0.4.52 闪退根因：对「返回结构体/基本类型」的属性盲调 getter，arm64 上返回值 ABI 不匹配，直接崩。
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

// v0.4.52：语音包口令整条路径删掉了，现在只剩合成口令一条
static BOOL SLTextHasAnyCommand(NSString *text) {
    return SLTextHasCommand(text);
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

// v0.4.82：把口令写回输入框。
// v0.4.81 只做了「失败不清空」，但陌陌的发送顺序是「取文本 → 建 message → 清空输入框 →
// 调 sendTextMessage:」，我们 hook 在最后一环，框早就空了 —— 所以必须主动回填。
// v0.4.84：真正往 UITextView 里写字，写完读回校验（text 全空也走这里 = 清空）。
static BOOL SLFillTextView(UITextView *tv, NSString *text) {
    if (!tv) return NO;
    NSString *want = text.length ? text : @"";
    @try {
        tv.text = want;
        // 光设 text 不够：输入栏的高度和右侧发送键都挂在 textViewDidChange: 上，
        // 不通知它，字有了但气泡高度还是原来那一行。
        id<UITextViewDelegate> d = tv.delegate;
        if (d && [d respondsToSelector:@selector(textViewDidChange:)]) {
            @try { [d textViewDidChange:tv]; } @catch (NSException *e) { }
        }
        // v0.4.83：UITextView 不是 UIControl，没有 sendActionsForControlEvents:（v0.4.82
        // 就是这么炸的 CI）。广播文本变更通知 —— UIKit 内部以及陌陌监听输入栏的那套都收这个。
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification
                                                            object:tv];
        if (want.length && want.length <= tv.text.length) {
            tv.selectedRange = NSMakeRange(want.length, 0);   // 光标落到末尾，接着改口令就行
        }
        if ([tv.text isEqualToString:want]) {
            sSLLastInputTextView = tv;
            return YES;
        }
    } @catch (NSException *e) { }
    return NO;
}

// v0.4.84：往一条输入栏里写字。
// 先按常见 KVC 名找文本框（陌陌几套输入栏命名不统一），找不到就把这棵子树扫一遍，
// 认「可编辑、有宽度」的第一个 UITextView —— 比死认属性名可靠。
// 每一步都单独 @try：valueForKey: 遇到不存在的 key 会抛 NSUnknownKeyException，
// 这就是 v0.4.83 扫描整个被吞掉、一个字也没写进去的直接原因。
static BOOL SLWriteTextToBar(UIView *bar, NSString *text) {
    if (!bar) return NO;
    if ([bar isKindOfClass:[UITextView class]]) return SLFillTextView((UITextView *)bar, text);
    NSArray *keys = @[@"inputTextView", @"textView", @"inputTextView_",
                      @"expandingTextView", @"textInputView", @"inputField"];
    for (NSString *k in keys) {
        id o = nil;
        @try { o = [bar valueForKey:k]; } @catch (NSException *e) { o = nil; }
        if (!o) continue;
        if ([o isKindOfClass:[UITextView class]]) {
            if (SLFillTextView((UITextView *)o, text)) return YES;
        } else if ([o isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)o;
            @try {
                tf.text = text.length ? text : @"";
                [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                if ([tf.text isEqualToString:(text.length ? text : @"")]) return YES;
            } @catch (NSException *e) { }
        }
    }
    // 兜底：把这棵子树扫一遍。优先挑「有宽度」的（真正在用的那个），
    // 一个都没有就把第一个可编辑的也算上 —— 输入栏切到语音模式时文本框会被收成 0 尺寸，
    // 但把字写进去，切回文字模式依然能看到。
    UITextView *fallback = nil;
    NSMutableArray *q = [NSMutableArray arrayWithObject:bar];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITextView class]]) {
            UITextView *t = (UITextView *)v;
            if (t.isEditable) {
                if (CGRectGetWidth(t.bounds) > 8.0) {
                    if (SLFillTextView(t, text)) return YES;
                } else if (!fallback) {
                    fallback = t;
                }
            }
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    if (fallback) return SLFillTextView(fallback, text);
    return NO;
}

static BOOL SLSetTextInView(UIView *v, NSString *text) {
    if (!text.length) return NO;
    if ([v isKindOfClass:[UITextView class]]) {
        if (SLFillTextView((UITextView *)v, text)) return YES;
    }
    return SLWriteTextToBar(v, text);
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

// v0.4.52：放宽版 —— 不再要求 ivar 静态类型名以 Hander/Handler 结尾。
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
// —— v0.4.52：接管陌陌录音的 PCM 流（MDAudioStreamBus → MDOpusEncoder）——
static id gSLBusRef = nil;              // 本次录音的 bus 实例（身份校验，别喂错对象）
static NSData *gSLBusPCM = nil;         // 按 bus 的 ASBD 预处理好的 PCM
static NSUInteger gSLBusOffset = 0;     // 已喂字节数
static BOOL gSLBusActive = NO;          // 正在接管
static BOOL gSLBusFed = NO;             // 至少喂过一块 → 文件里已经是 AI 语音
static int gSLBusSwallowLog = 0;
// —— v0.4.52：通用 PCM 漏斗（编码器入口兜底）——
static BOOL gSLPcmArmed = NO;
static double gSLArmRate = 0;
static unsigned gSLArmCh = 0;
static int gSLFunnelLog = 0;
static NSMutableSet *gSLHookedSels = nil;
// —— v0.4.52：收尾补喂（用户松手比 AI 语音短时，把剩下的 PCM 补进编码器，避免被截断）——
static NSUInteger gSLBusChunkSize = 0;  // 陌陌每次递进来的块大小（补喂按同样粒度，保持帧对齐）
static BOOL gSLDrained = NO;            // 本次录音是否已经补喂过（只补一次）
// v0.4.52：补喂不再自己调编码器，而是走总线自己的 sendPcm:byteSize:。
// 这些字节是我们塞进去的，encodePcm: 钩子必须原样放行（按字节数记账，异步也准）。
static NSUInteger gSLForcePassBytes = 0;
#define kSLFillShortKey @"SLFillShort"   // 短录音补全开关（默认开）
// v0.4.85：合成失败/取消时把口令原文放回输入框（默认开）。
// 关掉就只复制到剪贴板，不碰陌陌的输入框 —— 有人嫌它抢输入框焦点。
#define kSLKeepTextKey @"SLKeepTextOnFail"
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

// —— v0.4.52：按语音消息 body 里的 file token 精确定位陌陌真实录音文件 ——
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
// 单位是 0.1 秒（v0.4.52 日志实测：audiotime=18 显示 1.8 秒），所以要 ×10；
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

// v0.4.52：这条是「自动装载」——标记本次是语音包自动装填的（不是口令 / 合成），
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

// v0.4.52：给界面用的「清空槽位」。语音包和 #tts 合成音共用这一个槽位，
// 选包时必须把上一条合成音清掉（后写覆盖），否则会出现「选了包却发合成音」。
void SLClearArmedAudio(void) {
    SLResetArmedAudio();
    SLLog(@"armed audio cleared by UI");
}

// v0.4.52：不靠口令的装载路径。
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

// v0.4.52：一次性装填 —— 只有用户主动点过某条语音包，才为「下一条录音」装一发；
// 发送成功后由 AUDIO-SEND 清空，自然落回原声。没有开关、没有优先级、不会互相覆盖。
static BOOL SLArmPackAutoQuiet(void) {
    if (!SLIsEnabled()) return NO;
    if (![SLVoicePack isOneShotPending]) {
        // 没装填却还有残留（点了包但这次没发成、之后又取消），一次性清干净
        if (gSLAutoArmed) SLResetArmedAudio();
        return NO;
    }
    if (![SLVoicePack isEnabled]) return NO;
    // v0.4.52：槽位里装的是 #tts 合成音时，别拿语音包把它盖掉 —— 用户最后点的那条才算数。
    if ([SLVoicePack armedSource] == SLArmedSourceAI) return NO;
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
    // v0.4.52：槽位来源 = 语音包（胶囊上显示包名）
    [SLVoicePack setArmedSource:SLArmedSourcePack];
    SLLog(@"AUTO-PACK 装载 %@（%.2fs）→ 本次录音直接替换", gSLAutoPackName ?: @"-", gSLTTSAudioDur);
    return YES;
}

// v0.4.85：开关定义在文件后半段（跟 SLFillShortEnabled 放一起），这里先声明。
static BOOL SLKeepTextOnFail(void);
// v0.4.89：收尾该落哪个静止态。定义在文件后半段（录音收尾那段），这里先声明 ——
// 合成收尾的三条路径（取消 / 超时 / 失败）都在它前面。
static SLFloatState SLRestingState(void);

// v0.4.82：胶囊里只有一行位置放失败原因，而 pipeline 给的 msg 常带冒号后的细节
//（"网络错误: 无法连接服务器。"），截到冒号为止，够用且不会被省略号啃掉。
static NSString *SLShortFailReason(NSString *msg) {
    if (!msg.length) return nil;
    NSString *s = msg;
    NSRange r1 = [s rangeOfString:@":"];
    NSRange r2 = [s rangeOfString:@"："];
    NSRange r = r1;
    if (r2.location != NSNotFound && (r1.location == NSNotFound || r2.location < r1.location)) r = r2;
    if (r.location != NSNotFound && r.location > 0) s = [s substringToIndex:r.location];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // v0.4.88：8 → 6。失败原因现在挪到副标行（84pt 宽），8 个 11pt 汉字是 88pt，
    // 刚好撑破一点点就再被截一次，变成「网络连接超时…」这种两头都截的怪样子。
    if (s.length > 6) s = [[s substringToIndex:6] stringByAppendingString:@"…"];
    return s;
}

// v0.4.82：rawText = 输入框里的原文（含口令前缀），inputView = 那个输入框（拿不到就传 nil）。
// 失败 / 取消时把 rawText 原样写回去 —— 陌陌在调 sendTextMessage: 之前就把框清了，
// 不主动回填的话「留在输入框」只是一句空话（v0.4.81 的日志证实过）。
static void SLArmTTS(id handler,
                     NSString *content,
                     NSString *rawText,
                     UIView *inputView) {
    (void)handler;
    // v0.4.82：统一成「已经出结论」标志 —— 成功 / 失败 / 取消 / 超时，谁先到算谁，
    // 后到的回调一律丢掉。原来只有 cancelled，超时后 pipeline 迟到的成功回调仍会装填。
    __block BOOL settled = NO;

    // v0.4.84：回填改成有返回值 —— 写不进去的时候至少别把口令弄丢（退到剪贴板）。
    BOOL (^restoreText)(void) = ^{
        if (!rawText.length) return NO;
        // v0.4.85：设置里关掉「失败时放回输入框」就只留剪贴板，不去碰陌陌的框。
        if (!SLKeepTextOnFail()) {
            UIPasteboard.generalPasteboard.string = rawText;
            SLLog(@"keep-text off：只复制到剪贴板（%lu chars）", (unsigned long)rawText.length);
            return NO;
        }
        BOOL ok = inputView ? SLSetTextInView(inputView, rawText) : SLRestoreInputBarsText(rawText);
        if (ok) {
            // v0.4.85：写完 0.35 秒再回头看一眼。陌陌自己的发送收尾可能比我们晚一拍，
            // 把刚写进去的字又清掉 —— 用户看到的就是「还是没进框」。
            UITextView *tv = sSLLastInputTextView;
            if (tv) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (tv.window && tv.text.length == 0) {
                        if (SLFillTextView(tv, rawText)) SLLog(@"restore re-applied after 0.35s");
                    }
                });
            }
        } else {
            UIPasteboard.generalPasteboard.string = rawText;
            SLLog(@"restore text MISS，已复制到剪贴板");
            [AWECAUtils showToast:@"没写回输入框，原文已复制" duration:2.5];
        }
        return ok;
    };
    void (^clearOnSuccess)(void) = ^{
        if (inputView) { SLClearTextInView(inputView); return; }
        // v0.4.87：清「回填时写进去的那个框」，别再盲扫。
        // 原来这里走 SLClearInputBars()，而清空分支要求 text.length 非空才去扫全窗口，
        // 传 nil 就只剩 bars 白名单 —— 你单聊的输入栏不在白名单里（bars=0），
        // 所以日志里 input bar clear 全是 MISS，一次都没真清掉。失败重试成功后
        // 框里还留着「tts 测试」，手滑再点一次发送就又起一个合成。
        UITextView *last = sSLLastInputTextView;   // __weak 先落成强引用
        if (last && last.window) {
            NSUInteger before = last.text.length;
            if (SLFillTextView(last, nil)) {
                SLLog(@"input bar cleared via remembered tv (had %lu chars)", (unsigned long)before);
                return;
            }
            SLLog(@"clear via remembered tv failed, fallback to bars");
        }
        SLClearInputBars();
    };
    void (^retryBlock)(void) = ^{
        SLArmTTS(nil, content, rawText, inputView);
    };

    void (^cancelBlock)(void) = ^{
        settled = YES;
        // v0.4.89：取消只表示「这次不合成」，不代表槽位空了。选了语音包时它还在，
        // 球应该停在 Ready 绿；原来这里硬写 Idle，包还在也变灰。
        SLFloatSetState(SLRestingState());
        restoreText();                       // v0.4.82：取消也要回填，别指望陌陌留着
        SLReleaseClaim();                    // 释放去重锁，允许直接在输入框里重发
        SLLog(@"tts cancelled by user, text restored to input box");
    };

    // v0.4.52.5：语音包已改走独立口令（默认 yyb），这里只负责合成，两者不再互相抢。
    SLFloatSetState(SLFloatStateSynthesizing);   // v0.4.52：球变蓝、弧线转圈
    // v0.4.82：进度 / 取消从独立卡片挪进胶囊；上限从 60s 收到 30s ——
    // 旧版干等满一分钟才报超时，现在有可见时间条和取消键，没必要忍那么久。
    SLFloatTTSBegin(30.0, cancelBlock);

    // v0.4.82：pipeline 自己的超时是 60s，胶囊 30s 就走满了 —— 不能让它空转半分钟，
    // 到点自己判超时（迟到的成功回调被 settled 挡掉，不会再偷偷装填）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (settled) return;
        settled = YES;
        SLLog(@"tts timeout at 30s capsule limit");
        restoreText();
        // v0.4.85：先落失败态（相位 2）再回灰。反过来的话 Idle 会被
        //「合成中不接受回灰」那道闸拦掉，球停在蓝、胶囊却在报失败，状态对不上。
        SLFloatTTSEnd(NO, @"合成超时", retryBlock);
        // v0.4.89：超时只是这次没合成出来，槽位里的旧包还在 —— 按「有没有装填」落态
        SLFloatSetState(SLRestingState());
        SLReleaseClaim();
    });
    [[SLPipeline shared] synthesizeMessageText:content completion:^(BOOL ok, NSString *outPath, double dur, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (settled) return;   // v0.4.82：取消 / 超时之后到的回调，一律丢掉
            settled = YES;
            if (!ok || !outPath.length) {
                // v0.4.81：合成失败绝不再把口令文本当普通消息发出去（旧版失败兜底会调 orig，把口令当普通消息漏给对面）。
                // v0.4.82：失败反馈整体挪进胶囊（红字 + 「口令已放回输入框」），不再弹 toast；
                // 同时主动把原文写回输入框 —— 陌陌在这之前已经清过框了。
                SLLog(@"tts failed: %@", msg.length ? msg : @"(无信息)");
                restoreText();
                NSString *why = SLShortFailReason(msg);
                SLFloatTTSEnd(NO, why.length ? [NSString stringWithFormat:@"合成失败 · %@", why] : @"合成失败", retryBlock);
                // v0.4.85：同上 —— 红字先出，再落静止态。
                // v0.4.89：这次没合成出来，但槽位里的旧包可能还在，按「有没有装填」判绿/灰。
                SLFloatSetState(SLRestingState());
                SLReleaseClaim();
                return;
            }
            // v0.4.82：成功先收胶囊（绿球由下面的 setState 接，顺序不能反 —— 反过来会先绿再收）
            SLFloatTTSEnd(YES, nil, nil);
            // 「录音替换」模式：合成后只“装填”，不自动发。
            // 等用户真实录音，audioRecorder 钩子会把录音文件覆盖成这份 AI 音频。
            gSLTTSAudioPath = [outPath copy];
            gSLTTSAudioDur = dur;
            gSLArmedAt = [[NSDate date] timeIntervalSince1970];
            // v0.4.52：合成音和语音包共用同一个槽位，这里把它占住 ——
            // 覆盖掉之前选中的包，胶囊如实显示「AI 语音」而不是「原声」。
            [SLVoicePack setOneShotPending:YES];
            [SLVoicePack setArmedSource:SLArmedSourceAI];
            SLLog(@"armed tts path=%@ dur=%.2f — 等待用户录音替换", outPath, dur);
            // v0.4.81：合成成功才清输入框（失败分支不清除，口令留在框里等重试）。
            if (clearOnSuccess) clearOnSuccess();
            // v0.4.59：这里不再先落灰。原来先设 Idle（灰），紧接着同步解码 PCM（约 0.2–0.4s），
            // 等试听面板弹出后才设 Ready（绿）—— 录屏里就是「蓝 → 灰 → 绿」闪一下，看着像顿住。
            // 现在保持蓝：开着试听就走下面 present 完成时转绿，关掉试听走 else 分支转绿；只有取消才回灰。


            // —— v0.4.52：不再自己造 Opus 文件 ——
            // v0.4.52 直接调陌陌的 MDAudioStreamBus 构造器会闪退（它在 init 里就用到
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
            // v0.4.52：倒计时改成「确认使用之后」才启动 —— 否则用户在里面反复试听，
            // 还没听完装填就过期了。
            NSString *armed = outPath;
            void (^startDisarmTimer)(void) = ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (gSLTTSAudioPath && [gSLTTSAudioPath isEqualToString:armed]) {
                        gSLTTSAudioPath = nil;
                        // v0.4.52：槽位空了，胶囊上的「AI 语音」也要跟着落回原声
                        [SLVoicePack setOneShotPending:NO];
                        SLLog(@"armed tts expired (60s), cleared");
                    }
                });
            };

            if ([SLTTSAuditionPanel isEnabled]) {
                // 试听期间不清空装填：用户点「用这条」才算数，点「取消」才撤销。
                // v0.4.52：把 16k PCM 一起递进去，面板拿它封 WAV 试听（AMR 播不动）
                [SLTTSAuditionPanel presentWithAudioPath:outPath
                                                 pcm16k:gSLTTSPCM16k
                                               duration:dur
                                                   text:content
                                                  onUse:^{
                    [AWECAUtils showToast:[NSString stringWithFormat:@"已就绪 · 现在录音发送 AI 语音（%.1fs）", dur]
                                 duration:2.0];
                    // v0.4.52：确认使用才点亮就绪蓝
                    SLFloatSetState(SLFloatStateReady);
                    startDisarmTimer();
                }
                                                  onCancel:^{
                    // 只有这次装的还是这条才清，避免误清掉用户已经换成新的一条
                    if (gSLTTSAudioPath && [gSLTTSAudioPath isEqualToString:armed]) {
                        gSLTTSAudioPath = nil;
                        gSLTTSAudioDur = 0;
                        gSLTTSPCM16k = nil;
                        gSLTTSPCM16kDur = 0;
                        [SLVoicePack setOneShotPending:NO];   // v0.4.52：胶囊回落「原声」
                    }
                    // v0.4.52：取消就把球放回灰，别让它一直亮着就绪蓝
                    SLFloatSetState(SLFloatStateIdle);
                    SLLog(@"tts audition cancelled, disarmed");
                }
                                                 onRetry:^{
                    SLLog(@"tts audition retry");
                    SLArmTTS(nil, content, rawText, inputView);
                }];
            } else {
                // v0.4.52：没开试听面板时合成完就是直接可用，这里补上就绪蓝
                SLFloatSetState(SLFloatStateReady);
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
        SLReleaseClaim();
        return;   // 不放回也不发：口令本就在输入框
    }

    SLLog(@"#tts hit via %@ -sendText, text=%@", NSStringFromClass([self class]), SLShorten(text, 40));
    id handler = SLFindAudioHandlerNear(bar);
    if (!handler) {
        // v0.4.52：小宇宙私聊的发送器 MDChatUniverseHandler 不在输入栏响应链上，
        // 老逻辑会误判「没找到语音发送入口」→ 退回文字，于是私聊口令完全没反应。
        // 实际替换由全局编码器接管（MDAudioStreamBus → MDOpusEncoder），SLArmTTS 不使用
        // handler 实参（只用来判空），所以这里对小宇宙输入栏直接装填，不再退回文字。
        Class ub = NSClassFromString(@"MDChatUniverseInputBar");
        Class uh = NSClassFromString(@"MDChatUniverseHandler");
        if (ub && uh && [self isKindOfClass:ub]) {
            SLLog(@"Universe 输入栏：响应链未命中 handler，但仍装填（录音由全局编码器接管替换）");
            SLArmTTS(self, content, text, tv);
            return;
        }
        SLLog(@"no audio handler near input bar -> 留在输入框，不发送");
        [AWECAUtils showToast:@"没找到语音发送入口，已放回输入框" duration:2.0];
        SLReleaseClaim();
        return;
    }

    SLArmTTS(handler, content, text, tv);
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
        SLReleaseClaim();
        return;
    }

    SLLog(@"#tts hit via %@ -sendTextMessage:", NSStringFromClass([self class]));
    // v0.4.82：这一层拿不到输入框，只能让 SLArmTTS 自己扫全窗口回填
    SLArmTTS(self, content, text, nil);
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
    if (!SLTextHasCommand(str)) {
        if (orig) orig(self, _cmd, text, targetID, isSingle);
        return;
    }
    if (!SLClaimText(str)) return;
    NSString *content = SLTextAfterCommand(str);
    if (!content.length) {
        SLReleaseClaim();
        return;
    }
    SLLog(@"#tts hit via MMCommonServiceImpl");
    SLArmTTS(self, content, str, nil);
    return;
}

#pragma mark - 钩子 3.5：MDAudioStreamBus 的 PCM 流接管（v0.4.52 核心）

// 陌陌录音链路：MDAudioRecorder → MDAudioStreamBus
//   -sendPcmPrepareWithASBD:（开场）→ -sendPcm:byteSize:（逐块喂 PCM）→ -sendPcmOver（收尾）
//   → MDOpusEncoder → Ogg Opus 文件（Library/Application Support/Chat_Audios_Temp/<token>.opus）
//
// 为什么不在外面自己造 .opus：陌陌语音是 Ogg Opus，AMR 写进去对端解码失败 = 0 秒空语音；
// 而 v0.4.52 试过直接 alloc 陌陌的 MDAudioStreamBus 来自编码，会在 init 阶段闪退
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
// v0.4.52：补喂点改到 -stopRecord（主线程、收尾链路之前），并且走总线自己的
// sendPcm:byteSize: —— 就是录音时一直在用的那条公开入口，编码器/文件都还是正常态。
// v0.4.52/0.4.52 在 sendPcmOver 里直接同步调 encodePcm: 会卡死：那时已在收尾态，
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

// v0.4.85：合成失败 / 取消时要不要主动把口令写回输入框。默认开。
static BOOL SLKeepTextOnFail(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kSLKeepTextKey] == nil) return YES;
    return [d boolForKey:kSLKeepTextKey];
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

// v0.4.52：录音态起止统一收口。
// 原来只有 MDAudioRecorder -setTempAudioPath: 一处点亮录音态 —— 该 setter 在部分陌陌版本
// 压根不调用（类名都可能不同），所以用户按住说话时球一动不动。
// 录音必然要建总线并给出 ASBD，sendPcmPrepareWithASBD: 是唯一必经的关口，改从那里点亮。
static BOOL gSLRecordingUI = NO;

// v0.4.53：录音态不再靠「陌陌主动通知我录完了」来收尾。
// 0.4.52 点亮的三个入口（总线 ASBD / 临时路径 / 编码器首帧）里，总线入口是每按必走；
// 可收尾的四个点全是「录完了才调」的路径：置空 tempAudioPath / stopRecord（只对 4 个
// 类名装得上，陌陌真实类名不在名单里就等于没装）/ recordSucessStoreAt（只在上滑发送
// 成功时调）/ 180 秒超时。用户录音中途点「取消」，这四个一条都不触发 → 球一直红到
// 180 秒，看起来就是「永远红」。
//
// 解决办法：录音是一个持续出帧的流（每 20~40ms 一帧，录到静音也照样出帧），
// 所以「有没有帧」本身就是唯一可靠的活体信号 —— 超过 2.5 秒没有新帧，
// 无论用户是松手、取消、还是被来电/跳转打断，都判定停录，立刻落回就绪/空闲。
// 这样就不用猜陌陌把取消方法叫什么名字。
static NSTimeInterval gSLLastPcmAt = 0;    // 最近一帧 PCM 的到达时间
static NSTimeInterval gSLRecBeganAt = 0;   // 本轮点亮时间（一帧都没有时的兜底基准）
static BOOL gSLRecWatchdog = NO;           // 轮询是否在跑，避免重复挂

static void SLMarkRecordingEnded(void);   // 供上面超时兜底的 block 调用
static void SLRecWatchdogTick(void);

// 每来一帧就踢一脚。所有取帧点（编码器 / sendPcm / 总线准备）都要调。
static void SLRecWatchdogKick(void) {
    gSLLastPcmAt = [[NSDate date] timeIntervalSince1970];
}

static void SLRecWatchdogStart(void) {
    if (gSLRecWatchdog) return;
    gSLRecWatchdog = YES;
    SLRecWatchdogTick();
}

static void SLRecWatchdogTick(void) {
    if (!gSLRecordingUI) { gSLRecWatchdog = NO; return; }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 有帧：以最后一帧为基准，2.5 秒静默就算停。
    // 一帧都没有（只调了准备、其实没在录）：放到 10 秒 —— 万一某个版本是攒够一批才喂
    // 编码器，帧间隔会很长，3 秒就收会把正在录的球提前按成绿色。
    NSTimeInterval ref   = gSLLastPcmAt > 0 ? gSLLastPcmAt : gSLRecBeganAt;
    NSTimeInterval limit = gSLLastPcmAt > 0 ? 2.5 : 10.0;
    if (now - ref > limit) {
        SLLog(@"REC-UI %.1fs 无新音频帧（有帧=%d）→ 判定已停录",
              now - ref, gSLLastPcmAt > 0 ? 1 : 0);
        gSLRecWatchdog = NO;
        SLMarkRecordingEnded();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SLRecWatchdogTick(); });
}

// 落回哪个静止态，唯一真相是「有没有装填」，与 gSLTTSAudioPath 无关 ——
// 那条变量只表示「槽位里此刻有没有可直接接管的具体音频」：选语音包时会被
// SLClearArmedAudio() 清空，首次自动装载还可能因 PCM 缓存未命中而失败，
// 于是它经常是空，可装填明明是好的。原来据此判 Idle，球就错成灰色
//（用户报的「选好包 → 录一条变灰 → 再录又变蓝」正是这个）。
static SLFloatState SLRestingState(void) {
    return [SLVoicePack isOneShotPending] ? SLFloatStateReady : SLFloatStateIdle;
}

static void SLMarkRecordingStarted(void) {
    if (gSLRecordingUI) return;
    gSLRecordingUI = YES;
    gSLRecBeganAt = [[NSDate date] timeIntervalSince1970];
    gSLLastPcmAt = 0;
    SLLog(@"REC-UI 点亮录音态");
    SLFloatSetState(SLFloatStateRecording);
    // v0.4.53：活体轮询。2.5 秒没帧就落定（松手/取消/被打断都覆盖）。
    SLRecWatchdogStart();
    // 兜底：万一某个版本既没有停录回调、也没有落文件回调，180s 后强制落定，
    // 绝不让球一直红着挂在那里（正常情况下活体轮询早就收了，这条基本用不到）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gSLRecordingUI) {
            SLLog(@"REC-UI 超时强制落定");
            SLMarkRecordingEnded();
        }
    });
}

static void SLMarkRecordingEnded(void) {
    if (!gSLRecordingUI) return;   // 没点亮过就不落定：初始化时的路径清空不该把装填态按灰
    gSLRecordingUI = NO;
    gSLRecWatchdog = NO;
    gSLLastPcmAt = 0;
    SLFloatState s = SLRestingState();
    SLLog(@"REC-UI 录音结束 → %@", s == SLFloatStateReady ? @"就绪" : @"空闲");
    SLFloatSetState(s);
}

static void SLBusArmWithASBD(id bus, AudioStreamBasicDescription asbd) {
    if (!bus) return;
    if (!SLIsEnabled()) return;
    // v0.4.52：总线准备 = 真的在录了。放在「有没有装填」之前，没有装填也要点亮，
    // 否则这段代码会在下面第三行 return，录音态永远走不到。
    // 不按 mFormatID 过滤：这函数本身就叫 sendPcmPrepareWithASBD:，给 ASBD 就是在开录音流。
    SLMarkRecordingStarted();
    SLRecWatchdogKick();   // v0.4.53：开流也是一次活体信号，给轮询一个起点
    // v0.4.52：一次性装填。合成装填优先；否则看有没有待发的那一发。
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
    SLRecWatchdogKick();   // v0.4.53：有帧 = 还在录
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
    SLRecWatchdogKick();   // v0.4.53：有帧 = 还在录
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
//（v0.4.52.7 就是这样坏掉的）。只保留编码器单层替换。

static NSMethodSignature *SLSigOf(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return nil;
    const char *t = method_getTypeEncoding(m);
    if (!t) return nil;
    @try { return [NSMethodSignature signatureWithObjCTypes:t]; } @catch (NSException *e) { return nil; }
}

// v0.4.52：收尾点补喂 —— 在「关文件 / 收尾」前把 AI 语音剩下的部分喂完。
// 不同版本陌陌收尾选择子不完全一样，所以按名单探测（只钩无参方法）：
//   sendPcmOver / close / closeFile / finish / flush / stop / end / over
// 补喂只会发生一次，且必须已经喂过至少一块（否则说明还没真正接管）。
// v0.4.52：这里只直通，绝对不喂数据（收尾态调编码器必卡死）
static void SLDrainThenOrigHook(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))SLGetOrigIMP(self, _cmd);
    if (gSLBusActive && (gSLBusRef == nil || self == gSLBusRef)) {
        SLLog(@"PCM-OVER pass-through %@ drained=%d fed=%lu/%lu",
              NSStringFromSelector(_cmd), (int)gSLDrained,
              (unsigned long)gSLBusOffset, (unsigned long)gSLBusPCM.length);
    }
    if (orig) orig(self, _cmd);
}

// v0.4.52：补喂入口 —— 录音机停止时（主线程、收尾之前）
static void SLStopRecordHook(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))SLGetOrigIMP(self, _cmd);
    @try { SLDrainRemainingPCM(NSStringFromSelector(_cmd)); } @catch (NSException *e) {
        SLLog(@"PCM-OVER 异常 %@", e);
    }
    if (orig) orig(self, _cmd);
    // v0.4.52：停录也收口一次（与 setTempAudioPath 置空、REC-DONE 互相兜底）
    SLMarkRecordingEnded();
}

static void SLInstallStopRecordHook(Class cls) {
    if (!cls) return;
    // v0.4.53：除了 stopRecord，把「取消 / 丢弃」这一系也挂上。
    // 用户录音中途点取消时走的往往不是 stopRecord，而是 cancel/delete/discard 一类；
    // 以前只挂 stopRecord，取消就完全没人通知我们 → 球一直红。
    // 只在这几个候选录音机类上装，且只钩无参方法，撞到别的方法的概率很低；
    // 真正的活体兜底是 SLRecWatchdogTick（2.5 秒没帧就落定），这里只是让它更快一点。
    NSArray *names = @[@"stopRecord", @"stopRecording", @"cancelRecord", @"cancelRecording",
                       @"deleteRecord", @"discardRecord", @"abandonRecord",
                       @"endRecording", @"endRecord"];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *n in names) {
        SEL sel = NSSelectorFromString(n);
        NSMethodSignature *sig = SLSigOf(cls, sel);
        if (!sig || sig.numberOfArguments != 2) continue;   // 只钩无参
        if (SLRegisterMethod(cls, sel, (IMP)SLStopRecordHook)) [hits addObject:n];
    }
    if (hits.count) {
        SLLog(@"DRAIN-HOOK %s -> %@", class_getName(cls), [hits componentsJoinedByString:@" "]);
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

#pragma mark - 钩子 3.6：通用 PCM 漏斗接管（v0.4.52）

// 为什么要再加一层：
// v0.4.52 只钩了 MDAudioStreamBus 的 sendPcm*，但如果聊天语音实际上不走这个对象
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
    // v0.4.52：编码器拿到第一帧真 PCM = 确定正在录音。第三条保险
    //（总线 ASBD / 临时路径 / 这里，任一命中都会点亮，幂等不重复）。
    if ([data isKindOfClass:[NSData class]] && [(NSData *)data length] > 0) {
        SLMarkRecordingStarted();
        SLRecWatchdogKick();   // v0.4.53：编码器每帧都算活体信号
    }
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

// v0.4.52：语音真正发出后消耗掉这一发装填，胶囊落回「原声 / 灰态」。
// 小宇宙发语音走 sendContent: 音频条目，不经过 sendAudioMessage:，所以单独补一个调用点。
static void SLConsumeArmedOnSend(void) {
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
    [SLVoicePack setOneShotPending:NO];
    gSLRecordingUI = NO;   // v0.4.52：这一发已经发出去，别再留着录音态标记
    gSLRecWatchdog = NO;   // v0.4.53：活体轮询也一起停，避免下一拍又把状态改回去
    gSLLastPcmAt = 0;
    SLFloatSetState(SLFloatStateIdle);
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

    // 发送前的最后一步（v0.4.52）：录音阶段已把陌陌的 PCM 流换成 AI 语音，
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
            SLConsumeArmedOnSend();
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
        SLMarkRecordingStarted();   // v0.4.52：球变红 = 正在录（与总线准备互为双保险）
    } else {
        BOOL ex = NO;
        long long sz = -1;
        if (gSLTempRecPath.length) {
            ex = [[NSFileManager defaultManager] fileExistsAtPath:gSLTempRecPath];
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:gSLTempRecPath error:nil];
            sz = (long long)[a fileSize];
        }
        SLLog(@"TEMP-PATH cleared (prev=%@ exists=%d size=%lld)", gSLTempRecPath ?: @"(nil)", ex, sz);
        // v0.4.52：录音收尾不再看 gSLTTSAudioPath（它在选包那一刻就被清空了，
        // 首次自动装载还可能没来得及写入），改看「有没有装填」这个唯一真相。
        // 有装填就回就绪并一直亮着，等发送完成那一刻才回空闲。
        SLMarkRecordingEnded();
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

    // v0.4.52：这里不再覆盖文件。
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
    // v0.4.52：录音确认落了文件 = 一定录完了。这里兜一次底，
    // 免得某些版本不调 setTempAudioPath:（球就一直红着）。
    SLMarkRecordingEnded();
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

#pragma mark - 虚拟定位（v0.4.52）

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

// v0.4.52：只 swizzle delegate 类「自己实现」的该方法，避免改到父类方法影响全局
static BOOL SLImplementsDirectly(Class c, SEL sel) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(ms[i]) == sel) { found = YES; break; }
    }
    if (ms) free(ms);
    return found;
}

static NSUInteger sSLCLLocDidUpdHits = 0;
static NSMutableSet *sSLDelegatesSwizzled = nil;

// v0.4.52：CLLocationManager 用 delegate 回调拿坐标（回前台 / 后台 iOS 会推真实位置），
// 只 hook -location getter 拦不到这条路径。这里把回调里的 CLLocation 换成假坐标。
static void SLFakeDidUpdateLocations(id self, SEL _cmd, id manager, NSArray *locs) {
    void (*orig)(id, SEL, id, NSArray *) = (void (*)(id, SEL, id, NSArray *))SLGetOrigIMP(self, _cmd);
    CLLocation *fake = [SLVirtualLocation fakeLocation];
    NSArray *out = locs;
    if (fake) {
        out = @[fake];
        if (++sSLCLLocDidUpdHits % 100 == 1) SLLog(@"VLOC delegate 注入假坐标（第 %lu 次）", (unsigned long)sSLCLLocDidUpdHits);
    }
    if (orig) orig(self, _cmd, manager, out);
}

// v0.4.52：setDelegate: 时顺手接管 delegate 的 didUpdateLocations:
static void SLCLLocationSetDelegateHook(id self, SEL _cmd, id delegate) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))SLGetOrigIMP(self, _cmd);
    if (orig) orig(self, _cmd, delegate);
    if (!delegate) return;
    Class dc = [delegate class];
    SEL sel = @selector(locationManager:didUpdateLocations:);
    if (!SLImplementsDirectly(dc, sel)) return;
    if (!sSLDelegatesSwizzled) sSLDelegatesSwizzled = [NSMutableSet set];
    @synchronized (sSLDelegatesSwizzled) {
        if ([sSLDelegatesSwizzled containsObject:dc]) return;
        if (SLRegisterMethod(dc, sel, (IMP)SLFakeDidUpdateLocations)) {
            [sSLDelegatesSwizzled addObject:dc];
        }
    }
}

static void SLInstallVirtualLocationHooks(void) {
    SLDumpLocationClassesOnce();
    // v0.4.52：覆盖陌陌所有可能的定位类，而不只是 MomoLocationManager。
    // 哪个类被业务真正读取，-location getter 返回假坐标就拦哪条。
    NSArray<NSString *> *getters = @[@"MomoLocationManager", @"MILLocationManager", @"MDLocation",
                                     @"MDLocationClient", @"IMJClientLocationManager", @"BUSDKLocation"];
    for (NSString *n in getters) {
        Class c = NSClassFromString(n);
        if (c) SLRegisterMethod(c, NSSelectorFromString(@"location"), (IMP)SLMomoLocationGetHook);
    }
    SLRegisterMethod([CLLocationManager class], NSSelectorFromString(@"location"), (IMP)SLCLLocationGetHook);
    SLRegisterMethod([CLLocationManager class], NSSelectorFromString(@"setDelegate:"), (IMP)SLCLLocationSetDelegateHook);
    SLLog(@"VLOC 当前 %@", [SLVirtualLocation summary]);
}

// v0.4.52：音波发布后闪退的兜底。
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

// v0.4.52：小宇宙私聊发口令时日志「零记录」—— 说明它的发送链完全不经过我们钩的
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

// v0.4.52：小宇宙 sendContent: 正式接管（0.4.52 探针实测确认它就是私聊发送入口）。
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
        // 会踩 ABI（返回结构体时尤其致命），0.4.52 就是死在这里。
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

// v0.4.52：小宇宙语音气泡秒数对齐。
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

    // 读旧值只做日志（类型不对就跳过，绝不错位调用 —— 0.4.52 就是踩在这上面崩的）
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

    // v0.4.52：语音消息（content 无文本、带 audioUUID）先把气泡秒数改成 AI 语音的真实时长。
    // 必须在「无文本直接透传」之前，否则永远走不到这里。
    SLUniverseFixAudioDuration(arg);

    NSString *shown = SLTextFromArgument(arg);
    // 音频 / 图片 / 表情这类 content 没有文本：立刻透传，绝不进字段扫描。
    // 小宇宙发语音时 arg 就是这种对象（text=nil），0.4.52 在这里扫属性扫崩了。
    if (!shown.length) {
        BOOL slArmed = [SLVoicePack isOneShotPending];
        orig(self, _cmd, arg);
        // v0.4.52：小宇宙发语音走 sendContent: 音频条目，不经过 sendAudioMessage:，
        // 不在这里消耗装填，窗口会一直蓝。
        if (slArmed) SLConsumeArmedOnSend();
        return;
    }
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

    if (!SLTextHasCommand(full)) { orig(self, _cmd, arg); return; }
    if (!SLClaimText(full)) { SLLog(@"UNIV sendContent duplicate ignored"); return; }

    NSString *content = SLTextAfterCommand(full);
    if (!content.length) {
        [AWECAUtils showToast:[NSString stringWithFormat:@"用法：%@ 要转成语音的话", SLCommand()] duration:2.5];
        SLReleaseClaim();
        return;
    }

    SLLog(@"#tts hit via %@ -sendContent:, text=%@", NSStringFromClass([self class]), SLShorten(full, 40));
    // v0.4.81：合成失败不再退回原样发送（会漏口令），而是留在输入框；只有成功才清。
    // v0.4.82：小宇宙这套页面拿不到输入框实例，失败时由 SLArmTTS 扫全窗口回填原文。
    SLArmTTS(self, content, full, nil);
}


#pragma mark - 聊天记录修改（v0.4.97）

// 只在开着的时候拦；关掉时原样返回，零开销。
static NSInteger gSLCRProbe = 0;
static NSInteger gSLCardDump = 0;

static id SLChatBodyGetHook(id self, SEL _cmd) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (!orig) return nil;
    id raw = ((id (*)(id, SEL))orig)(self, _cmd);
    if (![raw isKindOfClass:[NSString class]]) return raw;
    @try {
        NSString *body = (NSString *)raw;
        BOOL rewriteOn = SLChatRewriteEnabled();
        BOOL recallOn = SLRecallGuardEnabled();
        // 改字与防撤回都要 id；两个都关就别白扫一遍 ivar
        NSArray *ids = (rewriteOn || recallOn) ? SLChatRewriteAliasesForMessage(self, nil) : nil;
        if (![ids isKindOfClass:[NSArray class]]) ids = @[];
        NSString *out = body;

        if (rewriteOn) {
            // 陌陌的菜单 id 与消息对象 msgid 不是同一个值（菜单是 "seq-uuid"），
            // 所以要拿全套 id 去查，命中任意一个都算。
            NSString *rep = SLChatRewriteTextForIds(ids, body);
            if ([rep isKindOfClass:[NSString class]] && rep.length) out = rep;
            // 探针：只在前 12 次读 body 且有条目时打，用来确认真的是这条路径在渲染
            if (gSLCRProbe < 12 && SLChatRewriteCount() > 0) {
                gSLCRProbe += 1;
                NSString *tv2Cls = @"-";
                @try {
                    id tv2 = [self valueForKey:@"textv2"];
                    if (tv2) tv2Cls = NSStringFromClass([tv2 class]);
                } @catch (NSException *e) { }
                SLLog(@"REWRITE-PROBE %@ ids=[%@] len=%lu hit=%d textv2=%@ body=%@",
                      NSStringFromClass([self class]),
                      [ids componentsJoinedByString:@" "],
                      (unsigned long)[body length],
                      (out != body) ? 1 : 0,
                      tv2Cls,
                      SLShorten(body, 14));
            }
        }

        // 防撤回：正文被清空 / 变成撤回提示时顶回原文（独立开关，默认开）
        if (recallOn && ids.count) {
            NSString *keep = SLRecallGuardBody(ids.firstObject, out);
            if ([keep isKindOfClass:[NSString class]] && keep.length) out = keep;
        }

        // 实拍卡片：prerender JSON 里的时间 / 公里数字面量，不知道字段名也能改
        if ([out hasPrefix:@"{"]) {
            if (gSLCardDump < 2) {
                gSLCardDump += 1;
                SLLog(@"REALSHOT-JSON %@ %@", ids.count ? ids.firstObject : @"-",
                      SLShorten(out, 2400));
            }
            NSString *edited = SLApplyRealShotEdits(out);
            if ([edited isKindOfClass:[NSString class]] && edited.length) out = edited;
        }
        return out;
    } @catch (NSException *e) { }
    return raw;
}

// 陌陌里「带表情 / 富文本」的气泡不一定读 body，而是读 textv2。
// 两条路都堵上：textv2 返回 NSString 才替换；返回模型对象就原样放过（不动它）。
static NSInteger gSLCRTv2Probe = 0;
static id SLChatTextV2GetHook(id self, SEL _cmd) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (!orig) return nil;
    id raw = ((id (*)(id, SEL))orig)(self, _cmd);
    if (![raw isKindOfClass:[NSString class]]) return raw;
    if (!SLChatRewriteEnabled()) return raw;
    @try {
        NSArray *ids = SLChatRewriteAliasesForMessage(self, nil);
        NSString *rep = SLChatRewriteTextForIds(ids, (NSString *)raw);
        if (gSLCRTv2Probe < 8 && SLChatRewriteCount() > 0) {
            gSLCRTv2Probe += 1;
            SLLog(@"REWRITE-TV2 %@ len=%lu hit=%d text=%@",
                  NSStringFromClass([self class]),
                  (unsigned long)[(NSString *)raw length],
                  (rep != raw) ? 1 : 0,
                  SLShorten((NSString *)raw, 16));
        }
        return rep ?: raw;
    } @catch (NSException *e) { }
    return raw;
}

// 气泡上的字最终是 MDMixLabel 自绘的排版结果，body / textv2 这两层拦不到。
// 保存后 reloadData 会让标签带着「原文」再排一次，这里把它换成新文 —— 渲染层最后一道闸。
static void SLChatMixLabelSetTextHook(id self, SEL _cmd, id text) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (!orig) return;
    if ([text isKindOfClass:[NSString class]]) {
        NSString *rep = SLChatRewriteTextForPlainString((NSString *)text);
        if (rep.length) text = rep;
    }
    ((void (*)(id, SEL, id))orig)(self, _cmd, text);
}

static void SLChatMixLabelSetAttributedHook(id self, SEL _cmd, id as) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (!orig) return;
    if ([as isKindOfClass:[NSAttributedString class]]) {
        NSString *s = [(NSAttributedString *)as string];
        NSString *rep = SLChatRewriteTextForPlainString(s);
        if (rep.length) {
            NSDictionary *attrs = s.length ? [(NSAttributedString *)as attributesAtIndex:0
                                                                         effectiveRange:NULL] : nil;
            as = [[NSMutableAttributedString alloc] initWithString:rep attributes:attrs];
        }
    }
    ((void (*)(id, SEL, id))orig)(self, _cmd, as);
}

// 聊天界面里每条消息下面那行「1分钟前 35.95km」。
// 这串不是任何字段，是 App 用消息发送时间 + 当前位置经纬度现场算出来的，
// 改 body 完全碰不到（v0.5.08 就改错了地方）。唯一能拦的是「最终显示」这一层。
// 门禁很严：短串、含 km、无换行，且用户没设值就直接放行 —— 开销可以忽略。
static void SLChatLabelSetTextHook(id self, SEL _cmd, NSString *text) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (!orig) return;
    if ([text isKindOfClass:[NSString class]] && text.length >= 4 && text.length <= 40) {
        NSString *_Nullable rep = SLApplyMetaEdits(text);
        if (rep.length) text = rep;
    }
    ((void (*)(id, SEL, id))orig)(self, _cmd, text);
}

static void SLChatLabelSetAttributedHook(id self, SEL _cmd, id as) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (!orig) return;
    if ([as isKindOfClass:[NSAttributedString class]]) {
        NSString *s = [(NSAttributedString *)as string];
        if (s.length >= 4 && s.length <= 40) {
            NSString *_Nullable rep = SLApplyMetaEdits(s);
            if (rep.length && ![rep isEqualToString:s]) {
                NSDictionary *attrs = [as attributesAtIndex:0 effectiveRange:NULL];
                as = [[NSMutableAttributedString alloc] initWithString:rep attributes:attrs];
            }
        }
    }
    ((void (*)(id, SEL, id))orig)(self, _cmd, as);
}

// 陌陌的气泡菜单是自绘的 MDChatUIMenuView + MDChatUIMenuItem，
// 往 items 数组尾部塞一项就能和原生项长得一模一样（字体/圆角/箭头都复用它的 cell）。
static const void *kSLCRMenuIndexKey = &kSLCRMenuIndexKey;

// 造一项原生样式的菜单项。图标照抄现有项的类型（UIImage 还是包内图片名），
// 抄不到就留空 —— 宁可没图标，也不能让菜单闪退。
static id SLCRMakeMenuItem(Class itemCls, NSString *title, id sampleImage,
                           NSString *sysSymbol, NSString *fallbackAsset) {
    id item = [[itemCls alloc] init];
    [item setValue:title forKey:@"title"];
    if ([sampleImage isKindOfClass:[UIImage class]]) {
        UIImage *icon = sysSymbol.length ? [UIImage systemImageNamed:sysSymbol] : nil;
        if (icon) [item setValue:icon forKey:@"image"];
    } else if ([sampleImage isKindOfClass:[NSString class]]) {
        NSString *name = sampleImage;
        if ([name hasPrefix:@"im_longPress_"]) name = fallbackAsset ?: name;
        [item setValue:name forKey:@"image"];
    }
    return item;
}

static NSArray *SLChatMenuPatchedItems(id menuView, NSArray *items) {
    if (!SLChatRewriteEnabled()) return items;
    if (![items isKindOfClass:[NSArray class]]) return items;
    Class itemCls = NSClassFromString(@"MDChatUIMenuItem");
    if (!itemCls) return items;
    @try {
        // 陌陌会连着走两个入口（一次构造、一次过滤），同一批项不能塞两遍。
        // 以「修改」为准 —— 它在就说明这一批已经补过了。
        for (id it in items) {
            NSString *t = nil;
            @try { t = [it valueForKey:@"title"]; } @catch (NSException *e) { }
            if ([t isEqualToString:@"修改"]) return items;
        }

        id sampleImage = nil;
        NSInteger sampleType = -1;
        for (id it in items) {
            if (sampleType < 0) {
                id t = nil;
                @try { t = [it valueForKey:@"itemType"]; } @catch (NSException *e) { }
                if (t) sampleType = [t integerValue];
            }
            id im = nil;
            @try { im = [it valueForKey:@"image"]; } @catch (NSException *e) { }
            if (im) { sampleImage = im; break; }
        }
        SLLog(@"REWRITE 菜单项图标：原生 image=%@(%@) itemType=%ld",
              sampleImage ? NSStringFromClass([sampleImage class]) : @"nil",
              [sampleImage isKindOfClass:[NSString class]] ? sampleImage : @"-",
              (long)sampleType);

        NSMutableArray *titles = [NSMutableArray array];
        for (id it in items) {
            NSString *t = nil;
            @try { t = [it valueForKey:@"title"]; } @catch (NSException *e) { }
            [titles addObject:t ?: @"?"];
        }
        SLLog(@"REWRITE 菜单原有项：[%@]", [titles componentsJoinedByString:@" | "]);

        NSMutableArray *out = [NSMutableArray arrayWithArray:items];
        // 「修改」插在「拷贝」后面（就地改文本，放一起最顺手）。
        // 时间 / 距离 / 日期不再进菜单 —— 改成「长按消息下方那行时间」直接改，更精准。
        NSUInteger at = out.count;
        for (NSUInteger i = 0; i < out.count; i++) {
            NSString *t = nil;
            @try { t = [out[i] valueForKey:@"title"]; } @catch (NSException *e) { }
            if ([t isEqualToString:@"拷贝"]) { at = i + 1; break; }
        }
        if (at > out.count) at = out.count;

        BOOL hasEdit = NO;
        for (id it in out) {
            NSString *t = nil;
            @try { t = [it valueForKey:@"title"]; } @catch (NSException *e) { }
            if ([t isEqualToString:@"修改"]) { hasEdit = YES; break; }
        }
        NSUInteger editIdx = NSNotFound;
        if (!hasEdit) {
            id editItem = SLCRMakeMenuItem(itemCls, @"修改", sampleImage,
                                           @"square.and.pencil", @"im_longPress_eit");
            [out insertObject:editItem atIndex:at];
            editIdx = at;
        } else {
            for (NSUInteger i = 0; i < out.count; i++) {
                NSString *t = nil;
                @try { t = [out[i] valueForKey:@"title"]; } @catch (NSException *e) { }
                if ([t isEqualToString:@"修改"]) { editIdx = i; break; }
            }
        }

        objc_setAssociatedObject(menuView, kSLCRMenuIndexKey,
                                 @(editIdx == NSNotFound ? -1 : (NSInteger)editIdx),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SLLog(@"REWRITE 菜单注入：原 %lu 项 → 现 %lu 项（修改@%ld）",
              (unsigned long)items.count, (unsigned long)out.count,
              editIdx == NSNotFound ? -1L : (long)editIdx);
        return out;
    } @catch (NSException *e) {
        SLLog(@"REWRITE 菜单注入失败：%@", e.reason);
        return items;
    }
}

static id SLChatMenuShowHook4(id self, SEL _cmd, id by, NSArray *items, CGRect rect, CGFloat bottom) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    NSArray *patched = SLChatMenuPatchedItems(self, items);
    if (!orig) return nil;
    return ((id (*)(id, SEL, id, NSArray *, CGRect, CGFloat))orig)(self, _cmd, by, patched, rect, bottom);
}

static id SLChatMenuShowHook3(id self, SEL _cmd, id by, NSArray *items, CGFloat bottom) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    NSArray *patched = SLChatMenuPatchedItems(self, items);
    if (!orig) return nil;
    return ((id (*)(id, SEL, id, NSArray *, CGFloat))orig)(self, _cmd, by, patched, bottom);
}

static void SLChatMenuDidSelectHook(id self, SEL _cmd, id cv, id ip) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    id mine = objc_getAssociatedObject(self, kSLCRMenuIndexKey);
    NSInteger editIdx = -1;
    if ([mine isKindOfClass:[NSNumber class]]) editIdx = [mine integerValue];
    else if ([mine isKindOfClass:[NSArray class]] && [mine count] >= 1) editIdx = [mine[0] integerValue];
    NSInteger tapped = -1;
    @try { tapped = [[ip valueForKey:@"item"] integerValue]; } @catch (NSException *e) { }
    if (tapped == editIdx && editIdx >= 0) {
        objc_setAssociatedObject(self, kSLCRMenuIndexKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL hideSel = NSSelectorFromString(@"hideMenu");
        if ([(id)self respondsToSelector:hideSel]) {
            IMP hideImp = [(id)self methodForSelector:hideSel];
            if (hideImp) ((void (*)(id, SEL))hideImp)(self, hideSel);
        }
        SLLog(@"REWRITE 点中「修改」 menu=%@", NSStringFromClass([self class]));
        SLChatRewriteBeginFromMenu((UIView *)self);
        return;
    }
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, cv, ip);
}

static void SLChatViewWillDisappearHook(id self, SEL _cmd, BOOL animated) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    @try { SLChatRewriteHandleLeave((UIViewController *)self); } @catch (NSException *e) { }
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);
}

// 时间行是 cell 复用时现场拼的（不是模型里的字段），所以每显示一格就按 msgid 刷一次：
// 「改过的那几条」贴自己存的值，没改过的原样。没改过任何一条时这里是一次字典查、直接返回。
static void SLChatWillDisplayCellHook(id self, SEL _cmd, UITableView *tv,
                                      UITableViewCell *cell, NSIndexPath *ip) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    if (orig) {
        ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))orig)(
            self, _cmd, tv, cell, ip);
    }
    // 时间行长按手势：每次显示都确保挂着（cell 复用会换 label，但按 label 实例去重）。
    // 必须放在 orig 之后 —— 这时时间行 UILabel 才拿到它的真实文本、能被形态识别认出来。
    @try { SLChatMetaAttachTimeLongPress(cell); } @catch (NSException *e) { }
    // 被拦下来的撤回：单格盖甲卡片（只动被拦的那条，别的消息不碰）。
    // 放在节流之前 —— 否则快速滚动时这一格会被跳过，卡片就不出现了。
    @try { SLRecallApplyCell(cell); } @catch (NSException *e) { }
    static NSTimeInterval lastT = 0;
    NSTimeInterval nowT = [[NSDate date] timeIntervalSince1970];
    if (lastT > 0 && nowT - lastT < 0.08) return;      // 一次滚动会连发十几下，节流
    lastT = nowT;
    @try { SLChatMetaApplyTable(tv); } @catch (NSException *e) { }
}

static BOOL SLCRTypeHas(Class cls, SEL sel, const char *needle) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    if (!t) return NO;
    return strstr(t, needle) != NULL;
}

// 撤回行高度自适应：被拦的撤回要显示甲卡片（含换行原文），得把行高撑起来。
// 只在被拦且未隐藏时撑高；其余行走原高度。取不到数据源就退化为不撑高（卡片顶对齐、可能截尾）。
extern BOOL SLRecallGuardEnabled(void);
extern BOOL SLRecallHidden(void);
extern BOOL SLRecallIsBlocked(NSString *mid);
extern NSString *SLRecallBlockedOriginal(NSString *mid);
extern CGFloat SLRecallCardHeight(NSString *orig, CGFloat tableWidth);
extern NSString *SLCRMsgidAtIndexPath(UITableView *tv, NSIndexPath *ip);

static CGFloat SLChatHeightHook(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    IMP orig = SLGetOrigIMP(self, _cmd);
    CGFloat (*o)(id, SEL, UITableView *, NSIndexPath *) = (void *)orig;
    CGFloat h = o ? o(self, _cmd, tv, ip) : 44.0;
    @try {
        if (SLRecallGuardEnabled() && !SLRecallHidden()) {
            NSString *mid = SLCRMsgidAtIndexPath(tv, ip);
            if (mid.length && SLRecallIsBlocked(mid)) {
                CGFloat want = SLRecallCardHeight(SLRecallBlockedOriginal(mid),
                                                 CGRectGetWidth(tv.bounds));
                if (want > h) h = want;
            }
        }
    } @catch (NSException *e) {}
    return h;
}

static void SLInstallChatRewriteHooks(void) {
    static BOOL done = NO;
    if (done) return;

    NSMutableArray *hits = [NSMutableArray array];
    NSArray *msgClasses = @[@"MDBaseMessage", @"MDTextChatMessage", @"MDSingleMessage",
                            @"MDGroupMessage", @"MDUniverseMessage", @"MDFastChatMessage"];
    for (NSString *n in msgClasses) {
        Class c = SLClassByName([n UTF8String]);
        if (!c) continue;
        if (SLRegisterMethod(c, NSSelectorFromString(@"body"), (IMP)SLChatBodyGetHook)) {
            [hits addObject:n];
        }
        if (SLRegisterMethod(c, NSSelectorFromString(@"textv2"), (IMP)SLChatTextV2GetHook)) {
            [hits addObject:[n stringByAppendingString:@".textv2"]];
        }
    }

    Class menu = SLClassByName("MDChatUIMenuView");
    if (menu) {
        SEL s4 = NSSelectorFromString(@"showBy:withItems:rect:bottomHeight:");
        if (SLCRTypeHas(menu, s4, "{CGRect=") &&
            SLRegisterMethod(menu, s4, (IMP)SLChatMenuShowHook4)) {
            [hits addObject:@"menu4"];
        }
        SEL s3 = NSSelectorFromString(@"showBy:withItems:bottomHeight:");
        if (SLRegisterMethod(menu, s3, (IMP)SLChatMenuShowHook3)) {
            [hits addObject:@"menu3"];
        }
        if (SLRegisterMethod(menu, NSSelectorFromString(@"collectionView:didSelectItemAtIndexPath:"),
                             (IMP)SLChatMenuDidSelectHook)) {
            [hits addObject:@"menuSel"];
        }
    }

    Class chatVC = SLClassByName("MDChatBaseViewController");
    if (chatVC) {
        SEL leave = NSSelectorFromString(@"viewWillDisappear:");
        if (SLRegisterMethod(chatVC, leave, (IMP)SLChatViewWillDisappearHook)) {
            [hits addObject:@"chatLeave"];
        }
    }

    // 单聊页的 willDisplayCell：时间行（"12:48 35.95km"）在 cell 复用时才算出来，
    // 没有它就只能在「保存那一刻」刷一次，滚一下又变回原样。
    NSArray *cellVCs = @[@"MDChatSingleViewController", @"MDChatUniverseViewController",
                         @"MDChatGroupViewController"];
    for (NSString *n in cellVCs) {
        Class c = SLClassByName([n UTF8String]);
        if (!c) continue;
        if (SLRegisterMethod(c, NSSelectorFromString(@"tableView:willDisplayCell:forRowAtIndexPath:"),
                             (IMP)SLChatWillDisplayCellHook)) {
            [hits addObject:[n stringByAppendingString:@".willDisplay"]];
        }
        if (SLRegisterMethod(c, NSSelectorFromString(@"tableView:heightForRowAtIndexPath:"),
                             (IMP)SLChatHeightHook)) {
            [hits addObject:[n stringByAppendingString:@".height"]];
        }
    }

    // 渲染层：气泡标签最后落字的那一步
    Class mixLabel = SLClassByName("MDMixLabel");
    if (mixLabel) {
        if (SLRegisterMethod(mixLabel, NSSelectorFromString(@"setText:"),
                             (IMP)SLChatMixLabelSetTextHook)) {
            [hits addObject:@"mixText"];
        }
        if (SLRegisterMethod(mixLabel, NSSelectorFromString(@"setAttributedString:"),
                             (IMP)SLChatMixLabelSetAttributedHook)) {
            [hits addObject:@"mixAttr"];
        }
    }

    // 消息下方「时间 + 距离」那行最后落在普通 UILabel 上
    if (SLRegisterMethod([UILabel class], NSSelectorFromString(@"setText:"),
                         (IMP)SLChatLabelSetTextHook)) {
        [hits addObject:@"labelText"];
    }
    if (SLRegisterMethod([UILabel class], NSSelectorFromString(@"setAttributedText:"),
                         (IMP)SLChatLabelSetAttributedHook)) {
        [hits addObject:@"labelAttr"];
    }

    if (hits.count) {
        done = YES;
        SLLog(@"REWRITE-HOOK %@", [hits componentsJoinedByString:@" "]);
    }
}

static void SLInstallHooks(void) {
    // v0.4.52：去掉「只装 3 轮」的硬上限。
    // 0.4.52 为了少刷日志把窗口从 6 轮/10 秒砍到 3 轮/3 秒，代价是：
    // 小宇宙这类懒加载模块的类在启动 3 秒后才 realize，就永远装不上钩子（0.4.52.9 能用、0.4.52 不能的真因）。
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
    // v0.4.52：小宇宙 handler 诊断（只打一次）+ sendContent: 正式接管
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
        SLLog(@"UNIV 口令 cmd=%@（语音包口令已删）", SLCommand());
        if (uh) SLInstallOneObjectHook(uh, NSSelectorFromString(@"sendContent:"), (IMP)SLUniverseContentHook);
    }
    // 录音机临时路径（拿得到就直接命中真实录音文件）
    SLInstallTempPathHook(NSClassFromString(@"MDAudioRecorder"));
    // v0.4.52 核心：接管陌陌录音的 PCM 流（AI 语音替换的落地位置）
    SLInstallBusPCMHooks();
    SLInstallFunnelHooks();
    SLInstallServiceHook();
    // v0.4.52：虚拟定位（不开时全透传）
    @try { SLInstallVirtualLocationHooks(); } @catch (NSException *e) {}
    // v0.4.52：UIButton configuration 断言兜底
    @try { SLInstallUIButtonGuard(); } @catch (NSException *e) {}
    // v0.4.52：事件探针（抓小宇宙私聊的真实发送入口，只记录不改行为）
    @try { SLInstallActionProbe(); } @catch (NSException *e) {}
    // v0.4.96：时刻拍摄页几何诊断（只读，不装任何 method hook）
    @try { SLDiagMomentInstall(); } @catch (NSException *e) {}
    // v0.4.97：聊天记录修改（只拦 body getter + 气泡菜单注入，不碰陌陌数据库）
    @try { SLInstallChatRewriteHooks(); } @catch (NSException *e) {}
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
        // v0.4.52：轮次从 2 次拉回 6 次（覆盖启动后 12 秒）。状态摘要仍只在最后一轮打一次。
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { SLInstallHooks(); } @catch (NSException *e) {}
                if (i == 6) SLLog(@"%@", SLHookStatusSummary());
            });
        }
        // v0.4.52：App 每次回前台都补装一次。小宇宙这些模块是「第一次点进去才加载类」，
        // 只在启动那几秒装钩子必然漏；回前台 = 模块已加载，这一轮就能补上。
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            @try { SLInstallHooks(); } @catch (NSException *e) {}
            // v0.4.63：CENSUS 会 objc_getClassList 枚举全部类并 class_copyMethodList，
            // 纯诊断（只写日志）却跑在主线程，每次回前台都卡一下。挪到后台队列，
            // 主线程不再被类表遍历阻塞（tweak 被多个 Momo 进程加载时尤其明显）。
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @try { SLDumpUniverseClassesOnce(); } @catch (NSException *e) {}
            });
        }];
        // v0.4.53：切后台时若还挂着录音态，强制落定。
        // 后台不会再出帧，与其让球红着挂在那儿、切回来还是红的，不如当场收干净。
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            if (gSLRecordingUI) {
                SLLog(@"REC-UI 进后台强制落定");
                SLMarkRecordingEnded();
            }
        }];
    });
}
