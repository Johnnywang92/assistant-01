import Foundation

// MARK: - 食物照片热量估算的纯逻辑
//
// 分工（与 HealthMetrics 同一套路）：
// - 本文件：热量库、份量换算、Vision 类目映射、置信度分级、**吃剩比例调整**。
//   全部为纯函数，下沉 Core 以便单测覆盖（app target 没有测试 scheme）。
// - app 侧：Vision 图像分类、端侧 LLM 推理、UI。
//
// 贯穿全文件的诚实性约束：
// **照片推算的热量永远是「估算」**。Vision 的通用分类在实测中
// 披萨/汉堡能到 0.76~0.87，但沙拉只认出泛类「food」、米饭照片甚至被误判成蜻蜓。
// 因此：
// 1. 识别不到具体食物时，**不编造**——返回「需要用户选择」的候选列表。
// 2. 置信度必须如实呈现，低置信度要明确标注。
// 3. 份量是最大的误差源，所以**必须支持手动调整**（包括吃剩比例）。

// MARK: - 份量

/// 食物份量。热量估算的主要误差来源。
public enum FoodPortion: String, CaseIterable, Sendable {
    /// 一小份（约 100g / 半份主食）
    case small
    /// 一份（标准餐量，约 200~300g）
    case regular
    /// 一大份（约 400g 以上）
    case large

    /// 相对标准份量的倍数。用于把「每 100 克热量」换算成实际摄入。
    public var multiplier: Double {
        switch self {
        case .small: return 0.5
        case .regular: return 1.0
        case .large: return 1.8
        }
    }

    public var displayName: String {
        switch self {
        case .small: return "小份"
        case .regular: return "标准份"
        case .large: return "大份"
        }
    }
}

// MARK: - 食物分类

/// 食物所属的类别，方便在选择列表中分类筛选浏览。
public enum FoodCategory: String, CaseIterable, Sendable, Identifiable {
    /// 主食与早点（米饭、面条、包子、米粉、煎饼等）
    case staple = "主食早点"
    /// 荤菜与家常热菜（炒肉、红烧、鸡肉、鱼肉等）
    case meat = "荤菜热菜"
    /// 素菜、豆制品与菌菇（炒青菜、麻婆豆腐、菌菇等）
    case veggie = "素菜菌菇"
    /// 汤品与羹类（番茄蛋汤、排骨汤、鸡汤等）
    case soup = "汤品炖品"
    /// 特色小吃、烧烤与快餐（火锅、烧烤、披萨、汉堡、卤味等）
    case snack = "小吃快餐"
    /// 甜点、糕点与坚果（蛋糕、饼干、冰淇淋等）
    case dessert = "甜点零食"
    /// 饮品与新鲜水果（咖啡、奶茶、茶饮、苹果等）
    case drink = "饮品水果"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .staple: return "takeoutbag.and.cup.and.straw"
        case .meat: return "fork.knife"
        case .veggie: return "leaf"
        case .soup: return "cup.and.saucer"
        case .snack: return "flame"
        case .dessert: return "birthday.cake"
        case .drink: return "waterbottle"
        }
    }
}

// MARK: - 食物库

/// 一种食物的热量基准。热量值取每 100 克可食部分的千卡数（kcal/100g）。
///
/// 数值来源为常见食物成分表的公开区间中值，属于**估算基准**而非精确值。
/// 真实热量还会受做法（油盐用量）、食材比例影响，故 UI 必须标注为估算。
public struct FoodItem: Equatable, Sendable, Identifiable {
    public let id: String
    /// 中文名（展示用）
    public let name: String
    /// 英文名（本地化与 LLM 提示词用）
    public let nameEn: String
    /// 每 100 克可食部分的千卡数
    public let caloriesPer100g: Double
    /// 每 100 克蛋白质（克）
    public let proteinPer100g: Double
    /// 每 100 克脂肪（克）
    public let fatPer100g: Double
    /// 每 100 克碳水化合物（克）
    public let carbsPer100g: Double
    /// 食物分类
    public let category: FoodCategory
    /// Vision 通用分类里可能命中的类目标识符（小写）
    public let visionIdentifiers: [String]
    /// 中文别名，用于 LLM 把识别结果映射到具体食物
    public let aliases: [String]
    /// USDA 资料对应的常见份量；nil 时沿用内置估算份量。
    public let referenceServingGrams: Double?
    /// FoodData Central 原始记录 ID，用于追溯营养数值。
    public let fdcID: String?
    /// USDA 原始英文食物描述，可用于区分生熟及具体品种。
    public let referenceDescription: String?

    public init(id: String,
                name: String,
                nameEn: String,
                caloriesPer100g: Double,
                proteinPer100g: Double = 0,
                fatPer100g: Double = 0,
                carbsPer100g: Double = 0,
                category: FoodCategory = .staple,
                visionIdentifiers: [String] = [],
                aliases: [String] = [],
                referenceServingGrams: Double? = nil,
                fdcID: String? = nil,
                referenceDescription: String? = nil) {
        self.id = id
        self.name = name
        self.nameEn = nameEn
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.fatPer100g = fatPer100g
        self.carbsPer100g = carbsPer100g
        self.category = category
        self.visionIdentifiers = visionIdentifiers
        self.aliases = aliases
        self.referenceServingGrams = referenceServingGrams
        self.fdcID = fdcID
        self.referenceDescription = referenceDescription
    }

    /// 创建一个用户自定义名称和热量的食物条目
    public static func custom(name: String, calories: Double, category: FoodCategory = .staple) -> FoodItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "自定义食物" : trimmed
        let cleanID = "custom_\(UUID().uuidString.prefix(8))"
        return FoodItem(
            id: cleanID,
            name: displayName,
            nameEn: "Custom Food",
            caloriesPer100g: max(1, calories),
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            category: category,
            visionIdentifiers: [],
            aliases: [displayName]
        )
    }

    /// 克隆并替换名称或热量
    public func withCustom(name: String? = nil, caloriesPer100g: Double? = nil) -> FoodItem {
        let changed = name != nil || caloriesPer100g != nil
        return FoodItem(
            id: id,
            name: name ?? self.name,
            nameEn: nameEn,
            caloriesPer100g: caloriesPer100g ?? self.caloriesPer100g,
            proteinPer100g: proteinPer100g,
            fatPer100g: fatPer100g,
            carbsPer100g: carbsPer100g,
            category: category,
            visionIdentifiers: visionIdentifiers,
            aliases: aliases,
            referenceServingGrams: referenceServingGrams,
            fdcID: changed ? nil : fdcID,
            referenceDescription: changed ? nil : referenceDescription
        )
    }

    /// 使用已核对的 FoodData Central 记录，保持 App 中既有的菜名、别名和识别 ID。
    func withUSDAReference(_ reference: USDAFoodReference.Entry) -> FoodItem {
        FoodItem(
            id: id,
            name: name,
            nameEn: nameEn,
            caloriesPer100g: reference.per100g.kcal,
            proteinPer100g: proteinPer100g,
            fatPer100g: fatPer100g,
            carbsPer100g: carbsPer100g,
            category: category,
            visionIdentifiers: visionIdentifiers,
            aliases: aliases,
            referenceServingGrams: reference.servingGrams,
            fdcID: reference.fdcID.value,
            referenceDescription: reference.nameEn
        )
    }

    /// 标准份（一碗/一份/一个）的克数假设。用于从「每 100g」推算「一份多少千卡」。
    public var standardServingGrams: Double {
        if let referenceServingGrams { return referenceServingGrams }
        if id.hasPrefix("custom_") { return 100 }
        switch id {
        case "rice": return 200
        case "fried_rice": return 300
        case "noodles": return 300
        case "sushi": return 180
        case "dumpling": return 200
        case "congee": return 350
        case "bread": return 80
        case "breakfast_cereal": return 50
        case "pastry": return 80
        case "chinese_fastfood": return 300
        case "steamed_bun": return 90
        case "shengjian_xiaolong": return 150
        case "mantou": return 120
        case "youtiao": return 80
        case "pancake_roll": return 220
        case "roujiamo": return 180
        case "rice_noodles": return 350
        case "zhajiangmian": return 300
        case "changfen": return 200
        case "shaomai": return 150
        case "zongzi": return 150
        case "niangao": return 150
        case "corn_sweetpotato": return 200
        case "stir_fry_meat": return 200
        case "braised_meat": return 180
        case "steak": return 220
        case "fried_chicken": return 180
        case "chicken_breast": return 150
        case "beef": return 150
        case "pork": return 150
        case "fish": return 150
        case "boiled_pork_fish": return 350
        case "sweet_sour_pork": return 200
        case "suancai_fish": return 350
        case "roast_duck": return 200
        case "lamb": return 180
        case "shrimp": return 180
        case "curry_chicken_beef": return 250
        case "fried_pork_cutlet": return 180
        case "pig_trotter": return 220
        case "vegetable_dish": return 200
        case "seaweed_dish": return 150
        case "salad": return 200
        case "tofu": return 150
        case "egg": return 55
        case "fried_egg": return 55
        case "tomato_scrambled_egg": return 200
        case "mapo_tofu": return 200
        case "sour_potato_shreds": return 200
        case "stir_fry_cabbage": return 200
        case "garlic_greens": return 200
        case "cold_cucumber_fungus": return 150
        case "steamed_egg_custard": return 180
        case "mushroom_dish": return 200
        case "soup": return 300
        case "tomato_egg_soup": return 300
        case "pork_ribs_soup": return 350
        case "hotpot": return 400
        case "barbecue": return 300
        case "pizza": return 200
        case "hamburger": return 220
        case "sandwich": return 200
        case "hotdog": return 150
        case "fries": return 120
        case "braised_duck_neck": return 150
        case "oden": return 250
        case "stinky_tofu": return 150
        case "roasted_cold_noodles": return 200
        case "cake": return 100
        case "cookie": return 30
        case "ice_cream": return 100
        case "yogurt": return 150
        case "chips": return 40
        case "chocolate": return 30
        case "nuts": return 30
        case "coffee": return 250
        case "latte": return 350
        case "milk_tea": return 500
        case "lemon_tea": return 400
        case "sugar_free_tea": return 400
        case "soy_milk": return 300
        case "pure_milk": return 250
        case "cola": return 330
        case "sugar_free_cola": return 330
        case "juice": return 250
        case "coconut_water": return 300
        case "alcohol": return 330
        case "fruit": return 150
        case "apple": return 200
        case "banana": return 120
        case "watermelon": return 300
        case "orange_citrus": return 150
        case "durian_mango": return 150
        case "avocado": return 150
        default: return 200
        }
    }

    /// 标准份的热量（千卡）。
    public var standardServingCalories: Double {
        caloriesPer100g * standardServingGrams / 100.0
    }

    /// 单件（单个/单只/单块/单串/单颗/单贯/单片）的参考克数。
    /// 专为「整份由多个小件组成」的食物（水饺、生煎、小笼包、烧麦、烤串、寿司、臭豆腐、曲奇饼干、虾等）提供单件换算。
    public var pieceGrams: Double? {
        switch id {
        case "dumpling": return 20.0             // 单个水饺/馄饨约 20g (整份 200g 约 10 个)
        case "shengjian_xiaolong": return 35.0   // 单个生煎/小笼约 35g (整份 150g 约 4-5 个)
        case "shaomai": return 38.0              // 单个烧麦约 38g (整份 150g 约 4 个)
        case "sushi": return 30.0                // 单贯寿司约 30g (整份 180g 约 6 贯)
        case "barbecue": return 35.0             // 单串烤串约 35g (整盘 300g 约 8-10 串)
        case "stinky_tofu": return 30.0          // 单块臭豆腐约 30g (整份 150g 约 5 块)
        case "fried_chicken": return 70.0        // 单块/单翅炸鸡约 70g (整份 180g 约 2-3 块)
        case "cookie": return 10.0               // 单片曲奇约 10g (整包 30g 约 3 片)
        case "shrimp": return 20.0               // 单只大虾约 20g (整盘 180g 约 9 只)
        case "oden": return 40.0                 // 单串关东煮约 40g (整份 250g 约 6 串)
        default: return nil
        }
    }

    /// 是否属于主食（用于套餐/托盘多菜组合判别）。
    public var isStaple: Bool {
        if category == .staple { return true }
        switch id {
        case "rice", "fried_rice", "noodles", "sushi", "dumpling", "congee", "bread", "breakfast_cereal", "pastry",
             "chinese_fastfood", "steamed_bun", "shengjian_xiaolong", "mantou", "youtiao", "pancake_roll", "roujiamo",
             "rice_noodles", "zhajiangmian", "changfen", "shaomai", "zongzi", "niangao", "corn_sweetpotato":
            return true
        default:
            return false
        }
    }
}

/// 内置食物热量库。
///
/// 收录 Vision 通用分类里可命中的常见食物 + 高频中餐。
/// 数据不追求穷尽，目标是**覆盖常见场景**并保证命中项的数值合理。
public enum FoodCatalog {

