// AMR-NB 编码：TTS 音频 → 陌陌语音消息格式
// 依赖：AudioToolbox(ExtAudioFile) + opencore-amrnb 静态库（可选，未链接时降级）

#import "SLAMREncoder.h"
#import "SLLog.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#ifdef SL_HAS_AMR
#import "interf_enc.h"
#endif

#define SL_AMR_FRAME_SAMPLES 160   // 20ms @ 8kHz
#define SL_AMR_MAGIC "#!AMR\n"

@implementation SLAMREncoder

+ (BOOL)available {
#ifdef SL_HAS_AMR
    return YES;
#else
    return NO;
#endif
}

+ (NSData *)pcm8kMono16AtPath:(NSString *)inPath {
    if (inPath.length == 0) return nil;
    NSURL *url = [NSURL fileURLWithPath:inPath];
    ExtAudioFileRef f = NULL;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) != noErr || !f) {
        SLLog(@"ExtAudioFileOpenURL failed %@", inPath);
        return nil;
    }

    AudioStreamBasicDescription cf;
    memset(&cf, 0, sizeof(cf));
    cf.mSampleRate = 8000.0;
    cf.mFormatID = kAudioFormatLinearPCM;
    cf.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    cf.mFramesPerPacket = 1;
    cf.mChannelsPerFrame = 1;
    cf.mBitsPerChannel = 16;
    cf.mBytesPerFrame = 2;
    cf.mBytesPerPacket = 2;

    if (ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(cf), &cf) != noErr) {
        SLLog(@"set client format failed");
        ExtAudioFileDispose(f);
        return nil;
    }

    const UInt32 kFrames = SL_AMR_FRAME_SAMPLES * 100;
    NSMutableData *out = [NSMutableData data];
    AudioBufferList abl;
    memset(&abl, 0, sizeof(abl));
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = 1;
    abl.mBuffers[0].mDataByteSize = kFrames * 2;
    abl.mBuffers[0].mData = malloc(kFrames * 2);

    while (YES) {
        UInt32 frames = kFrames;
        abl.mBuffers[0].mDataByteSize = kFrames * 2;
        OSStatus s = ExtAudioFileRead(f, &frames, &abl);
        if (s != noErr || frames == 0) break;
        [out appendBytes:abl.mBuffers[0].mData length:frames * 2];
    }

    free(abl.mBuffers[0].mData);
    ExtAudioFileDispose(f);
    SLLog(@"pcm bytes=%lu (%.2fs)", (unsigned long)out.length, (double)(out.length / 2) / 8000.0);
    return out.length ? out : nil;
}

+ (BOOL)encodeFileAtPath:(NSString *)inPath toAMRPath:(NSString *)outPath duration:(double *)durOut {
#ifdef SL_HAS_AMR
    NSData *pcm = [self pcm8kMono16AtPath:inPath];
    if (pcm.length < SL_AMR_FRAME_SAMPLES * 2) {
        SLLog(@"pcm too short");
        return NO;
    }
    const short *samples = (const short *)pcm.bytes;
    NSUInteger totalSamples = pcm.length / 2;
    NSUInteger frames = totalSamples / SL_AMR_FRAME_SAMPLES;

    void *st = Encoder_Interface_init(0);
    if (!st) {
        SLLog(@"amr encoder init failed");
        return NO;
    }

    NSMutableData *out = [NSMutableData data];
    [out appendBytes:SL_AMR_MAGIC length:6];
    unsigned char buf[128];
    NSUInteger written = 0;
    for (NSUInteger i = 0; i < frames; i++) {
        int n = Encoder_Interface_Encode(st, MR122, samples + i * SL_AMR_FRAME_SAMPLES, buf, 0);
        if (n > 0) {
            [out appendBytes:buf length:(NSUInteger)n];
            written++;
        }
    }
    Encoder_Interface_exit(st);

    if (written == 0) return NO;
    if (durOut) *durOut = (double)written * 0.02;
    NSError *err = nil;
    BOOL ok = [out writeToFile:outPath options:NSDataWritingAtomic error:&err];
    SLLog(@"amr frames=%lu bytes=%lu dur=%.2f ok=%d", (unsigned long)written,
          (unsigned long)out.length, (double)written * 0.02, ok);
    return ok;
#else
    SLLog(@"amr encoder not linked in this build");
    return NO;
#endif
}

@end
