// 豆包 TTS 管理器
// @cookieodd | github.com/cookieodd | t.me/cookieodd

#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECAAudioReplacer.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import <string.h>

#define kDefaultVoiceType   @"zh_female_cancan_uranus_bigtts"

#define kTTSV3UnidirURL @"https://openspeech.bytedance.com/api/v3/tts/unidirectional"
#define kTTSResourceTTS2 @"seed-tts-2.0"
#define kTTSResourceICL2 @"seed-icl-2.0"

#define kFishTTSURL     @"https://api.fish.audio/v1/tts"

static NSString *AWECATrim(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *AWECAHeader(NSDictionary *headers, NSString *key) {
    if (![headers isKindOfClass:[NSDictionary class]] || !key.length) return nil;
    id v = headers[key];
    if ([v isKindOfClass:[NSString class]]) return v;
    for (NSString *k in headers) {
        if ([k caseInsensitiveCompare:key] == NSOrderedSame) {
            id x = headers[k];
            return [x isKindOfClass:[NSString class]] ? x : nil;
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *AWECAJSONObjectsFromData(NSData *data) {
    NSMutableArray *out = [NSMutableArray array];
    if (!data.length) return out;
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    NSUInteger i = 0;
    while (i < len) {
        while (i < len && bytes[i] <= 32) i++;
        if (i >= len) break;
        if (i + 5 <= len && memcmp(bytes + i, "data:", 5) == 0) {
            i += 5;
            while (i < len && bytes[i] == ' ') i++;
        } else if (i + 6 <= len && memcmp(bytes + i, "event:", 6) == 0) {
            while (i < len && bytes[i] != '\n') i++;
            continue;
        }
        if (i >= len || bytes[i] != '{') { i++; continue; }
        NSUInteger start = i;
        int depth = 0;
        BOOL inStr = NO, esc = NO;
        BOOL closed = NO;
        for (; i < len; i++) {
            char c = (char)bytes[i];
            if (inStr) {
                if (esc) esc = NO;
                else if (c == '\\') esc = YES;
                else if (c == '"') inStr = NO;
                continue;
            }
            if (c == '"') inStr = YES;
            else if (c == '{') depth++;
            else if (c == '}') {
                depth--;
                if (depth == 0) {
                    NSData *one = [data subdataWithRange:NSMakeRange(start, i - start + 1)];
                    id obj = [NSJSONSerialization JSONObjectWithData:one options:0 error:nil];
                    if ([obj isKindOfClass:[NSDictionary class]]) [out addObject:obj];
                    i++;
                    closed = YES;
                    break;
                }
            }
        }
        if (!closed) break;
    }
    return out;
}

@interface AWECATTSManager ()
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy, readwrite) NSString *lastSynthesizedPath;
@end

@implementation AWECATTSManager

+ (instancetype)shared {
    static AWECATTSManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AWECATTSManager alloc] init];
        [instance loadConfig];
    });
    return instance;
}

#pragma mark - 合成

- (void)synthesizeText:(NSString *)text
            completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    [self synthesizeText:text previewOnly:NO completion:completion];
}

- (void)previewText:(NSString *)text
         completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    [self synthesizeText:text previewOnly:YES completion:completion];
}

- (void)synthesizeText:(NSString *)text
           previewOnly:(BOOL)previewOnly
            completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    if (!text || text.length == 0) {
        if (completion) completion(NO, nil, @"请输入要合成的文字");
        return;
    }

    if (self.fishEngine) {
        [self synthesizeFishText:text previewOnly:previewOnly completion:completion];
        return;
    }
    [self synthesizeVolcanoV3Text:text previewOnly:previewOnly completion:completion];
}

- (void)synthesizeVolcanoPreviewText:(NSString *)text
                          completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    // 流水线统一入口：按引擎分流（录音转音色 ASR 仍走火山，仅 TTS 分流）
    if (self.fishEngine) {
        [self synthesizeFishText:text previewOnly:NO completion:completion];
        return;
    }
    [self synthesizeVolcanoV3Text:text previewOnly:YES completion:completion];
}

static int aweca_mapRatioToV3(float ratio, int scale, int lo, int hi) {
    if (ratio < 0.01f) ratio = 1.0f;
    int v = (int)lround((ratio - 1.0f) * (double)scale);
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return v;
}

static int aweca_mapPitchToV3(float ratio) {
    int v = (int)lround((ratio - 1.0f) * 12.0);
    if (v < -12) v = -12;
    if (v > 12) v = 12;
    return v;
}

+ (NSString *)canonicalDialect:(NSString *)raw {
    NSString *s = AWECATrim(raw);
    if (!s.length) return @"";
    NSString *l = s.lowercaseString;
    if ([s isEqualToString:@"东北"] || [l isEqualToString:@"dongbei"]) return @"dongbei";
    if ([s isEqualToString:@"陕西"] || [l isEqualToString:@"shaanxi"]) return @"shaanxi";
    if ([s isEqualToString:@"四川"] || [l isEqualToString:@"sichuan"]) return @"sichuan";
    return @"";
}

- (BOOL)currentVoiceSupportsDialect {
    return [[self volcanoTTS2Speaker] isEqualToString:kAWECATTSDialectSpeaker];
}

- (NSString *)volcanoSpeakerId {
    if (self.voiceType.length > 0) return self.voiceType;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kAWECATTSVolcanoVoiceType];
    if (saved.length > 0) return saved;
    return kDefaultVoiceType;
}

