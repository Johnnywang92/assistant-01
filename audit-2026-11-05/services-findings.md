# Services 层代码审计（2026-11-05）

审计对象：`Assistant/Services/`（85 个 Swift 文件，29,879 行，含 `Persistence.swift`、`Migration/`、`Inference/`）。
审计基线：当前工作树（含未提交改动 `Assistant/Services/Persistence.swift`、`Assistant/Services/SleepReminderScheduler.swift` 等）。未执行 reset/checkout，未修改任何 `.swift`/工程/plist/文案文件，只新增本报告。

方法：静态阅读 + 针对性 grep/脚本统计；不跑完整 `xcodebuild`。凡标注「确认」表示源码链路成立（必要时已核对调用方），「疑点」表示依赖未实测的运行时条件。

## 结论摘要

本轮确认 15 项：**P1 一项、P2 八项、P3 六项**。

| 编号 | 优先级 | 主题 | 位置 |
| --- | --- | --- | --- |
| SVC-01 | P1 | 备份导出/还原在主线程一次性物化全库 + 全部附件字节 + 310k 轮 PBKDF2 | `Migration/DataMigrationService+Export.swift:616` 等 |
| SVC-02 | P2 | 后台自动备份失败只 `print`，不落同步状态，UI 长期显示上次成功 | `WebDAVSyncService.swift:262` |
| SVC-03 | P2 | `inbox.txt` 先清空后逐条导入，`try?` 吞错即永久丢条目 | `SupportServices.swift:30` |
| SVC-04 | P2 | 多条写库链路 `try? context.save()` 后仍向用户回「已记录/已加入」 | `VoiceIntentProcessor.swift:251` 等 |
| SVC-05 | P2 | 出行票务提醒 save 失败仍标记「已加入过」，导致永久不再提醒 | `TravelTicketReminderManager.swift:723` |
| SVC-06 | P2 | 服药提醒每次回前台「先删全部再重加」，`add` 无回调；叠加 64 条通知上限 | `HabitAndMedicationScheduler.swift:121` |
| SVC-07 | P2 | 模型导入在主 actor 上 copy 数 GB 文件并做全文件 SHA-256；导入目录未保证排除备份 | `LLMModelManager.swift:513` |
| SVC-08 | P2 | 每次回前台在 MainActor 串行跑全表巡检 + 28 夜 HealthKit + 通知全量重排 | `BackgroundRefreshCoordinator.swift:72` 等 |
| SVC-09 | P2 | 全景搜索每次打开都清空并重建 18 张表索引，重复全表拉取 | `SearchIndexService.swift:268` |
| SVC-10 | P3 | 152 处 `try? fetch` 把「读失败」压成「空数据」（重复待办/统计归零/索引缺项） | 多文件，见正文 |
| SVC-11 | P3 | WebDAV 钥匙串写入结果被丢弃，存密码「成功」但实际没写进 Keychain | `WebDAVSyncService.swift:286` |
| SVC-12 | P3 | `Persistence` 全局容器无隔离标注、可变静态状态、失败走 `fatalError` | `Persistence.swift:7` |
| SVC-13 | P3 | EventKit 同步查询/写入在 MainActor 上执行 | `CalendarAgendaService.swift:82` |
| SVC-14 | P3 | 记账→饮水→Apple 健康联动失败全静默（空 catch + 调用方忽略） | `HealthKitService.swift:212` |
| SVC-15 | P3 | 通知分类注册的「读-改-写」覆盖风险（疑点） | `NotificationCategoryRegistry.swift:22` 等 |

## 与上轮审查的去重说明（CR-01…CR-11）

先读了 `code-review-2026-10-29.md`（CR-01…CR-11 均已于 2026-10-30 修复）与 `todo.md` 的对应实施记录。以下已修复内容**未在本轮重复报告**：

- CR-01 分享导入「先删后确认」：本轮复核 `ShareInboxService.swift:44-83`、`handleImage/handleText` 已是「`.done` 才删、失败 `rollback()` 保留来源」，未发现回归；本轮报告的是**另一条同类链路**（`inbox.txt`，SVC-03）。
- CR-04/CR-05 备份口令与 WebDAV href：`WebDAVSyncService.uploadBackup/downloadBackup/listRemoteBackups/deleteRemoteBackup` 已统一走 `WebDAVRequestFactory.makeFileURL`，口令只存 Keychain，字面量已清除；未重复报告。
- CR-06/CR-07/CR-09/CR-10：`WidgetSnapshotSync.processCommandBatch*` 已是三态裁剪、`snoozeInDB/toggleDepartureInDB` 已 `do/catch`、预算播报已窗口取数、`executeLifeRecord` 四域已区分「读失败/确实没有」；未重复报告。
- CR-11 CSV 导入：`batchImportAnniversaries/Passwords/Todos` 已改为「循环 insert + 单次 `context.save()` + 失败 `rollback()`」，实测无逐条 save 回归；未重复报告。
- 上轮结尾「验证记录」已明示**仍留在 `WidgetSnapshotSync.swift:306-380` 的 6 处 App hook `try? context.save()`**（`handleCompleteTodo`/`handleSnooze*`/`handleToggleDeparture`/`handleQuickAdd*`）属于已记录的未修项，本轮不当作新发现计数；SVC-04 列出的是**其他文件**的同类新实例，并单独标注了与那 6 处的区别。

本轮特别核对后**未发现问题**的方向（避免读者误判为遗漏）：Services 层无空 `catch {}`（脚本扫描 0 处）、无 `DispatchQueue.main.sync`、无 `try!`（`LocalizationManager` 的 3 处 `try!` 是硬编码静态正则，不会失败）、无敏感数据日志（28 处 `print` 全部只打错误描述/标识符，无口令/PIN/正文）、WebDAV/AppLock/密码库密钥均只进 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。

---

## P1

### SVC-01 · P1 · 备份导出/还原在主线程一次性物化全库与全部附件字节，再做 310k 轮 PBKDF2 + AES-GCM

