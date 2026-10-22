import Foundation

// MARK: - 饮食偏好与习惯学习模型（纯逻辑下沉 Core）
//
// 核心目标：
// 1. 结构化分析用户历史饮食记录，识别「饮品风格（咖啡控 vs 奶茶党 vs 纯茶/果汁）」、
//    「主食偏好（米饭党 vs 面食党 vs 面点轻食）」、「加餐与下午茶习惯（频次、常吃零食与高频时段）」。
// 2. 结合当前时段（早、午、下午茶、晚、深夜宵夜）、今日已摄入与消耗能量，
//    输出贴合用户口味且具备健康指导价值的「懂你的场景化饮食建议」。

/// 传入分析器的结构化饮食快照摘要（用于解耦 SwiftData 模型，支持纯逻辑测试）。
public struct FoodIntakeItemSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let foodID: String
    public let foodName: String
    public let category: FoodCategory
    public let calories: Double
    public let portion: FoodPortion
    public let consumedRatio: Double

    public init(id: String = UUID().uuidString,
                date: Date,
                foodID: String,
                foodName: String,
                category: FoodCategory,
                calories: Double,
                portion: FoodPortion = .regular,
                consumedRatio: Double = 1.0) {
        self.id = id
        self.date = date
        self.foodID = foodID
        self.foodName = foodName
        self.category = category
        self.calories = calories
        self.portion = portion
        self.consumedRatio = consumedRatio
    }
}

// MARK: - 饮品习惯画像

/// 饮品风格
public enum BeverageStyle: String, Sendable, CaseIterable {
    case coffeeLover = "咖啡控"
    case milkTeaFan = "奶茶党"
    case healthyTea = "纯茶养生派"
    case fruitJuice = "鲜果轻饮派"
    case sodaBeverage = "碳酸快乐水派"
    case balanced = "均衡饮水派"

    public var icon: String {
        switch self {
        case .coffeeLover: return "cup.and.saucer.fill"
        case .milkTeaFan: return "takeoutbag.and.cup.and.straw.fill"
        case .healthyTea: return "leaf.fill"
        case .fruitJuice: return "waterbottle.fill"
        case .sodaBeverage: return "bubbles.and.sparkles.fill"
        case .balanced: return "drop.fill"
        }
    }
}

/// 饮品习惯画像
public struct BeverageHabitProfile: Equatable, Sendable {
    public let style: BeverageStyle
    /// 统计样本中的饮品总数
    public let totalDrinkCount: Int
    /// 咖啡频次
    public let coffeeCount: Int
    /// 奶茶频次
    public let milkTeaCount: Int
    /// 纯茶/无糖茶频次
    public let teaCount: Int
    /// 其他饮品频次（果汁/汽水/水）
    public let otherDrinkCount: Int
    /// 最常喝的 Top 饮品名称
    public let topBeverages: [String]
    /// 常见饮用时段说明（如「集中在上午 08:30-10:00 与午后 14:00-15:30」）
    public let typicalTimeDescription: String

    public init(style: BeverageStyle,
                totalDrinkCount: Int,
                coffeeCount: Int,
                milkTeaCount: Int,
                teaCount: Int,
                otherDrinkCount: Int,
                topBeverages: [String],
                typicalTimeDescription: String) {
        self.style = style
        self.totalDrinkCount = totalDrinkCount
        self.coffeeCount = coffeeCount
        self.milkTeaCount = milkTeaCount
        self.teaCount = teaCount
        self.otherDrinkCount = otherDrinkCount
        self.topBeverages = topBeverages
        self.typicalTimeDescription = typicalTimeDescription
    }
}

// MARK: - 主食偏好画像

/// 主食偏好风格
public enum StapleStyle: String, Sendable, CaseIterable {
    case noodleLover = "无面不欢"
    case riceLover = "忠实米饭党"
    case pastryBun = "早点面点控"
    case lightDiet = "轻食控卡族"
    case balanced = "荤素主食均衡"

    public var icon: String {
        switch self {
        case .noodleLover: return "fork.knife"
        case .riceLover: return "takeoutbag.and.cup.and.straw"
        case .pastryBun: return "birthday.cake"
        case .lightDiet: return "leaf"
        case .balanced: return "chart.pie.fill"
        }
    }
}

