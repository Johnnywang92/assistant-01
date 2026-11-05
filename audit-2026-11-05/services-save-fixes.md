# 批 2 · 服务层落库失败不再谎报成功（SVC-03 / SVC-04 / SVC-05）

> 执行人：services-save-fixer（服务层修复）
> 时间：2026-11-05
> 范围：`Assistant/Services/**/*.swift`（排除 `Persistence.swift`、`Migration/`、`ModelContext+SaveReporting.swift`）
> + `Assistant/Models/LifeReminderActionModel.swift`、`Assistant/Models/LifeEventModels.swift`
> 未改动：`Assistant/Features/`、`scripts/`、`Packages/`

## 0. 结果摘要

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 服务层 `try? context.save()`（闸门口径） | 46 处 / 17 文件 | **0 处** |
| 我负责的模型文件 `try? context.save()` | 3 处 / 2 文件 | **0 处** |
| 全仓 `try? save()`（`check_save_swallow.py`） | 184 处（基线） | 扫描时点 65 处，**全部在 `Assistant/Features/`（Lead 的 UI-01 批）** |
| `check_save_swallow.py` | exit 0 | **exit 0**（只剩「请下调基线」的 ℹ️ 提示，属预期） |
| 改动文件 `swiftc -parse` | — | 20/20 通过 |
| `Packages/AssistantCore` `swift test` | 1115 项全绿 | **1115 项全绿**（环境自检，未改 Core） |

核心原则（本批统一执行）：

1. **成功副作用一律放到 save 成功之后**：成功文案/震动/排通知/`markTodoAdded`/递增计数/推进 UserDefaults 排期/触发 HomeKit。
2. **返回值尽量保持原签名**：返回 `String` 的失败时给失败文案；返回 `Int` 的失败返回 0；返回 `Void` 的用户主动作补返回 `Bool`（`@discardableResult`，旧调用点源码兼容）。
3. **用户可见的失败走 `SaveFailureCenter` 横幅**（Lead 新建的 `Assistant/Features/SaveFailureBanner.swift`）：用于「返回值无法表达失败」或「通知/锁屏动作没有别的回执渠道」的路径；后台/派生路径只记日志。
4. 派生联动（记账 → 饮水/热量等）允许失败，但统一走 `saveLinked` 出口（回滚 + 日志），不再出现 `try?`。

---

## 1. SVC-03：`inbox.txt` 事务化（`SupportServices.swift` · `InboxService.drain`）

| 项 | 旧行为 | 新行为 | 失败时用户看到什么 |
| --- | --- | --- | --- |
| 读取 | 在 `.forReplacing` 协调块里读原文，**同一块内立即把文件覆盖成空** | 后台只读协调块读取，**不清空** | — |
| 逐条导入 | `try? service.ingest`，任一失败条目被静默丢弃 | 逐条 `do/catch`；失败条目回滚本条未提交的 insert，**原文保留在文件** | 无弹窗（后台补录）；日志 `⚠️ [Inbox] 条目落库失败…` |
| 消费判定 | 文件已清空 = 全部算消费 | `skippedDuplicate` 也视为「已消费」（否则会无限重试）；只有成功消费的原文才移除 | — |
| 写回 | 先清空（不可逆） | 写回前**重读当前文件**，按「本次消费掉的原文」逐段删除；快捷指令在读取后新追加的条目原样保留 | 写回文件失败：原文仍在文件，下次重试；重复导入由 `ImportService` 原文去重兜底（用户无重复数据） |
| 返回值 | 已导入条数（失败条目也计 0，无信号） | 新导入条数；失败条目下次重试 | 快捷指令回执里的条数只统计真正入库的 |

验证方式：`swiftc -parse` 通过；静态检查 `InboxService.drain` 内不再有 `try? service.ingest`、`removeConsumedEntries` 写失败只记日志不当作消费；闸门扫描该文件 0 处 `try? save()`。运行时注入建议：把 `ImportService` 的 save 打桩抛错，断言 ① 文件保留失败条目原文；② 返回计数只含成功条目；③ 复制文件后再次 drain 能重试失败条目。

---

## 2. SVC-05：`confirmAndInsertTicketTodos` 标记顺序（`TravelTicketReminderManager.swift`）

