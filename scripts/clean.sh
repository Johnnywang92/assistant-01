#!/usr/bin/env bash
# 清理仓库树内的 Xcode / SwiftPM 构建产物。
#
# 用法：
#   ./scripts/clean.sh             dry-run：只列出将清理的目录与体积，不删任何东西
#   ./scripts/clean.sh --yes       实际删除
#   ./scripts/clean.sh --help      显示帮助
#
# 安全边界（改动本脚本时不要放宽）：
#   - 只处理仓库根下固定白名单的三个目录，且必须与 .gitignore 保持一致；
#   - 逐个校验 realpath 未逃逸出仓库、不是符号链接、不是文件；
#   - 绝不触碰 .workbuddy/、源码、git 元数据、以及仓库外的任何个人目录；
#   - 默认 dry-run，必须显式传 --yes 才执行删除。
set -euo pipefail

# 用 pwd -P 取物理路径：ROOT 后面要和 `pwd -P` 解析出的目录做字符串比较，
# 若仓库位于符号链接下（例如 macOS 的 /tmp → /private/tmp），逻辑路径会误判成「逃逸」。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# 白名单：新增条目必须同时出现在 .gitignore 里，否则可能误删受版本控制的源码。
CLEAN_DIRS=(build DerivedData DerivedDataTests .build)

usage() {
    cat <<'EOF'
用法: ./scripts/clean.sh [--yes] [--help]

  默认 dry-run，只列出构建产物体积，不删除任何文件。
  --yes   实际删除白名单内的构建产物目录。
  --help  显示本帮助。

清理范围（仅限仓库根下）：build/、DerivedData/、DerivedDataTests/、.build/
不会触碰 .workbuddy/、源码、git 元数据或任何个人目录。
删除后首次 ./scripts/ci.sh all 会全量重编（数分钟）。
EOF
}

APPLY=0
if [ "$#" -gt 1 ]; then
    echo "❌ 参数过多" >&2
    usage >&2
    exit 2
fi
case "${1:-}" in
    "") ;;
    --yes | -y) APPLY=1 ;;
    --help | -h) usage; exit 0 ;;
    *) echo "❌ 未知参数: $1" >&2; usage >&2; exit 2 ;;
esac

# 必须在真正的仓库根执行，避免脚本被拷到别处后误删同名目录。
if [ ! -f "$ROOT/project.yml" ] || [ ! -d "$ROOT/.git" ]; then
    echo "❌ 无法确认仓库根（缺 project.yml 或 .git）：$ROOT" >&2
    exit 1
fi

human() {
    awk -v kb="$1" 'BEGIN { printf "%.2f GB", kb / 1024 / 1024 }'
}

declare -a paths=()
declare -a names=()
declare -a sizes=()
total_kb=0

for name in "${CLEAN_DIRS[@]}"; do
    path="$ROOT/$name"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        continue
    fi
    if [ -L "$path" ]; then
        echo "⚠️  跳过符号链接（不跟随）：$name" >&2
        continue
    fi
    if [ ! -d "$path" ]; then
        echo "⚠️  跳过非目录：$name" >&2
        continue
    fi
    resolved="$(cd "$path" && pwd -P)"
    if [[ "$resolved" != "$ROOT/"* ]]; then
        echo "❌ 路径逃逸出仓库，拒绝清理：$name → $resolved" >&2
        exit 1
    fi
    kb="$(du -sk "$path" | awk '{print $1}')"
    names+=("$name")
    paths+=("$path")
    sizes+=("$kb")
    total_kb=$((total_kb + kb))
done

if [ "$APPLY" -eq 0 ]; then
    printf '==> 构建产物清理（dry-run，未删除任何文件）\n\n'
else
    printf '==> 构建产物清理（--yes，即将删除）\n\n'
fi
printf '  %-16s %s\n' "目录" "体积"
printf '  %-16s %s\n' "----------------" "--------"
for i in "${!names[@]}"; do
    printf '  %-16s %s\n' "${names[$i]}/" "$(human "${sizes[$i]}")"
done
printf '  %-16s %s\n' "----------------" "--------"
printf '  %-16s %s\n\n' "合计" "$(human "$total_kb")"

if [ "${#paths[@]}" -eq 0 ]; then
    echo "没有需要清理的构建产物。"
    exit 0
fi

if [ "$APPLY" -eq 0 ]; then
    echo "⚠️  以上目录不可恢复（但都可重新生成）。确认后执行："
    echo "      ./scripts/clean.sh --yes"
    echo "   删除后首次 ./scripts/ci.sh all 需要全量重编。"
    exit 0
fi

echo "⚠️  即将删除上述 ${#paths[@]} 个目录；删除后首次全量构建需数分钟。"
for path in "${paths[@]}"; do
    rm -rf -- "$path"
    echo "   已删除 $path"
done
printf '✅ 已释放约 %s\n' "$(human "$total_kb")"
