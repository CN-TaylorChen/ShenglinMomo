// 语音包：本地音频导入、按文件夹分组、裁剪
// 数据落在 Documents/ShenglinMomo/voicepacks，索引存 NSUserDefaults

#import <Foundation/Foundation.h>

@interface SLVoicePack : NSObject

+ (NSString *)rootDir;

/// 全部语音包（按文件夹、文件名排序）
+ (NSArray<NSDictionary *> *)allPacks;
/// 文件夹名（含新建的空文件夹；「未分组」排最后）
+ (NSArray<NSString *> *)folders;
+ (NSArray<NSDictionary *> *)packsInFolder:(NSString *)folder;

/// 扫描目录，把索引里没有的音频补进来（手工放进目录也能看到）
+ (NSInteger)syncFromDisk;

/// 新建文件夹（已存在则返回 NO）
+ (BOOL)createFolder:(NSString *)name;
/// 删除文件夹（仅空文件夹；非空返回 NO）
+ (BOOL)removeFolder:(NSString *)name;
/// 重命名文件夹（索引里的 folder / rel 一起改）
+ (BOOL)renameFolder:(NSString *)oldName to:(NSString *)newName error:(NSString **)err;
/// 把语音包移到另一个文件夹
+ (BOOL)movePack:(NSDictionary *)pack toFolder:(NSString *)folder error:(NSString **)err;

+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)on;
/// v0.4.34：选中后按住说话就直接发这条语音包（不用再发口令）。默认开。
+ (BOOL)isAutoReplaceEnabled;
+ (void)setAutoReplaceEnabled:(BOOL)on;
+ (NSDictionary *)activePack;
+ (BOOL)isPackActive:(NSDictionary *)pack;
+ (void)selectPack:(NSDictionary *)pack;

/// v0.4.36：「原声」——选了它就不替换，用自己录的声音。
/// 和「语音包直发」是两件事：直发决定要不要自动替换，原声决定这一刻是不是不替换。
+ (BOOL)isOriginalMode;
+ (void)setOriginalMode:(BOOL)on;

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

/// v0.4.34：后台把当前语音包解码成 PCM 缓存好。
/// 录音开始那一刻要同步拿到 PCM，现解会在录音线程上卡几百毫秒，所以选中时先热一次。
/// 实现放在 Tweak.x（那里才有编码器和全局状态）。
void SLPackPrewarm(void);
