#!/usr/bin/env bash
# 创建一个把 BlackHole 2ch 包进去的聚合音频设备。
#
# ── 为什么需要这个 ────────────────────────────────────────────────
#
# 某些 App（典型例子是网易云信的 JRTC SDK，见 docs/aggregate-device.md）
# 枚举 macOS 音频设备时会读 kAudioDevicePropertyTransportType，
# 然后把 transportType == 'virt' 的设备全部丢掉：
#
#     BlackHole 2ch   'virt'  → 丢弃，不出现在麦克风下拉里
#     Cast Audio      'virt'  → 丢弃
#     NeCastAudio B   'virt'  → 丢弃
#     内置麦克风       'bltn'  → 保留
#     聚合设备         'grup'  → 保留   ← 我们要的就是这个
#
# 所以把 BlackHole 作为子设备包进一个聚合设备，就得到一个
# 既真的能环回、又能被那些 App 列出来的设备。
#
# ── 用法 ──────────────────────────────────────────────────────────
#
#   ./make_agg.sh                  用默认名字 "BH Aggregate" 创建
#   ./make_agg.sh "我的虚拟麦"      自定义名字
#   ./make_agg.sh --remove         删除
#
# 聚合设备不持久化（重启后消失）。想开机自动重建见
# scripts/install-agent.sh。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/build/aggdev"

if [ ! -x "$BIN" ]; then
    echo "→ aggdev 还没编译，先跑 make aggdev"
    ( cd "$ROOT" && make aggdev )
fi

if [ "${1:-}" = "--remove" ]; then
    "$BIN" --remove && echo "✅ 已删除聚合设备"
    exit 0
fi

NAME="${1:-BH Aggregate}"
"$BIN" --create "$NAME"
echo
"$BIN" --list
