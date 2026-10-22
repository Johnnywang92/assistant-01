import Foundation

/// 饮品分类及其生理补水折算特征
public enum HydrationBeverageType: String, CaseIterable, Codable, Sendable {
    /// 白开水 / 纯净水 / 矿泉水
    case plainWater = "plain_water"
    /// 淡茶 / 纯茶（无糖绿茶、红茶、乌龙茶等）
    case pureTea = "pure_tea"
    /// 黑咖啡 / 美式咖啡
    case blackCoffee = "black_coffee"
    /// 拿铁 / 牛奶咖啡
    case latte = "latte"
    /// 牛奶 / 豆奶
    case milk = "milk"
    /// 奶茶（含糖、加料、植脂末或全脂奶）
    case milkTea = "milk_tea"
    /// 含糖碳酸饮料 / 果汁饮料
    case sugaryDrink = "sugary_drink"
    /// 柠檬水 / 无糖气泡水
    case sparklingWater = "sparkling_water"
    /// 自定义饮品
    case custom = "custom"

    /// 显示名称
    public var displayName: String {
        switch self {
        case .plainWater: return "白开水/纯水"
        case .pureTea: return "淡茶/纯茶"
        case .blackCoffee: return "黑咖啡/美式"
        case .latte: return "拿铁/奶咖"
        case .milk: return "牛奶/豆乳"
        case .milkTea: return "奶茶"
        case .sugaryDrink: return "含糖饮料/果汁"
        case .sparklingWater: return "柠檬水/苏打水"
        case .custom: return "其他饮品"
        }
    }

    /// SF Symbol 图标名
    public var iconName: String {
        switch self {
        case .plainWater: return "drop.fill"
        case .pureTea: return "leaf.fill"
        case .blackCoffee: return "cup.and.saucer.fill"
        case .latte: return "mug.fill"
        case .milk: return "waterbottle.fill"
        case .milkTea: return "takeoutbag.and.cup.and.straw.fill"
        case .sugaryDrink: return "wineglass.fill"
        case .sparklingWater: return "bubbles.and.sparkles.fill"
        case .custom: return "plus.bubble.fill"
        }
    }

    /// 生理水分有效折算系数 (0.0 ~ 1.0)
    ///
    /// 科学依据：
    /// - 白开水/纯茶/气泡水：水分吸收率 100%。
    /// - 黑咖啡：日常饮用者对咖啡因耐受，净水分摄入为正，折算系数 100%（但需限制每日总咖啡因量）。
    /// - 拿铁/牛奶：含乳糖、乳脂和蛋白质，折算系数约 85%。
    /// - 奶茶/含糖饮料：高糖高脂，机体代谢糖分额外消耗水分，折算系数按 60% 计，且标注不建议替代饮水。
    public var defaultHydrationFactor: Double {
        switch self {
        case .plainWater, .pureTea, .blackCoffee, .sparklingWater:
            return 1.0
        case .latte, .milk:
            return 0.85
        case .milkTea, .sugaryDrink:
            return 0.60
        case .custom:
            return 0.90
        }
    }

    /// 每 100ml 估算咖啡因含量（毫克 mg）
    public var estimatedCaffeinePer100ml: Double {
        switch self {
        case .plainWater, .sparklingWater, .milk:
            return 0.0
        case .pureTea:
            return 12.0 // 约 30mg / 250ml
        case .blackCoffee:
            return 40.0 // 约 100mg / 250ml
        case .latte:
            return 30.0 // 约 75mg / 250ml
        case .milkTea:
            return 20.0 // 约 60-100mg / 杯（茶底浓度不同）
        case .sugaryDrink:
            return 0.0 // 可乐约为 10mg，多数为 0，此处取保守均值
        case .custom:
            return 0.0
        }
    }

    /// 每 100ml 估算热量（千卡 kcal）
    public var estimatedCaloriesPer100ml: Double {
        switch self {
        case .plainWater, .pureTea, .sparklingWater:
            return 0.0
        case .blackCoffee:
            return 2.0 // 极低
        case .latte:
            return 54.0 // 全脂牛奶拿铁
        case .milk:
            return 60.0
        case .milkTea:
            return 65.0 // 正常糖奶茶约 200~350 kcal/杯
        case .sugaryDrink:
            return 45.0 // 碳酸饮料约 43 kcal/100ml
        case .custom:
            return 30.0
        }
    }

