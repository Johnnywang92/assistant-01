import XCTest
@testable import AssistantCore

final class BudgetCycleWindowTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)! // UTC+8
        return cal
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        return calendar.date(from: comps)!
    }

    func testNaturalMonthCycle() {
        let testDate = date(year: 2026, month: 11, day: 2)
        let win = BudgetCycleWindow.window(for: testDate, startDay: 1, calendar: calendar)

        XCTAssertEqual(win.totalDays, 30) // 11 月 30 天
        XCTAssertEqual(win.daysLeft, 29)  // 11月2日到11月30日共 29 天
        XCTAssertEqual(BudgetCycleWindow.formatCycleLabel(startDay: 1), "自然月")

        // 11月20日同属该自然月
        XCTAssertTrue(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 11, day: 20), as: testDate, startDay: 1, calendar: calendar))
        // 10月31日不属于该自然月
        XCTAssertFalse(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 10, day: 31), as: testDate, startDay: 1, calendar: calendar))
    }

    func testCustomAllowanceStartDayAfterCycleStart() {
        // 比如每月 10 号发生活费，当前是 11 月 15 日（在 10 日之后）
        let testDate = date(year: 2026, month: 11, day: 15)
        let win = BudgetCycleWindow.window(for: testDate, startDay: 10, calendar: calendar)

        // 周期应为 2026-11-10 到 2026-12-09
        XCTAssertEqual(win.totalDays, 30)
        XCTAssertEqual(win.daysLeft, 25) // 11月15日到12月9日共 25 天
        XCTAssertEqual(BudgetCycleWindow.formatCycleLabel(startDay: 10), "10日~次月9日")

        // 11月10日和12月5日同属该生活费周期
        XCTAssertTrue(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 11, day: 10), as: testDate, startDay: 10, calendar: calendar))
        XCTAssertTrue(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 12, day: 5), as: testDate, startDay: 10, calendar: calendar))

        // 11月9日属于上一个生活费周期（未发钱前）
        XCTAssertFalse(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 11, day: 9), as: testDate, startDay: 10, calendar: calendar))
        // 12月10日属于下一个生活费周期
        XCTAssertFalse(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 12, day: 10), as: testDate, startDay: 10, calendar: calendar))
    }

    func testCustomAllowanceStartDayBeforeCycleStart() {
        // 每月 10 号发生活费，当前是 11 月 5 日（在 10 日之前，花的是 10 月 10 日发的生活费）
        let testDate = date(year: 2026, month: 11, day: 5)
        let win = BudgetCycleWindow.window(for: testDate, startDay: 10, calendar: calendar)

        // 周期应为 2026-10-10 到 2026-11-09（10月有 31 天，总天数 31）
        XCTAssertEqual(win.totalDays, 31)
        XCTAssertEqual(win.daysLeft, 5) // 11月5日到11月9日共 5 天

        // 10月25日同属此生活费周期
        XCTAssertTrue(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 10, day: 25), as: testDate, startDay: 10, calendar: calendar))
        // 11月10日不属于此生活费周期（已重置）
        XCTAssertFalse(BudgetCycleWindow.isInSameCycle(recordDate: date(year: 2026, month: 11, day: 10), as: testDate, startDay: 10, calendar: calendar))
    }

    func testLastDayOfCycle() {
        // 每月 15 号发生活费，今天是 11 月 14 日（周期的最后一天）
        let testDate = date(year: 2026, month: 11, day: 14)
        let win = BudgetCycleWindow.window(for: testDate, startDay: 15, calendar: calendar)

        XCTAssertEqual(win.daysLeft, 1) // 最后一天，daysLeft 严格为 1
    }

    func testClampedStartDayRange() {
        // 传入超过 28 的数值（如 31），被自动夹逼到 28，确保二月安全不越界
        let testDate = date(year: 2026, month: 2, day: 10)
        let win = BudgetCycleWindow.window(for: testDate, startDay: 35, calendar: calendar)
        XCTAssertEqual(win.daysLeft, 18) // 夹到 28
    }
}

