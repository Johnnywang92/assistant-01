# 增量复核与 P0 修复记录（2026-11-06）

> 基线：`main` @ `022ad34`（工作树干净）。本轮改动 23 个既有文件 + 新增 1 个脚本，未提交。
> 上游：[README.md](README.md)（2026-11-05 全景审计，64+5 条）。
> 范围：从 **UI / 交互 / 视觉规范落地**这条线切入；数据层与架构层昨轮已全覆盖且大部分已修，本轮不重复扫。
> 本轮四件事：① 三条悬案定性 ② 台账与当前代码核对 ③ 设计侧增量扫描 ④ P0 修复 + 全链路验证。

---

## 一、三条「待验证疑点」定性

| 疑点 | 结论 | 证据 | 后续 |
| --- | --- | --- | --- |
| `.onChange(of: @Model 数组)` 是否响应属性级编辑 | **大概率不触发**（高置信静态判断） | `TodoListView.swift:496`、`LifeVaultView.swift:731` 依赖数组 `==`；全仓 `static func ==` 零命中 → `@Model` 默认按 `persistentModelID` 比较，而排序键只有 `sortOrder/createdAt/date`，改标题/金额/到期日不改数组相等性。例外：改 `FoodIntakeRecord.date` 会重排从而触发 | 改订阅显式变更令牌；**仍需一次 Debug 打点实测坐实**（App 层零测试 target，1134 项 Core 测试不覆盖 SwiftData） |
| `PeriodicReportView` 指纹只覆盖前 30 条是否致缓存陈旧 | **确认会陈旧** | `PeriodicReportView.swift:15/:20` 两处 `fetchLimit=30`，`dataFingerprint`（:61-75）只哈希 `id+amount` / `id+status+completedAt`；`PeriodicReportManager.generateReport` 仍 5 次全表 fetch。改 3 个月前旧账目 / 分类 / 日期均不失效 | 指纹改为全量变更令牌 |
| `HabitAndMedicationScheduler(context:)` 重复构造是否有副作用 | **可关闭** | `init`（:24-30）只赋值 context，无重排/观察者；`HabitAndMedicationView` 3 次构造（:243/:560/:1107）全在事件处理、不在 body。报告记的 :221/:532/:1069 是改前基线 | 无需处理 |

---

## 二、台账与当前代码不一致（4 条，已在 README 文首与正文条目就地订正）

| # | 报告记录 | 当前实测 | 处理 |
| --- | --- | --- | --- |
| 1 | 第十节 L-04「已删除 `ExpenseShareView` 60 行」 | `ExpenseTrackerView.swift:2651` 仍有该零引用实现（全仓仅 1 处命中），`git log -S` 未见删除提交 | 本轮已删除；它内含的「附原始单据」Toggle 能力接回 `ExpenseCardShareSheet` |
| 2 | UI-02「7 弹窗 / toast 三套时长」 | 实际 **10 个弹窗 / 5 套时长**（2.0 / 2.4 / 2.5 / 3.0 / 无延时）；漏 `TodoShareSheet`、`ExpenseAASplitSheet`、`NearbyInteractionSheet` | 更新口径，P1 骨架统一收益上调 |
| 3 | `ui-findings.md` UI-03 表把 547 行标成 `AddOrEditStoredItemSheet` | 真身是 **`MedicineEditorSheet`**（`ItemStorageVaultView.swift:1739-2285`）；`AddOrEditStoredItemSheet` 实测 273 行 | UI-03 表格对象名就地更正为 `MedicineEditorSheet`，拆分方案第 1 条同步改指向，避免按错名字排期 |
| 4 | 无障碍缺口按固定 7 行窗口估 104 处 | 括号配平实测 **73 处 / 37 文件**（104 含已标注按钮的误报） | 本轮补 26 处 + 闸门，存量 47 处按文件基线锁定 |

> 订正策略（2026-11-06 补充）：**正文表格与排期章节就地更正**，原值以括注保留，另在文首留订正段说明来龙去脉。只加注记而不改正文的话，扫描式阅读的人仍会按旧数字/旧对象名排期，因此本轮把错误值直接改对；历史原值仍全程可追溯。

---

