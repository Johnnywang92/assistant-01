import Foundation

// MARK: - 三通道合并解读（纯逻辑下沉 Core）
//
// 为什么要单独做这一层：量表、微记录、生理数据**各自单看都能读**，
// 但合在一起才看得出「同一件事」。三段孤立的事实（分数中等、精力偏低、睡眠不足）
// 用户看不出因果；合成一句「你这周分数在升，同时精力连续三天偏低，睡眠均值只有 5.8 小时」
// 才指向同一个可行动的方向。
//
// ## 一条最容易搞错的时间语义
//
// 量表问的是**过去两周**（回忆窗 = 完成时刻往前 14 天）；
// 微记录问的是**当天**；生理数据也是**某一天**。
//
// 所以：
// - 微记录落在量表回忆窗**之内** → 两者描述**同一段时间**，可以互相印证或互相矛盾；
// - 微记录落在量表回忆窗**之后** → 量表是**滞后的**，微记录代表更近的情况。
//
// 不区分这两种关系，就会把「问卷覆盖的过去两周偏差，但最近几天已经好转」
// 误读成「问卷与日常记录矛盾」——这是完全相反的结论，方向性错误比不说更糟。
//
// ## 只描述现象，不下因果结论
//
// 合并解读可以说「两边指向同一件事」，**不能**说「因为睡眠不足所以分数上升」。
// 观察性数据支撑不了因果断言，而心理场景里错误的因果会让用户自责
//（「是我自己没睡好才变差」）。

// MARK: - 微记录条目

/// 每日情绪微记录条目（Core 侧结构，与 App 侧 `MoodCheckInRecord` 一一对应）。
public struct MoodCheckInEntry: Equatable, Sendable {
    /// 归属日（当天 00:00）。
    public let day: Date
    /// 情绪分值 1...5（1 = 很低落，5 = 很轻快）。
    public let moodScore: Int
    /// 精力分值 1...5（1 = 很疲惫，5 = 精力充沛）。
    public let energyScore: Int
    /// 压力分值 1...5（1 = 没有压力，5 = 压力极大）。
    public let stressScore: Int

    public init(day: Date, moodScore: Int, energyScore: Int, stressScore: Int) {
        self.day = day
        self.moodScore = moodScore
        self.energyScore = energyScore
        self.stressScore = stressScore
    }
}

// MARK: - 通道读数

/// 通道标识。
public enum PsychChannel: String, Equatable, Sendable, CaseIterable {
    /// 自评通道（量表）。
    case questionnaire
    /// 每日微记录通道。
    case daily
    /// 生理通道（HRV / 睡眠）。
    case physiological

    /// 通道中文名。
    public var displayName: String {
        switch self {
        case .questionnaire: return "问卷说"
        case .daily: return "日常记录说"
        case .physiological: return "身体说"
        }
    }
}

/// 通道的方向。
public enum PsychChannelDirection: String, Equatable, Sendable {
    /// 在变差。
    case worsening
    /// 平稳。
    case stable
    /// 在好转。
    case improving
    /// 数据不足，看不出方向。
    case unknown

    /// 是否是「负方向」。
    public var isNegative: Bool { self == .worsening }
}

/// 通道的状态水平。
public enum PsychChannelLevel: String, Equatable, Sendable {
    /// 状态偏低 / 负荷偏高。
    case low
    /// 在正常范围。
    case normal
    /// 状态偏好。
    case high
    /// 无法判定。
    case unknown
}

/// 单个通道的读数。
public struct PsychChannelReading: Equatable, Sendable {
    /// 通道。
    public let channel: PsychChannel
    /// 方向。
    public let direction: PsychChannelDirection
    /// 水平。
    public let level: PsychChannelLevel
    /// 一句话读数（不含结论，只描述这个通道看到了什么）。
    public let summary: String
    /// 该通道是否有可解读的数据。
    public let hasData: Bool

    public init(
        channel: PsychChannel,
        direction: PsychChannelDirection,
        level: PsychChannelLevel,
        summary: String,
        hasData: Bool
    ) {
        self.channel = channel
        self.direction = direction
        self.level = level
        self.summary = summary
        self.hasData = hasData
    }