- (NSString *)volcanoTTS2Speaker {
    NSString *s = [self volcanoSpeakerId] ?: @"";
    NSString *l = [s lowercaseString];
    if ([l containsString:@"uranus"]) return s;

    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"saturn_zh_female_cancan_tob": @"zh_female_cancan_uranus_bigtts",
            @"BV700_V2_streaming": @"zh_female_cancan_uranus_bigtts",
            @"zh_female_cancan_mars_bigtts": @"zh_female_cancan_uranus_bigtts",
            @"BV001_V2_streaming": @"zh_female_vv_uranus_bigtts",
            @"BV002_V2_streaming": @"zh_male_m191_uranus_bigtts",
            @"BV113_streaming": @"zh_male_taocheng_uranus_bigtts",
            @"BV102_streaming": @"zh_female_xiaohe_uranus_bigtts",
            @"BV406_V2_streaming": @"zh_male_m191_uranus_bigtts",
            @"BV405_streaming": @"zh_female_qingchezizi_uranus_bigtts",
            @"zh_female_xueayi_saturn_bigtts": @"zh_female_xiaoxue_uranus_bigtts",
            @"zh_female_santongyongns_saturn_bigtts": @"zh_female_liuchangnv_uranus_bigtts",
        };
    });
    NSString *mapped = map[s];
    if (mapped.length) return mapped;
    if ([s hasPrefix:@"saturn_"]) {
        return [@"ICL_uranus_" stringByAppendingString:[s substringFromIndex:7]];
    }
    if ([l containsString:@"saturn"]) {
        return [s stringByReplacingOccurrencesOfString:@"saturn" withString:@"uranus"];
    }
    // 未知音色 ID 原样透传，支持自定义音色（复刻 S_xxx、商店音色等）
    return s;
}

- (NSString *)volcanoTTSAdditionsJSONAllowContext:(BOOL)allowContext {
    NSMutableDictionary *add = [NSMutableDictionary dictionary];
    int pitch = aweca_mapPitchToV3(self.pitchRatio);
    if (pitch != 0) {
        add[@"post_process"] = @{ @"pitch": @(pitch) };
    }
    if (allowContext) {
        NSString *ctx = AWECATrim(self.contextText);
        if (ctx.length) add[@"context_texts"] = @[ctx];
    }
    NSString *dialect = [AWECATTSManager canonicalDialect:self.explicitDialect];
    if (dialect.length && [self currentVoiceSupportsDialect]) {
        add[@"explicit_dialect"] = dialect;
    }
    if (self.silenceDurationMs > 0) add[@"silence_duration"] = @(self.silenceDurationMs);
    if (add.count == 0) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:add options:0 error:nil];
    if (!data.length) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)applyVolcanoHTTPAuthToRequest:(NSMutableURLRequest *)request {
    if (!request) return;
    NSString *token = AWECATrim(self.accessToken);
    NSString *appID = AWECATrim(self.appID);
    if (token.length > 0) {
        [request setValue:token forHTTPHeaderField:@"X-Api-Key"];
        [request setValue:token forHTTPHeaderField:@"X-Api-Access-Key"];
    }
    if (appID.length > 0) {
        [request setValue:appID forHTTPHeaderField:@"X-Api-App-Id"];
    }
}

- (void)synthesizeVolcanoV3Text:(NSString *)text
                    previewOnly:(BOOL)previewOnly
                     completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    if (!text.length) {
        if (completion) completion(NO, nil, @"请输入要合成的文字");
        return;
    }
    NSString *token = AWECATrim(self.accessToken);
    NSString *appID = AWECATrim(self.appID);
    if (token.length == 0 && appID.length == 0) {
        if (completion) completion(NO, nil, @"请先填写火山 API Key");
        return;
    }

    NSString *speaker = [self volcanoTTS2Speaker];
    // 声音复刻音色（S_xxx / icl_ 开头）必须使用复刻资源 ID（seed-icl-2.0），
    // 否则报 55000000 resource ID is mismatched with speaker related resource
    BOOL isCloneVoice = ([speaker hasPrefix:@"S_"] || [speaker hasPrefix:@"s_"] || [speaker hasPrefix:@"icl_"]);
    NSMutableDictionary *reqParams = [@{
        @"text": text,
        @"speaker": speaker,
        @"audio_params": @{
            @"format": @"mp3",
            @"sample_rate": @24000,
            @"speech_rate": @(aweca_mapRatioToV3(self.speedRatio, 100, -50, 100)),
            @"loudness_rate": @(aweca_mapRatioToV3(self.volumeRatio, 100, -50, 100))
        }
    } mutableCopy];
    // 官方要求：speaker 为复刻音色时需指定 model，指定后不支持语音指令 context_texts
    if (isCloneVoice) reqParams[@"model"] = @"seed-tts-2.0-standard";
    NSString *additions = [self volcanoTTSAdditionsJSONAllowContext:(!isCloneVoice)];
    if (additions.length) reqParams[@"additions"] = additions;

    NSDictionary *body = @{
        @"user": @{ @"uid": appID.length ? appID : @"aweca_user" },
        @"req_params": reqParams
    };

    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr || !jsonData) {
        if (completion) completion(NO, nil, @"请求构造失败");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kTTSV3UnidirURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    request.timeoutInterval = 45;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[[NSUUID UUID] UUIDString] forHTTPHeaderField:@"X-Api-Request-Id"];
    [request setValue:(isCloneVoice ? kTTSResourceICL2 : kTTSResourceTTS2) forHTTPHeaderField:@"X-Api-Resource-Id"];
    [self applyVolcanoHTTPAuthToRequest:request];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription]);
            });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *apiCode = AWECAHeader(http.allHeaderFields, @"X-Api-Status-Code");
        NSString *apiMsg = AWECAHeader(http.allHeaderFields, @"X-Api-Message");
        if (apiCode.length && ![apiCode isEqualToString:@"20000000"] && ![apiCode isEqualToString:@"0"]) {
            NSString *hint = apiMsg.length ? apiMsg : @"失败";
            if ([apiCode isEqualToString:@"55000000"]) hint = @"音色与资源不匹配：复刻音色(S_开头)需在火山控制台开通「声音复刻2.0字符版」，且复刻音色不能过期";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"合成错误(%@): %@", apiCode, hint]);
            });
            return;
        }
        if (!data.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, @"服务器无响应");
            });
            return;
        }
        [self parseV3TTSResponse:data text:text previewOnly:previewOnly completion:completion];
    }] resume];
}

