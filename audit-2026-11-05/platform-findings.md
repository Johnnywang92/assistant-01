# 平台层审计（2026-11-05）

- **审计对象**：当前工作树（HEAD `0b04489` + 未提交改动 10 个文件；未 reset / 未 checkout）。
- **范围**：`Assistant/Models/`、`Assistant/App/`、`Assistant/Intents/`、`Assistant/Theme/`、`WidgetShared/`、`AssistantWidgetExtension/`、`ShareExtension/`、根目录 `project.yml`、`Assistant/Info.plist`、`Assistant/Assistant.entitlements`、`Assistant/InfoPlist.xcstrings`、`Assistant/Localizable.xcstrings`、`README.md` / `README.en.md`。
- **方法**：只读静态审查 + 配置/目录静态比对脚本；另在 `/tmp` 用 XcodeGen 2.46.0 做了 1 次最小工程生成实验（不触碰仓库工程与 plist）。未跑完整 `xcodebuild`，未跑真机/模拟器。
- **去重基线**：已读 `code-review-2026-10-29.md`（CR-01～CR-11 已修）与 `todo.md` 全部实施记录；本报告只记「当前树仍存在」且未在两者中记录为已修/遗留已知项的问题。与 CR-01/CR-06 同区域的条目已在正文注明差异。
- **结论**：确认 12 条、疑点 3 条，合计 15 条——**P1 1 条、P2 9 条、P3 5 条**。其中 PLT-01（用户输入从不落库）、PLT-04（分享载荷可被误删）、PLT-09（版本号配置失效）证据最硬、可直接动手。
- 交付限制：本轮只允许写本文件，未修改任何 `.swift` / 工程文件 / plist / 文案文件。

## 摘要表

| 编号 | 优先级 | 状态 | 一句话 | 位置 |
| --- | --- | --- | --- | --- |
| PLT-01 | P1 | 确认 | `ExpenseRecord` 的原始单据与 AA 分摊字段标成 `@Transient`，用户输入从不落库 | `Assistant/Models/ExpenseModel.swift:78-81` |
| PLT-02 | P2 | 确认 | 43 个 `@Model` 零索引、零唯一约束，高频字段全表扫描 | `Assistant/Models/Models.swift:171-224` |
| PLT-03 | P2 | 确认 | 共享快照无时效/空态校验，过期/缺失快照被当成「今天真的没有」 | `WidgetShared/WidgetSnapshot.swift:76-80` |
| PLT-04 | P2 | 确认 | 分享中转区 JSON 非原子写 + 解码失败即删，载荷可被永久丢弃 | `WidgetShared/ShareImportBridge.swift:103-143` |
| PLT-05 | P2 | 确认 | 分享图片全分辨率解码/编码，无降采样、无总量上限 | `ShareExtension/ShareViewController.swift:54-59` |
| PLT-06 | P2 | 确认 | `InfoPlist.xcstrings` 缺 4 条权限说明与 11 条快捷方式文案的英文 | `Assistant/InfoPlist.xcstrings:101-136,188-199,251-280` |
| PLT-07 | P2 | 确认 | 代码引用但目录缺失的静态本地化 key 262 个；1247/4929 键无英文 | `Assistant/Localizable.xcstrings`（全文） |
| PLT-08 | P2 | 确认 | 小组件/分享扩展/AppIntents 不带任何本地化资源，英文用户看到中文 | `project.yml:151-160,175-185` |
| PLT-09 | P2 | 确认 | `MARKETING_VERSION 0.1.0` 对生成的 Info.plist 无效，实际发版号恒为 1.0 | `project.yml:52-58` / `Assistant/Info.plist:43-46` |
| PLT-10 | P2 | 疑点 | 首帧前仍在主线程同步打开 SwiftData；250ms 盲等覆盖不到开库耗时 | `Assistant/App/AssistantApp.swift:64,76,92,113` |
| PLT-11 | P3 | 确认 | Intent 自由文本枚举参数静默兜底、数值参数无上下界 | `Assistant/Intents/ContextTriggerIntent.swift:15-28` |
| PLT-12 | P3 | 确认 | 分享信封解析不校验版本/金额/分数范围/体积 | `Assistant/Models/NearbySharePayload.swift:346-500` |
| PLT-13 | P3 | 疑点 | 共享快照跨进程 read-modify-write 无锁（指令队列有锁） | `WidgetShared/WidgetSnapshot.swift:110-123,195-206` |
| PLT-14 | P3 | 疑点 | 常规启动路径绕过版本化迁移计划，未来自定义阶段可能永不执行 | `Assistant/Services/Persistence.swift:26-40,67-77` |
| PLT-15 | P3 | 确认 | 分享扩展在内容未变化时也调用 `reloadAllTimelines`，挤占小组件刷新预算 | `ShareExtension/ShareViewController.swift:78-82` |

> 说明：PLT-13、PLT-14、PLT-10 是与本轮工作树/近期提交强相关的疑点，已单独写明「需要什么证据才能定性」，不计入确认项。

---

## PLT-01 · P1 · 记账的原始单据与 AA 分摊字段被 `@Transient` 排除，用户输入从不落库

- **状态**：确认（静态调用链完整；未做真机 UI 验证）。
- **位置**：
  - `Assistant/Models/ExpenseModel.swift:78`（`@Transient public var receiptImageData: Data?`）、`:79`（注释：*Kept out of the legacy ExpenseRecord schema so old stores can open safely.*）、`:80`（`@Transient public var splitCount: Int = 1`）、`:81`（`@Transient public var splitParticipants: String = ""`）、`:112-114`（init 里把它们重置为空）。
  - 写入端：`Assistant/Features/ExpenseTrackerView.swift:2497`、`:2499-2500`（编辑保存）、`:2523`、`:2525-2526`（新建保存）；附件选择 `:2357`、`:2378`；AA 表单 `:2218-2221`。
  - 读取端：编辑回填 `:2267-2268`；分享账单 `:2599-2609`（`if record.receiptImageData != nil` / `Text("这笔账单没有保存原始单据")`）；分享卡片 `Assistant/Features/ExpenseShareCardView.swift:344`。
  - 备份：`Assistant/Services/Migration/BackupPackageModels.swift:201-217`（`ExpenseDTO` 无这三个字段）。
