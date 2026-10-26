// SLPCMTool 实现：线性插值重采样 + 声道复制

#import "SLPCMTool.h"
#import "SLLog.h"
#import <math.h>

@implementation SLPCMTool

+ (NSData *)convertPCM16kMono:(NSData *)pcm
                       toRate:(double)targetRate
                     channels:(UInt32)targetChannels {
    if (pcm.length < 2) return pcm;
    if (targetRate < 8000 || targetRate > 48000) return pcm;
    if (targetChannels < 1 || targetChannels > 2) targetChannels = 1;

    const double srcRate = 16000.0;
    BOOL sameRate = (fabs(targetRate - srcRate) < 0.5);
    if (sameRate && targetChannels == 1) return pcm;

    const int16_t *src = (const int16_t *)pcm.bytes;
    NSUInteger srcFrames = pcm.length / 2;
    if (srcFrames == 0) return pcm;

    NSUInteger dstFrames = sameRate ? srcFrames
                                    : (NSUInteger)((double)srcFrames * targetRate / srcRate);
    if (dstFrames == 0) return pcm;

    NSMutableData *out = [NSMutableData dataWithLength:dstFrames * targetChannels * 2];
    int16_t *dst = (int16_t *)out.mutableBytes;
    const double step = srcRate / targetRate;

    for (NSUInteger i = 0; i < dstFrames; i++) {
        int16_t v;
        if (sameRate) {
            v = src[i];
        } else {
            double pos = (double)i * step;
            NSUInteger i0 = (NSUInteger)pos;
            double frac = pos - (double)i0;
            if (i0 >= srcFrames) i0 = srcFrames - 1;
            NSUInteger i1 = (i0 + 1 < srcFrames) ? i0 + 1 : srcFrames - 1;
            double s = (double)src[i0] * (1.0 - frac) + (double)src[i1] * frac;
            if (s > 32767.0) s = 32767.0;
            if (s < -32768.0) s = -32768.0;
            v = (int16_t)s;
        }
        for (UInt32 c = 0; c < targetChannels; c++) {
            dst[i * targetChannels + c] = v;
        }
    }

    SLLog(@"pcm convert %.0f→%.0f ch=%u frames=%lu→%lu bytes=%lu",
          srcRate, targetRate, (unsigned int)targetChannels,
          (unsigned long)srcFrames, (unsigned long)dstFrames, (unsigned long)out.length);
    return out;
}

@end
