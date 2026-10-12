import Foundation
import SwiftData

/// 收支类别
public enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case food = "餐饮美食"
    case transport = "交通出行"
    case living = "居家日用"
    case shopping = "购物消费"
    case entertainment = "休闲娱乐"
    case medical = "医疗健康"
    case pets = "宠物萌宠"
    case digital = "数码家电"
    case social = "人情社交"
    case income = "职业收入"
    case otherIncome = "其它收入"
    case other = "其它支出"

    public var icon: String {
        switch self {
        case .food: return "fork.knife"
        case .transport: return "car.fill"
        case .living: return "house.fill"
        case .shopping: return "bag.fill"
        case .entertainment: return "gamecontroller.fill"
        case .medical: return "cross.case.fill"
        case .pets: return "pawprint.fill"
        case .digital: return "laptopcomputer"
        case .social: return "heart.fill"
        case .income: return "yensign.circle.fill"
        case .otherIncome: return "arrow.down.left.circle.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    public var isIncome: Bool {
        self == .income || self == .otherIncome
    }

    public var displayName: String {
        L10n.tr(rawValue)
    }
}

/// 记账明细存储模型
@Model
public final class ExpenseRecord {
    public var id: UUID
    public var amount: Double                // 金额（正数）
    public var isIncome: Bool               // true: 收入, false: 支出
    public var categoryRaw: String          // ExpenseCategory.rawValue
    public var title: String                // 消费项目/描述，如 "吃麦当劳"
    public var rawText: String              // 用户一句话输入的原文
    public var date: Date                   // 账单归属日期时间
    public var createdAt: Date
    @Transient public var receiptImageData: Data?
    // Kept out of the legacy ExpenseRecord schema so old stores can open safely.
    @Transient public var splitCount: Int = 1
    @Transient public var splitParticipants: String = ""

    public init(
        amount: Double,
        isIncome: Bool = false,
        category: ExpenseCategory = .other,
        title: String,
        rawText: String = "",
        date: Date = .now
    ) {
        self.id = UUID()
        self.amount = abs(amount)
        self.isIncome = isIncome
        self.categoryRaw = category.rawValue
        self.title = title
        self.rawText = rawText
        self.date = date
        self.createdAt = .now
        self.receiptImageData = nil
        self.splitCount = 1
        self.splitParticipants = ""
    }

    public var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? (isIncome ? .otherIncome : .other) }
        set { categoryRaw = newValue.rawValue }
    }
}

/// 智能自然语言记账解析器（离线正则与语义关键词分析）
public struct ExpenseParseResult: Equatable {
    public var amount: Double
    public var isIncome: Bool
    public var category: ExpenseCategory
    public var title: String
    public var date: Date
    public var splitCount: Int = 1
    public var splitParticipants: String = ""
}

public enum ExpenseNaturalLanguageParser {
    /// 解析一句话记账文本，例如："中午吃麦当劳花了 38 块"、"打车 25.5 元"、"发工资 15000"
    public static func parse(_ text: String) -> ExpenseParseResult? {
        let trimmed = normalizeSpeechText(text)
        guard !trimmed.isEmpty else { return nil }

        // 1. 提取金额
        guard let amount = extractAmount(from: trimmed), amount > 0 else {
            return nil
        }

        // 2. 判断收支类型
        let isIncome = determineIsIncome(from: trimmed)

        // 3. 推断消费分类
        let category = determineCategory(from: trimmed, isIncome: isIncome)

        // 4. 识别相对日期（如 "昨天吃烤肉花了200"）
        let date = extractDate(from: trimmed)

        // 5. 提炼项目标题
        let title = extractTitle(from: trimmed, amount: amount, isIncome: isIncome)

        var result = ExpenseParseResult(
            amount: amount,
            isIncome: isIncome,
            category: category,
            title: title,
            date: date
        )
        if let match = trimmed.range(of: "(?:AA|split|平摊|均摊|分摊)\\s*[：:]?\\s*(\\d+)\\s*(?:人|份|people|ways)?", options: [.regularExpression, .caseInsensitive]),
           let count = Int(trimmed[match].filter(\.isNumber)), count > 1 {
            result.splitCount = count
        }
        return result
    }

