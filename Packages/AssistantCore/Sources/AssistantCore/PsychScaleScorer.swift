import Foundation

// MARK: - 心理健康量表计分（纯逻辑下沉 Core）
//
// 为什么要下沉到 Core：计分规则与缺失数据处理是安全底座，
// app target 没有测试 scheme，写在 app 里的判定逻辑等于没有防线。
//
// ## 缺失数据为什么不能按 0 计
//
// CASRAI 实施指南把这���列为量表实施中的默认失败模式：
// 「空白静默按 0 计」会让分母不变、分子少算，总分被系统性低估，
// 用户以为自己是「有点低分」，实际被低估了。
//
// 本文件的处置：
// - 全部作答 → `complete`，总分 = 直接求和。
// - **恰好缺 1 题** → `prorated`，按已答比例折算总分（这是量表实施的标准做法，
//   缺 1 题不丢弃整份数据），但折算事实在结果里**显式可见**，不假装是完整分。
// - **缺 2 题及以上** → `insufficient`，**不给总分**。宁可承认数据不足，
//   也不要给一个偏低且看起来很确定的分数。
//
// ## 危机题不受完整性影响
//
// 安全题（PHQ-9 第 9 题）的告警**独立于总分**，也**独立于完整性**：
// 即使其余 8 题全未作答，只要第 9 题有非零作答，就必须触发危机响应。
// 「数据不足所以先不算」在这里是不可接受的——那正是最需要被看见的时刻。

// MARK: - 作答完整性

/// 量表作答的完整性状态。
public enum PsychScoreCompleteness: Equatable, Sendable, Codable {
    /// 全部题目已作答。
    case complete
    /// 恰好缺 1 题，总分已按比例折算。
    case prorated(missingItemIndices: [Int])
    /// 缺 2 题及以上，**不给总分**。
    case insufficient(missingItemIndices: [Int])

    /// 是否给出了可用总分。
    public var hasValidTotal: Bool {
        switch self {
        case .complete, .prorated: return true
        case .insufficient: return false
        }
    }

    /// 未作答的题号。
    public var missingItemIndices: [Int] {
        switch self {
        case .complete: return []
        case .prorated(let indices), .insufficient(let indices): return indices
        }
    }

    /// 折算过（总分非直接求和）。
    public var isProrated: Bool {
        if case .prorated = self { return true }
        return false
    }
}

// MARK: - 计分结果

/// 量表计分结果。
///
/// 只含**结构化事实**：分数、完整性、分档。不含任何「你是不是抑郁了」式判断。
public struct PsychScaleScore: Equatable, Sendable, Codable {
    /// 量表标识。
    public let scaleID: PsychScaleID
    /// 总分。`completeness.hasValidTotal == false` 时为 **nil**（不是 0）。
    public let totalScore: Int?
    /// 作答完整性状态。
    public let completeness: PsychScoreCompleteness
    /// 分档。总分不可用时为 nil。
    public let band: PsychBandLevel?
    /// 是否达到筛查阳性阈值（即「建议考虑专业支持」）。
    public let isScreeningPositive: Bool
    /// 逐题得分（仅含已作答题）。**必须保留题目级数据**——
    /// 只存总分就做不了题目级告警，也没法在算法调整后重算历史。
    public let itemScores: [Int: Int]
    /// 得分最高的题号（并列时取题号最小者）。用于结果页指出「哪几项最突出」。
    public let topItemIndices: [Int]
    /// 作答完成时间。
    ///
    /// **三通道合并解读必需**：量表问的是「完成时刻往前 14 天」，
    /// 没有这个时间就判不了「微记录比问卷新还是旧」，
    /// 也就无法区分「问卷滞后」与「同期矛盾」这两种完全不同的结论。
    public let completedAt: Date?

    public init(
        scaleID: PsychScaleID,
        totalScore: Int?,
        completeness: PsychScoreCompleteness,
        band: PsychBandLevel?,
        isScreeningPositive: Bool,
        itemScores: [Int: Int],
        topItemIndices: [Int],
        completedAt: Date? = nil
    ) {
        self.scaleID = scaleID
        self.completedAt = completedAt
        self.totalScore = totalScore
        self.completeness = completeness
        self.band = band
        self.isScreeningPositive = isScreeningPositive
        self.itemScores = itemScores
        self.topItemIndices = topItemIndices
    }
}

// MARK: - 题目级数组转换

/// 题目级分数数组与作答字典之间的转换。
///
/// ## 为什么单独抽出来放 Core
///
/// 落库用的是**题目级分数数组**（`[Int?]`，下标 = 题号 - 1，`nil` = 未作答），
/// 而计分与危机路由吃的是**作答字典**（`[Int: PsychItemAnswer]`）。
/// 这个转换是**安全关键路径**——它喂给 `PsychSafetyRouter`，
/// 转换出错意味着第 9 题的告警可能失效。
///
/// 之前它写在 App 侧（SwiftData 模型里），而 app target 没有测试 scheme，
/// 等于没有防线。规则下沉到 Core 后才能被单测钉住。
public enum PsychItemScoreArray {

