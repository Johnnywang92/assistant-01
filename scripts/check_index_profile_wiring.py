#!/usr/bin/env python3
"""两个健康指数必须共用同一份身体档案上下文。

背景
----
`VitalityEvaluator.evaluate` / `PleasureIndexEvaluator.evaluate` 在 App 侧有
10 处现算点（健康页、手表快照、日报、睡前提醒、生活问答、HealthKitService）。
任何一处漏传 `profile:`，就会出现「手表 72 分、App 68 分」这类静默口径漂移，
而且不会有任何编译错误——`profile` 有默认值 nil。

本闸门扫描 App 侧全部调用点，要求：
  * 每个调用都必须显式传 `profile:`；
  * 参数不能是字面量 `nil`（那等于没接）。

用括号配平截取实参，避免注释/字符串里的假匹配。
`--self-test` 用 4 例内存变异验证闸门本身没失效。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "Assistant"
CALL_RE = re.compile(r"(?:VitalityEvaluator|PleasureIndexEvaluator)\.evaluate\(")


def _call_arguments(text: str, start: int) -> str:
    """从 `evaluate(` 的 `(` 之后开始，括号配平取到对应 `)` 的实参文本。"""
    depth = 1
    i = start
    while i < len(text) and depth:
        char = text[i]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        i += 1
    return text[start:i - 1] if depth == 0 else text[start:]


def _strip_comments(text: str) -> str:
    """逐行去掉 // 注释（本项目没有依赖字符串内 // 的调用点，精度足够）。"""
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def check_source(text: str, label: str) -> list[str]:
    """返回问题列表；空列表表示通过。"""
    clean = _strip_comments(text)
    problems: list[str] = []
    for match in CALL_RE.finditer(clean):
        line = clean[: match.start()].count("\n") + 1
        args = _call_arguments(clean, match.end())
        if "profile:" not in args:
            problems.append(f"{label}:{line} 未传 profile:（会退回旧口径，与其他端分数不一致）")
            continue
        # 抓 `profile:` 之后到下一个逗号/右括号之间的值
        tail = args.split("profile:", 1)[1]
        value = re.split(r"[,\)]", tail, maxsplit=1)[0].strip()
        if value in ("nil", "Optional.none"):
            problems.append(f"{label}:{line} profile 传了 nil（等于没接入）")
    return problems


def scan() -> list[str]:
    problems: list[str] = []
    for path in sorted(APP_DIR.rglob("*.swift")):
        problems.extend(check_source(path.read_text(encoding="utf-8"), str(path.relative_to(ROOT))))
    return problems


def self_test() -> int:
    cases = [
        ("未传 profile", "let v = VitalityEvaluator.evaluate(snapshot: s, foodIntakeCalories: 1)", 1),
        ("传 nil", "let p = PleasureIndexEvaluator.evaluate(snapshot: s, profile: nil)", 1),
        ("正确接入", "let v = VitalityEvaluator.evaluate(\n  snapshot: s,\n  foodIntakeCalories: c,\n  profile: BodyProfileContextProvider.shared.context()\n)", 0),
        ("注释里的假调用不算", "// let v = VitalityEvaluator.evaluate(snapshot: s)\nlet ok = 1", 0),
    ]
    failed = 0
    for name, source, expected in cases:
        got = len(check_source(source, name))
        flag = "OK" if got == expected else "FAIL"
        if got != expected:
            failed += 1
        print(f"  {flag} {name}: 期望 {expected} 个问题，实得 {got}")
    print(f"[self-test] {'通过' if failed == 0 else '失败'}（{len(cases)} 例）")
    return 1 if failed else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    problems = scan()
    if problems:
        print("❌ 两个指数的身体档案接入不完整：")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("✅ 两个指数的全部 App 调用点均已接入身体档案上下文")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
