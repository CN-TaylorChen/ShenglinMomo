// 语音包：本地音频导入、按文件夹分组、裁剪
// 数据落在 Documents/ShenglinMomo/voicepacks，索引存 NSUserDefaults

#import <Foundation/Foundation.h>

@interface SLVoicePack : NSObject

+ (NSString *)rootDir;

/// 全部语音包（按文件夹、文件名排序）
+ (NSArray<NSDictionary *> *)allPacks;
/// 文件夹名（有内容的才返回）
+ (NSArray<NSString *> *)folders;
+ (NSArray<NSDictionary *> *)packsInFolder:(NSString *)folder;

+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)on;
+ (NSDictionary *)activePack;
+ (BOOL)isPackActive:(NSDictionary *)pack;
+ (void)selectPack:(NSDictionary *)pack;

/// 导入整个文件夹（递归），返回新增条数
+ (NSInteger)importFolderAtURL:(NSURL *)url error:(NSString **)err;
/// 导入单个音频文件到指定文件夹（nil = 未分组）
+ (BOOL)importFileAtURL:(NSURL *)url folder:(NSString *)folder error:(NSString **)err;

+ (BOOL)deletePack:(NSDictionary *)pack;
+ (BOOL)renamePack:(NSDictionary *)pack toName:(NSString *)name;
/// 裁剪（秒），返回新条目；原文件保留
+ (NSDictionary *)trimPack:(NSDictionary *)pack from:(double)start to:(double)end error:(NSString **)err;

+ (NSString *)pathOfPack:(NSDictionary *)pack;
+ (NSString *)displayDuration:(NSDictionary *)pack;

@end