- **优先级**：P1（关键链路：备份/还原与后台自动备份；大附件用户会直接卡死/被杀）
- **状态**：**确认**（静态链路完整；耗时与内存峰值按代码结构推算，未真机实测）
- **位置**：
  - `Assistant/Services/Migration/DataMigrationService+Export.swift:616`（`exportEncryptedArchive`）、`:7-52`（`buildBackupPackage` 整表 fetch）、`:166-185`（证件正反面图片全量读入内存）、`:199-223`（语音音频 + 备忘图片全量读入内存）、`:230-257`（附件核对）、`:624-648`（JSON 编码 + 封套 base64）
  - `Assistant/Services/DataMigrationService.swift:183`（`@MainActor final class DataMigrationService`）
  - `Assistant/Services/WebDAVSyncService.swift:128-132`（后台自动备份走同一条导出链路）
  - `Assistant/Services/BackgroundRefreshCoordinator.swift:55-68`、`:103`（BGAppRefreshTask 内调用）
  - 调用方：`Assistant/Features/DataMigrationView.swift:404-419`（手动导出，同步调用）、`:425-433`（把整个备份文件 `Data(contentsOf:)` 到主线程）、`:458-472`（解锁：PBKDF2 + 解密 + 整包 JSON decode）、`:474-489`（还原：清库 + 全量 insert + save，全部同步）
- **代码证据**（关键片段）：

  ```swift
  // DataMigrationService+Export.swift:616
  public func exportEncryptedArchive(pin: String, hint: String? = nil) throws -> (data: Data, filename: String) {
      ...
      let package = try buildBackupPackage()        // 40+ 张表无谓词全表 fetch，附件字节一并进内存
      try validate(package: package)
      let packageData = try encoder.encode(package) // 附件 Data → JSON base64（体积 ×1.33）
      let combined = try BackupEnvelopeCrypto.seal( // PBKDF2 310,000 轮 + AES-GCM
          packageData, pin: cleanPin, salt: saltData,
          iterations: EncryptedBackupEnvelope.defaultIterations)
      let envelope = EncryptedBackupEnvelope(... payloadBase64: combined.base64EncodedString() ...)
      ...
  }
  ```

  ```swift
  // DataMigrationService+Export.swift:166（证件照）
  let frontData = IDPhotoStorage.loadData(fileName: doc.frontImageFileName) ?? ...
  // DataMigrationService+Export.swift:199（语音备忘与图片）
  let audioData = VoiceMemoStorage.loadData(memo.audioFileName)
  ```

  `DataMigrationService` 是 `@MainActor`（`DataMigrationService.swift:183`），以上全部方法同步执行，因此整条链路都在主线程。
- **触发条件**：① 用户在「数据备份与迁移」页点「生成加密备份」；② 开启「NAS 后台自动备份」后系统在后台唤醒（`BGAppRefreshTask`）；③ 用户导入备份并解锁/还原。附件越多越大（证件照、语音备忘、备忘内嵌图片、物品/待办附件）越严重。
- **用户影响**：
  - 主线程被阻塞：`PBKDF2 310k` 单项在旧设备约 0.2–0.5s（Core 注释 `BackupEnvelopeCrypto.swift:24` 自述），叠加 40+ 张全表 fetch、全部附件读盘、base64 膨胀、AES-GCM，几百 MB 附件下是**数十秒级卡死**；后台巡检预算只有几十秒，会被系统 watchdog/后台任务超时直接杀掉，**自动备份静默地永远不成功**。
  - 内存峰值 ≈ 附件体积 ×4~5（原始 Data → JSON base64 → encrypt 输出 → envelope base64 + 中间字符串），大附件用户可能直接被 OOM 杀掉，导出与还原都失败。
  - 还原路径更糟：`isRestoring = true` 之后同步跑完全程，SwiftUI 连一次「还原中」都渲染不出来（`DataMigrationView.swift:476-478`）。
- **修复建议**：
  1. 把「取数 + DTO 映射 + 附件读盘 + JSON 编码 + KBKDF/加密」移出主 actor：在 `Task.detached(priority: .utility)` 里用**独立 ModelContext**（`ModelContext(container)`，注意 SwiftData 的跨线程约束）取数，只把最终 `Data` 回主 actor；导出/还原对外暴露 async 版本，UI 显示进度并在后台执行。
  2. 附件不要整包内联：备份包里只存文件名 + 摘要，附件按独立文件打包（或直接排除），还原时流式写回，避免峰值内存。
  3. 后台路径改用「小体积增量备份」（仅变更表）或至少在 `BGAppRefreshTask` 里跳过超过阈值的备份并在 UI 如实提示。
  4. 加密/解密单独做流式或分块（或至少把 PBKDF2 放到后台），不要与全库物化叠加在同一主线程事务里。
- **验证方式**：构造一个含 100+ 张证件照/语音（约 200MB）的库，① 手动导出时用 `Instruments→Time Profiler` 观察主线程占用与内存峰值；② 直接调用 `exportEncryptedArchive` 并测量耗时/峰值内存（可在 App 层临时包一层 `os_signpost`）；③ 让后台自动备份在真机上跑一次（可把 `earliestBeginDate` 调为 `now+60s`），看系统日志是否出现 watchdog/`BGAppRefresh` 超时；④ 用 `xcodebuild` 之外的方式断言修复后导出不阻塞主线程（`DispatchQueue.main` 上埋点）。

---

## P2

### SVC-02 · P2 · NAS 后台自动备份失败只 `print`，同步状态不落库，UI 长期显示上次成功

- **优先级**：P2（用户依赖「已自动备份」的错误安全感）
- **状态**：**确认**
- **位置**：`Assistant/Services/WebDAVSyncService.swift:262-282`（`performBackgroundSyncIfNeeded`）；对照成功路径 `:162-166`（`updated.lastSyncStatus = "备份成功（\(archive.filename)）"` + `saveConfig`）
- **代码证据**：

  ```swift
  // WebDAVSyncService.swift:262
  public func performBackgroundSyncIfNeeded(context: ModelContext) async {
      guard config.autoSyncEnabled, config.isConfigured, hasPassword else { return }
      if let last = config.lastSyncDate, Date().timeIntervalSince(last) < 20 * 3600 { return }
      guard let pin = autoSyncPIN else { print("⚠️ ...未设置自动备份口令"); return }
      do {
          _ = try await uploadBackup(pin: pin, hint: "后台自动静默同步至NAS", context: context)
          print("☁️ ...后台自动同步备份至 NAS 成功")
      } catch {
          print("⚠️ [WebDAV] 后台自动同步备份失败: \(error)")   // 只进控制台
      }
  }
  ```

  失败时不写 `config.lastSyncStatus`、不设 `lastErrorMessage`、不发通知；而 `Config.lastSyncDate` 只在成功后更新，所以 UI 上「上次同步时间」+「备份成功」会一直停留在旧值。
