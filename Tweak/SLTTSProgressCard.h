//
//  SLTTSProgressCard.h
//  声临 · 陌陌版 —— 合成进度卡片（v0.4.81）
//
//  #tts 文字路径（≤60s）与语音转语音增强路径（≤120s）共用的「正在合成」指示。
//  显示：标题 + 时间进度条（按「已等待 / 上限」走，非真实百分比，因为 TTS 不回报进度）
//       + 倒计时 + 取消按钮。取消后由调用方决定如何兜底（本底包约定：保留输入框文字、
//       球回落灰、不发送）。
//
//  卡片本身只负责 UI 与计时；挂到哪个窗口、贴在浮球哪个位置由 SLEntry 决定。
//

#import <UIKit/UIKit.h>

@interface SLTTSProgressCard : UIView

/// 构造即开始计时。timeout 为兜底上限（秒）。
+ (instancetype)cardWithTimeout:(NSTimeInterval)timeout cancel:(void (^)(void))cancel;

/// 停表并从父视图移除（可重复调用，幂等）。
- (void)dismiss;

@end
