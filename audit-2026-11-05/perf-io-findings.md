# 批 3 · 主线程重 I/O 修复记录（SVC-01 / SVC-07 / SVC-09）

- **日期**：2026-11-05
- **范围**：备份导出/还原/解锁、本地大模型导入、全域搜索索引
- **审计依据**：`audit-2026-11-05/services-findings.md` 的 SVC-01 / SVC-07 / SVC-09
- **总原则**：SwiftData `ModelContext` 不是 `Sendable`。**取数/写库永远留在主 actor**，
  只把「纯值类型的 CPU + I/O」搬进 `Task.detached(priority: .utility)`；分片用
  `await Task.yield()`（主 actor 异步函数内让出，UI 可渲染、事件可插入）。
- **兼容性**：备份文件格式（DTO 字段、`BackupPackage` 结构、`EncryptedBackupEnvelope`
  字段与版本号、文件名规则）**一字未改**，旧备份仍可导入，新备份旧版本也能读。

---

## 0. 一页结论：哪些工作离开了主线程

| # | 工作项 | 原位置（主线程成本） | 现在的位置 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | 备份导出：JSON 编码（附件 base64）+ PBKDF2 310k + AES-GCM + 封套 base64/JSON | 全部主 actor，大库数十秒级卡死 | 主 actor 只留取数（分片让出）+ 结构校验；**编码/加密/封套在 `Task.detached`** | ✅ 完成 |
| 2 | 备份导出：43 张表全表 fetch + DTO 映射 + 证件/语音/图片附件读盘 | 一次同步完成，中间不让出 | 仍主 actor，但 43 个取数点之间 5 次 `Task.yield()`、附件按每 8 条让出 | ✅ 分片（取数不跨线程） |
| 3 | 备份还原：清库 41 个 `delete` + 60+ 域插入 + 最终 save | 一次同步跑完 | 仍主 actor；每域让出 + 大表每 N 条让出 + 关闭 autosave 防半成品落盘 | ✅ 分片（context 不跨线程） |
| 4 | 备份解锁：base64 + PBKDF2 310k + AES-GCM + 整包 JSON decode | 输完 PIN 主线程卡 0.2–0.5s + 大包 decode | `unlockEncryptedArchiveAsync`：后台 detached | ✅ 完成 |
| 5 | 备份文件选择：`Data(contentsOf:)` + 整包 JSON 解析 | 主线程读几百 MB + decode | 后台 detached 读取 + `inspectBackupFileAsync` 后台解析 | ✅ 完成 |
| 6 | 本地大模型导入：数 GB `copyItem` + 全文件 SHA-256 | 主 actor 同步数秒–数十秒 | `Task.detached` 完成 copy + 校验，只回主 actor 换名 | ✅ 完成 |
| 7 | 模型目录未排除 iCloud 备份 | 只下载路径打标记 | `modelsDirectory` 每次访问幂等补 `isExcludedFromBackup` | ✅ 完成 |
| 8 | 全景搜索：每次打开 `engine.clear()` + 重建 16 张表 | 打开即清空重建，构建窗口搜索为空 | 变更令牌（各表行数+最新时间戳）判断 + 新引擎构建后原子替换 + 手动刷新强制 | ✅ 完成 |

**测试/闸门**：`swiftc -parse` 11 个文件全过；`check_save_swallow.py` exit 0（仍 64 处，未新增）；
`check_radius_tokens.py` / `check_backup_pin_literals.py` exit 0；`AssistantCore swift test` exit 0（1116 项全绿）。

---

## 1. SVC-01 · 备份导出移出主线程

### 位置
- `Assistant/Services/Migration/DataMigrationService+Export.swift:15` `buildBackupPackage() async`（新增 11 处分片让出）
- `Assistant/Services/Migration/DataMigrationService+Export.swift:662` `exportEncryptedArchive(pin:hint:) async`
- 调用点：`Assistant/Features/DataMigrationView.swift:432`（手动导出）、`Assistant/Services/WebDAVSyncService.swift:128-134`（NAS 自动/手动备份）

