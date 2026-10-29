import Foundation

/// 周期报告的趋势汇总（周/月/季/年报专用）。
///
/// ## 与 `PeriodReportAnalytics` 的关系
///
/// `PeriodReportAnalytics` 提供的是**原子分析函数**（斜率、类别变化、行为模式…），
/// 本文件把它们组合成一份可直接渲染的**汇总**，并额外产出「洞察」——
/// 即报告里给用户的建设性意见的结构化来源。
///
/// ## 为什么洞察放在 Core 而不是 App
///
/// 洞察的**判定规则**（什么算"支出持续上升"、波动多大算"节奏不稳"）是纯逻辑，
/// 必须可单测；而文案与图标属于 App 侧表达。Core 只出结构化事实，
/// App 负责翻译成中文/英文文案。
public struct PeriodTrendSummary: Equatable, Sendable {

    /// 一个历史周期的汇总点（由旧到新，最后一个为本期）。
    public let points: [PeriodReportAnalytics.PeriodPoint]

    /// 支出的多期趋势
    public let expenseTrend: PeriodReportAnalytics.SeriesTrend
    /// 完成待办数的多期趋势
    public let completionTrend: PeriodReportAnalytics.SeriesTrend

    /// 本期 vs 上期的关键指标变化（含好坏方向判定）
    public let metricChanges: [PeriodReportAnalytics.MetricChange]
    /// 本期 vs 上期的支出类别结构变化
    public let categoryChanges: [PeriodReportAnalytics.CategoryChange]

    /// 本期消费行为模式
    public let spendingPattern: PeriodReportAnalytics.SpendingPattern?
    /// 本期待办准时率
    public let punctuality: PeriodReportAnalytics.PunctualityStats?
    /// 下期目标建议
    public let nextTargets: PeriodReportAnalytics.NextPeriodTargets?

    /// 上期总支出（无上期时为 nil）
    public let previousExpense: Double?
    /// 上期完成待办数
    public let previousCompletedCount: Int?

    public init(
        points: [PeriodReportAnalytics.PeriodPoint],
        expenseTrend: PeriodReportAnalytics.SeriesTrend,
        completionTrend: PeriodReportAnalytics.SeriesTrend,
        metricChanges: [PeriodReportAnalytics.MetricChange],
        categoryChanges: [PeriodReportAnalytics.CategoryChange],
        spendingPattern: PeriodReportAnalytics.SpendingPattern?,
        punctuality: PeriodReportAnalytics.PunctualityStats?,
        nextTargets: PeriodReportAnalytics.NextPeriodTargets?,
        previousExpense: Double?,
        previousCompletedCount: Int?
    ) {
        self.points = points
        self.expenseTrend = expenseTrend
        self.completionTrend = completionTrend
        self.metricChanges = metricChanges
        self.categoryChanges = categoryChanges
        self.spendingPattern = spendingPattern
        self.punctuality = punctuality
        self.nextTargets = nextTargets
        self.previousExpense = previousExpense
        self.previousCompletedCount = previousCompletedCount
    }

    /// 供 UI 渲染迷你柱图的数值序列（支出）。
    public var expenseSeries: [Double] { points.map(\.expense) }
    /// 供 UI 渲染迷你柱图的数值序列（完成数）。
    public var completionSeries: [Double] { points.map { Double($0.completedCount) } }

    /// 序列是否足够长到值得解读趋势（少于 3 期不做趋势结论）。
    public var hasMeaningfulTrend: Bool { points.count >= 3 }
}

// MARK: - 洞察

