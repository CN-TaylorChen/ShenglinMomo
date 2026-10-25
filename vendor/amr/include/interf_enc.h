// opencore-amrnb 编码器接口（Apache License 2.0，原属 PacketVideo / opencore-amr）
// 这里只保留我们需要的三个函数声明，避免依赖第三方头文件。
#ifndef SL_INTERF_ENC_H
#define SL_INTERF_ENC_H

#ifdef __cplusplus
extern "C" {
#endif

enum Mode {
    MR475 = 0,
    MR515,
    MR59,
    MR67,
    MR74,
    MR795,
    MR102,
    MR122,
    MRDTX,
    N_MODES
};

/* dtx: 0=关闭 1=开启；返回编码器状态句柄 */
void *Encoder_Interface_init(int dtx);

/* speech: 160 个 16bit、8kHz 单声道采样（20ms）
   out:   至少 32 字节的缓冲区，返回值为本帧字节数（含 1 字节 TOC 头） */
int Encoder_Interface_Encode(void *st, enum Mode mode, const short *speech, unsigned char *out, int forceSpeech);

void Encoder_Interface_exit(void *st);

#ifdef __cplusplus
}
#endif
#endif /* SL_INTERF_ENC_H */
