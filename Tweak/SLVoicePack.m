// 语音包存储与音频处理

#import "SLVoicePack.h"
#import "AWECAUtils.h"
#import "SLAMREncoder.h"
#import "SLLog.h"

#define kSLPacksKey   @"SLVoicePacks"       // 数组：[{name, rel, folder, dur}]
#define kSLPackOnKey  @"SLVoicePackOn"      // 开关
#define kSLPackSelKey @"SLVoicePackActive"  // 选中的 rel

static NSArray<NSString *> *SLAudioExts(void) {    static NSArray<NSString *> *exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = @[@"mp3", @"wav", @"m4a", @"aac", @"amr", @"caf", @"ogg", @"flac", @"aiff", @"aif"];
    });
    return exts;
}

static BOOL SLIsAudioFile(NSString *path) {
    return [SLAudioExts() containsObject:path.pathExtension.lowercaseString];
}

static NSString *SLSafeName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return @"未命名";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSString *s = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return @"未命名";
    if (s.length > 40) s = [s substringToIndex:40];
    return s;
}

// 16bit / 单声道 PCM 写成标准 WAV（44 字节头）
static BOOL SLWriteWAV(NSData *pcm, NSString *path, double sampleRate) {
    if (!pcm.length) return NO;
    NSMutableData *d = [NSMutableData dataWithCapacity:pcm.length + 44];
    uint32_t chunkSize = (uint32_t)(36 + pcm.length);
    uint32_t subChunk2 = (uint32_t)pcm.length;
    uint16_t fmt = 1, channels = 1, bits = 16, blockAlign = 2;
    uint32_t byteRate = (uint32_t)sampleRate * blockAlign;
    uint32_t rate = (uint32_t)sampleRate;
    [d appendBytes:"RIFF" length:4];
    [d appendBytes:&chunkSize length:4];
    [d appendBytes:"WAVEfmt " length:8];
    uint32_t fmtSize = 16;
    [d appendBytes:&fmtSize length:4];
    [d appendBytes:&fmt length:2];
    [d appendBytes:&channels length:2];
    [d appendBytes:&rate length:4];
    [d appendBytes:&byteRate length:4];
    [d appendBytes:&blockAlign length:2];
    [d appendBytes:&bits length:2];
    [d appendBytes:"data" length:4];
    [d appendBytes:&subChunk2 length:4];
    [d appendData:pcm];
    return [d writeToFile:path atomically:YES];
}

@interface SLVoicePack ()
+ (void)sl_addEntry:(NSDictionary *)entry;
+ (void)sl_removeEntryRel:(NSString *)rel;
+ (NSString *)sl_uniquePathInDir:(NSString *)dir fileName:(NSString *)fileName;
+ (BOOL)sl_copyIntoFolder:(NSString *)folderName
                fromPath:(NSString *)srcPath
                fileName:(NSString *)fileName
                   error:(NSString **)err;
@end

@implementation SLVoicePack

+ (NSString *)rootDir {
    NSString *dir = [[AWECAUtils documentsPath] stringByAppendingPathComponent:@"ShenglinMomo/voicepacks"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

+ (NSString *)pathOfPack:(NSDictionary *)pack {
    NSString *rel = pack[@"rel"];
    if (![rel isKindOfClass:[NSString class]] || !rel.length) return nil;
    return [[self rootDir] stringByAppendingPathComponent:rel];
}

+ (NSArray<NSDictionary *> *)allPacks {
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:kSLPacksKey];
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *p = item;
            NSString *rel = p[@"rel"];
            if (![rel isKindOfClass:[NSString class]] || !rel.length) continue;
            // 文件被系统清掉或手工删掉时，索引里自动剔除
            if (![fm fileExistsAtPath:[[self rootDir] stringByAppendingPathComponent:rel]]) continue;
            [out addObject:p];
        }
    }
    NSArray *sorted = [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *fa = a[@"folder"] ?: @"", *fb = b[@"folder"] ?: @"";
        NSComparisonResult r = [fa localizedStandardCompare:fb];
        if (r != NSOrderedSame) return r;
        return [(a[@"name"] ?: @"") localizedStandardCompare:(b[@"name"] ?: @"")];
    }];
    return sorted;
}

+ (NSArray<NSString *> *)folders {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *p in [self allPacks]) {
        NSString *f = [p[@"folder"] isKindOfClass:[NSString class]] ? p[@"folder"] : @"未分组";
        if (![names containsObject:f]) [names addObject:f];
    }
    return names;
}

+ (NSArray<NSDictionary *> *)packsInFolder:(NSString *)folder {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in [self allPacks]) {
        NSString *f = [p[@"folder"] isKindOfClass:[NSString class]] ? p[@"folder"] : @"未分组";
        if ([f isEqualToString:folder]) [out addObject:p];
    }
    return out;
}

