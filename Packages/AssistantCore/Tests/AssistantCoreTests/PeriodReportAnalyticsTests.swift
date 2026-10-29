import XCTest

@testable import AssistantCore

final class PeriodReportAnalyticsTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    // MARK: - 趋势

    func testLinearSlopeOfPerfectLine() {
        XCTAssertEqual(PeriodReportAnalytics.linearSlope([1, 2, 3, 4]), 1, accuracy: 1e-9)
        XCTAssertEqual(PeriodReportAnalytics.linearSlope([10, 8, 6]), -2, accuracy: 1e-9)
        XCTAssertEqual(PeriodReportAnalytics.linearSlope([5]), 0)
    }

    func testSeriesTrendRisingWithStreakAndBaseline() {
        let t = PeriodReportAnalytics.seriesTrend([100, 120, 150, 200])
        XCTAssertEqual(t.direction, .rising)
        XCTAssertEqual(t.streak, 3)
        // 历史均值 = (100+120+150)/3
        XCTAssertEqual(t.baselineAverage, 370.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(t.currentVsBaseline!, (200 - 370.0 / 3) / (370.0 / 3), accuracy: 1e-9)
        XCTAssertEqual(t.peakIndex, 3)
    }

    func testSeriesTrendFlatAndFallingStreak() {
        let flat = PeriodReportAnalytics.seriesTrend([100, 101, 99, 100])
        XCTAssertEqual(flat.direction, .flat)

        let falling = PeriodReportAnalytics.seriesTrend([300, 250, 180])
        XCTAssertEqual(falling.direction, .falling)
        XCTAssertEqual(falling.streak, -2)
    }

    func testSeriesTrendEmptyAndZeroBaseline() {
        let empty = PeriodReportAnalytics.seriesTrend([])
        XCTAssertEqual(empty.direction, .flat)
        XCTAssertNil(empty.currentVsBaseline)

        let zeroBase = PeriodReportAnalytics.seriesTrend([0, 0, 50])
        XCTAssertNil(zeroBase.currentVsBaseline, "历史均值为 0 时没有基线")
    }

    // MARK: - 指标变化

    func testMetricVerdictRespectsPolarity() {
        let expenseUp = PeriodReportAnalytics.MetricChange(key: "e", title: "支出", unit: "元", current: 120, previous: 100, polarity: .lowerIsBetter)
        XCTAssertEqual(expenseUp.verdict, -1)
        XCTAssertEqual(expenseUp.ratio!, 0.2, accuracy: 1e-9)

        let doneUp = PeriodReportAnalytics.MetricChange(key: "d", title: "完成", unit: "项", current: 12, previous: 10, polarity: .higherIsBetter)
        XCTAssertEqual(doneUp.verdict, 1)

        let tiny = PeriodReportAnalytics.MetricChange(key: "t", title: "x", unit: "", current: 101, previous: 100, polarity: .higherIsBetter)
        XCTAssertEqual(tiny.verdict, 0, "变化不足 3% 视为持平")

        let noBase = PeriodReportAnalytics.MetricChange(key: "n", title: "x", unit: "", current: 5, previous: nil, polarity: .higherIsBetter)
        XCTAssertEqual(noBase.verdict, 0)
        XCTAssertNil(noBase.ratio)
    }

    // MARK: - 类别变化

    func testCategoryChangesSortedByAbsoluteDelta() {
        let changes = PeriodReportAnalytics.categoryChanges(
            current: ["餐饮": 500, "交通": 100, "数码": 800],
            previous: ["餐饮": 400, "交通": 300, "娱乐": 50]
        )
        XCTAssertEqual(changes.map(\.categoryRaw), ["数码", "交通", "餐饮", "娱乐"])
        XCTAssertTrue(changes[0].isNew)
        XCTAssertTrue(changes[3].isGone)
        XCTAssertEqual(changes[0].currentShare, 800.0 / 1400, accuracy: 1e-9)
    }

    // MARK: - 行为模式

    func testSpendingPatternWeekendShareAndNoSpendDays() {
        // 2026-06-15 是周一，06-21 是周日
        let start = calendar.startOfDay(for: date(2026, 6, 15))
        let end = calendar.date(byAdding: .second, value: 7 * 86400 - 1, to: start)!
        let expenses: [(date: Date, amount: Double)] = [
            (date(2026, 6, 15), 20),   // 周一 小额
            (date(2026, 6, 17), 80),   // 周三
            (date(2026, 6, 20), 200),  // 周六
            (date(2026, 6, 21), 100),  // 周日
        ]
        let p = PeriodReportAnalytics.spendingPattern(expenses: expenses, start: start, end: end, now: date(2026, 6, 25), calendar: calendar)
        XCTAssertEqual(p.elapsedDays, 7)
        XCTAssertEqual(p.activeDays, 4)
        XCTAssertEqual(p.noSpendDays, 3)
        XCTAssertEqual(p.weekendShare, 300.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(p.peakWeekdayIndex, 5) // 周六
        XCTAssertEqual(p.weekendDailyAverage, 150, accuracy: 1e-9)
        XCTAssertEqual(p.weekdayDailyAverage, 20, accuracy: 1e-9)
        XCTAssertEqual(p.smallTicketCount, 1)
        XCTAssertEqual(p.peakDayAmount, 200)
    }

    func testSpendingPatternTruncatesFutureDaysForOngoingPeriod() {
        let start = calendar.startOfDay(for: date(2026, 6, 1))
        let end = calendar.date(byAdding: .second, value: 30 * 86400 - 1, to: start)!
        let p = PeriodReportAnalytics.spendingPattern(expenses: [], start: start, end: end, now: date(2026, 6, 10), calendar: calendar)
        XCTAssertEqual(p.elapsedDays, 10, "进行中的周期只统计已过天数")
        XCTAssertNil(p.peakWeekdayIndex)
    }

    // MARK: - 准时率

    func testPunctualityCountsSameDayAsOnTime() {
        let stats = PeriodReportAnalytics.punctuality(completions: [
            (completedAt: date(2026, 6, 10, 22), dueAt: date(2026, 6, 10, 9)),   // 当天晚些时候完成 → 准时
            (completedAt: date(2026, 6, 13, 9), dueAt: date(2026, 6, 10, 9)),    // 晚 3 天
            (completedAt: date(2026, 6, 8), dueAt: nil),                         // 无截止不计
        ], calendar: calendar)
        XCTAssertEqual(stats.dueCompletedCount, 2)
        XCTAssertEqual(stats.onTimeCount, 1)
        XCTAssertEqual(stats.onTimeRate!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stats.averageDelayDays, 3, accuracy: 1e-9)
    }

    // MARK: - 下期目标

    func testNextTargetsTightenWhenAboveAverage() {
        let t = PeriodReportAnalytics.nextTargets(currentExpense: 1200, baselineExpense: 1000, currentCompleted: 10, baselineCompleted: 8, currentIncome: 0)
        XCTAssertEqual(t.expenseCap!, 950, accuracy: 1e-9)
        XCTAssertEqual(t.completedTarget, 11)
        XCTAssertNil(t.savingsRateTarget)
    }

    func testNextTargetsHoldWhenAlreadyWellBelowAverage() {
        let t = PeriodReportAnalytics.nextTargets(currentExpense: 700, baselineExpense: 1000, currentCompleted: 0, baselineCompleted: 0, currentIncome: 2000)
        XCTAssertEqual(t.expenseCap!, 700, accuracy: 1e-9)
        XCTAssertEqual(t.completedTarget, 1)
        XCTAssertEqual(t.savingsRateTarget!, 0.5, accuracy: 1e-9) // 65% + 5pp 封顶 50%
    }
}
