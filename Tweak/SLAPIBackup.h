// API 凭证备份 / 还原
//
// 只备份「凭证 + 当前音色 + 引擎开关」，不含音色库、收藏、情绪勾选这些大块数据。
// 导出为 JSON 文件（Documents/ShenglinMomo/backup/sl-api-YYYYMMDD-HHmmss.json），
// 再由系统分享面板存到「文件」/隔空投送；还原走 UIDocumentPicker 选回同一个文件。
//
// 安全约束：还原只认白名单里的 key（见实现里的 sl_fields 表），
// 文件里多出来的字段一律忽略，不会被写进 NSUserDefaults。

#import <Foundation/Foundation.h>

@interface SLAPIBackup : NSObject

/// 采集当前配置（不会抛异常；没设过的项为空串/默认值）
+ (NSDictionary *)snapshot;

/// 一句话描述备份内容，用于导出/还原前的确认提示
+ (NSString *)summaryOfSnapshot:(NSDictionary *)snap;

/// 导出到 Documents/ShenglinMomo/backup/，返回文件路径；失败返回 nil 并回传原因
+ (NSString *)exportToFileError:(NSString **)err;

/// 读取并校验备份文件（schema 不对 / 不是 JSON 都会回传原因）
+ (NSDictionary *)readFileAtURL:(NSURL *)url error:(NSString **)err;

/// 按白名单还原；成功返回 YES
+ (BOOL)applySnapshot:(NSDictionary *)snap error:(NSString **)err;

@end
