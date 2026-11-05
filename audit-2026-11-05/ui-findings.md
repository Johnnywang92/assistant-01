# Features 视图层审计（2026-11-05）

范围：`Assistant/Features/`（124 个 Swift 文件，60 009 行，含 `Modules/`、`Omnibox/`、`Settings/`、`Share/`、`Todo/`、`Voice/`、`VoiceMemo/`、`Motion/`、`PromptBlocks/` 子目录）。
审计对象是**当前工作区内容**（`HabitAndMedicationView.swift`、`HealthDataView.swift`、`HealthShareCardView.swift`、`HydrationShareCardView.swift` 未提交改动按工作树读，未 reset/checkout）。只读业务代码，本文件是唯一写入。

## 结论摘要

| 优先级 | 条数 | 主题 |
| --- | --- | --- |
| P1 | 2 | 视图层 135 处 `try? context.save()` 吞错后仍给成功反馈；分享卡片家族（5 卡 + 7 弹窗）复制粘贴并已漂移 |
| P2 | 10 | 巨型 body/单表达式；指纹缓存 key 本身在 body 内重复 O(N) 计算；待办标签栏 O(T×N)；服药页 `todayMeals` 每行重扫全表；心理页全表 `@Query` 只换 3 个计数；行内 `@Query`（N+1）；`NavigationRouter` 整体订阅；164 个 sheet 修饰符 + 时序 hack；迁移页 body 内 20 次 `fetchCount`；食物页未缓存全表派生 |
| P3 | 5 | 新建/编辑待办双表单重复；宝宝/宠物档案同构；`ForEach` 索引身份与强解包；固定字号 82 处；body 内构造 `DateFormatter`/Service |

**与既有台账去重**：以下已实施项本轮**没有**重复报告——内容指纹缓存（`TodoClassificationCache`/`ExpenseSummary` 缓存/`ItemVaultCache`/`VaultStatsCache`/`ReportCache`）、`RowThumbnailCache`（ImageIO 降采样）、壁纸预渲染与 `@AppStorage(defaultsKey)` 订阅收敛、`AppTheme` 语义色/圆角令牌与 `check_radius_tokens.py` 闸门、`TodoShareSheet` 拆分、`DayTimelineView` 分钟缓存、`TodoListView` 已拆 `Todo/` 子文件、`TodayBriefingView` 折叠挂载、`SkillPathDetailView` 谓词化查询、`AppBackgroundManager` 退出 17 个页面的整体订阅。本轮对缓存的意见是**新的**：缓存 key 的计算成本本身没被缓存（见 UI-04）。

---

## 发现明细（按收益从大到小）

### UI-01 · P1 · 视图层 135 处 `try? context.save()`：落库失败被吞，UI 照样播成功

- **位置**：全 `Assistant/Features` 36 个文件共 **135 处**，密度最高：`LifeEventManagementView.swift`(15)、`VoiceMemoDetailView.swift`(7)、`ItemStorageVaultView.swift`(7)、`ExpenseTrackerView.swift`(7)、`Omnibox/OmniboxView.swift`(6)、`LearnedPlacesView.swift`(6)、`HabitAndMedicationView.swift`(6)、`TodoListView.swift`(5)、`Todo/TodoRowViews.swift`(5)、`PetManagementView.swift`(5)。
- **代码证据**：

  `Assistant/Features/HabitAndMedicationView.swift:165-169`（服药打卡）：
  ```swift
  } onMarkTaken: {
      med.markTaken()
      try? context.save()      // 失败静默
      Haptic.success()         // 成功反馈照给
  }
  ```

  `Assistant/Features/Todo/TodoRowViews.swift:65-77`（勾选完成）：
  ```swift
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
      AppMotion.animate(...) { item.markAsCompleted(in: context); ... }
      try? context.save()                                   // :72
      WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
  }
  ```
  同文件 `:85`（反选恢复未完成）同样是 `try? context.save()`。
- **影响**：磁盘满 / 数据库损坏 / SwiftData 校验失败 / 模型迁移遗留约束时，用户看到勾选打勾、成功震动、绿色反馈，但数据没落库；重启后记录回滚甚至丢失（尤其是「服药打卡」「完成待办」这类唯一事实源）。与 2026-10-29 CR-06/CR-07「成功但没落库」一族同源，只是这次面在视图层（当时只修了扩展/服务层，App 内 intent hook 分支仅剩 6 处；视图层这 135 处一直没进台账）。
- **修复建议**：
  1. 在 `Assistant/Services/`（或 `Assistant/Theme/` 之外的公共层）加一个统一出口，禁止视图层再直接 `try? save()`：
     ```swift
     extension ModelContext {
         /// 保存失败返回 false，由调用方决定是否播成功反馈。
         @discardableResult
         func saveReportingFailure(_ onFailure: (Error) -> Void) -> Bool {
             do { try save(); return true }
             catch { onFailure(error); return false }
         }
     }
     ```
  2. 每个写操作改成「保存成功才给成功反馈」：
     ```swift
     guard context.saveReportingFailure({ saveErrorToast = "保存失败：\($0.localizedDescription)" })
     else { Haptic.warning(); return }
     Haptic.success()
     ```
     页面已有 `showToast`/`feedbackBanner` 的，直接复用（`HabitAndMedicationView` 有 `showFeedback`，`ExpenseTrackerView` 有 `feedbackBanner`）。
  3. 加闸门脚本 `scripts/check_save_swallow.py`（照 `check_radius_tokens.py` 的形态）：扫 `Assistant/Features` 里 `try? context.save()`，命中即红；首批白名单可临时登记，按文件分批清零。
- **验证**：`grep -rn 'try? context.save()' Assistant/Features | wc -l` 应从 135 → 0；在 `#if DEBUG` 下加 `ForceSaveFailure` 开关（让 `context.save()` 抛错）跑一遍打卡/完成/删除路径，确认出现失败提示且 UI 不显示成功态；`./scripts/ci.sh test` 不回归。
- **状态**：**确认**（静态；135 处均为 `try?` 且多数紧跟成功态 UI）。修复本身需要逐条决定失败文案，属于「机械但需人工过一遍」的工作。

---

### UI-02 · P1 · 分享卡片家族：5 张卡 + 7 个弹窗模板级复制，已出现行为漂移与死状态

Lead 的 5 行窗口检测里，前 10 个配对有 **9 对**落在这个家族（见文末「重复配对索引」）。实读核对如下。

- **位置与重复面**：

  | 共享件 | 复制点 | 行数 |
  | --- | --- | --- |
  | 弹窗骨架（NavigationStack + 卡片预览 + 双按钮 + toast overlay + ShareActivityView sheet + 完成/标题） | `HealthShareCardView.swift:490-636`、`PsychShareCardView.swift:430-662`、`HydrationShareCardView.swift:298-434`、`ReportShareCardView.swift:491-645`、`ExpenseShareCardView.swift:214-357`、`Share/StoredItemShareSheet.swift:130-332`、`VoiceMemo/VoiceMemoShareCardView.swift:216-502` | 约 110–140 行/处 |
  | `renderImage / saveToPhotos / shareViaSystem / showToast` 四件套 | Health:606-634、Psych:633-661、Hydration:404-432、Report:615-644、Expense:323-355、StoredItem:286-331、VoiceMemo:476-501 | 约 30 行/处，7 处 |
  | toast overlay（黑底胶囊 + move/opacity transition + `.animation`） | 上述 7 个弹窗 + `TodoShareSheet`、`PetManagementView`、`ChildManagementView`、`WaterTrackerView`、`TodoListView` 各一份 | 约 13 行 × 12 处 |
  | 渐变卡面（`padding(18)` + `frame(maxWidth:350)` + `AppRadius.hero` + strokeBorder + shadow） | Health:330-350、Psych:64-82、Hydration:275-295、Report:441-455、Expense:200-210 | 约 15 行 × 5 处 |
  | 指标小卡 `statTile(icon:tint:title:value:subtitle:)` | Health:400-431、Report:458-489（两份只差 `ink`/`cardFill`）；Psych `subStatusTile` 344-374 同构 | 约 31 行 × 3 处 |
  | 品牌落款（「小助 · 个人智能生活助理」） | Health:296、Hydration:241、Psych:257-300、Report:407、Expense:171 | 约 20 行 × 5 处 |

