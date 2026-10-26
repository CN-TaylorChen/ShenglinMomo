//
//  SLTTSAuditionPanel.h
//  #tts 合成完成后的试听卡片
//
//  合成好的音频本来就落了盘（gSLTTSAudioPath），原来直接「装填」等用户录音替换，
//  用户听不到结果。这里在装填之后、启动 60 秒倒计时之前插一张卡片：
//  先听，确认了才进入「去录音替换」，不满意就取消或重新合成。
//
//  v0.4.13：试听不再播发给陌陌的 .amr —— AVAudioPlayer 对 AMR 的 prepareToPlay
//  会返回 NO（play 也跟着失败，界面就卡在「无法播放」）。改用内存里的 16k PCM
//  现场写一个 WAV 来播，PCM 是最稳的路径，不需要任何解码器。
//

#import <UIKit/UIKit.h>

@interface SLTTSAuditionPanel : NSObject

// 默认开。设置页「音色与情绪」里的开关。
+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)on;

// audioPath：最终发给陌陌的音频（.amr），仅作为兜底与展示用
// pcm16k   ：16kHz / mono / s16le 的裸 PCM，有值就用它生成 WAV 试听
+ (void)presentWithAudioPath:(NSString *)path
                      pcm16k:(NSData *)pcm16k
                    duration:(double)duration
                        text:(NSString *)text
                       onUse:(void (^)(void))onUse
                    onCancel:(void (^)(void))onCancel
                     onRetry:(void (^)(void))onRetry;

+ (BOOL)isShowing;
+ (void)stopAndDismiss;

@end
