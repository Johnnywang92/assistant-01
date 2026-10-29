import Foundation

/// 周期报告的窗口边界计算（纯值规则，可单测）。
///
/// ## 为什么单独下沉到 Core
///
/// 报告的「周期边界」是所有分析的地基：趋势序列取哪几段、环比对哪一段、
/// 季报/年报覆盖哪几天，全都由它决定。这类规则一旦依赖 `Calendar.current`
/// 的隐式设置（尤其是 `firstWeekday`），就会出现**同一份数据在不同设备上
/// 落在不同周期**的静默偏差——用户看到的周报跨了 6 天而不是 7 天，却没有任何报错。
///
/// 所以这里的所有规则都：
/// 1. 显式接收 `calendar` 与 `now`，不使用墙上时钟；
/// 2. 周窗口**锚定周一至周日**（`firstWeekday = 2`），不跟随地区设置漂移；
/// 3. 窗口终点统一为「下一周期的起点」且**不含**，因此「下一期 = 终点所在的窗口」
///    对日/周/月/季/年全部成立，无需为每种周期各写一套步进逻辑。
public enum ReportPeriodWindow {

    /// 一个报告周期的起止区间。`start` 含、`end` 不含。
    public struct Window: Equatable, Sendable {
        /// 周期起点（含）
        public let start: Date
        /// 周期终点（不含）。等于下一周期的起点。
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        /// 周期内的总天数（向上取整，至少 1）。
        public var dayCount: Int {
            let seconds = end.timeIntervalSince(start)
            guard seconds > 0 else { return 1 }
            return max(1, Int((seconds / 86400.0).rounded(.up)))
        }

        /// 周期是否包含给定时刻。
        public func contains(_ date: Date) -> Bool {
            date >= start && date < end
        }

        /// 从 `now` 起，周期内还剩几天（已过完则返回 0）。
        public func remainingDays(from now: Date, calendar: Calendar) -> Int {
            guard now < end else { return 0 }
            let fromDay = calendar.startOfDay(for: now)
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            let days = calendar.dateComponents([.day], from: fromDay, to: calendar.startOfDay(for: lastDay)).day ?? 0
            return max(0, days)
        }
    }

    /// 周期粒度。决定「包含某天的那一期」如何计算。
    ///
    /// 与 App 侧的 `ReportPeriodType` 一一对应，由 App 负责映射
    /// （App 认识自己的模型枚举，Core 不认识）。
    public enum Granularity: String, CaseIterable, Sendable {
        case day
        case week
        case month
        case quarter
        case year
    }

    // MARK: - 周窗口锚定

    /// 周窗口锚定周一（`firstWeekday = 2`）。
    ///
    /// 不用 `Calendar.current` 的 `firstWeekday`，因为它在 zh_CN / en_US / en_GB
    /// 之间不一致（周始日不同），会让同一周的记录被切进不同周报。
    public static func mondayFirstCalendar(base: Calendar = .current) -> Calendar {
        var cal = base
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    // MARK: - 单周期窗口

    /// 计算包含 `date` 的那个周期窗口。
    ///
    /// - Parameters:
    ///   - date: 目标日期（落在周期内任意位置都返回同一个窗口）
    ///   - granularity: 周期粒度
    ///   - calendar: 日历；周窗口内部会强制锚定周一
    public static func window(
        containing date: Date,
        granularity: Granularity,
        calendar: Calendar
    ) -> Window {
        switch granularity {
        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
            return Window(start: start, end: end)

        case .week:
            return weekWindow(containing: date, calendar: calendar)

        case .month:
            return monthWindow(containing: date, calendar: calendar)

        case .quarter:
            return quarterWindow(containing: date, calendar: calendar)

        case .year:
            return yearWindow(containing: date, calendar: calendar)
        }
    }

    // MARK: - 自然周期边界

    /// 自然周窗口（周一至周日），锚定周一。
    public static func weekWindow(containing date: Date, calendar: Calendar) -> Window {
        let cal = mondayFirstCalendar(base: calendar)
        let startOfDay = cal.startOfDay(for: date)
        // weekday: 1=周日 ... 7=周六。转成「距周一的天数」：周日为 6 天前。
        let weekday = cal.component(.weekday, from: startOfDay)
        let daysFromMonday = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
        let nextMonday = cal.date(byAdding: .day, value: 7, to: monday) ?? monday.addingTimeInterval(604800)
        return Window(start: monday, end: nextMonday)
    }

    /// 自然月窗口：月初 00:00 至次月月初 00:00。
    public static func monthWindow(containing date: Date, calendar: Calendar) -> Window {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: comps) ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(86400 * 30)
        return Window(start: start, end: end)
    }