- **已发生的漂移（不是假想风险）**：
  1. **死状态**：`ExpenseShareCardView.swift:219` 声明 `@State private var includeReceipt = false`，`:344` 用它决定是否把小票图片塞进分享面板，但**整个 `ExpenseCardShareSheet` 里没有任何 Toggle 绑定它**（对照 `ExpenseTrackerView.swift:2600` 里另一份 `ExpenseShareView` 才有关联 Toggle）→ 「附上原始单据」在卡片分享路径永远不生效，且多存了一份重复实现。
  2. toast 时长三套：6 处 2.5 秒、`StoredItemShareSheet.swift:326` 2.0 秒、`VoiceMemoShareCardView.swift:495` 用 `.snappy` 动画无 asyncAfter。
  3. `ShareCardActions.render` 的 `flattenAlpha` 参数（`Share/ShareCardActions.swift:19`）全仓 0 个调用点传 true。
  4. 卡面阴影 5 处不统一（`radius: 14/16/18, y: 6/8`），视觉上肉眼可辨。
- **修复建议（具体到文件与顺序）**：
  1. 新增 `Assistant/Features/Share/ShareCardPreviewSheet.swift`：
     ```swift
     struct ShareCardPreviewSheet<Card: View>: View {
         let title: String
         let saveButtonTitle: String
         let saveTint: Color
         let successMessage: String
         @ViewBuilder let card: () -> Card
         @State private var toastMessage: String?
         @State private var shareItems: [Any] = []
         @State private var isSharing = false
         // body = NavigationStack { ScrollView { card(); 双按钮 } .overlay(toast) } .sheet(...)
     }
     ```
     6 个弹窗改成 20~30 行的 `ShareCardPreviewSheet(title:..., card: { XxxShareCardView(...) })`，删除各自的 `renderImage/saveToPhotos/shareViaSystem/showToast`。
  2. 在 `ShareCardTheme.swift` 增加固定色板（**不要**用 `AppColor`：分享卡是 3x 离屏位图，必须颜色恒定，不能随深浅色/壁纸变化），例如
     ```swift
     struct ShareCardPalette { let background: [Color]; let ink: Color; let cardFill: Color; let divider: Color; let accent: Color }
     extension ShareCardPalette { static let mintVitality/…/obsidian }
     ```
     卡面收成 `ShareCardSurface(palette:)`（`padding(18)`/`maxWidth:350`/`AppRadius.hero`/strokeBorder/shadow 只写一次）。
  3. 新增 `ShareCardComponents.swift`：`ShareCardStatTile`、`ShareCardBrandFooter`、`ShareCardToast`（view modifier）。`statTile`/`subStatusTile`/落款全部改用它。
  4. `ExpenseCardShareSheet` 与 `ExpenseTrackerView.ExpenseShareView` 只保留一个：卡片分享走 `ShareCardPreviewSheet` 并补上小票 Toggle，或明确删掉死状态。
- **预期收益**：约 **-550 ~ -750 行**，5 张卡片的视觉/微交互收敛到 1 处；`includeReceipt` 这类漂移不再可能。
- **验证**：\(a\) 6 张卡改前改后用 `ShareCardActions.render` 各渲 3x PNG 做像素 diff（只允许无意义的 antialias 差异）；\(b\) `xcodegen generate` + `xcodebuild` 构建；\(c\) 新增闸门：`Assistant/Features` 里除 `Share/ShareCardPreviewSheet.swift` 外不允许出现 `private func renderImage()`。
- **状态**：**确认**（重复与漂移均已定位；像素级视觉一致性需真机核对）。

---

### UI-03 · P2 · 巨型 body / 单个 `some View` 表达式：不是文件大，是**单表达式**大

先说度量结论：8 个「超大文件」的主 `body` 其实只有 63–406 行，但**单个表达式**的嵌套与分支极多，且真正的巨型表达式集中在表单/行视图/卡片里。用大括号配平统计（`{}` 深度、`if/switch` 数、`ForEach` 数、三元数、`Section` 数）：

| 表达式（file:line，范围为 `some View` 表达式） | 行数 | 嵌套深度 | if/switch | ForEach | 三元 | Section |
| --- | --- | --- | --- | --- | --- | --- |
| `Todo/AddTodoSheet.swift:507-1072`（新建待办表单 body） | **566** | **14** | **33** | 5 | 11 | 10 |
| `LLMModelManagementView.swift:17-568`（模型管理 body） | **552** | 9 | 21 | 3 | 5 | 5 |
| `ItemStorageVaultView.swift:1709-2255`（`AddOrEditStoredItemSheet` body） | **547** | 11 | 15 | 13 | **28** | 10 |
| `ExpenseTrackerView.swift:1857-2353`（`AddOrEditExpenseSheet` body） | **497** | **13** | **25** | 4 | 6 | 7 |
| `Todo/TodoRowViews.swift:51-526`（**单行** `TodoRow` body，List 每行实例化） | **476** | 8 | **34** | 1 | **47** | — |
| `Omnibox/OmniboxView.swift:711-1156`（`actionCard`，每个待确认动作一张） | **446** | 8 | — | — | — | — |
| `ExpenseTrackerView.swift:330-735`（记账主页 body） | 406 | 12 | 18 | 6 | 9 | 6 |
| `ItemStorageVaultView.swift:353-736`（收纳主页 body） | 384 | 11 | 12 | 5 | 9 | 5 |
| `VoiceDialogueView.swift:46-422` | 377 | 10 | 11 | 2 | 18 | — |
| `WebDAVSyncView.swift:41-401` | 361 | 8 | 13 | 1 | 10 | 8 |
| `ReportShareCardView.swift:98-456` | 359 | 7 | 9 | 5 | 1 | — |
| `EditTodoSheet.swift:76-432` | 357 | **13** | 20 | 5 | 7 | 9 |

- **为什么是用户可见问题**（不只是「代码难看」）：
  1. 这些表达式里的子视图是**内联**的（`Section { ... }`、`if` 分支直接铺开），不是独立 `View` struct；父视图任一 `@State` 变化（表单里每敲一个字、每次 `estimation.isEstimating` 翻转）都要重建整段子树，SwiftUI 无法对其中稳定部分做跳过（只有独立 `View` 且可比较时才有这种优化空间）。
  2. 编译侧：单表达式是类型检查单元，14 层嵌套 + 33 个 `if` + 28 个三元是本项目最可能触发 "expression too complex" 与增量编译慢的文件；本仓已有 `scripts/typecheck-views.py` 专门为「视图体容易写错」兜底，说明视图层类型检查是团队的既有痛点。
  3. `TodoRow` 的 476 行 body 是**每行**都会实例化的，列表滚动时逐行构建/重建；且它带 4 个 `@State`（`isCopied/isAnimatingCompletion/ringScale/ringOpacity`），任一动画状态变化就重建 476 行表达式。
- **拆分方案（按工作量从小到大）**：
  1. `AddOrEditStoredItemSheet`：按现有 10 个 `Section` 机械拆成 `StoredItemNameSection`、`StoredItemLocationSection`、`StoredItemPhotoSection`、`StoredItemCostSection`、`StoredItemNoteSection`（新文件 `ItemStorage/StoredItemFormSections.swift`），body 目标 ≤ 80 行；`28` 个三元多半在「二手价/转卖/日均成本」摘要文案里，抽成 `private func costSummaryText() -> String` 纯函数。
  2. `AddOrEditExpenseSheet`：同理拆 `ExpenseAmountSection`(1861)、`ExpenseCategorySection`(2017)、`ExpenseReceiptSection`(2028)、`ExpenseLinkItemSection`(2197)、`ExpenseTimeSection`(2213)、`ExpenseSplitSection`(2218)，body 目标 ≤ 90 行。
  3. `AddTodoSheet`：拆 `TodoImportTabSection`(511/522)、`TodoCategorySection`(782)、`TodoContentSection`(812)、`TodoReminderSection`(865)、`TodoRecognitionSection`(1017/1027)；与 UI-13 的合并一起做，避免拆完再合并一次。
  4. `LLMModelManagementView`：拆 `ModelPresetSection`(20-78)、`ModelStatusCard`(79-183)、`ModelDownloadSection`(185-424)、`ModelSandboxTestSection`(426-500)、`ModelLANSection`(502-570)，body 只剩 5 个调用；这页是 552 行里唯一没有子 View 结构的，收益最直接。
  5. `TodoRow`：把「勾选圈 + 标题/取件码 + 徽标行 + 尾部按钮」拆成 `TodoRowCheckButton`/`TodoRowTitleBlock`/`TodoRowBadgeStrip`/`TodoRowTrailingActions` 4 个子结构（`rowTrailingButtons` 529-585 已经是现成的第一步，直接提到独立 struct 即可）。
  6. `OmniboxView.actionCard`：按 capability 拆 `ActionCardHeader`/`ActionCardFields(expense|todo|memo|habit|… )`，用 `switch wrapped.capability` 返回不同子视图；446 行 → 4~6 个 ≤80 行文件。
