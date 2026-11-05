# 批 3 性能修复：前台巡检节流 / 服药提醒差量对账 / 通知预算

日期：2026-11-05
对应审计：`services-findings.md` SVC-08、SVC-06（通知 64 条总账）
范围：只改通知与前台巡检相关文件（见下表），未触碰 Features / Models / Migration / Persistence / scripts / Packages。

| 文件 | 改动 |
| --- | --- |
| `Assistant/Services/BackgroundRefreshCoordinator.swift` | 新增 `ForegroundAuditCadence` 分级节流；`performIdempotentAudits` 拆「每次 / 节流」两档 |
| `Assistant/App/AssistantApp.swift` | `ForegroundAuditCoordinator` 接入节流 + 分片 `Task.yield()`（仅巡检段落） |
| `Assistant/Services/SleepReminderScheduler.swift` | 28 夜 HealthKit 样本 10 分钟内存缓存，冷启动必拉一次 |
| `Assistant/Services/HabitAndMedicationScheduler.swift` | 服药提醒全删全加 → 差量对账 + `add` 失败可观测 |
| `Assistant/Services/TodoNotificationManager.swift` | 待办通知全量重排 → 差量对账 + 接入预算；抽出纯构造器 |
| `Assistant/Services/NotificationBudget.swift`（新建） | 统一通知预算入口：优先级 + 64 条上限裁剪 + 可观测快照 |

**验证结果**

- 6 个改动/新增 Swift 文件逐个 `swiftc -parse`（iphoneos SDK / arm64 / iOS 18 target）通过。
- `NotificationBudget.swift` 额外用 `swiftc -typecheck` 整文件通过（该文件不依赖 App 其它类型，可独立类型检查）。
- 预算决策逻辑用一次性独立 harness（`NotificationBudget.swift` + 断言 main）在开发机跑过 8 组用例：指纹相等/变化、高优先级裁低优先级、同优先级不互抢、external 永不裁剪、逾期补提醒先裁、同 identifier 替换不重复占额、存量超限全局裁剪、主提醒挤掉逾期补提醒 —— 全部 PASS（harness 不提交，避免扩大改动面）。
- `python3 scripts/check_save_swallow.py` exit 0：仍是 64 处，未新增 `try? save()`。
- `python3 scripts/check_settings_keys.py` exit 0：**没有新增任何 UserDefaults 偏好键**（节流时间戳放运行态缓存文件，见 §1）。
- `cd Packages/AssistantCore && swift test --disable-sandbox`：**1116 tests / 0 failures**，exit 0（本批未改 Core；基线 1115 → 1116 是并发批次在同一工作树新增了 1 项 Core 测试，非本文件改动。以 `scripts/ci.sh test` 全绿为准）。
- `xcodegen generate` 已执行，新文件进入工程（`Assistant.xcodeproj` 被 `.gitignore` 忽略，属生成物）。

---

## 1. SVC-08-A · 前台巡检分级 + 时间戳节流

**位置**
- `Assistant/Services/BackgroundRefreshCoordinator.swift:21`（`ForegroundAuditCadence`）
- `Assistant/Services/BackgroundRefreshCoordinator.swift:270`（`performIdempotentAudits`）
- `Assistant/App/AssistantApp.swift:171`（`ForegroundAuditCoordinator` 巡检流水线）

**原成本**（每次 App 回到 `.active`，全部串行在 MainActor）
1. 收件箱补录 `InboxService.drain`（文件 I/O + 逐条 ingest）
2. `DailyPainPointAuditor.auditAll()`：**9 个全表 / 全谓词 fetch**（续费、证件临期、纪念日、订阅、票务……）
3. 周期支出入账 + 预算预警
4. 分享扩展中转区排空
5. 到站/落地提醒对账 + 运动证据评估
6. WebDAV 静默加密备份探测（Keychain + 配置 + 网络前置检查）
7. 天气评估（WeatherKit 网络请求）
8. 28 夜 HealthKit 睡眠样本拉取（见 §2）
9. 13 个 HealthKit 今日指标查询
10. 对话记录超期清理（fetch + 批量删除）
11. 定期报告通知排期
12. 待办通知全量重排（15 项 × 最多 4 条，见 §5）
13. 服药提醒全删全加（见 §3）
14. 单次 GPS 采样 + 第二次天气评估

没有任何「上次执行时间」判断：前台切来切去 = 重活反复全量跑，且随数据量线性恶化（审计 SVC-08 确认）。

**新成本（分级）**