/// 主食偏好画像
public struct StapleHabitProfile: Equatable, Sendable {
    public let style: StapleStyle
    /// 主食总摄入次数
    public let totalStapleCount: Int
    /// 米饭炒饭次数
    public let riceCount: Int
    /// 面条米粉螺蛳粉次数
    public let noodleCount: Int
    /// 面点包子煎饼次数
    public let pastryCount: Int
    /// 面食占总主食比例 (0~1)
    public var noodleRatio: Double {
        totalStapleCount > 0 ? Double(noodleCount) / Double(totalStapleCount) : 0
    }
    /// 米饭占总主食比例 (0~1)
    public var riceRatio: Double {
        totalStapleCount > 0 ? Double(riceCount) / Double(totalStapleCount) : 0
    }
    /// 最常吃的主食 Top
    public let topStaples: [String]

    public init(style: StapleStyle,
                totalStapleCount: Int,
                riceCount: Int,
                noodleCount: Int,
                pastryCount: Int,
                topStaples: [String]) {
        self.style = style
        self.totalStapleCount = totalStapleCount
        self.riceCount = riceCount
        self.noodleCount = noodleCount
        self.pastryCount = pastryCount
        self.topStaples = topStaples
    }
}

// MARK: - 零食与加餐习惯画像

/// 零食加餐习惯
public struct SnackHabitProfile: Equatable, Sendable {
    /// 零食小吃摄入总次数
    public let totalSnackCount: Int
    /// 是否有下午茶加餐习惯（14:00~17:00）
    public let hasAfternoonTeaHabit: Bool
    /// 是否有夜宵习惯（21:00 之后）
    public let hasLateNightHabit: Bool
    /// 最常吃的小吃零食 Top
    public let topSnacks: [String]
    /// 简述
    public let summary: String

    public init(totalSnackCount: Int,
                hasAfternoonTeaHabit: Bool,
                hasLateNightHabit: Bool,
                topSnacks: [String],
                summary: String) {
        self.totalSnackCount = totalSnackCount
        self.hasAfternoonTeaHabit = hasAfternoonTeaHabit
        self.hasLateNightHabit = hasLateNightHabit
        self.topSnacks = topSnacks
        self.summary = summary
    }
}

// MARK: - 完整饮食画像

/// 用户的综合饮食偏好与习惯画像
public struct DietaryPreferenceProfile: Equatable, Sendable {
    /// 统计样本记录总数
    public let sampleCount: Int
    /// 饮品习惯
    public let beverage: BeverageHabitProfile
    /// 主食习惯
    public let staple: StapleHabitProfile
    /// 零食小吃习惯
    public let snack: SnackHabitProfile
    /// 最常吃的所有食物排行 Top 5 (食物名称, 频次)
    public let topFoods: [(name: String, count: Int)]
    /// 个性化饮食标签（如「☕️ 晨间美式星人」「🍜 狂热面食派」「🧋 周末下午茶爱好者」）
    public let tags: [String]

    public init(sampleCount: Int,
                beverage: BeverageHabitProfile,
                staple: StapleHabitProfile,
                snack: SnackHabitProfile,
                topFoods: [(name: String, count: Int)],
                tags: [String]) {
        self.sampleCount = sampleCount
        self.beverage = beverage
        self.staple = staple
        self.snack = snack
        self.topFoods = topFoods
        self.tags = tags
    }

    public static func == (lhs: DietaryPreferenceProfile, rhs: DietaryPreferenceProfile) -> Bool {
        lhs.sampleCount == rhs.sampleCount &&
        lhs.beverage == rhs.beverage &&
        lhs.staple == rhs.staple &&
        lhs.snack == rhs.snack &&
        lhs.tags == rhs.tags &&
        lhs.topFoods.map(\.name) == rhs.topFoods.map(\.name) &&
        lhs.topFoods.map(\.count) == rhs.topFoods.map(\.count)
    }
}

// MARK: - 智能饮食建议

