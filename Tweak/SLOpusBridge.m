// SLOpusBridge 实现：调用陌陌 MDAudioStreamBus 把 PCM 写成 Ogg Opus

#import "SLOpusBridge.h"
#import "SLLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>

// 保持 bus 存活到文件收尾（ARC 下 static 赋值即 retain）
static id gSLBusRef = nil;

static NSMethodSignature *SLSigFor(Class cls, SEL sel) {
    if (!cls || !sel) return nil;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return nil;
    const char *t = method_getTypeEncoding(m);
    if (!t) return nil;
    @try {
        return [NSMethodSignature signatureWithObjCTypes:t];
    } @catch (NSException *e) {
        return nil;
    }
}

// 按签名第 index 个参数的真实类型，塞一个 NSInteger 类标量
static void SLSetIntArg(NSInvocation *inv, NSMethodSignature *sig, NSUInteger index, long long value) {
    if (index >= sig.numberOfArguments) return;
    const char *t = [sig getArgumentTypeAtIndex:index];
    if (!t) return;
    switch (t[0]) {
        case 'c': case 'B': { char v = (char)value; [inv setArgument:&v atIndex:index]; break; }
        case 'C': { unsigned char v = (unsigned char)value; [inv setArgument:&v atIndex:index]; break; }
        case 's': { short v = (short)value; [inv setArgument:&v atIndex:index]; break; }
        case 'S': { unsigned short v = (unsigned short)value; [inv setArgument:&v atIndex:index]; break; }
        case 'i': { int v = (int)value; [inv setArgument:&v atIndex:index]; break; }
        case 'I': { unsigned int v = (unsigned int)value; [inv setArgument:&v atIndex:index]; break; }
        case 'l': { long v = (long)value; [inv setArgument:&v atIndex:index]; break; }
        case 'L': { unsigned long v = (unsigned long)value; [inv setArgument:&v atIndex:index]; break; }
        case 'q': { long long v = (long long)value; [inv setArgument:&v atIndex:index]; break; }
        case 'Q': { unsigned long long v = (unsigned long long)value; [inv setArgument:&v atIndex:index]; break; }
        default: break;
    }
}

// 塞一个对象参数（只在该位确实是 @ 的时候塞）
static void SLSetObjArg(NSInvocation *inv, NSMethodSignature *sig, NSUInteger index, id obj) {
    if (index >= sig.numberOfArguments) return;
    const char *t = [sig getArgumentTypeAtIndex:index];
    if (!t || t[0] != '@') return;
    id v = obj;
    [inv setArgument:&v atIndex:index];
}

static unsigned long long SLFileSize(NSString *path) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [[a objectForKey:NSFileSize] unsignedLongLongValue];
}

// 轮询到「文件大小连续两次相同且 > 0」，说明 bus 已经把 EOS 页刷盘
static void SLPollStableSize(NSString *path, unsigned long long prev, int left,
                             void (^done)(BOOL ok, unsigned long long size)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long sz = SLFileSize(path);
        if (sz > 0 && sz == prev) { done(YES, sz); return; }
        if (left <= 0) { done(sz > 0, sz); return; }
        SLPollStableSize(path, sz, left - 1, done);
    });
}

@implementation SLOpusBridge

+ (BOOL)available {
    return NSClassFromString(@"MDAudioStreamBus") != nil;
}

