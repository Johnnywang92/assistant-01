# 项目代码优化扫描报告（2026-11-05）

> 基线：`main` @ `0b04489` + 工作树未提交改动（10 个文件，未 reset/checkout）。
> 范围：452 个 Swift 文件、137,818 行（App 98k：Features 60k / Services 30k / Models 5.1k；AssistantCore 包 39.7k，含 80 个测试文件）。
> 本报告是总入口；四条线的完整证据、代码片段与逐条验证步骤见同目录四份明细报告。

> **状态更新（2026-11-05）**：批 1 已完成并验证 —— 三道闸门转绿、死代码 −538 行、版本号接通、CORE-01/02 金额缺陷修复（见**第十节**）。
> 批 2 已完成并验证 —— 全仓 `try? save()` 184→64（服务层/模型层清零）、`@Transient` 单据与 AA 分摊真正落盘（SchemaV10）、inbox.txt 事务化、出行票务标记顺序修正、新增落库吞错闸门（见**第十一节**）。
> 批 3 已完成并验证 —— Core 热路径（食物匹配 ~160×、估算 ~3.6×）、搜索打分 ~2–2.7×、前台巡检分级节流、服药/待办通知差量对账 + 通知预算、备份导出/还原与模型导入移出主线程、搜索索引增量重建（见**第十二节**）。
> 批 2b 已完成 —— 全仓 `try? save()` **64 → 0**，闸门基线清零；同时收口 UI-04/06/07/08 的每帧重复计算（见**第十三节**）。
> 批 4 第一部分已完成 —— 搜索 bigram 候选裁剪（选择性查询 **6–7.6×**，含裁剪/全扫等价性测试）、分享卡品牌部件共享（见**第十四节**）。
> 宝宝/宠物档案组件化已完成（见**第十五节**，重复度 43→21）。
> 批 4 第三部分已完成：Core 正确性缺陷修复（小票日期错年、用药时效状态机、WebDAV 双重编码、Equatable 漏字段，见**第十六节**，+9 条回归测试）。
> 批 4 第四部分已完成：CORE-08 中文数字解析统一（4 份 → 1 份）+ CORE-09 多菜合并与未匹配提示（见**第十七节**，+8 条回归测试）。
> 批 4 剩余：分享卡完整骨架与统计卡、待办双表单合并、备份附件外置、App 测试 target；以及 UI 侧展示 `unmatchedHints`。
> 2026-11-06 下午 ~ 11-07 增量：报告推送排期、通知预算统一、药品双入口收敛、死代码订正与工程保障（7 道闸门接入 pre-push、新增 clean.sh），见 **incremental-2026-11-07.md**。

> **复核订正（2026-11-06）** —— 增量复核与 P0 修复见 [incremental-2026-11-06.md](incremental-2026-11-06.md)。以下 4 条以**当前代码实测**为准；正文表格与排期章节已就地更正，原值以括注保留，供追溯：
>
> 1. **第十节 L-04「已删除 `ExpenseShareView` 60 行」与代码不符**：复核时 `ExpenseTrackerView.swift:2651` 仍有该零引用实现（全仓仅 1 处命中），`git log -S` 未见删除提交。本轮已删除，并把「附原始单据」开关接到 `ExpenseCardShareSheet`，修掉 `includeReceipt` 死状态。
> 2. **UI-02 的「7 弹窗 / toast 三套时长」低估**：漏了 `Share/TodoShareSheet.swift`、`ExpenseAASplitSheet.swift`、`NearbyInteractionSheet.swift`，实际是 **10 个弹窗 / 5 套时长**（2.0 / 2.4 / 2.5 / 3.0 / 无延时）。统一骨架的收益比原估计更大。
> 3. **`ui-findings.md` UI-03 表的 547 行对象标错**：真身是 `ItemStorageVaultView.swift` 的 **`MedicineEditorSheet`**，不是 `AddOrEditStoredItemSheet`（后者实测 273 行）。按原表名排期会拆错文件。
> 4. **无障碍缺口准确口径是 73 处 / 37 文件**（纯图标且未标注的 Button，括号配平实测）；此前按固定 7 行窗口估出的 104 含已标注按钮的误报。本轮补 26 处并新增 `scripts/check_icon_button_a11y.py` 闸门，剩余 47 处按文件基线锁定、只降不升。
>
> 三条「待验证疑点」也在增量报告里给了定性结论：`.onChange(of: @Model 数组)` 不触发属性级编辑、报告指纹只覆盖前 30 条会陈旧、`HabitAndMedicationScheduler` 的 init 无副作用（疑点可关闭）。

> **复核订正与增量优化（2026-11-07）** —— 报告推送 / 通知预算 / 药品入口 / 工程保障四轮改动与验证见 [incremental-2026-11-07.md](incremental-2026-11-07.md)。再补 1 条台账与代码不符：
>
> 5. **第十节 L-04「`ReceiptScannerView` 整文件 403 行已删除」是假账**（第三次台账与代码不符）：复核时文件完好 403 行，`Assistant.xcodeproj` 仍有 PBXBuildFile（仍在编译），无障碍闸门基线还登记 2 处。更关键的是**整文件并非死代码**——`ReceiptScanParser`（`ExpenseTrackerView:2490`）与 `ReceiptCameraView`（`:1917`）都还在使用，照原记录整文件删除会直接编译失败。2026-11-07 只删零引用的 `ReceiptScannerView` 结构体，把 3 个活类型抽到 `ReceiptScanSupport.swift`（69 行），`xcodegen` 同步，基线移除该条目。
>
> 本轮同时新增 `scripts/clean.sh`（构建产物清理，默认 dry-run）与 `.githooks/pre-push` + `scripts/install-hooks.sh`（把已有 7 道闸门真正自动跑起来）；`scripts/add-xcstrings-keys.py` 写坏 xcstrings 的 bug 也已修复。

---

## 一、怎么扫的

四条线并行、按层切分、互不重叠（每条线只读业务代码，只写自己的 findings 文件）：

| 线 | 范围 | 报告 | 条数 |
| --- | --- | --- | --- |
| Core 纯逻辑 | `Packages/AssistantCore/`（91 源文件 + 80 测试文件） | [core-findings.md](core-findings.md) | 12（P1×2 / P2×5 / P3×5） |
| 服务层 | `Assistant/Services/`（85 文件，含 Migration/、Inference/） | [services-findings.md](services-findings.md) | 15（P1×1 / P2×8 / P3×6） |
| 视图层 | `Assistant/Features/`（124 文件） | [ui-findings.md](ui-findings.md) | 17（P1×2 / P2×10 / P3×5） |
| 平台层 | Models / App / Intents / Theme / 两个扩展 / 工程与文案配置 | [platform-findings.md](platform-findings.md) | 15（P1×1 / P2×9 / P3×5） |

另有 Lead 侧跨切面 5 条（本报告第四节），合计 **59 + 5 = 64 条**。

**可信度分级**（明细报告内每条都标注）：

- **实测**：真跑过输入/编译验证。例如两位 P1 金额缺陷，本轮把纯函数单独编译成 macOS 探针实际复现（见第六节「可复现验证」）。
- **静态确认**：调用链与代码路径读通、行号核对过，但未真机复现。
- **疑点**：需要真机/运行时证据才能定性，不计入确认项（全轮共 4 条）。

**基线质量**（这几项先跑过，避免把「已经很好」的地方也当问题）：

- `swift test --disable-sandbox` → **1112 项全绿，2.6s**（Core 层测试质量确实高）。
- 5 道质量闸门中 **3 道当前是红的**（见第四节 L-01，这是本轮最要紧的工程问题）。
- `xcodegen generate` + `xcodebuild` 在本次会话内**跑不了**：宿主沙箱拦截了 SwiftPM 的 `~/Library/Caches` 写入与 `sandbox-exec`（SwiftUI 宏展开依赖它），属环境限制而非代码问题。iOS 整包构建结论请在本机执行 `./scripts/ci.sh` 复核。

---

## 二、结论摘要

这个项目不是「写得乱」，恰恰相反：分层清楚（纯逻辑下沉 AssistantCore）、有单测、有 5 道质量闸门、有启动埋点、往期 11 项风险审查已全部修复并记录验证。**当前真正的优化空间集中在三件事：**

1. **静默失败一族**：`try? context.save()` 全仓 184 处（视图层 135 处）、`try?` 共 739 处。落库失败被吞掉，但用户照样看到「已记录/已勾选/成功震动」。这是伤数据可信度最深的一族，且与往期 CR-01/CR-06 同源，只是面在 App 内、此前没进台账。
2. **主线程上的重活**：备份导出把 43 张表 + 全部附件字节在主 actor 上一把物化再做 31 万轮 PBKDF2；模型导入在主 actor 上拷贝数 GB 并算全文件 SHA-256；每次回前台串行跑全表巡检 + 28 夜 HealthKit + 100+ 次通知 XPC。这是「已经做了多轮流畅度优化」之后性能天花板的主要来源。
3. **质量保障本身在漏水**：3 道闸门红了没人发现（仓库无 CI、无 git hook），App 层 9.8 万行**零测试目标**。所以本轮还能挖出「金额少记 0.5 元」「小票日期差一年」这类会被 1112 条 Core 测试放过去的缺陷——测试断言偏弱（只 `assertNotNil`）+ 缺 App 层测试，正好放走它们。

---

## 三、优先处理清单（按「收益/风险比」排序）

### P1 · 数据正确性与丢失（6 条，建议先做）

