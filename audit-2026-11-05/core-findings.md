# AssistantCore 纯逻辑包审计（2026-11-05）

## 范围与方法

- 范围：`Packages/AssistantCore/`（`Sources/AssistantCore` 91 个源文件 ≈ 2.47 万行；`Tests/AssistantCoreTests` 80 个测试文件）。
- 基线：当前工作树（含未提交改动）。工作树内 Core 侧未提交文件仅 `HealthMetrics.swift`、`SettingsSnapshot.swift`、`HealthMetricsTests.swift`，已逐行看过，未发现新缺陷（改动本身是「饮水/睡眠目标同源 + 每日热量目标进备份白名单」，方向正确）。
- 方法：静态阅读 + **独立探针实测**。关键结论不是只靠读代码：把纯函数文件单独编译成 macOS 探针（Release `-O`）跑真实输入，命令与输出见文末「实测记录」。
- 本轮**未修改任何 `.swift` / 工程 / 文案文件**，只写本文件。
- 不重复 `code-review-2026-10-29.md` 的 CR-01…CR-11（CSV 引号解析、WebDAV 跨源 href、备份口令等）；也不重复 `todo.md` 已完成项（PromptBudget、预算窗口、批量导入校验、拼音搜索倒排「设计」等）。
- 优先级：**P1** = 数据/安全/关键链路；**P2** = 特定场景正确性或可测性能退化；**P3** = 低影响改进。
- 每条标注「确认」（已实测或代码路径可静态闭合）或「疑点」（静态推断、未实测）。
- 结论：确认 12 项（P1×2、P2×5、P3×5）。最需要先看的是 CORE-01 / CORE-02：金额解析的两处静默错账。

## 结论摘要

| 编号 | 优先级 | 主题 | 状态 |
| --- | --- | --- | --- |
| CORE-01 | P1 | 一句话记账「X块五毛 / X毛五 / X点五元」的角分被截掉 | 确认 |
| CORE-02 | P1 | 中文数字口语省略单位（「三百五」=350）被算成 305 / 1005 | 确认 |
| CORE-03 | P2 | 小票日期：缺年用墙上时钟、不回滚未来日期、不校验溢出日期 | 确认 |
| CORE-04 | P2 | 用药时效状态机：饭后「等待最佳时机」分支不可达；饭前分支不看进餐记录 | 确认 |
| CORE-05 | P2 | `SearchIndexEngine` 倒排索引只写不读，搜索退化为每次按键 O(N) 全表 | 确认 |
| CORE-06 | P2 | 热量估算热路径：每次调用最多重编译 10 条正则 + 全表别名小写化 | 确认 |
| CORE-07 | P2 | Swift 6 严格并发未就绪：2 处 static 非 Sendable 缓存、Package 仍 5.10 | 确认 |
| CORE-08 | P3 | 中文数字解析 4 份重复实现且语义不一致 | 确认 |
| CORE-09 | P3 | `estimateMeal` 按 food.id 去重静默丢菜；无分隔符多菜只取第一道 | 确认 |
| CORE-10 | P3 | 测试缺口与断言过弱（正是 CORE-01/02/03/04 逃逸的原因） | 确认 |
| CORE-11 | P3 | `SafeToSpendResult.==` 自定义实现忽略 9 个字段 | 疑点 |
| CORE-12 | P3 | WebDAV 目录 URL 双重编码；裸文件名相对 href 被拒（注释承诺可用） | 确认 |

---

## CORE-01 · P1 · 一句话记账把「X块五毛」的角分截掉，静默少记 0.5–1 元

- **状态**：确认。独立探针实测（`swiftc -O`，见文末 R1）。
- **位置**：[ExpenseAmountExtractor.swift:124](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L124)（`extractAmount` 入口）、[127–133](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L127)（`chineseAmountRegex` 先命中即返回）、[48–57](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L48)（两条正则定义）。
- **代码证据**：
  ```swift
  // extractAmount(from:)  :127
  if let regex = chineseAmountRegex,
     let match = regex.firstMatch(in: text, range: fullRange),
     let range = Range(match.range(at: 1), in: text),
     let value = numberValue(String(text[range])), value > 0 {
      return value            // ← 命中「三百二十八」就返回 328，后面处理「块五毛」的 spokenAmountRegex 永远轮不到
  }
  if let regex = spokenAmountRegex, ... // :135 才处理 块/毛 分位
  ```
  `chineseAmountRegex` 的捕获组是 `([零〇一二两三四五六七八九十百千万]+)`，遇到「块」即停；它是**第一优先**且命中即 `return`。`spokenAmountRegex`(:54) 本身能正确处理「X块Y毛」（现有测试 `咖啡35块5毛` 之所以通过，只因为输入是阿拉伯数字）。
  另外 `normalize`(:25–38) 把「点」替换成 `.`，但所有正则的数字分支只接受阿拉伯小数（`[0-9]+(?:[.][0-9]+)?`），于是「九点五元」被拆成「九.五元」，同样被 `chineseAmountRegex` 截成 9。
- **触发条件**（用户语音/文字记账，任一即可）：
  | 输入 | 实际记入 | 应为 |
  | --- | --- | --- |
  | 花了三百二十八块五毛 | **328.0** | 328.5 |
  | 花了九块五毛 | **9.0** | 9.5 |
  | 付了九块五 | **9.0** | 9.5 |
  | 花了九毛五 | **9.0** | 0.95 |
  | 花了二十块零五毛 | **20.0** | 20.5 |
  | 花了九点五元 | **9.0** | 9.5 |
  | 午饭三十八点五元 | **nil**（完全不入账） | 38.5 |
