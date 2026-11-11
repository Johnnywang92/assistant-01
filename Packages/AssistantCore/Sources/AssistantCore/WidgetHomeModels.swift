import Foundation

// MARK: - 桌面小组件 · 首页概览快照
//
// 方案 C 的工程红线在小组件侧同样成立：**状态数据由 Core 输出结构化事实，
// 扩展只渲染、不自行计算**。
//
// 为什么不让小组件自己算完成环：
// - 扩展进程拿不到主 App 的 SwiftData 上下文，只能读 App Group 快照；
// - 若各端各算一套，会出现「桌面显示 2/4、App 显示 3/4」这种对不上的静默失败；
// - 所以主 App 用**同一份** `HomeSnapshotBuilder` 算出快照，扩展只画。
//
// 这里刻意不复用 `HomeSnapshot` 本身：它是计算中间产物（含日期等非 Codable 语义），
// 小组件需要的是**可直接持久化、可直接渲染**的扁平事实。

/// 首页概览的小组件快照（与 App 首页同源）。
public struct WidgetHomeOverview: Codable, Hashable, Sendable {
    /// 已完成数
    public var done: Int
    /// 今日待办总数
    public var total: Int
    /// 剩余空闲分钟数（无日程时为 0，用 `isAllDayFree` 区分）
    public var freeMinutes: Int
    /// 无日程占用 → 写「全天空闲」而不是「0 分钟」
    public var isAllDayFree: Bool
    /// 主任务标题（Core 判定，视图不排序）
    public var priorityTaskTitle: String?
    /// 今日节奏：空闲占比（0...1）
    public var freeRatio: Double
    /// 今日节奏：已安排占比（0...1）
    public var busyRatio: Double

    public init(
        done: Int,
        total: Int,
        freeMinutes: Int,
        isAllDayFree: Bool,
        priorityTaskTitle: String?,
        freeRatio: Double,
        busyRatio: Double
    ) {
        self.done = done
        self.total = total
        self.freeMinutes = freeMinutes
        self.isAllDayFree = isAllDayFree
        self.priorityTaskTitle = priorityTaskTitle
        self.freeRatio = min(1, max(0, freeRatio))
        self.busyRatio = min(1, max(0, busyRatio))
    }

    /// 进度比例。空态不写 0/0，视图用 `state` 判断是否显示空环。
    public var progressFraction: Double {
        total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
    }

    /// 空闲时长的可读文案。口径与 App 首页一致：
    /// 无日程 → 「全天空闲」；否则 → 「4h16m」。
    public var freeTimeText: String {
        if isAllDayFree { return "全天空闲" }
        let hours = freeMinutes / 60
        let minutes = freeMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    public static let empty = WidgetHomeOverview(
        done: 0,
        total: 0,
        freeMinutes: 0,
        isAllDayFree: true,
        priorityTaskTitle: nil,
        freeRatio: 1,
        busyRatio: 0
    )
}

// MARK: - 纪念日倒计时快照

/// 一条纪念日的小组件快照。
public struct WidgetAnniversaryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// 距离下一次周年还有多少天（0 = 就是今天）
    public var daysUntil: Int
    /// 第几年（如结婚第 3 周年）
    public var yearsCount: Int
    /// 已相伴天数
    public var passedDays: Int
    /// 是否农历（决定文案里写不写「农历」）
    public var isLunar: Bool

    public init(
        id: UUID,
        title: String,
        daysUntil: Int,
        yearsCount: Int,
        passedDays: Int,
        isLunar: Bool
    ) {
        self.id = id
        self.title = title
        self.daysUntil = daysUntil
        self.yearsCount = yearsCount
        self.passedDays = passedDays
        self.isLunar = isLunar
    }

    /// 倒计时文案。今天 / 明天 / N 天后。
    public var countdownText: String {
        switch daysUntil {
        case 0: return "就是今天"
        case 1: return "明天"
        default: return "\(daysUntil) 天后"
        }
    }
}