    /// 无数据时的读数。
    public static func unavailable(_ channel: PsychChannel) -> PsychChannelReading {
        PsychChannelReading(
            channel: channel,
            direction: .unknown,
            level: .unknown,
            summary: "",
            hasData: false
        )
    }
}

// MARK: - 通道间关系

/// 通道之间的关系。
public enum PsychChannelAgreement: String, Equatable, Sendable {
    /// 多条通道同向指向困扰，互相印证。
    case corroborated
    /// 量表反映的过去两周尚可，但更近的微记录显示在变差（问卷滞后于当下）。
    case recentDeterioration
    /// 量表反映的过去两周有困扰，但更近的微记录显示在好转（正在改善）。
    case recentImprovement
    /// 各通道之间没有明显冲突。
    case neutral
    /// 只有一条通道有可解读的数据。
    case singleChannel
}

/// 微记录与量表的时间关系。
public enum PsychTimelineRelation: String, Equatable, Sendable {
    /// 微记录落在量表回忆窗内或之前 —— 两者描述**同一段时间**，可直接比对。
    case overlapping
    /// 微记录晚于量表回忆窗 —— 量表是**滞后的**，微记录代表更近的情况。
    case dailyIsNewer
    /// 交错（既有窗内也有窗后的记录）。
    case mixed
}

// MARK: - 合并解读

/// 三通道合并解读结果。
public struct MentalHealthCombinedReading: Equatable, Sendable {
    /// 各通道读数。
    public let channels: [PsychChannelReading]
    /// 通道间关系。
    public let agreement: PsychChannelAgreement
    /// 微记录与量表的时间关系。
    public let timeline: PsychTimelineRelation
    /// 合并后的一句话结论。
    public let summary: String
}

// MARK: - 合并器

/// 三通道合并器。
public enum PsychChannelMerger {

    /// 「最近」窗口的天数（用于微记录的方向判定）。
    public static let recentWindowDays = 7

    /// 判定方向所需的最小样本数（每个窗口至少要有这么多天才算方向）。
    public static let minimumSamplesPerWindow = 2

    /// 方向判定阈值（1~5 量表上小于该变化视为噪声）。
    public static let directionThreshold = 0.5

    /// 合并三个通道。
    ///
    /// - Parameters:
    ///   - scaleScores: 自评通道的量表计分结果。
    ///   - moodEntries: 每日微记录。
    ///   - physiology: 生理通道推断结果（可为 nil = 无数据）。
    ///   - recentAverageSleepHours: 近 N 日平均睡眠（可为 nil = 无数据）。
    ///   - now: 当前时间（**必须真的用它**）。
    ///   - calendar: 日历（按日历天算窗口）。
    public static func merge(
        scaleScores: [PsychScaleScore],
        moodEntries: [MoodCheckInEntry],
        physiology: PleasureIndexEvaluation?,
        recentAverageSleepHours: Double?,
        now: Date,
        calendar: Calendar
    ) -> MentalHealthCombinedReading {
        let questionnaire = questionnaireReading(scaleScores)
        let daily = dailyReading(moodEntries, now: now, calendar: calendar)
        let physiological = physiologicalReading(physiology, recentAverageSleepHours: recentAverageSleepHours)

        let channels = [questionnaire, daily, physiological]
        let timeline = timelineRelation(scaleScores: scaleScores, moodEntries: moodEntries, calendar: calendar)

        let agreement = determineAgreement(
            questionnaire: questionnaire,
            daily: daily,
            physiological: physiological,
            timeline: timeline
        )

        return MentalHealthCombinedReading(
            channels: channels,
            agreement: agreement,
            timeline: timeline,
            summary: buildSummary(
                agreement: agreement,
                questionnaire: questionnaire,
                daily: daily,
                physiological: physiological,
                timeline: timeline
            )
        )
    }

    // MARK: - 自评通道

