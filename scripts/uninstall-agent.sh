#!/usr/bin/env bash
# 卸载 LaunchAgent（不删除聚合设备本身）
set -uo pipefail
LABEL="com.virtualmic.aggdev"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✅ 已卸载 $PLIST"
else
    echo "（未安装）"
fi
echo "   要删掉聚合设备本身: ./make_agg.sh --remove"
