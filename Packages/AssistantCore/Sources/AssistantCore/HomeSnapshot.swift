import Foundation

// MARK: - 首页概览 · 结构化事实
//
// 方案 C 的工程红线：**状态数据由 Core 输出结构化事实，视图只渲染、不自行计算**。
// 完成环数字、空闲时长、主任务判定、时间带比例一律在这里算完，
// App 层只负责翻译文案与画像素，不允许出现第二套口径。
//
// 设计约束（docs/home-redesign-handoff.md §2 / §4 / §7）：
// - 空态不隐藏概览卡，且「无日程」与「空闲 0 分钟」是两件不同的事；
// - 时间带色块宽度必须由窗口比例推导，禁止硬编码；
// - 主任务由 Core 判定，视图不排序；
// - 提醒数 > 0 时只改该行颜色，不新增模块。

public enum HomeProgressState: Hashable, Sendable {
    case empty
    case partial(done: Int, total: Int)
    case allDone
}

public enum HomeTaskRowState: String, CaseIterable, Sendable {
    case pending
    case priority
    case completed
    case overdue
}

public enum HomeBannerTone: String, CaseIterable, Sendable {
    case success
    case warning
    case neutral
}

/// 不用 `default`，避开 Swift 关键字。
public enum HomeChipState: String, CaseIterable, Sendable {
    case normal
    case selected
}

public enum HomeTimelineSegment: String, CaseIterable, Hashable, Sendable {
    case free
    case busy
    case reminder
}

/// 时间带的**一段**。`weight` 是该段占当日窗口的比例（0...1），
/// 视图用它算宽度；这里不产任何像素值，杜绝两端各写一套硬编码。
public struct HomeTimelineSlice: Hashable, Sendable {
    public let segment: HomeTimelineSegment
    public let weight: Double

    public init(segment: HomeTimelineSegment, weight: Double) {
        self.segment = segment
        self.weight = max(0, min(1, weight))
    }
}

/// 一条待办的纯值快照，App 层从 SwiftData 模型映射而来。
public struct HomeTodoFact: Hashable, Sendable {
    public let id: UUID
    public let isDone: Bool
    public let dueAt: Date?
    public let createdAt: Date
    public let isOverdue: Bool

    public init(
        id: UUID = UUID(),
        isDone: Bool,
        dueAt: Date? = nil,
        createdAt: Date,
        isOverdue: Bool = false
    ) {
        self.id = id
        self.isDone = isDone
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.isOverdue = isOverdue
    }
}

public struct HomeBusyInterval: Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// 当日日程窗口。**终点不含**，与周期报告窗口口径一致。
public struct HomeScheduleFact: Hashable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    public let busy: [HomeBusyInterval]
    public let reminders: [Date]

    public init(
        windowStart: Date,
        windowEnd: Date,
        busy: [HomeBusyInterval] = [],
        reminders: [Date] = []
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.busy = busy
        self.reminders = reminders
    }

    /// 没有安排任何日程（空态）：此时空闲写「全天空闲」，不写 0。
    public static let unscheduled = HomeScheduleFact(
        windowStart: .distantPast,
        windowEnd: .distantPast
    )

    public var hasSchedule: Bool { windowEnd > windowStart }

    /// 窗口内是否真的有占用。空态口径：无日程 ≠ 空闲 0 分钟，
    /// 只有「一个占用都没有」才写「全天空闲」。
    public var hasOccupancy: Bool { !busy.isEmpty || !reminders.isEmpty }
}

/// 首页一屏只回答三个问题的全部事实：还剩多少、节奏如何、接下来做什么。
public struct HomeSnapshot: Hashable, Sendable {
    public let done: Int
    public let total: Int
    public let freeMinutes: Int
    public let reminderCount: Int
    public let priorityTaskID: UUID?
    public let segments: [HomeTimelineSlice]
    public let state: HomeProgressState
    public let bannerTone: HomeBannerTone
    public let hasSchedule: Bool
    public let hasOccupancy: Bool