/// 当前时段对应的餐点时机
public enum DietaryMealSlot: String, Sendable, CaseIterable {
    case breakfast = "早餐时段"
    case lunch = "午餐时段"
    case afternoonTea = "下午茶时段"
    case dinner = "晚餐时段"
    case lateNight = "深夜时段"

    /// 根据小时确定时段（24小时制）
    public static func from(hour: Int) -> DietaryMealSlot {
        switch hour {
        case 5..<10: return .breakfast
        case 10..<14: return .lunch
        case 14..<17: return .afternoonTea
        case 17..<21: return .dinner
        default: return .lateNight
        }
    }
}

// MARK: - 场景化饮食建议项与健康上下文

/// 身体与生理健康上下文（从 HealthKit / VitalityEvaluator 注入，实现睡眠负债与运动消耗跟饮食的深度协同闭环）
public struct DietaryHealthContext: Equatable, Sendable {
    /// 昨晚睡眠时长（小时）
    public let sleepHours: Double?
    /// 是否存在睡眠负债（睡眠时长 < 6.0 小时或严重缺觉）
    public let isSleepDeprived: Bool
    /// 今日身体活动消耗能量（千卡）
    public let activeCalories: Double?
    /// 今日总步数
    public let stepCount: Int?
    /// 综合身体活力分（0~100）
    public let vitalityScore: Int?

    public init(
        sleepHours: Double? = nil,
        isSleepDeprived: Bool = false,
        activeCalories: Double? = nil,
        stepCount: Int? = nil,
        vitalityScore: Int? = nil
    ) {
        self.sleepHours = sleepHours
        self.isSleepDeprived = isSleepDeprived
        self.activeCalories = activeCalories
        self.stepCount = stepCount
        self.vitalityScore = vitalityScore
    }
}

/// 场景化饮食建议项
public struct DietaryRecommendation: Equatable, Sendable, Identifiable {
    public let id: String
    /// 建议针对的时段
    public let slot: DietaryMealSlot
    /// 建议标题（如「下午茶灵感」「午餐偏好推荐」）
    public let title: String
    /// 懂用户的偏好说明与具体推荐食物
    public let suggestionText: String
    /// 推荐食物候选（名称列表）
    public let suggestedFoods: [String]
    /// 营养与热量健康提醒（例如「今日已摄入拿铁，下午推荐低卡无糖乌龙茶」）
    public let healthTip: String?
    /// 是否属于控卡/健康替代推荐
    public let isHealthierAlternative: Bool

    public init(id: String = UUID().uuidString,
                slot: DietaryMealSlot,
                title: String,
                suggestionText: String,
                suggestedFoods: [String],
                healthTip: String? = nil,
                isHealthierAlternative: Bool = false) {
        self.id = id
        self.slot = slot
        self.title = title
        self.suggestionText = suggestionText
        self.suggestedFoods = suggestedFoods
        self.healthTip = healthTip
        self.isHealthierAlternative = isHealthierAlternative
    }
}

// MARK: - 饮食偏好分析器纯逻辑

public enum DietaryPreferenceAnalyzer {

    /// 从历史摄入记录中分析生成用户的饮食画像与当前时段的专属建议。
    public static func analyze(
        records: [FoodIntakeItemSummary],
        now: Date = .now,
        todayRecords: [FoodIntakeItemSummary] = [],
        healthContext: DietaryHealthContext? = nil,
        calendar: Calendar = .current
    ) -> (profile: DietaryPreferenceProfile, recommendations: [DietaryRecommendation]) {
        let profile = buildProfile(from: records, calendar: calendar)
        let recommendations = generateRecommendations(
            profile: profile,
            records: records,
            todayRecords: todayRecords,
            healthContext: healthContext,
            now: now,
            calendar: calendar
        )
        return (profile, recommendations)
    }

    // MARK: - 构建偏好画像

    public static func buildProfile(
        from records: [FoodIntakeItemSummary],
        calendar: Calendar = .current
    ) -> DietaryPreferenceProfile {
        guard !records.isEmpty else {
            return makeEmptyProfile()
        }

        // 1. 统计食物频次 Top 5
        var foodCounts: [String: Int] = [:]
        for item in records {
            foodCounts[item.foodName, default: 0] += 1
        }
        let topFoods = foodCounts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }

        // 2. 统计饮品
        let drinkRecords = records.filter { $0.category == .drink || isDrinkFood(foodID: $0.foodID, name: $0.foodName) }
        var coffeeCount = 0
        var milkTeaCount = 0
        var teaCount = 0
        var otherDrinkCount = 0
        var drinkCounts: [String: Int] = [:]
        var morningDrinkCount = 0
        var afternoonDrinkCount = 0

        for r in drinkRecords {
            drinkCounts[r.foodName, default: 0] += 1
            let hour = calendar.component(.hour, from: r.date)
            if (7...11).contains(hour) { morningDrinkCount += 1 }
            if (13...17).contains(hour) { afternoonDrinkCount += 1 }

            let id = r.foodID.lowercased()
            let name = r.foodName.lowercased()
            if id.contains("coffee") || id.contains("latte") || name.contains("咖啡") || name.contains("拿铁") || name.contains("美式") {
                coffeeCount += 1
            } else if id.contains("milk_tea") || name.contains("奶茶") {
                milkTeaCount += 1
            } else if id.contains("tea") || name.contains("茶") {
                teaCount += 1
            } else {
                otherDrinkCount += 1
            }
        }

        let beverageStyle: BeverageStyle
        if coffeeCount >= max(milkTeaCount, teaCount, otherDrinkCount) && coffeeCount > 0 {
            beverageStyle = .coffeeLover
        } else if milkTeaCount > coffeeCount && milkTeaCount >= teaCount {
            beverageStyle = .milkTeaFan
        } else if teaCount > coffeeCount && teaCount >= milkTeaCount {
            beverageStyle = .healthyTea
        } else if otherDrinkCount > 0 && drinkRecords.count > 0 {
            beverageStyle = .fruitJuice
        } else {
            beverageStyle = .balanced
        }

        let topBeverages = drinkCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let typicalTimeDesc: String
        if morningDrinkCount > afternoonDrinkCount && morningDrinkCount > 0 {
            typicalTimeDesc = "多在晨间 08:00-10:30 饮用"
        } else if afternoonDrinkCount > 0 {
            typicalTimeDesc = "多在午后 14:00-16:30 饮用"
        } else {
            typicalTimeDesc = "全天匀称饮用"
        }

        let beverageProfile = BeverageHabitProfile(
            style: beverageStyle,
            totalDrinkCount: drinkRecords.count,
            coffeeCount: coffeeCount,
            milkTeaCount: milkTeaCount,
            teaCount: teaCount,
            otherDrinkCount: otherDrinkCount,
            topBeverages: topBeverages,
            typicalTimeDescription: typicalTimeDesc
        )

        // 3. 统计主食
        let stapleRecords = records.filter { $0.category == .staple || isStapleFood(foodID: $0.foodID) }
        var riceCount = 0
        var noodleCount = 0
        var pastryCount = 0
        var stapleCounts: [String: Int] = [:]

        for r in stapleRecords {
            stapleCounts[r.foodName, default: 0] += 1
            let id = r.foodID.lowercased()
            let name = r.foodName.lowercased()
            if id.contains("noodle") || name.contains("面") || name.contains("粉") || id.contains("zhajiangmian") {
                noodleCount += 1
            } else if id.contains("rice") || name.contains("饭") {
                riceCount += 1
            } else {
                pastryCount += 1
            }
        }

        let stapleStyle: StapleStyle
        if noodleCount > riceCount && noodleCount >= pastryCount {
            stapleStyle = .noodleLover
        } else if riceCount >= noodleCount && riceCount > 0 {
            stapleStyle = .riceLover
        } else if pastryCount > 0 {
            stapleStyle = .pastryBun
        } else {
            stapleStyle = .balanced
        }

        let topStaples = stapleCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let stapleProfile = StapleHabitProfile(
            style: stapleStyle,
            totalStapleCount: stapleRecords.count,
            riceCount: riceCount,
            noodleCount: noodleCount,
            pastryCount: pastryCount,
            topStaples: topStaples
        )

        // 4. 统计零食小吃加餐
        let snackRecords = records.filter { $0.category == .snack || $0.category == .dessert }
        var afternoonSnackCount = 0
        var lateNightSnackCount = 0
        var snackCounts: [String: Int] = [:]

