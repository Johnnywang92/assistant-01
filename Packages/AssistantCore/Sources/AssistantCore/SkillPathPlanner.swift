import Foundation

/// 技能类别。决定了学习路径四个阶段的具体内容骨架。
public enum SkillCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case programming
    case language
    case fitness
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .programming: "编程与技术"
        case .language: "外语学习"
        case .fitness: "运动与健身"
        case .generic: "通用技能"
        }
    }

    public var icon: String {
        switch self {
        case .programming: "chevron.left.forwardslash.chevron.right"
        case .language: "character.book.closed.fill"
        case .fitness: "figure.run"
        case .generic: "sparkles"
        }
    }
}

/// 拆解出的任务类型：一次性里程碑，或需要重复执行的练习打卡。
public enum PlannedTaskKind: String, Codable, Sendable {
    case milestone
    case practice
}

/// 学习路径中的一条待办草稿
public struct PlannedSkillTask: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var kind: PlannedTaskKind
    /// 0 表示一次性里程碑；大于 0 表示每 N 天重复一次的练习打卡
    public var recurrenceDays: Int
    /// 单次投入分钟数
    public var minutes: Int
    /// 相对路径开始日的到期天偏移（仅一次性里程碑使用）
    public var dayOffset: Int

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        kind: PlannedTaskKind,
        recurrenceDays: Int = 0,
        minutes: Int = 0,
        dayOffset: Int = 0
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.recurrenceDays = recurrenceDays
        self.minutes = minutes
        self.dayOffset = dayOffset
    }
}

/// 学习路径中的一个阶段
public struct PlannedSkillStage: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var index: Int
    public var name: String
    /// 可观察、可验证的通关标准
    public var acceptance: String
    public var plannedDays: Int
    public var tasks: [PlannedSkillTask]

    public init(
        id: UUID = UUID(),
        index: Int,
        name: String,
        acceptance: String,
        plannedDays: Int,
        tasks: [PlannedSkillTask]
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.acceptance = acceptance
        self.plannedDays = plannedDays
        self.tasks = tasks
    }

    public var milestones: [PlannedSkillTask] { tasks.filter { $0.kind == .milestone } }
    public var practices: [PlannedSkillTask] { tasks.filter { $0.kind == .practice } }
}

/// 尚未写入数据库的完整学习路径草稿
public struct SkillPathDraft: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var category: SkillCategory
    /// 用可观察行为描述的目标，而非「学会 XX」这类无法验收的表述
    public var goal: String
    public var weeklyMinutes: Int
    public var totalWeeks: Int
    public var stages: [PlannedSkillStage]

    public init(
        id: UUID = UUID(),
        title: String,
        category: SkillCategory,
        goal: String,
        weeklyMinutes: Int,
        totalWeeks: Int,
        stages: [PlannedSkillStage]
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.goal = goal
        self.weeklyMinutes = weeklyMinutes
        self.totalWeeks = totalWeeks
        self.stages = stages
    }

    public var totalDays: Int { max(7, totalWeeks * 7) }
    public var dailyMinutes: Int { max(5, Int((Double(weeklyMinutes) / 7.0).rounded())) }

    /// 截止日落在路径区间内的总任务数
    public var taskCount: Int { stages.reduce(0) { $0 + $1.tasks.count } }

    /// 一句话概括：阶段串 + 投入 + 展开策略
    public var summaryText: String {
        let stageNames = stages.map { $0.name }.joined(separator: " → ")
        let firstCount = stages.first?.tasks.count ?? 0
        return "我把「\(title)」拆成了 \(stages.count) 个阶段的学习路径：\(stageNames)。\n"
            + "每周投入约 \(weeklyMinutes) 分钟，预计 \(totalWeeks) 周。"
            + "先只展开第一阶段（\(firstCount) 条），通关后自动解锁下一阶段——"
            + "学技能靠的是持续练习，不是一次性勾完几十条清单。"
    }
}

