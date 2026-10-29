import Foundation

/// 周期报告（周/月/季/年报）深度分析纯函数：多期趋势、指标变化、类别结构变化、消费行为模式、下期目标。
///
/// App 侧只喂数值快照，不依赖 SwiftData，便于单测覆盖斜率、波动、补零与边界。
public enum PeriodReportAnalytics {

    // MARK: - 多期趋势

    /// 一个历史周期的汇总点（由旧到新排列，最后一个为本期）
    public struct PeriodPoint: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public let label: String
        public let start: Date
        public let end: Date
        public let expense: Double
        public let income: Double
        public let completedCount: Int
        public let createdCount: Int

        public init(label: String, start: Date, end: Date, expense: Double, income: Double, completedCount: Int, createdCount: Int) {
            self.label = label
            self.start = start
            self.end = end
            self.expense = expense
            self.income = income
            self.completedCount = completedCount
            self.createdCount = createdCount
        }
    }

    public enum Direction: String, Sendable, Equatable {
        case rising, falling, flat
    }

    /// 单一指标序列的趋势判断
    public struct SeriesTrend: Equatable, Sendable {
        /// 历史均值（不含本期；仅一期时为本期值）
        public let baselineAverage: Double
        /// 最小二乘斜率（每期变化量）
        public let slope: Double
        /// 斜率相对全序列均值的比例（用于判断显著性）
        public let slopeRatio: Double
        public let direction: Direction
        /// 本期相对历史均值的偏离比例；基线为 0 时为 nil
        public let currentVsBaseline: Double?
        /// 截至本期连续上升（正）或连续下降（负）的期数
        public let streak: Int
        /// 变异系数（标准差/均值），衡量波动；均值为 0 时为 0
        public let volatility: Double
        /// 序列最大值所在下标
        public let peakIndex: Int?
    }

    /// 最小二乘斜率（x = 0...n-1）
    public static func linearSlope(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard values.count >= 2 else { return 0 }
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - meanX
            num += dx * (y - meanY)
            den += dx * dx
        }
        return den == 0 ? 0 : num / den
    }

    /// 序列趋势分析。
    /// - Parameter flatThreshold: 斜率/均值低于该比例视为平稳（默认 5%）
    public static func seriesTrend(_ values: [Double], flatThreshold: Double = 0.05) -> SeriesTrend {
        guard !values.isEmpty else {
            return SeriesTrend(baselineAverage: 0, slope: 0, slopeRatio: 0, direction: .flat,
                               currentVsBaseline: nil, streak: 0, volatility: 0, peakIndex: nil)
        }
        let history = values.count > 1 ? Array(values.dropLast()) : values
        let baseline = history.reduce(0, +) / Double(history.count)
        let mean = values.reduce(0, +) / Double(values.count)
        let slope = linearSlope(values)
        let slopeRatio = mean > 0 ? slope / mean : 0
        let direction: Direction
        if values.count < 2 || abs(slopeRatio) < flatThreshold {
            direction = .flat
        } else {
            direction = slope > 0 ? .rising : .falling
        }

        let current = values.last ?? 0
        let currentVsBaseline: Double? = (values.count > 1 && baseline > 0) ? (current - baseline) / baseline : nil

        // 连续涨跌
        var streak = 0
        if values.count >= 2 {
            var i = values.count - 1
            let firstUp = values[i] > values[i - 1]
            let firstDown = values[i] < values[i - 1]
            if firstUp || firstDown {
                while i >= 1 {
                    let up = values[i] > values[i - 1]
                    let down = values[i] < values[i - 1]
                    if firstUp, up { streak += 1 } else if firstDown, down { streak -= 1 } else { break }
                    i -= 1
                }
            }
        }

        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let volatility = mean > 0 ? sqrt(variance) / mean : 0
        let peak = values.indices.max(by: { values[$0] < values[$1] })

        return SeriesTrend(
            baselineAverage: baseline,
            slope: slope,
            slopeRatio: slopeRatio,
            direction: direction,
            currentVsBaseline: currentVsBaseline,
            streak: streak,
            volatility: volatility,
            peakIndex: peak
        )
    }

    // MARK: - 指标变化

    /// 指标好坏方向：越高越好 / 越低越好 / 中性
    public enum Polarity: Sendable, Equatable {
        case higherIsBetter, lowerIsBetter, neutral
    }

    public struct MetricChange: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        public let title: String
        public let unit: String
        public let current: Double
        public let previous: Double?
        public let polarity: Polarity

        public init(key: String, title: String, unit: String, current: Double, previous: Double?, polarity: Polarity) {
            self.key = key
            self.title = title
            self.unit = unit
            self.current = current
            self.previous = previous
            self.polarity = polarity
        }

        public var delta: Double? { previous.map { current - $0 } }

        /// 环比比例；上期为 0 或缺失时为 nil
        public var ratio: Double? {
            guard let previous, previous != 0 else { return nil }
            return (current - previous) / abs(previous)
        }

        /// 变化评价：+1 改善，-1 恶化，0 持平/中性/无基线（相对变化 < 3% 视为持平）
        public var verdict: Int {
            guard let delta, polarity != .neutral else { return 0 }
            if let r = ratio, abs(r) < 0.03 { return 0 }
            if delta == 0 { return 0 }
            let up = delta > 0
            switch polarity {
            case .higherIsBetter: return up ? 1 : -1
            case .lowerIsBetter: return up ? -1 : 1
            case .neutral: return 0
            }
        }
    }

    // MARK: - 类别结构变化

    public struct CategoryChange: Equatable, Sendable, Identifiable {
        public var id: String { categoryRaw }
        public let categoryRaw: String
        public let current: Double
        public let previous: Double
        public let currentShare: Double
        public let previousShare: Double

        public var delta: Double { current - previous }
        /// 占比变化（百分点，0.05 = 5pp）
        public var shareDelta: Double { currentShare - previousShare }
        public var isNew: Bool { previous == 0 && current > 0 }
        public var isGone: Bool { current == 0 && previous > 0 }
    }

    /// 合并本期与上期的类别金额，按变化绝对值降序。
    public static func categoryChanges(current: [String: Double], previous: [String: Double]) -> [CategoryChange] {
        let curTotal = current.values.reduce(0, +)
        let prevTotal = previous.values.reduce(0, +)
        var keys = Set(current.keys)
        keys.formUnion(previous.keys)
        return keys.map { key in
            let c = current[key] ?? 0
            let p = previous[key] ?? 0
            return CategoryChange(
                categoryRaw: key,
                current: c,
                previous: p,
                currentShare: curTotal > 0 ? c / curTotal : 0,
                previousShare: prevTotal > 0 ? p / prevTotal : 0
            )
        }
        .filter { $0.current > 0 || $0.previous > 0 }
        .sorted {
            if abs($0.delta) != abs($1.delta) { return abs($0.delta) > abs($1.delta) }
            return $0.categoryRaw < $1.categoryRaw
        }
    }

    // MARK: - 消费行为模式

    public struct SpendingPattern: Equatable, Sendable {
        /// 周一...周日（下标 0 = 周一）的支出合计
        public let weekdayTotals: [Double]
        /// 支出最高的星期下标（0 = 周一）；无支出时为 nil
        public let peakWeekdayIndex: Int?
        /// 周末（周六日）支出占比
        public let weekendShare: Double
        /// 工作日日均 / 周末日均（按周期内实际天数计）
        public let weekdayDailyAverage: Double
        public let weekendDailyAverage: Double
        /// 有支出的天数 / 周期已过天数
        public let activeDays: Int
        public let elapsedDays: Int
        /// 零支出天数
        public var noSpendDays: Int { max(0, elapsedDays - activeDays) }
        /// 日均支出（按已过天数）
        public let dailyAverage: Double
        /// 单日最高支出与日期
        public let peakDayAmount: Double
        public let peakDay: Date?
        /// 小额高频：单笔 < 30 元的笔数与合计
        public let smallTicketCount: Int
        public let smallTicketTotal: Double
    }

    /// 统计周期内的消费行为模式。
    /// - Parameters:
    ///   - expenses: (日期, 金额) 支出快照（不含收入）
    ///   - now: 用于截断「已过天数」（进行中的周期不把未来天数算作零支出）
    public static func spendingPattern(
        expenses: [(date: Date, amount: Double)],
        start: Date,
        end: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        smallTicketThreshold: Double = 30
    ) -> SpendingPattern {
        let startDay = calendar.startOfDay(for: start)
        let effectiveEnd = min(end, now)
        let lastDay = calendar.startOfDay(for: max(effectiveEnd, start))

        var weekdayTotals = Array(repeating: 0.0, count: 7)
        var byDay: [Date: Double] = [:]
        var smallCount = 0
        var smallTotal = 0.0
        for e in expenses where e.date >= start && e.date <= end {
            let idx = (calendar.component(.weekday, from: e.date) + 5) % 7 // 周一 = 0
            weekdayTotals[idx] += e.amount
            byDay[calendar.startOfDay(for: e.date), default: 0] += e.amount
            if e.amount < smallTicketThreshold {
                smallCount += 1
                smallTotal += e.amount
            }
        }

        // 遍历已过天数，统计工作日/周末天数
        var weekdayDays = 0
        var weekendDays = 0
        var elapsed = 0
        var cursor = startDay
        while cursor <= lastDay {
            elapsed += 1
            let idx = (calendar.component(.weekday, from: cursor) + 5) % 7
            if idx >= 5 { weekendDays += 1 } else { weekdayDays += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let total = weekdayTotals.reduce(0, +)
        let weekendTotal = weekdayTotals[5] + weekdayTotals[6]
        let weekdayTotal = total - weekendTotal
        let peakIdx = total > 0 ? weekdayTotals.indices.max(by: { weekdayTotals[$0] < weekdayTotals[$1] }) : nil
        let peak = byDay.max(by: { $0.value < $1.value })

        return SpendingPattern(
            weekdayTotals: weekdayTotals,
            peakWeekdayIndex: peakIdx,
            weekendShare: total > 0 ? weekendTotal / total : 0,
            weekdayDailyAverage: weekdayDays > 0 ? weekdayTotal / Double(weekdayDays) : 0,
            weekendDailyAverage: weekendDays > 0 ? weekendTotal / Double(weekendDays) : 0,
            activeDays: byDay.keys.filter { $0 <= lastDay }.count,
            elapsedDays: elapsed,
            dailyAverage: elapsed > 0 ? total / Double(elapsed) : 0,
            peakDayAmount: peak?.value ?? 0,
            peakDay: peak?.key,
            smallTicketCount: smallCount,
            smallTicketTotal: smallTotal
        )
    }

    // MARK: - 待办准时率

    public struct PunctualityStats: Equatable, Sendable {
        /// 有截止时间的已完成事项数
        public let dueCompletedCount: Int
        /// 其中按时完成数
        public let onTimeCount: Int
        /// 准时率；无样本时为 nil
        public var onTimeRate: Double? {
            dueCompletedCount > 0 ? Double(onTimeCount) / Double(dueCompletedCount) : nil
        }
        /// 逾期完成事项的平均拖延天数
        public let averageDelayDays: Double
    }

    /// 准时率：completedAt ≤ dueAt 当天结束即算准时。
    public static func punctuality(
        completions: [(completedAt: Date, dueAt: Date?)],
        calendar: Calendar = .current
    ) -> PunctualityStats {
        var due = 0
        var onTime = 0
        var delays: [Double] = []
        for c in completions {
            guard let dueAt = c.dueAt else { continue }
            due += 1
            let dueDayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: dueAt)) ?? dueAt
            if c.completedAt < dueDayEnd {
                onTime += 1
            } else {
                delays.append(c.completedAt.timeIntervalSince(dueAt) / 86400)
            }
        }
        let avgDelay = delays.isEmpty ? 0 : delays.reduce(0, +) / Double(delays.count)
        return PunctualityStats(dueCompletedCount: due, onTimeCount: onTime, averageDelayDays: avgDelay)
    }

    // MARK: - 下期目标

    public struct NextPeriodTargets: Equatable, Sendable {
        /// 建议支出上限
        public let expenseCap: Double?
        /// 建议完成事项数
        public let completedTarget: Int
        /// 建议储蓄率（仅录入收入时）
        public let savingsRateTarget: Double?
    }

    /// 基于本期与历史均值给出「跳一跳够得着」的下期目标：
    /// - 支出：取本期与历史均值中较低者再压 5%；若本期已低于均值 15% 以上，则以本期为上限（守住即可）。
    /// - 完成数：取本期与历史均值较高者 +10%（至少 +1）。
    /// - 储蓄率：本期储蓄率 +5pp，封顶 50%，下限 10%。
    public static func nextTargets(
        currentExpense: Double,
        baselineExpense: Double,
        currentCompleted: Int,
        baselineCompleted: Double,
        currentIncome: Double
    ) -> NextPeriodTargets {
        var cap: Double? = nil
        if currentExpense > 0 || baselineExpense > 0 {
            if baselineExpense > 0, currentExpense < baselineExpense * 0.85, currentExpense > 0 {
                cap = currentExpense
            } else {
                let ref = [currentExpense, baselineExpense].filter { $0 > 0 }.min() ?? 0
                cap = ref * 0.95
            }
        }
        let refCompleted = max(Double(currentCompleted), baselineCompleted)
        let completedTarget = max(Int((refCompleted * 1.1).rounded()), Int(refCompleted.rounded()) + 1)

        var savings: Double? = nil
        if currentIncome > 0 {
            let rate = (currentIncome - currentExpense) / currentIncome
            savings = min(0.5, max(0.1, rate + 0.05))
        }
        return NextPeriodTargets(expenseCap: cap, completedTarget: completedTarget, savingsRateTarget: savings)
    }
}