/// 一条建设性意见的结构化表达。App 侧负责翻译成文案与配色。
public enum PeriodInsight: Equatable, Sendable {
    /// 支出连续上升
    case expenseSustainedRise(periods: Int, averageDelta: Double)
    /// 支出连续下降
    case expenseSustainedFall(periods: Int, averageDelta: Double)
    /// 支出波动大，节奏不稳
    case expenseVolatile(volatility: Double)
    /// 完成量连续上升
    case completionSustainedRise(periods: Int)
    /// 完成量连续下降
    case completionSustainedFall(periods: Int)
    /// 准时率偏低
    case punctualityBelowTarget(rate: Double, averageDelayDays: Double)
    /// 准时率良好
    case punctualityHealthy(rate: Double)
    /// 周末消费明显高于工作日
    case weekendSpendingHeavy(weekendShare: Double, weekendDaily: Double, weekdayDaily: Double)
    /// 小额高频消费
    case smallTicketFrequent(count: Int, total: Double)
    /// 新出现的支出类别
    case categoryAppeared(name: String, amount: Double)
    /// 消失的支出类别
    case categoryVanished(name: String, amount: Double)
    /// 某类别支出占比明显上升
    case categoryShareUp(name: String, delta: Double, shareDelta: Double)
    /// 某类别支出占比明显下降
    case categoryShareDown(name: String, delta: Double, shareDelta: Double)
    /// 下期目标建议
    case nextPeriodTarget(expenseCap: Double?, completedTarget: Int, savingsRate: Double?)

    /// 严重度。App 侧据此决定配色与排序。
    public enum Severity: Int, Sendable, Comparable, Equatable {
        /// 正向反馈
        case positive = 0
        /// 中性提醒
        case neutral = 1
        /// 需要注意
        case warning = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var severity: Severity {
        switch self {
        case .expenseSustainedRise, .completionSustainedFall, .punctualityBelowTarget, .weekendSpendingHeavy:
            return .warning
        case .expenseSustainedFall, .completionSustainedRise, .punctualityHealthy:
            return .positive
        case .expenseVolatile, .smallTicketFrequent, .categoryAppeared, .categoryVanished,
             .categoryShareUp, .categoryShareDown, .nextPeriodTarget:
            return .neutral
        }
    }

    /// 稳定的类型标识（用于测试断言与去重）。
    public var kind: String {
        switch self {
        case .expenseSustainedRise: return "expenseSustainedRise"
        case .expenseSustainedFall: return "expenseSustainedFall"
        case .expenseVolatile: return "expenseVolatile"
        case .completionSustainedRise: return "completionSustainedRise"
        case .completionSustainedFall: return "completionSustainedFall"
        case .punctualityBelowTarget: return "punctualityBelowTarget"
        case .punctualityHealthy: return "punctualityHealthy"
        case .weekendSpendingHeavy: return "weekendSpendingHeavy"
        case .smallTicketFrequent: return "smallTicketFrequent"
        case .categoryAppeared: return "categoryAppeared"
        case .categoryVanished: return "categoryVanished"
        case .categoryShareUp: return "categoryShareUp"
        case .categoryShareDown: return "categoryShareDown"
        case .nextPeriodTarget: return "nextPeriodTarget"
        }
    }
}

// MARK: - 构建

/// 趋势汇总的构建器与洞察判定规则。
public enum PeriodTrendBuilder {

    // MARK: 阈值（集中定义，便于测试与调参）

    /// 连续几期同向变化才算「持续」
    public static let sustainedPeriods = 2
    /// 变异系数超过该值视为「波动大」
    public static let highVolatility = 0.6
    /// 准时率低于该值视为「偏低」
    public static let lowPunctuality = 0.7
    /// 准时率高于该值视为「良好」
    public static let healthyPunctuality = 0.9
    /// 周末日均是工作日的多少倍算「周末消费重」
    public static let weekendHeavyRatio = 1.5
    /// 小额消费笔数达到该值且占比够高才提示
    public static let smallTicketCount = 8
    /// 小额消费占总支出比例超过该值才提示
    public static let smallTicketShare = 0.3
    /// 类别占比变化超过该值（百分点）才算「明显」
    public static let notableShareShift = 0.05

