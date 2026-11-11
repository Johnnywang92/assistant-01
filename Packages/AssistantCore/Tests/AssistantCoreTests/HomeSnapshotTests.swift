import XCTest

@testable import AssistantCore

final class HomeSnapshotTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2
        return cal
    }()

    /// 2026-11-10（周二）10:00 作为参照时刻
    private var now: Date {
        date(2026, 11, 10, 10, 0)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi
        return calendar.date(from: comps)!
    }

    /// 09:00 – 21:00 的当日窗口（终点不含）
    private var schedule: HomeScheduleFact {
        HomeScheduleFact(
            windowStart: date(2026, 11, 10, 9, 0),
            windowEnd: date(2026, 11, 10, 21, 0)
        )
    }

    private func todo(isDone: Bool = false, due: Date? = nil, created: Date? = nil) -> HomeTodoFact {
        HomeTodoFact(
            isDone: isDone,
            dueAt: due,
            createdAt: created ?? date(2026, 11, 9, 8, 0)
        )
    }

    // MARK: - 环数字与三项指标同源

    func testRingAndMetricsShareOneSource() {
        let first = todo(isDone: true)
        let second = todo()
        let third = todo()
        let fourth = todo()

        let before = HomeSnapshotBuilder.make(
            todos: [first, second, third, fourth],
            schedule: schedule,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(before.done, 1)
        XCTAssertEqual(before.total, 4)
        XCTAssertEqual(before.state, .partial(done: 1, total: 4))
        XCTAssertEqual(before.progressFraction, 0.25)

        // 只把一件事改成完成：环、分母、状态、主任务必须一起变，不允许各自缓存
        let after = HomeSnapshotBuilder.make(
            todos: [first, HomeTodoFact(id: second.id, isDone: true, dueAt: second.dueAt, createdAt: second.createdAt), third, fourth],
            schedule: schedule,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(after.done, 2)
        XCTAssertEqual(after.total, 4, "分母不受完成状态影响")
        XCTAssertEqual(after.state, .partial(done: 2, total: 4))
        XCTAssertEqual(after.progressFraction, 0.5)
        XCTAssertNotEqual(after.priorityTaskID, before.priorityTaskID)
    }

    // MARK: - 空态 / 全完成 / 多提醒

    func testEmptyStateDoesNotHideOverviewAndNeverWritesZero() {
        let snapshot = HomeSnapshotBuilder.make(
            todos: [],
            schedule: .unscheduled,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.state, .empty)
        XCTAssertEqual(snapshot.done, 0)
        XCTAssertEqual(snapshot.total, 0)
        XCTAssertTrue(snapshot.isAllDayFree, "无日程应写「全天空闲」，不是空闲 0 分钟")
        XCTAssertFalse(snapshot.hasSchedule)
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.segments.first?.segment, .free)
        XCTAssertNil(snapshot.priorityTaskID)
    }

    func testAllDoneTurnsSuccessAndClearsPriority() {
        let items = (0..<4).map { _ in todo(isDone: true) }
        let snapshot = HomeSnapshotBuilder.make(
            todos: items,
            schedule: schedule,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.state, .allDone)
        XCTAssertEqual(snapshot.bannerTone, .success)
        XCTAssertNil(snapshot.priorityTaskID)
        XCTAssertEqual(snapshot.progressFraction, 1)
    }

    func testPendingRemindersOnlyTurnWarning() {
        let withReminders = HomeScheduleFact(
            windowStart: schedule.windowStart,
            windowEnd: schedule.windowEnd,
            reminders: [date(2026, 11, 10, 14, 0), date(2026, 11, 10, 18, 0)]
        )
        let snapshot = HomeSnapshotBuilder.make(
            todos: [todo(isDone: true), todo()],
            schedule: withReminders,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.reminderCount, 2)
        XCTAssertEqual(snapshot.bannerTone, .warning, "多提醒只改提示色，不新增模块")
        XCTAssertEqual(snapshot.total, 2, "提醒不混入待办分母")
        XCTAssertTrue(snapshot.segments.contains { $0.segment == .reminder })
    }

    func testExpiredReminderIsNotCounted() {
        let past = HomeScheduleFact(
            windowStart: schedule.windowStart,
            windowEnd: schedule.windowEnd,
            reminders: [date(2026, 11, 10, 8, 0)]
        )
        let snapshot = HomeSnapshotBuilder.make(
            todos: [todo()], schedule: past, now: now, calendar: calendar
        )
        XCTAssertEqual(snapshot.reminderCount, 0)
        XCTAssertEqual(snapshot.bannerTone, .neutral)
    }

    // MARK: - 时间带按窗口比例

    func testTimelineWeightsSumToOne() {
        let withBusy = HomeScheduleFact(
            windowStart: schedule.windowStart,
            windowEnd: schedule.windowEnd,
            busy: [HomeBusyInterval(start: date(2026, 11, 10, 12, 0), end: date(2026, 11, 10, 14, 0))],
            reminders: [date(2026, 11, 10, 16, 0)]
        )
        let snapshot = HomeSnapshotBuilder.make(
            todos: [todo()], schedule: withBusy, now: now, calendar: calendar
        )
        let sum = snapshot.segments.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(sum, 1.0, accuracy: 0.0001, "色块总宽必须等于整个窗口")
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.weight > 0 }, "不应产生 0 宽空段")
    }

    func testBusyIntervalsAreNotDoubleCounted() {
        // 两段重叠占用：10:00–11:00 与 10:30–11:30，实际只占 90 分钟
        let overlapping = HomeScheduleFact(
            windowStart: schedule.windowStart,
            windowEnd: schedule.windowEnd,
            busy: [
                HomeBusyInterval(start: date(2026, 11, 10, 10, 0), end: date(2026, 11, 10, 11, 0)),
                HomeBusyInterval(start: date(2026, 11, 10, 10, 30), end: date(2026, 11, 10, 11, 30))
            ]
        )
        let snapshot = HomeSnapshotBuilder.make(
            todos: [todo()], schedule: overlapping, now: now, calendar: calendar
        )
        // 10:00 → 21:00 = 11h = 660min，扣 90min 占用 = 570min
        XCTAssertEqual(snapshot.freeMinutes, 570)
    }

    func testWindowEndIsExclusiveForReminders() {
        let atEnd = HomeScheduleFact(
            windowStart: schedule.windowStart,
            windowEnd: schedule.windowEnd,
            reminders: [schedule.windowEnd]
        )
        let snapshot = HomeSnapshotBuilder.make(
            todos: [todo()], schedule: atEnd, now: now, calendar: calendar
        )
        XCTAssertEqual(snapshot.reminderCount, 0, "窗口终点不含，21:00 的提醒不属于当日窗口")
    }

    // MARK: - 主任务判定

    func testPriorityPrefersOverdueThenToday() {
        let overdue = HomeTodoFact(isDone: false, dueAt: date(2026, 11, 9, 18, 0), createdAt: now, isOverdue: true)
        let laterToday = todo(due: date(2026, 11, 10, 20, 0))
        let tomorrow = todo(due: date(2026, 11, 11, 9, 0))
        let snapshot = HomeSnapshotBuilder.make(
            todos: [tomorrow, laterToday, overdue],
            schedule: schedule,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(snapshot.priorityTaskID, overdue.id)
    }

    func testPriorityIsStableForIdenticalItems() {
        let items = (0..<6).map { _ in todo() }
        let first = HomeSnapshotBuilder.make(todos: items, schedule: schedule, now: now, calendar: calendar)
        let second = HomeSnapshotBuilder.make(todos: items, schedule: schedule, now: now, calendar: calendar)
        XCTAssertEqual(first.priorityTaskID, second.priorityTaskID, "同分事项必须靠原始下标稳定兜底")
        XCTAssertEqual(first.priorityTaskID, items.first?.id)
    }

    func testDoneItemIsNeverPriority() {
        let done = todo(isDone: true)
        let pending = todo()
        let snapshot = HomeSnapshotBuilder.make(
            todos: [done, pending], schedule: schedule, now: now, calendar: calendar
        )
        XCTAssertEqual(snapshot.priorityTaskID, pending.id)
    }
}
