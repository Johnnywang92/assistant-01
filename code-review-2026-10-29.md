# 代码审查记录（2026-10-29）

## 审查基线与规则

- 基线：`main`，`54524fe`（`chore(ci): 新增圆角令牌闸门并接入 ci.sh`）；开始审查时 `git status --short` 无输出。
- 本轮只写审查文档，不修改业务代码、不提交或推送。
- 采用风险导向审查，不宣称逐行覆盖全仓。优先检查数据安全、备份还原、跨端操作、提醒、AI 执行和外部输入。
- 每个发现必须提供当前代码证据、触发条件、用户影响、修复建议与验证办法；历史记录仅用于排除已修复问题，不作为当前结论依据。
- 严重性：P1＝应优先修复的数据丢失/安全/关键链路错误；P2＝特定场景下的功能正确性问题；P3＝低影响改进。疑点不计入已确认问题。
- “静态确认”仅说明源码路径成立，不等于已经在真机复现；自动化、构建和真机结果分别记录。

## 结论摘要

本轮确认 11 项问题：**P1 两项**（CR-01 分享导入丢数据、CR-04 自动备份写死口令）、**P2 九项**。除 CR-02/CR-03 是交互状态流外，其余集中在同一族：动作被报「成功」但实际没落库/没生效，以及外部输入（CSV、WebDAV 响应、OCR 文本、服务器给的 href）被无条件信任。逐范围审查状态见「审查覆盖与验证」。**四批（CR-04/CR-05；CR-06/CR-07/CR-01；CR-08/CR-02/CR-03；CR-11/CR-09/CR-10）均已于 2026-10-30 修复并验证**，见「验证记录」。

## 已确认问题

### CR-01 · P1 · 分享导入失败仍确认消费，原始载荷被永久删除

