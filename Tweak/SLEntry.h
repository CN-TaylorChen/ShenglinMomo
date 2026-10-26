#import <UIKit/UIKit.h>

// 陌陌版浮动入口按钮（可拖动，位置记忆）
void SLEnsureFloatButton(void);
void SLStartEntryWatcher(void);

// v0.4.5：悬浮球图标可换（文字 / 表情 / 自选图片）
void SLRefreshFloatButton(void);        // 改完设置后立刻刷新已挂载的按钮
NSString *SLFloatIconSummary(void);     // 设置页右侧显示当前图标

@interface SLFloatIconController : UITableViewController
@end