- **验证**：拆分前后各跑一次 `python3 scripts/typecheck-views.py <file>`（若可运行）与完整 `xcodebuild` 记录单文件编译耗时；用「编辑表单时每按键一次记录 body 求值次数」（临时 `os_signpost`）确认全树重建范围缩小；UI 行为回归靠真机逐字段操作。
- **状态**：**确认**（结构度量）；编译时间收益为**疑点**（本轮按要求未跑完整 xcodebuild）。

---

### UI-04 · P2 · 内容指纹缓存的 **key 本身**没缓存：一次渲染重复 O(N) 哈希 5–10 次

既有优化加了缓存，但每个缓存 getter 的第一行都是 `let key = vaultKey / analysisKey`——**缓存的 key 每次访问都重算**，body 里被引用几次就算几次。这是本轮新发现（与已实施的「加指纹缓存」不重复）。

- **位置与证据**：

  **收纳页** `ItemStorageVaultView.swift`：
  - `vaultKey`（`:88-110`）遍历**全部物品 10 个字段 + 全部关联支出 2 个字段**求 `Hasher`；
  - `areaCounts(:73)`、`linkedTotals(:113)`、`costTrackedSummaries(:130)`、`filteredItems(:154)` 四个 getter 都以 `let key = vaultKey` 开头；
  - body(353-736) 内引用次数：`costTrackedSummaries` ×5、`filteredItems` ×3、`areaCounts` ×1、`linkedTotals` ×1 → **单次渲染 10 次全表指纹**（每次含字符串哈希）。

  **记账页** `ExpenseTrackerView.swift`：
  - `analysisKey`（`:151-172`）对全部账目 10 个字段做指纹；
  - `summary`（`:182-190`）每次访问都算一次 `analysisKey`；body 里 `currentMonthCategoryBreakdown` 在 `:448 / :477 / :486 / :489 / :498` 被引用 5 次（每个 getter 都进 `summary`），加上 body 首行 `:331 let currentSummary = summary` → **6 次指纹/渲染**；
  - 另外 `filteredRecords` 在 `:562 / :574` 各过滤一遍全表，`dailyExpenseTrend(:212)`/`expenseTrend(:220)` 各把全量账目 map 一遍且**无缓存**。

  **待办页** `TodoListView.swift`：
  - `classificationKey`（`:155-196`）哈希活跃待办 13 个字段 + 最近完成 5 个字段；`classified`（`:110-152`）在 body/子视图被引用 25 次，虽然命中缓存后便宜，但**每次访问仍先算一次 key**（`:122`）；页面上还有一个 `.searchable` 输入框，每敲一个字就是一次全量哈希。
- **影响**：万条待办 / 万条账目下，每帧/每键的固定成本是「全表字段哈希」×5~10；表现为大字号搜索/极速记账输入时输入法卡顿（本项目的「流畅度」几轮一直在打这块，这个残留会抵掉一部分缓存收益）。数据量小时无感，所以适合压测时才暴露。
- **修复建议**（两种，任选，第一种改动最小）：
  1. 每个 body 只算一次 key，把值传给子视图/子 getter：
     ```swift
     var body: some View {
         let key = vaultKey                  // 每渲染一次
         let items = filteredItems(key: key) // getter 接收 key，不再自己算
         ...
     }
     private func filteredItems(key: Int) -> [StoredItem] { … }
     ```
     `ExpenseTrackerView` 已有 `let currentSummary = summary` 的先例，把 `currentMonthCategoryBreakdown`/`dailyExpenseTrend`/`filteredRecords` 一并提到 body 顶部即可（body 首行 5 个 `let`）。
  2. 更彻底：不要把「内容哈希」当 key，用**变更令牌**——写入路径统一 `recordStoreVersion &+= 1`（`@AppStorage`/单例计数）或监听 `ModelContext.willSave`/`didSave` 通知，key 变成 `O(1)`；同时解决下面「跨渲染陈旧」的隐患。
- **验证**：造 1 万条待办 / 1 万条账目（Core 已有万条性能闸的数据生成思路），Instruments Time Profiler 抓 `Hasher.combine`/`body` 耗时对比；在 `body` 首行加 signpost，统计单次渲染 `vaultKey` 调用次数应从 10 → 1。
- **状态**：**确认**（代码路径与引用次数已计数）；具体掉帧幅度为**疑点**（未真机实测）。

---

### UI-05 · P2 · 待办首页标签栏 O(标签数×待办数)，时间聚合条每次渲染重排 2–3 次

- **位置**：`Assistant/Features/TodoListView.swift`
  - `tagFilterBar`（`:1289-1330`）：`ForEach(allActiveTags, id: \.self)` 内 `let count = classified.active.filter { $0.tags.contains(tag) }.count`（`:1309`）→ 每个标签扫一遍**全部活跃待办**，标签数 T × 待办数 N；首页只要有标签就常驻渲染（`homeHeaderSection` `:1371` 判断非空即显示）。
  - `timeBuckets`（`:246-259`）无缓存：`TodoTimeAggregator.bucket(activeTodos.map { TodoTimeSnapshot(...) })`，每次访问都建一个 N 长数组再排序；同一渲染内被引用 3 次（`:262` `bucketTodoItems`、`:1159` `timeAggregationBar`、`:1378` `!timeBuckets.isEmpty`）。
  - `bucketTodoItems`（`:261-266`）还额外 `Dictionary(activeTodos.map {...})` 建一次全量字典。
- **代码证据**：
  ```swift
  ForEach(allActiveTags, id: \.self) { tag in
      let isSelected = selectedTagFilter == tag
      let count = classified.active.filter { $0.tags.contains(tag) }.count   // :1309
  ```
- **影响**：万条待办 + 20 个标签 ≈ 20 万次 `contains`，每次渲染都做（勾选、滚动触发状态变化、搜索输入都会触发）；`timeBuckets` 另加 3 次 O(N log N)。这是首页「打字/勾选时轻微顿一下」的固定成本，且随数据线性增长。
- **修复建议**：
  1. 把「标签 → 计数」并进 `TodoClassificationCache`（已有指纹 + 50ms 窗口机制，正好复用）：
     ```swift
     // TodoClassification 里新增
     let tagCounts: [String: Int]   // 一次遍历 classified.active 累加
     private var allActiveTags: [String] { classified.tagOrder }  // 稳定顺序
     // body
     let count = classified.tagCounts[tag] ?? 0
     ```
  2. `timeBuckets` 一样并入同一缓存对象（key 复用 `classificationKey`），`bucketTodoItems` 也用缓存的 `byID: [UUID: TodoItem]` 字典。
- **验证**：万条待办 + 20 标签场景，Instruments 里对 `TodoListView.body`/`tagFilterBar` 打 signpost 对比；或单测直接断言「一次 `classified` 访问后 `tagCounts` 已就绪，后续 body 访问不再 filter」。
- **状态**：**确认**。

---

### UI-06 · P2 · 服药页 `todayMeals` 在 `ForEach` 里每行重扫全表（工作区新代码放大了它）

