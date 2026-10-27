import Foundation

// MARK: - 交易时间提取（纯逻辑）

/// 从短信/截图/小票文本中提取交易时间。
///
/// 原实现位于 App 侧 `OmniboxPlanner`，小票解析器也要用同一份正则——
/// 两份正则必然漂移（见金额解析的教训），故下沉本层，App 侧保留转发。
public enum TransactionDateExtractor {

    /// 提取交易时间（短信/截图里的 MM月dd日 HH:mm、yyyy-MM-dd HH:mm 等）
    public static func extract(from text: String) -> Date? {
        // 完整日期 + 时间
        if let regex = try? NSRegularExpression(pattern: "(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?\\s*(\\d{1,2}):(\\d{2})"),
           let comps = dateComponents(regex, in: text, hasYear: true) {
            return Calendar.current.date(from: comps)
        }
        // 完整日期无时间
        if let regex = try? NSRegularExpression(pattern: "(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?"),
           let comps = dateComponents(regex, in: text, hasYear: true) {
            return Calendar.current.date(from: comps)
        }
        // 月日 + 时间（默认今年）
        if let regex = try? NSRegularExpression(pattern: "(\\d{1,2})月(\\d{1,2})日\\s*(\\d{1,2}):(\\d{2})"),
           let comps = dateComponents(regex, in: text, hasYear: false) {
            return Calendar.current.date(from: comps)
        }
        // 仅日期
        if let regex = try? NSRegularExpression(pattern: "(\\d{1,2})月(\\d{1,2})日"),
           let comps = dateComponents(regex, in: text, hasYear: false) {
            return Calendar.current.date(from: comps)
        }
        return nil
    }

    private static func dateComponents(_ regex: NSRegularExpression, in text: String, hasYear: Bool) -> DateComponents? {
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        func captured(_ index: Int) -> Int? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text),
                  let value = Int(text[range]) else { return nil }
            return value
        }
        var comps = DateComponents()
        var offset = 0
        if hasYear {
            guard let year = captured(1) else { return nil }
            comps.year = year
            offset = 1
        }
        guard let month = captured(1 + offset), let day = captured(2 + offset) else { return nil }
        comps.month = month
        comps.day = day
        // 「仅日期」正则没有时分捕获组，越界访问会抛 NSInvalidArgumentException
        if match.numberOfRanges > 4 + offset,
           let hour = captured(3 + offset), let minute = captured(4 + offset) {
            comps.hour = hour
            comps.minute = minute
        }
        // 与原 App 侧实现保持同一语义：缺省年=今年、缺省时=12 点
        if comps.year == nil { comps.year = Calendar.current.component(.year, from: .now) }
        if comps.hour == nil { comps.hour = 12 }
        return comps
    }
}

// MARK: - 小票/发票文本解析（纯逻辑）

/// 小票智能解析结果。
///
/// `categoryRaw` 取 `ExpenseCategory.rawValue`（如「餐饮美食」），
/// 本层不依赖 App 模型，由调用方映射回枚举。
public struct ReceiptParseResult: Sendable, Equatable {
    public var amount: Double
    public var title: String
    public var categoryRaw: String
    public var date: Date
    public var confidence: Double
    public var confidenceReason: String?
    public var candidateAmounts: [Double]
    /// 是否识别到明确的「合计/实付」等总额标签——投喂口据此决定是否直接建账
    public var hasLabeledTotal: Bool

    public init(
        amount: Double,
        title: String,
        categoryRaw: String,
        date: Date,
        confidence: Double,
        confidenceReason: String? = nil,
        candidateAmounts: [Double] = [],
        hasLabeledTotal: Bool = false
    ) {
        self.amount = amount
        self.title = title
        self.categoryRaw = categoryRaw
        self.date = date
        self.confidence = confidence
        self.confidenceReason = confidenceReason
        self.candidateAmounts = candidateAmounts
        self.hasLabeledTotal = hasLabeledTotal
    }
}

/// 小票/发票 OCR 文本 → 结构化记账要素。
///
/// 金额提取是**静默数据损坏**高发区（金额记错用户事后才发现），
/// 必须留在 AssistantCore 受单元测试约束，禁止在 App target 复制第二份正则。
public enum ReceiptTextParser {