| 项 | 旧行为 | 新行为 | 失败时用户看到什么 |
| --- | --- | --- | --- |
| 顺序 | insert → `scheduleNotification` → `try? save()` → 无条件 `markTodoAdded` → `activeUpcomingTicket = nil` | insert（只收集对象）→ **save** → 成功后才 `scheduleNotification` + `markTodoAdded` + 清 `activeUpcomingTicket` | 失败不排通知、不写 UserDefaults 标记，因此**本出行周期仍会继续提醒** |
| 失败语义 | 永久标记「已加入」+ 残留指向不存在待办的通知 | 回滚 + 日志 + 横幅「加入出行待办失败：…」+ **返回 0** | 顶部横幅（`count == 0` 需要视图配合，见 §5） |

验证方式：`swiftc -parse`；静态检查 `markTodoAdded` 只在 `guard saved` 之后调用；闸门该文件 0 处 `try? save()`。运行时注入 save 失败：断言返回 0、`isTodoAdded` 仍为 false、无通知注册。

---

## 3. SVC-04：写库链路逐文件清单

> 「失败时用户看到什么」= 注入 save 抛错后的用户可见结果；标「日志」的是后台/派生路径（无 UI 渠道）。

| 文件（处数） | 原行为 | 新行为 | 失败时用户看到什么 | 验证方式 |
| --- | --- | --- | --- | --- |
| `VoiceIntentProcessor.swift`（3） | `insert` → 先 `scheduleNotification` → `try? save()` → 照样回「已记下/已记入 N 笔」并算今天/本月累计 | 先 `saveReportingFailure`；失败即返回失败文案；成功后排通知、再算累计并给成功文案 | 语音/文本回执：「抱歉，待办保存失败，请再试一次。」「抱歉，这笔账保存失败，请再试一次。」；**不再产生指向不存在待办的通知** | parse；3 处闸门清零；静态检查 `scheduleNotification` 在 guard 之后 |
| `TaskPlanningEngine.swift`（1） | 边 insert 边排通知 → `try? save()` → `Haptic.success()` + 返回条数 | 收集对象 → 一次 save → 成功后排通知 + `Haptic.success()`；失败返回 0 不震动 | 服务层返回 0；视图需按 0 提示失败（见 §5） | parse；静态检查返回 `inserted.count` |
| `TodoNotificationManager.swift`（4） | 通知 action「完成/推迟 10m/1h/明早」：`try? save()` 后照样播成功震动（锁屏动作无任何失败回执） | 新增 `saveAction`：失败回滚 + 日志 + **顶部横幅**；成功才排新通知、才播 success/light，失败播 `Haptic.error()` | 顶部横幅「更新待办失败：…」+ 失败震动（App 前台时） | parse；4 处清零；静态检查三个 snooze 分支 `scheduleNotification` 在 `saved` 之后 |
| `SkillPathManager.swift`（3） | `save`：`try? save()` + 无条件 `Haptic.success()`；`refreshAll`/`refresh(path:)` 静默吞错 | `save`：先 save，成功后才排第 0 阶段通知 + `Haptic.success()`；失败返回**未插入占位对象** + `lastSaveFailureMessage` + 横幅。两处后台重算改为回滚 + 日志 + 成功后才排新阶段通知 | 顶部横幅「创建学习路径失败：…」；`lastSaveFailureMessage` 供视图判断（见 §5） | parse；3 处清零；`materialize` 改为返回新建待办、由调用方在 save 后统一排期 |
| `WidgetSnapshotSync.swift`（6 App hook） | 6 个 AppIntent hook 各自 `try? context.save()` 后照常回执/刷新快照；command 队列路径也是先排通知后 save | 新增 `saveHook` 统一出口（失败回滚 + 日志，`Void` hook 额外走横幅）；snooze/quickAddTodo 改为**先 save、成功后再排通知**；命令队列改为 `commit` 成功后才统一 `scheduleDeferredNotifications` | 完成/推迟/出门清点：顶部横幅；快捷记账/加待办：返回失败文案「记账失败，请稍后重试」/「待办保存失败，请稍后重试」 | parse；6 处清零；`apply(... deferredNotifications:)` + `commit` 顺序静态核对 |
| `TripArrivalService.swift`（3） | `evaluate`：先 `fire()`（发即时通知）再 `try? save()`；两个锁屏 action（再提醒/开始清点）先排通知/推灵动岛再 `try? save()` | `evaluate`：只改内存并收集待发提醒，save 成功后才 `postFireNotification`；锁屏 action 先 save，失败直接 return（不重排通知、不推灵动岛）并走横幅 | 顶部横幅「再提醒/开始清点失败：…」；本轮不发指向未落库状态的提醒 | parse；3 处清零；`fire` 拆成 `postFireNotification`（纯投递） |
| `PickupCheckoutService.swift`（1） | `markDone` 里先 `await` 灵动岛/撤销通知/地理围栏，最后 `try? save()`；失败时会话已推进、通知已撤 | 只改模型（`markDoneInDB`）→ save → 成功后才推进 session/收岛/撤提醒/同步围栏；失败横幅 + 保留会话与通知待重试 | 顶部横幅「取件销号失败：…」；通知与灵动岛保持可用 | parse；1 处清零；静态检查 `session = current` 在 save 之后 |
| `RecurringExpenseManager.swift`（2） | `recordNow`：先 `saveItems()` 推进 UserDefaults 排期再 `try? save()` + 无条件 `Haptic.success()`；巡检：先 `NotificationService.post` 再 `try? save()` | `recordNow`：save → 成功才推进排期 + haptic；失败 `lastSaveFailureMessage` + 横幅。巡检：save → 成功才 `saveItems()` + 发「已自动记账」通知；失败把内存 `items` 恢复到本轮之前 | 顶部横幅「记入固定支出/周期支出自动记账失败：…」；`lastSaveFailureMessage`（@Published）供视图判断 | parse；2 处清零 |
| `PlaceLearningEngine.swift`（2） | `refreshAndDeduplicateAllPlaces` 空 `catch` 静默；地名补全 `try? save()` | 空 catch 改为回滚 + 日志；补全 save 改 `saveReportingFailure` + 日志 | 仅日志（后台重算，下次回前台再算） | parse；2 处清零 |
| `HabitAndMedicationScheduler.swift`（2） | 周期家务：边插边排通知 + 触发 HomeKit + post 通知，最后 `try? save()`；服药待办物化 `try? save()` | 周期家务：收集对象 → save → 成功后才排通知/触发 HomeKit/post；失败本轮不产生任何副作用。服药待办：回滚 + 日志（下次巡检重建） | 仅日志（后台巡检） | parse；2 处清零 |
| `BatteryReminderService.swift`（2） | `upsertChargingTodo`/`resolveChargingTodo` 内 `try? save()`；低电量通知在 upsert 之后但失败也照样发 | `upsertChargingTodo` 返回 Bool，save 成功才发低电量通知；失败返回 `nil`（本轮不产出提醒）。`resolveChargingTodo` 回滚 + 日志 | 低电量：不发通知 = 不谎报「已建提醒」；充电后自动完成：仅日志 | parse；2 处清零 |
| `DailyPainPointAuditor.swift`（1） | 巡检过程中先 `postThrottledNotification`（含写限频标记），最后 `try? save()` | 提醒先进入待发队列；save 成功才 flush（限频标记也延后写）；失败丢弃本轮队列（下次巡检重来） | 不会收到「已生成提醒」但待办不存在的通知 | parse；1 处清零 |
| `AnniversaryReminderManager.swift`（1） | 先排 3 条通知 → `try? save()` → 无条件写 `prepAddedKey` + `Haptic.success()` | 先 save，成功才排通知 / 写年度标记 / haptic；失败 `return false` + 横幅；签名 `Void → Bool`（`@discardableResult`） | 顶部横幅「生成纪念日筹备待办失败：…」；年度标记不写，**下次仍会提示** | parse；1 处清零 |
| `LLMInferenceService.swift`（2） | `executeSideEffectIfNeeded` 两处收尾 `try? save()`（理解留痕 / 事务记录+撤销令牌） | 改 `do/catch` + 日志；执行事务留痕失败时在语音回执里补一句「（本次执行的记录保存失败，可能无法在历史里一键撤销）」 | 回执如实说明（动作本身已在 OmniboxExecutor 内落库） | parse；2 处清零 |
| `LifeReminderActionModel.swift`（2） | `complete`/`snooze` 派生状态 `try? save()` | 返回 Bool + 回滚 + 日志 + 横幅；签名 `Void → Bool`（`@discardableResult`） | 顶部横幅「完成/推迟提醒失败：…」 | parse；2 处清零 |
| `LifeEventModels.swift`（1） | `LifeEventTemplateFactory.createProject`：`try? save()` 后返回 project，视图照常 `Haptic.success()`/关闭 sheet | 先 save；失败返回**未插入占位对象**（签名不变，避免返回回滚后失效的 @Model）+ `lastSaveFailureMessage` + 横幅 | 顶部横幅「创建人生大事项目失败：…」；视图需按 flag 处理（见 §5） | parse；1 处清零 |

