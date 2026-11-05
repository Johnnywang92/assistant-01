# 批 4（第二部分）· 宝宝 / 宠物档案组件化（UI-14）

> 时间：2026-11-05 ｜ 执行：Lead（teammate 名额仍为上限 8）
> 范围：`ChildManagementView.swift`、`PetManagementView.swift`（新建 `ProfileSharedComponents.swift`）
> 未纳入：`ChildRecordsView` / `PetRecordsView`（实测跨文件重复仅 2 个窗口，不值得抽）

## 1. 重构前实测

| 指标 | 数值 |
| --- | --- |
| Child↔Pet 跨文件重复 5 行窗口 | **43** |
| 逐函数相似度（Body/空态/记录区/快捷按钮） | 0.83–1.00 |
| `ChildManagementView` / `PetManagementView` 行数 | 591 / 641 |

## 2. 抽出的组件（`ProfileSharedComponents.swift`，228 行）

| 组件 | 作用 | 参数化差异 |
| --- | --- | --- |
| `ProfileQuickActionButton` | 记录区下方快捷按钮（图标+标题+tint 底色） | 标题 / 图标 / 颜色 / 回调 |
| `ProfileEmptyStateCard` | 空态：图标 + 标题 + 说明 + 「添加档案」胶囊按钮 | 图标 / 图标色 / 标题 / 说明 / 按钮文案 / 按钮色 / 回调 |
| `ProfileRecordsAction` + `ProfileRecordsSection` | 成长记录入口区：可点整块 + 计数徽标 + 三个快捷动作 | tint / 标题 / 副标题 / 计数 / 主入口回调 / 动作数组 |
| `ProfileOverviewHeaderCard` | 顶部概览卡：圆形图标 + 标题（可带徽标）+ 副标题 | 图标 / tint / 标题 / 副标题 / 徽标文案（nil 时不包 HStack，保持原排版）/ 徽标色 |

设计原则：组件内部**不判断**当前是宝宝还是宠物；所有差异由调用方参数注入；沿用系统语义色 + 调用方 tint。

## 3. 行数与重复度

| 指标 | 重构前 | 重构后 | 变化 |
| --- | --- | --- | --- |
| `ChildManagementView.swift` | 591 | 482 | −109 |
| `PetManagementView.swift` | 641 | 522 | −119 |
| `ProfileSharedComponents.swift`（新增） | — | 228 | +228 |
| 两个页面净行数 | 1232 | 1004 | **−228（都搬进了共享组件）** |
| **Child↔Pet 重复 5 行窗口** | **43** | **21** | **−51%** |

> 诚实说明：审计预估「−200~300 行」是按「两套页面都瘦下来」算的，但抽出的共享组件本身要占行数，
> 所以**净行数没有变化，真正的收益是重复度减半 + 单一出处**。要继续减行只能合并 `AddEditChildSheet` /
> `AddEditPetSheet` 或 `childCard`/`petCard`，而那属于**行为合并**（字段与业务不同），不在本任务范围。

## 4. 刻意未合并（语义不同，合并会改变行为）

| 区域 | 相似度 | 不合并原因 |
| --- | --- | --- |
| `childCard` / `petCard` | 0.45 | 字段、徽标、疫苗/驱虫逻辑完全不同 |
| `AddEditChildSheet` / `AddEditPetSheet` | 低 | 表单字段集合不同（血型/身份证/过敏 vs 品种/芯片/绝育状态） |
| `vaccineRow` / `careStatusRow` | 低 | 疫苗排期 vs 驱虫/洗澡周期，业务规则不同 |
| `showToast` + toast overlay | 1.00 | 形态相同但状态由各页面 `@State` 持有；抽成共享需要改状态管理（引入 `@StateObject` 或环境对象），为 ~20 行收益引入新状态通道不划算，留作后续统一 toast 时再做 |
| `ChildRecordsView` / `PetRecordsView` | 重复窗口仅 2 | 记录类型与表单差异大，抽取收益 < 风险 |

## 5. 行为等价性检查（人工逐项对照）

- 空态：图标/图标色（`.pink`/`.teal` + 0.6 透明度）、标题、说明、按钮文案与底色、`AppRadius.banner`、`padding(.vertical, 12)` 全部逐值一致；
- 记录区：tint 透明度 0.12 / 徽标底色 0.15、「N 项」显示条件（>0）、`AppRadius.card`、`Color(.tertiarySystemGroupedBackground)`、chevron 字号与颜色、三个快捷动作的顺序/文案/图标/颜色/落地类型全部一致；
- 概览卡：圆形 50pt、tint 0.12、图标 `title2`、标题副标题字号与颜色、`AppRadius.banner`、`padding(14)` 一致；宠物卡的「N 项需处理」徽标文案/颜色/条件（`needingCareCount > 0`）不变；无徽标时不包 HStack，保持原排版；
- 状态与回调：`showAddChild` / `showAddPet` / `openRecords(for:type:)` / `needingCareCount` / `allPetRecords` 的读写位置与时机未变。

## 6. 验证

```
xcrun swiftc -parse（5 个文件，iphoneos/arm64/iOS18）   通过
./scripts/ci.sh test                                    全绿（4 闸门 + 1117 Core 测试 + 类型检查）
python3 scripts/check_radius_tokens.py                  exit 0
python3 scripts/check_save_swallow.py                   exit 0（全仓 0 处）
xcodegen generate                                       通过（新文件已入工程）
重复度复查（5 行窗口）                                  43 → 21
```

## 7. 真机回归清单

- 空态：无档案时点「添加宝贝档案 / 添加宠物档案」→ 弹出新建表单；
- 顶部概览卡：宠物有「需处理」项时徽标出现，清零后消失；宝宝卡文案正常；
- 记录区：点击整块 / 三个快捷按钮分别进入对应记录页与初始 Tab；
- 有记录时「N 项」徽标数值正确（宝宝：成长+里程碑+就诊；宠物：`sortedRecords` 总数）；
- 卡片删除 / 编辑 / 疫苗与驱虫状态展示不受影响。
