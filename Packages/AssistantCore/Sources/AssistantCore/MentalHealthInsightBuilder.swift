import Foundation

// MARK: - 心理状态双通道交叉解读（纯逻辑下沉 Core）
//
// 为什么要下沉到 Core：分档 → 干预强度的映射规则是产品的核心判断，
// 写进 app 就没法单测，也没法在改文案时确认没改坏判定。
//
// ## 什么是「双通道」
//
// 本项目已有的 `PleasureIndexEvaluator` 用 HRV + 睡眠推断的是**「身体说的」**，
// 量表问的是**「心理说的」**。两者是**独立证据**，各有盲区：
//
// - 生理通道强项：客观、无法作伪、连续；弱项：**无法区分**「抑郁导致的疲惫」
//   与「没睡好的疲惫」，也没有「焦虑」这一维。
// - 自评通道强项：直接问「你近两周怎么样」；弱项：受当天状态与自我认知影响，
//   且可能存在「报喜不报忧」。
//
// 因此交叉解读的价值不在于「算一个更准的分数」，而在于**发现两者的关系**：
// - 问卷与生理**同向**：身体和心理指向同一件事，说服力最强。
// - 问卷与生理**背离**：要么是「心理难受但身体扛住了」（躯体化不明显的心理困扰），
//   要么是「身体在报警但人没意识到」（生理指标先于主观感受恶化）。
//   两种都值得指出，但**只描述现象，不下因果结论**。
//
// ## 干预强度只给一个主动作
//
// 结果页若并列五六个建议，用户的选择成本会高到干脆什么都不做。
// 所以本层只产出**一个主动作**（`primaryAction`），
// 其余作为可展开的备选（`secondaryActions`）。这条规则由 Core 保证，不靠 UI 自觉。

// MARK: - 输入

/// 一次心理状态评估的输入。
public struct MentalHealthInsightInput: Equatable, Sendable {
    /// 自评通道：各量表的计分结果。
    public let questionnaireScores: [PsychScaleScore]
    /// 生理通道：身心愉悦与压力推断结果。为 nil 表示**没有生理数据**
    /// （不是「生理状态良好」——读不到必须归入缺失）。
    public let physiology: PleasureIndexEvaluation?
    /// 近 7 日平均睡眠时长（小时）。nil 表示无睡眠数据。
    public let recentAverageSleepHours: Double?
    /// 每日情绪微记录。三通道合并解读的第三路数据。
    public let moodEntries: [MoodCheckInEntry]
    /// 「现在」。**由调用方传入**，不要在规则里用墙上时钟代替——
    /// 硬编码 `.now` 会让这条规则失去单测能力（时间窗口整体错位）。
    public let now: Date
    /// 日历。用于按日历天切分窗口。
    public let calendar: Calendar

    public init(
        questionnaireScores: [PsychScaleScore],
        physiology: PleasureIndexEvaluation? = nil,
        recentAverageSleepHours: Double? = nil,
        moodEntries: [MoodCheckInEntry] = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.questionnaireScores = questionnaireScores
        self.physiology = physiology
        self.recentAverageSleepHours = recentAverageSleepHours
        self.moodEntries = moodEntries
        self.now = now
        self.calendar = calendar
    }
}

// MARK: - 数据状态

/// 解读所依据的数据状态。
///
/// 「没做」和「没答全」必须分开——它们给用户的下一步完全不同：
/// 前者该去开始一次测评，后者该把剩下的题补上。
public enum MentalHealthDataStatus: String, Sendable, Codable {
    /// 数据完整，可正常解读。
    case ready
    /// 答了但缺 2 题及以上，算不出可靠结果。
    case incomplete
    /// 一题都没答。
    case noData
}

// MARK: - 疏解动作

/// 疏解动作。
public enum PsychReliefAction: String, CaseIterable, Sendable, Codable {
    /// 呼吸类练习（生理性叹息 / 缓慢呼吸）。
    case breathing
    /// 出门走动。
    case walk
    /// 写下来，把感受外化。
    case journal
    /// 说出来（语音备忘）。
    case speak
    /// 提早上床，把睡眠债先补一点。
    case sleepEarlier
    /// 主动联系一个信任的人。
    case reachOut
    /// 寻求专业帮助（建议就医 / 拨打热线）。
    case professionalCare

    /// 动作标题（UI 直接用）。
    public var title: String {
        switch self {
        case .breathing: return "做一次缓慢的生理性叹息"
        case .walk: return "出门走 10 分钟"
        case .journal: return "写下此刻最强烈的一个感受"
        case .speak: return "说出来 · 录一段语音"
        case .sleepEarlier: return "今晚提早 30 分钟上床"
        case .reachOut: return "给一个信任的人发条消息"
        case .professionalCare: return "联系专业支持"
        }
    }