### 原主线程成本（审计 SVC-01 复述 + 代码结构推算）
- 43 张表无谓词全表 `fetch`（顺序同步，几十到几百 ms 起）；
- 全部附件字节读盘（证件正/反面、语音音频、笔记内嵌图片）；
- DTO 映射 + 密码库解密；
- **JSON 编码把全部附件 Data 变 base64（体积 ×1.33）**；
- **PBKDF2-HMAC-SHA256 310,000 轮**（审计引 Core 注释：旧设备约 0.2–0.5s）+ AES-256-GCM；
- 密文再 base64 进封套 + 封套 JSON 编码。
- 上述全部在 `@MainActor class DataMigrationService` 上一个同步方法里，主线程整段无呼吸；
  BGAppRefresh 唤醒时会被后台预算/watchdog 杀掉，自动备份可静默永不成功。

### 新方案
1. `buildBackupPackage()` 改 `async`（仍在主 actor），在取数/映射/附件读盘之间插入 11 处
   `await Task.yield()`：
   - 43 个 `fetch` 分 5 次让出；
   - `documents` / `voiceMemos` 的逐附件读盘从一次性 `map` 改为 `for` + 每 8 条
     `await Task.yield()`（证件多、语音多时 UI 不再整段冻住）。
2. `exportEncryptedArchive` 拆分：
   - **主 actor**：`validatePin` → `try await buildBackupPackage()` → `validate(package:)`
     （含 `UIImage(data:)` 校验，UIKit 留在主 actor）→ `Task.checkCancellation()`；
   - **`Task.detached(priority: .utility)`**：JSON 编码 + 随机盐 + `BackupEnvelopeCrypto.seal`
     （PBKDF2 + AES-GCM）+ 封套 base64 + 封套 JSON 编码 + 文件名。
   - 后台闭包只捕获 `BackupPackage`（Codable 值类型）、`String`、`Data` 等值类型，
     **不捕获 `self` / `ModelContext` / 任何 `@Model` 对象**；`packageData` 在加密后显式置 nil，
     尽快释放明文 JSON。
3. 导出格式与字段完全不变（DTO/封套/文件名/`hint` 归一化逻辑逐字等价）。

### 并发与内存风险
- **SwiftData 上下文没有跨线程**：取数仍全在主 actor，`ModelContext` 未被捕获进后台闭包；
  后台闭包只处理已物化的值类型，跨线程安全。
- 取数期间让出主线程会被 SwiftUI 的 autosave/其它主 actor 任务插入：导出是只读，最多拿到
  「跨表不完全同一时刻」的快照，不会破坏数据；不改变导出失败语义。
- 内存峰值仍是「附件原始字节 + JSON base64（×1.33）+ 密文 + 封套 base64」约 3–4 倍：
  备份格式要求附件和密文都进 JSON，不改格式无法压到 1 倍。已用显式 `nil` 释放中间 JSON，
  峰值比原实现少驻留一份明文。**附件外置/流式加密列为后续项**（见 §7）。
- Swift 5 语言模式下，后台闭包捕获非 `Sendable` 的 `BackupPackage` 只会告警（不升级为错误）；
  本项目未开启 `SWIFT_STRICT_CONCURRENCY`。

### 失败与取消行为
- `validate` 失败 / 附件缺失 / 口令非法：与旧实现一样抛错，**不产出任何文件**；
- 后台编码/加密失败：抛错，无半成品、无临时文件；
- `Task.checkCancellation()` 在进入后台加密前检查一次：取消即抛 `CancellationError`，
  `DataMigrationView` 捕获后提示「已取消生成」；
- UI 侧：`isExporting` 期间禁用「生成备份」按钮并显示「正在生成加密备份…」；
  新一次导出前先删除上一份临时文件，失败/取消也删除临时文件（临时目录不留敏感密文）。

