//
//  SLMapPickerController.h
//  地图选点：拖动地图定位 + 关键词搜索，确认后回调坐标
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLMapPickerController : UIViewController

/// 选中后回调（坐标 + 地点名，地点名可能为 nil）
@property (nonatomic, copy, nullable) void (^onPick)(CLLocationCoordinate2D coord, NSString *_Nullable name);

/// 打开时的初始中心；不传则用已经设置过的坐标，再没有就落到默认点
- (instancetype)initWithCoordinate:(CLLocationCoordinate2D)coord hasInitial:(BOOL)hasInitial;

@end

NS_ASSUME_NONNULL_END
