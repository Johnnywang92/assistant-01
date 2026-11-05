import Foundation

// MARK: - 交易时间提取（纯逻辑）

/// 从短信/截图/小票文本中提取交易时间。
///
/// 原实现位于 App 侧 `OmniboxPlanner`，小票解析器也要用同一份正则——
/// 两份正则必然漂移（见金额解析的教训），故下沉本层，App 侧保留转发。
public enum TransactionDateExtractor {

    /// 提取交易时间（短信/截图里的 MM月dd日 HH:mm、yyyy-MM-dd HH:mm 等）。
    ///
    /// `now` 参与两类判断（**可注入**，测试靠它钉住跨年行为）：
    /// 1. 月日缺年时按 `now` 所在年补；
    /// 2. 补出来的日期明显晚于 `now`（> now + 1 天）时回滚一年 ——
    ///    1 月导入 12 月小票不会被记成 11 个月后的未来。
    public static func extract(from text: String, now: Date = .now) -> Date? {
        let calendar = Calendar.current

        // 优先匹配电商/支付截图里的显式下单、付款、成交、创建时间
        let labeledPatterns: [(pattern: String, hasYear: Bool)] = [
            ("(?:付款时间|支付时间|成交时间|下单时间|创建时间|交易时间)\\s*[:：]?\\s*(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?\\s*(\\d{1,2}):(\\d{2})", true),
            ("(?:付款时间|支付时间|成交时间|下单时间|创建时间|交易时间)\\s*[:：]?\\s*(\\d{1,2})月(\\d{1,2})日\\s*(\\d{1,2}):(\\d{2})", false)
        ]
        for item in labeledPatterns {
            if let regex = try? NSRegularExpression(pattern: item.pattern),
               let comps = dateComponents(regex, in: text, hasYear: item.hasYear) {
                // 一旦匹配就以该精度为准：非法（2024-02-31 / 25:99）直接判无效，
                // 不再退到更粗的「仅日期」模式去「猜」一个看起来合法的日期。
                return validatedDate(comps, hasYear: item.hasYear, calendar: calendar, now: now)
            }
        }

        // 完整日期/月日型，按精度从高到低尝试
        let patterns: [(pattern: String, hasYear: Bool)] = [
            ("(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?\\s*(\\d{1,2}):(\\d{2})", true),
            ("(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})日?", true),
            ("(\\d{1,2})月(\\d{1,2})日\\s*(\\d{1,2}):(\\d{2})", false),
            ("(\\d{1,2})月(\\d{1,2})日", false)
        ]
        for item in patterns {
            if let regex = try? NSRegularExpression(pattern: item.pattern),
               let comps = dateComponents(regex, in: text, hasYear: item.hasYear) {
                return validatedDate(comps, hasYear: item.hasYear, calendar: calendar, now: now)
            }
        }
        return nil
    }

