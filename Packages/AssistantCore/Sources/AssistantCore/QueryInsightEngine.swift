import Foundation

// MARK: - 查询意图解析（纯逻辑，下沉 AssistantCore 便于测试覆盖）
//
// 「问一句就有数」的前提是先弄清用户在**问什么**：哪个领域、哪个时间窗、
// 是要汇总数字还是趋势对比还是要找东西。本层只做文本 → 结构化意图，
// 数据获取与文案渲染分别在 App 侧（LifeQueryService）与 `QueryAnswerBuilder`。
//
// 取舍：解析**宁可少解析，不可解析错**——非疑问句（如「昨天花了69.9」记账句）
// 必须返回 nil，否则记账会被误劫持成查询。所有识别都要求「领域词 + 疑问/查询标记」
// 双条件成立。

/// 结构化查询意图
public struct QueryInsight: Equatable, Sendable {

    /// 查询领域。多个领域词命中时按 `QueryInsightEngine.domainPriority` 取序。
    public enum Domain: String, Equatable, Sendable {
        case expense       // 账本 / 消费 / 支出
        case diet          // 饮食 / 热量 / 摄入
        case health        // 睡眠 / 健康 / 活力 / 步数 / 心率
        case todo          // 待办 / 日程 / 安排
        case anniversary   // 纪念日 / 生日 / 倒数
        case storage       // 物品收纳位置
        case medicine      // 家庭常备药
        case document      // 证件卡包
        case lifeEvent     // 人生大事项目
    }

    /// 查询形态
    public enum Kind: String, Equatable, Sendable {
        /// 汇总数字：花了多少 / 多少笔
        case aggregate
        /// 趋势对比：趋势 / 环比 / 比上周
        case trend
        /// 日程列表：今天有什么安排
        case agenda
        /// 关键词找东西：护照放哪了 / 查找充电宝
        case lookup
    }

    /// 时间窗。全部可解析为闭开区间，见 `interval(now:calendar:)`。
    public enum TimeRange: Equatable, Sendable {
        case today
        case tomorrow
        case yesterday
        case dayBeforeYesterday
        case thisWeek
        case lastWeek
        case thisMonth
        case lastMonth
        case lastNDays(Int)
        case lastNMonths(Int)
        case allTime

        /// 展示用短标签
        public var displayLabel: String {
            switch self {
            case .today: return "今天"
            case .tomorrow: return "明天"
            case .yesterday: return "昨天"
            case .dayBeforeYesterday: return "前天"
            case .thisWeek: return "本周"
            case .lastWeek: return "上周"
            case .thisMonth: return "本月"
            case .lastMonth: return "上月"
            case .lastNDays(let n): return "近\(n)天"
            case .lastNMonths(let n): return "近\(n)个月"
            case .allTime: return "全部时间"
            }
        }

        /// 解析为半开区间 [start, end)。`allTime` 返回无限区间。
        public func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
            let startOfDay = calendar.startOfDay(for: now)
            switch self {
            case .today:
                let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
                return DateInterval(start: startOfDay, end: end)
            case .tomorrow:
                let start = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
                let end = calendar.date(byAdding: .day, value: 2, to: startOfDay) ?? startOfDay
                return DateInterval(start: start, end: end)
            case .yesterday:
                let start = calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
                return DateInterval(start: start, end: startOfDay)
            case .dayBeforeYesterday:
                let start = calendar.date(byAdding: .day, value: -2, to: startOfDay) ?? startOfDay
                let end = calendar.date(byAdding: .day, value: -1, to: startOfDay) ?? startOfDay
                return DateInterval(start: start, end: end)
            case .thisWeek:
                let interval = calendar.dateInterval(of: .weekOfYear, for: now)
                    ?? DateInterval(start: startOfDay, end: startOfDay)
                let end = calendar.date(byAdding: .day, value: 7, to: interval.start) ?? interval.end
                return DateInterval(start: interval.start, end: max(interval.end, end))
            case .lastWeek:
                let interval = calendar.dateInterval(of: .weekOfYear, for: now)
                    ?? DateInterval(start: startOfDay, end: startOfDay)
                let start = calendar.date(byAdding: .day, value: -7, to: interval.start) ?? interval.start
                return DateInterval(start: start, end: interval.start)
            case .thisMonth:
                let interval = calendar.dateInterval(of: .month, for: now)
                    ?? DateInterval(start: startOfDay, end: startOfDay)
                return interval
            case .lastMonth:
                let interval = calendar.dateInterval(of: .month, for: now)
                    ?? DateInterval(start: startOfDay, end: startOfDay)
                let start = calendar.date(byAdding: .month, value: -1, to: interval.start) ?? interval.start
                return DateInterval(start: start, end: interval.start)
            case .lastNDays(let n):
                let count = max(1, n)
                // 含今天在内往前 n 天：[今天起点 - (n-1), 明天起点)
                let start = calendar.date(byAdding: .day, value: -(count - 1), to: startOfDay) ?? startOfDay
                let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
                return DateInterval(start: start, end: end)
            case .lastNMonths(let n):
                let count = max(1, n)
                let comps = calendar.dateComponents([.year, .month], from: now)
                let total = (comps.year ?? 1970) * 12 + (comps.month ?? 1) - 1 - (count - 1)
                var startComps = DateComponents()
                startComps.year = total / 12
                startComps.month = total % 12 + 1
                startComps.day = 1
                let start = calendar.date(from: startComps) ?? startOfDay
                let nextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.dateInterval(of: .month, for: now)?.start ?? startOfDay) ?? startOfDay
                return DateInterval(start: start, end: nextMonth)
            case .allTime:
                return DateInterval(start: .distantPast, end: .distantFuture)
            }
        }
    }

    public let domain: Domain
    public let kind: Kind
    public let timeRange: TimeRange
    /// `kind == .lookup` 时的匹配关键词（已剥掉「查找/放哪了」等壳），其余为 nil
    public let keyword: String?
    public let rawText: String

    public init(domain: Domain, kind: Kind, timeRange: TimeRange, keyword: String? = nil, rawText: String) {
        self.domain = domain
        self.kind = kind
        self.timeRange = timeRange
        self.keyword = keyword
        self.rawText = rawText
    }
}

