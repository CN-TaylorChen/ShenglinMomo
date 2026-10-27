#import <UIKit/UIKit.h>

// 陌陌版浮动入口按钮（可拖动，位置记忆）
void SLEnsureFloatButton(void);
void SLStartEntryWatcher(void);

// v0.4.5：悬浮球图标可换（文字 / 表情 / 自选图片）
void SLRefreshFloatButton(void);        // 改完设置后立刻刷新已挂载的按钮
NSString *SLFloatIconSummary(void);     // 设置页右侧显示当前图标

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

// v0.4.34：设置 / 语音包都装在浮窗里，内部是子控制器，
// 点「完成」要先向上找到真正的呈现者，否则 dismiss 自己什么也不会发生。
void SLCloseHostingPanel(UIViewController *vc);

@interface SLFloatIconController : UITableViewController
@end