    /// 从题目级分数数组还原作答字典。
    ///
    /// - Parameter itemScores: 下标 = 题号 - 1；`nil` 表示该题未作答。
    /// - Returns: 题号 → 作答状态。越界分值按未作答处理。
    public static func answers(from itemScores: [Int?]) -> [Int: PsychItemAnswer] {
        var answers: [Int: PsychItemAnswer] = [:]
        for (offset, raw) in itemScores.enumerated() {
            let index = offset + 1
            guard let raw, raw >= 0 else {
                answers[index] = .unanswered
                continue
            }
            answers[index] = .answered(score: raw)
        }
        return answers
    }

    /// 从作答字典生成题目级分数数组（对齐到量表题数）。
    ///
    /// - Parameters:
    ///   - answers: 题号 → 作答状态。
    ///   - itemCount: 量表题目数。数组长度固定为它，
    ///     避免量表题目数变化后旧数据错位。
    public static func itemScores(from answers: [Int: PsychItemAnswer], itemCount: Int) -> [Int?] {
        var result: [Int?] = Array(repeating: nil, count: max(itemCount, 0))
        for (index, answer) in answers {
            let offset = index - 1
            guard offset >= 0, offset < result.count else { continue }
            result[offset] = answer.score
        }
        return result
    }
}

// MARK: - 计分器

/// 量表计分器。
public enum PsychScaleScorer {

    /// 计分。
    ///
    /// - Parameters:
    ///   - answers: 题号 → 作答状态。未出现在字典中的题号视为未作答。
    ///   - definition: 量表定义，缺省用目录里的内置量表。
    /// - Returns: 计分结果。总分在数据不足时为 nil。
    public static func score(
        answers: [Int: PsychItemAnswer],
        definition: PsychScaleDefinition,
        completedAt: Date? = nil
    ) -> PsychScaleScore {
        // 1. 只取已作答的题，且只取合法范围内的分值。
        //    越界分值（负数 / 超过满分）视为数据损坏，按未作答处理——
        //    宁可少算一题，也不能让一个异常值污染总分。
        var itemScores: [Int: Int] = [:]
        for item in definition.items {
            guard let answer = answers[item.index],
                  let raw = answer.score,
                  raw >= 0,
                  raw <= definition.maxItemScore else { continue }
            itemScores[item.index] = raw
        }

        // 2. 完整性判定。
        let missing = definition.items
            .map(\.index)
            .filter { itemScores[$0] == nil }

        let completeness: PsychScoreCompleteness
        if missing.isEmpty {
            completeness = .complete
        } else if missing.count == 1 {
            completeness = .prorated(missingItemIndices: missing)
        } else {
            completeness = .insufficient(missingItemIndices: missing)
        }

        // 3. 总分。数据不足时给 nil —— 不用 0 顶替，也不用部分和冒充总分。
        var total: Int?
        var band: PsychBandLevel?
        var isPositive = false

        if completeness.hasValidTotal {
            let sum = itemScores.values.reduce(0, +)
            let rawTotal: Int
            if completeness.isProrated {
                // 折算：已答均分 × 题目总数。缺 1 题时最多偏差 1 分左右。
                let answeredCount = definition.itemCount - missing.count
                let prorated = Int((Double(sum) / Double(answeredCount) * Double(definition.itemCount)).rounded())
                rawTotal = min(max(prorated, 0), definition.maxTotalScore)
            } else {
                rawTotal = min(max(sum, 0), definition.maxTotalScore)
            }
            total = rawTotal
            band = definition.band(forTotal: rawTotal)?.level
            isPositive = rawTotal >= definition.screeningCutoff
        }

        // 4. 得分最高的题。用于结果页「你在这两项上得分最高」这类具体解读。
        let topIndices = itemScores
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(2)
            .map(\.key)
            .sorted()

        return PsychScaleScore(
            scaleID: definition.id,
            totalScore: total,
            completeness: completeness,
            band: band,
            isScreeningPositive: isPositive,
            itemScores: itemScores,
            topItemIndices: Array(topIndices),
            completedAt: completedAt
        )
    }

    /// 便捷入口：用内置量表计分。
    public static func score(
        scaleID: PsychScaleID,
        answers: [Int: PsychItemAnswer]
    ) -> PsychScaleScore {
        score(answers: answers, definition: PsychScaleCatalog.definition(for: scaleID))
    }

    /// 构造一份「全部题目得 0 分」的作答，用于测试与默认态。
    public static func zeroAnswers(for definition: PsychScaleDefinition) -> [Int: PsychItemAnswer] {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in definition.items {
            answers[item.index] = .answered(score: 0)
        }
        return answers
    }
}
