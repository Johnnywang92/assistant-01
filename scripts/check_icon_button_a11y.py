#!/usr/bin/env python3
"""图标按钮无障碍闸门：纯图标 `Button` 必须能被 VoiceOver 读出用途。

为什么要有这道闸：只有 `Image(systemName:)`、没有文字也没有 `accessibilityLabel`
的按钮，VoiceOver 只会念「按钮」。这类缺失不会编译报错、截图也看不出来，
只会在辅助功能实际启用时才暴露，很容易随着新页面持续累加。

判定：
- 纯图标 = `Button { ... } label: { ... }` 的 label 块里只有 `Image(systemName:)`，
  没有 `Text(` / `Label(`；带文字的 `Button("...")` 不计入。
- 已标注 = Button 后续链式修饰器里出现 `accessibilityLabel(` 或 `iconButton(`。
- 存量按文件登记 BASELINE，**只允许减少**；补完一批就同步下调基线。
- 确属装饰性、无需朗读的按钮，在同一行写 `// gate:icon-a11y <理由>` 豁免。

用法：
    python3 scripts/check_icon_button_a11y.py                 # 校验，失败非零退出
    python3 scripts/check_icon_button_a11y.py --audit        # 只打印现状
    python3 scripts/check_icon_button_a11y.py --print-baseline  # 输出可直接粘贴的 BASELINE
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIR = ROOT / "Assistant" / "Features"
MARKER = "gate:icon-a11y"

# 迁移期基线：文件（相对仓库根）-> 仍允许的「纯图标且未标注」处数。只降不升。
BASELINE = {
    "Assistant/Features/FoodPhotoCalorieView.swift": 5,
    "Assistant/Features/IDDocumentVaultView.swift": 3,
    "Assistant/Features/ItemStorageVaultView.swift": 2,
    "Assistant/Features/LearnedPlacesView.swift": 1,
    "Assistant/Features/MentalHealthView.swift": 1,
    "Assistant/Features/Omnibox/OmniboxView.swift": 3,
    "Assistant/Features/PasswordVaultView.swift": 1,
    "Assistant/Features/QRCodeScannerView.swift": 1,
    "Assistant/Features/SettingsViews.swift": 2,
    "Assistant/Features/Share/TodoShareSheet.swift": 1,
    "Assistant/Features/Share/UniversalImportPreviewSheet.swift": 1,
    "Assistant/Features/TabBarCustomizationView.swift": 2,
    "Assistant/Features/Todo/AddTodoSheet.swift": 2,
    "Assistant/Features/Todo/TodoBannerCards.swift": 1,
    "Assistant/Features/TravelTicketConfirmationSheet.swift": 1,
    "Assistant/Features/VehicleManagementView.swift": 2,
    "Assistant/Features/VoiceDialogueView.swift": 5,
    "Assistant/Features/WaterTrackerView.swift": 1,
    "Assistant/Features/WebDAVSyncView.swift": 1,
}

BUTTON_START = re.compile(r"\bButton\s*\{")
BUTTON_WITH_TITLE = re.compile(r"\bButton\s*\(\s*\"")
TEXT_IN_LABEL = re.compile(r"\bText\s*\(|\bLabel\s*\(")
MARKED = re.compile(r"accessibilityLabel\s*\(|\.iconButton\s*\(")


def strip_comments(text: str) -> str:
    """剥掉 // 与 /* */ 注释，避免文档里举例的 Button 自证其罪。"""
    out = []
    i, n = 0, len(text)
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


def unlabelled_icon_buttons(text: str):
    """返回 [(行号, 图标名)]，只统计 label 块里没有任何文字的 Button。"""
    lines = strip_comments(text).splitlines()
    found = []
    for i, line in enumerate(lines):
        if MARKER in line or not BUTTON_START.search(line) or BUTTON_WITH_TITLE.search(line):
            continue

        # 花括号配平，定位整个 Button 表达式的结束行。
        depth, started, end = 0, False, None
        for j in range(i, min(i + 60, len(lines))):
            for ch in lines[j]:
                if ch == "{":
                    depth += 1
                    started = True
                elif ch == "}":
                    depth -= 1
            if started and depth <= 0:
                end = j
                break
        if end is None:
            continue

        block = "\n".join(lines[i:end + 1])
        if "label:" not in block:
            continue
        label_part = block.split("label:", 1)[1]
        if TEXT_IN_LABEL.search(label_part) or "Image(systemName:" not in label_part:
            continue

        # 只收集**属于这个 Button** 的链式修饰器行。
        # 不能固定向后看 N 行：紧邻的下一个按钮若挂了 .iconButton()，
        # 会被误算到前一个按钮头上，把真正没标注的漏掉。
        tail_lines = []
        for k in range(end + 1, min(end + 10, len(lines))):
            stripped = lines[k].strip()
            if not stripped:
                continue
            if not stripped.startswith("."):
                break
            tail_lines.append(lines[k])
        tail = "\n".join(tail_lines)
        if MARKED.search(block) or MARKED.search(tail):
            continue

        icon = re.search(r'Image\(systemName:\s*"([^"]+)"', label_part)
        found.append((i + 1, icon.group(1) if icon else "?"))
    return found


def main() -> int:
    audit_only = "--audit" in sys.argv
    print_baseline = "--print-baseline" in sys.argv
    per_file = {}

    for path in sorted(SCAN_DIR.rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        hits = unlabelled_icon_buttons(path.read_text(encoding="utf-8", errors="ignore"))
        if hits:
            per_file[rel] = hits

    total = sum(len(v) for v in per_file.values())
    print(f"扫描 {SCAN_DIR.relative_to(ROOT)}/：纯图标且未标注的 Button {total} 处"
          f"（分布在 {len(per_file)} 个文件）")

    if print_baseline:
        print("\nBASELINE = {")
        for rel, hits in per_file.items():
            print(f'    "{rel}": {len(hits)},')
        print("}")
        return 0

    violations = []
    for rel, hits in per_file.items():
        allowed = BASELINE.get(rel, 0)
        if len(hits) > allowed:
            violations.append((rel, len(hits), allowed, hits))
        elif len(hits) < allowed:
            print(f"  ↓ 基线可下调：{rel} {allowed} → {len(hits)}")

    if violations:
        print("\n❌ 纯图标按钮缺少 accessibilityLabel（VoiceOver 只读「按钮」）：")
        for rel, count, allowed, hits in violations:
            print(f"  {rel}: 当前 {count} 处 / 基线允许 {allowed} 处")
            for lineno, icon in hits[:6]:
                print(f"      :{lineno}  {icon}")
        print("\n   用 `.iconButton(\"动作名\")` 一次补齐标签、44pt 点击区与按钮语义；"
              "\n   或单独加 `.accessibilityLabel(...)`。补完请同步下调 BASELINE。")
        if audit_only:
            print("\n（--audit：只汇报现状，不作为闸门结论）")
            return 0
        return 1

    if audit_only:
        print("\n（--audit：只汇报现状，不作为闸门结论）")
    else:
        print("✅ 图标按钮无障碍闸门通过（存量已在基线内，无新增）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
