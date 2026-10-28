//
//  SLGlass.h
//  声临 · 陌陌版 —— 全站统一的玻璃外观基座
//
//  v0.4.50：设置页那套材质（超薄毛玻璃底 + 玻璃片单元格 + 发丝高光边）原本只落在
//  设置页和语音包页里，API 凭证 / 音色库 / 运行日志 / 悬浮球图标 / 导入 / 裁剪 / 收藏
//  还是各自的 systemGroupedBackground，点进去立刻从「玻璃卡」掉回「系统灰页」。
//  这里把材质和胶囊控件抽出来，谁 import 谁就自动是同一套观感。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 玻璃片单元格底色（深色 6% 白 / 浅色 34% 白）。设置页、语音包页、全站二级页共用同一个数。
UIColor *SLGlassCellColor(void);

/// 给表格铺玻璃：table 本身透明 + backgroundView 换成超薄毛玻璃（设置页那张）。
void SLApplyGlassTable(UITableView *tv);

/// 给任意 view 铺玻璃底（自绘页面 / 日志页用），返回铺好的 blur，调用方可继续往 contentView 里放东西。
UIVisualEffectView *_Nullable SLInstallGlassBackdrop(UIView *host);

/// 胶囊导航按钮（毛玻璃 + 文字 + 发丝高光），用于「完成 / 保存 / 刷新 / 复制 / 清空」。
UIBarButtonItem *SLPillBarItem(NSString *title, id target, SEL action);

/// 胶囊图标按钮（返回箭头之类）。icon 为空时退回文字。
UIBarButtonItem *SLPillIconBarItem(NSString *_Nullable systemName,
                                   NSString *_Nullable fallbackTitle,
                                   id target, SEL action);

/// 胶囊标题（二级页复用设置页那套：毛玻璃胶囊 + 15pt 文字）。
UIView *SLPillTitleView(NSString *text);

NS_ASSUME_NONNULL_END
