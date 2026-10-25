// 陌陌版流水线：录音文件 → ASR 识别 → TTS 合成 → 可写回陌陌原路径的音频
// 核心逻辑从声临 AWECARecordEnhance 移植（TOS 上传 + 火山标准版 submit/query + 音色合成）

#import "SLPipeline.h"
#import "AWECATTSManager.h"
#import "AWECAUtils.h"
#import "AWECATOSUploader.h"

#define kASRSubmitURL         @"https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
#define kASRQueryURL          @"https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
#define kASRDefaultResourceId @"volc.seedasr.auc"
#define kSLEnhanceTimeout     120.0
#define kASRQueryInterval     3.0
#define kASRMaxQueryRounds    30
#define kASRSubmitRetries     2

static NSString *SLTrim(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *SLASRHeader(NSDictionary *headers, NSString *key) {
    id v = headers[key];
    if (!v) {
        for (NSString *k in headers) {
            if ([k caseInsensitiveCompare:key] == NSOrderedSame) { v = headers[k]; break; }
        }
    }
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return nil;
}

static NSString *SLASRCodeHint(NSString *code) {
    if ([code isEqualToString:@"45000030"]) return @"标准版识别未开通：火山控制台「服务管理」→ 录音文件识别 → 开通标准版资源";
    if ([code isEqualToString:@"45000001"]) return @"请求参数无效（音频 URL 无法下载或格式不支持）";
    if ([code isEqualToString:@"45000002"]) return @"空音频";
    if ([code isEqualToString:@"45000151"]) return @"音频格式不正确";
    if ([code isEqualToString:@"45000132"]) return @"音频超过大小限制";
    if ([code isEqualToString:@"55000031"]) return @"服务器繁忙，请稍后重试";
    return nil;
}

@implementation SLPipeline

+ (instancetype)shared {
    static SLPipeline *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[SLPipeline alloc] init]; });
    return inst;
}

- (NSString *)audioFormatForPath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"aac"] ||
        [ext isEqualToString:@"mp3"] || [ext isEqualToString:@"wav"] ||
        [ext isEqualToString:@"ogg"] || [ext isEqualToString:@"mp4"]) return ext;
    if ([ext isEqualToString:@"caf"]) return @"aac";
    return @"amr";
}

- (NSString *)textFromASRJSON:(NSDictionary *)json {
    id result = json[@"result"];
    if ([result isKindOfClass:[NSString class]]) return SLTrim((NSString *)result);
    if ([result isKindOfClass:[NSDictionary class]]) {
        NSString *text = result[@"text"];
        if (text.length) return SLTrim(text);
        NSArray *utterances = result[@"utterances"];
        if ([utterances isKindOfClass:[NSArray class]]) {
            NSMutableString *buf = [NSMutableString string];
            for (id u in utterances) {
                if (![u isKindOfClass:[NSDictionary class]]) continue;
                NSString *t = u[@"text"];
                if (t.length) [buf appendString:t];
            }
            if (buf.length) return SLTrim(buf);
        }
    }
    NSString *text = json[@"text"];
    if ([text isKindOfClass:[NSString class]] && text.length) return SLTrim(text);
    return nil;
}

