#!/bin/zsh
# 安装 / 查看 / 卸载 macOS 后台自动无线续签 LaunchAgent
# 用法：
#   scripts/install_auto_renew_agent.sh           # 安装并启用定时任务（并立即执行一次续签）
#   scripts/install_auto_renew_agent.sh --status  # 查看定时任务状态与最近日志
#   scripts/install_auto_renew_agent.sh --remove  # 卸载定时任务
set -euo pipefail

ROOT="${0:A:h:h}"
LABEL="com.yifanwang.assistant01.autorenew"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_PATH="$ROOT/build/auto_renew.log"
AUTO_SCRIPT="$ROOT/scripts/auto_renew.sh"

mkdir -p "$ROOT/build" "$PLIST_DIR"
chmod +x "$ROOT/scripts/reinstall.sh" "$AUTO_SCRIPT"

case "${1:-}" in
  --remove|--uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "🗑️ 已移除后台自动续签任务：$LABEL"
    exit 0
    ;;
  --status)
    echo "=== LaunchAgent 状态 ==="
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      echo "✅ 已启用 ($PLIST_PATH)"
    else
      echo "⚪ 未启用"
    fi
    if [[ -f "$ROOT/build/.last_renew_timestamp" ]]; then
      LAST_TS=$(cat "$ROOT/build/.last_renew_timestamp")
      echo "上次执行时间：$(date -r "$LAST_TS" '+%Y-%m-%d %H:%M:%S')"
    fi
    EXP_TS=0
    if [[ -f "$ROOT/build/Build/Products/Release-iphoneos/Assistant.app/embedded.mobileprovision" ]]; then
      EXP_TS=$(python3 -c "
import plistlib, sys
try:
    with open('$ROOT/build/Build/Products/Release-iphoneos/Assistant.app/embedded.mobileprovision', 'rb') as f:
        content = f.read()
    s = content.find(b'<?xml')
    e = content.find(b'</plist>') + 8
    if s != -1 and e != -1:
        data = plistlib.loads(content[s:e])
        print(int(data['ExpirationDate'].timestamp()))
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || echo 0)
    elif [[ -f "$ROOT/build/.profile_expiration_timestamp" ]]; then
      EXP_TS=$(cat "$ROOT/build/.profile_expiration_timestamp" 2>/dev/null || echo 0)
    fi
    if [[ "$EXP_TS" -gt 0 ]]; then
      NOW_TS=$(date +%s)
      REMAINING_HOURS=$(( (EXP_TS - NOW_TS) / 3600 ))
      echo "证书实际到期：$(date -r "$EXP_TS" '+%Y-%m-%d %H:%M:%S') (剩余约 ${REMAINING_HOURS} 小时)"
    fi
    echo "\n=== 最近日志 ($LOG_PATH) ==="
    tail -n 20 "$LOG_PATH" 2>/dev/null || echo "暂无日志"
    exit 0
    ;;
esac

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$AUTO_SCRIPT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$ROOT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>
    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "✅ 已安装并启动 macOS 自动无线续签服务 ($LABEL)"
echo "   • 检测频率：开机时 + 每 4 小时自动检测一次（满 3 天且 iPhone 在同一 Wi-Fi 下即自动无线续签）"
echo "   • 日志路径：$LOG_PATH"