| 档 | 项目 | 间隔 / 依据 |
| --- | --- | --- |
| **每次** | 收件箱补录、分享扩展排空、小组件/手表指令对账 | 用户输入与跨进程操作不能滞留；成本小且与交互直接相关 |
| **每次** | 周期支出入账 + 预算预警 | 与钱有关，且是幂等谓词查询，成本低 |
| **每次** | 到站/落地清点对账 | 到站窗口是分钟级，延后即失去意义 |
| **每次** | 服药提醒对账（已差量）、当天服药待办物化 | 当天必须生效；对账本身已降到常数级 XPC |
| **10 分钟** | `dailyAudit`：`DailyPainPointAuditor.auditAll()` | 9 个全表审计，但事件本质是天级的（续费/证件临期），10 分钟内数据不会变 |
| **15 分钟** | `healthToday`：`HealthKitService.refreshToday()` | 13 个 HK 查询，指标分钟级变化，15 分钟足够新鲜 |
| **15 分钟** | `weatherCached` / `weatherLocated` | WeatherKit 是网络请求；突降温告警需要一定时效，两条路径分开计时（后台缓存路径与前台 GPS 路径互不吞并） |
| **30 分钟** | `webdav`：静默后台加密备份 | 是否真备份由服务内部「上次备份时间」决定，这里只削掉重复探测 |
| **30 分钟** | `reportNotifications`：定期报告通知排期 | 报告触发按天/周/月，30 分钟足以对账 |
| **60 分钟** | `dialogueCleanup`：对话超期清理 | 保留期是 7 天/30 天，小时级足够 |

**行为变化**
- 重活**只延后，不永久跳过**：时间戳只在任务真正执行完之后写入（`markRun`），下一次 `.active` 或 4 小时后的 `BGAppRefreshTask` 间隔到了自然执行。时间戳持久化到 `Caches/foreground-audit-cadence.json`（运行态缓存，进程重启后仍有效；不进备份、不占偏好键闸门额度）。**没有**改成后台线程，也没有把 `ModelContext` 带出主 actor。
- 节流日志：`⏳ [ForegroundAudit] 节流跳过 <step>：距上次 Xm < 最小间隔 Ym`，真机 Console 可直接分辨「节流」与「漏跑」。
- 每个重活之间插入 `await Task.yield()`，把主线程让给渲染/交互一次（不改变执行顺序）。
- 新增 `setThrottlingEnabled(_:)` / `setIntervalOverride(_:for:)` 两个内部调试入口（当前无 UI 调用），便于真机 A/B。

**退化时表现**
- 状态文件丢失 / 损坏 / 被系统清理 → 视为「全部到期」，退化成修复前行为（全量跑一次），不会永久不跑。
- 状态写入失败 → 只丢节流记忆（下次多跑一次），打印一条警告，不影响巡检本身。
- 任务执行中被取消（用户快速切后台又回来）→ 不记账，下一轮重新执行。
- 天气/健康数据查询失败：与原实现一致（各自服务内部保留旧快照或记录错误）。

**验证方式（真机）**
- Console 过滤 `[ForegroundAudit]`：1 分钟内连续两次切前台，第二次应出现 `dailyAudit` / `healthToday` / `webdav` 等「节流跳过」；间隔超过阈值后再次切前台应实际执行且无该日志。
- `StartupMetrics` 的 `audit.*` 节点（`subsystem=assistant.startup`）：对比修复前后 `audit.dailyAudit` / `audit.healthToday` / `audit.sleepReminders` 的出现频率与耗时。
- 删除 `Caches/foreground-audit-cadence.json`（或改系统时间/间隔）验证「到期必跑」。
- 冷启动一次 + 从后台回来一次，确认每次都有便宜项执行、重活按间隔执行。

---

## 2. SVC-08-B · 28 夜睡眠样本缓存（SleepReminderScheduler）

**位置**：`Assistant/Services/SleepReminderScheduler.swift:290`（`sleepSamples(nightKey:now:calendar:)`），调用点 `:186`（`syncSleepReminders`）。

**原成本**：每次回前台 `HealthKitService.fetchSleepNights(days: 28)` 跨 28 夜取全部睡眠样本，再在主 actor 上按夜归一分组；随后才计算 3 夜计划。前台切换频繁的用户会反复做同一次全量查询。

**新成本**：进程内缓存 + 10 分钟有效期（`sleepSampleRefreshSeconds = 10 * 60`，依据：睡眠债/习惯中位数以「夜」为单位变化）。缓存键 = 夜归属日（`upcomingNightKey`，跨日自动失效）+ 拉取时间；命中时 0 次 HealthKit 查询。冷启动缓存为空，必然拉一次。

