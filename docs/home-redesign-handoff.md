# 首页改版 · 设计到实现交接文档

| 项目 | 值 |
| --- | --- |
| 选定方案 | 方案 C「今日概览 · 数据仪表盘」 |
| 设计文件 | Ardot `https://ardot.tencent.com/file/745529208617685`（4 个页面） |
| 代码基线 | `13d4155`（2026-11-09） |
| 文档日期 | 2026-11-10 |
| 当前状态 | **设计已定稿，Swift 源码零改动** |

> ⚠️ **动手前先读 [8.4 节](#84-必须保留10-个条件横幅)**：现有首页挂着 10 个存量条件横幅，方案 C 设计稿只画了 happy path，照稿删会直接丢功能。
>
> 本文所有行号基于上述 HEAD，代码改动后即失效，请按**模块名**而非行号定位。

---

## 0. 一页速览

- **目标**：把首页从「6 层卡片堆叠、无主角」改为「完成环 + 三项数字 + 时间带 + 主任务行」的一屏概览。
- **不改**：搜索语义、筛选分类、任务数据源、五个 Tab、右上角「+」、`.searchable` 行为。
- **不碰**：`AssistantCore` 的持久化 Schema、通知预算、周期报告等既有逻辑。
- **边界**：本文档与 Ardot 画布是设计侧输入；Swift 源码改动由实现侧完成，本文不含实现代码。

---

## 1. 现状诊断与选型

### 1.1 现状的 5 个问题

1. 首屏叠了 6 层卡片，「现在最该做什么 / 今日时间轴 / 提醒中心」重复回答同一个问题「今天要干嘛」。
2. 所有卡片同白底、同圆角、同间距 —— 没有主角，用户打开后不知道眼睛先落哪。
3. 左上孤立的「J」无语义却占黄金位；左下语音悬浮球压住列表第一行的勾选区。
4. 筛选胶囊描边 + 阴影偏重；任务右侧灰色小勾与左侧圆圈语义重复。
5. 「当前为板块分组展示 / 切换为自由排序流」是设置语言，不该占首屏一整行。

### 1.2 三版取舍

| 版本 | 做法 | 代价 / 适合 |
| --- | --- | --- |
| A 聚焦今日 | 只留一张深蓝主任务卡，其余降级为扁平列表 | 减负最彻底，但改了信息架构 |
| B 秩序卡片流 | 模块全留，统一卡片语言、压平描边阴影 | 改动最小，但只解决视觉噪音 |
| **C 今日概览（选定）** | 完成环 + 三项数字 + 时间带，问候降级为一行 | 信息密度最高，但首页会更像报表 |

**选 C 的理由**：现状最致命的不是「不好看」而是「没有主角」。B 只压平噪音，C 又加了一层信息但给出了明确的状态答案。

**C 的风险与对策**：C 容易把「待办」做成「报表」。因此保留两处动作锚点 —— 完成环点击展开当日清单；「接下来」首行固定为主任务并提供一键完成。数据只回答「还剩多少、节奏如何」，不替用户排序、不新增第二套优先级体系。

---

## 2. 定稿信息架构

一屏只回答三个问题：

1. **还剩多少** → 完成环 + 三项数字
2. **节奏如何** → 今日节奏时间带
3. **接下来做什么** → 主任务行 + 两条后续

问候、天气、搜索、筛选全部降级为辅助信息。任何新模块都必须能归进这三问之一，否则不许进首屏。

### 2.1 首屏自上而下

| 顺序 | 区块 | 处理 |
| --- | --- | --- |
| 1 | 状态栏 | OS 控制，62pt，不动 |
| 2 | 问候 + 日期天气 | 压成一行（标题 16 / 副标 11），不再单独成卡 |
| 3 | 右上角「+」 | 保留（排序模式切「完成」） |
| 4 | 搜索框 | 保留，44pt 胶囊 |
| 5 | 今日概览卡 | **新增**，高 150，环 96×96 + 三项数字 |
| 6 | 今日节奏卡 | **新增**，高 120，时间带高 36 |
| 7 | 筛选 chips | 保留但轻文字化，高 28 |
| 8 | 「接下来」标题 | 新增 |
| 9 | 任务列表 | 首行固定主任务（高 50），后续 2 行 |
| 10 | 底部 TabBar | 标准贴底，高 84 |

### 2.2 删 / 留 / 增

- **删**：问候卡与天气卡、轮播容器、「现在最该做什么」独立卡、分组切换整行提示、孤立「J」、语音悬浮球、灰色重复小勾。
- **留**：搜索、筛选、任务内容、时间轴的空闲时长计算、五个 Tab 与原有文案。
- **增**：完成环、三项数字、时间带、主任务行、状态提示色、`HomeSnapshot` 结构化快照。

---

## 3. 视觉规格

### 3.1 颜色令牌（浅 / 深）

| 角色 | 浅色 | 深色 |
| --- | --- | --- |
| 壁纸 | `#E8F2FF → #F7EDFF` 渐变 | `#101828 → #1A1B35` 渐变 |
| 卡片 | `#FFFFFF` | `#1E2436` |
| 主蓝 | `#1A73E8` | `#6FA8FF` |
| 文字主 / 次 / 三级 | `#202124` / `#5F6368` / `#9AA0A6` | `#F2F5FF` / `#A7B0C4` / `#6E7791` |
| 环轨道 / 时间带空闲块 | `#E8EEFB` | `#2A3552` |
| 主任务行底 | `#EAF1FF` | `#24304A` |
| 分隔线 / TabBar | `#E8EAF0` / `#FFFFFF` | `#2E3852` / `#1A2032` |
| 成功 / 警告 | `#34A853` / `#FBBC04` | 同色，警告文字用 `#B26A00` |

颜色一律走 semantic color，**组件内不写死 hex**，浅/深两套值集中在 Theme 定义。图标需独立的深色描边资源。

### 3.2 尺寸（390 × 844 @1x，遵守 iPhone 安全区）

| 项 | 值 |
| --- | --- |
| 状态栏 / 底部 TabBar | 62 / 84（含 Home Indicator） |
| 内容区左右边距 / 模块间距 / 卡片内边距 | 20 / 14 / 16~18 |
| 今日概览卡 / 环 / 环线宽 / 环数字 | 150 / 96×96 / 9 / 25 Inter Bold |
| 今日节奏卡 / 时间带 | 120 / 36（色块按当日窗口比例分配） |
| 任务行 / 勾选圈视觉 / 点击区 | 50 / 20 / ≥ 44pt |
| 筛选 chip 高 / 圆角 | 28 / 14 |
| 圆角层级 | 手机 28 · 卡片 22 · 列表 18 · 胶囊 22 · 色块 8 |
| 字号层级 | 页面标题 20 · 卡片标题 15 · 指标 14 · 正文 13 · 辅助 11 |

---

## 4. 三种状态

三种状态共用同一套组件，只替换数字、文案与提示色；**概览卡在任何状态下都不隐藏**。

| 状态 | 环 | 指标 | 节奏条 | 提示 | 列表区 |
| --- | --- | --- | --- | --- | --- |
| 空态 | `0/4`，空环不隐藏 | 待办 0 件；空闲写「全天空闲」**不写 0** | 全空闲 | 成功色「今天没有日程，享受空白的一天」 | 一句轻提示 +「添加一件」入口 |
| 全完成 | `4/4`，环转 `#34A853` | 4 件已打卡 | 已安排段转绿 | 「4 件全部完成 · 查看今日记录」 | 收起任务行，不弹庆祝动效 |
| 多提醒 | `2/4` | 提醒数行转警告色 | 标出提醒时间点（橙） | 「3 条提醒待处理 · 其中 1 条已过期」 | 不新增独立提醒卡 |

处理规则：空闲时长由日程窗口计算，无日程时不判为「0」；提醒数 > 0 时只改该行颜色，不新增模块。

---

## 5. 组件库（6 个）

| 组件 | 状态 | Frame 与约束 | 数据源 / 无障碍 |
| --- | --- | --- | --- |
| `HomeOverviewCard` / `ProgressRing` | `.empty` / `.partial` / `.allDone` | 宽 `fill_container`(350)，高固定 150；环 96×96 固定不随文字伸缩 | Core 的 `doneCount/totalCount/freeMinutes/reminderCount`；环一个 label「已完成 2 件，共 4 件」，数字变化发 announcement |
| `TaskRow` / `PriorityTaskRow` | `.pending` / `.priority` / `.completed` / `.overdue` | 行高 50；勾选圈 20 固定、点击区 ≥44；标题单行截断，时间右对齐；主任务行底 `#EAF1FF` | `TodoItem` + 主任务 ID（Core 判定，视图不排序）；label 写动作「完成 换新电饭锅」 |
| `RhythmTimelineBar` | `.free` / `.busy` / `.reminder` | 高 36 圆角 8；色块宽度按当日窗口比例算，**禁止硬编码** | 日程窗口（起点含、终点不含）+ 提醒时间点；整条一个 label |
| `FilterChip` | `.normal` / `.selected` | 高 28 圆角 14，宽 `hug_contents` + 左右 12；选中态唯一 | 计数取筛选后的真实未完成数；`.isButton` + 含数量的 label |
| `StatusBanner` | `.success` / `.warning` / `.neutral` | 高 34 圆角 8；只换文案与提示色，不弹 toast | 三态规则推导，视图不判断阈值；对比 ≥4.5:1，警告态文案需含「已过期」 |
| `ActionButton` / `HomeTabBar` | `.enabled` / `.disabled`（首页不出现禁用态） | 主按钮 64×30；圆形新建 36×36；TabBar 84 | 纯图标按钮统一补 label 与 `.isButton`，label 写动作不写图标名 |

---

## 6. 交互状态流

1. **打开首页 · 默认态** — 环 2/4，主任务行置顶；指标 4 件 / 4h16m / 0 条提醒。
2. **勾选主任务** — 点「完成」或左侧圆圈。
3. **数字即时刷新** — 环 → 3/4，三项指标同步；该行划线并下沉，下一件补上主任务位。
4. **全部完成** — 环转语义绿，列表区收起，只留「查看今日记录」；不弹庆祝动效。
5. **次日 / 无日程** — 空态 0/4、全天空闲，列表换成轻提示 +「添加一件」。

两条工程红线：

- **持久化成功后才刷新 UI**；保存失败保持原状态并给横幅提示，不留假状态。
- **状态数据由 Core 输出结构化事实**，视图只渲染、不自行计算（含完成环数字、空闲时长、主任务判定）。

---

## 7. Swift 接口形状（只定契约，不含实现）

```swift
enum ProgressState {
    case empty
    case partial(done: Int, total: Int)
    case allDone
}
enum TaskRowState    { case pending, priority, completed, overdue }
enum BannerTone      { case success, warning, neutral }
enum ChipState       { case normal, selected }   // 不用 default，避开 Swift 关键字
enum TimelineSegment { case free, busy, reminder }

// 视图只消费 Core 的结构化快照，不自行计算
struct HomeSnapshot {
    let done, total, freeMinutes, reminderCount: Int
    let priorityTaskID: UUID?
    let segments: [TimelineSegment]
}
```

> 相关存量问题：`TodoRecurrenceConfig.rule` 的 Swift 6 `Sendable` 报错，仓库已有提交 `e57f8a0`（11-08）修复。若仍报，先查分支同步 / DerivedData 缓存 / `SWIFT_VERSION`，不要重复改 enum。

---

## 8. 设计变更点 → 代码位置对照表

> 行号基于 `13d4155`。所有路径相对仓库根。

### 8.1 删除 / 降级

| 设计动作 | 现在的代码 | 设计稿出处 |
| --- | --- | --- |
| 问候卡 + 天气卡 + 轮播整块移除，压成一行标题 | `Assistant/Features/Todo/TodoSupportingViews.swift:8` `HomeGreetingCard`、`:110` `HomeTopCardsCarousel`；挂载 `Assistant/Features/TodoListView.swift:1350` | 深化设计 · 浅色定稿顶部 |
| 「现在最该做什么」独立卡移除，优先逻辑下沉 Core | `Assistant/Features/TodayBriefingView.swift:239-243`；挂载 `TodoListView.swift:1460` | 组件库 · TaskRow 主任务态 |
| 「今日时间轴」整卡压成节奏条（保留空闲时长计算） | `Assistant/Features/DayTimelineView.swift:372 / 405 / 416`；挂载 `TodoListView.swift:1463` | 深化设计 · 今日节奏卡 |
| 分组切换整行提示删除，入口收进导航或设置 | `TodoListView.swift:703-738` | 深化设计 · 落地顺序 |
| 语音悬浮球移除（改到底栏语音 Tab） | `Assistant/Features/MainTabView.swift:71-73` `DraggableVoiceFloatingBall` | 组件库 · ActionButton |

### 8.2 改造

| 设计动作 | 现在的代码 | 备注 |
| --- | --- | --- |
| 分类栏轻文字化，去描边与重阴影 | `TodoListView.swift:1214` `filterTabBar` | 对应 FilterChip 三态 |
| 时间聚合条 / 标签筛选栏降级或合并 | `TodoListView.swift:1149` / `:1280` | 别给聚合条挂 `.wallpaperReadableText()` |
| 搜索框保持不动 | `TodoListView.swift:376-380` `.searchable` | 保持 `.automatic`，不要改 `.always` |
| 右上角「+」保持不动 | `TodoListView.swift:349-372` toolbar | 排序模式仍切「完成」 |
| 底栏贴底、去掉「9」角标 | `MainTabView.swift:36-50`；`Assistant/Services/TabBarManager.swift:147` | 不要取消 `MainTabView.swift:29` 的 `loadedTabs` 懒挂载 |
| 头部总入口保留但重组 | `TodoListView.swift:1345` `homeHeaderSection` | 内含 `:1358` 分类栏、`:1363` 标签栏、`:1370` 时间聚合条 |

### 8.3 新增

| 设计动作 | 落点 | 契约 |
| --- | --- | --- |
| 完成环 + 三项数字 | 新建 `HomeOverviewCard` | 消费 Core 的 `HomeSnapshot`，视图不计算 |
| 主任务行置顶 + 完成后补位 | `TodoListView.swift` 任务行构建处 | 按 `priorityTaskID` 置顶，先 save 成功再刷 UI |
| 空态 / 全完成 / 多提醒三态提示 | 新建 `StatusBanner` | 与 8.4 的横幅共用一条队列 |
| 时间带 | 新建 `RhythmTimelineBar` | 复用 `DayTimelineView.swift:241-242` 的空闲时段计算，不要另写一套 |

### 8.4 必须保留：10 个条件横幅

`TodoListView.swift:1378-1441` 里挂着一批存量功能，方案 C 设计稿**一个都没画**：

- `TodoReorderingBanner`（排序模式）
- `TodoSeniorModeBanner`（长辈关怀大字模式）
- `TodoWeatherAlertBanner`（气象预警）
- `TodoAnniversaryPrepBanner`（纪念日筹备）
- `TodoTravelTicketPrepBanner`（出行购票）
- 以及 `LifeEventHomeBanner`、`homeSearchIndexPreview`、`tagFilterBar`、`timeAggregationBar`、待确认事项 Section 等

**不可照稿直接删**。建议收敛为 `StatusBanner` 单条优先队列：按优先级只显示 1 条，其余折叠进「更多」或二级入口。优先级顺序实现前需产品确认，本文未替业务决定。

### 8.5 项目硬约定（别顺手改坏）

1. 首页右上角只保留「+」，不放搜索按钮；`.searchable` 用 `.navigationBarDrawer(displayMode: .automatic)`，禁 `.always`。
2. 快捷卡片 / 横幅 / 分类栏 / 标签栏 / 时间聚合条必须放进 `List` 的 `homeHeaderSection` 随滑动滑出；禁滚动容器外层固定 `VStack`；分类栏背景 `Color.clear`。
3. `timeAggregationBar` 禁挂 `.wallpaperReadableText()`（胶囊自带底色，自定义壁纸下会被加黑阴影）。
4. 纯图标按钮统一 `View.iconButton(_:hint:)`（`Assistant/Theme/AppTheme.swift`），一次补 label、44pt 点击区与 `.isButton`；label 写动作不写图标名。
5. 禁 `Section { EmptyView() } header: { 复杂视图 }`（UICollectionView 高度死锁 → 白屏）；`TodoListView.swift:1456` 注释已记录这个坑。
6. 写库统一 `context.saveReportingFailure()`（失败 rollback + `SaveFailureCenter` 横幅）；**成功副作用后置到 save 之后**；禁 `try? context.save()`。
7. `@Query` 加 `#Predicate` / `fetchLimit`；多 Tab 懒挂载 `loadedTabs` 保持。
8. 本地化 `Assistant/Localizable.xcstrings`：已有 key 文案不可改；新增 key 只走 `scripts/add-xcstrings-keys.py`；diff 三查 added/removed/changed，**changed 必须为 0**。当前工作区已有该文件的未提交改动（+18/−3），动手前先确认归属。

---

## 9. 验收清单

建议逐条写成测试钉住：

- [ ] 环数字与三项指标同源，禁止各自计算或各自缓存
- [ ] 空态不隐藏概览卡；空闲写「全天空闲」，不写 0
- [ ] 勾选先持久化成功，再更新环数字与列表顺序
- [ ] 保存失败保持原状态并给横幅提示，不留假状态
- [ ] 时间带色块按窗口比例算，禁止硬编码宽度
- [ ] 主任务行始终置顶，完成后下一件补位
- [ ] 深色模式颜色走 semantic color，组件内不写死 hex
- [ ] 纯图标按钮补 label 与 `.isButton`，点击区 ≥44pt
- [ ] 全完成不弹庆祝动效；多提醒不新增独立卡片
- [ ] 数字变化发 accessibility announcement
- [ ] 8.4 的 10 个存量横幅一个不丢，仅改为队列展示

---

## 10. 落地顺序

1. **先新增、不动旧结构**：建 `HomeSnapshot` + `HomeOverviewCard` / `RhythmTimelineBar` / `StatusBanner` / 主任务行，接上数据但保留旧模块。此时可对照第 9 节验收前半段。
2. **逐块降级旧模块**：按 8.1 → 8.2 顺序，每删/改一块跑一次验证，避免 1134 个 Core 单测与 6 道脚本闸门同时失焦。
3. **最后处理横幅队列与底栏**：确认 8.4 优先级后再动，补无障碍与深色资源。

每步验证：`./scripts/ci.sh all`（Core 单测 + 6 道脚本闸门，含 `check_icon_button_a11y.py`）。

---

## 11. 交付物索引

### Ardot 画布（`745529208617685`）4 个页面

| 页面 | 内容 |
| --- | --- |
| 默认页 | A / B / C 三版效果图 + 现状诊断 |
| 方案 C · 深化设计 | 浅色 / 深色定稿、三种状态、设计令牌与开发标注、设计决策与落地顺序 |
| 方案 C · 组件库与交互流 | 6 个组件全状态、5 步交互流、命名与令牌映射 |
| 方案 C · 开发交付清单 | 6 张组件规格卡、Swift 接口形状、验收清单、交付物索引 |

### 导出图

本地 `/Users/yifanwang/.cache/workbuddy-ardot-verify/` 下以「方案…」命名的 17 张 PNG（同目录另有一批 `light.png` / `grid2.png` / `dev-all.png` 等核对中间图，非交付物）。各轮对话中的附件卡片也可直接打开。

### 项目日志

`.workbuddy/memory/2026-11-09.md`、`2026-11-10.md`（过程记录，非交付文档）。

---

## 附录：已知项

- 底部「设置」图标为放射状齿轮的近似画法，浅/深两版一致；如需精确轮廓需替换 SVG 资源。
- 本文行号与模块名按 `13d4155` 核实，代码改动后以模块名为准。
- 设计稿只覆盖 happy path；8.4 的存量横幅与长辈模式等特殊态尚未出视觉稿，实现前需补设计确认。
