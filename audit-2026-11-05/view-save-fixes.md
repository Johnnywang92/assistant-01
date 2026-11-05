# 批 2b：视图层剩余 58 处落库吞错收口（Features，除 4 个 Lead 文件）

日期：2026-11-05　负责人：view-save-fixer（task-8）
范围：`Assistant/Features/` 下除 `ItemStorageVaultView.swift`、`ExpenseTrackerView.swift`、`HabitAndMedicationView.swift`、`MentalHealthView.swift` 之外的全部 `try? context.save()`。

## 0. 结果总览

| 指标 | 数值 |
| --- | --- |
| 本批清理站点 | **58 处 / 28 文件**（清单见 §1） |
| 收口后 `Assistant/Features` 剩余 `try? save()` | **0 处**（本批 58 处清零；Lead 并行的 4 个文件也已清零，其中 ItemStorageVaultView 的 6 处在本次收尾时已被 Lead 改掉） |
| 全仓剩余（闸门读数） | **0 处**（基线仍为 64，脚本提示「请下调基线」，**未改 BASELINE**，按任务约定留给 Lead 统一重算） |
| `python3 scripts/check_save_swallow.py` | **exit 0** |
| 28 个改动文件 `swiftc -parse` | **28/28 通过** |
| `Packages/AssistantCore && swift test --disable-sandbox` | **1115 tests, 0 failures**（Core 未改动，作为环境自检） |
| 整包 `xcodebuild` | 本沙箱无法执行（宏插件被沙箱拒绝）→ **需本机 `./scripts/ci.sh` 收尾** |

统一改法：`try? context.save()` → `context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "用户视角动作名") }`（失败自动 `rollback()`），并把**成功副作用全部后置**：
`Haptic.success()` / `showToast` / `showFeedback` / `UIImpactFeedbackGenerator` / `dismiss()` / `onCompletion` / 计数与提示文案 / 排通知 / 实时活动 / 快照刷新。
失败时统一：**不弹成功文案、不播成功触感、不 dismiss**，补 `Haptic.error()`；
用户可见的失败提示由全局红色横幅（`SaveFailureBanner`，读 `SaveFailureCenter.shared.message`）承担，视图内不新增 toast。

站点分布（每文件处数 = 本批清理数）：

- 5 处：VoiceMemoDetailView、PetManagementView
- 4 处：VehicleManagementView、LifeEventManagementView
- 3 处：MedicineReminderSupport、LearnedPlacesView、FoodPhotoCalorieView、DepartureChecklistView、ChildRecordsView、ChildManagementView
- 2 处：WaterTrackerView、PainPointManagementView、LifeEventTaskPlanningView、EditTodoSheet
- 1 处 ×14：VoiceMemoListView、TodoListView、TodoImportPreviewSheet、Todo/TodoSheet、TodayBriefingView、SkillPathListView、Share/UniversalImportPreviewSheet、ReminderCenterView、QRCodeScannerView、PetRecordsView、Omnibox/OmniboxView、IDDocumentVaultView、CompletedTodoHistoryView、AnniversaryManagementView

## 1. 逐文件改动清单