- **证据**：SwiftData 的 `@Transient` 明确表示「不写库、不参与 schema」，因此 `record.receiptImageData = ...`、`record.splitCount = ...` 只在当前进程内存对象上有效；任何一次重开 App / 重新 fetch 之后读回都是 `nil` / `1` / `""`。UI 却按「已持久化」使用：编辑页从 `record.receiptImageData` 回填、分享面板据此判断能否「附上原始单据/小票」、AA 分摊区从 `record.splitCount` 回填参与人数。
- **触发条件**：记账时拍照/选择原始单据并保存，或在「AA 分摊（可选）」填参与人数/姓名后保存；之后重启 App、重新进入该笔编辑页，或做账单分享。
- **用户影响**：报销用的原始单据照片、AA 分摊信息静默消失——用户以为已保存；重启后编辑页显示「这笔账单没有保存原始单据」，分享卡片永远无法附单据；备份/换机同样没有这部分数据。属于「数据丢失」级别，与 CR-01（分享失败仍删载荷）同类但根因不同。
- **修复建议**：
  1. 开 `AssistantSchemaV10`：`@Attribute(.externalStorage) var receiptImageData: Data?`（或按 `IDPhotoStorage` 的做法存 `receiptImageFileName` + 沙盒文件，避免库文件膨胀），并新增持久化字段 `var splitCount: Int = 1`、`var splitParticipants: String = ""`；走 `.lightweight` 阶段。
  2. `ExpenseDTO` 补对应字段，导出/还原/附件预检/孤儿清理四处接线（参考 `DataMigrationService+Export.swift` 的证件照附件路径）。
  3. 加一条纪律测试/闸门：持久模型上新增 `@Transient` 必须带白名单注释理由（与 `check_settings_keys.py` 同风格），防止再次把用户输入丢进内存态字段。
- **验证方式**：新增一笔→拍照/填 AA→保存→杀进程重开→编辑页能看到单据与分摊人数；分享账单可勾「附上原始单据」；导出加密备份→还原到干净库→仍可见；`grep -n "@Transient" Assistant/Models/` 只剩派生/缓存字段。

---

## PLT-02 · P2 · 43 个 `@Model` 零索引、零唯一约束，高频字段全表扫描

- **状态**：确认（`#Index` / `#Unique` / `@Attribute(.unique)` 全仓命中数 = 0；查询点已逐一核对）。
- **位置**：
  - 模型字段：`Assistant/Models/Models.swift:171-224`（`TodoItem.statusRaw` / `dueAt` / `createdAt` / `completedAt`）、`Assistant/Models/ExpenseModel.swift:63-81`（`ExpenseRecord.date` / `categoryRaw` / `isIncome`）、`Assistant/Models/HealthDaySnapshotRecord.swift:18-22`（`day`，注释声称「同一天只应有一条」）、`Assistant/Models/MentalHealthModels.swift:100-109`（`MoodCheckInRecord.day`，同样声称日唯一）、`Assistant/Models/SkillPathModel.swift:145-155`（`SkillPracticeLog.pathID`）、`Assistant/Models/DialogueRecord.swift:42-51`（`sessionID` / `timestamp`）、`Assistant/Models/Models.swift:464-481`（`RawMessage.receivedAt`）。
  - 高频查询：`Assistant/Features/MainTabView.swift:11`（`statusRaw == "active"` 的 `@Query`，待办变更即重跑）、`Assistant/Features/TodoListView.swift:24`（`statusRaw == "done"`）、`Assistant/Services/WidgetSnapshotSync.swift:27-29`、`:57-60`、`:105-112`（启动/回前台/回后台/每次通知交互都跑）、`Assistant/Services/MedicineReminderSupport.swift:1042`、`Assistant/Services/LifeQueryService.swift:204`、`Assistant/Models/HealthDaySnapshotRecord.swift:138-142`（按 `day` 查旧记录）。
- **证据**：上述谓词字段都没有对应索引；`#Index` 是 iOS 18 引入的 SwiftData API，而 `project.yml:4-5` 的 deployment target 已是 iOS 18.0，因此不是版本限制。项目自己在 `todo.md` 2026-10-29 CR-09 记录过「列表成本约 15µs/行，与索引无关，只能靠谓词/分页解决」——但那是**单次窗口查询**的结论；跨越多个月的窗口（`date >= windowStart`）与「活跃/已完成状态」这类低基数过滤无可避免要扫全表，索引才是正解。
- **触发条件**：账本/待办历史增长到数千～万条后，每次冷启动刷新快照、每次勾选（触发 `@Query` 重算）、健康数据每次 `upsert`、Siri 查询预算等。
- **用户影响**：主线程扫描成本随历史线性增长（1 万行 × 15µs ≈ 150ms/次，且同一动作常叠加多次查询），表现为冷启动白屏时间变长、勾选/切换卡顿、小组件与 Siri 路径延迟。数据量越大越明显，且不会随时间自愈。
- **修复建议**：
  1. 开 `AssistantSchemaV10`（纯索引/唯一约束变更，配 `.lightweight` 阶段）并在模型里加：
     - `#Index<TodoItem>([\.statusRaw], [\.dueAt], [\.completedAt])`
     - `#Index<ExpenseRecord>([\.date], [\.categoryRaw])`
     - `#Unique<HealthDaySnapshotRecord>([\.day])`、`#Unique<MoodCheckInRecord>([\.day])`（同时把 upsert 的「先查后插」改成依赖唯一约束，消除并发/时区漂移下的重复日行）
     - `#Index<SkillPracticeLog>([\.pathID])`、`#Index<DialogueMessageRecord>([\.timestamp], [\.sessionID])`、`#Index<RawMessage>([\.receivedAt])`
  2. 用 `scripts/migration-drill` 验证万条旧库升级后查询仍正确、索引生效。
- **验证方式**：`migration-drill`（V9 万条库 → V10）通过；对 `default.store` 用 `EXPLAIN QUERY PLAN` 确认 `statusRaw`/`date`/`day` 查询走 index；对照 `WidgetSnapshotSync.refreshSnapshot` 与首屏 `mainTab.onAppear` 的 os_signpost 耗时，目标 ≥50% 改善；`swift test` 补一条规模测试断言 1 万条分类/窗口查询 < 阈值。

---

## PLT-03 · P2 · 共享快照没有时效与「空 vs 未知」区分，过期快照被当成今天