---

## 4. 仍保留的「允许失败的派生路径」及理由

这些路径失败**不阻断主流程**（主数据已由调用方落库 / 属于后台巡检派生数据），但已全部去掉 `try?`，统一「回滚 + 日志（+ 部分横幅）」，失败可观测：

| 路径 | 为什么允许失败 | 失败后的补偿 |
| --- | --- | --- |
| `ExpenseWaterService`（6 处改为 `saveLinked`） | 记账 → 饮水是**派生联动**，主账单已由 Feature 层先 `save`；饮水记录缺失不影响账本正确性 | 下次编辑同一账单会重建；新建联动失败时**跳过 HealthKit 写入**，避免健康数据出现无来源的孤立记录；日志 `⚠️ [ExpenseWater]` |
| `ExpenseCalorieService`（6 处改为 `saveLinked`） | 同上（记账 → 热量是「建议/派生」链路，且热量本就要用户确认） | 失败保留 `pending` 建议让用户重试；下次编辑重建；日志 `⚠️ [ExpenseCalorie]` |
| `PlaceLearningEngine` 地点合并/角色重算/地名补全 | 后台地点学习是尽力而为的启发式数据，失败不影响待办/账本 | 下次回前台/巡检重算；日志 |
| `HabitAndMedicationScheduler` 服药待办按天物化 | 依赖系统通知与按天巡检，漏一天由下次巡检补建；不阻断首页其它功能 | 下次巡检重建；日志 |
| `HabitAndMedicationScheduler` 周期家务 | 同上（periodic habit 巡检派生） | 下轮巡检重建；日志 |
| `DailyPainPointAuditor` 巡检 | 后台/每日巡检派生提醒；失败下轮重来 | 丢弃本轮提醒队列，下轮重发；日志 |
| `BatteryReminderService.resolveChargingTodo`（充电后自动完成） | 电量变化是连续事件，下次检查会再判一次 | 下次电量检查重试；日志 |
| `InboxService.removeConsumedEntries` 写回文件失败 | 落库已成功、只是文件清理失败，属于**清理**而非消费判定 | 原文仍在文件，下次 drain 重试；`ImportService` 原文去重保证不重复入库；日志 |
| `LifeReminderAction` 提醒卡片状态 | 提醒实例完成/推迟只是提醒中心卡片的展示状态，主档案另有落库 | 日志 + 横幅；下次打开提醒中心可重试 |

