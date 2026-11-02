# lab_ex4_tf — 基于安路 FPGA 的 TF 卡 BMP 轮播 + HDMI 1.4b 显示

本工程为 **APUG092_HDMI1.4b_Transmitter_V1.4** 的纯视频播放版本，专注于 TF 卡读取、HDMI 视频输出及可靠性提升。

- 详细功能说明：[代码说明.md](代码说明.md)
- 完整设计参考例程：[设计参考例程文档.md](设计参考例程文档.md) / [设计参考例程文档.docx](设计参考例程文档.docx)

## 功能特性

| 功能 | 说明 |
| --- | --- |
| BMP 播放 | 从 TF 卡读取 640×480 / 24-bit 非压缩 BMP |
| 多图轮播 | 最多 4 张图片自动扫描加载，SDRAM 双缓冲无缝切换 |
| 显示输出 | 通过开发板 `HDMI_B` 接口输出 |
| 按键控制 | key1 手动切换下一张；key2 开/关自动轮播 |
| 上电防抖 | PLL 全部锁定稳定后才启动，避免上电花屏/死机 |
| 防死锁 | 图片损坏/截断/分辨率非标时，状态机 1 秒超时强制恢复 |

## 硬件平台

```text
FPGA      : 安路 EG4S20BG256
开发板    : APUG092（安路 EG4 系列）
接口      : HDMI_B → HDMI 线 → 显示器
存储      : TF 卡（FAT32）
```

## 目录结构

```text
lab_ex4_tf/
├── src/
│   ├── user_source/
│   │   ├── hdl_source/          # 全部 RTL 源码（顶层 / SD / HDMI / AUDIO / DISPLAY / IP）
│   │   ├── constraints_source/  # 引脚约束 pin.adc、时序约束 timing.sdc、edid_debug.cwc
│   │   └── ip_source/           # IP 配置
│   ├── td_project/              # 安路 TD 工程
│   │   ├── lab_ex5_i2s_v1.0.al  # ★ 工程入口文件
│   │   ├── al_ip/               # PLL 等 IP 生成文件
│   │   └── bit_archive/         # 已验证的 bit 流归档
│   └── sim/                     # 各模块 Modelsim 仿真工程与 testbench
├── doc/
│   ├── TF卡图片/                # 可直接拷入 TF 卡的示例 BMP
│   └── convert/                 # Python 辅助脚本（图片转换 / SD 卡同步 / WAV 转 PCM）
├── 代码说明.md
└── 设计参考例程文档.md / .docx
```

## 快速开始

1. 用 **安路 TD** 直接打开 `src/td_project/lab_ex5_i2s_v1.0.al`；
2. 综合 → 布局布线 → 下载到 FPGA；
3. 将 `doc/TF卡图片/` 下的 BMP 拷入 TF 卡（推荐用 `doc/convert/sync_to_sd.py` 同步，可避免旧扇区数据残留导致读图失败）；
4. TF 卡插入开发板，HDMI 线接 `HDMI_B`，上电即可看到图片轮播。

### TF 卡图片格式要求

```text
格式    : BMP（真正的 BMP，不能把 PNG/JPG 改后缀）
分辨率  : 640 × 480
色深    : 24-bit RGB
压缩    : 非压缩
文件系统: FAT32
```

批量转换：`python doc/convert/convert_images_to_bmp.py`

## 关于仓库内容

为控制仓库体积，以下内容**不入库**（`.gitignore` 已配置），均可由源码重新生成：

- TD 编译产物：`*_Runs/`、`log/`、`out/`（.db/.rpt/.timing 等，约 150 MB）
- 仿真工作区：`work*/`、`*.qpg`、`*.qtl`、`*.qdb`（约 70 MB）
- IDE 缓存：`.dide/`
- 原始音频素材：`doc/*.PCM`（约 95 MB，可用 `doc/convert/wav_to_pcm.py` 从 WAV 重新生成）
- 图片转换中间产物：`doc/convert/output_bmp/`（约 21 MB）

> 若确需把上述大文件纳入版本管理（单文件 > 25 MB 已超出 GitHub 普通上传限制），请使用 Git LFS：
>
> ```bash
> git lfs install
> git lfs track "*.PCM" "*.bit" "*.BMP"
> git add .gitattributes
> ```