**行为变化**
- 每个前台周期仍会重算 3 夜计划、刷新卡片、查 delivered、重排通知（这些是便宜且需要及时性的）；**只有 28 夜样本查询被缓存**。
- 夜间进前台「精修」照旧，只是修正项基于最多 10 分钟前的样本（睡眠债不会在 10 分钟里变）。
- 拉取结果为空（HealthKit 抖动/确实无数据）时：有旧缓存则继续沿用旧样本（避免把睡眠债误判为 0）；空结果也按有效期节流，避免无数据用户每次前台都打 HealthKit。

**退化时表现**：HealthKit 持续失败 → 与修复前一样退化为快照/默认节律，最多多打一条「沿用 N 夜缓存」日志。样本是纯内存值，不落盘，所以冷启动一定重新拉（不存在「持久化时间戳导致没样本可用」的坑）。

**验证方式（真机）**：Instruments Time Profiler / HealthKit 查询计数 —— 修复前每次前台 1 次 28 夜 category 查询，修复后同一前台周期内 ≤ 1 次/10 分钟；Console 观察上述警告日志；确认「今晚睡眠」卡片仍随当天饮食/运动/天气变化。

---

## 3. SVC-06 · 服药提醒差量对账

**位置**：`Assistant/Services/HabitAndMedicationScheduler.swift:108`（`scheduleMedicationReminders`）→ `:144`（`reconcileMedicationReminders`）、`:195`（`makeMedicationRequest`）、`:8`（`MedicationReminderEntry` 纯值快照）。

**原成本**：每次回前台 `getPendingNotificationRequests` → 删除**所有** `med-` 前缀 → 逐条重新 `add`（无 completion）。N = 启用计划数 × 每日时点数：每次 1 + N 次删除/新增 XPC；且存在「已全删、尚未重加完」的真实窗口。

**新成本**：期望集合 vs 现有待处理差量对账。
- 期望集合按 `identifier = med-<planId>-<HH>-<mm>` 生成；对已存在的同 identifier 用内容指纹比较（title / subtitle / body / category / thread / userInfo / 日历触发时分 / repeats）。
- 只删除「不在期望集合」或「指纹变化」的旧通知；只 `add`「缺失或变化」的。
- 正常路径（无计划变更、时间点未变）：1 次 `pendingNotificationRequests()` + 0 次删除 + 0 次 `add`。
- `add` 改为 `try await center.add(request)`，失败带 identifier 打日志；预算拒绝也有日志。
- 服药是通知预算最高优先级：名额不足时由 `NotificationBudget` 裁剪更低优先级的模块（见 §4），不会为了给别的模块腾地方删服药提醒。

**行为变化**
- 消除「全删 → 重加」窗口：正常前台对账不再触碰已在系统里的服药提醒，进程在任意时刻被挂起都不会出现「当天服药提醒全没了」。
- 停用/删除计划：旧 identifier 不在期望集合 → 被精准删除（保留原有清理语义）。
- 修改剂量/备注/时点：只重排受影响的那几条。
- 文案、触发时刻（`UNCalendarNotificationTrigger` 每日重复）、`interruptionLevel`、`userInfo` 与原实现逐字段一致。
- 调用方 API 不变（仍是同步 `scheduleMedicationReminders()`），内部发起主 actor 上的 async 对账；取数仍用主 actor 的 `ModelContext`，只把 `Sendable` 值快照（`MedicationReminderEntry`）传进 async 函数。

**退化时表现**
- 若系统读回的 trigger 与本地构造的 `dateComponents` 表示不同（例如系统补 timeZone 字段），指纹会不等 → 该条每轮被删加一次：**正确性不受影响**，只是退回接近旧实现的 XPC 量；Console 可见重复排期日志，据此判断是否要把指纹放宽。
- `pendingNotificationRequests()` 失败/超时（async 抛错前该 API 不抛，只可能拿不到完整列表）：最坏情况是「该删的没删」或「该加的下轮再补」，下一轮前台对账会收敛；不会先删后挂。
- 预算拒绝：打印「预算不足，本轮未排期，下次前台对账重试」；服药优先级最高，只有在 external（未接入模块）占满时才会拒绝。

**验证方式（真机）**
- 建 2 个服药计划 × 3 个时点 + 15 条待办提醒，连续切前台：`getPendingNotificationRequests` 总数应稳定 ≤ 56，且 6 条 `med-` 全部在列。
- 在「删除与重加之间杀 App」已不可能复现（不再有全删窗口）：先记录待处理列表，杀 App 重开，确认前一天的服药提醒仍在。
- Console 观察 `⚠️ [HabitAndMedication] 服药提醒排期失败 …` 与预算日志。

---

## 4. 通知预算（新增 `NotificationBudget`）