    /// 动作说明。措辞刻意「小」——从最小可执行的一步开始，
    /// 而不是让人去完成一件看起来很大的事。
    public var detail: String {
        switch self {
        case .breathing:
            return "连做 3 次：吸一小口气，再慢慢吐长一点。身体会先于情绪松下来。"
        case .walk:
            return "不用换衣服、不用定目标，出门走 10 分钟就行。先动起来，感受可以晚一点再处理。"
        case .journal:
            return "只写一句：现在最强烈的感觉是什么。写下来本身就有整理作用。"
        case .speak:
            return "打开语音备忘，把想说的说出来。说出口比想清楚更容易开始。"
        case .sleepEarlier:
            return "睡眠不足会同时放大情绪的低落与迟钝。今晚先把入睡时间提前半小时。"
        case .reachOut:
            return "不用解释太多，发一句「最近有点闷，能聊两句吗」就够了。"
        case .professionalCare:
            return "自助方法有它的边界。找专业的人聊聊，是更快也更稳的路。"
        }
    }

    /// 该动作是否可以被转成一条**真待办**（能提醒、能打卡）。
    ///
    /// 转成待办是关键一步：建议不落成可执行动作 = 没做。
    public var isConvertibleToTodo: Bool {
        switch self {
        case .walk, .sleepEarlier, .reachOut, .breathing: return true
        case .journal, .speak, .professionalCare: return false
        }
    }
}

// MARK: - 解读结果

/// 双通道交叉解读结果。
public struct MentalHealthInsight: Equatable, Sendable {
    /// 处置强度。取所有量表中的最高档。
    public let supportLevel: PsychSupportLevel
    /// 达到最高分档（nil 表示数据不足，无法分档）。
    public let band: PsychBandLevel?
    /// 最高分（nil 表示数据不足）。
    public let topScore: Int?
    /// 达到该分的量表标识。
    public let topScaleID: PsychScaleID?
    /// 数据状态。`.ready` 之外都不给分、不给分档。
    public let dataStatus: MentalHealthDataStatus
    /// 危机信号。
    public let safetySignal: PsychSafetySignal
    /// 一句话解读：把两通道的关系说清楚。
    public let headline: String
    /// 主动作（**只给一个**）。
    public let primaryAction: PsychReliefAction?
    /// 备选动作。
    public let secondaryActions: [PsychReliefAction]
    /// 是否建议专业支持。
    public let recommendsProfessionalCare: Bool
    /// 三通道合并读数（问卷 / 微记录 / 生理）。
    ///
    /// 为 nil 表示合并所需的数据不足（连一条通道都没有）。
    public let combinedReading: MentalHealthCombinedReading?

    /// 是否需要展示危机响应。
    public var requiresCrisisResponse: Bool { safetySignal.requiresCrisisResponse }

    /// 危机响应时的求助资源。
    public var crisisResources: [PsychHelpResource] {
        safetySignal.requiresCrisisResponse ? PsychHelpResources.crisisResources : []
    }
}

// MARK: - 解读器

/// 心理状态解读器。
public enum MentalHealthInsightBuilder {