- **触发条件**：NAS 离线/改密码/证书过期/磁盘满/上传被墙，且后台任务被系统唤起执行。
- **用户影响**：用户以为 NAS 上有最新备份（可能几周前就已停更），直到换机还原才发现数据缺失；这类失败无声无息，正是备份功能最不该有的失效方式。
- **修复建议**：失败时也落 `lastSyncStatus = "失败（原因）"`、`lastErrorMessage`，并在「上次同步时间」旁展示失败态；连续 N 天失败或距上次成功超过阈值时发一条本地通知（走 `NotificationService`，注意安静模式）。注意 `saveConfig` 会编码整个 config 到 UserDefaults，失败原因里不要塞完整错误对象。
- **验证方式**：把服务器地址改成不可达的主机，触发一次 `performBackgroundSyncIfNeeded`，断言 `config.lastSyncStatus` 变为失败、`lastErrorMessage` 非空、UI 文案变化；再恢复可达后确认成功态回写。静态验证：`grep -n "lastSyncStatus" Assistant/Services/WebDAVSyncService.swift` 只出现在成功分支。

### SVC-03 · P2 · `inbox.txt` 先清空再逐条导入，`try?` 吞错导致条目永久丢失

- **优先级**：P2（用户输入永久丢失，难度低但需触发写库失败）
- **状态**：**确认**
- **位置**：`Assistant/Services/SupportServices.swift:24-44`（`InboxService.drain`），清空在 `:32`，吞错在 `:41`
- **代码证据**：

  ```swift
  // SupportServices.swift:30
  coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
      content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      if !content.isEmpty { try? Data().write(to: url) }   // 先清空（覆盖成空文件）
  }
  ...
  for entry in entries {
      if let r = try? service.ingest(entry, source: "inbox"), !r.skippedDuplicate { count += 1 }
      // ingest 内部 throw（如 context.save() 失败）→ 该条被静默丢弃，文件已在上面清空
  }
  ```

  `ImportService.ingest` 在 `Assistant/Services/ImportService.swift:71` 用 `try context.save()` 抛错（磁盘满/迁移异常时可达），抛错后 `InboxService` 不再重试也不保留原文。
- **触发条件**：快捷指令往 `Documents/inbox.txt` 写入多条文本，App 回前台排空时数据库写入失败（或第 N 条解析/保存抛错）。
- **用户影响**：用户在「文件」App 里看到的待补录文本被清空，但对应数据从未入库，也没有任何失败提示；与 CR-01 修复后的「落库成功才消费」方向相反。
- **修复建议**：与 `ShareInboxService` 对齐成事务语义——先读入内存，逐条 `do/catch` 落库；只有**全部成功**（或按成功子集）才把已处理的原文写回文件（保留失败部分），失败条目发通知并在回执里报告行数；`Data().write` 的失败也要处理（写失败则不要认为消费成功）。
- **验证方式**：注入 `context.save()` 抛错（可临时把 store 目录设为只读/构造损坏库），断言：① `inbox.txt` 内容仍在且只删掉已成功的条目；② 返回计数与文件剩余一致；③ 无成功通知。静态验证：修复后 `InboxService.drain` 内不再有 `try? service.ingest`。

### SVC-04 · P2 · 多条写库链路 `try? context.save()` 后仍向用户回「已记录/已加入」

- **优先级**：P2（与上轮 CR-01/CR-06 同族，但发生在不同文件、不同入口）
- **状态**：**确认**
- **位置**（Services 层新实例，均与上轮已记录的 6 处 `WidgetSnapshotSync` App hook 不同文件）：
  - `Assistant/Services/VoiceIntentProcessor.swift:249-251`（`createTodoFromVoice`：`insert` → `scheduleNotification` → `try? context.save()` → 返回「好的，已为你记下待办「…」」）
  - `Assistant/Services/VoiceIntentProcessor.swift:354`（`recordExpenses`）、`:376`（`recordExpense`：`try? context.save()` 后返回「已为你记入 N 笔」）
  - `Assistant/Services/TaskPlanningEngine.swift:582-583`（`savePlanToTodos`：批量 insert + `try? context.save()` + `Haptic.success()` + 返回条数，调用方据此报「已添加」）
  - `Assistant/Services/TodoNotificationManager.swift:352/358/365/375`（通知「完成/推迟 10 分钟/1 小时/明早 9 点」四个 action：`try? context.save()`，即使用户在锁屏点了动作也无任何失败回执）
  - `Assistant/Services/SkillPathManager.swift:68-69`（新建技能路径：`try? context.save()` + `Haptic.success()`）
- **代码证据**：

  ```swift
  // VoiceIntentProcessor.swift:249
  context.insert(item)
  TodoNotificationManager.shared.scheduleNotification(for: item)  // 通知先于落库注册
  try? context.save()
  ...
  return "好的，已为你记下待办「\(parsed.title)」"                    // 无论 save 是否成功
  ```

- **同文件族但影响较轻（不计入本条）**：`Assistant/Services/LLMInferenceService.swift:976-992` 的 `executeSideEffectIfNeeded` 也以 `try? context.save()` 收尾，但写库动作由 `OmniboxExecutor` 的各个 provider 内部先 `try context.save()` 并抛错（`Assistant/Features/Omnibox/Providers/*.swift` 均有 save，失败会变成 outcome.errorText 回给用户），主数据大概率已落库；这里丢失的是**事务记录与撤销令牌**（`:990-992`）和确认卡留痕（`:976-978`）——用户看到动作已执行，但历史页找不到、无法一键撤销。建议一并改成 `do/catch` 并如实回执「已执行但未记录撤销入口」。

