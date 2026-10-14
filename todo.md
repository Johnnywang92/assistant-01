# 项目改进清单

基于 2026-10-10 工作区代码的静态审查。优先级按数据安全、功能真实性、体验与维护成本排列。原始问题描述保留，当前进度见文末实施记录。

## P0｜先处理数据与安全风险

- [x] **数据库打开失败时保留原数据并提供恢复入口。** `Assistant/Services/Persistence.swift:30-55` 当前首次建库失败就删除 `default.store` 及 WAL/SHM，随后可能静默使用内存库。改为明确的版本化迁移；失败时保留原库、记录可诊断错误、提示用户导出或恢复，只有用户确认后才重建。验收：用旧版数据库和损坏数据库分别升级，原文件不被自动删除，应用不会在内存库中假装保存成功。
- [x] **真正加密密码库内容，并迁移已有明文记录。** `Assistant/Models/PasswordVaultModel.swift:10` 的 `passwordEncrypted` 是普通字符串，`Assistant/Features/PasswordVaultView.swift:160,176,316` 直接显示、复制和写入它。采用 Keychain 或由 Keychain 管理密钥的加密存储，旧数据迁移后清除明文；复制时给出自动清除剪贴板的选项。验收：持久化文件中搜不到原始密码，升级后原记录仍可解锁读取。
- [ ] **补齐“全量备份”的数据范围与字段。** `Assistant/Services/Persistence.swift:7-26` 已有 `VehicleProfile`、`StoredItem`、`DialogueMessageRecord` 等模型，但 `Assistant/Services/DataMigrationService.swift:336-505` 未导出它们；`TodoDTO` 也漏了排序与重复规则字段。为备份格式升版本，增加向后兼容的导入和导出后校验，并核对附件、设置、原始消息等是否属于承诺的范围。验收：各类数据、重复规则和排序在新设备导入后保持一致；覆盖还原不会留下旧数据或丢失新数据。
- [x] **加强备份 PIN 的密钥派生。** `Assistant/Services/DataMigrationService.swift:510-565` 允许 4 位 PIN 且用 HKDF 直接派生加密密钥；离线拿到文件后可高速猜测。改用适合口令的慢速 KDF、独立随机盐和版本化参数，并提供较强口令提示及旧备份兼容。验收：新备份可解密、错误口令失败，旧备份仍能按原格式导入。
- [x] **让锁屏通知默认不暴露敏感详情。** `Assistant/Services/TodoNotificationManager.swift:62-83` 将取件码、地点、事项详情写进通知正文。增加“隐藏锁屏详情”设置，默认只显示通用提醒，解锁后再查看内容。验收：锁屏通知不显示取件码及个人备注；用户可自行选择展示级别。

## P1｜补齐关键功能与可信度

- [x] **提升语音记账识别准确率。** 记账解析增加 ASR 同音词归一化、中文数字、`12块5毛`/中文小数、收入口语词和更完整分类关键词；保留金额缺失时不入账的保护。

- [x] **悬浮球长按直接语音对话。** 长按首页悬浮球直接请求权限并开始录音，不再先打开对话页；识别结果复用统一意图处理器，状态提示与语音播报结果，单击仍打开对话页。

- [x] **实现真实的本地模型推理，或如实标注当前能力。** `Assistant/Services/LLMInferenceService.swift:129-161` 下载模型后仍只等待 350 ms 并按关键词走规则分支，未读取 GGUF；`Assistant/Features/LLMModelManagementView.swift:20-75` 却显示模型“已就绪”和端侧推理说明。接入实际推理运行时、加载/生成/取消与错误处理；完成前将页面及回答改为“模型文件管理/规则助手”。验收：断网时的自由问答确实调用模型，日志和测试可区分模型与规则回复。
- [ ] **验证下载或导入的模型文件。** `Assistant/Services/LLMModelManager.swift:75-88,205-220` 目前只以文件大于 100 MB 判断模型可用。增加精确版本、大小及 SHA-256 校验，在校验通过前不标记“已就绪”；导入失败时保留原模型。验收：截断文件、错误 GGUF 和正确模型分别得到明确状态。
- [ ] **让权限引导按需申请，并修正文案。** `Assistant/App/AssistantApp.swift:29` 启动即请求通知权限，`Assistant/Features/PermissionOnboardingView.swift:20-22` 宣称“100% 离线、数据绝不上云”，但 `Assistant/Services/LLMInferenceService.swift:164-191` 支持向局域网 Ollama 发送待办、取件码、开销等上下文。在首次使用相关功能时申请对应权限；启用远程端点时明确显示发送范围和连接状态。验收：首次打开可跳过授权正常浏览，远程模式不会继续显示纯本地承诺。
- [ ] **完善备份与还原失败处理。** `Assistant/Services/DataMigrationService.swift:338-349,689-706` 多处 `try?` 将读取或删除失败当作空数据/成功；`restore` 的覆盖操作应先验证包与附件，再执行可回滚的导入。验收：模拟读取、写入和附件失败时有明确错误，不产生“成功但部分丢失”的备份或还原。
- [ ] **增加全局搜索和快捷操作入口。** 目前搜索分散在收纳、证件、录音和已完成历史，待办主页尚无统一搜索。先支持待办标题、详情、取件码的搜索与筛选，再考虑跨模块搜索；结果直接跳到对应详情。验收：大量待办时可在两步内找到指定事项，敏感结果在锁定时不展示。
- [ ] **为临期事项提供可配置的提醒提前量和稍后提醒。** `Assistant/Services/TodoNotificationManager.swift:55-97` 只在 `dueAt` 时安排一次通知，交互仅固定推迟 1 小时。为普通待办提供 5 分钟、1 小时、1 天等提前量与自定义选项，并区分截止时间与提醒时间。验收：跨时区或修改时间后通知能正确重排，删除及完成后旧通知消失。

## P2｜界面与性能

- [ ] **重做待办顶部分类在窄屏和大字号下的布局。** `Assistant/Features/TodoListView.swift:1121-1175` 将 6 个分类按钮等宽塞进一行，角标字体仅 10 pt；在 iPhone SE 和长辈模式下易拥挤。改成可横滑分类栏或自适应布局，保留当前选中态和可见角标。验收：大字号、窄屏下文字不截断，按钮可清楚点击。
- [ ] **统一视觉层级与主题颜色。** 待办、生活档案、记账和模型页分别使用多套彩色胶囊、渐变、阴影和卡片样式。提取语义色、间距、圆角、卡片及警告态规范；重点简化 `Assistant/Features/LifeVaultView.swift` 顶部统计与下方重复入口，并检查自定义壁纸上的文字对比度。验收：浅色、深色、自定义背景都能清晰辨认标题、状态和主操作。
- [ ] **补齐 VoiceOver 和动态字体。** `Assistant/Features` 中显式无障碍标签很少，悬浮语音球主要靠手势操作，多个角标使用 9–10 pt 固定字号。给悬浮球、统计卡、分类角标、复制按钮添加标签/提示和可访问操作；字号采用语义文本样式或缩放指标，并尊重“减少动态效果”。验收：只用 VoiceOver 可完成新增、查找、完成待办与录音入口；大字模式不重叠。
- [ ] **减少大数据量下的全表读取和重复计算。** `Assistant/Features/TodoListView.swift:80-120` 的 `@Query` 读取全部待办，每个 `classified` 属性访问都重新构造一次分类；`Assistant/Features/ExpenseTrackerView.swift:54-78` 对账本也每次计算全量汇总。改成一次派生、按状态/日期分页或限定查询，并测量 1 万条记录的首屏与切换耗时。验收：上述数据量仍可流畅滚动和切换，统计值与旧实现一致。
- [ ] **拆分过大的视图与服务文件。** `TodoListView.swift` 已约 2400 行，`DataMigrationService.swift` 约 1000 行，`TodoShareSheet.swift` 约 970 行。按页面组件、模型映射、导入导出流程拆分，并将纯逻辑下沉到 `AssistantCore`。验收：UI 状态与数据处理边界清楚，关键规则可独立测试。

## P3｜质量保障与后续功能

