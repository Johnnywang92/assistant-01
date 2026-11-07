#!/usr/bin/env python3
"""向 Localizable.xcstrings 追加新键，**不改动任何已有内容**。

## 为什么必须用文本插入而不是重新序列化

这个文件由 Xcode 生成，格式是它自己的 JSON 风格：
- `"key" : value`——冒号**两侧都有空格**（标准 json.dumps 没有）
- 2 空格缩进
- 空对象写作 `{\\n\\n    }`（闭合括号在行首，缩进为空）

用 `json.dumps(indent=2)` 重新序列化会得到完全不同的字节，整个文件变成一大坨无关 diff。
所以这里只在文本层面**定点插入**新键，已有字节一个都不碰。

## 插入策略

把新键插到 `"strings" : {` 之后、第一个已有键之前。
新键块之间用行尾逗号分隔，块尾再补一个逗号接回原有个键。
这样插入点唯一确定，不需要在文件尾部做脆弱的括号反扫。

## 纪律（见 .workbuddy/memory/MEMORY.md）

1. 不 sort_keys——文件里 key 的顺序并非字典序。
2. 改完必须 diff 三查：added / removed / changed 都要看，changed 必须是 0。
"""
import json
import sys


def escape(text):
    """按 Xcode 风格转义字符串字面量（含引号与控制字符）。"""
    return json.dumps(text, ensure_ascii=False)


def build_entry(key, en, zh_hans, indent, auto_extracted=False):
    """生成一个键的完整文本块。缩进层级与文件其余部分一致，**不带尾逗号**。

    逗号一律跟在**值后面**（行尾），与 Xcode 原生风格一致。

    `en` 为 None 时**不写英文块**——项目里中文先上、英文后补是常态，
    不能因为缺英文就拒绝新增这个键（否则整个批次都加不进去）。

    `auto_extracted` 为 True 时按 **Xcode 自动提取**的形态输出：
    不写 `extractionState`，`state` 用 `new`，并保留位置参数形式
    （`%1$@ %2$lld`）。这类串是 Xcode 从源码里抓的，
    位置参数保证参数重排时不错乱——手写成 `%@ %lld` 会丢掉这个保证。
    """
    # Xcode 的层级是 4 / 6 / 8 / 10 / 12 空格（每层 +2），不是 4 的倍数。
    # 写成 4/8/12 虽然 JSON 合法，但会让新增键与文件其余部分风格不一致。
    pad = "  " * (indent * 2)
    inner = pad + "  "
    inner2 = pad + "    "
    inner3 = pad + "      "
    inner4 = pad + "        "
    pairs = [("en", en), ("zh-Hans", zh_hans)]
    pairs = [(loc, value) for loc, value in pairs if value is not None]
    if not pairs:
        # 没有任何语言值 → 输出 Xcode 风格的空对象（闭合括号在行首、缩进为空）。
        return f"{pad}{escape(key)} : {{\n\n{pad}}}"
    lines = []
    lines.append(f"{pad}{escape(key)} : {{")
    if not auto_extracted:
        lines.append(f'{inner}"extractionState" : "manual",')
    lines.append(f'{inner}"localizations" : {{')
    for idx, (loc, value) in enumerate(pairs):
        lines.append(f'{inner2}{escape(loc)} : {{')
        lines.append(f'{inner3}"stringUnit" : {{')
        # 值必须是合法 JSON 字符串：曾经漏写引号，写出 `"state" : translated,`
        # 这种坏 JSON，且当时是在写回文件之后才校验，直接把 xcstrings 写坏了。
        state = "new" if auto_extracted else "translated"
        lines.append(f'{inner4}"state" : "{state}",')
        lines.append(f'{inner4}"value" : {escape(value)}')
        lines.append(f'{inner3}}}')
        # localizations 内各语言之间用行尾逗号分隔
        lines.append(f'{inner2}}}' + ("," if idx < len(pairs) - 1 else ""))
    lines.append(f"{inner}}}")
    lines.append(f"{pad}}}")
    return "\n".join(lines)