    /// 解析小票文本。`now` 仅作为文本中无日期时的兜底。
    public static func parse(_ text: String, now: Date = .now) -> ReceiptParseResult {
        let candidates = extractAllCandidateAmounts(from: text)
        let labeledTotal = extractLabeledTotalAmount(from: text)
        let merchant = extractMerchantOrTitle(from: text)
        let category = guessCategoryRaw(merchant: merchant, text: text)
        let date = TransactionDateExtractor.extract(from: text) ?? now

        if let explicit = labeledTotal {
            return ReceiptParseResult(
                amount: explicit,
                title: merchant,
                categoryRaw: category,
                date: date,
                confidence: 0.92,
                confidenceReason: nil,
                candidateAmounts: candidates,
                hasLabeledTotal: true
            )
        } else if let maxCandidate = candidates.max() {
            return ReceiptParseResult(
                amount: maxCandidate,
                title: merchant,
                categoryRaw: category,
                date: date,
                confidence: 0.60,
                confidenceReason: "未明确检测到“合计/实付”标签，已提取最大可能金额，请核对",
                candidateAmounts: candidates,
                hasLabeledTotal: false
            )
        } else {
            return ReceiptParseResult(
                amount: 0.0,
                title: merchant,
                categoryRaw: category,
                date: date,
                confidence: 0.25,
                confidenceReason: "未能自动识别金额，请手动输入或重拍",
                candidateAmounts: [],
                hasLabeledTotal: false
            )
        }
    }

    /// 是否存在明确的总额标签（合计/实付/应付…）。
    /// 投喂口用它做「这张图是小票」的强判据，避免普通文稿里的数字被误建账。
    public static func hasLabeledTotal(_ text: String) -> Bool {
        extractLabeledTotalAmount(from: text) != nil
    }

    // MARK: - 金额

    /// 金额数字片段：千分位逗号整体吞掉后再可选小数，防止 `1,250.00` 被截成 `1,25`。
    /// 两个分支顺序不能换：千分位形式必须先于纯数字形式，否则 `1,25` 会先匹配上。
    private static let amountNumberPattern =
        "([0-9]+(?:,[0-9]{3})+(?:[.][0-9]{1,2})?|[0-9]+(?:[.][0-9]{1,2})?)"

    private static func parseAmount(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        return Double(cleaned)
    }

    /// 提取明确带有「合计/实付/总计/应付」等字样的金额。
    /// 标签允许可选「金额」后缀（「实付金额 55」与「实付 55」都要能命中）。
    public static func extractLabeledTotalAmount(from text: String) -> Double? {
        let patterns = [
            "(?:合计|总计|实付|应付|实际支付|支付金额|订单金额|实收|消费金额|账单金额|结算金额|小计|TOTAL|Total|PAID)(?:金额)?\\s*[:：]?\\s*[¥￥]?\\s*\(amountNumberPattern)",
            "[¥￥]\\s*\(amountNumberPattern)\\s*(?:元)?\\s*(?:合计|实付|应付|实收)",
            "(?:合计|实付|应付|实收)(?:金额)?\\s*[¥￥]?\\s*\(amountNumberPattern)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.range(at: 1).location != NSNotFound,
                  let range = Range(match.range(at: 1), in: text),
                  let amount = parseAmount(String(text[range])),
                  amount > 0 else { continue }
            return amount
        }
        return nil
    }