- [ ] **为关键数据路径补回归测试。** 当前 `Packages/AssistantCore/Tests/AssistantCoreTests/RuleEngineTests.swift` 只覆盖规则解析与快递匹配。优先覆盖旧库迁移、备份往返、重复待办、通知重排和密码库旧数据迁移；再加入 CI 的 `swift test` 与 iOS 构建。验收：上述真实场景在改动后可自动复现和验证。
- [ ] **增加待办首页的“今天/即将到期”聚合视图。** 在现有类型分类之外，提供按时间组织的今日、逾期、本周入口，并支持一键处理逾期事项。验收：用户无需逐个类型分页就能看到当天应做的事；聚合计数与详情一致。
- [ ] **为记账增加预算与趋势视图。** 基于现有日/月支出和分类汇总，支持月预算、超预算提醒及近 6 个月趋势；优先用已有本地账本数据。验收：跨月后预算自动重置，编辑或删除账目会实时更新统计。
- [ ] **实现取件码、行程与出门清单的灵动岛及实时活动（Live Activities），并同步至 Apple Watch 智能叠放。** 新增 `WidgetExtension` 与 `ActivityKit` 实时活动配置，支持从待办首页或快递分组一键将待取快递码、临近车次/航班倒计时、出门防丢核对项推上锁屏与灵动岛；开启 `supplementalActivityFamilies([.small])` 适配 watchOS 智能叠放（Smart Stack）腕上小尺寸卡片，并提供直接完成/已取件交互按钮。验收：锁屏、灵动岛与 Apple Watch 智能叠放可同步展示大字取件码或行程倒计时，在手表或锁屏点击“已取件/已完成”后主应用状态同步更新且灵动岛自动收起。
- [ ] **增加桌面与锁屏交互式小组件（Interactive Widgets）。** 提供小号（待取快递速览 / 今日剩余预算）与中号（今日高优待办 Top 3 + 快递取件码）桌面及锁屏小组件；基于 `Button(intent:)` 支持在桌面直接勾选完成待办或日常打卡，无需打开主应用。验收：桌面点击完成按钮后组件与主应用数据即时同步，深浅色模式下排版清晰。
- [ ] **接入系统原生 `AppIntents` 与 `AppShortcutsProvider`，打通操作按钮、敲击背面及 Apple Watch 抬腕快捷操作。** 将完成待办、快速记账、新建待办、查询待取快递并上岛封装为系统级 `AppIntent`；支持绑定 iPhone 操作按钮（Action Button）、敲击背面及 Apple Watch 表盘快捷指令复杂功能，配合手表可交互通知（完成/推迟 10 分钟/1 小时/明早 9 点）实现免掏手机闭环。验收：在 Apple Watch 或 iPhone 锁屏/桌面触发快捷指令或点击通知按钮即可完成记账、建待办与取件销号，手表端可直接看到执行结果反馈。
- [ ] **增加全局多模态单入口速记（Omnibox）与早间逾期快速清理卡片。** 支持单入口输入文字、语音或拖入截图（小票、快递、车票、保修单）并自动分流或跨模块联动生成待办、账目与物品档案；存在多项逾期事项时提供卡片式一键顺延/改期/完成整理流。验收：单次输入可准确路由至对应模块，逾期事项可在数秒内批量处理完毕。
- [x] **打通记账“今日安心花”动态额度与收纳物品“日均持有成本”。**
- [x] **增加技能学习路径模式。** 学习某项技能时按「启动 / 基础 / 刻意练习 / 实战输出」四阶段拆解，每阶段 3–5 条可验收里程碑 + 1 条周期练习打卡；只展开当前阶段，通关后自动解锁下一阶段，并统计连续打卡天数与本周投入。验收：说一句「我想学 Python，每天半小时」即可生成路径并把第一阶段写入待办，练习打卡每日提醒且完成后自动接上下一期。 在月预算基础上扣除固定支出计算每日可用余额；支持大额支出关联收纳物品并自动计算持有天数、日均成本与保修剩余天数。验收：记账或修改预算后每日可用额度实时重算，关联物品详情可准确展示日均成本变化。


## P3+｜“免掏手机”闭环：灵动岛 + 桌面交互小组件 + Apple Watch 联动（详细实施方案）

目标设备：iPhone 15 Pro Max（灵动岛 + 操作按钮）+ 已配对 Apple Watch。核心思路是把取快递、赶车、日常打卡三类高频场景串成「手机揣兜里，抬腕点一下就搞定」的闭环：灵动岛/锁屏实时活动在 iOS 18 + watchOS 11 下自动同步到 Apple Watch 智能叠放（Smart Stack）顶部，无需独立 watch App。上方 P3 中灵动岛、交互小组件、AppIntents 三条条目的具体实施细节如下。

### 架构约束与选型（兼顾免费个人开发者证书限制）

- **2 Target 架构，不触碰免费证书扩展上限**：只新增 1 个 `AssistantWidgetExtension`（Widget + ActivityKit Live Activity 共用），不单独建 watch App target、不建独立 Intents Extension。手表侧全部依赖系统能力桥接：
  - 实时活动 → 手表智能叠放：`ActivityConfiguration` 开启 `supplementalActivityFamilies([.small])`。
  - AppIntents → 手表快捷指令表盘组件 / 操作按钮 / 敲击背面：主应用内注册 `AppShortcutsProvider`，系统自动分发到手表。
  - 通知办结 → 手表可交互通知：UNNotificationCategory 带 action 按钮，手表抬腕直接点。
- **数据共享**：`AssistantWidgetExtension` 与主应用通过 App Group（`group.com.yifanwang.assistant`）共享 SwiftData store 或轻量 App Storage 快照（待办 Top 3、待取快递列表、今日剩余额度），避免小组件全量查询。
- **免费账号注意**：App Group、ActivityKit、App Intents 均在免费 Personal Team 支持范围内；Live Activity 需在 Info.plist 声明 `NSSupportsLiveActivities` 与 `NSSupportsLiveActivitiesFrequentUpdates`（仅行程倒计时场景开启）。

### 场景 1：去驿站拿快递（最高频）

- [x] **取件码上岛数据模型**：为快递待办定义 `PickupActivityAttributes`（驿站名、取件码、件数、到期时间），支持多件包裹同屏。
- [x] **一键上岛入口**：待办行 contextMenu 增加「🏝️ 上灵动岛（同步手表）」按钮（快递/退货/行程/日程类型可见）。
- [x] **灵动岛三态 + 锁屏卡片**：紧凑态显示取件码主体；最小化态双胶囊；长按展开态列出全部待取包裹与驿站；锁屏卡片大字排版。`supplementalActivityFamilies([.small])` 适配手表智能叠放，手表端大字显示取件码。
- [x] **抬腕一键销号**：卡片与手表叠放卡片上的「✅ 已取件」按钮走 `CompleteTodoIntent`，完成后 `Activity.end` 收起灵动岛并同步主应用数据。
- [ ] **验收**：手表智能叠放顶部可见大字取件码；双手抱快递不掏手机即可完成取件销号；多件包裹展开态完整列出。

### 场景 2：赶高铁/飞机 & 出门防丢清点

- [x] **行程护航实时活动**：`TravelActivityAttributes`（标题、地点、出发时间、备注），灵动岛紧凑态与锁屏卡片显示 `Text(timerInterval:)` 实时倒计时；展开态带「已出发，结束护航」按钮。
- [x] **出门防丢实时活动**：`DepartureChecklistActivityAttributes`，显示未勾选项（必带项标红），锁屏/手表逐项点击打勾（`ToggleDepartureItemIntent` 更新活动状态），全部确认后自动收岛。
- [x] **入口整合**：出门防遗忘清单页 toolbar 新增「上岛清点」按钮；行程/日程类待办经行内菜单「上灵动岛」启动护航。
- [ ] **验收**：电梯内启动后低头看一眼手腕或灵动岛即可确认清单；倒计时在锁屏实时刷新；清单全部勾选后活动自动结束。

### 场景 3：日常待办打卡、吃药提醒与一句话记账

- [x] **桌面交互式小组件**：
  - 小号（2×2）：「今日待取快递码速览」或「今日支出」，长按组件配置切换（`WidgetConfigurationIntent`）。
  - 中号（4×2）：「今日高优待办 Top 3 + 快递取件码」，每行带 `Button(intent:)` 原生打勾按钮（`CompleteTodoIntent`），无需打开 App。
  - 锁屏 accessory 组件（圆形件数 / 矩形取件码 / 行内提醒）。
- [x] **手表可交互通知**：待办通知已携带「完成事项 / 10分钟后 / 1小时后 / 明早9点」四个 action（`TodoNotificationManager` 已实现，手表抬腕即可处理）。
- [x] **Siri 与快捷意图**：`CompleteTodoIntent`、`QuickAddExpenseIntent`（记账并回显今日累计）、`QuickAddTodoIntent`、`QueryParcelsIntent`（播报取件码并推上灵动岛）+ `AppShortcutsProvider` 注册（快捷指令 / 操作按钮 / 敲击背面 / 手表快捷指令均可用）。
- [ ] **验收**：桌面点圆圈打勾后小组件与主应用即时同步；手表说一句话记账并回显累计；操作按钮一键触发「快递上岛」。

### 实施顺序

1. [x] App Group + 数据快照层（主应用 → 扩展共享）。
2. [x] `AssistantWidgetExtension`：桌面/锁屏交互小组件（先于 Live Activity，风险低、可独立验收）。
3. [x] ActivityKit：快递取件场景（场景 1 全链路）。
4. [x] 场景 2 行程 + 出门清单活动。
5. [x] AppIntents / AppShortcutsProvider + 手表可交互通知。
6. [ ] 真机联调：iPhone 15 Pro Max + Apple Watch 智能叠放同步、免费证书签名验证。

### 通用验收

- 灵动岛、锁屏、手表智能叠放三处状态一致，任一处完成操作后其余两处即时更新且活动正确收起。
- 深浅色模式下所有扩展界面排版清晰、大字号可读；免费 Personal Team 签名下全部功能可安装运行。
- 扩展 target 不引入主应用敏感数据（密码库、证件）——小组件与活动只暴露用户主动选择的条目。

## 2026-10-14｜优化方案：从「记录器」到「助理」（详细实施方案）

定位判断：采集面已经极大（24 类 `TodoType`、35 个持久化模型、约 4.9 万行 Swift），但模型对生活状态的**行动面**几乎为零——LLM 对整个库只有读权限 + 3 个写入口，并且不记得上一句说了什么。本节围绕补齐行动面展开。静态依据：`Assistant/Services/LLMInferenceService.swift`、`Assistant/Features/Omnibox/OmniboxModels.swift`、`Assistant/Features/Omnibox/OmniboxExecutors.swift`、`Assistant/Services/TaskPlanningEngine.swift`、`Assistant/App/AssistantApp.swift`。

**本节 P0–P4 是本轮方案自身的优先级，与文档开头 2026-10-10 静态审查的 P0–P3 不是同一轴，不要混读。**

### 贯穿原则

- **每个能力都要有规则降级。** 沿用 `OmniboxPlanner` 已有的 `llm → rules` 双引擎范式：模型未下载或推理失败时行为退化成今天的样子，不空返回。
- **动作只走一条通道。** 所有写库统一经 `OmniboxExecutor.executeTopologically` + `undo`。现有 `LLMInferenceService.swift:711-731` 的前缀匹配写库是并存的第二条支路，本节要把它收编而不是留着继续长。
- **迁移守项目自己的规矩。** 加字段带默认值走轻量迁移即可；**加新模型必须开 `AssistantSchemaV4`**，V1/V2/V3 已发布清单不可再改（见 `Assistant/Services/Persistence.swift:134-137` 注释）。

