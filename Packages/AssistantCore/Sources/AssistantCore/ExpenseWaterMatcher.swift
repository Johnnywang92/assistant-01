import Foundation

/// 记账条目匹配饮水记录的纯逻辑
///
/// 场景：用户记账「买咖啡 18 元」、「瑞幸生椰拿铁」、「喜茶波波奶茶」、「星巴克大杯美式」等，
/// 自动推断饮品种类、估算容积与生理补水量，并生成待联动的饮水记录。
public enum ExpenseWaterMatcher {

    /// 匹配出的饮水建议参数
    public struct Suggestion: Equatable, Sendable {
        /// 识别出的饮品类别
        public let beverageType: HydrationBeverageType
        /// 饮用容积（毫升）
        public let volumeML: Double
        /// 饮品名称（如「生椰拿铁」、「珍珠奶茶」、「冰美式」）
        public let customName: String
        /// 水分有效折算系数 (0.0 ~ 1.0)
        public let hydrationFactor: Double
        /// 折算后的有效补水量（毫升）
        public let effectiveHydrationML: Double
        /// 估算咖啡因含量（毫克）
        public let caffeineMG: Double
        /// 估算热量（千卡）
        public let calories: Double

        public init(
            beverageType: HydrationBeverageType,
            volumeML: Double,
            customName: String,
            hydrationFactor: Double? = nil,
            effectiveHydrationML: Double? = nil,
            caffeineMG: Double? = nil,
            calories: Double? = nil
        ) {
            self.beverageType = beverageType
            self.volumeML = volumeML
            self.customName = customName
            let factor = hydrationFactor ?? beverageType.defaultHydrationFactor
            self.hydrationFactor = factor
            self.effectiveHydrationML = effectiveHydrationML ?? (volumeML * factor).rounded()
            self.caffeineMG = caffeineMG ?? ((volumeML / 100.0) * beverageType.estimatedCaffeinePer100ml).rounded()
            self.calories = calories ?? ((volumeML / 100.0) * beverageType.estimatedCaloriesPer100ml).rounded()
        }
    }

    // MARK: 排除词（非饮品）

    /// 避免将「咖啡豆」、「咖啡机」、「可乐鸡翅」、「茶叶蛋」等误判为饮品
    private static let nonDrinkPatterns: [String] = [
        "咖啡豆", "咖啡粉", "咖啡机", "咖啡滤纸", "咖啡壶", "咖啡糖",
        "可乐鸡翅", "可乐鸭", "可乐排骨",
        "茶叶蛋", "茶树菇", "茶饼", "茶具", "茶壶", "茶杯",
        "奶茶色", "奶茶裙", "奶茶蛋糕", "奶茶冰淇淋", "奶茶雪糕",
        "牛奶糖", "牛奶饼干", "牛奶棒",
        "汽水糖", "啤酒鸭"
    ]

    // MARK: 知名饮品品牌与简称（便于提取中心饮品词）

    private static let brandPrefixes: [String] = [
        "星巴克", "瑞幸", "库迪", "manner", "mstand", "tims", "幸运咖",
        "喜茶", "奈雪", "奈雪的茶", "霸王茶姬", "茶百道", "茶颜悦色", "一点点",
        "蜜雪冰城", "coco都可", "coco", "古茗", "沪上阿姨", "书亦烧仙草", "乐乐茶",
        "东方树叶", "三得利", "农夫山泉", "怡宝", "娃哈哈", "康师傅", "统一"
    ]

    // MARK: 核心匹配函数

    /// 根据记账文本推测饮水记录建议；若不是饮品则返回 nil。
    public static func match(title: String) -> Suggestion? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()

        // 1. 命中排除词则直接返回 nil
        for forbidden in nonDrinkPatterns {
            if lowercased.contains(forbidden) {
                return nil
            }
        }

        // 2. 判定饮品种类
        guard let beverageType = detectBeverageType(lowercased) else {
            return nil
        }

        // 3. 提取饮品自定义名称
        let customName = extractDrinkName(from: trimmed, beverageType: beverageType)

        // 4. 提取或推算容量
        let volumeML = estimateVolumeML(from: lowercased, beverageType: beverageType)

