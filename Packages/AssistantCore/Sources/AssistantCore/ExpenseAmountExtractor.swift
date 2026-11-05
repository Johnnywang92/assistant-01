import Foundation

/// 一句话记账的**金额提取**纯逻辑。
///
/// 为什么独立于 App target：金额解析一旦出错是静默的数据损坏（记进去的数字是错的，
/// 用户很难立刻发现），必须有单元测试兜底。该文件只依赖 Foundation，可直接 `swift test`。
///
/// 两条必须守住的约束（均由线上 bug 演化而来，改动前先读测试）：
///
/// 1. **口语金额正则的数字部分必须支持小数，且首尾都要有边界断言。**
///    写成 `([0-9]+|中文数字)\s*元` 时，"花了1234.56元" 会回溯成只捕获 "56"——
///    因为 `[0-9]+` 吃掉 "1234" 后遇到 "." 无法继续，回溯到 "56" 再接 "元" 成功。
///    结果就是用户反馈的「只记录最后两位数字」。
/// 2. **千分位逗号的正则不能用 `\b` 收尾。**
///    `\b` 是「单词字符↔非单词字符」边界，而汉字属于单词字符，
///    所以 "1,250元" 里逗号后的 `\b` 不成立，逗号没被剥掉，金额被截成 "250"。
///    应改用 `(?![0-9])`（后面不能再跟数字）来界定分组结束。
public enum ExpenseAmountExtractor {

    // MARK: - 文本归一化

    private static let thousandsCommaRegex = try? NSRegularExpression(pattern: "(?<=[0-9]),(?=[0-9]{3}(?![0-9]))")
    private static let whitespaceCollapseRegex = try? NSRegularExpression(pattern: "\\s+")