- **状态**：确认（`generatedAt` 全仓无读取点，grep 验证；三处消费方已核对）。
- **位置**：
  - 快照模型：`WidgetShared/WidgetSnapshot.swift:76`（`generatedAt`）、`:78-80`（`.empty` 用 `.distantPast`）、`:110-117`（解码失败/不存在都返回 `.empty`）。
  - 消费方：`AssistantWidgetExtension/AssistantWidgetBundle.swift:32-40`（15 分钟 timeline 策略，只读快照）；`AssistantWidgetExtension/AssistantWidgets.swift:22-30`（空 → 「今日待办已清空」）、`:154-190`（空 → 「暂无待取快递」）、`:199-221`（支出读数无任何时效校验）、`:259-271`；
  - Intent 侧：`WidgetShared/WidgetIntents.swift:384-397`（`snapshot.parcels` 为空即答「目前没有待取的快递」）、`:412-423`（无 hook 时直接答「今日已累计支出 X 元」——快照缺失时 X=0）、`:436-454`（空 → 「今日待办已全部清空，好好休息吧！」）。
- **证据**：快照只在主 App 运行时由 `Assistant/Services/WidgetSnapshotSync.swift:16-21` 重建；扩展每次 timeline 刷新只是重读同一个 UserDefaults blob。`generatedAt` 从未被读，因此「昨天 23:50 写入的快照」与「刚刚写入的快照」在组件/Siri 眼里没有区别；`.empty`（`generatedAt == .distantPast`）与「今天真的没有待办/支出」也同样不可区分。
- **触发条件**：用户安装后从未打开 App；或连续两天以上未打开 App；或主 App 写快照失败（磁盘满/扩展被限）后系统仍按 15 分钟刷新组件；或 Siri 在 App 未启动时走扩展兜底分支。
- **用户影响**：桌面/锁屏组件显示「几天前的今日待办/今日支出」，用户误以为是当前值；Siri 说「今日待办已全部清空，好好休息吧」「今日已累计支出 0 元」「目前没有待取的快递」，而实际上本地是「没有可用数据」。这与项目在 CR-09 中确立的「读失败 ≠ 空账本、不能用 0 顶替」纪律直接冲突，且发生在用户最信任的免掏手机入口。
- **修复建议**：
  1. 给 `WidgetSnapshot` 增 `hasData: Bool`（或让 `generatedAt == .distantPast` 作为哨兵），并在所有读取点统一走 `WidgetSnapshotStore.loadFresh()`：非当日（`Calendar.current.isDateInToday(generatedAt)`）即视为不可用。
  2. 组件在不可用时渲染「打开小助刷新」而不是「已清空」；Intent 在扩展兜底分支回复「本地快照是 N 天前的 / 尚未同步，请打开小助」，不要给出金额 0。
  3. timeline 的 `getTimeline` 里按 `generatedAt` 判断，旧快照时把 `policy` 改为较短间隔或在 UI 标注「上次同步 …」。
- **验证方式**：直接改 App Group UserDefaults 里的 `widget_shared_snapshot_v1` 为前一天日期，预览组件 + Siri 查三项；删掉该 key（模拟从未同步）；让 App 静置过夜后再看组件；断言三处文案不再是「已清空/0 元」。

---

## PLT-04 · P2 · 分享中转区 JSON 非原子写入 + 解码失败即删，载荷可被永久丢弃

- **状态**：确认（静态路径成立；未做双进程压力复现）。**注意**：这是 CR-01 修复之后仍存在的另一条删除路径——CR-01 处理的是「处理失败后删载荷」，本条是「读取竞争/写半截被当作损坏而删」。
- **位置**：`WidgetShared/ShareImportBridge.swift:103-116`（`write(_:to:)` 用 `try data.write(to: jsonURL)`，**未带 `.atomic`**；JSON 写失败才回收图片）、`:122-143`（`peekAll()` 对解码失败的 `*.json` 直接 `try? fm.removeItem(at: file)` 后 `continue`）、`:155-166`（同一文件的 `recordFailure` 反而用了 `options: .atomic`，说明作者知道原子写）；排空侧 `Assistant/Services/ShareInboxService.swift:41-44`（启动/回前台/后台巡检都会跑）。
- **证据**：写入端与读取端在不同进程（分享扩展 vs 主 App），`data.write(to:)` 默认非原子：读者可能看到「文件已创建但内容尚未写完」的中间态。`peekAll` 把任何 `JSONDecoder` 失败都归类为「损坏」并立即删除，没有「文件可能仍在写入」的宽限策略。分享扩展在写 JSON 中途被杀时也会留下同样的半截文件。
- **触发条件**：主 App 正在后台巡检/回前台排空分享中转区，而分享扩展同时把一条分享写入 App Group（两进程并发）；或分享扩展写入过程中被系统回收。概率低但一旦命中即不可恢复。
- **用户影响**：用户刚分享的文本/链接/图片被主 App 当「损坏文件」删除：JSON 删除后图片文件变成孤儿或一并丢失，且没有任何「分享导入失败」通知（因为根本没走到处理逻辑）。属于静默数据丢失。
- **修复建议**：
  1. 写入改 `try data.write(to: jsonURL, options: .atomic)`（与 `recordFailure` 一致）。
  2. `peekAll` 遇到解码失败时不要删除：移动到 `ShareInbox/quarantine/` 并在文件名带时间戳；或仅在文件 `mtime` 早于当前 24h 时才清理。
  3. 跳过 `contentModificationDate` 在最近 5 秒内的文件（仍可能被写入），下一轮再读。
  4. 补一条故障注入单测：写一个截断 JSON，断言 `peekAll` 不删文件、不产出载荷，且后续正常载荷仍可处理。
- **验证方式**：单测（截断 JSON/半写文件）断言保留；在真机上「刚分享立刻回 App」反复 20 次不丢；扩展被强制中断后再回 App 检查 quarantine 目录。

---

## PLT-05 · P2 · 分享图片全分辨率解码/重编码，无降采样与总量上限

