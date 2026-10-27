import Foundation

/// 趋势分析聚合（纯函数）：消费月序列与饮食日序列。
///
/// App 侧只喂数据快照（`ExpenseEntry`/`DietEntry`），不依赖 SwiftData，
/// 便于单测覆盖分桶、补零、环比、半段均值等边界。
public enum TrendAnalytics {

    // MARK: - 消费趋势

    /// 一条记账快照（仅趋势所需字段）
    public struct ExpenseEntry: Equatable, Sendable {
        public let date: Date
        public let amount: Double
        public let isIncome: Bool
        public let categoryRaw: String

        public init(date: Date, amount: Double, isIncome: Bool, categoryRaw: String) {
            self.date = date
            self.amount = amount
            self.isIncome = isIncome
            self.categoryRaw = categoryRaw
        }
    }

    /// 单月汇总点（图表直接消费）
    public struct MonthlyExpensePoint: Equatable, Sendable, Identifiable {
        public var id: String { "\(year)-\(month)" }
        public let year: Int
        public let month: Int
        public let expense: Double
        public let income: Double
        public let recordCount: Int

        public init(year: Int, month: Int, expense: Double, income: Double, recordCount: Int) {
            self.year = year
            self.month = month
            self.expense = expense
            self.income = income
            self.recordCount = recordCount
        }
    }

    /// 类别金额的上期→本期变化
    public struct CategoryShift: Equatable, Sendable {
        public let categoryRaw: String
        public let from: Double
        public let to: Double
        /// to - from；正 = 增长，负 = 降温
        public let delta: Double

        public init(categoryRaw: String, from: Double, to: Double) {
            self.categoryRaw = categoryRaw
            self.from = from
            self.to = to
            self.delta = to - from
        }
    }

    public struct ExpenseTrend: Equatable, Sendable {
        /// 由旧到新的月序列（含当月；窗口内无记录的月份补 0）
        public let months: [MonthlyExpensePoint]
        /// 当月支出相对上月的环比；上月为 0 时无基线，为 nil
        public let changeRatio: Double?
        /// 窗口内月均支出
        public let averageExpense: Double
        /// 当月相对上月支出增长最多的类别（delta > 0 才有值）
        public let growingCategory: CategoryShift?
        /// 当月相对上月降温最多的类别（delta < 0 才有值）
        public let shrinkingCategory: CategoryShift?
    }