    /// 健康补水等级与科学评注
    public var healthAdvice: String {
        switch self {
        case .plainWater:
            return "最佳补水来源，纯净零负担，维持机体代谢平衡。"
        case .pureTea:
            return "优质补水饮品，富含茶多酚；避免过浓或睡前饮用。"
        case .blackCoffee:
            return "净补水为正，常喝者耐受咖啡因利尿作用；每日咖啡因建议不超过 400mg。"
        case .latte:
            return "兼具补水与奶类营养，含有一定热量和乳糖。"
        case .milk:
            return "优质蛋白质与钙来源，水分折算约 85%，可计入营养补给。"
        case .milkTea:
            return "生理上含水，但高糖高脂加重代谢负担，代谢糖分需额外耗水，不建议替代日常饮水。"
        case .sugaryDrink:
            return "高糖容易引起渗透压变化与口干，无法达到健康解渴目的，不建议代水。"
        case .sparklingWater:
            return "清爽无糖，补水效果与纯水相当，适合调节口味。"
        case .custom:
            return "自定义饮品，建议根据实际成分关注糖分与咖啡因。"
        }
    }

    /// 是否推荐作为主力补水
    public var isRecommendedAsMainHydration: Bool {
        switch self {
        case .plainWater, .pureTea, .sparklingWater:
            return true
        default:
            return false
        }
    }
}

/// 单次饮水输入结构（纯逻辑）
public struct WaterIntakeSnapshot: Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let beverageType: HydrationBeverageType
    public let volumeML: Double
    public let hydrationFactor: Double
    public let customName: String?
    public let note: String?

    public init(
        id: String = UUID().uuidString,
        date: Date = .now,
        beverageType: HydrationBeverageType,
        volumeML: Double,
        hydrationFactor: Double? = nil,
        customName: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.date = date
        self.beverageType = beverageType
        self.volumeML = volumeML
        self.hydrationFactor = hydrationFactor ?? beverageType.defaultHydrationFactor
        self.customName = customName
        self.note = note
    }

    /// 经生理折算后的有效补水量（毫升）
    public var effectiveHydrationML: Double {
        (volumeML * hydrationFactor).rounded()
    }

    /// 估算摄入的咖啡因（毫克）
    public var estimatedCaffeineMG: Double {
        ((volumeML / 100.0) * beverageType.estimatedCaffeinePer100ml).rounded()
    }

    /// 估算摄入的热量（千卡）
    public var estimatedCalories: Double {
        ((volumeML / 100.0) * beverageType.estimatedCaloriesPer100ml).rounded()
    }
}

/// 当日饮水摄入统计汇总
public struct DailyHydrationSummary: Sendable {
    /// 目标饮水量（毫升，默认 1700ml 纯水摄入）
    public let targetML: Double
    /// 所有饮品的物理总容量（毫升）
    public let totalVolumeML: Double
    /// 生理有效折算后的净补水量（毫升）
    public let effectiveHydrationML: Double
    /// 当日累计咖啡因（毫克）
    public let totalCaffeineMG: Double
    /// 当日饮品累计附带热量（千卡）
    public let totalBeverageCalories: Double
    /// 记录条数
    public let recordCount: Int
    /// 是否达成目标
    public var isGoalAchieved: Bool {
        effectiveHydrationML >= targetML
    }

    /// 达成百分比 (0.0 ~ 1.0+)
    public var progressRatio: Double {
        guard targetML > 0 else { return 0.0 }
        return min(max(effectiveHydrationML / targetML, 0.0), 2.0)
    }

    /// 咖啡因是否超标（健康安全阈值通常为 400mg/天）
    public var isCaffeineHigh: Bool {
        totalCaffeineMG >= 400.0
    }

    /// 咖啡因风险提示
    public var caffeineWarning: String? {
        if totalCaffeineMG >= 400.0 {
            return "今日累计咖啡因已达 \(Int(totalCaffeineMG))mg，超过每日建议上限 (400mg)，请避免继续摄入含咖啡因饮品。"
        } else if totalCaffeineMG >= 300.0 {
            return "今日咖啡因已摄入 \(Int(totalCaffeineMG))mg，接近上限，睡前请尽量饮用白开水。"
        }
        return nil
    }

    public init(
        targetML: Double = 1700,
        snapshots: [WaterIntakeSnapshot]
    ) {
        self.targetML = targetML
        self.recordCount = snapshots.count

        var volSum: Double = 0
        var effSum: Double = 0
        var cafSum: Double = 0
        var calSum: Double = 0

        for s in snapshots {
            volSum += s.volumeML
            effSum += s.effectiveHydrationML
            cafSum += s.estimatedCaffeineMG
            calSum += s.estimatedCalories
        }

        self.totalVolumeML = volSum
        self.effectiveHydrationML = effSum
        self.totalCaffeineMG = cafSum
        self.totalBeverageCalories = calSum
    }
}