#pragma mark - FishAudio

- (NSString *)fishEmotionPrefix {
    NSMutableString *p = [NSMutableString string];
    for (NSString *tag in self.fishEmotionSel) {
        if (![tag isKindOfClass:[NSString class]] || !tag.length) continue;
        [p appendFormat:@"%@ ", tag];
    }
    return p;
}

// 第 idx 个标签的中文备注（备注只影响显示，合成始终用英文标签；越界/缺失安全）
- (NSString *)fishEmotionNoteAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.fishEmotionNotes.count) return @"";
    NSString *n = self.fishEmotionNotes[idx];
    return [n isKindOfClass:[NSString class]] ? n : @"";
}

- (void)synthesizeFishText:(NSString *)text
                previewOnly:(BOOL)previewOnly
                 completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    if (!text.length) {
        if (completion) completion(NO, nil, @"请输入要合成的文字");
        return;
    }
    NSString *key = AWECATrim(self.fishAPIKey);
    if (!key.length) {
        if (completion) completion(NO, nil, @"请先填写 Fish Audio API Key");
        return;
    }
    NSString *refID = AWECATrim(self.fishVoiceType);
    if (!refID.length) {
        if (completion) completion(NO, nil, @"请先选择 Fish Audio 音色");
        return;
    }

    // 情绪标签直接拼在文本前（s2.x 用 [tag]，s1 用 (tag)，由用户自行维护）
    NSString *fullText = [[self fishEmotionPrefix] stringByAppendingString:text];
    NSString *model = AWECATrim(self.fishModel);
    if (!model.length) model = @"s2.1-pro-free";

    NSMutableDictionary *body = [@{
        @"text": fullText,
        @"reference_id": refID,
        @"format": @"mp3",
        @"mp3_bitrate": @128,
        @"chunk_length": @200,
    } mutableCopy];
    if ([model isEqualToString:@"s1"]) body[@"normalize"] = @YES;

    // 语速/音量（v0.4.8）：prosody.speed 0.5~2.0；prosody.volume 是 dB 偏移，由倍率 20*log10 换算。
    // 开着响度归一化时音量偏移会被抹平，所以调音量时顺带关掉 normalize_loudness
    float sp = self.speedRatio; float vo = self.volumeRatio;
    if (sp < 0.01f) sp = 1.0f;
    if (vo < 0.01f) vo = 1.0f;
    if (fabsf(sp - 1.0f) > 0.005f || fabsf(vo - 1.0f) > 0.005f) {
        NSMutableDictionary *prosody = [NSMutableDictionary dictionary];
        if (fabsf(sp - 1.0f) > 0.005f) prosody[@"speed"] = @(sp);
        if (fabsf(vo - 1.0f) > 0.005f) {
            prosody[@"volume"] = @(20.0 * log10f(vo));
            body[@"normalize_loudness"] = @NO;
        }
        body[@"prosody"] = prosody;
    }

    NSError *jsonErr = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr || !jsonData) {
        if (completion) completion(NO, nil, @"请求构造失败");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kFishTTSURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    request.timeoutInterval = 60;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [request setValue:model forHTTPHeaderField:@"model"];

    NSLog(@"AWECA-Fish: synthesize ref=%@ model=%@ len=%lu", refID, model, (unsigned long)fullText.length);

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription]);
            });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200 || !data.length) {
            // 错误响应是 JSON：{"message": "..."}
            NSString *msg = @"服务错误";
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *m = json[@"message"] ?: json[@"detail"];
                if ([m isKindOfClass:[NSString class]] && m.length) msg = m;
            }
            if (!data.length) msg = @"服务器无响应";
            if (http.statusCode == 402) {
                msg = @"Fish Audio 余额不足：模型选「免费版」(s2.1-pro-free) 可零费用，或到 fish.audio/app/developers 充值";
            } else if (http.statusCode == 401) {
                msg = @"API Key 无效或已过期，请检查";
            }
            NSLog(@"AWECA-Fish: error %ld %@", (long)http.statusCode, msg);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, [NSString stringWithFormat:@"合成错误(%ld): %@", (long)http.statusCode, msg]);
            });
            return;
        }
        // 成功：响应体即 mp3 原始字节流
        NSLog(@"AWECA-Fish: got audio %lu bytes", (unsigned long)data.length);
        [self finishWithAudioData:data text:text previewOnly:previewOnly completion:completion];
    }] resume];
}