    /// 近 N 个自然月（含当月）的消费趋势。
    /// - Parameters:
    ///   - monthCount: 窗口月数（至少 1；环比需要 ≥ 2）
    public static func expenseTrend(
        entries: [ExpenseEntry],
        now: Date = .now,
        calendar: Calendar = .current,
        monthCount: Int = 6
    ) -> ExpenseTrend {
        let count = max(1, monthCount)
        let comps = calendar.dateComponents([.year, .month], from: now)
        let currentYear = comps.year ?? 1970
        let currentMonth = comps.month ?? 1

        // 由旧到新的 (year, month) 窗口
        var window: [(year: Int, month: Int)] = []
        for step in stride(from: count - 1, through: 0, by: -1) {
            let total = currentYear * 12 + (currentMonth - 1) - step
            window.append((year: total / 12, month: total % 12 + 1))
        }

        // 分桶
        let key = { (y: Int, m: Int) in "\(y)-\(m)" }
        let windowKeys = Set(window.map { key($0.year, $0.month) })
        var expenseByMonth = [String: Double](minimumCapacity: count)
        var incomeByMonth = [String: Double](minimumCapacity: count)
        var countByMonth = [String: Int](minimumCapacity: count)
        var curCategory = [String: Double]()
        var prevCategory = [String: Double]()

        for entry in entries {
            let ec = calendar.dateComponents([.year, .month], from: entry.date)
            guard let y = ec.year, let m = ec.month else { continue }
            let k = key(y, m)
            guard windowKeys.contains(k) else { continue }

            if entry.isIncome {
                incomeByMonth[k, default: 0] += entry.amount
            } else {
                expenseByMonth[k, default: 0] += entry.amount
                // 类别结构只比较当月与上月的支出
                if count >= 2, y == currentYear, m == currentMonth {
                    curCategory[entry.categoryRaw, default: 0] += entry.amount
                } else if count >= 2 {
                    let prev = window[count - 2]
                    if y == prev.year, m == prev.month {
                        prevCategory[entry.categoryRaw, default: 0] += entry.amount
                    }
                }
            }
            countByMonth[k, default: 0] += 1
        }

        let months: [MonthlyExpensePoint] = window.map { ym in
            let k = key(ym.year, ym.month)
            return MonthlyExpensePoint(
                year: ym.year,
                month: ym.month,
                expense: expenseByMonth[k] ?? 0,
                income: incomeByMonth[k] ?? 0,
                recordCount: countByMonth[k] ?? 0
            )
        }

        let totalExpense = months.reduce(0.0) { $0 + $1.expense }
        let averageExpense = months.isEmpty ? 0 : totalExpense / Double(months.count)

        var changeRatio: Double? = nil
        if count >= 2 {
            let prevExpense = months[count - 2].expense
            if prevExpense > 0 {
                changeRatio = (months[count - 1].expense - prevExpense) / prevExpense
            }
        }

        var growing: CategoryShift? = nil
        var shrinking: CategoryShift? = nil
        if count >= 2 {
            var allKeys = Set(curCategory.keys)
            allKeys.formUnion(prevCategory.keys)
            for cat in allKeys {
                let from = prevCategory[cat] ?? 0
                let to = curCategory[cat] ?? 0
                let shift = CategoryShift(categoryRaw: cat, from: from, to: to)
                if shift.delta > 0, growing == nil || shift.delta > growing!.delta {
                    growing = shift
                }
                if shift.delta < 0, shrinking == nil || shift.delta < shrinking!.delta {
                    shrinking = shift
                }
            }
        }

        return ExpenseTrend(
            months: months,
            changeRatio: changeRatio,
            averageExpense: averageExpense,
            growingCategory: growing,
            shrinkingCategory: shrinking
        )
    }

    // MARK: - 饮食趋势

    /// 一条饮食摄入快照
    public struct DietEntry: Equatable, Sendable {
        public let date: Date
        /// 实际摄入热量（千卡）
        public let calories: Double

        public init(date: Date, calories: Double) {
            self.date = date
            self.calories = calories
        }
    }

    /// 单日摄入汇总点（图表直接消费）
    public struct DailyDietPoint: Equatable, Sendable, Identifiable {
        public var id: Date { dayStart }
        /// 当日起点（用于图表横轴）
        public let dayStart: Date
        public let calories: Double
        /// 当日是否有记录（有记录但 0 千卡也算有记录）
        public let hasRecords: Bool

        public init(dayStart: Date, calories: Double, hasRecords: Bool) {
            self.dayStart = dayStart
            self.calories = calories
            self.hasRecords = hasRecords
        }
    }

    public struct DietTrend: Equatable, Sendable {
        /// 由旧到新的日序列（含今天；无记录日 hasRecords = false）
        public let days: [DailyDietPoint]
        /// 有记录天数
        public let recordedDays: Int
        /// 仅有记录天的日均摄入（千卡）；无任何记录时为 0
        public let averageCalories: Double
        /// 后半段（含今天）有记录天的日均；该半段无记录时为 0
        public let recentAverage: Double
        /// 前半段有记录天的日均；该半段无记录时为 0
        public let earlierAverage: Double
        /// 后半相对前半的均值变化；前半无记录时无基线，为 nil
        public let changeRatio: Double?
        /// 有记录天中的最高/最低日摄入；无记录时为 nil
        public let maxDayCalories: Double?
        public let minDayCalories: Double?
    }