| # | 文件 | 处数 | 站点与「原行为 → 新行为」 | 失败时用户看到什么 |
| --- | --- | --- | --- | --- |
| 1 | `Assistant/Features/VoiceMemoDetailView.swift` | 5 | ① 标题 `.onSubmit`；② 分类 Picker 的 Binding setter（均为纯写入）→ 直接 `saveReportingFailure(action: 保存语音备忘标题/分类)`；③ 转写编辑「保存」→ guard 后才 `isEditingTranscript=false` + `Haptic.success()`；④ AI 摘要→ guard 后才成功触感（`isGeneratingAISummary` 已先复位）；⑤ 提取待办 `commit()` → guard 后才 `Haptic.success()` + `dismiss()` | 横幅「保存xxx失败：…」+ 错误触感；转写/提取失败**不退出编辑、不关页**；标题/分类失败仅横幅 |
| 2 | `Assistant/Features/PetManagementView.swift` | 5 | 体外驱虫 / 体内驱虫 / 疫苗打卡 → guard 后才 `showToast("已打卡…")`；删除宠物档案 → guard 后才 toast；添加宠物档案 → guard 后才 `dismiss()` | 横幅 + 错误触感；打卡失败**不显示「已打卡」**；删除失败档案保留且无「已删除」；建档失败**留页可重试** |
| 3 | `Assistant/Features/VehicleManagementView.swift` | 4 | 删除爱车 → guard 后才 `Haptic.warning()`；新增爱车 → guard 后才成功触感 + dismiss；编辑爱车「完成」→ guard 后才成功 + dismiss；车务一键记账 → guard 后成功 + dismiss | 横幅 + 错误触感；删除失败车还在、无成功触感；表单失败**不关页** |
| 4 | `Assistant/Features/LifeEventManagementView.swift` | 4 | 添加人物 / 添加开销 / 添加宾客 / 编辑任务四个表单的「保存」→ 各自 guard 后才 `dismiss()` | 横幅 + 错误触感；**表单留在页内**、输入不丢，可重试 |
| 5 | `Assistant/Features/MedicineReminderSupport.swift` | 3 | ① `takeOneDose` → guard 后才成功触感；失败返回 `"服药记录保存失败，请重试"`（原返回成功文案）；② `disposeAndCreateRestockTodo` → guard 后才成功触感；失败返回 `0`（原返回已清理数）；③ `stopReminder` → **撤销提醒/重排/成功触感全部移到 save 成功之后**；失败 `Haptic.error()` + `return false`（原 `return true`） | 横幅 + 错误触感；打卡失败时调用方显示的是失败文案而非「已记录服用…」；停提醒失败时提醒**不被撤掉**、档案与提醒保持一致；另同步修复本文件内唯一的 `stopReminder` 调用点：失败时**不 dismiss**，留页重试 |
| 6 | `Assistant/Features/LearnedPlacesView.swift` | 3 | 坐标校准 / Wi-Fi 关联两处在 `Task` 闭包内 → 用 `if context.saveReportingFailure { 成功反馈 } else { Haptic.error() }`（**不用 guard**，保证后面的 `isUpdatingLocation = false` 一定执行）；新增地点表单 → guard 后才 `syncParcelStationGeofences` + 成功触感 + dismiss | 横幅 + 错误触感；失败时「已成功校准/已关联」文案**不出现**，「正在定位」状态正常复位、按钮可再点 |
| 7 | `Assistant/Features/FoodPhotoCalorieView.swift` | 3 | 保存饮食记录 → guard 后才 `Haptic.success()` 与入账动效/草稿清空；删除记录 → guard 后才警告触感 + dismiss；编辑记录 → guard 后才成功 + dismiss | 横幅 + 错误触感；保存失败**不播「入账」动效、不清空草稿**；删除失败记录保留；编辑失败不关页 |
| 8 | `Assistant/Features/DepartureChecklistView.swift` | 3 | 添加建议条目 → guard 后才 `pendingDepartureRefresh` + 成功触感；重置清单 → guard 后才成功触感（并在其后保留原有 `clearedIDs` 判空）；编辑/新增条目 → guard 后才成功 + `onChanged()` + dismiss | 横幅 + 错误触感；失败时清单不显示「已重置/已保存」、不触发实时活动同步 |
| 9 | `Assistant/Features/ChildRecordsView.swift` | 3 | 成长测量 / 里程碑 / 就诊记录三个 `save()`（原为一行式）→ 拆分并 guard 后才 `dismiss()` | 横幅 + 错误触感；表单**留在页内**可重试 |
| 10 | `Assistant/Features/ChildManagementView.swift` | 3 | 疫苗打卡 → guard 后才 `UIImpactFeedbackGenerator` + 「已完成打卡」toast；删除宝贝 → guard 后才 toast；添加宝贝 → guard 后才 dismiss | 横幅 + 错误触感；打卡失败不显示成功 toast；删除失败档案保留；建档失败留页 |
| 11 | `Assistant/Features/WaterTrackerView.swift` | 2 | ① HealthKit 同步标记（`MainActor.run` 内纯写入）→ 直接上报，不再吞错；② 删除饮水记录 → guard 后才 `showToast("已删除记录")` | 横幅；同步标记失败仅横幅（主记录此前已单独落库）；删除失败记录保留、无「已删除」 |
| 12 | `Assistant/Features/PainPointManagementView.swift` | 2 | 添加自动续费监控 / 添加临期预警 → guard 后才 dismiss | 横幅 + 错误触感；表单留页可重试 |
| 13 | `Assistant/Features/LifeEventTaskPlanningView.swift` | 2 | 两处「导入 AI 决策为待办」→ guard 后才成功触感、`copiedHint`/`statusHint` 成功文案、关闭预览/dismiss | 横幅 + 错误触感；失败时**不显示「已导入 N 条待办」**、预览不关闭，可重试 |
| 14 | `Assistant/Features/EditTodoSheet.swift` | 2 | 保存待办 → guard 后才成功 + dismiss；删除待办 → guard 后才警告触感 + dismiss | 横幅 + 错误触感；保存失败**不关编辑页**、改动留在表单；删除失败待办保留 |
| 15 | `Assistant/Features/VoiceMemoListView.swift` | 1 | 录音结束保存 → guard 后才 `Haptic.success()` + 自动转写 + dismiss | 横幅 + 错误触感；**不自动转写、不 dismiss**（用户可再试；录音文件已生成，见 §4 风险） |
| 16 | `Assistant/Features/TodoListView.swift` | 1 | 置顶排序 → guard 后才 `Haptic.success()` | 横幅 + 错误触感；排序不播出成功触感 |
| 17 | `Assistant/Features/TodoImportPreviewSheet.swift` | 1 | 批量导入待办 → **通知后置**：先收集 `importedItems` → guard 成功后才逐条 `scheduleNotification` → 成功触感 + `onCompletion` + dismiss | 横幅 + 错误触感；`isImporting` 复位；失败时**不产生任何通知**、不回调、不关页 |
| 18 | `Assistant/Features/Todo/AddTodoSheet.swift` | 1 | 新建待办（含出行配套票务）→ **通知后置**：主待办通知、`TripArrivalService.syncReminder`、配套票务通知全部移到 guard 成功之后（到站信息仍先写进对象再 save） | 横幅 + 错误触感；失败时**不留幽灵通知/到站提醒**、不 dismiss、表单留在页内 |
| 19 | `Assistant/Features/TodayBriefingView.swift` | 1 | 简报完成待办 → guard 后才 `Haptic.success()` | 横幅 + 错误触感；待办保持未完成（`markAsCompleted` 的内存改动被 rollback） |
| 20 | `Assistant/Features/SkillPathListView.swift` | 1 | 练习打卡 → guard 后才 `SkillPathManager.refresh` + 小组件快照刷新 + 成功触感 | 横幅 + 错误触感；失败时按钮仍是未完成态、不刷快照 |
| 21 | `Assistant/Features/Share/UniversalImportPreviewSheet.swift` | 1 | 面对面导入（待办 / AA / 代取 / 物品）→ **通知与实时活动后置**：先收集 → guard 成功后才 `scheduleNotification`、`startPickupActivity`、快照刷新、成功触感、dismiss、`onCompletion` | 横幅 + 错误触感；`isProcessing` 复位；失败时**无幽灵通知、无幽灵实时活动**、不关页 |
| 22 | `Assistant/Features/ReminderCenterView.swift` | 1 | 提醒中心「完成」→ guard 后才 `Haptic.success()` | 横幅 + 错误触感；`markAsCompleted` 的内存改动被 rollback，提醒不消失 |
| 23 | `Assistant/Features/QRCodeScannerView.swift` | 1 | 相册扫码识别导入待办 → **通知后置**：guard 成功后才 `scheduleNotification` → 成功触感 + dismiss | 横幅 + 错误触感；失败时无幽灵通知、不 dismiss |
| 24 | `Assistant/Features/PetRecordsView.swift` | 1 | 添加宠物记录 → guard 后才成功触感 + dismiss | 横幅 + 错误触感；表单留页可重试 |
| 25 | `Assistant/Features/Omnibox/OmniboxView.swift` | 1 | 归档决策「关联待办到人生大事」→ guard 后才快照刷新 + 成功触感 + `archiveHint` 成功文案 | 横幅 + 错误触感；失败时**不显示「已关联 N 条」** |
| 26 | `Assistant/Features/IDDocumentVaultView.swift` | 1 | 保存证件 → guard 后才 dismiss | 横幅 + 错误触感；表单留页可重试 |
| 27 | `Assistant/Features/CompletedTodoHistoryView.swift` | 1 | 清空已完成 → guard 后才 `Haptic.warning()` | 横幅 + 错误触感；列表不显示「已清空」 |
| 28 | `Assistant/Features/AnniversaryManagementView.swift` | 1 | 添加纪念日 → guard 后才 dismiss | 横幅 + 错误触感；表单留页可重试 |

