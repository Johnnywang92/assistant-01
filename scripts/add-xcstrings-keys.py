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


def build_entry(key, en, zh_hans, indent):
    """生成一个键的完整文本块。缩进层级与文件其余部分一致，**不带尾逗号**。

    逗号一律跟在**值后面**（行尾），与 Xcode 原生风格一致。
    """
    pad = "    " * indent
    inner = "    " * (indent + 1)
    inner2 = "    " * (indent + 2)
    inner3 = "    " * (indent + 3)
    inner4 = "    " * (indent + 4)
    lines = []
    lines.append(f"{pad}{escape(key)} : {{")
    lines.append(f'{inner}"extractionState" : "manual",')
    lines.append(f'{inner}"localizations" : {{')
    for idx, (loc, value) in enumerate((("en", en), ("zh-Hans", zh_hans))):
        lines.append(f'{inner2}{escape(loc)} : {{')
        lines.append(f'{inner3}"stringUnit" : {{')
        lines.append(f'{inner4}"state" : "translated",')
        lines.append(f'{inner4}"value" : {escape(value)}')
        lines.append(f'{inner3}}}')
        # localizations 内各语言之间用行尾逗号分隔
        lines.append(f'{inner2}}}' + ("," if idx == 0 else ""))
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
        locs = item["localizations"]
        en = locs["en"]["stringUnit"]["value"]
        zh = locs["zh-Hans"]["stringUnit"]["value"]
        blocks.append(build_entry(key, en, zh, 1))

    # 块之间用行尾逗号分隔；最后一块也带逗号，接回原有个键
    insertion = ",\n".join(blocks) + ",\n"
    new_raw = raw[:insert_pos] + insertion + raw[insert_pos:]

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_raw)

    # ---- diff 三查 ----
    after = json.loads(new_raw)
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


if __name__ == "__main__":
    main()