| # | 编号 | 问题 | 证据 | 本轮验证 |
| --- | --- | --- | --- | --- |
| 1 | CORE-01 | 一句话记账把中文角分截掉：「花了三百二十八块五毛」记成 **328.0**、「花了九毛五」记成 **9.0**、「花了九点五元」记成 **9.0** | `ExpenseAmountExtractor.swift:127` 中文数字正则先命中即 return，「块/毛/角/分」分支永远轮不到 | **实测复现**（本机探针） |
| 2 | CORE-02 | 口语省略单位算错：「三百五」→ **305**、「一千五」→ **1005**、「一万五」→ **10005**（应为 350/1500/15000） | `ExpenseAmountExtractor.swift:162` `numberValue` 把尾随数字当个位 | **实测复现**（本机探针） |
| 3 | PLT-01 | 记账的**原始单据照片**与 **AA 分摊**字段被标 `@Transient`，用户输入从不落库、不进备份；重启后编辑页显示「这笔账单没有保存原始单据」 | `ExpenseModel.swift:78-81`；写入 `ExpenseTrackerView.swift:2497-2526` | 静态确认（Lead 已复核） |
| 4 | SVC-01 | 备份导出/还原在主线程一次性物化 43 张全表 + 全部附件字节 → base64 + 31 万轮 PBKDF2；大附件用户卡死/OOM，**后台自动备份被 watchdog 杀掉后静默永不成功** | `Migration/DataMigrationService+Export.swift:616`（`@MainActor`）；链路 `WebDAVSyncService.swift:128` → `BackgroundRefreshCoordinator.swift:103` → `DataMigrationView.swift:433/458/474` | 静态确认（Lead 已复核） |
| 5 | UI-01 | 视图层 **135 处** `try? context.save()`（36 文件）吞掉落库失败，勾选/服药打卡/删除仍播成功反馈与震动 | `HabitAndMedicationView.swift:167`、`Todo/TodoRowViews.swift:72/85` 等 | 静态确认（计数已复核） |
| 6 | SVC-04 | 服务层同类：语音/通知 action/任务规划 `try? save()` 后回「已记下/已记入」，且**通知在 save 之前注册** | `VoiceIntentProcessor.swift:249-251/354/376`、`TaskPlanningEngine.swift:582`、`TravelTicketReminderManager.swift:723` | 静态确认（去重后仍属新实例） |

> 修复要点：CORE-01/02 调整正则优先级 + 中文小数先数字化 + 补精确断言用例；PLT-01 开 `AssistantSchemaV10` 走 `.lightweight` 迁移（`@Attribute(.externalStorage)` 或文件名外置）；SVC-01 把取数/编码/加密移出主 actor（独立 ModelContext），附件改为外置文件；UI-01/SVC-04 统一 `context.saveReportingFailure()` 出口 + 加一道 `check_save_swallow.py` 闸门分批清零。

### P2 · 性能与静默失败（32 条中的高收益部分）

| 编号 | 问题 | 位置 | 用户可见影响 |
| --- | --- | --- | --- |
| SVC-06 | 服药提醒每次回前台「先删全部再全量重加」，`add` 无回调；待办已占 60 条名额，叠加睡眠/报告/天气易越过 iOS 64 条上限 | `HabitAndMedicationScheduler.swift:121` | 吃药提醒可能整批静默消失 |
| SVC-08 | 每次回前台在 MainActor 串行跑全表巡检 + 28 夜 HealthKit + 100+ 次通知 XPC，无节流 | `BackgroundRefreshCoordinator.swift:72-111`、`AssistantApp.swift:182-221` | 切前台卡顿/耗电，随数据量线性恶化 |
| SVC-09 | 全景搜索每次打开先 `engine.clear()` 再重建 18 张表索引 | `SearchIndexService.swift:268`、`UnifiedSearchView.swift:105` | 打开搜索第一秒不可用、结果短暂缺失 |
| CORE-05 | Core 侧倒排索引**只写不读**，`search` 仍是每次按键 O(N) 全表 + 每文档多次 `lowercased()` | `SearchIndexEngine.swift:321/165/224`；调用点 `TodoListView.swift:592`（view builder 内） | 万条数据打字卡顿 |
| CORE-06 | 热量估算热路径实测 **1.31 ms/次**：`items(matchingName:)` 476µs、`parseDetailedQuantity` 85µs、单条正则编译 14.5µs 且未复用缓存 | `FoodCalorieEstimator.swift` 家族 | 餐食评估/批量导入慢 |
| UI-04 | **缓存 key 本身没缓存**：收纳页 `vaultKey` 单次渲染被 4 个 getter 各算一遍（10 次全表字段哈希）；记账页 6 次/渲染 | `ItemStorageVaultView.swift:88`、`ExpenseTrackerView.swift:151` | 万条数据下打字/滚动固定成本 |
| UI-06 | 服药页 `todayMeals` 在 `ForEach` 内每行重扫全表 → 单渲染 2M+1 次全历史过滤（M=药数） | `HabitAndMedicationView.swift:29/82/162` | 打卡页卡顿（工作区未提交代码放大了它） |
| UI-07 | 心理页用两张**全表** `@Query` 只换 3 个计数，趋势分每渲染算 4 遍 | `MentalHealthView.swift:22/25/492-504` | 心理页进入慢 |
| PLT-02 | 43 个 `@Model` **零 `#Index`、零唯一约束**，`statusRaw`/`date`/`day`/`pathID` 高频谓词全表扫描（deployment target 已 iOS 18，API 可用） | `Models.swift:171-224` 等 | 万条后启动快照/勾选重算变慢 |
| PLT-03 | 共享快照无时效校验（`generatedAt` 全仓无读取点），过期快照被当「今天真的没有」 | `WidgetShared/WidgetSnapshot.swift:76-80` | 组件/Siri 误报「今日已清空/支出 0 元」 |
| SVC-02 | NAS 后台自动备份失败只 `print`，不落同步状态 | `WebDAVSyncService.swift:262-282` | UI 长期显示「上次成功」，错误安全感 |
| SVC-03 | `inbox.txt` 先清空再逐条 `try? ingest` | `SupportServices.swift:32/41` | 快捷指令补录条目可能永久丢失 |
| UI-02 | 分享卡家族 **5 卡 + 10 弹窗**模板级复制，**已实际漂移**（`includeReceipt` 死状态、toast **5 套时长**、阴影不统一） | `Features/*ShareCard*.swift`、`Share/*` | 维护成本 + 交互不一致（原记「7 弹窗 / 3 套时长」，2026-11-06 复核订正，见文首） |

### P3 · 可维护性与清理（21 条，择要）

- **UI-13 新建/编辑待办是两套表单**（2089 行，52 个重复窗口，字段已漂移）→ 抽 `TodoFormDraft` + 模式枚举，预计 −600~800 行。
- **UI-14 宝宝档案 ↔ 宠物档案同构**（实测 59.4% 行级相似）→ 抽 `ProfileScaffoldComponents`，预计 −250 行。
- **CORE-08 中文数字解析有 4 份重复实现**且语义不一致（CORE-02 的根因之一）。
- **CORE-03 小票日期**：缺年用墙上时钟且不回滚未来日期（1 月解析 12 月小票 → 差 11 个月）；`2024-02-31`、`25:99` 被静默规范化。
- **CORE-04 用药时效状态机**：饭后「刚吃完、等待最佳时机」分支构造上不可达；刚吃完 5 分钟仍提示「黄金窗口，建议现在服药」，饭前计划进食后仍提示「空腹送服」。
- **PLT-09 版本号是死配置**：`MARKETING_VERSION 0.1.0` 不生效，三份 Info.plist 恒为 `1.0/1`（XcodeGen 实验 + 构建产物双重确认）。
- **本地化**：`Localizable.xcstrings` 262 个代码引用键缺失、1247/4929 键无英文；扩展与 AppIntents 全链路无本地化资源（英文用户看到中文）；`InfoPlist.xcstrings` 缺 4 条权限 + 11 条快捷方式英文。
- **PLT-05 分享图片全分辨率解码/编码**，无降采样、无总量上限（扩展内存受限）。
- **PLT-15 分享扩展**内容未变化也 `reloadAllTimelines`，挤占组件刷新预算。

> 完整 21 条见四份明细报告；优先级口径：P1=数据/安全/关键链路，P2=特定场景正确性或可测性能退化，P3=低影响改进。

---

## 四、跨切面工程问题（Lead 侧确认，5 条）

### L-01 · P2 · 三道质量闸门当前全红，且没有任何自动化在跑

实测（HEAD `0b04489`，工作树即可复现）：

```bash
$ python3 scripts/check_settings_keys.py
❌ 既不在白名单、也不在豁免清单的键（9）：
     \(digestKey(for: part))_mtime/_size  ← VisionModelManager.swift:198/199/218/219/284/437/438
     \(self.validatedDigestKey)_mtime/_size  ← LLMModelManager.swift:303/305/499/500
     selected_companion_persona             ← Features/Share/CompanionEchoCard.swift:7
[exit 1]

$ python3 scripts/check_radius_tokens.py
❌ 请改用 AppRadius 令牌：Assistant/Features/Share/StoredItemShareSheet.swift:108  cornerRadius: 5
[exit 1]

$ python3 scripts/typecheck-views.py ...（CI 里锁定的 7 个心理视图）
error: type 'PsychStubHaptic' has no member 'selection' / 'light'
error: cannot find 'CompanionEchoCard' in scope
error: value of type 'HStack<...>' has no member 'responsiveAnimation'
[exit 1]
```

**归因（用 `git worktree` 在历史提交上复跑定位）**：

| 闸门 | 何时开始红 | 根因 |
| --- | --- | --- |
| 圆角令牌 | `99fba52`（2026-11-04，分享套件） | 新增 `StoredItemShareSheet.swift:108` 用了字面量 `cornerRadius: 5` |
| 偏好键覆盖 | `b147d9b`（2026-11-03，视觉模型多部件） | 新增 8 个插值缓存键未登记/未豁免 + `selected_companion_persona` 未进备份白名单 |
| 心理视图类型检查 | 不早于 CompanionEchoCard 引入 | 手写桩 `PsychStubHaptic` 缺 `light()/selection()`、缺 `CompanionEchoCard`/`responsiveAnimation`——**闸门自身随代码演进而腐化** |

