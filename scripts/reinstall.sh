#!/bin/zsh
# 一键编译并安装到 iPhone（免费账号每 7 天运行一次续签）。
# 用法：scripts/reinstall.sh            # 编译 Release 并安装
#      scripts/reinstall.sh --generate # 只生成 Xcode 工程
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
xcodegen generate --quiet
[[ "${1:-}" == "--generate" ]] && { echo "已生成 Assistant.xcodeproj"; exit 0; }

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"
echo "▶ 编译中…"
xcodebuild \
  -project Assistant.xcodeproj \
  -scheme Assistant \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates \
  -quiet \
  build

APP="$BUILD_DIR/Build/Products/Release-iphoneos/Assistant.app"
echo "▶ 安装到设备 ${DEVICE_ID}…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
date +%s > "$BUILD_DIR/.last_renew_timestamp"
echo "✅ 安装完成，签名有效期至 $(date -v+7d '+%m月%d日 %H:%M')"