    private static func questionnaireReading(_ scaleScores: [PsychScaleScore]) -> PsychChannelReading {
        let valid = scaleScores.filter { $0.totalScore != nil && $0.band != nil }

        // 「最近一次」按**完成时间**取，不是按分档最高。
        //
        // 用分档最高会读错方向：先做的一次 9 分、8 天前，后做的一次 5 分、1 天前——
        // 分档最高的那次是**旧的**，拿它当「最近」会把下降读成平稳甚至上升。
        // 最近一次评估才代表用户当前的状态。
        let sorted = valid.sorted { lhs, rhs in
            let l = lhs.completedAt ?? .distantPast
            let r = rhs.completedAt ?? .distantPast
            if l != r { return l < r }
            return (lhs.totalScore ?? 0) < (rhs.totalScore ?? 0)
        }
        guard let latest = sorted.last else {
            return .unavailable(.questionnaire)
        }

        // 方向：需要至少两次有效记录才能判断。
        let direction: PsychChannelDirection
        if sorted.count >= 2 {
            let previous = sorted[sorted.count - 2].totalScore!
            let current = latest.totalScore!
            if current > previous {
                direction = .worsening
            } else if current < previous {
                direction = .improving
            } else {
                direction = .stable
            }
        } else {
            direction = .unknown
        }

        let level: PsychChannelLevel
        switch latest.band!.supportLevel {
        case .monitor: level = .normal
        case .selfCare: level = .low
        case .professional: level = .low
        }

        let summary: String
        if direction == .worsening {
            summary = "分数比上次高了"
        } else if direction == .improving {
            summary = "分数比上次低了"
        } else {
            summary = "分数与上次持平"
        }

        return PsychChannelReading(
            channel: .questionnaire,
            direction: direction,
            level: level,
            summary: summary,
            hasData: true
        )
    }

    // MARK: - 微记录通道

    private static func dailyReading(
        _ entries: [MoodCheckInEntry],
        now: Date,
        calendar: Calendar
    ) -> PsychChannelReading {
        guard !entries.isEmpty else { return .unavailable(.daily) }

        // 归一化到「当天零点」再比较。`MoodCheckInEntry.day` 语义上是归属日，
        // 但调用方可能传入带时分的日期——不归一化会让窗口边界判定漂移
        // （比如「7 天前」在有时分时会被判到窗口外）。
        let normalized = entries.map {
            MoodCheckInEntry(
                day: calendar.startOfDay(for: $0.day),
                moodScore: $0.moodScore,
                energyScore: $0.energyScore,
                stressScore: $0.stressScore
            )
        }

        let sorted = normalized.sorted { $0.day < $1.day }
        let today = calendar.startOfDay(for: now)
        let recentCutoff = calendar.date(byAdding: .day, value: -recentWindowDays, to: today) ?? today
        let earlierCutoff = calendar.date(byAdding: .day, value: -recentWindowDays * 2, to: today) ?? recentCutoff

        let recent = sorted.filter { $0.day >= recentCutoff && $0.day <= today }
        let earlier = sorted.filter { $0.day >= earlierCutoff && $0.day < recentCutoff }

        // 水平：近窗口均值。
        let level: PsychChannelLevel
        if recent.isEmpty {
            level = .unknown
        } else {
            let moodMean = Double(recent.map(\.moodScore).reduce(0, +)) / Double(recent.count)
            let energyMean = Double(recent.map(\.energyScore).reduce(0, +)) / Double(recent.count)
            let stressMean = Double(recent.map(\.stressScore).reduce(0, +)) / Double(recent.count)
            // 任一维度落到低位即视为整体偏低——不必三项都差才算。
            if moodMean <= 2.0 || energyMean <= 2.0 || stressMean >= 4.0 {
                level = .low
            } else if moodMean >= 4.0 && energyMean >= 4.0 && stressMean <= 2.0 {
                level = .high
            } else {
                level = .normal
            }
        }

        // 方向：比较近窗口与前窗口的三个维度，看有几个在变差。
        let direction: PsychChannelDirection
        if recent.count >= minimumSamplesPerWindow && earlier.count >= minimumSamplesPerWindow {
            let worsened = countWorsenedDimensions(recent: recent, earlier: earlier)
            let improved = countImprovedDimensions(recent: recent, earlier: earlier)
            if worsened >= 2 && worsened > improved {
                direction = .worsening
            } else if improved >= 2 && improved > worsened {
                direction = .improving
            } else {
                direction = .stable
            }
        } else {
            direction = .unknown
        }

        let summary: String
        if recent.isEmpty {
            summary = "最近没有记录"
        } else if direction == .worsening {
            summary = "近 \(recent.count) 天在往下走"
        } else if direction == .improving {
            summary = "近 \(recent.count) 天在好转"
        } else if level == .low {
            summary = "近 \(recent.count) 天状态偏低"
        } else {
            summary = "近 \(recent.count) 天比较平稳"
        }

        return PsychChannelReading(
            channel: .daily,
            direction: direction,
            level: level,
            summary: summary,
            hasData: true
        )
    }

