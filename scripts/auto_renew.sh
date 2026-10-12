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
STAMP_FILE="$BUILD_DIR/.last_renew_timestamp"
RENEW_INTERVAL_SECONDS=$((3 * 86400)) # 每满 3 天自动续签一次（免费证书有效期 7 天）

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if [[ "$FORCE" -eq 0 && -f "$STAMP_FILE" ]]; then
  LAST_TS=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  ELAPSED=$((NOW_TS - LAST_TS))
  if (( ELAPSED < RENEW_INTERVAL_SECONDS )); then
    REMAINING_HOURS=$(( (RENEW_INTERVAL_SECONDS - ELAPSED) / 3600 ))
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 距离下次自动续签还有约 ${REMAINING_HOURS} 小时，跳过。"
    exit 0
  fi
fi

# 检查目标 iPhone 是否在同局域网 Wi-Fi 或 USB 下可达
DEVICE_LINE=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" || true)
if [[ -z "$DEVICE_LINE" ]] || ! echo "$DEVICE_LINE" | grep -Eq "connected|available \(paired\)"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 设备 ${DEVICE_ID} 当前未连接或不在同一 Wi-Fi 下，稍后重试。"
  exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到 iPhone 在线，开始无线重签安装…"
"$ROOT/scripts/reinstall.sh"

osascript -e 'display notification "已通过 Wi-Fi 自动为 iPhone 续签「小助」（有效期 7 天）" with title "小助自动续签完成"' >/dev/null 2>&1 || true