    /// 组装趋势汇总。
    ///
    /// - Parameters:
    ///   - points: 历史周期汇总点，**由旧到新**，最后一个是本期
    ///   - currentCategoryAmounts: 本期各类别支出金额（key 为类别 rawValue）
    ///   - previousCategoryAmounts: 上期各类别支出金额
    ///   - expenseSnapshots: 本期支出明细（日期, 金额），用于行为模式分析
    ///   - completions: 本期完成的待办（完成时间, 截止时间），用于准时率分析
    ///   - currentIncome: 本期总收入
    ///   - currentCompletionRate: 本期待办达成率
    ///   - previousCompletionRate: 上期待办达成率
    public static func build(
        points: [PeriodReportAnalytics.PeriodPoint],
        currentCategoryAmounts: [String: Double],
        previousCategoryAmounts: [String: Double],
        expenseSnapshots: [(date: Date, amount: Double)],
        completions: [(completedAt: Date, dueAt: Date?)],
        currentIncome: Double,
        currentCompletionRate: Double,
        previousCompletionRate: Double?,
        now: Date,
        calendar: Calendar
    ) -> PeriodTrendSummary {
        let expenseValues = points.map(\.expense)
        let completionValues = points.map { Double($0.completedCount) }

        let expenseTrend = PeriodReportAnalytics.seriesTrend(expenseValues)
        let completionTrend = PeriodReportAnalytics.seriesTrend(completionValues)

        // 上期 = 倒数第二个点（序列只有 1 期时无上期）
        let previousPoint = points.count >= 2 ? points[points.count - 2] : nil
        let currentPoint = points.last

        var metricChanges: [PeriodReportAnalytics.MetricChange] = []
        if let current = currentPoint, let previous = previousPoint {
            metricChanges = [
                .init(key: "expense", title: "总支出", unit: "元",
                      current: current.expense, previous: previous.expense, polarity: .lowerIsBetter),
                .init(key: "income", title: "总收入", unit: "元",
                      current: current.income, previous: previous.income, polarity: .higherIsBetter),
                .init(key: "completed", title: "完成事项", unit: "项",
                      current: Double(current.completedCount), previous: Double(previous.completedCount),
                      polarity: .higherIsBetter),
                .init(key: "created", title: "新录事项", unit: "项",
                      current: Double(current.createdCount), previous: Double(previous.createdCount),
                      polarity: .neutral),
            ]
        }
        // 达成率单独比较：它是百分比，不是金额
        if let previous = previousCompletionRate, previous > 0 {
            metricChanges.append(
                .init(key: "completionRate", title: "达成率", unit: "%",
                      current: currentCompletionRate * 100, previous: previous * 100,
                      polarity: .higherIsBetter)
            )
        }

        let categoryChanges = PeriodReportAnalytics.categoryChanges(
            current: currentCategoryAmounts,
            previous: previousCategoryAmounts
        )

        let spendingPattern = PeriodReportAnalytics.spendingPattern(
            expenses: expenseSnapshots,
            start: currentPoint?.start ?? now,
            end: currentPoint?.end ?? now,
            now: now,
            calendar: calendar
        )

        let punctuality = PeriodReportAnalytics.punctuality(completions: completions, calendar: calendar)

        let nextTargets = PeriodReportAnalytics.nextTargets(
            currentExpense: currentPoint?.expense ?? 0,
            baselineExpense: expenseTrend.baselineAverage,
            currentCompleted: currentPoint?.completedCount ?? 0,
            baselineCompleted: completionTrend.baselineAverage,
            currentIncome: currentIncome
        )

        return PeriodTrendSummary(
            points: points,
            expenseTrend: expenseTrend,
            completionTrend: completionTrend,
            metricChanges: metricChanges,
            categoryChanges: categoryChanges,
            spendingPattern: spendingPattern,
            punctuality: punctuality,
            nextTargets: nextTargets,
            previousExpense: previousPoint?.expense,
            previousCompletedCount: previousPoint?.completedCount
        )
    }

