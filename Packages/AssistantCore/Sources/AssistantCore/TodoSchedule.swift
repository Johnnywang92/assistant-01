import Foundation

/// 待办的时间形态。
/// - `none`：不设时间（纯清单事项）
/// - `point`：单个时间点，语义等同于历史的「截止时间」，落在 `endAt`
/// - `range`：时间段，`startAt` 到 `endAt`
public enum TodoTimeMode: String, Codable, CaseIterable, Sendable {
    case none
    case point
    case range
}

/// 重复的驱动方式。两套语义互斥，UI 必须显式二选一，避免「能选锚点却按顺延触发」的假功能。
public enum TodoRecurrenceMode: String, Codable, CaseIterable, Sendable {
    /// 完成后按固定天数顺延（历史语义，`RecurrencePlan.nextDueDate`）
    case afterCompletion
    /// 按日历锚点固定重复（每周几 / 每月几号），不随完成时刻漂移
    case calendarAnchor
}

/// 重复配置。`rule == .none` 时其余字段无意义。
public struct TodoRecurrenceConfig: Codable, Hashable, Sendable {
    public var rule: TodoRecurrenceRule
    public var customDays: Int
    public var mode: TodoRecurrenceMode

    /// `Calendar.component(.weekday)` 口径：1 = 周日 … 7 = 周六。
    /// 仅 `weekly` / `biweekly` + `.calendarAnchor` 生效。
    public var weekdays: [Int]

    /// 1...31；`-1` 表示「当月最后一天」。
    /// 不存在的日期（如 2 月 30 日）会跳过该月而不是钳制到月末，
    /// 避免历史上 `day: 31` 在短月静默不触发通知的问题。
    /// 仅 `monthly` + `.calendarAnchor` 生效。
    public var monthDays: [Int]

    /// 重复截止日（含）。nil = 永不结束。超过后不再生成下一期，也不再排通知。
    public var endAt: Date?

    public init(
        rule: TodoRecurrenceRule = .none,
        customDays: Int = 3,
        mode: TodoRecurrenceMode = .afterCompletion,
        weekdays: [Int] = [],
        monthDays: [Int] = [],
        endAt: Date? = nil
    ) {
        self.rule = rule
        self.customDays = customDays
        self.mode = mode
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.endAt = endAt
    }

    public static var none: TodoRecurrenceConfig {
        TodoRecurrenceConfig()
    }

    /// 锚点模式下是否真的配了可用锚点；没配就退回顺延语义，避免出现「选了日历却永无下一次」。
    public var hasUsableAnchor: Bool {
        switch rule {
        case .weekly, .biweekly: return !normalizedWeekdays.isEmpty
        case .monthly: return !normalizedMonthDays.isEmpty
        default: return false
        }
    }

    public var normalizedWeekdays: [Int] {
        Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
    }

    public var normalizedMonthDays: [Int] {
        Array(Set(monthDays.filter { $0 == -1 || (1...31).contains($0) })).sorted()
    }
}

/// 一条待办的完整日程。纯值类型，不认识 SwiftData 模型，规则全部可注入 `now` / `calendar` 单测。
public struct TodoSchedule: Codable, Hashable, Sendable {
    public var mode: TodoTimeMode
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool
    public var recurrence: TodoRecurrenceConfig
    /// 日历锚点的原始基准时刻。nil = 以 `endAt` 为基准（新建/存量数据）。
    /// 用户改期或逾期分流时冻结为改期前的 `endAt`，保证「每周一 / 双周 / 每月几号」
    /// 的相位不随「今天做」「跳过这一期」漂移。可选字段，旧 JSON 解码自动为 nil。
    public var anchorAt: Date?

    public init(
        mode: TodoTimeMode = .point,
        startAt: Date = .now,
        endAt: Date = .now,
        isAllDay: Bool = false,
        recurrence: TodoRecurrenceConfig = .none,
        anchorAt: Date? = nil
    ) {
        self.mode = mode
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
        self.recurrence = recurrence
        self.anchorAt = anchorAt
    }

    /// 历史「截止时间」的等价物，也是通知与排序的唯一时间锚点。
    public var effectiveDueAt: Date? {
        mode == .none ? nil : endAt
    }

    public var effectiveStartAt: Date? {
        mode == .range ? startAt : nil
    }

    /// 时间段必须起在前、止在后；无时间形态时不做要求。
    public var isValid: Bool {
        guard mode == .range else { return true }
        return startAt < endAt
    }

    /// 由历史的散字段构造旧语义日程：单时间点（或无时间）+ 完成后顺延。
    /// `scheduleRaw == nil` 的存量数据走这里，行为与改造前完全一致。
    public static func legacy(
        dueAt: Date?,
        ruleRaw: String?,
        customDays: Int,
        now: Date = .now
    ) -> TodoSchedule {
        let rule = TodoRecurrenceRule(rawValue: ruleRaw ?? "") ?? .none
        let mode: TodoTimeMode = dueAt == nil ? .none : .point
        let anchor = dueAt ?? now
        return TodoSchedule(
            mode: mode,
            startAt: anchor,
            endAt: anchor,
            isAllDay: false,
            recurrence: TodoRecurrenceConfig(rule: rule, customDays: customDays)
        )
    }

