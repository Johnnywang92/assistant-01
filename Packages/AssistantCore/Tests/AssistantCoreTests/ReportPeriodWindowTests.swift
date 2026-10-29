import XCTest

@testable import AssistantCore

final class ReportPeriodWindowTests: XCTestCase {

    private var calendar: Calendar {
        ReportPeriodWindow.mondayFirstCalendar(base: {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            return cal
        }())
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    // MARK: - 周窗口锚定

    func testWeekWindowIsMondayToSunday() {
        // 2026-06-15 是周一
        let w = ReportPeriodWindow.weekWindow(containing: date(2026, 6, 15), calendar: calendar)
        XCTAssertEqual(w.start, date(2026, 6, 15, 0))
        XCTAssertEqual(w.end, date(2026, 6, 22, 0))
        XCTAssertEqual(w.dayCount, 7)
    }

    func testWeekWindowFromSundayBelongsToThatWeekNotNext() {
        // 2026-06-21 是周日 —— 属于 6/15~6/21 那一周，不能跑到下一周
        let w = ReportPeriodWindow.weekWindow(containing: date(2026, 6, 21), calendar: calendar)
        XCTAssertEqual(w.start, date(2026, 6, 15, 0))
        XCTAssertEqual(w.end, date(2026, 6, 22, 0))
        XCTAssertTrue(w.contains(date(2026, 6, 21)))
    }

    func testWeekWindowDoesNotDependOnLocaleFirstWeekday() {
        // 模拟 firstWeekday = 1（周日起始）的地区设置：规则不应被带偏
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        let w = ReportPeriodWindow.weekWindow(containing: date(2026, 6, 17), calendar: sundayFirst)
        XCTAssertEqual(w.start, date(2026, 6, 15, 0), "无论地区设置如何，周窗口都从周一开始")
        XCTAssertEqual(w.end, date(2026, 6, 22, 0))
    }

    func testWeekWindowAcrossMonthBoundary() {
        // 2026-06-30 是周二，属于 6/29~7/5 那一周
        let w = ReportPeriodWindow.weekWindow(containing: date(2026, 6, 30), calendar: calendar)
        XCTAssertEqual(w.start, date(2026, 6, 29, 0))
        XCTAssertEqual(w.end, date(2026, 7, 6, 0))
    }

    // MARK: - 自然周期

    func testMonthWindowCoversWholeMonth() {
        let w = ReportPeriodWindow.monthWindow(containing: date(2026, 2, 14), calendar: calendar)
        XCTAssertEqual(w.start, date(2026, 2, 1, 0))
        XCTAssertEqual(w.end, date(2026, 3, 1, 0))
        XCTAssertEqual(w.dayCount, 28, "2026 是平年，2 月 28 天")
    }

    func testQuarterWindowCoversNaturalQuarter() {
        let q1 = ReportPeriodWindow.quarterWindow(containing: date(2026, 2, 14), calendar: calendar)
        XCTAssertEqual(q1.start, date(2026, 1, 1, 0))
        XCTAssertEqual(q1.end, date(2026, 4, 1, 0))

        let q4 = ReportPeriodWindow.quarterWindow(containing: date(2026, 11, 9), calendar: calendar)
        XCTAssertEqual(q4.start, date(2026, 10, 1, 0))
        XCTAssertEqual(q4.end, date(2027, 1, 1, 0))
    }

    func testYearWindowCoversNaturalYear() {
        let w = ReportPeriodWindow.yearWindow(containing: date(2026, 8, 8), calendar: calendar)
        XCTAssertEqual(w.start, date(2026, 1, 1, 0))
        XCTAssertEqual(w.end, date(2027, 1, 1, 0))
        XCTAssertEqual(w.dayCount, 365)
    }

    // MARK: - 月末 / 季末 / 年末

    func testLastDayOfMonthHandlesShortMonths() {
        XCTAssertEqual(ReportPeriodWindow.lastDayOfMonth(containing: date(2026, 2, 10), calendar: calendar), date(2026, 2, 28, 0))
        XCTAssertEqual(ReportPeriodWindow.lastDayOfMonth(containing: date(2026, 4, 10), calendar: calendar), date(2026, 4, 30, 0))
        XCTAssertEqual(ReportPeriodWindow.lastDayOfMonth(containing: date(2026, 12, 10), calendar: calendar), date(2026, 12, 31, 0))
    }

    func testLastDayOfMonthHandlesLeapFebruary() {
        XCTAssertEqual(ReportPeriodWindow.lastDayOfMonth(containing: date(2028, 2, 10), calendar: calendar), date(2028, 2, 29, 0))
    }

    func testLastDayOfQuarterAndYear() {
        XCTAssertEqual(ReportPeriodWindow.lastDayOfQuarter(containing: date(2026, 5, 5), calendar: calendar), date(2026, 6, 30, 0))
        XCTAssertEqual(ReportPeriodWindow.lastDayOfQuarter(containing: date(2026, 12, 5), calendar: calendar), date(2026, 12, 31, 0))
        XCTAssertEqual(ReportPeriodWindow.lastDayOfYear(containing: date(2026, 3, 3), calendar: calendar), date(2026, 12, 31, 0))
    }

    func testUpcomingMonthEndsAreStrictlyIncreasingAndUnique() {
        let ends = ReportPeriodWindow.upcomingMonthEnds(from: date(2026, 1, 15), count: 14, calendar: calendar)
        XCTAssertEqual(ends.count, 14)
        XCTAssertEqual(ends[0], date(2026, 1, 31, 0))
        XCTAssertEqual(ends[1], date(2026, 2, 28, 0))
        XCTAssertEqual(ends[2], date(2026, 3, 31, 0))
        for i in 1..<ends.count {
            XCTAssertGreaterThan(ends[i], ends[i - 1], "月末日期必须严格递增，不能重复")
        }
    }

    func testUpcomingQuarterEndsAndYearEnds() {
        let quarters = ReportPeriodWindow.upcomingQuarterEnds(from: date(2026, 2, 1), count: 4, calendar: calendar)
        XCTAssertEqual(quarters[0], date(2026, 3, 31, 0))
        XCTAssertEqual(quarters[1], date(2026, 6, 30, 0))
        XCTAssertEqual(quarters[2], date(2026, 9, 30, 0))
        XCTAssertEqual(quarters[3], date(2026, 12, 31, 0))

        let years = ReportPeriodWindow.upcomingYearEnds(from: date(2026, 5, 1), count: 3, calendar: calendar)
        XCTAssertEqual(years, [date(2026, 12, 31, 0), date(2027, 12, 31, 0), date(2028, 12, 31, 0)])
    }

    // MARK: - 周期序列

    func testWeekSeriesReturnsOldestFirstAndIncludesCurrentPeriod() {
        let series = ReportPeriodWindow.series(containing: date(2026, 6, 17), count: 4, granularity: .week, calendar: calendar)
        XCTAssertEqual(series.count, 4)
        // 6/17 属于 6/15~6/21 那周，往前推 3 期：6/8、6/1、5/25
        XCTAssertEqual(series.map(\.start), [
            date(2026, 5, 25, 0), date(2026, 6, 1, 0), date(2026, 6, 8, 0), date(2026, 6, 15, 0)
        ])
        XCTAssertEqual(series[3].end, date(2026, 6, 22, 0))
        // 相邻窗口必须首尾相接，不留缝也不重叠
        for i in 1..<series.count {
            XCTAssertEqual(series[i].start, series[i - 1].end, "周与周之间必须严格相接")
        }
    }

    func testMonthSeriesAlignsToCalendarMonths() {
        let series = ReportPeriodWindow.series(containing: date(2026, 6, 17), count: 3, granularity: .month, calendar: calendar)
        XCTAssertEqual(series.map(\.start), [date(2026, 4, 1, 0), date(2026, 5, 1, 0), date(2026, 6, 1, 0)])
        XCTAssertEqual(series.last!.end, date(2026, 7, 1, 0))
    }

    func testQuarterSeriesAlignsToCalendarQuarters() {
        let series = ReportPeriodWindow.series(containing: date(2026, 6, 17), count: 3, granularity: .quarter, calendar: calendar)
        // 6/17 属于 Q2（4/1~7/1），往前推 2 期：Q1、去年 Q4
        XCTAssertEqual(series.map(\.start), [date(2025, 10, 1, 0), date(2026, 1, 1, 0), date(2026, 4, 1, 0)])
        XCTAssertEqual(series.last!.end, date(2026, 7, 1, 0))
    }

    func testYearSeriesAlignsToCalendarYears() {
        let series = ReportPeriodWindow.series(containing: date(2026, 6, 17), count: 3, granularity: .year, calendar: calendar)
        XCTAssertEqual(series.map(\.start), [date(2024, 1, 1, 0), date(2025, 1, 1, 0), date(2026, 1, 1, 0)])
    }

    func testSeriesHandlesShortMonthWithoutDrift() {
        // 跨 2 月（28 天）时，序列起点必须仍落在月初，不能错位到月中
        let series = ReportPeriodWindow.series(containing: date(2026, 3, 15), count: 3, granularity: .month, calendar: calendar)
        XCTAssertEqual(series.map(\.start), [date(2026, 1, 1, 0), date(2026, 2, 1, 0), date(2026, 3, 1, 0)])
        XCTAssertEqual(series[1].end, date(2026, 3, 1, 0))
    }

    func testSeriesWindowsAreContiguousAcrossAllGranularities() {
        for granularity in ReportPeriodWindow.Granularity.allCases {
            let series = ReportPeriodWindow.series(containing: date(2026, 6, 17), count: 6, granularity: granularity, calendar: calendar)
            XCTAssertEqual(series.count, 6, "\(granularity) 序列长度不对")
            for i in 1..<series.count {
                XCTAssertEqual(series[i].start, series[i - 1].end, "\(granularity) 窗口之间出现缝隙或重叠")
            }
        }
    }

    func testSeriesWithCountZeroReturnsEmpty() {
        XCTAssertTrue(ReportPeriodWindow.series(containing: date(2026, 6, 17), count: 0, granularity: .week, calendar: calendar).isEmpty)
    }

    // MARK: - 窗口语义

    func testDayWindowEndIsExclusiveStartOfNextDay() {
        let w = ReportPeriodWindow.window(containing: date(2026, 6, 17), granularity: .day, calendar: calendar)
        XCTAssertEqual(w.start, date(2026, 6, 17, 0))
        XCTAssertEqual(w.end, date(2026, 6, 18, 0))
        XCTAssertTrue(w.contains(date(2026, 6, 17, 23)))
        XCTAssertFalse(w.contains(date(2026, 6, 18, 0)), "终点不含，当日 24:00 属于下一周期")
    }

    func testRemainingDaysCountsDownWithinPeriod() {
        let w = ReportPeriodWindow.monthWindow(containing: date(2026, 6, 17), calendar: calendar)
        XCTAssertEqual(w.remainingDays(from: date(2026, 6, 17), calendar: calendar), 13, "6 月还剩 14 天，含当天则剩 13 天")
        XCTAssertEqual(w.remainingDays(from: date(2026, 7, 5), calendar: calendar), 0, "已过完则为 0")
    }
}