- **触发条件**：磁盘满、SQLite 写锁、迁移/损坏库导致 `context.save()` 抛错。
- **用户影响**：用户听到/看到「已记录」，实际没落库；更糟的是**通知已经在 save 之前注册**（`VoiceIntentProcessor:250`、`TaskPlanningEngine:580`、`TravelTicketReminderManager:719`），点开通知时目标可能不存在。语音是「免掏手机」主入口，这类静默失败会直接损坏记账/待办数据可信度。
- **修复建议**：把「保存」和「副作用」排成 `do { try context.save() } catch { context.rollback(); 返回失败文案/返回 nil }`，成功后才 `scheduleNotification`/`Haptic.success`；对外返回 `Result`，由调用方决定回执文案（与 CR-06 的「落库成功才确认」保持一致）。
- **验证方式**：注入 save 失败（可用只读 store 或临时 wrapper），断言：① 语音回执不含「已记下/已记入」；② 不产生指向不存在待办的通知；③ `context` 回滚后无残留 insert。静态验证：上述文件里 `try? context.save()` 归零，或仅出现在真正允许「尽力而为」的派生数据（如 `ExpenseWaterService` 联动）路径。

### SVC-05 · P2 · 出行票务提醒 save 失败仍标记「已加入过」，导致永久不再提醒

- **优先级**：P2（功能永久失效 + 数据丢失，且用户点过「加入」却什么都没得到）
- **状态**：**确认**
- **位置**：`Assistant/Services/TravelTicketReminderManager.swift:701-727`（`confirmAndInsertTicketTodos`）；去重标记 `:791-800`（`isTodoAdded` / `markTodoAdded`，UserDefaults）
- **代码证据**：

  ```swift
  for item in items where item.isSelected {
      let todo = TodoItem(...)
      context.insert(todo)
      TodoNotificationManager.shared.scheduleNotification(for: todo)  // 先排通知
      count += 1
  }
  try? context.save()          // 失败被吞
  markTodoAdded(id: info.id)   // 无论是否落库都标记「已加入」，此后 isTodoAdded 恒为 true
  self.activeUpcomingTicket = nil
  return count
  ```

- **触发条件**：`context.save()` 抛错（磁盘满/库损坏），用户在「春节/国庆出行提醒」卡片上点「加入待办」。
- **用户影响**：待办与提醒都没落库；但 `markTodoAdded` 已写入 UserDefaults，`refreshUpcomingTickets` 会认为这趟出行「已加过」，之后**整个出行周期内不再提示**；同时残留一次指向不存在待办的即时/定时通知。用户以为「已加入」，实际永远失去该提醒。
- **修复建议**：`do/catch save`；仅成功后 `markTodoAdded(id:)`；失败时回滚并返回失败（调用方提示「保存失败，请重试」）。UserDefaults 与 SwiftData 不在同一事务里，顺序必须是「先落库成功、再记标记」。
- **验证方式**：注入 save 失败后调用 `confirmAndInsertTicketTodos`，断言 ① 返回 0 或抛错；② `isTodoAdded` 仍为 false；③ 再次 `refreshUpcomingTickets` 仍会出现该卡片；④ 无通知被注册。

### SVC-06 · P2 · 服药提醒每次回前台「先删全部再重加」，`add` 无回调；再叠加 64 条通知总账

- **优先级**：P2（健康关键提醒可能整批消失，且全程无错误可观测）
- **状态**：**确认**（机制确认；「被系统截断」的具体频率为**疑点**，取决于用户数据量与系统配额）
- **位置**：
  - `Assistant/Services/HabitAndMedicationScheduler.swift:77-151`（`scheduleMedicationReminders`：`:121` `getPendingNotificationRequests` → `:123-126` 删除所有 `med-` 前缀 → `:128-149` 全部重加，`center.add` 无 completion handler）
  - 调用点：`Assistant/App/AssistantApp.swift:205-211`（每次前台巡检都调用）
  - 通知总账：`Assistant/Services/TodoNotificationManager.swift:88-111`（`getNotificationSettings` + 逐条 `add`，失败只 `print`）、`:412-427`（待办最多 15 项 × 最多 4 条 = **60 条**）；`Assistant/Services/SleepReminderScheduler.swift:406-429`（3 条）、`Assistant/Services/PeriodicReportManager.swift:1686-1828`（最多 5 条）、`Assistant/Services/WeatherAlertService.swift:460/553`（2 条）、`Assistant/Services/TripArrivalService.swift:78-116`（每个行程 1–2 条）
- **代码证据**：

  ```swift
  // HabitAndMedicationScheduler.swift:121
  center.getPendingNotificationRequests { requests in
      let existingMedIds = requests.filter { $0.identifier.hasPrefix("med-") }.map(\.identifier)
      if !existingMedIds.isEmpty { center.removePendingNotificationRequests(withIdentifiers: existingMedIds) }
      for reg in registrations {
          ...
          center.add(UNNotificationRequest(identifier: reg.id, content: content, trigger: trigger))  // 无 completion，错误全丢
      }
  }
  ```

- **触发条件**：每次 App 回到前台；用户在删完之后立刻切后台/被系统挂起，或待处理通知总数超过系统上限（iOS 对同一 App 只保留 64 条待处理通知，超出部分被系统丢弃）。
- **用户影响**：
  - 服药提醒是「每日重复触发」排期，若在删除与重加之间进程被挂起/杀掉，当天剩余服药提醒会全部消失，直到用户下次打开 App。
  - 待办已占 60 条上限，任何「2 个服药计划 × 3 个时点 + 睡眠 3 + 报告 5 + 天气 2」的组合就会越过 64；越界请求被系统静默丢弃，`print` 里的错误在用户设备上不可见，用户只会「某天没收到吃药提醒」。
- **修复建议**：
  1. 服药提醒排期改成「差量对账」：只删除 identifier 不在最新集合的旧通知、只新增/覆盖变化项，不要每次先全删。
  2. `center.add` 必须带 completion handler 记录失败；`getPendingNotificationRequests` 后计算总条数，超阈值时按优先级（服药 > 睡眠 > 到站 > 报告 > 待办逾期补提醒）裁剪并在设置页给出可解释的提示。
  3. 建立唯一的「通知预算」入口（`NotificationCategoryRegistry` 同目录下加 `NotificationBudget`），各模块申请名额而不是自行 `add`。
- **验证方式**：真机 `UNUserNotificationCenter.current().getPendingNotificationRequests` 打印总数（需临时调试入口）；构造 2 个服药计划 × 3 时点 + 15 条待办提醒，观察服药通知是否仍在；在删除与重加之间杀 App，重开前检查通知中心无服药提醒（复现丢提醒）。

### SVC-07 · P2 · 模型导入在主 actor 上同步 copy 数 GB 文件并做全文件 SHA-256；导入目录未保证排除 iCloud 备份