- **状态**：确认（代码路径成立；扩展内存上限具体数值未实测）。
- **位置**：`ShareExtension/ShareViewController.swift:54-59`（`provider.loadObject(ofClass: UIImage.self)` → `image.jpegData(compressionQuality: 0.85)`，原始像素全保留）、`:63-80`（URL/文本分支）；`project.yml:200-203` 与 `ShareExtension/Info.plist` 的 `NSExtensionActivationSupportsImageWithMaxCount: 10`（最多 10 张）；`WidgetShared/ShareImportBridge.swift:135-139`（`peekAll` 对每条载荷同步 `Data(contentsOf:)` 读图片）；`Assistant/Services/ShareInboxService.swift:41-44`（一次性把全部载荷与图片字节读进内存后才逐条处理）。
- **证据**：12MP 照片解码后的 `UIImage` 约 48MB，重新 JPEG 编码再叠加一份压缩缓冲；分享扩展的系统内存预算远低于主 App，多张图片同时经 `loadObject` 回调时峰值可达数倍。写进 App Group 的也是全分辨率 JPEG（3–5MB/张），10 张即 30–50MB。回主 App 后 `peekAll` 先把**所有**待处理图片字节同时读入内存（可能积压多天），再逐条 `UIImage(data:)`，这段磁盘 I/O 还是同步、由启动/体检路径触发。
- **触发条件**：从相册多选 3–10 张大图分享；或多天的分享积压在一起后首次打开 App。
- **用户影响**：分享扩展可能因内存超限被系统终止（用户看到分享面板闪退、内容未收到，也没有失败提示）；主 App 冷启动/回前台时一次性读几十 MB 图片并解码，造成首屏卡顿与内存尖峰；App Group 磁盘占用被多份全分辨率副本挤占。
- **修复建议**：
  1. 扩展侧写入前用 `CGImageSourceCreateThumbnailAtIndex` 降采样（长边 ≤ 2048、`kCGImageSourceCreateThumbnailFromImageAlways`），或直接写原始文件字节、把压缩留给后续 OCR 管线；单次分享总量上限（例如 20MB）与张数上限（例如 5 张），超限在扩展内提示。
  2. `ShareImportBridge` 拆成 `list()` 只读 JSON 元数据 + `loadImage(payload)` 按需读单张；`ShareInboxService` 逐条加载、处理后立即释放，并限制单轮处理条数。
- **验证方式**：分享 10 张大图，Xcode Memory Graph 观察扩展与主 App 峰值（记录改造前后）；`du -sh` App Group 目录；冷启动 os_signpost 对比 `ShareInboxService.processAll` 耗时；真机反复分享-回前台不触发 jetsam。

---

## PLT-06 · P2 · `InfoPlist.xcstrings` 缺 4 条权限说明与 11 条快捷方式文案的英文

- **状态**：确认（目录文件解析结果；未切英文真机看弹窗）。
- **位置**：
  - 只有 `zh-Hans`、`en` 缺失的权限说明：`Assistant/InfoPlist.xcstrings:101-112`（`NSHealthShareUsageDescription`，`state: new`）、`:113-124`（`NSHealthUpdateUsageDescription`）、`:125-136`（`NSLocalNetworkUsageDescription`）、`:188-199`（`NSMotionUsageDescription`）。
  - `localizations` 为空的桌面快捷方式文案（11 个 key）：`Assistant/InfoPlist.xcstrings:251-280`（`一句话记账`、`待取快递`、`新建待办`、`证件保险箱`、`语音对话`、`快速创建日常待办与日程` 等）。
  - 对应中文原文：`Assistant/Info.plist:77-90`、`project.yml:73-76`（声明了 `en` 本地化）、`project.yml:84-110`（`UIApplicationShortcutItems`）。
- **证据**：这四条 usage description 的 `extractionState` 是 `extracted_with_value`、`state: new`——是本轮才新增/改写的健康、局域网、运动感知、健康写入权限，英文条目从未补；其余更早的权限（相机/麦克风/定位/相册/日历）都已有 `en`。`InfoPlist.xcstrings` 的 `sourceLanguage` 是 `zh-Hans`，缺 `en` 时英文系统会回退到中文原文。
- **触发条件**：系统语言为英文（或 App 内 `LanguageManager` 切到英文后重启）时首次触发健康/本地网络/运动权限，或长按 App 图标查看快捷操作。
- **用户影响**：英文用户看到中文隐私权限弹窗（App Review 对「声明语言与实际文案不一致」敏感，也是拒审常见原因）、快捷方式标题全中文；这两类都是近两轮新增、且属于主推功能（健康指数、碰一碰、到站提醒）。
- **修复建议**：用现有 `scripts/add-xcstrings-keys.py` 给 4 条权限补 `en`（zh-Hans 的 `state` 从 `new` 改 `translated`），给 11 个快捷方式 key 补 `zh-Hans` + `en`；顺带补 `CFBundleName` 的 `en`。在 `ci.sh` 里加一条 InfoPlist strings 完整性检查（复用同一脚本的 diff 三查纪律）。
- **验证方式**：系统切英文 + 重启 App，逐一触发四个权限面板；长按图标看快捷操作；`plutil -p` 构建产物对比 `en.lproj/InfoPlist.strings`；脚本断言 0 个 `en` 缺失键。

---

## PLT-07 · P2 · `Localizable.xcstrings` 覆盖不足：262 个代码引用 key 缺失，1247/4929 键无英文

- **状态**：确认（静态比对脚本结果，脚本逻辑见文末「验证方式」）。
- **位置**：`Assistant/Localizable.xcstrings`（4929 个 key，其中 1247 个 `localizations` 无 `en`；842 条是纯文本、会被用户直接看到）；回退逻辑 `Assistant/Services/LocalizationManager.swift:164-186`（`L10n.tr` 查不到就原样返回中文 key）；示例（英文模式下会显示中文）：`Assistant/Features/DayTimelineView.swift:408-409`、`Assistant/Features/MentalHealthView.swift:360`、`Assistant/Features/MentalHealthView.swift:835-837`、`Assistant/Features/PsychExportSheet.swift:76`、`Assistant/Features/Omnibox/OmniboxView.swift:1510`，本审计范围内也有一处：`Assistant/Models/IDDocumentModel.swift:311`（`L10n.tr("当前无法验证身份，请稍后重试")`）。
- **证据**：脚本提取代码里 `L10n.tr("literal")` / `"literal".localized` / `String(localized: "literal")` 的**静态精确 key** 共 458 个，其中 262 个不在 catalog；`L10n.tr` 对缺失 key 直接返回中文（不报错、不日志），所以这类缺键没有任何运行期告警。另一方面，Xcode 自动提取的 1159 个 key（`localizations` 为空对象）与 88 个只有 `zh-Hans` 的 key 合计 1247 个没有英文——`Text("...")` 这类 SwiftUI 自动化本地化在没有 `en` 时同样回退中文。
- **触发条件**：`LanguageManager.selectedLanguage = .en` 或系统语言英文，打开对应页面。
- **用户影响**：英文界面出现成段中文（时间轴、心理健康、投喂口等），与 `README.en.md` 宣称的双语支持不符；更隐蔽的是新加文案「能编译、能显示中文」但永远不会被英文用户正确看到。
- **修复建议**：
  1. 用 `scripts/add-xcstrings-keys.py` 批量补：先补 262 个静态精确 key，再处理含插值的动态分支（`translateDynamic` 已有前缀规则可逐步收编进 Core 测试）。
  2. `ci.sh` 增加一条本地化闸门：静态 `L10n.tr` / `String(localized:)` key 必须在 catalog 中且带 `en`；自动提取 key 若 `localizations` 为空则判「未翻译」 Warning（先 warning 后转红）。
  3. 长期：`L10n.tr` 在 Debug 下对缺 key 打一次 `os_log` 告警，避免继续增长。
