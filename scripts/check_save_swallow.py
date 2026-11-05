#!/usr/bin/env python3
"""落库吞错闸门：禁止新增 `try? ... save()`。

为什么要有这道闸：`try?` 把落库失败压成 nil，调用方却照样播成功震动、回「已记下」、
把通知排出去。磁盘满 / 库损坏时用户看到成功、数据没落库（审计报告 UI-01 / SVC-04）。

规则：
- 新增的 `try? <ctx>.save()` 一律判红。
- 存量按文件登记基线（下面的 BASELINE），**只允许减少**；改完一批就同步下调基线。
- 注释里的写法不计入（先剥注释再扫描，避免文档自证其罪）。
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = ["Assistant"]

# 迁移期基线：文件 -> 仍允许的 `try? save` 处数。改完一批请同步下调，只降不升。
BASELINE = {}


def strip_comments(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    in_str = in_line = in_block = False
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            i += 1
            continue
        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            if c == "\n":
                out.append(c)
            i += 1
            continue
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(nxt)
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def count_swallowed(path: Path) -> int:
    import re
    text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
    return len(re.findall(r"try\?\s+[A-Za-z_][\w.]*\.save\(\)", text))


def main() -> int:
    current = {}
    for d in SCAN_DIRS:
        for p in (ROOT / d).rglob("*.swift"):
            if ".build" in p.parts or "DerivedData" in p.parts:
                continue
            n = count_swallowed(p)
            if n:
                current[str(p.relative_to(ROOT))] = n

    regressions = []
    for f, n in sorted(current.items()):
        allowed = BASELINE.get(f, 0)
        if n > allowed:
            regressions.append((f, allowed, n))
    stale = [(f, base) for f, base in sorted(BASELINE.items()) if current.get(f, 0) < base]

    print(f"扫描 {len(current)} 个文件，仍有 {sum(current.values())} 处 `try? save()`"
          f"（基线 {sum(BASELINE.values())} 处）")

    if stale:
        print(f"\nℹ️  以下文件已清理，请把基线下调到当前值（只降不升）：")
        for f, base in stale[:40]:
            print(f"  {f}: 基线 {base} -> 当前 {current.get(f, 0)}")
    if regressions:
        print(f"\n❌ 新增了 `try? save()`（会吞掉落库失败）：")
        for f, allowed, n in regressions:
            print(f"  {f}: 允许 {allowed}，实际 {n}")
        print("\n  改用 `context.saveReportingFailure { error in ... }` 或 do/catch，"
              "并在成功后给成功反馈。")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