- **位置**：`Assistant/Features/HabitAndMedicationView.swift`
  - `todayMeals`（`:29-77`）每次访问都 `foodRecords.filter(isDateInToday)` + `waterRecords.filter(...)` + `map` + `compactMap` + `sorted`，而两个 `@Query`（`:10`、`:12`）都是**全历史、无谓词**；
  - `topTimingEvaluation`（`:78-111`）在 `.map { MedicationFoodTimingAdvisor.evaluate(todayMeals:) }` 的闭包里引用 `todayMeals`（`:82`）→ **每个启用中的药各算一次**；
  - body 里 `ForEach(medPlans)`（`:159-180`）又对每行算一次 `todayMeals`（`:162`）→ 单次渲染 **2M+1 次全表扫描**（M=药数，8 个药就是 17 次）；
  - `todayEffectiveWaterML`（`:21-26`）同样每次访问扫全部 `waterRecords`，body `:371` 通过 `health.snapshot?.overridingDietaryWater(...)` 再调一次。
  - 工作区改动新增了 `@Query waterRecords`（`:12`，`git diff` 可见）——这个方向是对的（饮品也参与服药时效），但把「全表 + 每行重扫」的成本翻了一倍。
- **代码证据**：
  ```swift
  ForEach(medPlans) { med in
      let eval = MedicationFoodTimingAdvisor.evaluate(
          plan: med.toSnapshot(),
          todayMeals: todayMeals,      // :162 每行重算
          now: .now
      )
  ```
- **影响**：饮食/饮水记录累计到数百条后，进入打卡页与每次打卡都会做 15+ 次全表过滤；`@Query` 还把全部历史物化进内存，`HabitAndMedicationView` 又被 `@ObservedObject HealthKitService`(7 个 `@Published`) 驱动刷新，成本会反复发生。
- **修复建议**：
  1. 一次渲染只算一次并下发：
     ```swift
     var body: some View {
         let meals = todayMeals              // 1 次
         let water = todayEffectiveWaterML
         let evals = medPlans.filter(\.isEnabled).map {
             ($0, MedicationFoodTimingAdvisor.evaluate(plan: $0.toSnapshot(), todayMeals: meals, now: .now))
         }
         // topTimingEvaluation 从 evals 里挑；ForEach(evals, id: \.0.id) 直接用
     ```
  2. `@Query` 加日窗口谓词（`#Predicate<FoodIntakeRecord> { $0.date >= todayStart }`，`todayStart` 在 `init` 里取 `Calendar.current.startOfDay(for: .now)`），趋势/历史交给对应页面，不在这页物化全史。
  3. 若必须保留全表（跨午夜刷新考虑），退一步：把 `todayMeals`/`todayEffectiveWaterML` 放进和 `ItemVaultCache` 同形态的指纹缓存，key 只含 `foodRecords.count/waterRecords.count + 今日日期`。
- **验证**：造 400 条饮食 + 400 条饮水记录、8 个用药计划，Instruments 对比进入页面与点「已服药」时 `todayMeals` 调用次数（加临时计数器）应从 17 → 1。
- **状态**：**确认**。

---

### UI-07 · P2 · 心理页用两张**全表** `@Query` 换 3 个计数，且趋势线每次渲染重复算分

- **位置**：`Assistant/Features/MentalHealthView.swift`
  - `@Query private var todos: [TodoItem]`（`:22-23`）与 `@Query private var expenses: [ExpenseRecord]`（`:25-26`）都是无谓词全表；
  - 用途只有三个数：`completedTodosTodayCount`(`:492-495`)、`pendingTodosCount`(`:497-499`)、`todayExpenseAmount`(`:501-504`)，各筛一遍全表；
  - `availableTrendScales`（`:133-137`）对每个量表调 `trendPoints(for:)`；body `:62-64` 的 `ForEach(availableTrendScales)` 又对每个量表再调一次 `trendPoints`；每次 `trendPoints`（`:143-156`）都对全部量表记录做 `record.score()` → **同一份记录每次渲染算 4 遍分**；`latestInsight`（`:632-647`）还会对前 4 条记录再 `score()` 一次、把全部心情记录转一遍。
- **影响**：
  - 每次在任何页面新增/编辑**待办或账目**，本页的 `todos`/`expenses` 都会变更 → 整个心理页 body 重算（含上面 4 遍算分）；页面一旦打开，全历史待办/账目常驻内存；
  - 量表记录 200 条以上时，心理页首帧明显慢于同体量其他页（其他页做了指纹缓存，这页没有）。
- **修复建议**：
  1. 两个全表 `@Query` 换成窗口/状态谓词，或直接改成「进入页面时取一次数」：
     ```swift
     @Query(filter: #Predicate<TodoItem> { $0.statusRaw == "active" }) private var activeTodos: [TodoItem]
     // 今日已完成 / 今日支出：init 里用 startOfDay 构造日窗口谓词（同 ExpenseRecordWindow 的做法）
     ```
     计数也可用 `context.fetchCount(descriptor)` 在 `.task` 里取，页面不再订阅全表。
  2. 趋势数据一次算完：
     ```swift
     var body: some View {
         let trends = PsychScaleID.allCases
             .map { ($0, trendPoints(for: $0)) }
             .filter { !$0.1.isEmpty }
         // ForEach(trends, id: \.0) { PsychTrendChartCard(scaleID: $0.0, points: $0.1) }
     ```
     并把 `record.score()` 结果按 `record.id` 缓存在本页 `@State` 里（量表记录不可变，天然适合缓存）。
- **验证**：万条待办 + 5 千条账目 + 200 条量表记录，Instruments Allocations/Time Profiler 对比进入心理页；在别的 tab 记一笔账，观察本页 body 是否仍被触发（signpost 计数）。
- **状态**：**确认**（结构与重复访问已定位；具体耗时未实测）。

---

### UI-08 · P2 · 行内 `@Query`：`MedicineItemRow` 每个药品行都重查一遍 `MedicationPlan` 全表（父视图已查过同一张表）

- **位置**：`Assistant/Features/ItemStorageVaultView.swift`
  - 父视图 `ItemStorageVaultView` 已有 `@Query private var medPlans: [MedicationPlan]`（`:18`），并在 `batchRow`（`:262-263`）里用 `medPlans.contains { ... }`；
  - 但行视图 `MedicineItemRow`（`:1338`）在 `:1344` 又声明了一份 `@Query private var medPlans: [MedicationPlan]`（无谓词），`linkedPlan`(`:1347`)、`pausedPlan`(`:1351`)、`takenRecentlyToday`(`:1357`) 都用它 `first { ... }`；
  - 行实例由 `batchRow` 里的 `MedicineItemRow(`（`:265`）和分组展开（`:643-651`）创建——即**每个药品批次行各自发起一次全表查询 + 一份观察者**。
- **影响**：常备药 60 条时，收纳页一次渲染会触发 60 次 `MedicationPlan` fetch 与 60 份 SwiftData 观察；任何一次服药/停药会通知所有行重查。这是典型的 N+1，且父视图数据已现成。
- **修复建议**：删掉子视图的 `@Query`，由父视图下发（或下发 `[String: MedicationPlan]` 索引）：
  ```swift
  private struct MedicineItemRow: View {
      let plans: [MedicationPlan]          // 父视图传入
      private var linkedPlan: MedicationPlan? { plans.first { $0.medName == medicine.name && $0.isEnabled } }
      // …
  }
  ```
  父视图 `batchRow` 里 `MedicineItemRow(plans: medPlans, medicine: med, …)`。若担心父视图每次重建数组，`plans` 是值类型数组的引用拷贝（O(1)），不会拷贝元素。
- **验证**：60 个药品 + 60 个计划，Instruments Time Profiler 看页面进入时 `MedicationPlan` 的 fetch 次数（应从 ~61 → 1）；用 SwiftData 的 `ModelContext` 断言或在 `@Query` 初始化处打 signpost 计数。
- **状态**：**确认**。

---

### UI-09 · P2 · `NavigationRouter` 14 个 `@Published` 被 8 个页面整体订阅

