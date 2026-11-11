import XCTest
@testable import AssistantCore

/// 小组件数据层（首页概览 + 纪念日倒计时）的测试。
///
/// 对应方案 C 的红线：**小组件不自己算状态**，主 App 用同一份 Core 事实算完写入快照，
/// 扩展只渲染。这里钉住两个最容易漂的口径：
/// 1. 首页概览的空闲文案（「全天空闲」≠「0 分钟」）；
/// 2. 纪念日的**农历**换算（此前 `isLunar` 被完全忽略，会算出错误天数）。
final class WidgetHomeModelsTests: XCTestCase {

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-11-10 14:00 +08:00
        return cal.date(from: DateComponents(
            year: 2026, month: 11, day: 10, hour: 14, minute: 0
        ))!
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: y, month: m, day: d, hour: h, minute: min
        ))!
    }

    // MARK: - 首页概览 · 空闲文案

    /// 无日程 → 写「全天空闲」，**不是**「0 分钟」。
    func testAllDayFreeWhenNoOccupancy() {
        let overview = WidgetHomeOverview(
            done: 0, total: 0, freeMinutes: 0,
            isAllDayFree: true, priorityTaskTitle: nil,
            freeRatio: 1, busyRatio: 0
        )

        XCTAssertEqual(overview.freeTimeText, "全天空闲")
    }

    /// 有占用 → 写具体时长，格式 h/m。
    func testFreeTimeTextFormatsHoursAndMinutes() {
        func overview(_ minutes: Int) -> WidgetHomeOverview {
            WidgetHomeOverview(
                done: 0, total: 0, freeMinutes: minutes,
                isAllDayFree: false, priorityTaskTitle: nil,
                freeRatio: 0.5, busyRatio: 0.5
            )
        }

        XCTAssertEqual(overview(256).freeTimeText, "4h16m")
        XCTAssertEqual(overview(120).freeTimeText, "2h")
        XCTAssertEqual(overview(45).freeTimeText, "45m")
        XCTAssertEqual(overview(0).freeTimeText, "0m")
    }

    /// 空态进度是 0/0，不能显示成 100%。
    func testEmptyProgressIsZeroNotFull() {
        XCTAssertEqual(WidgetHomeOverview.empty.progressFraction, 0)
    }

    /// 进度比例被夹在 0...1，脏数据不会把环画爆。
    func testProgressFractionIsClamped() {
        let over = WidgetHomeOverview(
            done: 9, total: 3, freeMinutes: 0,
            isAllDayFree: false, priorityTaskTitle: nil,
            freeRatio: 0, busyRatio: 0
        )
        XCTAssertEqual(over.progressFraction, 1)
    }

    /// 节奏比例被夹在 0...1。
    func testRatiosAreClamped() {
        let dirty = WidgetHomeOverview(
            done: 0, total: 0, freeMinutes: 0,
            isAllDayFree: false, priorityTaskTitle: nil,
            freeRatio: 1.8, busyRatio: -0.4
        )
        XCTAssertEqual(dirty.freeRatio, 1)
        XCTAssertEqual(dirty.busyRatio, 0)
    }

    // MARK: - 纪念日 · 公历

    /// 今年还没到 → 就是今年。
    func testNextAnniversaryThisYear() {
        let target = date(2020, 12, 25)
        let next = AnniversaryCountdown.nextAnniversaryDate(
            targetDate: target, isLunar: false, now: now, calendar: calendar
        )

        XCTAssertEqual(calendar.component(.year, from: next), 2026)
        XCTAssertEqual(calendar.component(.month, from: next), 12)
        XCTAssertEqual(calendar.component(.day, from: next), 25)
    }

    /// 今年已过 → 顺延到明年。
    func testNextAnniversaryRollsToNextYear() {
        let target = date(2020, 3, 5)
        let next = AnniversaryCountdown.nextAnniversaryDate(
            targetDate: target, isLunar: false, now: now, calendar: calendar
        )

        XCTAssertEqual(calendar.component(.year, from: next), 2027)
        XCTAssertEqual(calendar.component(.month, from: next), 3)
        XCTAssertEqual(calendar.component(.day, from: next), 5)
    }

    /// 就是今天 → 倒计时 0 天。
    func testAnniversaryTodayCountsAsZeroDays() {
        let target = date(2020, 11, 10)
        let days = AnniversaryCountdown.daysUntilNext(
            targetDate: target, isLunar: false, now: now, calendar: calendar
        )

        XCTAssertEqual(days, 0)
    }

    /// 倒计时天数与日历口径一致（跨月、跨年都对）。
    func testDaysUntilMatchesCalendarDifference() {
        let target = date(2020, 12, 25)
        let days = AnniversaryCountdown.daysUntilNext(
            targetDate: target, isLunar: false, now: now, calendar: calendar
        )
        let expected = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date(2026, 12, 25))
        ).day

        XCTAssertEqual(days, expected)
    }

    /// 第几年与已相伴天数。
    func testYearsCountAndPassedDays() {
        let target = date(2023, 11, 10)

        let years = AnniversaryCountdown.yearsCount(
            targetDate: target, isLunar: false, now: now, calendar: calendar
        )
        // 2023-11-10 → 2024 是 1 周年 → 2025 是 2 周年 → 2026-11-10（今天）是 3 周年
        XCTAssertEqual(years, 3, "2023 → 2026 是第 3 周年")

        let passed = AnniversaryCountdown.passedDays(
            targetDate: target, now: now, calendar: calendar
        )
        let expected = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: target),
            to: calendar.startOfDay(for: now)
        ).day
        XCTAssertEqual(passed, expected)
    }

    // MARK: - 纪念日 · 农历（此前被完全忽略的 bug）

    /// 农历纪念日必须落在**农历**的同月同日，而不是公历同月同日。
    ///
    /// 取 2026-03-19（农历 2026 年二月初一）作为基准：
    /// 下一年的农历二月初一不是公历 3 月 19 日 —— 公历路径会算错。
    func testLunarAnniversaryDoesNotFallOnGregorianSameDate() {
        // 找一个农历 2 月 1 日对应的公历日期
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        var found: Date?
        for offset in 0..<400 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date(2026, 1, 1)) else { break }
            let comps = lunar.dateComponents([.month, .day], from: candidate)
            if comps.month == 2, comps.day == 1 {
                found = candidate
                break
            }
        }
        let target = try! XCTUnwrap(found)

        let next = AnniversaryCountdown.nextAnniversaryDate(
            targetDate: target, isLunar: true, now: now, calendar: calendar
        )

        // 结果的农历月日必须仍是 2 月 1 日
        let nextLunar = lunar.dateComponents([.month, .day], from: next)
        XCTAssertEqual(nextLunar.month, 2)
        XCTAssertEqual(nextLunar.day, 1)

        // 且不能等于公历路径的结果（否则说明农历分支没生效）
        let gregorianNext = AnniversaryCountdown.nextAnniversaryDate(
            targetDate: target, isLunar: false, now: now, calendar: calendar
        )
        XCTAssertNotEqual(
            calendar.startOfDay(for: next),
            calendar.startOfDay(for: gregorianNext),
            "农历分支与公历分支算出了同一天 —— 农历换算没生效"
        )
    }

    /// 农历下一次周年必须在今天之后（不能返回过去的日期）。
    func testLunarNextAnniversaryIsInFuture() {
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        var target: Date?
        for offset in 0..<400 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date(2020, 1, 1)) else { break }
            let comps = lunar.dateComponents([.month, .day], from: candidate)
            if comps.month == 8, comps.day == 15 {
                target = candidate
                break
            }
        }
        let origin = try! XCTUnwrap(target)

        let next = AnniversaryCountdown.nextAnniversaryDate(
            targetDate: origin, isLunar: true, now: now, calendar: calendar
        )

        XCTAssertGreaterThanOrEqual(
            calendar.startOfDay(for: next),
            calendar.startOfDay(for: now),
            "农历下一次周年不能是过去的日期"
        )
    }

    /// 农历倒计时天数不能为负。
    func testLunarDaysUntilIsNonNegative() {
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        var target: Date?
        for offset in 0..<400 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date(2020, 1, 1)) else { break }
            let comps = lunar.dateComponents([.month, .day], from: candidate)
            if comps.month == 1, comps.day == 1 {
                target = candidate
                break
            }
        }
        let origin = try! XCTUnwrap(target)

        let days = AnniversaryCountdown.daysUntilNext(
            targetDate: origin, isLunar: true, now: now, calendar: calendar
        )
        XCTAssertGreaterThanOrEqual(days, 0)
    }

    // MARK: - 倒计时文案

    func testCountdownText() {
        func entry(_ days: Int) -> WidgetAnniversaryEntry {
            WidgetAnniversaryEntry(
                id: UUID(), title: "纪念日",
                daysUntil: days, yearsCount: 1, passedDays: 100, isLunar: false
            )
        }

        XCTAssertEqual(entry(0).countdownText, "就是今天")
        XCTAssertEqual(entry(1).countdownText, "明天")
        XCTAssertEqual(entry(12).countdownText, "12 天后")
    }
}
