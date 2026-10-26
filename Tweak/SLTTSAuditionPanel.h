//
//  SLTTSAuditionPanel.h
//  #tts 合成完成后的试听卡片
//
//  合成好的音频本来就落了盘（gSLTTSAudioPath），原来直接「装填」等用户录音替换，
//  用户听不到结果。这里在装填之后、启动 60 秒倒计时之前插一张卡片：
//  先听，确认了才进入「去录音替换」，不满意就取消或重新合成。
//

#import <UIKit/UIKit.h>

@interface SLTTSAuditionPanel : NSObject

// 默认开。设置页「音色与情绪」里的开关。
+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)on;

// 播放器用独立 AVAudioPlayer，不碰陌陌自己的播放器实例。
+ (void)presentWithAudioPath:(NSString *)path
                    duration:(double)duration
                        text:(NSString *)text
                       onUse:(void (^)(void))onUse
                    onCancel:(void (^)(void))onCancel
                     onRetry:(void (^)(void))onRetry;

+ (BOOL)isShowing;
+ (void)stopAndDismiss;

@end
