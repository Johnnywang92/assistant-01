import Foundation

/// 记账支持币种（含出国游常用外币及人民币折算能力）
public enum ExpenseCurrency: String, Codable, CaseIterable, Identifiable, Sendable {
    case cny = "CNY" // 人民币
    case jpy = "JPY" // 日元
    case usd = "USD" // 美元
    case eur = "EUR" // 欧元
    case hkd = "HKD" // 港币
    case krw = "KRW" // 韩元
    case thb = "THB" // 泰铢
    case gbp = "GBP" // 英镑
    case sgd = "SGD" // 新币
    case twd = "TWD" // 新台币
    case myr = "MYR" // 马来西亚林吉特
    case aud = "AUD" // 澳元
    case cad = "CAD" // 加元
    case chf = "CHF" // 瑞士法郎
    case mop = "MOP" // 澳门元

    public var id: String { rawValue }

    /// 偏好记账币种存储键（出国游期间可一键切换默认币种）
    public static let preferredCurrencyKey = "expense_preferred_currency"
    /// 最近一次同步实时汇率的时间戳键
    public static let rateLastUpdatedKey = "expense_exchange_rate_updated_at"

    public var customRateDefaultsKey: String {
        "expense_exchange_rate_\(rawValue)"
    }

    public var chineseName: String {
        switch self {
        case .cny: return "人民币"
        case .jpy: return "日元"
        case .usd: return "美元"
        case .eur: return "欧元"
        case .hkd: return "港币"
        case .krw: return "韩元"
        case .thb: return "泰铢"
        case .gbp: return "英镑"
        case .sgd: return "新币"
        case .twd: return "新台币"
        case .myr: return "林吉特"
        case .aud: return "澳元"
        case .cad: return "加元"
        case .chf: return "瑞郎"
        case .mop: return "澳门元"
        }
    }

    public var englishName: String {
        switch self {
        case .cny: return "Chinese Yuan"
        case .jpy: return "Japanese Yen"
        case .usd: return "US Dollar"
        case .eur: return "Euro"
        case .hkd: return "HK Dollar"
        case .krw: return "Korean Won"
        case .thb: return "Thai Baht"
        case .gbp: return "British Pound"
        case .sgd: return "Singapore Dollar"
        case .twd: return "New Taiwan Dollar"
        case .myr: return "Malaysian Ringgit"
        case .aud: return "Australian Dollar"
        case .cad: return "Canadian Dollar"
        case .chf: return "Swiss Franc"
        case .mop: return "Macanese Pataca"
        }
    }

    public var symbol: String {
        switch self {
        case .cny: return "¥"
        case .jpy: return "JP¥"
        case .usd: return "$"
        case .eur: return "€"
        case .hkd: return "HK$"
        case .krw: return "₩"
        case .thb: return "฿"
        case .gbp: return "£"
        case .sgd: return "S$"
        case .twd: return "NT$"
        case .myr: return "RM"
        case .aud: return "A$"
        case .cad: return "C$"
        case .chf: return "CHF"
        case .mop: return "MOP$"
        }
    }

    public var flag: String {
        switch self {
        case .cny: return "🇨🇳"
        case .jpy: return "🇯🇵"
        case .usd: return "🇺🇸"
        case .eur: return "🇪🇺"
        case .hkd: return "🇭🇰"
        case .krw: return "🇰🇷"
        case .thb: return "🇹🇭"
        case .gbp: return "🇬🇧"
        case .sgd: return "🇸🇬"
        case .twd: return "🇹🇼"
        case .myr: return "🇲🇾"
        case .aud: return "🇦🇺"
        case .cad: return "🇨🇦"
        case .chf: return "🇨🇭"
        case .mop: return "🇲🇴"
        }
    }

    /// 离线内置参考汇率（1 外币 = X 人民币）
    public var defaultRateToCNY: Double {
        switch self {
        case .cny: return 1.0
        case .jpy: return 0.0470
        case .usd: return 7.20
        case .eur: return 7.80
        case .hkd: return 0.92
        case .krw: return 0.0052
        case .thb: return 0.21
        case .gbp: return 9.15
        case .sgd: return 5.35
        case .twd: return 0.22
        case .myr: return 1.62
        case .aud: return 4.70
        case .cad: return 5.20
        case .chf: return 8.15
        case .mop: return 0.90
        }
    }