- **优先级**：P2（UI 卡死/被系统杀 + 备份体积异常膨胀）
- **状态**：**确认**（主线程阻塞确认；备份膨胀取决于用户是否先下载过模型，属**疑点**）
- **位置**：`Assistant/Services/LLMModelManager.swift:513-544`（`importModel`，类注解在 `:107` `@MainActor`）；同仓对照 `Assistant/Services/VisionModelManager.swift:536-540`（同样的校验放在 `Task.detached` 里）
- **代码证据**：

  ```swift
  // LLMModelManager.swift:513（@MainActor class 内，同步方法）
  public func importModel(from sourceURL: URL) throws {
      ...
      _ = modelsDirectory
      let candidate = modelsDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
      try FileManager.default.copyItem(at: sourceURL, to: candidate)   // 数 GB 同步拷贝
      let validated = try ModelFileValidation.validate(               // 全文件 SHA-256（1MB 分块 but 同步）
          at: candidate, minSizeBytes: selectedPreset.minValidSizeBytes,
          releases: selectedPreset.publishedReleases)
      ...
  }
  ```

  ```swift
  // 对照：VisionModelManager.swift:536
  let result = await Task.detached(priority: .utility) {
      Result { try ModelFileValidation.validate(at: candidate, ...) }
  }.value
  ```

  目录侧：`modelsDirectory` 在 `LLMModelManager.swift:116-122` 里只 `createDirectory`，**不设置** `isExcludedFromBackup`；只有「下载完成」路径 `:597-604` 会给 `Documents/Models` 目录打排除标记。只走「从文件 App 导入」的用户，其 1–4GB 模型会留在 `Documents/Models` 并被 iCloud/iTunes 备份。
- **触发条件**：用户在「AI 本地大模型」页用「导入模型文件」选择一个 1–4GB GGUF；或从未下载过模型、只导入过。
- **用户影响**：① 拷贝 + SHA-256 全程主线程，数秒到数十秒无响应，前后台切换/锁屏时可被系统杀掉（导入失败且无回执）；② `Documents/Models` 位于用户可见沙盒，且未被排除备份，iCloud 备份会被多 GB 模型占满（备份失败/变慢）。
- **修复建议**：
  1. 把 `importModel` 改成 `async`：`Task.detached` 里完成 copy + `ModelFileValidation.validate`，只把结果回 `@MainActor`；UI 显示进度（大文件拷贝可分段 `copyItem` 或 `FileHandle` 流式拷贝）。
  2. `modelsDirectory` 创建后立即 `setResourceValues(isExcludedFromBackup: true)`（幂等），并且对已存在的模型文件/目录在 App 启动时补打一次标记。
  3. 导入前检查可用磁盘空间，失败要回滚候选文件。
- **验证方式**：真机导入一个 ≥2GB GGUF，用 Time Profiler 观察主线程是否被 `copyItem`/`CC_SHA256` 占满；`ls -lO ~/.../Documents/Models` 或 `xattr`/`URLResourceValues` 断言 `NSURLIsExcludedFromBackupKey == true`；在设置 App 的 iCloud 备份大小里确认模型不计入。

### SVC-08 · P2 · 每次回前台在 MainActor 上串行跑全表巡检 + 28 夜 HealthKit + 通知全量重排

- **优先级**：P2（每次前台切换都有可感知卡顿/耗电，且随数据量线性恶化）
- **状态**：**确认**（成本结构确认；具体毫秒数未实测）
- **位置**：
  - `Assistant/Services/BackgroundRefreshCoordinator.swift:72-111`（`performIdempotentAudits`：串行执行收件箱、`DailyPainPointAuditor.auditAll()`、`RecurringExpenseManager`、`BudgetAlertService`、`ShareInboxService.processAll()`、`TripArrivalService`、WebDAV、天气）
  - `Assistant/Services/DailyPainPointAuditor.swift:19-33`（9 个 audit，全部主线程全表/谓词 fetch）与 `:330-343`（`upsertTodo`）
  - `Assistant/Services/SleepReminderScheduler.swift:174-267`（`:194` `fetchSleepNights(days: 28)` 拉 28 夜全部睡眠样本并在主 actor 上分组/计算；`:218` `deliveredNotifications()`；3 次 `plan()`）
  - `Assistant/Services/HealthKitService.swift:235-300`（`refreshToday`：13 个 `async let` HealthKit 查询）
  - `Assistant/Services/TodoNotificationManager.swift:390-433`（`syncAllTodoNotifications`：全量活跃待办 + 15 项 × 最多 4 条通知逐条 `remove`/`add`（约 90 次以上 XPC 往返））
  - `Assistant/Services/HabitAndMedicationScheduler.swift:121-151`（见 SVC-06）
  - 调用点：`Assistant/App/AssistantApp.swift:182-221`（`ForegroundAuditCoordinator` 在每次 `.active` 都跑上述全部）
- **触发条件**：每次 App 从后台回到前台（含冷启动一次）。
- **用户影响**：首帧之后仍有明显卡顿/掉帧与耗电；万级待办/账本 + 长期 HealthKit 数据的用户最明显。虽然每个子项都不大，但串行叠加在同一个主 actor 上，且**没有任何缓存/节流**（睡眠 28 夜查询每次重跑、服药通知每次全删全加、15×4 条通知全量重排（约 90 次以上 usernoted XPC））。
- **修复建议**：
  1. 前台巡检分级：便宜且必须同步的（小组件指令、分享排空）留在前台；贵查询（28 夜睡眠、报告、天气）改为「距上次执行 < N 分钟则跳过」的节流，并逐步下沉到后台任务。
  2. `SleepReminderScheduler.syncSleepReminders` 缓存 `samples`（键：最近一次 HealthKit 变更/日期 + 上次拉取时间），不要每次前台都全量拉。
  3. 通知重排改为差量：`getPendingNotificationRequests` 后只对 identifier 集合做增删差。
  4. 报表/审计类全表 fetch 改为窗口谓词 + `fetchLimit`（见 SVC-01/09 的同类问题）。
- **验证方式**：真机用 `StartupMetrics` 已有埋点画一次「冷启动」与「切后台再回来」的时间线；对比修复前后 `audit.*` 各 mark 耗时；用 Instruments 的 Time Profiler 看主线程热点是否落在 `fetchSleepNights`/`getPendingNotificationRequests`/`context.fetch`。

