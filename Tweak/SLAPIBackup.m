#import "SLAPIBackup.h"
#import "AWECATTSManager.h"
#import "AWECATOSUploader.h"
#import "AWECAUtils.h"

static NSString *const kSLBackupSchema = @"shenglinmomo.api.backup";
static const NSInteger kSLBackupVersion = 1;

// 白名单：key + 类型（s = 字符串，b = 布尔）+ 展示名
static NSArray<NSDictionary *> *SLBackupFields(void) {
    static NSArray<NSDictionary *> *fields = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fields = @[
            @{@"key": kAWECATTSAppID,             @"type": @"s", @"label": @"火山 App ID"},
            @{@"key": kAWECATTSAccessToken,       @"type": @"s", @"label": @"火山 Access Token"},
            @{@"key": kAWECFishAPIKey,            @"type": @"s", @"label": @"Fish Audio 密钥"},
            @{@"key": kAWECFishModel,             @"type": @"s", @"label": @"Fish 模型"},
            @{@"key": kAWECATTSEngine,            @"type": @"b", @"label": @"合成引擎"},
            @{@"key": kAWECATTSVolcanoVoiceType,  @"type": @"s", @"label": @"火山音色"},
            @{@"key": kAWECATTSVolcanoVoiceName,  @"type": @"s", @"label": @"火山音色名"},
            @{@"key": kAWECFishVoiceType,         @"type": @"s", @"label": @"Fish 音色"},
            @{@"key": kAWECFishVoiceName,         @"type": @"s", @"label": @"Fish 音色名"},
            @{@"key": kAWECATOSAccessKey,         @"type": @"s", @"label": @"TOS AccessKey"},
            @{@"key": kAWECATOSSecretKey,         @"type": @"s", @"label": @"TOS SecretKey"},
            @{@"key": kAWECATOSBucket,            @"type": @"s", @"label": @"TOS 存储桶"},
            @{@"key": kAWECATOSRegion,            @"type": @"s", @"label": @"TOS 地域"},
            @{@"key": kAWECAASRResourceId,        @"type": @"s", @"label": @"识别资源 ID"},
        ];
    });
    return fields;
}

static NSString *SLBackupDirPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:@"ShenglinMomo/backup"];
}

@implementation SLAPIBackup

+ (NSDictionary *)snapshot {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    for (NSDictionary *f in SLBackupFields()) {
        NSString *key = f[@"key"];
        if ([f[@"type"] isEqualToString:@"b"]) {
            items[key] = @([d boolForKey:key]);
        } else {
            id v = [d objectForKey:key];
            items[key] = [v isKindOfClass:[NSString class]] ? v : (v ? [v description] : @"");
        }
    }
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    return @{
        @"schema": kSLBackupSchema,
        @"version": @(kSLBackupVersion),
        @"app": @"ShenglinMomo",
        @"savedAt": [df stringFromDate:[NSDate date]],
        @"items": items,
    };
}

+ (NSInteger)sl_filledCountInSnapshot:(NSDictionary *)snap {
    NSDictionary *items = snap[@"items"];
    if (![items isKindOfClass:[NSDictionary class]]) return 0;
    NSInteger n = 0;
    for (NSDictionary *f in SLBackupFields()) {
        if (![f[@"type"] isEqualToString:@"s"]) continue;
        id v = items[f[@"key"]];
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) n++;
    }
    return n;
}

+ (NSString *)summaryOfSnapshot:(NSDictionary *)snap {
    if (![snap isKindOfClass:[NSDictionary class]]) return @"文件内容不是有效的备份";
    NSInteger n = [self sl_filledCountInSnapshot:snap];
    NSString *at = [snap[@"savedAt"] isKindOfClass:[NSString class]] ? snap[@"savedAt"] : @"未知时间";
    return [NSString stringWithFormat:@"已填 %ld 项凭证 · 备份于 %@", (long)n, at];
}

+ (NSString *)exportToFileError:(NSString **)err {
    NSDictionary *snap = [self snapshot];
    NSError *jsonErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:snap
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&jsonErr];
    if (!data) {
        if (err) *err = jsonErr.localizedDescription ?: @"生成备份内容失败";
        return nil;
    }

    NSError *dirErr = nil;
    NSString *dir = SLBackupDirPath();
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&dirErr]) {
        if (err) *err = dirErr.localizedDescription ?: @"创建备份目录失败";
        return nil;
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"sl-api-%@.json", [df stringFromDate:[NSDate date]]];
    NSString *path = [dir stringByAppendingPathComponent:name];

    NSError *writeErr = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeErr]) {
        if (err) *err = writeErr.localizedDescription ?: @"写入备份文件失败";
        return nil;
    }
    return path;
}

+ (NSDictionary *)readFileAtURL:(NSURL *)url error:(NSString **)err {
    if (!url) {
        if (err) *err = @"没有选中文件";
        return nil;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:NULL];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!data.length) {
        if (err) *err = @"文件读不出来（可能是空的或没有访问权限）";
        return nil;
    }
    NSError *jsonErr = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (err) *err = @"不是有效的备份文件（JSON 解析失败）";
        return nil;
    }
    NSDictionary *snap = (NSDictionary *)obj;
    if (![snap[@"schema"] isEqual:kSLBackupSchema]) {
        if (err) *err = @"不是声临的 API 备份文件";
        return nil;
    }
    NSInteger ver = [snap[@"version"] respondsToSelector:@selector(integerValue)] ? [snap[@"version"] integerValue] : 0;
    if (ver > kSLBackupVersion) {
        if (err) *err = @"备份文件来自更新的版本，请升级后再还原";
        return nil;
    }
    if (![snap[@"items"] isKindOfClass:[NSDictionary class]]) {
        if (err) *err = @"备份文件缺少内容";
        return nil;
    }
    return snap;
}

+ (BOOL)applySnapshot:(NSDictionary *)snap error:(NSString **)err {
    if (![snap isKindOfClass:[NSDictionary class]] || ![snap[@"items"] isKindOfClass:[NSDictionary class]]) {
        if (err) *err = @"备份内容不完整";
        return NO;
    }
    NSDictionary *items = snap[@"items"];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger applied = 0;

    for (NSDictionary *f in SLBackupFields()) {
        NSString *key = f[@"key"];
        id v = items[key];
        if (!v || v == [NSNull null]) continue;          // 文件里没这项：保留本机原值
        if ([f[@"type"] isEqualToString:@"b"]) {
            if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) {
                [d setBool:[v boolValue] forKey:key];
                applied++;
            }
        } else if ([v isKindOfClass:[NSString class]]) {
            [d setObject:v forKey:key];
            applied++;
        }
    }
    [d synchronize];

    if (applied == 0) {
        if (err) *err = @"文件里没有可还原的项";
        return NO;
    }
    [[AWECATTSManager shared] loadConfig];   // 同步回内存，界面重排后立刻生效
    return YES;
}

@end