- **用户影响**：「X块五毛」是中文口语里最常见的报账方式之一。金额被静默改小（0.5 元到 1 元、或差 8 元），用户不会收到任何提示；日/月汇总、预算与「安心花」全部基于错账计算，属于典型的静默数据损坏。反过来「九毛五 → 9 元」是 10 倍偏差。
- **修复建议**（两条都要做，缺一不能覆盖上表）：
  1. **调换优先级**：先跑 `spokenAmountRegex`（带单位与分位），再跑不带单位的纯中文数字。同时给「毛/角」单独的「X毛Y」分支：
     ```swift
     // 新增：X毛Y / X角Y（无「块/元」主单位）
     private static let jiaoFenRegex = try? NSRegularExpression(
         pattern: "(?<![0-9.．])([零〇一二两三四五六七八九十]+|[0-9]+)\\s*(?:毛|角)\\s*([0-9]+|[零〇一二两三四五六七八九十]+)?"
     )
     ```
  2. **中文小数在 `normalize` 里先数字化**（`九点五` → `9.5`），再走现有阿拉伯小数正则：
     ```swift
     // normalize 内，在 replace("点"→".") 之前：
     value = Regex.replace("([零〇一二两三四五六七八九十百千万]+)点([零〇一二两三四五六七八九十]+)",
                           in: value, with: "") // 取到两段后各自 numberValue 拼成 "整.分" 回写
     ```
     实现时注意「点」还要保持「九点吃了个苹果」这类时间表达不被数字化的保护（仅当「点」前后都是数字字符时才转换）。
- **验证方式**：把上表 7 行直接加成 `ExpenseAmountExtractorTests` 用例；再跑 `swift test --disable-sandbox --filter ExpenseAmountExtractorTests`。本轮已用独立探针确认修复前行为（R1）。

---

## CORE-02 · P1 · 中文数字口语省略单位被算错：「三百五」→305、「一千五」→1005

- **状态**：确认。探针实测（R1）。
- **位置**：[ExpenseAmountExtractor.swift:162–179](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L162)（`numberValue`）；被 [130](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L130)、[138](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L138)、[142](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L142) 三处调用。
- **代码证据**：
  ```swift
  for char in value {
      if let digit = digits[char] { current = digit; continue }
      switch char {
      case "十": section += (current == 0 ? 1 : current) * 10; current = 0
      case "百": section += (current == 0 ? 1 : current) * 100; current = 0
      ...
  }
  return total + section + current      // :178 「三百五」→ 300 + 5 = 305
  ```
  中文口语里「尾随一位数字」表示**下一级单位**：三百五 = 350、一千五 = 1500、两百五 = 250、一万五 = 15000。当前实现把它当个位处理，且**没有「零」的判别**（`一千零五` 应保持 1005）。
- **触发条件**：语音/文字记账里的口语数字，经 `chineseAmountRegex`（含「花了/付了/收入/进账/工资/奖金/支出/消费/共计/借出」等动词）或 `spokenAmountRegex` 进入 `numberValue`。
  | 输入 | 实际 | 应为 |
  | --- | --- | --- |
  | 花了三百五 | **305** | 350 |
  | 花了三百五元 | **305** | 350 |
  | 收入一千五 | **1005** | 1500 |
  | 一万五 | **10005** | 15000 |
  | 一千零五 | 1005（正确） | 1005 |
- **用户影响**：金额被静默记错（可差一个数量级），且「收入一千五」这种说法在语音记账里很常见；错账进入月汇总/预算后无法自愈。
- **修复建议**：在 `numberValue` 末尾按「是否出现过 零 / 尾随单位」判定：
  ```swift
  // 记录最后一个大单位与其倍数
  var lastBigUnit = 0.0          // 10000 / 1000 / 100 / 10
  var sawZero = false
  ...
  case "零", "〇": sawZero = true
  ...
  // 收尾：无「零」、个位是 1...9 且前面出现过大单位 → 该位表示下一级单位
  if !sawZero, current > 0, current < 10, lastBigUnit > 0 {
      let shortcut = lastBigUnit / 10 * current   // 百→十 / 千→百 / 万→千
      return total + section + shortcut
  }
  return total + section + current
  ```
  注意 `三百零五`（有零）必须保持 305，`一百五十` 保持 150（此时 `lastBigUnit==10`，短路不触发即可）。
- **验证方式**：给 `ExpenseAmountExtractorTests.testChineseNumberConversion` 补 `三百五=350`、`一千五=1500`、`一万五=15000`、`两百五=250`、`一千零五=1005`、`三百零五=305` 六条；探针已确认修复前行为（R1）。

---

## CORE-03 · P2 · 小票交易日期：缺年用墙上时钟、未来日期不回滚、溢出日期被静默规范化