## 2. 特殊写法 / 需要 Lead 重点复核的站点

1. **`if !saved { } else { }` 而非 guard（2 处）**：`LearnedPlacesView.swift` 坐标校准（原 464 行附近）与 Wi-Fi 关联（原 483 行附近）。
   两者都在 `Task { … }` 闭包里，函数末尾必须执行 `isUpdatingLocation = false`；用 guard 早退会让「正在定位」卡死，所以按任务约定改成 `if context.saveReportingFailure(...) { 成功反馈 } else { Haptic.error() }`，外层流程不变。
2. **返回值语义变化（3 处，均在 `MedicineReminderSupport.swift`）**，调用方在 Lead 的文件里，需复核文案：
   - `takeOneDose(...) -> String`：失败返回 `"服药记录保存失败，请重试"`（调用方是 `ItemStorageVaultView` 的批次行/左滑「吃1次」，会显示成「药品名：服药记录保存失败，请重试」——语义正确）。
   - `disposeAndCreateRestockTodo(...) -> Int`：失败返回 `0`。调用方 `ItemStorageVaultView` 有两处：一处 `_ =` 忽略返回值后**无条件** `showFeedback("已标记处理…并加入买药待办")`，另一处用 count 拼「已清理 N 种」。**若该文件仍按原样显示成功文案，需 Lead 在调用点补一次返回值判断**（我没有改这 4 个文件）。
   - `stopReminder(...) -> Bool`：失败返回 `false`（原恒 `return true`）。本文件内唯一调用点已改成 `guard stopReminder(...) else { return }`（失败不 dismiss）；`HabitAndMedicationView` / `ItemStorageVaultView` 里 4 处 `_ = stopReminder(...)` 后仍无条件显示「已停止…」，同样需要 Lead 在调用点补判断。
