//
//  SLFavoriteStore.h
//  收藏的定位位置：持久化在 NSUserDefaults，供选点页快速复用
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 收藏列表变化时发这个通知（选点页据此刷新星标状态）
extern NSString *const SLFavoriteStoreChanged;

@interface SLFavoriteItem : NSObject

/// 持久化标识（重命名/删除靠它精确定位，不受排序影响）
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) double lat;
@property (nonatomic, assign) double lng;
@property (nonatomic, copy, nullable) NSString *address;
@property (nonatomic, assign) NSTimeInterval createdAt;

@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;

/// 「31.240000, 121.490000」
- (NSString *)coordText;

/// 相对某个点的距离，「850 m」/「1.2 km」；坐标无效时返回空串
- (NSString *)distanceTextFrom:(CLLocationCoordinate2D)from;

@end


@interface SLFavoriteStore : NSObject

/// 按创建时间倒序
+ (NSArray<SLFavoriteItem *> *)items;
+ (NSUInteger)count;

/// meters 半径内最近的一条，没有返回 nil
+ (nullable SLFavoriteItem *)itemNear:(CLLocationCoordinate2D)coord within:(double)meters;

/// 同名或 100 米内视为同一个点，覆盖更新并返回 NO；否则新增返回 YES
+ (BOOL)saveName:(NSString *)name
      coordinate:(CLLocationCoordinate2D)coord
         address:(nullable NSString *)address;

+ (void)renameItem:(SLFavoriteItem *)item to:(NSString *)name;
+ (void)removeItem:(SLFavoriteItem *)item;
+ (void)moveFrom:(NSUInteger)from to:(NSUInteger)to;

@end

NS_ASSUME_NONNULL_END