    /// 当前生效汇率（优先读取用户自定义或在线同步汇率，否则回退离线参考汇率）
    public func currentRateToCNY(in defaults: UserDefaults = .standard) -> Double {
        guard self != .cny else { return 1.0 }
        if let custom = defaults.object(forKey: customRateDefaultsKey) as? Double, custom > 0 {
            return custom
        }
        return defaultRateToCNY
    }

    public var currentRateToCNY: Double {
        currentRateToCNY(in: .standard)
    }

    public func hasCustomRate(in defaults: UserDefaults = .standard) -> Bool {
        guard self != .cny else { return false }
        if let custom = defaults.object(forKey: customRateDefaultsKey) as? Double, custom > 0 {
            return abs(custom - defaultRateToCNY) > 0.000001
        }
        return false
    }

    public func setCustomRateToCNY(_ rate: Double, in defaults: UserDefaults = .standard) {
        guard self != .cny, rate > 0 else { return }
        defaults.set(rate, forKey: customRateDefaultsKey)
    }

    public func resetRateToDefault(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: customRateDefaultsKey)
    }

    /// 当前用户偏好的默认记账币种（默认 CNY；出国游时可切换为当地币种）
    public static func preferred(in defaults: UserDefaults = .standard) -> ExpenseCurrency {
        guard let raw = defaults.string(forKey: preferredCurrencyKey),
              let currency = ExpenseCurrency(rawValue: raw) else {
            return .cny
        }
        return currency
    }

    public static func setPreferred(_ currency: ExpenseCurrency, in defaults: UserDefaults = .standard) {
        defaults.set(currency.rawValue, forKey: preferredCurrencyKey)
    }

    /// 外币折算为人民币（保留 2 位小数）
    public func convertToCNY(_ foreignAmount: Double, rate: Double? = nil) -> Double {
        let clean = abs(foreignAmount)
        guard self != .cny else {
            return (clean * 100).rounded() / 100
        }
        let candidateRate = rate ?? currentRateToCNY
        let effectiveRate = candidateRate > 0 ? candidateRate : defaultRateToCNY
        return ((clean * effectiveRate) * 100).rounded() / 100
    }

    /// 格式化原币金额（如 "JP¥1500"、"$25.50"）
    public func formatAmount(_ value: Double) -> String {
        let clean = abs(value)
        if abs(clean - clean.rounded()) < 0.005 {
            return "\(symbol)\(String(format: "%.0f", clean))"
        }
        return "\(symbol)\(String(format: "%.2f", clean))"
    }

    /// 格式化汇率可读说明（针对日元/韩元自动补充百元/千元对照）
    public func rateDisplayString(rate: Double? = nil) -> String {
        guard self != .cny else { return "1 CNY = ¥1.00" }
        let candidate = rate ?? currentRateToCNY
        let r = candidate > 0 ? candidate : defaultRateToCNY
        switch self {
        case .jpy:
            return String(format: "100 JPY ≈ ¥%.2f（1 JPY = %.4f CNY）", r * 100, r)
        case .krw:
            return String(format: "1000 KRW ≈ ¥%.2f（1 KRW = %.4f CNY）", r * 1000, r)
        case .thb, .twd:
            return String(format: "100 %@ ≈ ¥%.1f（1 %@ = %.3f CNY）", rawValue, r * 100, rawValue, r)
        default:
            return String(format: "1 %@ ≈ ¥%.2f CNY", rawValue, r)
        }
    }

    /// 汇率输入框默认格式化字符串
    public func formatRateInput(_ rate: Double? = nil) -> String {
        let candidate = rate ?? currentRateToCNY
        let r = candidate > 0 ? candidate : defaultRateToCNY
        if r < 0.01 {
            return String(format: "%.5f", r)
        } else if r < 1.0 {
            return String(format: "%.4f", r)
        } else {
            return String(format: "%.3f", r)
        }
    }

    /// 在线拉取最新人民币基准汇率（失败时静默返回 false，不影响离线使用）
    @discardableResult
    public static func refreshOnlineRates(in defaults: UserDefaults = .standard) async -> Bool {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/CNY") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = json["rates"] as? [String: Double] else {
                return false
            }
            var updatedCount = 0
            for currency in ExpenseCurrency.allCases where currency != .cny {
                if let perCNY = rates[currency.rawValue], perCNY > 0 {
                    let toCNY = 1.0 / perCNY
                    currency.setCustomRateToCNY(toCNY, in: defaults)
                    updatedCount += 1
                }
            }
            if updatedCount > 0 {
                defaults.set(Date().timeIntervalSince1970, forKey: rateLastUpdatedKey)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - 自然语言与小票文本币种识别

    private static let compiledForeignPatterns: [(ExpenseCurrency, NSRegularExpression)] = {
        let rawPatterns: [(ExpenseCurrency, String)] = [
            (.jpy, #"(?:JP[¥￥]|日元|日币|日圓|円|\bJPY\b|yen\b|税込|税抜)"#),
            (.hkd, #"(?:HK\$|港币|港元|\bHKD\b)"#),
            (.twd, #"(?:NT\$|新台币|台币|台幣|\bTWD\b|\bNTD\b)"#),
            (.mop, #"(?:MOP\$|澳门元|澳门币|葡币|\bMOP\b)"#),
            (.sgd, #"(?:S\$|SG\$|新加坡元|新币|新元|\bSGD\b)"#),
            (.aud, #"(?:A\$|AU\$|澳元|澳币|\bAUD\b)"#),
            (.cad, #"(?:C\$|CA\$|加元|加币|\bCAD\b)"#),
            (.myr, #"(?:马币|林吉特|令吉|\bMYR\b|(?:^|[^\p{L}])RM\s*[0-9])"#),
            (.chf, #"(?:瑞士法郎|瑞郎|\bCHF\b)"#),
            (.krw, #"(?:₩|韩元|韩币|韓元|\bKRW\b|\bwon\b)"#),
            (.thb, #"(?:฿|泰铢|\bTHB\b|\bbaht\b|[0-9]+\s*铢)"#),
            (.gbp, #"(?:£|英镑|\bGBP\b|\bpounds?\b|[0-9]+\s*镑)"#),
            (.eur, #"(?:€|欧元|歐元|\bEUR\b|\beuros?\b|[0-9]+(?:\.[0-9]+)?\s*欧(?!洲|美|式|莱雅|舒丹))"#),
            (.usd, #"(?:US\$|美元|美金|美刀|\bUSD\b|\bdollars?\b|\bbucks?\b|[0-9]+(?:\.[0-9]+)?\s*刀(?!削|片|鱼|叉)|(?<![A-Za-z])\$(?=\s*[0-9]))"#)
        ]
        return rawPatterns.compactMap { currency, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (currency, regex)
        }
    }()

    private static let compiledCNYRegex: NSRegularExpression? = {
        let cnyPattern = #"(?:人民币|\bRMB\b|\bCNY\b|\byuan\b|(?<!JP)[¥￥]\s*[0-9]|[0-9零〇一二两三四五六七八九十百千万]+(?:\.[0-9]+)?\s*(?:元|块|块钱|毛|角))"#
        return try? NSRegularExpression(pattern: cnyPattern, options: [.caseInsensitive])
    }()

    /// 从文本中识别显式币种标记。
    /// - Returns: 若文本含明确外币或人民币单位，返回对应币种；若仅含裸数字无货币标记则返回 `nil`。
    public static func detectExplicitCurrency(in text: String) -> ExpenseCurrency? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)

        // 1. 先匹配多字符明确外币关键词与符号前缀（顺序从更具体到更通用，避免 "港币/日元/美元" 被 "元" 抢先匹配）
        for (currency, regex) in compiledForeignPatterns {
            if regex.firstMatch(in: trimmed, range: fullRange) != nil {
                return currency
            }
        }

        // 2. 匹配显式人民币关键词或符号
        if let regex = compiledCNYRegex,
           regex.firstMatch(in: trimmed, range: fullRange) != nil {
            return .cny
        }

        return nil
    }
}
