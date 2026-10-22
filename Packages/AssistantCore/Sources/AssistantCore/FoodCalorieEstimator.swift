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
    /// 食物分类
    public let category: FoodCategory
    /// Vision 通用分类里可能命中的类目标识符（小写）
    public let visionIdentifiers: [String]
    /// 中文别名，用于 LLM 把识别结果映射到具体食物
    public let aliases: [String]

    public init(id: String,
                name: String,
                nameEn: String,
                caloriesPer100g: Double,
                category: FoodCategory = .staple,
                visionIdentifiers: [String] = [],
                aliases: [String] = []) {
        self.id = id
        self.name = name
        self.nameEn = nameEn
        self.caloriesPer100g = caloriesPer100g
        self.category = category
        self.visionIdentifiers = visionIdentifiers
        self.aliases = aliases
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
            category: category,
            visionIdentifiers: [],
            aliases: [displayName]
        )
    }

    /// 克隆并替换名称或热量
    public func withCustom(name: String? = nil, caloriesPer100g: Double? = nil) -> FoodItem {
        FoodItem(
            id: id,
            name: name ?? self.name,
            nameEn: nameEn,
            caloriesPer100g: caloriesPer100g ?? self.caloriesPer100g,
            category: category,
            visionIdentifiers: visionIdentifiers,
            aliases: aliases
        )
    }

    /// 标准份（一碗/一份/一个）的克数假设。用于从「每 100g」推算「一份多少千卡」。
    public var standardServingGrams: Double {
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
        case "steamed_bun": return 150
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
        case "egg": return 50
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

    /// 是否属于主食（用于套餐/托盘多菜组合判别）。
    public var isStaple: Bool {
        if category == .staple { return true }
        switch id {
        case "rice", "fried_rice", "noodles", "sushi", "dumpling", "congee", "bread", "breakfast_cereal", "pastry",
             "chinese_fastfood", "steamed_bun", "mantou", "youtiao", "pancake_roll", "roujiamo",
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

    /// 食物库条目（收录高频中餐主食、早点、荤菜、素菜、汤品、特色小吃、水果饮品）。
    public static let items: [FoodItem] = [
        // MARK: - 主食与早点 (Staple)
        FoodItem(id: "rice", name: "米饭", nameEn: "Steamed Rice", caloriesPer100g: 116, category: .staple,
                 visionIdentifiers: ["rice"], aliases: ["米饭", "白饭", "白米饭", "大米饭", "rice", "steamed rice"]),
        FoodItem(id: "fried_rice", name: "炒饭", nameEn: "Fried Rice", caloriesPer100g: 180, category: .staple,
                 visionIdentifiers: [], aliases: ["炒饭", "蛋炒饭", "扬州炒饭", "酱油炒饭", "牛肉炒饭", "fried rice"]),
        FoodItem(id: "noodles", name: "面条", nameEn: "Noodles", caloriesPer100g: 110, category: .staple,
                 visionIdentifiers: ["noodle", "ramen", "pasta", "spaghetti"], aliases: ["面条", "拉面", "汤面", "拌面", "牛肉面", "刀削面", "面", "noodles", "ramen", "pasta"]),
        FoodItem(id: "steamed_bun", name: "包子/生煎/小笼", nameEn: "Steamed Stuffed Bun", caloriesPer100g: 230, category: .staple,
                 visionIdentifiers: [], aliases: ["包子", "肉包", "菜包", "生煎包", "小笼包", "生煎", "灌汤包", "叉烧包", "水煎包", "baozi", "bun"]),
        FoodItem(id: "mantou", name: "馒头/花卷", nameEn: "Steamed Bread", caloriesPer100g: 210, category: .staple,
                 visionIdentifiers: [], aliases: ["馒头", "花卷", "白馒头", "刀切馒头", "窝窝头", "杂粮馒头", "mantou"]),
        FoodItem(id: "youtiao", name: "油条/油饼", nameEn: "Fried Dough Stick", caloriesPer100g: 380, category: .staple,
                 visionIdentifiers: [], aliases: ["油条", "油饼", "炸油条", "麻花", "youtiao"]),
        FoodItem(id: "pancake_roll", name: "煎饼果子/手抓饼", nameEn: "Pancake Roll", caloriesPer100g: 240, category: .staple,
                 visionIdentifiers: [], aliases: ["煎饼果子", "手抓饼", "鸡蛋灌饼", "葱油饼", "煎饼", "卷饼", "肉卷", "jianbing"]),
        FoodItem(id: "roujiamo", name: "肉夹馍", nameEn: "Roujiamo", caloriesPer100g: 260, category: .staple,
                 visionIdentifiers: [], aliases: ["肉夹馍", "陕西肉夹馍", "腊汁肉夹馍", "白吉馍", "roujiamo"]),
        FoodItem(id: "rice_noodles", name: "米粉/米线/螺蛳粉", nameEn: "Rice Noodles", caloriesPer100g: 120, category: .staple,
                 visionIdentifiers: [], aliases: ["米粉", "米线", "螺蛳粉", "酸辣粉", "桂林米粉", "过桥米线", "牛肉粉", "河粉", "炒河粉", "rice noodles"]),
        FoodItem(id: "zhajiangmian", name: "炸酱面/热干面", nameEn: "Noodles with Paste", caloriesPer100g: 200, category: .staple,
                 visionIdentifiers: [], aliases: ["炸酱面", "热干面", "油泼面", "葱油拌面", "担担面", "武汉热干面", "zhajiangmian"]),
        FoodItem(id: "dumpling", name: "饺子/馄饨", nameEn: "Dumplings", caloriesPer100g: 240, category: .staple,
                 visionIdentifiers: ["dumpling", "wonton", "pierogi"], aliases: ["饺子", "水饺", "煎饺", "馄饨", "抄手", "云吞", "dumpling", "wonton"]),
        FoodItem(id: "congee", name: "粥/稀饭", nameEn: "Congee", caloriesPer100g: 50, category: .staple,
                 visionIdentifiers: ["oatmeal", "porridge"], aliases: ["粥", "白粥", "稀饭", "皮蛋瘦肉粥", "小米粥", "八宝粥", "南瓜粥", "congee", "porridge"]),
        FoodItem(id: "sushi", name: "寿司", nameEn: "Sushi", caloriesPer100g: 150, category: .staple,
                 visionIdentifiers: ["sushi"], aliases: ["寿司", "手握寿司", "军舰寿司", "加州卷", "sushi"]),
        FoodItem(id: "bread", name: "面包/吐司", nameEn: "Bread", caloriesPer100g: 280, category: .staple,
                 visionIdentifiers: ["bread", "toast", "white_bread"], aliases: ["面包", "吐司", "全麦面包", "法棍", "欧包", "bread", "toast"]),
        FoodItem(id: "breakfast_cereal", name: "麦片/燕麦", nameEn: "Cereal", caloriesPer100g: 380, category: .staple,
                 visionIdentifiers: ["oatmeal", "cereal"], aliases: ["麦片", "燕麦", "燕麦片", "cereal", "oatmeal"]),
        FoodItem(id: "changfen", name: "肠粉", nameEn: "Rice Noodle Roll", caloriesPer100g: 110, category: .staple,
                 visionIdentifiers: [], aliases: ["肠粉", "广东肠粉", "鸡蛋肠粉", "肉沫肠粉", "虾仁肠粉", "changfen"]),
        FoodItem(id: "shaomai", name: "烧麦", nameEn: "Shaomai", caloriesPer100g: 220, category: .staple,
                 visionIdentifiers: [], aliases: ["烧麦", "烧卖", "糯米烧麦", "广式烧卖", "shaomai", "shumai"]),
        FoodItem(id: "zongzi", name: "粽子", nameEn: "Zongzi", caloriesPer100g: 200, category: .staple,
                 visionIdentifiers: [], aliases: ["粽子", "肉粽", "甜粽", "蛋黄肉粽", "豆沙粽", "zongzi"]),
        FoodItem(id: "niangao", name: "年糕/汤圆", nameEn: "Rice Cake & Tangyuan", caloriesPer100g: 180, category: .staple,
                 visionIdentifiers: [], aliases: ["年糕", "炒年糕", "汤圆", "元宵", "糍粑", "rice cake", "tangyuan"]),
        FoodItem(id: "corn_sweetpotato", name: "玉米/红薯/紫薯", nameEn: "Corn & Sweet Potato", caloriesPer100g: 105, category: .staple,
                 visionIdentifiers: [], aliases: ["玉米", "煮玉米", "红薯", "烤红薯", "紫薯", "南瓜", "蒸南瓜", "corn", "sweet potato"]),
        FoodItem(id: "chinese_fastfood", name: "中式快餐/便当", nameEn: "Chinese Fast Food", caloriesPer100g: 170, category: .staple,
                 visionIdentifiers: [], aliases: ["盖浇饭", "炒面", "炒粉", "盒饭", "套餐", "中式快餐", "快餐", "便当"]),

        // MARK: - 荤菜与家常热菜 (Meat)
        FoodItem(id: "stir_fry_meat", name: "辣椒炒肉/家常小炒", nameEn: "Stir-fried Meat & Peppers", caloriesPer100g: 165, category: .meat,
                 visionIdentifiers: ["stir_fry", "curry"],
                 aliases: ["辣椒炒肉", "小炒肉", "农家小炒肉", "青椒炒肉", "家常小炒", "家常炒菜", "肉片炒菜", "红烧肉块", "啤酒鸭", "黄焖鸡", "红烧鸡块", "宫保鸡丁", "鱼香肉丝", "回锅肉", "荤素小炒", "炒菜", "炒肉", "stir fry", "stir_fry"]),
        FoodItem(id: "braised_meat", name: "红烧肉/红烧排骨", nameEn: "Braised Pork & Ribs", caloriesPer100g: 245, category: .meat,
                 visionIdentifiers: [],
                 aliases: ["红烧肉", "红烧排骨", "卤肉", "梅菜扣肉", "红烧牛肉", "红烧鸭", "braised pork"]),
        FoodItem(id: "sweet_sour_pork", name: "糖醋里脊/锅包肉", nameEn: "Sweet & Sour Pork", caloriesPer100g: 260, category: .meat,
                 visionIdentifiers: [], aliases: ["糖醋里脊", "锅包肉", "咕咾肉", "糖醋排骨", "菠萝咕咾肉", "sweet sour pork"]),
        FoodItem(id: "boiled_pork_fish", name: "水煮肉片/水煮鱼/毛血旺", nameEn: "Boiled Meat & Fish in Chili", caloriesPer100g: 210, category: .meat,
                 visionIdentifiers: [], aliases: ["水煮肉片", "水煮鱼", "毛血旺", "水煮牛肉", "川味水煮", "boiled meat"]),
        FoodItem(id: "suancai_fish", name: "酸菜鱼/烤鱼", nameEn: "Fish with Sauerkraut", caloriesPer100g: 120, category: .meat,
                 visionIdentifiers: [], aliases: ["酸菜鱼", "烤鱼", "剁椒鱼头", "沸腾鱼", "清蒸鲈鱼", "suancai fish"]),
        FoodItem(id: "roast_duck", name: "烤鸭/卤鸭", nameEn: "Roast & Braised Duck", caloriesPer100g: 240, category: .meat,
                 visionIdentifiers: [], aliases: ["烤鸭", "北京烤鸭", "卤鸭", "南京盐水鸭", "烧鸭", "roast duck"]),
        FoodItem(id: "steak", name: "牛排", nameEn: "Steak", caloriesPer100g: 250, category: .meat,
                 visionIdentifiers: ["steak", "meat", "beef"], aliases: ["牛排", "煎牛排", "steak"]),
        FoodItem(id: "fried_chicken", name: "炸鸡/鸡排", nameEn: "Fried Chicken", caloriesPer100g: 280, category: .meat,
                 visionIdentifiers: ["fried_chicken", "chicken", "tempura"], aliases: ["炸鸡", "鸡排", "辣子鸡", "鸡米花", "原味鸡", "炸鸡翅", "fried chicken"]),
        FoodItem(id: "chicken_breast", name: "鸡胸肉/白切鸡", nameEn: "Chicken", caloriesPer100g: 165, category: .meat,
                 visionIdentifiers: ["grilled_chicken", "chicken"], aliases: ["鸡胸肉", "鸡肉", "白切鸡", "口水鸡", "鸡腿", "白斩鸡", "chicken breast", "chicken"]),
        FoodItem(id: "beef", name: "牛肉/酱牛肉", nameEn: "Beef", caloriesPer100g: 190, category: .meat,
                 visionIdentifiers: ["meat", "beef", "meatball"], aliases: ["牛肉", "卤牛肉", "酱牛肉", "小炒牛肉", "黑椒牛肉粒", "beef"]),
        FoodItem(id: "pork", name: "猪肉/叉烧", nameEn: "Pork", caloriesPer100g: 210, category: .meat,
                 visionIdentifiers: ["meat", "pork", "ham", "bacon", "sausage"], aliases: ["猪肉", "叉烧", "香肠", "培根", "烤肠", "pork"]),
        FoodItem(id: "lamb", name: "羊肉/羊肉串", nameEn: "Lamb & Mutton", caloriesPer100g: 200, category: .meat,
                 visionIdentifiers: [], aliases: ["羊肉", "烤羊肉串", "羊肉汤", "手抓羊肉", "葱爆羊肉", "lamb", "mutton"]),
        FoodItem(id: "shrimp", name: "虾/白灼虾/小龙虾", nameEn: "Shrimp & Prawns", caloriesPer100g: 100, category: .meat,
                 visionIdentifiers: ["shellfish", "shellfish_prepared", "crab", "lobster"], aliases: ["虾", "大虾", "白灼虾", "油焖大虾", "小龙虾", "麻辣小龙虾", "虾仁", "shrimp", "prawn"]),
        FoodItem(id: "fish", name: "鱼肉/海鲜", nameEn: "Fish & Seafood", caloriesPer100g: 130, category: .meat,
                 visionIdentifiers: ["fish", "seafood", "oyster", "clam"], aliases: ["鱼", "海鲜", "清蒸鱼", "红烧鱼", "三文鱼", "鳕鱼", "fish", "seafood"]),
        FoodItem(id: "curry_chicken_beef", name: "咖喱鸡/咖喱牛肉", nameEn: "Curry", caloriesPer100g: 160, category: .meat,
                 visionIdentifiers: [], aliases: ["咖喱鸡", "咖喱牛肉", "咖喱饭", "日式咖喱", "curry"]),
        FoodItem(id: "fried_pork_cutlet", name: "炸猪排", nameEn: "Fried Pork Cutlet", caloriesPer100g: 300, category: .meat,
                 visionIdentifiers: [], aliases: ["炸猪排", "猪排", "日式猪排", "天妇罗", "tonkatsu"]),
        FoodItem(id: "pig_trotter", name: "卤猪蹄/猪手", nameEn: "Braised Pig Trotter", caloriesPer100g: 260, category: .meat,
                 visionIdentifiers: [], aliases: ["猪蹄", "卤猪蹄", "猪手", "红烧猪蹄", "猪脚姜", "pig trotter"]),

        // MARK: - 素菜、豆制品与菌菇 (Veggie)
        FoodItem(id: "vegetable_dish", name: "素菜/炒青菜", nameEn: "Vegetable Dish", caloriesPer100g: 75, category: .veggie,
                 visionIdentifiers: ["vegetable", "broccoli", "tomato", "potato", "eggplant", "pepper_veggie", "bell_pepper", "jalapeno", "green_beans", "bean", "asparagus", "cabbage", "carrot", "cucumber", "lettuce", "onion", "pea", "pumpkin", "spinach"],
                 aliases: ["青菜", "炒青菜", "蔬菜", "素菜", "炒时蔬", "四季豆", "豆角", "干煸豆角", "红烧茄子", "vegetable"]),
        FoodItem(id: "stir_fry_cabbage", name: "手撕包菜/干锅花菜", nameEn: "Stir-fried Cabbage & Cauliflower", caloriesPer100g: 80, category: .veggie,
                 visionIdentifiers: [], aliases: ["手撕包菜", "干锅花菜", "炒花菜", "大头菜", "圆白菜", "包菜", "fried cabbage"]),
        FoodItem(id: "sour_potato_shreds", name: "酸辣土豆丝/地三鲜", nameEn: "Shredded Potato & Eggplant", caloriesPer100g: 120, category: .veggie,
                 visionIdentifiers: [], aliases: ["酸辣土豆丝", "土豆丝", "地三鲜", "红烧土豆", "土豆片", "shredded potato"]),
        FoodItem(id: "garlic_greens", name: "蒜蓉空心菜/绿叶青菜", nameEn: "Garlic Greens", caloriesPer100g: 60, category: .veggie,
                 visionIdentifiers: [], aliases: ["蒜蓉空心菜", "空心菜", "生菜", "白灼生菜", "菜心", "广东菜心", "油麦菜", "菠菜", "油菜", "garlic greens"]),
        FoodItem(id: "mapo_tofu", name: "麻婆豆腐/家常豆腐", nameEn: "Mapo Tofu", caloriesPer100g: 130, category: .veggie,
                 visionIdentifiers: [], aliases: ["麻婆豆腐", "家常豆腐", "肉沫豆腐", "麻辣豆腐", "mapo tofu"]),
        FoodItem(id: "tofu", name: "豆制品/豆干", nameEn: "Tofu", caloriesPer100g: 80, category: .veggie,
                 visionIdentifiers: [], aliases: ["豆腐", "豆干", "腐竹", "豆皮", "千张", "tofu"]),
        FoodItem(id: "egg", name: "西红柿炒鸡蛋/荷包蛋", nameEn: "Egg Dish", caloriesPer100g: 155, category: .veggie,
                 visionIdentifiers: ["egg", "fried_egg", "scrambled_eggs", "omelet"], aliases: ["鸡蛋", "煎蛋", "炒蛋", "番茄炒蛋", "西红柿炒鸡蛋", "荷包蛋", "卤蛋", "茶叶蛋", "水煮蛋", "蛋", "egg"]),
        FoodItem(id: "steamed_egg_custard", name: "水蒸蛋/鸡蛋羹", nameEn: "Steamed Egg Custard", caloriesPer100g: 70, category: .veggie,
                 visionIdentifiers: [], aliases: ["水蒸蛋", "鸡蛋羹", "蒸蛋", "炖蛋", "蒸水蛋", "steamed egg"]),
        FoodItem(id: "mushroom_dish", name: "炒菌菇/香菇油菜", nameEn: "Mushroom Dish", caloriesPer100g: 70, category: .veggie,
                 visionIdentifiers: [], aliases: ["炒菌菇", "菌菇", "香菇油菜", "杏鲍菇", "金针菇", "蘑菇", "mushroom dish"]),
        FoodItem(id: "cold_cucumber_fungus", name: "拍黄瓜/凉拌木耳", nameEn: "Cold Cucumber & Fungus", caloriesPer100g: 50, category: .veggie,
                 visionIdentifiers: [], aliases: ["拍黄瓜", "黄瓜", "凉拌木耳", "木耳", "凉拌腐竹", "皮蛋豆腐", "cold cucumber"]),
        FoodItem(id: "seaweed_dish", name: "凉拌海带丝/凉菜", nameEn: "Seaweed & Cold Dish", caloriesPer100g: 55, category: .veggie,
                 visionIdentifiers: ["seaweed", "pickle"],
                 aliases: ["凉拌海带丝", "海带丝", "海带", "凉拌菜", "凉菜", "小菜", "泡菜", "seaweed"]),
        FoodItem(id: "salad", name: "蔬菜沙拉/轻食", nameEn: "Salad", caloriesPer100g: 90, category: .veggie,
                 visionIdentifiers: ["salad", "vegetable", "guacamole", "hummus"], aliases: ["沙拉", "蔬菜沙拉", "轻食沙拉", "轻食", "salad"]),

        // MARK: - 汤品与羹类 (Soup)
        FoodItem(id: "soup", name: "汤品/例汤", nameEn: "Soup", caloriesPer100g: 35, category: .soup,
                 visionIdentifiers: ["soup"], aliases: ["汤", "例汤", "高汤", "清汤", "罗宋汤", "soup"]),
        FoodItem(id: "tomato_egg_soup", name: "番茄蛋花汤/紫菜蛋汤", nameEn: "Tomato Egg Soup", caloriesPer100g: 35, category: .soup,
                 visionIdentifiers: [], aliases: ["番茄蛋花汤", "西红柿鸡蛋汤", "紫菜蛋花汤", "蛋花汤", "紫菜汤", "tomato egg soup"]),
        FoodItem(id: "pork_ribs_soup", name: "排骨汤/老鸭汤/鸡汤", nameEn: "Pork Rib & Chicken Soup", caloriesPer100g: 65, category: .soup,
                 visionIdentifiers: [], aliases: ["排骨汤", "山药排骨汤", "玉米排骨汤", "老鸭汤", "母鸡汤", "鸡汤", "骨头汤", "ribs soup"]),

        // MARK: - 特色小吃、快餐与烧烤 (Snack)
        FoodItem(id: "hotpot", name: "火锅/麻辣烫", nameEn: "Hot Pot", caloriesPer100g: 150, category: .snack,
                 visionIdentifiers: ["hotpot"], aliases: ["火锅", "麻辣烫", "冒菜", "麻辣香锅", "hotpot"]),
        FoodItem(id: "barbecue", name: "烧烤/烤串", nameEn: "Barbecue", caloriesPer100g: 260, category: .snack,
                 visionIdentifiers: ["grill"], aliases: ["烧烤", "烤串", "烤肉", "串串", "barbecue", "bbq"]),
        FoodItem(id: "braised_duck_neck", name: "卤鸭脖/鸡爪", nameEn: "Braised Duck Neck & Claw", caloriesPer100g: 220, category: .snack,
                 visionIdentifiers: [], aliases: ["鸭脖", "卤鸭脖", "周黑鸭", "绝味", "鸡爪", "卤鸡爪", "鸭锁骨", "鸭翅", "duck neck"]),
        FoodItem(id: "oden", name: "关东煮/串串", nameEn: "Oden", caloriesPer100g: 80, category: .snack,
                 visionIdentifiers: [], aliases: ["关东煮", "便利店关东煮", "罗森关东煮", "oden"]),
        FoodItem(id: "stinky_tofu", name: "臭豆腐", nameEn: "Stinky Tofu", caloriesPer100g: 210, category: .snack,
                 visionIdentifiers: [], aliases: ["臭豆腐", "长沙臭豆腐", "炸臭豆腐", "stinky tofu"]),
        FoodItem(id: "roasted_cold_noodles", name: "烤冷面/章鱼小丸子", nameEn: "Roasted Cold Noodles & Takoyaki", caloriesPer100g: 230, category: .snack,
                 visionIdentifiers: [], aliases: ["烤冷面", "章鱼小丸子", "章鱼烧", "炸串", "takoyaki"]),
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
                 visionIdentifiers: ["cookie", "chocolate_chip"], aliases: ["饼干", "曲奇", "威化", "cookie"]),
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
                 visionIdentifiers: ["coffee", "coffee_bean"], aliases: ["咖啡", "美式", "黑咖啡", "浓缩咖啡", "冷萃", "coffee", "americano"]),
        FoodItem(id: "latte", name: "拿铁/卡布奇诺", nameEn: "Latte", caloriesPer100g: 40, category: .drink,
                 visionIdentifiers: ["latte", "cappuccino"], aliases: ["拿铁", "卡布奇诺", "摩卡", "焦糖玛奇朵", "生椰拿铁", "星巴克", "瑞幸", "库迪", "latte", "cappuccino", "mocha"]),
        FoodItem(id: "milk_tea", name: "奶茶/果茶", nameEn: "Milk Tea", caloriesPer100g: 70, category: .drink,
                 visionIdentifiers: ["bubble_tea", "juice", "drink"], aliases: ["奶茶", "珍珠奶茶", "喜茶", "奈雪", "蜜雪冰城", "霸王茶姬", "茶颜悦色", "古茗", "一点点", "milk tea", "bubble tea"]),
        FoodItem(id: "lemon_tea", name: "手打柠檬茶", nameEn: "Lemon Tea", caloriesPer100g: 35, category: .drink,
                 visionIdentifiers: ["juice", "drink"], aliases: ["柠檬茶", "手打柠檬茶", "暴打柠檬茶", "鸭屎香柠檬茶", "lemon tea"]),
        FoodItem(id: "sugar_free_tea", name: "无糖纯茶/乌龙茶", nameEn: "Sugar-free Tea", caloriesPer100g: 1, category: .drink,
                 visionIdentifiers: ["drink"], aliases: ["无糖纯茶", "乌龙茶", "东方树叶", "三得利乌龙茶", "绿茶", "普洱茶", "红茶", "sugar free tea"]),
        FoodItem(id: "soy_milk", name: "豆浆", nameEn: "Soy Milk", caloriesPer100g: 35, category: .drink,
                 visionIdentifiers: ["drink"], aliases: ["豆浆", "现磨豆浆", "原味豆浆", "甜豆浆", "soy milk"]),
        FoodItem(id: "pure_milk", name: "纯牛奶/鲜牛奶", nameEn: "Whole Milk", caloriesPer100g: 65, category: .drink,
                 visionIdentifiers: ["milk"], aliases: ["牛奶", "鲜牛奶", "纯牛奶", "热牛奶", "温牛奶", "全脂牛奶", "脱脂牛奶", "一袋牛奶", "一杯牛奶", "盒装牛奶", "milk", "whole milk"]),
        FoodItem(id: "cola", name: "可乐/含糖汽水", nameEn: "Cola", caloriesPer100g: 42, category: .drink,
                 visionIdentifiers: ["cola", "soda"], aliases: ["可乐", "汽水", "雪碧", "芬达", "cola"]),
        FoodItem(id: "sugar_free_cola", name: "无糖可乐/气泡水", nameEn: "Zero Calorie Soda", caloriesPer100g: 1, category: .drink,
                 visionIdentifiers: [], aliases: ["无糖可乐", "零度可乐", "元气森林", "气泡水", "无糖汽水", "diet cola", "zero cola"]),
        FoodItem(id: "juice", name: "鲜榨果汁", nameEn: "Juice", caloriesPer100g: 45, category: .drink,
                 visionIdentifiers: ["juice", "juicer"], aliases: ["果汁", "橙汁", "苹果汁", "juice"]),
        FoodItem(id: "coconut_water", name: "椰子水/椰青", nameEn: "Coconut Water", caloriesPer100g: 20, category: .drink,
                 visionIdentifiers: ["drink"], aliases: ["椰子水", "椰青", "生椰水", "coconut water"]),
        FoodItem(id: "alcohol", name: "酒类/啤酒", nameEn: "Alcoholic Drink", caloriesPer100g: 70, category: .drink,
                 visionIdentifiers: ["beer", "red_wine", "sparkling_wine", "wine"], aliases: ["啤酒", "红酒", "白酒", "鸡尾酒", "beer", "wine"]),
        FoodItem(id: "fruit", name: "水果拼盘", nameEn: "Fruit Platter", caloriesPer100g: 55, category: .drink,
                 visionIdentifiers: ["fruit", "apple", "banana", "orange", "grapefruit", "pineapple", "citrus_fruit", "passionfruit", "starfruit", "strawberry", "blueberry", "raspberry", "blackberry", "cherry", "grape", "melon", "peach", "pear", "plum", "kiwi", "avocado", "lemon", "lime", "mango"], aliases: ["水果", "水果拼盘", "草莓", "蓝莓", "葡萄", "桃子", "梨", "fruit"]),
        FoodItem(id: "apple", name: "苹果", nameEn: "Apple", caloriesPer100g: 52, category: .drink,
                 visionIdentifiers: [], aliases: ["苹果", "红富士", "青苹果", "apple"]),
        FoodItem(id: "banana", name: "香蕉", nameEn: "Banana", caloriesPer100g: 89, category: .drink,
                 visionIdentifiers: [], aliases: ["香蕉", "banana"]),
        FoodItem(id: "watermelon", name: "西瓜", nameEn: "Watermelon", caloriesPer100g: 30, category: .drink,
                 visionIdentifiers: [], aliases: ["西瓜", "切块西瓜", "watermelon"]),
        FoodItem(id: "orange_citrus", name: "橙子/柑橘/柚子", nameEn: "Orange & Citrus", caloriesPer100g: 45, category: .drink,
                 visionIdentifiers: [], aliases: ["橙子", "橘子", "柑橘", "柚子", "砂糖橘", "orange", "citrus"]),
        FoodItem(id: "durian_mango", name: "榴莲/芒果", nameEn: "Durian & Mango", caloriesPer100g: 130, category: .drink,
                 visionIdentifiers: [], aliases: ["榴莲", "芒果", "金枕榴莲", "台农芒果", "durian", "mango"]),
        FoodItem(id: "avocado", name: "牛油果", nameEn: "Avocado", caloriesPer100g: 160, category: .drink,
                 visionIdentifiers: [], aliases: ["牛油果", "鳄梨", "avocado"])
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
            "份", "个", "只", "块", "片", "条", "根", "碗", "盘", "杯", "碟", "袋", "盒", "瓶", "串", "颗", "包", "听", "勺",
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

        // 先尝试按常见分隔符拆分为多道菜
        let pattern = "[，,、+＋/；;\\s]|(?:还有|加上|以及|配|加|和)"
        let rawParts: [String]
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(cleaned.startIndex..., in: cleaned)
            let replaced = regex.stringByReplacingMatches(in: cleaned, range: nsRange, withTemplate: "|")
            rawParts = replaced.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            rawParts = [cleaned]
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