#pragma mark - FishAudio 音色库与头像

+ (NSArray<NSDictionary *> *)fishVoices {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kAWECFishVoices];
    return saved ?: @[];
}

+ (void)saveFishVoices:(NSArray<NSDictionary *> *)voices {
    [[NSUserDefaults standardUserDefaults] setObject:voices ?: @[] forKey:kAWECFishVoices];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)fishAvatarDirPath {
    NSString *dir = [[AWECAUtils audioSavePath] stringByAppendingPathComponent:@"fish_avatars"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)fishAvatarPathForVoiceID:(NSString *)vid {
    if (!vid.length) return nil;
    NSString *safe = [vid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[[AWECATTSManager fishAvatarDirPath] stringByAppendingPathComponent:safe] stringByAppendingPathExtension:@"jpg"];
}

- (UIImage *)fishAvatarForVoiceID:(NSString *)vid {
    NSString *p = [self fishAvatarPathForVoiceID:vid];
    if (!p || ![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return [UIImage imageWithContentsOfFile:p];
}

- (BOOL)saveFishAvatarImage:(UIImage *)image forVoiceID:(NSString *)vid {
    NSString *p = [self fishAvatarPathForVoiceID:vid];
    if (!p || !image) return NO;
    // 中心正方形裁剪
    CGFloat side = MIN(image.size.width, image.size.height);
    CGRect crop = CGRectMake((image.size.width - side) / 2.0, (image.size.height - side) / 2.0, side, side);
    CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, crop);
    if (!cg) return NO;
    UIImage *square = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    // 压缩到 256x256 JPEG
    CGSize target = CGSizeMake(256, 256);
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [square drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *jpeg = UIImageJPEGRepresentation(resized, 0.82);
    if (!jpeg.length) return NO;
    return [jpeg writeToFile:p atomically:YES];
}

- (void)deleteFishAvatarForVoiceID:(NSString *)vid {
    NSString *p = [self fishAvatarPathForVoiceID:vid];
    if (p) [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
}

#pragma mark - 解析响应

- (void)parseV3TTSResponse:(NSData *)data
                      text:(NSString *)text
               previewOnly:(BOOL)previewOnly
                completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    NSArray *chunks = AWECAJSONObjectsFromData(data);
    if (!chunks.count) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) chunks = @[json];
    }
    if (!chunks.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, nil, @"响应解析失败");
        });
        return;
    }

    NSMutableData *audioBuf = [NSMutableData data];
    NSString *errMsg = nil;
    NSInteger errCode = 0;
    for (NSDictionary *json in chunks) {
        NSInteger code = [json[@"code"] integerValue];
        BOOL codeOK = (!json[@"code"] || code == 0 || code == 20000000);
        if (!codeOK) {
            errCode = code;
            errMsg = json[@"message"] ?: @"未知错误";
            continue;
        }
        NSString *b64 = json[@"data"];
        if (![b64 isKindOfClass:[NSString class]] || b64.length == 0) {
            b64 = json[@"audio"];
        }
        if ([b64 isKindOfClass:[NSString class]] && b64.length > 0) {
            NSData *part = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (part.length) [audioBuf appendData:part];
        }
    }

    if (audioBuf.length) {
        [self finishWithAudioData:audioBuf text:text previewOnly:previewOnly completion:completion];
        return;
    }

    NSDictionary *last = chunks.lastObject;
    NSString *url = last[@"url"];
    if ([url isKindOfClass:[NSString class]] && url.length > 0) {
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *audioData, NSURLResponse *resp, NSError *err) {
            if (err || !audioData.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, nil, err.localizedDescription ?: @"音频下载失败");
                });
                return;
            }
            [self finishWithAudioData:audioData text:text previewOnly:previewOnly completion:completion];
        }] resume];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (errMsg.length) {
            NSString *finalMsg = errMsg;
            if (errCode == 55000000) finalMsg = @"音色与资源不匹配：复刻音色(S_开头)需在火山控制台开通「声音复刻2.0字符版」，且复刻音色不能过期";
            if (completion) completion(NO, nil, [NSString stringWithFormat:@"合成错误(%ld): %@", (long)errCode, finalMsg]);
        } else {
            if (completion) completion(NO, nil, @"音频数据为空");
        }
    });
}

- (void)finishWithAudioData:(NSData *)audioData
                       text:(NSString *)text
                previewOnly:(BOOL)previewOnly
                 completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {

    [AWECAUtils ensureDirectoriesExist];
    NSString *savePath = [[AWECAUtils audioSavePath] stringByAppendingPathComponent:@"tts_result.mp3"];
    BOOL writeOK = [audioData writeToFile:savePath atomically:YES];

    if (!writeOK) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, nil, @"音频保存失败");
        });
        return;
    }

    self.lastSynthesizedPath = savePath;
    [self saveConfig];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (previewOnly) {
            if (completion) completion(YES, savePath, nil);
            return;
        }

        AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
        replacer.ttsAudioPath = savePath;
        [replacer saveState];

        NSString *vName = (self.voiceName.length > 0) ? self.voiceName : @"未知音色";

        // 陌陌版：永远走 Ai 合成路径，不再弹「是否切换为Ai」冲突框
        // （那是抖音“普通语音替换”逻辑，在陌陌里无意义，且每次 #tts 都会挡住自动发送）
        __weak AWECAAudioReplacer *weakReplacer = replacer;
        [replacer setReplacementFromTTSPath:savePath text:text voiceName:vName completion:^(BOOL ok) {
            if (completion) {
                if (ok) {
                    double dur = [AWECAUtils audioDurationAtPath:weakReplacer.replacementAudioPath];
                    // v0.4.9.1：这里原本弹「成功合成 AI 语音」，与 Tweak 侧的「已就绪…」
                    // 只隔几十毫秒，两个黑框叠在一起。合成结果统一由调用方提示，这里不再弹。
                    completion(YES, weakReplacer.replacementAudioPath, [NSString stringWithFormat:@"语音合成成功 (%.1f秒)", dur]);
                } else {
                    completion(NO, savePath, @"合成成功但设置替换失败");
                }
            }
        }];
    });
}