### 验证方式（真机 Instruments 观察点）
- **Time Profiler**：点「生成加密备份」时，主线程栈不应再出现
  `CCKeyDerivationPBKDF` / `CCCryptorGCM` / `JSONEncoder.encode` / `Data.base64EncodedString`；
  这些应落在 `com.apple.root.utility-qos` 线程。
- **Allocations / VM Tracker**：导出期间物理内存峰值对比修复前（预期降低约一份明文 JSON）；
  观察峰值是否仍随附件体积线性增长（是 → 附件外置后续项的必要性）。
- **App Launch / os_signpost**：给 `exportEncryptedArchive` 前后包 `os_signpost`，看
  「主线程阻塞时长」从数十秒降到「单个分片 ≤ 一帧级」。
- **BGAppRefresh 真机**：把 `earliestBeginDate` 调成 now+60s，跑一次自动备份，系统日志不应
  出现 `BGAppRefresh` 超时/`watchdog`。

---

## 2. SVC-01 · 备份还原移出主线程（分片，不跨 context）

### 位置
- `Assistant/Services/Migration/DataMigrationService+Restore.swift:52` `restore(from:strategy:) async`
- 调用点：`Assistant/Features/DataMigrationView.swift:544`、`Assistant/Features/WebDAVSyncView.swift:507/509`

### 原主线程成本
- `strategy == .overwrite` 时 41 个 `try context.delete(model:)`；
- 每个域 1 次 `context.fetch` 取 existing IDs（约 43 次）；
- 60+ 个插入循环（最多 800 条/表；证件/语音还要逐条写沙盒文件）；
- 最终**一次** `try context.save()`；
- 之后 3 段孤儿文件扫描/清理 + 偏好设置写 UserDefaults。
- 全部同步在 MainActor：SwiftUI 连「还原中」都渲染不出来。

### 新方案
- 方法改 `async throws`；插入 **70 处** `await Task.yield()`：
  - 清库 41 条 `delete` 每 10 张让出一次；
  - **每个实体域起点**（43 个 `existing*IDs` 查询前）让出一次；
  - **19 张可能会很大的表**改为 `for (index, x) in xs.enumerated()`，每 200 条
    （证件/语音每 50 条，因为要逐条写盘）让出一次；
  - 最终 `context.save()` 前后各让出一次（先让「还原中」渲染，再落盘）；
  - 偏好设置写盘前再让出。
- **失败语义不变**：仍是 `do/catch { context.rollback(); throw error }`，异常向外抛。
- **新增 autosave 防护**（`Restore.swift:102`）：还原期间临时把 `context.autosaveEnabled`
  置 false，`defer` 恢复。原因：分片让出后主 runloop 有机会触发 SwiftUI 主 context 的
  autosave，若不关，会「还原到一半」落盘，随后失败时 `rollback()` 回不到原库，
  破坏「还原失败不动库」承诺。

### 并发与内存风险
- `ModelContext` 全程只在主 actor，不跨线程——这是本项最大的正确性边界。
- 让出期间用户可能操作其它 UI（本页有门禁覆盖层+还原中禁用按钮，实际交互面很小）；
  关闭 autosave 也顺带避免让出期间把脏改动自动落盘。
- 内存：不新增整包副本（`package` 是已解码好的值类型）；`context.save()` 的峰值与旧实现相同。

### 失败与取消行为
- 校验/附件缺失/密码重加密失败：在任何删除之前抛出，磁盘库不动；
- 中途插入/写盘失败：`rollback()` + 抛错，autosave 已关，磁盘仍是还原前的库；
- 取消：`Task.yield()` 不检查取消（还原是不可中断事务），取消后仍会把这次还原跑完，
  与旧同步实现语义一致（旧实现同样无法中途取消）。

### 验证方式
- **Time Profiler**：还原期间主线程不应长时间连续占用；`context.save()` 单次热点仍在，
  但前后能看到 UI 帧提交（`CA::Transaction::commit` 有机会运行）。
- **Instruments → Thread State**：主线程 Run Loop 在还原期间应出现多次 Idle/事件处理，
  而不是一条几十秒的连续栈。
