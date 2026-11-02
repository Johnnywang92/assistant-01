import Foundation

/// 预算/生活费周期时间窗计算引擎（纯逻辑，下沉 AssistantCore）
/// 支持自然月（每月 1 日重置）与自定义生活费/发薪周期（每月 1~28 日任意指定）。
public enum BudgetCycleWindow {

    /// 计算指定日期在特定周期起始日下所归属的周期窗口
    /// - Parameters:
    ///   - date: 目标日期时刻
    ///   - startDay: 周期起始日（1~28，1 为自然月，默认 1）
    ///   - calendar: 日历实例
    /// - Returns:
    ///   - startDate: 本周期的起始日期（当天 00:00:00）
    ///   - endDate: 本周期的结束日期（下一周期起始前 1 秒）
    ///   - daysLeft: 包含今天在内，距离周期结束的剩余天数（≥ 1）
    ///   - totalDays: 本周期跨越的总天数（通常为 28~31 天）
    public static func window(
        for date: Date,
        startDay: Int = 1,
        calendar: Calendar = .current
    ) -> (startDate: Date, endDate: Date, daysLeft: Int, totalDays: Int) {
        let clampedDay = min(max(1, startDay), 28)
        let currentDay = calendar.component(.day, from: date)
        let startOfToday = calendar.startOfDay(for: date)

        let cycleStart: Date
        let nextCycleStart: Date

        if clampedDay == 1 {
            // 自然月：本月 1 日 00:00:00 到下月 1 日 00:00:00
            let comps = calendar.dateComponents([.year, .month], from: date)
            cycleStart = calendar.date(from: comps) ?? startOfToday
            nextCycleStart = calendar.date(byAdding: .month, value: 1, to: cycleStart) ?? startOfToday
        } else if currentDay >= clampedDay {
            // 当前日期已进入本月生活费周期：从本月 startDay 到下月 startDay
            var comps = calendar.dateComponents([.year, .month], from: date)
            comps.day = clampedDay
            cycleStart = calendar.date(from: comps) ?? startOfToday
            nextCycleStart = calendar.date(byAdding: .month, value: 1, to: cycleStart) ?? startOfToday
        } else {
            // 当前日期尚未到达本月发放日：处于上月发放延续周期，从上月 startDay 到本月 startDay
            var comps = calendar.dateComponents([.year, .month], from: date)
            comps.day = clampedDay
            nextCycleStart = calendar.date(from: comps) ?? startOfToday
            cycleStart = calendar.date(byAdding: .month, value: -1, to: nextCycleStart) ?? startOfToday
        }

        let cycleEnd = calendar.date(byAdding: .second, value: -1, to: nextCycleStart) ?? nextCycleStart

        // 周期总天数
        let totalDays = max(1, calendar.dateComponents([.day], from: cycleStart, to: nextCycleStart).day ?? 30)

        // 距离本周期结束的剩余天数（包含今天自身）
        let diff = calendar.dateComponents([.day], from: startOfToday, to: nextCycleStart).day ?? 1
        let daysLeft = max(1, diff)

        return (cycleStart, cycleEnd, daysLeft, totalDays)
    }

    /// 判定某笔账单记录是否处于基准时间对应的预算/生活费周期内
    public static func isInSameCycle(
        recordDate: Date,
        as baseDate: Date,
        startDay: Int = 1,
        calendar: Calendar = .current
    ) -> Bool {
        let win = window(for: baseDate, startDay: startDay, calendar: calendar)
        return recordDate >= win.startDate && recordDate <= win.endDate
    }

    /// 格式化周期的简要展示标签（如："10日~次月9日" 或 "自然月"）
    public static func formatCycleLabel(startDay: Int) -> String {
        let clamped = min(max(1, startDay), 28)
        if clamped == 1 {
            return "自然月"
        }
        let prevDay = clamped - 1
        return "\(clamped)日~次月\(prevDay)日"
    }
}