#pragma mark - 选中状态

+ (BOOL)isEnabled {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSLPackOnKey];
    return v ? [v boolValue] : NO;
}

+ (void)setEnabled:(BOOL)on {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:on forKey:kSLPackOnKey];
    [d synchronize];
}

+ (NSDictionary *)activePack {
    NSString *rel = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPackSelKey];
    if (!rel.length) return nil;
    for (NSDictionary *p in [self allPacks]) {
        if ([p[@"rel"] isEqualToString:rel]) return p;
    }
    return nil;
}

+ (BOOL)isPackActive:(NSDictionary *)pack {
    NSString *rel = [[NSUserDefaults standardUserDefaults] stringForKey:kSLPackSelKey];
    return rel.length && [pack[@"rel"] isEqualToString:rel];
}

+ (void)selectPack:(NSDictionary *)pack {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *rel = pack[@"rel"];
    if (rel.length) [d setObject:rel forKey:kSLPackSelKey];
    else [d removeObjectForKey:kSLPackSelKey];
    [d synchronize];
}

#pragma mark - 索引维护

+ (void)sl_addEntry:(NSDictionary *)entry {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *list = [NSMutableArray array];
    id raw = [d objectForKey:kSLPacksKey];
    if ([raw isKindOfClass:[NSArray class]]) [list addObjectsFromArray:raw];
    for (NSDictionary *p in list) {
        if ([p[@"rel"] isEqualToString:entry[@"rel"]]) return;   // 已存在
    }
    [list addObject:entry];
    [d setObject:list forKey:kSLPacksKey];
    [d synchronize];
}

+ (void)sl_removeEntryRel:(NSString *)rel {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *list = [NSMutableArray array];
    id raw = [d objectForKey:kSLPacksKey];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            if ([[item objectForKey:@"rel"] isEqualToString:rel]) continue;
            [list addObject:item];
        }
    }
    [d setObject:list forKey:kSLPacksKey];
    if ([[d stringForKey:kSLPackSelKey] isEqualToString:rel]) [d removeObjectForKey:kSLPackSelKey];
    [d synchronize];
}

+ (NSString *)displayDuration:(NSDictionary *)pack {
    double dur = [pack[@"dur"] doubleValue];
    if (dur <= 0) {
        NSString *path = [self pathOfPack:pack];
        dur = path.length ? [AWECAUtils audioDurationAtPath:path] : 0;
    }
    if (dur <= 0) return @"--";
    return [NSString stringWithFormat:@"%.1fs", dur];
}

#pragma mark - 导入

+ (NSString *)sl_uniquePathInDir:(NSString *)dir fileName:(NSString *)fileName {
    NSString *name = fileName.stringByDeletingPathExtension;
    NSString *ext = fileName.pathExtension;
    NSString *candidate = fileName;
    NSInteger i = 2;
    NSFileManager *fm = [NSFileManager defaultManager];
    while ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:candidate]]) {
        candidate = ext.length ? [NSString stringWithFormat:@"%@-%ld.%@", name, (long)i++, ext]
                               : [NSString stringWithFormat:@"%@-%ld", name, (long)i++];
    }
    return [dir stringByAppendingPathComponent:candidate];
}

+ (BOOL)sl_copyIntoFolder:(NSString *)folderName
                 fromPath:(NSString *)srcPath
                 fileName:(NSString *)fileName
                    error:(NSString **)err {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [[self rootDir] stringByAppendingPathComponent:SLSafeName(folderName)];
    if (![fm fileExistsAtPath:dir]) {
        NSError *e = nil;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e];
        if (e) { if (err) *err = e.localizedDescription; return NO; }
    }
    NSString *dest = [self sl_uniquePathInDir:dir fileName:SLSafeName(fileName)];
    NSError *e = nil;
    [fm copyItemAtPath:srcPath toPath:dest error:&e];
    if (e) { if (err) *err = e.localizedDescription; return NO; }

    NSString *rel = [dest stringByReplacingOccurrencesOfString:[[self rootDir] stringByAppendingString:@"/"] withString:@""];
    double dur = [AWECAUtils audioDurationAtPath:dest];
    [self sl_addEntry:@{ @"name": dest.lastPathComponent.stringByDeletingPathExtension ?: @"未命名",
                         @"rel": rel,
                         @"folder": SLSafeName(folderName),
                         @"dur": @(dur) }];
    return YES;
}