- **失败注入**：构造缺附件的备份 + 覆盖策略 → 断言磁盘库未变（还原前后 `fetchCount` 一致，
  且「待办」等表内容未变）。
- **内存**：还原 200MB 附件库，峰值不应比旧实现高（本项不增加副本）。

---

## 3. SVC-01 连带修复 · 解锁与备份文件解析（同一主线程链路）

### 位置
- `Assistant/Services/DataMigrationService.swift:258` `inspectBackupFileAsync`
- `Assistant/Services/DataMigrationService.swift:284` `unlockEncryptedArchiveAsync`
- 后台纯解析入口：`DataMigrationService.swift:306`（封套/明文包解码）、`:323`（PBKDF2+解密）
- 调用点：`Assistant/Features/DataMigrationView.swift:474`（选文件）、`:523`（输 PIN 解锁）

### 原主线程成本
- 选文件：`Data(contentsOf:)` 整包进内存（几百 MB）+ 整包 JSON decode；
- 解锁：`Data(base64Encoded:)` + **PBKDF2 310k** + AES-GCM + 整包 JSON decode。

### 新方案
- 把「纯解析」抽成 `private nonisolated static` 纯函数（不碰 `self`/context/`@Model`），
  新增 async 入口在 `Task.detached(priority: .utility)` 里执行，只把值类型结果回主 actor；
- `DataMigrationView` 的读文件也移到 detached，且**安全作用域资源在后台读完才释放**
  （`stopAccessingSecurityScopedResource` 放进 Task 的 defer，避免主线程提前释放导致后台读取无权限）；
- 保留原同步方法给 `WebDAVSyncView`（不改其行为）。
- UI：新增「正在校验备份文件…」与解锁中 `ProgressView`，防重复提交。

### 风险 / 失败行为
- detached 闭包只捕获 `Data` / `EncryptedBackupEnvelope` / `String`（无 context）；
- 错误映射（口令错/篡改/版本不支持）逻辑原样搬进纯函数，错误码与文案不变；
- 解析失败：与原行为一致，`restoreResultText` / `unlockErrorMessage` 展示失败，不进入还原。

### 验证方式
- Time Profiler：输 PIN 点「解锁并读取」后主线程不再出现 `CCKeyDerivationPBKDF`；
- 选 200MB 备份文件时主线程无 `Data(contentsOf:)` 长时间栈（应在 utility 线程）；
- 失败路径：错误 PIN → 仍显示「PIN 码不正确，无法解密该备份文件」；损坏文件 → 解析失败提示。

---

## 4. SVC-07 · 本地大模型导入 detached + 备份排除

### 位置
- `Assistant/Services/LLMModelManager.swift:536` `importModel(from:) async`
- `Assistant/Services/LLMModelManager.swift:124` `modelsDirectory`（幂等 `isExcludedFromBackup`）
- 调用点：`Assistant/Features/LLMModelManagementView.swift` 的 `handleFileImport`（改为 `Task { try await ... }` + 进度态）

### 原主线程成本
- `@MainActor` 同步 `copyItem`（1–4GB，数秒到数十秒）+ `ModelFileValidation.validate`
  （全文件 SHA-256，1MB 分块但同步）；期间 UI 冻死，锁屏/切后台可能被系统杀掉；
- 只走「从文件导入」的用户，`Documents/Models` 从未被打 `isExcludedFromBackup`，
  iCloud/iTunes 备份会被多 GB 模型占满。

### 新方案
- `importModel` 改 `async throws`：
  - `Task.detached(priority: .utility)` 内：`copyItem` + `ModelFileValidation.validate`；
    `defer` 里释放 security-scoped 访问（必须覆盖整个后台拷贝）；
  - 回主 actor 只做毫秒级「先挪走旧模型 → 换入新模型 → 写摘要」的原子替换，
    失败把旧模型挪回、删除候选文件（失败不丢旧模型，与原行为一致）；
