# 增量优化与工程保障记录（2026-11-06 下午 ~ 2026-11-07）

> 承接 [incremental-2026-11-06.md](incremental-2026-11-06.md) 与 [README.md](README.md) 文首订正 5。
> 范围：报告推送链路审查 → 四轮修复 → 药品入口收敛 → 台账订正与工程保障。
> 每一轮都跑过 `./scripts/ci.sh all`（iOS arm64 真机目标，BUILD SUCCEEDED）与 `./scripts/ci.sh test`（7 道闸门 + AssistantCore 1134 项单测全绿）。

## 一、报告推送：两个 P0 静默丢通知

静态审查「检查一下报告的推送是否正常」的结论是 **日期与周期计算无误，但排期层会静默丢通知**。

| 级别 | 问题 | 处理 |
| --- | --- | --- |
| P0 | `PeriodicReportManager` 用 `getPendingNotificationRequests { …remove… }` 异步清空，紧接着同步 `center.add`；日报/周报是固定 identifier，remove 晚于 add 就会把刚排好的新通知删掉。触发面：10 个 `@AppStorage` didSet、DatePicker 拖动、设置页「完成」、30 分钟前台巡检 | 改成合并串行队列：`await pending` → 构造期望 → 过预算 → 先删 → `try await center.add` 逐条 catch。同步壳保留给 didSet，连续变更合并成一轮，不取消正在写入的任务 |
| P0 | 报告模块完全没接 `NotificationBudget`，`add` 无错误回调；全开会排 25 条远期一次性触发器，叠加其它模块顶满系统 64 条上限后静默失败 | 接 `admit(.report)`；月/季/年报枚举量 12/8/3 → **6/4/2**（全开最多 14 条），靠前台巡检滚动补 |
| P1 | 5 处 `categoryIdentifier = "PERIODIC_REPORT"` 但注册表从未注册该分类 | `NotificationCategoryRegistry` 补注册，锁屏加「查看报告」动作（`L10n.choose` 内联双语，**未改 xcstrings 已有 key**） |
| P1 | 模块不查 `notificationSettings()`、不主动请求授权，日报默认开启却靠待办对账顺带授权 | 自检 `.notDetermined` 主动请求、`.denied` 清残留 |

短月/季末/年末按真实日期枚举一次性触发器、`userInfo` 英文 identifier、`didReceive` 周期透传这些原本就是对的，未改。新增第 7 道闸门 `scripts/check_report_notification_scheduling.py` 钉住这次修复。

## 二、心理提醒同源竞态 + 差量对账

- `PsychReminderScheduler` 与报告模块**完全同源**的回调清空 + 同步 add（且 `AssistantApp:254` 每次进前台无节流调用），闸门初版只扫两个文件恰好放过它。同样改为合并串行 + `NotificationBudget.fingerprint` 差量对账 + `try await add` 逐条 catch。
- 隐私细节：心理提醒**默认关闭**，只有确实要新增通知且授权未定时才请求权限，否则进前台巡检就会为从没开过的功能弹权限框。
- `nextFireDate` 把 `now` 变成真实生效的形参（项目红线：规则函数出现 `now` 必须真的用）。
- `PeriodicReportManager.rebuildReportNotifications()` 由全前缀删加重加改为差量对账；加 `staleIDs.subtracting(rejectedIDs)` —— **被预算拒绝的替换型请求保留旧通知**，避免「旧的删了、新的没排上」。
- `HabitAndMedicationScheduler.cancelMedicationReminders` 的回调清空本身不构成竞态（后面没有 add），改它只为让全仓闸门规则零例外。
- 闸门从「只扫 2 个文件」重写为全模块基线规则，新增 `--self-test`（纯内存反例，3 类违规判红、无误报）与 `--print-baseline`。实测基线 4 文件 / 6 处，留作下一轮精确待办清单。

## 三、通知预算统一接入（涉及 10 个调度器）