### P0｜地基：上下文预算与提示词装配（先做，1 天，风险最低收益立现）

- [x] **改掉截断语义：溢出时丢的恰好是最该留的数据。** `LLMInferenceService.swift:128` 写死 `n_ctx = 2048`，`:181-184` 用 `promptTokens.suffix(maxPromptLength)` 保留尾部——12 条生活档案对一个真实活跃用户必定超预算，于是被丢掉的是 system 人格设定 + 排在最前面的「待取快递」「日常待办」，正好是回答「我现在该干嘛」最需要的两组；同时 ChatML 起始结构被截成残缺体。改为**分块装配 + 预算裁剪**：新增 `Packages/AssistantCore/Sources/AssistantCore/PromptBudget.swift`（纯函数），`struct PromptBlock { id: BlockID; priority: Int; text: String }`，`assemble(blocks:tokenBudget:estimate:)` 按 priority 从低到高**整块丢弃**，永不截半块。估算：CJK ≈ 1 token/字，ASCII ≈ 4 字符/token，ChatML 标记 8 token/段，留 15% 余量（估算偏乐观，宁少勿多）。`generate` 内的 token 级截断降级为兜底断言：真分词后仍超预算时丢 `history`，不丢档案。验收：单测覆盖「档案超预算时丢低优先级块、`parcel`/`todo` 幸存、ChatML 结构完整」；真机断网问「我现在该干嘛」，回答能出现具体待办而非通用套话。
- [x] **`n_ctx` 改为读 GGUF 元数据。** 从模型头部取 context length，`min(模型值, 4096)`，内存告警降档。⚠️ 具体 C 符号形态（新版为 `llama_model_n_ctx(model, LLAMA_CONTEXT_DEFAULT)`）落地前**先对照随包 xcframework 头文件核实**——本 SDK 已有多处标签与实参类型不一致的先例（`MigrationStage.lightweight`）。验收：分别加载 2K/8K 上下文的 GGUF，日志显示实际生效 `n_ctx`；小上下文模型不因请求超窗而 `decodeFailed`。
- [x] **闲聊旁路，省掉整次 prefill。** `shouldRouteQueryToRules`（`:734-745`）之外加 `isSmallTalk(_:)`，问候/情绪语走轻量提示词不带档案。现状：说一声「你好」也要为 12 条生活档案做一次全量 prefill。验收：闲聊类输入的提示词体积可测得地小于生活问答类。

### P1｜让它记住 + 让它动手（本轮核心价值）

- [x] **多轮对话记忆注入（几乎免费）。** `DialogueMessageRecord` 已有 `sessionID` 字段，`VoiceDialogueView` 全部 15 处 `saveMessage` 也都已传 `currentSessionID`——缺的只是读出来喂模型：`buildPrompt`（`:382`）目前只吃「当前这一句 + 档案快照」，`DialogueHistoryManager.fetchRecentMessages`（`:68`）全仓只在 `VoiceDialogueView:335` 被调用于重启后回填界面。改：`DialogueHistoryManager` 增 `recentTurns(sessionID:limit:context:)`（按 `sessionID` + 时间降序谓词 + `fetchLimit`）；`buildPrompt` 增 `history` 参数序列化为 ChatML 轮次，**硬配额 400 token**（≈6 轮，超则丢最旧轮）；`DialogueRetentionPolicy.none` 时不注入（该策略现在获得第二重语义：隐私开关）。`generate(query:context:)` 增 `sessionID`，调用点仅 `VoiceDialogueView.swift:560/566` 两处。验收：连续三轮「我有哪些快递」→「取第一个」→「它的取件码是多少」，第三轮无需重复实体即可答对。
- [x] **动作空间从 3 个扩到 9 个。** `OmniboxModels.swift:7-13` 的全部动作空间就是 `expense.create`/`todo.create`/`memo.inbox`，**不存在修改或删除既有记录的通道**——「取消明天去医院的提醒」「尾款我付了」都无法执行。按 `OmniboxExecutors.swift:6` 注释已写明的缝隙扩展（「新增模块 = 注册一个分支并实现 undo」）：`todo.update`、`todo.complete`、`todo.cancel`、`reminder.snooze`（复用通知层已有的 10 分/1 小时/明早语义）、`expense.update`、`query.lookup`（只读）。验收：断网 + 已下载模型下 9 类动作各至少 1 条真机通过；每条执行后撤销能回到改动前状态（**重点验证修改式撤销，不要只测删除式**）。
- [x] **`OmniboxUndoToken` 升级为可承载「修改式回滚」。** 现状 `OmniboxModels.swift:79-90` 只有 `kind + recordID + memoLine`，够「删除即撤销」，不够「改回原值」。加 `snapshotJSON: Data?`（改动前字段字典）；旧令牌缺该字段解码为 nil，兼容已落库的 `OmniboxTransaction.undoJSON`。验收：旧 `OmniboxTransaction` 记录仍可撤销；新修改式动作撤销后字段逐项还原。
- [x] **目标解析走确定性代码，不交给模型。** 1.5B 挑 ID 必翻车。新增 `Assistant/Services/ActionTargetResolver.swift`：`resolve(kind:mention:context:) -> .unique(TodoItem) | .ambiguous([Candidate]) | .none`，打分 = 标题/详情包含度 × 活跃状态加权 × 时间接近度。`ambiguous` 时**复用已有 chip 交互**（`VoiceIntentResult.options` 与 `PlanningClarificationEngine` 机制已在），不新写 UI。模型永远只见自然语言 `target` 串，解析后的 ID 才进 `execute`。验收：同名/近义两条待办时弹出选项且点选后动作正确；`mention` 无命中时明确回复「没找到」而不是猜一个。
- [x] **对话路径改为产出与 Omnibox 相同的动作 schema。** 用统一的 `actionSystemInstruction` 取代 `executeSideEffectIfNeeded`（`:711-731`）的前缀判断，模型输出 `[{"capability":"todo.complete","target":"…"}]`，直接复用 `OmniboxPlanner.parseActionJSON`（`:105`，**已带 markdown 围栏剥离与尾逗号修复，白捡**），再进 `OmniboxExecutor`。前缀匹配保留为「模型不可用时的规则入口」，不再是并存的第二写库通道。验收：同一句「提醒我明天取快递」走对话与走投喂口，落库结果与可撤销性一致（两通道合流的可证依据）。
- [ ] **动作输出尝试挂语法约束。** 若随包 llama 头文件提供 grammar 采样器（`llama_sampler_init_grammar`/GBNF 形态），给动作输出加 JSON 语法约束——1.5B 的 JSON 合规率提升通常是数量级的。无该符号则退化为「解析失败重试 1 次 → 规则兜底」。验收：50 条脚本输入下动作 JSON 一次解析成功率 ≥ 90%（或降级路径下无静默丢动作）。
- [x] **破坏性动作无条件过确认卡。** `PlannedAction.needsConfirmation`（阈值 0.6，`OmniboxModels.swift:72-74`）目前只在投喂口生效。`todo.cancel`、`expense.update`/删除类**无论模型给多高置信度都必须确认**，在 `OmniboxExecutor` 派发前按 capability 强制置位，不信任模型自报的 confidence。验收：伪造一条 confidence=0.99 的 `todo.cancel` 动作仍进确认卡；`todo.complete` 不误进。

### P2｜规划带时间 + 主动性真正在后台

- [x] **修掉 AI 规划结果不带时间。** `TaskPlanningEngine.swift:472-491` 建 `TodoItem` 时完全不设 `dueAt`，也不调 `scheduleNotification`——尽管引擎自己有「前置筹备→物料执行→行前冲刺→收尾复盘」四阶段时间模型，尽管提示词明确索要「提前 30 天办理签证」这类窗口期。改：`TaskPlanningPlan` 增 `anchorDate: Date?`（追问已确认的时间，现在只以 `backgroundContext` 自由文本存在，未结构化）；`PlannedSubtask` 增 `offsetDays: Int?`，由 `parseDecompositionOutput`（`:431`）从标题抽「提前 N 天/前一周/当天」，抽不到按阶段默认 `prepare −7 / execute −3 / sprint −1 / followup +2`；`savePlanToTodos` 计算 `dueAt` 并补排通知。递归细化（`refineSubtaskWithAI`，`:331`）继承父步骤 `dueAt − 1 天`。验收：说「下月 5 号去日本，帮我规划」，清单在 `DayTimelineView`/`TodayBriefing` 可见、按阶段分散在未来两周、到期前有通知；细化出的微步骤同样带时间。
- [x] **注册 `BGAppRefreshTask`，把回前台巡检搬进后台。** `grep BGAppRefreshTask|BGTaskScheduler` 全仓零命中；`AssistantApp.swift:85-128` 的 11 项主动作全部挂在 `scenePhase == .active`，用户不开 App 就什么都不评估——「情景智能」实为「开屏智能」。新增 `Assistant/Services/BackgroundRefreshCoordinator.swift`，搬迁其中已幂等且不在主线程的第 1/4/9/11 项（收件箱补录、痛点巡检、周期支出自动入账、分享中转区排空）；`initialDate = now + 4h`、`requiresExternalContent = false`、每次完成后 `setNeedsBackgroundRefreshTaskSchedule`；handler 内检查 `task.expirationHandler`，各 service 独立 `try?`。`.active` 保留即时路径不变，两者共用入口不复制实现。验收：Xcode 手动触发后台刷新任务，日志显示巡检执行且新建了临期提醒；真机静置一晚后次日首屏无「积压一次性爆发」。
  ⚠️ **工程配置坑（本项目已踩过）**：`project.yml` 的 `info.properties` 完全覆盖磁盘 `Info.plist`，`BGTaskSchedulerPermittedIdentifiers` **必须写进 `project.yml:57` 那段**，写在 `Assistant/Info.plist` 会被 `xcodegen generate` 抹掉。`BGAppRefreshTask` 不需要 `UIBackgroundModes`（当前一个都没有，保持不加）。