// MARK: - 解析器

/// 文本 → `QueryInsight`。识别不到查询意图时返回 nil。
public enum QueryInsightEngine {

    /// 领域判定优先级（多领域词同时命中时取序靠前者）。
    /// 金额问句优先于饮食——「买药花了多少」应查账而不是查药品。
    public static let domainPriority: [QueryInsight.Domain] = [
        .expense, .diet, .health, .todo, .lifeEvent, .anniversary, .document, .medicine, .storage
    ]

    // MARK: 词表

    /// 疑问/查询标记：没有这些词的句子不当成查询（防记账句被劫持）
    private static let queryMarkers = [
        "多少", "几笔", "几块", "多吗", "吗", "？", "?", "什么", "啥", "哪些", "哪",
        "统计", "汇总", "一共", "总共", "趋势", "走势", "环比", "同比", "对比",
        "怎么样", "如何", "查", "找", "搜索", "看看", "看下", "看一", "有没有", "是不是",
        "有几", "算算", "算一下"
    ]

    private static let trendWords = [
        "趋势", "走势", "环比", "同比", "对比", "比上", "比前", "变化", "涨了", "降了",
        "花得怎么", "吃得好", "花得多吗", "花得多么", "多了吗", "少了么"
    ]

    private static let expenseWords = [
        "消费", "支出", "开销", "花销", "账单", "账本", "记账", "花了", "花钱", "花得",
        "收入", "收支", "多少钱", "账目", "查账", "对账"
    ]

    private static let dietWords = [
        "饮食", "热量", "摄入", "卡路里", "千卡", "大卡", "吃了", "吃多少", "吃了多少",
        "吃得好", "营养", "食物"
    ]

    private static let healthWords = [
        "睡眠", "睡觉", "睡得", "睡了", "健康", "活力", "步数", "心率", "血氧", "体重"
    ]

    private static let todoWords = [
        "安排", "日程", "待办", "任务", "要做", "待办事项", "行程"
    ]

    private static let anniversaryWords = ["纪念日", "生日", "倒数", "倒计时"]
    private static let storageWords = ["放哪", "放在哪", "在哪", "收纳", "存放", "位置", "收在"]
    private static let medicineWords = [
        "药", "服药", "吃药", "备药", "常备药", "布洛芬", "阿莫西林", "感冒", "退烧",
        "消炎", "维生素", "创可贴", "眼药水", "止痛"
    ]
    private static let documentWords = ["证件", "护照", "身份证", "驾照", "签证", "证件照"]
    private static let lifeEventWords = ["人生大事", "大事", "购车", "买房", "婚礼", "留学", "项目进度"]

    /// 日程问句（比裸「安排」更硬的判据，防止「安排一下明天的会议」被误判成查询）
    private static let agendaPhrases = [
        "有什么安排", "什么安排", "安排了什么", "有哪些安排", "什么日程", "有什么日程",
        "有什么事", "有哪些事", "有啥事", "要做什么", "要做啥", "要干嘛", "有什么任务",
        "哪些任务", "有什么待办", "待办有哪些", "今天的安排", "明天的安排", "本周的安排",
        "今日安排", "明日安排", "今日事", "今天要做", "日程安排"
    ]