    /// 写入前统一收敛：排序去重锚点、修正非法时间段、规则为 none 时清空锚点。
    public func normalized() -> TodoSchedule {
        var result = self
        result.recurrence.weekdays = result.recurrence.normalizedWeekdays
        result.recurrence.monthDays = result.recurrence.normalizedMonthDays
        if result.recurrence.rule == .none {
            result.recurrence.mode = .afterCompletion
            result.recurrence.weekdays = []
            result.recurrence.monthDays = []
            result.recurrence.endAt = nil
        }
        if result.mode == .range, result.startAt >= result.endAt {
            result.startAt = result.endAt.addingTimeInterval(-3600)
        }
        return result
    }

    /// 改期到新的截止时刻（逾期分流「今天做 / 推到周末 / 指定日期 / 跳过这一期」统一走这里）。
    /// 时间段整体平移保留时长；重复配置、全天标记与锚点相位全部不动。
    /// 冻结 `anchorAt` 是关键：否则双周/月锚点会以改期后的日期重新起算，
    /// 出现「用户只是把这一期挪到今天，后面每一期却整体错开」的静默漂移。
    public func rescheduled(to newEndAt: Date) -> TodoSchedule {
        var result = self
        result.anchorAt = anchorAt ?? endAt
        let duration = mode == .range ? max(0, endAt.timeIntervalSince(startAt)) : 0
        result.endAt = newEndAt
        result.startAt = mode == .range
            ? newEndAt.addingTimeInterval(-duration)
            : newEndAt
        return result.normalized()
    }

    /// 外部把 `dueAt` 清成 nil 时，日程退回「不设时间」但保留重复配置与锚点，
    /// 不能直接丢弃整个日程（否则周期设置会静默消失）。
    public func clearingTime() -> TodoSchedule {
        var result = self
        result.anchorAt = anchorAt ?? endAt
        result.mode = .none
        return result.normalized()
    }

    /// 用于读时自愈：外部旧代码若直接改了 `dueAt`，判定是否与日程快照失配。
    /// 0.5 秒容差覆盖 JSON 编解码的浮点误差，DatePicker 精度远大于此。
    public func matches(dueAt: Date?) -> Bool {
        guard let dueAt else { return mode == .none }
        return mode != .none && abs(endAt.timeIntervalSince(dueAt)) <= 0.5
    }
}

public enum TodoScheduleCodec {
    public static func encode(_ schedule: TodoSchedule) -> String? {
        guard let data = try? JSONEncoder().encode(schedule) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 损坏的字符串按 nil 处理，调用方回落 legacy 解释，绝不因单个字段让列表白屏。
    public static func decode(_ raw: String?) -> TodoSchedule? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TodoSchedule.self, from: data)
    }
}

/// 下一次触发与下一期日程的纯计算。
public enum TodoScheduleRule {
    private static let maxIterations = 4_000