    /// 仅关联含义明确的食物。复合菜、生熟状态不一致及错误中文映射须先人工核对。
    private static let usdaCrosswalk: [String: String] = [
        "rice": "f001", "fried_rice": "f114", "noodles": "f007",
        "fried_chicken": "f119", "pizza": "f121", "hamburger": "f118",
        "chips": "f124", "coffee": "f136", "pure_milk": "f052",
        "cola": "f131", "sugar_free_cola": "b001", "apple": "f085",
        "banana": "f086", "watermelon": "f089", "avocado": "f098"
    ]

    /// 资料中含义清楚、但旧食物库没有独立条目的食物。生食明确标注，避免套用熟菜的热量。
    private static let usdaAdditional: [(referenceID: String, category: FoodCategory, displayName: String, aliases: [String])] = [
        ("f002", .staple, "糙米饭", ["糙米饭", "brown rice"]),
        ("f048", .veggie, "水煮蛋", ["水煮蛋", "白煮蛋", "煮鸡蛋"]),
        ("f010", .staple, "鲜玉米（生）", ["生玉米"]),
        ("f011", .staple, "红薯（生）", ["生红薯"]),
        ("f058", .veggie, "西兰花（生）", ["生西兰花"]),
        ("f059", .veggie, "菠菜（生）", ["生菠菜"]),
        ("f064", .veggie, "黄瓜（生）", ["黄瓜", "生黄瓜"]),
        ("f065", .veggie, "番茄（生）", ["番茄", "西红柿", "生番茄"]),
        ("f066", .veggie, "胡萝卜（生）", ["生胡萝卜"]),
        ("f087", .drink, "橙子", ["橙子", "orange"]),
        ("f088", .drink, "葡萄", ["葡萄", "grapes"]),
        ("f090", .drink, "草莓", ["草莓", "strawberry"]),
        ("f091", .drink, "蓝莓", ["蓝莓", "blueberry"]),
        ("f092", .drink, "梨", ["梨", "雪梨"]),
        ("f093", .drink, "桃子", ["桃子", "水蜜桃"]),
        ("f095", .drink, "菠萝", ["菠萝", "凤梨"]),
        ("f096", .drink, "猕猴桃", ["猕猴桃", "奇异果"]),
        ("f100", .dessert, "核桃", ["核桃"]),
        ("f101", .dessert, "杏仁", ["杏仁"]),
        ("f102", .dessert, "花生", ["花生"])
    ]

