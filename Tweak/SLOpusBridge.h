// SLOpusBridge —— 借陌陌自己的 MDOpusEncoder / MDAudioStreamBus 把 PCM 编成 .opus
//
// 为什么必须这样：陌陌语音消息的真实落盘格式是 Ogg Opus
//   Library/Application Support/Chat_Audios_Temp/<token>.opus
// 而 v0.4.0 直接往这个文件里写 AMR 字节 → 陌陌/服务端解码失败 → 对端 0 秒空白语音。
// 陌陌的 bus 会自己写 Ogg 头 / OpusHead / OpusTags / EOS 页，产出与原生录音
// 完全同构的文件，所以这里不自己拼 Ogg 容器，直接调它的 API。
//
// 全部调用都走 NSInvocation（参数个数/类型从运行时 Method 签名取），
// 不硬编码签名 —— 陌陌改版也不会因为类型猜错而崩。

#import <Foundation/Foundation.h>

@interface SLOpusBridge : NSObject

// 陌陌的编码器类是否可用（MDAudioStreamBus 存在）
+ (BOOL)available;

// PCM（s16le、交错、mono/stereo 均可）→ Ogg Opus 文件
// completion 在后台队列回调；duration = pcm 对应的时长（秒）
+ (void)encodePCM:(NSData *)pcm
        sampleRate:(double)rate
          channels:(UInt32)channels
        toOpusPath:(NSString *)outPath
        completion:(void (^)(BOOL ok, NSString *path, double duration, unsigned long long bytes))completion;

@end
