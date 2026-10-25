#import <Foundation/Foundation.h>

typedef void(^SLPipelineResult)(BOOL ok, NSString *outPath, double duration, NSString *message);

@interface SLPipeline : NSObject
+ (instancetype)shared;
// 输入：陌陌录音文件；输出：可写回原路径的合成音频 + 新时长
- (void)enhanceRecordedAudioAtPath:(NSString *)path
                 originalDuration:(double)origDuration
                       completion:(SLPipelineResult)completion;
@end