### SVC-09 · P2 · 全景搜索每次打开都清空并重建 18 张表索引，重复全表拉取

- **优先级**：P2（打开搜索的第一秒不可用/结果不完整；万级数据时明显卡顿）
- **状态**：**确认**（性能与「清空重建」确认；「结果短暂缺失」的可见程度为**疑点**，取决于用户输入速度）
- **位置**：`Assistant/Services/SearchIndexService.swift:268-276`（`rebuildIndex` 先 `engine.clear()`）、`:285-660`（18 张表 `try? context.fetch`，多数 `fetchLimit = 800`，逐条拼音分词）、`:660-675`（分批 `Task.yield()`）、`:678-692`（`search` 不检查 `isIndexing`）；触发点：`Assistant/Features/UnifiedSearchView.swift:105-107`（每次 sheet 打开都 `await searchIndex.rebuildIndex`）、`:119`（手动刷新按钮）、`Assistant/Features/TodoListView.swift:381-386`（首屏延迟 900ms 再重建）
- **代码证据**：

  ```swift
  // SearchIndexService.swift:268
  public func rebuildIndex(context: ModelContext) async {
      guard !isIndexing else { return }
      isIndexing = true
      defer { isIndexing = false }
      engine.clear()                 // 先清空
      hasIndexedStaticSettings = false
      indexStaticSettings()
      await Task.yield()
      ...
      for ... { if let x = try? context.fetch(desc) { batch.append(...) } }  // 18 张表
  ```

- **触发条件**：每次打开「全景索引搜索」sheet（用户的高频入口），或从待办页首屏。
- **用户影响**：每次打开都重新拉 18 张表（最多约 1.4 万条文档）并重做拼音分词；期间 `search()` 在**已被清空的引擎**上工作，用户快速输入时可能得到「无结果」或残缺结果（视图在 `searchResults.isEmpty && isIndexing` 时显示「正在全域倒排索引检索…」，但结果列表在索引补齐前不会自动重算——`runSearch` 只由输入变化触发）。
- **修复建议**：
  1. 索引常驻 + 增量更新：按模型日期/变更游标增量重建（或提供 `reindex(ifNeeded:)`，以「上次索引完成时间 + 数据变更计数」作指纹），sheet 打开时只做指纹校验。
  2. 重建时不要先 `engine.clear()`；改为构建新引擎实例，完成后原子替换（`let newEngine = SearchIndexEngine(); ... self.engine = newEngine`）。
  3. `search()` 在 `isIndexing` 且结果为空时给「索引未就绪」态，并在重建完成后主动重跑最近一次查询（`searchIndex.search(query:lastQuery)`）。
- **验证方式**：在 `UnifiedSearchView` 打开后立刻输入一个已存在的待办标题，断言能命中（修复前可复现「无结果」）；用 Instruments 测量打开 sheet 到可交互的耗时；万级待办下对比重建耗时与内存。

---

## P3

### SVC-10 · P3 · 152 处 `try? fetch` 把「读失败」压成「空数据」

- **优先级**：P3（单点影响小，但分布广，其中 3 类会产生可见错误结果）
- **状态**：**确认**（机制与代表性危害确认；单个触发条件属低频，但分布广）
- **位置与证据**（统计：`try? context.fetch` 共 152 处，`try? ... save` 46 处 / 17 个文件）：
  - `Assistant/Services/DailyPainPointAuditor.swift:333-343`：

    ```swift
    let existing = (try? context.fetch(FetchDescriptor<TodoItem>(predicate: ...))) ?? []
    if existing.isEmpty { context.insert(TodoItem(...)); TodoNotificationManager.shared.scheduleNotification(for: todo) }
    ```
    读失败 → 视为「没有同名待办」→ 插入重复待办 + 重复通知（这正是 CR-10 修过的形状，只是换到巡检服务）。
  - `Assistant/Services/DataMigrationService.swift:196-240`（`getLocalDataStats`）：20 个 `try? fetchCount ?? 0`，读失败时「数据备份与迁移」页把「待办 0、账本 0」当真实统计展示，用户会以为数据丢了。
  - `Assistant/Services/SearchIndexService.swift:285-660`：16 处 `try? fetch`，失败分类静默缺席，搜索少一整类结果且无任何提示。
  - 本工作树新增代码亦同形状：`Assistant/Services/SleepReminderScheduler.swift:295-321`（`try? context.fetch` 饮食/饮水，读失败即当「今天没有摄入」→ 睡前计划少算咖啡因）、`:336-350`（服药计划读失败 → 少算睡前药）。
- **触发条件**：SwiftData fetch 抛错（库损坏、迁移不完整、存储受限）。
- **用户影响**：非破坏性的多数场景（统计/索引缺项）属体验降级；`DailyPainPointAuditor` 这一处会产生重复待办与重复通知；`getLocalDataStats` 会让用户在数据迁移前误判「数据没了」而做出错误操作。
- **修复建议**：按 CR-09/CR-10 的口径区分「读失败 / 确实为空」：读失败要么 `throw`/返回可选、要么在 UI 上明确「统计不可用」；插入型路径（`upsertTodo`、`PlaceLearningEngine.recordObservation:51`）必须先确认 fetch 成功再 insert。
- **验证方式**：写一个临时包装：把 `context.fetch` 换成抛错实现（或注入损坏 store），断言 ① `getLocalDataStats` 不再返回全 0；② `auditSubscriptions` 不新增待办；③ 搜索界面提示索引不可用。静态验证：`upsertTodo` 内不再有 `(try? context.fetch(...)) ?? []`。

### SVC-11 · P3 · WebDAV 钥匙串写入结果被丢弃：存密码「成功」但实际没写进 Keychain

- **优先级**：P3（低概率但会静默丢失凭据）
- **状态**：**确认**
- **位置**：`Assistant/Services/WebDAVSyncService.swift:286-298`（`saveSecret` 忽略 `SecItemAdd` 返回值）；调用方 `:32-40`（`saveConfig` 无条件认为保存成功）、`:64-68`（`setAutoSyncPIN` 先 `deleteSecret` 再 `saveSecret` 失败也返回成功）
- **代码证据**：

  ```swift
  private func saveSecret(_ value: String, account: String) {
      guard let data = value.data(using: .utf8) else { return }
      deleteSecret(account: account)                       // 先删旧的
      let query: [CFString: Any] = [..., kSecValueData: data, ...]
      SecItemAdd(query as CFDictionary, nil)               // 结果被丢弃：写失败时旧密码已删、新密码没写
  }
  ```

  对比同仓 `AppLockManager.saveToKeychain`（`:161-175`）会返回 Bool 并检查。