    /// 构建解读结果。
    public static func build(from input: MentalHealthInsightInput) -> MentalHealthInsight {
        let scores = input.questionnaireScores

        // 1. 危机信号：独立于总分与完整性，独立遍历所有量表。
        //    任何一张量表命中安全题，立刻升级为危机信号。
        let safetySignal = scores
            .map { PsychSafetyRouter.detectSignal(in: $0) }
            .max(by: { $0 < $1 }) ?? .none

        // 2. 取有效量表结果中最高的一档。
        //
        //    **「最高档」与「最近一次」是两个不同的东西**：
        //    - `top`（最高档）用于**处置强度**——曾到过中重度就值得关注，
        //      这是安全兜底，不该因为「最近一次好点了」就抹掉。
        //    - `latest`（最近一次）用于**描述当前状态**——「过去两周得分最集中的是第 X 题」
    //      说的是用户此刻的处境，拿一个月前那次来描述是错的。
        let scored = scores.filter { $0.totalScore != nil && $0.band != nil }
        let top = scored.max { lhs, rhs in
            let lhsBand = lhs.band!.supportLevel
            let rhsBand = rhs.band!.supportLevel
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            return (lhs.totalScore ?? 0) < (rhs.totalScore ?? 0)
        }
        // 最近一次（按完成时间）。
        let latest = scored.max { lhs, rhs in
            let l = lhs.completedAt ?? .distantPast
            let r = rhs.completedAt ?? .distantPast
            return l < r
        }

        // 3. 数据状态判定。
        //    - `noData`：一张题都没答 → 无数据，不给分档；
        //    - `incomplete`：答了但缺 2 题及以上 → 数据不足，同样不给分档。
        //    两者都不能给出分档，但给用户的下一步完全不同，状态必须分开。
        let hasAnyAnswered = scores.contains { !$0.itemScores.isEmpty }
        let dataStatus: MentalHealthDataStatus
        if scored.isEmpty {
            dataStatus = hasAnyAnswered ? .incomplete : .noData
        } else {
            dataStatus = .ready
        }

        guard let top, dataStatus == .ready else {
            // 数据不足：不给分、不给分档、不给行动建议。
            // 「你可能有点问题」这种猜测在数据不足时毫无依据。
            let headline: String
            switch dataStatus {
            case .noData:
                headline = "还没有可用的问卷结果。做完一次测评，这里会给出这两周的整体解读。"
            case .incomplete:
                headline = "这次作答缺了几道题，还算不出可靠的结果。补齐后再看解读会更准。"
            case .ready:
                headline = ""
            }
            return MentalHealthInsight(
                supportLevel: .monitor,
                band: nil,
                topScore: nil,
                topScaleID: nil,
                dataStatus: dataStatus,
                safetySignal: safetySignal,
                headline: headline,
                primaryAction: nil,
                secondaryActions: [],
                recommendsProfessionalCare: false,
                combinedReading: nil
            )
        }

        let band = top.band!
        let supportLevel = band.supportLevel

        // 4. 三通道合并读数（问卷 / 微记录 / 生理）。
        //    必须在有可用量表分之后才算——数据不足时连分档都给不出，
        //    谈「三路数据的关系」没有意义。
        let combinedReading = PsychChannelMerger.merge(
            scaleScores: scores,
            moodEntries: input.moodEntries,
            physiology: input.physiology,
            recentAverageSleepHours: input.recentAverageSleepHours,
            now: input.now,
            calendar: input.calendar
        )

        // 5. 主动作：按分档 + 通道关系挑**一个**最小可执行动作。
        let (primary, secondary) = chooseActions(
            band: band,
            supportLevel: supportLevel,
            score: latest ?? top,
            physiology: input.physiology,
            recentAverageSleepHours: input.recentAverageSleepHours,
            combinedReading: combinedReading
        )

        // 6. 解读文案：把三通道的关系讲清楚，但**只描述现象不下因果结论**。
        let headline = buildHeadline(
            band: band,
            score: latest ?? top,
            physiology: input.physiology,
            recentAverageSleepHours: input.recentAverageSleepHours,
            combinedReading: combinedReading,
            worstScore: top,
            latestScore: latest
        )

        return MentalHealthInsight(
            supportLevel: supportLevel,
            band: band,
            topScore: top.totalScore,
            topScaleID: top.scaleID,
            dataStatus: dataStatus,
            safetySignal: safetySignal,
            headline: headline,
            primaryAction: primary,
            secondaryActions: secondary,
            recommendsProfessionalCare: supportLevel == .professional,
            combinedReading: combinedReading
        )
    }

    // MARK: - 动作选择

    /// 选择主动作与备选动作。
    ///
    /// 规则：
    /// - `monitor` 档：**不给任何动作**。低分用户不需要被干预，
    ///   主动推送反而会让人把「被提醒」当成「有问题」。
    /// - `professional` 档：主动作是「联系专业支持」——
    ///   这时候再给呼吸练习是避重就轻，把该做的严肃事替换成了轻量安慰。
    /// - `selfCare` 档：给一个最小可执行动作，优先选**与本次数据对得上**的那个
    ///   （睡眠不足 → 早睡；生理压力高 → 呼吸/走动；否则 → 走出门）。
    private static func chooseActions(
        band: PsychBandLevel,
        supportLevel: PsychSupportLevel,
        score: PsychScaleScore,
        physiology: PleasureIndexEvaluation?,
        recentAverageSleepHours: Double?,
        combinedReading: MentalHealthCombinedReading
    ) -> (PsychReliefAction?, [PsychReliefAction]) {
        switch supportLevel {
        case .monitor:
            return (nil, [])

        case .professional:
            return (
                .professionalCare,
                [.breathing, .journal, .reachOut]
            )

        case .selfCare:
            var primary: PsychReliefAction = .walk

            // 优先选**与本次数据对得上**的动作。三通道合并后，
            // 「微记录显示精力在掉」比「问卷某题得分高」更能指向该做什么。
            let dailyReading = combinedReading.channels.first { $0.channel == .daily }
            if dailyReading?.direction == .worsening {
                primary = .walk
            } else if let hours = recentAverageSleepHours, hours < 6.5 {
                // 睡眠不足是抑郁与焦虑的常见伴随因素，且是少数「改了就有效」的项。
                primary = .sleepEarlier
            } else if let physiology, physiology.stressScore >= 60 {
                primary = .breathing
            } else if score.scaleID == .phq9, score.topItemIndices.contains(where: { [1, 2, 6].contains($0) }) {
                // PHQ-9 的 1/2/6 题是「情绪与自我评价」组，
                // 这些题得分高时，写下来比走动更对症。
                primary = .journal
            }

            var secondary: [PsychReliefAction] = [.walk, .journal, .speak]
            secondary.removeAll { $0 == primary }
            return (primary, Array(secondary.prefix(3)))
        }
    }