    private static let replacements: [String: String] = [
        "元钱": "元", "圆": "元", "园": "元", "块 q": "块", "块钱": "块",
        "人民币": "元", "点": ".", "．": "."
    ]

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]

    /// 中文小数金额：「九点五元」「三十八点五元」。
    ///
    /// 归一化会把「点」替换成「.」，但所有正则的数字分支只认阿拉伯小数，
    /// 于是「九点五元」会退化成「九.五元」，被中文整数正则截成 9。
    /// 所以在替换「点」之前，先把「中文整数点中文小数 + 货币单位」整体转成阿拉伯小数。
    /// 必须带货币单位前瞻：否则「下午三点半」这类时间表达会被误当成金额。
    private static let chineseDecimalRegex = try? NSRegularExpression(
        pattern: "([零〇一二两三四五六七八九十百千万]+)点([零〇一二两三四五六七八九十]+)(?=\\s*(?:元钱|圆|园|人民币|日元|日币|美元|美金|欧元|港币|港元|韩元|泰铢|英镑|新币|新台币|澳元|加元|瑞郎|澳门元|元|块))"
    )

    /// 把「中文整数点中文小数」的字面量转换成阿拉伯小数（仅限后面跟货币单位时）。
    private static func convertChineseDecimals(in text: String) -> String {
        guard let regex = chineseDecimalRegex, !text.isEmpty else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            guard let whole = numberValue(nsText.substring(with: match.range(at: 1))),
                  whole >= 0 else { continue }
            let fractionText = nsText.substring(with: match.range(at: 2))
            let fractionDigits = fractionText.compactMap { chineseDigits[$0] }.map(String.init).joined()
            guard !fractionDigits.isEmpty else { continue }
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "\(Int(whole)).\(fractionDigits)"
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// 语音/OCR 文本归一化：剥千分位逗号、把中文小数金额数字化、统一口语金额单位与小数点。
    public static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commaRegex = thousandsCommaRegex {
            value = commaRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
        // 必须在下面「点 → .」替换之前做，否则中文小数会被拆成两段。
        value = convertChineseDecimals(in: value)
        for (from, to) in replacements {
            value = value.replacingOccurrences(of: from, with: to)
        }
        if let wsRegex = whitespaceCollapseRegex {
            value = wsRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        }
        return value
    }

    // MARK: - 金额正则

    /// 中文数字金额：「花了一百二十三」
    private static let chineseAmountRegex = try? NSRegularExpression(
        pattern: "(?:花了|付了|收入|进账|到账|工资|奖金|支出|消费|共计|借出)\\s*([零〇一二两三四五六七八九十百千万]+)"
    )

    /// 口语金额：「35块5毛」「一百五十日元」「12.80块」。
    /// 数字部分支持小数；`(?<![0-9.．])` / `(?![0-9])` 防止从长数字里截取片段。
    private static let spokenAmountRegex = try? NSRegularExpression(
        pattern: "(?<![0-9.．])([0-9]+(?:[.．][0-9]{1,})?|[零〇一二两三四五六七八九十百千万]+)(?![0-9])\\s*(?:日元|日币|日圓|円|美元|美金|美刀|刀|欧元|欧|港币|港元|韩元|韩币|泰铢|铢|英镑|镑|新币|新加坡元|新元|新台币|台币|林吉特|马币|令吉|澳元|澳币|加元|加币|瑞郎|瑞士法郎|澳门元|葡币|元|块|块钱)\\s*([0-9]+(?![0-9])|[零〇一二两三四五六七八九十]+(?![零〇一二两三四五六七八九十]))?\\s*(?:毛|角)?"
    )

    /// 只有角分的金额：「九毛五」= 0.95、「五毛」= 0.5。
    /// 必须排在中文整数正则之前，否则「花了九毛五」会先被中文正则截成 9。
    private static let jiaoAmountRegex = try? NSRegularExpression(
        pattern: "(?<![0-9.．])([0-9]+|[零〇一二两三四五六七八九十]+)\\s*(?:毛|角)\\s*([0-9]+|[零〇一二两三四五六七八九十]+)?(?![0-9])"
    )

    /// 阿拉伯数字金额，按语义优先级排列（越靠前越可信）。
    private static let numericAmountRegexes: [NSRegularExpression] = {
        let patterns = [
            "(?:花了|付了|用去|支出|消费|收入|进账|共计|为|是|买.*?花了?|借出|spent|paid|cost|earned|received)\\s*(?:JP[¥￥]|HK\\$|NT\\$|US\\$|MOP\\$|S\\$|A\\$|C\\$|RM|CHF|[¥￥\\$€£₩฿])?\\s*([0-9]+(?:[.．][0-9]{1,2})?)",
            "([0-9]+(?:[.．][0-9]{1,2})?)\\s*(?:日元|日币|日圓|円|JPY|yen|美元|美金|美刀|刀|USD|dollars?|bucks?|欧元|欧|EUR|euros?|港币|港元|HKD|韩元|韩币|KRW|won|泰铢|铢|THB|baht|英镑|镑|GBP|pounds?|新币|新加坡元|新元|SGD|新台币|台币|TWD|NTD|林吉特|马币|令吉|MYR|澳元|澳币|AUD|加元|加币|CAD|瑞郎|瑞士法郎|CHF|澳门元|葡币|MOP|元|块钱|块|RMB|CNY|¥|yuan)",
            "(?:JP[¥￥]|HK\\$|NT\\$|US\\$|MOP\\$|S\\$|A\\$|C\\$|RM|CHF|[¥￥\\$€£₩฿])\\s*([0-9]+(?:[.．][0-9]{1,2})?)",
            "(?<![0-9.．])([0-9]+(?:[.．][0-9]{1,2})?)(?![0-9])"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    // MARK: - 合格金额（供多笔拆分使用）

    /// 合格金额 = 带货币单位/货币符号/消费动词的金额。裸数字（「3人」「24期」）不算，
    /// 否则多笔拆分会把人数/期数误当成一笔消费的金额。
    /// 匹配范围覆盖整个金额 token（含口语小数尾「10块9」），供拆分切点使用。
    private static let qualifiedAmountRegexes: [NSRegularExpression] = {
        let patterns = [
            // 口语金额（与 spokenAmountRegex 同构，整体作切点）
            "(?<![0-9.．])([0-9]+(?:[.．][0-9]{1,})?|[零〇一二两三四五六七八九十百千万]+)(?![0-9])\\s*(?:日元|日币|日圓|円|美元|美金|美刀|刀|欧元|欧|港币|港元|韩元|韩币|泰铢|铢|英镑|镑|新币|新加坡元|新元|新台币|台币|林吉特|马币|令吉|澳元|澳币|加元|加币|瑞郎|瑞士法郎|澳门元|葡币|元|块|块钱)\\s*([0-9]+(?![0-9])|[零〇一二两三四五六七八九十]+(?![零〇一二两三四五六七八九十]))?\\s*(?:毛|角)?",
            // 货币符号金额
            "(?:JP[¥￥]|HK\\$|NT\\$|US\\$|MOP\\$|S\\$|A\\$|C\\$|RM|CHF|[¥￥\\$€£₩฿])\\s*([0-9]+(?:[.．][0-9]{1,})?)",
            // 消费动词 + 金额（中文数字或阿拉伯）
            "(?:花了|付了|用去|支出|消费|收入|进账|共计|借出|spent|paid|cost|earned|received)\\s*(?:JP[¥￥]|HK\\$|NT\\$|US\\$|MOP\\$|S\\$|A\\$|C\\$|RM|CHF|[¥￥\\$€£₩฿])?\\s*([0-9]+(?:[.．][0-9]{1,})?|[零〇一二两三四五六七八九十百千万]+)(?![0-9])\\s*(?:毛|角)?"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// 全文所有合格金额的匹配范围（按出现顺序，重叠区间已合并）。
    public static func qualifiedAmountNSRanges(in text: String) -> [NSRange] {
        let fullRange = NSRange(text.startIndex..., in: text)
        var raw: [NSRange] = []
        for regex in qualifiedAmountRegexes {
            raw.append(contentsOf: regex.matches(in: text, range: fullRange).map(\.range))
        }
        guard !raw.isEmpty else { return [] }
        let sorted = raw.sorted { $0.location < $1.location }
        var merged: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.location < last.location + last.length {
                let end = max(last.location + last.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// 是否存在合格金额。
    public static func hasQualifiedAmount(_ text: String) -> Bool {
        !qualifiedAmountNSRanges(in: text).isEmpty
    }

    // MARK: - 提取入口

    /// 从一句话中提取金额（原始单位，不做币种折算）。
    /// - Returns: 金额；无法识别时返回 nil。
    public static func extract(from rawText: String) -> Double? {
        extractAmount(from: normalize(rawText))
    }

    /// 从**已归一化**的文本中提取金额（原始单位，不做币种折算）。
    /// 公开此入口是为了让 App target 复用同一份实现，避免正则双份漂移。
    /// - Returns: 金额；无法识别时返回 nil。
    public static func extractAmount(from text: String) -> Double? {
        let fullRange = NSRange(text.startIndex..., in: text)

        // 1. 先跑**带货币单位**的金额（含角分）。
        //
        // 顺序不能反：「花了三百二十八块五毛」里中文整数正则会先命中「三百二十八」
        // 并直接 return 328，后面的「块五毛」永远轮不到 —— 用户少记 0.5 元且无提示。
        if let regex = spokenAmountRegex,
           let match = regex.firstMatch(in: text, range: fullRange),
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

        // 2. 只有角分：「花了九毛五」= 0.95、「五毛」= 0.5。
        if let regex = jiaoAmountRegex,
           let match = regex.firstMatch(in: text, range: fullRange),
           let jiaoRange = Range(match.range(at: 1), in: text),
           let jiao = numberValue(String(text[jiaoRange])) {
            var value = jiao / 10
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
               let fenRange = Range(match.range(at: 2), in: text),
               let fen = numberValue(String(text[fenRange])) {
                value += fen / 100
            }
            if value > 0 { return value }
        }

        // 3. 无单位的纯中文数字：「花了一百二十三」。
        if let regex = chineseAmountRegex,
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text),
           let value = numberValue(String(text[range])), value > 0 {
            return value
        }

        // 4. "花了/付了/用去/收入/支出/消费/为/是 38.5" 或外币符号/代码 "$38.5"、"1200日元"
        for regex in numericAmountRegexes {
            if let match = regex.firstMatch(in: text, range: fullRange),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                if let val = Double(text[range].replacingOccurrences(of: "．", with: ".")), val > 0 {
                    return val
                }
            }
        }
        return nil
    }

    /// 中文数字转值（统一实现见 `ChineseNumeralParser`；保留本入口供 App 侧复用）。
    public static func numberValue(_ value: String) -> Double? {
        ChineseNumeralParser.value(value)
    }
}