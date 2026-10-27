import Foundation

/// 一句话多笔消费的**拆分**纯逻辑（如「咖啡10.9元，午餐22元，公交1元」→ 3 笔）。
///
/// 为什么在 AssistantCore：拆分决定「哪个金额配哪个标题」，拆错就是静默记错账，
/// 必须有单元测试兜底；App 侧只做分类/标题等展示性组装。
///
/// 三条设计要点（均有测试钉住，改动前先读测试）：
///
/// 1. **只认「合格金额」作为分笔依据**——带货币单位/符号或消费动词的金额才算，
///    裸数字（「3人」的 3、「24期」的 24）不拆笔，否则 AA/人数/期数会被误拆成一笔。
/// 2. **先按分隔符拆，不够再按金额边界邻接拆**——覆盖语音无逗号的
///    「咖啡10块9午餐22元」。邻接切点取金额（含口语小数尾「10块9」）整体结束处，
///    余文归入后一笔。
/// 3. **「共/合计/总计」汇总句在拆出 ≥2 笔后剔除**，不再单独成笔；
///    剔除后不足 2 笔则整句退回单笔解析（宁可不拆，不可拆错）。
public enum MultiExpenseSegmenter {

    // MARK: - 分隔符

    /// 列举分隔符：中文逗号/顿号/分号/句号/换行/括号，以及「还有」「另外」。
    /// 注意：不拆 ASCII `.`（小数点）、不拆 `:`（时间 12:30）。
    private static let delimiterRegex = try? NSRegularExpression(
        pattern: "[，,、；;。\\n（）()【】\\[\\]]|还有|另外"
    )

    /// 汇总句标记：「共33元」的裸「共」要求后接数字/中文数字，避免误伤「共享单车」。
    private static let summaryRegex = try? NSRegularExpression(
        pattern: "(?:一共|共计|合计|总计|总共|小计|实付|应付|总额|共(?=[0-9零〇一二两三四五六七八九十]))"
    )

    /// 段末裸金额：「打车15」「咖啡10.9」这类省略单位的口语（数字收尾）。
    /// 前缀必须有实体文字、且数字前一字不是「号/第/期」等非金额量词——「取餐号3」「24期」不算。
    private static let trailingBareAmountRegex = try? NSRegularExpression(
        pattern: "(?<![0-9.．])([0-9]+(?:[.．][0-9]{1,})?|[零〇一二两三四五六七八九十]+)(?![0-9.．])\\s*(?:元|块|块钱|毛|角)?$"
    )
    private static let amountExclusionPrefixChars = Set("号第期约近共计时点人份条张杯个次")

    /// 段内是否有可作为「一笔」的金额：严格合格金额，或段末裸金额（单位省略口语）。
    static func hasItemAmount(_ clause: String) -> Bool {
        if ExpenseAmountExtractor.hasQualifiedAmount(clause) { return true }
        return hasTrailingBareAmount(clause)
    }