**未纳入允许失败、必须成功的路径**：所有「用户主动作」——语音记账/记待办、一键加入规划/出行/纪念日待办、锁屏通知动作、取件销号、快捷记账/加待办、创建学习路径/人生大事项目。这些失败要么给失败文案、要么给 0/false、要么弹横幅。

---

## 5. 需要 Lead 复核的判断（视图层配合，均在 `Assistant/Features/`，我未改动）

返回值语义变化（服务层已保证成功路径不变，失败路径语义为新增）：

1. `TaskPlanningEngine.savePlanToTodos(...) -> Int`：失败现在返回 **0**（原为 selected.count）。
   - 需要改：`VoiceDialogueView.swift:751`（`handleSavePlan`）——`count == 0` 时不要 append「🎉 已成功为你将 0 项…」、不要 `p.isSaved = true`、不要语音播报成功。
2. `TravelTicketReminderManager.confirmAndInsertTicketTodos(...) -> Int`：失败现在返回 **0**。
   - 需要改：`TravelTicketConfirmationSheet.swift:494-503`（`confirmSelection`）——`count == 0` 时不要 `UIImpactFeedbackGenerator(.medium)` / 不调 `onConfirm?(count)`；`TodoListView.swift:419-421` 的 toast 需从「已确认添加 0 项」改成失败提示。
3. `WidgetSnapshotSyncController.handleQuickAddExpense/handleQuickAddTodo -> String?`：失败返回失败文案「记账失败，请稍后重试」/「待办保存失败，请稍后重试」。回调方不要再把返回文案当成功播报。
4. `AnniversaryReminderManager.addPreparationTodos(...) -> Bool`（原 Void，`@discardableResult`）：失败返回 false。
   - 需要改：`TodoListView.swift:1425-1426`——`false` 时不要 `showToast("已一键将…加入待办！🎉")`（服务层已弹横幅，视图再弹成功会自相矛盾）。
