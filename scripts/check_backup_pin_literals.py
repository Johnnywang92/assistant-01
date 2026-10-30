#!/usr/bin/env python3
"""备份口令字面量闸门：备份封套的口令必须是用户输入/钥匙串读取，不许写字面量。

为什么要有这道闸：后台自动同步曾经把 `"AssistantAutoSync2026!"` 写死在
WebDAVSyncService 里当 PIN。文件在 NAS 上、口令在二进制里，等于对任何拿到文件的人
公开——而 PBKDF2 的全部强度都建立在「口令保密」这个前提上。字面量不会报错、也不影响
功能，只会让加密外壳变成一个很贵的摆设，所以用闸门把它堵在提交前。

判定：`exportEncryptedArchive(pin:)` 与 `uploadBackup(pin:)` 的 pin 实参
- 直接是字符串字面量 → 判红；
- 是同文件里的标识符，而该标识符被赋成字符串字面量（`let x = "…"`）→ 判红
  （换一行中转一下就绕过闸门的写法，照样拦）；
- 是函数参数、属性读取、Keychain 结果等 → 放行。

用法：
    python3 scripts/check_backup_pin_literals.py          # 校验，失败非零退出
    python3 scripts/check_backup_pin_literals.py --audit  # 只打印现状

豁免：确有必要时，在调用行或常量声明行写 `// gate:backup-pin-literal <理由>`。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = ["Assistant", "WidgetShared", "ShareExtension", "AssistantWidgetExtension"]

# `exportEncryptedArchive(pin: X` / `uploadBackup(pin: X`，X 取到逗号或右括号为止
CALL = re.compile(r"\b(?:exportEncryptedArchive|uploadBackup)\s*\(\s*pin\s*:\s*([^,)\n]+)")
MARKER = "gate:backup-pin-literal"
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")


def literal_declarations(path: Path) -> set:
    """同文件里「名字 = 非空字符串字面量」的声明，用来识别绕道常量。
    空串只是占位（如 @State 的初始值），不当作硬编码口令。"""
    pattern = re.compile(
        r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[^=\n]+?)?\s*=\s*\"([^\"]*)\""
    )
    names = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        if MARKER in line:
            continue
        for match in pattern.finditer(line):
            if match.group(2).strip():
                names.add(match.group(1))
    return names


def scan() -> list:
    findings = []
    for dirname in SCAN_DIRS:
        directory = ROOT / dirname
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.swift")):
            if "DerivedData" in path.parts or "build" in path.parts:
                continue
            rel = str(path.relative_to(ROOT))
            literal_constants = None
            for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if MARKER in line:
                    continue
                for match in CALL.finditer(line):
                    argument = match.group(1).strip()
                    reason = None
                    if argument.startswith('"'):
                        if argument.strip('"').strip():
                            reason = "直接传字符串字面量"
                    else:
                        name = argument.split(".")[-1].strip()
                        if IDENTIFIER.match(name):
                            if literal_constants is None:
                                literal_constants = literal_declarations(path)
                            if name in literal_constants:
                                reason = f"`{name}` 是同文件的字符串字面量常量"
                    if reason:
                        findings.append((rel, lineno, argument, reason, line.strip()))
    return findings


def main() -> int:
    audit_only = "--audit" in sys.argv
    findings = scan()

    print(f"扫描 {'/、'.join(SCAN_DIRS)}/：备份口令字面量 {len(findings)} 处")

    if findings:
        print("\n❌ 备份口令必须是用户输入或钥匙串读取，不能写字面量：")
        for rel, lineno, argument, reason, _ in findings:
            print(f"  {rel}:{lineno}  pin: {argument}  （{reason}）")
        print("\n   自动备份请用 WebDAVSyncService.setAutoSyncPIN 存进钥匙串后读回；")
        print(f"   确属特例在该行写 `// {MARKER} <理由>`。")

    if audit_only:
        print("\n（--audit：只汇报现状，不作为闸门结论）")
        return 0
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