- `modelsDirectory` 每次访问幂等 `setResourceValues(isExcludedFromBackup: true)`，
  下载路径与导入路径都覆盖；对已标记目录是廉价 no-op；
- UI 调用点：`isImportingModel` 期间禁用导入按钮并显示「正在后台拷贝并校验模型文件…」，
  失败继续走原有 `errorMessage` 展示。

### 并发与内存风险
- 后台闭包捕获 `URL`（Sendable）+ `preset` 值类型，不捕获 `self`；
  校验结果 `ModelFileValidation.Validated` 是可跨线程传递的值类型；
- 无额外内存峰值（流式 SHA-256 仍在 `ModelFileValidation` 内部，1MB 分块）。

### 失败与取消行为
- 拷贝失败：清候选文件、旧模型未动；
- 校验失败/大小不符/发布版本不符：清候选文件、旧模型未动，`errorMessage` 展示失败；
- 取消：`copyItem` 不响应取消，导入会跑完；中途不产生半成品（候选文件在校验失败路径清理）。

### 验证方式
- Time Profiler：导入 ≥2GB GGUF 时主线程不应出现 `copyfile` / `CC_SHA256` 长栈；
- 断言 `Documents/Models` 的 `NSURLIsExcludedFromBackupKey == true`
  （`xattr` / `URLResourceValues`），并在设置 App 的 iCloud 备份大小里确认模型不计入；
- 导入失败（选个非 GGUF/截断文件）→ 旧模型仍可用、无残留候选文件。

---

## 5. SVC-09 · 搜索索引按需重建 + 原子替换

### 位置
- `Assistant/Services/SearchIndexService.swift:290` `rebuildIndex(context:force:)`
- 变更令牌：`SearchIndexService.swift:720`（16 张表）+ `:778`（通用 mix）
- 静态设置文档抽成 `private static func staticSettingsDocuments()`
- 触发点：`Assistant/Features/UnifiedSearchView.swift:106`（打开，默认增量）、
  `:120`（手动刷新 `force: true`）、`Assistant/Features/TodoListView.swift:381-388`（首屏延迟，默认增量）

### 原主线程成本
- 每次打开搜索 sheet：`engine.clear()` → 注入静态设置 → `fetch` **16 张业务表**
  （多数 `fetchLimit` 200–800，最多约 1.4 万条）→ 逐条拼音分词建倒排 → 分批 `engine.add`；
- 清空到构建完成之间 `search()` 在空/半空引擎上工作：用户输入可能得到「无结果」，
  而且索引补齐后不会自动重算（`runSearch` 只由输入变化触发）。

### 新方案
1. **按需重建**：`rebuildIndex(context:force: Bool = false)`。
   - 先算「数据变更令牌」：16 张表各自 `fetchCount` + 每表**最新一条**的时间戳
     （`fetchLimit = 1` + 降序 `SortDescriptor`）；混成一个 `Int` 哈希；
   - 已有索引（`isIndexInitialized`）且令牌与上次成功建索引时一致 → 直接返回；
   - 令牌计算任何一步失败 → 返回 nil → 退化成重建（安全侧）；
   - 令牌在**构建前**采集，构建期间数据又变则下次打开会再重建（不会把旧状态误标成最新）；
   - 手动刷新按钮传 `force: true` 强制重建。
2. **原子替换**：构建进全新的 `SearchIndexEngine`（`engine` 改为 `public private(set) var`），
   全部文档 `add` 完再 `self.engine = newEngine`；构建期间旧索引完整可搜索，
   取消时 `self.engine` 仍是旧索引、不留半成品。
3. **重建后自动重跑最近一次查询**：`search()` 记录 `(query, category)`，
   重建完成后用新引擎重跑，修复「输入了没结果、索引补齐后也不补算」的可见症状。

### 并发与内存风险
- `SearchIndexEngine` 自身 `NSLock` 线程安全；引用替换在主 actor 同步完成，搜索侧
  要么看到旧引擎、要么看到完整新引擎（不存在空窗口）。