        return Suggestion(
            beverageType: beverageType,
            volumeML: volumeML,
            customName: customName
        )
    }

    // MARK: - 内部辅助方法

    private static func detectBeverageType(_ text: String) -> HydrationBeverageType? {
        // 奶茶 / 果茶
        if text.contains("奶茶") || text.contains("果茶") || text.contains("烧仙草") ||
           text.contains("波霸") || text.contains("珍珠奶") || text.contains("杨枝甘露") ||
           text.contains("霸王茶姬") || text.contains("喜茶") || text.contains("奈雪") ||
           text.contains("茶百道") || text.contains("茶颜悦色") || text.contains("古茗") ||
           text.contains("沪上阿姨") || text.contains("一点点") {
            return .milkTea
        }

        // 拿铁 / 奶咖类
        if text.contains("拿铁") || text.contains("卡布奇诺") || text.contains("摩卡") ||
           text.contains("澳白") || text.contains("馥芮白") || text.contains("生椰拿铁") ||
           text.contains("燕麦拿铁") || text.contains("奶咖") || text.contains("玛奇朵") {
            return .latte
        }

        // 黑咖啡 / 美式类
        if text.contains("美式") || text.contains("黑咖啡") || text.contains("黑咖") ||
           text.contains("手冲") || text.contains("浓缩") || text.contains("冷萃") ||
           text.contains("咖啡") || text.contains("coffee") || text.contains("espresso") ||
           text.contains("americano") || text.contains("星巴克") || text.contains("瑞幸") ||
           text.contains("库迪") || text.contains("manner") {
            return .blackCoffee
        }

        // 柠檬水 / 气泡水 / 苏打水
        if text.contains("柠檬水") || text.contains("气泡水") || text.contains("苏打水") ||
           text.contains("无糖气泡") {
            return .sparklingWater
        }

        // 牛奶 / 豆奶
        if text.contains("牛奶") || text.contains("豆浆") || text.contains("豆奶") ||
           text.contains("鲜牛奶") || text.contains("燕麦奶") {
            return .milk
        }

        // 含糖饮料 / 碳酸饮料 / 果汁
        if text.contains("可乐") || text.contains("雪碧") || text.contains("芬达") ||
           text.contains("汽水") || text.contains("果汁") || text.contains("橙汁") ||
           text.contains("苹果汁") || text.contains("椰子水") || text.contains("加多宝") ||
           text.contains("王老吉") || text.contains("冰红茶") {
            return .sugaryDrink
        }

        // 纯茶 / 淡茶
        if text.contains("纯茶") || text.contains("乌龙茶") || text.contains("绿茶") ||
           text.contains("红茶") || text.contains("普洱") || text.contains("茉莉花茶") ||
           text.contains("龙井") || text.contains("铁观音") || text.contains("东方树叶") ||
           text.contains("三得利") {
            return .pureTea
        }

        // 水
        if text.contains("白开水") || text.contains("矿泉水") || text.contains("纯净水") {
            return .plainWater
        }

        return nil
    }

    private static func estimateVolumeML(from text: String, beverageType: HydrationBeverageType) -> Double {
        // 1. 优先提取显式容量数值（如 500ml, 350毫升, 1.5L 等）
        if let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(?:ml|毫升)", options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range(at: 1), in: text),
           let val = Double(text[range]), val > 0, val <= 5000 {
            return val
        }
        if let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(?:l|升)", options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let range = Range(match.range(at: 1), in: text),
           let val = Double(text[range]), val > 0, val <= 5 {
            return val * 1000.0
        }

        // 2. 数量乘数（如两杯、2杯、3瓶等）
        var multiplier = 1.0
        if text.contains("两杯") || text.contains("2杯") || text.contains("两瓶") || text.contains("2瓶") {
            multiplier = 2.0
        } else if text.contains("三杯") || text.contains("3杯") || text.contains("三瓶") || text.contains("3瓶") {
            multiplier = 3.0
        } else if text.contains("半杯") || text.contains("半瓶") {
            multiplier = 0.5
        }

        // 3. 杯型基础容量
        let baseVolume: Double
        if text.contains("超大杯") || text.contains("超大份") || text.contains("venti") {
            baseVolume = 550.0
        } else if text.contains("大杯") || text.contains("大份") || text.contains("grande") ||
                  text.contains("一瓶") || text.contains("1瓶") || text.contains("瓶") {
            baseVolume = 500.0
        } else if text.contains("小杯") || text.contains("小份") || text.contains("mini") || text.contains("tall") {
            baseVolume = 250.0
        } else if text.contains("罐") || text.contains("听") {
            baseVolume = 330.0
        } else {
            // 标准/默认容量
            switch beverageType {
            case .milkTea:
                baseVolume = 450.0 // 奶茶常规杯多为 450~500ml
            case .blackCoffee, .latte:
                baseVolume = 350.0 // 咖啡常规中杯约 350ml
            case .pureTea, .sugaryDrink:
                baseVolume = 350.0
            default:
                baseVolume = 300.0
            }
        }

        return (baseVolume * multiplier).rounded()
    }

    private static func extractDrinkName(from text: String, beverageType: HydrationBeverageType) -> String {
        var cleaned = text

        // 去掉开头的常见动作词与标点
        let prefixes = ["买了一杯", "买了一瓶", "买了两杯", "买了两瓶", "买了一罐", "买了一听", "买", "喝了", "喝", "来一杯", "一杯", "一瓶", "一罐", "一听"]
        for p in prefixes {
            if cleaned.hasPrefix(p) {
                cleaned = String(cleaned.dropFirst(p.count))
                break
            }
        }

        // 去掉末尾的金额或后缀（如「18元」、「20块钱」、「15¥」等）
        if let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(?:元|块钱|块|rmb|cny|¥|￥)?$", options: .caseInsensitive),
           let match = regex.firstMatch(in: cleaned, range: NSRange(location: 0, length: cleaned.utf16.count)),
           let range = Range(match.range, in: cleaned) {
            cleaned = String(cleaned[..<range.lowerBound])
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return beverageType.displayName
        }
        return cleaned
    }
}
