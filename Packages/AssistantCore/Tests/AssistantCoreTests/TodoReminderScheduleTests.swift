import XCTest
@testable import AssistantCore

/// 临期提醒提前量与批量重排选择的回归测试。
/// 核心风险：编辑截止时间/点「稍后」后提醒时刻算错、重排截断口径漂移
/// （文档曾写 50 项上限，代码事实为 15，以代码为准并在下方钉住）。
final class TodoReminderScheduleTests: XCTestCase {

    /// 固定 now：2026-06-01 12:00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_780_315_200)
    private let day: TimeInterval = 86_400

    private func item(_ id: UUID = UUID(), dueAt: Date?, overrideAt: Date? = nil, leadMinutes: Int = 0) -> TodoReminderSchedule.Item {
        TodoReminderSchedule.Item(id: id, dueAt: dueAt, reminderOverrideAt: overrideAt, remindBeforeMinutes: leadMinutes)
    }

    private func main(_ dueAt: Date, leadMinutes: Int, overrideAt: Date? = nil) -> Date? {
        TodoReminderSchedule.mainReminderDate(dueAt: dueAt, remindBeforeMinutes: leadMinutes,
                                              reminderOverrideAt: overrideAt, now: now)
    }

    // MARK: - 提前量

    func testLeadZeroRemindsAtDueAt() {
        let due = now + 2 * 3600
        XCTAssertEqual(main(due, leadMinutes: 0), due)
    }

    func testLeadFiveMinutes() {
        let due = now + 2 * 3600
        XCTAssertEqual(main(due, leadMinutes: 5), due - 5 * 60)
    }

    func testLeadOneHour() {
        let due = now + 3 * 3600
        XCTAssertEqual(main(due, leadMinutes: 60), due - 3600)
    }

    func testLeadOneDay() {
        let due = now + 2 * day
        XCTAssertEqual(main(due, leadMinutes: 1440), due - day)
    }

    func testLeadCustomNinetyMinutes() {
        let due = now + 4 * 3600
        XCTAssertEqual(main(due, leadMinutes: 90), due - 90 * 60)
    }

    /// 提前量把提醒点推到过去时，回落到 dueAt 本身（事项还有未来到期意义）。
    func testLeadAlreadyElapsedFallsBackToDueAt() {
        let due = now + 10 * 60
        XCTAssertEqual(main(due, leadMinutes: 60), due)
    }

    /// 主提醒、dueAt、三次逾期补提醒全部落在过去 → 不再排期。
    func testFullyPastItemGetsNoReminder() {
        XCTAssertNil(main(now - 3 * day, leadMinutes: 30))
        XCTAssertNil(main(now - 3 * day, leadMinutes: 30, overrideAt: now - 3600))
    }

    /// 刚过期但仍有未来逾期补提醒：保持原实现语义，返回（过去的）计划时刻，
    /// 由 app 侧 max(1, …) 兜底为立即触发。
    func testRecentlyPastDueStillSchedulesForFutureOverdue() {
        let due = now - 2 * 3600
        XCTAssertEqual(main(due, leadMinutes: 30), due)
    }

    // MARK: - override 与提前量并存

    /// 「稍后提醒」写入 override 后，无条件优先于提前量。
    func testOverrideWinsOverLeadTime() {
        let due = now + 2 * 3600
        let override = now + 3 * 3600
        XCTAssertEqual(main(due, leadMinutes: 30, overrideAt: override), override)
    }

    /// 钉住现状：即使 override 在过去而 dueAt 在未来，主提醒时刻仍取 override（不改 dueAt 语义）。
    func testPastOverrideStillPreferredOverLead() {
        let due = now + 2 * 3600
        let override = now - 60
        XCTAssertEqual(main(due, leadMinutes: 30, overrideAt: override), override)
    }

    func testNegativeLeadClampedToZero() {
        let due = now + 3600
        XCTAssertEqual(main(due, leadMinutes: -30), due)
    }

