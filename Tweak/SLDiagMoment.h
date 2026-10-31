// 声临·陌陌版 v0.4.96 只读诊断：时刻（MDMoment）拍摄页的视图几何采集
//
// 目的：确认「实拍时刻拍摄时图片被放大」到底发生在哪一层 ——
//   ① 预览容器（contentView）本身是全屏还是方形；
//   ② 播放器层 videoGravity 是不是 ResizeAspectFill；
//   ③ 图片层（UIImageView）的 contentMode 与原图 size。
//
// 实现原则：不装任何方法钩子、不改任何行为，只按秒轮询顶层 VC 类名，
// 命中 Moment/Record/Camera 等页面后 dump 一次视图树到 slmomo.log。

#import <Foundation/Foundation.h>

/// 启动诊断轮询（幂等，可重复调用）
void SLDiagMomentInstall(void);
