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
    /// Vision 通用分类里可能命中的类目标识符（小写）
    public let visionIdentifiers: [String]
    /// 中文别名，用于 LLM 把识别结果映射到具体食物
    public let aliases: [String]

    public init(id: String,
                name: String,
                nameEn: String,
                caloriesPer100g: Double,
                visionIdentifiers: [String] = [],
                aliases: [String] = []) {
        self.id = id
        self.name = name
        self.nameEn = nameEn
        self.caloriesPer100g = caloriesPer100g
        self.visionIdentifiers = visionIdentifiers
        self.aliases = aliases
    }

    /// 标准份（一碗/一份/一个）的克数假设。用于从「每 100g」推算「一份多少千卡」。
    public var standardServingGrams: Double {
        switch id {
        case "rice": return 200
        case "noodles": return 300
        case "sushi": return 180
        case "dumpling": return 200
        case "soup": return 300
        case "salad": return 200
        case "steak": return 220
        case "fried_chicken": return 180
        case "pizza": return 200
        case "hamburger": return 220
        case "sandwich": return 200
        case "bread": return 80
        case "breakfast_cereal": return 50
        case "hotdog": return 150
        case "pastry": return 80
        case "ice_cream": return 100
        case "cake": return 100
        case "cookie": return 30
        case "coffee": return 250
        case "milk_tea": return 500
        case "latte": return 350
        case "chips": return 40
        case "chocolate": return 30
        case "cola": return 330
        case "juice": return 250
        case "fruit": return 150
        case "egg": return 50
        case "fish": return 150
        case "chicken_breast": return 150
        case "beef": return 150
        case "pork": return 150
        case "braised_meat": return 180
        case "stir_fry_meat": return 200
        case "tofu": return 150
        case "vegetable_dish": return 200
        case "seaweed_dish": return 150
        case "hotpot": return 400
        case "barbecue": return 300
        case "fried_rice": return 300
        case "chinese_fastfood": return 300
        case "congee": return 350
        case "yogurt": return 150
        case "nuts": return 30
        default: return 200
        }
    }

    /// 标准份的热量（千卡）。
    public var standardServingCalories: Double {
        caloriesPer100g * standardServingGrams / 100.0
    }

    /// 是否属于主食（用于套餐/托盘多菜组合判别）。
    public var isStaple: Bool {
        switch id {
        case "rice", "fried_rice", "noodles", "sushi", "dumpling", "congee", "bread", "breakfast_cereal", "pastry":
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

    /// 食物库条目。
    public static let items: [FoodItem] = [
        // MARK: 主食
        FoodItem(id: "rice", name: "米饭", nameEn: "Steamed Rice", caloriesPer100g: 116,
                 visionIdentifiers: ["rice"], aliases: ["米饭", "白饭", "白米饭", "大米饭", "rice", "steamed rice"]),
        FoodItem(id: "fried_rice", name: "炒饭", nameEn: "Fried Rice", caloriesPer100g: 180,
                 visionIdentifiers: [], aliases: ["炒饭", "蛋炒饭", "扬州炒饭", "酱油炒饭", "fried rice"]),
        FoodItem(id: "noodles", name: "面条", nameEn: "Noodles", caloriesPer100g: 110,
                 visionIdentifiers: ["noodle", "ramen", "pasta", "spaghetti"], aliases: ["面条", "拉面", "汤面", "拌面", "牛肉面", "面", "noodles", "ramen", "pasta"]),
        FoodItem(id: "sushi", name: "寿司", nameEn: "Sushi", caloriesPer100g: 150,
                 visionIdentifiers: ["sushi"], aliases: ["寿司", "sushi"]),
        FoodItem(id: "dumpling", name: "饺子/馄饨", nameEn: "Dumplings", caloriesPer100g: 240,
                 visionIdentifiers: ["dumpling", "wonton", "pierogi"], aliases: ["饺子", "水饺", "煎饺", "馄饨", "抄手", "云吞", "包子", "dumpling", "wonton"]),
        FoodItem(id: "congee", name: "粥", nameEn: "Congee", caloriesPer100g: 50,
                 visionIdentifiers: ["oatmeal", "porridge"], aliases: ["粥", "白粥", "稀饭", "皮蛋瘦肉粥", "congee", "porridge"]),
        FoodItem(id: "bread", name: "面包", nameEn: "Bread", caloriesPer100g: 280,
                 visionIdentifiers: ["bread", "toast", "white_bread"], aliases: ["面包", "吐司", "全麦面包", "bread", "toast"]),
        FoodItem(id: "breakfast_cereal", name: "麦片/燕麦", nameEn: "Cereal", caloriesPer100g: 380,
                 visionIdentifiers: ["oatmeal", "cereal"], aliases: ["麦片", "燕麦", "cereal", "oatmeal"]),
        FoodItem(id: "pastry", name: "糕点/酥点", nameEn: "Pastry", caloriesPer100g: 400,
                 visionIdentifiers: ["pastry", "croissant", "donut", "doughnut", "pancake", "waffle", "pie"], aliases: ["糕点", "酥点", "面包圈", "甜甜圈", "松饼", "华夫饼", "pastry"]),
        FoodItem(id: "chinese_fastfood", name: "中式快餐", nameEn: "Chinese Fast Food", caloriesPer100g: 170,
                 visionIdentifiers: [], aliases: ["盖浇饭", "炒面", "炒粉", "盒饭", "套餐", "中式快餐", "快餐"]),

        // MARK: 荤菜与中式热菜
        FoodItem(id: "stir_fry_meat", name: "辣椒炒肉/家常小炒", nameEn: "Stir-fried Meat & Peppers", caloriesPer100g: 165,
                 visionIdentifiers: ["stir_fry", "curry"],
                 aliases: ["辣椒炒肉", "小炒肉", "农家小炒肉", "青椒炒肉", "家常小炒", "家常炒菜", "肉片炒菜", "红烧肉块", "啤酒鸭", "黄焖鸡", "红烧鸡块", "宫保鸡丁", "鱼香肉丝", "回锅肉", "荤素小炒", "炒菜", "炒肉", "stir fry", "stir_fry"]),
        FoodItem(id: "braised_meat", name: "红烧肉/红烧排骨", nameEn: "Braised Pork & Ribs", caloriesPer100g: 245,
                 visionIdentifiers: [],
                 aliases: ["红烧肉", "红烧排骨", "糖醋排骨", "卤肉", "梅菜扣肉", "红烧猪蹄", "红烧牛肉", "红烧鸭", "braised pork"]),
        FoodItem(id: "steak", name: "牛排", nameEn: "Steak", caloriesPer100g: 250,
                 visionIdentifiers: ["steak", "meat", "beef"], aliases: ["牛排", "steak"]),
        FoodItem(id: "fried_chicken", name: "炸鸡", nameEn: "Fried Chicken", caloriesPer100g: 280,
                 visionIdentifiers: ["fried_chicken", "chicken", "tempura"], aliases: ["炸鸡", "鸡排", "辣子鸡", "鸡米花", "fried chicken"]),
        FoodItem(id: "chicken_breast", name: "鸡胸肉/白切鸡", nameEn: "Chicken", caloriesPer100g: 165,
                 visionIdentifiers: ["grilled_chicken", "chicken"], aliases: ["鸡胸肉", "鸡肉", "白切鸡", "口水鸡", "鸡腿", "chicken breast", "chicken"]),
        FoodItem(id: "beef", name: "牛肉", nameEn: "Beef", caloriesPer100g: 190,
                 visionIdentifiers: ["meat", "beef", "meatball"], aliases: ["牛肉", "卤牛肉", "酱牛肉", "小炒牛肉", "beef"]),
        FoodItem(id: "pork", name: "猪肉/排骨", nameEn: "Pork", caloriesPer100g: 210,
                 visionIdentifiers: ["meat", "pork", "ham", "bacon", "sausage"], aliases: ["猪肉", "排骨", "叉烧", "香肠", "培根", "pork"]),
        FoodItem(id: "fish", name: "鱼/海鲜", nameEn: "Fish & Seafood", caloriesPer100g: 130,
                 visionIdentifiers: ["fish", "seafood", "shellfish", "shellfish_prepared", "crab", "lobster", "oyster", "clam"], aliases: ["鱼", "海鲜", "清蒸鱼", "红烧鱼", "酸菜鱼", "虾", "虾仁", "fish", "seafood"]),
        FoodItem(id: "egg", name: "鸡蛋/炒蛋", nameEn: "Egg", caloriesPer100g: 155,
                 visionIdentifiers: ["egg", "fried_egg", "scrambled_eggs", "omelet"], aliases: ["鸡蛋", "煎蛋", "炒蛋", "番茄炒蛋", "西红柿炒鸡蛋", "卤蛋", "茶叶蛋", "水煮蛋", "蛋", "egg"]),
        FoodItem(id: "hotpot", name: "火锅/麻辣烫", nameEn: "Hot Pot", caloriesPer100g: 150,
                 visionIdentifiers: ["hotpot"], aliases: ["火锅", "麻辣烫", "冒菜", "麻辣香锅", "hotpot"]),
        FoodItem(id: "barbecue", name: "烧烤", nameEn: "Barbecue", caloriesPer100g: 260,
                 visionIdentifiers: ["grill"], aliases: ["烧烤", "串串", "烤肉", "烤串", "barbecue", "bbq"]),

        // MARK: 素菜、凉菜与汤品
        FoodItem(id: "seaweed_dish", name: "凉拌海带丝/凉菜", nameEn: "Seaweed & Cold Dish", caloriesPer100g: 55,
                 visionIdentifiers: ["seaweed", "pickle"],
                 aliases: ["凉拌海带丝", "海带丝", "海带", "凉拌菜", "凉菜", "小菜", "凉拌木耳", "拍黄瓜", "泡菜", "seaweed"]),
        FoodItem(id: "vegetable_dish", name: "素菜/炒青菜", nameEn: "Vegetable Dish", caloriesPer100g: 75,
                 visionIdentifiers: ["vegetable", "broccoli", "tomato", "potato", "eggplant", "pepper_veggie", "bell_pepper", "jalapeno", "green_beans", "bean", "mushroom", "asparagus", "cabbage", "carrot", "corn", "cucumber", "lettuce", "onion", "pea", "pumpkin", "spinach"],
                 aliases: ["青菜", "炒青菜", "蔬菜", "素菜", "炒时蔬", "四季豆", "豆角", "干煸豆角", "手撕包菜", "酸辣土豆丝", "红烧茄子", "蘑菇", "香菇", "青椒", "vegetable"]),
        FoodItem(id: "salad", name: "沙拉", nameEn: "Salad", caloriesPer100g: 90,
                 visionIdentifiers: ["salad", "vegetable", "guacamole", "hummus"], aliases: ["沙拉", "蔬菜沙拉", "轻食沙拉", "salad"]),
        FoodItem(id: "tofu", name: "豆制品/豆腐", nameEn: "Tofu", caloriesPer100g: 80,
                 visionIdentifiers: [], aliases: ["豆腐", "麻婆豆腐", "家常豆腐", "豆干", "腐竹", "tofu"]),
        FoodItem(id: "soup", name: "汤品/例汤", nameEn: "Soup", caloriesPer100g: 35,
                 visionIdentifiers: ["soup"], aliases: ["汤", "例汤", "紫菜蛋花汤", "番茄蛋汤", "排骨汤", "鸡汤", "罗宋汤", "soup"]),
        FoodItem(id: "fruit", name: "水果", nameEn: "Fruit", caloriesPer100g: 55,
                 visionIdentifiers: ["fruit", "apple", "banana", "orange", "grapefruit", "pineapple", "citrus_fruit", "passionfruit", "starfruit", "strawberry", "blueberry", "raspberry", "blackberry", "cherry", "grape", "melon", "watermelon", "peach", "pear", "plum", "mango", "kiwi", "avocado", "lemon", "lime"], aliases: ["水果", "苹果", "香蕉", "橙子", "西瓜", "草莓", "蓝莓", "葡萄", "fruit"]),
        FoodItem(id: "nuts", name: "坚果", nameEn: "Nuts", caloriesPer100g: 600,
                 visionIdentifiers: ["seed", "nuts", "nut", "almond", "peanut", "cashew", "chestnut", "sunflower_seeds"], aliases: ["坚果", "花生", "瓜子", "杏仁", "腰果", "核桃", "nuts"]),

        // MARK: 西式快餐
        FoodItem(id: "pizza", name: "披萨", nameEn: "Pizza", caloriesPer100g: 265,
                 visionIdentifiers: ["pizza"], aliases: ["披萨", "比萨", "pizza"]),
        FoodItem(id: "hamburger", name: "汉堡", nameEn: "Hamburger", caloriesPer100g: 250,
                 visionIdentifiers: ["hamburger", "burger"], aliases: ["汉堡", "hamburger", "burger"]),
        FoodItem(id: "sandwich", name: "三明治", nameEn: "Sandwich", caloriesPer100g: 230,
                 visionIdentifiers: ["sandwich", "burger"], aliases: ["三明治", "sandwich"]),
        FoodItem(id: "hotdog", name: "热狗", nameEn: "Hot Dog", caloriesPer100g: 240,
                 visionIdentifiers: ["hotdog"], aliases: ["热狗", "hotdog"]),
        FoodItem(id: "fries", name: "薯条", nameEn: "French Fries", caloriesPer100g: 310,
                 visionIdentifiers: ["fries"], aliases: ["薯条", "炸薯条", "fries"]),

        // MARK: 甜点
        FoodItem(id: "cake", name: "蛋糕", nameEn: "Cake", caloriesPer100g: 350,
                 visionIdentifiers: ["cake", "cake_regular", "cheesecake", "cupcake", "birthday_cake", "fruitcake"], aliases: ["蛋糕", "甜点", "cake"]),
        FoodItem(id: "cookie", name: "饼干", nameEn: "Cookie", caloriesPer100g: 480,
                 visionIdentifiers: ["cookie", "chocolate", "chocolate_chip"], aliases: ["饼干", "曲奇", "cookie"]),
        FoodItem(id: "ice_cream", name: "冰淇淋", nameEn: "Ice Cream", caloriesPer100g: 200,
                 visionIdentifiers: ["ice_cream", "frozen_dessert", "dessert"], aliases: ["冰淇淋", "雪糕", "ice cream"]),
        FoodItem(id: "yogurt", name: "酸奶", nameEn: "Yogurt", caloriesPer100g: 90,
                 visionIdentifiers: ["yogurt"], aliases: ["酸奶", "yogurt"]),

        // MARK: 饮品
        FoodItem(id: "coffee", name: "咖啡", nameEn: "Coffee", caloriesPer100g: 2,
                 visionIdentifiers: ["coffee", "coffee_bean"], aliases: ["咖啡", "美式", "coffee"]),
        // 带奶咖啡（拿铁/卡布奇诺/摩卡…）热量远高于黑咖啡，单列；连锁咖啡品牌名也归入此类
        FoodItem(id: "latte", name: "拿铁", nameEn: "Latte", caloriesPer100g: 40,
                 visionIdentifiers: ["latte", "cappuccino"], aliases: ["拿铁", "卡布奇诺", "摩卡", "焦糖玛奇朵", "生椰", "星巴克", "瑞幸", "库迪", "latte", "cappuccino", "mocha"]),
        FoodItem(id: "milk_tea", name: "奶茶", nameEn: "Milk Tea", caloriesPer100g: 70,
                 visionIdentifiers: ["bubble_tea", "juice", "drink"], aliases: ["奶茶", "珍珠奶茶", "喜茶", "奈雪", "蜜雪冰城", "霸王茶姬", "茶颜悦色", "古茗", "一点点", "milk tea", "bubble tea"]),
        FoodItem(id: "cola", name: "可乐", nameEn: "Cola", caloriesPer100g: 42,
                 visionIdentifiers: ["cola", "soda"], aliases: ["可乐", "汽水", "cola"]),
        FoodItem(id: "juice", name: "果汁", nameEn: "Juice", caloriesPer100g: 45,
                 visionIdentifiers: ["juice", "juicer"], aliases: ["果汁", "juice"]),
        FoodItem(id: "chips", name: "薯片", nameEn: "Potato Chips", caloriesPer100g: 540,
                 visionIdentifiers: ["potato_chips"], aliases: ["薯片", "薯条", "chips"]),
        FoodItem(id: "chocolate", name: "巧克力", nameEn: "Chocolate", caloriesPer100g: 540,
                 visionIdentifiers: ["chocolate"], aliases: ["巧克力", "chocolate"]),
        FoodItem(id: "alcohol", name: "酒类", nameEn: "Alcoholic Drink", caloriesPer100g: 70,
                 visionIdentifiers: ["beer", "red_wine", "sparkling_wine", "wine"], aliases: ["啤酒", "红酒", "白酒", "beer", "wine"])
    ]

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

        // 规则 1：完全相等
        for food in items {
            if food.name.lowercased() == lowerKey
                || food.nameEn.lowercased() == lowerKey
                || food.aliases.contains(where: { $0.lowercased() == lowerKey }) {
                return food
            }
        }

        // 规则 2：剥离量词/修饰后相等
        let stripped = stripPortionModifiers(key)
        guard stripped != key, !stripped.isEmpty else { return nil }
        let lowerStripped = stripped.lowercased()
        for food in items {
            if food.name.lowercased() == lowerStripped
                || food.nameEn.lowercased() == lowerStripped
                || food.aliases.contains(where: { $0.lowercased() == lowerStripped }) {
                return food
            }
        }
        return nil
    }

    /// 剥离中文菜名前的量词与修饰词（如「一份」「小份」「这个」）。
    private static func stripPortionModifiers(_ name: String) -> String {
        let modifiers: Set<Character> = [
            "一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十", "半",
            "份", "个", "只", "块", "片", "条", "碗", "盘", "杯", "碟",
            "小", "中", "大", "这", "那", "的"
        ]
        var result = name
        var changed = true
        while changed {
            changed = false
            while let first = result.first, modifiers.contains(first) {
                result.removeFirst()
                changed = true
            }
            while let last = result.last, modifiers.contains(last) {
                result.removeLast()
                changed = true
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// 展示用菜品名称（单菜显示菜名，多菜显示「米饭 + 辣椒炒肉/家常小炒 + 凉拌海带丝/凉菜」）。
    public var displayName: String {
        guard dishes.count > 1 else { return food.name }
        return dishes.map(\.food.name).joined(separator: " + ")
    }

    public var confidenceLevel: FoodConfidenceLevel {
        FoodConfidenceLevel(confidence: confidence)
    }

    public init(food: FoodItem,
                portion: FoodPortion,
                confidence: Double,
                consumedRatio: Double = 1.0,
                fullPortionCaloriesOverride: Double? = nil) {
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
    }

    /// 由多道菜品构造整餐热量估算（自动汇总所有菜品的整份热量与实际摄入热量）。
    public init(dishes: [FoodDishEstimate], portion: FoodPortion? = nil) {
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
    }

    /// 换算后的实际摄入热量（保留整份热量基准，包括多道菜品、LLM 或手动覆盖后的整份热量）。
    public func withConsumedRatio(_ ratio: Double) -> FoodCalorieEstimate {
        let clamped = FoodCalorieEstimator.clampRatio(ratio)
        if dishes.count > 1 {
            let updatedDishes = dishes.map { $0.withConsumedRatio(clamped) }
            return FoodCalorieEstimate(dishes: updatedDishes, portion: portion)
        }
        return FoodCalorieEstimate(
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: clamped,
            fullPortionCaloriesOverride: fullPortionCalories
        )
    }

    /// 换算后的份量。
    public func withPortion(_ newPortion: FoodPortion) -> FoodCalorieEstimate {
        if dishes.count > 1 {
            let updatedDishes = dishes.map { $0.withPortion(newPortion) }
            return FoodCalorieEstimate(dishes: updatedDishes, portion: newPortion)
        }
        return FoodCalorieEstimate(food: food, portion: newPortion, confidence: confidence, consumedRatio: consumedRatio)
    }

    /// 用外部算出的热量覆盖基准值（保留份量、置信度与吃剩比例）。
    public func withOverriddenCalories(_ fullPortionCalories: Double) -> FoodCalorieEstimate {
        if dishes.count > 1, self.fullPortionCalories > 0 {
            let scale = fullPortionCalories / self.fullPortionCalories
            let updatedDishes = dishes.map {
                $0.withOverriddenCalories($0.fullPortionCalories * scale)
            }
            return FoodCalorieEstimate(dishes: updatedDishes, portion: portion)
        }
        return FoodCalorieEstimate(
            food: food,
            portion: portion,
            confidence: confidence,
            consumedRatio: consumedRatio,
            fullPortionCaloriesOverride: fullPortionCalories
        )
    }

    /// 调整某一道菜吃掉的百分比（例如米饭只吃了一半 50%，菜吃完了 100%）。
    public func updatingDishConsumedRatio(dishID: String, ratio: Double) -> FoodCalorieEstimate {
        let updated = dishes.map { dish in
            dish.id == dishID ? dish.withConsumedRatio(ratio) : dish
        }
        return FoodCalorieEstimate(dishes: updated, portion: portion)
    }

    /// 调整某一道菜的份量（小份/标准份/大份）。
    public func updatingDishPortion(dishID: String, portion newPortion: FoodPortion) -> FoodCalorieEstimate {
        let updated = dishes.map { dish in
            dish.id == dishID ? dish.withPortion(newPortion) : dish
        }
        return FoodCalorieEstimate(dishes: updated, portion: portion)
    }

    /// 向本餐追加一道菜品（若已存在同 ID 菜品则更新它，避免重复叠加同一菜品）。
    public func addingDish(_ newDish: FoodDishEstimate) -> FoodCalorieEstimate {
        if let idx = dishes.firstIndex(where: { $0.food.id == newDish.food.id }) {
            var copy = dishes
            copy[idx] = newDish
            return FoodCalorieEstimate(dishes: copy, portion: portion)
        }
        return FoodCalorieEstimate(dishes: dishes + [newDish], portion: portion)
    }

    /// 从本餐移除一道菜品（至少保留 1 道菜）。
    public func removingDish(dishID: String) -> FoodCalorieEstimate {
        let remaining = dishes.filter { $0.id != dishID }
        guard !remaining.isEmpty else { return self }
        return FoodCalorieEstimate(dishes: remaining, portion: portion)
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

    /// 由 Vision 分类结果构造候选列表。
    ///
    /// - Parameters:
    ///   - classifications: `(标识符, 置信度)` 列表，按置信度降序。
    ///   - limit: 最多返回几个候选。
    /// - Returns: 候选列表。识别不到任何食物时返回**空数组**——
    ///   此时调用方应让用户手动选择，**不要**随便挑一个充数。
    public static func candidates(from classifications: [(identifier: String, confidence: Double)],
                                  limit: Int = 5) -> [FoodCandidate] {
        var results: [FoodCandidate] = []
        var seen = Set<String>()

        for classification in classifications {
            let key = classification.identifier.lowercased()
            for food in FoodCatalog.items(matchingVisionIdentifier: key) {
                // 同一个食物只保留最高置信度的一次命中
                if seen.contains(food.id) { continue }
                seen.insert(food.id)
                results.append(FoodCandidate(food: food,
                                              confidence: classification.confidence,
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
    /// 避免只算一碗白米饭而漏掉配菜热量。
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
        guard best.food.isStaple else {
            return FoodCalorieEstimate(
                food: best.food,
                portion: portion,
                confidence: best.confidence,
                consumedRatio: clampedRatio
            )
        }

        let hasStirFry = candidates.contains { $0.food.id == "stir_fry_meat" && $0.confidence >= 0.10 }
        var mealCandidates: [FoodCandidate] = [best]

        for candidate in candidates.dropFirst() {
            // 主食只取置信度最高的一种（避免米饭 + 面条同时误加）
            if candidate.food.isStaple { continue }
            // 当已有辣椒炒肉/家常小炒时，其中的辣椒/配菜常同时触发 vegetable_dish 或 salad，避免重复计入两份炒菜
            if hasStirFry && (candidate.food.id == "vegetable_dish" || candidate.food.id == "salad") {
                continue
            }
            // 汤品在深色酱汁盘或圆碗边缘易产生低置信度误报（~0.12），需更高置信度才自动并入整餐
            if candidate.food.id == "soup" && candidate.confidence < 0.25 {
                continue
            }
            // 凉拌海带丝等特征明确的配菜允许较低阈值（≥0.07），普通配菜需 ≥0.12
            let threshold = candidate.food.id == "seaweed_dish" ? 0.07 : 0.12
            if candidate.confidence >= threshold {
                mealCandidates.append(candidate)
            }
            if mealCandidates.count >= 4 { break }
        }

        if mealCandidates.count == 1 {
            return FoodCalorieEstimate(
                food: best.food,
                portion: portion,
                confidence: best.confidence,
                consumedRatio: clampedRatio
            )
        }

        let dishes = mealCandidates.map {
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

        // 先尝试按常见分隔符拆分为多道菜
        let pattern = "[，,、+＋/；;\\s]|(?:还有|加上|以及|配|加|和)"
        let rawParts: [String]
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            let replaced = regex.stringByReplacingMatches(in: trimmed, range: nsRange, withTemplate: "|")
            rawParts = replaced.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            rawParts = [trimmed]
        }

        var matchedFoods: [FoodItem] = []
        var seen = Set<String>()
        for part in rawParts {
            if let strict = FoodCatalog.item(matchingNameStrict: part) ?? FoodCatalog.items(matchingName: part).first {
                if !seen.contains(strict.id) {
                    seen.insert(strict.id)
                    matchedFoods.append(strict)
                }
            }
        }

        if matchedFoods.isEmpty {
            guard let fallback = FoodCatalog.items(matchingName: trimmed).first else { return nil }
            matchedFoods = [fallback]
        }

        if matchedFoods.count == 1, let single = matchedFoods.first {
            return FoodCalorieEstimate(
                food: single,
                portion: portion,
                confidence: confidence,
                consumedRatio: clampedRatio
            )
        }

        let dishes = matchedFoods.map {
            FoodDishEstimate(
                food: $0,
                portion: portion,
                confidence: confidence,
                consumedRatio: clampedRatio
            )
        }
        return FoodCalorieEstimate(dishes: dishes, portion: portion)
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
    public static func summary(for estimate: FoodCalorieEstimate) -> String {
        let portionText = estimate.portion == .regular ? "" : "（\(estimate.portion.displayName)）"
        var text = "\(estimate.displayName)\(portionText)约 \(formatCalories(estimate.consumedCalories))"
        if estimate.consumedRatio < 0.999 {
            text += "，吃了 \(Int((estimate.consumedRatio * 100).rounded()))%"
        }
        return text
    }
}
