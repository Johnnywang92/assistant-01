import XCTest
@testable import AssistantCore

/// 预算播报取数窗口的边界用例。
///
/// 窗口必须覆盖「本月 + 昨日 + 本周一」三者中最早的一天：月初、周初跨月时
/// 只取本月会漏掉昨日/本周记录，只取昨日又会漏掉本月历史。
final class ExpenseRecordWindowTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testMidMonthWindowCoversWholeMonthThroughTomorrow() {
        let window = ExpenseRecordWindow.budgetWindow(now: day(2026, 10, 15), calendar: calendar)
        XCTAssertEqual(window.start, day(2026, 10, 1))
        XCTAssertEqual(window.end, day(2026, 10, 16))
    }

    func testMonthOpeningPullsWindowBackToThisMonday() {
        // 2026-10-01 是周四，本周一 09-28 与昨日 09-30 都在上个月
        let window = ExpenseRecordWindow.budgetWindow(now: day(2026, 10, 1), calendar: calendar)
        XCTAssertEqual(window.start, day(2026, 9, 28))
        XCTAssertEqual(window.end, day(2026, 10, 2))
    }

    func testSundayUsesSixDaysBackToMonday() {
        // 2026-10-04 是周日，本周一是 09-28
        let window = ExpenseRecordWindow.budgetWindow(now: day(2026, 10, 4), calendar: calendar)
        XCTAssertEqual(window.start, day(2026, 9, 28))
        XCTAssertEqual(window.end, day(2026, 10, 5))
    }

    func testSundayAtMonthStartPullsBackIntoPreviousMonth() {
        // 2026-11-01 是周日，本月从 11-01 起，窗口仍需回到 10-26
        let window = ExpenseRecordWindow.budgetWindow(now: day(2026, 11, 1), calendar: calendar)
        XCTAssertEqual(window.start, day(2026, 10, 26))
        XCTAssertEqual(window.end, day(2026, 11, 2))
    }

    func testMondayAtMonthStartUsesMonthStart() {
        // 2026-11-02 是周一，昨日与本周一都在本月
        let window = ExpenseRecordWindow.budgetWindow(now: day(2026, 11, 2), calendar: calendar)
        XCTAssertEqual(window.start, day(2026, 11, 1))
        XCTAssertEqual(window.end, day(2026, 11, 3))
    }

    func testSaturdayLateInMonthStillStartsAtMonthStart() {
        // 2026-10-31 是周六，本周一 10-26 晚于月初
        let window = ExpenseRecordWindow.budgetWindow(now: day(2026, 10, 31), calendar: calendar)
        XCTAssertEqual(window.start, day(2026, 10, 1))
        XCTAssertEqual(window.end, day(2026, 11, 1))
    }

    func testWindowContainsNow() {
        let now = day(2026, 10, 15).addingTimeInterval(12 * 3600)
        let window = ExpenseRecordWindow.budgetWindow(now: now, calendar: calendar)
        XCTAssertTrue(window.contains(now))
    }
}