- **触发条件**：钥匙串写入失败（设备锁屏 + `ThisDeviceOnly` 的可访问性、钥匙串损坏、配额/权限异常）。
- **用户影响**：UI 回「保存成功」，但登录凭据丢失（且旧凭据已被删除）；后台自动备份随后静默跳过（`hasPassword == false`），与 SVC-02 叠加成「看起来都配好了、其实什么都不工作」。
- **修复建议**：`saveSecret` 返回 Bool/`throws`；`saveConfig(password:)`、`setAutoSyncPIN` 在失败时抛错并回滚（不要先删旧的，或失败时恢复旧值）；UI 如实提示「无法写入钥匙串」。
- **验证方式**：注入失败（可在 DEBUG 下把 `SecItemAdd` 包一层可注入的 seam），断言 `setAutoSyncPIN` 抛错且旧 PIN 仍可读；模拟钥匙串重置后重开 App，UI 应显示「未配置密码」而不是「已保存」。

### SVC-12 · P3 · `Persistence` 全局容器：可变静态状态、无 actor 隔离、打不开就 `fatalError`

- **优先级**：P3（当前 Swift 5 模式运行正常；Swift 6 就绪度/健壮性）
- **状态**：**确认**（无隔离标注、`fatalError` 为静态事实）；「首个访问线程非主线程」为**疑点**
- **位置**：`Assistant/Services/Persistence.swift:7-11`（`private static var storedRecoveryError` + 计算属性 `recoveryError` 强制 `_ = shared`）、`:26-51`（`static let shared`，失败时写 `storedRecoveryError`，最终 `fatalError`）、`:43`、`:48`
- **代码证据**：

  ```swift
  enum Persistence {
      private static var storedRecoveryError: String?      // 可变全局状态
      static var recoveryError: String? { _ = shared; return storedRecoveryError }
      static let shared: ModelContainer = { ... }()        // 无 @MainActor；首次访问线程同步打开数据库/迁移
      ...
      fatalError("无法打开数据库或恢复页: \(error)")        // 恢复页也建不出来时直接崩
  }
  ```

- **触发条件**：Swift 6 严格并发编译；或恢复页内存容器也创建失败；或（疑点）首次访问 `Persistence.shared` 的线程不是主线程（例如未来从后台队列/Intent 直接取 mainContext）。
- **用户影响**：目前无已知线上故障；风险是「恢复页也失败时直接崩溃」和迁移/打开数据库发生在非预期线程。Swift 6 迁移时会成为编译错误（需改成 `@MainActor` + `nonisolated(unsafe)` 或 `Mutex`）。
- **修复建议**：给 `Persistence` 加 `@MainActor`（其使用方几乎全是 `@MainActor`），`storedRecoveryError` 收进一个 `@MainActor` 的 recovery 状态对象；把 `fatalError` 换成「最后一级降级：无容器的只读空壳 + 调起系统分享导出 store 文件」或在 App 层兜底展示。
- **验证方式**：以 `SWIFT_STRICT_CONCURRENCY=complete` + `-swift-version 6` 对 Services 做一次类型检查（不跑全量构建），确认报错点；构造一个 store 文件不可读且内存容器创建失败的环境（可注入一个必然抛错的 `Schema`）验证不再 `fatalError`。

### SVC-13 · P3 · EventKit 同步查询/写入在 MainActor 上执行

- **优先级**：P3（大日历用户进页面/保存时轻微卡顿）
- **状态**：**确认**（调用线程确认；耗时未实测）
- **位置**：`Assistant/Services/CalendarAgendaService.swift:18`（`@MainActor final class`）、`:82`（`store.events(matching:)` 同步全量物化 7 天日程）、`:143`（`store.save(event)`）、`:155`（`store.remove(event)`）
- **代码证据**：

  ```swift
  let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
  events = store.events(matching: predicate)      // 同步、在 MainActor 上
      .sorted { $0.startDate < $1.startDate }
      .map { AgendaEvent(...) }
  ```

- **触发条件**：首页/日历卡片每次进入时 `loadEvents(daysAhead: 7)`；用户把待办写入/删除系统日历。
- **用户影响**：日历账号多（iCloud + Exchange + Google + 订阅日历）且事件多时，同步查询是 XPC 阻塞调用，主线程会有几十~几百毫秒卡顿；写操作同理。
- **修复建议**：把 `events(matching:)` 与 `save/remove` 挪到 `Task.detached`（`EKEventStore` 可在后台队列使用，注意每次操作在同一个后台队列/或按 Apple 建议使用专用队列），只把 `[AgendaEvent]` 回主 actor。
- **验证方式**：真机上连接一个事件量 >5k 的日历账号，用 Time Profiler 看 `loadEvents` 主线程耗时；对比修复后。

### SVC-14 · P3 · 记账→饮水→Apple 健康联动失败全静默

- **优先级**：P3（联动功能静默失效，用户以为已同步）
- **状态**：**确认**
- **位置**：`Assistant/Services/HealthKitService.swift:212-226`（`recordWaterIntake`：`catch { return false }`，不写 `lastError`、不提示）；调用方 `Assistant/Services/ExpenseWaterService.swift:66-77`（`Task { let success = await ...; if success { ... try? context.save() } }`——失败分支什么都不做）；同类：`Assistant/Services/SmartHomeService.swift:21-35`（场景失败返回 false）与 `HabitAndMedicationScheduler.swift:48-51`（`_ = await ...triggerScene` 忽略结果）
- **代码证据**：

  ```swift
  // HealthKitService.swift:219
  do {
      try await store.save(sample)
      await refreshToday()
      return true
  } catch {
      return false          // 无 lastError、无日志、无 UI
  }
  ```

