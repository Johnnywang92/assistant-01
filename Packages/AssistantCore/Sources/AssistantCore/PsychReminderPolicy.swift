import Foundation

// MARK: - 心理状态提醒决策（纯逻辑下沉 Core）
//
// 为什么要下沉到 Core：**「什么时候该打扰用户」是产品判断，不是 UI 细节**。
// 写进 app 就没法单测，而这条规则一旦写错，后果是持续的骚扰或持续的沉默。
//
// ## 一条铁律：低分不打扰
//
// 心理健康场景里，「被提醒」很容易被用户读成「我有病」。
// 所以：
// - `monitor` 档（无明显症状）**绝不主动推送**。只记录，不出声。
// - 只有「趋势连续上行」或「到了该复评的时候」才提示。
//
// ## 「连续两周上行」的严格定义
//
// 不是「比上次高」——那只是一次波动。
// 必须是**连续两次都上升**（至少 3 个数据点），且最新一次达到
// `monitor` 档以上（否则「上升」可能只是从 0 升到 1 的噪声）。
//
// ## 去重：同一件事不反复提醒
//
// 上行提示必须带冷却窗口，否则用户连续几天收到「你的状态在上升」会直接关掉通知。
// 冷却期按**日历天**算，不用绝对秒数——
// 绝对秒数会让「昨天提醒过、今天同一时刻又到」的边界行为变得不可预测。

// MARK: - 提醒类型

/// 心理提醒类型。
public enum PsychReminderKind: String, Equatable, Sendable {
    /// 到期该做量表了（周期性复评提醒）。
    case assessmentDue
    /// 分数连续两周上行，值得主动关心一下。
    case risingTrend
}

/// 提醒决策结果。
public struct PsychReminderDecision: Equatable, Sendable {
    /// 是否需要提醒。
    public let kind: PsychReminderKind?
    /// 提醒所依据的分数（趋势提醒时为最新一次分数）。
    public let latestScore: Int?
    /// 触发理由（用于文案与调试）。
    public let reason: String

    public init(kind: PsychReminderKind?, latestScore: Int? = nil, reason: String) {
        self.kind = kind
        self.latestScore = latestScore
        self.reason = reason
    }

    /// 不提醒。
    public static let none = PsychReminderDecision(kind: nil, reason: "无需提醒")

    /// 是否需要提醒。
    public var shouldNotify: Bool { kind != nil }
}

// MARK: - 历史序列

/// 一条量表得分记录（App 侧从 `PsychScaleRecord` 转换而来）。
public struct PsychScoreHistoryEntry: Equatable, Sendable {
    /// 量表标识。
    public let scaleID: PsychScaleID
    /// 完成时间。
    public let completedAt: Date
    /// 总分（数据不足的记录不进入序列，故此处恒有值）。
    public let totalScore: Int
    /// 分档。
    public let band: PsychBandLevel

    public init(scaleID: PsychScaleID, completedAt: Date, totalScore: Int, band: PsychBandLevel) {
        self.scaleID = scaleID
        self.completedAt = completedAt
        self.totalScore = totalScore
        self.band = band
    }
}

// MARK: - 决策器

/// 心理提醒决策器。
public enum PsychReminderPolicy {

    /// 连续上行判定所需的最小样本数。
    ///
    /// 3 个点才能判断「连续两次上升」——2 个点只能说明「比上次高」，
    /// 那属于波动而非趋势。
    public static let minimumSamplesForRisingTrend = 3

    /// 同一类提醒的冷却天数。
    public static let cooldownDays = 14

    /// 判定是否需要提醒。
    ///
    /// - Parameters:
    ///   - history: 该量表的历史得分序列（**任意顺序**，内部会按时间排序）。
    ///   - lastNotifiedAt: 上次同类提醒的时间。nil 表示从未提醒过。
    ///   - now: 当前时间。**必须真的用它**——不要用墙上时钟代替，
    ///     否则这条规则就失去了单测能力。
    ///   - calendar: 日历。用于按日历天计算冷却窗口。
    ///   - assessmentIntervalDays: 两次量表之间的建议间隔（天）。
    /// - Returns: 决策结果。
    public static func decide(
        history: [PsychScoreHistoryEntry],
        lastNotifiedAt: Date?,
        now: Date,
        calendar: Calendar,
        assessmentIntervalDays: Int = 7
    ) -> PsychReminderDecision {
        // 1. 数据不足：样本少于 2 个，既看不出趋势也谈不上「比上次」。
        guard history.count >= 2 else {
            return .none
        }

        // 2. 按时间升序排序（决策必须与传入顺序无关）。
        let sorted = history.sorted { $0.completedAt < $1.completedAt }
        guard sorted.count >= 2 else { return .none }
        let latest = sorted[sorted.count - 1]

        // 3. 冷却窗口：同一类提醒在冷却期内不重复。
        //    用日历天比较，不用绝对秒数——边界行为才可预期。
        if let lastNotifiedAt {
            let daysSince = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: lastNotifiedAt),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
            if daysSince < cooldownDays {
                return PsychReminderDecision(
                    kind: nil,
                    latestScore: latest.totalScore,
                    reason: "冷却期内（距上次 \(daysSince) 天，冷却 \(cooldownDays) 天）"
                )
            }
        }

        // 4. 低分档不打扰：无论趋势如何，`monitor` 档都不主动推送。
        guard latest.band.supportLevel != .monitor else {
            return PsychReminderDecision(
                kind: nil,
                latestScore: latest.totalScore,
                reason: "低分档，不打扰"
            )
        }

        // 5. 连续两周上行：需要至少 3 个点，且最近两次比较都是「上升」。
        let riseCount = consecutiveRiseCount(in: sorted)
        if riseCount >= 2, sorted.count >= minimumSamplesForRisingTrend {
            return PsychReminderDecision(
                kind: .risingTrend,
                latestScore: latest.totalScore,
                reason: "连续 \(riseCount) 次上升，最新 \(latest.totalScore) 分"
            )
        }

        // 6. 到期该做量表：距上次完成已超过建议间隔。
        let daysSinceAssessment = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latest.completedAt),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if daysSinceAssessment >= assessmentIntervalDays {
            return PsychReminderDecision(
                kind: .assessmentDue,
                latestScore: latest.totalScore,
                reason: "距上次评估已 \(daysSinceAssessment) 天"
            )
        }

        return PsychReminderDecision(
            kind: nil,
            latestScore: latest.totalScore,
            reason: "距上次评估 \(daysSinceAssessment) 天，趋势平稳"
        )
    }

    /// 计算序列末尾的**连续上升次数**。
    ///
    /// 例：`[3, 5, 4, 7]` → 末尾只有 1 次上升（4→7），前面 3→5 那次被 5→4 打断了。
    /// 返回 0 表示末尾不是上升。
    public static func consecutiveRiseCount(in sortedHistory: [PsychScoreHistoryEntry]) -> Int {
        guard sortedHistory.count >= 2 else { return 0 }
        var count = 0
        var index = sortedHistory.count - 1
        while index > 0 {
            let current = sortedHistory[index].totalScore
            let previous = sortedHistory[index - 1].totalScore
            if current > previous {
                count += 1
                index -= 1
            } else {
                break
            }
        }
        return count
    }
}
