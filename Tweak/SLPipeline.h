#import <Foundation/Foundation.h>

typedef void(^SLPipelineResult)(BOOL ok, NSString *outPath, double duration, NSString *message);

@interface SLPipeline : NSObject
+ (instancetype)shared;
// 输入：陌陌录音文件；输出：可写回原路径的合成音频 + 新时长
- (void)enhanceRecordedAudioAtPath:(NSString *)path
                 originalDuration:(double)origDuration
                       completion:(SLPipelineResult)completion;

// 输入：#tts 后面的文字；输出：可直接交给陌陌发送的语音文件（默认 AMR）+ 时长
- (void)synthesizeMessageText:(NSString *)text
                   completion:(SLPipelineResult)completion;
@end