- **验证方式**：文末附的比对脚本（纯只读）在当前树输出 `static exact keys used: 458 / missing: 262` 与 `no-en plain-text: 842`；切英文逐页走查三个示例页；CI 闸门红绿两态实测。

---

## PLT-08 · P2 · 小组件/分享扩展/AppIntents 不带本地化资源，英文用户全链路中文

- **状态**：确认（target 组成与硬编码字符串已核对；Siri 实际匹配行为未真机验证）。
- **位置**：
  - 工程组成：`project.yml:151-160`（Widget 扩展 `sources` 只有 `WidgetShared` + `AssistantWidgetExtension`）、`:175-185`（Share 扩展同理）；`AssistantWidgetExtension/` 目录下只有 3 个 Swift + Info.plist + entitlements，**没有任何 `.xcstrings`/`.strings` 资源**；`Localizable.xcstrings` 只属于主 App target（`Assistant/`）。
  - 硬编码中文（节选）：`AssistantWidgetExtension/AssistantWidgets.swift:11-13`（`configurationDisplayName/description`）、`:22-30`（「今日待办已清空」）、`:154-190`（「暂无待取快递」）、`:199-221`（「今日支出」「放宽心，慢慢花」）、`:264`、`:310-315`；`AssistantWidgetExtension/AssistantWidgetBundle.swift:46-52`；`WidgetShared/WidgetIntents.swift:62`/`69`/`71`/`101-111`/`143-157`/`188-190`/`218`/`235`/`276`/`315-321`/`356-361`/`386`/`395`/`420-421`/`444-452`（Siri 回执与错误提示）；`Assistant/Intents/AssistantAppShortcuts.swift:11-15` 等（`phrases` 只有中文）。
- **证据**：扩展 bundle 没有本地化表，`Text("今日待办")`、`IntentDialog(stringLiteral:)` 都只能显示字面量；`AppShortcutsProvider` 的短语是中文，英文 Siri 无法匹配中文触发词，等于「AppShortcuts」在英文环境下不可用（快捷指令 App 里手动添加仍可用，但抬腕一句话、操作按钮的推荐短语失效）。
- **触发条件**：英文系统/英文 Siri 使用桌面小组件、锁屏组件、Live Activity、Siri 抬腕查询、分享扩展反馈通知。
- **用户影响**：英文用户的小组件与 Live Activity 全是中文；Siri 回执中文；英文「Add an expense to 小助」类说法识别不到；这是项目主推的「免掏手机」入口，双语承诺在这里断掉。
- **修复建议**：
  1. 把 `Localizable.xcstrings` 同时加入 `AssistantWidgetExtension` / `AssistantShareExtension` 两个 target（或用一份 `WidgetShared/Localizable.xcstrings` 作为共享资源），扩展侧统一 `String(localized:)` / `LocalizedStringResource`。
  2. `AssistantAppShortcuts` 为每个 shortcut 补英文 `phrases`（如 `"Add an expense in \(.applicationName)"`、`"What's left in my budget in \(.applicationName)"`），标题/描述走 `LocalizedStringResource` 并补目录。
  3. 通知文案（`ShareViewController.postReceivedNotification`、`NotificationService` 调用点）走同一出口。
- **验证方式**：英文系统预览三种组件 + 触发 Siri 三个查询；`xcodebuild` 后检查 `AssistantWidgetExtension.appex/en.lproj` 是否产出；中文环境回归无变化。

---

## PLT-09 · P2 · `MARKETING_VERSION 0.1.0` 对生成的 Info.plist 无效，实际发版号恒为 1.0

- **状态**：确认（XcodeGen 2.46.0 最小工程实验 + 已构建产物实测，双重证据）。
- **位置**：`project.yml:52-58`（主 target `MARKETING_VERSION: "0.1.0"`、`CURRENT_PROJECT_VERSION: "1"`）、`:162-167`、`:186-191`（两个扩展同设置）；`project.yml:60-61/168-169/192-193` 的 `info.properties` **没有** `CFBundleShortVersionString` / `CFBundleVersion`；`Assistant/Info.plist:43-46`、`AssistantWidgetExtension/Info.plist:19-21`、`ShareExtension/Info.plist:19-21` 均为 `1.0` / `1`；备份元数据写死 `appVersion: "0.1.0"`：`Assistant/Services/Migration/DataMigrationService+Export.swift:529`、`Assistant/Services/DataMigrationService.swift:72`。
- **证据**：
  1. 仓库内已构建产物 `build/Debug-iphonesimulator/AssistantShareExtension.appex/Info.plist` 的 `CFBundleShortVersionString` 为 `1.0`，而同工程 `Assistant.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION` 是 `0.1.0`——说明 `MARKETING_VERSION` 没有进入最终 bundle。
  2. 在 `/tmp/xgtest` 用同一个 XcodeGen 2.46.0、只设 `MARKETING_VERSION: "9.9.9"` + `CURRENT_PROJECT_VERSION: "42"` 生成最小工程，生成的 Info.plist 仍是 `CFBundleShortVersionString = 1.0`、`CFBundleVersion = 1`。XcodeGen 会为 application 类型写死这两个默认值，除非在 `info.properties` 里显式给出占位符。
