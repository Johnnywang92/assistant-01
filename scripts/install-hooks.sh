#!/usr/bin/env bash
# 启用仓库内的 Git hooks（把 core.hooksPath 指向 .githooks）。
#
# git config 不随仓库分发，所以每个 clone 首次需要跑一次：
#   ./scripts/install-hooks.sh
#
# 停用：git config --unset core.hooksPath
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

if [ ! -d "$ROOT/.git" ]; then
    echo "❌ 不是 git 工作树：$ROOT" >&2
    exit 1
fi

HOOK="$ROOT/.githooks/pre-push"
if [ ! -f "$HOOK" ]; then
    echo "❌ 找不到 .githooks/pre-push" >&2
    exit 1
fi
chmod +x "$HOOK"

# 若用户此前在 .git/hooks 里放了自己的 pre-push，不要静默屏蔽它。
if [ -e "$ROOT/.git/hooks/pre-push" ]; then
    echo "⚠️  检测到 .git/hooks/pre-push 已存在。设置 core.hooksPath=.githooks 后它将不再生效，" >&2
    echo "    请自行把其中需要的逻辑合并到 .githooks/pre-push。" >&2
fi

git config core.hooksPath .githooks

echo "✅ 已启用仓库内 hooks：core.hooksPath=$(git config --get core.hooksPath)"
echo "   生效 hooks："
for f in "$ROOT/.githooks"/*; do
    [ -f "$f" ] && echo "     - $(basename "$f")"
done
echo "   下次 git push 会自动跑 scripts/ci.sh test。"
echo "   停用：git config --unset core.hooksPath"