### P3｜打通外部世界（可并行，按用户价值排序）

- [x] **系统日历改双向。** `CalendarAgendaService.swift` 现状只读、只取今天、且要用户主动展开；`EventKit` 全仓仅此一处引用，App 写不进用户其他设备已在同步的日历，等于两份真相。改：加 `saveEvent/deleteEvent`、同步窗口今天→7 天、`TodoItem` 增 `calendarItemIdentifier: String?`（默认 nil，轻量迁移安全），`event`/`travelBooking` 且有 `dueAt` 的待办提供「写入系统日历」开关。**成本极低：`NSCalendarsFullAccessUsageDescription` 已在 `project.yml:110`，零新增权限**；先做导出方向，冲突最小。验收：带截止的工作待办一键写入系统日历后在 Mac 上可见；在 iPhone 删除该待办不留孤儿日程。
- [x] **跨模块统一搜索（收口原 P1 未完成项，见上文 L23）。** 现状 `.searchable` 分散在待办/已完成/证件/收纳/录音 5 个页面，无跨模块入口。新增 `Assistant/Services/UnifiedSearchService.swift` 扇出 `TodoItem`/`ExpenseRecord`/`StoredItem`/`IDDocumentItem`/`VoiceMemo`；TabView 根挂 `.searchable`；结果经已有 `NavigationRouter`（`assistant://` 深链 + `VaultDestination`）直达详情；受 `AppLockManager` 与「敏感详情」开关约束。验收：万件待办 + 大账本下两步内找到指定事项；App 锁定时敏感模块结果不暴露正文。
- [ ] **通讯录作为人物主干。** `Contacts` 全仓零引用，但已有 `AnniversaryItem`/`ChildProfile`/`PetProfile`。用 `CNContactPickerViewController`（免全量通讯录权限）把真实联系人挂到人上，需在 `project.yml` 加 `NSContactsUsageDescription`。顺带让 P1 的 resolver 能解析「提醒我给妈妈打电话」到具体人与号码。验收：纪念日与育儿档案可从通讯录一次选人录入；「给妈妈打电话」这类指代能落到已选联系人。
- [ ] **HealthKit 只读接入。** `HealthKit` 零引用，而 `TodoType` 里已有 `exercise`/`hydration`/`medication` 三类在孤本地记账。只 `read` 步数/睡眠/饮水喂给这三类，需要加 entitlement 与两条用途描述串。验收：授权后运动/饮水打卡页能看到健康侧数值；拒绝授权时页面正常降级不卡死。
- [ ] **选择性云同步（按数据可用性看待，不是按功能）。** `CloudKit` 零引用，唯一灾备路径是手动导出→换机导入；叠加免费个人团队 7 天重签，**单机存储是数据可用性问题**。方案：CloudKit 同步 todo/expense/storedItem，密码库密钥与证件图像留本机，同步密钥放 iCloud Keychain。**云许可边界直接复用 `AssistantCore/SettingsSnapshot.swift` 的排除白名单与它的「纪律测试」**（谁把安全材料登记进可同步清单，测试就报错）。验收：换机导入后待办/账目/收纳一致，密码库与证件不出现在云端备份。

### P4｜架构债（P1 的前置条件，边做边还）

- [x] **把要改的纯逻辑下沉 `AssistantCore`。** 下沉候选（均无 UIKit 依赖）：`OmniboxPlanner` 正则抽取器、`TaskPlanningEngine.inferTodoType/inferPhase`、`shouldRouteQueryToRules`、`PromptBudget`、`parseActionJSON`。原因：**app target 无测试 scheme**（工程只有 Assistant / AssistantCore 两个 scheme，既有事实），不下沉就没有测试能力；而 P1 让 LLM 驱动这些判定前，必须先用测试钉住行为。验收：新增测试覆盖动作 schema 解析（含畸形 JSON）、undo 快照回滚、`PromptBudget` 丢块优先级、规划 `dueAt` 推算。
- [ ] **拆 `TodoListView.swift`（3,611 行，收口原 P2 项，见上文 L32）。** 按「列表容器 / 行视图 / 排序与分档 / Sheet」四块切；本轮只需先拆出 P1.2 要碰的完成与顺延入口，不必一次到位。验收：UI 状态与数据处理边界清楚，关键规则可在 `AssistantCore` 独立测试。

### 实施顺序

1. [x] P0 上下文预算与截断语义（一切的前提，最小风险）。
2. [x] P4 下沉 + 补测试（P1.2 的安全网）。
3. [x] P1.1 记忆注入 → P1.2 动作空间（含 resolver / undo 升级 / 通道合流 / 确认边界）。
4. [x] P2.1 规划带时间 → P2.2 后台巡检。
5. [x] P3.1 日历双向、P3.2 统一搜索（可并行插入）；P3.5 云同步按数据风险可提前。

**最小可感知的第一版 = P0 + P1.1 + P1.2 的 `todo.complete`/`todo.update`/`reminder.snooze` 三动作。** 约一周工作量，不新增权限、不新增 target，就能把产品从「很聪明的 App」推到「助理」。

### 度量指标

| 指标 | 现状 | 目标 |
| --- | --- | --- |
| 多轮指代可解析率（20 条脚本对话） | ≈0（架构上不可能） | ≥17/20 |
| 自然语言**变更**既有记录的覆盖率 | 0（只能新建） | 9 类动作 × ≥3 种表述 |
| AI 规划步骤带时间比例 | 0% | 100%（无锚点走阶段默认） |
| 无前台时巡检执行率 | 0% | ≥每日 1 次（系统调度下尽力） |
| 首 token 延迟（真机 1.5B，档案满载） | 未测（每轮全量重 prefill） | 建基线后 −30% |

### 本轮会反复撞到的工程约束

- 验证只能真机构建：`llama.swiftxcframework` 无模拟器切片（既有限制）。
- `project.yml` 是工程唯一来源，任何 Info.plist 键都写在 `info.properties` 里。
- 加新模型 = 开 `AssistantSchemaV4` 并补一条 lightweight 迁移阶段；不要往已发布的 V1/V2/V3 清单里塞。
- 手表/Mac 交互受「无 watchOS App 时实时活动整卡不可点」约束（见上文 2026-10-12 续二记录）——P1.2 新增的完成/顺延动作要同时挂到**可交互通知 action** 上，不要往手表卡片里放假按钮。

## 验证记录

- 审查方式：静态阅读当前工作区源码，未运行 iOS 模拟器，也未做屏幕截图；界面问题需要后续在小屏、深色与大字号下实机确认。
- `swift test`：覆盖 `AssistantCore` 纯逻辑模块（PromptBudget、ActionModels、TaskPlanningInference、SkillPath 等），共 128 项测试、0 失败，100% 通过。
- `xcodebuild -scheme Assistant -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build`：成功构建 iOS 整体工程（**BUILD SUCCEEDED**），覆盖全部 9 个动作空间、后台刷新协调器、日历双向同步与跨模块全景搜索模块。

## 2026-10-10 实施记录

- **语音记账与悬浮球：已完成。** `ExpenseNaturalLanguageParser` 支持中文数字、口语金额、ASR 同音词归一化及收入/分类词扩展；首页悬浮球长按直录并直接执行意图，单击行为保持不变。已通过 iOS generic device Debug 构建。

- **P0 数据库恢复：部分完成。** 已停止自动删除旧库；打不开时只显示恢复页并提供原始 store/WAL/SHM 导出。尚未引入显式版本化 SwiftData 迁移，也未用真实旧库与损坏库演练。
- **P0 密码库：部分完成。** 新记录用 Keychain 中的随机密钥进行 AES-GCM 加密；启动和打开保险箱时迁移旧明文；复制密码设置 60 秒过期。尚未做升级设备上的持久化取证与迁移回归测试。
- **P0 全量备份：部分完成。** 新格式 v2 加入车辆、收纳、对话、原始消息、位置采样，以及待办排序、重复和提醒字段；旧格式仍可合并导入，禁止旧版覆盖还原。附件读取失败将中止导出，覆盖还原先做预检。尚未覆盖设置项，也未完成真机跨设备往返测试。
- **P0 备份口令：代码完成，待测试。** 新备份要求 8–64 位口令，使用 PBKDF2-HMAC-SHA256 310,000 次与随机盐；v1 备份保留旧版 HKDF 解锁路径。明文导出已关闭。
- **P0 通知隐私：代码完成，待设备验证。** 默认隐藏标题与详情，设置中可主动开启；切换时重新安排待办通知。
- **P1 模型能力：采用如实标注方案。** 已删除模拟“本地 Qwen 推理”回复，界面明确说明 GGUF 尚未接入推理；局域网发送需要显式开关。真实端侧推理仍是可选的后续开发。
- **P1 模型文件验证：部分完成。** 导入/下载会验证最小体积、GGUF 头、版本并计算 SHA-256；保存候选文件时保留旧模型。尚无官方发布哈希可对照，当前哈希只用于本机完整性复核。
- **P1 权限与文案：部分完成。** 启动不再直接申请通知权限，自动位置采样不再触发首次定位授权；新建/编辑提醒时才申请通知权限，位置页面操作时才申请定位权限。离线承诺已改成如实说明远程端点；问答测试页显示最近一次连接状态。全场景权限与文案核对仍待完成。
- **P1 备份错误：部分完成。** 导出主要 fetch 已改为抛错，覆盖还原使用 `rollback()` 处理数据库错误，并对附件与密码预检。附件文件写入的跨文件系统回滚和故障注入测试仍待完成。
- **P1 搜索：部分完成。** 待办首页加入标题、详情、取件码和驿站搜索；跨模块搜索与锁屏实机测试未完成。
- **P1 提醒：部分完成。** 新建/编辑待办可选择到期前 5 分钟、1 小时、1 天或自定义提前分钟数；“稍后 1 小时”不再改截止时间。全量同步会清除失效的待办通知，并优先排期最近的 50 项。跨时区和大量待办仍待设备测试。
- **P2 分类与无障碍：部分完成。** 分类栏可横滑、按钮高度至少 44 pt，增加分类与语音悬浮球的 VoiceOver 描述；仍需小屏、大字号、深色主题实机验证。
- **验证：** 本次修改前后多次运行 iOS generic device Debug 构建；编译阶段只报告项目原有的 Swift 并发警告（`PermissionManager`、`LocationReminderService` 等），未出现新的语法错误。`AssistantCore` 的 24 项测试通过；模拟器 P0 回归测试 target 因工程测试宿主配置问题未纳入最终工程，仍需后续补齐自动化回归测试。