- (void)enhanceRecordedAudioAtPath:(NSString *)path
                 originalDuration:(double)origDuration
                       completion:(SLPipelineResult)completion {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (completion) completion(NO, nil, origDuration, @"录音文件不存在");
        return;
    }
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSLEnhanceTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (done) return;
        done = YES;
        if (completion) completion(NO, nil, origDuration, @"处理超时，已保留原声");
    });

    NSString *wavPath = [path stringByAppendingString:@".sl16k.wav"];
    [AWECAUtils convertAudioAtPath:path toWAV16kPath:wavPath completion:^(BOOL success, NSError *error) {
        NSString *sendPath = success ? wavPath : path;
        [weakSelf uploadThenRecognizeAtPath:sendPath completion:^(NSString *text, NSString *err) {
            [[NSFileManager defaultManager] removeItemAtPath:wavPath error:nil];
            if (done) return;
            if (!text.length) {
                done = YES;
                if (completion) completion(NO, nil, origDuration, err.length ? err : @"识别失败，已保留原声");
                return;
            }
            [AWECAUtils showToast:@"正在合成..." duration:2.0];
            [[AWECATTSManager shared] synthesizeText:text completion:^(BOOL success2, NSString *audioPath, NSString *ttsError) {
                if (done) return;
                if (!success2 || !audioPath.length) {
                    done = YES;
                    if (completion) completion(NO, nil, origDuration, ttsError.length ? ttsError : @"合成失败，已保留原声");
                    return;
                }
                // 输出合成音频给调用方：由 Tweak 侧决定如何写回陌陌的原路径
                double dur = [AWECAUtils audioDurationAtPath:audioPath];
                done = YES;
                if (completion) completion(YES, audioPath, dur > 0 ? dur : origDuration, @"ok");
            }];
        }];
    }];
}

#pragma mark - 识别

- (void)uploadThenRecognizeAtPath:(NSString *)path
                       completion:(void(^)(NSString *text, NSString *error))completion {
    if (![AWECATOSUploader hasCredentials]) {
        if (completion) completion(nil, @"未配置 TOS：请在「API 凭证」里填写 AK/SK/Bucket/区域，已保留原声");
        return;
    }
    NSString *ext = path.pathExtension.lowercaseString;
    if (!ext.length) ext = @"wav";
    NSString *objectKey = [NSString stringWithFormat:@"shenglin-asr/%@.%@", [[NSUUID UUID] UUIDString], ext];
    [AWECAUtils showToast:@"上传识别中..." duration:2.0];
    [AWECATOSUploader uploadFileAtPath:path objectKey:objectKey completion:^(NSString *url, NSError *error) {
        if (!url.length) {
            NSString *msg = error.localizedDescription ?: @"上传失败";
            if (completion) completion(nil, [NSString stringWithFormat:@"%@，已保留原声", msg]);
            return;
        }
        [self submitASRWithURL:url
                        format:([ext isEqualToString:@"wav"] ? @"wav" : [self audioFormatForPath:path])
                    completion:^(NSString *text, NSString *err) {
            [AWECATOSUploader deleteObject:objectKey completion:nil];
            if (completion) completion(text, err);
        }];
    }];
}

- (void)submitASRWithURL:(NSString *)url format:(NSString *)format
              completion:(void(^)(NSString *text, NSString *error))completion {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    NSString *requestId = [[NSUUID UUID] UUIDString];
    NSMutableDictionary *audioDict = [@{ @"url": url, @"format": format.length ? format : @"wav", @"language": @"zh-CN" } mutableCopy];
    if ([format isEqualToString:@"wav"]) {
        audioDict[@"codec"] = @"raw";
        audioDict[@"rate"] = @16000;
        audioDict[@"bits"] = @16;
        audioDict[@"channel"] = @1;
    }
    NSDictionary *body = @{
        @"user": @{ @"uid": mgr.appID.length ? mgr.appID : @"shenglin_user" },
        @"audio": audioDict,
        @"request": @{ @"model_name": @"bigmodel", @"enable_itn": @YES, @"enable_punc": @YES }
    };
    [self postASRSubmit:body requestId:requestId attempt:0 completion:^(NSString *error) {
        if (error) { if (completion) completion(nil, error); return; }
        [self pollASRQuery:requestId attempt:0 completion:completion];
    }];
}

