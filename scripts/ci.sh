#!/usr/bin/env bash
# 本地/CI 通用质量闸门：单元测试 → 工程生成 → iOS 构建，任一步失败即非零退出并指明失败步骤。
# 用法：
#   ./scripts/ci.sh          跑全部三步
#   ./scripts/ci.sh test     只跑 AssistantCore 单元测试（swift test）
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-all}"

# 「步骤名|命令」列表；管道数组避免 eval 引号问题之外的意外展开。
STEPS=(
  "偏好键覆盖闸门|python3 scripts/check_settings_keys.py"
  "圆角令牌闸门|python3 scripts/check_radius_tokens.py"
  "AssistantCore 单元测试|cd Packages/AssistantCore && swift test"
)
if [ "$MODE" = "all" ]; then
  STEPS+=(
    "Xcode 工程生成|xcodegen generate"
    "iOS 构建|xcodebuild -project Assistant.xcodeproj -scheme Assistant -destination 'generic/platform=iOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO"
  )
elif [ "$MODE" != "test" ]; then
  echo "用法: $0 [all|test]" >&2
  exit 2
fi

for entry in "${STEPS[@]}"; do
  name="${entry%%|*}"
  cmd="${entry#*|}"
  echo "==> [ci] ${name}"
  echo "    \$ ${cmd}"
  if ! bash -c "cd '${ROOT}' && ${cmd}"; then
    echo "❌ [ci] 步骤失败: ${name}" >&2
    echo "   命令: ${cmd}" >&2
    echo "   工作目录: ${ROOT}" >&2
    exit 1
  fi
  echo "==> [ci] ${name} 通过"
done

echo "✅ [ci] 全部步骤通过 (${MODE})"