3. **通知调度后置（4 个文件，共 5 处调度点）**：`QRCodeScannerView`、`TodoImportPreviewSheet`、`Todo/AddTodoSheet`（主待办 + 到站 `syncReminder` + 配套票务）、`Share/UniversalImportPreviewSheet`（待办通知 + 取件实时活动）。
   做法是先把待排对象收集到数组、save 成功后再逐条排；成功路径的调用次数与参数不变。仅 `AddTodoSheet` 用了一个 `pendingArrivalSync` 布尔保持「只在有到站信息时才 sync」的原有语义。
4. **`stopReminder` 顺序调整**：原「先 `cancelMedicationReminders` 再 save」改为「save 成功后 cancel + 重排」，避免 save 失败时提醒已撤、档案还在。

## 3. 本批刻意未动（已有结论/超出 58 处范围，供 Lead 决策）

- **`markAsCompleted` 族（`TodayBriefingView` / `SkillPathListView` / `ReminderCenterView.complete` / `EditTodoSheet` 的完成分支）**：`Models.swift` 的 `markAsCompleted` 会在调用方 save 之前为下一期周期待办排通知（9 个调用点共享）。README §11.5 已明确该行为「失败时最多多一条指向不存在对象的提醒，不会丢数据」，留待批 3 通知预算一起处理；本批只收口其后的用户可见成功反馈，未改该函数。
- `MedicineStockHelper.ensureRestockTodo` 内部在 save 之前 `scheduleNotification`（被 `takeOneDose` / `disposeAndCreateRestockTodo` 调用）：要改需把「创建买药待办」与「排通知」拆开、波及 3 个调用点，属结构性改动，本批未做。
- `ReminderCenterView.snooze`（不在 58 处内）：仍是「排通知 → save」，且已用 `saveReportingFailure` 但未检查返回值；本批未动。
- `EditTodoSheet.saveChanges` 的「完成/撤销完成」通知、日历同步 `Task`：属外部集成/`markAsCompleted` 同族，未动。
- 所有**文案与 UI 布局零改动**；未新增 UserDefaults 键；未动 `scripts/`、`Packages/`、`Assistant/Services/`、`Assistant/Models/`。

