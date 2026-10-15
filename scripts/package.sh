#!/usr/bin/env bash
# 打发布包：universal .app + CLI 工具，各打一个 zip。
#
# 用法：
#   ./scripts/package.sh           用 Info.plist 里的版本号
#   ./scripts/package.sh 1.0.1     指定版本号
#
# 产物在 dist/ 下，可直接拖到 GitHub Release。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)}"
DIST="$ROOT/dist"

echo "→ 全量构建（universal）"
make clean >/dev/null
make all

echo "→ 校验架构"
for b in build/VirtualMic.app/Contents/MacOS/VirtualMic build/vmic build/aggdev; do
    archs=$(lipo -info "$b" | sed 's/.*are: //')
    echo "   $b: $archs"
done

echo "→ 打包"
rm -rf "$DIST"
mkdir -p "$DIST"

APP_ZIP="$DIST/VirtualMic-${VERSION}-macos.zip"
CLI_ZIP="$DIST/VirtualMic-${VERSION}-cli-macos.zip"

# ditto 保留符号链接和权限，比 zip 更适合 .app
ditto -c -k --sequesterRsrc --keepParent build/VirtualMic.app "$APP_ZIP"

# CLI 单独一个包，附上 README 片段
CLI_STAGE="$(mktemp -d)"
cp build/vmic build/aggdev "$CLI_STAGE/"
cp scripts/install_blackhole.sh scripts/make_agg.sh "$CLI_STAGE/"
( cd "$CLI_STAGE" && zip -q "$CLI_ZIP" vmic aggdev install_blackhole.sh make_agg.sh )
rm -rf "$CLI_STAGE"

echo "→ 生成校验和"
( cd "$DIST" && shasum -a 256 ./*.zip > SHA256SUMS.txt )

echo
echo "✅ 产物："
ls -lh "$DIST"
echo
echo "⚠️  未签名/未公证。用户首次打开需「右键 → 打开」或"
echo "    xattr -dr com.apple.quarantine。详见 docs/distribution.md"
