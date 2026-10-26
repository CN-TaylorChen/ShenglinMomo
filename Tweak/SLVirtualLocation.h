//
//  SLVirtualLocation.h
//  虚拟定位：把陌陌读到的坐标换成用户在地图上选的点
//
//  设计原则：默认关闭时 fakeLocation 返回 nil，所有钩子原样透传，
//  对现有功能零影响；只有手动开启且有坐标时才生效。
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLVirtualLocation : NSObject

/// 总开关（存 SLVirtualLocOn）
+ (BOOL)isOn;
+ (void)setOn:(BOOL)on;

/// 是否已经选过点（存 SLVirtualLocLat / SLVirtualLocLng）
+ (BOOL)hasCoordinate;
+ (CLLocationCoordinate2D)coordinate;
+ (void)setCoordinate:(CLLocationCoordinate2D)coord;
+ (void)clearCoordinate;

/// 「31.23040, 121.47370」形式的展示文本，未设置时返回 nil
+ (nullable NSString *)coordinateText;

/// 核心出口：开启且有坐标时返回伪造的 CLLocation，否则返回 nil。
/// 钩子拿到 nil 就原样透传，不做任何干预。
+ (nullable CLLocation *)fakeLocation;

/// 给日志用的一行摘要
+ (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