- **位置**：`Assistant/Services/NavigationRouter.swift:80-102`（14 个 `@Published`：`selectedTab`、`activeSheet`、`requestedFilter`、`focusedTodoID`、`requestedTodoDetailID`、`pendingImportPayload`、`pendingUniversalEnvelope`、`omniboxPrefill`、`omniboxIsClipboardAutoIngest`、`requestedSkillPathList`、`requestedVaultDestination`、`requestedSettingsDestination`、`prefilledSearchQuery`、`requestedReportPeriod`）。
  订阅方（`@ObservedObject private var router = NavigationRouter.shared`）：
  `MainTabView.swift:9`、`TodoListView.swift:38`、`ExpenseTrackerView.swift:101`、`LifeVaultView.swift:277`、`LifeEventManagementView.swift:1018`、`Omnibox/OmniboxView.swift:24`、`SettingsViews.swift:84`、`UnifiedSearchView.swift:11`。
- **影响**：任意一个字段变化 → 8 个页面全部重算 body。最典型的是深链/统一搜索跳转：
  ```swift
  // NavigationRouter.focusTodo(_:)  // :109-112
  selectedTab = .todos
  focusedTodoID = id
  ```
  加上调用侧再设 `requestedTodoDetailID`（`:119-121`、`:134-136`）→ 一次点击 **3 次全量发布**。若当时停留在记账页/生活档案页，每次都要跑一遍 UI-04 的 O(N) 指纹 + 大 body 重建。
- **修复建议**（iOS 17 已可用的两条路）：
  1. 拆对象：`AppNavigationState`（`selectedTab`/`activeSheet`）+ `DeepLinkRouter`（`requested*`/`prefilled*`/`pending*`）+ `OmniboxRouter`（`omniboxPrefill`/`omniboxIsClipboardAutoIngest`），页面只订阅用到的那一个；一次深链的字段尽量落在同一个对象里。
  2. 或迁移到 `@Observable`（Observation 框架）：`@Observable final class NavigationRouter`，视图只追踪**实际读到的属性**，`selectedTab` 变化不会再让记账页重绘（需同步把 `@ObservedObject` 改成 `@State`/`@Environment` 直读）。本仓 iOS 17 起步，可逐步分文件迁移，风险可控。
- **验证**：临时在各页 body 首行 `os_signpost`；从统一搜索点一条待办，统计 8 个页面 body 求值次数（改前 3×8=24 量级，改后应 ≈ 1×1 + 目标页）；Instruments 的 SwiftUI View Body 模板可直接看。
- **状态**：**确认**（订阅面与发布次数）；实际掉帧幅度为**疑点**。

---

### UI-10 · P2 · 单页挂 10–12 个 sheet/fullScreenCover，靠 `asyncAfter` 延时规避冲突；其中一处逻辑会「当天再也不提醒」

- **规模**：全 Features **164 处** `.sheet(` / `.fullScreenCover(`，集中在：`TodoListView.swift`(12)、`LifeEventManagementView.swift`(11)、`ItemStorageVaultView.swift`(11)、`ExpenseTrackerView.swift`(11)、`FoodPhotoCalorieView.swift`(9)、`MainTabView.swift`(8)、`IDDocumentVaultView.swift`(6)。同一视图挂多个 `.sheet` 时 SwiftUI 只保证「一次一个」，由不同状态同时触发时的行为依赖时序，于是代码里出现多处延时 hack。

- **代码证据**：
  `TodoListView.swift:269-280`（早间逾期整理）：
  ```swift
  guard lastTriageDateKey != key, !overdueTodos.isEmpty else { return }
  lastTriageDateKey = key                      // 先记账：今天就「已整理」了
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
      if !showOverdueTriage { showOverdueTriage = true }   // 若此时别的 sheet 在场/页面已切走，这句静默失败
  }
  ```
  `TodoListView.swift:286-290`（搜索/深链直达详情）：
  ```swift
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { itemToEdit = item }
  ```
  `TodoListView.swift:320-327`（聚焦高亮 4s 后复位）与 `AppLockView.swift`（7 处 `asyncAfter`）同类。
- **影响**：
  1. **逾期整理当天丢失**：日期键在真正弹出前就被消耗；0.9s 内切 tab、或当时有别的 sheet（新建/语音/报告）在场导致呈现被丢弃时，当天不会再提醒——用户感知是「说好的早间清理卡没出现」。
  2. 慢设备（SE/长辈模式大字号）上 0.45s 不够 dismiss 动画，详情 sheet 被系统丢弃 → 点搜索结果「没反应」。
  3. 维护上：12 个布尔/可选状态两两组合都可能撞车，新增入口时极易引入同类 bug。
- **修复建议**：
  1. 每页收敛成单一路由枚举（沿用 `NavigationRouter.ActiveSheet` 的既有形态），只留一个 `.sheet(item:)`：
     ```swift
     enum TodoSheetRoute: String, Identifiable {
         case addTodo, voice, overdueTriage, timeBucket, completedHistory, periodicReport, share, edit, qr, ticket, senior, category
         var id: String { rawValue }
     }
     @State private var sheetRoute: TodoSheetRoute?
     // .sheet(item: $sheetRoute) { route in switch route { … } }
     ```
     需要携带数据的（`itemToEdit`/`selectedTimeBucket`）用 `enum Route { case edit(TodoItem), bucket(TodoTimeBucketKind), … }`。
  2. 跳转时序不要用 `asyncAfter`：详情/聚合页用 `.onDismiss` 链式呈现（`showSearch = false` → `.onDismiss { itemToEdit = item }`），或把「搜索选中 → 详情」合并成同一个 sheet 内部导航。
  3. 逾期整理改为「真正呈现后才记账」：把 `lastTriageDateKey = key` 挪到 `OverdueTriageSheet` 的 `.onAppear`（或 `.sheet(onDismiss:)` 里按是否展示过判断），并且 `DispatchQueue.main.asyncAfter` 前先判 `sheetRoute == nil`。
- **验证**：Debug 构建里给两个 sheet 之间人为加 1s 延迟（或在模拟器用慢动画），复现「点搜索结果无反应」与「切 tab 后当天不再弹整理卡」；改后同样步骤应稳定呈现。真机回归全部 12 个入口。
- **状态**：**确认**（12 个修饰符、4 处时序 hack、日期键顺序均可直接读到）；「呈现被丢弃」的具体发生率**疑点**（需真机复现）。

---

### UI-11 · P2 · 迁移页 body 内每次重绘执行 20 次 `fetchCount` 并重建 Service

- **位置**：`Assistant/Features/DataMigrationView.swift:64`
  ```swift
  Section {
      let stats = (migrationService ?? DataMigrationService(context: context)).getLocalDataStats()
  ```
  `DataMigrationService.getLocalDataStats()`（`Assistant/Services/DataMigrationService.swift:196-240`）对 **20 张表**逐个 `context.fetchCount(FetchDescriptor<T>())`；同时 `:405 / :434 / :459 / :475 / :494` 多处 `migrationService ?? DataMigrationService(context: context)` 在各按钮/辅助函数里重复构造。
- **影响**：这个页面有大量页面级 `@State`（`exportSuccessNotice`、`exportTempURL`、`shareFileURL`、`showSetPinSheet`、`isExporting` 等），每次状态变化（导出进度、提示出现、PIN 弹窗开关）都重新执行 20 条 SQL count。大库（万级待办/账目）上表现为进页与每次提示跳动的卡顿，且这些 count 与页面内容无关。
- **修复建议**：
  ```swift
  @State private var localStats: [String: Int] = [:]
  @State private var service: DataMigrationService?   // 复用实例
  private func refreshStats() { localStats = (service ?? DataMigrationService(context: context)).getLocalDataStats() }
  // body 只读 localStats
  // .task { service = service ?? DataMigrationService(context: context); refreshStats() }
  // 导入/还原成功后调用 refreshStats()
  ```
  另外把 `migrationService ?? DataMigrationService(context: context)` 统一收敛成一个 `private var service: DataMigrationService { if let existing = migrationService { return existing }; let s = DataMigrationService(context: context); return s }`（注意 `@State` 里持有的实例不能在 getter 里赋值——建议在 `.task`/`.onAppear` 里初始化一次）。
- **验证**：万条数据下 Instruments Time Profiler 进页；signpost 统计 `getLocalDataStats` 调用次数（应从「每次 body ×20 count」→「进页 1 次 ×20」）。
- **状态**：**确认**。

---

### UI-12 · P2 · 食物热量页 body 里两次未缓存的全表扫描（含全历史频次统计）

