//
//  SLVirtualLocation.m
//  虚拟定位存储层
//

#import "SLVirtualLocation.h"
#import "SLLog.h"

static NSString *const kSLOffKey = @"SLVirtualLocOn";
static NSString *const kSLLatKey = @"SLVirtualLocLat";
static NSString *const kSLLngKey = @"SLVirtualLocLng";

// 内存镜像：-location 的钩子可能每秒被调用几十次，每次都读 NSUserDefaults 太重。
// 写操作时同步刷新，读操作只碰这几个静态变量。
static BOOL sSLVLLoaded = NO;
static BOOL sSLVLOn = NO;
static BOOL sSLVLHasCoord = NO;
static double sSLVLLat = 0;
static double sSLVLLng = 0;

@implementation SLVirtualLocation

+ (void)sl_loadIfNeeded {
    if (sSLVLLoaded) return;
    sSLVLLoaded = YES;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    sSLVLOn = [d boolForKey:kSLOffKey];
    // objectForKey 而不是 doubleForKey：后者未设置时返回 0，会被误当成「纬度 0 经度 0」这个合法坐标
    sSLVLHasCoord = ([d objectForKey:kSLLatKey] != nil && [d objectForKey:kSLLngKey] != nil);
    sSLVLLat = [d doubleForKey:kSLLatKey];
    sSLVLLng = [d doubleForKey:kSLLngKey];
}

+ (BOOL)isOn {
    [self sl_loadIfNeeded];
    return sSLVLOn;   // 只反映开关本身；是否真的生效由 fakeLocation 判断（要有坐标才行）
}

+ (void)setOn:(BOOL)on {
    [self sl_loadIfNeeded];
    sSLVLOn = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSLOffKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    SLLog(@"VLOC 开关 -> %@  %@", on ? @"开" : @"关", [self summary]);
}

+ (BOOL)hasCoordinate {
    [self sl_loadIfNeeded];
    return sSLVLHasCoord;
}

+ (CLLocationCoordinate2D)coordinate {
    [self sl_loadIfNeeded];
    return CLLocationCoordinate2DMake(sSLVLLat, sSLVLLng);
}

+ (void)setCoordinate:(CLLocationCoordinate2D)coord {
    if (!CLLocationCoordinate2DIsValid(coord)) return;
    [self sl_loadIfNeeded];
    sSLVLHasCoord = YES;
    sSLVLLat = coord.latitude;
    sSLVLLng = coord.longitude;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:coord.latitude forKey:kSLLatKey];
    [d setDouble:coord.longitude forKey:kSLLngKey];
    [d synchronize];
    SLLog(@"VLOC 坐标 -> %.6f, %.6f", coord.latitude, coord.longitude);
}

+ (void)clearCoordinate {
    [self sl_loadIfNeeded];
    sSLVLHasCoord = NO;
    sSLVLLat = 0;
    sSLVLLng = 0;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kSLLatKey];
    [d removeObjectForKey:kSLLngKey];
    [d synchronize];
    SLLog(@"VLOC 坐标已清除");
}

+ (NSString *)coordinateText {
    if (![self hasCoordinate]) return nil;
    CLLocationCoordinate2D c = [self coordinate];
    return [NSString stringWithFormat:@"%.6f, %.6f", c.latitude, c.longitude];
}

+ (CLLocation *)fakeLocation {
    [self sl_loadIfNeeded];
    if (!sSLVLOn || !sSLVLHasCoord) return nil;
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(sSLVLLat, sSLVLLng);
    if (!CLLocationCoordinate2DIsValid(c)) return nil;

    // 每次新建对象、时间戳取当前时刻：
    // 陌陌可能校验 location.timestamp 的新鲜度，复用同一个实例会被判定为「缓存过期位置」。
    // accuracy 给 10 米：太小(<=0)会被当成无效定位，太大又会落到「精度不足」的兜底逻辑。
    return [[CLLocation alloc] initWithCoordinate:c
                                        altitude:20.0
                              horizontalAccuracy:10.0
                                verticalAccuracy:10.0
                                       timestamp:[NSDate date]];
}

+ (NSString *)summary {
    if (![self isOn]) return [NSString stringWithFormat:@"关（坐标 %@）", [self coordinateText] ?: @"未设置"];
    return [NSString stringWithFormat:@"开 %@", [self coordinateText] ?: @"未设置坐标"];
}

@end
