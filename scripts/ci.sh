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
  "备份口令字面量闸门|python3 scripts/check_backup_pin_literals.py"
  "AssistantCore 单元测试|cd Packages/AssistantCore && swift test"
  "心理视图类型检查|python3 scripts/typecheck-views.py Assistant/Features/PsychCombinedReadingCard.swift Assistant/Features/PsychTrendChartCard.swift Assistant/Features/MentalHealthView.swift Assistant/Features/PsychScaleResultView.swift Assistant/Features/PsychExportSheet.swift Assistant/Features/PsychScaleTestView.swift Assistant/Services/PsychReliefCopy.swift"
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
    # 宿主环境的 `sandbox-exec` 不可用时（容器 / 受限沙箱 / 嵌套执行），
    # SwiftPM 的 manifest 编译与 Swift 宏插件都会报
    # `sandbox_apply: Operation not permitted`——**这不是代码错误**。
    #
    # `swift test` 有 `--disable-sandbox` 可回退；
    # `xcodebuild` 没有对应开关，但**可以先诊断**再决定是不是环境问题，
    # 免得把环境故障误读成代码故障、浪费时间排查。
    if bash -c "cd '${ROOT}' && ${cmd}" 2>&1 | grep -q "sandbox_apply: Operation not permitted"; then
      echo "    ⚠️  宿主环境的 sandbox-exec 不可用（不是代码错误）："
      echo "       /usr/bin/sandbox-exec -p '(version 1)(allow default)' /bin/echo test"
      if [[ "$cmd" == *"swift test"* ]]; then
        echo "    (SwiftPM：改用 --disable-sandbox 重试)"
        if bash -c "cd '${ROOT}' && ${cmd} --disable-sandbox"; then
          echo "==> [ci] ${name} 通过（--disable-sandbox 回退）"
          continue
        fi
      else
        echo "       xcodebuild 无 --disable-sandbox 等价开关，"
        echo "       本步骤需要宿主放开 sandbox-exec 后重跑。"
        echo "       （Core 层单测可用：./scripts/ci.sh test）"
      fi
    fi
    echo "❌ [ci] 步骤失败: ${name}" >&2
    echo "   命令: ${cmd}" >&2
    echo "   工作目录: ${ROOT}" >&2
    exit 1
  fi
  echo "==> [ci] ${name} 通过"
done

echo "✅ [ci] 全部步骤通过 (${MODE})"
