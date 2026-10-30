#import <UIKit/UIKit.h>

// 陌陌版浮动入口按钮（可拖动，位置记忆）
void SLEnsureFloatButton(void);
void SLStartEntryWatcher(void);

// v0.4.5：悬浮球图标可换（文字 / 表情 / 自选图片）
void SLRefreshFloatButton(void);        // 改完设置后立刻刷新已挂载的按钮
NSString *SLFloatIconSummary(void);     // 设置页右侧显示当前图标

// v0.4.54：把球抬到最上层。
// 设置浮窗 / 试听卡片都是 OverFullScreen 呈现，会盖在球上面（球一半被卡片压住）。
// 面板每次出现后调一次：球若换了窗口先迁过去，再在同一个窗口里 bringSubviewToFront。
void SLRaiseFloatButton(void);

// v0.4.33：品牌图标（黑底 + 六根声波条），代码绘制，不依赖任何图片资源。
// 设置页标题栏和悬浮球共用同一张，保证两处视觉一致。
UIImage *SLBrandIconImage(CGFloat side);
UIImage *SLBrandIconImageTinted(CGFloat side, UIColor *bg);

// v0.4.34：悬浮球三态。录音红 / 合成蓝 / 就绪蓝常亮（直到语音真正发出去）。
// v0.4.36：就绪不再自动回空闲；Ready → Idle 的切换会外扩一圈涟漪。
// Tweak.x 只在钩子里调这个，界面细节全部留在 SLEntry.m。
typedef NS_ENUM(NSInteger, SLFloatState) {
    SLFloatStateIdle = 0,
    SLFloatStateRecording = 1,
    SLFloatStateSynthesizing = 2,
    SLFloatStateReady = 3,
};
void SLFloatSetState(SLFloatState state);

// v0.4.60：同上，但不触发「合成完成」的缩放回弹。
// 试听面板呈现时用这个：面板自己有弹入动画，球再缩一下会撞车。
void SLFloatSetStateQuiet(SLFloatState state);

// v0.4.82：合成状态并进悬浮胶囊，不再有独立进度卡片（原来那张浮在球上方，遮聊天记录）。
// 合成开始 → 胶囊自动展开：左端图标保持状态色，中间「合成中 / 已等 12s · 上限 30s」，
// 右端一个「取消」小胶囊，底部一条 2pt 时间条按「已等待 / 上限」推进。
// 取消块由调用方提供；约定「取消后把口令写回输入框、球回落灰、不发送」。
void SLFloatTTSBegin(NSTimeInterval limitSec, void (^cancelBlock)(void));

// success=YES：0.2s 收起回绿球，不弹任何提示。
// success=NO ：胶囊原地转红，主行 failText、副行「口令已放回输入框」，停 2.2s 收球；
//              期间点胶囊会执行 retryBlock（重来一次合成），用户不用重打口令。
void SLFloatTTSEnd(BOOL success, NSString *failText, void (^retryBlock)(void));

// v0.4.34：设置 / 语音包都装在浮窗里，内部是子控制器，
// 点「完成」要先向上找到真正的呈现者，否则 dismiss 自己什么也不会发生。
void SLCloseHostingPanel(UIViewController *vc);

// v0.4.41：清掉当前装填的那一发（语音包 / #tts 合成音都算）。
// 语音包和「#tts 即时合成」共用同一个槽位，后写覆盖先写 —— 选包时调它把合成音赶走，
// 否则会出现「明明选了包，发出去却是刚才那段合成音」。实现放在 Tweak.x。
void SLClearArmedAudio(void);

@interface SLFloatIconController : UITableViewController
@end