    // MARK: 主入口

    /// 解析查询意图。非查询句（记账/陈述/命令）返回 nil。
    public static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> QueryInsight? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }

        // 0. 祈使句（提醒我/记一下/安排一下…）是建任务，不是查询
        guard !isDirective(trimmed) else { return nil }

        // 1. 显式日程短语（「今日安排」「明天的安排」可无疑问标记）
        if agendaPhrases.contains(where: trimmed.contains) {
            return QueryInsight(
                domain: .todo,
                kind: .agenda,
                timeRange: resolveTimeRange(trimmed, kind: .agenda, domain: .todo),
                keyword: nil,
                rawText: trimmed
            )
        }

        // 2. 必须带疑问/查询标记，否则不是问句
        guard containsAny(trimmed, queryMarkers) else { return nil }

        // 3. 带真实金额的句子是记账陈述（「买了什么菜花了50」），不是查询
        guard !looksLikeRecord(trimmed) else { return nil }

        // 4. 领域词 + 形态 + 时间窗
        guard let domain = resolveDomain(trimmed) else { return nil }
        let kind = resolveKind(trimmed, domain: domain)
        let timeRange = resolveTimeRange(trimmed, kind: kind, domain: domain)
        let keyword = (kind == .lookup) ? extractLookupKeyword(trimmed) : nil

        return QueryInsight(
            domain: domain,
            kind: kind,
            timeRange: timeRange,
            keyword: keyword,
            rawText: trimmed
        )
    }

    /// 祈使/建任务前缀：这些句子的意图是「创建」而非「查询」
    private static func isDirective(_ text: String) -> Bool {
        let directives = [
            "提醒我", "记一下", "帮我记", "帮我建", "添加待办", "建立待办",
            "添加提醒", "记个待办", "安排一下", "记得", "别忘了"
        ]
        return directives.contains { text.contains($0) }
    }

    /// 带真实金额的陈述句（元/块/万 + 数字，或「花了35」这类裸金额）。
    /// 只有**没有**强疑问词时才算记录句——「上周花了多少」仍然安全。
    private static func looksLikeRecord(_ text: String) -> Bool {
        let hasAmountUnit = containsAny(text, ["元", "块", "角", "万", "¥", "$"])
        let hasVerbAmount = text.range(of: "(?:花了|付了|收了|买了|充值)\\s*[0-9]", options: .regularExpression) != nil
        guard hasAmountUnit || hasVerbAmount else { return false }
        let strongQuestion = ["多少", "几笔", "吗", "？", "?", "趋势", "环比", "统计", "汇总", "对比", "怎么样"]
        return !containsAny(text, strongQuestion)
    }

    /// 抽出「X放哪了 / 查找X」里的 X。抽不出返回 nil。
    /// 与投喂口规则路径共用，保证正则只有一份（避免双份漂移）。
    public static func extractLookupKeyword(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "(?:查|找|问|搜)?\\s*(.+?)\\s*(?:放哪了|在哪里|在什么地方|放在哪|放在哪里)[？?]?$",
            "^(?:帮我)?(?:查找|查询|检索|搜索|查一下|找一下|查下|找下)\\s*(.+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let first = matches.first, first.numberOfRanges > 1 {
                let target = ns.substring(with: first.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty, target.count < 40 {
                    return target
                }
            }
        }
        return nil
    }

    // MARK: 分步识别

    private static func resolveDomain(_ text: String) -> QueryInsight.Domain? {
        for domain in domainPriority {
            switch domain {
            case .expense where containsAny(text, expenseWords):
                return .expense
            case .diet where containsAny(text, dietWords):
                return .diet
            // 健康域不接位置问句（「健康证放哪了」是收纳查找，不是健康趋势）
            case .health where containsAny(text, healthWords) && !containsAny(text, storageWords):
                return .health
            case .todo where containsAny(text, todoWords):
                return .todo
            case .anniversary where containsAny(text, anniversaryWords):
                return .anniversary
            case .storage where containsAny(text, storageWords):
                return .storage
            case .medicine where containsAny(text, medicineWords):
                return .medicine
            case .document where containsAny(text, documentWords):
                return .document
            case .lifeEvent where containsAny(text, lifeEventWords):
                return .lifeEvent
            default:
                continue
            }
        }
        return nil
    }

    private static func resolveKind(_ text: String, domain: QueryInsight.Domain) -> QueryInsight.Kind {
        // 趋势：趋势词 + 领域词（领域词已由 domain 判定兜底）
        if containsAny(text, trendWords) {
            return .trend
        }
        // 待办域 → 日程列表
        if domain == .todo {
            return .agenda
        }
        // 健康域：「怎么样/如何」是趋势问（「最近睡得怎么样」），「多少/平均」是汇总问
        if domain == .health {
            if containsAny(text, ["怎么样", "如何", "好不好", "正常吗"]) {
                return .trend
            }
            return .aggregate
        }
        // 账/饮食域 → 数字汇总（趋势已提前拦截）
        if domain == .expense || domain == .diet {
            return .aggregate
        }
        // 其余（收纳/药品/证件/纪念日/人生大事）→ 关键词查找
        return .lookup
    }

    private static func resolveTimeRange(
        _ text: String,
        kind: QueryInsight.Kind,
        domain: QueryInsight.Domain
    ) -> QueryInsight.TimeRange {
        // 显式时间词优先（当前窗口优先于对照窗口：「这周比上周」以这周为准）
        if text.contains("前天") { return .dayBeforeYesterday }
        if text.contains("昨天") || text.contains("昨日") { return .yesterday }
        if text.contains("今天") || text.contains("今日") || text.contains("当日") { return .today }
        if text.contains("明天") || text.contains("明日") { return .tomorrow }
        if text.contains("本周") || text.contains("这周") || text.contains("这星期") || text.contains("这礼拜") {
            return .thisWeek
        }
        if text.contains("上周") || text.contains("上星期") || text.contains("上礼拜") { return .lastWeek }
        if text.contains("本月") || text.contains("这个月") || text.contains("这月") || text.contains("当月") {
            return .thisMonth
        }
        if text.contains("上个月") || text.contains("上月") || text.contains("上一个月") { return .lastMonth }

        // 「近/最近 N 天|周|月」
        if let range = parseRelativeRange(text) { return range }

        // 兜底：趋势看近半年，汇总看本月，日程看今天，查找不限；
        // 健康按日粒度——睡眠/步数以天为单位，月窗没有意义
        switch kind {
        case .trend:
            if domain == .health { return .lastNDays(7) }
            return domain == .diet ? .lastNDays(30) : .lastNMonths(6)
        case .aggregate:
            return domain == .health ? .today : .thisMonth
        case .agenda:
            return .today
        case .lookup:
            return .allTime
        }
    }

    /// 「近一周」「最近3天」「近半个月」「近半年」「近一年」→ 结构化窗口
    private static func parseRelativeRange(_ text: String) -> QueryInsight.TimeRange? {
        if text.contains("近一周") || text.contains("最近一周") || text.contains("近一星期") || text.contains("近一个礼拜") {
            return .lastNDays(7)
        }
        if text.contains("近半个月") || text.contains("最近半个月") || text.contains("近半月") {
            return .lastNDays(15)
        }
        if text.contains("近半年") || text.contains("最近半年") {
            return .lastNMonths(6)
        }
        if text.contains("近一年") || text.contains("最近一年") || text.contains("近一年来") {
            return .lastNMonths(12)
        }

        guard let regex = try? NSRegularExpression(pattern: "(?:近|最近)\\s*([0-9一二两三四五六七八九十半]+)\\s*个?\\s*(天|日|周|星期|礼拜|月)") else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 2 else { return nil }
        let numberText = ns.substring(with: match.range(at: 1))
        let unitText = ns.substring(with: match.range(at: 2))

        if numberText == "半" {
            return unitText.contains("月") ? .lastNDays(15) : .lastNDays(3)
        }
        guard let n = parseChineseNumber(numberText), n > 0, n <= 36 else { return nil }
        if unitText.contains("天") || unitText.contains("日") {
            return .lastNDays(n)
        }
        if unitText.contains("周") || unitText.contains("星期") || unitText.contains("礼拜") {
            return .lastNDays(n * 7)
        }
        return .lastNMonths(n)
    }

    /// 中文/阿拉伯数字 → Int（支持 1~99：一 二 两 三 … 十 十一 二十 三十）
    static func parseChineseNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Int(trimmed) { return direct }
        let digits: [Character: Int] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "十" { return 10 }
        if trimmed.hasPrefix("十"), let unit = digits[trimmed.dropFirst().first ?? " "] {
            return 10 + unit
        }
        if trimmed.hasSuffix("十"), let tens = digits[trimmed.first ?? " "] {
            return tens * 10
        }
        if trimmed.count == 2,
           let tens = digits[trimmed.first ?? " "],
           trimmed.hasPrefix("十") == false,
           let unit = digits[trimmed.dropFirst().first ?? " "] {
            return tens * 10 + unit
        }
        if trimmed.count == 1, let single = digits[trimmed.first ?? " "] {
            return single
        }
        return nil
    }

    private static func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }
}
