import XCTest

@testable import AssistantCore

final class DayScheduleCalculatorTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2
        return cal
    }()

    private func date(_ h: Int, _ m: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 10
        comps.hour = h; comps.minute = m
        return calendar.date(from: comps)!
    }

    private func schedule(
        from: Int,
        to: Int,
        busy: [(Int, Int, Int, Int)] = [],
        reminders: [Date] = []
    ) -> HomeScheduleFact {
        HomeScheduleFact(
            windowStart: date(from),
            windowEnd: date(to),
            busy: busy.map { sh, sm, eh, em in
                HomeBusyInterval(start: date(sh, sm), end: date(eh, em))
            },
            reminders: reminders
        )
    }

    private func plan(
        _ fact: HomeScheduleFact,
        now: Date? = nil,
        minimum: Int = 30
    ) -> DaySchedulePlan {
        DayScheduleCalculator.make(
            schedule: fact,
            now: now ?? date(9),
            minFreeSlotMinutes: minimum
        )
    }

    // MARK: - 占用合并（同源口径的根基）

    func testOverlappingBusyIsNotDoubleCounted() {
        let fact = schedule(
            from: 9, to: 12,
            busy: [(9, 30, 10, 0), (9, 45, 10, 30)]
        )
        let result = plan(fact)
        // 合并后占 09:30–10:30，剩余 09:00–09:30(30) + 10:30–12:00(90)
        XCTAssertEqual(result.freeMinutes, 120)
        XCTAssertEqual(result.freeSlots.count, 2)
    }

    func testGapsShorterThanThresholdAreExcluded() {
        let fact = schedule(from: 9, to: 12, busy: [(9, 20, 11, 40)])
        let result = plan(fact)
        XCTAssertTrue(result.freeSlots.isEmpty, "20 分钟的碎片不算可用空闲")
        XCTAssertEqual(result.freeMinutes, 0)
    }

    func testBusyOutsideWindowIsClipped() {
        let fact = schedule(from: 9, to: 12, busy: [(7, 0, 9, 30), (11, 30, 15, 0)])
        let result = plan(fact)
        // 裁剪后占用 09:00–09:30 + 11:30–12:00，只剩 09:30–11:30 = 120
        XCTAssertEqual(result.freeMinutes, 120)
    }

    // MARK: - now 对齐与终点不含

    func testFreeSlotStartsAtNow() {
        let result = plan(schedule(from: 9, to: 12), now: date(10, 15))
        XCTAssertEqual(result.freeSlots.count, 1)
        XCTAssertEqual(result.freeSlots.first?.start, date(10, 15))
        XCTAssertEqual(result.freeMinutes, 105)
    }

    func testReminderAtWindowEndIsExcludedFromSegments() {
        let fact = schedule(from: 9, to: 21, reminders: [date(21)])
        let result = plan(fact)
        XCTAssertFalse(result.segments.contains { $0.segment == .reminder })
    }

    // MARK: - 时间带比例

    func testSegmentWeightsSumToOne() {
        let fact = schedule(
            from: 9, to: 21,
            busy: [(12, 0, 14, 0)],
            reminders: [date(16)]
        )
        let result = plan(fact)
        let sum = result.segments.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(sum, 1.0, accuracy: 0.0001)
        XCTAssertTrue(result.segments.contains { $0.segment == .busy })
        XCTAssertTrue(result.segments.contains { $0.segment == .reminder })
    }

    func testMinimumIsConfigurableForCallers() {
        let fact = schedule(from: 9, to: 12, busy: [(9, 20, 11, 40)])
        let result = plan(fact, minimum: 20)
        XCTAssertEqual(result.freeSlots.count, 2)
        XCTAssertEqual(result.freeMinutes, 40)
    }

    // MARK: - 空窗口与同源

    func testUnscheduledProducesEmptyPlan() {
        let result = plan(.unscheduled)
        XCTAssertTrue(result.freeSlots.isEmpty)
        XCTAssertEqual(result.freeMinutes, 0)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.segment, .free)
    }

    func testFreeMinutesAlwaysEqualsSumOfSlots() {
        let fact = schedule(
            from: 9, to: 21,
            busy: [(9, 30, 10, 15), (10, 0, 11, 0), (14, 0, 15, 30), (18, 0, 18, 20)],
            reminders: [date(12), date(17)]
        )
        let result = plan(fact, now: date(10))
        XCTAssertEqual(
            result.freeMinutes,
            result.freeSlots.reduce(0) { $0 + $1.durationMinutes },
            "首页数字与时间轴必须来自同一组空档"
        )
    }
}
