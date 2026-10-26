// 声临 · Fish 音色导入（v0.4.9）
// 三种来源：我的音色（self=true）/ 搜公开库（title 关键词）/ 粘贴 JSON
// 只收 Fish 音色；导入后统一并入「我导入的音色」分区，与收藏分开

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SLImportMode) {
    SLImportModeMine = 0,     // 我账号下的音色
    SLImportModeSearch,       // 搜 Fish 公开音色库
    SLImportModePaste         // 粘贴 JSON
};

@interface SLVoiceImportController : UITableViewController

@property (nonatomic, assign) SLImportMode initialMode;
@property (nonatomic, copy) void (^onImported)(NSInteger added, NSInteger updated);

@end