    // MARK: - 逾期补提醒

    func testOverdueOffsetValues() {
        XCTAssertEqual(TodoReminderSchedule.overdueOffsets, [3600, 3 * 3600, 24 * 3600])
    }

    func testFutureOverdueOffsetsSelection() {
        XCTAssertEqual(TodoReminderSchedule.futureOverdueOffsets(dueAt: now + 12 * 3600, now: now),
                       [3600, 3 * 3600, 24 * 3600])
        XCTAssertEqual(TodoReminderSchedule.futureOverdueOffsets(dueAt: now + 2 * 3600, now: now),
                       [3600, 3 * 3600, 24 * 3600])
        // 到期 2 小时后才排期：1 小时补提醒已过点，只剩 3 小时与 24 小时
        XCTAssertEqual(TodoReminderSchedule.futureOverdueOffsets(dueAt: now - 2 * 3600, now: now),
                       [3 * 3600, 24 * 3600])
        XCTAssertEqual(TodoReminderSchedule.futureOverdueOffsets(dueAt: now - 23 * 3600, now: now),
                       [24 * 3600])
        XCTAssertEqual(TodoReminderSchedule.futureOverdueOffsets(dueAt: now - 2 * day, now: now), [])
    }

    // MARK: - 是否值得重排

    func testNeedsReschedule() {
        XCTAssertTrue(TodoReminderSchedule.needsReschedule(item(dueAt: now + 60), now: now))
        XCTAssertTrue(TodoReminderSchedule.needsReschedule(item(dueAt: now - 2 * 3600), now: now)) // 未来逾期补提醒
        XCTAssertTrue(TodoReminderSchedule.needsReschedule(item(dueAt: now - 3 * day, overrideAt: now + 60), now: now))
        XCTAssertTrue(TodoReminderSchedule.needsReschedule(item(dueAt: nil, overrideAt: now + 60), now: now))
        XCTAssertFalse(TodoReminderSchedule.needsReschedule(item(dueAt: nil), now: now))
        XCTAssertFalse(TodoReminderSchedule.needsReschedule(item(dueAt: now - 3 * day), now: now))
    }

    // MARK: - 排序键

    func testSortKeyPrefersOverrideThenDueMinusLead() {
        let due = now + 2 * 3600
        let override = now + 30 * 60
        XCTAssertEqual(TodoReminderSchedule.sortKey(item(dueAt: due, leadMinutes: 15)), due - 15 * 60)
        XCTAssertEqual(TodoReminderSchedule.sortKey(item(dueAt: due, overrideAt: override, leadMinutes: 15)), override)
    }

    /// 钉住现状：排序键不 clamp 负提前量（与逐项排期的 mainReminderDate 口径不同）。
    func testSortKeyDoesNotClampNegativeLead() {
        let due = now + 3600
        XCTAssertEqual(TodoReminderSchedule.sortKey(item(dueAt: due, leadMinutes: -60)), due + 3600)
    }

    func testSortKeyWithoutDueAtUsesDistantFuture() {
        let key = TodoReminderSchedule.sortKey(item(dueAt: nil, leadMinutes: 10))
        XCTAssertEqual(key.timeIntervalSince(now), Date.distantFuture.timeIntervalSince(now) - 600, accuracy: 1)
    }

    // MARK: - 批量重排选择与 15 项截断

    /// 钉死代码事实：上限是 15（todo.md 等文档写 50 已过时）。
    func testMaxScheduledItemsIsFifteen() {
        XCTAssertEqual(TodoReminderSchedule.maxScheduledItems, 15)
    }

    /// 20 项竞争：截断口径 = 触发最近的 15 项，最晚到期的 5 项被丢弃。
    func testSelectsNearestFifteenOfTwenty() {
        let ids = (0..<20).map { _ in UUID() }
        let items = ids.enumerated().map { index, id in
            item(id, dueAt: now + Double(index + 1) * 3600, leadMinutes: 10)
        }
        let selected = TodoReminderSchedule.selectItemsForRescheduling(items, now: now)
        XCTAssertEqual(selected.count, 15)
        XCTAssertEqual(selected.map(\.id), Array(ids[0..<15]))
    }

