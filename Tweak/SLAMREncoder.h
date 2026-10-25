#import <Foundation/Foundation.h>

// TTS 产出的音频（mp3/m4a/wav）→ 陌陌语音消息使用的 AMR-NB
// 只有编译时链接了 opencore-amrnb 静态库（SL_HAS_AMR）才有真编码能力，
// 否则 available 返回 NO，调用方直接发原始音频。
@interface SLAMREncoder : NSObject

+ (BOOL)available;

/// 编码为 AMR-NB 文件。durOut 返回时长（秒）。失败返回 NO。
+ (BOOL)encodeFileAtPath:(NSString *)inPath
              toAMRPath:(NSString *)outPath
               duration:(double *)durOut;

/// 把任意音频文件解码重采样为 8kHz / 16bit / 单声道 PCM（内部也用于调试）
+ (NSData *)pcm8kMono16AtPath:(NSString *)inPath;

@end
