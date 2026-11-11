#!/usr/bin/env python3
"""新增 Swift 文件必须重新生成 Xcode 工程，否则不会进编译源。

背景
----
`project.yml` 里各 target 的 `sources` 是**目录级**配置，XcodeGen 在生成时
把目录里的文件展开成 `PBXBuildFile` 写死进 `.pbxproj`。因此新增一个 .swift
文件后，如果没跑 `xcodegen generate`，文件在磁盘上存在、在 Finder 里看得见，
但 Xcode 根本不编译它 —— 表现为 `@main` 入口报
`Cannot find 'XXX' in scope`，而且**报错行指向引用方而不是缺失的文件**，
极难定位（2026-11-11 的 `TravelCountdownWidget` 就是这么漏的）。

本闸门扫描各 target 的源目录，要求每个 .swift 文件都在 pbxproj 的
`in Sources` 编译阶段里出现。SwiftPM 包（`Packages/AssistantCore`）由
包管理器自行收集，不在此检查范围。

`--self-test` 用 3 例内存变异验证闸门本身没失效。
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBX = ROOT / "Assistant.xcodeproj" / "project.pbxproj"

# 与 project.yml 各 target 的 sources 目录一一对应。
SOURCE_DIRS = [
    "Assistant",
    "WidgetShared",
    "AssistantWidgetExtension",
    "ShareExtension",
    "AssistantWatch",
    "AssistantTests",
]


def missing_sources(pbx_text: str, pairs: list[tuple[str, str]]) -> list[str]:
    """pairs: (相对路径, 文件名)。返回未出现在任何 Sources 阶段的文件。"""
    missing: list[str] = []
    for rel, name in pairs:
        # pbxproj 里的 build file 注释形如：/* Foo.swift in Sources */
        if f"{name} in Sources" not in pbx_text:
            missing.append(rel)
    return missing


def collect_pairs() -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for directory in SOURCE_DIRS:
        base = ROOT / directory
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.swift")):
            pairs.append((str(path.relative_to(ROOT)), path.name))
    return pairs


def self_test() -> int:
    fake_pairs = [
        ("AssistantWidgetExtension/A.swift", "A.swift"),
        ("AssistantWidgetExtension/B.swift", "B.swift"),
    ]
    cases = [
        ("全部收录", "/* A.swift in Sources */\n/* B.swift in Sources */", 0),
        ("漏一个文件", "/* A.swift in Sources */", 1),
        ("只有文件引用、没进编译阶段", "/* A.swift */\n/* B.swift */", 2),
    ]
    failed = 0
    for name, pbx, expected in cases:
        got = len(missing_sources(pbx, fake_pairs))
        flag = "OK" if got == expected else "FAIL"
        if got != expected:
            failed += 1
        print(f"  {flag} {name}: 期望 {expected} 个缺失，实得 {got}")
    print(f"[self-test] {'通过' if failed == 0 else '失败'}（{len(cases)} 例）")
    return 1 if failed else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    if not PBX.exists():
        # pbxproj 是 XcodeGen 生成物、未入库。干净 clone / CI 环境里
        # 先跑 ci.sh test 时它本就不存在，此时不该误报成代码问题；
        # all 模式在 xcodegen generate 之后会用 --strict 复核一次。
        if "--strict" in sys.argv:
            print(f"❌ 找不到 {PBX.relative_to(ROOT)}，请先跑 xcodegen generate")
            return 1
        print("⏭️  跳过：pbxproj 是生成物（未入库）；all 模式会在 xcodegen generate 后复核")
        return 0

    pbx_text = PBX.read_text(encoding="utf-8")
    pairs = collect_pairs()
    missing = missing_sources(pbx_text, pairs)
    if missing:
        print(f"❌ 有 {len(missing)} 个 Swift 文件没进 Xcode 编译源：")
        for rel in missing:
            print(f"  - {rel}")
        print("\n  project.yml 是唯一真源，新增文件后请执行：xcodegen generate")
        return 1
    print(f"✅ {len(pairs)} 个 Swift 源文件全部已进 Xcode 编译阶段")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