## 2026-10-12 实施记录（灵动岛 + 交互小组件 + Apple Watch 闭环）

- **App Group 快照层：已完成。** 新增共享目录 `WidgetShared/`（编译进主应用与扩展两个 target）：`WidgetSnapshot.swift`（快照模型 + App Group `group.com.yifanwang.assistant01` 读写 + 扩展→主应用指令队列）、`WidgetActivityModels.swift`（三个实时活动 Attributes + 跨进程状态更新/收岛 Helper）、`WidgetIntents.swift`（全部 AppIntent）。主应用侧 `WidgetSnapshotSync.swift` 负责从 SwiftData 构建快照（高优待办 Top6 / 待取快递 / 今日支出）并对账扩展指令；在启动、回前台、回后台、通知交互后自动刷新。出于 P0 数据安全，快照不包含密码库、证件等敏感数据；未移动 SwiftData 存储位置（扩展不直接读库，规避多进程 SwiftData 风险）。
- **小组件扩展：已完成。** 新 target `AssistantWidgetExtension`（bundle id `com.yifanwang.assistant01.widgets`）：中号「今日待办 Top3」每行原生打勾按钮；小号「小助速览」长按可切换待取快递码/今日支出；锁屏圆形/矩形/行内 accessory。工程由 xcodegen 重新生成，两个 target 均配置 App Group entitlements。
- **实时活动：已完成三个场景。** 快递取件（多包裹同屏、展开态逐件"已取件"、全部取完自动收岛）、行程护航（倒计时 + "已出发"按钮）、出门防丢清点（逐项打勾、必带项标红、全部确认自动结束）。均开启 `supplementalActivityFamilies([.small])` 适配手表智能叠放大字布局。
- **AppIntents：已完成。** `AppShortcutsProvider` 注册一句话记账/新建待办/快递上岛三个快捷意图（快捷指令、操作按钮、敲击背面、手表快捷指令可用）；进程分流设计：主应用进程内直连 SwiftData，扩展进程走指令队列 + 本地快照突变 + WidgetCenter 刷新，回前台对账。
- **构建验证：`BUILD SUCCEEDED`**（generic iOS device Debug，`CODE_SIGNING_ALLOWED=NO`，主应用 + 扩展全部编译链接通过）。签名相关：免费 Personal Team 生成含 App Groups 的描述文件需要**连接已注册的 iPhone** 后在 Xcode 中自动更新 profile（当前未连接设备，报 "no devices from which to generate a provisioning profile"）；模拟器构建不可行（llama.swift xcframework 无模拟器切片，属项目既有限制）。AppIntent 短语不支持 String 参数插值（仅 AppEntity/AppEnum），已改为短语触发 + Siri 追问内容。
- **待真机验证：** ① 连接 iPhone 后自动签名安装，确认 App Group 在免费账号下生效；② 智能叠放大字取件码、桌面打勾三端同步、手表一句话记账回显、操作按钮绑定「快递上岛」；③ 深浅色与大字号下组件排版。

## 2026-10-12 实施记录（安心花 + 日均持有成本）