    /// 近 N 天（含今天）的饮食摄入趋势。
    /// - Parameters:
    ///   - dayCount: 窗口天数（至少 1）；奇数天时前半取 floor(N/2) 天、后半取剩余天
    public static func dietTrend(
        entries: [DietEntry],
        now: Date = .now,
        calendar: Calendar = .current,
        dayCount: Int = 7
    ) -> DietTrend {
        let count = max(1, dayCount)
        let todayStart = calendar.startOfDay(for: now)

        var dayStarts: [Date] = []
        for step in stride(from: count - 1, through: 0, by: -1) {
            dayStarts.append(calendar.date(byAdding: .day, value: -step, to: todayStart) ?? todayStart)
        }

        var caloriesByDay = [Date: Double](minimumCapacity: count)
        var flagsByDay = [Date: Bool](minimumCapacity: count)
        for entry in entries {
            let start = calendar.startOfDay(for: entry.date)
            // 只统计窗口内（含今天与最早一天整天）
            guard start >= dayStarts[0] else { continue }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStarts[count - 1]), start < next else { continue }
            caloriesByDay[start, default: 0] += entry.calories
            flagsByDay[start] = true
        }

        let days: [DailyDietPoint] = dayStarts.map { start in
            DailyDietPoint(
                dayStart: start,
                calories: caloriesByDay[start] ?? 0,
                hasRecords: flagsByDay[start] ?? false
            )
        }

        let recorded = days.filter(\.hasRecords)
        let recordedDays = recorded.count
        let averageCalories = recordedDays > 0
            ? recorded.reduce(0.0) { $0 + $1.calories } / Double(recordedDays)
            : 0

        // 前半 = 前 floor(N/2) 天，后半 = 剩余天（含今天）
        let earlierCount = count / 2
        let earlierDays = Array(days.prefix(earlierCount)).filter(\.hasRecords)
        let recentDays = Array(days.dropFirst(earlierCount)).filter(\.hasRecords)
        let earlierAverage = earlierDays.isEmpty
            ? 0
            : earlierDays.reduce(0.0) { $0 + $1.calories } / Double(earlierDays.count)
        let recentAverage = recentDays.isEmpty
            ? 0
            : recentDays.reduce(0.0) { $0 + $1.calories } / Double(recentDays.count)

        var changeRatio: Double? = nil
        if earlierAverage > 0 {
            changeRatio = (recentAverage - earlierAverage) / earlierAverage
        }

