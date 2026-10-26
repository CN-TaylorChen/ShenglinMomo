//
//  SLFavoriteController.h
//  收藏的位置：命名浮层 + 列表页
//

#import <UIKit/UIKit.h>
#import "SLFavoriteStore.h"

NS_ASSUME_NONNULL_BEGIN

/// 收藏命名浮层：全屏遮罩 + 居中卡片，快捷标签 + 输入框
@interface SLFavoriteEditor : UIView

+ (instancetype)showWithCoordinate:(CLLocationCoordinate2D)coord
                           address:(nullable NSString *)address
                          existing:(nullable SLFavoriteItem *)existing
                            onSave:(void (^)(NSString *name))onSave
                          onDelete:(nullable void (^)(void))onDelete;

@end


@interface SLFavoriteController : UIViewController

/// 选中某条收藏后回调（坐标 + 收藏名）
@property (nonatomic, copy, nullable) void (^onPick)(CLLocationCoordinate2D coord, NSString *_Nullable name);

@end

NS_ASSUME_NONNULL_END