## 三、设计侧增量发现（报告零覆盖或覆盖不足）

| 项 | 实测口径 | 典型证据 |
| --- | --- | --- |
| 纯图标按钮不可读 | Button 848 / `Image(systemName:)` 653+，`accessibilityLabel` 58、`accessibilityHint` 13、`.isButton` trait 3；**73 处**纯图标无标签 | `UnifiedSearchView.swift:118/225`（xmark 点击区 <44pt）、`AppLockView.swift:76/91/307`、`PetRecordsView.swift:50` |
| 本地化漏译是另一层问题 | `Text("中文")` **1133 行** vs 本地化调用 **512 行**；`L10n.tr` 以中文原文作 key，未走 tr 者英文模式直接漏译 | `FoodPhotoCalorieView` 94 / `ExpenseTrackerView` 63 / `PeriodicReportView` 56。与 PLT-07 的 xcstrings 缺键**不是同一层** |
| 动态字体零改造 | `.font(.system(size: 9~12)` 203 处，剔除位图类后仍有 **64 处真实文本**；`@ScaledMetric` **0** | `MentalHealthView.swift:427` 10pt 叠 `.lineLimit(1)`，AX5 下必截断 |
| 壁纸/深色可读性无兜底 | `wallpaperReadableText()` 全仓仅 **3** 次调用；`Color.white/.black` 156 + `.foregroundStyle(.white/.black)` 104 | `PeriodicReportView` 已算 `isCustomThemedBackground` 却只给 `Color.clear`；`MainTabView.swift:80/83` 白字压渐变 |
| 令牌闸门只管圆角 | 圆角做得好：`AppRadius` 508 处、字面量仅 3 处。但间距 **2850 处字面量 vs `AppSpacing` 238**、52 处 `.shadow` 全字面量，扩展 target 不在 `SCAN_DIRS` | 建议扩成 `check_design_tokens.py` |
| 反馈一致性 | 98 处延时散在 **39 种时长**（2.0~8.0s）、520 处 `Haptic` 无统一门控、31 个含 `@Query` 的列表中 4 个无空态 | 同一 App 各处手感不一致 |

---

## 四、本轮 P0 改动（逐条 + 验证步骤）

### P0-1 记账分享死代码与 `includeReceipt` 死状态
- `ExpenseTrackerView.swift`：删除 `ExpenseShareView`（原 :2651-2710，60 行，零引用），留注释说明能力迁移去向。
- `ExpenseShareCardView.swift`：在卡片与按钮组之间新增「附带原始单据 / 小票」Toggle，仅当 `record.receiptImageData != nil` 出现；绑定 `$includeReceipt`，用 `AppColor.surface` / `AppRadius.banner` / `AppSpacing`。此前 `shareViaSystem()`（:330-333）里附加原始图片的逻辑因状态恒 false 从不生效。
- **验证**：真机对一笔带小票照片的账单 → 打开分享弹层 → 打开开关 → 点「直接发送到社交平台」→ 系统分享面板应同时出现卡片图与原始小票图；关闭开关只剩卡片图；「保存至相册」不受开关影响。

### P0-2 早间逾期整理卡「假状态」
- `TodoListView.swift`：抽出 `todayTriageKey`；`maybePresentOverdueTriage()` 不再提前写 `lastTriageDateKey`，改为在 `.sheet` 内容的 `.onAppear` 里写；延时闭包补 `guard lastTriageDateKey != key` 防重复。
- 旧行为：先写键再延时 0.9s 弹层，若转场被别的 sheet 抢占或用户切 Tab，弹层没出现但当天已被标记「已整理」→ 整天不再提醒。
- **验证**：造一条逾期待办 → 冷启动进首页，在 0.9s 内立刻切到别的 Tab 再切回 → 整理卡仍应弹出；正常弹出并关闭后，当天再进首页不应重复弹。

### P0-3 健康指标卡强解包
- `HealthDataView.swift:567`：`effectiveSnapshot ?? health.snapshot!` → `?? HealthDaySnapshot(day: .now, values: [:])`。空快照让 `HealthMetrics.progress` 自然产出全 `.noData`，既不崩也不把「没读到」渲染成 0 步（项目红线）。
- **验证**：iPad 或健康数据未授权/未读取状态下打开健康页 → 指标卡应显示「暂无数据」，不崩溃、不出现精确 0 值。

