import XCTest

@testable import AssistantCore

final class PeriodTrendSummaryTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    private func point(_ label: String, day: Int, expense: Double, completed: Int, created: Int = 0)
        -> PeriodReportAnalytics.PeriodPoint {
        let start = date(2026, 6, day)
        return PeriodReportAnalytics.PeriodPoint(
            label: label,
            start: start,
            end: start.addingTimeInterval(7 * 86400),
            expense: expense,
            income: 0,
            completedCount: completed,
            createdCount: created
        )
    }

    private func makeSummary(
        points: [PeriodReportAnalytics.PeriodPoint],
        currentCategories: [String: Double] = [:],
        previousCategories: [String: Double] = [:],
        expenses: [(date: Date, amount: Double)] = [],
        completions: [(completedAt: Date, dueAt: Date?)] = [],
        income: Double = 0,
        completionRate: Double = 0.5,
        previousCompletionRate: Double? = nil
    ) -> PeriodTrendSummary {
        PeriodTrendBuilder.build(
            points: points,
            currentCategoryAmounts: currentCategories,
            previousCategoryAmounts: previousCategories,
            expenseSnapshots: expenses,
            completions: completions,
            currentIncome: income,
            currentCompletionRate: completionRate,
            previousCompletionRate: previousCompletionRate,
            now: date(2026, 6, 21),
            calendar: calendar
        )
    }

    // MARK: - 汇总构建

    func testBuildProducesMetricChangesAgainstPreviousPeriod() {
        let points = [
            point("W1", day: 1, expense: 500, completed: 3),
            point("W2", day: 8, expense: 800, completed: 5),
        ]
        let s = makeSummary(points: points, currentCategories: ["餐饮": 300], previousCategories: ["餐饮": 500],
                            completionRate: 0.6, previousCompletionRate: 0.4)

        XCTAssertEqual(s.previousExpense, 500)
        XCTAssertEqual(s.previousCompletedCount, 3)

        let expenseChange = s.metricChanges.first { $0.key == "expense" }
        XCTAssertNotNil(expenseChange)
        XCTAssertEqual(expenseChange!.current, 800)
        XCTAssertEqual(expenseChange!.previous, 500)
        XCTAssertEqual(expenseChange!.verdict, -1, "支出上升是恶化")

        let completionChange = s.metricChanges.first { $0.key == "completed" }
        XCTAssertEqual(completionChange!.verdict, 1, "完成数上升是改善")

        let rateChange = s.metricChanges.first { $0.key == "completionRate" }
        XCTAssertNotNil(rateChange)
        XCTAssertEqual(rateChange!.current, 60, accuracy: 1e-9)
        XCTAssertEqual(rateChange!.previous ?? -1, 40, accuracy: 1e-9)
    }

    func testBuildWithSinglePointHasNoPreviousComparison() {
        let s = makeSummary(points: [point("W1", day: 1, expense: 500, completed: 3)])
        XCTAssertNil(s.previousExpense)
        XCTAssertNil(s.previousCompletedCount)
        XCTAssertTrue(s.metricChanges.isEmpty, "只有一期时不该编造环比")
    }

    func testCategoryChangesCaptureStructureShift() {
        let s = makeSummary(
            points: [point("W1", day: 1, expense: 500, completed: 1), point("W2", day: 8, expense: 900, completed: 1)],
            currentCategories: ["餐饮": 500, "数码": 400],
            previousCategories: ["餐饮": 500]
        )
        XCTAssertTrue(s.categoryChanges.contains { $0.categoryRaw == "数码" && $0.isNew })
        XCTAssertEqual(s.categoryChanges.first { $0.categoryRaw == "餐饮" }?.delta, 0)
    }

    // MARK: - 洞察判定

    func testInsightDetectsSustainedExpenseRise() {
        let points = [
            point("W1", day: 1, expense: 100, completed: 1),
            point("W2", day: 8, expense: 200, completed: 1),
            point("W3", day: 15, expense: 400, completed: 1),
        ]
        let insights = PeriodTrendBuilder.insights(from: makeSummary(points: points))
        guard case .expenseSustainedRise(let periods, let delta)? = insights.first(where: {
            if case .expenseSustainedRise = $0 { return true }
            return false
        }) else {
            return XCTFail("应识别出支出持续上升")
        }
        XCTAssertEqual(periods, 2)
        XCTAssertGreaterThan(delta, 0)
    }

    func testInsightDetectsSustainedExpenseFall() {
        let points = [
            point("W1", day: 1, expense: 400, completed: 1),
            point("W2", day: 8, expense: 250, completed: 1),
            point("W3", day: 15, expense: 100, completed: 1),
        ]
        let insights = PeriodTrendBuilder.insights(from: makeSummary(points: points))
        XCTAssertTrue(insights.contains { if case .expenseSustainedFall = $0 { return true } else { return false } })
    }

    func testInsightDoesNotClaimTrendWithTooFewPeriods() {
        let points = [point("W1", day: 1, expense: 100, completed: 1), point("W2", day: 8, expense: 500, completed: 1)]
        let insights = PeriodTrendBuilder.insights(from: makeSummary(points: points))
        XCTAssertFalse(insights.contains { if case .expenseSustainedRise = $0 { return true } else { return false } },
                       "只有 2 期不足以断言趋势")
    }

    func testInsightDetectsLowPunctuality() {
        let completions: [(completedAt: Date, dueAt: Date?)] = [
            (completedAt: date(2026, 6, 18, 20), dueAt: date(2026, 6, 10, 9)),
            (completedAt: date(2026, 6, 19, 20), dueAt: date(2026, 6, 11, 9)),
        ]
        let s = makeSummary(points: [point("W1", day: 1, expense: 100, completed: 1)], completions: completions)
        let insights = PeriodTrendBuilder.insights(from: s)
        guard case .punctualityBelowTarget(let rate, _)? = insights.first(where: {
            if case .punctualityBelowTarget = $0 { return true }
            return false
        }) else {
            return XCTFail("应识别出准时率偏低")
        }
        XCTAssertEqual(rate, 0, accuracy: 1e-9)
    }

    func testInsightDoesNotClaimPunctualityWithoutSamples() {
        let s = makeSummary(points: [point("W1", day: 1, expense: 100, completed: 1)], completions: [])
        let insights = PeriodTrendBuilder.insights(from: s)
        XCTAssertFalse(insights.contains { if case .punctualityBelowTarget = $0 { return true } else { return false } },
                       "没有准时率样本时不得下结论")
        XCTAssertFalse(insights.contains { if case .punctualityHealthy = $0 { return true } else { return false } })
    }

    func testInsightDetectsWeekendHeavySpending() {
        // 2026-06-20 周六，06-21 周日
        let expenses: [(date: Date, amount: Double)] = [
            (date: date(2026, 6, 15), 50),   // 周一
            (date: date(2026, 6, 16), 50),   // 周二
            (date: date(2026, 6, 17), 50),   // 周三
            (date: date(2026, 6, 18), 50),   // 周四
            (date: date(2026, 6, 19), 50),   // 周五
            (date: date(2026, 6, 20), 400),  // 周六
            (date: date(2026, 6, 21), 400),  // 周日
        ]
        let points = [point("W1", day: 15, expense: 1050, completed: 1)]
        let s = makeSummary(points: points, expenses: expenses)
        let insights = PeriodTrendBuilder.insights(from: s)
        XCTAssertTrue(insights.contains { if case .weekendSpendingHeavy = $0 { return true } else { return false } })
    }

    func testInsightDetectsNewCategory() {
        let s = makeSummary(
            points: [point("W1", day: 1, expense: 500, completed: 1), point("W2", day: 8, expense: 700, completed: 1)],
            currentCategories: ["数码": 200],
            previousCategories: [:]
        )
        let insights = PeriodTrendBuilder.insights(from: s)
        XCTAssertTrue(insights.contains { if case .categoryAppeared = $0 { return true } else { return false } })
    }

    func testInsightAlwaysProvidesNextPeriodTarget() {
        let s = makeSummary(points: [
            point("W1", day: 1, expense: 1000, completed: 5),
            point("W2", day: 8, expense: 1200, completed: 6),
        ], income: 5000)
        let insights = PeriodTrendBuilder.insights(from: s)
        guard case .nextPeriodTarget(let cap, let target, let savings)? = insights.first(where: {
            if case .nextPeriodTarget = $0 { return true }
            return false
        }) else {
            return XCTFail("应给出下期目标")
        }
        XCTAssertNotNil(cap)
        XCTAssertGreaterThan(target, 0)
        XCTAssertNotNil(savings)
    }

    func testInsightSeveritiesAreOrderedForSorting() {
        let rise = PeriodInsight.expenseSustainedRise(periods: 2, averageDelta: 10)
        let fall = PeriodInsight.expenseSustainedFall(periods: 2, averageDelta: -10)
        let neutral = PeriodInsight.expenseVolatile(volatility: 0.8)
        XCTAssertTrue(fall.severity < neutral.severity)
        XCTAssertTrue(neutral.severity < rise.severity)
    }

    func testExpenseSeriesFeedsMiniChart() {
        let points = [
            point("W1", day: 1, expense: 100, completed: 1),
            point("W2", day: 8, expense: 200, completed: 3),
        ]
        let s = makeSummary(points: points)
        XCTAssertEqual(s.expenseSeries, [100, 200])
        XCTAssertEqual(s.completionSeries, [1, 3])
    }

    // MARK: - 窗口与序列的一致性（防止环比拿错基准）

    /// 趋势序列的最后一期必须与「本期」窗口完全一致。
    ///
    /// 这是最容易出错、且错了最难发现的一处：一旦两者用了不同的窗口规则，
    /// 环比就会变成「拿上上周比上周」，而所有数字看起来都正常。
    func testSeriesLastWindowMatchesCurrentPeriodWindow() {
        for granularity in ReportPeriodWindow.Granularity.allCases {
            let windows = ReportPeriodWindow.series(
                containing: date(2026, 6, 17),
                count: 8,
                granularity: granularity,
                calendar: calendar
            )
            let independent = ReportPeriodWindow.window(
                containing: date(2026, 6, 17),
                granularity: granularity,
                calendar: calendar
            )
            XCTAssertEqual(windows.last!.start, independent.start, "\(granularity) 本期起点与序列末期不一致")
            XCTAssertEqual(windows.last!.end, independent.end, "\(granularity) 本期终点与序列末期不一致")
        }
    }

    /// 序列的倒数第二期必须是「紧邻的上一期」，而不是更早的某一期。
    func testSecondToLastWindowIsImmediatelyPreviousPeriod() {
        let windows = ReportPeriodWindow.series(
            containing: date(2026, 6, 17),
            count: 8,
            granularity: .week,
            calendar: calendar
        )
        let expectedPrevious = ReportPeriodWindow.window(
            containing: date(2026, 6, 10),  // 上一周
            granularity: .week,
            calendar: calendar
        )
        XCTAssertEqual(windows[windows.count - 2].start, expectedPrevious.start)
        XCTAssertEqual(windows[windows.count - 2].end, expectedPrevious.end)
    }
}