**为什么重要**：`scripts/ci.sh` 是「单测 → 生成 → 构建」的完整门禁，但仓库**没有 `.github/`、没有 git hook**，所以它只有在有人手动想起来时才跑。`ci.sh` 第一步就红，等于整条门禁从 11-03 起形同虚设——这解释了为什么上面 P1 的问题能持续存在。

**建议**：① 立刻把三道闸门转绿（radius 改用 `AppRadius.badge`；9 个键按脚本提示「是偏好就登记 / 是缓存就加 EXEMPT 并写理由」；typecheck 桩补 3 项）；② 加 `pre-push` hook 跑 `./scripts/ci.sh test`（2.6s 的 Core 单测 + 3 道脚本闸门，成本极低）；③ typecheck 这类手写桩机制建议长期替换为「本机允许 sandbox 时直接 `xcodebuild`」，或至少把桩的维护写进提交清单。

### L-02 · P2 · App 层 9.8 万行零测试目标

`project.yml` 只有 `Assistant` / `AssistantWidgetExtension` / `AssistantShareExtension` 三个 target，**没有单元测试 target**。Core 层 1112 条测试全绿，但 `Features`(60k) + `Services`(30k) + `Models`(5k) 完全靠人工验证。本轮 P1 里有 4 条（UI-01、SVC-04、PLT-01、SVC-01）都属于「App 层没有测试/target 就抓不到」的类型。

**建议**：先加一个极小成本的 `AssistantTests` target，只覆盖三类：① 迁移（开库/轻量迁移/回滚）；② 写库失败路径（注入 save 抛错）；③ 备份封套往返。不必追求覆盖率数字。

### L-03 · P3 · 仍停留在 Swift 5 语言模式

`project.yml:14` `SWIFT_VERSION: "5.0"`，`Package.swift` `swift-tools-version:5.10`，工具链已是 Swift 6.4。好消息是迁移成本很低：`-strict-concurrency=complete` 实编译**只有 2 处 error**——`Regex.swift:5`（static `NSCache`）、`WebDAVModels.swift:265`（static `ISO8601DateFormatter`），其余包体已干净。建议先把 Core 切到 Swift 6 模式，再逐 target 推进。

### L-04 · P3 · 约 530 行死代码（可用编译器/脚本一次性确认）

| 符号 | 位置 | 行数 | 说明 |
| --- | --- | --- | --- |
| `ReceiptScannerView` | `ReceiptScanSupport.swift`（原 `ReceiptScannerView.swift`） | 403 → 69 | **仅视图结构体零引用，不是整文件死代码**：同文件的 `ReceiptScanParser`（`ExpenseTrackerView:2490`）、`ReceiptCameraView`（`:1917`）仍在使用。2026-11-07 删死视图、抽出 3 个活类型（原记「整文件无任何引用 / 已删除整文件 403 行」，与代码不符，见文首订正 5） |
| `ExpenseShareView` | `ExpenseTrackerView.swift:2569` | 60 | `private` 且无引用（本轮**未删除**，2026-11-06 补删，见文首订正 1） |
| `ManualImportView` | `SettingsViews.swift:5` | 55 | 无引用 |
| `PickupCodeChip` | `AssistantWidgetExtension/AssistantWidgetBundle.swift:56` | 12 | 无引用 |

（`Intents/*` 里几个「只出现一次」的类型是系统发现的 App Intents，属正常，不是死代码。）

**判死代码的纪律（2026-11-07 补充）**：按「类型名全仓只命中一次」判定**文件**可删是不够的，必须同时检查同文件内的其它顶层类型。本表第一行就是反例——`ReceiptScannerView` 只出现一次，但同文件另有两个活类型；照原记录整文件删会直接编译失败。删除前至少跑一次 `grep -nE '^(struct|enum|class|extension) ' <file>` 并逐个查引用。

### L-05 · P3 · 仓库树内约 6.4 GB 构建产物

`build/` 2.4G + `DerivedData/` 2.9G + `.build/` 1.1G（2026-11-07 实测，原记 5.9G / DerivedData 2.4G）。虽然都在 `.gitignore` 里，但每次全量扫描/备份/同步都会被带上。**2026-11-07 已新增 `scripts/clean.sh`**：默认 dry-run 只列体积，`--yes` 才删，白名单仅这三目录且强制校验仓库根，绝不触碰 `.workbuddy/` 与个人目录。

---

## 五、重复代码实测（跨文件 5 行窗口检测）

对 `Assistant/Features` 124 个文件做归一化后 5 行滑窗比对（608 个跨文件重复窗口），前 10 个配对：

| 重复窗口数 | 文件对 | 对应条目 | 预估收益 |
| --- | --- | --- | --- |
| 52 | `EditTodoSheet.swift` ↔ `Todo/AddTodoSheet.swift` | UI-13 | −600~800 行 |
| 44 | `HealthShareCardView` ↔ `PsychShareCardView` | UI-02 | 分享卡族合计 |
| 40 | `HydrationShareCardView` ↔ `ReportShareCardView` | UI-02 | −550~750 行 |
| 37 | `HealthShareCardView` ↔ `ReportShareCardView` | UI-02 | 同上 |
| 35 | `ChildManagementView` ↔ `PetManagementView` | UI-14 | −250 行 |
| 34 | `HealthShareCardView` ↔ `HydrationShareCardView` | UI-02 | 同上 |
| 27 | `HydrationShareCardView` ↔ `PsychShareCardView` | UI-02 | 同上 |
| 27 | `PsychShareCardView` ↔ `ReportShareCardView` | UI-02 | 同上 |
| 26 | `PsychShareCardView` ↔ `Share/StoredItemShareSheet` | UI-02 | 同上 |
| 23 | `ExpenseShareCardView` ↔ `HealthShareCardView` | UI-02 | 同上 |

关键观察：分享卡族的基础件其实已经有了（`Share/ShareCardTheme.swift` 74 行、`ShareCardActions.swift` 52 行），但 5 张卡没吃进去，各自复制了一套「渐变背景 + 指标卡 + 品牌落款 + 导出按钮」，并已经产生行为漂移。这是**最值得做的一次性重构**（收益明确、有现成基础件、失败风险低）。

**另一个好消息**：Core 包与 App 层的公开类型**零重名**（362 个 Core public type 全无碰撞），说明「纯逻辑下沉」的分层纪律保持得不错，没有出现同名逻辑两处各写一份的整体性腐化。

---

## 六、实施路线图（建议分 4 批）

| 批次 | 内容 | 预计工时 | 风险 |
| --- | --- | --- | --- |
| **批 1：止血** | 三道闸门转绿（L-01）+ 删 530 行死代码（L-04）+ 修版本号（PLT-09）+ 金额解析 P1（CORE-01/02，含补测） | 0.5–1 天 | 极低，全部可回滚 |
| **批 2：数据可信度** | 统一 `saveReportingFailure` 出口 + `check_save_swallow.py` 闸门，按文件分批清零 184 处（UI-01/SVC-04）；`inbox.txt` 事务化（SVC-03）；`markTodoAdded` 顺序（SVC-05）；`@Transient` 迁移（PLT-01） | 2–3 天 | 中（要逐条定失败文案） |
| **批 3：性能** | 备份导出移出主 actor + 附件外置（SVC-01）；模型导入 detached（SVC-07）；回前台巡检分级/节流（SVC-08）；服药通知差量对账（SVC-06）；搜索索引差量/增量（SVC-09 + CORE-05）；补 `#Index`（PLT-02） | 3–5 天 | 中高（涉及并发与 SwiftData 边界） |
| **批 4：结构性** | 分享卡族抽模板（UI-02）、待办双表单合并（UI-13）、档案页组件化（UI-14）、body 内重复计算收敛（UI-04/06/07）、本地化补齐（PLT-06/07/08）、Core 切 Swift 6（L-03） | 持续 | 低（纯重构，可增量） |

---

## 七、可复现验证

```bash
# 0. 基线与闸门（本会话已实测）
cd Packages/AssistantCore && swift test --disable-sandbox        # → 1112 tests, 0 failures, 2.6s
python3 scripts/check_settings_keys.py                            # → exit 1（9 个键）
python3 scripts/check_radius_tokens.py                            # → exit 1（StoredItemShareSheet.swift:108）
python3 scripts/typecheck-views.py Assistant/Features/PsychCombinedReadingCard.swift \
  Assistant/Features/PsychTrendChartCard.swift Assistant/Features/MentalHealthView.swift \
  Assistant/Features/PsychScaleResultView.swift Assistant/Features/PsychExportSheet.swift \
  Assistant/Features/PsychScaleTestView.swift Assistant/Services/PsychReliefCopy.swift   # → exit 1

# 1. 金额 P1 复现（Lead 本轮实际执行）
mkdir -p /tmp/amt && cp Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift /tmp/amt/
cat > /tmp/amt/main.swift <<'EOF'
import Foundation
for s in ["花了三百二十八块五毛","花了九块五毛","花了九毛五","花了九点五元","花了三百五","收入一千五"] {
    print(s, "->", String(describing: ExpenseAmountExtractor.extractAmount(from: s)))
}
EOF
swiftc -O /tmp/amt/main.swift /tmp/amt/ExpenseAmountExtractor.swift -o /tmp/amt/probe && /tmp/amt/probe
#    → 328.0 / 9.0 / 9.0 / 9.0 / 305.0 / 1005.0（应 328.5 / 9.5 / 0.95 / 9.5 / 350 / 1500）
#    注：core-findings.md 记「午饭三十八点五元 → nil」，本机复现为 5.0；两者都错，修复后以补测为准。

# 2. 死代码确认（只查这几个符号，不足以判定「整文件可删」）
grep -rn "ReceiptScannerView\|ManualImportView\|ExpenseShareView\|PickupCodeChip" --include="*.swift" Assistant AssistantWidgetExtension
#    → 这四个符号只命中定义处，无调用点
#    但同文件另有活类型，必须先单独查：
grep -rn "ReceiptScanParser\|ReceiptCameraView" --include="*.swift" Assistant
#    → ExpenseTrackerView:2490 / :1917 命中（2026-11-07 订正，见文首订正 5）

# 3. 整包构建（需在本机、非受限沙箱下执行）
./scripts/ci.sh
```