    // MARK: - 金额提取
    private static func extractAmount(from text: String) -> Double? {
        let chineseAmountPattern = "(?:花了|付了|收入|进账|到账|工资|奖金|支出|消费|共计|借出)\\s*([零〇一二两三四五六七八九十百千万]+)"
        if let regex = try? NSRegularExpression(pattern: chineseAmountPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let value = numberValue(String(text[range])), value > 0 {
            return value
        }

        // 先处理口语金额："二十五块五"、"12块5毛"、"12元5角"。
        let spokenAmountPattern = "([0-9]+|[零〇一二两三四五六七八九十百千万]+)\\s*(?:元|块|块钱)\\s*([0-9]+|[零〇一二两三四五六七八九十百千万]+)?\\s*(?:毛|角)?"
        if let regex = try? NSRegularExpression(pattern: spokenAmountPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let wholeRange = Range(match.range(at: 1), in: text),
           let whole = numberValue(String(text[wholeRange])), whole > 0 {
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
               let fractionRange = Range(match.range(at: 2), in: text),
               let fractionValue = numberValue(String(text[fractionRange])) {
                let fraction = fractionValue >= 10 ? fractionValue / 100 : fractionValue / 10
                return whole + fraction
            }
            return whole
        }

        // 常见语法 "花了/付了/用去/收入/支出/消费/为/是 38.5" 或英文 "$38.5", "spent 38.5"
        let patterns = [
            "(?:花了|付了|用去|支出|消费|收入|进账|共计|为|是|买.*?花了?|借出|spent|paid|cost|earned|received)\\s*\\$?([0-9]+(?:[.．][0-9]{1,2})?)",
            "([0-9]+(?:[.．][0-9]{1,2})?)\\s*(?:元|块钱|块|RMB|rmb|\\¥|USD|usd|dollars?|bucks?|yuan)",
            "(?:\\¥|￥|\\$)\\s*([0-9]+(?:\\.[0-9]{1,2})?)",
            "\\b([0-9]+(?:[.．][0-9]{1,2})?)\\b" // 末尾或独立的数字
        ]

        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                if let val = Double(text[range].replacingOccurrences(of: "．", with: ".")), val > 0 {
                    return val
                }
            }
        }
        return nil
    }

    // MARK: - 收入/支出判断
    private static func determineIsIncome(from text: String) -> Bool {
        let lower = text.lowercased()
        let incomeKeywords = [
            "收入", "进账", "到账", "收到", "发工资", "工资", "奖金", "年终奖", "红包收入", "收红包",
            "兼职", "副业", "退款", "报销", "利息", "理财收益", "收账", "赚到", "入账",
            "salary", "paycheck", "bonus", "income", "earned", "refund", "reimbursement", "dividend"
        ]
        for kw in incomeKeywords {
            if lower.contains(kw) && !text.contains("发红包") && !text.contains("给红包") {
                return true
            }
        }
        return false
    }

    // MARK: - 智能分类匹配
    private static func determineCategory(from text: String, isIncome: Bool) -> ExpenseCategory {
        let lower = text.lowercased()
        if isIncome {
            if text.contains("工资") || text.contains("奖金") || text.contains("薪水") || text.contains("薪资")
                || lower.contains("salary") || lower.contains("paycheck") || lower.contains("bonus") {
                return .income
            }
            return .otherIncome
        }

        let dict: [(ExpenseCategory, [String])] = [
            (.food, ["吃", "喝", "饭", "麦当劳", "肯德基", "星巴克", "咖啡", "奶茶", "外卖", "美团", "饿了么", "午餐", "晚餐", "早餐", "午饭", "晚饭", "早饭", "夜宵", "烧烤", "火锅", "零食", "面包", "水果", "蔬菜", "菜场", "买菜", "食堂", "便利店", "可乐", "饮品", "快餐", "餐厅", "lunch", "dinner", "breakfast", "coffee", "starbucks", "mcdonald", "kfc", "food", "meal", "snack", "fruit", "grocery", "groceries", "restaurant", "burger", "pizza", "tea"]),
            (.transport, ["打车", "滴滴", "地铁", "公交", "加油", "停车", "高铁", "机票", "火车", "车票", "高速费", "打车费", "单车", "共享单车", "代驾", "过路费", "洗车", "修车", "轮渡", "taxi", "uber", "lyft", "subway", "metro", "bus", "train", "flight", "parking", "gas", "fuel", "toll"]),
            (.living, ["房租", "水电", "电费", "水费", "燃气", "物业", "话费", "充话费", "宽带", "超市", "山姆", "日用品", "卫生纸", "洗洁精", "洗发水", "沐浴露", "牙膏", "理发", "剪头发", "洗衣", "保洁", "家政", "rent", "utility", "utilities", "electric", "water bill", "internet", "phone bill", "supermarket", "haircut", "laundry"]),
            (.shopping, ["买衣服", "衣服", "裤子", "鞋子", "裙子", "淘宝", "京东", "拼多多", "网购", "包包", "首饰", "化妆品", "护肤品", "防晒", "口红", "香水", "clothes", "shirt", "shoes", "dress", "pants", "shopping", "amazon", "bag", "cosmetics", "skincare"]),
            (.entertainment, ["电影", "看电影", "游戏", "充值", "皮肤", "Steam", "steam", "任天堂", "旅游", "门票", "KTV", "演唱会", "剧本杀", "密室", "捏脚", "按摩", "健身", "游泳", "movie", "cinema", "game", "concert", "ticket", "gym", "fitness", "massage", "travel"]),
            (.medical, ["药", "买药", "医院", "看病", "挂号", "体检", "诊所", "眼药水", "感冒药", "创口贴", "口罩", "检查费", "治疗", "牙医", "补牙", "medicine", "pharmacy", "hospital", "doctor", "clinic", "dentist", "medical"]),
            (.pets, ["猫", "狗", "宠物", "猫粮", "狗粮", "猫砂", "罐头", "绝育", "驱虫", "宠物医院", "牵引绳", "猫爬架", "pet", "cat food", "dog food", "vet", "kitty", "puppy"]),
            (.digital, ["手机", "电脑", "耳机", "键盘", "鼠标", "平板", "iPad", "充电线", "充电宝", "显示器", "数码", "家电", "冰箱", "洗衣机", "空调", "phone", "laptop", "macbook", "ipad", "airpods", "headphones", "keyboard", "mouse", "charger", "monitor"]),
            (.social, ["红包", "发红包", "请客", "聚餐", "礼金", "份子钱", "送礼", "人情", "请客吃饭", "借给", "gift", "present", "treat", "party"])
        ]

        for (cat, keywords) in dict {
            for kw in keywords {
                if lower.contains(kw) {
                    return cat
                }
            }
        }

        return .other
    }