- **触发条件**：任何一次 `xcodegen generate`（`scripts/ci.sh all` 的固定步骤、README 的推荐流程），以及未来按 `MARKETING_VERSION` 发版/上 TestFlight 时。
- **用户影响**：改 `project.yml` 的版本号不会反映到 IPA——构建恒为 `1.0 (1)`，TestFlight/App Store 上传会出现「版本已存在/版本号不递增」而无法发包；备份文件里记录的 `appVersion` 又与二进制不一致，跨版本兼容判断和用户排障都会失真（例如误判这是 0.1.0 导出的包）。
- **修复建议**：
  1. 三个 target 的 `info.properties` 显式加：
     ```yaml
     CFBundleShortVersionString: $(MARKETING_VERSION)
     CFBundleVersion: $(CURRENT_PROJECT_VERSION)
     ```
     （或改用 `GENERATE_INFOPLIST_FILE: YES` + `INFOPLIST_KEY_CFBundleShortVersionString` 方案，只保留一个事实来源。）
  2. 备份 `appVersion` 改为读 `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`，不要字面量。
  3. `ci.sh` 增加闸门：`xcodegen generate` 后解析三份 Info.plist，断言版本键是占位符；构建产物 `plutil -p` 断言版本等于 `project.yml` 的值。
- **验证方式**：仓库副本里 `xcodegen generate` → `plutil -p` 三份 plist 均显示 `$(MARKETING_VERSION)`；`xcodebuild` 构建产物 `plutil -p` 显示 `0.1.0`；把 `MARKETING_VERSION` 改成 `0.2.0` 重建后产物跟随、备份 `appVersion` 同步。

---

## PLT-10 · P2（疑点）· 首帧前仍在主线程同步打开 SwiftData，250ms 盲等覆盖不到开库耗时

- **状态**：**疑点**——结构成立，但「白屏是否还剩」需要 Release 真机 metrics 才能定性；`de2942d` 的修复方向是「降低反射成本 + 让出首帧后窗口」，不是把开库移出首帧。
- **位置**：`Assistant/App/AssistantApp.swift:64`、`:76`（body 里读 `Persistence.recoveryError`）、`:113`（`.modelContainer(Persistence.shared)`）；`Assistant/Services/Persistence.swift:8-11`（`recoveryError` 内部 `_ = shared`）、`:26-51`（`shared` 静态初始化里同步 `openStoreAutoMigrate()`，失败再同步 `openStore()`）、`:67-77`；`AssistantApp.swift:92`（`root.task` 里 `Task.sleep(250ms)`）。
- **证据**：`@main` App 的 `body` 在首帧渲染**之前**求值，`Persistence.recoveryError` 的第一次读取就会触发 `Persistence.shared` 的懒初始化——即 340+ 模型描述符反射 + 轻量迁移/打开库全在主线程、首帧之前完成；`.modelContainer(Persistence.shared)` 只是复用已初始化的值。`:92` 的 250ms 让出发生在开库**之后**，让出的是通知分类注册与快照对账，不覆盖开库耗时。`StartupMetrics`（`:6-34`）已埋点，但 `todo.md` 2026-10-14 仍记「埋点日志待真机取」，本工作树里没有 Release 真机的 `store.open begin → ready` 数据结论。当前树未提交改动只是给 `AppSettings` 加公开属性，与此无关。
- **触发条件**：旧设备 + 数千/万条待办与账目 + 较大 WAL 的冷启动；或旧库升级（V1…V9 之一）需要实际迁移时。
- **用户影响**：若开库+迁移耗时超过 ~300ms，用户仍看到白屏（系统启动图之后到首帧之间没有任何自有占位 UI）；用户感知为「点了 App 半天没反应」。另外 `Persistence.swift:43-48` 在内存容器也失败时 `fatalError`，恢复页面在最坏情况下变成崩溃。
- **修复建议**：
  1. 首帧只渲染轻量占位（品牌 splash / 骨架 Tab），把 `ModelContainer` 的打开放到 `Task.detached` 或后台队列，完成后通过 `@State` 注入 `.modelContainer(_:)`；同时保留恢复页分支。
  2. 或按 store 文件是否存在/是否需要迁移分流：新装/已就绪库走快路径，需要迁移时先显示「正在升级数据」进度页。
  3. 把 `StartupMetrics` 的 Release 真机采样纳入发版检查（`os_signpost` + P95 门槛，例如 `store.open` < 500ms）。
- **验证方式**：Release 真机 Console 过滤 subsystem `assistant.startup`，记录 `store.open begin/ready`、`mainTab.onAppear` 间隔；用 `scripts/migration-drill` 造一个 V1 万条库做升级测量；对比「占位 UI + 异步开库」方案的首帧时间。

---

## PLT-11 · P3 · Intent 自由文本枚举参数静默兜底、数值参数无上下界

- **状态**：确认。
- **位置**：
  - `Assistant/Intents/ContextTriggerIntent.swift:15-16`（`@Parameter(title: "情景类型", default: "离开家/断开家庭Wi-Fi") var scenario: String`）、`:23-28`（`switch scenario` 的 `default` 落到 `.leaveHomeOrDisconnectWiFi`）。
  - `Assistant/Intents/ReportDeviceBatteryIntent.swift:10-11`（`deviceName: String`）、`:21-24`（未知值 `default: .watch`）、`:13-14`（`percent: Int` 无范围校验；`Assistant/Services/SafetyReminder…` 实际在 `Assistant/Services/BatteryReminderService.swift:47` 用 `percent <= 20` 判定低电量，负数会生成「电量仅剩 -5%」的充电待办）。
  - `Assistant/Intents/ReportScreenTimeIntent.swift:11`、`:16`（`Assistant/Services/ScreenTimeTracker.swift:45-48` 只 `max(0, minutes)`，100000 分钟原样进入作息算法）。
  - 同类：`WidgetShared/WidgetIntents.swift:216-219`、`:260-263`（逗号分隔 UUID 列表，非法项被 `compactMap` 静默丢弃，回执仍报「已全部取齐」）。
- **证据**：这些参数用自由文本 `String` 而不是 `AppEnum`，`switch` 的 `default` 把「用户拼写错误/未知设备」静默映射成一个具体语义；数值参数在 `perform` 前没有 clamp 或回执校验，非法值直接进入持久化/算法。
- **触发条件**：用户自建快捷指令/自动化时手填参数（例如「回家/连接Wi-Fi」「iPhone 15」「电量 -1」「屏幕时间 100000」），或 Shortcuts 变量解析出异常值。
- **用户影响**：情景提醒按「离家」而非「到家」执行、给出错误情境建议；设备电量被记成 Apple Watch 并生成错误充电待办；作息/蓝光算法被异常屏幕时间污染；批量动作部分失败却回执全成功。不会损坏既有数据，但会制造错误记录/错误建议。
- **修复建议**：`ContextTriggerReason`、`ChargeDeviceType` 已存在，直接改为 `AppEnum` 参数；`percent` clamp 到 `0...100` 并对越界回执提示；`minutes` clamp 到合理区间（如 0…1440）并拒绝异常值；批量 UUID 解析统计非法项数量并在回执中说明。
- **验证方式**：在快捷指令里传非法/边界参数，断言按预期拒绝或归一化并回执；为 enum 映射与 clamp 补单测（可下沉到 Core）。