- **今日安心花（Safe-to-Spend）：已完成。** 新增 `Assistant/Services/BudgetAndItemCostService.swift`：`BudgetSettings`（UserDefaults 月预算）+ `SafeToSpendCalculator` 纯函数（今日额度 = (月预算 - 固定支出折算月额 - 本月已花弹性) / 距月底剩余天数，天然带滚入效应；昨日结余单独回推用于正向展示；超支/未设预算均有明确状态）。固定周期支出自动入账通过 rawText 前缀（`周期自动记账:`/`周期固定支出:`）从弹性池剔除，避免与 `RecurringExpenseManager.monthlyEstimatedTotal` 双重扣减。`ExpenseTrackerView` 顶部新增 `SafeToSpendCard`（大字今日可花 + 进度条 + 「昨日省下 ¥X 已滚入 💰」），点按弹 `BudgetEditSheet`（设预算 + 列出自动扣除的固定支出明细）。
- **日均持有成本（Cost Per Day）：已完成。** `StoredItem` 增加 `purchasePrice`/`purchaseDate`（可选字段，轻量迁移安全）；`ExpenseRecord` 增加 `linkedItemID` 支持把后续投入（保养/配件）关联到物品；`ItemCostCalculator.summary` 计算 累计投入=购入价+关联记账、持有天数、日均成本与里程碑提示（如「再用 30 天，日均成本就低于 ¥20 啦」，档位 1/2/5/10/20/50/100/200/500）。收纳页：行卡片显示「已使用 X 天 · 日均 ¥Y/天」，顶部新增「日均持有成本速览」（跟踪件数/累计投入/最高日均），编辑表单可填购入价与日期并实时预览成本；记账表单新增「关联收纳物品」选择器。
- **备份同步：** `ExpenseDTO` 与 `StoredItemDTO` 增加新字段（可选，旧备份可解），导出/导入均已接线。
- **验证：** 核心公式用独立 Swift 脚本跑了 5 组边界场景（正常/昨日零花滚入/超支/未设预算/里程碑天数）全部通过；`xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**。顺手确认 `OmniboxSupportViews.swift` 两处 `ContentUnavailableView` 非法 `icon:` 尾闭包已被（用户同步）修复。
- **遗留：** 预算仅全局单值（无按月历史）；安心花卡片未接入桌面小组件快照（「今日支出」小号组件可升级显示今日剩余额度）；保修剩余天数未纳入（可后续复用 `ItemExpiryItem`）。
- **二手市场联动（持有成本 v2）：已完成。** `StoredItem` 增加 `isSecondHand`/`resalePrice`/`resoldDate`；
`ItemCostSummary` 新增净持有成本口径：净成本 = 累计投入 − 转卖回血、净日均成本，已转卖物品持有天数截至转卖日（闲置期不再摊高日均）；里程碑文案按状态分流——已转卖讲「回血」（净成本 ≤ 0 显示「相当于零成本持有 🎉」），在持物品保留「跌破整数价」提示。收纳表单新增「二手购入」开关与「转卖回血」小节（可撤销转卖记录）；行卡片显示二手/已转卖徽章与净成本行；速览增加「转卖回血」合计；周期报告成本榜增加购入渠道/回血/净成本列 + 「二手交易如何影响实际持有成本」说明段（卡片与 Markdown 均有），Markdown 表格扩为 8 列。备份 DTO 同步三个新字段（可选，旧备份兼容）。BUILD SUCCEEDED；净成本口径经脚本核验（¥6999 用 320 天转卖 ¥3500 → 净 ¥10.9/天；回血超投入 → 零成本持有）。
- **日报行动建议引擎：已完成。** `PeriodicReportManager` 新增 `ReportSuggestion`（urgent/action/positive 三档）与 `generateSuggestions` 引擎，从真实数据提炼最多 5 条可执行建议：①未设预算→引导开通安心花；②弹性超支→指向最高占比类别给削减抓手；③预算节奏超前（消耗比时间进度快 15%+ 且预测超支 >¥50）→给出「按当前节奏月底将超支约 ¥X，今天起日均控制在 ¥Y」；④今天已花超当日额度→「今晚收手」；⑤逾期待办→指名最早一项；⑥明天到期→睡前预排；⑦本月 ¥200+ 大额支出未关联收纳物品→提示接入持有成本跟踪；⑧Top1 在持物品日均 >¥10 且持有 30 天+→转卖回血建议；⑨昨日省下滚入→正反馈；⑩无异常→稳定确认兜底。报告页智能小结后新增「行动建议」卡片（红/橙/绿分色底），Markdown 导出同步「🎯 行动建议」章节。物品成本榜改为全周期计算但 UI/导出仅月报/年报展示（日报只用于提炼建议）。BUILD SUCCEEDED。

## 2026-10-12 实施记录（免掏手机闭环 v2：修掉手表交互断点）

- **发现的设计错误：手表上的实时活动卡片点不动。** WWDC24 Session 10098《Design Live Activities for Apple Watch》明确：没有 watchOS App 时，智能叠放里的实时活动**整张卡片是单一点击目标**，点击后展开系统全屏视图并提供「在 iPhone 上打开」；卡片内的 `Button(intent:)` 不可点。此前 `PickupLockScreenView` / `DepartureLockScreenView` 的 `.small` 分支里放的「已取件 / 逐项打勾」按钮在手腕上属于**假按钮**——场景 1「抬腕一键销号」实际是断的（手机还在兜里，只会让你去打开 iPhone）。注意：watchOS 11 的「可交互」是加在**小组件**上的，不是实时活动。
- **闭环改为「看 + 点」分离。** 实时活动（灵动岛 + 手表智能叠放）只负责大字只读展示；动手交给**可交互通知**——通知 action 是手腕上唯一不需要 watchOS App 就能原生点击的单位。新增 `Assistant/Services/PickupCheckoutService.swift`：上岛成功后投递一条无声销号通知（标题即取件码、分类 `PICKUP_CHECKOUT_CATEGORY`、action「已取件 ✓ / 全部取齐」）；点击后在主应用进程销号 → `PickupActivityHelper.markCompleted` 更新灵动岛 → 还有剩余就自动把通知推进为下一件的码 → 全部取完撤掉通知并收岛。会话状态存在 `UserDefaults`（`Step(id, code)` 队列），不依赖 `Activity.activities` 的异步刷新时序，行为确定；回前台 `reconcile` 会剔除已在 App 内手动勾掉的包裹，避免留下幽灵通知。
- **灵动岛多包裹 bug 修复。** 紧凑态 `compactTrailing` 原来取 `parcels.first`，取完第一件后仍一直显示已取件包裹的旧码。新增 `PickupProgress.nextPending / remainingCount`（用 filter 而非「总数 − 已完成数」，避免遗留 id 干扰计数），紧凑态与手表大字都改用「下一个未取」，全部取完显示「已取齐」。
- **手表视图去掉假按钮 + Always-On 适配。** `.small` 分支改为纯展示（驿站 / 大字取件码 / 还剩几件 + 一句操作提示），并读 `@Environment(\.isLuminanceReduced)`，手腕放下时去掉高饱和色。出门清点手表端只回答「还差什么」（未勾项 + 必带标红），打勾保留在 iPhone 锁屏与灵动岛（那里按钮是真能点的）；代码注释写明原因，避免以后又被补回假按钮。
- **行程补上座位号 / 检票口。** 新增 `Packages/AssistantCore/Sources/AssistantCore/TicketDetails.swift`（纯函数、无平台依赖）：从详情与短信原文抽取车次（`车次:` 前缀优先，其次 `[GDZTKC]\d{2,5}`、航班 `[A-Z]{2}\d{3,4}`）、车厢、座位（要求非字母数字边界，避免把 C2002 拆出座位）、检票口/登机口（含全角转半角）。`TravelActivityAttributes` 新增 `ticketSummary`（车次 + 座位）与 `gate`，灵动岛展开态、锁屏与手表卡片都显示；抽不到就只显示倒计时，不硬凑。新增 `TicketDetailsTests` 8 例（12306 短信、航班、全角检票口、车次不被误拆等）。
- **AppIntent 改为内联回显。** 六个意图统一 `openAppWhenRun = false`：Siri / 手表抬腕说一句直接内联回显结果（如「已记账 18 元（餐饮），今日累计支出 63 元」），不再把 App 拉到前台；从灵动岛点按钮也不打断当前界面。
- **接线：** `AppDelegate.didReceive` 增加 `type == "pickup"` 分支；`AssistantApp` 启动时注册销号通知分类，回前台执行 `reconcile`。
- **验证：** `swift test` 30 项通过（新增 8 项）；`xcodebuild` generic iOS device Debug 主应用 + 扩展 BUILD SUCCEEDED。
- **待真机验证：** ① 手表智能叠放同时出现大字取件码卡片与销号通知，点「已取件」后卡片消失、下一件自动接上；② 多件包裹连续销号时通知标题是否逐件刷新；③ 抬腕放下（Always-On 降亮度）后配色是否仍清晰。
- **未做（需你拍板）：** 若要让手表智能叠放里的卡片**直接可点**、不必绕通知，唯一正解是新增一个极小 watchOS App target 并在其 Info.plist 配置 `Supports Launch for Live Activity Attribute Types`。这会突破此前定的「2 Target、不碰免费证书扩展上限」约束（多 1–2 个 bundle id / profile，免费证书 7 天需重签）。当前方案在 2 Target 前提下已能把三个场景跑通。

## 2026-10-12 实施记录（技能学习路径：四阶段拆解 + 周期练习打卡）

- **为什么不能复用原任务拆解。** 原 `TaskPlanningEngine` 是「一次性场景清单」架构（露营/搬家/出差，平铺 4–6 条、无阶段、无周期、无进度）。学技能是跨周/跨月项目，价值 80% 在**重复练习**而非勾完清单，直接套模板两周后就失效。因此新增独立的学习路径模型与引擎，而不是再加一个 `learning` 分支。
- **Core 拆解引擎（离线可用）：已完成。** 新增 `Packages/AssistantCore/Sources/AssistantCore/SkillPathPlanner.swift`（纯函数、无平台依赖）：`SkillCategory`（编程/外语/运动/通用）+ 四阶段骨架（启动 10% / 基础 30% / 刻意练习 40% / 实战输出 20%）+ 每阶段 3–5 条里程碑与 1 条周期练习打卡；每个阶段带**可观察的通关标准**（如「不查资料能写出基础语法」，不是「学会 Python」）。意图识别需同时命中「学习动词」与「技能词典」，避免把「帮我规划露营」误判成学习；`parseCommitment` 支持「每天半小时 / 每周 5 小时 + 3 个月 / 12 周」与中文数字。练习频次按每周投入自适应：≤150 分钟走每日打卡，否则隔天，保证单次不低于 20 分钟。
- **数据模型：已完成。** 新增 `Assistant/Models/SkillPathModel.swift`（`SkillPath` / `SkillStage` / `SkillPracticeLog`），沿用项目已有的 `LifeEventProject` 惯例——用 `id` 软关联而非 SwiftData 关系，规避迁移风险；未展开阶段的任务以 JSON 模板存在 `SkillStage.tasksJSON`，解锁时才写成真实待办。`TodoItem` 新增可选 `skillPathID` / `skillStageIndex` / `isSkillPractice` / `skillPracticeMinutes`（均有默认值，旧库轻量迁移安全），新类型 `TodoType.skillLearning`（图标 book.fill，首页归入「日常待办」分组）。三个模型已注册进 `Persistence` 的 `Schema`。
- **关键修复：重复待办会丢关联。** `TodoItem.markAsCompleted` 为周期性待办生成下一期时，原本不复制任何新字段——打卡一次后生成的下一期会脱离原学习路径。已补上四个新字段的复制；同时在该方法内写入一条 `SkillPracticeLog` 作为打卡流水（无需在 7 个完成入口各埋 hook，统计以此为准）。
- **服务层：已完成。** `Assistant/Services/SkillPathManager.swift`：`save`（只展开第 0 阶段，里程碑带截止日、练习带 `recurrenceRule` 并安排通知）、`refresh`（里程碑全部完成即通关 → 解锁并展开下一阶段 → 全部走完置为已完成）、`refreshAll` / `progressByPath`（**一次全量读取算完所有路径**，避免列表每行各扫三次全表）、`streakDays`（今天未打卡允许从昨天起算，隔一天断）。
- **语音与 UI 接线：已完成。** `VoiceIntentProcessor` 中学习判断**排在通用规划之前**（否则「我想学 Python」会被平铺清单模板吃掉）；`VoiceIntentResult` / `DialogueMessage` 增加 `skillPlan`，对话页新增 `SkillPlanCardView`（阶段概览条 + 第一阶段任务与打卡频次 + 「开启学习路径」）。新增 `Assistant/Features/SkillPathListView.swift`（列表进度卡 / 详情页阶段推进与任务勾选 / 手动新建表单，含空状态与无障碍标签）；入口在「生活 → 学习成长 → 技能学习路径」。
- **验证：** `swift test` **58 项通过**（新增 `SkillPathPlannerTests` 23 项，覆盖三类识别、技能名抽取、投入与周期解析、阶段天数守恒、练习频次、边界截断）；`xcodegen generate` 后 `xcodebuild` generic iOS device Debug 主应用 + 扩展 **BUILD SUCCEEDED**。
- **踩坑记录：** 正则里把 `NUM` 展开成裸 alternation 会被 `|` 把整个模式拆散；且 Swift tuple 下标从 0 起，`(g1,g2,g3)` 的 `.1` 是第二个元素不是 group1——已改为命名元素返回，避免再踩。新增 `TodoType.skillLearning` 后 `TodoListView` 两处**穷举 switch** 编译失败（分类映射与占位文案），已补。
- **遗留：** ① 学习路径尚未纳入备份 DTO（P0「全量备份」现有缺口，需扩 `DataMigrationService`）；② 桌面小组件快照未接「今日练习」（现有小号「今日支出」组件可升级显示剩余额度与今日练习）；③ 端侧模型接入前，阶段内任务全靠模板，AI 细化只能作为后续增强层；④ 未做真机验证（阶段通关后自动展开下一阶段、每日 21:00 练习提醒、连续天数跨天计算）。

## 2026-10-12 续：学习路径补齐备份与桌面组件（收尾方案 B 遗留两项）

- **备份 DTO 纳入学习路径（P0「全量备份」补上最大缺口）。** `DataMigrationService` 新增 `SkillPathDTO` / `SkillStageDTO` / `SkillPracticeLogDTO` 三个可选数组（沿用 `expenses?` 的可选模式，旧备份缺字段时解码为 nil，兼容不破）；`TodoDTO` 补 `skillPathID` / `skillStageIndex` / `isSkillPractice` / `skillPracticeMinutes` 四个可选字段。导出端 `buildBackupPackage` 全量映射（打卡流水的 `practicedAt` 一并带走，换设备后连续天数不断）；导入端 `restore` 按「路径 → 阶段 → 打卡」顺序还原（软关联无外键约束，顺序错了会出孤儿数据），覆盖策略先删三个模型，合并策略按 ID 去重；`validate` 增加三类 ID 唯一性校验，并**校验阶段/流水的 pathID 必须挂在已备份路径上**，避免损坏包装成孤儿数据。备份摘要页在旧数据行下方条件展示「学习路径 N 条 | 阶段 N | 打卡 N 次」。
- **`SkillStage` 还原保留原始 base64 模板。** 直接赋 `tasksJSON` 而非「解码成 `[PlannedSkillTask]` 再编码」，避免 JSONEncoder 的键序/表示漂移导致模板与导出时不一致。
- **桌面小组件接入「今日练习」。** `WidgetSnapshot` 新增可选 `todayPractice: WidgetPracticeEntry?`（旧快照缺字段解码为 nil，App Group 里已存的旧数据不炸）；`WidgetGlanceMode` 加 `practice` 模式，长按组件即可在「待取快递码 / 今日支出 / 今日练习」间切换，三种锁屏家族（圆形=连续天数火焰、矩形=技能名+打卡状态、行内=🎯 一行）分别渲染。快照构建取**最近活跃的进行中路径**（最近打卡优先，否则最近开始），`isPracticedToday` 按打卡流水当天判断。
- **深链 `assistant://skills`。** `NavigationRouter` 新分支切到生活档案并置 `requestedSkillPathList`，`LifeVaultView` 消费后直接推入 `SkillPathListView`（新增 `VaultDestination.skillPaths`，与既有 statPill 导航机制一致）。
- **快照刷新点补齐。** 之前只有启动/回前台/通知交互才刷快照，打卡后桌面最多滞后 15 分钟。现在三处完成动作都会即时刷：学习路径详情页勾选、手动新建路径、语音对话「开启学习路径」；另外给**主待办列表的通用勾选**也补了刷新（练习从首页勾选同样即时反映，顺带修掉旧问题：首页勾完待办桌面组件不更新）。
- **踩坑：** ① SwiftUI `ViewModifier` 里把 `switch family` 挪进计算属性后，`default: content` 里的 `content` 不在作用域 → 编译失败；正确做法是 switch 留在 `body(content:)` 里，只把各 accessory 分支抽成无 `default` 的小计算属性。② `DataMigrationService` 用 `SkillCategory` 需 `import AssistantCore`（app target 不会自动可见 package 类型）。③ 编辑文件路径笔误两次（workspace-01/workspace-assistant-01），已改正。
- **验证：** `swift test` **58 项通过 0 失败**；`xcodegen generate` 后 `xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**，`Assistant.app` 与 `AssistantWidgetExtension.appex` 产物均已生成。
- **仍遗留：** ① P0 备份范围里的「设置/偏好」仍未纳入备份（学习路径已补齐，此项收口到设置类）；② 端侧模型接入前阶段内任务全靠模板；③ 未真机验证：备份导出→换设备导入后阶段解锁状态与连续天数是否一致、锁屏练习小组件三种家族实际渲染、`assistant://skills` 深链跳转。

