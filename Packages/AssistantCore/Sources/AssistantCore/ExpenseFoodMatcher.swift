import Foundation

// MARK: - 由记账条目推测饮食热量的纯逻辑
//
// 场景：用户在记账里写了「喜茶多肉葡萄」「瑞幸拿铁」「薯片」，可以顺手估算热量，
// 经用户确认后写入饮食记录。
//
// 分工与 FoodCalorieEstimator 一致：本文件只含纯函数（可单测），
// 本地 LLM 兜底与 SwiftData 读写在 app 侧。
//
// 诚实性约束：
// - 食物库命中的估算置信度固定为中等（0.6），LLM 兜底的固定为低（0.3），
//   不采信模型自评置信度。
// - LLM 给出的热量必须通过合理区间校验，离谱数字直接丢弃。
// - 任何估算都必须经用户确认后才会入库（由 UI 层保证）。

/// 用餐时段。
public enum MealSlot: String, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack, lateNight

    public var displayName: String {
        switch self {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        case .lateNight: return "夜宵"
        }
    }
}

public enum ExpenseFoodMatcher {

    /// 估算来源。
    public enum Origin: String, Equatable, Sendable {
        /// 命中内置食物库
        case catalog
        /// 本地 LLM 兜底
        case llm
    }

    /// 一条待用户确认的热量建议。
    public struct Suggestion: Equatable, Sendable {
        /// 展示名（食物库菜名，或 LLM 给出的菜名）
        public let name: String
        /// 食物库 id（LLM 兜底且不在库中时为 nil）
        public let foodID: String?
        public let portion: FoodPortion
        /// 整份热量（千卡）
        public let fullPortionCalories: Double
        public let confidence: Double
        public let origin: Origin

        public init(name: String, foodID: String?, portion: FoodPortion,
                    fullPortionCalories: Double, confidence: Double, origin: Origin) {
            self.name = name
            self.foodID = foodID
            self.portion = portion
            self.fullPortionCalories = fullPortionCalories
            self.confidence = confidence
            self.origin = origin
        }
    }

    // MARK: 食物库匹配

    /// 饮品类 id：份量差异小（大杯 ≈ 1.3 倍，而不是主食的 1.8 倍），且受糖度影响。
    static let drinkIDs: Set<String> = ["coffee", "latte", "milk_tea", "cola", "juice", "alcohol"]

    /// 零食/饮品类：无论几点吃，都归入「加餐」。
    static let snackLikeIDs: Set<String> = [
        "coffee", "latte", "milk_tea", "cola", "juice", "alcohol",
        "cookie", "chips", "chocolate", "ice_cream", "cake", "pastry",
        "fruit", "nuts", "yogurt"
    ]

    /// 用记账标题匹配食物库。匹配不到返回 nil（不编造）。
    public static func suggest(title: String) -> Suggestion? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let portion = portion(from: text)

        guard let estimate = FoodCalorieEstimator.estimateMeal(
            fromHint: text, portion: portion, confidence: 0.6
        ) else { return nil }

        // 多菜（如「米饭 + 炒菜」）：直接沿用整餐累加结果
        guard estimate.dishes.count == 1 else {
            return Suggestion(name: estimate.displayName, foodID: nil, portion: portion,
                              fullPortionCalories: estimate.fullPortionCalories,
                              confidence: 0.6, origin: .catalog)
        }