+ (NSInteger)importFolderAtURL:(NSURL *)url error:(NSString **)err {
    if (!url) { if (err) *err = @"没有拿到文件夹"; return 0; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *folderName = url.lastPathComponent.length ? url.lastPathComponent : @"导入";
    NSInteger added = 0;

    NSError *listErr = nil;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:url.path error:&listErr];
    if (listErr) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (err) *err = listErr.localizedDescription;
        return 0;
    }
    for (NSString *item in items) {
        NSString *full = [url.path stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) continue;                       // 只取一层，子目录跳过
        if (!SLIsAudioFile(full)) continue;
        if ([self sl_copyIntoFolder:folderName fromPath:full fileName:item error:err]) added++;
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!added && err && !*err) *err = @"文件夹里没有可用的音频文件";
    return added;
}

+ (BOOL)importFileAtURL:(NSURL *)url folder:(NSString *)folder error:(NSString **)err {
    if (!url) { if (err) *err = @"没有拿到文件"; return NO; }
    if (!SLIsAudioFile(url.path)) { if (err) *err = @"不是支持的音频格式"; return NO; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    BOOL ok = [self sl_copyIntoFolder:(folder.length ? folder : @"未分组")
                             fromPath:url.path
                             fileName:url.lastPathComponent
                                error:err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return ok;
}

#pragma mark - 编辑

+ (BOOL)deletePack:(NSDictionary *)pack {
    NSString *path = [self pathOfPack:pack];
    if (path.length) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [self sl_removeEntryRel:pack[@"rel"]];
    return YES;
}

+ (BOOL)renamePack:(NSDictionary *)pack toName:(NSString *)name {
    NSString *newName = SLSafeName(name);
    NSString *oldPath = [self pathOfPack:pack];
    if (!oldPath.length) return NO;
    NSString *ext = oldPath.pathExtension;
    NSString *destName = ext.length ? [newName stringByAppendingPathExtension:ext] : newName;
    NSString *dest = [oldPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:destName];
    if (![dest isEqualToString:oldPath]) {
        NSError *e = nil;
        [[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:dest error:&e];
        if (e) return NO;
    }
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *list = [NSMutableArray array];
    id raw = [d objectForKey:kSLPacksKey];
    NSString *oldRel = pack[@"rel"];
    NSString *newRel = [dest stringByReplacingOccurrencesOfString:[[self rootDir] stringByAppendingString:@"/"] withString:@""];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *m = [item mutableCopy];
            if ([m[@"rel"] isEqualToString:oldRel]) {
                m[@"rel"] = newRel;
                m[@"name"] = newName;
            }
            [list addObject:m];
        }
    }
    [d setObject:list forKey:kSLPacksKey];
    if ([[d stringForKey:kSLPackSelKey] isEqualToString:oldRel]) [d setObject:newRel forKey:kSLPackSelKey];
    [d synchronize];
    return YES;
}

+ (NSDictionary *)trimPack:(NSDictionary *)pack from:(double)start to:(double)end error:(NSString **)err {
    NSString *path = [self pathOfPack:pack];
    if (!path.length) { if (err) *err = @"文件不在了"; return nil; }
    if (end - start < 0.3) { if (err) *err = @"选段太短，至少 0.3 秒"; return nil; }

    NSData *pcm = [SLAMREncoder pcmMono16AtPath:path sampleRate:16000.0];
    if (pcm.length < 3200) { if (err) *err = @"音频解码失败"; return nil; }
    NSUInteger total = pcm.length / 2;
    NSUInteger f0 = (NSUInteger)llround(start * 16000.0);
    NSUInteger f1 = (NSUInteger)llround(end * 16000.0);
    if (f1 > total) f1 = total;
    if (f0 >= f1) { if (err) *err = @"选段无效"; return nil; }

    NSData *sub = [pcm subdataWithRange:NSMakeRange(f0 * 2, (f1 - f0) * 2)];
    NSString *base = [[path stringByDeletingPathExtension].lastPathComponent stringByAppendingString:@"-裁剪"];
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSString *dest = [self sl_uniquePathInDir:dir fileName:[base stringByAppendingPathExtension:@"wav"]];
    if (!SLWriteWAV(sub, dest, 16000.0)) { if (err) *err = @"写入失败"; return nil; }

    NSString *rel = [dest stringByReplacingOccurrencesOfString:[[self rootDir] stringByAppendingString:@"/"] withString:@""];
    NSDictionary *entry = @{ @"name": dest.lastPathComponent.stringByDeletingPathExtension ?: @"裁剪",
                             @"rel": rel,
                             @"folder": ([pack[@"folder"] isKindOfClass:[NSString class]] ? pack[@"folder"] : @"未分组"),
                             @"dur": @((double)sub.length / 2.0 / 16000.0) };
    [self sl_addEntry:entry];
    SLLog(@"pack trim %@ -> %@ %.2fs", path.lastPathComponent, dest.lastPathComponent, [entry[@"dur"] doubleValue]);
    return entry;
}

@end
