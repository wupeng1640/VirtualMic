#!/usr/bin/env bash
# LaunchAgent 的执行体：确保聚合设备存在（幂等）。
#
# 聚合设备由 AudioHardwareCreateAggregateDevice 创建，不持久化，
# 重启后就没了。这个脚本被 LaunchAgent 在每次登录时调用，把它补回来。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/build/aggdev"
LOG="${VIRTUALMIC_LOG:-$HOME/Library/Logs/VirtualMic-aggdev.log}"

mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

if [ ! -x "$BIN" ]; then
    log "❌ 找不到 $BIN，先运行 make aggdev"
    exit 1
fi

if "$BIN" --list 2>/dev/null | grep -q "BH Aggregate"; then
    log "✅ 聚合设备已存在"
    exit 0
fi

"$BIN" --remove >/dev/null 2>&1 || true

if out=$("$BIN" --create "BH Aggregate" 2>&1); then
    log "✅ 已重建: $out"
else
    log "❌ 创建失败: $out"
    exit 1
fi