- **位置**：`Assistant/Features/FoodPhotoCalorieView.swift`
  - `@Query(sort: \FoodIntakeRecord.date, order: .reverse) private var records`（`:20`）无谓词（全历史）；
  - `quickSuggestionFoods`（`:1253-1300`）在 `for r in records` 里遍历**全部**历史记录做菜品频次 map，再排序；它被 `topSummaryAndRecommendationCard` 使用，位于 body 首屏（`body:109` 第一项，属性定义在 `:260`），因此**每次 body 求值都跑**；
  - `filteredFoodRecords`（`:1050-1063`）按周期过滤全表，被引用 4 次；`groupedFoodRecords`（`:1065-1100`）又调一次 `filteredFoodRecords`，其 `recordsHistorySection`（`:1150-1250`）内部还有 per-row `UIImage(data:)`（已确认图片写入时压到 480px JPEG，` :1408`，故解码开销可接受，不作为主要问题）。
- **影响**：拍照估算过程中 `estimation.isEstimating` 等状态高频翻转 → body 反复重建 → 每次都做 O(全部历史) 的频次统计；记录数百条后，拍照页在估算期间会有明显掉帧（这是拍照主流程，用户停留时间长）。
- **修复建议**：
  1. `quickSuggestionFoods` 结果按「记录指纹（count + 首条 updatedAt/日期）+ 餐次时间段」缓存（`ItemVaultCache` 同形态），或把频次统计挪到 `.task`/后台一次算好存 `@State`（历史频次是慢变量，不需要逐帧算）。
  2. `filteredFoodRecords`/`groupedFoodRecords` 一次算完：在 body 顶部 `let visibleGroups = groupedFoodRecords`，把值传给 `recordsHistorySection(groups:)`，避免 getter 链重复过滤。
  3. `@Query` 加「最近 N 天」窗口（趋势/历史翻页再扩展窗口），减少全史物化。
- **验证**：造 500 条食物记录，Instruments 对比拍照估算期间 `quickSuggestionFoods` 调用次数与主线程耗时；改后估算期间该函数应为 0 次（缓存命中）。
- **状态**：**确认**。

---

### UI-13 · P3 · 新建/编辑待办是两套表单（2089 行），已出现字段与能力漂移

- **位置**：`Assistant/Features/Todo/AddTodoSheet.swift`（1250 行，body `:507-1072`）与 `Assistant/Features/EditTodoSheet.swift`（839 行，body `:76-432`）。Lead 的 5 行窗口检测里这一对是**重复窗口第一名（52 个）**。
- **证据（逐项核对）**：
  - 重复的 `@State` 字段约 20 个：`title / type / detail / pickupCode / station / courier / hasDueDate / dueDate / remindBeforeMinutes / customRemindBeforeMinutes / recurrenceRule / customIntervalDays / qrCodePayload / qrCodeImageData / attachmentImageData / selectedPhotoItem / isRecognizingImage / showingQRPreview / recognizedTravelPickup / recognitionConfidence / recognitionConfidenceReason / recognitionSuggestedTypes / showConfidenceNotice`（AddTodo `:27-53`、Edit `:10-35`）；
  - 重复 section：`事项内容（标题+标签+分类选择）`（AddTodo `:812-864`、Edit `:80-137`）、`预约二维码与图片凭证 + 识别置信度提示`（AddTodo `:1017-1071`、Edit `:139-305` 附近）、`详情与备注`、`提醒与时间（截止/提前提醒/重复周期）`（AddTodo `:865-1015`、Edit `:306-357`）——两边的文案、`Picker` 选项、`DatePicker` 组合基本同构。
  - 已漂移：Edit 独有「到站清点」（`:358-380`）、「完成状态」（`:382-385`）、日历同步、删除确认；Add 独有「手动/智能导入」分段（`:511`）、剪贴板侦测（`:60-66` 状态）、同行票务附加待办（`:889-960`）。两边默认提醒值/自定义提醒哨兵（Edit `init` 里 `-1`）逻辑各写一份。
- **影响**：同一个待办字段的输入体验/默认值两边不一致；新增字段（如到站清点、标签）要改两处并手工对齐，漏改即「新建能填、编辑看不到」。
- **修复建议**：抽 `TodoFormSheet`：
  1. 新文件 `Todo/TodoFormDraft.swift`：`struct TodoFormDraft { var title, type, detail, …; init(defaultsFor:) / init(from: TodoItem) }`，把 20 个 `@State` 收进 1 个 `@State private var draft`；
  2. 新文件 `Todo/TodoFormSheet.swift`：`enum Mode { case create(TodoFilterCategory), edit(TodoItem) }`，单 `Form` + 共用 sections；
  3. 保留三个模式专属块：`if case .create = mode { importTab }`、`if case .edit = mode { arrivalCheck / doneStatus / delete }`；
  4. 旧 `AddTodoSheet`/`EditTodoSheet` 先保留为 30 行 wrapper（`TodoFormSheet(mode: .edit(item))`），确认无回归后删除。
  - 预期 2089 → 约 1200–1350 行（**-600 ~ -800**），且默认值/校验只有一处。
- **验证**：`xcodegen generate` + 构建；逐字段对比「新建 → 保存 → 编辑」的持久化结果（写成 UI 测试或脚本化 SwiftData 断言）；重点回归：自定义提醒 `-1` 哨兵、重复周期、到站清点、二维码图片、标签增删。
- **状态**：**确认**（重复与漂移已逐项核对；合并本身属中等风险重构，建议放在性能项之后）。

---

### UI-14 · P3 · 宝宝档案 ↔ 宠物档案同构（59.4% 行级相似），组件可共享

Lead 检测到 35 个重复窗口，核对属实：`Assistant/Features/ChildManagementView.swift`（582 行）与 `PetManagementView.swift`（626 行）的成员结构几乎一一对应：

| 角色 | Child | Pet |
| --- | --- | --- |
| 顶部概览卡（图标圈 + 标题 + 说明 + 圆角 banner 底） | `:74-101` | `:79-119` |
| 空状态卡（48pt 图标 + 标题 + 说明 + 添加按钮 + banner 底） | `:105-146` | `:121-162` |
| 档案卡 | `:148-294` | `:164-326` |
| 记录区块 | `:353-416` | `:412-476` |
| 快捷操作按钮 | `:418-435` | `:477-494` |
| `showToast` | `:437-448` | `:496-507` |
| 新增/编辑 sheet | `:450-582` | `:509-626` |

规范化（去字符串）后两段区间相似度 **59.4%**，最长连续匹配块：child `:371-402` ↔ pet `:431-462`（32 行记录区块）。

- **影响**：宝宝/宠物是两条高频维护线，「记录类型分组 + 里程碑时间线」的交互修复要在两处重复做（例如日期格式化、空态文案、无障碍标签）。
- **修复建议**（先组件化、不急于泛型化，避免类型擦除把可读性搞坏）：
  1. 新增 `Assistant/Features/Profile/ProfileScaffoldComponents.swift`：`ProfileOverviewCard(icon:tint:title:banner:subtitle:badge:)`、`ProfileEmptyStateCard(...)`、`ProfileQuickActionButton(...)`、`ProfileRecordsSectionCard(...)`、`ToastOverlay` modifier；两份档案页各删约 120–150 行。
  2. 若继续收敛，再引入协议（`DependentProfileCardModel`）只覆盖「标题/副标题/状态徽标/快捷操作」这层纯展示，记录与疫苗/驱虫的业务语义保留在各自文件。
- **预期收益**：约 **-250 行**，两个页面的空态/概览/按钮样式此后只改一处（也顺带修掉两页 banner 圆角/内边距的细微不一致）。
- **验证**：两页截图对比（空态、1 条档案、多档案三种状态）；`showToast` 统一后检查 2.0s/2.5s 提示时长是否按预期统一。
- **状态**：**确认**（相似度与成员映射已实测）。

---

### UI-15 · P3 · `ForEach` 身份不稳定 / 索引用作 ID（含一处边删边遍历）