    /// 食物库条目（收录高频中餐主食、早点、荤菜、素菜、汤品、特色小吃、水果饮品）。
    private static let baseItems: [FoodItem] = [
        // MARK: - 主食与早点 (Staple)
        FoodItem(id: "rice", name: "米饭", nameEn: "Steamed Rice", caloriesPer100g: 116,
                 proteinPer100g: 2.6, fatPer100g: 0.3, carbsPer100g: 25.9, category: .staple,
                 visionIdentifiers: ["rice"], aliases: ["米饭", "白饭", "白米饭", "大米饭", "rice", "steamed rice"]),
        FoodItem(id: "fried_rice", name: "炒饭", nameEn: "Fried Rice", caloriesPer100g: 180,
                 proteinPer100g: 4.8, fatPer100g: 6.5, carbsPer100g: 25.0, category: .staple,
                 visionIdentifiers: ["fried_rice", "pilaf"], aliases: ["炒饭", "蛋炒饭", "扬州炒饭", "酱油炒饭", "牛肉炒饭", "fried rice"]),
        FoodItem(id: "noodles", name: "面条", nameEn: "Noodles", caloriesPer100g: 110,
                 proteinPer100g: 4.0, fatPer100g: 0.5, carbsPer100g: 22.0, category: .staple,
                 visionIdentifiers: ["noodle", "ramen", "pasta", "spaghetti", "carbonara"], aliases: ["面条", "拉面", "汤面", "拌面", "牛肉面", "刀削面", "清汤面", "热汤面", "面", "noodles", "ramen", "pasta"]),
        FoodItem(id: "steamed_bun", name: "包子/肉包/菜包", nameEn: "Steamed Bun", caloriesPer100g: 230,
                 proteinPer100g: 7.0, fatPer100g: 6.5, carbsPer100g: 36.0, category: .staple,
                 visionIdentifiers: ["bun", "steamed_bun", "baozi", "dim_sum", "roll", "dumpling"], aliases: ["包子", "肉包", "菜包", "大包", "鲜肉包", "猪肉包", "猪肉包子", "小肉包", "大肉包", "肉大包", "baozi", "bun"]),
        FoodItem(id: "shengjian_xiaolong", name: "生煎包/小笼包/汤包", nameEn: "Pan-fried & Xiaolong Buns", caloriesPer100g: 230,
                 proteinPer100g: 8.5, fatPer100g: 10.0, carbsPer100g: 26.5, category: .staple,
                 visionIdentifiers: ["dim_sum", "dumpling"], aliases: ["生煎包", "生煎", "小笼包", "小笼", "灌汤包", "小笼汤包", "水煎包", "xiaolongbao"]),
        FoodItem(id: "mantou", name: "馒头/花卷", nameEn: "Steamed Bread", caloriesPer100g: 210,
                 proteinPer100g: 7.0, fatPer100g: 1.1, carbsPer100g: 44.0, category: .staple,
                 visionIdentifiers: ["bun", "steamed_bun", "bread_roll", "roll"], aliases: ["馒头", "花卷", "白馒头", "刀切馒头", "窝窝头", "杂粮馒头", "mantou"]),
        FoodItem(id: "youtiao", name: "油条/油饼", nameEn: "Fried Dough Stick", caloriesPer100g: 380,
                 proteinPer100g: 6.9, fatPer100g: 17.6, carbsPer100g: 50.0, category: .staple,
                 visionIdentifiers: ["fritter", "churro", "doughnut", "cruller"], aliases: ["油条", "油饼", "炸油条", "麻花", "youtiao"]),
        FoodItem(id: "pancake_roll", name: "煎饼果子/手抓饼", nameEn: "Pancake Roll", caloriesPer100g: 240,
                 proteinPer100g: 6.5, fatPer100g: 9.0, carbsPer100g: 33.0, category: .staple,
                 visionIdentifiers: ["crepe", "burrito", "wrap", "pancake", "tortilla"], aliases: ["煎饼果子", "手抓饼", "鸡蛋灌饼", "葱油饼", "煎饼", "卷饼", "肉卷", "jianbing"]),
        FoodItem(id: "roujiamo", name: "肉夹馍", nameEn: "Roujiamo", caloriesPer100g: 260,
                 proteinPer100g: 9.5, fatPer100g: 11.0, carbsPer100g: 30.0, category: .staple,
                 visionIdentifiers: ["sandwich", "burger", "slider"], aliases: ["肉夹馍", "陕西肉夹馍", "腊汁肉夹馍", "白吉馍", "roujiamo"]),
        FoodItem(id: "rice_noodles", name: "米粉/米线/螺蛳粉", nameEn: "Rice Noodles", caloriesPer100g: 120,
                 proteinPer100g: 2.5, fatPer100g: 0.8, carbsPer100g: 26.0, category: .staple,
                 visionIdentifiers: ["noodle", "vermicelli", "ramen"], aliases: ["米粉", "米线", "螺蛳粉", "酸辣粉", "桂林米粉", "过桥米线", "牛肉粉", "河粉", "炒河粉", "rice noodles"]),
        FoodItem(id: "zhajiangmian", name: "炸酱面/热干面", nameEn: "Noodles with Paste", caloriesPer100g: 200,
                 proteinPer100g: 6.0, fatPer100g: 7.5, carbsPer100g: 27.0, category: .staple,
                 visionIdentifiers: ["noodle", "spaghetti", "pasta", "ramen"], aliases: ["炸酱面", "热干面", "油泼面", "葱油拌面", "担担面", "武汉热干面", "zhajiangmian"]),
        FoodItem(id: "dumpling", name: "饺子/馄饨", nameEn: "Dumplings", caloriesPer100g: 240,
                 proteinPer100g: 8.0, fatPer100g: 8.5, carbsPer100g: 32.0, category: .staple,
                 visionIdentifiers: ["dumpling", "wonton", "pierogi", "potsticker", "dim_sum"], aliases: ["饺子", "水饺", "煎饺", "馄饨", "抄手", "云吞", "dumpling", "wonton"]),
        FoodItem(id: "congee", name: "粥/稀饭", nameEn: "Congee", caloriesPer100g: 50,
                 proteinPer100g: 1.1, fatPer100g: 0.2, carbsPer100g: 10.8, category: .staple,
                 visionIdentifiers: ["oatmeal", "porridge", "gruel", "broth"], aliases: ["粥", "白粥", "稀饭", "皮蛋瘦肉粥", "小米粥", "八宝粥", "南瓜粥", "congee", "porridge"]),
        FoodItem(id: "sushi", name: "寿司", nameEn: "Sushi", caloriesPer100g: 150, category: .staple,
                 visionIdentifiers: ["sushi"], aliases: ["寿司", "手握寿司", "军舰寿司", "加州卷", "sushi"]),
        FoodItem(id: "bread", name: "面包/吐司", nameEn: "Bread", caloriesPer100g: 280, category: .staple,
                 visionIdentifiers: ["bread", "toast", "white_bread", "baguette"], aliases: ["面包", "吐司", "全麦面包", "法棍", "欧包", "bread", "toast"]),
        FoodItem(id: "breakfast_cereal", name: "麦片/燕麦", nameEn: "Cereal", caloriesPer100g: 380, category: .staple,
                 visionIdentifiers: ["oatmeal", "cereal"], aliases: ["麦片", "燕麦", "燕麦片", "cereal", "oatmeal"]),
        FoodItem(id: "changfen", name: "肠粉", nameEn: "Rice Noodle Roll", caloriesPer100g: 110, category: .staple,
                 visionIdentifiers: ["dim_sum", "noodle"], aliases: ["肠粉", "广东肠粉", "鸡蛋肠粉", "肉沫肠粉", "虾仁肠粉", "changfen"]),
        FoodItem(id: "shaomai", name: "烧麦", nameEn: "Shaomai", caloriesPer100g: 220, category: .staple,
                 visionIdentifiers: ["dim_sum", "dumpling", "shaomai"], aliases: ["烧麦", "烧卖", "糯米烧麦", "广式烧卖", "shaomai", "shumai"]),
        FoodItem(id: "zongzi", name: "粽子", nameEn: "Zongzi", caloriesPer100g: 200, category: .staple,
                 visionIdentifiers: ["tamale", "dumpling"], aliases: ["粽子", "肉粽", "甜粽", "蛋黄肉粽", "豆沙粽", "zongzi"]),
        FoodItem(id: "niangao", name: "年糕/汤圆", nameEn: "Rice Cake & Tangyuan", caloriesPer100g: 180, category: .staple,
                 visionIdentifiers: ["rice_cake", "mochi", "dumpling"], aliases: ["年糕", "炒年糕", "汤圆", "元宵", "糍粑", "rice cake", "tangyuan"]),
        FoodItem(id: "corn_sweetpotato", name: "玉米/红薯/紫薯", nameEn: "Corn & Sweet Potato", caloriesPer100g: 105, category: .staple,
                 visionIdentifiers: ["corn", "sweet_potato", "yam"], aliases: ["玉米", "煮玉米", "红薯", "烤红薯", "紫薯", "南瓜", "蒸南瓜", "corn", "sweet potato"]),
        FoodItem(id: "chinese_fastfood", name: "中式快餐/便当", nameEn: "Chinese Fast Food", caloriesPer100g: 170, category: .staple,
                 visionIdentifiers: ["fast_food", "platter", "tray"], aliases: ["盖浇饭", "炒面", "炒粉", "盒饭", "套餐", "中式快餐", "快餐", "便当"]),

        // MARK: - 荤菜与家常热菜 (Meat)
        FoodItem(id: "stir_fry_meat", name: "辣椒炒肉/家常小炒", nameEn: "Stir-fried Meat & Peppers", caloriesPer100g: 165, category: .meat,
                 visionIdentifiers: ["stir_fry", "curry", "wok"],
                 aliases: ["辣椒炒肉", "小炒肉", "农家小炒肉", "青椒炒肉", "家常小炒", "家常炒菜", "肉片炒菜", "红烧肉块", "啤酒鸭", "黄焖鸡", "红烧鸡块", "宫保鸡丁", "鱼香肉丝", "回锅肉", "荤素小炒", "炒菜", "炒肉", "stir fry", "stir_fry"]),
        FoodItem(id: "braised_meat", name: "红烧肉/红烧排骨", nameEn: "Braised Pork & Ribs", caloriesPer100g: 245, category: .meat,
                 visionIdentifiers: ["meat", "pork", "beef", "pot_roast", "stew"],
                 aliases: ["红烧肉", "红烧排骨", "卤肉", "梅菜扣肉", "红烧牛肉", "红烧鸭", "braised pork"]),
        FoodItem(id: "sweet_sour_pork", name: "糖醋里脊/锅包肉", nameEn: "Sweet & Sour Pork", caloriesPer100g: 260, category: .meat,
                 visionIdentifiers: ["sweet_and_sour", "meat", "pork", "tempura"], aliases: ["糖醋里脊", "锅包肉", "咕咾肉", "糖醋排骨", "菠萝咕咾肉", "sweet sour pork"]),
        FoodItem(id: "boiled_pork_fish", name: "水煮肉片/水煮鱼/毛血旺", nameEn: "Boiled Meat & Fish in Chili", caloriesPer100g: 210, category: .meat,
                 visionIdentifiers: ["chili"], aliases: ["水煮肉片", "水煮鱼", "毛血旺", "水煮牛肉", "川味水煮", "boiled meat"]),
        FoodItem(id: "suancai_fish", name: "酸菜鱼/烤鱼", nameEn: "Fish with Sauerkraut", caloriesPer100g: 120, category: .meat,
                 visionIdentifiers: ["fish"], aliases: ["酸菜鱼", "烤鱼", "剁椒鱼头", "沸腾鱼", "清蒸鲈鱼", "suancai fish"]),
        FoodItem(id: "roast_duck", name: "烤鸭/卤鸭", nameEn: "Roast & Braised Duck", caloriesPer100g: 240, category: .meat,
                 visionIdentifiers: ["duck", "poultry", "roast"], aliases: ["烤鸭", "北京烤鸭", "卤鸭", "南京盐水鸭", "烧鸭", "roast duck"]),
        FoodItem(id: "steak", name: "牛排", nameEn: "Steak", caloriesPer100g: 250,
                 proteinPer100g: 25.0, fatPer100g: 17.0, carbsPer100g: 0.0, category: .meat,
                 visionIdentifiers: ["steak", "meat", "beef"], aliases: ["牛排", "煎牛排", "steak"]),
        FoodItem(id: "fried_chicken", name: "炸鸡/鸡排", nameEn: "Fried Chicken", caloriesPer100g: 280,
                 proteinPer100g: 18.0, fatPer100g: 18.0, carbsPer100g: 10.0, category: .meat,
                 visionIdentifiers: ["fried_chicken", "chicken", "tempura"], aliases: ["炸鸡", "鸡排", "辣子鸡", "鸡米花", "原味鸡", "炸鸡翅", "fried chicken"]),
        FoodItem(id: "chicken_breast", name: "鸡胸肉/白切鸡", nameEn: "Chicken", caloriesPer100g: 165,
                 proteinPer100g: 31.0, fatPer100g: 3.6, carbsPer100g: 0.0, category: .meat,
                 visionIdentifiers: ["grilled_chicken", "chicken", "poultry"], aliases: ["鸡胸肉", "鸡肉", "白切鸡", "口水鸡", "鸡腿", "白斩鸡", "chicken breast", "chicken"]),
        FoodItem(id: "beef", name: "牛肉/酱牛肉", nameEn: "Beef", caloriesPer100g: 190,
                 proteinPer100g: 26.0, fatPer100g: 9.0, carbsPer100g: 0.0, category: .meat,
                 visionIdentifiers: ["meat", "beef", "meatball"], aliases: ["牛肉", "卤牛肉", "酱牛肉", "小炒牛肉", "黑椒牛肉粒", "beef"]),
        FoodItem(id: "pork", name: "猪肉/叉烧", nameEn: "Pork", caloriesPer100g: 210,
                 proteinPer100g: 20.0, fatPer100g: 14.0, carbsPer100g: 0.0, category: .meat,
                 visionIdentifiers: ["meat", "pork", "ham", "bacon", "sausage"], aliases: ["猪肉", "叉烧", "香肠", "培根", "烤肠", "pork"]),
        FoodItem(id: "lamb", name: "羊肉/羊肉串", nameEn: "Lamb & Mutton", caloriesPer100g: 200,
                 proteinPer100g: 19.0, fatPer100g: 13.0, carbsPer100g: 0.0, category: .meat,
                 visionIdentifiers: ["lamb", "mutton", "kebab"], aliases: ["羊肉", "烤羊肉串", "羊肉汤", "手抓羊肉", "葱爆羊肉", "lamb", "mutton"]),
        FoodItem(id: "shrimp", name: "虾/白灼虾/小龙虾", nameEn: "Shrimp & Prawns", caloriesPer100g: 100,
                 proteinPer100g: 21.0, fatPer100g: 1.0, carbsPer100g: 0.5, category: .meat,
                 visionIdentifiers: ["shellfish", "shellfish_prepared", "crab", "lobster", "shrimp", "prawn"], aliases: ["虾", "大虾", "白灼虾", "油焖大虾", "小龙虾", "麻辣小龙虾", "虾仁", "shrimp", "prawn"]),
        FoodItem(id: "fish", name: "鱼肉/海鲜", nameEn: "Fish & Seafood", caloriesPer100g: 130,
                 proteinPer100g: 20.0, fatPer100g: 5.0, carbsPer100g: 0.0, category: .meat,
                 visionIdentifiers: ["fish", "seafood", "oyster", "clam", "salmon"], aliases: ["鱼", "海鲜", "清蒸鱼", "红烧鱼", "三文鱼", "鳕鱼", "fish", "seafood"]),
        FoodItem(id: "curry_chicken_beef", name: "咖喱鸡/咖喱牛肉", nameEn: "Curry", caloriesPer100g: 160, category: .meat,
                 visionIdentifiers: ["curry"], aliases: ["咖喱鸡", "咖喱牛肉", "咖喱饭", "日式咖喱", "curry"]),
        FoodItem(id: "fried_pork_cutlet", name: "炸猪排", nameEn: "Fried Pork Cutlet", caloriesPer100g: 300, category: .meat,
                 visionIdentifiers: ["cutlet", "schnitzel", "tonkatsu", "tempura"], aliases: ["炸猪排", "猪排", "日式猪排", "天妇罗", "tonkatsu"]),
        FoodItem(id: "pig_trotter", name: "卤猪蹄/猪手", nameEn: "Braised Pig Trotter", caloriesPer100g: 260, category: .meat,
                 visionIdentifiers: ["pork"], aliases: ["猪蹄", "卤猪蹄", "猪手", "红烧猪蹄", "猪脚姜", "pig trotter"]),

        // MARK: - 素菜、豆制品与菌菇 (Veggie)
        FoodItem(id: "vegetable_dish", name: "素菜/炒青菜", nameEn: "Vegetable Dish", caloriesPer100g: 75, category: .veggie,
                 visionIdentifiers: ["vegetable", "broccoli", "tomato", "potato", "eggplant", "pepper_veggie", "bell_pepper", "jalapeno", "green_beans", "bean", "asparagus", "cabbage", "carrot", "cucumber", "lettuce", "onion", "pea", "pumpkin", "spinach"],
                 aliases: ["青菜", "炒青菜", "蔬菜", "素菜", "炒时蔬", "四季豆", "豆角", "干煸豆角", "红烧茄子", "vegetable"]),
        FoodItem(id: "stir_fry_cabbage", name: "手撕包菜/干锅花菜", nameEn: "Stir-fried Cabbage & Cauliflower", caloriesPer100g: 80, category: .veggie,
                 visionIdentifiers: ["cabbage", "cauliflower"], aliases: ["手撕包菜", "干锅花菜", "炒花菜", "大头菜", "圆白菜", "包菜", "fried cabbage"]),
        FoodItem(id: "sour_potato_shreds", name: "酸辣土豆丝/地三鲜", nameEn: "Shredded Potato & Eggplant", caloriesPer100g: 120, category: .veggie,
                 visionIdentifiers: ["potato"], aliases: ["酸辣土豆丝", "土豆丝", "地三鲜", "红烧土豆", "土豆片", "shredded potato"]),
        FoodItem(id: "garlic_greens", name: "蒜蓉空心菜/绿叶青菜", nameEn: "Garlic Greens", caloriesPer100g: 60, category: .veggie,
                 visionIdentifiers: ["spinach", "greens"], aliases: ["蒜蓉空心菜", "空心菜", "生菜", "白灼生菜", "菜心", "广东菜心", "油麦菜", "菠菜", "油菜", "garlic greens"]),
        FoodItem(id: "mapo_tofu", name: "麻婆豆腐/家常豆腐", nameEn: "Mapo Tofu", caloriesPer100g: 130, category: .veggie,
                 visionIdentifiers: ["tofu"], aliases: ["麻婆豆腐", "家常豆腐", "肉沫豆腐", "麻辣豆腐", "mapo tofu"]),
        FoodItem(id: "tofu", name: "豆制品/豆干", nameEn: "Tofu", caloriesPer100g: 80,
                 proteinPer100g: 8.0, fatPer100g: 4.0, carbsPer100g: 2.0, category: .veggie,
                 visionIdentifiers: ["tofu", "bean_curd"], aliases: ["豆腐", "豆干", "腐竹", "豆皮", "千张", "tofu"]),
        FoodItem(id: "egg", name: "鸡蛋/茶叶蛋/水煮蛋", nameEn: "Boiled & Tea Egg", caloriesPer100g: 145,
                 proteinPer100g: 13.0, fatPer100g: 10.0, carbsPer100g: 1.0, category: .veggie,
                 visionIdentifiers: ["egg", "poached_egg"], aliases: ["鸡蛋", "茶叶蛋", "水煮蛋", "卤蛋", "煮鸡蛋", "白煮蛋", "煮蛋", "蛋", "egg", "tea egg", "boiled egg"]),
        FoodItem(id: "fried_egg", name: "荷包蛋/煎蛋", nameEn: "Fried Egg", caloriesPer100g: 185,
                 proteinPer100g: 12.0, fatPer100g: 15.0, carbsPer100g: 1.5, category: .veggie,
                 visionIdentifiers: ["fried_egg", "omelet"], aliases: ["荷包蛋", "煎蛋", "煎鸡蛋", "太阳蛋", "fried egg"]),
        FoodItem(id: "tomato_scrambled_egg", name: "西红柿炒鸡蛋/番茄炒蛋", nameEn: "Tomato Scrambled Eggs", caloriesPer100g: 110,
                 proteinPer100g: 5.5, fatPer100g: 7.0, carbsPer100g: 6.5, category: .veggie,
                 visionIdentifiers: ["scrambled_eggs"], aliases: ["西红柿炒鸡蛋", "番茄炒蛋", "番茄炒鸡蛋", "西红柿炒蛋", "炒鸡蛋", "炒蛋"]),
        FoodItem(id: "steamed_egg_custard", name: "水蒸蛋/鸡蛋羹", nameEn: "Steamed Egg Custard", caloriesPer100g: 70, category: .veggie,
                 visionIdentifiers: ["custard", "pudding"], aliases: ["水蒸蛋", "鸡蛋羹", "蒸蛋", "炖蛋", "蒸水蛋", "steamed egg"]),
        FoodItem(id: "mushroom_dish", name: "炒菌菇/香菇油菜", nameEn: "Mushroom Dish", caloriesPer100g: 70, category: .veggie,
                 visionIdentifiers: ["mushroom", "fungus"], aliases: ["炒菌菇", "菌菇", "香菇油菜", "杏鲍菇", "金针菇", "蘑菇", "mushroom dish"]),
        FoodItem(id: "cold_cucumber_fungus", name: "拍黄瓜/凉拌木耳", nameEn: "Cold Cucumber & Fungus", caloriesPer100g: 50, category: .veggie,
                 visionIdentifiers: ["cucumber"], aliases: ["拍黄瓜", "黄瓜", "凉拌木耳", "木耳", "凉拌腐竹", "皮蛋豆腐", "cold cucumber"]),
        FoodItem(id: "seaweed_dish", name: "凉拌海带丝/凉菜", nameEn: "Seaweed & Cold Dish", caloriesPer100g: 55, category: .veggie,
                 visionIdentifiers: ["seaweed", "pickle"],
                 aliases: ["凉拌海带丝", "海带丝", "海带", "凉拌菜", "凉菜", "小菜", "泡菜", "seaweed"]),
        FoodItem(id: "salad", name: "蔬菜沙拉/轻食", nameEn: "Salad", caloriesPer100g: 90, category: .veggie,
                 visionIdentifiers: ["salad", "guacamole", "hummus"], aliases: ["沙拉", "蔬菜沙拉", "轻食沙拉", "轻食", "salad"]),

        // MARK: - 汤品与羹类 (Soup)
        FoodItem(id: "soup", name: "汤品/例汤", nameEn: "Soup", caloriesPer100g: 35, category: .soup,
                 visionIdentifiers: ["soup", "broth", "consomme"], aliases: ["汤", "例汤", "高汤", "清汤", "罗宋汤", "soup"]),
        FoodItem(id: "tomato_egg_soup", name: "番茄蛋花汤/紫菜蛋汤", nameEn: "Tomato Egg Soup", caloriesPer100g: 35, category: .soup,
                 visionIdentifiers: [], aliases: ["番茄蛋花汤", "西红柿鸡蛋汤", "紫菜蛋花汤", "蛋花汤", "紫菜汤", "tomato egg soup"]),
        FoodItem(id: "pork_ribs_soup", name: "排骨汤/老鸭汤/鸡汤", nameEn: "Pork Rib & Chicken Soup", caloriesPer100g: 65, category: .soup,
                 visionIdentifiers: [], aliases: ["排骨汤", "山药排骨汤", "玉米排骨汤", "老鸭汤", "母鸡汤", "鸡汤", "骨头汤", "ribs soup"]),

        // MARK: - 特色小吃、快餐与烧烤 (Snack)
        FoodItem(id: "hotpot", name: "火锅/麻辣烫", nameEn: "Hot Pot", caloriesPer100g: 150, category: .snack,
                 visionIdentifiers: ["hotpot", "hot_pot", "stew", "fondue"], aliases: ["火锅", "麻辣烫", "冒菜", "麻辣香锅", "hotpot"]),
        FoodItem(id: "barbecue", name: "烧烤/烤串", nameEn: "Barbecue", caloriesPer100g: 260, category: .snack,
                 visionIdentifiers: ["grill", "barbecue", "kebab", "skewer"], aliases: ["烧烤", "烤串", "烤肉", "串串", "羊肉串", "牛肉串", "烤羊肉串", "烤肉串", "barbecue", "bbq"]),
        FoodItem(id: "braised_duck_neck", name: "卤鸭脖/鸡爪", nameEn: "Braised Duck Neck & Claw", caloriesPer100g: 220, category: .snack,
                 visionIdentifiers: ["duck", "poultry", "meat"], aliases: ["鸭脖", "卤鸭脖", "周黑鸭", "绝味", "鸡爪", "卤鸡爪", "鸭锁骨", "鸭翅", "duck neck"]),
        FoodItem(id: "oden", name: "关东煮/串串", nameEn: "Oden", caloriesPer100g: 80, category: .snack,
                 visionIdentifiers: ["oden"], aliases: ["关东煮", "便利店关东煮", "罗森关东煮", "oden"]),
        FoodItem(id: "stinky_tofu", name: "臭豆腐", nameEn: "Stinky Tofu", caloriesPer100g: 210, category: .snack,
                 visionIdentifiers: ["tofu"], aliases: ["臭豆腐", "长沙臭豆腐", "炸臭豆腐", "stinky tofu"]),
        FoodItem(id: "roasted_cold_noodles", name: "烤冷面/章鱼小丸子", nameEn: "Roasted Cold Noodles & Takoyaki", caloriesPer100g: 230, category: .snack,
                 visionIdentifiers: ["crepe", "noodle"], aliases: ["烤冷面", "章鱼小丸子", "章鱼烧", "炸串", "takoyaki"]),
        FoodItem(id: "pizza", name: "披萨", nameEn: "Pizza", caloriesPer100g: 265, category: .snack,
                 visionIdentifiers: ["pizza"], aliases: ["披萨", "比萨", "pizza"]),
        FoodItem(id: "hamburger", name: "汉堡", nameEn: "Hamburger", caloriesPer100g: 250, category: .snack,
                 visionIdentifiers: ["hamburger", "burger"], aliases: ["汉堡", "牛肉堡", "鸡腿堡", "hamburger", "burger"]),
        FoodItem(id: "sandwich", name: "三明治", nameEn: "Sandwich", caloriesPer100g: 230, category: .snack,
                 visionIdentifiers: ["sandwich", "burger"], aliases: ["三明治", "潜艇堡", "sandwich"]),
        FoodItem(id: "hotdog", name: "热狗", nameEn: "Hot Dog", caloriesPer100g: 240, category: .snack,
                 visionIdentifiers: ["hotdog"], aliases: ["热狗", "hotdog"]),
        FoodItem(id: "fries", name: "薯条", nameEn: "French Fries", caloriesPer100g: 310, category: .snack,
                 visionIdentifiers: ["fries"], aliases: ["薯条", "炸薯条", "fries"]),

        // MARK: - 甜点零食 (Dessert)
        FoodItem(id: "pastry", name: "糕点/酥点", nameEn: "Pastry", caloriesPer100g: 400, category: .dessert,
                 visionIdentifiers: ["pastry", "croissant", "donut", "doughnut", "pancake", "waffle", "pie"], aliases: ["糕点", "酥点", "面包圈", "甜甜圈", "松饼", "华夫饼", "pastry"]),
        FoodItem(id: "cake", name: "蛋糕", nameEn: "Cake", caloriesPer100g: 350, category: .dessert,
                 visionIdentifiers: ["cake", "cake_regular", "cheesecake", "cupcake", "birthday_cake", "fruitcake"], aliases: ["蛋糕", "甜点", "提拉米苏", "芝士蛋糕", "cake"]),
        FoodItem(id: "cookie", name: "饼干/曲奇", nameEn: "Cookie", caloriesPer100g: 480, category: .dessert,
                 visionIdentifiers: ["cookie", "chocolate_chip"], aliases: ["饼干", "曲奇", "威化", "曲奇饼干", "cookie"]),
        FoodItem(id: "ice_cream", name: "冰淇淋/雪糕", nameEn: "Ice Cream", caloriesPer100g: 200, category: .dessert,
                 visionIdentifiers: ["ice_cream", "frozen_dessert", "dessert"], aliases: ["冰淇淋", "雪糕", "甜筒", "冰棒", "ice cream"]),
        FoodItem(id: "yogurt", name: "酸奶", nameEn: "Yogurt", caloriesPer100g: 90, category: .dessert,
                 visionIdentifiers: ["yogurt"], aliases: ["酸奶", "希腊酸奶", "酸牛奶", "yogurt"]),
        FoodItem(id: "chips", name: "薯片/膨化食品", nameEn: "Potato Chips", caloriesPer100g: 540, category: .dessert,
                 visionIdentifiers: ["potato_chips"], aliases: ["薯片", "虾条", "chips"]),
        FoodItem(id: "chocolate", name: "巧克力", nameEn: "Chocolate", caloriesPer100g: 540, category: .dessert,
                 visionIdentifiers: ["chocolate"], aliases: ["巧克力", "黑巧", "chocolate"]),
        FoodItem(id: "nuts", name: "坚果/花生", nameEn: "Nuts", caloriesPer100g: 600, category: .dessert,
                 visionIdentifiers: ["seed", "nuts", "nut", "almond", "peanut", "cashew", "chestnut", "sunflower_seeds"], aliases: ["坚果", "花生", "瓜子", "杏仁", "腰果", "核桃", "开心果", "nuts"]),

        // MARK: - 饮品与水果 (Drink & Fruit)
        FoodItem(id: "coffee", name: "黑咖啡/美式", nameEn: "Black Coffee", caloriesPer100g: 2, category: .drink,
                 visionIdentifiers: ["coffee", "coffee_bean"], aliases: ["咖啡", "美式", "黑咖啡", "浓缩咖啡", "冷萃", "冰美式", "热美式", "coffee", "americano"]),
        FoodItem(id: "latte", name: "拿铁/卡布奇诺", nameEn: "Latte", caloriesPer100g: 40, category: .drink,
                 visionIdentifiers: ["latte", "cappuccino"], aliases: ["拿铁", "卡布奇诺", "摩卡", "焦糖玛奇朵", "生椰拿铁", "冰拿铁", "热拿铁", "星巴克", "瑞幸", "库迪", "latte", "cappuccino", "mocha"]),
        FoodItem(id: "milk_tea", name: "奶茶/果茶", nameEn: "Milk Tea", caloriesPer100g: 70, category: .drink,
                 visionIdentifiers: ["bubble_tea", "juice", "drink"], aliases: ["奶茶", "珍珠奶茶", "喜茶", "奈雪", "蜜雪冰城", "霸王茶姬", "茶颜悦色", "古茗", "一点点", "半糖奶茶", "无糖奶茶", "milk tea", "bubble tea"]),
        FoodItem(id: "lemon_tea", name: "手打柠檬茶", nameEn: "Lemon Tea", caloriesPer100g: 35, category: .drink,
                 visionIdentifiers: ["juice", "drink"], aliases: ["柠檬茶", "手打柠檬茶", "暴打柠檬茶", "鸭屎香柠檬茶", "lemon tea"]),
        FoodItem(id: "sugar_free_tea", name: "无糖纯茶/乌龙茶", nameEn: "Sugar-free Tea", caloriesPer100g: 1, category: .drink,
                 visionIdentifiers: ["drink"], aliases: ["无糖纯茶", "乌龙茶", "东方树叶", "三得利乌龙茶", "绿茶", "普洱茶", "红茶", "sugar free tea"]),
        FoodItem(id: "soy_milk", name: "豆浆", nameEn: "Soy Milk", caloriesPer100g: 35, category: .drink,
                 visionIdentifiers: ["drink"], aliases: ["豆浆", "现磨豆浆", "原味豆浆", "甜豆浆", "热豆浆", "冰豆浆", "soy milk"]),
        FoodItem(id: "pure_milk", name: "纯牛奶/鲜牛奶", nameEn: "Whole Milk", caloriesPer100g: 65, category: .drink,
                 visionIdentifiers: ["milk"], aliases: ["牛奶", "鲜牛奶", "纯牛奶", "热牛奶", "温牛奶", "全脂牛奶", "脱脂牛奶", "一袋牛奶", "一杯牛奶", "盒装牛奶", "milk", "whole milk"]),
        FoodItem(id: "cola", name: "可乐/含糖汽水", nameEn: "Cola", caloriesPer100g: 42, category: .drink,
                 visionIdentifiers: ["cola", "soda"], aliases: ["可乐", "汽水", "雪碧", "芬达", "cola"]),
        FoodItem(id: "sugar_free_cola", name: "无糖可乐/气泡水", nameEn: "Zero Calorie Soda", caloriesPer100g: 1, category: .drink,
                 visionIdentifiers: ["soda"], aliases: ["无糖可乐", "零度可乐", "元气森林", "气泡水", "无糖汽水", "diet cola", "zero cola"]),
        FoodItem(id: "juice", name: "鲜榨果汁", nameEn: "Juice", caloriesPer100g: 45, category: .drink,
                 visionIdentifiers: ["juice", "juicer"], aliases: ["果汁", "橙汁", "苹果汁", "juice"]),
        FoodItem(id: "coconut_water", name: "椰子水/椰青", nameEn: "Coconut Water", caloriesPer100g: 20, category: .drink,
                 visionIdentifiers: ["drink"], aliases: ["椰子水", "椰青", "生椰水", "coconut water"]),
        FoodItem(id: "alcohol", name: "酒类/啤酒", nameEn: "Alcoholic Drink", caloriesPer100g: 70, category: .drink,
                 visionIdentifiers: ["beer", "red_wine", "sparkling_wine", "wine"], aliases: ["啤酒", "红酒", "白酒", "鸡尾酒", "beer", "wine"]),
        FoodItem(id: "fruit", name: "水果拼盘", nameEn: "Fruit Platter", caloriesPer100g: 55, category: .drink,
                 visionIdentifiers: ["fruit", "apple", "banana", "orange", "grapefruit", "pineapple", "citrus_fruit", "passionfruit", "starfruit", "strawberry", "blueberry", "raspberry", "blackberry", "cherry", "grape", "melon", "peach", "pear", "plum", "kiwi", "avocado", "lemon", "lime", "mango"], aliases: ["水果", "水果拼盘", "草莓", "蓝莓", "葡萄", "桃子", "梨", "fruit"]),
        FoodItem(id: "apple", name: "苹果", nameEn: "Apple", caloriesPer100g: 52, category: .drink,
                 visionIdentifiers: ["apple"], aliases: ["苹果", "红富士", "青苹果", "apple"]),
        FoodItem(id: "banana", name: "香蕉", nameEn: "Banana", caloriesPer100g: 89, category: .drink,
                 visionIdentifiers: ["banana"], aliases: ["香蕉", "banana"]),
        FoodItem(id: "watermelon", name: "西瓜", nameEn: "Watermelon", caloriesPer100g: 30, category: .drink,
                 visionIdentifiers: ["watermelon", "melon"], aliases: ["西瓜", "切块西瓜", "watermelon"]),
        FoodItem(id: "orange_citrus", name: "橙子/柑橘/柚子", nameEn: "Orange & Citrus", caloriesPer100g: 45, category: .drink,
                 visionIdentifiers: ["orange", "citrus", "tangerine"], aliases: ["橙子", "橘子", "柑橘", "柚子", "砂糖橘", "orange", "citrus"]),
        FoodItem(id: "durian_mango", name: "榴莲/芒果", nameEn: "Durian & Mango", caloriesPer100g: 130, category: .drink,
                 visionIdentifiers: ["mango", "durian"], aliases: ["榴莲", "芒果", "金枕榴莲", "台农芒果", "durian", "mango"]),
        FoodItem(id: "avocado", name: "牛油果", nameEn: "Avocado", caloriesPer100g: 160, category: .drink,
                 visionIdentifiers: ["avocado", "guacamole"], aliases: ["牛油果", "鳄梨", "avocado"])
    ]