**本轮未能完成的验证**（需本机或真机）：完整 `xcodebuild`（沙箱拦截 SwiftPM 缓存与 `sandbox-exec`）、性能条目真机 Instruments 实测、P2 中标注「疑点」的 4 条（快照跨进程 RMW、迁移计划绕过、`.onChange(of: @Model)` 属性级编辑是否触发、首帧开库耗时）。

---

## 八、已核对、确认没问题的方向（避免下一轮重复投入）

- Services 层无空 `catch {}`、无 `DispatchQueue.main.sync`、无 `try!`、无敏感数据日志；口令/密钥均只进 Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。
- App Group 与 entitlements 一致；43 个 `@Model` 全部在 V9 schema 内；`project.yml` 与三份 Info.plist 除版本键外一致。
- 视图层 0 处 `EnvironmentObject` 滥用、0 处 `Timer`、`parts[0]` 系列全有 guard；大列表无 `ScrollView + VStack` 反模式。
- 往期 CR-01…CR-11 的修复无回归（分享收件箱「落库成功才删」、WebDAV 跨源 href、CSV 事务化等均已复核）。
- 搜索的性能改造（分片 `Task.yield()`、`fetchLimit` 下推、锁屏脱敏闸门）确实已落地——本轮对搜索的意见是**「倒排索引没被真正用起来」与「每次打开都清空重建」**，不是重复上轮工作。

---

## 九、附录

- [core-findings.md](core-findings.md) — 12 条，含 6 段可复现探针记录（R0–R6）
- [services-findings.md](services-findings.md) — 15 条，含与 CR-01…CR-11 的逐条去重说明
- [ui-findings.md](ui-findings.md) — 17 条，含重复配对索引、建议实施顺序、测量命令
- [platform-findings.md](platform-findings.md) — 15 条，含 `@Model`↔V9 schema、`project.yml`↔plist 逐键比对结果

**未覆盖范围**（诚实说明，供下一轮排期）：AssistantCore 里 `SleepReminderPlanner`、`DietaryPreference`、`TrendAnalytics`、`SkillPathPlanner`、`PleasureIndexEvaluator`、`PsychExportFormatter`、`PsychChannelMerger`、`WebDAVXMLParser` 的 `getlastmodified` 未逐行审计；`scripts/` 下工具脚本本身只做使用与红绿验证，未做代码审查。

---

## 十、批 1 修复记录（2026-11-05 当天完成并验证）

批 1 = 「止血」：把质量门禁修回可用、清掉死代码、接通版本号、修掉两处 P1 静默错账。
**只改上述范围，未触碰批 2–4 的任何业务逻辑**（`try? save` 收口、主线程重活、索引、UI 重构均未动）。

### 10.1 改动清单

| 项 | 改动 | 文件 |
| --- | --- | --- |
| L-01 圆角闸门 | `cornerRadius: 5` → `AppRadius.badge`（20pt 图标，视觉差 1pt 不可见） | `Assistant/Features/Share/StoredItemShareSheet.swift:108` |
| L-01 偏好键闸门 | ① 闸门脚本把 `@AppStorage` / `forKey:` / 常量三条路径的**插值键**统一归入「只汇报不判红」（原本只有常量路径这么做，8 个模型缓存键被误判成未登记偏好）；② `selected_companion_persona` 确实是用户偏好，登记进 `stringKeys` 备份白名单 | `scripts/check_settings_keys.py`、`SettingsSnapshot.swift` |
| L-01 类型检查闸门 | ① 桩补齐：`Haptic.light/selection`、`AppMotion.reduceMotion`、`CompanionEchoCard`、`PsychShareSheet`、`themedAppBackground`、`responsiveAnimation`、`TodoItem`/`ExpenseRecord`/`MoodCheckInRecord` 模型桩；② 改写器修复 6 处真实缺陷：裸 `@Query`（无参数）未改写、`init` 里 `_x = State(initialValue:)` 的 @State 未覆盖、`let` 开头行被整体跳过导致漏改写、局部同名绑定被误改、条件绑定 `guard let x = state`、裸实参 `foo(mood, energy)`；③ 新增 `--keep` 调试开关（保留改写产物，便于把编译器行号映射回原文件） | `scripts/typecheck-views.py` |
| L-04 死代码 | 实际删除 `ManualImportView` 55 行、`PickupCodeChip` 12 行；`ExpenseShareView` 当时**未删除**，2026-11-06 增量复核才补删并把「附原始单据」开关接回分享卡。**`ReceiptScannerView` 当时并未删除**：文件完好 403 行且仍在编译，2026-11-07 才删掉零引用的视图结构体（−334 行），把 3 个仍被 `ExpenseTrackerView` 使用的类型抽为 `ReceiptScanSupport.swift`（69 行），同步 `xcodegen` 与无障碍基线 | 见 `git diff --stat`（原记「删除 4 处…含 `ExpenseShareView` 60 行」，2026-11-06 订正；原记「`ReceiptScannerView` 整文件 403 行已删」为假账，2026-11-07 订正，见文首订正 5） |
| PLT-09 版本号 | 三份 Info.plist 的 `CFBundleShortVersionString` / `CFBundleVersion` 改为 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`，`MARKETING_VERSION` 从此真正生效（原为死配置，恒输出 1.0/1） | `project.yml` + 重新生成的三份 plist |
| CORE-01/02 金额 | ① 提取顺序改为「带单位 → 角分 → 纯中文整数 → 阿拉伯」，中文整数不再抢跑；② 新增「中文小数金额数字化」（`九点五元`→`9.5元`，且仅在**后面跟货币单位**时转换，`下午三点半` 不受影响）；③ 新增「只有角分」正则（`九毛五`=0.95）；④ `numberValue` 支持口语省略下级单位（`三百五`=350、`一千五`=1500、`一万五`=15000），但「零」是显式个位（`一千零五`=1005 不变） | `ExpenseAmountExtractor.swift` |
| 测试 | 新增 3 组共 21 条精确断言（`assertAmount` 等值断言，不是 `assertNotNil`）：中文角分、口语省略单位、时间表达不得被当金额；`numberValue` 用例同步扩到 12 条 | `ExpenseAmountExtractorTests.swift` |

### 10.2 验证结果

```
./scripts/ci.sh test
  ✓ 偏好键覆盖闸门          exit 0
  ✓ 圆角令牌闸门            exit 0
  ✓ 备份口令字面量闸门      exit 0
  ✓ AssistantCore 单元测试  1115 tests, 0 failures（修复前 1112，新增 3 组）
  ✓ 心理视图类型检查        通过（7 个文件）