    private static func dateComponents(_ regex: NSRegularExpression, in text: String, hasYear: Bool) -> DateComponents? {
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        func captured(_ index: Int) -> Int? {
            guard index < match.numberOfRanges,
                  match.range(at: index).location != NSNotFound,
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
        return comps
    }

    /// 构造并校验日期。
    ///
    /// - 范围校验：月 1–12、日 1–31、时 0–23、分 0–59；
    /// - **回写比对**：拒绝 `2024-02-31` / `2024-13-45` / `25:99` 这类会被日历静默顺延的非法值
    ///   （与 `BatchCSVImport.parseDay` 的判据保持一致）；
    /// - 缺年时按 `now` 所在年补，缺时补 12 点（沿用旧语义）；
    /// - 月日型结果晚于 `now + 1 天` 时回滚一年。
    private static func validatedDate(
        _ comps: DateComponents,
        hasYear: Bool,
        calendar: Calendar,
        now: Date
    ) -> Date? {
        var components = comps
        if components.year == nil { components.year = calendar.component(.year, from: now) }
        if components.hour == nil { components.hour = 12 }

        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        if let hour = components.hour, !(0...23).contains(hour) { return nil }
        if let minute = components.minute, !(0...59).contains(minute) { return nil }

        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard roundTrip.year == components.year,
              roundTrip.month == components.month,
              roundTrip.day == components.day,
              // minute 在「仅日期」模式下是 nil，不能拿 Optional 与 Int 直接比
              components.hour == nil || roundTrip.hour == components.hour,
              components.minute == nil || roundTrip.minute == components.minute else { return nil }

        guard !hasYear else { return date }
        if date > now.addingTimeInterval(24 * 60 * 60) {
            var rolledBack = components
            rolledBack.year = year - 1
            return calendar.date(from: rolledBack)
        }
        return date
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
        let date = TransactionDateExtractor.extract(from: text, now: now) ?? now

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
    /// 针对淘宝、京东、拼多多、外卖及线下小票采用分级优先级策略：
    /// 1. 优先提取「实付款/实付金额/实际支付/在线支付」等实际扣款额（排除原价与满减干扰）；
    /// 2. 其次提取「合计/总计/应付/实收」；
    /// 3. 最后提取「订单金额/订单总额/商品总价/小计」。
    public static func extractLabeledTotalAmount(from text: String) -> Double? {
        // 第一优先级：实际支付金额（最准确反映用户钱包实际支出的金额）
        let paidPatterns = [
            "(?:实付款|实付金额|实付|实际支付|实际付款|需付款|付款金额|在线支付|微信支付|支付宝支付|支付宝付款|支付成功)(?:金额)?\\s*[:：]?\\s*[¥￥$]?\\s*\(amountNumberPattern)",
            "[¥￥$]\\s*\(amountNumberPattern)\\s*(?:元)?\\s*(?:实付款|实付金额|实付|实际支付|实际付款|需付款)",
            "(?:实付款|实付金额|实付|实际支付|需付款)\\s*[¥￥$]?\\s*\(amountNumberPattern)"
        ]
        if let amt = matchFirstAmount(in: text, patterns: paidPatterns) {
            return amt
        }

        // 第二优先级：合计 / 账单总额 / 应付
        let totalPatterns = [
            "(?:合计|总计|应付|应付金额|实收|消费金额|账单金额|结算金额|TOTAL|Total|PAID)(?:金额)?\\s*[:：]?\\s*[¥￥$]?\\s*\(amountNumberPattern)",
            "[¥￥$]\\s*\(amountNumberPattern)\\s*(?:元)?\\s*(?:合计|总计|应付|实收)",
            "(?:合计|总计|应付|实收)(?:金额)?\\s*[¥￥$]?\\s*\(amountNumberPattern)"
        ]
        if let amt = matchFirstAmount(in: text, patterns: totalPatterns) {
            return amt
        }

        // 第三优先级：订单金额 / 商品总额 / 小计
        let orderPatterns = [
            "(?:订单金额|订单总额|订单总价|商品总额|商品总价|商品金额|交易金额|总额|总价|小计)(?:金额)?\\s*[:：]?\\s*[¥￥$]?\\s*\(amountNumberPattern)"
        ]
        if let amt = matchFirstAmount(in: text, patterns: orderPatterns) {
            return amt
        }

        return nil
    }

    private static func matchFirstAmount(in text: String, patterns: [String]) -> Double? {
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
            "[¥￥$]\\s*\(amountNumberPattern)",
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

    /// 从文本中提取商户名、店铺名或商品名称（兼容实体小票与淘宝/京东等购物订单截图）
    public static func extractMerchantOrTitle(from text: String) -> String {
        // 1. 尝试匹配显式的商户/店铺/品名/收款方标签（避免误匹配「商品总价」「店铺优惠」）
        let labeledPatterns = [
            "(?:商品名称|商品全称|品名|货物名称)\\s*[:：]?\\s*([^\\n\\r]{2,35})",
            "(?:商户全称|商户名称|门店名称|收款商户|收款方)\\s*[:：]?\\s*([^\\n\\r]{2,30})",
            "(?:商户|门店|店铺|商品)\\s*[:：]\\s*([^\\n\\r]{2,30})",
            "欢迎光临\\s*([^\\n\\r]{2,25})"
        ]
        for pattern in labeledPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.range(at: 1).location != NSNotFound,
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                let isPrice = candidate.range(of: "^[¥￥$\\-0-9. +]+$", options: .regularExpression) != nil
                let isNoise = candidate.contains("详情") || candidate.contains("优惠") || candidate.contains("满减") || candidate.contains("总价") || candidate.contains("总额")
                if !candidate.isEmpty && !isPrice && !isNoise { return candidate }
            }
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let ignoreKeywords = [
            "结账单", "收银单", "销售小票", "发票", "存根", "POS签购单", "明细", "小票", "小票消费", "欢迎光临", "交易凭条",
            "订单详情", "交易详情", "账单详情", "订单状态", "交易成功", "交易完成", "买家已付款", "卖家已发货", "等待发货", "待发货", "待付款",
            "待收货", "待评价", "已完成", "交易关闭", "退款成功", "售后中", "已送达", "配送中", "支付成功", "淘宝", "手机淘宝",
            "天猫", "京东", "京东商城", "拼多多", "唯品会", "抖音", "抖音电商", "快手", "美团", "饿了么", "微信支付", "支付宝",
            "复制", "查看物流", "申请售后", "评价", "再来一单", "加入购物车", "再次购买", "确认收货", "修改地址", "退换", "价保",
            "商品总价", "商品总额", "店铺优惠", "红包抵扣", "运费", "配送费", "实付款", "需付款", "应付款", "实付金额", "支付金额",
            "收货地址", "收货人", "下单时间", "付款时间", "创建时间", "成交时间", "订单编号", "订单号", "交易单号", "支付方式",
            "中国移动", "中国联通", "中国电信", "7天无理由退货", "七天无理由退货"
        ]

        let shopKeywords = ["旗舰店", "专卖店", "专营店", "自营", "官方店", "直营店", "天猫超市", "京东超市", "企业店"]
        var detectedShop: String? = nil
        var detectedProduct: String? = nil

        for line in lines.prefix(15) {
            var cleanedLine = line
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "＞", with: "")
                .replacingOccurrences(of: "进店", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let labelPrefixes = ["商户全称", "商户名称", "门店名称", "店铺名称", "收款商户", "收款方", "商品名称", "商品全称", "商品"]
            for prefix in labelPrefixes {
                if cleanedLine.hasPrefix(prefix) {
                    cleanedLine = String(cleanedLine.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: ":： ").union(.whitespacesAndNewlines))
                    break
                }
            }

            guard cleanedLine.count >= 2, cleanedLine.count <= 40 else { continue }
            let isPureDigitsOrSymbols = cleanedLine.range(of: "^[0-9\\-—*#:=. /¥￥$]+$", options: .regularExpression) != nil
            guard !isPureDigitsOrSymbols else { continue }
            let isExactIgnore = ignoreKeywords.contains { cleanedLine == $0 }
            guard !isExactIgnore else { continue }

            // 检测电商店铺名
            if detectedShop == nil && shopKeywords.contains(where: { cleanedLine.contains($0) }) {
                detectedShop = cleanedLine
                continue
            }

            // 检测商品品名
            let containsIgnore = ignoreKeywords.contains { cleanedLine.contains($0) }
            let isPriceOrCountLine = cleanedLine.range(of: "^[¥￥$0-9.xX× +\\-]+$", options: .regularExpression) != nil
            if !containsIgnore && !isPriceOrCountLine {
                if detectedProduct == nil && cleanedLine.count >= 3 {
                    detectedProduct = cleanedLine
                }
            }
        }

        // 电商场景优先整合店铺与商品信息
        if let shop = detectedShop, let prod = detectedProduct {
            if shop.count + prod.count <= 28 {
                return "\(shop) - \(prod)"
            } else if shop == "京东自营" || shop == "天猫超市" {
                return prod.count <= 25 ? "\(shop) - \(prod)" : prod
            } else {
                return prod.count <= 25 ? prod : shop
            }
        } else if let prod = detectedProduct {
            return prod
        } else if let shop = detectedShop {
            return shop
        }

        // 3. 常规前几行兜底提取
        for line in lines.prefix(6) {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count >= 2 && cleaned.count <= 25 {
                let isIgnore = ignoreKeywords.contains { cleaned.contains($0) }
                let isPureDigitsOrSymbols = cleaned.range(of: "^[0-9\\-—*#:=. /¥￥$]+$", options: .regularExpression) != nil
                if !isIgnore && !isPureDigitsOrSymbols {
                    return cleaned
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
                "萨莉亚", "达美乐", "烧烤", "麻辣烫", "小吃", "早餐", "午餐", "晚餐", "零食",
                "坚果", "巧克力", "糖果", "饼干", "蛋糕", "酸奶", "牛奶", "速食", "方便面",
                "生鲜", "水果", "海鲜", "牛排", "大米", "食用油", "粮油", "淘宝买菜", "美团买菜"
            ]),
            ("居家日用", [
                "超市", "便利店", "生鲜", "百货", "果蔬", "菜场", "粮油", "日用", "全家", "罗森",
                "7-11", "7-ELEVEN", "大润发", "沃尔玛", "永辉", "盒马", "物美", "华润万家",
                "家乐福", "屈臣氏", "名创优品", "便利蜂", "杂货", "菜市", "百联", "天猫超市",
                "京东超市", "山姆", "纸巾", "抽纸", "卷纸", "湿巾", "洗衣液", "洗洁精", "洗发水",
                "沐浴露", "牙膏", "牙刷", "毛巾", "垃圾袋", "保鲜膜", "清洁剂", "抹布", "拖把",
                "收纳盒", "收纳箱", "水杯", "保温杯", "餐具", "四件套", "床单", "被套"
            ]),
            ("交通出行", [
                "加油", "中石化", "中石油", "中国海油", "加气", "充电桩", "停车", "收费站", "高速",
                "滴滴", "出租车", "打车", "地铁", "公交", "ETC", "铁路", "客运", "高德打车"
            ]),
            ("医疗健康", [
                "药房", "药店", "大药房", "同仁堂", "海王星辰", "益丰", "国大", "老百姓", "一心堂",
                "医院", "门诊", "诊所", "体检", "卫生院", "口腔", "眼科", "处方", "挂号",
                "阿里健康", "京东大药房", "口罩", "体温计", "棉签", "碘伏", "创口贴", "维生素", "感冒药", "退烧药"
            ]),
            ("休闲娱乐", [
                "影城", "影院", "电影", "万达影城", "大地影院", "KTV", "密室", "剧本杀", "乐园",
                "游乐", "网吧", "电竞", "健身", "游泳", "保龄球", "桌游"
            ]),
            ("数码家电", [
                "数码", "手机", "电脑", "专卖店", "Apple", "苹果", "华为", "小米", "OPPO",
                "vivo", "大疆", "联想", "电子产品", "苏宁易购", "京东电器", "天猫电器", "iPhone",
                "iPad", "MacBook", "笔记本", "耳机", "无线鼠标", "鼠标", "机械键盘", "键盘",
                "充电宝", "移动电源", "充电器", "数据线", "智能手环", "显卡", "显示器", "电饭煲",
                "吹风机", "剃须刀", "音箱", "摄像头", "路由器", "小家电"
            ]),
            ("宠物萌宠", [
                "宠物", "萌宠", "猫粮", "狗粮", "宠物医院", "宠物洗护", "猫砂", "猫罐头", "狗罐头",
                "猫条", "冻干", "猫抓板", "逗猫棒", "牵引绳", "猫窝", "狗窝"
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