/// 技能学习路径拆解引擎（纯函数、离线可用、不依赖端侧模型）
public enum SkillPathPlanner {

    public static let defaultWeeklyMinutes = 150
    public static let defaultWeeks = 12

    // MARK: - 意图识别

    private static let learningVerbs = [
        "学会", "学一下", "学一学", "学习", "想学", "要学", "开始学", "自学", "入门", "零基础", "从零",
        "掌握", "练会", "练成", "怎么学", "如何学", "上手", "精通", "提高我的", "提升我的"
    ]

    /// 判断输入是否表达「学习某项技能」的意图
    public static func isLearningQuery(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if detectCategory(in: trimmed) == nil { return false }
        return learningVerbs.contains { trimmed.contains($0) }
            || trimmed.contains("学") && trimmed.count <= 24
    }

    /// 依据关键词识别技能类别；识别不出返回 nil，避免把普通规划误判为学习
    public static func detectCategory(in text: String) -> SkillCategory? {
        let lower = text.lowercased()

        let programmingKeys = [
            "编程", "写代码", "代码", "程序", "开发", "前端", "后端", "全栈", "算法", "数据结构",
            "python", "swift", "golang", "go语言", "rust", "java", "kotlin", "javascript", "typescript",
            "react", "vue", "node", "sql", "linux", "git", "docker", "安卓", "ios开发", "小程序",
            "机器学习", "深度学习", "ai", "大模型", "数据分析", "爬虫", "面试", "leetcode", "刷题", "运维"
        ]
        if programmingKeys.contains(where: { lower.contains($0) }) { return .programming }

        let languageKeys = [
            "英语", "日语", "韩语", "法语", "德语", "西语", "西班牙语", "俄语", "意大利语", "泰语", "粤语",
            "雅思", "托福", "托业", "gre", "考研英语", "背单词", "单词", "口语", "听力", "语法", "发音",
            "外语", "外教", "原版书", "字幕", "english", "japanese", "korean", "ielts", "toefl"
        ]
        if languageKeys.contains(where: { lower.contains($0) }) { return .language }

        let fitnessKeys = [
            "健身", "跑步", "游泳", "瑜伽", "力量", "增肌", "减脂", "减肥", "塑形", "马拉松", "半马",
            "引体向上", "俯卧撑", "深蹲", "硬拉", "卧推", "骑行", "骑车", "网球", "羽毛球", "乒乓球",
            "篮球", "足球", "滑雪", "攀岩", "拳击", "格斗", "拉伸", "体脂", "配速", "pb", "keep"
        ]
        if fitnessKeys.contains(where: { lower.contains($0) }) { return .fitness }

        return nil
    }