#pragma mark - 冲突选择器

- (void)showTTSConflictAlertWithPath:(NSString *)ttsPath
                                text:(NSString *)text
                           voiceName:(NSString *)voiceName
                          completion:(void(^)(BOOL success, NSString *audioPath, NSString *error))completion {
    UIViewController *topVC = [AWECAUtils topViewController];
    if (!topVC) {
        [[AWECAAudioReplacer shared] setReplacementFromTTSPath:ttsPath text:text voiceName:voiceName completion:^(BOOL ok) {
            if (completion) completion(ok, ttsPath, ok ? @"语音合成成功" : @"设置替换失败");
        }];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"当前已选择普通语音替换"
                                                                  message:@"是否切换为Ai合成语音?"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"使用Ai" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        AWECAAudioReplacer *replacer = [AWECAAudioReplacer shared];
        __weak AWECAAudioReplacer *weakReplacer = replacer;
        [replacer setReplacementFromTTSPath:ttsPath text:text voiceName:voiceName completion:^(BOOL ok) {
            if (completion) {
                if (ok) {
                    double dur = [AWECAUtils audioDurationAtPath:weakReplacer.replacementAudioPath];
                    // v0.4.9.1：同上，去掉这条重复提示，避免和「已就绪…」叠在一起
                    completion(YES, weakReplacer.replacementAudioPath, [NSString stringWithFormat:@"语音合成成功 (%.1f秒)", dur]);
                } else {
                    completion(NO, ttsPath, @"合成成功但设置替换失败");
                }
            }
        }];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"不使用Ai" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (completion) completion(YES, ttsPath, @"合成已保存，当前使用普通语音");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (completion) completion(YES, ttsPath, @"合成已保存");
    }]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = topVC.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2, topVC.view.bounds.size.height, 0, 0);
    }

    [topVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 试听播放

- (void)playAudioAtPath:(NSString *)path {
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [AWECAUtils showToast:@"音频文件不存在"];
        return;
    }

    [self stopPlayback];

    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (err || !self.player) {
        [AWECAUtils showToast:@"播放失败"];
        return;
    }

    self.player.delegate = self;

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [audioSession setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:nil];
    [audioSession setActive:YES error:nil];

    [self.player play];
}

- (void)stopPlayback {
    if (self.player && self.player.isPlaying) {
        [self.player stop];
    }
    self.player = nil;
}

- (BOOL)isPlaying {
    return self.player && self.player.isPlaying;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.player = nil;
}

#pragma mark - 内置情绪（v0.4.9）

// 30 条 Fish Audio 情绪标签 + 中文备注（备注只影响列表显示，合成始终用英文标签）
+ (NSArray<NSArray<NSString *> *> *)sl_defaultFishEmotions {
    static NSArray *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            @[@"Continuous Panting",    @"持续喘气"],
            @[@"Continuous Gasping",    @"连连倒气"],
            @[@"Sustained Wheezing",    @"不停哮喘"],
            @[@"Rapid Breathing",       @"急促呼吸"],
            @[@"Repeated Gulping",      @"反复吞咽"],
            @[@"Fits of Coughing",      @"一阵咳嗽"],
            @[@"Repeated Sneezing",     @"连续喷嚏"],
            @[@"Audible Swallowing",    @"吞咽出声"],
            @[@"Repeated Burping",      @"反复打嗝"],
            @[@"Long Yawning",          @"长长哈欠"],
            @[@"Continuous Groaning",   @"持续哼唧"],
            @[@"Sustained Moaning",     @"连绵呻吟"],
            @[@"Continuous Screaming",  @"持续尖叫"],
            @[@"Prolonged Shouting",    @"长时间喊"],
            @[@"Continuous Sobbing",    @"不停抽泣"],
            @[@"Constant Whining",      @"委屈抱怨"],
            @[@"Continuous Roaring",    @"持续咆哮"],
            @[@"Uncontrollable Laughter", @"放声大笑"],
            @[@"Soft Chuckling",        @"轻声轻笑"],
            @[@"Repeated Snickering",   @"连连偷笑"],
            @[@"Indistinct Mumbling",   @"含糊嘟囔"],
            @[@"Stuttering Speech",     @"结巴说话"],
            @[@"Soft Murmuring",        @"柔声低语"],
            @[@"Echoing Voice",         @"空灵回声"],
            @[@"Angry Muttering",       @"生气嘟囔"],
            @[@"Repeated Sniffling",    @"反复抽鼻"],
            @[@"Sighing Heavily",       @"重重叹气"],
            @[@"Awkward Silence",       @"尴尬沉默"],
            @[@"Hesitant Speech",       @"迟疑说话"],
            @[@"Deep Sighing",          @"深深叹气"],
        ];
    });
    return table;
}

