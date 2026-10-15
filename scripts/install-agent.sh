#!/usr/bin/env bash
# 安装 LaunchAgent：每次登录时自动重建聚合设备。
#
# 用法: ./install-agent.sh
# 卸载: ./uninstall-agent.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LABEL="com.virtualmic.aggdev"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. 确保二进制在
[ -x "$ROOT/build/aggdev" ] || ( cd "$ROOT" && make aggdev )

# 2. 生成 plist（写实际路径，不写死）
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HERE/agent_wrapper.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/VirtualMic-aggdev.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/VirtualMic-aggdev.log</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null || { echo "❌ plist 语法错误"; exit 1; }
echo "→ 已写入 $PLIST"

# 3. 加载
if launchctl load "$PLIST" 2>/dev/null; then
    echo "→ 已加载 LaunchAgent"
else
    echo "⚠️  launchctl load 未成功。请手动执行："
    echo "     launchctl load \"$PLIST\""
fi

# 4. 立刻跑一次
bash "$HERE/agent_wrapper.sh"
echo
echo "✅ 完成。日志: $HOME/Library/Logs/VirtualMic-aggdev.log"