    /// 从用户输入中抽出技能名称
    public static func extractSkillName(from text: String, category: SkillCategory) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "我想学习", "我想学", "我要学习", "我要学", "帮我学", "帮我拆解一下", "帮我拆解", "帮我规划一下", "帮我规划",
            "怎么学好", "怎么学", "如何学好", "如何学", "从零开始学", "零基础学", "开始学", "学会", "掌握", "学习", "学",
            "我想练会", "我想练成", "练会", "练成", "想练", "练好"
        ]
        for p in prefixes where clean.hasPrefix(p) {
            clean = String(clean.dropFirst(p.count))
            break
        }
        // 去掉句尾语气与标点
        clean = clean
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,。.！!？?、的了啊呢吧~ "))

        // 去掉时间投入描述，避免技能名里混入「每天半小时」
        let noisePatterns = [
            #"(每天|每周|每日|一周)\s*[0-9一二三四五六七八九十半两]+\s*(分钟|分|小时|个?小时|h)"#,
            #"[0-9]+\s*(周|个?月|天|年)(内|之内|后)?(学会|学完|搞定|拿下)?"#
        ]
        for pattern in noisePatterns {
            clean = clean.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，,。.！!？?、的 "))

        if clean.isEmpty || clean.count > 18 {
            return category.defaultSkillName
        }
        return clean
    }

    // MARK: - 投入与周期解析

    /// 解析「每天半小时 / 每周 5 小时」「3 个月 / 12 周」这类投入与周期描述
    public static func parseCommitment(in text: String) -> (weeklyMinutes: Int, totalWeeks: Int) {
        var weeklyMinutes = defaultWeeklyMinutes
        var weeks = defaultWeeks

        // 每天 X 分钟 / 小时
        if let m = firstMatch(in: text, pattern: #"(每天|每日|天天)\s*NUM\s*(分钟|分)"#) {
            if let v = numericValue(m.g2) { weeklyMinutes = Int((v * 7).rounded()) }
        } else if let m = firstMatch(in: text, pattern: #"(每天|每日|天天)\s*NUM\s*(小时|个小时|h|H)"#) {
            if let v = numericValue(m.g2) { weeklyMinutes = Int((v * 60 * 7).rounded()) }
        } else if let m = firstMatch(in: text, pattern: #"(每周|一周|每星期)\s*NUM\s*(小时|个小时|h|H)"#) {
            if let v = numericValue(m.g2) { weeklyMinutes = Int((v * 60).rounded()) }
        } else if let m = firstMatch(in: text, pattern: #"(每周|一周|每星期)\s*NUM\s*(分钟|分)"#) {
            if let v = numericValue(m.g2) { weeklyMinutes = Int(v.rounded()) }
        }

        // 周期
        if let m = firstMatch(in: text, pattern: #"NUM\s*(周|个?星期)(内|之内|后)?(学会|学完|搞定|拿下)?"#) {
            if let v = numericValue(m.g1) { weeks = Int(v.rounded()) }
        } else if let m = firstMatch(in: text, pattern: #"NUM\s*(个?月)(内|之内|后)?(学会|学完|搞定|拿下)?"#) {
            if let v = numericValue(m.g1) { weeks = Int((v * 4.34).rounded()) }
        } else if let m = firstMatch(in: text, pattern: #"NUM\s*(年)(内|之内|后)?(学会|学完|搞定|拿下)?"#) {
            if let v = numericValue(m.g1) { weeks = Int((v * 52).rounded()) }
        } else if let m = firstMatch(in: text, pattern: #"NUM\s*(天)(内|之内|后)?(学会|学完|搞定|拿下)?"#) {
            if let v = numericValue(m.g1) { weeks = max(2, Int((v / 7).rounded())) }
        }

        weeklyMinutes = min(max(30, weeklyMinutes), 1200)
        weeks = min(max(2, weeks), 104)
        return (weeklyMinutes, weeks)
    }

    // MARK: - 拆解

    /// 从自然语言输入直接生成学习路径草稿；无法识别技能类别时返回 nil
    public static func build(query: String) -> SkillPathDraft? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let category = detectCategory(in: text) else { return nil }
        let skill = extractSkillName(from: text, category: category)
        let commitment = parseCommitment(in: text)
        return build(
            skillName: skill,
            category: category,
            weeklyMinutes: commitment.weeklyMinutes,
            weeks: commitment.totalWeeks
        )
    }

    /// 按阶段权重把总时长拆成四阶段，并填充阶段任务
    public static func build(
        skillName: String,
        category: SkillCategory,
        weeklyMinutes: Int,
        weeks: Int
    ) -> SkillPathDraft {
        let weekly = min(max(30, weeklyMinutes), 1200)
        let totalWeeks = min(max(2, weeks), 104)
        let totalDays = totalWeeks * 7

        let templates = stageTemplates(for: category)
        let weightSum = templates.reduce(0) { $0 + $1.weight }

        // 练习频次：每周投入小于等于 150 分钟按每日打卡，否则隔天一次（保证单次时长不低于 20 分钟）
        let recurrenceDays = weekly <= 150 ? 1 : 2
        let sessionsPerWeek = Double(7) / Double(recurrenceDays)
        let perSessionMinutes = max(10, Int((Double(weekly) / sessionsPerWeek).rounded()))

        var stages: [PlannedSkillStage] = []
        var consumedDays = 0
        for (idx, template) in templates.enumerated() {
            let isLast = idx == templates.count - 1
            var plannedDays: Int
            if isLast {
                plannedDays = max(3, totalDays - consumedDays)
            } else {
                plannedDays = max(3, Int((Double(totalDays) * template.weight / weightSum).rounded()))
            }
            consumedDays += plannedDays

            var tasks: [PlannedSkillTask] = []
            let milestoneCount = template.milestones.count
            for (mIdx, milestone) in template.milestones.enumerated() {
                let offset = consumedDays - plannedDays
                    + Int((Double(plannedDays) * Double(mIdx + 1) / Double(milestoneCount + 1)).rounded())
                tasks.append(
                    PlannedSkillTask(
                        title: milestone.0,
                        detail: milestone.1,
                        kind: .milestone,
                        recurrenceDays: 0,
                        minutes: max(15, perSessionMinutes),
                        dayOffset: min(offset, totalDays)
                    )
                )
            }
            tasks.append(
                PlannedSkillTask(
                    title: template.practice.0,
                    detail: template.practice.1,
                    kind: .practice,
                    recurrenceDays: recurrenceDays,
                    minutes: perSessionMinutes,
                    dayOffset: consumedDays - plannedDays
                )
            )

            stages.append(
                PlannedSkillStage(
                    index: idx,
                    name: template.name,
                    acceptance: template.acceptance,
                    plannedDays: plannedDays,
                    tasks: tasks
                )
            )
        }

        return SkillPathDraft(
            title: "\(category.verbPrefix)\(skillName)",
            category: category,
            goal: category.goalTemplate(skill: skillName),
            weeklyMinutes: weekly,
            totalWeeks: totalWeeks,
            stages: stages
        )
    }

    // MARK: - 阶段模板

    private struct StageTemplate {
        let weight: Double
        let name: String
        let acceptance: String
        let milestones: [(String, String)]
        let practice: (String, String)
    }

    private static func stageTemplates(for category: SkillCategory) -> [StageTemplate] {
        switch category {
        case .programming:
            [
                StageTemplate(
                    weight: 10,
                    name: "启动期",
                    acceptance: "环境跑通、学习资源锁定，能独立写出并运行第一个程序",
                    milestones: [
                        ("搭建开发环境：装好工具链与编辑器，跑通 Hello World", "把环境配置步骤记录下来，换机器时可复现"),
                        ("选定唯一主学习资源（一门课或一本书）", "同时开三门是半途而废的主因，先只跟一个体系"),
                        ("建一个练手仓库，约定每天提交一次", "仓库即学习日志，回看 diff 就是复习")
                    ],
                    practice: ("每日编码打卡", "哪怕只写 15 分钟，也要让手指保持每天碰代码的节奏")
                ),
                StageTemplate(
                    weight: 30,
                    name: "基础期",
                    acceptance: "不查资料也能写出基础语法与常用数据结构的典型操作",
                    milestones: [
                        ("过一遍核心语法：变量、控制流、函数与错误处理", "用自己的话写一份 cheat sheet"),
                        ("掌握该语言最常用的数据结构与标准库 API", "列表/字典/集合各写 5 个操作练习"),
                        ("完成 20 道入门级练习题", "错题单独归档，标注卡住的原因"),
                        ("读懂一份别人写的简单项目代码", "先跑起来，再逐文件画调用关系")
                    ],
                    practice: ("每日基础练习", "重做昨天的错题 + 写 30 行新代码")
                ),
                StageTemplate(
                    weight: 40,
                    name: "刻意练习期",
                    acceptance: "独立实现一个小项目的核心链路，卡点有记录、有解法",
                    milestones: [
                        ("选定一个中等难度小项目并写出功能清单", "范围写死，中途不加需求"),
                        ("实现核心链路，跑通最小可用版本", "先让它跑起来，再谈优雅"),
                        ("针对反复卡住的知识点做专项突破", "每个卡点写成一篇 300 字笔记"),
                        ("读一份优秀开源代码并做结构笔记", "重点看它怎么组织模块与处理错误"),
                        ("给自己的项目写单元测试与 README", "能讲清楚怎么跑起来")
                    ],
                    practice: ("每日项目推进", "每次只攻一个小功能，提交信息写清做了什么")
                ),
                StageTemplate(
                    weight: 20,
                    name: "实战输出期",
                    acceptance: "有一个可运行的完整项目与一篇公开复盘",
                    milestones: [
                        ("完成项目并部署或打包，让别人能真正用上", "真实用户反馈最值钱"),
                        ("写一篇技术复盘：踩过的坑与下一步", "输出倒逼输入，讲不清就是没懂"),
                        ("把项目分享到社区或简历", "收集至少一条外部反馈")
                    ],
                    practice: ("每周复盘与维护", "整理本周学到的新知，修掉遗留 issue")
                )
            ]
        case .language:
            [
                StageTemplate(
                    weight: 10,
                    name: "启动期",
                    acceptance: "资源与场景目标锁定，完成一次水平基线测试",
                    milestones: [
                        ("确定目标场景：考试、工作还是日常交流", "目标不同，学习内容差别很大"),
                        ("选定唯一主教材或 App，配一份听力材料", "材料宁少勿多，坚持跟完一套"),
                        ("做一次基线测试：词汇量或一段自我介绍录音", "留档，一个月后回听对比"),
                        ("准备生词本与每日固定学习时段", "把学习绑在一个已有习惯上更容易坚持")
                    ],
                    practice: ("每日接触目标语言", "哪怕 10 分钟听力泛听，保持耳朵在线")
                ),
                StageTemplate(
                    weight: 30,
                    name: "基础期",
                    acceptance: "掌握高频 1000 词与核心句型，能听懂慢速材料大意",
                    milestones: [
                        ("刷完高频 1000 词，按场景而非字母顺序分组", "动词与搭配优先于生僻名词"),
                        ("过一遍核心语法框架：时态、语序、基本从句", "语法是脚手架，不要陷进去"),
                        ("每天做 15 分钟影子跟读（shadowing）", "跟读比背单词更接近真实口语"),
                        ("用目标语言写 20 句关于自己的句子", "和自己相关的句子记得最牢")
                    ],
                    practice: ("每日词汇与跟读", "新词 20 个 + 跟读 10 分钟")
                ),
                StageTemplate(
                    weight: 40,
                    name: "刻意练习期",
                    acceptance: "能脱离字幕看懂一集剧集大意，能连续说 3 分钟不掉链子",
                    milestones: [
                        ("沉浸式输入：每天 20 分钟原声播客或剧集", "先盲听再看字幕，最后再盲听一遍"),
                        ("每周写 3 篇 100 字短文并自己改一遍", "写作暴露的语法漏洞最彻底"),
                        ("每周录 1 段 3 分钟口语，回听找问题", "回听很痛苦，但进步最快"),
                        ("整理易错语法与发音专项清单", "同类错误集中攻克"),
                        ("开始有真人输出：外教对话或语言交换", "被真人检验才知道是不是真会")
                    ],
                    practice: ("每日输入输出双练", "听力 20 分钟 + 输出 10 分钟")
                ),
                StageTemplate(
                    weight: 20,
                    name: "实战输出期",
                    acceptance: "完成一次真实场景检验（模考 / 对话 / 读原版书）",
                    milestones: [
                        ("参加一次模考或真实对话，记录卡壳点", "分数不重要，卡壳点才是复习清单"),
                        ("读完一本原版简易读物或一部无字幕视频", "第一次完整啃下来会重塑信心"),
                        ("复盘：列出仍薄弱的三项，排进下一轮", "学习是循环，不是终点")
                    ],
                    practice: ("每周真实场景练习", "把语言用起来，而不是继续背")
                )
            ]
        case .fitness:
            [
                StageTemplate(
                    weight: 10,
                    name: "启动期",
                    acceptance: "完成体能基线测试，装备与训练计划就位",
                    milestones: [
                        ("做一次体能基线测试并留档", "跑多久/举多重/做几个，全都要有数字"),
                        ("准备必要装备与场地，确认训练时段", "把训练写进日历，而不是等有空"),
                        ("选定一套成熟训练计划，不要自己乱编", "新手最缺的是结构化，不是努力"),
                        ("学会目标动作的标准姿势（先空杆/慢速）", "姿势错了，练得越勤伤得越快")
                    ],
                    practice: ("每日活动量打卡", "训练日之外也保持基础活动，别久坐")
                ),
                StageTemplate(
                    weight: 30,
                    name: "基础期",
                    acceptance: "动作标准稳定，能按计划连续完成 4 周训练不中断",
                    milestones: [
                        ("固定每周训练频次并连续执行 4 周", "规律性比强度重要得多"),
                        ("每个主动作拍一次视频自查姿势", "自己看一遍比教练说十遍有效"),
                        ("建立训练日志：重量、组数、时长、主观感受", "没有记录就没有渐进"),
                        ("把睡眠与蛋白质摄入先做到位", "恢复跟不上，练再多也是白练")
                    ],
                    practice: ("按计划完成每次训练", "记录在案，不靠记忆")
                ),
                StageTemplate(
                    weight: 40,
                    name: "刻意练习期",
                    acceptance: "关键指标相比基线有可测量的提升",
                    milestones: [
                        ("执行渐进超负荷：每周在重量或时长上加一点", "每次加 2.5%~5%，别贪"),
                        ("针对最弱的一项做专项强化", "短板决定上限"),
                        ("每 4 周复测一次基线指标", "数据不会骗人，感觉会"),
                        ("学会识别过度训练信号并安排减载周", "休息是计划的一部分"),
                        ("调整饮食热量与宏观配比配合目标", "增肌减脂的差别在厨房")
                    ],
                    practice: ("每次训练 + 记录", "练完立刻记，隔天就记不准了")
                ),
                StageTemplate(
                    weight: 20,
                    name: "实战输出期",
                    acceptance: "达成一个可量化的目标（配速 / 重量 / 完赛）",
                    milestones: [
                        ("设定一个具体可验证的目标并公开", "5 公里配速、深蹲体重、完赛，要能测量"),
                        ("按周期化安排完成最后一次强度峰值", "赛前减量，别在最后一周拼命"),
                        ("完成目标并复测全部指标", "和启动期的基线并排看"),
                        ("复盘：写下有效的三项与无效的一项", "下一轮计划从这里开始")
                    ],
                    practice: ("保持训练频次", "目标达成后维持比冲刺更难")
                )
            ]
        case .generic:
            [
                StageTemplate(
                    weight: 10,
                    name: "启动期",
                    acceptance: "资源与环境就位，明确了什么叫「学会」",
                    milestones: [
                        ("写清楚可验收的目标：做到什么程度算学会", "目标不可观察，就无法判断进度"),
                        ("准备所需工具、材料或场地", "别让缺一件东西卡住第一次练习"),
                        ("选定唯一主学习资源与一位可参考的榜样", "先模仿，再创造")
                    ],
                    practice: ("每日接触这项技能", "先养成出现率，再谈质量")
                ),
                StageTemplate(
                    weight: 30,
                    name: "基础期",
                    acceptance: "掌握该技能最基本的操作单元，能完成最简单的完整动作",
                    milestones: [
                        ("拆解出这项技能的最小组成单元并逐个练", "先分块，再串起来"),
                        ("完成最简版本的完整流程一次", "完整做一遍比完美做一半重要"),
                        ("记录第一次的完整表现作为基线", "后面每一次都和它比")
                    ],
                    practice: ("每日基础练习", "每次只练一个单元")
                ),
                StageTemplate(
                    weight: 40,
                    name: "刻意练习期",
                    acceptance: "针对最弱环节有明显改善，能稳定复现中等难度表现",
                    milestones: [
                        ("找出最拖后腿的环节并专项突破", "整体水平由最短板决定"),
                        ("每次练习后做一次自我反馈或外部反馈", "没有反馈的重复只是重复"),
                        ("提高难度或速度，挑战舒适区边缘", "太简单没进步，太难会放弃"),
                        ("积累 10 次可对比的练习记录", "用数据看趋势，别靠感觉")
                    ],
                    practice: ("每日刻意练习", "带着一个明确的改进点去练")
                ),
                StageTemplate(
                    weight: 20,
                    name: "实战输出期",
                    acceptance: "拿出一件可被他人检验的成品或表现",
                    milestones: [
                        ("完成一件完整作品或一次完整表现", "做到能给别人看的程度"),
                        ("请一位懂行的人给真实反馈", "外部视角能看到自己的盲区"),
                        ("复盘：列出下一轮要攻的三件事", "结束即下一轮开始")
                    ],
                    practice: ("每周保持与复盘", "维持手感，记录变化")
                )
            ]
        }
    }

    // MARK: - 文本工具

    /// 数字或中文数字（整体为捕获组，内部全部使用非捕获组，避免打乱外层分组序号）
    private static let numberPattern = #"([0-9]+(?:\.[0-9]+)?|[一二三四五六七八九十]+|半|两)"#

    /// 返回第 1/2/3 个捕获组；用命名元素避免把 tuple 下标（从 0 起）误当成分组序号
    private static func firstMatch(in text: String, pattern: String) -> (g1: String, g2: String?, g3: String?)? {
        // NUM 必须整体包成捕获组：若展开成裸 alternation，外层正则会被 "|" 拆散
        let expanded = pattern.replacingOccurrences(of: "NUM", with: numberPattern)
        guard let regex = try? NSRegularExpression(pattern: expanded) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        func group(_ i: Int) -> String? {
            guard match.numberOfRanges > i, let r = Range(match.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        return (group(1) ?? "", group(2), group(3))
    }

    private static func numericValue(_ token: String?) -> Double? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let direct = Double(trimmed) { return direct }
        if trimmed == "半" { return 0.5 }
        if trimmed == "两" { return 2 }
        let digits: [Character: Double] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        // 十 / 十X / X十 / X十Y
        if let ten = trimmed.firstIndex(of: "十") {
            let before = String(trimmed[trimmed.startIndex..<ten])
            let after = String(trimmed[trimmed.index(after: ten)...])
            var value: Double = 10
            if let b = before.first, let bv = digits[b] { value = bv * 10 }
            if let a = after.first, let av = digits[a] { value += av }
            return value
        }
        var total: Double = 0
        for ch in trimmed {
            guard let v = digits[ch] else { continue }
            total = total * 10 + v
        }
        return total == 0 ? nil : total
    }
}

extension SkillCategory {
    public var verbPrefix: String {
        switch self {
        case .programming, .language, .fitness, .generic: return "学"
        }
    }

    public var defaultSkillName: String {
        switch self {
        case .programming: "编程"
        case .language: "外语"
        case .fitness: "健身"
        case .generic: "新技能"
        }
    }

    /// 用可观察行为描述的目标模板，避免「学会 XX」这种无法验收的表述
    public func goalTemplate(skill: String) -> String {
        switch self {
        case .programming:
            return "能独立用 \(skill) 完成一个可运行的小项目，并讲清它的实现思路"
        case .language:
            return "能用 \(skill) 完成一次真实场景的听与说，不依赖字幕与翻译"
        case .fitness:
            return "在 \(skill) 上达成一个可测量的指标（基线提升可复测）"
        case .generic:
            return "拿出一件 \(skill) 方面可被他人检验的成品或表现"
        }
    }
}