- **状态**：确认。探针实测（R2）。
- **位置**：[ReceiptTextParser.swift:77–78](Packages/AssistantCore/Sources/AssistantCore/ReceiptTextParser.swift#L77)（缺省年/时）、[12–49](Packages/AssistantCore/Sources/AssistantCore/ReceiptTextParser.swift#L12)（`extract(from:)` 无 `now` 参数）、[50–95](Packages/AssistantCore/Sources/AssistantCore/ReceiptTextParser.swift#L50)（`dateComponents` 不校验范围）、[132](Packages/AssistantCore/Sources/AssistantCore/ReceiptTextParser.swift#L132)（`parse` 的 `now` 只做兜底，不参与年份推断）。
- **代码证据**：
  ```swift
  if comps.year == nil { comps.year = Calendar.current.component(.year, from: .now) }  // :77 ← 用真实墙上时钟
  if comps.hour == nil { comps.hour = 12 }                                            // :78
  ```
  `ReceiptTextParser.parse(_:now:)` 声明了可注入的 `now`（便于测试），但它只用于「文本里完全没有日期」的兜底：`let date = TransactionDateExtractor.extract(from: text) ?? now`（:132）。文本只有「月日」时，年份取的是**真实当前年**，与传入的 `now` 无关；也**没有「解析结果晚于 now 就回滚一年」**的处理。
- **触发条件与实测**（R2，探针 `now` 注入 2025-01-02，机器真实日期 2026-11-05）：
  - `parse("12月25日 18:30 消费 88元", now: 2025-01-02)` → **2026-12-25 18:30**（应 2024-12-25，差近两年；真实场景里 1 月导入 12 月小票会记到 11 个月后的未来）。
  - `2024-02-31 10:00` → **2024-03-02**（应为无效/跳过）。
  - `2024-13-45 10:00` → **2025-02-14**。
  - `2024-06-15 25:99` → **2024-06-16 02:39**。
- **用户影响**：小票/截图记账的日期错月（跨年时差 11 个月），月报、预算周期、「本月已花」全部错位；同一缺陷让 `now` 注入形同虚设，测试无法钉住行为。
- **修复建议**：
  ```swift
  // 1) extract 增加 now 参数（默认 .now），内部一律用注入值；
  // 2) 月日缺年时：先按 now 的年构造，若结果 > now + 1 天，则减 1 年；
  // 3) 解析后做「回写比对」，非法日期（月>12、日超过当月天数、时>23、分>59）返回 nil：
  guard let date = calendar.date(from: comps),
        calendar.dateComponents([.year,.month,.day,.hour,.minute], from: date).month == comps.month,
        ... else { return nil }
  ```
  与 `BatchCSVImport.parseDay`(:128) 的「回写比对」保持同一套判据（那里已修过 `2022-02-31` 被顺延的问题，本文件是漏网的同族实现）。
- **验证方式**：`ReceiptTextParserTests` 现有用例只 `XCTAssertNotNil`（:95–99），改成断言精确日期并注入 `now`；补「1 月解析 12 月」「2024-02-31」「25:99」三条。探针已确认修复前行为（R2）。

---

## CORE-04 · P2 · 用药时效状态机：饭后「等待最佳时机」分支不可达；饭前分支不看进餐记录

- **状态**：确认。探针实测（R3）。
- **位置**：[MedicationFoodTimingAdvisor.swift:108–131](Packages/AssistantCore/Sources/AssistantCore/MedicationFoodTimingAdvisor.swift#L108)（`.afterMeal` 两个分支）、[120](Packages/AssistantCore/Sources/AssistantCore/MedicationFoodTimingAdvisor.swift#L120)（不可达分支）、[175–186](Packages/AssistantCore/Sources/AssistantCore/MedicationFoodTimingAdvisor.swift#L175)（`.beforeMeal` 不看 `recentMeal`）。
- **代码证据**：
  ```swift
  if now >= meal.date && now <= windowEnd {        // :108 windowEnd = meal + minutes + 30min
      ... headline: "✨ 餐后黄金用药窗口" ...
  } else if now < meal.date.addingTimeInterval(Double(minutes) * 60) {   // :120 永远为假
      ... headline: "用餐完毕 · 等待最佳饭后时机" ...
  }
  ```
  `recentMeal` 已过滤 `date <= now`，所以 `now >= meal.date` 恒成立；而 `bestTime = meal + minutes` 必然 ≤ `windowEnd`。于是 `else if now < bestTime` 从构造上不可能成立——**「刚吃完、建议稍等 X 分钟」这条提示永远不会出现**，整段 [120–131](Packages/AssistantCore/Sources/AssistantCore/MedicationFoodTimingAdvisor.swift#L120) 是死代码。此外 `.beforeMeal` 分支（:175）完全不检查 `todayMeals`。
- **触发条件与实测**（R3：`now=12:00`，午餐 11:55 结束即 5 分钟前）：
  - `afterMeal(minutes: 30)` → `✨ 餐后黄金用药窗口（刚享用 牛肉面）`，提示「建议在 12:55 前温水送服」——即让人**立刻**吃药，而计划语义是饭后 30 分钟；`adaptiveNotificationTime` 却是 12:25，文案与调度自相矛盾。
  - `afterMeal(minutes: 30)` + 刚吃完 1 分钟 → 同样判为「黄金窗口」。
  - `beforeMeal(minutes: 30)` + 刚吃完 5 分钟 → `⏰ 饭前最佳服药时间（空腹吸收）`，提示「请空腹温水送服」——刚进食完仍建议空腹服药。
- **用户影响**：健康指引类文案与实际时点矛盾。对「饭后服用以减少胃刺激/饭后 30 分钟吸收」的药，用户会被引导提前服用；对「饭前空腹」的药，用户刚吃完饭也会被提示空腹服。属于特定场景下的正确性问题（不直接影响数据落库，但影响用户服药行为）。
- **修复建议**：
  ```swift
  if now < bestTime {
      // 刚吃完，等待最佳时机（放在黄金窗口判定之前）
      return MedicationTimingEvaluation(... headline: "用餐完毕 · 等待最佳饭后时机",
                                        adaptiveNotificationTime: bestTime)
  }
  if now <= windowEnd { ... 黄金窗口 ... }
  ```
  `.beforeMeal` 增加「近 30–60 分钟内吃过饭 → 提示与本计划冲突，建议顺延到下一次或确认医嘱」分支；并给 `evaluate` 补「同一计划多时点」的组合用例。
- **验证方式**：`MedicationFoodTimingAdvisorTests` 补「刚吃完 1/5 分钟」「饭前计划 + 刚吃完」三条（现有用例只覆盖了窗口内/外与漏服）；探针已确认修复前行为（R3）。

---

## CORE-05 · P2 · `SearchIndexEngine` 倒排索引只写不读，搜索退化为每次按键 O(N) 全表

- **状态**：确认（代码路径闭合 + app 调用点核对）。
- **位置**：[SearchIndexEngine.swift:165](Packages/AssistantCore/Sources/AssistantCore/SearchIndexEngine.swift#L165)（`tokenIndex` 声明）、[220–236](Packages/AssistantCore/Sources/AssistantCore/SearchIndexEngine.swift#L220)（只写/重建）、[321–326](Packages/AssistantCore/Sources/AssistantCore/SearchIndexEngine.swift#L321)（`search` 取全量文档）、[239–317](Packages/AssistantCore/Sources/AssistantCore/SearchIndexEngine.swift#L239)（`scoreSingleTerm` 每次对 title/keywords/subtitle/content 做 `lowercased()`）。
- **代码证据**：
  ```swift
  // 写入侧（:220-227）——建了完整倒排索引
  for token in tokens { tokenIndex[token.lowercased(), default: []].insert(doc.id) }
  // 读取侧（:326）——从不查 tokenIndex
  let allDocs = Array(documents.values)          // 每次搜索复制全部文档结构体
  for doc in allDocs { ... scoreSingleTerm(...) } // 对每篇文档逐字段 contains
  ```
  `grep tokenIndex` 只有声明、`clear()`/`rebuildTokenIndex()` 的 `removeAll`、以及 `indexDocTokens` 的写入，**没有任何读取**。索引占内存（10 万级 token → Set<String>），却零收益；`remove(ids:)`(:191) 还会全量 `rebuildTokenIndex()`（O(N) 重新分词 + CFStringTransform 拼音解析）。
  app 侧调用点确认这是热路径：`Assistant/Features/TodoListView.swift:592` 在 view builder 里直接调 `engine.search(query: trimmed, limit: 4)`（输入框每敲一个字都会执行）；`UnifiedSearchView.swift:363` 有 120ms 防抖但仍全表扫描。
- **触发条件**：待办/账目等数据量大（`todo.md` 已有「万件待办」基线）+ 用户在首页搜索框输入。
- **用户影响**：搜索每次按键 O(N) 全表 + 每文档 4 次 `lowercased()` 分配；万件量级会明显掉帧。索引内存白占，移除条目时还有 O(N) 重建卡顿。
- **修复建议**：
  ```swift
  // search(): 先用 tokenIndex 求候选集，再打分
  let queryTokens = PinyinHelper.extractSearchTokens(text: trimmed)
  var candidates = Set<String>()
  for t in queryTokens { candidates.formUnion(tokenIndex[t] ?? []) }
  let docs = candidates.compactMap { documents[$0] }   // 只对候选打分
  ```
  若短期不想改行为，至少删掉 `tokenIndex` 与 `rebuildTokenIndex`（省内存与删除卡顿），并在类型注释里如实写明「线性扫描」；但既然已经维护索引，用起来收益更大。另外 `search` 里 `Array(documents.values)`(:326) 应改为在锁内只取候选 id 的数组，避免每次复制 N 个含多个 String 的结构体。
- **验证方式**：`SearchIndexEngineTests` 补 1 万文档基准测试（测量 `search` 耗时，当前实现应在毫秒级偏上）；断言「tokenIndex 命中数 == 候选文档数」以证明索引真的被使用；`swift test --filter SearchIndexEngineTests`。

---

## CORE-06 · P2 · 热量估算热路径：每次调用最多重编译 10 条正则 + 全表别名小写化

- **状态**：确认。探针实测（R4）。
- **位置**：
  - [FoodCalorieEstimator.swift:2184–2383](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2184)（`parseDetailedQuantity` 内 7 处 `try? NSRegularExpression(pattern:)`：糖度循环 [2227](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2227)、冰度 [2240](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2240)、重量 [2260](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2260)、复合半量 [2288](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2288)、数量 [2303](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2303)、纯数字 [2317](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2317)、尾随量 [2333](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2333)，另有 4 处 `replacingOccurrences(.regularExpression)`）+ [2012–2034](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2012)（`estimateMeal` 内 2 处 `replacingOccurrences(.regularExpression)`（:2012/:2017）与 2 处 `try? NSRegularExpression`（:2026/:2034））。
  - [FoodCalorieEstimator.swift:964–1006](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L964)（`items(matchingName:)` / `item(matchingNameStrict:)` 全表线性扫描，且每次调用对每条目的每个别名做 `lowercased()`）。
  - 包内已有缓存工具未复用：[Regex.swift:5–19](Packages/AssistantCore/Sources/AssistantCore/Regex.swift#L5)（`NSCache` 编译缓存）。
- **代码证据**（实测数据，macOS arm64 / `swiftc -O`，见 R4）：
  - `FoodCatalog.items(matchingName:)`：**≈476 µs/次**（208 条目 × ≈2000 个别名，每次全部 `lowercased()`）。
  - `FoodCalorieEstimator.parseDetailedQuantity(from:)`：**≈85 µs/次**；单次 `NSRegularExpression(pattern:)` 编译实测 ≈14.5 µs，该函数每次调用最多编译 10 条（糖度 5 + 其余 5），另有 4 次 `replacingOccurrences(.regularExpression)`。
  - `estimateMeal(fromHint:)`：**≈1313 µs/次**（800 次 1050 ms）。
  - 调用链：`estimateMeal` 对每个菜品片段最多调 4 次名称查找（`:2047–2050`：strict→loose→strict(part)→loose(part)），且每片段先过 `parseDetailedQuantity`。
- **触发条件**：照片识别后的整餐估算、一句话饮食记录（`MemoCapabilityProvider` / `FoodCapabilityProvider` / `OmniboxPlanner`）、饮食详情的重新估算。
- **用户影响**：单次估算 1.3 ms（Mac 上；iPhone 慢 2–4 倍），多道菜时线性放大；用户侧感知是拍照识别/语音记账后的明显停顿。这不是致命错误，但属于「每次调用都重复做本可一次做完的事」。
- **修复建议**：
  1. 给 `FoodCatalog` 建一次性索引（`private static let` 惰性初始化，O(1) 查找）：
     ```swift
     private static let byID: [String: FoodItem] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
     private static let byLowerName: [String: FoodItem] = { /* name/nameEn/aliases 小写 → 条目 */ }()
     private static let loweredAliases: [(alias: String, item: FoodItem)] = items.flatMap { item in
         item.aliases.map { ($0.lowercased(), item) }
     }
     public static func item(id: String) -> FoodItem? { byID[id] }
     public static func items(matchingName name: String) -> [FoodItem] { /* 先查 byLowerName，再退化成"包含"扫描 */ }
     ```
  2. 把 `parseDetailedQuantity` 里的正则全部提为 `private static let`（或用现成的 `Regex.compile`），不要再在函数体内 `try? NSRegularExpression(...)`。
  3. `estimateMeal` 里 4 段 `??` 链改为：先 `parseDetailedQuantity`，再只做一次 `matchFood(queryName)`（strict 内部已包含 loose 兜底时再退）。
- **验证方式**：加性能闸测试（`measure`）固定「1 千次 `items(matchingName:)` < X ms」；用修复前的探针（R4）作基线对比。功能回归用现有 `FoodCalorieEstimatorTests` + `FoodLLMOutputParserTests`。

---

## CORE-07 · P2 · Swift 6 严格并发未就绪：2 处 static 非 Sendable 缓存 + Package 仍是 5.10

- **状态**：确认（用 `-strict-concurrency=complete` 实编译复现，见 R5）。
- **位置**：
  - [Package.swift:1](Packages/AssistantCore/Package.swift#L1)：`// swift-tools-version:5.10`，target 无 `swiftSettings`、无 `swiftLanguageMode(.v6)`、无 `.enableUpcomingFeature("StrictConcurrency")`。
  - [Regex.swift:5](Packages/AssistantCore/Sources/AssistantCore/Regex.swift#L5)：`private static let cache = NSCache<NSString, NSRegularExpression>()`。
  - [WebDAVModels.swift:265](Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift#L265)：`private static let iso8601Formatter: ISO8601DateFormatter`。
  - 需要保留评审的手写逃逸：[SearchIndexEngine.swift:162](Packages/AssistantCore/Sources/AssistantCore/SearchIndexEngine.swift#L162)（`@unchecked Sendable`，内部 `NSLock` 覆盖全部读写，已逐项核对，可保留）；[CapabilityRegistry.swift:76–93](Packages/AssistantCore/Sources/AssistantCore/Plugins/CapabilityRegistry.swift#L76)（`GrammarCache` 同样用锁，实现正确）。
- **代码证据**（R5 实测，Xcode 工具链、`swift build -Xswiftc -strict-concurrency=complete`）：
  ```
  Regex.swift:5:24: warning: static property 'cache' is not concurrency-safe because non-'Sendable' type
                       'NSCache<NSString, NSRegularExpression>' may have shared mutable state;
                       this is an error in the Swift 6 language mode [#MutableGlobalVariable]
  WebDAVModels.swift:265:24: warning: static property 'iso8601Formatter' is not concurrency-safe because
                       non-'Sendable' type 'ISO8601DateFormatter' may have shared mutable state;
                       this is an error in the Swift 6 language mode [#MutableGlobalVariable]
  ```
  除这两处外全包无并发警告（`Calendar.current` 13 处、`DateFormatter` 3 处、`await`/`Task` 仅 `ExpenseCurrency.refreshOnlineRates`），说明**包体本身已接近就绪，缺的是开关与这两处修法**。另：`ExpenseCurrency.refreshOnlineRates`(:224) 在「纯逻辑包」里做了网络 I/O 并写 `UserDefaults`，与包注释「纯逻辑、可在 macOS 直接 swift test」的定位相冲突，迁移时可一并挪到 Services 层（此刻不影响正确性）。
- **触发条件**：升级到 Swift 6 语言模式（Xcode 16+ 的 `swiftLanguageMode(.v6)`，或 tools-version 6.x）时编译失败；当前 5.10 模式下完全静默。
- **用户影响**：不直接产生线上故障（两处运行期实际线程安全：`NSCache` 线程安全、`NSRegularExpression` 不可变；`ISO8601DateFormatter` 无官方线程安全承诺），但阻塞语言模式升级；且 `ISO8601DateFormatter` 的共享实例若被并发格式化，属于**未定义行为**，是潜在的数据竞态。
- **修复建议**：
  ```swift
  // 方案 A（推荐，零共享可变状态）：Foundation 的 FormatStyle 是 Sendable
  private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  // 方案 B（保留实例）：用带锁的 Sendable 盒子
  private final class FormatterBox: @unchecked Sendable {
      private let lock = NSLock(); private let formatter = ISO8601DateFormatter()
      func string(from d: Date) -> String { lock.lock(); defer { lock.unlock() }; return formatter.string(from: d) }
  }
  // Regex.cache 同理：`private final class RegexCache: @unchecked Sendable { let lock; var storage }`
  ```
  然后在 `Package.swift` 加 `swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]`（或迁到 tools-version 6 + `.swiftLanguageMode(.v6)`），并把 `swift build -Xswiftc -strict-concurrency=complete` 接进 `scripts/ci.sh`，防止回退。
- **验证方式**：R5 命令在修复后应 0 warning；再加一条 CI 步骤（`swift build ... -strict-concurrency=complete 2>&1 | grep -q "warning:" && exit 1`）。

---

## CORE-08 · P3 · 中文数字解析 4 份重复实现，语义不一致

- **状态**：确认（静态 + 探针）。
- **位置**：
  - [ExpenseAmountExtractor.swift:162](Packages/AssistantCore/Sources/AssistantCore/ExpenseAmountExtractor.swift#L162)（`numberValue`：支持十/百/千/万，非法返回 `nil`）
  - [FoodCalorieEstimator.swift:2385](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2385)（`parseChineseQuantity`：只支持十，**无法解析时返回 1.0**）
  - [SkillPathPlanner.swift:664](Packages/AssistantCore/Sources/AssistantCore/SkillPathPlanner.swift#L664)（`numericValue`：十的写法另有一套，「两」「半」特判）
  - [QueryInsightEngine.swift:426](Packages/AssistantCore/Sources/AssistantCore/QueryInsightEngine.swift#L426)（`parseChineseNumber`：只支持 1–99，超出返回 nil）
- **代码证据**：四份实现各自维护 `digits` 字典；对「半」：前者特判 0.5 / 2，`numberValue` 把「半」交给 `Double` 失败后返回 nil；对未知输入：`parseChineseQuantity` 返回 `1.0`（静默当成一份），另三处返回 nil。行为差异可实测：「近一百天」在 `QueryInsightEngine` 返回 nil（`百` 不在其字典）→ 时间范围解析直接失败；同一字符串在 `ExpenseAmountExtractor.numberValue` 返回 100；「半半」在 `parseChineseQuantity` 返回 1.0 而非 0.5/nil。
- **触发条件**：任何中文数字输入遇到各实现未覆盖的写法（百/千/万、半、零）。
- **用户影响**：同类输入在「记账金额」「食物份量」「技能计划周期」「查询时间范围」四处给出不同结果；修一处 bug 不会传导到另一处（本次 CORE-02 就是只在记账那份里暴露）。
- **修复建议**：在 Core 新增 `ChineseNumeralParser.value(_:) -> Double?`（统一支持 `零/〇/一…九/十/百/千/万/两/半`，未知一律返回 `nil`，由调用方给默认值），四处改为转发；`parseChineseQuantity` 的 `return 1.0` 改为返回 nil 并在调用处 `?? 1.0`，让「静默」变成显式的调用方决策。
- **验证方式**：新文件配表驱动单测（同一批输入跑四个入口，断言统一结果）；`grep -c "digits: \[Character"` 应从 4 降到 1。

---

## CORE-09 · P3 · `estimateMeal` 按 food.id 去重静默丢菜；无分隔符多菜只取第一道

- **状态**：确认。探针实测（R4）。
- **位置**：[FoodCalorieEstimator.swift:2046–2056](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2046)（`seen` 去重）、[2031–2041](Packages/AssistantCore/Sources/AssistantCore/FoodCalorieEstimator.swift#L2031)（分隔符拆分的边界插入只处理「数量词边界」）。
- **代码证据**：
  ```swift
  var seen = Set<String>()          // :2045
  ...
  if !seen.contains(food.id) {      // :2055 同 id 第二道菜直接丢弃（不累加数量、不提示）
      seen.insert(food.id)
  ```
- **触发条件与实测**（R4）：
  | 输入 | 实际 | 说明 |
  | --- | --- | --- |
  | 两个包子一个肉包 | 包子 414 kcal（只算一份） | 肉包是同一 `steamed_bun` 的别名，第二道被丢 |
  | 两个包子一碗粥一个肉包一杯豆浆两个鸡蛋 | 4 道菜，缺第二份包子 | 同上 |
  | 米饭红烧肉青菜 | **只有米饭 195 kcal** | 无标点/空格时 `estimateMeal` 不做中文分词，只命中第一道 |
  | 米饭250克红烧肉150克 | 米饭 195 + 红烧肉 1025 | 有「数量词边界」才被切开 |
- **用户影响**：整餐热量被系统性低估（少一份约 200 kcal / 少两道菜）。界面上不会提示「有 N 个片段没匹配上」，用户以为估算已包含全部。
- **修复建议**：同 id 时**合并数量**而不是丢弃（`matchedDishes` 用 `[foodID: FoodDishEstimate]` 累积 `multiplier`/`explicitGrams`）；对「未匹配到食物的片段」返回 `unmatchedHints: [String]` 供 UI 提示「这些没认出来」。注意去重本意是防「米饭/白米饭」这类同义重复，合并数量可以同时满足两个目的。
- **验证方式**：`FoodCalorieEstimatorTests` 补上表 4 行；断言总热量与 `unmatchedHints`。

---

## CORE-10 · P3 · 测试缺口与断言过弱（CORE-01/02/03/04 逃逸的直接原因）

- **状态**：确认（对照测试文件逐条核对）。
- **位置与缺口**：
  1. [ExpenseAmountExtractorTests.swift:91–98](Packages/AssistantCore/Tests/AssistantCoreTests/ExpenseAmountExtractorTests.swift#L91) 的「口语金额」组只覆盖**阿拉伯数字**分位（`咖啡35块5毛`、`中石化…三百二十八块五毛` 用的是「加了」——恰好不在动词表里，所以走 spoken 分支）。中文分位「X块五毛」、中文小数「X点五」、口语省略「三百五」**零覆盖** → CORE-01/02 无防线。
  2. [ReceiptTextParserTests.swift:95–99](Packages/AssistantCore/Tests/AssistantCoreTests/ReceiptTextParserTests.swift#L95)：日期用例全部 `XCTAssertNotNil`，不校验年月日时，也不注入 `now` → CORE-03 无防线。
  3. [MedicationFoodTimingAdvisorTests.swift](Packages/AssistantCore/Tests/AssistantCoreTests/MedicationFoodTimingAdvisorTests.swift)：未覆盖 `afterMeal` + 「刚吃完 N 分钟」场景 → CORE-04 的死分支存活至今。
  4. [LifeEventTaskPlanningEngine.swift:600–601](Packages/AssistantCore/Sources/AssistantCore/LifeEventTaskPlanningEngine.swift#L600) 注释写「长度过滤：5~80 字之间」，代码是 `>= 4 && <= 100`；同一函数另一处（:623）是 `>= 6 && <= 80`。三套阈值并存，注释已漂移。
- **用户影响**：不是运行时缺陷，但正是「金额静默错账」「日期错年」这类最高代价缺陷能通过 1112 条测试的原因。
- **修复建议**：CORE-01/02/03/04 每条修复时同步补上报告里给出的用例；另加一条「等值断言优先」的评审规则（日期/金额/热量一律断言精确值，禁止只写 `XCTAssertNotNil`）。
- **验证方式**：`swift test --disable-sandbox`（当前 1112 项全绿、2.6s，见 R0；补用例后应 >1120）。

---

## CORE-11 · P3 · `SafeToSpendResult.==` 自定义实现忽略 9 个字段

- **状态**：疑点（当前仓内未发现 `==` 被用于 UI 刷新判断；属潜在风险 + 测试陷阱）。
- **位置**：[SafeToSpendCalculator.swift:122–134](Packages/AssistantCore/Sources/AssistantCore/SafeToSpendCalculator.swift#L122)。
- **代码证据**：自定义 `==` 只比较 `isEnabled / safeToSpendToday / todayAllowance / todayFlexibleSpend / todaySpentRatio / savedYesterday / daysLeft / isOverBudget / isTodayOverspent / rhythmMode / isWeekend`，**不比较** `disposableBudget`、`remainingThisMonth`、`daysInMonth`、`todayOverspentAmount`、`spentRatio`、`workdayAllowance`、`weekendAllowance`、`weekendReservoirTotal`、`rhythmAdviceText`（共 19 个字段里的 9 个）。
- **触发条件**：任何 `XCTAssertEqual(resultA, resultB)` 或将来 `onChange(of: result)` / `EquatableView` 用整值比较的调用。当前测试是逐字段断言，所以尚无实际表现；但「预算超支金额/本月剩余/工作日基准额度」正是安心花卡片的核心数字。
- **用户影响**：若把该 `==` 用于 SwiftUI 刷新判断，这些字段变化不会触发重绘（卡片显示旧数字）；用于测试则会让这几项的回归静默通过。
- **修复建议**：删除自定义 `==`，用编译器合成（`Double` 精度问题在测试里用 `XCTAssertEqual(_:_:accuracy:)` 解决；本文件此前的自定义实现只会掩盖差异）。如果确实需要「近似相等」语义，就显式提供 `isApproximatelyEqual(to:)` 而不要重载 `==`。
- **验证方式**：补一条测试：仅改动 `remainingThisMonth` / `workdayAllowance`，断言两个结果**不相等**（修复前会失败）。

---

## CORE-12 · P3 · WebDAV 目录 URL 双重编码；裸文件名相对 href 被拒

- **状态**：确认。探针实测（R6）。
- **位置**：[WebDAVModels.swift:79–95](Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift#L79)（`makeDirectoryURL` 对整个 serverURL 做 `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`）、[107–152](Packages/AssistantCore/Sources/AssistantCore/WebDAVModels.swift#L107)（`makeFileURL(fromHref:)` 的相对路径分支）、[WebDAVTests.swift:139–160](Packages/AssistantCore/Tests/AssistantCoreTests/WebDAVTests.swift#L139)（现有 href 用例）。
- **代码证据**（R6）：
  | 输入 | 输出 | 问题 |
  | --- | --- | --- |
  | serverURL `https://nas.local/my%20folder`，dir `backup` | `https://nas.local/my%2520folder/backup` | 已编码的 `%20` 被二次编码成 `%2520` → 404 |
  | serverURL `https://nas.local/dav/my folder` | `…/dav/my%20folder/backup` | 正常 |
  | href `a.zip`（相对文件名） | **nil** | 注释（:112–118）承诺「只承认三种情况——相对路径、…」，但裸文件名相对 href 会被目录归属检查拒绝 |
  | href `/dav/AssistantBackups/a.zip` | 正常 | 正常的 path-absolute 形态，符合 RFC 4918，主流 NAS 都这么返回 |
- **触发条件**：用户从浏览器地址栏复制已编码的 WebDAV 地址；或服务端返回相对文件名 href（非 RFC 严格但存在于部分实现）。
- **用户影响**：前者表现为「连接测试失败/列表 404」，错误信息只显示通用失败，用户无从排查（改地址也改不对）；后者是当前被安全地拒绝（不会泄漏凭据），但注释承诺的能力没有兑现，且无测试固定这一行为。
- **修复建议**：
  ```swift
  // makeDirectoryURL：先按原样解析，只在解析失败/含非法字符时才补转义，避免二次编码
  let normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
  let withScheme = normalized.hasPrefix("http") ? normalized : "https://" + normalized
  guard var base = URL(string: withScheme)
      ?? withScheme.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap(URL.init(string:)) else { return nil }
  ```
  同时把 href 分支的接受规则明确成两种并写进注释/测试：`path-absolute`（必须落在目录内）与「裸文件名相对 href」→ `dirURL.appendingPathComponent(lastSegment)`（只取最后一段，天然无遍历风险）。
- **验证方式**：`WebDAVTests` 补 `resolveHref("a.assistantbackup")`（期望非 nil）与 `makeDirectoryURL(serverURL: "https://nas.local/my%20folder")`（期望不出现 `%2520`）两条；R6 探针可复现修复前行为。

---

## 实测记录（可复现）

> 全部为本轮一次性真实执行；探针仅读取源文件编译，未改动仓库内任何文件。

**R0 · 基线测试**（`Packages/AssistantCore`）：
```
swift test --disable-sandbox
→ Executed 1112 tests, with 0 failures (0 unexpected) in 2.614 (2.721) seconds
```

**R1 · 金额提取探针**（`ExpenseAmountExtractor.swift` 单文件 + `main.swift`，`swiftc -O`）：
```
花了三百二十八块五毛 -> 328.0     花了九块五毛 -> 9.0     花了九毛五 -> 9.0
花了九点五元 -> 9.0              打车十二点五元 -> nil    午饭三十八点五元 -> nil
一千五 -> 1005   三百五 -> 305   一万五 -> 10005   一千零五 -> 1005   三百零五 -> 305
```

**R2 · 小票日期探针**（`ReceiptTextParser.swift` 单文件 + 注入 `now=2025-01-02 09:00`）：
```
parse("12月25日 18:30 消费 88元", now: 2025-01-02) -> 2026-12-25 18:30
2024-02-31 10:00 -> 2024-03-02 10:00
2024-13-45 10:00 -> 2025-02-14 10:00
2024-06-15 25:99 -> 2024-06-16 02:39
```

**R3 · 用药时效探针**（`MedicationFoodTimingModels.swift` + `MedicationFoodTimingAdvisor.swift`，`now=12:00`，午餐 5 分钟前）：
```
[饭后30分钟, 刚吃完5分钟] headline=✨ 餐后黄金用药窗口（刚享用 牛肉面）
                          tip=建议在 12:55 前温水送服；notifyAt=12:25
[饭后30分钟, 刚吃完1分钟] headline=✨ 餐后黄金用药窗口；notifyAt=12:29
[饭前30分钟, 刚吃完5分钟] headline=⏰ 饭前最佳服药时间（空腹吸收）；tip=请空腹温水送服
```

**R4 · 食物估算性能/行为探针**（链接 `swift build` 产物，`swiftc -O`）：
```
catalog size: 208
estimateMeal x800:            1050.1 ms  → 1312.6 µs/次
FoodCatalog.items(matchingName:) x2000: 953.0 ms → 476.5 µs/次
FoodCatalog.item(id:) x2000:        0.5 ms
parseDetailedQuantity x2000:      170.8 ms → 85.4 µs/次
NSRegularExpression 编译 x2000（同类 pattern）: 29.0 ms → 14.5 µs/条
两个包子一个肉包 -> dishes: 包子 414.0（第二份被去重丢弃）
米饭红烧肉青菜   -> dishes: 米饭 195.0（另两道未匹配、无提示）
```

**R5 · 严格并发构建**（`swift build --disable-sandbox --scratch-path /tmp/… -Xswiftc -strict-concurrency=complete`）：
```
Regex.swift:5:24        static property 'cache' is not concurrency-safe ... error in Swift 6 language mode
WebDAVModels.swift:265  static property 'iso8601Formatter' is not concurrency-safe ... error in Swift 6 language mode
Build complete!（其余 0 warning）
```

**R6 · WebDAV URL 探针**（链接 `AssistantCore`）：
```
makeDirectoryURL("https://nas.local/my%20folder", "backup") -> https://nas.local/my%2520folder/backup
makeFileURL(fromHref: "a.zip", serverURL: "https://nas.local", remoteDirectory: "dav/AssistantBackups") -> nil
makeFileURL(fromHref: "/dav/AssistantBackups/a.zip", ...) -> https://nas.local/dav/AssistantBackups/a.zip
```

## 未覆盖 / 边界说明

- 本轮不跑完整 `xcodebuild`；`swift test` 已按任务要求用 `--disable-sandbox` 且只跑一次（2.6s）。
- 未覆盖的 Core 模块（时间原因，按风险排序留待下一轮）：`SleepReminderPlanner`(777)、`DietaryPreference`(764)、`TrendAnalytics`(763)、`SkillPathPlanner`(724)、`PleasureIndexEvaluator`(670)、`PsychExportFormatter`(572)、`PsychChannelMerger`(568)、`HealthMetrics` 的生命体征判定、`PeriodReportAnalytics`/`ReportPeriodWindow` 的跨年窗口、`WebDAVXMLParser` 的 `getlastmodified`（只认 RFC1123 与「带小数秒」的 ISO8601，服务器返回无小数秒 ISO8601 时 `lastModified` 会为 nil，未实测影响面）。
- 「重复/可合并同族实现」除 CORE-08（中文数字）外，还发现：`ParcelMatcher` 与 `RuleEngine` 各自维护快递/取件码正则、`ReceiptTextParser` 与 `ExpenseAmountExtractor` 各自维护金额正则族。因未确认会造成行为漂移，本轮未单列条目，建议下一轮以「把金额/快递正则收敛到单出口」为一个专项。
- 所有结论均为静态+探针确认，未做真机 UI 级验证；CORE-03/04 的用户可见表现（月报错月、用药提示文案）需真机或 UI 测试确认。