/// 饮水科学指导常数与问答速查
public enum HydrationScienceFAQ {
    public struct QAItem: Identifiable, Sendable {
        public var id: String { question }
        public let question: String
        public let shortAnswer: String
        public let detail: String
    }

    public static let items: [QAItem] = [
        QAItem(
            question: "喝黑咖啡到底算不算喝水？",
            shortAnswer: "算。对于日常有咖啡习惯的人，净补水为正。",
            detail: "咖啡 98% 以上是水。虽然咖啡因具有轻微利尿作用，但医学研究表明，对经常喝咖啡的人机体已产生耐受，排尿增加量远小于喝入的水量。中国与欧美膳食指南均将黑咖啡计入每日总水分摄入。注意每日咖啡因控制在 400mg 以内（约 2~3 杯美式）。"
        ),
        QAItem(
            question: "喝奶茶算不算喝水？",
            shortAnswer: "生理上吸收水分，但在健康管理上「强烈不建议」当作喝水。",
            detail: "奶茶含大量添加糖、脂肪与植脂末，代谢高糖高脂本身需要消耗体内水分。如果把奶茶计入日常饮水量，容易造成「今天水喝够了」的错觉，不仅未达到健康解渴目的，还摄入了超标的热量与添加糖。本工具对奶茶按 60% 折算，并标出热量。"
        ),
        QAItem(
            question: "每天到底该喝多少水？",
            shortAnswer: "轻体力成人建议 1500~1700 ml 纯水（约 7~8 杯）。",
            detail: "《中国居民膳食指南》推荐：温和气候成年男性每天 1700 ml，女性 1500 ml。夏季出汗多或运动时可增加到 2000~2500 ml。最简单的自测方式是观察尿液颜色，淡柠檬黄色说明饮水适量；深黄则提示需及时补水。"
        ),
        QAItem(
            question: "不同饮品怎么折算水分？",
            shortAnswer: "白开水、淡茶、黑咖啡按 100% 计；拿铁、牛奶按 85% 计；奶茶、甜饮料按 60% 计。",
            detail: "本功能采用营养学生理水分折算模型：白开水与淡茶是最佳水源；奶类提供蛋白质按 85% 折算；奶茶与含糖饮料由于高渗透压和代谢负担按 60% 折算，并同步提示热量与咖啡因。"
        )
    ]
}

// MARK: - 饮水自然语言解析器

public extension HydrationBeverageType {
    /// 从模型标签或中文简称映射饮品类型
    static func fromLabel(_ label: String) -> HydrationBeverageType {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = HydrationBeverageType(rawValue: trimmed) {
            return direct
        }
        if trimmed.contains("奶茶") || trimmed.contains("果茶") || trimmed.contains("波霸") || trimmed.contains("珍珠") {
            return .milkTea
        }
        if trimmed.contains("拿铁") || trimmed.contains("卡布奇诺") || trimmed.contains("摩卡") || trimmed.contains("澳白") || trimmed.contains("馥芮白") || trimmed.contains("奶咖") {
            return .latte
        }
        if trimmed.contains("美式") || trimmed.contains("黑咖") || trimmed.contains("手冲") || trimmed.contains("浓缩") || trimmed.contains("咖啡") {
            return .blackCoffee
        }
        if trimmed.contains("柠檬水") || trimmed.contains("气泡水") || trimmed.contains("苏打水") {
            return .sparklingWater
        }
        if trimmed.contains("牛奶") || trimmed.contains("豆浆") || trimmed.contains("豆奶") || trimmed.contains("鲜奶") {
            return .milk
        }
        if trimmed.contains("可乐") || trimmed.contains("雪碧") || trimmed.contains("汽水") || trimmed.contains("果汁") || trimmed.contains("橙汁") || trimmed.contains("含糖饮料") || trimmed.contains("运动饮料") {
            return .sugaryDrink
        }
        if trimmed.contains("茶") || trimmed.contains("乌龙") || trimmed.contains("绿茶") || trimmed.contains("红茶") || trimmed.contains("普洱") || trimmed.contains("茉莉") {
            return .pureTea
        }
        if trimmed.contains("水") {
            return .plainWater
        }
        return .plainWater
    }
}