## 2026-10-12 续二：偏好设置纳入备份（P0「全量备份」收官）

- **收录原则：只收「用户明确表达过的偏好」。** `AssistantCore` 新增 `SettingsSnapshot.swift`：`SettingsValue`（string/bool/int/double/data 五型）+ `SettingsSnapshotDTO`（entries + wallpaperImageData）+ `AssistantSettingsKeys` 白名单。**白名单而非全量导出**——UserDefaults 里混着安全材料与设备缓存，必须逐键过审；漏登记的键只是不进备份，不报错。已收录 9 个 String（助手名/称呼/模式/保留策略/背景/语言/生活画像/长辈字号/出门场景）、13 个 Bool（语音朗读/敏感详情/剪贴板摄取/长辈模式四件套/自适应排序/日报周报月报开关/悬浮球/天气预警）、2 个 Int、7 个 Double、1 个 Data（首页 Tab 顺序）。
- **明确排除（注释写明理由）：** 应用锁 PIN 哈希等安全材料、LLM 远程上下文同意（隐私同意不能替用户搬到新设备）、LLM 开发者端点（局域网地址）、天气/城市/剪贴板计数等设备缓存、权限引导标记、各审计器的「今日已处理」日期。`SettingsSnapshotTests.testWhitelistExcludesSecurityAndCacheKeys` 是一条**纪律测试**：谁把这类键登记进白名单，它就报错。
- **类型保真是本项的核心风险。** UserDefaults 里 Bool/Double/Int 底层都是 NSNumber——`true as? Int` 会桥接成 1，`8.0` 与 `8` 在 NSNumber 层无法区分。不记录类型的话还原会把 `true` 写成 `1.0`、模糊度 `12.5` 取整成 `12`。因此快照每个值都带显式类型标签，`SettingsSnapshotTests` 10 项覆盖：五型往返保真、true 与 1.0 不串、小数完整保留、旧形状（无 wallpaperImageData 键）兼容、`apply(to:)` 写盘类型正确、白名单无重复/非空/含语言键/排除安全缓存键。
- **DTO 放 Core 而非 app target 的原因：** app target 没有测试 scheme（工程只有 Assistant / AssistantCore 两个 scheme，既有备份 DTO 一直无测试）。把纯数据的部分放进 Core 才能真跑单测；收集/还原逻辑留在 app（依赖 UserDefaults 与各单例）。
- **单一出处：** `LanguageManager.storageKey` 改指向 `AssistantSettingsKeys.languagePreference`，语言键不再有两份定义。
- **还原时序：** 偏好设置放在 `context.save()` **之后**应用——UserDefaults 无法随 `context.rollback()` 回滚，必须等数据库落库成功再动设置，避免「库回滚了、偏好却已写盘」。仅覆盖策略还原设置；**合并策略只搬数据、不改本机行为**（用户在新设备上的偏好选择应被保留）。
- **写盘后重载：** `AppBackgroundManager.reloadFromDefaults()` / `restoreCustomImage(data:)` / `TabBarManager.reloadFromDefaults()`（后者为此把 `activeTabs` 补了默认值，否则 init 调方法触发「初始化未完成」编译错）；语言走 `LanguageManager.selectedLanguage` setter 同步 AppleLanguages。壁纸边界：备份无壁纸字节但样式是自定义照片 → 回落系统样式，避免设置页显示与渲染不符。
- **导出只收已设置的键：** `object(forKey:) != nil` 才进备份，否则会把「用户从未设置、默认值兜底」的键也搬过去，覆盖新设备的合理默认。
- **验证：** `swift test` **68 项通过 0 失败**（新增 10 项）；`xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**。备份摘要页新增「偏好设置: N 项」条件行。
- **仍遗留：** ① 未真机验证完整迁移链路（导出加密包→新设备导入→逐类核对，尤其是设置类与阶段解锁状态）；② 端侧模型接入前学习路径阶段内任务全靠模板。

## 2026-10-12 续三：P0 数据与安全风险收官（版本化迁移 / 密码库取证 / 备份 KDF）

P0 五项至此全部完成。本轮把三项「部分完成」推到可自动验证的终态，核心手段是**把纯加密/迁移逻辑下沉 AssistantCore 换来了真实单测**（此前这些代码在 app target 里，工程只有 Assistant / AssistantCore 两个 scheme，app 无测试能力）。

- **P0-1 数据库显式版本化迁移：已完成。** `Persistence.swift` 新增 `AssistantSchemaV1`（初始提交的 13 个模型，从 git `cdecc7b` 提取）/ `AssistantSchemaV2`（当前 34 个）与 `AssistantMigrationPlan`（`.lightweight` 单阶段——V1→V2 全是「加字段带默认值 + 加模型」）。`ModelContainer(for:migrationPlan:configurations:)` 打开；打开失败不再只说一句「打不开」，`diagnose` 附带各库文件路径与体积，恢复页可引导导出；DEBUG 下 `assertSchemaCoverage` 断言 V1 ⊆ V2（防手滑删模型导致旧库升级静默丢表）。**API 坑**：本 SDK 的 `MigrationStage.lightweight` 标签是 `fromVersion:toVersion:` 但实参类型是 `any VersionedSchema.Type`（标签与类型不符），已按 SDK 实际形态接线。
- **P0-1 演练包 `scripts/migration-drill/`（16 项断言全过）。** 独立 SwiftPM 可执行包（不能塞进 AssistantCore：需要 `@Model` 宏与真实文件操作，属一次性验证工具）。① 旧库升级：V1 库写入 2 条 → 带迁移计划打开 → 记录数/字段值不变、新字段默认 nil、新模型表可写；② 损坏库：破坏数据区后打开（SQLite 对损坏是惰性的，落空闲页时甚至不报错——真正的验收不是「打开必须失败」），硬断言在**文件原样保留**：存在、SHA256 逐字节不变、体积不变；③ 未知结构库：打不开且内容不改，用户可导出交新版本处理；④ 结构回归防线：直接读仓库内真实 `Persistence.swift`，断言不含 `removeItem`/「重置数据库」字样、必须含迁移计划与 diagnose——谁把删库逻辑写回来，演练立刻红。**环境坑**：裸 `swiftc`/解释器跑不了 `@Model` 宏（sandbox_apply 挡插件服务器）；SwiftPM 路径可以，但 `swift run`/`swift test` 需加 `--disable-sandbox`（否则清单编译阶段的 testing 插件被沙箱拦，报 "Invalid manifest"）。
- **P0-2 密码库：加密核心下沉 + 真问题修复。** 新增 `AssistantCore/PasswordVaultCipher.swift`：`aesgcm:v1:` 前缀判定、AES-GCM 加解密（密钥由 app 侧 Keychain 注入）、`migrate` 只搬明文且幂等（空串跳过、密文不动）。app 侧 `PasswordVaultCrypto` 瘦身为 Keychain 保管 + 迁移入口，`PasswordVaultItem` 遵循 `PasswordVaultRecord` 协议（class 约束——迁移要就地改写，值类型不回写）。
- **P0-2 取证测试抓到一个真漏洞：SQLite 的 UPDATE 不擦旧字节。** 测试先写明文记录→迁移成密文→保存，再扫 `.store`/`.store-wal` 原始字节：**明文仍在磁盘上**（旧行留在空闲页、WAL 里存着明文版旧帧）。只做「加密+保存」根本过不了「持久化文件中搜不到原始密码」的验收。修复：新增 `AssistantCore/SQLiteMaintenance.swift`——`PRAGMA secure_delete = ON`（此后 UPDATE/DELETE 先零填充旧内容）+ `VACUUM`（重写整个库文件，空闲页连同明文一起消失）+ `wal_checkpoint(TRUNCATE)`（清掉 WAL 旧帧）。app 侧迁移后调用；失败（库忙）置 `password_vault_purge_pending_v1` 标记下次启动重试——清不掉不假装成功。测试清理前后各扫一次：「清理前：有（符合预期）→ 清理后：无」，并验证 VACUUM 后库仍可正常打开读取。
- **P0-4 备份 KDF 下沉 + 兼容验证。** 新增 `AssistantCore/BackupEnvelopeCrypto.swift`：口令 8–64 位、PBKDF2-HMAC-SHA256 默认 310,000 轮、32 字节每包独立随机盐、迭代次数合法区间 10 万–200 万（导入方校验，防「迭代 1 次」的伪造封套被瞬间解开）、AES-GCM 认证失败统一归 `authenticationFailed`（不向用户区分口令错与篡改，避免变成口令预言机）。v1 封套保留 HKDF 只读路径。`EncryptedBackupEnvelope.currentVersion/defaultIterations` 改指向 Core 常量（单一出处）；导出/解锁改调 `validatePin`+`makeSalt`+`seal` 与 `openPayload`（版本分发在 Core），错误码映射回 `MigrationCryptoError`。
- **验证：** `swift test` **92 项通过 0 失败**（新增密码库 12 项 + 备份加密 12 项，含 SwiftData 取证测试与 v1 兼容）；`scripts/migration-drill` **16 项断言全过**；`xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**（主应用 + 扩展）。
- **仍遗留：** ① 未真机验证：旧库升级链路（v1 库→v2）、迁移后 VACUUM 在真机库忙时的重试、备份 v1→v2 跨版本导入；② 端侧模型接入前学习路径阶段内任务全靠模板；③ 备份/迁移的故障注入（附件写失败、进程中断）仍未自动化。