        for r in snackRecords {
            snackCounts[r.foodName, default: 0] += 1
            let hour = calendar.component(.hour, from: r.date)
            if (14...17).contains(hour) { afternoonSnackCount += 1 }
            if hour >= 21 || hour < 4 { lateNightSnackCount += 1 }
        }

        let hasAfternoonTea = afternoonSnackCount >= 2 || (drinkRecords.count >= 2 && afternoonDrinkCount >= 2)
        let hasLateNight = lateNightSnackCount >= 2
        let topSnacks = snackCounts.sorted { $0.value > $1.value }.prefix(3).map(\.key)

        var snackSummaryParts: [String] = []
        if hasAfternoonTea { snackSummaryParts.append("有午后加餐习惯") }
        if hasLateNight { snackSummaryParts.append("夜间容易加餐") }
        if snackSummaryParts.isEmpty { snackSummaryParts.append("极少吃高热量零食，饮食较规律") }

        let snackProfile = SnackHabitProfile(
            totalSnackCount: snackRecords.count,
            hasAfternoonTeaHabit: hasAfternoonTea,
            hasLateNightHabit: hasLateNight,
            topSnacks: topSnacks,
            summary: snackSummaryParts.joined(separator: " · ")
        )

        // 5. 生成生动饮食标签
        var tags: [String] = []
        switch beverageStyle {
        case .coffeeLover: tags.append("☕️ 晨醒咖啡星人")
        case .milkTeaFan: tags.append("🧋 奶茶解压党")
        case .healthyTea: tags.append("🍵 养生茶饮派")
        case .fruitJuice: tags.append("🥤 鲜果轻饮控")
        case .sodaBeverage: tags.append("🫧 气泡快乐水")
        case .balanced: tags.append("💧 规律饮水型")
        }

        switch stapleStyle {
        case .noodleLover: tags.append("🍜 狂热面条派")
        case .riceLover: tags.append("🍚 忠实米饭主粮党")
        case .pastryBun: tags.append("🥟 碳水面点早点控")
        case .lightDiet: tags.append("🥗 轻食控卡自律者")
        case .balanced: tags.append("🍱 荤素多样均衡")
        }

        if hasAfternoonTea {
            tags.append("🍪 下午茶能量补给员")
        }
        if hasLateNight {
            tags.append("🌙 夜猫子防破戒守护")
        }

