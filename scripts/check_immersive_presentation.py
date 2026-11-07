#!/usr/bin/env python3
"""沉浸式页面呈现闸门：相机/扫码/碰一碰/亮码出示必须全屏，不能用半屏 sheet。

为什么要有这道闸：半屏 `.sheet` 在 iPhone 上会露出上层视图、压缩取景框、
并且支持下拉误关。以下页面天生需要占满屏幕：

- 相机取景器（`AVCaptureVideoPreviewLayer` / `UIImagePickerController`）
- 扫一扫、碰一碰雷达（全屏对焦 + 雷达动画）
- 面对面互联 / 亮码出示（二维码要尽可能大且稳定地给对方扫，
  `TodoQRCodeQuickSheet` 甚至会把屏幕亮度提到 0.95）
- 黑底全屏图片查看器

这类页面用 `.sheet` 不会编译报错、截图也不一定看得出，只在真机上表现为
「取景框被压小 / 后面漏出一层 / 手一滑就关了」。本闸门把名单钉死，
防止新增入口时又退回半屏。

判定：
- `IMMERSIVE_VIEWS` 是需要全屏的 View 名。
- 对每个 `.sheet(` 调用点用大括号配平取出呈现块，块内只要实例化了名单中的
  View 就报违规。配平而非固定看 N 行，避免把紧邻的 `.fullScreenCover` 块
  里的内容误算进前一个 `.sheet`。
- 表单、分享卡、确认弹窗、设置页、导入预览**不在名单内**，保持半屏。
  新增沉浸式页面时把 View 名加进名单即可。
- 注释/文档字符串会被剥除，避免文档举例自证其罪。

用法：
    python3 scripts/check_immersive_presentation.py           # 校验，失败非零退出
    python3 scripts/check_immersive_presentation.py --audit    # 打印当前呈现分布
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = [
    ROOT / "Assistant" / "Features",
    ROOT / "Assistant",
]

# 需要占满屏幕才能正常使用的 View。新增同类页面时在此登记。
IMMERSIVE_VIEWS = {
    "QRCodeScannerView",          # 扫一扫 / 碰一碰接收端
    "NearbyInteractionSheet",     # 碰一碰发送端 / 面对面互联
    "TodoQRCodeQuickSheet",       # 预约二维码 / 门票亮码
    "ReceiptCameraView",          # 小票相机
    "FoodCameraPicker",           # 食物拍照相机
    "VaultCameraPicker",          # 收纳 / 药品相机
    "IDDocumentCameraView",       # 证件相机
    "FullScreenImageViewer",      # 黑底证件大图
}

SHEET_START = re.compile(r"\.sheet\s*\(")
COVER_START = re.compile(r"\.fullScreenCover\s*\(")
VIEW_USE = re.compile(
    r"\b(" + "|".join(sorted(IMMERSIVE_VIEWS)) + r")\s*[\({]"
)


def strip_comments(text: str) -> str:
    """剥掉 // 与 /* */ 注释，保留字符串字面量（SwiftUI 文案里可能有花括号）。"""
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
            if c == "\\":
                if i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
            elif c == '"':
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


def presentation_block(lines, start):
    """返回呈现修饰符的**内容块**文本（`... ) { 这里是内容 }`）。

    不能直接从修饰符所在行数花括号：`onDismiss: { ... }`、
    `Binding(get: { ... }, set: { ... })` 这类参数闭包会让配平提前收尾，
    从而漏掉真正的内容块。所以先用圆括号定位调用结束，再找其后的
    第一个 `{`，最后才对内容块做花括号配平。
    """
    # 1) 配平参数圆括号，定位整个调用结束的 `)`
    depth, started, call_end = 0, False, None
    for j in range(start, min(start + 40, len(lines))):
        for k, ch in enumerate(lines[j]):
            if ch == "(":
                depth += 1
                started = True
            elif ch == ")":
                depth -= 1
                if started and depth == 0:
                    call_end = (j, k)
                    break
        if call_end:
            break
    if not call_end:
        return ""

    # 2) 调用结束之后的第一个 `{` 才是内容块起点
    j0, k0 = call_end
    brace_start = None
    for j in range(j0, min(j0 + 6, len(lines))):
        idx = lines[j].find("{", k0 + 1 if j == j0 else 0)
        if idx >= 0:
            brace_start = (j, idx)
            break
    if not brace_start:
        return ""

    # 3) 从内容块起点做花括号配平
    bj, bk = brace_start
    depth, seen, parts = 0, False, []
    for j in range(bj, min(bj + 200, len(lines))):
        seg = lines[j][bk:] if j == bj else lines[j]
        parts.append(seg)
        for ch in seg:
            if ch == "{":
                depth += 1
                seen = True
            elif ch == "}":
                depth -= 1
        if seen and depth <= 0:
            return "\n".join(parts)
    return "\n".join(parts[:8])


def presentations(root: Path):
    """产出 (路径, 行号, 呈现方式, 块内命中的沉浸式 View 列表)。"""
    seen, files = set(), []
    for d in SCAN_DIRS:
        if not d.exists():
            continue
        for p in d.rglob("*.swift"):
            rp = p.resolve()
            if rp not in seen:
                seen.add(rp)
                files.append(p)
    for p in sorted(files):
        clean = strip_comments(p.read_text(encoding="utf-8", errors="ignore"))
        lines = clean.splitlines()
        rel = str(p.relative_to(ROOT))
        for i, line in enumerate(lines):
            is_sheet = SHEET_START.search(line) is not None
            is_cover = COVER_START.search(line) is not None
            if not (is_sheet or is_cover):
                continue
            kind = "sheet" if is_sheet else "fullScreenCover"
            block = presentation_block(lines, i)
            hits = sorted(set(VIEW_USE.findall(block)))
            if hits:
                yield rel, i + 1, kind, hits


def main() -> int:
    audit = "--audit" in sys.argv
    violations, ok = [], []
    for rel, line, kind, hits in presentations(ROOT):
        entry = (rel, line, kind, hits)
        (violations if kind == "sheet" else ok).append(entry)

    if audit:
        print(f"沉浸式 View 名单：{len(IMMERSIVE_VIEWS)} 个")
        print(f"\n全屏呈现（{len(ok)} 处）：")
        for rel, line, _, hits in ok:
            print(f"  {rel}:{line}  {', '.join(hits)}")
        print(f"\n半屏呈现（{len(violations)} 处，应为 0）：")
        for rel, line, _, hits in violations:
            print(f"  {rel}:{line}  {', '.join(hits)}")
        return 0

    if violations:
        print("沉浸式页面仍用半屏 .sheet 呈现，请改为 .fullScreenCover：")
        for rel, line, _, hits in violations:
            print(f"  {rel}:{line}  {', '.join(hits)}")
        print(f"\n共 {len(violations)} 处。表单/分享卡/确认弹窗不受此约束。")
        return 1
    print(f"沉浸式呈现闸门通过：{len(ok)} 处全屏，0 处半屏")
    return 0


if __name__ == "__main__":
    sys.exit(main())