    public init(
        done: Int,
        total: Int,
        freeMinutes: Int,
        reminderCount: Int,
        priorityTaskID: UUID?,
        segments: [HomeTimelineSlice],
        state: HomeProgressState,
        bannerTone: HomeBannerTone,
        hasSchedule: Bool,
        hasOccupancy: Bool
    ) {
        self.done = done
        self.total = total
        self.freeMinutes = freeMinutes
        self.reminderCount = reminderCount
        self.priorityTaskID = priorityTaskID
        self.segments = segments
        self.state = state
        self.bannerTone = bannerTone
        self.hasSchedule = hasSchedule
        self.hasOccupancy = hasOccupancy
    }

    public static let empty = HomeSnapshot(
        done: 0,
        total: 0,
        freeMinutes: 0,
        reminderCount: 0,
        priorityTaskID: nil,
        segments: [HomeTimelineSlice(segment: .free, weight: 1)],
        state: .empty,
        bannerTone: .success,
        hasSchedule: false,
        hasOccupancy: false
    )

    public var progressFraction: Double {
        total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
    }

    /// 空态口径：无日程 ≠ 空闲 0 分钟。UI 用这个开关决定写「全天空闲」还是具体时长。
    public var isAllDayFree: Bool { !hasOccupancy }
}

public enum HomeSnapshotBuilder {

    /// 从纯值事实一次性算出整屏快照。`now` / `calendar` 都真实参与计算，
    /// 测试可传固定日历；禁止在视图里改用 `Calendar.isDateInToday()` 读墙上时钟。
    public static func make(
        todos: [HomeTodoFact],
        schedule: HomeScheduleFact,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> HomeSnapshot {
        let total = todos.count
        let done = todos.reduce(into: 0) { result, item in
            if item.isDone { result += 1 }
        }

        let state: HomeProgressState
        if total == 0 {
            state = .empty
        } else if done == total {
            state = .allDone
        } else {
            state = .partial(done: done, total: total)
        }

        // 空闲时长与时间带比例来自唯一的公共计算，与今日时间轴同源
        let plan = DayScheduleCalculator.make(schedule: schedule, now: now)
        let reminderCount = schedule.reminders.filter { point in
            guard point >= now else { return false }
            return !schedule.hasSchedule || point < schedule.windowEnd
        }.count
        let tone: HomeBannerTone
        if reminderCount > 0 {
            tone = .warning
        } else if state == .allDone {
            tone = .success
        } else {
            tone = .neutral
        }

        return HomeSnapshot(
            done: done,
            total: total,
            freeMinutes: plan.freeMinutes,
            reminderCount: reminderCount,
            priorityTaskID: priorityID(todos: todos, now: now, calendar: calendar),
            segments: plan.segments,
            state: state,
            bannerTone: tone,
            hasSchedule: schedule.hasSchedule,
            hasOccupancy: schedule.hasOccupancy
        )
    }

    // MARK: - 主任务判定（视图不排序）

    private static func priorityID(
        todos: [HomeTodoFact],
        now: Date,
        calendar: Calendar
    ) -> UUID? {
        let candidates = todos.enumerated().filter { !$0.element.isDone }
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if a.isOverdue != b.isOverdue { return a.isOverdue }

            // 今天到期的排在未来日期之前；calendar 由调用方注入，测试可固定时区。
            let aToday = a.dueAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            let bToday = b.dueAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            if aToday != bToday { return aToday }

            switch (a.dueAt, b.dueAt) {
            case let (x?, y?) where x != y: return x < y
            case let (x?, y?) where x == y: break
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            default: break
            }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            // Array.sorted 不稳定，必须带原始下标兜底，保证同分事项顺序可复现
            return lhs.offset < rhs.offset
        }.first?.element.id
    }
}