- **位置与证据**：
  1. `Assistant/Features/MedicineReminderSupport.swift:492-512`：`ForEach(timePoints.indices, id: \.self)`，行内删除按钮直接 `timePoints.remove(at: idx)`（`:509`）。删中间一项后，`0..<n-1` 的身份被复用，`DatePicker` 行会「换内容不换身份」，动画与焦点落在错行；虽然 Binding 用 `indices.contains(idx)` 做了防越界（`:498-501`），但身份语义仍是错的。
  2. `Assistant/Features/HabitAndMedicationView.swift:951-953`：同类 `ForEach(timePoints.indices, id: \.self)` + `timePointBinding(at: idx)`。
  3. `Assistant/Features/TodoImportPreviewSheet.swift:85`：`ForEach(payload.items.indices, id: \.self)`，选中集合 `selectedItemIndices` 存的是**下标**；一旦条目顺序变化，选中态会错位（当前 payload 固定，属隐患）。
  4. `Assistant/Features/Todo/TodoRowViews.swift:358`：`ForEach(item.tags.prefix(2), id: \.self)` —— 标签若重复（导入/手输未去重），同一行内出现重复 ID，SwiftUI 会丢行/告警。同类：`MentalHealthView.swift:716`、`PsychScaleResultView.swift:265` 的 `ForEach(insight.secondaryActions, id: \.self)`。
  5. 顺带一处正确性小项：`Assistant/Features/HealthDataView.swift:567`
     ```swift
     let progresses = HealthMetrics.progress(for: effectiveSnapshot ?? health.snapshot!, goals: goals)
     ```
     当前由 `:110` 的 `if health.snapshot?.readState == .hasData` 兜住，但这是**工作区刚改过的那一行**仍保留的强解包；`snapshot` 被清空（HealthKit 撤权/重置）时会崩溃。
- **影响**：编辑服药时刻时删行闪烁/焦点错位；重复标签行静默消失；`snapshot!` 是低概率崩溃点。
- **修复建议**：
  1. 时刻列表改成带身份的值类型：`struct TimePointDraft: Identifiable { let id = UUID(); var time: Date }`，`ForEach($draft.timePoints) { $item in DatePicker(..., selection: $item.time) }`；导入预览同理改用 `item.id` 作为选中键。
  2. 标签行改为 `ForEach(Array(item.tags.prefix(2).enumerated()), id: \.offset)`，或先 `uniqueTags` 去重。
  3. `health.snapshot!` → `guard let snapshot = effectiveSnapshot ?? health.snapshot else { return EmptyView() }`（`metricCards` 内部再兜一层，不依赖调用方条件）。
- **验证**：删中间时刻行、删除首行后再次编辑；导入含重复标签的待办；`HealthDataView` 走一次「授权 → 设置里撤销健康权限 → 返回」。
- **状态**：**确认**（代码路径）；实际崩溃/闪烁为**疑点**（需真机复现）。

---

### UI-16 · P3 · 非分享卡区域仍有 82 处 9–12pt 固定字号，大字号/长辈模式不缩放

- **位置**：`grep -rn '\.font(\.system(size: \(9\|10\|11\|12\)' Assistant/Features | grep -v ShareCard` → **82 处**（2026-10-14 那轮只改了 26 处 9–10pt 文本）。典型且是**真实文本**（不是图标/角标）的：
  - `PeriodicReportView.swift:368/380/393`（「晚盘复盘中」等状态标签 9.5pt）
  - `MentalHealthView.swift:415`（情绪描述文本 10pt）、`:391/:589`
  - `LifeVaultView.swift:417/878/888`（「周期总览」等 9–10pt 标签）
  - `ExpenseTrackerView.swift:1778`、`HabitAndMedicationView.swift:471/491`、`UnifiedSearchView.swift:295`
  - `AppBackgroundSettingsView.swift:53` 属壁纸预览仿真图，可豁免。
- **影响**：系统字体放大或长辈模式下这些标签不跟随，与周边语义字体比例失衡；长辈模式用户大概率看不清（项目本身有「长辈关怀」卖点）。
- **修复建议**：逐条判断：真实文本改 `.caption2/.caption` 或 `@ScaledMetric`；`Image` 图标用 `.caption2` 或 `@ScaledMetric(relativeTo: .body) var iconSize`；分享卡/壁纸预览等**渲染成位图**的固定尺寸保留（输出必须确定性）。可给 `check_radius_tokens.py` 的兄弟脚本加一道「`Assistant/Features` 下除 `*ShareCard*`/`Share/`/`AppBackgroundSettingsView` 外禁止 `.font(.system(size: 9|10|11|12`」闸门。
- **验证**：Accessibility Inspector + 设置里 AX5 字号截图；长辈模式下检查上述 6 个页面标签是否与正文等比放大。
- **状态**：**确认**（数量与位置；视觉影响明显）。

---

### UI-17 · P3 · body 内构造 `DateFormatter` / Service（可减少每键分配）

- **位置**：
  1. `Assistant/Features/Todo/AddTodoSheet.swift:908-912`（在 `ViewBuilder` 分支里创建，表单每敲一个字都会重建）：
     ```swift
     let f: DateFormatter = {
         let df = DateFormatter()
         df.dateFormat = "M月d日"
         return df
     }()
     ```
  2. 视图内重复构造重量级对象：`HabitAndMedicationView.swift:221/532/1069` 的 `HabitAndMedicationScheduler(context:)`、`MedicineReminderSupport.swift:692/1131`、`DataMigrationView.swift:64/405/434/459/475/494` 的 `DataMigrationService(context:)`（后者已并入 UI-11 一起改）。
- **影响**：`DateFormatter` 初始化是已知的毫秒级/次成本，放在表单 builder 里随打字反复发生；重复构造 Service 会重复建立定时/调度状态（`HabitAndMedicationScheduler` 每构造一次都可能触发一次重排，具体看其 init，属**疑点**）。
- **修复建议**：格式化器用静态常量或值类型格式：
  ```swift
  // 方案 A
  private static let monthDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日"; return f }()
  // 方案 B（推荐，Swift 5.9+）
  Text(date.formatted(.dateTime.month(.defaultDigits).day()))
  ```
  Service 在 `.task`/`.onAppear` 里构造一次存 `@State`。
- **验证**：Instruments Allocations 对比表单打字时的 `DateFormatter` 分配数（应从每键多次 → 0）；`grep -n 'DateFormatter()' Assistant/Features` 应只剩静态常量。
- **状态**：**确认**（构造点位置）；Service 构造的具体副作用**疑点**。

---

## 与 Lead 重复配对检测的映射

| Lead 排序 | 配对 | 窗口数 | 归属 | 处理建议 |
| --- | --- | --- | --- | --- |
| 1 | EditTodoSheet ↔ Todo/AddTodoSheet | 52 | **UI-13** | 合并为 `TodoFormSheet` + `TodoFormDraft`（-600~-800 行） |
| 2 | HealthShareCardView ↔ PsychShareCardView | 44 | **UI-02** | `ShareCardPreviewSheet` + `ShareCardSurface` + `ShareCardStatTile` |
| 3 | HydrationShareCardView ↔ ReportShareCardView | 40 | **UI-02** | 同上；弹窗骨架 81% 相似已验证 |
| 4 | HealthShareCardView ↔ ReportShareCardView | 37 | **UI-02** | `statTile` 两份只差 ink/fill（Health:400 vs Report:458） |
| 5 | ChildManagementView ↔ PetManagementView | 35 | **UI-14** | 抽 `ProfileScaffoldComponents`（-250 行），暂不做泛型 |
| 6 | HealthShareCardView ↔ HydrationShareCardView | 34 | **UI-02** | 弹窗骨架相似度实测 81% |
| 7 | HydrationShareCardView ↔ PsychShareCardView | 27 | **UI-02** | 同上 |
| 8 | PsychShareCardView ↔ ReportShareCardView | 27 | **UI-02** | 同上 |
| 9 | PsychShareCardView ↔ Share/StoredItemShareSheet | 26 | **UI-02** | 两者都有主题选择/导出四件套；StoredItem 多「微信口令/AirDrop」两个按钮 |
| 10 | ExpenseShareCardView ↔ HealthShareCardView | 23 | **UI-02** | 同模板；顺带修 `includeReceipt` 死状态 |