---

## PLT-12 · P3 · 分享信封解析不校验版本、金额/分数范围与体积

- **状态**：确认。
- **位置**：`Assistant/Models/NearbySharePayload.swift:149`（`version` 字段只解码不校验）、`:346-348`（`decode(from data:)` 直接 `try? JSONDecoder`）、`:350-407`（从任意文本里正则抓 `assistant://` 链接；`d=` base64 无长度上限）、`:410-500`（紧凑 URL 分支对缺失参数用默认值补齐：`:421` `splitAmount` 可为负/超大、`:464-466` `mood/energy/stressScore` 未限定 `1...5`）；调用方 `Assistant/Services/NearbyShareService.swift:184`（从未鉴权 peer 接收）、`Assistant/Services/QRCodeService.swift:128`（相册/扫码识别）。
- **证据**：解码得到的 `UniversalShareEnvelope` 直接被 UI 消费并落库（AA 账单、心情名片、待办、收纳），但 `validate` 只存在于备份包路径，分享信封没有任何字段范围校验；协议 `version` 恒被忽略，未来不兼容数据会被当当前版本解析。
- **触发条件**：用户扫描/粘贴一个手工构造或损坏的 `assistant://` 链接、二维码或碰一碰数据包（对端完全不可信）。
- **用户影响**：可写入负数/超大金额的 AA 账单、越界情绪分（图表/共振计算的除零或越界表现）、超长标题/备注；超大 base64 解析造成内存尖峰（与 PLT-05 同类的扩展/主 App 内存风险）；版本不兼容数据被错误接受。
- **修复建议**：`decode` 末尾统一 `validate()`——version 白名单（1/2）、payload 与 type 一致性、金额 `> 0` 且上限、分数 `1...5`（clamp 或拒绝）、字符串长度上限；`d=` 参数长度上限（如 64KB）；拒绝时向用户回执「分享数据不完整/版本不兼容」，不静默丢弃。
- **验证方式**：单测覆盖负金额、9999 分、`version: 99`、10MB base64、type 与 payload 不匹配；真机扫构造二维码/碰碰传输验证被拒。

---

## PLT-13 · P3（疑点）· 共享快照跨进程 read-modify-write 无锁（指令队列有锁）

- **状态**：**疑点**——代码结构确认无锁，但「UserDefaults 跨进程可见性延迟」导致旧值覆盖的概率无法静态证明，需要压力脚本/真机复现。
- **位置**：`WidgetShared/WidgetSnapshot.swift:110-123`（`load()` / `save()` 无任何互斥）、`:195-206`（`applyCompletionLocally` / `applyExpenseLocally` 都是 load→修改→save）；同文件 `:127-167` + `:169-191` 已经为**指令队列**实现了 `flock` 跨进程锁（注释明确写「read-modify-write 不加锁时两侧交错会互相覆盖」），但快照读写没有复用。主 App 侧 `Assistant/Services/WidgetSnapshotSync.swift:16-21`（`drain` → `buildSnapshot` → `save` → `reloadAllTimelines`），共 24 个刷新调用点。
- **证据**：快照是一个 UserDefaults JSON blob，扩展 `applyCompletionLocally` 与主 App `refreshSnapshot` 都会整块覆盖写；两者分属不同进程。若扩展拿到的是稍旧快照（跨进程 UserDefaults 不保证即时一致），它的 `save` 会把主 App 刚写入的新快照整体回退——例如刚在 App 里勾掉的另一条待办重新出现在组件上。`applyExpenseLocally` 目前**没有任何调用方**（grep 0 处），是死代码，一旦被启用会放大同类风险。
- **触发条件**：主 App 存活并正在刷新快照时（回前台/后台巡检/完成任意操作后的 24 个调用点之一），用户同时点小组件/灵动岛按钮，扩展进程也做一次快照 RMW。
- **用户影响**：极端情况下桌面/锁屏/手表短暂显示回退的旧数据（已勾掉的事项复活、今日支出回到旧值），直到下一次主 App 刷新（≤15 分钟或下次回前台）；不会损坏数据库，但会让「三端一致」承诺出现可见裂缝。
- **修复建议**：把 `withQueueLock` 提升为通用 App Group 锁，`WidgetSnapshotStore.save/load+修改` 全部走锁；或更简单——扩展只 `enqueue` + `WidgetCenter.reloadAllTimelines`，不再写快照（快照只由主 App 权威写入，扩展侧「乐观显示」交给 timeline 下次重读）；删除无调用方的 `applyExpenseLocally`。
- **验证方式**：写一个临时双进程压力脚本/单元（扩展循环 `applyCompletionLocally`、主 App 循环 `refreshSnapshot`），断言最终快照与 SwiftData 状态一致且无回退；真机在「回前台瞬间点组件按钮」场景复现。

---

## PLT-14 · P3（疑点）· 常规启动路径绕过版本化迁移计划，未来自定义阶段可能永不执行

- **状态**：**疑点**——是 `de2942d` 引入的架构取舍（autoMigrate 优先），当前纯加法 schema 下无可见问题；风险在「下一次非纯加法变更」。
- **位置**：`Assistant/Services/Persistence.swift:26-34`（首选 `openStoreAutoMigrate()`，**无 migrationPlan**）、`:36-40`（失败才回退 `openStore()`）、`:53-77`（`openStore` 带 `AssistantMigrationPlan`）、`:274-298`（9 段 `.lightweight` 阶段）、`:284-287` 注释约定「未来出现不兼容变更，在此插自定义阶段」。该顺序由 `de2942d` 从「版本化计划优先」改成「autoMigrate 优先」（见该提交 diff）。
- **证据**：正常用户走的是无迁移计划的隐式轻量升级路径，`AssistantMigrationPlan` 只作为兜底；若以后按注释新增一个自定义 stage（例如字段重命名需要搬数据），而系统隐式轻量迁移能「成功打开」（把旧列删掉/新列填默认值），自定义 stage 永远不会执行，旧数据会静默丢失且没有任何报错。
- **触发条件**：未来新增一次非纯加法 schema 变更（重命名/改类型/拆表），并按项目纪律在 `AssistantMigrationPlan` 增加自定义阶段。
- **用户影响**：升级后部分历史数据消失/变默认值，且因为「打开成功」，恢复页与备份导出都不会触发；等用户发现时旧库已被新 schema 写回。
- **修复建议**：保留显式迁移计划为**唯一升级路径**（检测到旧库/需要迁移时先走 `openStore()`），只在确认是全新安装时才用无计划打开；或在 `openStoreAutoMigrate()` 前读取 store 的 schema 版本元数据，按需分流。`scripts/migration-drill` 增加一条「重命名字段」用例（V9 → 模拟 V10 + 自定义 stage），断言数据确实被搬进新列而不是为空。
- **验证方式**：migration-drill 新用例红绿两态；在 Debug 下打印实际命中的打开路径（`openStore(versioned)` vs `openStore(autoMigrate)`），确认旧库分流的预期；构造一个需要自定义迁移的库做升级演练。

