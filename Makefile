# VirtualMic —— 构建入口
#
#   make           构建 .app 和 CLI（默认）
#   make app       只构建 VirtualMic.app
#   make cli       只构建 vmic 命令行工具
#   make aggdev    只构建聚合设备工具
#   make test      跑无头自检（需要一个音频文件）
#   make clean     清理构建产物
#   make install   装到 /usr/local/bin（CLI + aggdev）

SHELL   := /bin/bash
SDK     := $(shell xcrun --sdk macosx --show-sdk-path)
BUILD   := build
APP     := $(BUILD)/VirtualMic.app

# 最低支持的 macOS 版本
MIN_OS  := 10.13

# 目标架构。universal 让 Intel 和 Apple Silicon 都能跑；
# 本地开发想快可以 make ARCHS=arm64
ARCHS   ?= arm64 x86_64
ARCHFLAGS := $(foreach a,$(ARCHS),-arch $(a))

CFLAGS  := -fobjc-arc -isysroot $(SDK) -mmacosx-version-min=$(MIN_OS) \
           -Wall -Wno-deprecated-declarations -I src

# GUI：Cocoa + 音频框架；AVFoundation/CoreMedia 是给「假 mp3 真 m4a」的
# 回退解码器用的
GUI_FW  := -framework Cocoa -framework Foundation -framework CoreAudio \
           -framework AudioToolbox -framework Accelerate \
           -framework AVFoundation -framework CoreMedia -framework CoreVideo

# CLI 不需要 Cocoa
CLI_FW  := -framework Foundation -framework CoreAudio \
           -framework AudioToolbox -framework Accelerate \
           -framework AVFoundation -framework CoreMedia -framework CoreVideo

GUI_SRC := src/VMAppDelegate.m src/VMMainWindowController.m \
           src/VMAudioDevice.m src/VMAudioFilePlayer.m src/VMRoute.m
CLI_SRC := src/main.m src/VMAudioDevice.m src/VMAudioFilePlayer.m src/VMRoute.m

.PHONY: all app cli aggdev clean test install

all: app cli aggdev

app: $(APP)

$(APP): $(GUI_SRC) src/*.h packaging/Info.plist
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@echo "→ 编译 VirtualMic.app ..."
	@clang $(CFLAGS) $(ARCHFLAGS) $(GUI_FW) -o "$(APP)/Contents/MacOS/VirtualMic" $(GUI_SRC)
	@cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	@echo "→ 签名（adhoc，无证书时的唯一选择）"
	@codesign --force --deep --sign - "$(APP)" 2>/dev/null || \
		echo "⚠️  签名跳过（下载分发会被 Gatekeeper 拦截，见 docs/distribution.md）"
	@echo "✅ $(APP)"

cli: $(BUILD)/vmic

$(BUILD)/vmic: $(CLI_SRC) src/*.h
	@mkdir -p $(BUILD)
	@echo "→ 编译 vmic ..."
	@clang $(CFLAGS) $(ARCHFLAGS) $(CLI_FW) -o $@ $(CLI_SRC)
	@echo "✅ $@"

aggdev: $(BUILD)/aggdev

$(BUILD)/aggdev: scripts/aggdev.m
	@mkdir -p $(BUILD)
	@echo "→ 编译 aggdev ..."
	@clang $(CFLAGS) $(ARCHFLAGS) -framework Foundation -framework CoreAudio -o $@ $<
	@echo "✅ $@"

# 无头自检：不会弹窗，适合 CI
#   make test FILE=~/Music/test.mp3 DEVICE="BlackHole 2ch"
test: cli
	@if [ -z "$(FILE)" ]; then echo "用法: make test FILE=<音频文件> [DEVICE=<设备名>]"; exit 2; fi
	@$(BUILD)/vmic --play "$(FILE)" --device "$(DEVICE)" --duration 3 --verify

install: cli aggdev
	@echo "→ 安装到 /usr/local/bin（可能需要 sudo）"
	install -m 755 $(BUILD)/vmic    /usr/local/bin/vmic
	install -m 755 $(BUILD)/aggdev  /usr/local/bin/aggdev
	@echo "✅ 完成"

clean:
	@rm -rf $(BUILD)
	@echo "✅ 已清理"