// 把标签的括号剥掉，便于「已存在」判断（用户可能自建过同一个标签、括号不同）
static NSString *SLEmotionBare(NSString *tag) {
    if (![tag isKindOfClass:[NSString class]] || tag.length < 3) return tag ?: @"";
    unichar f = [tag characterAtIndex:0];
    unichar l = [tag characterAtIndex:tag.length - 1];
    if ((f == '[' && l == ']') || (f == '(' && l == ')')) {
        return [tag substringWithRange:NSMakeRange(1, tag.length - 2)];
    }
    return tag;
}

// 首次启动补齐 30 条内置情绪；已有自定义的只补缺失项，不覆盖备注、不动已勾选状态
- (void)seedDefaultFishEmotions {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:@"SLDefaultEmotionsV1"]) return;

    NSMutableArray<NSString *> *all = [self.fishEmotionAll mutableCopy] ?: [NSMutableArray array];
    NSMutableArray<NSString *> *notes = [self.fishEmotionNotes mutableCopy] ?: [NSMutableArray array];
    while (notes.count < all.count) [notes addObject:@""];

    BOOL s1 = [self.fishModel isEqualToString:@"s1"];
    for (NSArray<NSString *> *pair in [AWECATTSManager sl_defaultFishEmotions]) {
        NSString *bare = pair[0];
        BOOL exists = NO;
        for (NSString *x in all) {
            if ([SLEmotionBare(x) caseInsensitiveCompare:bare] == NSOrderedSame) { exists = YES; break; }
        }
        if (exists) continue;
        [all addObject:(s1 ? [NSString stringWithFormat:@"(%@)", bare] : [NSString stringWithFormat:@"[%@]", bare])];
        [notes addObject:pair[1]];
    }
    if (notes.count > all.count) notes = [[notes subarrayWithRange:NSMakeRange(0, all.count)] mutableCopy];

    self.fishEmotionAll = all;
    self.fishEmotionNotes = notes;
    [d setBool:YES forKey:@"SLDefaultEmotionsV1"];
    [self saveConfig];
}

#pragma mark - 音色导入（v0.4.9）

static NSString *SLStringOf(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

// 单个音色对象 → 归一化字段；识别不了返回 nil
+ (NSDictionary *)sl_normalizeVoiceItem:(NSDictionary *)raw inheritedCategory:(NSString *)cat skipped:(NSInteger *)skipped {
    if (![raw isKindOfClass:[NSDictionary class]]) { if (skipped) (*skipped)++; return nil; }

    // v0.4.9.1：Fish 官方接口的 type 只有 "tts" / "svc"，旧逻辑「type 不含 fish 就跳过」
    // 会把整页结果全丢掉（报「接口返回里没有解析到音色」就是这里）。
    // 改成只排除明确的他家引擎，tts / svc / 没有 type 的一律按 Fish 收。
    NSString *type = SLStringOf(raw[@"type"]) ?: SLStringOf(raw[@"engine"]);
    if (type.length) {
        NSString *t = type.lowercaseString;
        BOOL isFish = [t rangeOfString:@"fish"].location != NSNotFound
                   || [t isEqualToString:@"tts"] || [t isEqualToString:@"svc"];
        BOOL isOtherEngine = [t hasPrefix:@"fine"] || [t hasPrefix:@"kk"]
                          || [t hasPrefix:@"volc"] || [t hasPrefix:@"azure"] || [t hasPrefix:@"edge"];
        if (isOtherEngine && !isFish) {
            if (skipped) (*skipped)++;
            return nil;
        }
    }
    NSString *vid = SLStringOf(raw[@"vid"]) ?: SLStringOf(raw[@"voice_id"])
                 ?: SLStringOf(raw[@"voiceType"]) ?: SLStringOf(raw[@"reference_id"])
                 ?: SLStringOf(raw[@"_id"]) ?: SLStringOf(raw[@"id"]);
    vid = [vid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!vid.length) { if (skipped) (*skipped)++; return nil; }

    NSString *name = SLStringOf(raw[@"name"]) ?: SLStringOf(raw[@"title"])
                  ?: SLStringOf(raw[@"voice_name"]) ?: SLStringOf(raw[@"nickname"]) ?: vid;
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) name = vid;

    NSString *img = SLStringOf(raw[@"img"]) ?: SLStringOf(raw[@"avatar"])
                 ?: SLStringOf(raw[@"cover_image"]) ?: SLStringOf(raw[@"cover"]);
    // cover_image 常是相对路径（coverimage/xxxx），不补域名 NSURL 会建失败、头像永远下不来
    if (img.length && [img rangeOfString:@"http" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        NSString *p = [img hasPrefix:@"/"] ? [img substringFromIndex:1] : img;
        img = [@"https://fish.audio/" stringByAppendingString:p];
    }
    NSString *category = SLStringOf(raw[@"category"]) ?: SLStringOf(raw[@"cat"])
                      ?: SLStringOf(raw[@"group"]) ?: cat ?: @"";

    return @{ @"name": name, @"voiceType": vid, @"img": img ?: @"", @"category": category };
}

// 递归展开：数组 / 字典包一层 / 分类字典
+ (void)sl_collectVoiceItems:(id)node inheritedCategory:(NSString *)cat
                       into:(NSMutableArray *)out skipped:(NSInteger *)skipped {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id one in (NSArray *)node) {
            if ([one isKindOfClass:[NSDictionary class]]) {
                // 分类字典里再套一层 {"name":..., "list":[...]} 的写法
                id nested = ((NSDictionary *)one)[@"voices"] ?: ((NSDictionary *)one)[@"list"];
                if ([nested isKindOfClass:[NSArray class]]) {
                    NSString *sub = SLStringOf(((NSDictionary *)one)[@"category"])
                                 ?: SLStringOf(((NSDictionary *)one)[@"name"]) ?: cat;
                    [self sl_collectVoiceItems:nested inheritedCategory:sub into:out skipped:skipped];
                    continue;
                }
                NSDictionary *n = [self sl_normalizeVoiceItem:one inheritedCategory:cat skipped:skipped];
                if (n) [out addObject:n];
            } else if ([one isKindOfClass:[NSArray class]]) {
                [self sl_collectVoiceItems:one inheritedCategory:cat into:out skipped:skipped];
            } else {
                if (skipped) (*skipped)++;
            }
        }
        return;
    }
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        id inner = dict[@"items"] ?: dict[@"voices"] ?: dict[@"data"]
                ?: dict[@"list"] ?: dict[@"models"] ?: dict[@"result"];
        if (inner) {
            [self sl_collectVoiceItems:inner inheritedCategory:cat into:out skipped:skipped];
            return;
        }
        // {"分类名": [ ... ], ...} 形态（voicesByCat / categories / 直接分类键）
        for (NSString *key in dict) {
            id v = dict[key];
            if ([v isKindOfClass:[NSArray class]]) {
                [self sl_collectVoiceItems:v inheritedCategory:key into:out skipped:skipped];
            }
        }
        return;
    }
    if (skipped) (*skipped)++;
}