/// 从自然语言文本提取饮水记录参数
public enum HydrationNaturalLanguageParser {
    public struct ParsedDrink: Equatable, Sendable {
        public let beverageType: HydrationBeverageType
        public let volumeML: Double
        public let customName: String
    }

    /// 识别纯饮水/喝饮品陈述（如“喝了500ml水”、“喝了一杯冰美式”、“喝了一瓶乌龙茶”）
    public static func parse(_ text: String) -> ParsedDrink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 排除包含明确金额花费词的记账语句
        let expenseWords = ["花了", "花掉", "付了", "支出", "消费", "元", "块钱", "块", "¥", "￥", "$", "买", "下单"]
        if expenseWords.contains(where: { trimmed.contains($0) }) {
            return nil
        }

        // 排除固体食物或正餐多菜陈述（如“早饭吃了一根玉米和一杯牛奶”走 food.record）
        let solidFoodIndicators = ["吃了", "吃了个", "米饭", "面条", "玉米", "鸡蛋", "包子", "面包", "三明治", "汉堡", "沙拉", "饺子", "麦片", "红薯", "鸡胸肉", "牛肉", "猪肉"]
        if solidFoodIndicators.contains(where: { trimmed.contains($0) }) {
            return nil
        }

        // 必须包含饮用动词或明确容量+饮品
        let hasDrinkVerb = trimmed.contains("喝") || trimmed.contains("饮水") || trimmed.contains("补水") || trimmed.contains("干了")
        let drinkKeywords = [
            "水", "温水", "白开水", "矿泉水", "纯净水", "柠檬水", "苏打水", "气泡水",
            "美式", "冰美式", "黑咖啡", "手冲咖啡", "拿铁", "冰拿铁", "燕麦拿铁", "生椰拿铁", "卡布奇诺", "摩卡", "澳白", "咖啡",
            "奶茶", "珍珠奶茶", "果茶", "霸王茶姬", "喜茶",
            "乌龙茶", "绿茶", "红茶", "普洱茶", "茉莉花茶", "纯茶", "茶",
            "可乐", "雪碧", "橙汁", "果汁", "椰汁", "豆浆"
        ]
        guard hasDrinkVerb, drinkKeywords.contains(where: { trimmed.contains($0) }) else {
            return nil
        }

        let beverageType = HydrationBeverageType.fromLabel(trimmed)

        // 提取具体饮品名称
        let sortedKeywords = drinkKeywords.sorted { $0.count > $1.count }
        let matchedName = sortedKeywords.first(where: { trimmed.contains($0) }) ?? beverageType.displayName
        let customName = matchedName == "水" ? "白开水" : matchedName

        // 1. 优先匹配显式毫升/升数值（如 500ml, 350毫升, 1.5L, 0.5升）
        if let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(?:ml|ML|mL|毫升)"),
           let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
           let range = Range(match.range(at: 1), in: trimmed),
           let val = Double(trimmed[range]), val > 0, val <= 5000 {
            return ParsedDrink(beverageType: beverageType, volumeML: val, customName: customName)
        }
        if let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(?:L|l|升)"),
           let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
           let range = Range(match.range(at: 1), in: trimmed),
           let val = Double(trimmed[range]), val > 0, val <= 5 {
            return ParsedDrink(beverageType: beverageType, volumeML: val * 1000.0, customName: customName)
        }

        // 2. 按杯/瓶/罐/壶量词推算默认容量
        var multiplier = 1.0
        if trimmed.contains("半杯") || trimmed.contains("半瓶") {
            multiplier = 0.5
        } else if trimmed.contains("两杯") || trimmed.contains("2杯") || trimmed.contains("两瓶") || trimmed.contains("2瓶") {
            multiplier = 2.0
        } else if trimmed.contains("三杯") || trimmed.contains("3杯") {
            multiplier = 3.0
        }

        let baseVolume: Double
        if trimmed.contains("大杯") || trimmed.contains("超大杯") || trimmed.contains("一瓶") || trimmed.contains("1瓶") || trimmed.contains("瓶") {
            baseVolume = 500.0
        } else if trimmed.contains("罐") || trimmed.contains("听") {
            baseVolume = 330.0
        } else if beverageType == .milkTea {
            baseVolume = 450.0
        } else if beverageType == .blackCoffee || beverageType == .latte {
            baseVolume = 300.0
        } else {
            baseVolume = 250.0
        }

        return ParsedDrink(beverageType: beverageType, volumeML: (baseVolume * multiplier).rounded(), customName: customName)
    }
}