- **触发条件**：用户未授予写权限 / 健康数据库写入失败 / 设备不支持；或 HomeKit 场景名不存在、中枢离线。
- **用户影响**：饮水记录上的「已同步健康」标记不亮，但界面没有解释；用户无法区分「没同步」与「同步失败」。HomeKit 场景同理（家务习惯里的「触发扫地机」失败无感知）。
- **修复建议**：`recordWaterIntake` 在失败时写 `lastError`（供健康页诊断），联动侧在失败时给一次性低打扰提示（或在饮水记录行上显示「未同步·点击重试」）；`triggerScene` 失败时把原因回传给调用方并在习惯详情显示。
- **验证方式**：关闭健康写权限后记一笔咖啡账，断言出现失败提示/可重试入口；HomeKit 场景改名后打卡习惯，断言界面提示「场景未找到」。

### SVC-15 · P3 · 通知分类注册的「读-改-写」覆盖风险（疑点）

- **优先级**：P3（低概率，但一旦发生会丢掉「完成/推迟/已取件」按钮——正是「免掏手机」闭环的载体）
- **状态**：**疑点**（并发窗口存在，未实测复现）
- **位置**：`Assistant/Services/NotificationCategoryRegistry.swift:9-26`（冷启动合并注册，单次 read-modify-write）；`Assistant/Services/TodoNotificationManager.swift:65-78`（每次 `syncAllTodoNotifications` 都 fire-and-forget `registerCategories()`，读全量分类后 `insert` 自己的再 `setNotificationCategories`）；同类各自注册还有 `SleepReminderScheduler.swift:113-126`、`TripArrivalService.swift:66-72`、`WeatherAlertService.swift:601-603`、`LiveActivityService.swift:189-193`、`PickupCheckoutService.swift:66-68`
- **代码证据**：

  ```swift
  // TodoNotificationManager.swift:65
  public func registerCategoriesAsync() async {
      var updated = await center.notificationCategories()   // 读全量
      updated.insert(makeCategory())                        // 改
      center.setNotificationCategories(updated)             // 写回全量：覆盖并发期间别处的 insert
  }
  ```

- **触发条件**：冷启动时 `NotificationCategoryRegistry.registerAllCategoriesAsync()` 与 `syncAllTodoNotifications → registerCategories()` 的 `await` 交错（两者都在 MainActor，但 `await center.notificationCategories()` 是挂起点）。
- **用户影响**：若覆盖发生在启动期，某类通知可能缺少 action 按钮，用户在锁屏/手表上无法一键完成/推迟，只能打开 App（与「免掏手机」目标冲突）。
- **修复建议**：全仓只保留 `NotificationCategoryRegistry.registerAllCategoriesAsync()` 一个写入点（`TodoNotificationManager.registerCategories` 删除或改为调用它），或用一个串行 actor 包住所有 read-modify-write。
- **验证方式**：在 `setNotificationCategories` 前插入随机 50–200ms 延时模拟交错，冷启动 20 次后断言 `notificationCategories()` 包含全部 7+ 个分类；静态验证：全仓 `setNotificationCategories` 只剩 1 处调用。

---

## 覆盖边界

- **已逐行/逐段实读**：`Persistence.swift`、`WebDAVSyncService.swift`、`BackgroundRefreshCoordinator.swift`、`AppBackgroundManager.swift`、`DataMigrationService.swift`、`Migration/DataMigrationService+Export.swift`（重点段）、`LLMModelManager.swift`（全部关键段）、`VisionModelManager.swift`（校验/目录段）、`LocationReminderService.swift`、`HealthKitService.swift`（读写与查询段）、`SleepReminderScheduler.swift`、`HabitAndMedicationScheduler.swift`（排期段）、`TodoNotificationManager.swift`、`TravelTicketReminderManager.swift`（确认/通知段）、`PlaceLearningEngine.swift`（记录/保存段）、`DailyPainPointAuditor.swift`、`SupportServices.swift`、`ImportService.swift`、`SearchIndexService.swift`（rebuild/search 段）、`OCRService.swift`（识别入口段）、`PasswordVaultCrypto.swift`、`AppLockManager.swift`、`CalendarAgendaService.swift`、`SmartHomeService.swift`、`AssistantPackageService.swift`、`NearbyShareService.swift`（会话/收发段）、`VoiceMemoAudioService.swift`（计时器/播放段）、`VoiceIntentProcessor.swift`（写库/回执段）、`LLMInferenceService.swift`（模型加载/远程端点/侧效应段）、`Inference/*`（4 个文件，全文）。
- **按形状 grep 覆盖、未逐行读**：`PeriodicReportManager.swift`（1,832 行，只读报告生成与通知排期段）、`Migration/DataMigrationService+Restore.swift`（1,146 行，只读入口/清库/落库/回滚段）、`Migration/BackupPackageModels.swift`、`VoiceIntentProcessor.swift` 的解析器部分、`PsychReminderScheduler`/`RecurringExpenseManager`/`BudgetAlertService`/`BatteryReminderService`/`AnniversaryReminderManager`/`WidgetSnapshotSync`（上轮已重点审过，只复核未回归）。
- **未覆盖（建议下一轮单独排）**：`Assistant/App/AssistantApp.swift` 的完整生命周期与 Intents 入口编排（本轮只引用其触发顺序）、`Psych*` 三个服务的完整策略、`LiveActivityService` 的全部生命周期分支、`LocalizationManager`/`SeniorModeManager`/`TabBarManager` 的全局状态、Inference 的 llama.cpp C 接口细节、真机故障注入（本轮全部为静态确认，未做抛错注入与真机复现）。

## 附：本轮静态扫描计数（供复核）

- `Assistant/Services/**/*.swift`：85 文件 / 29,879 行。
- `try?`：325 处；其中 `try? context.fetch*`：152 处；`try? context.save()`：46 处 / 17 个文件。
- 空 `catch {}`：0 处（脚本扫描全部 catch 块体为空白的为 0）。
- `Task {}`/`Task(`：93 处；`Task.detached`：9 处（`VisionModelManager`、`LLMModelManager`、`OCRService`、`FoodVisionService`、`SupportServices`）。
- `DispatchQueue.main.sync`：0 处；`print(`：28 处（无敏感字段）。
- `SecItemAdd/SecItemCopyMatching`：`WebDAVSyncService`、`AppLockManager`、`PasswordVaultCrypto` 三处；敏感配置均未写入 UserDefaults（`SettingsSnapshot` 白名单核对无口令/PIN/WebDAV 密码键）。
- 验证记录：本轮**未运行** `xcodebuild`/`swift test`/真机，全部结论为静态确认（已在各条「验证方式」给出可执行步骤）。
