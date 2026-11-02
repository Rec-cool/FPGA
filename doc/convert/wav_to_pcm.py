"""
WAV -> wav_stream_player 所需的 raw PCM

输出格式：16 位有符号、小端序、48 kHz、单声道，无文件头，
尾部补零到 512 字节整数倍（FPGA 按整扇区读取）。

用法：
    python wav_to_pcm.py 输入.wav [输出.PCM] [--gain 0.9]

依赖：numpy（不需要 scipy / ffmpeg）
"""
import argparse
import os
import struct
import sys

import numpy as np

TARGET_RATE = 48000
SECTOR = 512


def read_wav(path):
    """手动解析 RIFF chunk，跳过 LIST 等非音频块。返回 (float32[n, ch], rate)。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        sys.exit("不是 RIFF/WAVE 文件")

    pos = 12
    fmt = None
    pcm = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", body, 0)
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)  # chunk 按 2 字节对齐

    if fmt is None or pcm is None:
        sys.exit("缺少 fmt 或 data 块")
    audio_fmt, ch, rate, _, block_align, bits = fmt
    # 0xFFFE = WAVE_FORMAT_EXTENSIBLE，子格式通常也是 PCM
    if audio_fmt not in (1, 3, 0xFFFE):
        sys.exit(f"不支持的编码格式 {audio_fmt}（只支持 PCM / float）")

    n = len(pcm) // block_align
    pcm = pcm[:n * block_align]
    if audio_fmt == 3 and bits == 32:
        x = np.frombuffer(pcm, "<f4").astype(np.float32)
    elif bits == 16:
        x = np.frombuffer(pcm, "<i2").astype(np.float32) / 32768.0
    elif bits == 24:
        b = np.frombuffer(pcm, np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        v = np.where(v & 0x800000, v - 0x1000000, v)
        x = v.astype(np.float32) / 8388608.0
    elif bits == 32:
        x = np.frombuffer(pcm, "<i4").astype(np.float32) / 2147483648.0
    elif bits == 8:
        x = (np.frombuffer(pcm, np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        sys.exit(f"不支持的位深 {bits}")
    return x.reshape(-1, ch), rate, ch, bits


def resample(x, src, dst, taps=32, beta=8.0):
    """多相 Kaiser 窗 sinc 重采样（有理数比 dst/src = L/M）。"""
    if src == dst:
        return x
    g = np.gcd(src, dst)
    L, M = dst // g, src // g          # 44100->48000: L=160, M=147
    cutoff = min(1.0, dst / src) * 0.95  # 相对输入奈奎斯特频率，留 5% 过渡带

    # 系数表 h[phase, k]：输出点落在两输入点之间 phase/L 处，第 k 个抽头
    half = taps // 2
    k = np.arange(-half + 1, half + 1)               # 抽头相对 i0 的偏移
    frac = np.arange(L)[:, None] / L                 # 输出点相对 i0 的小数位置
    d = frac - k[None, :]                            # 到各输入点的距离（输入采样单位）
    win = np.i0(beta * np.sqrt(np.clip(1 - (d / half) ** 2, 0, 1))) / np.i0(beta)
    h = (cutoff * np.sinc(cutoff * d) * win).astype(np.float32)
    h /= h.sum(axis=1, keepdims=True)                # 每个相位直流增益归一

    n_out = (len(x) * L) // M
    pos = np.arange(n_out, dtype=np.int64) * M
    i0 = pos // L
    phase = pos % L
    xp = np.pad(x, (half, half))                     # 两端补零，免得越界
    y = np.zeros(n_out, dtype=np.float32)
    for j, kk in enumerate(k):
        y += xp[i0 + kk + half] * h[phase, j]
    return y


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="WAV 转 48kHz/16bit/单声道 raw PCM")
    ap.add_argument("input")
    ap.add_argument("output", nargs="?", help="默认与输入同目录的 MUSIC.PCM")
    ap.add_argument("--gain", type=float, default=0.9,
                    help="输出增益，默认 0.9（重采样有过冲，留一点余量防削波）")
    args = ap.parse_args()

    out = args.output or os.path.join(os.path.dirname(os.path.abspath(args.input)), "MUSIC.PCM")

    x, rate, ch, bits = read_wav(args.input)
    print(f"输入: {rate} Hz, {ch} 声道, {bits} bit, {len(x)} 帧, {len(x) / rate:.2f} s")

    mono = x.mean(axis=1)                       # 立体声 -> 单声道
    y = resample(mono, rate, TARGET_RATE) * args.gain

    clipped = int(np.count_nonzero(np.abs(y) > 32767 / 32768))
    s16 = np.clip(np.round(y * 32768.0), -32768, 32767).astype("<i2")
    raw = s16.tobytes()
    raw += b"\x00" * ((-len(raw)) % SECTOR)     # 补零到整扇区

    with open(out, "wb") as f:
        f.write(raw)

    sectors = len(raw) // SECTOR
    print(f"输出: {out}")
    print(f"      {TARGET_RATE} Hz, 1 声道, 16 bit LE, {len(s16)} 样本, {len(s16) / TARGET_RATE:.2f} s")
    print(f"      峰值 {np.abs(s16).max()}，削波样本 {clipped}")
    print(f"      文件大小 {len(raw)} 字节 = {sectors} 扇区")
    print()
    print(f"顶层填写：WAV_TOTAL_SECTORS = 32'd{sectors};")
    print("WAV_START_LBA：拷到 TF 卡后用 WinHex 打开物理磁盘，")
    print("              在目录浏览里选中该文件，看“第一扇区”（物理扇区号，不是分区内相对号）")


if __name__ == "__main__":
    main()