    /// 下一次触发时间。返回 nil 表示不应再有下一次（不重复 / 已过重复截止）。
    public static func nextDueDate(
        for schedule: TodoSchedule,
        after referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let config = schedule.recurrence
        guard config.rule != .none else { return nil }
        guard isWithinEndLimit(referenceDate, config: config) else { return nil }

        let candidate: Date?
        if config.mode == .calendarAnchor, config.hasUsableAnchor {
            candidate = anchoredNext(
                for: schedule,
                after: referenceDate,
                calendar: calendar
            )
        } else {
            candidate = RecurrencePlan.nextDueDate(
                dueAt: schedule.effectiveDueAt,
                rule: config.rule,
                customDays: config.customDays,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }
        guard let candidate, isWithinEndLimit(candidate, config: config) else { return nil }
        return candidate
    }

    /// 生成下一期日程：把时间段整体平移到新触发日，保留时长、时刻、锚点与截止。
    public static func nextSchedule(
        from schedule: TodoSchedule,
        after referenceDate: Date,
        calendar: Calendar = .current
    ) -> TodoSchedule? {
        guard let nextDue = nextDueDate(for: schedule, after: referenceDate, calendar: calendar) else {
            return nil
        }
        // 无时间形态的周期事项（纯清单打卡）仍要生成下一期，只是不产生 dueAt；
        // 推进内部游标即可，不能因为「没有时间」就静默停掉重复。
        guard schedule.mode != .none else {
            var untimed = schedule
            untimed.startAt = nextDue
            untimed.endAt = nextDue
            return untimed.normalized()
        }

        var next = schedule
        let duration = schedule.endAt.timeIntervalSince(schedule.startAt)
        next.endAt = nextDue
        next.startAt = schedule.mode == .range
            ? nextDue.addingTimeInterval(-max(0, duration))
            : nextDue
        return next.normalized()
    }

    // MARK: - 锚点计算

    private static func isWithinEndLimit(_ date: Date, config: TodoRecurrenceConfig) -> Bool {
        guard let limit = config.endAt else { return true }
        return date <= limit
    }

    private static func anchoredNext(
        for schedule: TodoSchedule,
        after referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        switch schedule.recurrence.rule {
        case .weekly, .biweekly:
            return nextWeekdayDate(for: schedule, after: referenceDate, calendar: calendar)
        case .monthly:
            return nextMonthDayDate(for: schedule, after: referenceDate, calendar: calendar)
        default:
            return nextDayIntervalDate(for: schedule, after: referenceDate, calendar: calendar)
        }
    }

    /// 按天间隔用日历加天（而不是加秒），避免 DST 让时刻漂移一小时。
    private static func nextDayIntervalDate(
        for schedule: TodoSchedule,
        after referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        let days = schedule.recurrence.rule.dayInterval(customDays: schedule.recurrence.customDays)
        guard days > 0 else { return nil }
        // 按天间隔同样以冻结锚点起算，改期不该让「每 3 天」重新排相位。
        var cursor = schedule.anchorAt ?? schedule.effectiveDueAt ?? referenceDate
        // 先按日历天差一次跳到参考时间附近，避免几年前的每日重复在循环里空转上千次。
        if cursor <= referenceDate {
            let gap = max(0, calendar.dateComponents([.day], from: cursor, to: referenceDate).day ?? 0)
            let steps = gap / days
            if let jumped = calendar.date(byAdding: .day, value: steps * days, to: cursor) {
                cursor = jumped
            }
        }
        for _ in 0..<maxIterations {
            guard let advanced = calendar.date(byAdding: .day, value: days, to: cursor) else { return nil }
            cursor = advanced
            if cursor > referenceDate { return cursor }
        }
        return nil
    }

    private static func nextWeekdayDate(
        for schedule: TodoSchedule,
        after referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        let weekdays = schedule.recurrence.normalizedWeekdays
        guard !weekdays.isEmpty else { return nil }
        // 时刻与双周奇偶都以冻结锚点为准，不随当前一期的改期漂移。
        let anchor = schedule.anchorAt ?? schedule.endAt
        let time = timeComponents(of: anchor, calendar: calendar)
        let anchorWeek = weekStart(of: anchor, calendar: calendar) ?? anchor
        // 双周：枚举两周，用「与锚点周相隔的周数」奇偶判定，跨年也不依赖 weekOfYear。
        let span = schedule.recurrence.rule == .biweekly ? 14 : 7
        let dayStart = calendar.startOfDay(for: referenceDate)

        for offset in 0...span {
            guard let day = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard weekdays.contains(weekday) else { continue }
            if schedule.recurrence.rule == .biweekly {
                guard let hitWeek = weekStart(of: day, calendar: calendar),
                      let weeks = calendar.dateComponents([.weekOfYear], from: anchorWeek, to: hitWeek).weekOfYear,
                      weeks % 2 == 0 else { continue }
            }
            guard let candidate = withTime(time, on: day, calendar: calendar),
                  candidate > referenceDate else { continue }
            return candidate
        }
        return nil
    }

    private static func nextMonthDayDate(
        for schedule: TodoSchedule,
        after referenceDate: Date,
        calendar: Calendar
    ) -> Date? {
        let days = schedule.recurrence.normalizedMonthDays
        guard !days.isEmpty else { return nil }
        let time = timeComponents(of: schedule.anchorAt ?? schedule.endAt, calendar: calendar)
        guard let monthStart = calendar.dateInterval(of: .month, for: referenceDate)?.start else { return nil }

        // 枚举 24 个月：足以覆盖任意锚点组合（含 2/29），且不会把不存在的日期钳制掉。
        // 同一月内可能有多个锚点（含「月末」），必须收集后取最早，不能遇到第一个就返回。
        var candidates: [Date] = []
        for monthOffset in 0..<24 {
            guard let currentMonth = calendar.date(byAdding: .month, value: monthOffset, to: monthStart),
                  let dayRange = calendar.range(of: .day, in: .month, for: currentMonth) else { continue }
            let lastDay = dayRange.count
            for day in days {
                let resolved = day == -1 ? lastDay : day
                // 关键：短月没有该日就跳过这个月，继续找下个月；绝不静默变成月末。
                guard (1...lastDay).contains(resolved) else { continue }
                var components = calendar.dateComponents([.year, .month], from: currentMonth)
                components.day = resolved
                components.hour = time.hour
                components.minute = time.minute
                components.second = time.second
                if let candidate = calendar.date(from: components), candidate > referenceDate {
                    candidates.append(candidate)
                }
            }
            if let earliest = candidates.min() { return earliest }
        }
        return candidates.min()
    }

    // MARK: - 日历工具

    private static func timeComponents(of date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.hour, .minute, .second], from: date)
    }

    private static func withTime(_ time: DateComponents, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        return calendar.date(from: components)
    }

    private static func weekStart(of date: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components)
    }
}