✅ 全部步骤通过 (test)
```

- **闸门不是假绿**：往 `MentalHealthView` 注入 `private var __debugBroken: String = 42`，类型检查闸门立刻报 `cannot convert value of type 'Int' to specified type 'String'` 并 exit 1；移除后恢复绿色。
- **金额修复实测**（Release `-O` 探针，27 条输入全过）：`花了三百二十八块五毛`→328.5、`花了九毛五`→0.95、`花了九点五元`→9.5、`午饭三十八点五元`→38.5、`花了三百五`→350、`收入一千五`→1500、`花了一千零五`→1005、`下午三点半开会`→nil。修复前同输入为 328/9/9/nil/305/1005/1005。
- **改动文件语法自检**：`swiftc -parse` 对 `ExpenseTrackerView.swift`、`SettingsViews.swift`、`AssistantWidgetBundle.swift`、`StoredItemShareSheet.swift` 均通过。
- **整包构建仍无法在本会话验证**：`xcodebuild` 卡在 SwiftPM manifest 缓存（`~/Library/Caches/org.swift.swiftpm` 只读，属宿主沙箱限制），已尝试 `-packageCachePath` 与 `HOME` 重定向均无效。**请在本机跑一次 `./scripts/ci.sh` 完成 `xcodegen` + `xcodebuild` 两步确认。**
- `swift test` 1115 项全绿，说明新的金额解析顺序与 `numberValue` 进位规则**没有破坏既有 1112 条用例**（含 2026-10-29 审查后补的金额/日期/备份类断言）。

### 10.3 未做（留给批 2 起）

- UI-01 / SVC-04 的 184 处 `try? context.save()` 收口（批 2，需要逐条决定失败文案）。
- SVC-01/SVC-07/SVC-08 的主线程重活下移（批 3，涉及 SwiftData 并发边界）。
- PLT-01 `@Transient` 字段迁移（批 2，需要开 `AssistantSchemaV10`）。
- SVC-06 服药通知差量对账、PLT-02 索引、CORE-05 搜索索引读写不一致（批 3）。
- 分享卡族/待办双表单等结构性重构（批 4）。

---

## 十一、批 2 修复记录（2026-11-05 当天完成并验证）

批 2 =「数据可信度」：让落库失败不再被吞、不再谎报成功；把此前只存在内存里的用户输入真正落盘。
服务层 46 处 + 模型层 3 处 + 视图层 71 处已收口（全仓 184 → 64），并新增一道闸门防回潮。

### 11.1 数量变化

| 层 | 修复前 | 修复后 | 说明 |
| --- | --- | --- | --- |
| Services | 46 处 / 17 文件 | **0** | 全部改走 `saveReportingFailure` 或显式 do/catch；成功副作用（文案/震动/通知/标记/计数）后置 |
| Models（LifeReminderAction / LifeEventModels） | 3 处 | **0** | 同上，`complete/snooze` 改为返回 Bool |
| Features | 135 处 | **64** | 71 处收口：18 处高价值写路径人工加成功门控（服药打卡/完成待办/记账/删除/新增计划…），52 处「纯写入无成功反馈」机械替换，1 处人生大事编辑分支 |
| **全仓** | **184 处** | **64 处** | 新闸门 `check_save_swallow.py` 按文件基线只降不升 |

### 11.2 新增的基础设施

1. **`ModelContext.saveReportingFailure`**（`Assistant/Services/ModelContext+SaveReporting.swift`）
   - 失败时 `rollback()` 再回调错误：不回滚的话，未落库的脏改动会被下一次无关 save 顺带提交，失败会延迟到更远处爆发。
   - 返回 Bool，调用方必须检查后再决定是否给成功反馈。
2. **`SaveFailureCenter` + 全局横幅**（`Assistant/Services/SaveFailureCenter.swift` + `Assistant/Features/SaveFailureBanner.swift`）
   - 视图层不再各造 toast：失败统一在根视图顶部出一条可点掉的红色横幅（4s 自动消失）。
   - **分层**：中心放在 Services（服务层也要上报），横幅留在 Features——避免 Services→Features 的反向依赖。
3. **闸门 `scripts/check_save_swallow.py`** 并接入 `ci.sh`
   - 剥注释后扫描 `try? <ctx>.save()`；按文件基线只降不升（新增即红）。
   - 负向测试：临时新增一处 `try? context.save()` → exit 1；移除 → exit 0。

### 11.3 具体修复

**SVC-03 · inbox.txt 事务化**（`InboxService.drain`）
- 旧：先把文件覆盖成空，再逐条 `try? ingest` —— 落库失败时原文已被清空，用户输入永久丢失且无提示。
- 新：只读原文 → 逐条 `do/catch` 落库 → 只从文件里移除「已消费」的原文（`skippedDuplicate` 也算消费，否则每次巡检会反复解析）→ 写回前**重读**当前文件（不覆盖读取后新追加的条目）→ 写回失败不当作消费成功（原文仍在，下次由原文去重兜底）。每失败一条 `context.rollback()`，避免后续条目 save 把失败条目一起提交。

**SVC-04 · 写库失败不再报成功**（服务层 17 文件 + 模型 2 文件）
- 语音记待办/记账：先 save，失败返回「抱歉，保存失败，请再试一次」而不是「已为你记下」。
- 通知 action（完成/推迟）：save 成功后才算完成，失败静默回滚（无回执渠道的场景接全局横幅）。
- `WidgetSnapshotSync` 的 6 处 App hook、`TaskPlanningEngine`、`PickupCheckoutService`、`TripArrivalService`、`SkillPathManager`、`HabitAndMedicationScheduler`、`BatteryReminderService`、`DailyPainPointAuditor` 等统一。
- 派生联动（记账→饮水/热量、地点学习、服药物化等）保留「允许失败」，但去掉 `try?`、统一回滚 + 日志并写明理由。

**SVC-05 · 出行票务标记顺序**（`confirmAndInsertTicketTodos`）
- 旧：先排通知 → `try? save()` → 无条件 `markTodoAdded` —— save 失败也永久标记「已加入」，整趟出行再也不提醒。
- 新：先 insert → save → **成功后**才排通知 + `markTodoAdded` + 清 `activeUpcomingTicket`；失败回滚、返回 0。

**PLT-01 · 单据照片与 AA 分摊真正落盘**
- `ExpenseRecord` 三个字段从 `@Transient`（只存内存）改为持久化：
  - `receiptImageData` 用 `@Attribute(.externalStorage)`（字节放库外，避免把几 MB 图片塞进 SQLite）；
  - AA 分摊存 `splitCountStored: Int?` / `splitParticipantsStored: String?`，对外保留同名计算属性（**纯加法**迁移最稳，旧库升级不需要给存量行补默认值）。
- `AssistantSchemaV10`（模型清单不变，仅属性变化）+ lightweight 迁移阶段；运行时开库/覆盖率断言同步指向 V10。
- `ExpenseDTO` 补三个可选字段（旧备份缺键时解码为 nil）；导出带上、还原写回。
- 用户可见结果：拍过的报销单据、填过的 AA 分摊重启后还在、进备份、换机能还原。

**视图侧返回值语义收口**（服务层改返回值后必须同步的 6 处 + 2 处状态）
- `VoiceDialogueView`：计划保存返回 0 → 不再播「已成功保存 N 项」；学习路径保存失败 → 不播成功。
- `TravelTicketConfirmationSheet`：加入返回 0 → 不播成功触感、不回调、不关闭，留页重试。
- `TodoListView`：纪念日准备待办返回 false → 不再 toast「已加入」。
- `ReminderCenterView`：提醒完成/稍后返回 false → 不播成功触感、不推进 revision。
- `SkillPathListView` / `LifeEventManagementView` / `ExpenseTrackerView`：读 `lastSaveFailureMessage`，失败不 dismiss、不播成功。

### 11.4 验证结果

```
./scripts/ci.sh test
  ✓ 偏好键覆盖闸门 / 圆角令牌闸门 / 备份口令字面量闸门 / 落库吞错闸门    exit 0
  ✓ AssistantCore 单元测试        1115 tests, 0 failures
  ✓ 心理视图类型检查               通过
✅ 全部步骤通过 (test)

python3 scripts/check_save_swallow.py
  扫描 29 个文件，仍有 64 处 `try? save()`（基线 64 处）   exit 0

负向测试：临时新增 `try? context.save()` → exit 1（拦截成功）；移除 → exit 0
```

- **69 个改动/新增 Swift 文件**逐个 `swiftc -parse` 通过（含服务层 teammate 的 20 个文件）。
- `swift test` 1115 项全绿（Core 未改动，作为环境自检）。
- `xcodegen generate` 通过，3 个新文件（helper / center / banner）已进入工程。
- 整包 `xcodebuild` 仍受宿主沙箱限制无法在本会话执行 —— 请在本机跑一次 `./scripts/ci.sh` 收尾确认。

### 11.5 未做 / 下一批

- **视图层剩余 64 处 `try? context.save()`**（29 文件）：全部是「附近有成功反馈、需要逐条判断失败语义」的站点（例如宠物打卡、证件保存、语音备忘删除…）。基础设施与全局横幅已就位，下一批按文件逐个加成功门控并把基线继续下调即可；闸门已经保证不会再新增。
- `Models.swift` 的 `markAsCompleted` 仍会在调用方 save 之**前**为下一期周期待办排通知（9 个调用点共享该行为）。失败时最多多一条指向不存在对象的提醒，不会丢数据；改动要动 9 个调用点，留作批 3 与通知预算（SVC-06）一起做。
- App 层仍无测试 target（L-02）：本批的失败路径验证依赖静态检查与闸门，建议批 3 起加最小 `AssistantTests`（迁移 / save 失败注入 / 备份往返）。

---

## 十二、批 3 修复记录（2026-11-05 当天完成并验证）

批 3 =「性能」：Core 热路径、搜索热路径、前台巡检/通知调度、备份与模型导入的主线程重活。
三条线并行（Lead 做 Core 与搜索；两个 teammate 分别做通知/巡检与 I/O 下移），全部只做「同语义、少做事」的优化。

### 12.1 Core 热路径（CORE-06 及同族）——有实测数据

优化手法（都不改匹配/估算语义，测试全绿）：

1. **预计算食物目录索引**：`FoodCatalog` 每次匹配都把 208 条 × 全部别名现场 `lowercased()`，还逐个 `key.contains(alias)`。改为首次访问建一次不可变索引：`nameIndex` / `aliasIndex` / `visionIdentifierIndex` / `itemsByID`。
2. **把「别名被 query 包含」反转成「query 子串查别名索引」**：query 通常 3–8 字，子串 ≤ 36 个，字典查表 O(1)，复杂度从 O(条目×别名) 降到 O(|query|²)。
3. **正则统一走带缓存的 `Regex.compile` / `Regex.replace`**：`FoodCalorieEstimator` 里 9 处 `try? NSRegularExpression` 与 18 处 `replacingOccurrences(options:.regularExpression)` 全部改掉（其中 1 处变长 lookbehind 无法被 NSRegularExpression 接受，已单独保留并注释原因）。
4. **搜索引擎预计算小写字段 + 打分短路**：`scoreSingleTerm` 原先把 title/keywords/subtitle/content 每次按键都转小写；现在 add 时预计算。并利用「标题命中即全局最高档（1000/850/700）」「拼音首字母完全匹配 680 > 其后所有档位」「全拼完全匹配 650 > 关键词 620」「关键词完全匹配 620 > 副标题/正文」做安全提前返回。

实测（`swift test -c release` 探针，同机同数据；探针不提交）：

| 指标 | 优化前 | 优化后 | 提升 |
| --- | --- | --- | --- |
| `FoodCatalog.items(matchingName:)` | ~335 µs/次 | **~2.0 µs/次** | ~160× |
| `items(matchingVisionIdentifier:)` | ~11.5 µs/次 | **~0.1 µs/次** | ~115× |
| `parseDetailedQuantity`（两碗 / 300克） | 67 / 44 µs | **16 / 13 µs** | ~3–4× |
| `estimateMeal(fromHint:)` | ~308 µs/次 | **~86 µs/次** | ~3.6× |
| 搜索 1000 篇·单字（顺） | 13.3 ms/次 | **6.6 ms/次** | ~2.0× |
| 搜索 1000 篇·双字（顺丰） | 14.7 ms/次 | **7.0 ms/次** | ~2.1× |
| 搜索 1000 篇·多词（取件 顺丰） | 22.5 ms/次 | **8.2 ms/次** | ~2.7× |
| 搜索 1000 篇·拼音（shunfeng） | 11.0 ms/次 | 10.5 ms/次 | 持平（拼音路径未短路） |

> 搜索剩下的成本主要在「全库逐篇 contains」。下一步应做 **token/bigram 候选裁剪**（引擎里 `tokenIndex` 至今只写不读，审计 CORE-05 的另一半）：对长度≥2 的查询用 bigram 交集拿候选集，单字查询回退全扫。本轮没做是因为它要动匹配语义、收益依赖真实数据分布，留作批 4 专项并配回归测试。

### 12.2 通知与前台巡检（SVC-08 / SVC-06）

- **前台巡检分级节流**（`ForegroundAuditCadence`）：每次必跑 收件箱/分享排空/小组件指令/周期记账/到站/服药对账/待办通知/心理提醒；贵查询按间隔节流 —— 9 个全表审计 10 分钟、13 个 HealthKit 查询 15 分钟、天气两条路径各 15 分钟、WebDAV 30 分钟、报告通知 30 分钟、对话清理 60 分钟。时间戳存 `Caches/foreground-audit-cadence.json`（**不占 UserDefaults 偏好键**），`markRun` 只在执行完成后写 → **只延后、不永久跳过**；文件丢失退化为全量跑一次。
- **28 夜 HealthKit 样本**加 10 分钟内存缓存（按夜归属日失效；空结果沿用旧缓存），冷启动必拉一次。
- **服药提醒差量对账**：旧实现每次回前台「删除所有 `med-` → 全量重加、`add` 无回调」；新实现 1 次 `pendingNotificationRequests` + 指纹比较（title/subtitle/body/category/thread/userInfo/触发时分/repeats），只删停用/变化项、只加缺失/变化项，`try await add` 失败带 identifier 打日志。正常路径 0 写 XPC，消除「删完被挂起 → 当天服药提醒全丢」窗口；文案与触发时间逐字段不变。
- **待办通知差量对账**：旧实现 15 项 × 最多 4 条全量 remove/add（~90+ 次 XPC）；新实现期望集合差量（缺失/内容变化才动），正常路径 1 次 pending + 1 次 settings + 0 写。
- **新增 `NotificationBudget`**：统一预算入口，优先级 服药(4) > 睡眠(3) > 到站(2) > 报告(1) > 待办主提醒(0) > 待办逾期补提醒(-1)，未接入模块 external(5) 计入总量但不主动裁剪；软上限 56（64 硬上限留余量）；只裁「严格更低优先级」避免 churn；日志 + `lastSummary` 可观测。服药与待办已接入。

### 12.3 主线程 I/O 下移（SVC-01 / SVC-07 / SVC-09）

- **备份导出**（`exportEncryptedArchive` → `async throws`）：取数留在主 actor（SwiftData `ModelContext` 非 Sendable，不冒险跨线程），但改成每 8 处 `Task.yield()` 分片、附件每 8 条让出；**JSON 编码 + base64 + PBKDF2 310k + AES-GCM + 封套编码全部 `Task.detached(priority: .utility)`**，主线程不再承担加密与 base64。备份格式/DTO/封套字段未变，旧备份兼容；支持取消并清理临时文件。
- **备份还原**（`restore` → `async throws`）：70 处 `Task.yield()`（每实体域、每张大表每 N 条、清库每 10 张、save 前后）；还原期间关闭 `context.autosaveEnabled`，防止分片让出时 SwiftUI 主 context autosave 把「还原到一半」落盘，保住「失败不动原库」的承诺。
- **对话备份解析/解锁**：新增后台 `inspectBackupFileAsync` / `unlockEncryptedArchiveAsync`（PBKDF2 + 解密 + 整包 decode 移到 detached），同步旧方法保留给 WebDAVSyncView。
- **模型导入**（`importModel` → `async`）：数 GB `copyItem` 与全文件 SHA-256 移入 `Task.detached(priority: .utility)`，只把结果回主 actor；失败清理候选文件、旧模型不动；`modelsDirectory` 幂等打 `isExcludedFromBackup`（此前只有下载完成路径会打，纯导入用户的模型会被 iCloud 备份带上）。
- **搜索索引**：`rebuildIndex(context:force:)` + 变更令牌（16 张表 `fetchCount` + 每表最新时间戳 `LIMIT 1`）+ **构建新引擎后原子替换**（不再 `clear()` 后为空窗）；打开搜索不再无条件全量重建，手动刷新走 `force: true`。
- **视图调用点**：`DataMigrationView` 全链路 async + 「生成中/校验中/解锁中/还原中」状态 + 防重复点击 + 失败清理临时文件；`LLMModelManagementView` 导入进度/禁用；`WebDAVSyncView` 2 处 `try await restore`。

### 12.4 验证结果

```
./scripts/ci.sh test
  ✓ 偏好键覆盖 / 圆角令牌 / 备份口令字面量 / 落库吞错 四道闸门   exit 0
  ✓ AssistantCore 单元测试        1115 tests, 0 failures
  ✓ 心理视图类型检查               通过