    public static let items: [FoodItem] = baseItems.map { food in
        guard let referenceID = usdaCrosswalk[food.id],
              let reference = USDAFoodReference.entriesByID[referenceID],
              reference.servingGrams > 0,
              reference.per100g.kcal.isFinite,
              reference.per100g.kcal >= 0 else { return food }
        return food.withUSDAReference(reference)
    } + usdaAdditional.compactMap { item in
        guard let reference = USDAFoodReference.entriesByID[item.referenceID],
              reference.servingGrams > 0,
              reference.per100g.kcal.isFinite,
              reference.per100g.kcal >= 0 else { return nil }
        return FoodItem(
            id: "usda_\(item.referenceID)",
            name: item.displayName,
            nameEn: reference.nameEn,
            caloriesPer100g: reference.per100g.kcal,
            category: item.category,
            aliases: item.aliases,
            referenceServingGrams: reference.servingGrams,
            fdcID: reference.fdcID.value,
            referenceDescription: reference.nameEn
        )
    } + ChineseFoodReference.entries.map { entry in
        FoodItem(
            id: "cn_\(entry.id)",
            name: entry.name,
            nameEn: entry.nameEn,
            caloriesPer100g: entry.kcalPer100g,
            category: category(for: entry.category),
            aliases: entry.aliases,
            referenceServingGrams: entry.servingGrams,
            referenceDescription: entry.source
        )
    }

