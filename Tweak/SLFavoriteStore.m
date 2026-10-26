//
//  SLFavoriteStore.m
//  收藏定位位置的读写。存 NSUserDefaults，结构是一组字典，最多 50 条。
//

#import "SLFavoriteStore.h"

NSString *const SLFavoriteStoreChanged = @"SLFavoriteStoreChanged";

static NSString *const kSLFavKey = @"SLLocationFavorites";
static const NSUInteger kSLFavMax = 50;

@implementation SLFavoriteItem

- (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake(self.lat, self.lng);
}

- (NSString *)coordText {
    return [NSString stringWithFormat:@"%.6f, %.6f", self.lat, self.lng];
}

- (NSString *)distanceTextFrom:(CLLocationCoordinate2D)from {
    if (!CLLocationCoordinate2DIsValid(from)) return @"";
    CLLocation *a = [[CLLocation alloc] initWithLatitude:from.latitude longitude:from.longitude];
    CLLocation *b = [[CLLocation alloc] initWithLatitude:self.lat longitude:self.lng];
    double m = [b distanceFromLocation:a];
    if (m < 1000) return [NSString stringWithFormat:@"%.0f m", m];
    return [NSString stringWithFormat:@"%.1f km", m / 1000.0];
}

- (NSDictionary *)sl_dict {
    return @{@"uid": self.uid ?: @"",
             @"name": self.name ?: @"",
             @"lat": @(self.lat),
             @"lng": @(self.lng),
             @"address": self.address ?: @"",
             @"ts": @(self.createdAt)};
}

+ (instancetype)sl_itemFromDict:(NSDictionary *)d {
    SLFavoriteItem *it = [[SLFavoriteItem alloc] init];
    it.uid = [d[@"uid"] isKindOfClass:[NSString class]] ? d[@"uid"] : [[NSUUID UUID] UUIDString];
    it.name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
    it.lat = [d[@"lat"] doubleValue];
    it.lng = [d[@"lng"] doubleValue];
    NSString *addr = d[@"address"];
    it.address = [addr isKindOfClass:[NSString class]] && addr.length ? addr : nil;
    it.createdAt = [d[@"ts"] doubleValue];
    return it;
}

@end


@implementation SLFavoriteStore

+ (NSMutableArray<NSDictionary *> *)sl_raw {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSLFavKey];
    if ([v isKindOfClass:[NSArray class]]) return [v mutableCopy];
    return [NSMutableArray array];
}

+ (void)sl_writeRaw:(NSArray<NSDictionary *> *)arr {
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:kSLFavKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:SLFavoriteStoreChanged object:nil];
}

+ (NSArray<SLFavoriteItem *> *)items {
    NSMutableArray<SLFavoriteItem *> *out = [NSMutableArray array];
    for (NSDictionary *d in [self sl_raw]) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        [out addObject:[SLFavoriteItem sl_itemFromDict:d]];
    }
    return out;
}

+ (NSUInteger)count {
    return [self items].count;
}

+ (SLFavoriteItem *)itemNear:(CLLocationCoordinate2D)coord within:(double)meters {
    if (!CLLocationCoordinate2DIsValid(coord)) return nil;
    CLLocation *target = [[CLLocation alloc] initWithLatitude:coord.latitude longitude:coord.longitude];
    SLFavoriteItem *best = nil;
    double bestD = meters;
    for (SLFavoriteItem *it in [self items]) {
        CLLocation *p = [[CLLocation alloc] initWithLatitude:it.lat longitude:it.lng];
        double d = [p distanceFromLocation:target];
        if (d <= bestD) { bestD = d; best = it; }
    }
    return best;
}

+ (BOOL)saveName:(NSString *)name
      coordinate:(CLLocationCoordinate2D)coord
         address:(NSString *)address {
    if (!CLLocationCoordinate2DIsValid(coord)) return NO;

    NSString *n = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (n.length == 0) n = address.length ? address : [NSString stringWithFormat:@"%.5f, %.5f", coord.latitude, coord.longitude];

    NSMutableArray<NSDictionary *> *arr = [self sl_raw];

    // 同名，或 100 米内 —— 视为同一个点，覆盖更新
    NSInteger hit = -1;
    CLLocation *target = [[CLLocation alloc] initWithLatitude:coord.latitude longitude:coord.longitude];
    for (NSUInteger i = 0; i < arr.count; i++) {
        NSDictionary *d = arr[i];
        NSString *dn = d[@"name"];
        if ([dn isKindOfClass:[NSString class]] && [dn isEqualToString:n]) { hit = (NSInteger)i; break; }
        CLLocation *p = [[CLLocation alloc] initWithLatitude:[d[@"lat"] doubleValue] longitude:[d[@"lng"] doubleValue]];
        if ([p distanceFromLocation:target] <= 100.0) { hit = (NSInteger)i; break; }
    }

    SLFavoriteItem *it = [[SLFavoriteItem alloc] init];
    it.uid = [[NSUUID UUID] UUIDString];
    it.name = n;
    it.lat = coord.latitude;
    it.lng = coord.longitude;
    it.address = address;
    it.createdAt = [[NSDate date] timeIntervalSince1970];

    if (hit >= 0) {
        NSDictionary *old = arr[(NSUInteger)hit];
        NSString *oldUid = old[@"uid"];
        if ([oldUid isKindOfClass:[NSString class]] && oldUid.length) it.uid = oldUid;
        [arr removeObjectAtIndex:(NSUInteger)hit];
    }
    [arr insertObject:[it sl_dict] atIndex:0];
    while (arr.count > kSLFavMax) [arr removeLastObject];
    [self sl_writeRaw:arr];
    return hit < 0;
}

+ (void)renameItem:(SLFavoriteItem *)item to:(NSString *)name {
    NSString *n = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (item.uid.length == 0 || n.length == 0) return;
    NSMutableArray<NSDictionary *> *arr = [self sl_raw];
    for (NSUInteger i = 0; i < arr.count; i++) {
        if (![arr[i][@"uid"] isEqual:item.uid]) continue;
        NSMutableDictionary *d = [arr[i] mutableCopy];
        d[@"name"] = n;
        [arr replaceObjectAtIndex:i withObject:d];
        break;
    }
    [self sl_writeRaw:arr];
}

+ (void)removeItem:(SLFavoriteItem *)item {
    if (item.uid.length == 0) return;
    NSMutableArray<NSDictionary *> *arr = [self sl_raw];
    for (NSUInteger i = 0; i < arr.count; i++) {
        if (![arr[i][@"uid"] isEqual:item.uid]) continue;
        [arr removeObjectAtIndex:i];
        break;
    }
    [self sl_writeRaw:arr];
}

+ (void)moveFrom:(NSUInteger)from to:(NSUInteger)to {
    NSMutableArray<NSDictionary *> *arr = [self sl_raw];
    if (from >= arr.count || to > arr.count) return;
    NSDictionary *d = arr[from];
    [arr removeObjectAtIndex:from];
    NSUInteger dst = to > from ? to - 1 : to;
    if (dst > arr.count) dst = arr.count;
    [arr insertObject:d atIndex:dst];
    [self sl_writeRaw:arr];
}

@end