- (void)postASRSubmit:(NSDictionary *)body requestId:(NSString *)requestId attempt:(NSInteger)attempt
            completion:(void(^)(NSString *error))completion {
    [self postASRRequest:body url:kASRSubmitURL requestId:requestId includeSequence:YES
              completion:^(NSDictionary *json, NSString *statusCode, NSString *error) {
        (void)json;
        if (!error && (!statusCode.length || [statusCode isEqualToString:@"20000000"] || [statusCode isEqualToString:@"0"])) {
            if (completion) completion(nil);
            return;
        }
        if (error && attempt + 1 < kASRSubmitRetries) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self postASRSubmit:body requestId:requestId attempt:attempt + 1 completion:completion];
            });
            return;
        }
        if (completion) {
            if (error) completion([error stringByAppendingString:@"，已保留原声"]);
            else {
                NSString *hint = SLASRCodeHint(statusCode) ?: @"提交失败";
                completion([NSString stringWithFormat:@"识别提交错误(%@): %@，已保留原声", statusCode ?: @"未知", hint]);
            }
        }
    }];
}

- (void)pollASRQuery:(NSString *)requestId attempt:(NSInteger)attempt
          completion:(void(^)(NSString *text, NSString *error))completion {
    if (attempt >= kASRMaxQueryRounds) {
        if (completion) completion(nil, @"识别超时（轮询用尽），已保留原声");
        return;
    }
    NSTimeInterval delay = (attempt == 0) ? 1.0 : kASRQueryInterval;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self postASRRequest:@{} url:kASRQueryURL requestId:requestId includeSequence:NO
                  completion:^(NSDictionary *json, NSString *statusCode, NSString *error) {
            if (error) {
                [self pollASRQuery:requestId attempt:attempt + 1 completion:completion];
                return;
            }
            if ([statusCode isEqualToString:@"20000000"] || [statusCode isEqualToString:@"0"]) {
                NSString *text = [self textFromASRJSON:json];
                if (completion) completion(text.length ? text : nil, text.length ? nil : @"未识别到文字");
                return;
            }
            if ([statusCode isEqualToString:@"20000001"] || [statusCode isEqualToString:@"20000002"]) {
                [self pollASRQuery:requestId attempt:attempt + 1 completion:completion];
                return;
            }
            if ([statusCode isEqualToString:@"20000003"]) {
                if (completion) completion(nil, @"未检测到人声（静音），已保留原声");
                return;
            }
            NSString *msg = json[@"message"] ?: json[@"msg"] ?: SLASRCodeHint(statusCode) ?: @"失败";
            if (completion) {
                completion(nil, [NSString stringWithFormat:@"识别错误(%@): %@，已保留原声", statusCode ?: @"未知", msg]);
            }
        }];
    });
}

- (void)postASRRequest:(NSDictionary *)body
                   url:(NSString *)url
            requestId:(NSString *)requestId
      includeSequence:(BOOL)includeSequence
           completion:(void(^)(NSDictionary *json, NSString *statusCode, NSString *error))completion {
    AWECATTSManager *mgr = [AWECATTSManager shared];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) jsonData = [NSData data];
    NSString *resourceId = SLTrim([[NSUserDefaults standardUserDefaults] stringForKey:kAWECAASRResourceId]);
    if (!resourceId.length) resourceId = kASRDefaultResourceId;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = jsonData;
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [mgr applyVolcanoHTTPAuthToRequest:req];
    [req setValue:resourceId forHTTPHeaderField:@"X-Api-Resource-Id"];
    [req setValue:requestId forHTTPHeaderField:@"X-Api-Request-Id"];
    if (includeSequence) [req setValue:@"-1" forHTTPHeaderField:@"X-Api-Sequence"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^finished)(NSDictionary *, NSString *, NSString *) = ^(NSDictionary *j, NSString *code, NSString *err) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(j, code, err); });
        };
        if (error) {
            finished(nil, nil, [NSString stringWithFormat:@"识别网络错误: %@", error.localizedDescription]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *apiCode = SLASRHeader(http.allHeaderFields, @"X-Api-Status-Code");
        if (!apiCode.length) {
            finished(nil, nil, @"识别响应异常（无状态码）");
            return;
        }
        NSDictionary *json = nil;
        if (data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) json = obj;
        }
        finished(json, apiCode, nil);
    }] resume];
}

@end