+ (NSArray<NSDictionary *> *)sl_parseVoiceJSONText:(NSString *)text skipped:(NSInteger *)skipped {
    NSInteger local = 0;
    if (skipped) *skipped = 0;
    NSMutableArray *out = [NSMutableArray array];
    if (![text isKindOfClass:[NSString class]] || !text.length) return out;

    NSString *s = [text stringByReplacingOccurrencesOfString:@"\uFEFF" withString:@""];
    NSRange firstBrace = [s rangeOfString:@"["];
    NSRange firstCurly = [s rangeOfString:@"{"];
    NSUInteger start = NSNotFound;
    if (firstBrace.location != NSNotFound && firstCurly.location != NSNotFound) {
        start = MIN(firstBrace.location, firstCurly.location);
    } else if (firstBrace.location != NSNotFound) {
        start = firstBrace.location;
    } else if (firstCurly.location != NSNotFound) {
        start = firstCurly.location;
    }
    if (start == NSNotFound) { if (skipped) *skipped = 0; return out; }

    NSRange rBracket = [s rangeOfString:@"]" options:NSBackwardsSearch];
    NSRange rBrace = [s rangeOfString:@"}" options:NSBackwardsSearch];
    NSUInteger end = MAX(rBracket.location == NSNotFound ? 0 : rBracket.location,
                         rBrace.location == NSNotFound ? 0 : rBrace.location);
    if (end < start) end = s.length - 1;
    NSString *json = [s substringWithRange:NSMakeRange(start, end - start + 1)];

    id root = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (!root) return out;
    [self sl_collectVoiceItems:root inheritedCategory:nil into:out skipped:&local];

    // 同一次导入内按 vid 去重（后出现的名字覆盖前面的）
    NSMutableDictionary *byVid = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *v in out) {
        NSString *vid = v[@"voiceType"];
        if (!byVid[vid]) [order addObject:vid];
        byVid[vid] = v;
    }
    NSMutableArray *dedup = [NSMutableArray array];
    for (NSString *vid in order) [dedup addObject:byVid[vid]];

    if (skipped) *skipped = local;
    return dedup;
}

+ (NSDictionary *)sl_importFishVoices:(NSArray<NSDictionary *> *)items {
    NSInteger added = 0, updated = 0;
    if (![items isKindOfClass:[NSArray class]] || !items.count) {
        return @{ @"added": @0, @"updated": @0 };
    }
    NSMutableArray<NSDictionary *> *lib = [[AWECATTSManager fishVoices] mutableCopy] ?: [NSMutableArray array];
    for (NSDictionary *it in items) {
        NSString *vid = it[@"voiceType"];
        NSString *name = it[@"name"];
        if (!vid.length) continue;
        NSInteger hit = -1;
        for (NSUInteger i = 0; i < lib.count; i++) {
            if ([lib[i][@"voiceType"] isEqualToString:vid]) { hit = (NSInteger)i; break; }
        }
        if (hit >= 0) {
            NSMutableDictionary *m = [lib[hit] mutableCopy];
            if (name.length) m[@"name"] = name;
            m[@"voiceType"] = vid;
            lib[hit] = m;
            updated++;
        } else {
            [lib addObject:@{ @"name": name.length ? name : vid,
                              @"voiceType": vid,
                              @"color": @(lib.count % 6) }];
            added++;
        }
    }
    [AWECATTSManager saveFishVoices:lib];
    return @{ @"added": @(added), @"updated": @(updated) };
}