def main():
    path = sys.argv[1]
    entries_path = sys.argv[2]

    with open(path, encoding="utf-8") as f:
        raw = f.read()

    data = json.loads(raw)
    before_keys = list(data["strings"].keys())
    before_content = {k: data["strings"][k] for k in before_keys}

    new_entries = json.load(open(entries_path, encoding="utf-8"))

    to_add = []
    for key in new_entries:
        if key in data["strings"]:
            print(f"跳过已存在的键: {key!r}")
            continue
        to_add.append(key)

    if not to_add:
        print("没有需要新增的键")
        return

    marker = '"strings" : {'
    insert_pos = raw.index(marker) + len(marker)
    # 紧跟其后的是换行 + 第一个键的缩进
    tail = raw[insert_pos:]
    nl = tail.index("\n")
    insert_pos += nl + 1  # 落到第一个键所在行的行首

    blocks = []
    for key in to_add:
        item = new_entries[key]
        locs = item.get("localizations")
        if not locs:
            # 空定义（Xcode 的「已声明但未翻译」状态）：原样保留空对象。
            # Xcode 自己写的就是 `{\n\n    }`（闭合括号在行首、缩进为空）。
            blocks.append(f'    {escape(key)} : {{\n\n    }}')
            continue
        # 缺英文时用 None（不写英文块），而不是报错拒绝新增
        en = locs.get("en", {}).get("stringUnit", {}).get("value")
        zh = locs.get("zh-Hans", {}).get("stringUnit", {}).get("value")
        # 值里带位置参数（`%1$@`）说明是 Xcode 从源码自动提取的，
        # 要按自动提取的形态输出（`state: "new"`、无 extractionState）。
        auto = any(v and "%1$" in v for v in (en, zh))
        blocks.append(build_entry(key, en, zh, 1, auto_extracted=auto))

    # 块之间用行尾逗号分隔；最后一块也带逗号，接回原有个键
    insertion = ",\n".join(blocks) + ",\n"
    new_raw = raw[:insert_pos] + insertion + raw[insert_pos:]

    # ---- 先校验再落盘 ----
    # 生成的块一旦非法，绝不能把坏 JSON 写进文件（xcstrings 是工程唯一本地化源）。
    try:
        after = json.loads(new_raw)
    except json.JSONDecodeError as exc:
        print(f"!! 生成结果不是合法 JSON，已放弃写入：{exc}")
        sys.exit(1)

    # ---- diff 三查 ----
    after_keys = list(after["strings"].keys())
    removed = [k for k in before_keys if k not in after["strings"]]
    changed = [
        k for k in before_keys
        if k in after["strings"]
        and json.dumps(before_content[k], ensure_ascii=False, sort_keys=True)
        != json.dumps(after["strings"][k], ensure_ascii=False, sort_keys=True)
    ]

    print(f"键总数: {len(before_keys)} -> {len(after_keys)}")
    print(f"added   = {len(after_keys) - len(before_keys)}")
    print(f"removed = {len(removed)}  {removed[:5]}")
    print(f"changed = {len(changed)}  {changed[:5]}")
    if removed or changed:
        print("!! 有已有键被改动或删除，请检查")
        sys.exit(1)
    print("OK：已有键零改动")

    # ---- 全部校验通过后才落盘 ----
    # 曾经把校验前置时漏掉了写入语句：脚本一路打印 OK，文件却一个字节没变，
    # 新文案全部静默失效。落盘后必须复读确认新键真的在文件里。
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_raw)

    with open(path, encoding="utf-8") as f:
        persisted = json.load(f)
    missing = [k for k in to_add if k not in persisted["strings"]]
    if missing:
        print(f"!! 写入后仍缺少新键：{missing}")
        sys.exit(1)
    print(f"已写入 {len(to_add)} 个新键 -> {path}")


if __name__ == "__main__":
    main()