- **废除倒挂**：旧 `.external = 5` 是最高优先级且永不裁剪，导致「守规矩走 `admit` 的被裁、绕开预算的占名额」。改为 15 个 identifier 前缀映射到真实业务优先级，未知前缀落最低档 `.ambient`；补齐 `.psych` 等缺失档。
- **抑制名单**：`admit` 每裁掉一条记 30 分钟 TTL，准入时先过滤，掐断「报告裁 todo → 待办差量对账发现缺失 → 立刻加回」的同轮推翻。
- **巡检末尾单点裁决**：四处排期全改 `await …AndWait()`，等全部完成后 `await NotificationBudget.reconcile()` 读一次真实 pending 做最终裁剪；`trigger: nil` 的即时通知不占 64 条名额。`lastReconcile` 用独立快照，不覆盖各模块准入摘要。
- 6 处存量违规清零（`SupportServices` 2、`TripArrivalService` 2、`AnniversaryReminderManager` 1、`LocationReminderService` 1），闸门 `BASELINE` 从 6 降到 `{}`。
- 顺手修 `AnniversaryReminderManager`：原来无论投递成功与否都写「今日已提醒」时间戳，现在只有系统确认接收才落状态。
- **编译坑**：`UNUserNotificationCenter.add` 的 completion 是 `@Sendable`，闭包引用实例属性 `lastNotificationDateKey` 触发 `requires explicit use of 'self'`。改成闭包外提取 Sendable 局部 `let`。`swiftc -parse` 查不出这类并发捕获语义 —— 这是坚持跑完整真机构建的价值。

## 四、药品双入口收敛

用户反馈「运动里面那个药品入口重复」。核对后：

- `HabitAndMedicationView`（原「运动与药物保健品」）1188 → **370 行**：删「药物与保健品」Section、+ 菜单添加按钮、`MedicationRow` / `MedicationEditorSheet` 两套重复 UI，导航标题改「运动」。
- 饮食时效自适应看板抽为自包含 `MedicationTimingCard.swift`，挂到 `ItemStorageVaultView` 药品 Section 顶部，复用该页已有 `@Query medPlans`，判定规则仍走 Core。
- 确认收纳页本来就是完整药品管理（`MedicineItemRow` 打卡/改排期/停用、`MedicineReminderSheet` 创建更新 `MedicationPlan`、`MedicineEditorSheet` 管批次有效期），删运动页那 750 行不丢功能。
- 连带修全局搜索「用药计划」索引路由 `habits` → `storage`，否则收敛后「搜到药却跳到空页」。
- 同步 `ModuleRegistry` 卡片标题、`LifeVaultView` 统计胶囊与摘要、`Localizable.xcstrings` 只新增 1 个 key。

**工具 bug**：`scripts/add-xcstrings-keys.py` 的 `build_entry` 把 `"state" : translated` 写成无引号值，且 `json.loads` 校验发生在写回文件**之后**，一次调用直接把 xcstrings 写坏。已修：state 补引号、缩进改 Xcode 的 4/6/8/10/12 空格、校验前置到落盘前；文件已修回合法内容并确认已有 key 零改动。

## 五、台账订正与工程保障（本轮）

- **README 第三次假账订正**：L-04 记「已删除 `ReceiptScannerView` 整文件 403 行」不实。复核发现更危险的问题——**整文件并非死代码**：`ReceiptScanParser`（`ExpenseTrackerView:2490`）和 `ReceiptCameraView`（`:1917`）仍在使用，照原记录整文件删会编译失败。实际做法：删零引用的 `ReceiptScannerView` 结构体（−334 行），把 3 个活类型抽到 `ReceiptScanSupport.swift`（69 行），`xcodegen` 同步，`check_icon_button_a11y.py` 基线移除该条目（实测 47 → 44 处 / 25 → 23 文件）。
- 台账新增「判死代码纪律」：按类型名只命中一次判定**文件**可删不够，必须查同文件所有顶层类型。
- `scripts/clean.sh`：默认 dry-run 只列体积，`--yes` 才删；白名单仅 `build/` / `DerivedData/` / `.build/`，强制校验仓库根与路径未逃逸，不碰 `.workbuddy/` 与个人目录。
- `.githooks/pre-push` + `scripts/install-hooks.sh`：把已有 7 道闸门 + Core 单测真正自动跑起来，不再靠人记得手动执行；`core.hooksPath=.githooks` 可跟踪，clone 后一键启用。