    // MARK: - 日期推断
    private static func extractDate(from text: String) -> Date {
        let cal = Calendar.current
        let lower = text.lowercased()
        if text.contains("昨天") || text.contains("寻日") || lower.contains("yesterday") {
            return cal.date(byAdding: .day, value: -1, to: .now) ?? .now
        }
        if text.contains("前天") || lower.contains("two days ago") {
            return cal.date(byAdding: .day, value: -2, to: .now) ?? .now
        }
        if text.contains("大前天") || lower.contains("three days ago") {
            return cal.date(byAdding: .day, value: -3, to: .now) ?? .now
        }
        return .now
    }

    // MARK: - 标题提炼
    private static func extractTitle(from text: String, amount: Double, isIncome: Bool) -> String {
        var clean = text
        // 移除修饰词、时间词、代词与消费动词
        let removePatterns = [
            "帮我记一下", "帮我记一笔", "记一下", "记一笔", "记录", "记账", "帮我记",
            "大前天", "前天", "昨天", "昨日", "今天", "今日", "刚刚", "刚才",
            "中午", "早上", "晚上", "下午", "上午", "夜里",
            "一共", "总共", "累计", "大概", "差不多",
            "花了", "花掉", "付了", "用去", "支出", "消费了", "消费", "共计", "为", "是"
        ]
        for p in removePatterns {
            clean = clean.replacingOccurrences(of: p, with: "")
        }

        // 移除数字金额与货币单位（如 "69.9元"、"69.9块"、"¥69.9"、"$69.9"、"69.9"）
        if let amtRegex = try? NSRegularExpression(pattern: "(?:\\¥|￥|\\$)?\\s*[0-9]+(?:[.．][0-9]{1,2})?\\s*(?:元|块钱|块|毛|角|RMB|rmb|USD|usd|dollars?|bucks?|yuan)?", options: [.caseInsensitive]) {
            clean = amtRegex.stringByReplacingMatches(
                in: clean,
                range: NSRange(clean.startIndex..., in: clean),
                withTemplate: ""
            )
        }

        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: " ，。、,!？?元块¥￥$"))
        if clean.hasPrefix("我") {
            clean = String(clean.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " ，。、,!？?的"))
        }
        if clean.isEmpty {
            return isIncome ? L10n.tr("收到款项") : L10n.tr("日常消费")
        }
        return clean
    }

    // MARK: - 语音文本归一化与中文数字
    private static func normalizeSpeechText(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacements = [
            "元钱": "元", "圆": "元", "园": "元", "块 q": "块", "块钱": "块",
            "人民币": "元", "点": ".", "．": "."
        ]
        for (from, to) in replacements { value = value.replacingOccurrences(of: from, with: to) }
        return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func numberValue(_ value: String) -> Double? {
        if let arabic = Double(value.replacingOccurrences(of: "．", with: ".")) { return arabic }
        let digits: [Character: Double] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0.0
        var section = 0.0
        var current = 0.0
        for char in value {
            if let digit = digits[char] { current = digit; continue }
            switch char {
            case "十": section += (current == 0 ? 1 : current) * 10; current = 0
            case "百": section += (current == 0 ? 1 : current) * 100; current = 0
            case "千": section += (current == 0 ? 1 : current) * 1_000; current = 0
            case "万": total += (section + current) * 10_000; section = 0; current = 0
            default: return nil
            }
        }
        return total + section + current
    }
}