        let recordedCalories = recorded.map(\.calories)
        return DietTrend(
            days: days,
            recordedDays: recordedDays,
            averageCalories: averageCalories,
            recentAverage: recentAverage,
            earlierAverage: earlierAverage,
            changeRatio: changeRatio,
            maxDayCalories: recordedCalories.max(),
            minDayCalories: recordedCalories.min()
        )
    }

    // MARK: - 健康趋势（睡眠 / 健康分数）

    /// 一条健康日快照（仅趋势所需字段；缺失指标为 nil，**不得用 0 顶替**）
    public struct HealthEntry: Equatable, Sendable {
        public let date: Date
        /// 睡眠时长（小时）
        public let sleepHours: Double?
        /// 健康/活力分数（0~100）
        public let vitalityScore: Double?

        public init(date: Date, sleepHours: Double? = nil, vitalityScore: Double? = nil) {
            self.date = date
            self.sleepHours = sleepHours
            self.vitalityScore = vitalityScore
        }
    }

    /// 单日健康汇总点（图表直接消费）。无数据的指标为 nil，与「0 小时睡眠」严格区分。
    public struct DailyHealthPoint: Equatable, Sendable, Identifiable {
        public var id: Date { dayStart }
        /// 当日起点（用于图表横轴）
        public let dayStart: Date
        public let sleepHours: Double?
        public let vitalityScore: Double?

        public init(dayStart: Date, sleepHours: Double? = nil, vitalityScore: Double? = nil) {
            self.dayStart = dayStart
            self.sleepHours = sleepHours
            self.vitalityScore = vitalityScore
        }

        public var hasSleep: Bool { sleepHours != nil }
        public var hasScore: Bool { vitalityScore != nil }
        /// 当日是否有任一健康数据
        public var hasRecords: Bool { hasSleep || hasScore }
    }

    public struct HealthTrend: Equatable, Sendable {
        /// 由旧到新的日序列（含今天；无数据日指标为 nil）
        public let days: [DailyHealthPoint]
        /// 有睡眠数据的天数
        public let sleepRecordedDays: Int
        /// 有分数数据的天数
        public let scoreRecordedDays: Int
        /// 有睡眠数据天的日均睡眠（小时）；无数据时为 nil（不伪造 0 小时）
        public let averageSleepHours: Double?
        /// 后半段（含今天）有睡眠数据天的日均；该半段无数据时为 nil
        public let recentAverageSleepHours: Double?
        /// 前半段有睡眠数据天的日均；该半段无数据时为 nil
        public let earlierAverageSleepHours: Double?
        /// 后半相对前半的睡眠均值变化；任一半无数据时无基线，为 nil
        public let sleepChangeRatio: Double?
        /// 有分数天的日均分；无数据时为 nil
        public let averageScore: Double?
        /// 后半段日均分；该半段无数据时为 nil
        public let recentAverageScore: Double?
        /// 前半段日均分；该半段无数据时为 nil
        public let earlierAverageScore: Double?
        /// 后半相对前半的分数均值变化；任一半无数据时为 nil
        public let scoreChangeRatio: Double?
    }

    /// 近 N 天（含今天）的健康趋势。
    /// - Parameters:
    ///   - dayCount: 窗口天数（至少 1）；前半取 floor(N/2) 天、后半取剩余天（含今天）
    public static func healthTrend(
        entries: [HealthEntry],
        now: Date = .now,
        calendar: Calendar = .current,
        dayCount: Int = 7
    ) -> HealthTrend {
        let count = max(1, dayCount)
        let todayStart = calendar.startOfDay(for: now)

        var dayStarts: [Date] = []
        for step in stride(from: count - 1, through: 0, by: -1) {
            dayStarts.append(calendar.date(byAdding: .day, value: -step, to: todayStart) ?? todayStart)
        }

        // 同一天多条时后者覆盖前者（落库已是日唯一；这里是防御）
        var sleepByDay = [Date: Double](minimumCapacity: count)
        var scoreByDay = [Date: Double](minimumCapacity: count)
        for entry in entries {
            let start = calendar.startOfDay(for: entry.date)
            guard start >= dayStarts[0] else { continue }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStarts[count - 1]), start < next else { continue }
            if let sleep = entry.sleepHours { sleepByDay[start] = sleep }
            if let score = entry.vitalityScore { scoreByDay[start] = score }
        }

        let days: [DailyHealthPoint] = dayStarts.map { start in
            DailyHealthPoint(
                dayStart: start,
                sleepHours: sleepByDay[start],
                vitalityScore: scoreByDay[start]
            )
        }

        let sleepValues = days.compactMap(\.sleepHours)
        let scoreValues = days.compactMap(\.vitalityScore)

        // 前半 = 前 floor(N/2) 天，后半 = 剩余天（含今天）
        let earlierCount = count / 2
        let earlierSleep = Array(days.prefix(earlierCount)).compactMap(\.sleepHours)
        let recentSleep = Array(days.dropFirst(earlierCount)).compactMap(\.sleepHours)
        let earlierScore = Array(days.prefix(earlierCount)).compactMap(\.vitalityScore)
        let recentScore = Array(days.dropFirst(earlierCount)).compactMap(\.vitalityScore)

        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        func change(earlier: Double?, recent: Double?) -> Double? {
            guard let earlier, earlier > 0, let recent else { return nil }
            return (recent - earlier) / earlier
        }

        return HealthTrend(
            days: days,
            sleepRecordedDays: sleepValues.count,
            scoreRecordedDays: scoreValues.count,
            averageSleepHours: average(sleepValues),
            recentAverageSleepHours: average(recentSleep),
            earlierAverageSleepHours: average(earlierSleep),
            sleepChangeRatio: change(earlier: average(earlierSleep), recent: average(recentSleep)),
            averageScore: average(scoreValues),
            recentAverageScore: average(recentScore),
            earlierAverageScore: average(earlierScore),
            scoreChangeRatio: change(earlier: average(earlierScore), recent: average(recentScore))
        )
    }
}
