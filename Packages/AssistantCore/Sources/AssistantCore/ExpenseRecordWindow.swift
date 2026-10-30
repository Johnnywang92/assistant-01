import Foundation

/// 预算播报所需的最小取数窗口：本月 + 昨日 + 本周一至今天。
///
/// 月初、周初与月份边界重叠时，昨日与本周一都在上个月；窗口取三者最早值，
/// 这样既能覆盖 `SafeToSpendCalculator.inputFromRecords` 用到的全部日期，
/// 又不必把整本账物化到主线程。
public enum ExpenseRecordWindow {
    public static func budgetWindow(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

        let weekday = calendar.component(.weekday, from: now)
        let daysFromMonday = weekday == 1 ? 6 : weekday - 2
        let startOfWeekMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfToday) ?? startOfToday

        let start = min(startOfMonth, min(startOfYesterday, startOfWeekMonday))
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        return DateInterval(start: start, end: end)
    }
}
