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
  "落库吞错闸门|python3 scripts/check_save_swallow.py"
  "图标按钮无障碍闸门|python3 scripts/check_icon_button_a11y.py"
  "沉浸式呈现闸门|python3 scripts/check_immersive_presentation.py"
  "通知排期闸门|python3 scripts/check_report_notification_scheduling.py"
  "首页筛选控件阴影闸门|python3 scripts/check_home_filter_shadow.py --self-test && python3 scripts/check_home_filter_shadow.py"
  "双指数档案接入闸门|python3 scripts/check_index_profile_wiring.py --self-test && python3 scripts/check_index_profile_wiring.py"
  "Xcode 源码收录闸门|python3 scripts/check_project_sources.py --self-test && python3 scripts/check_project_sources.py"
  "磁盘余量闸门|python3 scripts/check_disk_space.py"
  "AssistantCore 单元测试|cd Packages/AssistantCore && swift test"
  "心理视图类型检查|python3 scripts/typecheck-views.py Assistant/Features/PsychCombinedReadingCard.swift Assistant/Features/PsychTrendChartCard.swift Assistant/Features/MentalHealthView.swift Assistant/Features/PsychScaleResultView.swift Assistant/Features/PsychExportSheet.swift Assistant/Features/PsychScaleTestView.swift Assistant/Services/PsychReliefCopy.swift"
)
if [ "$MODE" = "all" ]; then
  STEPS+=(
    "Xcode 工程生成|xcodegen generate"
    # 生成后立刻复核：新增 Swift 文件若忘了收录，这里是最后一道拦截。
    "Xcode 源码收录复核|python3 scripts/check_project_sources.py --strict"
    # COMPILER_INDEX_STORE_ENABLE=NO / INDEX_ENABLE_DATA_STORE=NO：
    # 索引存储会往 DerivedData/Index.noindex 写上千个分片目录（实测 1190+397 个），
    # 在磁盘吃紧时它的失败方式极具误导性——表现为随机挂在不相干源文件上的
    # 「failed to create directory .../records/XX」编译错误。
    # CI 只需要编译器产出，不需要 IDE 索引，关掉能省下数 GB 磁盘并根除这类假故障。
    "iOS 构建|xcodebuild -project Assistant.xcodeproj -scheme Assistant -destination 'generic/platform=iOS' -derivedDataPath DerivedData COMPILER_INDEX_STORE_ENABLE=NO INDEX_ENABLE_DATA_STORE=NO build CODE_SIGNING_ALLOWED=NO"
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
    # 关键：`swift-plugin-server`（跑 SwiftData `@Model` / `@Query` 宏的进程）
    # 本身就是用 `sandbox-exec` 启动的，所以这类宿主上**任何含 SwiftData 宏的
    # target 都编译不了**，报错形态是「external macro implementation type
    # 'SwiftDataMacros.PersistentModelMacro' could not be found」，很容易被误读成代码问题。
    #
    # `swift test` 有 `--disable-sandbox` 可回退；
    # `xcodebuild` 没有对应开关，但**可以先诊断**再决定是不是环境问题，
    # 免得把环境故障误读成代码故障、浪费时间排查。
    if bash -c "cd '${ROOT}' && ${cmd}" 2>&1 | grep -q "sandbox_apply: Operation not permitted"; then
      echo "    ⚠️  宿主环境的 sandbox-exec 不可用（不是代码错误）："
      echo "       自检: /usr/bin/sandbox-exec -p '(version 1)(allow default)' /bin/echo test"
      if [[ "$cmd" == *"swift test"* ]]; then
        echo "    (SwiftPM：改用 --disable-sandbox 重试)"
        if bash -c "cd '${ROOT}' && ${cmd} --disable-sandbox"; then
          echo "==> [ci] ${name} 通过（--disable-sandbox 回退）"
          continue
        fi
      else
        echo "       xcodebuild 无 --disable-sandbox 等价开关。"
        echo "       受影响的两处："
        echo "         ① SwiftPM 包解析（本地 path 包也要加载 Package.swift manifest）"
        echo "         ② SwiftData 宏插件（swift-plugin-server 由 sandbox-exec 启动）"
        echo "       → 本宿主上任何含 @Model / @Query 的 target 都编译不了，与代码无关。"
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