+ (void)encodePCM:(NSData *)pcm
        sampleRate:(double)rate
          channels:(UInt32)channels
        toOpusPath:(NSString *)outPath
        completion:(void (^)(BOOL, NSString *, double, unsigned long long))completion {

    void (^finish)(BOOL, NSString *, double, unsigned long long) = ^(BOOL ok, NSString *p, double d, unsigned long long b) {
        if (completion) completion(ok, p, d, b);
    };

    if (pcm.length < 320 || outPath.length == 0) { finish(NO, outPath, 0, 0); return; }
    if (rate < 8000) rate = 16000;
    if (channels < 1) channels = 1;

    Class cls = NSClassFromString(@"MDAudioStreamBus");
    SEL initSel  = NSSelectorFromString(@"initWithOpusPath:blockQueue:partEncoded:completion:");
    SEL prepSel  = NSSelectorFromString(@"sendPcmPrepareWithASBD:");
    SEL feedSel  = NSSelectorFromString(@"sendPcm:byteSize:");
    SEL overSel  = NSSelectorFromString(@"sendPcmOver");

    NSMethodSignature *initSig = SLSigFor(cls, initSel);
    NSMethodSignature *prepSig = SLSigFor(cls, prepSel);
    NSMethodSignature *feedSig = SLSigFor(cls, feedSel);
    NSMethodSignature *overSig = SLSigFor(cls, overSel);
    if (!initSig || !prepSig || !feedSig || !overSig) {
        SLLog(@"OPUS-ENC 缺少陌陌方法 init=%d prep=%d feed=%d over=%d", !!initSig, !!prepSig, !!feedSig, !!overSig);
        finish(NO, outPath, 0, 0);
        return;
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:[outPath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

    id bus = nil;
    @try {
        // 1) alloc + initWithOpusPath:blockQueue:partEncoded:completion:
        id allocated = [cls alloc];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:initSig];
        [inv setTarget:allocated];
        [inv setSelector:initSel];
        SLSetObjArg(inv, initSig, 2, outPath);
        // blockQueue：给一个自己的串行队列，避免它内部 dispatch 到 nil
        __block dispatch_queue_t q = dispatch_queue_create("com.shenglin.opusbus", DISPATCH_QUEUE_SERIAL);
        SLSetObjArg(inv, initSig, 3, q);

        // partEncoded
        if (initSig.numberOfArguments > 4) {
            const char *t = [initSig getArgumentTypeAtIndex:4];
            if (t && (t[0] == '@')) {
                SLSetObjArg(inv, initSig, 4, @(NO));
            } else {
                SLSetIntArg(inv, initSig, 4, 0);
            }
        }
        // completion：给一个空 block（给 nil 而它真去调就会崩）
        if (initSig.numberOfArguments > 5) {
            const char *t = [initSig getArgumentTypeAtIndex:5];
            if (t && t[0] == '@') {
                void (^noop)(void) = ^{};
                SLSetObjArg(inv, initSig, 5, noop);
            }
        }
        [inv invoke];
        void *ret = NULL;
        const char *rt = [initSig methodReturnType];
        if (rt && rt[0] == '@') [inv getReturnValue:&ret];
        bus = ret ? (__bridge id)ret : allocated;
        gSLBusRef = bus;
        SLLog(@"OPUS-ENC bus=%@ path=%@ rate=%.0f ch=%u pcm=%lu",
              NSStringFromClass([bus class]), outPath, rate, (unsigned int)channels,
              (unsigned long)pcm.length);
    } @catch (NSException *e) {
        SLLog(@"OPUS-ENC init 异常 %@", e);
        finish(NO, outPath, 0, 0);
        return;
    }
    if (!bus) { finish(NO, outPath, 0, 0); return; }

    // 2) sendPcmPrepareWithASBD:
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = 16;
    asbd.mBytesPerFrame = 2 * channels;
    asbd.mBytesPerPacket = 2 * channels;
    @try {
        NSInvocation *p = [NSInvocation invocationWithMethodSignature:prepSig];
        [p setTarget:bus];
        [p setSelector:prepSel];
        if (prepSig.numberOfArguments > 2) {
            const char *t = [prepSig getArgumentTypeAtIndex:2];
            if (t && t[0] == '^') {              // 传的是指针
                void *ptr = &asbd;
                [p setArgument:&ptr atIndex:2];
            } else {                             // 传的是结构体本身
                [p setArgument:&asbd atIndex:2];
            }
        }
        [p invoke];
    } @catch (NSException *e) {
        SLLog(@"OPUS-ENC prepare 异常 %@", e);
        finish(NO, outPath, 0, 0);
        return;
    }

    // 3) sendPcm:byteSize: 分块喂 PCM
    const char *t2 = feedSig.numberOfArguments > 2 ? [feedSig getArgumentTypeAtIndex:2] : NULL;
    const char *t3 = feedSig.numberOfArguments > 3 ? [feedSig getArgumentTypeAtIndex:3] : NULL;
    const NSUInteger chunk = 3200;   // 100ms @16k mono s16
    BOOL objArg = (t2 && t2[0] == '@');
    @try {
        for (NSUInteger off = 0; off < pcm.length; off += chunk) {
            NSUInteger n = MIN(chunk, pcm.length - off);
            NSInvocation *f = [NSInvocation invocationWithMethodSignature:feedSig];
            [f setTarget:bus];
            [f setSelector:feedSel];
            if (objArg) {
                NSData *d = [pcm subdataWithRange:NSMakeRange(off, n)];
                SLSetObjArg(f, feedSig, 2, d);
            } else {
                const void *p = (const char *)pcm.bytes + off;
                [f setArgument:&p atIndex:2];
            }
            if (t3) {
                switch (t3[0]) {
                    case 'Q': { unsigned long long v = n; [f setArgument:&v atIndex:3]; break; }
                    case 'I': { unsigned int v = (unsigned int)n; [f setArgument:&v atIndex:3]; break; }
                    case 'q': { long long v = (long long)n; [f setArgument:&v atIndex:3]; break; }
                    case 'i': { int v = (int)n; [f setArgument:&v atIndex:3]; break; }
                    case 'L': { unsigned long v = (unsigned long)n; [f setArgument:&v atIndex:3]; break; }
                    case 'l': { long v = (long)n; [f setArgument:&v atIndex:3]; break; }
                    default: break;
                }
            }
            [f invoke];
        }
    } @catch (NSException *e) {
        SLLog(@"OPUS-ENC feed 异常 %@", e);
        finish(NO, outPath, 0, 0);
        return;
    }

    // 4) sendPcmOver：收尾写 EOS 页
    @try {
        NSInvocation *o = [NSInvocation invocationWithMethodSignature:overSig];
        [o setTarget:bus];
        [o setSelector:overSel];
        [o invoke];
    } @catch (NSException *e) {
        SLLog(@"OPUS-ENC over 异常 %@", e);
    }

    double dur = (double)(pcm.length / (2 * channels)) / rate;

    // 5) 等文件刷盘稳定，再看魔数（Ogg 是 "OggS"）
    SLPollStableSize(outPath, 0, 40, ^(BOOL ok, unsigned long long size) {
        BOOL magicOk = NO;
        if (ok) {
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:outPath];
            NSData *head = [fh readDataOfLength:16];
            [fh closeFile];
            const uint8_t *b = head.bytes;
            magicOk = (head.length >= 4 && b[0] == 'O' && b[1] == 'g' && b[2] == 'g' && b[3] == 'S');
            SLLog(@"OPUS-ENC done path=%@ bytes=%llu dur=%.2f magic=%@ magicOk=%d",
                  outPath, size, dur,
                  head.length >= 4 ? [NSString stringWithFormat:@"%c%c%c%c",
                                      b[0], b[1], b[2], b[3]] : @"(empty)", (int)magicOk);
        } else {
            SLLog(@"OPUS-ENC 失败：没有产出文件 %@", outPath);
        }
        gSLBusRef = nil;
        // 只要陌陌的 bus 真写出了东西（>200 字节）就用它 —— 容器是它自己写的，
        // 即便魔数不是 OggS 也是陌陌自己的格式（覆盖时会把两边魔数一起记进日志）。
        BOOL usable = (ok && size > 200);
        dispatch_async(dispatch_get_main_queue(), ^{
            finish(usable, outPath, dur, size);
        });
    });
}

@end