    private static func hasTrailingBareAmount(_ clause: String) -> Bool {
        guard let regex = trailingBareAmountRegex,
              let match = regex.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)),
              match.range.location != NSNotFound,
              match.range.location > 0,
              let numberRange = Range(match.range(at: 1), in: clause) else { return false }
        // 数字前必须有实体文字，且前一字不是量词/序数前缀/ASCII 字母（「取餐号3」「24期」「登机口T3」不算）
        let beforeNumber = clause[..<numberRange.lowerBound]
        guard let lastChar = beforeNumber.last,
              !amountExclusionPrefixChars.contains(lastChar),
              !(lastChar.isASCII && lastChar.isLetter),
              beforeNumber.contains(where: { !$0.isNumber && !$0.isPunctuation && !$0.isWhitespace }) else {
            return false
        }
        return true
    }

    // MARK: - 入口

    /// 将一句话拆成多笔消费片段。
    /// - Returns: ≥2 个片段时返回各片段（含金额，已归一化）；无法可靠拆分时返回 nil（调用方走单笔解析）。
    public static func split(_ rawText: String) -> [String]? {
        let text = ExpenseAmountExtractor.normalize(rawText)
        guard !text.isEmpty else { return nil }

        // 1. 分隔符拆
        if let items = buildItems(from: delimiterClauses(text)), items.count >= 2 {
            return items
        }

        // 2. 邻接金额拆：切点取每个合格金额（含口语小数尾）整体结束处
        let ranges = ExpenseAmountExtractor.qualifiedAmountNSRanges(in: text)
        guard ranges.count >= 2 else { return nil }
        var pieces: [String] = []
        var cursor = text.startIndex
        for range in ranges.dropLast() {
            guard let end = Range(range, in: text)?.upperBound else { continue }
            let piece = String(text[cursor..<end]).trimmedForSegment
            if !piece.isEmpty { pieces.append(piece) }
            cursor = end
        }
        let tail = String(text[cursor...]).trimmedForSegment
        if !tail.isEmpty { pieces.append(tail) }
        guard let items = buildItems(from: pieces), items.count >= 2 else { return nil }
        return items
    }

    /// 段内是否存在可作为「一笔」的金额（严格合格金额或段末裸金额）。
    public static func hasQualifiedAmount(_ text: String) -> Bool {
        hasItemAmount(text)
    }

    // MARK: - 组装

    private static func delimiterClauses(_ text: String) -> [String] {
        guard let regex = delimiterRegex else { return [text] }
        let replaced = regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n"
        )
        return replaced
            .components(separatedBy: "\n")
            .map(\.trimmedForSegment)
            .filter { !$0.isEmpty }
    }

    /// 无金额段合并（前缀并入后一笔、段尾并入前一笔）→ 剔除汇总句 → ≥2 笔才成立。
    private static func buildItems(from clauses: [String]) -> [String]? {
        guard clauses.count >= 2 else { return nil }
        let qualified = clauses.map(hasItemAmount)
        guard qualified.filter({ $0 }).count >= 2 else { return nil }

        // 合并无金额段：中间/段尾并入前一笔（「咖啡10.9元，好喝」），开头前缀并入后一笔（「打车去机场，花了50元」）
        var merged: [String] = []
        var pendingPrefix: [String] = []
        for (index, clause) in clauses.enumerated() {
            if qualified[index] {
                merged.append((pendingPrefix + [clause]).joined(separator: " "))
                pendingPrefix = []
            } else if !merged.isEmpty {
                merged[merged.count - 1] += " " + clause
            } else {
                pendingPrefix.append(clause)
            }
        }

        // 剔除汇总句：仅当「共/合计」句金额 ≈ 其余各笔之和（才是总额），且剔除后仍剩 ≥2 笔。
        // 否则「共2人花了100元」这类真实消费会被误删——宁可保留，不可丢账。
        let items = merged.map { text -> (text: String, amount: Double?) in
            (text, ExpenseAmountExtractor.extractAmount(from: text))
        }
        for index in items.indices where isSummaryClause(items[index].text) {
            guard let summaryAmount = items[index].amount else { continue }
            let otherAmounts = items.enumerated().filter { $0.offset != index }.compactMap { $0.element.amount }
            guard !otherAmounts.isEmpty else { continue }
            let sum = otherAmounts.reduce(0, +)
            // 容差：允许抹零/四舍五入（1 元或 5%）
            guard abs(summaryAmount - sum) <= max(1.0, sum * 0.05) else { continue }
            let nonSummary = items.enumerated().filter { $0.offset != index }.map { $0.element.text }
            // 汇总句成立：剔除后仍剩 ≥2 笔才拆；否则整句退回单笔（宁可不拆，不可拆错）
            return nonSummary.count >= 2 ? nonSummary : nil
        }
        return merged
    }

    /// 「共33元」「合计32.9」等汇总句判定。
    static func isSummaryClause(_ text: String) -> Bool {
        guard let regex = summaryRegex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

private extension String {
    var trimmedForSegment: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
