import XCTest
@testable import AssistantCore

final class SafeToSpendCalculatorTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    /// 创建一个指定月份和日期的 Date（以 2026 年 6 月为例，总共 30 天）
    private func date(day: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 6
        comps.day = day
        comps.hour = 12
        return calendar.date(from: comps)!
    }

    func testMorningStartSafeToSpendEqualsAllowance() {
        let now = date(day: 1) // 6月1日，剩余 30 天
        let input = SafeToSpendInput(
            monthlyBudget: 3000,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 0,
            todayFlexibleSpend: 0
        )
        let result = SafeToSpendCalculator.compute(input: input, now: now, calendar: calendar)

        XCTAssertTrue(result.isEnabled)
        XCTAssertEqual(result.daysLeft, 30)
        XCTAssertEqual(result.disposableBudget, 3000)
        XCTAssertEqual(result.todayAllowance, 100, accuracy: 0.001)
        XCTAssertEqual(result.safeToSpendToday, 100, accuracy: 0.001)
        XCTAssertFalse(result.isTodayOverspent)
    }

    func testNewExpenseAddedTodayDecreasesSafeToSpendEquallyInRealTime() {
        let now = date(day: 1) // 30 天剩余，日均额度 100 元
        
        // 1. 中午新增记账 35 元（午餐）
        let inputAfterLunch = SafeToSpendInput(
            monthlyBudget: 3000,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 35,
            todayFlexibleSpend: 35
        )
        let result1 = SafeToSpendCalculator.compute(input: inputAfterLunch, now: now, calendar: calendar)
        XCTAssertEqual(result1.todayAllowance, 100, accuracy: 0.001, "今日初始额度保持稳定基准")
        XCTAssertEqual(result1.todayFlexibleSpend, 35, accuracy: 0.001)
        XCTAssertEqual(result1.safeToSpendToday, 65, accuracy: 0.001, "新增 35 元支出后，安心花实时精准递减 35 元")
        XCTAssertEqual(result1.todaySpentRatio, 0.35, accuracy: 0.001, "今日进度条比例为 35%")
        XCTAssertFalse(result1.isTodayOverspent)

        // 2. 晚上新增记账 45 元（晚餐），今日共花费 80 元
        let inputAfterDinner = SafeToSpendInput(
            monthlyBudget: 3000,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 80,
            todayFlexibleSpend: 80
        )
        let result2 = SafeToSpendCalculator.compute(input: inputAfterDinner, now: now, calendar: calendar)
        XCTAssertEqual(result2.todayAllowance, 100, accuracy: 0.001)
        XCTAssertEqual(result2.todayFlexibleSpend, 80, accuracy: 0.001)
        XCTAssertEqual(result2.safeToSpendToday, 20, accuracy: 0.001, "再次新增 45 元支出后，安心花精准变为 20 元")
        XCTAssertEqual(result2.todaySpentRatio, 0.80, accuracy: 0.001, "今日进度条比例为 80%")
        XCTAssertFalse(result2.isTodayOverspent)
    }

    func testOverspendingTodayAllowanceBecomesZeroAndMarksOverspent() {
        let now = date(day: 1) // 日均额度 100 元
        // 今日共花了 130 元，超额 30 元
        let input = SafeToSpendInput(
            monthlyBudget: 3000,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 130,
            todayFlexibleSpend: 130
        )
        let result = SafeToSpendCalculator.compute(input: input, now: now, calendar: calendar)

        XCTAssertEqual(result.todayAllowance, 100, accuracy: 0.001)
        XCTAssertEqual(result.safeToSpendToday, 0, "超额后今日可安心花归零，不再给虚假额度")
        XCTAssertTrue(result.isTodayOverspent)
        XCTAssertEqual(result.todayOverspentAmount, 30, accuracy: 0.001)
        XCTAssertEqual(result.todaySpentRatio, 1.30, accuracy: 0.001, "超额后今日进度条超出 100%")
        XCTAssertFalse(result.isOverBudget, "本月总预算尚有结余，仅今日超额")
    }

    func testMonthlyDeficitMarksOverBudget() {
        let now = date(day: 15)
        // 预算 3000，本月已花 3200
        let input = SafeToSpendInput(
            monthlyBudget: 3000,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 3200,
            todayFlexibleSpend: 50
        )
        let result = SafeToSpendCalculator.compute(input: input, now: now, calendar: calendar)

        XCTAssertTrue(result.isOverBudget)
        XCTAssertEqual(result.remainingThisMonth, -200)
        XCTAssertEqual(result.safeToSpendToday, 0)
    }

    func testYesterdaySavingsRollover() {
        // 6月10日，距月底 21 天，月初已过 9 天
        let now = date(day: 10)
        // 前 8 天总共花了 800 元，昨天（第 9 天）花了 40 元，今天花了 0 元
        let input = SafeToSpendInput(
            monthlyBudget: 3000,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 840,
            yesterdayFlexibleSpend: 40,
            todayFlexibleSpend: 0
        )
        let result = SafeToSpendCalculator.compute(input: input, now: now, calendar: calendar)

        // 昨天早晨视角：池子 = 3000 - 800 = 2200，天数 = 21 + 1 = 22 天
        // 昨天应得额度 = 2200 / 22 = 100 元
        // 昨天实际花了 40 元，省下 60 元
        XCTAssertEqual(result.savedYesterday, 60, accuracy: 0.01)
    }

    func testWeekendLeisureRhythmDifferentiatesWorkdayAndWeekend() {
        let monday = date(day: 1) // 2026-06-01 为周一
        let inputMonday = SafeToSpendInput(
            monthlyBudget: 3640,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 0,
            todayFlexibleSpend: 0,
            rhythmMode: .weekendLeisure
        )
        let resultMonday = SafeToSpendCalculator.compute(input: inputMonday, now: monday, calendar: calendar)

        XCTAssertFalse(resultMonday.isWeekend)
        XCTAssertEqual(resultMonday.rhythmMode, .weekendLeisure)
        // 2026年6月共有 22 个工作日，8 个周末日。
        // 加权天数 = 22 + 8 * 1.8 = 36.4 天
        // 工作日基准 = 3640 / 36.4 = 100 元
        // 周末基准 = 100 * 1.8 = 180 元
        XCTAssertEqual(resultMonday.workdayAllowance, 100, accuracy: 0.1)
        XCTAssertEqual(resultMonday.weekendAllowance, 180, accuracy: 0.1)
        XCTAssertEqual(resultMonday.todayAllowance, 100, accuracy: 0.1, "周一工作日基准额度为 100 元")
        XCTAssertEqual(resultMonday.safeToSpendToday, 100, accuracy: 0.1)

        // 验证周六（2026-06-06）
        let saturday = date(day: 6)
        let inputSaturday = SafeToSpendInput(
            monthlyBudget: 3640,
            fixedMonthlyTotal: 0,
            flexibleSpentThisMonth: 500, // 周一至周五共花了 500 元（日均 100）
            todayFlexibleSpend: 0,
            rhythmMode: .weekendLeisure,
            weekdaySavedSoFarThisWeek: 60
        )
        let resultSaturday = SafeToSpendCalculator.compute(input: inputSaturday, now: saturday, calendar: calendar)

        XCTAssertTrue(resultSaturday.isWeekend)
        XCTAssertEqual(resultSaturday.todayAllowance, resultSaturday.weekendAllowance, accuracy: 0.01)
        XCTAssertGreaterThan(resultSaturday.todayAllowance, resultSaturday.workdayAllowance)
        XCTAssertNotNil(resultSaturday.rhythmAdviceText)
        XCTAssertTrue(resultSaturday.rhythmAdviceText?.contains("周末") ?? false)
    }
}