// MARK: - 纪念日倒计时计算（Core 唯一实现）
//
// **修复了一个静默失败**：`AnniversaryItem.isLunar` 此前被完全忽略——
// `nextAnniversaryDate` 一律按公历 `[.month, .day]` 拼装，
// 用户填了农历生日就会算出错误的倒计时天数，且不报任何错。
//
// 现在农历换算统一走 `Calendar(identifier: .chinese)`，
// 与 `TravelTicketReminderManager` 的农历节日推算同源。
public enum AnniversaryCountdown {

    /// 计算下一次周年日期。
    ///
    /// - Parameters:
    ///   - targetDate: 原始起始/发生日期。
    ///   - isLunar: 是否按农历。
    ///   - now: 计算基准时刻，由调用方注入（禁止读墙上时钟）。
    ///   - calendar: 公历日历，由调用方注入（测试可固定时区）。
    /// - Returns: 下一次周年的公历日期；推算失败时回落到 `targetDate`。
    public static func nextAnniversaryDate(
        targetDate: Date,
        isLunar: Bool,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: now)

        if isLunar {
            var lunar = Calendar(identifier: .chinese)
            lunar.timeZone = calendar.timeZone
            let comps = lunar.dateComponents([.month, .day], from: targetDate)
            guard let lunarMonth = comps.month, let lunarDay = comps.day else {
                return targetDate
            }
            // 从今天往后最多找两年：农历年长 354~385 天，两年足够覆盖一个农历年。
            // 每年农历春节在公历 1/21~2/21 之间，扫 400 天即可覆盖一整农历年。
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else {
                return targetDate
            }
            for offset in 0...400 {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: start) else {
                    break
                }
                let candidateComps = lunar.dateComponents([.month, .day], from: candidate)
                if candidateComps.month == lunarMonth, candidateComps.day == lunarDay {
                    return candidate
                }
            }
            return targetDate
        }

        // 公历：今年同月同日，已过则推下一年
        let targetComps = calendar.dateComponents([.month, .day], from: targetDate)
        var thisYearComps = calendar.dateComponents([.year], from: today)
        thisYearComps.month = targetComps.month
        thisYearComps.day = targetComps.day

        guard let thisYearDate = calendar.date(from: thisYearComps) else { return targetDate }
        if thisYearDate >= today { return thisYearDate }

        thisYearComps.year = (thisYearComps.year ?? 2026) + 1
        return calendar.date(from: thisYearComps) ?? targetDate
    }

    /// 距离下一次周年还有多少天。
    public static func daysUntilNext(
        targetDate: Date,
        isLunar: Bool,
        now: Date,
        calendar: Calendar
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        let next = calendar.startOfDay(for: nextAnniversaryDate(
            targetDate: targetDate,
            isLunar: isLunar,
            now: now,
            calendar: calendar
        ))
        return max(0, calendar.dateComponents([.day], from: today, to: next).day ?? 0)
    }

    /// 当前是第几年。
    public static func yearsCount(
        targetDate: Date,
        isLunar: Bool,
        now: Date,
        calendar: Calendar
    ) -> Int {
        let next = nextAnniversaryDate(
            targetDate: targetDate,
            isLunar: isLunar,
            now: now,
            calendar: calendar
        )
        let startYear = calendar.component(.year, from: targetDate)
        let nextYear = calendar.component(.year, from: next)
        return max(1, nextYear - startYear)
    }

    /// 已相伴天数。
    public static func passedDays(
        targetDate: Date,
        now: Date,
        calendar: Calendar
    ) -> Int {
        let start = calendar.startOfDay(for: targetDate)
        let today = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: start, to: today).day ?? 0)
    }

    /// 组装一条纪念日快照。
    public static func entry(
        id: UUID,
        title: String,
        targetDate: Date,
        isLunar: Bool,
        now: Date,
        calendar: Calendar
    ) -> WidgetAnniversaryEntry {
        WidgetAnniversaryEntry(
            id: id,
            title: title,
            daysUntil: daysUntilNext(
                targetDate: targetDate,
                isLunar: isLunar,
                now: now,
                calendar: calendar
            ),
            yearsCount: yearsCount(
                targetDate: targetDate,
                isLunar: isLunar,
                now: now,
                calendar: calendar
            ),
            passedDays: passedDays(targetDate: targetDate, now: now, calendar: calendar),
            isLunar: isLunar
        )
    }
}
