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

    /// 语音/OCR 文本归一化：剥千分位逗号、统一口语金额单位与小数点。
    public static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commaRegex = thousandsCommaRegex {
            value = commaRegex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
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

        if let regex = chineseAmountRegex,
           let match = regex.firstMatch(in: text, range: fullRange),
           let range = Range(match.range(at: 1), in: text),
           let value = numberValue(String(text[range])), value > 0 {
            return value
        }

        // 口语与外币中文金额："二十五块五"、"12块5毛"、"一千五百日元"、"三十美元"
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

        // "花了/付了/用去/收入/支出/消费/为/是 38.5" 或外币符号/代码 "$38.5"、"1200日元"
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

    /// 中文数字转值，支持十/百/千/万。
    public static func numberValue(_ value: String) -> Double? {
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