- 短暂内存峰值 = 旧索引 + 新索引（构建期间两份文档/倒排）。万级数据下约几十 MB 量级；
  由于绝大多数打开不再重建，这个峰值只在首建/强制刷新出现。
- 令牌判断成本：16 次 `fetchCount` + 16 次 `LIMIT 1` 索引查询（主线程，毫秒级），
  远低于重建（16 次 fetch + 上万条拼音分词）。

### 失败与取消行为
- 令牌查询失败：退化为重建（不会错误跳过）；
- 构建被取消（`Task.isCancelled`）：直接返回，旧引擎保持原样，`isIndexInitialized`/令牌不变，
  下次打开会重新尝试；
- 某张表 `try? context.fetch` 失败：该表文档缺席（与旧行为一致）——但令牌计算用的是
  `try`，任何一个失败都会触发重建，不会把「缺表的索引」记成最新。

### 验证方式
- **打开搜索 sheet 到可交互耗时**：修复后第二次起应显著下降（Time Profiler 顶部不再出现
  `SearchIndexService.rebuildIndex` 的 16 次 context.fetch / `PinyinHelper` 分词）；
- 打开后立刻输入一个已存在的待办标题 → 能命中（构建窗口不再返回空）；
- 编辑/新增一条待办后再打开搜索 → 令牌变化 → 重建，能搜到新内容；
- `isIndexing` 只在真正重建时翻转（`UnifiedSearchView` 刷新按钮禁用态不再每次打开闪一下）；
- Memory Graph：强制刷新时短暂出现两份 `SearchIndexEngine`，完成后旧实例释放。

---

## 6. `@MainActor` 隔离标注变化（供复核）

| 文件 | 变化 |
| --- | --- |
| `DataMigrationService+Export.swift` | `buildBackupPackage()` / `exportEncryptedArchive()` 加 `async`，仍在 `@MainActor` 类上（隔离不变）；后台加密在 `Task.detached` |
| `DataMigrationService+Restore.swift` | `restore()` 加 `async throws`，仍在 `@MainActor` 类上（隔离不变） |
| `DataMigrationService.swift` | 新增 `private nonisolated static func inspectBackupFilePayload/openPackage`（纯解析，不碰主 actor 状态）；新增 async 入口 |
| `LLMModelManager.swift` | `importModel` 由同步改 `async`，类仍是 `@MainActor`；重活 detached |
| `SearchIndexService.swift` | `engine` 由 `public let` 改为 `public private(set) var`（原子替换需要）；`rebuildIndex` 加 `force` 参数；类仍是 `@MainActor` |
| `WebDAVSyncService.swift` | 仅调用点 `try await`；类仍是 `@MainActor` |
| 视图层 | `DataMigrationView` / `LLMModelManagementView` 调用点改 `Task { await }` + 进度态；`WebDAVSyncView` 仅 2 处 `try await restore`（Lead 已批准） |

**没有**把任何 `ModelContext`、`@Model` 对象、`PersistentModel` 实例送进后台闭包。

---

## 7. 仍在主线程 / 留给后续（明确不做或做不了的）

1. **导出取数仍主 actor**：`ModelContext` 非 `Sendable`，按任务要求保守处理——没有改用
   `ModelContext(container)` 后台取数。若要彻底移出，需要新建后台 context + 结果回传 +
   主 context 刷新的一致性设计，改动大、风险高，建议单独立项。
2. **还原最终 `context.save()` 仍主 actor**：SwiftData 主上下文落盘无法跨线程；
   这是还原路径剩余的最大单次停顿（与旧实现相同）。分片已把「save 之前」的累积停顿拆掉。
3. **附件整包内联**：备份格式要求附件进 JSON，导出峰值仍 ≈ 附件 ×3–4。附件外置
   （包里只存文件名+摘要、附件独立文件/流式加密）需要改备份格式与还原写回，
   会破坏旧备份兼容，列为后续项——改格式时必须带版本迁移。
