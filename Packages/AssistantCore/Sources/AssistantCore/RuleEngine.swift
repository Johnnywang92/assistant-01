import Foundation

/// 规则引擎：用正则从短信中提取快递、取件、流量信息。纯函数、无副作用、毫秒级。
public struct RuleEngine: Sendable {
    public var rules: RuleSet

    public init(rules: RuleSet = .default) {
        self.rules = rules
    }

    // MARK: - 入口

    /// 解析一条短信。
    /// - Parameters:
    ///   - text: 短信正文
    ///   - sender: 发件人号码（可选，快捷指令能拿到时传入）
    public func parse(_ text: String, sender: String? = nil) -> ParseOutcome {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return .ignored }

        let signature = Self.signature(of: normalized)
        let courier = detectCourier(in: normalized, signature: signature)
        let station = detectStation(in: normalized, signature: signature)
        let location = extractLocation(in: normalized)
        let codes = extractPickupCodes(in: normalized)

        // 去掉"如已取件请忽略"一类的免责语，避免把到件通知误判成已取件
        let cleaned = Regex.replace(rules.ignorePhrasePattern, in: normalized, with: "")

        // 1. 明确的"已取件"
        if Regex.matches(rules.pickedUpStrongPattern, in: cleaned) {
            return .pickedUp(PickupConfirmation(pickupCodes: codes, courier: courier, station: station, location: location))
        }
        // 2. 有取件码 → 到件通知
        if !codes.isEmpty {
            return .parcel(ParcelInfo(pickupCodes: codes, courier: courier, station: station, location: location))
        }
        // 3. "已签收"且没有取件码 → 视为已取件
        if Regex.matches(rules.pickedUpWeakPattern, in: cleaned) {
            return .pickedUp(PickupConfirmation(pickupCodes: [], courier: courier, station: station, location: location))
        }
        // 4. 流量
        if let usage = parseDataUsage(normalized, signature: signature, sender: sender) {
            return .dataUsage(usage)
        }
        // 5. 信用卡账单
        if let bill = parseCreditCardBill(normalized, signature: signature) {
            return .creditCardBill(bill)
        }
        // 6. 验证码 / 营销
        if Regex.matches(rules.verificationPattern, in: normalized) || Regex.matches(rules.marketingPattern, in: normalized) {
            return .ignored
        }
        return .unknown
    }

    // MARK: - 快递

    func extractPickupCodes(in text: String) -> [String] {
        var result: [String] = []
        for groups in Regex.allGroups(rules.pickupCodePattern, in: text) {
            guard let run = groups.first ?? nil else { continue }
            let parts = run
                .components(separatedBy: CharacterSet(charactersIn: "、,，和及/ "))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { Self.isPlausibleCode($0) }
            for p in parts where !result.contains(p) {
                result.append(p)
            }
        }
        return result
    }

    static func isPlausibleCode(_ s: String) -> Bool {
        let compact = s.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 3, compact.count <= 14 else { return false }
        return s.contains(where: \.isNumber)
    }

    func extractLocation(in text: String) -> String? {
        if let raw = Regex.firstGroup(rules.locationPattern, in: text) {
            return cleanLocation(raw)
        }
        // 兜底：匹配类似 "到/至/在 [地点] (取/提/领取/查收)"
        let fallbackPattern = "(?:已到达|已到|到达|送达|存入|放至|放入|放到|送至|已从|从|到|至|在)了?([^,。;!?\\s]{2,30}?)(?:取|提|领取|自提|查收)"
        if let raw = Regex.firstGroup(fallbackPattern, in: text) {
            return cleanLocation(raw)
        }
        return nil
    }

    private func cleanLocation(_ raw: String) -> String? {
        var loc = raw
        if let idx = loc.lastIndex(where: { "到至在入从".contains($0) }) {
            let after = String(loc[loc.index(after: idx)...])
            if after.count >= 2 { loc = after }
        }
        loc = loc.trimmingCharacters(in: CharacterSet(charactersIn: " 了的:"))
        return loc.count >= 2 ? loc : nil
    }

    func detectCourier(in text: String, signature: String?) -> String? {
        if let sig = signature, let c = rules.couriers.first(where: { sig.contains($0) }) {
            return c
        }
        return rules.couriers.first(where: { text.contains($0) })
    }

    func detectStation(in text: String, signature: String?) -> String? {
        if let sig = signature, let s = rules.stations.first(where: { sig.contains($0) }) {
            return s
        }
        return rules.stations.first(where: { text.contains($0) })
    }

    // MARK: - 流量

    func parseDataUsage(_ text: String, signature: String?, sender: String?) -> DataUsageInfo? {
        let op = detectOperator(signature: signature, sender: sender, text: text)
        guard text.contains("流量") || op != nil else { return nil }

        let remaining = Regex.firstGroups(rules.dataRemainingPattern, in: text).flatMap(Self.toMB)
        let used = Regex.firstGroups(rules.dataUsedPattern, in: text).flatMap(Self.toMB)
        let percent = Regex.firstGroup(rules.dataPercentPattern, in: text).flatMap(Double.init)

        guard remaining != nil || used != nil || percent != nil else { return nil }
        return DataUsageInfo(operatorName: op, remainingMB: remaining, usedMB: used, usedPercent: percent)
    }

    func detectOperator(signature: String?, sender: String?, text: String) -> String? {
        if let digits = sender?.filter(\.isNumber), let name = rules.operatorSenders[digits] {
            return name
        }
        let haystack = (signature ?? "") + text
        return rules.operatorKeywords.first(where: { haystack.contains($0.keyword) })?.name
    }

    static func toMB(_ groups: [String?]) -> Double? {
        guard groups.count >= 2, let numStr = groups[0], let value = Double(numStr), let unit = groups[1]?.uppercased() else {
            return nil
        }
        switch unit {
        case "GB", "G": return value * 1024
        case "MB", "M": return value
        case "KB", "K": return value / 1024
        case "TB", "T": return value * 1024 * 1024
        default: return nil
        }
    }

    // MARK: - 信用卡与账单

    func parseCreditCardBill(_ text: String, signature: String?) -> CreditCardBillInfo? {
        guard text.contains("信用卡") || text.contains("账单") || text.contains("还款") else { return nil }
        guard !text.contains("验证码") else { return nil }

        // 提取银行名称
        let bank = detectBank(text: text, signature: signature)
        guard bank != nil || text.contains("信用卡") else { return nil }

        // 提取卡号尾号（如 "尾号1234"、"卡号末四位1234"）
        let tail = Regex.firstGroup("(?:尾号|末四位|卡号末[4四]位|卡号[为是:：])\\s*([0-9]{4})", in: text)

        // 提取还款金额（如 "应还金额1234.56元"、"账单金额为人民币1234.56元"、"应还款1234.56"）
        let amountStr = Regex.firstGroup("(?:应还(?:款|金额)?|本期账单(?:金额)?|账单金额|人民币)(?:为|:)?\\s*([0-9]+(?:\\.[0-9]{1,2})?)\\s*(?:元)?", in: text)
        let amount = amountStr.flatMap(Double.init)

        // 提取还款日（如 "到期还款日为10月25日"、"还款日10月25日"、"请于10月25日前还款"）
        let dueDate = Regex.firstGroup("(?:到期还款日|还款日|还款截止日|请于)\\s*(?:为|:)?\\s*([0-9]{1,2}月[0-9]{1,2}日|[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2})", in: text)

        // 提取最低还款额（可选）
        let minStr = Regex.firstGroup("(?:最低还款(?:额)?)(?:为|:)?\\s*([0-9]+(?:\\.[0-9]{1,2})?)\\s*(?:元)?", in: text)
        let minAmount = minStr.flatMap(Double.init)

        guard amount != nil || dueDate != nil else { return nil }
        return CreditCardBillInfo(bankName: bank, cardTail: tail, amount: amount, dueDateString: dueDate, minPayment: minAmount)
    }

    func detectBank(text: String, signature: String?) -> String? {
        let banks = ["招商银行", "建设银行", "工商银行", "中国银行", "农业银行", "交通银行", "浦发银行", "中信银行", "民生银行", "光大银行", "平安银行", "兴业银行", "广发银行", "邮储银行", "招行", "建行", "工行", "中行", "农行", "交行"]
        let haystack = (signature ?? "") + text
        return banks.first(where: { haystack.contains($0) })
    }

    // MARK: - 工具

    /// 全角 ASCII（！到～）转半角、全角空格转半角、换行转空格。
    /// 不用系统的 fullwidthToHalfwidth，因为它会把 "。" "、" 也转成半角片假名标点。
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.value {
            case 0xFF01...0xFF5E:
                scalars.append(Unicode.Scalar(s.value - 0xFEE0)!)
            case 0x3000, 0x0A, 0x0D, 0x09:
                scalars.append(" ")
            case 0x2014, 0x2013, 0x2212: // — – − 统一成 -
                scalars.append("-")
            default:
                scalars.append(s)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 短信签名，如【菜鸟驿站】→ "菜鸟驿站"（取第一个）。
    static func signature(of text: String) -> String? {
        Regex.firstGroup("[【\\[]([^】\\]]{1,16})[】\\]]", in: text)
    }
}