    private static func category(for sourceCategory: String) -> FoodCategory {
        switch sourceCategory {
        case "staple": return .staple
        case "snack": return .snack
        case "veggie": return .veggie
        case "soup": return .soup
        default: return .meat
        }
    }

    /// 按 id 查找。
    public static func item(id: String) -> FoodItem? {
        items.first { $0.id == id }
    }

    /// 按 Vision 类目标识符查找食物。
    public static func items(matchingVisionIdentifier identifier: String) -> [FoodItem] {
        let key = identifier.lowercased()
        return items.filter { item in
            item.visionIdentifiers.contains { $0.lowercased() == key }
        }
    }

    /// 按中文名或别名查找（用于 LLM 给出的菜名回查）。
    ///
    /// 这是**宽松**匹配：别名只要被包含即命中，适合搜索场景。
    /// **不适合校验模型输出的菜名**——模型编造的「外星烧烤」会因包含
    /// 别名「烧烤」而被误判为合法。校验场景请用 `item(matchingNameStrict:)`。
    public static func items(matchingName name: String) -> [FoodItem] {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        return items.filter { item in
            if item.name.lowercased() == key || item.nameEn.lowercased() == key { return true }
            if item.aliases.contains(where: { $0.lowercased() == key }) { return true }
            return item.aliases.contains { alias in
                alias.count >= 2 && key.contains(alias.lowercased())
            }
        }
    }

    /// 严格匹配一个菜名到食物库。
    ///
    /// 判定规则（按顺序）：
    /// 1. 与食物名/英文名/别名**完全相等** → 命中。
    /// 2. 剥离「量词与修饰」后相等（如「一份披萨」→「披萨」）→ 命中。
    /// 3. 其余一律不命中。
    ///
    /// 规则 3 是关键：模型编造的「外星烧烤」减去别名「烧烤」剩下「外星」，
    /// 不是量词，因此不命中——宁可解析失败退回候选列表，
    /// 也不能给用户一个不存在的食物配一个看似合理的热量。
    public static func item(matchingNameStrict name: String) -> FoodItem? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let lowerKey = key.lowercased()

        // 规则 1：完整名称优先于宽泛旧条目的别名（例如「橙子」优先于「橙子/柑橘/柚子」）。
        if let exact = items.first(where: { $0.name.lowercased() == lowerKey || $0.nameEn.lowercased() == lowerKey }) {
            return exact
        }
        if let alias = items.first(where: { $0.aliases.contains(where: { $0.lowercased() == lowerKey }) }) {
            return alias
        }

