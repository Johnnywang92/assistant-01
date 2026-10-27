#!/bin/zsh
# 一键编译并安装到 iPhone（免费账号每 7 天运行一次续签）。
# 用法：scripts/reinstall.sh                  # 编译 Release 并安装
#      scripts/reinstall.sh --install-only   # 跳过编译，直接将已生成的 App 安装到设备
#      scripts/reinstall.sh --clean-profile  # 清除旧描述文件缓存并续签
#      scripts/reinstall.sh --generate       # 只生成 Xcode 工程
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIG="$ROOT/scripts/config.local"
if [[ ! -f "$CONFIG" ]]; then
  echo "缺少 scripts/config.local，请先复制 scripts/config.example 并填写。" >&2
  exit 1
fi
source "$CONFIG"
export DEVELOPMENT_TEAM BUNDLE_ID

command -v xcodegen >/dev/null || { echo "请先安装 xcodegen：brew install xcodegen" >&2; exit 1; }

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/Build/Products/Release-iphoneos/Assistant.app"

INSTALL_ONLY=0
if [[ "${1:-}" == "--install-only" || "${1:-}" == "-i" ]]; then
  INSTALL_ONLY=1
fi

if [[ "$INSTALL_ONLY" -eq 0 ]]; then
  xcodegen generate --quiet
  [[ "${1:-}" == "--generate" ]] && { echo "已生成 Assistant.xcodeproj"; exit 0; }

  # 若指定 --clean-profile，清理 Xcode 本地缓存的该 bundle ID 描述文件，强制向苹果申请最新 7 天 profile
  if [[ "${1:-}" == "--clean-profile" ]]; then
    echo "▶ 清理 Xcode 描述文件缓存以确保生成最新 7 天证书…"
    for pdir in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
      if [[ -d "$pdir" ]]; then
        find "$pdir" -name "*.mobileprovision" 2>/dev/null | while read -r p; do
          if grep -q "$BUNDLE_ID" "$p" 2>/dev/null; then
            rm -f "$p"
          fi
        done
      fi
    done
  fi

  echo "▶ 编译与签名中（首次约 1~2 分钟）…"
  xcodebuild \
    -project Assistant.xcodeproj \
    -scheme Assistant \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    -quiet \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    BUNDLE_ID="$BUNDLE_ID" \
    build
fi

if [[ ! -d "$APP" ]]; then
  echo "❌ 未找到编译产物 $APP，请先执行完整编译：scripts/reinstall.sh" >&2
  exit 1
fi

echo "▶ 检查设备连接状态…"
DEVICE_CONNECTED=0
for i in {1..10}; do
  DEVICE_LINE=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" || true)
  if echo "$DEVICE_LINE" | grep -Eq "connected|available \(paired\)"; then
    DEVICE_CONNECTED=1
    break
  fi
  if [[ "$i" -eq 1 ]]; then
    echo "⚠️ 手机当前处于休眠或锁屏状态，请点亮并解锁 iPhone 屏幕…"
  fi
  sleep 1.5
done

if [[ "$DEVICE_CONNECTED" -eq 0 ]]; then
  echo "❌ 设备 ${DEVICE_ID} 未处于在线解锁状态。请点亮解锁 iPhone，或插上 USB 数据线重试。" >&2
  exit 1
fi

echo "▶ 安装到设备 ${DEVICE_ID}…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

# 解析实际签名过期时间
EXPIRY_TS=$(python3 -c "
import plistlib, sys
try:
    with open('$APP/embedded.mobileprovision', 'rb') as f:
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

date +%s > "$BUILD_DIR/.last_renew_timestamp"
if [[ "$EXPIRY_TS" -gt 0 ]]; then
  echo "$EXPIRY_TS" > "$BUILD_DIR/.profile_expiration_timestamp"
  EXPIRY_STR=$(date -r "$EXPIRY_TS" '+%m月%d日 %H:%M')
  echo "✅ 安装完成，签名实际有效期至 $EXPIRY_STR"
else
  echo "✅ 安装完成"
fi