**位置**：`Assistant/Services/NotificationBudget.swift`（新文件）。接入点：`HabitAndMedicationScheduler.reconcileMedicationReminders`（服药）、`TodoNotificationManager.reconcileTodoNotifications`（待办）。

**问题**：iOS 对同一 App 只保留约 64 条待处理通知，超出部分**静默丢弃**；此前各模块各自 `add`，待办一项就能占 60 条，服药/睡眠/报告只能靠运气。

**策略**
- 优先级（高 → 低）：**服药(4) > 睡眠(3) > 到站(2) > 报告(1) > 待办主提醒(0) > 待办逾期补提醒(-1)**。
  未接入预算的模块（天气 / 取件 / 心理 / 习惯等）标为 `external(5)`：**计入总量但永不主动裁剪**。
- 软上限默认 **56 条**（64 条硬上限留 8 条余量给未接入模块与系统窗口），可 `admit(..., limit:)` 覆盖并夹到 [16, 64]。
- 决策顺序：
  1. 存量已超上限 → 先按「优先级最低 / 同优先级离触发最远」全局裁剪（external 除外）；
  2. 按优先级从高到低接纳本轮新增；名额不足时**只裁优先级严格更低**的存量项，同优先级不互相抢占（避免每次前台「你删我、我删你」的 churn）；
  3. 仍放不下 → 拒绝低优先级请求，下一轮对账自然重试。
- 可观测：被拒绝 / 被裁剪时打印
  `📊 [NotificationBudget] <source>：待处理 A→B/56，申请 N，接受 X，拒绝 Y（优先级分布），裁剪 Z（模块分布）`；
  同时写入线程安全的 `NotificationBudget.lastSummary`（来源、各计数、优先级分布、时间戳），供真机/设置页/后续 UI 读取。
- 指纹比较（`fingerprint(of:)`）供差量对账复用：内容字段 + 日历触发时分 + repeats；
  时间间隔触发器（待办主提醒）的剩余时长会随读取时间变化，不参与比较（见 §5 说明）。

**未接入预算的模块**（本次不改其文件）：睡眠、到站、报告、天气、取件、心理仍直接 `add`。它们被预算**保护**（不会被裁），但反过来说：如果它们把总量顶到 56 以上，下一次服药/待办对账会按优先级裁掉待办逾期补提醒 → 待办主提醒。行为可解释，日志可查。

**退化时表现**
- 只有 external 占满 56 条时，新的服药请求会被拒绝并打日志（不会删 external，也不会删别的服药）。
- 预算只影响「能不能排进去」，不影响已存在的通知内容与触发时间；被拒绝的会在下一次前台对账重试。
- `lastSummary` / 日志在容量富余时保持静默（正常路径不产生噪音）；容量紧张时每轮对账可能一行日志。

**验证方式（真机）**
- 构造「2 服药计划 × 3 时点 + 15 条待办 + 5 条报告 + 3 条睡眠」：连续切前台后 `getPendingNotificationRequests` 总数应 ≤ 56，服药 6 条齐全，最先消失的是待办逾期补提醒。
- Console 观察 `📊 [NotificationBudget]` 行；需要程序化查看时读 `NotificationBudget.lastSummary`（临时调试入口即可）。
- 负向：把 `admit(limit:)` 传小（如 20）在测试代码里验证裁剪顺序。

---

## 5. SVC-06/SVC-08 · 待办通知差量对账（TodoNotificationManager）

**位置**：`Assistant/Services/TodoNotificationManager.swift:124`（抽出 `makeNotificationRequests`）、`:166`（单条排期复用构造器，行为不变）、`:423`（`syncAllTodoNotifications` 入口）、`:436`（`reconcileTodoNotifications` 差量对账）、`:515`（`submitAuthorized`）。

**原成本**：每次前台 `syncAllTodoNotifications` 对 15 项逐条 `scheduleNotification`：每项先 `cancelNotification`（1 次 remove）+ `getNotificationSettings` + 逐条 `add`；最多 15 × 4 = 60 次 `add` + 60 次 remove 名额 + 1 次 pending 查询，约 90+ 次 usernoted XPC；且无总额约束。

**新成本**：
- 主 actor 上算出「期望集合」（top-15 项的主提醒 + 未来逾期补提醒）；
- 1 次 `pendingNotificationRequests()` 拿存量，按 identifier + 内容指纹做差量：
  - 存量不在期望集合 → 删除（已完成/已删除/不再入选/触发时刻全过）；
  - 缺失 → 新增；内容变化（标题/副标题/详情/日期标签等）→ 删旧加新；
  - 其余保持不动（**不再 remove/add 同一个通知**）。