---

## PLT-15 · P3 · 分享扩展在内容未变化时也调用 `reloadAllTimelines`，挤占小组件刷新预算

- **状态**：确认。
- **位置**：`ShareExtension/ShareViewController.swift:78-82`（只要有分享内容写入就 `WidgetCenter.shared.reloadAllTimelines()`，此时共享快照并未变化——快照只由主 App 重建）；主 App 侧每次快照刷新也 reload：`Assistant/Services/WidgetSnapshotSync.swift:21`，共有 24 个 `refreshSnapshot` 调用点（`Assistant/App/AssistantApp.swift:101,129`、`Assistant/Features/Todo/TodoRowViews.swift:74` 等）。
- **证据**：分享扩展写的是 `ShareInbox/`，与组件读取的 `widget_shared_snapshot_v1` 无关；这次 reload 纯粹浪费 WidgetKit 的刷新机会。WidgetKit 对 `reloadAllTimelines` 有系统级频率限制（超出后静默丢弃），而小组件的数据本来就只在主 App 刷新快照时更新——真正需要 reload 的点是 `WidgetSnapshotSyncController.refreshSnapshot` 与扩展侧本地突变（已有）。高频完成待办的用户可能把预算耗在这些「无变化 reload」上，导致真正需要更新时被限流。
- **触发条件**：频繁分享、或频繁勾选待办/回前台（每次都会 reload）。
- **用户影响**：小组件/锁屏组件在数据变化后仍显示旧值，用户以为「组件坏了」；重装/重启后短时恢复。
- **修复建议**：删除分享扩展里的 `reloadAllTimelines`；给 `refreshSnapshot` 外层加一个短窗口节流（例如同一秒内的多次调用合并为一次 reload，快照写入本身仍每次执行）；只在快照内容 hash 变化时才 reload。
- **验证方式**：在 Debug 里给 reload 打点计数（一天/一次会话），对比改造前后；真机高频勾选后观察组件是否即时更新。

---

## 覆盖与核对记录（未发现问题的检查项）

为避免把范围说大，以下检查项已实际执行且**未发现问题**，不计入发现：

| 检查项 | 结论 |
| --- | --- |
| App Group 一致性 | `group.com.yifanwang.assistant01` 在 3 份 entitlements、`project.yml:43/161/185`、`WidgetShared/WidgetSnapshot.swift:10` 完全一致，无历史遗留的 `group.com.yifanwang.assistant` 混用 |
| Schema 注册完整性 | 脚本比对：代码中 43 个 `@Model` 类与 `AssistantSchemaV9.models` 43 个名字**完全一致**（无漏注册/无多余项）；`assertSchemaCoverage` 的 V1⊆V9 也成立 |
| `project.yml` ↔ 三份 Info.plist 内容一致性 | 除版本键（见 PLT-09）与 XcodeGen 自动生成的 `CFBundleExecutable/Identifier/…` 外，33/2/2 个 `info.properties` 键与磁盘 plist 完全一致；没有「写在 plist 里但下次 generate 会被抹掉」的键（`BGTaskSchedulerPermittedIdentifiers`、`UIBackgroundModes` 等都在 `project.yml` 里） |
| 平台版本与 README | `project.yml` iOS 18.0、README/README.en 都写 iOS 18.0+、仅竖屏，一致 |
| HealthKit 权限与实际行为 | `HealthKitService.requestAuthorization` 用 `toShare` 申请 `dietaryWater`，`recordWaterIntake` 被 `WaterTrackerView`/`ExpenseWaterService`/`WaterCapabilityProvider` 真实调用；`NSHealthUpdateUsageDescription` 文案与实际写入一致（**不是**遗留的「只读却声明写权限」） |
| 软关联删除路径 | 抽查 `PetProfile`（`PetManagementView.deletePet` 先删 `PetRecord`）、`ChildProfile`（4 条 `.cascade` 关系）、`LifeEventProject`（`deleteProjectCascade` 删除 5 类子表 + `LifeEventTodoLink.removeMirrors`）、`SkillPath`（无删除入口）均有清理，未发现可复现的孤儿数据路径 |
| `Info.plist` ↔ `InfoPlist.xcstrings` 中文值漂移 | 除 `CFBundleName`（plist 为 `$(PRODUCT_NAME)`）外，所有带 `zh-Hans` 的 usage description 值与 plist 原文一致，无「改了 plist 忘改本地化」的漂移 |
| 分享/组件 entitlements 与代码路径 | Share 扩展只写 App Group（`ShareImportBridge`），Widget 扩展只读共享快照 + 写指令队列，均不触碰 SwiftData，与 `Persistence` 的多进程约束一致 |

## 本轮未做 / 未验证

- 未跑完整 `xcodebuild`（按要求），未跑模拟器/真机：扩展内存峰值、Siri 英文匹配、权限面板语言、组件实测均为静态结论。
- 未做双进程并发压力复现（PLT-04/PLT-13），未做旧库升级实测（PLT-02/PLT-14）；这两类需要真机/注入工具。
- PLT-10 需要的 Release 真机 `assistant.startup` 日志仓库内没有，故只记为疑点；建议发版前补采一次。
- 本地化统计脚本为一次性只读脚本（未入库）：`python3` 解析 `Assistant/Localizable.xcstrings`，正则提取 `L10n.tr("…")` / `"…".localized` / `String(localized: "…")` 的静态精确 key 与目录对比；XcodeGen 版本实验在 `/tmp/xgtest` 完成，未改动仓库文件。
