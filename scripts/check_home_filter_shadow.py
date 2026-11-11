#!/usr/bin/env python3
"""首页筛选控件禁黑色阴影闸门。

为什么要有这道闸：
`AppTheme.wallpaperReadableText()` 在自定义壁纸下会给**整栏**叠一层
`shadow(color: .black.opacity(0.55), radius: 2, y: 1)`。它原本是给裸文字
做对比度兜底的，但挂在分类栏 / 标签栏 / 时间聚合条这类**胶囊控件**上时，
投影会绕着胶囊描一圈黑边，看起来像控件脏了；浅色壁纸上尤其明显。

胶囊自带底色，对比度应该由**不透明的语义底色**保证，而不是黑色投影。
`TodoListView` 里三处筛选控件的 `.background` 已经按这个口径实现。

判定（剥除注释后）：
1. `TodoListView.swift` 内不得出现任何 `.wallpaperReadableText()` 调用。
2. `filterTabBar` / `tagFilterBar` / `timeAggregationBar` 三个视图定义体内
   不得出现 `.shadow(`（任何颜色都不行：胶囊不需要投影）。
3. `homeHeaderSection` 装配区不得给这三个控件挂黑色投影。

规则对用户可见效果的约束是「分类标签不要黑色阴影」；这里把范围略放宽到
整个首页筛选控件组，是为了避免只修一处、下次在相邻控件复发。

用法：
    python3 scripts/check_home_filter_shadow.py            # 校验，失败非零退出
    python3 scripts/check_home_filter_shadow.py --self-test # 变异自测，验证闸门真的会拦
"""
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "Assistant" / "Features" / "TodoListView.swift"

FORBIDDEN_MODIFIER = re.compile(r"\.wallpaperReadableText\s*\(")
SHADOW = re.compile(r"\.shadow\s*\(")
BLACK_SHADOW = re.compile(r"\.shadow\s*\([^)]*\.black", re.S)

FILTER_BARS = ("filterTabBar", "tagFilterBar", "timeAggregationBar")
BAR_DECL = re.compile(r"private\s+var\s+(" + "|".join(FILTER_BARS) + r")\s*:\s*some\s+View\s*\{")


def strip_comments(text: str) -> str:
    """剥掉 // 与 /* */ 注释，保留字符串字面量，避免注释里的示例自证其罪。"""
    out, i, n = [], 0, len(text)
    in_str = in_line = in_block = False
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            else:
                out.append(" ")
            i += 1
            continue
        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            out.append("  ")
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block = True
            out.append("  ")
            i += 2
            continue
        if c == '"':
            in_str = True
        out.append(c)
        i += 1
    return "".join(out)


def brace_block(text: str, start: int) -> str:
    """从第一个 `{` 起做花括号配平，取出视图定义体。"""
    begin = text.find("{", start)
    if begin < 0:
        return ""
    depth, i, n = 0, begin, len(text)
    while i < n:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[begin:i + 1]
        i += 1
    return text[begin:]


def check(source: str):
    """返回违规说明列表。"""
    clean = strip_comments(source)
    violations = []

    for m in FORBIDDEN_MODIFIER.finditer(clean):
        line = clean.count("\n", 0, m.start()) + 1
        violations.append(
            f":{line} 分类/筛选控件挂了 .wallpaperReadableText()（黑色投影），"
            "请改用不透明语义底色"
        )

    for m in BAR_DECL.finditer(clean):
        name = m.group(1)
        body = brace_block(clean, m.start())
        hit = SHADOW.search(body)
        if hit:
            line = clean.count("\n", 0, m.start() + body.find(".shadow(")) + 1
            violations.append(f":{line} {name} 内含 .shadow(，胶囊控件不需要任何投影")

    # 装配区：三个调用点附近不得出现黑色投影修饰器
    for name in FILTER_BARS:
        for m in re.finditer(r"^\s*" + name + r"\s*$", clean, re.M):
            tail = clean[m.end():m.end() + 200]
            if BLACK_SHADOW.search(tail):
                violations.append(f":{clean.count(chr(10), 0, m.start()) + 1} {name} 装配处有黑色投影")

    return violations


def main() -> int:
    if not TARGET.exists():
        print(f"找不到 {TARGET}")
        return 1

    source = TARGET.read_text(encoding="utf-8", errors="ignore")

    if "--self-test" in sys.argv:
        cases = [
            ("挂回 wallpaperReadableText", source.replace(
                "                filterTabBar\n",
                "                filterTabBar\n                    .wallpaperReadableText()\n", 1),
             "wallpaperReadableText"),
            ("分类栏内加黑色阴影", source.replace(
                "        .background(Color.clear)\n    }",
                "        .background(Color.clear)\n        .shadow(color: .black.opacity(0.4), radius: 3)\n    }", 1),
             "胶囊控件不需要任何投影"),
            ("标签栏内加任意投影", source.replace(
                ".foregroundStyle(isSelected ? Color.white : Color.indigo)",
                ".foregroundStyle(isSelected ? Color.white : Color.indigo)\n                        .shadow(color: .gray, radius: 2)", 1),
             "胶囊控件不需要任何投影"),
            ("干净样本应放行", source, None),
        ]
        failed = []
        for label, mutated, expected in cases:
            hits = check(mutated)
            if expected is None:
                if hits:
                    failed.append(f"{label}: 误报 {hits[:2]}")
            elif not any(expected in h for h in hits):
                failed.append(f"{label}: 未拦住（命中 {hits[:2]}）")
        if failed:
            for f in failed:
                print("  ✗ " + f)
            return 1
        print(f"自测通过：{len(cases)} 例（3 类变异均拦下，干净样本放行）")
        return 0

    violations = check(source)
    if violations:
        print("首页分类/标签控件使用了黑色阴影，请改掉：")
        for v in violations:
            print("  TodoListView.swift" + v)
        return 1
    print("首页筛选控件阴影闸门通过：0 处 wallpaperReadableText / 0 处胶囊投影")
    return 0


if __name__ == "__main__":
    sys.exit(main())