- **位置**：[ShareInboxService.swift:35–50](Assistant/Services/ShareInboxService.swift#L35)、[58–115](Assistant/Services/ShareInboxService.swift#L58)、[120–153](Assistant/Services/ShareInboxService.swift#L120)；删除实现：[ShareImportBridge.swift:126–134](WidgetShared/ShareImportBridge.swift#L126)。
- **触发**：分享图片 OCR 抛错、图片字节暂时不可读，或分享文本/图片/链接落库时 `context.save()` / `ImportService.ingest` 抛错。
- **证据链**：`handleImage` 捕获 OCR 错误后直接返回，保存和规则导入使用 `try?`；`handleText` 同样不返回成功状态；外层循环无论结果如何都调用 `ShareImportBridge.remove(payload)`，连图片原件一并删除。[ImportService.swift:71](Assistant/Services/ImportService.swift#L71) 原本会向调用方抛出保存错误，但此处被吞掉。
- **影响**：没有成功入库也失去重试来源；部分分支还发出“已记/已添加”成功通知。磁盘写满、数据库写入失败或 OCR 失败后，用户可能只看到成功提示或识别失败提示，无法从收件箱重试。
- **建议**：让每条处理返回明确成功/可重试失败结果，仅在事务保存成功后确认删除；保存前不要发成功通知/安排依赖落库的副作用。为 payload ID 建立持久化幂等记录，避免保存成功但删除失败后重复记账。
- **验证**：对 OCR、读取和保存分别注入失败，检查 JSON/图片仍在且没有成功反馈；重试成功只生成一份数据。
- **状态**：**已修复（2026-10-30，批次二）**。原为静态调用链确认、未做真机故障注入。`handleImage` / `handleText` / 规则导入统一返回 `.done` / `.retryable(reason)`：保存抛错即 `context.rollback()` 并保留 JSON 与图片，成功通知改到落库之后（建待办还改为先落库再排提醒）；只有 `.done` 才 `remove` 来源。图片字节暂时读不到（锁屏文件保护）也按可重试保留，不再当损坏丢弃。单条载荷最多尝试 3 次，第 1 次与第 3 次失败各发一条通知，之后停止重试、来源留在中转区。新增 App Group 根目录的 `ShareInboxLedger.json`：落库成功后记录 payload ID，删除文件失败时下次排空只清文件、不再重复入账；旧版 JSON 没有 `attempts` 字段也能解码。无调用方的 `drainAll()`（读出即删）一并删除，避免同类路径复现。

### CR-02 · P2 · 语音详情的预加载播放分支没有启动进度计时器

- **位置**：[VoiceMemoAudioService.swift:166–203](Assistant/Services/VoiceMemoAudioService.swift#L166)、[210–223](Assistant/Services/VoiceMemoAudioService.swift#L210)；调用方：[VoiceMemoDetailView.swift:128–129](Assistant/Features/VoiceMemoDetailView.swift#L128)、[146–182](Assistant/Features/VoiceMemoDetailView.swift#L146)。
- **触发**：从列表打开一条未在播放的语音备忘，直接点击详情页的播放按钮。
- **证据链**：`onAppear → prepare` 创建 player、设置 `playingFileName`，并通过 `stopPlayback()` 清掉原计时器；随后 `togglePlayback` 命中同文件分支，执行 `p.play()` 后直接返回。更新 `playbackTime` 的计时器只在另一条 `play(fileName:)` 路径创建。
- **影响**：音频播放但进度条、已播/剩余时间停住；±15 秒跳转以陈旧的 `playbackTime` 为起点，连续快进无法按实际播放位置前进。
- **建议**：在实际开始/恢复播放时统一启动唯一的进度计时器，保留预加载不启动计时器的约束；快进/快退基于当前 player 时间。
- **验证**：打开详情后播放、暂停恢复、切换录音、自然播完后重播；检查时间推进与连续快进，同时确保没有重复计时器。
- **状态**：**已修复（2026-10-30，批次三）**。计时器创建收敛到唯一的 `startPlaybackTimer()`：`play(fileName:)` 与 `togglePlayback` 的恢复分支共用，`prepare` 仍只建 player、不建计时器（保留预加载不空转的约束）。暂停（含来电中断）时失效计时器并把 `playbackTime` 对齐 `player.currentTime`，恢复时重建，全局最多一条计时器。`skip(by:)` 改以 `player.currentTime` 为基准，连续快进不再按滞后的 `playbackTime` 越跳越偏。未做真机音频交互验证（播放、暂停恢复、自然播完重播的屏幕级行为仍需真机确认）。

### CR-03 · P2 · 块编辑中直接点“完成”会静默丢弃正在输入的文字

- **位置**：[VoiceMemoBlockEditorView.swift:64–65](Assistant/Features/VoiceMemo/VoiceMemoBlockEditorView.swift#L64)、[254–270](Assistant/Features/VoiceMemo/VoiceMemoBlockEditorView.swift#L254)、[443–464](Assistant/Features/VoiceMemo/VoiceMemoBlockEditorView.swift#L443)、[504–508](Assistant/Features/VoiceMemo/VoiceMemoBlockEditorView.swift#L504)。
- **触发**：长按段落进入编辑，修改文字后不点段落内“保存”，直接点击页面右上角“完成”。
- **证据链**：`TextEditor` 绑定独立的 `editingText`；仅 `commitEditing` 将草稿写入 `document.blocks`。顶层 `save()` 直接 `memo.apply(document: document)` 并关闭页面，未提交编辑中的草稿，也未提示。
- **影响**：界面显示保存成功的触感并退出，但刚修改的段落仍是旧文；新增段落可能仅保存空块。
- **建议**：顶层“完成”先提交当前编辑块，再持久化整个文档；持久化错误保留编辑状态并明确提示。
- **验证**：已有段落修改、新增段落、清空段落后分别直接点“完成”，重开并验证文字/删除结果；补保存失败场景。
- **状态**：**已修复（2026-10-30，批次三）**。顶层「完成」先 `commitEditing(blockID:)` 把就地编辑中的草稿写回 `document`（空内容仍按删除处理），再 `memo.apply` + `context.save()`；`save()` 改为 `do/catch`，失败时保留页面与编辑状态并弹出「保存失败：…」，不再 `try?` 后假装成功退出。段落内「保存」与顶层「完成」共用同一份提交逻辑，避免两套行为漂移。未做真机 UI 验证。

### CR-04 · P1 · 后台自动备份用写死口令加密，且不向用户披露

- **位置**：[WebDAVSyncService.swift:233–251](Assistant/Services/WebDAVSyncService.swift#L233)（口令常量在 [244](Assistant/Services/WebDAVSyncService.swift#L244)）；开关入口：[WebDAVSyncView.swift:98–104](Assistant/Features/WebDAVSyncView.swift#L98)；后台调用点：[BackgroundRefreshCoordinator.swift:101–104](Assistant/Services/BackgroundRefreshCoordinator.swift#L101)。
- **触发**：用户打开「启用后台静默自动备份」，后台巡检即自动生成并上传加密备份。
- **证据链**：`performBackgroundSyncIfNeeded` 传入常量 `"AssistantAutoSync2026!"` 作为 PIN；`uploadBackup` → `exportEncryptedArchive(pin:)` 用它派生密钥；`BackupEnvelopeCrypto` 的 PBKDF2 强度前提是口令保密。UI 只有开关与上次同步时间，没有任何一处说明这批文件由内置口令保护，也没有让用户为自动备份设定口令的入口。
- **影响**：文件内含密码库明文（导出侧会 `decrypt` 成明文再进封套，见 [DataMigrationService+Export.swift:130–137](Assistant/Services/Migration/DataMigrationService+Export.swift#L130)）、证件照与全部账目。口令在分发的二进制里可提取，因此任何拿到 `.assistantbackup` 文件的人都能解密；README 承诺的「PIN 加密导出导入」在这条路径上不成立。
- **建议**：为自动备份引入用户自设、只存 Keychain 的独立口令（或每次随机口令 + 只在本机保存的清单），并在开关文案里写清远端文件的可解密性；不要沿用手动导出的 PIN 语义。
- **验证**：Core 层补一条断言，禁止业务代码把字面量传进 `exportEncryptedArchive`；真机验证关闭/重开开关后的远端文件不可用固定常量解密。
- **状态**：**已修复（2026-10-30，批次一）**。口令改为用户在设置页自设、只存钥匙串（`WebDAVSyncService.autoSyncPIN` / `setAutoSyncPIN`），`performBackgroundSyncIfNeeded` 取不到口令即静默跳过、内置常量已删除；开关开启前强制先设口令，界面如实披露「只存钥匙串、App 内无法再看、忘记即不可恢复、更换只影响之后的备份」。新增 `scripts/check_backup_pin_literals.py` 闸门并接入 `ci.sh`，字面量（含同文件字面量常量绕道）判红。闸门红绿两态已实跑；未对真实 NAS 做端到端上传验证。

### CR-05 · P2 · 下载远端备份时按服务器给的绝对地址发请求并附带 Basic 凭据

- **位置**：[WebDAVSyncService.swift:185–211](Assistant/Services/WebDAVSyncService.swift#L185)；`path` 来源：[WebDAVModels.swift:189–202](Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift#L189)。
- **触发**：连接的 WebDAV 服务（或被中间篡改的响应）在 PROPFIND 的 `<d:href>` 中返回指向第三方主机的绝对 URL。
- **证据链**：`downloadBackup` 对 `item.path.hasPrefix("http://")/("https://")` 直接使用，不经 `makeFileURL` 校验来源，随后 `makeGETRequest` 仍注入 `Authorization: Basic base64(user:password)`（[WebDAVModels.swift:141–150](Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift#L141)）。此外 `makeDirectoryURL` 明确允许 `http://`（[78–92](Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift#L78)），凭据可明文传输。
- **影响**：NAS 账号口令可被恶意服务端外带到第三方；与「数据只存本机、备份端到端加密」的隐私承诺冲突（口令泄漏后远端文件即失去保护）。
- **建议**：只接受与配置同源同 scheme 的相对 href，跨源直接丢弃；对 `http://` 给出显式风险标识或限制为仅本机/局域网。
- **验证**：Core 加解析用例：绝对跨源 href 不应进入下载列表或应被拒；抓包确认请求主机与授权头。
- **状态**：**已修复（2026-10-30，批次一）**。新增 `WebDAVRequestFactory.makeFileURL(fromHref:serverURL:remoteDirectory:)`：只接受相对 href，或与配置同源同 scheme（默认端口等价）且路径落在备份目录内的绝对 href；跨源、scheme 降级、目录外、`..` 一律返回 nil。`downloadBackup` 与远端列表过滤都改走它，被拒时回执「远端返回的文件地址不在本机配置的服务器与备份目录内」。顺带把 `deleteRemoteBackup` 从「用服务器给的 displayname 拼路径」改成同一解析器——否则同一主机上的 `../` 名字能把「删一个备份」变成删任意路径。`http://` 由 `usesInsecureTransport` 在设置页给出明文传输警示。10 条 Core 单测覆盖跨源、`user:port@host` 伪装、降级、目录外、默认端口、编码名、遍历；未做真实 WebDAV 外带实验。

### CR-06 · P2 · 扩展指令先摘队后落库，写库失败即静默丢指令且谎报「已记录」

- **位置**：[WidgetSnapshotSync.swift:138–162](Assistant/Services/WidgetSnapshotSync.swift#L138)（队列在 [161](Assistant/Services/WidgetSnapshotSync.swift#L161) 摘除）、落库在 [117–130](Assistant/Services/WidgetSnapshotSync.swift#L117)（`try? context.save()`）；入队侧反馈：[WidgetIntents.swift:274–276](WidgetShared/WidgetIntents.swift#L274)、[313–315](WidgetShared/WidgetIntents.swift#L313)。
- **触发**：手表/Siri 一句话记账或新建待办进入扩展队列，主 App 回前台对账时数据库写入抛错（磁盘满、迁移异常）或在保存前被系统终止。
- **证据链**：`processCommandBatch` 在处理完整批后立刻 `removeProcessedPrefix`，而 `context.save()` 在其外层循环结束后才执行且为 `try?`；抛错既不上报也不回滚队列。扩展侧无论入队是否真正落盘都返回「已记录，打开小助后自动入账」。
- **影响**：账目/待办永久消失且用户已被告知成功；快照层还可能已把金额乐观累加（[WidgetSnapshot.swift:171–175](WidgetShared/WidgetSnapshot.swift#L171)），下轮刷新才回落。
- **建议**：把队列裁剪改成「按已成功落库的子集」并在 `save()` 成功后执行；失败保留在队并给出可重试提示；扩展侧回调用语改为「待入账」。
- **验证**：Core/集成用例注入 save 失败，断言指令仍在队、二次对账只入账一次；真机验证手表记账后杀 App 再开。
- **状态**：**已修复（2026-10-30，批次二）**。`processCommandBatch` 改为逐条返回 `.applied` / `.consumed` / `.retry`，只在 `try context.save()` 成功后才 `removeFirst(成功前缀条数)`；save 抛错则 `context.rollback()` 并保留整批，队首遇到暂时性失败立即停下（不越过它执行后面的指令），下次回前台重试。`enqueue` 改为返回是否真正写入，扩展侧五个入队点按回执分支：没写进去就说「没能同步／没能记录，请打开小助」，且入队失败时不再先改本地乐观快照；主 App 处理 `.quickAddExpense` 时也去掉了「先累加快照金额再 save」的写入（`refreshSnapshot` 本就会按库重建）。队列 read-modify-write 加 `flock` 跨进程互斥（最多等 50ms，拿不到锁退回无锁，不阻塞扩展进程）。`WidgetSnapshotStore.removeProcessedPrefix` 与其只服务于「读出即删」的 `drainAll` 已删除。

### CR-07 · P2 · 稍后提醒与出门清点把「查询抛错」当成「条目不存在」

- **位置**：[WidgetSnapshotSync.swift:183–196](Assistant/Services/WidgetSnapshotSync.swift#L183)（`(try? context.fetch(descriptor))?.first else { return }`）、[198–203](Assistant/Services/WidgetSnapshotSync.swift#L198)。
- **触发**：手表点「10 分钟后/明早 9 点」或勾清单项，主 App 对账时该条 `FetchDescriptor` 抛错。
- **证据链**：同文件的 `completeInDB` 已在 `96846ef` 改成 `do/catch` 并打印告警（[164–181](Assistant/Services/WidgetSnapshotSync.swift#L164)），这两条兄弟路径仍是 `try?`；抛错 → `nil` → 直接 `return`，指令随后被 CR-06 的裁剪摘走。
- **影响**：提醒不会重排（用户以为已推迟，仍按原时间到点或永不到点）、清单项在卡片上显示已勾而库内未变，下次刷新回弹。
- **建议**：与 `completeInDB` 对齐，抛错即保留指令并告警；配合 CR-06 的「按成功子集裁剪」。
- **验证**：注入抛错路径断言指令保留且不落库；真机走一遍手表推迟与勾选。
- **状态**：**已修复（2026-10-30，批次二）**。`snoozeInDB` 与 `toggleDepartureInDB` 改成 `do/catch`：查询抛错返回 `.retry`（指令留在队首、下次对账重试），只有确实查不到才按「条目已不存在」消费；`completeInDB` 同步改成三态返回值，与这两条路径对齐。

### CR-08 · P2 · 收卡动作交给未 await 的 `Task`，扩展进程可能带着「已结束」回执被回收

- **位置**：[WidgetIntents.swift:130–136](WidgetShared/WidgetIntents.swift#L130)、[156–162](WidgetShared/WidgetIntents.swift#L156)；同一形状还在 [WidgetActivityModels.swift:125](WidgetShared/WidgetActivityModels.swift#L125)、[127](WidgetShared/WidgetActivityModels.swift#L127)、[138](WidgetShared/WidgetActivityModels.swift#L138)、[164](WidgetShared/WidgetActivityModels.swift#L164)、[166](WidgetShared/WidgetActivityModels.swift#L166)。
- **触发**：锁屏/Mac 通知中心/手表伴随通知 action 点「已出发，关闭卡片」或「全部带齐」——这些都在扩展进程执行。
- **证据链**：`perform()` 里对 `activity.end(...)`/`activity.update(...)` 只 `Task { await … }` 不等待，随即 `return .result(dialog:)`；`end` 抛错无人接收。扩展进程在 `perform()` 返回后随时可能被系统回收。
- **影响**：灵动岛/锁屏/Mac 通知中心留下死卡，用户已被告知「已结束护航」；与项目记忆中的约束叠加——手表智能叠放整卡不可交互，关闭语义唯一的载体就是这条 action。
- **建议**：`perform()` 内 `await` 全部结束/更新操作后再返回回执，失败时如实回执「未能收起」；主 App 侧保留一条巡检兜底收卡。
- **验证**：真机 iPhone + Watch/Mac 通知中心各点一次，观察收卡与错误回执；静态检查无 `Task { await ` 的 fire-and-forget 残留。
- **状态**：**已修复（2026-10-30，批次三）**。`PickupActivityHelper.markCompleted/endActivity` 与 `DepartureActivityHelper.setChecked` 改为 `async`，内部直接 `await activity.end/update`，不再派发未等待的 `Task`；扩展侧四个回执路径（完成待办、出门单项、全部取齐、全部带齐）经 `WidgetBridge.apply*Locally` 全部 await 后才 `return .result`。`EndTravelActivityIntent` / `EndDepartureActivityIntent` 先 await 全部 end，再回查 `Activity.activities`（最多 3 次、每次 120ms）确认是否真的收起：收不掉就如实回执「还有 N 张卡片没收起，请再点一次」，不再提前报「已结束」。主 App 侧 `LiveActivityService.end*Activities` 同步改为 async，重推清点卡前先 await 旧卡收起（避免两代卡片并存）；`LiveActivityControlNotifications` 的「全部带齐」也改为 await 卡片更新后再 `reconcile()`，点完通知不再挂着。指令对账与清单勾选等同步调用点保留 `Task { await … }` 交给长寿的主 App 进程执行。静态检索扩展侧已无 `Task { await activity` 残留；**实际发生率、回执措辞与真机收卡效果仍需 iPhone + Watch/Mac 通知中心现场验证**。

### CR-09 · P2 · 预算播报全表物化并把查询失败当成「本月没有支出」

- **位置**：[WidgetSnapshotSync.swift:353–377](Assistant/Services/WidgetSnapshotSync.swift#L353)，其中 [359](Assistant/Services/WidgetSnapshotSync.swift#L359) 为 `FetchDescriptor<ExpenseRecord>()` 无谓词 + `try?`。
- **触发**：Siri/手表问「预算」，账本已有多月历史；或该查询抛错。
- **证据链**：同文件其他路径已改为窗口谓词取数（[100–112](Assistant/Services/WidgetSnapshotSync.swift#L100)、[27–29](Assistant/Services/WidgetSnapshotSync.swift#L27) 并写明「避免全量物化到主线程」），此处例外；`SafeToSpendCalculator.inputFromRecords` 收到 `?? []` 的空账本会算出「本月剩余＝全额预算」。第五轮实测结论：列表成本约 15µs/行，与索引无关，只能靠谓词/分页解决。
- **影响**：大额账本下主线程卡顿（免掏手机入口正是最在意延迟的路径）；抛错时播报警告级别的错误数字。
- **建议**：按月窗口谓词取数（或复用已有月度汇总），失败时回执「暂时读不到账本」而不是给出一版看似安全的额度。
- **验证**：Core 加「抛错≠空账本」用例；大数据集真机测 `handleQueryBudget` 耗时。
- **状态**：**已修复（2026-10-30，批次四）**。`handleQueryBudget` 的全表 `FetchDescriptor<ExpenseRecord>()` 改为 `ExpenseRecordWindow.budgetWindow()` 生成的窗口谓词（本月 + 昨日 + 本周一，月初/周初跨月时前探到上月，避免漏取昨日与本周记录）；`todayExpenseTotal` 改为返回 `Double?`，预算播报读账本失败时回「暂时读不到账本，算不出今天的安心花额度」，记账回执则整段省略「今日累计支出」，不再用 0 元冒充。窗口边界补了 7 条 Core 单测（月中、月初、周日、周初跨月、月末周六）。**「抛错≠空账本」的分支在 App 层，`AssistantCore` 没有对应入口，未做抛错注入；大数据集下 `handleQueryBudget` 的耗时未在真机重测**。

### CR-10 · P2 · 一句话生活记录把「查询抛错」当成「还没有档案」，凭空新建重复对象

- **位置**：[OmniboxExecutors.swift:788–847](Assistant/Features/Omnibox/OmniboxExecutors.swift#L788)，`pets.first ?? create`（[791–795](Assistant/Features/Omnibox/OmniboxExecutors.swift#L791)）、`vehicles`（[817–821](Assistant/Features/Omnibox/OmniboxExecutors.swift#L817)）、`children`（[843–847](Assistant/Features/Omnibox/OmniboxExecutors.swift#L843)）。
- **触发**：语音说「给毛孩子记一次驱虫」，该 `FetchDescriptor` 抛错（同一形状在习惯/服药匹配处 [659–690](Assistant/Features/Omnibox/OmniboxExecutors.swift#L659) 只是判成「没找到」，非破坏性）。
- **证据链**：`(try? context.fetch(desc)) ?? []` 后再 `first ?? 自动 insert 新建`，把「读不到」与「确实没有」压成同一条自动建档路径。
- **影响**：库里多出名为「毛孩子／爱车／宝宝」的占位档案，且本次记录挂到错对象；用户不会收到任何异常提示，后续再记一次会命中旧档案，形成两份并行数据。
- **建议**：区分两种情况——抛错直接回执「暂时读不到档案」，不做写入；只有确认为空时才走首次建档，并在回执里说明新建了档案。
- **验证**：注入抛错断言不插入新记录；真机各条域走一次首次建档与已有建档。
- **状态**：**已修复（2026-10-30，批次四）**。pet / vehicle / child / skill 四处取数改为 `do/catch`，读失败抛新增的 `OmniboxError.dataUnavailable`，回执原样展示「暂时读不到…档案，本次没有写入」，不插入任何记录；只有确认库中确实为空时才走首次建档，回执追加「（已新建档案「毛孩子／爱车／宝宝／title」）」。skill 分支是同一形状（审查位置列表未列），本次一并修掉。习惯/服药匹配与撤销令牌里的 `try?` 是非破坏性/尽力而为，保持不变。**未做抛错注入，也未在真机分别走首次建档与已有建档**。

### CR-11 · P2 · 密码/纪念日 CSV 用裸逗号切分，含逗号的字段被静默截断且回执仍报「成功」

- **位置**：[DataMigrationService.swift:341–373](Assistant/Services/DataMigrationService.swift#L341)（裸切在 [346](Assistant/Services/DataMigrationService.swift#L346)）、同形状的纪念日 [312–338](Assistant/Services/DataMigrationService.swift#L312)；回执文案：[DataMigrationView.swift:500–502](Assistant/Features/DataMigrationView.swift#L500)。
- **触发**：从别的密码管理器导出的 CSV 里，标题/账号/密码/备注任一字段的值本身含逗号（通用 CSV 会用双引号包裹，这是常见情形）。
- **证据链**：解析只按 `,` 切且不做引号处理，双引号连同内容原样进入字段值，后续字段整体右移；行序为 `title,account,password,…`，一旦密码含逗号，落库密码就是被截断的前半段，多余部分变成分类/备注。返回的 `count` 只统计插入条数，UI 直接播报「成功批量登记 N 个账号密码凭据」，不报跳行或错位。
- **影响**：凭据以「看似成功」的方式损坏，用户要到复制粘贴登录失败时才发觉，此时原始 CSV 往往已丢弃；日期列含逗号时同样被判无效而静默跳行。
- **建议**：CSV 解析下沉 `AssistantCore`，支持引号与转义（或明确只接受制表符分隔并在 UI 写清格式），返回 `(imported, skipped)` 并在回执列出跳过行号与原因。
- **验证**：Core 单测覆盖 `a,"b,c",d`、`"he said ""hi""",x,y`、尾随空字段与非法日期；真机用系统「密码」App 导出的 CSV 走一遍。
- **状态**：**已修复（2026-10-30，批次四）**。CSV 解析下沉为 `AssistantCore/CSVParser.swift`（RFC 4180 风格：引号包裹、`""` 转义、引号内逗号/换行、CRLF/CR/LF、BOM，记录带物理行号）；逐行校验与跳过原因在 `BatchCSVImport.swift`。`batchImportAnniversaries` / `batchImportPasswords` 返回 `BatchImportReport(imported, skipped)`，密码保持原样不 trim，日期用公历 + POSIX locale 解析并回写比对（`2022-02-31` 这类溢出日期判无效）。导入回执列出前 5 个跳过行的物理行号与原因（字段不足 / 字段为空 / 日期无效 / 密码加密失败），全部被跳过时保留输入原文供用户改。新增 23 条单测（11 条解析 + 12 条导入校验）全绿。**未用系统「密码」App 真实导出的 CSV 走一遍，也未做 UI 级导入实测**。

## 审查覆盖与验证

| 范围 | 状态 | 结论 |
| --- | --- | --- |
| 分享导入与扩展交接 | 已审 | CR-01；另 CR-06/CR-08 涉及扩展侧回执 |
| 语音备忘与分享卡片（近期改动） | 已审 | CR-02、CR-03；`ShareCardActions` 与分享面板释放路径未发现缺陷 |
| 备份还原、同步、认证与密码库 | 已审 | CR-04、CR-05、CR-11 |
| 提醒、跨端队列与生命周期 | 已审 | CR-06、CR-07、CR-08、CR-09 |
| AI 动作与上下文边界 | 抽查 | CR-10；Omnibox 事务/撤销令牌结构本身核对通过，未覆盖全部 15 个 capability 分支 |
| 质量闸门与构建 | 已实测 | 见「验证记录」 |

## 修复批次

1. **第一批（凭据与隐私，改动面最小）· ✅ 已落地 2026-10-30**：CR-04、CR-05。自动备份口令改为用户自设并只存 Keychain（无口令不上传），新增字面量闸门；WebDAV 只接受同源同 scheme 且在备份目录内的 href，跨源条目从列表丢弃并拒发请求，`http://` 显式警示。
2. **第二批（「成功但没落库」一族）· ✅ 已落地 2026-10-30**：CR-06、CR-07、CR-01。统一改成「落库成功后才确认消费」，失败保留来源并如实回执；顺带解决队列的无锁 read-modify-write（台账已记的遗留项）。
3. **第三批（交互真实性）· ✅ 已落地 2026-10-30**：CR-08、CR-02、CR-03。收卡/更新操作改为 `await` 后再回执并回查真实结果；播放器开始/恢复播放统一启动唯一进度计时器；块编辑器顶层「完成」先提交草稿、保存失败留在页面并提示。
4. **第四批（导入正确性与性能）· ✅ 已落地 2026-10-30**：CR-11、CR-09、CR-10。CSV 解析下沉 Core 并支持引号/转义，导入回执列出跳过行号与原因；预算播报改窗口取数，读失败与空账本分开处理；生活记录建档区分「读失败/确实没有」，首次建档在回执里说明。

## 已核对未发现缺陷的关键路径

- 覆盖还原流程 [DataMigrationService+Restore.swift:45–132](Assistant/Services/Migration/DataMigrationService+Restore.swift#L45)、[1004–1072](Assistant/Services/Migration/DataMigrationService+Restore.swift#L1004)：附件预检先于清库、备份负载与口令加密在删除前验证、失败 `context.rollback()`、偏好设置在 `save()` 之后写入、孤儿文件清理走 `BackupRestoreGuard.pruneDecision(referenceLookupSucceeded:)` 双保险。
- 迁移计划 [Persistence.swift:26–50](Assistant/Services/Persistence.swift#L26)、[247–269](Assistant/Services/Persistence.swift#L247)：三级兜底均不删文件，失败走内存容器承载恢复页；DEBUG 下有 V1 模型覆盖断言。
- 密码库导出/还原对称性 [DataMigrationService+Export.swift:130–137](Assistant/Services/Migration/DataMigrationService+Export.swift#L130) 与 Restore 的 [84–88](Assistant/Services/Migration/DataMigrationService+Restore.swift#L84)：DTO 明文只存在于加密负载内，还原时重新加密，无双重加密。
- 门禁 PIN [DataMigrationService.swift:122–178](Assistant/Services/DataMigrationService.swift#L122)：只存盐+派生校验值、恒时比较、改 PIN 需先验旧 PIN、重置不影响既有备份。
- 分享扩展交接 [ShareImportBridge.swift:84–97](WidgetShared/ShareImportBridge.swift#L84)：写 JSON 失败会回收已落盘的图片文件，不留孤儿。

## 待验证事项

- 真机交互、权限状态、后台调度与 Apple Watch 联动不由纯逻辑单元测试证明。
- CR-04/CR-05 需要一次真实 WebDAV 端点才能验证端到端行为；本轮未联网。
- CR-08 的实际发生率只能在 iPhone + Watch/Mac 通知中心现场复现。
- CR-09 的抛错分支与大数据集耗时、CR-10 的首次建档路径、CR-11 的「密码」App 导出文件都还没有真机实测。

## 验证记录

实测（本机 2026-10-29，均为一次性真实执行）：

- 初始工作区检查：`git status --short` 无输出；本轮只新增/修改本文档，未改业务代码。
- 质量闸门 `./scripts/ci.sh test`：退出码 0。偏好键覆盖闸门通过（另有 5 处含插值的键模板按闸门规则不判定）；圆角令牌闸门通过（扫描 `Assistant/` 跳过 `Assistant/Theme/`，圆角字面量 0 处）；`swift test` **812 项全部通过，0 失败**（1.594s）。
- iOS 构建：`xcodebuild -project Assistant.xcodeproj -scheme Assistant -destination 'generic/platform=iOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`，依赖图 6 个 target（主 App、Widget 扩展、Share 扩展、AssistantCore 及其资源包）。未生成新工程（未跑 `xcodegen`），用的是仓库现有 `.xcodeproj`。
- 上述两条自动化结果只证明「当前 HEAD 可构建、纯逻辑测试绿」，**不覆盖本轮任何一条发现**：CR-01～CR-11 全部位于 App 层/扩展层路径（`ShareInboxService`、`WidgetSnapshotSync`、`WebDAVSyncService`、View 层状态流），现有 `AssistantCore` 测试没有对应入口。因此每条的「状态」栏都写的是静态确认，修复时要按各条「验证」栏补测试或真机步骤。

未做的验证：

- 未跑模拟器或真机（项目仅真机构建路径可信，LlamaSwift 无模拟器切片）；UI 类结论（CR-02、CR-03）没有屏幕级复现。
- 未连接真实 WebDAV 端点（CR-04、CR-05）；未做实际 CSV 导入（CR-11）；未观测挂起通知条数（与既有台账 D 项一样保持未定级）。
- 未运行 `scripts/migration-drill` 与备份还原大数据集演练。

分批修复验证（2026-10-30，第一批 CR-04 / CR-05）：

- `./scripts/ci.sh test` → 退出码 0。三道闸门全绿：偏好键覆盖、圆角令牌、新增的备份口令字面量；`swift test` **822 项全部通过、0 失败**（原 812 + 新增 10 条 href 解析与明文传输用例，1.7s）。
- 新闸门红绿两态实跑：临时探针文件写 `let defaultSyncPIN = "…"` 后 `uploadBackup(pin: defaultSyncPIN)`、以及直接 `pin: "HardCoded12345"` 各一处 → 判红并分别标注「同文件的字符串字面量常量」「直接传字符串字面量」；删除探针后 0 处、退出码 0。当前树 0 处（两处调用点都是函数参数）。
- iOS 构建：`xcodebuild -project Assistant.xcodeproj -scheme Assistant -destination 'generic/platform=iOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`。未跑 `xcodegen`，本轮未新增 Swift 文件（只加了 python 闸门脚本）。
- 仍未验证：真实 WebDAV 端点的跨源 href 拒绝与上传/下载端到端；真机走一遍「开启自动备份开关 → 提示先设口令 → 设口令后开关自动启用」与钥匙串重启后仍在；老用户在钥匙串无口令时的「自动备份当前未生效」警示行。

分批修复验证（2026-10-30，第二批 CR-06 / CR-07 / CR-01）：

- `./scripts/ci.sh test` → 退出码 0。三道闸门全绿；`swift test` **822 项全部通过、0 失败**（1.6s）。本批改动全部在 App 层与 `WidgetShared/`，不在 `AssistantCore` 测试范围内，用例数不变。
- iOS 构建：`xcodebuild -project Assistant.xcodeproj -scheme Assistant -destination 'generic/platform=iOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`（主 App、Widget 扩展、Share 扩展一并重编）。未跑 `xcodegen`，未新增 Swift 文件。
- 独立实跑（`swiftc` 编译 `WidgetSnapshot.swift` + `ShareImportBridge.swift` + 临时 `main.swift`，脚本未入库，运行输出 `OK`）：① 旧版无 `attempts` 字段的载荷 JSON 解码为 0 且字段完整——这条失败会让 `peekAll` 把用户待处理的分享当损坏文件删掉；② `attempts` 写回后往返保持；③ 连续入队两条后 `removeFirst(1)` 只摘队首、`removeFirst(5)` 清空队列。
- 静态检索：`removeProcessedPrefix` 0 处、`drainAll` 0 处；指令对账与分享导入路径不再有 `try? context.save()`。仍有 6 处 `try? context.save()` 位于 App 内直接执行 intent 的 hook 分支（`handleCompleteTodo` / `handleSnooze*` / `handleToggleDeparture` / `handleQuickAdd*`），属另一条回执链路，本批未改，**该路径「save 失败仍回『已完成／已创建』」的风险仍在**。
- 未做：故障注入（构造 `save()` 抛错）与真机「手表记账 → 杀 App → 重开」。`WidgetShared` 没有独立测试 target，这类验证要么新建 target（超出本批范围），要么上真机。

分批修复验证（2026-10-30，第三批 CR-08 / CR-02 / CR-03）：

- `./scripts/ci.sh all` → 退出码 0。三道闸门全绿；`swift test` **822 项全部通过、0 失败**（1.6s）；`xcodegen generate` 后 iOS 构建 `** BUILD SUCCEEDED **`（主 App、Widget 扩展、Share 扩展一并重编）。
- 静态检索（全仓 `*.swift`）：`Task { await activity` **0 处**，扩展进程的收卡 fire-and-forget 已清零；主 App 侧保留 4 处 `Task { await PickupActivityHelper/DepartureActivityHelper … }`（`WidgetSnapshotSync` 3 处、`DepartureChecklistView` 单行勾选 1 处）与 1 处批量重置循环，均为长寿进程内的显式异步收尾，不等回执。块编辑器 `try? context.save()` 已降为 **0 处**（改为 `do/catch` + 提示）。
- 未做：CR-08 的「收不住如实回执」只在代码层回查 `Activity.activities`，未在 iPhone + Watch/Mac 通知中心实测实际发生率；CR-02 未做真机播放/暂停/重播，CR-03 未做真机 UI 操作；本批三条都在 App 层，`AssistantCore` 没有对应入口，未新增单测。

分批修复验证（2026-10-30，第四批 CR-11 / CR-09 / CR-10）：

- `./scripts/ci.sh all` → 退出码 0。三道闸门全绿；`swift test` **852 项全部通过、0 失败**（1.65s；原 822 + 30 条新增：11 条 CSV 解析、12 条导入逐行校验、7 条预算取数窗口）；`xcodegen generate` 后 iOS 构建 `** BUILD SUCCEEDED **`（主 App、Widget 扩展、Share 扩展一并重编）。
- CR-11 实跑：新增单测覆盖 `a,"b,c",d`、`"he said ""hi""",x,y`、引号内换行与物理行号、CRLF/CR、BOM、尾随/前导空字段、纯空白行跳过，以及密码含逗号/转义引号时字段不错位；非法日期（`2022-13-45`、`2022-02-31`）与字段缺失/为空进入「跳过」并带行号。首轮 `2022-02-31` 曾被 `DateFormatter` 顺延成 `2022-03-03`，改为解析后回写比对才判无效。
- CR-09 实跑：窗口边界 7 条用例覆盖月中、月初（本周一在上月）、周日跨月、周一恰逢月初、月末周六；`handleQueryBudget` 不再有全表 `FetchDescriptor<ExpenseRecord>()`，取数走 `ExpenseRecordWindow.budgetWindow()` 谓词，`try context.fetch` 失败与非空判断分开。
- CR-10 静态检索：`executeLifeRecord` 四个域内 `try? context.fetch` **0 处**（习惯/服药匹配与撤销令牌的 `try?` 未动）；四处读失败统一抛 `OmniboxError.dataUnavailable`，只有取到空数组才建占位档案，回执追加「已新建档案」。
- 未做：系统「密码」App 真实导出 CSV 的导入、SQLite 抛错注入、真机首次建档/已有建档两条路径、大数据集下 `handleQueryBudget` 耗时；导入回执的换行与截断效果没有屏幕级核对。

## 覆盖边界

本轮为风险导向审查，不是全仓逐行审查。

实读文件（全文或全部相关段落）：`Assistant/Services/ShareInboxService.swift`、`WidgetShared/ShareImportBridge.swift`、`ShareExtension/ShareViewController.swift`、`Assistant/Services/ImportService.swift`、`Assistant/Services/VoiceMemoAudioService.swift`、`Assistant/Features/VoiceMemoDetailView.swift`、`Assistant/Features/VoiceMemo/VoiceMemoBlockEditorView.swift`、`Assistant/Features/Share/ShareCardActions.swift`、`WidgetShared/WidgetSnapshot.swift`、`WidgetShared/WidgetIntents.swift`、`WidgetShared/WidgetActivityModels.swift`（活动突变段）、`Assistant/Services/WidgetSnapshotSync.swift`、`Assistant/Services/Persistence.swift`、`Assistant/Services/DataMigrationService.swift`、`Assistant/Services/WebDAVSyncService.swift`、`Assistant/Features/WebDAVSyncView.swift`（同步与批量导入段）、`Assistant/Features/DataMigrationView.swift`（还原与批量导入段）、`Assistant/Services/Migration/DataMigrationService+Restore.swift`（还原入口、覆盖清库段、落库与孤儿清理段）、`Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift`、`scripts/ci.sh`、`Packages/AssistantCore/Package.swift`、`project.yml`、`README.md`。

按形状抽查（grep + 命中段落阅读，未逐行读全文）：`Assistant/Features/Omnibox/OmniboxExecutors.swift`（15 个 capability 分支只覆盖 habit/medication/pet/vehicle/child 五处取数与撤销令牌骨架）、`Assistant/Services/Migration/DataMigrationService+Export.swift`（密码段）、`Assistant/Services/LiveActivityService.swift`（结束活动段）、`WidgetShared/ShareImportBridge.swift` 调用方。

**未覆盖，后续要单独排**：通知排期与 64 条名额总账（含台账 D 项）、`LocationReminderService`/`TripArrivalService` 围栏与到站判定、`TaskPlanningEngine`/`PlanningClarificationEngine`、`HealthKitService` 读写、`AppLockManager` 与 `PasswordVaultCrypto` 内部实现（只读了函数签名与调用侧）、`AssistantApp.swift` 生命周期与前台巡检顺序、其余约 60 个 Feature 视图、Widget 扩展全部时间线、`todo.md` 记录的既有批次结论。