    // MARK: - 解读文案

    /// 构建一句话解读。
    ///
    /// 措辞纪律：
    /// - 说「同时出现」「指向同一件事」，**不说「因为」「导致」**。
    /// - 生理通道无数据时**不提生理**，也不说「身体数据正常」——
    ///   读不到就是读不到，不能拿来当安慰。
    private static func buildHeadline(
        band: PsychBandLevel,
        score: PsychScaleScore,
        physiology: PleasureIndexEvaluation?,
        recentAverageSleepHours: Double?,
        combinedReading: MentalHealthCombinedReading,
        worstScore: PsychScaleScore,
        latestScore: PsychScaleScore?
    ) -> String {
        let symptomPart: String
        if score.topItemIndices.isEmpty {
            symptomPart = "本次量表各题得分都不高"
        } else if score.topItemIndices.count == 1 {
            symptomPart = "得分最集中的是第 \(score.topItemIndices[0]) 题"
        } else {
            symptomPart = "得分最集中的是第 \(score.topItemIndices[0]) 题与第 \(score.topItemIndices[1]) 题"
        }
        let symptomText = "过去两周，\(symptomPart)。"

        // 「曾达到过的最高档」与「最近一次」不同时，必须显式说明。
        //
        // 否则会出现自相矛盾的结论：「最近一次已经回落到轻度」+
        // 「处置强度按最高档算出的中重度，建议专业支持」——
        // 用户会不知道该听哪一句。
        // 处置强度仍按最高档算（安全兜底，不该因为最近好转就抹掉曾有的严重程度），
        // 但必须把「这是之前某一次的情况」讲清楚。
        var severityNote = ""
        if let latestScore,
           !isSameAssessment(latestScore, worstScore),
           worstScore.band!.supportLevel > latestScore.band!.supportLevel {
            severityNote = "（之前有过一次分数更高、程度更重的记录，这次已经回落。）"
        }

        // 三通道合并关系已经说明问题时，直接用合并结论——
        // 它比「量表 + 生理」两两拼接更完整，也更贴近真实时间线。
        switch combinedReading.agreement {
        case .corroborated:
            return combinedReading.summary + severityNote
        case .recentDeterioration:
            return combinedReading.summary + severityNote
        case .recentImprovement:
            return combinedReading.summary + severityNote
        case .singleChannel, .neutral:
            break
        }

        // 生理通道缺失时不提生理。
        guard let physiology else {
            if let hours = recentAverageSleepHours, hours < 6.5 {
                return symptomText + severityNote + "同时你记录的平均睡眠只有 \(Int(hours.rounded())) 小时左右，睡眠不足会放大情绪的低落。"
            }
            return symptomText + severityNote
        }

        let physiologicalHigh = physiology.stressScore >= 60
        let questionnaireHigh = score.band?.supportLevel != .monitor

        if physiologicalHigh && questionnaireHigh {
            return symptomText + severityNote + "你的心率变异性与睡眠数据也显示身体处在较高负荷状态 —— 两边指向同一件事。"
        }
        if physiologicalHigh && !questionnaireHigh {
            return symptomText + severityNote + "不过身体数据（心率变异性、睡眠）显示负荷偏高，有时身体比自我感觉更早察觉。"
        }
        if !physiologicalHigh && questionnaireHigh {
            return symptomText + severityNote + "身体指标看起来还算平稳，但问卷反映出的困扰是真实的 —— 它值得被认真对待。"
        }
        return symptomText + severityNote + "身体指标与问卷结果基本一致，目前都在可接受的范围内。"
    }

    /// 判断两次评估是不是同一次。
    ///
    /// 按**完成时间**比，不是按量表标识——同一张量表可以做很多次，
    /// 量表标识相同但完成时间不同就是两次不同的评估。
    private static func isSameAssessment(_ lhs: PsychScaleScore, _ rhs: PsychScaleScore) -> Bool {
        switch (lhs.completedAt, rhs.completedAt) {
        case let (l?, r?): return l == r
        default: return lhs.scaleID == rhs.scaleID && lhs.totalScore == rhs.totalScore
        }
    }
}