- 通过 `NotificationBudget` 申请名额（待办最低优先级；主提醒高于逾期补提醒）。
- 新增/替换用 async `try await center.add`，失败带 identifier 打日志；授权检查保留（未决时先申请，拒授权不排期）。
- 正常路径：1 次 `pendingNotificationRequests` + 1 次 `notificationSettings` + 0 次 remove + 0 次 add。

**行为变化**
- 正常前台不再产生「全量 remove/add」窗口；通知内容/触发时刻未变时保持系统里已有的请求（剩余触发时间不再每次前台被重置）。
- 编辑待办（标题/提前量/截止时间）会改内容指纹 → 精准重排该条。
- 单条排期路径（新建待办、编辑弹层、通知动作「稍后」等）保持原有「先 cancel 再 enqueue」语义，不受本次改动影响。

**已知取舍（需真机确认）**
- 时间间隔触发器（主提醒）不比较剩余时长，只比较内容。**只改 `reminderOverrideAt` 而内容不变**的场景，批量对账不会重排；但该场景都由直接调用点 `scheduleNotification(for:)` 覆盖（通知动作/编辑保存路径），因此功能正确。若真机发现「推迟后又被批量对账改回」——不会发生：批量对账不会改动内容相同的请求。
- 跨天时副标题「今天/明天 HH:mm」的变化会触发一次重排（期望行为）。

**退化时表现**
- `add` 失败 → 记录日志，下一轮对账重新判定为缺失并重试；不会谎报成功。
- 待办量很大的用户：top-15 之外不排期（Core 既有口径不变），预算再裁掉一部分最低优先级（逾期补提醒优先）；被裁的在下一次前台对账重试。
- 取数失败（`try? context.fetch`）：与旧实现一致，本轮跳过对账（下一轮重试），不删任何通知。

**验证方式（真机）**
- 15 条待办 + 2 个服药计划：连续切前台，Instruments 的 usernoted XPC / `Time Profiler` 观察 `syncAllTodoNotifications` 不再出现大批 `remove`/`add`；
- 修改某条待办标题/提前量 → 只看到该条 identifier 的变化；
- 删除/完成待办 → 其通知在下一次对账被删除；
- Console 观察 `Failed to schedule todo notification` 与预算日志。

---

## 6. 需要真机验证的风险点（汇总）

1. **系统读回的通知触发器表示**：差量对账依赖 `UNNotificationRequest.trigger` 读回的 `dateComponents` / `repeats` 与本地构造一致。若 iOS 补了 `timeZone`/`calendar` 等字段，指纹会不等 → 退化为「每轮删加一次」（正确性不受影响，只是优化失效）。观察服药/待办是否每轮都重排即可判断。
2. **64 条上限与裁剪顺序**：真机确认 `getPendingNotificationRequests().count ≤ 56`，以及被裁的是待办逾期补提醒（而不是服药/睡眠）。未接入预算的天气/心理等 `external` 通知不会被预算删除。
3. **节流是否「只延后不永久跳过」**：冷启动、后台回来、间隔到期三种路径都要各验证一次；确认 Console 里是「节流跳过」而不是没有任何日志（漏跑）。
4. **Caches 运行态文件**：`Caches/foreground-audit-cadence.json` 在设备上可写（Caches 目录必存在）；被杀进程后时间戳仍在（验证方式：两次启动间隔 < 10 分钟，第二次应出现节流日志）。
5. **28 夜样本缓存**：确认夜间精修仍然生效（卡片/通知时刻随最新饮食、运动、天气变化），只是样本本身最多旧 10 分钟。
6. **Xcode 工程**：新文件 `NotificationBudget.swift` 需 `xcodegen generate` 后才进入 target（本次已执行；`.xcodeproj` 是生成物且被 gitignore）。
7. **日志噪音**：容量长期紧张时每轮对账可能刷一行预算日志；如影响观察，可在后续把 `softLimit` 调高或改成每 N 分钟一条汇总。

## 7. 未做 / 后续建议

- 睡眠、到站、报告、天气、心理等模块**没有**改成走 `NotificationBudget` 排队（本次只要求至少服药 + 待办接入）；它们目前被优先级保护但可能把总量顶到软上限，下一步建议统一走 `admit`。
- `NotificationBudget` 的裁剪只针对通知系统层；设置页目前没有「因预算裁剪」的用户提示（可在后续用 `lastSummary` 做一个只读说明）。
- 前台巡检的下一步（批 3/4）：日报/报告类全表 fetch 改窗口谓词 + `fetchLimit`（SVC-08 建议 4 / SVC-10），本批未动。