✅ 全部步骤通过 (test)

全仓 82 个改动/新增 Swift 文件逐个 swiftc -parse 通过
xcodegen generate 通过（NotificationBudget.swift / SaveFailureCenter.swift 等新文件已入工程）
Core 探针实测数据见 12.1（探针用后即删，未提交）
```

- 通知预算决策另用一次性独立 harness 跑了 8 组用例（高优先级裁低优先级、同优先级不互抢、external 不裁、逾期先裁、同 id 替换不占额、存量超限全局裁剪、主提醒挤掉逾期）全 PASS（harness 未提交）。
- 整包 `xcodebuild` 仍受宿主沙箱限制，无法在本会话验证 → **请在本机跑 `./scripts/ci.sh` 收尾**。

### 12.5 真机验证清单（本批改动必须实测的部分）

1. **备份导出**：200MB 附件库导出时 Time Profiler 主线程无 PBKDF2/AES/base64 热点、内存峰值不 OOM；生成的备份能在**旧版本** App 导入（格式未变）。
2. **备份还原**：还原中途杀 App，重启后库要么是旧库、要么是完整新库，不能出现半成品。
3. **模型导入**：≥2GB GGUF 导入时主线程不卡；`Documents/Models` 的 `isExcludedFromBackup == true`。
4. **搜索**：第二次打开明显更快；编辑数据后能搜到新内容（变更令牌未漏判）；手动刷新强制重建可用。
5. **通知**：真机 pending 总数 ≤ 56、服药 6 条齐全、最先被裁的是待办逾期补提醒；Console 不出现「每轮重复排期」（指纹失配会退化为每轮删加，正确性不受影响）。
6. **节流**：冷启动 / 后台回来 / 间隔到期三条路径都执行；日志出现 `⏳ [ForegroundAudit] 节流跳过…` 而不是无声无息。
7. **Core 数值回归**：食物估算/搜索的排序与分数在真机上与旧版一致（测试已覆盖主要用例，但建议抽样对比）。

### 12.6 未做 / 下一批

- **搜索候选裁剪**（token/bigram 索引）：本轮只做了「少转小写 + 提前返回」，全库逐篇 `contains` 仍在；1000 篇单字查询 ~6.6ms，万级数据会到几十 ms。批 4 专项。
- **备份附件外置**：附件仍内联进 JSON（峰值≈附件×3–4），要改备份格式，属兼容性变更，单独排期。
- **视图层剩余 64 处 `try? context.save()`**（批 2b 遗留）。
- **App 层测试 target**（L-02）：本批失败/并发路径仍只能靠静态检查与真机验证。

---

## 十三、批 2b + 渲染热点收口（2026-11-05 当天完成并验证）

本轮两件事：把视图层最后 64 处落库吞错清零（批 2b），并修掉审计里 UI-04 / UI-06 / UI-07 / UI-08 的「每帧重复计算」。
服务层 teammate 同轮完成 58 处（28 文件），Lead 完成自己负责的 6 处（ItemStorageVaultView）与 4 个渲染热点。

### 13.1 批 2b：全仓 `try? context.save()` 归零

| 层 | 批 2 结束时 | 本轮后 |
| --- | --- | --- |
| Services / Models | 0 | **0** |
| Features | 64 | **0** |
| **全仓** | 64 | **0** |

- 每一处都按语义处理：成功副作用（成功触感/成功文案/dismiss/`onSaved`/排通知/实时活动/快照刷新/计数递增）全部后置到 save 成功之后；失败走 `SaveFailureCenter` 全局横幅 + `Haptic.error()`，表单与编辑页不 dismiss。
- 额外做了 **通知后置**（4 文件 5 个调度点）：扫码导入、待办批量导入、新建待办（含到站 sync + 配套票务通知）、面对面导入（含取件实时活动）——避免 save 失败留下指向不存在对象的提醒。
- `MedicineStockHelper` 三个 helper 的返回值语义变化（`takeOneDose → 失败文案`、`disposeAndCreateRestockTodo → 0`、`stopReminder → false`）在调用点补齐判断：不再出现「已标记处理」「已停止提醒」「已清理 N 种」这类假成功文案。
- **闸门基线清空为 0**：`check_save_swallow.py` 现在只剩「禁止新增」的作用。负向测试：临时加一处 `try? context.save()` → exit 1，移除 → exit 0。

### 13.2 UI-04：内容指纹「每帧只算一次」

- `ItemStorageVaultView`：`vaultKey` 要对全部物品 12 个字段 + 全部关联记账做哈希，而 `areaCounts`/`linkedTotals`/`costTrackedSummaries`/`filteredItems` 四个 getter 各自算一次 → **单次渲染 10 次**。改为 body 开头 `prepareRender()` 算一次写进缓存键。
- `ExpenseTrackerView`：`analysisKey` 要在 body 里被 `summary` 引用 5 次 + `groupedRecords` 1 次 → **6 次/渲染**。改为 body 开头 `prepareRenderKey()` 算一次，两个 getter 只读缓存。

### 13.3 UI-06：服药页「今日用餐」与时效评估只算一次

- 旧：`todayMeals` 每次访问都对全部饮食/饮水记录 filter+map；`ForEach(medPlans)` 每行再算一次，`topTimingEvaluation` 又给每个启用计划各算一次 → 8 个药时**单次渲染 17 次全表扫描**。
- 新：body 里 `let meals = todayMeals`（1 次）与 `medEvaluations(meals:)`（每药 1 次），`topTimingEvaluation(from:)` 与每行 `MedicationRow` 复用同一份结果。

### 13.4 UI-07：心理页「最近解读」与趋势点只算一次

- 旧：`latestInsight` 在 body 与分享 sheet 各算一次（内部还含 `recentAverageSleepHours` 的 SwiftData 查询）；`trendPoints(for:)` 在「可用量表筛选」与「每张趋势卡」各算一次（每次都要给每条记录算分）。
- 新：body 开头 `let insight = latestInsight`、`let trendPointsByScale = allTrendPoints()`，两处引用共用；`availableTrendScales(from:)` 直接读预算好的字典。

### 13.5 UI-08：药品行 N+1 查询

- `MedicineItemRow` 原先自己 `@Query private var medPlans`，父视图已经查过同一张表 → 每个药品行都建一份全表观察。改为「父视图把 `medPlans` 传进来」，行内只用传入数组查找 `linkedPlan`/`pausedPlan`。

### 13.6 验证结果

```
./scripts/ci.sh test
  ✓ 偏好键覆盖 / 圆角令牌 / 备份口令字面量 / 落库吞错 四道闸门   exit 0
  ✓ AssistantCore 单元测试        1115 tests, 0 failures
  ✓ 心理视图类型检查               通过