5. `LifeReminderActionStore.complete/snooze(...) -> Bool`（原 Void，`@discardableResult`）：失败返回 false。
   - 需要改：`ReminderCenterView.swift:75-81`——`false` 时不要 `Haptic.success()`/`Haptic.light()`。
6. **`SkillPathManager.save(...) -> SkillPath`（签名未变，失败时返回「未插入的占位对象」）**：为了不改签名（会波及两处视图调用），失败信息放在 `SkillPathManager.shared.lastSaveFailureMessage`，并已弹横幅。
   - 需要改：`SkillPathListView.swift:381-389`、`VoiceDialogueView.swift:771-784`——`save` 后先判断 `lastSaveFailureMessage != nil`，失败则提示并 `return`，不要 `refreshSnapshot`/`dismiss`/播报「已开启学习路径」。
   - **建议**：视图层修完后可把返回改成 `SkillPath?`（更干净），届时我可同步调整服务层签名。
7. **`LifeEventTemplateFactory.createProject(...) -> LifeEventProject`（签名未变，失败时返回「未插入的占位对象」）**：失败信息在 `LifeEventTemplateFactory.lastSaveFailureMessage`，并已弹横幅。
   - 需要改：`LifeEventManagementView.swift:323`（`saveAction`）——失败时不要 `Haptic.success()`/`dismiss()`/`onSave?(project)`（占位对象不在 context 里，后续详情页查不到阶段/任务）。
   - **建议**：视图层修完后可把返回改成 `LifeEventProject?`。
8. `RecurringExpenseManager.lastSaveFailureMessage`（新增 `@Published`）：`recordNow` 失败时非 nil。
   - 需要改：`ExpenseTrackerView.swift:1418`——`recordNow` 后不要无条件 `Haptic.success()`，改读 `recurringManager.lastSaveFailureMessage`。
9. **服务层新增对 `SaveFailureCenter` 的依赖**（`Assistant/Features/SaveFailureBanner.swift`，14 处 / 11 文件）：`TravelTicketReminderManager`、`WidgetSnapshotSync`、`TodoNotificationManager`、`RecurringExpenseManager`、`TripArrivalService`、`SkillPathManager`、`TaskPlanningEngine`、`AnniversaryReminderManager`、`PickupCheckoutService`、`LifeReminderActionModel`、`LifeEventModels`。若该文件改名/改 API，请同步这 14 处；若不想 Services 依赖 Features 文件，我可以改成注入的 `SaveFailureReporting` 协议。
10. **范围外的遗留（建议 Lead 决定是否本批处理）**：`Assistant/Models/Models.swift:420` `markAsCompleted(in:)` 会在内部为新一期周期待办**先 `scheduleNotification`**，调用方的 `save` 在其后；这与本批「先落库后排通知」原则相反，但 `Models.swift` 不在我的可改范围。

---

## 6. 验证记录（本轮实际执行）

```bash
# 1) 闸门：exit 0，服务层/模型层 0 处，剩余 65 处均在 Features（Lead 批次）
python3 scripts/check_save_swallow.py
# → 扫描 29 个文件，仍有 65 处 `try? save()`（基线 184 处）；exit 0

# 2) 20 个改动文件逐个语法检查
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
for f in <20 files>; do xcrun swiftc -parse -sdk "$SDK" -target arm64-apple-ios18.0 "$f"; done
# → ALL 20 FILES PARSE OK

# 3) Core 包环境自检（未改 Core）
cd Packages/AssistantCore && swift test --disable-sandbox
# → Executed 1115 tests, with 0 failures

# 4) 关键 Swift 模式类型检查（-typecheck 迷你探针，验证 saveReportingFailure 调用形式、
#    `if case ... , let ..., saveHook()`、@MainActor 静态失败标记、Task { @MainActor in } 捕获 Error 等）
# → 全部通过（沙箱不能整包 xcodebuild，故用探针覆盖类型层面风险）
```

补充说明：`try? context.fetch(...)` 等**读路径**的 `try?` 属于另一类问题（回退成空数组 vs 报错），不在本批范围；`check_save_swallow.py` 也只统计 `save()`。
