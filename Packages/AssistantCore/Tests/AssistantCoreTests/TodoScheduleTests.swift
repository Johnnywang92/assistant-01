import Foundation
import XCTest
@testable import AssistantCore

final class TodoScheduleTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 1 // 1 = 周日，与 Calendar.component(.weekday) 口径一致
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = cal
        components.timeZone = cal.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return cal.date(from: components)!
    }

    private func parts(_ date: Date) -> (Int, Int, Int, Int, Int) {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    // MARK: - 旧数据兼容

    func testLegacyWithoutDueDateIsNoTime() {
        let schedule = TodoSchedule.legacy(dueAt: nil, ruleRaw: nil, customDays: 0, now: date(2026, 1, 1))
        XCTAssertEqual(schedule.mode, .none)
        XCTAssertNil(schedule.effectiveDueAt)
        XCTAssertEqual(schedule.recurrence.rule, .none)
    }

    func testLegacyWithDueDateIsSinglePointAndAfterCompletion() {
        let due = date(2026, 3, 10, 15, 30)
        let schedule = TodoSchedule.legacy(
            dueAt: due, ruleRaw: TodoRecurrenceRule.weekly.rawValue, customDays: 0, now: due
        )
        XCTAssertEqual(schedule.mode, .point)
        XCTAssertEqual(schedule.effectiveDueAt, due)
        XCTAssertEqual(schedule.recurrence.mode, .afterCompletion)
        XCTAssertEqual(schedule.recurrence.rule, .weekly)
    }

    func testLegacyUnknownRuleFallsBackToNone() {
        let schedule = TodoSchedule.legacy(dueAt: nil, ruleRaw: "某天再说", customDays: 0, now: date(2026, 1, 1))
        XCTAssertEqual(schedule.recurrence.rule, .none)
    }

    // MARK: - 编解码

    func testCodecRoundTripKeepsAnchors() {
        var config = TodoRecurrenceConfig(rule: .monthly, mode: .calendarAnchor)
        config.monthDays = [31, -1, 15]
        config.endAt = date(2027, 1, 1)
        let schedule = TodoSchedule(
            mode: .range,
            startAt: date(2026, 11, 7, 9),
            endAt: date(2026, 11, 7, 11),
            isAllDay: false,
            recurrence: config
        )
        let raw = TodoScheduleCodec.encode(schedule)
        XCTAssertNotNil(raw)
        XCTAssertEqual(TodoScheduleCodec.decode(raw), schedule)
    }

    func testCorruptedRawDecodesToNilSoCallerCanUseLegacy() {
        XCTAssertNil(TodoScheduleCodec.decode("not-json"))
        XCTAssertNil(TodoScheduleCodec.decode(nil))
    }

    func testNormalizeFixesInvalidRangeAndCleansAnchorsWhenRuleIsNone() {
        let end = date(2026, 11, 7, 10)
        var config = TodoRecurrenceConfig(rule: .none, mode: .calendarAnchor)
        config.weekdays = [2, 2, 99]
        config.monthDays = [31]
        let schedule = TodoSchedule(mode: .range, startAt: end.addingTimeInterval(3600), endAt: end, recurrence: config)
            .normalized()
        XCTAssertTrue(schedule.isValid)
        XCTAssertLessThan(schedule.startAt, schedule.endAt)
        XCTAssertEqual(schedule.recurrence.mode, .afterCompletion)
        XCTAssertTrue(schedule.recurrence.weekdays.isEmpty)
        XCTAssertTrue(schedule.recurrence.monthDays.isEmpty)
        XCTAssertNil(schedule.recurrence.endAt)
    }

    // MARK: - 完成后顺延（历史语义不变）

    func testAfterCompletionMatchesLegacyRecurrencePlan() {
        let due = date(2026, 11, 1, 9)
        var config = TodoRecurrenceConfig(rule: .everyThreeDays)
        config.mode = .afterCompletion
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)
        let now = date(2026, 11, 8, 12)

        let expected = RecurrencePlan.nextDueDate(
            dueAt: due, rule: .everyThreeDays, customDays: 3, referenceDate: now, calendar: cal
        )
        XCTAssertEqual(TodoScheduleRule.nextDueDate(for: schedule, after: now, calendar: cal), expected)
    }

    func testNonRecurringNeverProducesNextOccurrence() {
        let due = date(2026, 11, 7, 9)
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due)
        XCTAssertNil(TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 11, 8), calendar: cal))
    }

    // MARK: - 周锚点

    func testWeeklyAnchorPicksNextSelectedWeekdayAndKeepsTimeOfDay() {
        // 2026-11-07 是周六；选周一(2)与周三(4)，下一次应为 11/9 周一 15:45
        let due = date(2026, 11, 2, 15, 45) // 周一
        var config = TodoRecurrenceConfig(rule: .weekly, mode: .calendarAnchor)
        config.weekdays = [2, 4]
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        let next = TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 11, 7, 20), calendar: cal)
        XCTAssertEqual(next.map { parts($0) }.map { "\($0.0)-\($0.1)-\($0.2) \($0.3):\($0.4)" }, "2026-11-9 15:45")
    }

    func testWeeklyAnchorDoesNotDriftWithCompletionTime() {
        let due = date(2026, 11, 2, 9)
        var config = TodoRecurrenceConfig(rule: .weekly, mode: .calendarAnchor)
        config.weekdays = [2] // 每周一
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        // 周六才完成，下一次仍是周一 9:00，而不是「完成时刻 + 7 天」
        let next = TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 11, 7, 23), calendar: cal)
        XCTAssertEqual(next, date(2026, 11, 9, 9))
    }

    func testBiweeklyAnchorSkipsTheOffWeek() {
        let due = date(2026, 11, 2, 9) // 周一，锚点周
        var config = TodoRecurrenceConfig(rule: .biweekly, mode: .calendarAnchor)
        config.weekdays = [2]
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        // 下一周（11/9）是空周，应跳到 11/16
        let next = TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 11, 8), calendar: cal)
        XCTAssertEqual(next, date(2026, 11, 16, 9))
    }

    func testCalendarAnchorWithoutUsableWeekdaysFallsBackToInterval() {
        let due = date(2026, 11, 2, 9)
        var config = TodoRecurrenceConfig(rule: .weekly, mode: .calendarAnchor)
        config.weekdays = [99] // 全被过滤
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)
        XCTAssertFalse(schedule.recurrence.hasUsableAnchor)
        let next = TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 11, 8), calendar: cal)
        XCTAssertNotNil(next, "没有可用锚点必须退回顺延，不能永远没有下一次")
    }

    // MARK: - 月锚点（短月红线）

    func testMonthDay31SkipsShortMonthsInsteadOfSilentlyDropping() {
        let due = date(2026, 1, 31, 9)
        var config = TodoRecurrenceConfig(rule: .monthly, mode: .calendarAnchor)
        config.monthDays = [31]
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        // 2 月没有 31 日，必须跳到 3/31，而不是钳制到 2/28 或干脆不触发
        let next = TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 2, 1), calendar: cal)
        XCTAssertEqual(next, date(2026, 3, 31, 9))
    }

    func testMonthLastDayAnchorHandlesFebruaryAndLeapYear() {
        let due = date(2026, 1, 31, 18)
        var config = TodoRecurrenceConfig(rule: .monthly, mode: .calendarAnchor)
        config.monthDays = [-1]
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        XCTAssertEqual(
            TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 2, 1), calendar: cal),
            date(2026, 2, 28, 18)
        )
        XCTAssertEqual(
            TodoScheduleRule.nextDueDate(for: schedule, after: date(2028, 2, 1), calendar: cal),
            date(2028, 2, 29, 18)
        )
    }

    func testMultipleMonthAnchorsPickEarliestFutureOne() {
        let due = date(2026, 1, 5, 9)
        var config = TodoRecurrenceConfig(rule: .monthly, mode: .calendarAnchor)
        config.monthDays = [1, 15, -1] // 含月末，必须收集后取最早，不能被月末抢先
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        let next = TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 1, 10), calendar: cal)
        XCTAssertEqual(next, date(2026, 1, 15, 9))
    }

    // MARK: - 重复截止与时间段平移

    func testEndAtStopsGeneratingNextOccurrence() {
        let due = date(2026, 11, 2, 9)
        var config = TodoRecurrenceConfig(rule: .weekly, mode: .calendarAnchor)
        config.weekdays = [2]
        config.endAt = date(2026, 11, 5)
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        XCTAssertNil(TodoScheduleRule.nextDueDate(for: schedule, after: date(2026, 11, 3), calendar: cal))
        XCTAssertNil(TodoScheduleRule.nextSchedule(from: schedule, after: date(2026, 11, 8), calendar: cal))
    }

    func testNextScheduleKeepsRangeDurationAndAnchorConfig() {
        let start = date(2026, 11, 2, 9)
        let end = date(2026, 11, 2, 11) // 2 小时段
        var config = TodoRecurrenceConfig(rule: .weekly, mode: .calendarAnchor)
        config.weekdays = [2]
        config.endAt = date(2027, 1, 1)
        let schedule = TodoSchedule(mode: .range, startAt: start, endAt: end, recurrence: config)

        let next = TodoScheduleRule.nextSchedule(from: schedule, after: date(2026, 11, 3), calendar: cal)
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.endAt, date(2026, 11, 9, 11))
        XCTAssertEqual(next?.startAt, date(2026, 11, 9, 9))
        XCTAssertEqual(next?.mode, .range)
        XCTAssertEqual(next?.recurrence.weekdays, [2])
        XCTAssertEqual(next?.recurrence.endAt, config.endAt)
    }

    func testNoTimeModeStillRollsRecurrenceWithoutProducingDueAt() {
        var config = TodoRecurrenceConfig(rule: .daily)
        config.mode = .afterCompletion
        let schedule = TodoSchedule(mode: .none, recurrence: config)
        let next = TodoScheduleRule.nextSchedule(from: schedule, after: date(2026, 11, 8), calendar: cal)
        XCTAssertNotNil(next, "纯清单打卡也要生成下一期，不能静默停掉重复")
        XCTAssertEqual(next?.mode, TodoTimeMode.none)
        XCTAssertNil(next?.effectiveDueAt)
    }

    // MARK: - DST

    func testDailyAnchorUsesCalendarDaysNotRawSeconds() {
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime]

        guard let due = formatter.date(from: "2026-03-07T09:00:00Z"),
              let after = formatter.date(from: "2026-03-09T13:00:00Z") else {
            XCTFail("固定日期构造失败")
            return
        }
        var config = TodoRecurrenceConfig(rule: .daily, mode: .calendarAnchor)
        config.weekdays = [] // 无周锚点 → 走按天间隔分支
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        let next = TodoScheduleRule.nextDueDate(for: schedule, after: after, calendar: dst)
        XCTAssertNotNil(next)
        let hour = dst.component(.hour, from: next!)
        XCTAssertEqual(hour, 4, "跨 DST 后墙上时刻应保持 09:00（UTC 04:00 前后按日历天对齐），不能由 +86400 秒漂成 10:00")
    }

    // MARK: - 改期与读时自愈

    func testRescheduleKeepsRangeDurationAndFreezesAnchor() {
        let start = date(2026, 11, 2, 9)
        let end = date(2026, 11, 2, 11)
        var config = TodoRecurrenceConfig(rule: .monthly, mode: .calendarAnchor)
        config.monthDays = [15]
        let schedule = TodoSchedule(mode: .range, startAt: start, endAt: end, isAllDay: true, recurrence: config)

        let moved = schedule.rescheduled(to: date(2026, 11, 2, 18))
        XCTAssertEqual(moved.endAt, date(2026, 11, 2, 18))
        XCTAssertEqual(moved.startAt, date(2026, 11, 2, 16), "两小时时间段应整体平移")
        XCTAssertEqual(moved.anchorAt, end, "首次改期必须冻结原锚点")
        XCTAssertEqual(moved.recurrence.monthDays, [15])
        XCTAssertTrue(moved.isAllDay)
    }

    func testRescheduleDoesNotShiftBiweeklyPhase() {
        // 锚点周 = 11/01 那一周（周一 11/02）。改期到下一周的周三 11/11 后，
        // 若用改期后的 endAt 重算锚点周，奇偶翻转会把下一次触发从 11/16 推到 11/23。
        let anchor = date(2026, 11, 2)
        var config = TodoRecurrenceConfig(rule: .biweekly, mode: .calendarAnchor)
        config.weekdays = [2]
        let schedule = TodoSchedule(mode: .point, startAt: anchor, endAt: anchor, recurrence: config)
        let moved = schedule.rescheduled(to: date(2026, 11, 11))

        let next = TodoScheduleRule.nextDueDate(for: moved, after: date(2026, 11, 11, 12), calendar: cal)
        XCTAssertEqual(next, date(2026, 11, 16), "改期只影响当前一期，双周相位必须保持不变")
    }

    func testClearingTimeKeepsRecurrenceAndAnchor() {
        let due = date(2026, 11, 2)
        var config = TodoRecurrenceConfig(rule: .weekly, mode: .calendarAnchor)
        config.weekdays = [2]
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due, recurrence: config)

        let cleared = schedule.clearingTime()
        XCTAssertEqual(cleared.mode, .none)
        XCTAssertNil(cleared.effectiveDueAt)
        XCTAssertEqual(cleared.recurrence.weekdays, [2], "清掉时间不该连周期设置一起丢")
        XCTAssertEqual(cleared.anchorAt, due)
    }

    func testMatchesDetectsDueAtDriftForSelfHealing() {
        let due = date(2026, 11, 2)
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due)
        XCTAssertTrue(schedule.matches(dueAt: due))
        XCTAssertFalse(schedule.matches(dueAt: due.addingTimeInterval(3600)), "外部直接改 dueAt 必须被识别为失配")
        XCTAssertFalse(schedule.matches(dueAt: nil))
        XCTAssertTrue(TodoSchedule(mode: .none).matches(dueAt: nil))
    }

    func testLegacyJSONWithoutAnchorAtStillDecodes() throws {
        let due = date(2026, 11, 2)
        let schedule = TodoSchedule(mode: .point, startAt: due, endAt: due)
        let data = try JSONEncoder().encode(schedule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "anchorAt")
        let raw = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)

        let decoded = TodoScheduleCodec.decode(raw)
        XCTAssertEqual(decoded, schedule, "旧 JSON 缺 anchorAt 应回落为以 endAt 为锚，不能解码失败")
        XCTAssertNil(decoded?.anchorAt)
    }
}
