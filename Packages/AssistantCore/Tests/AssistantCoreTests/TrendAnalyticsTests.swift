import XCTest

@testable import AssistantCore

final class TrendAnalyticsTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    // MARK: - 消费趋势

    func testExpenseTrendFillsMissingMonthsWithZeros() {
        let now = date(2026, 6, 15)
        let entries = [
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 3), amount: 100, isIncome: false, categoryRaw: "餐饮美食"),
            TrendAnalytics.ExpenseEntry(date: date(2026, 1, 10), amount: 300, isIncome: false, categoryRaw: "交通出行"),
        ]
        let trend = TrendAnalytics.expenseTrend(entries: entries, now: now, calendar: calendar, monthCount: 6)

        XCTAssertEqual(trend.months.count, 6)
        // 由旧到新：1月……6月
        XCTAssertEqual(trend.months.map(\.month), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(trend.months[0].expense, 300)
        XCTAssertEqual(trend.months[1].expense, 0) // 无记录月补 0
        XCTAssertEqual(trend.months[5].expense, 100)
        XCTAssertEqual(trend.averageExpense, 400.0 / 6.0, accuracy: 0.0001)
    }

    func testExpenseTrendChangeRatioAndCategoryShift() {
        let now = date(2026, 6, 15)
        let entries = [
            // 上月：餐饮 200、交通 100
            TrendAnalytics.ExpenseEntry(date: date(2026, 5, 5), amount: 200, isIncome: false, categoryRaw: "餐饮美食"),
            TrendAnalytics.ExpenseEntry(date: date(2026, 5, 6), amount: 100, isIncome: false, categoryRaw: "交通出行"),
            // 当月：餐饮 500（增长）、交通 50（降温）
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 5), amount: 500, isIncome: false, categoryRaw: "餐饮美食"),
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 6), amount: 50, isIncome: false, categoryRaw: "交通出行"),
        ]
        let trend = TrendAnalytics.expenseTrend(entries: entries, now: now, calendar: calendar, monthCount: 6)

        // 当月 550 vs 上月 300 → +83.3%
        XCTAssertEqual(trend.changeRatio ?? -1, (550.0 - 300.0) / 300.0, accuracy: 0.0001)
        XCTAssertEqual(trend.growingCategory?.categoryRaw, "餐饮美食")
        XCTAssertEqual(trend.growingCategory?.delta ?? 0, 300, accuracy: 0.0001)
        XCTAssertEqual(trend.shrinkingCategory?.categoryRaw, "交通出行")
        XCTAssertEqual(trend.shrinkingCategory?.delta ?? 0, -50, accuracy: 0.0001)
    }

    func testExpenseTrendNoBaselineWhenPreviousMonthEmpty() {
        let now = date(2026, 6, 15)
        let entries = [
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 5), amount: 100, isIncome: false, categoryRaw: "餐饮美食"),
        ]
        let trend = TrendAnalytics.expenseTrend(entries: entries, now: now, calendar: calendar, monthCount: 6)

        XCTAssertNil(trend.changeRatio) // 上月为 0 → 无基线
        // 新冒出来的类别算「增长」（与周期报告引擎口径一致：¥0 → ¥100）
        XCTAssertEqual(trend.growingCategory?.categoryRaw, "餐饮美食")
        XCTAssertEqual(trend.growingCategory?.from ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(trend.shrinkingCategory)
    }

    func testExpenseTrendIgnoresOutOfWindowAndSeparatesIncome() {
        let now = date(2026, 6, 15)
        let entries = [
            // 窗口外（近 6 个月窗口从 2026-1 起）
            TrendAnalytics.ExpenseEntry(date: date(2025, 12, 20), amount: 999, isIncome: false, categoryRaw: "购物消费"),
            // 窗口内收入：不计入支出
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 1), amount: 8000, isIncome: true, categoryRaw: "职业收入"),
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 2), amount: 30, isIncome: false, categoryRaw: "其它支出"),
        ]
        let trend = TrendAnalytics.expenseTrend(entries: entries, now: now, calendar: calendar, monthCount: 6)

        XCTAssertEqual(trend.months.map(\.expense).reduce(0, +), 30)
        XCTAssertEqual(trend.months.last?.income, 8000)
        XCTAssertEqual(trend.months.last?.recordCount, 2)
    }

    func testExpenseTrendYearBoundaryWindow() {
        let now = date(2026, 1, 10)
        let entries = [
            TrendAnalytics.ExpenseEntry(date: date(2025, 12, 31), amount: 120, isIncome: false, categoryRaw: "居家日用"),
            TrendAnalytics.ExpenseEntry(date: date(2026, 1, 1), amount: 60, isIncome: false, categoryRaw: "居家日用"),
        ]
        let trend = TrendAnalytics.expenseTrend(entries: entries, now: now, calendar: calendar, monthCount: 3)

        // 窗口：2025-11、2025-12、2026-1
        XCTAssertEqual(trend.months.map { "\($0.year)-\($0.month)" }, ["2025-11", "2025-12", "2026-1"])
        XCTAssertEqual(trend.months[1].expense, 120)
        XCTAssertEqual(trend.months[2].expense, 60)
        XCTAssertEqual(trend.changeRatio ?? 0, -0.5, accuracy: 0.0001)
    }

    func testExpenseTrendSingleMonthHasNoComparison() {
        let now = date(2026, 6, 15)
        let entries = [
            TrendAnalytics.ExpenseEntry(date: date(2026, 6, 5), amount: 100, isIncome: false, categoryRaw: "餐饮美食"),
        ]
        let trend = TrendAnalytics.expenseTrend(entries: entries, now: now, calendar: calendar, monthCount: 1)

        XCTAssertEqual(trend.months.count, 1)
        XCTAssertNil(trend.changeRatio)
        XCTAssertNil(trend.growingCategory)
        XCTAssertNil(trend.shrinkingCategory)
    }

    // MARK: - 饮食趋势

    func testDietTrendFillsMissingDaysAndAveragesOverRecordedDays() {
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.DietEntry(date: date(2026, 6, 15, 8), calories: 400),  // 今天
            TrendAnalytics.DietEntry(date: date(2026, 6, 15, 12), calories: 600), // 今天同日累加
            TrendAnalytics.DietEntry(date: date(2026, 6, 13, 12), calories: 500),
        ]
        let trend = TrendAnalytics.dietTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.days.count, 7)
        XCTAssertEqual(trend.recordedDays, 2)
        XCTAssertEqual(trend.days.last?.calories ?? 0, 1000, accuracy: 0.0001) // 同日累加
        XCTAssertFalse(trend.days[0].hasRecords) // 无记录日补位
        // 日均 = (1000 + 500) / 2，无记录天不计入
        XCTAssertEqual(trend.averageCalories, 750, accuracy: 0.0001)
        XCTAssertEqual(trend.maxDayCalories ?? 0, 1000, accuracy: 0.0001)
        XCTAssertEqual(trend.minDayCalories ?? 0, 500, accuracy: 0.0001)
    }

    func testDietTrendHalfComparison() {
        // 窗口 7 天：前半 = 前 3 天（6/9-6/11），后半 = 后 4 天（6/12-6/15）
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.DietEntry(date: date(2026, 6, 10, 12), calories: 1000), // 前半
            TrendAnalytics.DietEntry(date: date(2026, 6, 14, 12), calories: 1500), // 后半
            TrendAnalytics.DietEntry(date: date(2026, 6, 15, 12), calories: 1300), // 后半
        ]
        let trend = TrendAnalytics.dietTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.earlierAverage, 1000, accuracy: 0.0001)
        XCTAssertEqual(trend.recentAverage, 1400, accuracy: 0.0001)
        XCTAssertEqual(trend.changeRatio ?? 0, 0.4, accuracy: 0.0001)
    }

    func testDietTrendChangeRatioNilWithoutEarlierBaseline() {
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.DietEntry(date: date(2026, 6, 15, 12), calories: 800), // 只有后半有记录
        ]
        let trend = TrendAnalytics.dietTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.earlierAverage, 0)
        XCTAssertNil(trend.changeRatio) // 前半无记录 → 无基线
        XCTAssertEqual(trend.recentAverage, 800, accuracy: 0.0001)
    }

    func testDietTrendIgnoresOutOfWindowEntries() {
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.DietEntry(date: date(2026, 6, 8, 12), calories: 999),  // 窗口外（窗口从 6/9 起）
            TrendAnalytics.DietEntry(date: date(2026, 6, 9, 12), calories: 300),  // 窗口最早一天
        ]
        let trend = TrendAnalytics.dietTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.recordedDays, 1)
        XCTAssertEqual(trend.averageCalories, 300, accuracy: 0.0001)
    }

    func testDietTrendEmptyAndSingleDay() {
        let now = date(2026, 6, 15, 20)

        let empty = TrendAnalytics.dietTrend(entries: [], now: now, calendar: calendar, dayCount: 7)
        XCTAssertEqual(empty.recordedDays, 0)
        XCTAssertEqual(empty.averageCalories, 0)
        XCTAssertNil(empty.maxDayCalories)
        XCTAssertNil(empty.minDayCalories)
        XCTAssertNil(empty.changeRatio)

        let single = TrendAnalytics.dietTrend(
            entries: [TrendAnalytics.DietEntry(date: date(2026, 6, 15, 12), calories: 500)],
            now: now, calendar: calendar, dayCount: 1
        )
        XCTAssertEqual(single.days.count, 1)
        XCTAssertEqual(single.recordedDays, 1)
        // dayCount=1 时前半为空，无基线
        XCTAssertNil(single.changeRatio)
    }

    // MARK: - 健康趋势

    func testHealthTrendEmptyIsNilNotZero() {
        let trend = TrendAnalytics.healthTrend(entries: [], now: date(2026, 6, 15), calendar: calendar, dayCount: 7)
        XCTAssertEqual(trend.days.count, 7)
        XCTAssertEqual(trend.sleepRecordedDays, 0)
        // 「读不到」不能伪造成 0 小时睡眠
        XCTAssertNil(trend.averageSleepHours)
        XCTAssertNil(trend.averageScore)
        XCTAssertNil(trend.sleepChangeRatio)
    }

    func testHealthTrendAveragesOnlyRecordedDays() {
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.HealthEntry(date: date(2026, 6, 14), sleepHours: 7.0),
            TrendAnalytics.HealthEntry(date: date(2026, 6, 15), sleepHours: 8.0)
        ]
        let trend = TrendAnalytics.healthTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.sleepRecordedDays, 2)
        XCTAssertEqual(trend.averageSleepHours ?? 0, 7.5, accuracy: 0.0001)
        XCTAssertEqual(trend.scoreRecordedDays, 0)
        XCTAssertNil(trend.averageScore, "无分数数据日均应为 nil")
    }

    func testHealthTrendHalfSplitChangeRatio() {
        // 7 天窗：前半 = 3 天（6/9~6/11），后半 = 4 天（6/12~6/15）
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.HealthEntry(date: date(2026, 6, 9), sleepHours: 6.0),
            TrendAnalytics.HealthEntry(date: date(2026, 6, 10), sleepHours: 6.0),
            TrendAnalytics.HealthEntry(date: date(2026, 6, 13), sleepHours: 8.0),
            TrendAnalytics.HealthEntry(date: date(2026, 6, 14), sleepHours: 8.0)
        ]
        let trend = TrendAnalytics.healthTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.earlierAverageSleepHours ?? 0, 6.0, accuracy: 0.0001)
        XCTAssertEqual(trend.recentAverageSleepHours ?? 0, 8.0, accuracy: 0.0001)
        XCTAssertEqual(trend.sleepChangeRatio ?? 0, (8.0 - 6.0) / 6.0, accuracy: 0.0001)
    }

    func testHealthTrendChangeRatioNilWhenEarlierEmpty() {
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.HealthEntry(date: date(2026, 6, 15), sleepHours: 8.0, vitalityScore: 80)
        ]
        let trend = TrendAnalytics.healthTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertNil(trend.sleepChangeRatio, "前半无睡眠数据 → 无基线")
        XCTAssertNil(trend.scoreChangeRatio)
        XCTAssertEqual(trend.averageScore ?? 0, 80, accuracy: 0.0001)
    }

    func testHealthTrendIgnoresOutOfWindowAndDeduplicatesDays() {
        let now = date(2026, 6, 15, 20)
        let entries = [
            TrendAnalytics.HealthEntry(date: date(2026, 6, 8), sleepHours: 9.0),   // 窗口外
            TrendAnalytics.HealthEntry(date: date(2026, 6, 15), sleepHours: 7.0),
            TrendAnalytics.HealthEntry(date: date(2026, 6, 15), sleepHours: 7.5)  // 同日后者覆盖
        ]
        let trend = TrendAnalytics.healthTrend(entries: entries, now: now, calendar: calendar, dayCount: 7)

        XCTAssertEqual(trend.sleepRecordedDays, 1)
        XCTAssertEqual(trend.averageSleepHours ?? 0, 7.5, accuracy: 0.0001)
    }
}