        // 规则 2：剥离量词/修饰后相等
        let stripped = stripPortionModifiers(key)
        guard stripped != key, !stripped.isEmpty else { return nil }
        let lowerStripped = stripped.lowercased()
        return items.first(where: { $0.name.lowercased() == lowerStripped || $0.nameEn.lowercased() == lowerStripped })
            ?? items.first(where: { $0.aliases.contains(where: { $0.lowercased() == lowerStripped }) })
    }

    /// 剥离中文菜名前后的量词与修饰词（如「一份」「小份」「这个」「一个」「200g」「二两」「半糖」「冰美式」）。
    public static func stripPortionModifiers(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // 移除括号内注释文字，如 "(1个，约80g)" 或 "（大包）"
        text = text.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 剥离前缀指示代词与修饰（这、那、的）
        text = text.replacingOccurrences(of: "^[这那的]+", with: "", options: .regularExpression)

        // 剥离重量/体积单位前缀（如「200g」「200克」「500ml」「二两」「半斤」）
        let weightPattern = "^([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*(?:g|克|千克|kg|ml|毫升|升|L|两|斤)\\s*"
        text = text.replacingOccurrences(of: weightPattern, with: "", options: .regularExpression)

        // 剥离前缀数量与量词（如「一个」「2个」「两只」「半碗」「1碗」「一杯」）
        let prefixQtyPattern = "^([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*(个|只|块|片|条|根|碗|盘|杯|碟|袋|盒|瓶|串|颗|包|份|听|勺|笼|客)\\s*"
        text = text.replacingOccurrences(of: prefixQtyPattern, with: "", options: .regularExpression)

        // 剥离前缀份量级别（如「大份」「小份」「中份」「标准份」「大碗」「小碗」「大盘」「小盘」「大杯」「小杯」）
        let prefixPortionPattern = "^(大份|小份|中份|标准份|大碗|小碗|中碗|大盘|小盘|大杯|小杯|中杯|大罐|小罐|大瓶|小瓶)\\s*"
        text = text.replacingOccurrences(of: prefixPortionPattern, with: "", options: .regularExpression)

        // 剥离糖度修饰（如「无糖」「微糖」「三分糖」「3分糖」「半糖」「五分糖」「少糖」「全糖」）
        let sugarPattern = "^(无糖|0糖|零糖|不加糖|微糖|三分糖|3分糖|半糖|五分糖|5分糖|少糖|七分糖|7分糖|全糖|正常糖|多糖)\\s*"
        text = text.replacingOccurrences(of: sugarPattern, with: "", options: .regularExpression)

        // 剥离温度/冰度修饰（如「冰镇」「去冰」「少冰」「常温」），并安全剥离「冰」「热」「温」「冷」
        let iceModifierPattern = "^(冰镇|去冰|少冰|常温)\\s*"
        text = text.replacingOccurrences(of: iceModifierPattern, with: "", options: .regularExpression)
        if text.hasPrefix("冰") && !text.hasPrefix("冰淇淋") && !text.hasPrefix("冰棒") && !text.hasPrefix("冰粉") && !text.hasPrefix("冰糖") {
            text = String(text.dropFirst())
        }
        if text.hasPrefix("热") && !text.hasPrefix("热干面") && !text.hasPrefix("热狗") {
            text = String(text.dropFirst())
        }
        if text.hasPrefix("温") || (text.hasPrefix("冷") && !text.hasPrefix("冷面")) {
            text = String(text.dropFirst())
        }

        // 剥离后缀糖度修饰
        let suffixSugarPattern = "\\s*(无糖|0糖|零糖|不加糖|微糖|三分糖|3分糖|半糖|五分糖|5分糖|少糖|七分糖|7分糖|全糖|正常糖|多糖)$"
        text = text.replacingOccurrences(of: suffixSugarPattern, with: "", options: .regularExpression)

        // 剥离后缀数量与量词（如「一份」「2碗」「1只」）
        let suffixQtyPattern = "\\s*([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*(个|只|块|片|条|根|碗|盘|杯|碟|袋|盒|瓶|串|颗|包|份|听|勺|笼|客|两|斤|g|克|ml|毫升)$"
        text = text.replacingOccurrences(of: suffixQtyPattern, with: "", options: .regularExpression)

        // 剥离后缀份量级别（如「大份」「小份」「大碗」）
        let suffixPortionPattern = "\\s*(大份|小份|中份|标准份|大碗|小碗|中碗|大盘|小盘|大杯|小杯|中杯|大罐|小罐|大瓶|小瓶)$"
        text = text.replacingOccurrences(of: suffixPortionPattern, with: "", options: .regularExpression)

        // 剥离末尾的「的」
        text = text.replacingOccurrences(of: "[的]+$", with: "", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 用餐时段先验

/// 用餐时段。用于基于时间上下文动态加权分类候选。
public enum MealTimePeriod: String, CaseIterable, Sendable {
    case breakfast    // 早餐 05:00 - 10:30
    case lunch        // 午餐 10:30 - 14:30
    case afternoonTea // 下午茶 14:30 - 17:00
    case dinner       // 晚餐 17:00 - 21:30
    case lateNight    // 夜宵 21:30 - 05:00

    public static func from(date: Date, calendar: Calendar = .current) -> MealTimePeriod {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let timeMinutes = hour * 60 + minute

        switch timeMinutes {
        case 5 * 60 ..< 10 * 60 + 30:
            return .breakfast
        case 10 * 60 + 30 ..< 14 * 60 + 30:
            return .lunch
        case 14 * 60 + 30 ..< 17 * 60:
            return .afternoonTea
        case 17 * 60 ..< 21 * 60 + 30:
            return .dinner
        default:
            return .lateNight
        }
    }

    /// 对食物项的时段先验调节乘数 (0.5 ~ 1.4)
    public func priorMultiplier(for item: FoodItem) -> Double {
        let isBreakfastStaple = item.id == "steamed_bun" || item.id == "shengjian_xiaolong" || item.id == "mantou" || item.id == "youtiao" ||
            item.id == "pancake_roll" || item.id == "congee" || item.id == "breakfast_cereal" ||
            item.id == "bread" || item.id == "soy_milk" || item.id == "pure_milk" || item.id == "egg" || item.id == "fried_egg"
        let isHeavyDish = item.id == "hotpot" || item.id == "barbecue" || item.id == "boiled_pork_fish" ||
            item.id == "suancai_fish" || item.id == "roast_duck" || item.id == "pig_trotter"

        switch self {
        case .breakfast:
            if isBreakfastStaple { return 1.35 }
            if item.id == "coffee" || item.id == "latte" { return 1.25 }
            if isHeavyDish { return 0.55 }
            if item.category == .snack && item.id != "sandwich" { return 0.65 }
            return 0.95

        case .lunch:
            if item.category == .staple || item.category == .meat || item.category == .veggie {
                return isBreakfastStaple && item.id != "steamed_bun" && item.id != "shengjian_xiaolong" ? 0.75 : 1.15
            }
            if item.id == "coffee" || item.id == "latte" { return 1.10 }
            return 1.0

        case .afternoonTea:
            if item.category == .drink || item.category == .dessert { return 1.35 }
            if item.id == "salad" || item.id == "fruit" { return 1.25 }
            if item.category == .meat || item.category == .staple { return 0.75 }
            return 0.9

        case .dinner:
            if item.category == .meat || item.category == .veggie || item.category == .soup { return 1.20 }
            if item.category == .staple && !isBreakfastStaple { return 1.15 }
            if isBreakfastStaple { return 0.65 }
            if item.id == "hotpot" || item.id == "barbecue" { return 1.25 }
            return 1.0

        case .lateNight:
            if item.id == "barbecue" || item.id == "fried_chicken" || item.id == "oden" ||
                item.id == "braised_duck_neck" || item.id == "roasted_cold_noodles" || item.id == "alcohol" ||
                item.id == "noodles" || item.id == "rice_noodles" {
                return 1.35
            }
            if isBreakfastStaple { return 0.50 }
            return 0.9
        }
    }
}

// MARK: - 用户历史饮食先验

/// 用户历史饮食习惯与偏好先验。
public struct FoodHistoryPrior: Sendable {
    /// 常用食物 ID 及食用次数统计
    public let frequentItemCounts: [String: Int]
    /// 最近（如 7 天内）吃过的食物 ID
    public let recentItemIDs: Set<String>

    public init(frequentItemCounts: [String: Int] = [:], recentItemIDs: Set<String> = []) {
        self.frequentItemCounts = frequentItemCounts
        self.recentItemIDs = recentItemIDs
    }

    /// 历史加权乘数 (1.0 ~ 1.3)
    public func multiplier(for itemID: String) -> Double {
        var mult = 1.0
        if let count = frequentItemCounts[itemID], count > 0 {
            // 频次越高，给与适度先验加成，最多 +20%
            mult += min(0.20, Double(count) * 0.04)
        }
        if recentItemIDs.contains(itemID) {
            mult += 0.05
        }
        return mult
    }
}

// MARK: - 识别候选

/// 一次识别得到的一个候选食物及其置信度。
public struct FoodCandidate: Equatable, Sendable, Identifiable {
    public let food: FoodItem
    /// 置信度 0...1。来自 Vision 的分类置信度，或 LLM 给出时的自评。
    public let confidence: Double
    /// 命中的 Vision 类目标识符（便于排查识别质量）
    public let matchedIdentifier: String?

    public var id: String { food.id }

    public init(food: FoodItem, confidence: Double, matchedIdentifier: String? = nil) {
        self.food = food
        self.confidence = confidence
        self.matchedIdentifier = matchedIdentifier
    }
}

/// 置信度分级。决定 UI 如何呈现这个估算。
public enum FoodConfidenceLevel: String, Sendable {
    /// 明确识别（置信度 ≥ 0.6）
    case high
    /// 可能是（0.35 ~ 0.6）
    case medium
    /// 认不准（< 0.35）
    case low

    public init(confidence: Double) {
        if confidence >= 0.6 { self = .high }
        else if confidence >= 0.35 { self = .medium }
        else { self = .low }
    }

    public var displayName: String {
        switch self {
        case .high: return "识别较明确"
        case .medium: return "可能是"
        case .low: return "认不准"
        }
    }
}

// MARK: - 估算结果

/// 单道菜品的估算明细（支持一餐多菜，例如托盘餐「米饭 + 辣椒炒肉 + 凉拌海带丝」）。
public struct FoodDishEstimate: Equatable, Sendable, Identifiable {
    public let id: String
    public let food: FoodItem
    public let portion: FoodPortion
    public let confidence: Double
    /// 该道菜吃掉的比例 0...1（1 表示全部吃完，0.5 表示吃了一半）
    public let consumedRatio: Double
    /// 该道菜整份热量（千卡）
    public let fullPortionCalories: Double
    /// 该道菜实际摄入热量（千卡）
    public var consumedCalories: Double {
        fullPortionCalories * consumedRatio
    }
    /// 实际摄入蛋白质（克）
    public var protein: Double {
        let grams = (fullPortionCalories / max(1, food.caloriesPer100g)) * 100.0
        return (grams / 100.0) * food.proteinPer100g * consumedRatio
    }
    /// 实际摄入脂肪（克）
    public var fat: Double {
        let grams = (fullPortionCalories / max(1, food.caloriesPer100g)) * 100.0
        return (grams / 100.0) * food.fatPer100g * consumedRatio
    }
    /// 实际摄入碳水化合物（克）
    public var carbs: Double {
        let grams = (fullPortionCalories / max(1, food.caloriesPer100g)) * 100.0
        return (grams / 100.0) * food.carbsPer100g * consumedRatio
    }

    public init(id: String? = nil,
                food: FoodItem,
                portion: FoodPortion = .regular,
                confidence: Double = 0.8,
                consumedRatio: Double = 1.0,
                fullPortionCaloriesOverride: Double? = nil) {
        self.id = id ?? food.id
        self.food = food
        self.portion = portion
        self.confidence = confidence
        self.consumedRatio = FoodCalorieEstimator.clampRatio(consumedRatio)
        self.fullPortionCalories = fullPortionCaloriesOverride
            ?? (food.standardServingCalories * portion.multiplier)
    }

    public func withConsumedRatio(_ ratio: Double) -> FoodDishEstimate {
        FoodDishEstimate(
            id: id,
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: ratio,
            fullPortionCaloriesOverride: fullPortionCalories
        )
    }

    public func withPortion(_ newPortion: FoodPortion) -> FoodDishEstimate {
        FoodDishEstimate(
            id: id,
            food: food,
            portion: newPortion,
            confidence: confidence,
            consumedRatio: consumedRatio
        )
    }

    public func withOverriddenCalories(_ calories: Double) -> FoodDishEstimate {
        FoodDishEstimate(
            id: id,
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: consumedRatio,
            fullPortionCaloriesOverride: calories
        )
    }

    /// 替换菜品对应的食物基准（换菜）
    public func replacing(food newFood: FoodItem) -> FoodDishEstimate {
        FoodDishEstimate(
            id: id,
            food: newFood,
            portion: portion,
            confidence: 1.0,
            consumedRatio: consumedRatio,
            fullPortionCaloriesOverride: newFood.standardServingCalories * portion.multiplier
        )
    }

    /// 更新菜品显示名称与热量数值（改名、直接输入卡路里数值）
    public func updating(name: String? = nil, calories: Double? = nil) -> FoodDishEstimate {
        let updatedFood: FoodItem
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updatedFood = food.withCustom(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            updatedFood = food
        }
        return FoodDishEstimate(
            id: id,
            food: updatedFood,
            portion: portion,
            confidence: confidence,
            consumedRatio: consumedRatio,
            fullPortionCaloriesOverride: calories ?? fullPortionCalories
        )
    }
}

/// 一次热量估算的完整结果（支持单品或「主食 + 多道配菜」的整餐组合）。
public struct FoodCalorieEstimate: Equatable, Sendable {
    /// 主菜品（兼容单菜品访问）
    public let food: FoodItem
    /// 本餐包含的所有菜品明细（至少包含 1 项；多菜托盘餐包含主食与各道配菜）
    public let dishes: [FoodDishEstimate]
    /// 份量
    public let portion: FoodPortion
    /// 识别置信度 0...1
    public let confidence: Double
    /// **吃掉的比例** 0...1。1 表示全部吃完，0.5 表示吃了一半。
    public let consumedRatio: Double
    /// 份量调整前的热量（整份合计）
    public let fullPortionCalories: Double
    /// 实际摄入热量 = 各道菜实际摄入之和（或整份 × 吃掉的比例）
    public let consumedCalories: Double
    /// 用户自定义的整餐展示名（若设置则覆盖自动生成的菜名拼接）
    public let customDisplayName: String?

    /// 展示用菜品名称（单菜显示菜名，多菜显示「米饭 + 辣椒炒肉 + 凉拌海带丝」；若用户自定义了整餐名称则显示自定义名称）。
    public var displayName: String {
        if let custom = customDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        guard dishes.count > 1 else { return food.name }
        return dishes.map(\.food.name).joined(separator: " + ")
    }

    public var confidenceLevel: FoodConfidenceLevel {
        FoodConfidenceLevel(confidence: confidence)
    }

    /// 整餐实际摄入蛋白质合计（克）
    public var totalProtein: Double {
        dishes.reduce(0.0) { $0 + $1.protein }
    }

    /// 整餐实际摄入脂肪合计（克）
    public var totalFat: Double {
        dishes.reduce(0.0) { $0 + $1.fat }
    }

    /// 整餐实际摄入碳水化合物合计（克）
    public var totalCarbs: Double {
        dishes.reduce(0.0) { $0 + $1.carbs }
    }

    /// 宏量营养素简报（如「碳水 55g · 蛋白质 18g · 脂肪 12g」）
    public var macroNutrientSummary: String {
        let p = Int(totalProtein.rounded())
        let f = Int(totalFat.rounded())
        let c = Int(totalCarbs.rounded())
        return "碳水 \(c)g · 蛋白质 \(p)g · 脂肪 \(f)g"
    }

    public init(food: FoodItem,
                portion: FoodPortion,
                confidence: Double,
                consumedRatio: Double = 1.0,
                fullPortionCaloriesOverride: Double? = nil,
                customDisplayName: String? = nil) {
        let clamped = FoodCalorieEstimator.clampRatio(consumedRatio)
        let base = fullPortionCaloriesOverride
            ?? (food.standardServingCalories * portion.multiplier)
        let singleDish = FoodDishEstimate(
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: clamped,
            fullPortionCaloriesOverride: base
        )
        self.food = food
        self.dishes = [singleDish]
        self.portion = portion
        self.confidence = confidence
        self.consumedRatio = clamped
        self.fullPortionCalories = base
        self.consumedCalories = base * clamped
        self.customDisplayName = customDisplayName
    }

    /// 由多道菜品构造整餐热量估算（自动汇总所有菜品的整份热量与实际摄入热量）。
    public init(dishes: [FoodDishEstimate], portion: FoodPortion? = nil, customDisplayName: String? = nil) {
        let validDishes = dishes.isEmpty
            ? [FoodDishEstimate(food: FoodCatalog.item(id: "rice") ?? FoodCatalog.items[0])]
            : dishes
        let primary = validDishes[0]
        let totalFull = validDishes.reduce(0.0) { $0 + $1.fullPortionCalories }
        let totalConsumed = validDishes.reduce(0.0) { $0 + $1.consumedCalories }
        let avgConfidence = validDishes.reduce(0.0) { $0 + $1.confidence } / Double(validDishes.count)
        let effectiveRatio = totalFull > 0
            ? FoodCalorieEstimator.clampRatio(totalConsumed / totalFull)
            : primary.consumedRatio

        self.food = primary.food
        self.dishes = validDishes
        self.portion = portion ?? primary.portion
        self.confidence = avgConfidence
        self.consumedRatio = effectiveRatio
        self.fullPortionCalories = totalFull
        self.consumedCalories = totalConsumed
        self.customDisplayName = customDisplayName
    }

    /// 修改整餐自定义名称
    public func withCustomDisplayName(_ name: String?) -> FoodCalorieEstimate {
        FoodCalorieEstimate(
            dishes: dishes,
            portion: portion,
            customDisplayName: name
        )
    }

    /// 替换某一道菜为另一个食物
    public func replacingDish(dishID: String, with newFood: FoodItem) -> FoodCalorieEstimate {
        let updatedDishes = dishes.map { dish in
            dish.id == dishID ? dish.replacing(food: newFood) : dish
        }
        return FoodCalorieEstimate(dishes: updatedDishes, portion: portion, customDisplayName: customDisplayName)
    }

    /// 更新某一道菜的名称与热量数值
    public func updatingDish(dishID: String, name: String? = nil, calories: Double? = nil) -> FoodCalorieEstimate {
        let updatedDishes = dishes.map { dish in
            dish.id == dishID ? dish.updating(name: name, calories: calories) : dish
        }
        return FoodCalorieEstimate(dishes: updatedDishes, portion: portion, customDisplayName: customDisplayName)
    }

    /// 换算后的实际摄入热量（保留整份热量基准，包括多道菜品、LLM 或手动覆盖后的整份热量）。
    public func withConsumedRatio(_ ratio: Double) -> FoodCalorieEstimate {
        let clamped = FoodCalorieEstimator.clampRatio(ratio)
        if dishes.count > 1 {
            let updatedDishes = dishes.map { $0.withConsumedRatio(clamped) }
            return FoodCalorieEstimate(dishes: updatedDishes, portion: portion, customDisplayName: customDisplayName)
        }
        return FoodCalorieEstimate(
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: clamped,
            fullPortionCaloriesOverride: fullPortionCalories,
            customDisplayName: customDisplayName
        )
    }

    /// 换算后的份量。
    public func withPortion(_ newPortion: FoodPortion) -> FoodCalorieEstimate {
        if dishes.count > 1 {
            let updatedDishes = dishes.map { $0.withPortion(newPortion) }
            return FoodCalorieEstimate(dishes: updatedDishes, portion: newPortion, customDisplayName: customDisplayName)
        }
        return FoodCalorieEstimate(food: food, portion: newPortion, confidence: confidence, consumedRatio: consumedRatio, customDisplayName: customDisplayName)
    }

    /// 用外部算出的热量覆盖基准值（保留份量、置信度与吃剩比例）。
    public func withOverriddenCalories(_ fullPortionCalories: Double) -> FoodCalorieEstimate {
        if dishes.count > 1, self.fullPortionCalories > 0 {
            let scale = fullPortionCalories / self.fullPortionCalories
            let updatedDishes = dishes.map {
                $0.withOverriddenCalories($0.fullPortionCalories * scale)
            }
            return FoodCalorieEstimate(dishes: updatedDishes, portion: portion, customDisplayName: customDisplayName)
        }
        return FoodCalorieEstimate(
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: consumedRatio,
            fullPortionCaloriesOverride: fullPortionCalories,
            customDisplayName: customDisplayName
        )
    }

    /// 调整某一道菜吃掉的百分比（例如米饭只吃了一半 50%，菜吃完了 100%）。
    public func updatingDishConsumedRatio(dishID: String, ratio: Double) -> FoodCalorieEstimate {
        let updated = dishes.map { dish in
            dish.id == dishID ? dish.withConsumedRatio(ratio) : dish
        }
        return FoodCalorieEstimate(dishes: updated, portion: portion, customDisplayName: customDisplayName)
    }

    /// 调整某一道菜的份量（小份/标准份/大份）。
    public func updatingDishPortion(dishID: String, portion newPortion: FoodPortion) -> FoodCalorieEstimate {
        let updated = dishes.map { dish in
            dish.id == dishID ? dish.withPortion(newPortion) : dish
        }
        return FoodCalorieEstimate(dishes: updated, portion: portion, customDisplayName: customDisplayName)
    }

    /// 向本餐追加一道菜品（若已存在同 ID 菜品则更新它，避免重复叠加同一菜品）。
    public func addingDish(_ newDish: FoodDishEstimate) -> FoodCalorieEstimate {
        if let idx = dishes.firstIndex(where: { $0.food.id == newDish.food.id }) {
            var copy = dishes
            copy[idx] = newDish
            return FoodCalorieEstimate(dishes: copy, portion: portion, customDisplayName: customDisplayName)
        }
        return FoodCalorieEstimate(dishes: dishes + [newDish], portion: portion, customDisplayName: customDisplayName)
    }

    /// 从本餐移除一道菜品（至少保留 1 道菜）。
    public func removingDish(dishID: String) -> FoodCalorieEstimate {
        let remaining = dishes.filter { $0.id != dishID }
        guard !remaining.isEmpty else { return self }
        return FoodCalorieEstimate(dishes: remaining, portion: portion, customDisplayName: customDisplayName)
    }
}

// MARK: - 估算与调整

/// 热量估算与调整的纯逻辑入口。
public enum FoodCalorieEstimator {

    /// 把比例限制在 0...1。非法输入（负数、超过 1、NaN）一律收敛到边界。
    public static func clampRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 1.0 }
        return min(max(ratio, 0), 1)
    }

    /// 由 Vision 分类结果构造候选列表，并可结合用餐时段先验与用户历史画像动态重排序。
    ///
    /// - Parameters:
    ///   - classifications: `(标识符, 置信度)` 列表，按置信度降序。
    ///   - limit: 最多返回几个候选。
    ///   - mealTime: 用餐时段（早餐/午餐/下午茶/晚餐/夜宵），用于动态调整置信度。
    ///   - history: 用户历史偏好与高频食用先验。
    /// - Returns: 候选列表。识别不到任何食物时返回**空数组**——
    ///   此时调用方应让用户手动选择，**不要**随便挑一个充数。
    public static func candidates(from classifications: [(identifier: String, confidence: Double)],
                                  limit: Int = 5,
                                  mealTime: MealTimePeriod? = nil,
                                  history: FoodHistoryPrior? = nil) -> [FoodCandidate] {
        var results: [FoodCandidate] = []
        var seen = Set<String>()

        for classification in classifications {
            let key = classification.identifier.lowercased()
            for food in FoodCatalog.items(matchingVisionIdentifier: key) {
                // 同一个食物只保留最高置信度的一次命中
                if seen.contains(food.id) { continue }
                seen.insert(food.id)

                let timeMult = mealTime?.priorMultiplier(for: food) ?? 1.0
                let histMult = history?.multiplier(for: food.id) ?? 1.0
                let adjustedConfidence = min(0.98, classification.confidence * timeMult * histMult)

                results.append(FoodCandidate(food: food,
                                              confidence: adjustedConfidence,
                                              matchedIdentifier: key))
            }
        }

        return Array(results.sorted { $0.confidence > $1.confidence }.prefix(limit))
    }

    /// 从候选列表中选出最佳估算。
    /// 候选为空时返回 nil（调用方引导用户手动选择）。
    public static func estimate(from candidates: [FoodCandidate],
                                 portion: FoodPortion = .regular,
                                 consumedRatio: Double = 1.0) -> FoodCalorieEstimate? {
        guard let best = candidates.first else { return nil }
        return FoodCalorieEstimate(food: best.food,
                                   portion: portion,
                                   confidence: best.confidence,
                                   consumedRatio: consumedRatio)
    }

    /// 由 LLM 给出的菜名反查食物库并构造估算。
    /// 查不到时返回 nil（不编造热量）。
    public static func estimate(foodName: String,
                                portion: FoodPortion = .regular,
                                confidence: Double = 0.5,
                                consumedRatio: Double = 1.0) -> FoodCalorieEstimate? {
        guard let food = FoodCatalog.items(matchingName: foodName).first else { return nil }
        return FoodCalorieEstimate(food: food,
                                   portion: portion,
                                   confidence: confidence,
                                   consumedRatio: consumedRatio)
    }

    /// 针对中式托盘餐/多菜套餐的整餐热量估算：
    /// 自动把识别到的「主食（如米饭）+ 热菜（如辣椒炒肉/家常小炒）+ 凉菜/配菜（如凉拌海带丝）」组合并累加热量，
    /// 避免只算一碗白米饭而漏掉配菜，或热菜置信度高时漏算米饭主食。
    public static func estimateMeal(from candidates: [FoodCandidate],
                                    detectedDishes: [FoodCandidate] = [],
                                    portion: FoodPortion = .regular,
                                    consumedRatio: Double = 1.0) -> FoodCalorieEstimate? {
        let clampedRatio = clampRatio(consumedRatio)

        // 1. 若多区域扫描已识别出明确的分区菜品列表，优先按分区菜品组合整餐
        if !detectedDishes.isEmpty {
            var seen = Set<String>()
            var mealDishes: [FoodDishEstimate] = []
            for item in detectedDishes {
                guard !seen.contains(item.food.id) else { continue }
                seen.insert(item.food.id)
                mealDishes.append(
                    FoodDishEstimate(
                        food: item.food,
                        portion: portion,
                        confidence: item.confidence,
                        consumedRatio: clampedRatio
                    )
                )
            }
            if mealDishes.count == 1, let only = mealDishes.first {
                return FoodCalorieEstimate(
                    food: only.food,
                    portion: portion,
                    confidence: only.confidence,
                    consumedRatio: clampedRatio
                )
            }
            if !mealDishes.isEmpty {
                return FoodCalorieEstimate(dishes: mealDishes, portion: portion)
            }
        }

        // 2. 退化到从候选列表中智能组合「主食 + 配菜」
        guard let best = candidates.first else { return nil }

        // 若最佳候选不是主食，但在候选中检出了主食（如白米饭置信度 ≥ 0.15），则同时保留该主食与配菜
        let bestStaple = candidates.first { $0.food.isStaple && $0.confidence >= 0.15 }
        let hasStirFry = candidates.contains { $0.food.id == "stir_fry_meat" && $0.confidence >= 0.10 }

        var mealCandidates: [FoodCandidate] = []
        if let staple = bestStaple {
            mealCandidates.append(staple)
            if best.food.id != staple.food.id {
                mealCandidates.append(best)
            }
        } else {
            mealCandidates.append(best)
        }

        for candidate in candidates {
            guard !mealCandidates.contains(where: { $0.food.id == candidate.food.id }) else { continue }
            // 主食只保留 1 种
            if candidate.food.isStaple { continue }
            // 辣椒炒肉互斥去重
            if hasStirFry && (candidate.food.id == "vegetable_dish" || candidate.food.id == "salad") {
                continue
            }
            // 汤品反光低置信度防误判
            if candidate.food.id == "soup" && candidate.confidence < 0.25 {
                continue
            }
            let threshold = candidate.food.id == "seaweed_dish" ? 0.07 : 0.12
            if candidate.confidence >= threshold {
                mealCandidates.append(candidate)
            }
            if mealCandidates.count >= 4 { break }
        }

        if mealCandidates.count == 1, let only = mealCandidates.first {
            return FoodCalorieEstimate(
                food: only.food,
                portion: portion,
                confidence: only.confidence,
                consumedRatio: clampedRatio
            )
        }

        // 排序：主食排在最前，其余按顺序排列
        let sortedMealCandidates = mealCandidates.filter(\.food.isStaple) + mealCandidates.filter { !$0.food.isStaple }
        let dishes = sortedMealCandidates.map {
            FoodDishEstimate(
                food: $0.food,
                portion: portion,
                confidence: $0.confidence,
                consumedRatio: clampedRatio
            )
        }
        return FoodCalorieEstimate(dishes: dishes, portion: portion)
    }

    /// 从用户输入的描述文本（支持单菜或多菜，如「米饭、辣椒炒肉、凉拌海带丝」）构造整餐估算。
    public static func estimateMeal(fromHint hintText: String,
                                    portion: FoodPortion = .regular,
                                    confidence: Double = 0.85,
                                    consumedRatio: Double = 1.0) -> FoodCalorieEstimate? {
        let trimmed = hintText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clampedRatio = clampRatio(consumedRatio)

        // 剥离常见的餐次与进食动作前缀/后缀（如「早饭吃了」、「午餐喝了」、「当做晚饭」）
        var cleaned = trimmed
        let mealPrefixes = [
            "早饭吃了", "早餐吃了", "午饭吃了", "午餐吃了", "晚饭吃了", "晚餐吃了", "夜宵吃了",
            "早饭喝了", "早餐喝了", "午饭喝了", "午餐喝了", "晚饭喝了", "晚餐喝了",
            "早饭吃", "早餐吃", "午饭吃", "午餐吃", "晚饭吃", "晚餐吃", "夜宵吃",
            "早饭喝", "早餐喝", "午饭喝", "午餐喝", "晚饭喝", "晚餐喝",
            "早饭", "早餐", "午饭", "午餐", "晚饭", "晚餐", "夜宵",
            "吃了点", "喝了点", "吃了个", "吃了", "喝了", "吃", "喝"
        ]
        for p in mealPrefixes {
            if cleaned.hasPrefix(p) {
                cleaned = String(cleaned.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let mealSuffixes = ["当早饭", "当早餐", "当午饭", "当午餐", "当晚饭", "当晚餐", "作早饭", "作早餐"]
        for s in mealSuffixes {
            if cleaned.hasSuffix(s) {
                cleaned = String(cleaned.dropLast(s.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 1. 先检查是否包含未用标点分隔的多菜口语表述（如「两个包子一碗粥」「一个肉包一杯豆浆」「两个鸡蛋一碗小米粥」）
        var preprocessed = cleaned
        let spokenBoundaryPattern = "(?<=[^\\s|，,、+＋/；;0-9一二两三四五六七八九十百千万半])(?=(?:[0-9]+|[一二两三四五六七八九十半]+)\\s*(?:个|只|块|片|条|根|碗|盘|杯|碟|袋|盒|瓶|串|颗|包|份|听|勺|笼|客|两|g|克|ml|毫升))"
        if let boundaryRegex = try? NSRegularExpression(pattern: spokenBoundaryPattern) {
            let range = NSRange(preprocessed.startIndex..., in: preprocessed)
            preprocessed = boundaryRegex.stringByReplacingMatches(in: preprocessed, range: range, withTemplate: "|")
        }

        // 2. 先尝试按常见分隔符拆分为多道菜
        let pattern = "[，,、+＋/；;\\s\n\r|]|(?:还有|加上|以及|配|加|和)"
        let rawParts: [String]
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(preprocessed.startIndex..., in: preprocessed)
            let replaced = regex.stringByReplacingMatches(in: preprocessed, range: nsRange, withTemplate: "|")
            rawParts = replaced.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            rawParts = [preprocessed]
        }

        var matchedDishes: [FoodDishEstimate] = []
        var seen = Set<String>()
        for part in rawParts {
            let parsed = parseDetailedQuantity(from: part)
            let queryName = parsed.cleanName.isEmpty ? part : parsed.cleanName
            guard let food = FoodCatalog.item(matchingNameStrict: queryName)
                ?? FoodCatalog.items(matchingName: queryName).first
                ?? FoodCatalog.item(matchingNameStrict: part)
                ?? FoodCatalog.items(matchingName: part).first else {
                continue
            }

            if !seen.contains(food.id) {
                seen.insert(food.id)
                let baseCal: Double
                if let grams = parsed.explicitGrams, grams > 0 {
                    baseCal = (grams / 100.0) * food.caloriesPer100g
                } else if let pieceGrams = food.pieceGrams, let unit = parsed.unit, isPieceUnit(unit) {
                    let totalGrams = pieceGrams * parsed.multiplier
                    baseCal = (totalGrams / 100.0) * food.caloriesPer100g
                } else {
                    let dishPortion = parsed.portion != .regular ? parsed.portion : portion
                    baseCal = food.standardServingCalories * dishPortion.multiplier * parsed.multiplier
                }

                let finalCal: Double
                if let sugarFactor = parsed.sugarFactor, food.category == .drink || food.id == "milk_tea" || food.id == "lemon_tea" {
                    finalCal = baseCal * sugarFactor
                } else {
                    finalCal = baseCal
                }

                let dishPortion = parsed.portion != .regular ? parsed.portion : portion
                let dish = FoodDishEstimate(
                    food: food,
                    portion: dishPortion,
                    confidence: confidence,
                    consumedRatio: clampedRatio,
                    fullPortionCaloriesOverride: finalCal
                )
                matchedDishes.append(dish)
            }
        }

        if matchedDishes.isEmpty {
            let parsed = parseDetailedQuantity(from: trimmed)
            let fallbackName = parsed.cleanName.isEmpty ? trimmed : parsed.cleanName
            guard let fallback = FoodCatalog.items(matchingName: fallbackName).first ?? FoodCatalog.items(matchingName: trimmed).first else {
                return nil
            }
            let baseCal: Double
            if let grams = parsed.explicitGrams, grams > 0 {
                baseCal = (grams / 100.0) * fallback.caloriesPer100g
            } else if let pieceGrams = fallback.pieceGrams, let unit = parsed.unit, isPieceUnit(unit) {
                let totalGrams = pieceGrams * parsed.multiplier
                baseCal = (totalGrams / 100.0) * fallback.caloriesPer100g
            } else {
                let dishPortion = parsed.portion != .regular ? parsed.portion : portion
                baseCal = fallback.standardServingCalories * dishPortion.multiplier * parsed.multiplier
            }

            let finalCal: Double
            if let sugarFactor = parsed.sugarFactor, fallback.category == .drink || fallback.id == "milk_tea" || fallback.id == "lemon_tea" {
                finalCal = baseCal * sugarFactor
            } else {
                finalCal = baseCal
            }

            let dishPortion = parsed.portion != .regular ? parsed.portion : portion
            matchedDishes = [
                FoodDishEstimate(
                    food: fallback,
                    portion: dishPortion,
                    confidence: confidence,
                    consumedRatio: clampedRatio,
                    fullPortionCaloriesOverride: finalCal
                )
            ]
        }

        if matchedDishes.count == 1, let single = matchedDishes.first {
            return FoodCalorieEstimate(
                food: single.food,
                portion: single.portion,
                confidence: single.confidence,
                consumedRatio: single.consumedRatio,
                fullPortionCaloriesOverride: single.fullPortionCalories
            )
        }

        return FoodCalorieEstimate(dishes: matchedDishes, portion: portion)
    }

    /// 结构化解析后的菜品数量信息
    public struct ParsedFoodQuantity: Equatable, Sendable {
        public var cleanName: String
        public var multiplier: Double
        public var portion: FoodPortion
        public var unit: String?
        public var explicitGrams: Double?
        public var sugarFactor: Double?
        public var temperature: String?

        public init(cleanName: String,
                    multiplier: Double = 1.0,
                    portion: FoodPortion = .regular,
                    unit: String? = nil,
                    explicitGrams: Double? = nil,
                    sugarFactor: Double? = nil,
                    temperature: String? = nil) {
            self.cleanName = cleanName
            self.multiplier = multiplier
            self.portion = portion
            self.unit = unit
            self.explicitGrams = explicitGrams
            self.sugarFactor = sugarFactor
            self.temperature = temperature
        }
    }

    private static func isPieceUnit(_ unit: String) -> Bool {
        let pieceUnits: Set<String> = ["个", "只", "串", "块", "片", "颗", "贯", "粒", "根"]
        return pieceUnits.contains(unit)
    }

    /// 解析单个菜品片段中的数量倍数、份量级别与纯菜名（兼容旧接口）
    public static func parsePortionAndQuantity(from rawPart: String) -> (cleanName: String, multiplier: Double, portion: FoodPortion) {
        let detailed = parseDetailedQuantity(from: rawPart)
        return (detailed.cleanName, detailed.multiplier, detailed.portion)
    }

    /// 深入解析单个菜品片段中的纯菜名、数量倍数、显式克数/毫升数、量词、份量级别、糖度与冰度
    public static func parseDetailedQuantity(from rawPart: String) -> ParsedFoodQuantity {
        var text = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ParsedFoodQuantity(cleanName: text) }

        // 移除括号内的补充文字，如 "(1个，约80–100g)" 或 "（约80g）"
        text = text.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var portion: FoodPortion = .regular
        var multiplier: Double = 1.0
        var unit: String?
        var explicitGrams: Double?
        var sugarFactor: Double?
        var temperature: String?

        // 1. 检查份量修饰（大份/小份/中份/大碗/小碗/大盘/小盘/大杯/小杯/大罐/小罐/大瓶/小瓶）
        if text.hasPrefix("大份") || text.hasPrefix("大碗") || text.hasPrefix("大盘") || text.hasPrefix("大杯") || text.hasPrefix("大罐") || text.hasPrefix("大瓶") {
            portion = .large
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("小份") || text.hasPrefix("小碗") || text.hasPrefix("小盘") || text.hasPrefix("小杯") || text.hasPrefix("小罐") || text.hasPrefix("小瓶") {
            portion = .small
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if text.hasPrefix("中份") || text.hasPrefix("标准份") || text.hasPrefix("中碗") || text.hasPrefix("中杯") {
            portion = .regular
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        } else if text.hasSuffix("大份") || text.hasSuffix("大碗") || text.hasSuffix("大盘") || text.hasSuffix("大杯") || text.hasSuffix("大罐") || text.hasSuffix("大瓶") {
            portion = .large
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
        } else if text.hasSuffix("小份") || text.hasSuffix("小碗") || text.hasSuffix("小盘") || text.hasSuffix("小杯") || text.hasSuffix("小罐") || text.hasSuffix("小瓶") {
            portion = .small
            text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }

        // 2. 检查糖度修饰（支持前缀、中缀、后缀，如「一杯半糖奶茶」「大杯无糖可乐」「少糖奶茶」）
        let sugarList: [(pattern: String, factor: Double)] = [
            ("无糖|0糖|零糖|不加糖", 0.65),
            ("三分糖|3分糖|微糖", 0.75),
            ("五分糖|5分糖|半糖", 0.85),
            ("七分糖|7分糖|少糖", 0.95),
            ("全糖|正常糖|多糖", 1.10)
        ]
        for item in sugarList {
            let regexStr = "(?:\(item.pattern))"
            if let regex = try? NSRegularExpression(pattern: regexStr),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                sugarFactor = item.factor
                if let r = Range(match.range, in: text) {
                    text.removeSubrange(r)
                    text = text.trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }

        // 3. 检查冰度/温度修饰（支持前缀、中缀、后缀）
        let iceModifierPattern = "(?:冰镇|去冰|少冰|多冰|常温)"
        if let regex = try? NSRegularExpression(pattern: iceModifierPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(match.range, in: text) {
            text.removeSubrange(r)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("冰") && !text.hasPrefix("冰淇淋") && !text.hasPrefix("冰棒") && !text.hasPrefix("冰粉") && !text.hasPrefix("冰糖") {
            temperature = "冰"
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("热") && !text.hasPrefix("热干面") && !text.hasPrefix("热狗") {
            temperature = "热"
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("温") || (text.hasPrefix("冷") && !text.hasPrefix("冷面")) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // 4. 检查显式重量/容量单位（前缀如 "200g", "150克", "500ml", "二两", "半斤"）
        let weightPattern = "^([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*(g|克|千克|kg|ml|毫升|升|L|两|斤)\\s*"
        if let regex = try? NSRegularExpression(pattern: weightPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let numRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text) {
            let numStr = String(text[numRange])
            let u = String(text[unitRange])
            let numVal = parseChineseQuantity(numStr)
            unit = u
            switch u {
            case "g", "克", "ml", "毫升":
                explicitGrams = numVal
            case "kg", "千克", "升", "L":
                explicitGrams = numVal * 1000.0
            case "两":
                explicitGrams = numVal * 50.0
            case "斤":
                explicitGrams = numVal * 500.0
            default:
                explicitGrams = numVal
            }
            if let fullRange = Range(match.range(at: 0), in: text) {
                text = String(text[fullRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        // 5. 若未匹配到显式重量，检查复合半量词（如 "一个半", "两碗半", "1个半", "2碗半"）
        if explicitGrams == nil {
            let compoundHalfPattern = "^([0-9]+|[一二两三四五六七八九十]+)\\s*(个|只|块|片|条|根|碗|盘|杯|碟|袋|盒|瓶|串|颗|包|份|听|勺|笼|客|两)半\\s*"
            if let regex = try? NSRegularExpression(pattern: compoundHalfPattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let numRange = Range(match.range(at: 1), in: text),
               let uRange = Range(match.range(at: 2), in: text) {
                multiplier = parseChineseQuantity(String(text[numRange])) + 0.5
                unit = String(text[uRange])
                if let fullRange = Range(match.range(at: 0), in: text) {
                    text = String(text[fullRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // 6. 检查前缀数量量词（如 "2个", "两个", "半个", "1颗", "一颗", "3只", "一根", "一杯", "10个", "十五个"）
        if explicitGrams == nil && multiplier == 1.0 && unit == nil {
            let qtyPattern = "^([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*(个|只|块|片|条|根|碗|盘|杯|碟|袋|盒|瓶|串|颗|包|份|听|勺|笼|客|两)\\s*"
            if let regex = try? NSRegularExpression(pattern: qtyPattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let numRange = Range(match.range(at: 1), in: text) {
                    multiplier = parseChineseQuantity(String(text[numRange]))
                }
                if let uRange = Range(match.range(at: 2), in: text) {
                    unit = String(text[uRange])
                }
                if let fullRange = Range(match.range(at: 0), in: text) {
                    text = String(text[fullRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            } else {
                // 检查纯数字空格前缀（如 "2 肉包", "10 饺子"）
                let digitOnlyPattern = "^([0-9]+(?:\\.[0-9]+)?)\\s+"
                if let regex = try? NSRegularExpression(pattern: digitOnlyPattern),
                   let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let numRange = Range(match.range(at: 1), in: text) {
                    if let val = Double(String(text[numRange])), val > 0 {
                        multiplier = val
                    }
                    if let fullRange = Range(match.range(at: 0), in: text) {
                        text = String(text[fullRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // 7. 检查后缀数量量词（如 "肉包2个", "水饺10个", "面条二两"）
        if explicitGrams == nil && multiplier == 1.0 {
            let trailingQtyPattern = "\\s*([0-9]+(?:\\.[0-9]+)?|[一二两三四五六七八九十半]+)\\s*(个|只|块|片|条|根|碗|盘|杯|碟|袋|盒|瓶|串|颗|包|份|听|勺|笼|客|两|斤|g|克|ml|毫升)$"
            if let regex = try? NSRegularExpression(pattern: trailingQtyPattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let numRange = Range(match.range(at: 1), in: text),
               let uRange = Range(match.range(at: 2), in: text) {
                let numStr = String(text[numRange])
                let u = String(text[uRange])
                unit = u
                let numVal = parseChineseQuantity(numStr)
                if u == "g" || u == "克" || u == "ml" || u == "毫升" {
                    explicitGrams = numVal
                } else if u == "两" {
                    explicitGrams = numVal * 50.0
                } else if u == "斤" {
                    explicitGrams = numVal * 500.0
                } else {
                    multiplier = numVal
                }
                if let fullRange = Range(match.range(at: 0), in: text) {
                    text = String(text[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        if temperature == nil {
            if text.hasPrefix("冰") && !text.hasPrefix("冰淇淋") && !text.hasPrefix("冰棒") && !text.hasPrefix("冰粉") && !text.hasPrefix("冰糖") {
                temperature = "冰"
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("热") && !text.hasPrefix("热干面") && !text.hasPrefix("热狗") {
                temperature = "热"
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("温") || (text.hasPrefix("冷") && !text.hasPrefix("冷面")) {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }

        text = text.replacingOccurrences(of: "^[这那的]+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[的]+$", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedFoodQuantity(
            cleanName: text,
            multiplier: multiplier,
            portion: portion,
            unit: unit,
            explicitGrams: explicitGrams,
            sugarFactor: sugarFactor,
            temperature: temperature
        )
    }

    /// 解析中文数字表达与常见数量（如「半」「一」「两」「十」「十一」「二十五」）
    public static func parseChineseQuantity(_ str: String) -> Double {
        if let d = Double(str), d > 0 { return d }
        if str == "半" { return 0.5 }
        let digits: [Character: Double] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if str.count == 1, let char = str.first, let single = digits[char] { return single }

        if str == "十" { return 10.0 }
        if str.hasPrefix("十") {
            if let secondChar = str.dropFirst().first {
                return 10.0 + (digits[secondChar] ?? 0)
            }
            return 10.0
        }
        if str.contains("十") {
            let parts = str.split(separator: "十", omittingEmptySubsequences: false)
            let tensChar = parts[0].first
            let tens = tensChar.flatMap { digits[$0] } ?? 1.0
            let ones = parts.count > 1 && !parts[1].isEmpty
                ? (parts[1].first.flatMap { digits[$0] } ?? 0.0)
                : 0.0
            return tens * 10.0 + ones
        }

        return 1.0
    }

    private static func parseQuantityNumber(_ str: String) -> Double {
        parseChineseQuantity(str)
    }

    /// 计算「整份」热量（不含吃剩比例）。
    public static func fullPortionCalories(food: FoodItem, portion: FoodPortion) -> Double {
        food.standardServingCalories * portion.multiplier
    }

    /// 格式化热量（整数千卡）。
    public static func formatCalories(_ calories: Double) -> String {
        "\(Int(calories.rounded())) 千卡"
    }

    /// 生成一句可读的摘要，供卡片与语音播报。
    public static func summary(for estimate: FoodCalorieEstimate, includeMacros: Bool = false) -> String {
        let portionText = estimate.portion == .regular ? "" : "（\(estimate.portion.displayName)）"
        var text = "\(estimate.displayName)\(portionText)约 \(formatCalories(estimate.consumedCalories))"
        if estimate.consumedRatio < 0.999 {
            text += "，吃了 \(Int((estimate.consumedRatio * 100).rounded()))%"
        }
        if includeMacros && (estimate.totalProtein > 0 || estimate.totalCarbs > 0 || estimate.totalFat > 0) {
            text += "（\(estimate.macroNutrientSummary)）"
        }
        return text
    }
}