## 2026-10-13 实施记录（流畅度第二轮：剩余全表读与重复计算收尾）

- **本轮范围。** 上一轮已对主页三大数据页（待办分类/记账统计/周期报告）做了内容指纹缓存、启动 VACUUM 移出主线程、LLM 流式回显限频、小组件/通知对账谓词化。本轮审查后继续修剩余热点：
- **新建待办的 min(sortOrder) 下推 SQLite。** 首页新建/语音建待办/扫码建待办三处都为算一个最小排序值把整张待办表（含全部已完成历史）物化到主线程；`TodoItem.minimumSortOrder(in:)` 用 sortBy + fetchLimit 1 下沉给 SQLite，三处调用点统一替换。
- **语音记账/查账不再拉整本账。** `recordExpense` 回显的「当日累计/本月累计」改日月窗口谓词取数；`queryExpenses` 只取「本周 ∪ 本月 ∪ 前天前」窗口（降序排序下推），窗口无账时用 fetchLimit 1 回查最近一笔，保持对久远零散记录的原有答复口径。
- **收纳页三重优化。** ①关联记账 @Query 加谓词（只拉 linkedItemID 非空的支出）；②linkedTotals/costTrackedSummaries/filteredItems 三个派生属性接入内容指纹引用缓存（body 内 10+ 处访问同一次渲染各只算一次）；③行卡片照片改 `RowThumbnailCache`：ImageIO 降采样 + NSCache（键含字节数与 updatedAt，换图/编辑必换键不串旧图），消除行重绘时整图解码的卡滚。编辑表单的关联投入归集也改为 pathID 谓词定向取数。
- **学习路径不再扫全待办表。** `refreshAll/progressByPath` 的 todos 拉取加 `skillPathID != nil` 谓词；`refresh(path:)/progress(for:)`（勾选完成/进页时的热路径）改为按 pathID 定向取 stages/todos/logs。
- **今日时间轴布局缓存。** TimelineView 每分钟重绘一次，原实现 rangeStart/rangeEnd/画布两处 filter 每次访问都重建并排序全量条目数组；现 allEntries/freeSlots/rangeStart/rangeEnd 共用分钟粒度指纹缓存（与每分钟重绘节奏一致，不引入额外刷新成本）。
- **API 坑：** 本 SDK 的 `Calendar.dateInterval(of:for:)` 返回 `DateInterval`（类）而非旧版 `(start:, end:)` 元组，`?? (date, date)` 式回退直接编译失败，已改 `.start/.end` 可选链。
- **未动（有意保留）：** 首页 `@Query` 仍读全部待办（分类缓存已兼容，改谓词需分页重构，风险大于收益）；锁屏 blur(0) 离屏合成成本待 Instruments 实测（代码内已注）；周期报告 generateReport 仍一次全表扫描后内存分档（视图层已有缓存，每次打开只算一次）；录音电平 0.06s 定时器只在录音会话内活跃。
- **验证：** `xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**（无新增告警）。仍待真机验证：大账本/万件待办下的滚动与新建响应、收纳页长列表照片滚动流畅度。

## 2026-10-13 实施记录（手表/Mac 联动交互：把「点不到关闭」改成一键收卡）

- **问题根因。** ①无 watchOS App 时手表智能叠放的实时活动整卡不可交互，而护航/清点两个场景上岛后根本没有可点的伴随入口，手腕上关不掉；②锁屏/Mac 通知中心镜像卡片里「已取件」「已出发」等按钮热区只贴着文字一小条，Mac 镜面上难点中；③取件销号通知只有销号动作，没有「先不销号、只收卡」的关闭入口。
- **卡片热区放大（AssistantLiveActivities，iPhone 锁屏/灵动岛展开态/Mac 镜像共用）。** 取件码逐件销号改为整行 Button + contentShape；行程「已出发，关闭卡片」从右侧小按钮改为通栏胶囊大按钮（锁屏重排为上下结构）；清点行加垂直 padding；灵动岛展开态的结束护航按钮同样通栏胶囊化（岛底部高度有限，只在现有按钮上加高不加新行）。
- **一键收卡 Intent（WidgetShared/WidgetIntents）。** 新增 `CompleteAllParcelsIntent` / `CheckAllDepartureItemsIntent`：逗号分隔 UUID 标量参数（Button(intent:) 携数组在扩展侧不便序列化），主应用进程走 hook 循环、扩展进程逐件 enqueue+本地突变，复用既有对账链路不新增命令类型；锁屏卡片多件/多项未确认时追加通栏「全部取齐/全部带齐，关闭卡片」。
- **手表侧伴随控制通知（LiveActivityService 尾部新增 LiveActivityControlNotifications）。** 护航/清点上岛时同步挂一条静默通知，action 即「已出发，关闭卡片」/「全部带齐，关闭卡片」（通知 action 是手腕上唯一可点的原生大按钮，与取件销号通知同一套路）；活动被其它路径收掉后回前台 reconcile 摘掉幽灵通知；NavigationRouter didReceive 新增 liveActivityControl 分支。取件销号通知补第三个动作「关闭卡片（先不销号）」并把「关闭」排在第二位（手表只露前两个 action），点它只收卡不改动待办。
- **顺带修正：** TodoListView 行内二维码快捷按钮引用了不存在的 `isShowingQRCodeSheet`（外部会话遗留的半成品改动），改接行视图已有的 `onShowQRCode?()` 回调，修复了存量编译失败。
- **验证：** `xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**。待真机验收：手表点伴随通知收卡、Mac 通知中心镜像卡片点通栏按钮、灵动岛展开态新布局不截断。

## 2026-10-14 实施记录（万能投喂口执行后倒计时自动关闭与时长配置）

- **需求背景：** 用户反馈万能投喂口执行动作（记账、待办、备忘）后，总需要手动点击右上角「关闭」退出弹窗；希望执行完成后支持倒计时（默认 3 秒）自动关闭，并在弹窗上清晰展示倒计时，同时在设置中允许自由调节时长或关闭自动关闭。
- **倒计时生命周期与防误触机制：**
  - **触发时机：** 仅当用户在投喂口完成拆解并点击「确认执行」（`phase == .executed`，回执生成）后启动倒计时；在 `idle`、`planning`、`confirm` 阶段绝不启动，避免打断用户的输入或参数微调。
  - **全链路防误触：** 若用户点击「一键撤销」(`undoAll`)、「继续投喂」(`resetForNextFeed`)、手动关闭或页面销毁，倒计时任务立即取消 (`cancelCountdown`)；
  - **暂停与恢复：** 回执区提供「暂停关闭 / 恢复倒计时」按钮及状态徽标，用户若需核对记账或待办结果可随时暂停倒计时，右上角标题同步显示 `关闭 (已暂停)`。
- **UI 呈现与多处配置入口：**
  - **顶部导航栏关闭按钮：** 倒计时期间动态显示 `关闭 (Xs)`（如 `关闭 (3s)`），暂停时显示 `关闭 (已暂停)`；点击后立即停止任务并关闭弹窗。
  - **回执区完成横幅：** 顶栏新增胶囊计时徽标（`Xs 后自动关闭` / `倒计时已暂停`），下方紧随操作横幅附带说明与暂停/恢复按钮。
  - **投喂口快捷调节：** `OmniboxView` 顶部卡片在剪贴板自动投喂开关下方新增「完成后自动关闭」下拉菜单，支持一键切换 `不自动关闭 / 1秒 / 2秒 / 3秒 / 5秒 / 10秒`。
  - **系统设置页集成：** `SettingsView` 增加「万能投喂口」专属设置区块，包含剪贴板自动识别开关与「投喂完成后自动关闭弹窗」时长选择器（0/1/2/3/5/10 秒，默认 3 秒），持久化存储于 `@AppStorage("omnibox_auto_dismiss_seconds")`。
- **验证：**
  - `AssistantCore` 单元测试套件全部通过（128 tests passed, 0 failures）；
  - `xcodebuild` generic iOS device Debug **BUILD SUCCEEDED**。
