#!/usr/bin/env python3
"""圆角令牌闸门：`Assistant/` 里的圆角必须引用 `AppRadius`，不许再写字面量。

为什么要有这道闸：接缝处的圆角原本散成 17 个不同的值（1/2/3/4/5/6/7/8/9/10/12/14/16/
18/20/22/24），同一个角色在不同页面差 1–2pt、改一处永远改不齐。2026-10-29 收敛成
AppRadius 的十档标尺后，这道闸负责让它不再长回去——字面量不会报错，只会慢慢发散。

用法：
    python3 scripts/check_radius_tokens.py          # 校验，失败非零退出
    python3 scripts/check_radius_tokens.py --audit  # 只打印现状

豁免：确有必要写字面量时，在同一行加 `// gate:radius-literal <理由>`。
0 是「不圆角」的重置值，不要求令牌。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIR = ROOT / "Assistant"
# 令牌定义处自己当然要写字面量
EXEMPT_DIR = "Assistant/Theme"

# `cornerRadius: 8` / `cornerRadius: 8.0` / `.cornerRadius(4)`，只认纯数字
LITERAL = re.compile(r"cornerRadius:\s*(\d+(?:\.\d+)?)(?![\d.])|\.cornerRadius\(\s*(\d+(?:\.\d+)?)\s*\)")
MARKER = "gate:radius-literal"


def main() -> int:
    audit_only = "--audit" in sys.argv
    findings = []

    for path in sorted(SCAN_DIR.rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        if rel.startswith(EXEMPT_DIR) or "DerivedData" in path.parts:
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if MARKER in line:
                continue
            for m in LITERAL.finditer(line):
                value = float(m.group(1) or m.group(2))
                if value == 0:
                    continue
                findings.append((rel, lineno, m.group(0).strip(), line.strip()))

    print(f"扫描 {SCAN_DIR.relative_to(ROOT)}/（跳过 {EXEMPT_DIR}/）："
          f"圆角字面量 {len(findings)} 处")

    if findings:
        print("\n❌ 请改用 AppRadius 令牌（定义见 Assistant/Theme/AppTheme.swift）：")
        for rel, lineno, snippet, _ in findings:
            print(f"  {rel}:{lineno}  {snippet}")
        print("\n   已有档位：hairline 2 / badge 4 / small 6 / chip 8 / medium 10 /"
              " card 12 / banner 14 / large 16 / panel 20 / hero 24")
        print("   都不合适就先在 AppRadius 里加一档；确属特例在行尾写 "
              f"`// {MARKER} <理由>`。")

    if audit_only:
        print("\n（--audit：只汇报现状，不作为闸门结论）")
        return 0
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