## 六、验证结果

```
./scripts/ci.sh all   → BUILD SUCCEEDED（iOS arm64 真机目标，llama.framework 正常链接）
./scripts/ci.sh test  → 7 道闸门全绿 + AssistantCore 1134 项 0 失败 + 心理视图类型检查通过
通知排期闸门          → --self-test 3 类违规 + 6 类预算链路变异全部判红，--print-baseline 为空 {}
无障碍闸门            → 44 处存量均在基线内，无新增
沉浸式闸门            → 16 处全屏 / 0 处半屏
git diff --check      → 通过；xcodegen 未改动 project.yml / Assistant.xcodeproj（后者被 .gitignore 忽略）
```

App 层**仍无测试 target**，本地通知只有真机可验。以上除真机构建的类型检查外，通知行为均为静态审查 + 单测 + 日期推导，不是真机 pending 快照。

## 七、仍未做（按优先级）

1. **后台刷新路径未接**：`BackgroundRefreshCoordinator.swift:253` 在 BGTask 里 fire-and-forget 调 `syncAllTodoNotifications` 后紧接着 `setTaskCompleted`，既不等待也不跑 reconcile。需单独一轮加串行等待 + 轻量裁决并真机验 BGTask。
2. 报告推送时间口径：周报周日 21:00 推、周窗口周一 00:00 才结束，推送时本期还差 3 小时；月/季/年报同理在末日 21:00 推。文案「已生成/已出炉」实际是点击后现算。属产品口径决策，未擅自改 xcstrings 已有 key。
3. `removePendingNotificationRequests` 无完成确认，与 `add` 之间仍有理论顺序窗口（与待办/服药现有实现同口径）。
4. 报告指纹 `fetchLimit=30` 且只哈希 id/amount/status，改三个月前旧账不会刷新；`unmatchedHints` 在 App 层零引用。
5. 工程：App 层测试 target、Core 切 Swift 6（`SWIFT_VERSION` 仍 5.0）、版本号恒 0.1.0/build 1、无 GitHub Actions。
6. 台账已登记的 UI 项：分享卡 5 卡 + 10 弹窗统一骨架、待办双表单合并、巨型 body 拆分、`NavigationRouter` 14 个 `@Published` 被整体订阅、固定小字号 82 处、备份附件外置、本地化漏译。
7. 工作树混 4 类语义且有多个 untracked 脚本/组件，**提交前必须按语义拆分**；漏 `git add` 新组件会编译失败，漏闸门脚本会断 CI。

## 八、口径说明（避免下轮重复投入）

- 报告中「已核对无问题」的方向（README 第八节、`ui-findings.md` 末节）不要重复投入。
- 通知排期闸门已覆盖全仓，基线为 `{}`；新增违规会直接判红，不必再人工盘点调度器。
- 药品功能唯一入口是「物品收纳 → 药品与健康储备」；运动页只管周期性运动计划。历史数据若存在「有用药计划但无常备药档案」的孤立 `MedicationPlan`，收纳页不会有对应行可编辑（正常流程都会补档案）。
- 本地化纪律不变：已有 key 文案不可改、不能 `sort_keys`、绝不能 `json.dumps(indent=2)` 全量重序列化；用 `scripts/add-xcstrings-keys.py` 定点插入并做 diff 三查。
