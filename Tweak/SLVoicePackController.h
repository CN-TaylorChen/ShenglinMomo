#import <UIKit/UIKit.h>

// v0.4.9.6：改成真文件夹两级结构
//   一级页（init）：启用开关 + 文件夹列表 + 未分组音频
//   二级页（initInFolder:）：某个文件夹里的音频
@interface SLVoicePackController : UITableViewController

/// 直接进到某个文件夹的内容页；传 nil 或空 = 一级页
- (instancetype)initInFolder:(NSString *)folder;

@end