    /// 提取全文中所有合法的金额数值（降序）
    public static func extractAllCandidateAmounts(from text: String) -> [Double] {
        let patterns = [
            "[¥￥]\\s*\(amountNumberPattern)",
            "\(amountNumberPattern)\\s*(?:元|块)",
            "\\b([0-9]+\\.[0-9]{2})\\b"
        ]
        var amounts: Set<Double> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches where match.range(at: 1).location != NSNotFound {
                if let range = Range(match.range(at: 1), in: text),
                   let val = parseAmount(String(text[range])),
                   val > 0 && val < 500000 {
                    amounts.insert(val)
                }
            }
        }
        return amounts.sorted(by: >)
    }

    // MARK: - 商户/标题

    /// 从头部提取商户名或门店名称
    public static func extractMerchantOrTitle(from text: String) -> String {
        // 1. 尝试匹配显式的商户/门店标签
        let labeledPatterns = [
            "(?:商户名称|门店名称|商户|门店|店铺|收款方|商户全称)\\s*[:：]\\s*([^\\n\\r]{2,20})",
            "欢迎光临\\s*([^\\n\\r]{2,20})"
        ]
        for pattern in labeledPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }

        // 2. 检查前几行非空文本，排除常规表头、分隔线与纯数字
        let ignoreKeywords = ["结账单", "收银单", "销售小票", "发票", "存根", "POS签购单", "明细", "小票", "小票消费", "欢迎光临", "交易凭条"]
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.prefix(6) {
            if line.count >= 2 && line.count <= 25 {
                let isIgnore = ignoreKeywords.contains { line.contains($0) }
                let isPureDigitsOrSymbols = line.range(of: "^[0-9\\-—*#:=. /]+$", options: .regularExpression) != nil
                if !isIgnore && !isPureDigitsOrSymbols {
                    return line
                }
            }
        }

        return "小票消费"
    }

    // MARK: - 分类

    /// 智能分类判定。返回 `ExpenseCategory.rawValue`；未命中回落「购物消费」。
    public static func guessCategoryRaw(merchant: String, text: String) -> String {
        let combined = merchant + " " + text

        let mapping: [(String, [String])] = [
            ("餐饮美食", [
                "餐饮", "饭店", "餐馆", "火锅", "咖啡", "奶茶", "快餐", "美食", "茶饮", "面馆",
                "米线", "烤肉", "料理", "酒楼", "烘焙", "甜品", "面包", "堂食", "外卖", "麦当劳",
                "肯德基", "星巴克", "瑞幸", "喜茶", "蜜雪", "汉堡", "披萨", "必胜客", "海底捞",
                "西贝", "真功夫", "吉野家", "味千", "老乡鸡", "霸王茶姬", "茶百道", "茶颜悦色",
                "萨莉亚", "达美乐", "烧烤", "麻辣烫", "小吃", "早餐", "午餐", "晚餐"
            ]),
            ("居家日用", [
                "超市", "便利店", "生鲜", "百货", "果蔬", "菜场", "粮油", "日用", "全家", "罗森",
                "7-11", "7-ELEVEN", "大润发", "沃尔玛", "永辉", "盒马", "物美", "华润万家",
                "家乐福", "屈臣氏", "名创优品", "便利蜂", "杂货", "菜市", "百联"
            ]),
            ("交通出行", [
                "加油", "中石化", "中石油", "中国海油", "加气", "充电桩", "停车", "收费站", "高速",
                "滴滴", "出租车", "打车", "地铁", "公交", "ETC", "铁路", "客运", "高德打车"
            ]),
            ("医疗健康", [
                "药房", "药店", "大药房", "同仁堂", "海王星辰", "益丰", "国大", "老百姓", "一心堂",
                "医院", "门诊", "诊所", "体检", "卫生院", "口腔", "眼科", "处方", "挂号"
            ]),
            ("休闲娱乐", [
                "影城", "影院", "电影", "万达影城", "大地影院", "KTV", "密室", "剧本杀", "乐园",
                "游乐", "网吧", "电竞", "健身", "游泳", "保龄球", "桌游"
            ]),
            ("数码家电", [
                "数码", "手机", "电脑", "专卖店", "Apple", "苹果", "华为", "小米", "OPPO",
                "vivo", "大疆", "联想", "电子产品", "苏宁易购"
            ]),
            ("宠物萌宠", [
                "宠物", "萌宠", "猫粮", "狗粮", "宠物医院", "宠物洗护", "猫砂"
            ])
        ]

        for (cat, keywords) in mapping {
            if keywords.contains(where: { combined.localizedCaseInsensitiveContains($0) }) {
                return cat
            }
        }

        return "购物消费"
    }
}