4. **`getLocalDataStats()`** 仍在 `DataMigrationView.body` 每次渲染做 20 次 `fetchCount`
   （SVC-10/P3 的同类问题）：与本次三件事无直接关系，未动。
5. **`WebDAVSyncService.performBackgroundSyncIfNeeded` 失败仍只 print**（SVC-02）：
   属于批 3 通知/巡检工作流，未动。
6. **搜索索引令牌的覆盖粒度**：行数 + 单表最新时间戳；若某表在两行间「删一条、加一条」
   且新加行的日期早于旧最新日期，理论上有漏判（概率极低；手动刷新可兜底）。
   更严格可改用各表 `updatedAt` 最大值 + 行数，但需要给缺时间字段的表加字段（改模型），
   本次不做。
7. **`check_settings_keys.py` 当前红**：来自批 3 通知/巡检改动新增的 4 个 UserDefaults 键
   （`foregroundAudit.*`、`notificationBudget.*`、`sleepReminder.*`），**不是本次 I/O 改动引入**；
   需要 task-6 的 owner 登记白名单或豁免。本次改动的 11 个文件未新增任何 UserDefaults 键。

---

## 8. 验证记录（本沙箱内能跑的）

```
# 1) 语法（每个改动文件）
xcrun swiftc -parse -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -target arm64-apple-ios18.0 <file>
#  ✅ 11/11 通过（含 DataMigrationView / WebDAVSyncView / LLMModelManagementView / TodoListView）

# 2) 闸门
python3 scripts/check_save_swallow.py         # ✅ exit 0，仍 64 处（基线 64，未新增）
python3 scripts/check_radius_tokens.py        # ✅ exit 0
python3 scripts/check_backup_pin_literals.py  # ✅ exit 0
python3 scripts/check_settings_keys.py        # ❌ 仅因 task-6 新键（见 §7.7），非本次改动

# 3) Core 单测（环境自检，未改 Core）
cd Packages/AssistantCore && swift test --disable-sandbox
#  ✅ exit 0：1116 tests, 0 failures
```

**整包 `xcodebuild` / 全量 `swiftc -typecheck` 在本沙箱不可用**（已实测）：
`swift-plugin-server` 被沙箱拒绝（`sandbox-exec: sandbox_apply: Operation not permitted`），
`@Model` / `@State` 宏全部无法展开，任何依赖宏的模块都无法类型检查。因此
本批的编译级验证 = 逐文件 `-parse` + 人工核对（含全部调用点 `await` 检查）：

```
grep -rn "exportEncryptedArchive(\|restore(from:\|importModel(\|rebuildIndex(" Assistant/
#  ✅ 所有调用点均已改为 try await / Task { await ... }
```

---

## 9. 需要真机验证的点（交付给 Lead 的清单）

1. **导出**：100+ 证件照/语音、约 200MB 附件的库，点「生成加密备份」：
   - Time Profiler 主线程无 PBKDF2/AES/base64 热点；后台 utility 线程承担；
   - UI 在导出期间可滚动、可点取消/返回；内存峰值不 OOM；
   - 生成的备份能在旧版本（或另一台机）成功导入（格式兼容回归）。
2. **还原**：同库覆盖还原：
   - 「还原中」进度先渲染再开始重活；
   - 中途杀掉 App 后重启：数据要么是旧库、要么完整新库（不允许半成品库）；
   - 失败注入（缺附件备份 + 覆盖策略）→ 库未变。
3. **解锁/选文件**：大备份文件选择/输 PIN 时主线程无卡顿；错误 PIN 文案不变。
4. **模型导入**：≥2GB GGUF 从「文件」App 导入，主线程不卡；`Documents/Models`
   `isExcludedFromBackup == true`；iCloud 备份大小不含模型。
5. **搜索**：打开→关闭→再打开，第二次主线程耗时明显下降；
   新增/编辑待办后打开能搜到新内容；手动刷新会真正强制重建。
6. **NAS 自动备份**：BGAppRefresh 真机跑一次，自动备份不再被后台预算杀掉。