✅ 全部步骤通过 (test)

python3 scripts/check_save_swallow.py
  扫描 0 个文件，仍有 0 处 `try? save()`（基线 0 处）   exit 0
  负向测试：新增一处 → exit 1；移除 → exit 0

全仓 93 个改动/新增 Swift 文件逐个 swiftc -parse 通过
xcodegen generate 通过
```

- 探针/临时脚本均已删除，工作树只剩源码、脚本、报告。
- 整包 `xcodebuild` 仍受宿主沙箱限制 → **请在本机跑 `./scripts/ci.sh` 收尾**。

### 13.7 真机验证清单

1. 注入落库失败（或磁盘写满）后：不出现成功文案/触感/震动、不 dismiss、不排通知、不刷新组件快照；全局横幅出现。
2. 药品相关：停止提醒/标记处理/批量清理失败时不显示「已停止/已标记/已清理」；成功路径行为不变（提醒撤销与重排仍在 save 后）。
3. 收纳页与记账页：万条数据下滚动/输入时不再每帧重算指纹（Time Profiler 对比 `Hasher.combine` 调用次数 10→1、6→1）。
4. 服药页：8 个用药计划时打卡与滚动更顺（`todayMeals` 调用次数 17→1）。
5. 心理页：进入与切周期更顺（`latestInsight` 与趋势点各 1 次）。
6. 药品列表滚动更顺（行级全表观察 N→0）。

### 13.8 已知遗留（明确记录）

- `VoiceMemoListView`：录音保存失败时音频文件已落盘、memo 被 rollback → 可能留下孤儿音频文件（建议后续加启动清理）。
- `Models.swift` 的 `markAsCompleted` 仍会在调用方 save 前为下一期周期待办排通知（9 个调用点共享，失败最多多一条无效提醒，不丢数据）。
- 结构性问题（批 4）：分享卡族 5 卡 + **10 弹窗**模板级复制、待办新建/编辑双表单、宝宝/宠物档案同构；搜索候选裁剪；备份附件外置；App 层测试 target。（原记 7 弹窗，2026-11-06 订正）

---

## 十四、批 4（第一部分）：搜索候选裁剪 + 分享卡共享品牌部件（2026-11-05 完成并验证）

批 4 的结构性重构里，先做两块「可验证性最高」的：搜索候选裁剪（Core，有等价性测试与实测）、分享卡里逐字符相同的品牌部件（纯视图抽取，参数逐一对应）。

### 14.1 CORE-05 完成：bigram 候选裁剪（搜索从 O(全库) 到 O(候选集)）

**问题**：上批把搜索打分做到了「少转小写 + 命中最高档提前返回」，但仍是**每篇文档都扫一遍**才能知道命中与否；引擎里的 `tokenIndex` 至今只写不读。1000 篇单字查询 ~8ms、万级数据会到几十 ms。

**方案**：
1. `add()` 时为每篇文档的「可搜索字符串」建 **bigram 倒排**：标题、关键词、副标题、正文、拼音全拼、拼音首字母（覆盖打分逻辑会用到的**全部**字段）。
2. `search()` 先用查询词的 bigram 求交得到候选集，再走原打分逻辑：
   - 多个变体（原文 / 拼音首字母 / 全拼）之间取**并集**（任一命中即可）；
   - 多个查询词之间取**交集**（必须同时命中）；
   - 只要某个词的任一变体短到建不了 bigram（如单字查询），该词不参与裁剪；若没有可裁剪的词则**退回全量扫描**——保证候选集永远是「可能命中」的**超集**。
3. 两个工程保护：
   - **内存预算**：bigram 条目数超过 150 万就整体丢弃索引、永久退回全量扫描（宁可慢，不能 OOM）；
   - **零分配键**：单标量字符对打包成 `UInt64`（组合字符才退回字符串），倒排表用数组 + `last` 判重（同一文档的 bigram 连续写入）。这两点是必须的——第一版用 `String` 键 + `Set` 倒排时，1000 篇建索引从 0.5s 涨到 0.71s，直接触发了仓库既有的「建索引 <500ms」性能测试。

**正确性保证**（新增 2 条测试）：
- `testBigramPruningMatchesFullScan`：同一批 300 篇文档，20 个查询 × 3 个分类过滤，**裁剪版与全扫版的 id 序列与分数逐条相等**。
- `testBigramPruningAfterRemoveAndClear`：remove/clear 之后两者仍一致。

**实测**（1000 篇、查询只命中约 1/6 文档，`swift test -c release` 探针；探针用后即删）：

| 查询 | 全量扫描 | bigram 裁剪 | 提升 |
| --- | --- | --- | --- |
| 「顺丰」 | 6.57 ms | **0.90 ms** | 7.3× |
| 「顺丰 取件」 | 7.01 ms | **1.13 ms** | 6.2× |
| 「体检」 | 6.66 ms | **0.87 ms** | 7.6× |
| 「猫粮」 | 7.05 ms | **0.95 ms** | 7.4× |
| 「swift 并发」 | 7.41 ms | **1.13 ms** | 6.5× |
| 单字「顺」（不可裁剪） | 8.0 ms | 8.0 ms | 持平（走全扫，符合设计） |

> 备注：单字查询受限于「一个字符无法建 bigram」。真机上用户输入首字时仍会走全扫（千条量级 ~8ms），第二字起即进入裁剪路径。若要进一步优化可加 unigram 索引，但内存代价明显、收益递减，暂不做。

### 14.2 UI-02（部分）：分享卡共享品牌部件

- 新增 `Assistant/Features/Share/ShareCardScaffold.swift`：
  - `ShareCardBrandIdentity`：App 图标 + 主标题 + 副标题（记所想，助所行），参数化标题文案/颜色/行距/阴影强度；
  - `ShareCardStudioBadge`：`JohnnyBoyStudio` 专属网站标识胶囊，参数化 tint 与底色透明度（Health 卡历史是 0.12，其它是 0.18）。
- 迁移 4 张卡（Health / Hydration / Report / Expense）：每个文件里逐字符重复的落款与胶囊各收敛成一次组件调用；**所有参数与历史值逐一对应**（文案、颜色、行距 2 vs 1.5、阴影 0.12 vs 0.2、胶囊底色透明度、stroke 0.3、图标圆角 `AppRadius.chip` 等），视觉零变化。
- 行数：`HealthShareCardView` 620→607、`HydrationShareCardView` 434→405、`ReportShareCardView` 645→616、`ExpenseShareCardView` 357→344（合计 −84 行），新增共享文件 73 行 —— **净行数几乎持平，价值在于「同一个落款只存在一份」**，后续改品牌信息不用再改四处；已出现的三处漂移（toast 时长、阴影、胶囊底色）因为会改视觉，本批未动，留待有截图对比条件时处理。
- `ExpenseShareCardView` 右侧是文字块（`JohnnyBoyStudio` + `Crafted with Purpose`）与其它三张不同，只迁移了左侧品牌身份，右侧保留原样。

### 14.3 验证结果

```
./scripts/ci.sh test
  ✓ 偏好键覆盖 / 圆角令牌 / 备份口令字面量 / 落库吞错 四道闸门   exit 0
  ✓ AssistantCore 单元测试        1117 tests, 0 failures（新增 2 条 bigram 等价性测试）
  ✓ 心理视图类型检查               通过
✅ 全部步骤通过 (test)