    /// 三个维度中「在变差」的个数。
    ///
    /// 心情降、精力降、压力升 —— 都是变差的方向。
    private static func countWorsenedDimensions(
        recent: [MoodCheckInEntry],
        earlier: [MoodCheckInEntry]
    ) -> Int {
        var count = 0
        if mean(recent, \.moodScore) < mean(earlier, \.moodScore) - directionThreshold { count += 1 }
        if mean(recent, \.energyScore) < mean(earlier, \.energyScore) - directionThreshold { count += 1 }
        if mean(recent, \.stressScore) > mean(earlier, \.stressScore) + directionThreshold { count += 1 }
        return count
    }

    /// 三个维度中「在好转」的个数。
    private static func countImprovedDimensions(
        recent: [MoodCheckInEntry],
        earlier: [MoodCheckInEntry]
    ) -> Int {
        var count = 0
        if mean(recent, \.moodScore) > mean(earlier, \.moodScore) + directionThreshold { count += 1 }
        if mean(recent, \.energyScore) > mean(earlier, \.energyScore) + directionThreshold { count += 1 }
        if mean(recent, \.stressScore) < mean(earlier, \.stressScore) - directionThreshold { count += 1 }
        return count
    }

    private static func mean(
        _ entries: [MoodCheckInEntry],
        _ keyPath: KeyPath<MoodCheckInEntry, Int>
    ) -> Double {
        guard !entries.isEmpty else { return 0 }
        return Double(entries.map { $0[keyPath: keyPath] }.reduce(0, +)) / Double(entries.count)
    }

    // MARK: - 生理通道

    private static func physiologicalReading(
        _ physiology: PleasureIndexEvaluation?,
        recentAverageSleepHours: Double?
    ) -> PsychChannelReading {
        guard let physiology else { return .unavailable(.physiological) }

        let stressHigh = physiology.stressScore >= 60
        let sleepLow = (recentAverageSleepHours ?? 8) < 6.5

        let level: PsychChannelLevel = (stressHigh || sleepLow) ? .low : .normal

        var summary = "压力指数 \(physiology.stressScore)"
        if let hours = recentAverageSleepHours {
            summary += "，平均睡眠 \(Int(hours.rounded())) 小时"
        }

        return PsychChannelReading(
            channel: .physiological,
            // 单次快照无法判断方向——不编造。
            direction: .unknown,
            level: level,
            summary: summary,
            hasData: true
        )
    }

    // MARK: - 时间关系