        return DietaryPreferenceProfile(
            sampleCount: records.count,
            beverage: beverageProfile,
            staple: stapleProfile,
            snack: snackProfile,
            topFoods: topFoods,
            tags: tags
        )
    }

    // MARK: - 生成智能时段建议

    public static func generateRecommendations(
        profile: DietaryPreferenceProfile,
        records: [FoodIntakeItemSummary],
        todayRecords: [FoodIntakeItemSummary] = [],
        healthContext: DietaryHealthContext? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [DietaryRecommendation] {
        let hour = calendar.component(.hour, from: now)
        let currentSlot = DietaryMealSlot.from(hour: hour)
        var list: [DietaryRecommendation] = []

        let isSleepDeprived = healthContext?.isSleepDeprived == true
        let sleepHours = healthContext?.sleepHours
        let activeCal = healthContext?.activeCalories ?? 0
        let steps = healthContext?.stepCount ?? 0
        let isHighWorkout = activeCal >= 450 || steps >= 10000

        // 统计今日已摄入的热量与咖啡因
        let todayCalories = todayRecords.reduce(0.0) { $0 + $1.calories }
        let hasHadCoffeeToday = todayRecords.contains { r in
            r.foodID.contains("coffee") || r.foodID.contains("latte") || r.foodName.contains("咖啡") || r.foodName.contains("拿铁")
        }
        let hasHadMilkTeaToday = todayRecords.contains { r in
            r.foodID.contains("milk_tea") || r.foodName.contains("奶茶")
        }

        switch currentSlot {
        case .breakfast:
            var suggested: [String] = []
            if !profile.staple.topStaples.isEmpty {
                suggested.append(contentsOf: profile.staple.topStaples.prefix(2))
            } else {
                suggested.append(contentsOf: ["包子/生煎/小笼", "粥/稀饭"])
            }
            if profile.beverage.style == .coffeeLover {
                suggested.append("黑咖啡/美式")
            } else {
                suggested.append("豆浆")
            }

            if isSleepDeprived {
                let sleepText = sleepHours.map { String(format: "%.1f", $0) } ?? "偏短"
                let desc = profile.beverage.style == .coffeeLover
                    ? "昨夜睡眠偏短（约 \(sleepText) 小时），身体容易感到倦怠。建议先饮用温开水补水，再来 1 杯温美式或黑咖啡唤醒状态；同时请搭配富含优质蛋白的早餐（鸡蛋/豆浆），平抑日间疲劳与食欲波动。"
                    : "昨夜睡眠偏短（约 \(sleepText) 小时），晨起先来一杯温开水加速身体代谢，早餐推荐温热面点搭配高蛋白饮品（豆浆/牛奶），给身体补充第一波温和元气。"

                list.append(DietaryRecommendation(
                    slot: .breakfast,
                    title: "早安 · 睡眠负债温和唤醒",
                    suggestionText: desc,
                    suggestedFoods: suggested,
                    healthTip: "缺觉时体内皮质醇偏高易诱发对糖的渴望，早餐摄入优质蛋白能有效平抑全天暴食冲动。"
                ))
            } else {
                let desc = profile.beverage.style == .coffeeLover
                    ? "早安！按照您的习惯，晨间来一杯黑咖啡唤醒状态，搭配热乎主食吸收更平稳。"
                    : "早安！美好的一天从温热营养早餐开始，推荐一份面点搭配新鲜饮品。"

                list.append(DietaryRecommendation(
                    slot: .breakfast,
                    title: "早餐元气灵感",
                    suggestionText: desc,
                    suggestedFoods: suggested,
                    healthTip: "晨起第一餐建议搭配优质蛋白与低升糖碳水，饱腹感更持久。"
                ))
            }

        case .lunch:
            var suggested: [String] = []
            let stapleName: String
            if profile.staple.style == .noodleLover {
                stapleName = profile.staple.topStaples.first ?? "面条/拉面"
                suggested = [stapleName, "西红柿炒鸡蛋/荷包蛋", "炒青菜"]
            } else {
                stapleName = profile.staple.topStaples.first ?? "米饭"
                suggested = [stapleName, "辣椒炒肉/家常小炒", "炒青菜"]
            }

            let desc = "午餐时间到了！您平时更偏好\(profile.staple.style.rawValue)（\(stapleName)），推荐搭配一份绿叶青菜与高蛋白主菜。"
            list.append(DietaryRecommendation(
                slot: .lunch,
                title: "午餐懂你推荐",
                suggestionText: desc,
                suggestedFoods: suggested,
                healthTip: "吃完主食搭配青菜慢速咀嚼，避免午后血糖剧烈波动引发犯困。"
            ))

        case .afternoonTea:
            if isSleepDeprived {
                // 核心闭环：睡眠不足时，下午茶强制避免高咖啡因，打破失眠恶性循环
                list.append(DietaryRecommendation(
                    slot: .afternoonTea,
                    title: "🛑 睡眠负债预警 · 控咖啡因护睡眠",
                    suggestionText: "监测到昨夜睡眠欠佳，午后 14:00 后强烈建议避免重度咖啡因（拿铁/冷萃/高糖奶茶），改喝无糖麦茶、椰子水或温开水，打破「白天疲劳狂饮咖啡因 ➔ 今晚继续失眠」的恶性循环！",
                    suggestedFoods: ["无糖纯茶/乌龙茶", "椰子水/椰青", "苹果", "温开水"],
                    healthTip: "咖啡因体内半衰期长达 5~8 小时，午后控制咖啡因是今晚重获深睡眠的第一步。",
                    isHealthierAlternative: true
                ))
            } else if profile.beverage.style == .coffeeLover {
                if hasHadCoffeeToday {
                    list.append(DietaryRecommendation(
                        slot: .afternoonTea,
                        title: "下午茶健康平替",
                        suggestionText: "您今早已经享用过咖啡，午后建议换成清润温和的无糖纯茶或椰子水，避免晚间入睡困难。",
                        suggestedFoods: ["无糖纯茶/乌龙茶", "椰子水/椰青", "水果拼盘"],
                        healthTip: "摄入适量水分与维C，既能解腻提神又不会增加额外热量负担。",
                        isHealthierAlternative: true
                    ))
                } else {
                    let favCoffee = profile.beverage.topBeverages.first ?? "拿铁/卡布奇诺"
                    list.append(DietaryRecommendation(
                        slot: .afternoonTea,
                        title: "午后咖啡提神时光",
                        suggestionText: "下午工作稍作小憩，来一杯您喜爱的「\(favCoffee)」，热量适中，满血复活！",
                        suggestedFoods: [favCoffee, "坚果/花生"],
                        healthTip: "若追求控卡，拿铁可选择换脱脂奶或生椰无糖版本。"
                    ))
                }
            } else if profile.beverage.style == .milkTeaFan {
                if hasHadMilkTeaToday || todayCalories > 1500 {
                    list.append(DietaryRecommendation(
                        slot: .afternoonTea,
                        title: "低卡轻盈下午茶推荐",
                        suggestionText: "知道您爱喝甜润饮品，但今天热量预算较紧，强烈安利手打柠檬茶或无糖气泡水，同样清爽解馋！",
                        suggestedFoods: ["手打柠檬茶", "无糖可乐/气泡水", "苹果"],
                        healthTip: "一杯标准全糖奶茶热量约 350~500 千卡，换成柠檬茶能轻松省下 300 千卡！",
                        isHealthierAlternative: true
                    ))
                } else {
                    let favDrink = profile.beverage.topBeverages.first ?? "手打柠檬茶"
                    list.append(DietaryRecommendation(
                        slot: .afternoonTea,
                        title: "下午茶解馋时光",
                        suggestionText: "到了犒劳自己的午后时光，来一杯您常喝的「\(favDrink)」，建议选择微糖更轻盈。",
                        suggestedFoods: [favDrink, "酸奶"]
                    ))
                }
            } else {
                list.append(DietaryRecommendation(
                    slot: .afternoonTea,
                    title: "午后补水与轻食能量",
                    suggestionText: "午后工作间隙补充水分与微量元素，推荐一份清甜水果或无糖好茶。",
                    suggestedFoods: ["水果拼盘", "无糖纯茶/乌龙茶", "坚果/花生"]
                ))
            }

        case .dinner:
            if isSleepDeprived {
                list.append(DietaryRecommendation(
                    slot: .dinner,
                    title: "晚餐轻负担修复方案",
                    suggestionText: "昨夜缺觉导致身体代谢负荷偏重，今晚推荐清淡温和的家常菜或热汤（如冬瓜排骨汤、清蒸鱼、时蔬），给肠胃减负，为今晚提前入睡修复做好准备。",
                    suggestedFoods: ["清蒸鱼", "蔬菜沙拉/轻食", "番茄蛋花汤/紫菜蛋汤"],
                    healthTip: "睡前 2~3 小时避免高脂油腻大餐，温热易消化的饮食利于体温自然下降并促进深睡眠。",
                    isHealthierAlternative: true
                ))
            } else if isHighWorkout {
                let staple = profile.staple.topStaples.first ?? "米饭"
                let burnText = activeCal > 0 ? "活动消耗超 \(Int(activeCal)) 千卡" : "步数超 1 万步"
                list.append(DietaryRecommendation(
                    slot: .dinner,
                    title: "🔥 今日暴汗运动能量犒劳",
                    suggestionText: "今日身体运动消耗充沛（\(burnText)），热量预算相当宽裕！晚餐可安心补充优质碳水主食与优质蛋白（牛排/鸡胸/鱼肉），帮助肌肉糖原快速复原。",
                    suggestedFoods: [staple, "牛排", "炒青菜", "番茄蛋花汤/紫菜蛋汤"],
                    healthTip: "高消耗后适量补充优质蛋白与碳水能避免代谢代偿性下调，放心享受美食无负担。"
                ))
            } else if todayCalories > 1400 {
                let suggested = ["蔬菜沙拉/轻食", "清蒸鱼", "水蒸蛋/鸡蛋羹"]
                list.append(DietaryRecommendation(
                    slot: .dinner,
                    title: "晚餐清淡控卡方案",
                    suggestionText: "今天白天摄入较丰富，晚餐建议以清淡素菜、优质鱼肉蛋白为主，减轻夜间肠胃负担。",
                    suggestedFoods: suggested,
                    healthTip: "晚间适度减少精制碳水，有助于夜间深度睡眠与体脂管理。",
                    isHealthierAlternative: true
                ))
            } else {
                let staple = profile.staple.topStaples.first ?? "米饭"
                let suggested = [staple, "西红柿炒鸡蛋/荷包蛋", "番茄蛋花汤/紫菜蛋汤"]
                list.append(DietaryRecommendation(
                    slot: .dinner,
                    title: "温馨晚饭搭配",
                    suggestionText: "晚餐时间到了，犒赏劳碌一天，推荐一份暖胃汤品与家常菜肴。",
                    suggestedFoods: suggested,
                    healthTip: "睡前 3 小时完成晚餐，让身体进入轻松平稳的夜间修复状态。"
                ))
            }

        case .lateNight:
            if isSleepDeprived {
                list.append(DietaryRecommendation(
                    slot: .lateNight,
                    title: "🛌 助眠蓄力关怀",
                    suggestionText: "昨夜睡眠欠佳，今晚请务必放下手机提早休息！如果睡前略有饥饿感，可饮用小半杯脱脂温牛奶安神，争取今晚 23:00 前熄灯就寝。",
                    suggestedFoods: ["脱脂温牛奶", "温开水"],
                    healthTip: "温牛奶中的色氨酸是合成褪黑素的原料，有助温和酝酿睡意。",
                    isHealthierAlternative: true
                ))
            } else {
                list.append(DietaryRecommendation(
                    slot: .lateNight,
                    title: "深夜防破戒关怀",
                    suggestionText: "夜深了容易嘴馋！如果肚子饿想吃东西，尽量避开高热量烧烤与油炸薯片，推荐喝杯温开水或少量无糖酸奶。",
                    suggestedFoods: ["无糖酸奶", "苹果", "温开水"],
                    healthTip: "深夜摄入高油高钠小吃容易造成次日水肿与消化不良，管住嘴明天活力更满！",
                    isHealthierAlternative: true
                ))
            }
        }

        return list
    }

    // MARK: - 辅助判断

    private static func isDrinkFood(foodID: String, name: String) -> Bool {
        let id = foodID.lowercased()
        let n = name.lowercased()
        return id.contains("coffee") || id.contains("latte") || id.contains("tea") || id.contains("cola") || id.contains("juice") || id.contains("drink") || id.contains("milk") || n.contains("咖啡") || n.contains("拿铁") || n.contains("奶茶") || n.contains("茶") || n.contains("可乐") || n.contains("豆浆") || n.contains("果汁")
    }

    private static func isStapleFood(foodID: String) -> Bool {
        let id = foodID.lowercased()
        return id.contains("rice") || id.contains("noodle") || id.contains("bread") || id.contains("bun") || id.contains("mantou") || id.contains("dumpling") || id.contains("congee") || id.contains("pancake") || id.contains("fastfood")
    }

    private static func makeEmptyProfile() -> DietaryPreferenceProfile {
        DietaryPreferenceProfile(
            sampleCount: 0,
            beverage: BeverageHabitProfile(style: .balanced, totalDrinkCount: 0, coffeeCount: 0, milkTeaCount: 0, teaCount: 0, otherDrinkCount: 0, topBeverages: [], typicalTimeDescription: "记录多几餐后自动生成"),
            staple: StapleHabitProfile(style: .balanced, totalStapleCount: 0, riceCount: 0, noodleCount: 0, pastryCount: 0, topStaples: []),
            snack: SnackHabitProfile(totalSnackCount: 0, hasAfternoonTeaHabit: false, hasLateNightHabit: false, topSnacks: [], summary: "尚无零食小吃数据"),
            topFoods: [],
            tags: ["🌱 饮食档案起步中", "🍽️ 记录饮食解锁专属偏好"]
        )
    }
}