+ (void)sl_downloadAvatarForVoice:(NSString *)vid fromURL:(NSString *)urlString {
    if (!vid.length || !urlString.length) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp; (void)err;
        if (!data.length) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        [[AWECATTSManager shared] saveFishAvatarImage:img forVoiceID:vid];
    }] resume];
}

#pragma mark - 持久化

- (void)saveConfig {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (self.appID) [d setObject:self.appID forKey:kAWECATTSAppID];
    if (self.accessToken) [d setObject:self.accessToken forKey:kAWECATTSAccessToken];
    if (self.voiceType) [d setObject:self.voiceType forKey:kAWECATTSVoiceType];
    if (self.voiceName) [d setObject:self.voiceName forKey:kAWECATTSVoiceName];
    if (self.voiceType) [d setObject:self.voiceType forKey:kAWECATTSVolcanoVoiceType];
    if (self.voiceName) [d setObject:self.voiceName forKey:kAWECATTSVolcanoVoiceName];
    [d setFloat:self.speedRatio forKey:kAWECATTSSpeedRatio];
    [d setFloat:self.volumeRatio forKey:kAWECATTSVolumeRatio];
    [d setFloat:self.pitchRatio forKey:kAWECATTSPitchRatio];
    [d setObject:self.contextText ?: @"" forKey:kAWECATTSContextText];
    [d setObject:[AWECATTSManager canonicalDialect:self.explicitDialect] forKey:kAWECATTSDialect];
    [d setInteger:self.silenceDurationMs forKey:kAWECATTSSilenceMs];
    if (self.lastSynthesizedPath) [d setObject:self.lastSynthesizedPath forKey:kAWECATTSLastPath];
    [d setBool:self.fishEngine forKey:kAWECATTSEngine];
    [d setObject:self.fishAPIKey ?: @"" forKey:kAWECFishAPIKey];
    [d setObject:self.fishModel ?: @"s2.1-pro-free" forKey:kAWECFishModel];
    [d setObject:self.fishVoiceType ?: @"" forKey:kAWECFishVoiceType];
    [d setObject:self.fishVoiceName ?: @"" forKey:kAWECFishVoiceName];
    [d setObject:self.fishEmotionSel ?: @[] forKey:kAWECFishEmotionSel];
    [d setObject:self.fishEmotionAll ?: @[] forKey:kAWECFishEmotionAll];
    [d setObject:self.fishEmotionNotes ?: @[] forKey:kAWECFishEmotionNotes];
    [d synchronize];
}

- (void)loadConfig {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.appID = AWECATrim([d objectForKey:kAWECATTSAppID]);
    self.accessToken = AWECATrim([d objectForKey:kAWECATTSAccessToken]);
    self.voiceType = [d objectForKey:kAWECATTSVoiceType];
    self.voiceName = [d objectForKey:kAWECATTSVoiceName];

    float sp = [d floatForKey:kAWECATTSSpeedRatio];
    float vo = [d floatForKey:kAWECATTSVolumeRatio];
    self.speedRatio = (sp > 0.01f) ? sp : 1.0f;
    self.volumeRatio = (vo > 0.01f) ? vo : 1.0f;
    id pitchObj = [d objectForKey:kAWECATTSPitchRatio];
    self.pitchRatio = pitchObj ? [pitchObj floatValue] : 1.0f;
    if (self.pitchRatio < 0.0f) self.pitchRatio = 0.0f;
    if (self.pitchRatio > 2.0f) self.pitchRatio = 2.0f;
    self.contextText = [d objectForKey:kAWECATTSContextText] ?: @"";
    self.explicitDialect = [AWECATTSManager canonicalDialect:[d objectForKey:kAWECATTSDialect]];
    self.silenceDurationMs = [d integerForKey:kAWECATTSSilenceMs];

    self.lastSynthesizedPath = [d objectForKey:kAWECATTSLastPath];

    self.fishEngine = [d boolForKey:kAWECATTSEngine];
    self.fishAPIKey = AWECATrim([d objectForKey:kAWECFishAPIKey]);
    self.fishModel = [d objectForKey:kAWECFishModel] ?: @"s2.1-pro-free";
    self.fishVoiceType = [d objectForKey:kAWECFishVoiceType];
    self.fishVoiceName = [d objectForKey:kAWECFishVoiceName];
    id selEmo = [d objectForKey:kAWECFishEmotionSel];
    self.fishEmotionSel = [selEmo isKindOfClass:[NSArray class]] ? selEmo : @[];
    id allEmo = [d objectForKey:kAWECFishEmotionAll];
    self.fishEmotionAll = [allEmo isKindOfClass:[NSArray class]] ? allEmo : @[];
    // 中文备注：平行数组，长度对齐 fishEmotionAll（旧数据无备注 -> 全空串兼容）
    NSArray *notes = [d objectForKey:kAWECFishEmotionNotes];
    if (![notes isKindOfClass:[NSArray class]]) notes = nil;
    NSMutableArray<NSString *> *aligned = [NSMutableArray arrayWithCapacity:self.fishEmotionAll.count];
    for (NSUInteger i = 0; i < self.fishEmotionAll.count; i++) {
        NSString *n = (notes && i < notes.count) ? notes[i] : nil;
        [aligned addObject:([n isKindOfClass:[NSString class]] ? n : @"")];
    }
    self.fishEmotionNotes = aligned;

    // v0.4.9：首次启动补齐 30 条内置情绪（带中文备注）
    [self seedDefaultFishEmotions];
}

@end