    /// 自然季度窗口：季度首月月初至下一季度首月月初。
    public static func quarterWindow(containing date: Date, calendar: Calendar) -> Window {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let month = comps.month ?? 1
        let quarter = (month - 1) / 3 + 1
        let startMonth = (quarter - 1) * 3 + 1
        let start = calendar.date(from: DateComponents(year: comps.year, month: startMonth, day: 1))
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 3, to: start)
            ?? start.addingTimeInterval(86400 * 92)
        return Window(start: start, end: end)
    }

    /// 自然年窗口：1 月 1 日至次年 1 月 1 日。
    public static func yearWindow(containing date: Date, calendar: Calendar) -> Window {
        let comps = calendar.dateComponents([.year], from: date)
        let start = calendar.date(from: DateComponents(year: comps.year, month: 1, day: 1))
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .year, value: 1, to: start)
            ?? start.addingTimeInterval(86400 * 366)
        return Window(start: start, end: end)
    }

    // MARK: - 周期序列（趋势分析用）

    /// 回溯生成包含 `date` 所在周期的连续 `count` 个周期窗口，**由旧到新**排列。
    ///
    /// 步进规则统一为「终点所在窗口」：因为每个窗口的 `end` 就是下一周期的 `start`，
    /// 所以 `window(containing: end)` 天然就是下一期，无需按粒度分别写推进逻辑。
    /// 这条性质对日/周/月/季/年全部成立——2 月只有 28 天也不会让序列错位。
    ///
    /// - Parameters:
    ///   - count: 周期个数。1 表示只有当期；趋势分析建议周报取 8~12、月报取 6~12。
    public static func series(
        containing date: Date,
        count: Int,
        granularity: Granularity,
        calendar: Calendar
    ) -> [Window] {
        guard count > 0 else { return [] }
        let current = window(containing: date, granularity: granularity, calendar: calendar)

        // 先退到最早一期，再逐期向前，避免逐期回退时受月末长度差异影响。
        var anchor = current.start
        for _ in 0..<(count - 1) {
            anchor = previousWindow(before: anchor, granularity: granularity, calendar: calendar).start
        }

        var result: [Window] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let w = window(containing: anchor, granularity: granularity, calendar: calendar)
            result.append(w)
            anchor = w.end
        }
        return result
    }

    /// 下一个周期窗口（`end` 所在的那个窗口）。
    public static func nextWindow(
        after window: Window,
        granularity: Granularity,
        calendar: Calendar
    ) -> Window {
        self.window(containing: window.end, granularity: granularity, calendar: calendar)
    }

    /// 上一个周期窗口（`start` 前一瞬间所在的那个窗口）。
    public static func previousWindow(
        before start: Date,
        granularity: Granularity,
        calendar: Calendar
    ) -> Window {
        let probe = start.addingTimeInterval(-1)
        return window(containing: probe, granularity: granularity, calendar: calendar)
    }

    // MARK: - 月末 / 季末 / 年末（调度用）

    /// 当月最后一天（当日 00:00）。
    ///
    /// 月报在「每月最后一天」推送——这是用户明确要求的口径，
    /// 而 `UNCalendarNotificationTrigger` 的 `day: 31` 在 2 月/4 月等短月**不会触发**，
    /// 所以调度侧必须用这个方法枚举出未来若干月的真实最后一天，逐月注册。
    public static func lastDayOfMonth(containing date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        // `comps` 只含年与月，得到的就是当月 1 日 00:00。
        let monthStart = calendar.date(from: comps) ?? calendar.startOfDay(for: date)
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else {
            return calendar.startOfDay(for: date)
        }
        // range.count 是当月总天数，最后一天 = 月初 + (总天数 - 1)
        return calendar.date(byAdding: .day, value: range.count - 1, to: monthStart)
            ?? calendar.startOfDay(for: date)
    }

    /// 该季度最后一天（当日 00:00）：3/6/9/12 月的最后一天。
    public static func lastDayOfQuarter(containing date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let month = comps.month ?? 1
        let quarter = (month - 1) / 3 + 1
        let quarterEndMonth = quarter * 3
        let anchor = calendar.date(from: DateComponents(year: comps.year, month: quarterEndMonth, day: 1))
            ?? calendar.startOfDay(for: date)
        return lastDayOfMonth(containing: anchor, calendar: calendar)
    }

    /// 该年最后一天（12 月 31 日，当日 00:00）。
    public static func lastDayOfYear(containing date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year], from: date)
        let anchor = calendar.date(from: DateComponents(year: comps.year, month: 12, day: 1))
            ?? calendar.startOfDay(for: date)
        return lastDayOfMonth(containing: anchor, calendar: calendar)
    }

    /// 未来 `count` 个「每月最后一天」（由近到远，含 `reference` 所在月的最后一天）。
    public static func upcomingMonthEnds(
        from reference: Date,
        count: Int,
        calendar: Calendar
    ) -> [Date] {
        var result: [Date] = []
        var anchor = reference
        for _ in 0..<max(0, count) {
            let lastDay = lastDayOfMonth(containing: anchor, calendar: calendar)
            result.append(lastDay)
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: lastDay) else { break }
            anchor = nextMonth
        }
        return result
    }

    /// 未来 `count` 个「每季度最后一天」（由近到远）。
    public static func upcomingQuarterEnds(
        from reference: Date,
        count: Int,
        calendar: Calendar
    ) -> [Date] {
        var result: [Date] = []
        var anchor = reference
        for _ in 0..<max(0, count) {
            let lastDay = lastDayOfQuarter(containing: anchor, calendar: calendar)
            result.append(lastDay)
            guard let next = calendar.date(byAdding: .month, value: 3, to: lastDay) else { break }
            anchor = next
        }
        return result
    }

    /// 未来 `count` 个「每年最后一天」（由近到远）。
    public static func upcomingYearEnds(
        from reference: Date,
        count: Int,
        calendar: Calendar
    ) -> [Date] {
        var result: [Date] = []
        var anchor = reference
        for _ in 0..<max(0, count) {
            let lastDay = lastDayOfYear(containing: anchor, calendar: calendar)
            result.append(lastDay)
            guard let next = calendar.date(byAdding: .year, value: 1, to: lastDay) else { break }
            anchor = next
        }
        return result
    }
}