**主题令牌可否复用**：可以复用但只限**几何**令牌——`AppRadius.hero/card/banner`、`AppSpacing.*` 在 5 张卡里已经在用（`check_radius_tokens.py` 罩得住）。颜色**不要**收敛到 `AppColor`：分享卡要 3x 离屏渲染出确定性位图，`AppColor` 是动态语义色（随深浅色/壁纸变化），会让同一张卡在不同外观下导出不同图。正确做法是新增固定色板 `ShareCardPalette`（UI-02 方案 2），与 `ShareCardTheme` 现有四套主题并列。

---

## 建议实施顺序（收益/风险比）

1. **UI-01**（save 吞错 + 闸门）：改动机械、风险最低，直接消除一类静默数据丢失。
2. **UI-04 / UI-05 / UI-06 / UI-08 / UI-11 / UI-12**（性能小手术）：每项都是「把重复计算挪到一次/去掉全表订阅」，单点可回滚，建议每项配一个 signpost 数据。
3. **UI-02**（分享卡模板化）：先做 `ShareCardPreviewSheet`（风险小、行数收益大），再做卡面/statTile/落款。
4. **UI-03**（巨型 body 拆分）：工作量大但机械，先拆表单与 `TodoRow`，最后拆 `OmniboxView.actionCard`。
5. **UI-09 / UI-10**（路由与 sheet）：跨页面改动，放同一批次做，配真机回归。
6. **UI-13 / UI-14**（表单与档案合并）：行为回归面最大，放最后，先补 UI 级冒烟用例。
7. **UI-15 / UI-16 / UI-17**（小项）：随时可做，适合穿插。

---

## 测量方法与复核命令

```bash
# 1) 文件/表达式规模（本报告 UI-03 表）
find Assistant/Features -name '*.swift' | xargs wc -l | sort -rn | head

# 2) body 与单表达式范围（配平大括号，见正文表格）
#    实现见本次审计临时脚本思路：定位 `var body: some View` /
#    `private func xxx(...) -> some View`，从 `{` 配平到深度 0。

# 3) 吞错保存
grep -rn 'try? context.save()' Assistant/Features --include=*.swift | wc -l   # 135
grep -rl 'try? context.save()' Assistant/Features --include=*.swift | wc -l   # 36

# 4) 分享卡复制面
for f in HealthShareCardView PsychShareCardView HydrationShareCardView \
         ReportShareCardView ExpenseShareCardView Share/StoredItemShareSheet \
         VoiceMemo/VoiceMemoShareCardView; do
  grep -n 'private func renderImage\|private func saveToPhotos\|private func showToast' \
    "Assistant/Features/$f.swift"
done

# 5) 重复窗口（Lead 数据可复跑；规范化后 difflib.SequenceMatcher）
python3 - <<'PY'
import difflib, pathlib, re
def sig(p, a, b):
    ls = pathlib.Path(p).read_text().splitlines()[a-1:b]
    return [re.sub(r'"[^"]*"', '"S"', l.strip()) for l in ls if l.strip()]
a = sig('Assistant/Features/ChildManagementView.swift', 74, 450)
b = sig('Assistant/Features/PetManagementView.swift', 79, 509)
print(round(difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()*100, 1))  # 59.4
PY

# 6) 订阅面
grep -rn '@ObservedObject private var router = NavigationRouter.shared' Assistant/Features | wc -l  # 8
grep -c '@Published' Assistant/Services/NavigationRouter.swift                                  # 14

# 7) sheet 规模
grep -rc '\.sheet(\|\.fullScreenCover(' Assistant/Features --include=*.swift | awk -F: '$2>0' | sort -t: -k2 -rn | head

# 8) 固定字号（排除分享卡）
grep -rn '\.font(\.system(size: \(9\|10\|11\|12\)' Assistant/Features --include=*.swift | grep -v ShareCard | wc -l  # 82
```

**本轮未做**：未跑完整 `xcodebuild`（按要求）；未真机/模拟器实测 UI；未接入 Instruments（所有「掉帧/耗时」结论都是基于代码路径与数据规模的推断，已在各条标注「疑点」的除外均为静态确认）。

---

## 已核对但**未**发现问题的方向（避免后续重复投入）

- **`@EnvironmentObject` 滥用**：`Assistant/Features` 全层 0 处 `@EnvironmentObject`（只有 `@Environment(\.modelContext)`/`\.dismiss`/`\.colorScheme`/`\.scenePhase`），主题订阅已在 2026-10-14 收敛，无新增。
- **`Timer` 未失效**：Features 层 0 个 `Timer`；唯一的周期重绘是 `DayTimelineView` 的 `TimelineView(.periodic: 60)`（已有分钟级指纹缓存）。
- **force unwrap / `try!` / `as!`**：全层仅 1 处 `health.snapshot!`（UI-15 已列）；`as!`、`try!` 各 0；`.first!`/`.last!` 各 1 处且都有前置 guard（`MemoCapabilityProvider.swift:83` 的 `documentDirectory.first!`、`PsychTrendChartCard.swift:51` 的 `points.count >= 2` 后 `last!`）。
- **字典/数组越界**：`parts[0]/parts[1]` 系列（`HabitAndMedicationView:1135`、`TodayBriefingView:254`、`ReminderCenterView:50`、`DayTimelineView:192`、`MedicineReminderSupport:418/590`、`TodoCapabilityProvider:262`、`OmniboxPlanner:1287`）**全部**有 `guard count == 2` / `count >= 2` 保护；`costTrackedSummaries[0]`、`group.batches[0]`、`palette[0]` 也都在非空/count==1 分支内。不构成越界风险。
- **`ForEach` 非稳定 id 的大头**：绝大多数 `id: \.self` 是枚举/固定字符串数组（安全）；真正有隐患的已收进 UI-15。
- **图片未降采样**：收纳/药品行已用 `RowThumbnailCache`；食物记录图片写入时压到 480px JPEG（`FoodPhotoCalorieView.swift:1408`），行内 `UIImage(data:)` 解码约 0.7MB 位图/行，属可接受，未单列发现。
- **Lazy 容器缺失**：8 个目标页的列表都是 `List`（天然懒加载），`HealthDataView` 有 5 处 `LazyVGrid/LazyVStack`；没有发现「大列表塞进 `ScrollView + VStack`」的写法。
- **`NavigationRouter` 的 `requested*` 消费纪律**：各消费点基本都在用后置 `nil/false`，未发现「置位后无人消费」的悬挂字段（UI-09 只谈订阅面过大，不谈消息丢失）。
- **`OmniboxView` 的倒计时 Task**：`countdownTask`/`clipboardDismissTask` 有 `onDisappear`（`:205`）与 cancel（`:1848/1891`）成对处理，未发现泄漏。

## 待验证疑点（留给下一轮或真机）

1. **`.onChange(of: 模型数组)` 是否对属性级编辑生效**：`TodoListView.swift:494 .onChange(of: todos)`、`LifeVaultView.swift:731 .onChange(of: foodRecords)` 依赖「数组变更」触发提醒横幅刷新。若 SwiftData `@Model` 实例按 `persistentModelID` 比较（`Array` 的 `==` 走元素 `==`），则**改标题/到期日不会改变数组相等性，回调不触发**，纪念日/车票横幅要等下一次结构变更才刷新。验证方式：Debug 下在两处 `onChange` 里 `print`，编辑一条待办标题/时间观察是否打印；若确认不触发，改为订阅显式变更信号（如 `NotificationCenter` 的 `NSManagedObjectContextDidSave`/写入路径递增版本号）。
2. **`PeriodicReportView` 指纹覆盖不足**：`dataFingerprint`（`:72-85`）只哈希 `recentExpenses/recentTodos` 各前 30 条的 `id + amount`（待办只 + `status/isDone/completedAt`），而 `generateReport` 是多次全表 fetch。编辑 30 条之外的旧账目或改分类，本页缓存不会失效（0.05s 窗口之外仍陈旧）。验证：打开周报 → 修改一笔 3 个月前的账目 → 回到报告页看分类占比是否更新。
3. **`HabitAndMedicationScheduler(context:)` 在视图内多次构造的副作用**：若其 init 会重排通知或注册观察者，`HabitAndMedicationView:221/532/1069` 的重复构造可能造成通知重排放大；需读 Services 层确认（不在本轮范围）。
