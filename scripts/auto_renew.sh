#!/bin/zsh
# 后台自动检测并无线重签安装到 iPhone
# 用法：scripts/auto_renew.sh          # 距上次重签满 3 天且设备在同一 Wi-Fi/USB 下时自动续签
#      scripts/auto_renew.sh --force  # 立即执行无线编译并重签安装
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIG="$ROOT/scripts/config.local"
if [[ ! -f "$CONFIG" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 缺少 scripts/config.local，跳过自动续签。" >&2
  exit 1
fi
source "$CONFIG"

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/Build/Products/Release-iphoneos/Assistant.app"
PROVISION_FILE="$APP/embedded.mobileprovision"
EXPIRY_FILE="$BUILD_DIR/.profile_expiration_timestamp"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

# 获取当前 App 描述文件（Provisioning Profile）的实际到期时间戳
get_profile_expiry() {
  if [[ -f "$PROVISION_FILE" ]]; then
    python3 -c "
import plistlib, sys
try:
    with open('$PROVISION_FILE', 'rb') as f:
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
" 2>/dev/null && return 0
  fi
  if [[ -f "$EXPIRY_FILE" ]]; then
    cat "$EXPIRY_FILE"
    return 0
  fi
  echo 0
}

EXPIRY_TS=$(get_profile_expiry)
NOW_TS=$(date +%s)
REMAINING_SECONDS=$((EXPIRY_TS - NOW_TS))

# 缓冲阈值：剩余不足 48 小时（2天）时自动触发续签；若已过期或无记录，立即触发
RENEW_THRESHOLD_SECONDS=$((48 * 3600))

if [[ "$FORCE" -eq 0 && "$REMAINING_SECONDS" -gt "$RENEW_THRESHOLD_SECONDS" ]]; then
  REMAINING_HOURS=$((REMAINING_SECONDS / 3600))
  EXPIRY_STR=$(date -r "$EXPIRY_TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 证书仍在有效期内（剩余约 ${REMAINING_HOURS} 小时，到期时间：${EXPIRY_STR}），暂无需续签。"
  exit 0
fi

# 检查目标 iPhone 是否在同局域网 Wi-Fi 或 USB 下可达
DEVICE_LINE=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" || true)
if [[ -z "$DEVICE_LINE" ]] || ! echo "$DEVICE_LINE" | grep -Eq "connected|available \(paired\)"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 设备 ${DEVICE_ID} 当前未连接或不在同一 Wi-Fi 下，稍后重试。"
  exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到 iPhone 在线且证书即将到期/强制重签，开始无线重签安装…"
"$ROOT/scripts/reinstall.sh" --clean-profile

osascript -e 'display notification "已通过 Wi-Fi 自动为 iPhone 续签「小助」（有效期 7 天）" with title "小助自动续签完成"' >/dev/null 2>&1 || true
