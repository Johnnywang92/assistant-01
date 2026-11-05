# 批 4（第一部分）· 分享卡共享品牌部件

> 时间：2026-11-05 ｜ 执行：Lead（teammate 名额已达上限 8，本部分由 Lead 完成）
> 范围：`Assistant/Features/Share/ShareCardScaffold.swift`（新建）+ 4 张分享卡
> 未纳入：Psych 卡（结构不同）、VoiceMemo/Todo 分享卡、完整的 `ShareCardScaffold`/`ShareCardStatTile`

## 1. 抽出的组件

| 组件 | 作用 | 可参数 |
| --- | --- | --- |
| `ShareCardBrandIdentity` | App 图标（34pt，`AppRadius.chip`）+ 主标题 + 副标题「记所想，助所行」 | 标题文案、标题色、副标题色、行距（2 / 1.5）、图标阴影强度（0.12 / 0.2） |
| `ShareCardStudioBadge` | `JohnnyBoyStudio` 专属网站标识胶囊（globe 图标 + 文字） | tint、底色透明度（Health 历史 0.12，其它 0.18） |

设计约束：分享卡是 `ImageRenderer` 位图导出，**组件内不引用任何依赖环境的动态色**，所有颜色由调用方传固定色板。

## 2. 迁移与行数

| 文件 | 重构前 | 重构后 | 变化 |
| --- | --- | --- | --- |
| HealthShareCardView.swift | 620 | 607 | −13 |
| HydrationShareCardView.swift | 434 | 405 | −29 |
| ReportShareCardView.swift | 645 | 616 | −29 |
| ExpenseShareCardView.swift | 357 | 344 | −13 |
| **合计** | 2056 | 1972 | **−84** |
| ShareCardScaffold.swift（新增） | — | 73 | +73 |

净行数几乎持平——**价值不在减行，而在单一出处**：改品牌信息从「改 4 处」变成「改 1 处」。

## 3. 刻意保持不变（视觉零变化）

- 文案：三张卡「小助 · 个人智能生活助理」、Expense 卡「小助 Assistant」，逐字保留；
- 颜色：Health 用 `ink` / `ink.opacity(0.55)`；Hydration/Report 用 `.white` / `white.opacity(0.6)`；Expense 用暖色 RGB 硬编码，全部原值传入；
- 间距：落款外 `VStack` 12（Health/Report）与 8（Hydration/Expense）保持；标题行距 2 与 1.5 保持；
- 阴影：Health/Expense 0.12，Hydration/Report 0.2；
- 胶囊：图标 9pt、文字 10pt rounded bold、内边距 9×4.5、stroke 0.3/0.6、`fixedSize` 全部原值。

## 4. 发现但未改的漂移（会改视觉，需真机截图对比后再动）

1. toast 动画时长三套（2.0 / 2.5 / `.snappy`）；
2. 卡片阴影不统一（部分有阴影、部分没有）；
3. 胶囊底色透明度 Health 0.12 vs 其它 0.18；
4. `ExpenseShareCardView` 的 `includeReceipt` 疑似死状态（无 Toggle 绑定）。

## 5. 验证

- 5 个文件 `swiftc -parse`（iphoneos / arm64 / iOS18）通过；
- `check_radius_tokens.py` exit 0（图标圆角走 `AppRadius.chip`）；
- `check_save_swallow.py` exit 0（全仓 0 处）；
- `./scripts/ci.sh test` 全绿（1117 Core 测试 + 4 道闸门 + 心理视图类型检查）；
- `xcodegen generate` 通过。

## 6. 真机截图对比清单（合并前必做）

- 健康日签（有数据 / 无数据）
- 饮水卡（渐变主题 × 深浅两套）
- 周期报告卡（日报 / 周报 / 月报各一张）
- 记账账单卡（含原币种 / AA 分摊）
- 逐张确认：图标圆角、标题字号、副标题颜色、落款间距、胶囊底色与描边、卡片宽度 350pt