### P0-4 图标按钮无障碍
- `Assistant/Theme/AppTheme.swift`：新增 `iconButton(_:hint:)` 统一修饰器，一次补齐 `accessibilityLabel`、44×44 最小点击区、`.contentShape(Rectangle())` 与 `.isButton` trait。
- 19 个高频页面补 **26 处**，`label` 按实际上下文逐条人工指定（刷新索引、删除最近搜索、面容 ID 解锁、上一期报告…），未做图标名自动推断。
- 新增 `scripts/check_icon_button_a11y.py`：括号配平识别「label 块内只有 `Image(systemName:)`」的 Button，链式修饰器归属判定（修掉了早期版本把相邻按钮的 `.iconButton` 误算到前一个的漏洞），存量按文件基线 `BASELINE` 锁定、**只降不升**，支持 `--audit` / `--print-baseline` / `gate:icon-a11y` 行内豁免。已接入 `scripts/ci.sh`。
- **验证**：`python3 scripts/check_icon_button_a11y.py` → 「47 处 / 25 文件，存量已在基线内，无新增」；真机开 VoiceOver 逐个聚焦上述按钮，应读出动作名而非「按钮」。

---

## 五、验证结果（2026-11-06）

| 检查 | 结果 |
| --- | --- |
| `swiftc -parse`（19 个改动 Swift 文件逐个） | 全部通过 |
| `./scripts/ci.sh test` | 偏好键 / 圆角 / 备份口令 / 落库吞错 / **图标按钮无障碍** 5 道闸门全绿；AssistantCore **1134 项测试 0 失败**；心理视图类型检查通过 |
| `./scripts/ci.sh all` | `xcodegen generate` + 真机构建 **BUILD SUCCEEDED** |
| 真机产物 | `Assistant.app/Frameworks/llama.framework` 存在，端侧推理依赖链接正常 |
| 工作树 | 23 个既有文件 + 1 个新增脚本；`xcodegen` 未改动 `Assistant.xcodeproj`，构建产物已被忽略 |

> 说明：整包 iOS 构建在本轮**首次跑通**（此前受宿主 `sandbox-exec` 限制）。因此本轮全部 SwiftUI 改动都经过了真实类型检查，不只是语法解析。
> 静态口径复核：`try? *.save()` 扫出的 4 处全在注释/文档字符串里，`check_save_swallow.py` 的剥注释逻辑正确，落库吞错确实归零 —— **不是假警报**。

---

## 六、剩余与下一步

**P1**：10 个分享弹窗收敛成 1 个 `ShareCardPreviewSheet`（顺带统一 5 套 toast 时长与 14/16/18/10 四套阴影）；64 处真实文本改语义字体；本地化先攻高频 3 页（新增 Toggle 文案沿用该文件既有硬编码中文风格，纳入 P1 统一处理，不单独补孤立 xcstrings key）。

**P2**：待办双表单合并（`EditTodoSheet` 845 + `AddTodoSheet` 1262 = 2107 行、22 个重复 `@State`、字段已漂移）；按**正确对象名**拆 `MedicineEditorSheet` 547 行；`NavigationRouter` 迁 `@Observable`（14 `@Published` / 8 页整体订阅）；报告指纹改全量变更令牌；`NavigationRouter` 与 164 个 sheet 的时序 hack。

**本轮未做**：`.onChange` 的 Debug 打点实测（静态结论已给，需真机坐实）；无障碍剩余 47 处（已有闸门兜住，可按文件逐步下调基线）；App 层测试 target。

---

## 七、口径说明（避免下轮重复投入或误报）

- 无障碍缺口准确数字链：**73 处 / 37 文件 → 补 26 处 → 47 处 / 25 文件**。此前 104 / 70 均为固定窗口估计，含已标注按钮的误报，不再使用。
- 圆角令牌 `check_radius_tokens.py --audit` 为 0 违规、`AppRadius` 508 处，这块无需再投入；盲区在间距、颜色、阴影与扩展 target。
- 报告里「已核对无问题」的方向（README 第八节、ui-findings 末节）不要重复投入。