        // 单品：用「中心词」匹配，而不是食物库顺序里的第一个命中。
        // 例：「喜茶多肉葡萄奶茶」同时含「葡萄」（水果）与「奶茶」，中文中心词在末尾，应取奶茶。
        let food = headFood(in: text) ?? estimate.food
        var calories: Double
        if drinkIDs.contains(food.id) {
            calories = food.standardServingCalories * drinkSizeFactor(portion)
            if food.id == "milk_tea" { calories *= sugarFactor(from: text) }
        } else {
            calories = food.standardServingCalories * portion.multiplier
        }
        return Suggestion(name: food.name, foodID: food.id, portion: portion,
                          fullPortionCalories: calories.rounded(),
                          confidence: 0.6, origin: .catalog)
    }

    /// 在标题中找「中心词」食物：取别名出现位置**最靠后**的食物，位置相同取别名更长的。
    static func headFood(in title: String) -> FoodItem? {
        let text = title.lowercased()
        var best: (food: FoodItem, end: Int, length: Int, exactName: Bool)?
        for food in FoodCatalog.items {
            let names = [food.name, food.nameEn] + food.aliases
            for name in names {
                let key = name.lowercased()
                guard key.count >= 2, let range = text.range(of: key, options: .backwards) else { continue }
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                let exactName = food.name.lowercased() == key || food.nameEn.lowercased() == key
                if best == nil || end > best!.end
                    || (end == best!.end && key.count > best!.length)
                    || (end == best!.end && key.count == best!.length && exactName && !best!.exactName) {
                    best = (food, end, key.count, exactName)
                }
            }
        }
        return best?.food
    }

    /// 从标题里的尺寸词判断份量。
    public static func portion(from title: String) -> FoodPortion {
        let t = title.lowercased()
        if ["超大", "加大", "大杯", "大份", "大号", "venti", "grande"].contains(where: t.contains) { return .large }
        if ["小杯", "小份", "迷你", "小号", "mini", "tall"].contains(where: t.contains) { return .small }
        return .regular
    }

    /// 饮品份量系数（杯型之间差异远小于主食份量）。
    static func drinkSizeFactor(_ portion: FoodPortion) -> Double {
        switch portion {
        case .small: return 0.75
        case .regular: return 1.0
        case .large: return 1.3
        }
    }

    /// 奶茶糖度系数：糖约占奶茶热量的三成上下，无糖/少糖相应下调。
    public static func sugarFactor(from title: String) -> Double {
        if ["无糖", "零糖", "不加糖", "0糖"].contains(where: title.contains) { return 0.75 }
        if ["微糖", "三分糖"].contains(where: title.contains) { return 0.82 }
        if ["半糖", "五分糖"].contains(where: title.contains) { return 0.88 }
        if ["少糖", "七分糖"].contains(where: title.contains) { return 0.94 }
        return 1.0
    }

    // MARK: LLM 兜底

    /// 单份食物热量的合理区间（千卡）。区间外一律视为模型胡编。
    public static let plausibleCalorieRange: ClosedRange<Double> = 20...2500

    /// 校验并转换 LLM 输出。校验不过返回 nil。
    ///
    /// 若 LLM 给的菜名恰好在食物库里，且热量与库基准差异过大（超出 0.4~1.6 倍），
    /// 以食物库基准为准，与照片估算的口径保持一致。
    public static func suggestion(fromLLM parsed: FoodLLMOutputParser.Parsed) -> Suggestion? {
        let name = parsed.foodName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 20,
              parsed.calories.isFinite,
              plausibleCalorieRange.contains(parsed.calories) else { return nil }

        var calories = parsed.calories
        var foodID: String?
        if let food = FoodCatalog.item(matchingNameStrict: name) {
            foodID = food.id
            let baseline = food.standardServingCalories
            let ratio = calories / baseline
            if baseline > 0, ratio < 0.4 || ratio > 1.6 { calories = baseline }
        }
        return Suggestion(name: name, foodID: foodID, portion: parsed.portion ?? .regular,
                          fullPortionCalories: calories.rounded(),
                          confidence: 0.3, origin: .llm)
    }

    // MARK: 用餐时段

    /// 按时间划分用餐时段；零食/饮品类食物固定为「加餐」。
    public static func mealSlot(for date: Date,
                                foodID: String? = nil,
                                calendar: Calendar = .current) -> MealSlot {
        if let foodID, snackLikeIDs.contains(foodID) { return .snack }
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<10: return .breakfast
        case 10..<14: return .lunch
        case 14..<17: return .snack
        case 17..<21: return .dinner
        default: return .lateNight
        }
    }
}