    /// 全无未来提醒的项即使名额充裕也不入选（与截断无关）。
    func testExpiredItemsExcludedEvenWithFreeQuota() {
        let live = item(dueAt: now + 3600)
        let dead = [item(dueAt: now - 3 * day), item(dueAt: nil), item(dueAt: now - 4 * day, overrideAt: now - 3600)]
        let selected = TodoReminderSchedule.selectItemsForRescheduling(dead + [live], now: now)
        XCTAssertEqual(selected.map(\.id), [live.id])
    }

    /// override 近的项排在前面并拿到名额，dueAt 更晚但被挤出的项落选。
    func testOverrideReordersSelection() {
        let earlyOverrideID = UUID()
        let a = item(earlyOverrideID, dueAt: now + 10 * day, overrideAt: now + 60)
        let b = item(dueAt: now + 2 * 3600)
        let selected = TodoReminderSchedule.selectItemsForRescheduling([b, a], now: now, limit: 1)
        XCTAssertEqual(selected.map(\.id), [earlyOverrideID])
    }

    func testLimitParameterOverridesDefault() {
        let items = (0..<8).map { index in item(UUID(), dueAt: now + Double(index) * 60) }
        XCTAssertEqual(TodoReminderSchedule.selectItemsForRescheduling(items, now: now, limit: 3).count, 3)
    }

    // MARK: - 跨时区

    /// 用固定时区构造 DateComponents，断言提醒时刻是绝对瞬间、与机器时区无关。
    func testAbsoluteReminderTimeAcrossTimezones() throws {
        func date(_ tz: String, year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = try! XCTUnwrap(TimeZone(identifier: tz))
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day; comps.hour = hour; comps.minute = minute
            return cal.date(from: comps)
        }

        // 上海 09:00 到期、提前 30 分钟 → 上海 08:30（同一绝对瞬间 = UTC 00:30）
        let shanghaiDue = try XCTUnwrap(date("Asia/Shanghai", year: 2026, month: 6, day: 15, hour: 9, minute: 0))
        let shanghaiPlanned = try XCTUnwrap(TodoReminderSchedule.mainReminderDate(
            dueAt: shanghaiDue, remindBeforeMinutes: 30, reminderOverrideAt: nil,
            now: shanghaiDue - 4 * 3600))
        XCTAssertEqual(shanghaiPlanned.timeIntervalSince(shanghaiDue), -1800)
        let shanghaiExpected = try XCTUnwrap(date("Asia/Shanghai", year: 2026, month: 6, day: 15, hour: 8, minute: 30))
        XCTAssertEqual(shanghaiPlanned, shanghaiExpected)

        // 纽约 09:00（EDT，UTC-4）到期 → 提醒点必须是纽约 08:30 的绝对瞬间
        let newYorkDue = try XCTUnwrap(date("America/New_York", year: 2026, month: 6, day: 15, hour: 9, minute: 0))
        let newYorkPlanned = try XCTUnwrap(TodoReminderSchedule.mainReminderDate(
            dueAt: newYorkDue, remindBeforeMinutes: 30, reminderOverrideAt: nil,
            now: newYorkDue - 4 * 3600))
        let newYorkExpected = try XCTUnwrap(date("America/New_York", year: 2026, month: 6, day: 15, hour: 8, minute: 30))
        XCTAssertEqual(newYorkPlanned, newYorkExpected)

        // 同一本地墙钟时刻在不同时区是两个不同瞬间，提醒时刻也必须随之不同（差 = 时区差）
        XCTAssertNotEqual(shanghaiPlanned, newYorkPlanned)
        XCTAssertEqual(shanghaiPlanned.timeIntervalSince(newYorkPlanned),
                       shanghaiDue.timeIntervalSince(newYorkDue))
    }
}