    /// 判定微记录与量表回忆窗的时间关系。
    ///
    /// 没有完成时间的量表记录**判不出时间关系**——这时按「同期」处理，
    /// 因为「同期矛盾」比「问卷滞后」更保守：
    /// 说「问卷滞后」是在断言一个需要时间证据的结论，
    /// 说「同期」只是不下结论。
    public static func timelineRelation(
        scaleScores: [PsychScaleScore],
        moodEntries: [MoodCheckInEntry],
        calendar: Calendar
    ) -> PsychTimelineRelation {
        let valid = scaleScores.filter { $0.totalScore != nil && $0.completedAt != nil }
        guard let latest = valid.max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }),
              let completedAt = latest.completedAt,
              !moodEntries.isEmpty else {
            return .overlapping
        }

        let scaleDay = calendar.startOfDay(for: completedAt)
        let windowStart = calendar.date(byAdding: .day, value: -latest.scaleID.recallWindowDays, to: scaleDay) ?? scaleDay

        // 微记录同样归一化到当天零点——否则「同一天」的判定会因时分秒不同而漂移。
        let normalizedDays = moodEntries.map { calendar.startOfDay(for: $0.day) }
        let withinCount = normalizedDays.filter { $0 >= windowStart && $0 <= scaleDay }.count
        let afterCount = normalizedDays.filter { $0 > scaleDay }.count

        if afterCount > 0 && withinCount == 0 {
            return .dailyIsNewer
        }
        if afterCount > 0 && withinCount > 0 {
            return .mixed
        }
        return .overlapping
    }

    // MARK: - 关系判定

    private static func determineAgreement(
        questionnaire: PsychChannelReading,
        daily: PsychChannelReading,
        physiological: PsychChannelReading,
        timeline: PsychTimelineRelation
    ) -> PsychChannelAgreement {
        let availableCount = [questionnaire, daily, physiological].filter(\.hasData).count
        guard availableCount >= 2 else { return .singleChannel }

        let questionnaireAbnormal = questionnaire.level == .low
        let dailyAbnormal = daily.level == .low
        let dailyWorsening = daily.direction == .worsening
        let dailyImproving = daily.direction == .improving
        let physiologicalAbnormal = physiological.level == .low

        // 1. 多通道同向 → 互相印证（最有说服力）。
        if questionnaireAbnormal && (dailyAbnormal || dailyWorsening || physiologicalAbnormal) {
            return .corroborated
        }

        // 2. 问卷尚可但更近的微记录在变差 → 问卷滞后于当下。
        //    只有在微记录确实比量表新的时候才这么说，否则是同期矛盾。
        //
        //    注意：微记录**只有一个窗口**时判不出方向（没有历史可比），
        //    但「近期状态明显偏低」本身就是信息——所以此时用**水平**兜底，
        //    否则「刚开始记录 + 状态很差」这种最该被看到的组合会被判成 neutral。
        let dailySignalsDeterioration = dailyWorsening
            || (daily.direction == .unknown && dailyAbnormal && daily.hasData)

        if !questionnaireAbnormal && dailySignalsDeterioration && timeline == .dailyIsNewer {
            return .recentDeterioration
        }

        // 3. 问卷有困扰但更近的微记录在好转 → 正在改善。
        if questionnaireAbnormal && dailyImproving && timeline == .dailyIsNewer {
            return .recentImprovement
        }

        // 4. 问卷与微记录同期却方向相反 —— 也是一种值得指出的情况。
        if questionnaireAbnormal && dailyImproving && timeline == .overlapping {
            return .recentImprovement
        }

        return .neutral
    }

    // MARK: - 合并结论

    private static func buildSummary(
        agreement: PsychChannelAgreement,
        questionnaire: PsychChannelReading,
        daily: PsychChannelReading,
        physiological: PsychChannelReading,
        timeline: PsychTimelineRelation
    ) -> String {
        switch agreement {
        case .corroborated:
            var pieces: [String] = ["问卷、近期记录和身体数据指向同一件事"]
            if questionnaire.hasData { pieces.append(questionnaire.summary) }
            if daily.hasData { pieces.append(daily.summary) }
            if physiological.hasData { pieces.append(physiological.summary) }
            return pieces.joined(separator: "；") + "。"

        case .recentDeterioration:
            return "问卷覆盖的过去两周还看不出明显问题，但最近的日常记录在往下走 —— 问卷比当下慢半拍，最近的情况更值得当真。"

        case .recentImprovement:
            return "问卷反映的那两周有些偏差，但最近的日常记录在好转 —— 情况看起来正在往回走。"

        case .singleChannel:
            let only = [questionnaire, daily, physiological].first { $0.hasData }
            if let only {
                return "目前只有「\(only.channel.displayName)」这一路数据，\(only.summary)。补上另外两路才能看出它们之间有没有关系。"
            }
            return "还没有可解读的数据。"

        case .neutral:
            var parts: [String] = []
            if questionnaire.hasData { parts.append(questionnaire.summary) }
            if daily.hasData { parts.append(daily.summary) }
            if physiological.hasData { parts.append(physiological.summary) }
            return parts.isEmpty
                ? "还没有可解读的数据。"
                : parts.joined(separator: "；") + "。三路数据之间没有明显冲突。"
        }
    }
}
