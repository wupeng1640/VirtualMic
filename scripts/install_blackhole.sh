#!/usr/bin/env bash
# 编译并安装 BlackHole 2ch 虚拟声卡。
#
# 为什么需要它：macOS 没有内置的环回（loopback）音频设备。
# 内置麦克风是物理硬件，任何软件都无法往里写数据 —— 这是系统设计，不是权限问题。
# 要让别的 App 从「麦克风」列表里选到我们的虚拟麦克风，
# 就必须先有一个真正的环回设备：往它的 Output 写，从它的 Input 读。
#
# 为什么从源码编译而不是装官方 pkg：
#   官方下载页被 Cloudflare 拦截，release 页只有源码。而这个项目本身就是单文件 C，
#   编译只需要一条 clang 命令。
#
# 用法: ./install_blackhole.sh
set -euo pipefail

BLACKHOLE_VERSION="0.7.1"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 需要 root 才能写 /Library/Audio/Plug-Ins/HAL
if [ "$(id -u)" -ne 0 ]; then
    echo "→ 需要管理员权限，正在重新以 sudo 运行..."
    exec sudo "$0" "$@"
fi

echo "→ 下载 BlackHole ${BLACKHOLE_VERSION} 源码"
curl -fsSL -o "$WORK/bh.tar.gz" \
    "https://github.com/ExistentialAudio/BlackHole/archive/refs/tags/v${BLACKHOLE_VERSION}.tar.gz"
tar xzf "$WORK/bh.tar.gz" -C "$WORK"

SRC="$WORK/BlackHole-${BLACKHOLE_VERSION}/BlackHole/BlackHole.c"
[ -f "$SRC" ] || { echo "❌ 没找到源码 $SRC"; exit 1; }

echo "→ 编译（universal: arm64 + x86_64）"
DRIVER="$WORK/BlackHole2ch.driver"
mkdir -p "$DRIVER/Contents/MacOS"

# 用 Xcode 的 SDK；CommandLineTools 的 CoreAudio.tbd 可能报
# "tapi error: malformed file / unknown architecture"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
clang -bundle -fPIC -arch arm64 -arch x86_64 \
    -isysroot "$SDK" -mmacosx-version-min=10.10 \
    -framework CoreAudio -framework CoreFoundation \
    -framework IOKit -framework Accelerate \
    -o "$DRIVER/Contents/MacOS/BlackHole" "$SRC"

echo "→ 写 Info.plist"
cat > "$DRIVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>English</string>
    <key>CFBundleExecutable</key><string>BlackHole</string>
    <key>CFBundleIdentifier</key><string>audio.existential.BlackHole2ch</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>BlackHole</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>0.7.1</string>
    <key>CFBundleVersion</key><string>0.7.1</string>
    <key>CFPlugInFactories</key>
    <dict>
        <key>e395c745-4eea-4d94-bb92-46224221047c</key>
        <string>BlackHole_Create</string>
    </dict>
    <key>CFPlugInTypes</key>
    <dict>
        <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
        <array><string>e395c745-4eea-4d94-bb92-46224221047c</string></array>
    </dict>
    <key>LSMinimumSystemVersion</key><string>10.10</string>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0 (Existential Audio Inc.)</string>
</dict>
</plist>
PLIST

DEST="/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
echo "→ 安装到 $DEST"
rm -rf "$DEST"
cp -R "$DRIVER" "$DEST"
chown -R root:wheel "$DEST"
chmod -R 755 "$DEST"

echo "→ 重启 coreaudiod 让驱动加载"
killall coreaudiod 2>/dev/null || true
sleep 2

echo
echo "✅ BlackHole 2ch 已安装。验证："
echo "     cd \"$HERE/..\" && make cli && ./build/vmic --loops"