## 4. 需要真机/模拟器验证的交互

1. **失败路径不再谎报成功（核心）**：注入落库失败（磁盘满 / 只读库 / 数据库损坏）后逐项验证——只出现顶部红色横幅 + 错误触感，**不出现**「已打卡/已删除/已保存/已记录」等成功文案、不播成功触感、不 dismiss、不新增通知。
2. **表单失败留页 + 重试**：宠物/爱车/人生大事（人物·开销·宾客·任务）/宝贝（建档·成长·里程碑·就诊）/证件/纪念日/续费监控/临期预警/饮食记录编辑/待办编辑。重点确认 **rollback 后重试不会生成重复对象**（rollback 会丢弃 insert，重试即重新 insert）。
3. **待办创建的通知时序**：`AddTodoSheet` 正常保存后，主待办提醒、出行配套票务提醒、到站清点提醒仍按时收到；失败时 Console 不应出现对应通知排期。`TodoImportPreviewSheet` / `QRCodeScannerView` / `UniversalImportPreviewSheet` 同理（含取件实时活动）。
4. **服药打卡/停止提醒**：打卡失败时页面显示失败文案而不是「已记录服用…」；停提醒失败时通知**仍在**（不被撤掉）、档案与提醒一致；成功路径行为与改前一致。
5. **语音备忘**：录音结束保存失败时页面不退出、不自动转写；转写编辑保存失败时仍在编辑态；AI 摘要保存失败仅横幅（`isGeneratingAISummary` 已复位）。**已知风险**：`VoiceMemoListView.finishAndSave` 失败时 rollback 会丢弃 memo，而音频文件已落盘，重试需要重新录音，可能留下孤儿音频文件——本次按「不谎报成功」优先，孤儿清理建议后续单独排期。
6. **地点校准/Wi-Fi 关联失败**：「正在定位」状态必须复位、按钮可再次点击；失败时不得出现「已成功校准/已关联」文案。
7. **`if/else` 两处（LearnedPlacesView）**：失败分支不改变 `updateLocationFeedback` 之外的任何状态，确认不会误清空既有反馈文案。

## 5. 验证命令与结果

```text
# 闸门
$ python3 scripts/check_save_swallow.py
扫描 0 个文件，仍有 0 处 `try? save()`（基线 64 处）
ℹ️  已清理，请下调基线…（预期提示；未改脚本 BASELINE）
exit 0

# 语法（28 个改动文件逐个执行）
$ xcrun swiftc -parse -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -target arm64-apple-ios18.0 <file>
28/28 OK

# Core 回归（Core 未改动，作为环境自检）
$ cd Packages/AssistantCore && swift test --disable-sandbox
Executed 1115 tests, with 0 failures (0 unexpected)

# 未执行：整包 xcodebuild（宿主沙箱拒绝 Swift 宏插件）
# → 请在本机跑 ./scripts/ci.sh 收尾（含 xcodegen + 整包构建 + 视图类型检查）
```