    // MARK: - 洞察判定

    /// 从趋势汇总中提炼建设性意见。
    ///
    /// 判定规则全部基于真实统计量，**不产出「看起来像结论」的臆测**：
    /// 序列不足 3 期时不给趋势结论；准时率无样本时不给准时率结论。
    public static func insights(from summary: PeriodTrendSummary) -> [PeriodInsight] {
        var result: [PeriodInsight] = []
        let trend = summary.expenseTrend
        let completion = summary.completionTrend

        // 1. 支出持续上升 / 下降（需至少 3 期，且有连续同向变化）
        if summary.hasMeaningfulTrend {
            if trend.streak >= sustainedPeriods, trend.direction == .rising {
                result.append(.expenseSustainedRise(periods: trend.streak, averageDelta: trend.slope))
            } else if trend.streak <= -sustainedPeriods, trend.direction == .falling {
                result.append(.expenseSustainedFall(periods: abs(trend.streak), averageDelta: trend.slope))
            }

            // 2. 支出波动大
            if trend.volatility >= highVolatility {
                result.append(.expenseVolatile(volatility: trend.volatility))
            }

            // 3. 完成量趋势
            if completion.streak >= sustainedPeriods, completion.direction == .rising {
                result.append(.completionSustainedRise(periods: completion.streak))
            } else if completion.streak <= -sustainedPeriods, completion.direction == .falling {
                result.append(.completionSustainedFall(periods: abs(completion.streak)))
            }
        }

        // 4. 准时率（无样本不下结论）
        if let p = summary.punctuality, let rate = p.onTimeRate {
            if rate < lowPunctuality {
                result.append(.punctualityBelowTarget(rate: rate, averageDelayDays: p.averageDelayDays))
            } else if rate >= healthyPunctuality {
                result.append(.punctualityHealthy(rate: rate))
            }
        }

        // 5. 周末消费偏重
        if let pattern = summary.spendingPattern,
           pattern.weekendDailyAverage > 0,
           pattern.weekdayDailyAverage > 0,
           pattern.weekendDailyAverage >= pattern.weekdayDailyAverage * weekendHeavyRatio {
            result.append(.weekendSpendingHeavy(
                weekendShare: pattern.weekendShare,
                weekendDaily: pattern.weekendDailyAverage,
                weekdayDaily: pattern.weekdayDailyAverage
            ))
        }

        // 6. 小额高频消费
        if let pattern = summary.spendingPattern,
           pattern.smallTicketCount >= smallTicketCount {
            let total = pattern.weekdayTotals.reduce(0, +)
            if total > 0, pattern.smallTicketTotal / total >= smallTicketShare {
                result.append(.smallTicketFrequent(count: pattern.smallTicketCount, total: pattern.smallTicketTotal))
            }
        }

        // 7. 类别结构变化
        for change in summary.categoryChanges {
            if change.isNew {
                result.append(.categoryAppeared(name: change.categoryRaw, amount: change.current))
            } else if change.isGone {
                result.append(.categoryVanished(name: change.categoryRaw, amount: change.previous))
            } else if abs(change.shareDelta) >= notableShareShift {
                if change.shareDelta > 0 {
                    result.append(.categoryShareUp(name: change.categoryRaw, delta: change.delta, shareDelta: change.shareDelta))
                } else {
                    result.append(.categoryShareDown(name: change.categoryRaw, delta: change.delta, shareDelta: change.shareDelta))
                }
            }
        }

        // 8. 下期目标
        if let targets = summary.nextTargets {
            if targets.expenseCap != nil || targets.completedTarget > 0 || targets.savingsRateTarget != nil {
                result.append(.nextPeriodTarget(
                    expenseCap: targets.expenseCap,
                    completedTarget: targets.completedTarget,
                    savingsRate: targets.savingsRateTarget
                ))
            }
        }

        return result
    }
}