全仓 97 个改动/新增 Swift 文件逐个 swiftc -parse 通过
xcodegen generate 通过（ShareCardScaffold.swift 已入工程）
建索引性能门禁（既有测试「1000 篇 < 500ms」）通过（优化后 0.55s → 降回阈值内）
```

- 整包 `xcodebuild` 当时受宿主沙箱限制未跑 → 请在本机跑 `./scripts/ci.sh` 收尾。（**本报告各批次章节中「受沙箱限制」均为当时状态；2026-11-06 已由 `./scripts/ci.sh all` 跑通，BUILD SUCCEEDED**，见增量报告）

### 14.4 批 4 剩余（未做，已排期）

- **分享卡完整骨架**：`ShareCardScaffold`（背景/标题区/底部按钮区）+ `ShareCardStatTile` 的完整抽取，以及 **5 卡 + 10 弹窗**的统一（原记 7 弹窗，2026-11-06 订正）。顺带统一 5 套 toast 时长与卡面阴影。需要真机截图对比（ImageRenderer 位图）。
- **宝宝/宠物档案同构**（UI-14）：纯视图组件抽取，共享任务板上仍为 pending。
- **待办新建/编辑双表单**（UI-13）：2089 行、52 个重复窗口、字段已漂移，属行为合并，风险最高，建议单独一轮。
- **备份附件外置**：峰值内存 ×3–4，需改备份格式（兼容性变更）。
- **App 层测试 target**（L-02）：目前失败/并发路径只能靠静态检查与真机。
- 已知遗留：`VoiceMemoListView` 录音保存失败可能留孤儿音频文件；`markAsCompleted` 仍是「先排通知后 save」（9 个调用点共享）。

---

## 十五、批 4（第二部分）：宝宝 / 宠物档案组件化（2026-11-05 完成并验证）

- 新增 `Assistant/Features/ProfileSharedComponents.swift`（228 行）：`ProfileQuickActionButton`、`ProfileEmptyStateCard`、`ProfileRecordsAction` + `ProfileRecordsSection`、`ProfileOverviewHeaderCard`。
- `ChildManagementView` / `PetManagementView` 迁移到这 4 个组件，参数注入差异（图标 / tint / 文案 / 计数 / 回调），组件内不判断「宝宝还是宠物」。
- 结果：两个页面合计 −228 行（搬进共享组件）；**Child↔Pet 跨文件重复 5 行窗口 43 → 21（−51%）**，净行数不变——收益是重复度减半与单一出处。
- 明确未合并：`childCard`/`petCard`（相似度 0.45）、两个 AddEdit 表单、`vaccineRow`/`careStatusRow`、toast（需改状态管理）、两个 Records 页（重复窗口仅 2）。理由见 [profile-refactor.md](profile-refactor.md)。
- 验证：5 个文件 `swiftc -parse` 通过；`ci.sh test` 全绿（1117 测试 + 4 闸门）；`xcodegen` 通过；重复度复查 43→21。

---

## 十六、批 4（第三部分）：Core 正确性缺陷修复（2026-11-05 完成并验证）

上一轮把「性能 + 结构」推进完后，回头清 Core 里剩下的**正确性**缺陷。这批全部在 `AssistantCore` 内，**有单元测试兜底**，是本项目里可验证性最高的一类改动。

### 16.1 CORE-03（P2）· 小票日期错年 + 非法日期被静默顺延

- **修前行为**（审计探针 R2）：`parse("12月25日 18:30", now: 2025-01-02)` → 2026-12-25（差近两年）；`2024-02-31` → 2024-03-02；`2024-13-45` → 2025-02-14；`25:99` → 次日 02:39。
- **改动**：
  1. `TransactionDateExtractor.extract(from:now:)` 增加可注入 `now`（默认 `.now`），所有分支统一用它；
  2. 缺年时按 `now` 补年；月日型结果 > `now + 1 天` 时**回滚一年**（1 月导入 12 月小票不再记到 11 个月后）；
  3. 新增 `validatedDate`：范围校验（月 1–12 / 日 1–31 / 时 0–23 / 分 0–59）+ **回写比对**（拒绝会被日历顺延的非法值，与 `BatchCSVImport.parseDay` 同判据）；
  4. 语义收紧：一旦某个精度的正则命中就以该精度为准，非法直接判无效，**不再退到更粗的「仅日期」模式去猜一个看起来合法的日期**；
  5. `ReceiptTextParser.parse` 把 `now` 真正传给提取器（此前 `now` 只做「完全无日期」的兜底，测试无法钉住跨年行为）。
- **测试**：把原来的 `XCTAssertNotNil` 全部改成**精确日期断言**，并新增 3 组回归（1 月解析 12 月回滚、非法日期拒绝、闰日仍合法）。

### 16.2 CORE-04（P2）· 用药时效状态机：饭后「等待」分支不可达 + 饭前不看进餐

- **修前行为**（R3）：`afterMeal(minutes:30)` + 刚吃完 5 分钟 → 「✨ 餐后黄金用药窗口，建议现在送服」，但调度时间却是 12:25（文案与调度自相矛盾）；`beforeMeal(30)` + 刚吃完 → 「请空腹温水送服」。
- **改动**：
  1. `.afterMeal`：把「还没到最佳时间」的判断挪到「黄金窗口」之前（`recentMeal` 已过滤 `date <= now`，旧顺序导致等待分支从构造上不可达）；现在刚吃完会提示「等待最佳饭后时机」，`adaptiveNotificationTime` 与文案一致；
  2. `.beforeMeal`：新增「近 1 小时内进餐 → 与空腹服药计划冲突」分支，返回 `waitingForMeal` + 明确风险文案，不再建议空腹服药。
- **测试**：既有黄金窗口用例调整到 `now` 落在最佳时点之后；新增「刚吃完先等待」「饭前遇刚进食提示冲突」两条。

### 16.3 CORE-12（P3）· WebDAV 地址二次编码 + 裸文件名 href 被拒

- **修前**：复制浏览器里已编码的地址（`https://nas.local/my%20folder`）会被整串 `addingPercentEncoding(.urlQueryAllowed)` 二次编码成 `my%2520folder` → 404；服务端返回裸文件名 href（`a.zip`）时一律拒绝（注释承诺的能力没兑现）。
- **改动**：先按原样解析 URL，**只有解析失败**（含空格/非 ASCII）才按 `.urlPathAllowed` 补编码；目录段单独编码后拼接，避免 `%` 再转义。裸文件名 href 现在按配置目录拼成完整路径（只取文件名、不含 `/` 与 `..`，无遍历风险）。
- **测试**：新增「已编码不二次编码」「含空格只编码一次」「裸文件名解析」「裸文件名仍拒绝遍历/空值」4 条；原有跨源/降级/越权安全用例全部保持通过。

### 16.4 CORE-11（P3）· 自定义 `==` 只比较 11/19 个字段

- 删除 `SafeToSpendResult` 的自定义近似 `==`，改用编译器合成（全字段）。旧实现漏掉 `disposableBudget / remainingThisMonth / daysInMonth / todayOverspentAmount / spentRatio / workdayAllowance / weekendAllowance / weekendReservoirTotal / rhythmAdviceText`，一旦被用于 SwiftUI 刷新判断或测试断言，这些字段的变化会被静默忽略。
- 仓内检查：现有测试都是逐字段 `XCTAssertEqual(...accuracy:)`，App 侧没有整值比较，删除后全绿。

### 16.5 验证结果

```
cd Packages/AssistantCore && swift test --disable-sandbox
  Executed 1126 tests, with 0 failures   （上一轮 1117，本轮 +9 条回归用例）

./scripts/ci.sh test
  ✓ 4 道闸门 exit 0
  ✓ AssistantCore 单元测试 通过
  ✓ 心理视图类型检查 通过
✅ 全部步骤通过 (test)
```

- 本轮只改 Core 源文件与其测试，未触碰 App 层，`swift test` 即为权威验证；整包 `xcodebuild` 仍需本机收尾。
- 已知仍未做（列在批 4 剩余里）：CORE-09（多菜按 `food.id` 去重会静默丢菜）、CORE-08（中文数字 4 份重复实现）、CORE-10（测试缺口清单里的其余项）。

---

## 十七、批 4（第四部分）：CORE-08 中文数字统一 + CORE-09 多菜合并（2026-11-05 完成并验证）

### 17.1 CORE-08（P3）· 中文数字解析 4 份重复实现 → 1 份

- **修前**：同一套「中文数字 → 数值」逻辑散在四处，语义还互不相同：
  - `ExpenseAmountExtractor.numberValue`：支持十/百/千/万，非法返回 nil；
  - `FoodCalorieEstimator.parseChineseQuantity`：只支持十，**非法静默返回 1.0**；
  - `SkillPathPlanner.numericValue`：另一套十的写法 + 特判两/半；
  - `QueryInsightEngine.parseChineseNumber`：只支持 1–99，超范围返回 nil。
  - 于是「近一百天」在查询侧解析失败、在记账侧得到 100；「半半」在份量侧被当成 1 份；`CORE-02`（三百五=305）只在记账那一份里暴露。
- **改动**：新增 `ChineseNumeralParser`（`value(_:) -> Double?` / `integer(_:) -> Int?`）作为唯一实现：
  - 支持阿拉伯直通、零/〇/一…九/两、半（含「一半」）、十/百/千/万、口语省略下级单位、零显式个位；
  - **不可解析一律返回 nil**，由调用方显式决定默认值；
  - 四处改为转发（`FoodCalorieEstimator` 的「按一份算」收敛成唯一一个 `?? 1.0` 显式默认值）。
- **测试**：新增 `ChineseNumeralParserTests`（表驱动 22 条输入）+ **四入口一致性测试**（同一批输入分别跑记账/份量/技能计划/查询四个入口，断言结果一致）；`QueryInsightEngine` 顺带获得百/千/万支持（「近一百天」= 100）。

### 17.2 CORE-09（P3）· 多菜按 `food.id` 去重静默丢菜

- **修前**：「两个包子一个肉包」只算一份包子（肉包是同一食物条目的别名），整餐热量少算约一份；未匹配的片段直接 `continue` 丢掉，用户以为估算已包含全部内容。
- **改动**：
  1. 同一 `food.id` 重复出现时**合并份量**（累加热量；两段都有显式克数时克数也累加），而不是丢弃——去重本意是防「米饭/白米饭」同义重复，合并数量同时满足两个目的；
  2. `FoodCalorieEstimate` 增加 `unmatchedHints: [String]`：把没认出来的片段收集起来供 UI 提示「这些没计入热量」；派生方法（改份量/换菜/自定义名称等 18 处）都会保留 hints。
- **测试**：新增 3 条——重复同类合并（两份包子+一个肉包 = 3 份热量）、混合餐保留 4 道菜、未匹配片段进入 `unmatchedHints`。
- **仍未做**：「米饭红烧肉青菜」这类无分隔符/无量词的中文连写，仍只命中第一道（需要中文分词，属于另一个量级的工作，已在报告里留档）。

### 17.3 验证结果

```
cd Packages/AssistantCore && swift test --disable-sandbox
  Executed 1134 tests, with 0 failures   （上一轮 1126，本轮 +8 条回归用例）

./scripts/ci.sh test
  ✓ 4 道闸门 exit 0
  ✓ AssistantCore 单元测试 通过
  ✓ 心理视图类型检查 通过
✅ 全部步骤通过 (test)

重复实现检查：`digits: [Character` 形式的独立字典 4 → 0，唯一实现收敛到 ChineseNumeralParser
```

- 本轮只改 Core 源文件 + 测试，`swift test` 即权威验证；App 侧可选后续：把 `unmatchedHints` 显示在食物热量页（「这些没认出来：…」）。
