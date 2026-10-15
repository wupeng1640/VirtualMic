# VirtualMic

> 把任意本地音频文件「播放」成你的麦克风 —— macOS。

[![Platform](https://img.shields.io/badge/platform-macOS%2010.13%2B-lightgrey)](#环境要求)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **中文说明**

VirtualMic 把本地音频文件送进一个虚拟音频设备，于是任何从这个设备读取的 App
—— 腾讯会议、Zoom、Teams、OBS、微信、浏览器、录音工具 —— 都会把你的文件当作
实时麦克风输入听到。

可以理解为 OBS 虚拟摄像头的音频版。

---

## 目录

- [它做什么](#它做什么)
- [工作原理](#工作原理)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [使用方法](#使用方法)
  - [图形界面](#图形界面)
  - [命令行](#命令行)
- [App 的麦克风列表里看不到虚拟设备](#app-的麦克风列表里看不到虚拟设备)
- [从源码构建](#从源码构建)
- [项目结构](#项目结构)
- [排错](#排错)
- [常见问题](#常见问题)
- [参与贡献](#参与贡献)
- [许可证](#许可证)
- [致谢](#致谢)

---

## 它做什么

- 解码本地音频文件（`mp3`、`m4a`、`aac`、`wav`、`aiff`、`flac` 等）
- 实时重采样到虚拟设备支持的采样率
- 写入环回设备的**输出侧**
- 任何 App 都可以把该设备选为**输入**（麦克风）来听

它**不会**改动你的物理麦克风 —— 原因见
[为什么不能直接写进内置麦克风](#为什么不能直接写进内置麦克风)。

## 工作原理

```
┌──────────────────┐
│   本地音频文件    │
└────────┬─────────┘
         │  VMAudioFilePlayer
         │  解码 → 目标采样率 / 2ch / Float32，拉取式
         ▼
┌──────────────────┐
│    VMRoute       │  CoreAudio HAL 输出 AudioUnit
└────────┬─────────┘
         │  kAudioOutputUnitProperty_CurrentDevice
         ▼
┌──────────────────────────────────────┐
│  环回设备（如 BlackHole 2ch）         │
│    Output 侧  ←── 我们写这里          │
│    Input  侧  ──→ App 从这里读        │
└──────────────────────────────────────┘
         ▲
         │  哪个 App 把它选成麦克风
    ┌────┴─────┐
    │ 微信 /   │
    │ OBS / …  │
    └──────────┘
```

不需要内核扩展，也不需要自己写驱动：macOS 已经有环回设备，本工具只是往其中一个写。
设计取舍见 [docs/architecture.md](docs/architecture.md)。

## 环境要求

- macOS 10.13 或更高
- 一个**环回音频设备**。macOS 系统不自带，需要自己装：
  - [BlackHole](https://github.com/ExistentialAudio/BlackHole) —— 推荐，免费开源。
    仓库里的 `scripts/install_blackhole.sh` 会帮你从源码编译安装。
  - 或 [Loopback](https://rogueamoeba.com/loopback/)（付费）、
    [Soundflower](https://github.com/mattingalls/Soundflower)（已停止维护）。
- 构建需要 Xcode 或 Xcode 命令行工具

> **要用 Xcode 的 SDK，不要用 CommandLineTools 的。** 后者可能报
> `tapi error: malformed file / unknown architecture`。
> `make` 通过 `xcrun --sdk macosx --show-sdk-path` 取 SDK，拿到的是 Xcode 那份。

## 快速开始

```bash
git clone https://github.com/wupeng1640/VirtualMic.git
cd VirtualMic
make

# 1. 安装环回设备（需要 sudo，会提示你输入密码）
./scripts/install_blackhole.sh

# 2. 确认能看到它
./build/vmic --loops
```

然后打开 `build/VirtualMic.app`，或用命令行推送：

```bash
./build/vmic --play ~/Music/voice.mp3 --device "BlackHole 2ch"
```

最后，在你要喂的那个 App（腾讯会议 / Zoom / OBS …）里，把麦克风选成
**BlackHole 2ch**。

## 使用方法

### 图形界面

```bash
make app
open build/VirtualMic.app
```

选虚拟设备、选文件、点开始。界面有电平表和进度条显示推送状态。

![VirtualMic 界面](docs/screenshot.png)

### 命令行

```
vmic --list                       列出所有音频设备
vmic --loops                      只列出可用的虚拟麦克风
vmic --play <文件> [选项]          开始推送
```

| 选项 | 含义 |
|---|---|
| `--device <名字\|UID>` | 写入哪个虚拟设备。默认自动选第一个环回设备。 |
| `--loop` | 循环播放 |
| `--gain <倍数>` | 音量倍数，默认 `1.0` |
| `--verify` | 同时从输入侧读回来，验证环回真的通了 |
| `--duration <秒>` | 播够 N 秒就退出，默认播完文件 |
| `--rate <Hz>` | 目标采样率，默认 `48000` |

```bash
# 循环把一首曲子送进 BlackHole
./build/vmic --play ~/Music/bgm.mp3 --device "BlackHole 2ch" --loop

# 验证信号真的到了（会打印从输入侧读到的电平）
./build/vmic --play ./voice.wav --device "BlackHole 2ch" --verify --duration 5
```

`--verify` 是诚实的检查方式：它打开设备的**输入侧**并报告读回的电平。
如果那个值一直是 0，说明声音根本没到设备 —— 无论发送计数显示多少。

### 无头自检

适合 CI 或 SSH 环境，不弹窗、不需要交互：

```bash
./build/VirtualMic.app/Contents/MacOS/VirtualMic --selftest <文件> [设备]
```

推送三秒并打印实测帧率。帧率与设备采样率误差在 5% 以内时退出码为 `0`。

## App 的麦克风列表里看不到虚拟设备

有些 App 枚举音频设备后，会**丢弃所有 `kAudioDevicePropertyTransportType`
为 `'virt'` 的设备**。BlackHole 正好就是这样，所以它在这些 App 的麦克风下拉里
根本不出现 —— 尽管 macOS 本身完全能正常识别它。

解法是把 BlackHole 包进一个**聚合设备**：聚合设备的 transportType 是 `'grup'`，
这些 App 会接受：

```bash
./scripts/make_agg.sh              # 创建 "BH Aggregate"
./scripts/make_agg.sh --remove     # 删除
./build/aggdev --list              # 列出所有设备及其 transportType
```

`aggdev --list` 会把可能被忽略的设备标出来，方便快速定位问题。

聚合设备重启后会消失。想让它每次登录自动重建：

```bash
./scripts/install-agent.sh
```

含日志证据的完整分析：[docs/aggregate-device.md](docs/aggregate-device.md)。

## 从源码构建

```bash
make            # 全部：.app、vmic、aggdev
make app        # 只构建图形界面
make cli        # 只构建命令行工具
make aggdev     # 只构建聚合设备工具
make clean
make install    # 把 vmic 和 aggdev 装到 /usr/local/bin
```

没有 Xcode 工程 —— 整个项目就是一个 `Makefile` 加约 2000 行 Objective-C，
依赖只有系统框架。

## 项目结构

```
.
├── Makefile                 构建入口
├── src/
│   ├── VMAudioDevice.{h,m}       CoreAudio 设备发现 / 按 UID 定位
│   ├── VMAudioFilePlayer.{h,m}   解码 + 实时拉取式取帧
│   ├── VMRoute.{h,m}             HAL 输出 AudioUnit，往设备里写
│   ├── VMAppDelegate.{h,m}       GUI 委托 + 无头自检
│   ├── VMMainWindowController.{h,m}  窗口、文件选择、电平表
│   └── main.m                    命令行入口
├── scripts/
│   ├── install_blackhole.sh  从源码编译并安装 BlackHole 2ch
│   ├── make_agg.sh           创建/删除聚合设备
│   ├── aggdev.m              聚合设备工具源码
│   ├── install-agent.sh      LaunchAgent：登录时自动重建
│   └── uninstall-agent.sh
├── packaging/Info.plist      app bundle 配置
└── docs/
    ├── architecture.md       设计与取舍
    ├── aggregate-device.md   transport-type 问题，含证据
    └── faq.md
```

## 排错

**`vmic --loops` 什么都不打印**
没装环回设备。跑 `./scripts/install_blackhole.sh`。

**声音推过去了，但对面听不到**
确认对方 App 读的是你写的**同一个**设备，且它的输入没被静音。
用 `--verify` 判断信号有没有真的到达设备。

**某个 `.mp3` 报 `ExtAudioFileOpenURL=<数字>`**
有些文件后缀是 `.mp3`，实际是 M4A/AAC 容器。播放器会自动回退到
`AVAssetReader`；如果两个解码器都拒绝，说明容器确实有问题 ——
目前**没有**第三级 `ffmpeg` 回退。先转一下：
`ffmpeg -i in.mp3 -ar 48000 out.wav`。

**听起来卡顿或爆音**
把 `--rate` 调成和设备一致，或降低 `--gain`。大文件是流式处理的，不是全量载入，
所以跟内存无关。

**重启后聚合设备不见了**
正常现象 —— 装 `./scripts/install-agent.sh`。

## 常见问题

**为什么不能直接写进内置麦克风？**

因为它是物理硬件。没有任何软件能往它里面注入采样；信号通路是单向的，
只能从麦克风流向系统。这是 macOS 的设计属性，不是可以授予的权限。
虚拟设备是唯一的路子，这个领域所有工具都是这么做的。

**需要装驱动吗？**

不需要装本项目写的驱动。你需要**某一个**环回设备，通常选 BlackHole。
从零写一个 HAL 插件意味着代码签名、公证、重启、关闭 SIP ——
付出的代价远超收益。

**Apple Silicon 能用吗？**

能。`scripts/install_blackhole.sh` 构建的是 universal 驱动（`arm64` + `x86_64`）。

**我的音频会被上传吗？**

不会。本项目没有任何一行代码开网络连接。文件在本地解码，写入本地音频设备。

## 参与贡献

欢迎提 issue 和 PR —— 见 [CONTRIBUTING.md](CONTRIBUTING.md)。
提 PR 前请先跑 `make && make test FILE=<某个音频文件>`。

## 许可证

[MIT](LICENSE)。

## 致谢

- [BlackHole](https://github.com/ExistentialAudio/BlackHole) —— 本工具驱动的环回
  驱动（GPL-3.0，独立作品，未随本仓库分发）
- Apple 的 CoreAudio / AudioToolbox 框架
