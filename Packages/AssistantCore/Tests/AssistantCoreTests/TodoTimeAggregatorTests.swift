import XCTest

@testable import AssistantCore

final class TodoTimeAggregatorTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        cal.firstWeekday = 2 // 周一开始，与中文习惯一致
        return cal
    }()

    /// 2026-10-27（周二）10:00 作为参照时刻
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 27
        comps.hour = 10; comps.minute = 0
        return calendar.date(from: comps)!
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 9, _ mi: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi
        return calendar.date(from: comps)!
    }

    // MARK: - 互斥性（计数与详情一致的根基）

    func testBucketsAreMutuallyExclusive() {
        let items = [
            TodoTimeSnapshot(dueAt: date(2026, 10, 20), createdAt: date(2026, 10, 1)),
            TodoTimeSnapshot(dueAt: date(2026, 10, 27), createdAt: date(2026, 10, 1)),
            TodoTimeSnapshot(dueAt: date(2026, 10, 29), createdAt: date(2026, 10, 1)),
            TodoTimeSnapshot(dueAt: date(2026, 11, 20), createdAt: date(2026, 10, 1))
        ]
        let result = TodoTimeAggregator.bucket(items, now: now, calendar: calendar)
        let allIDs = result.overdue + result.today + result.thisWeek
        XCTAssertEqual(allIDs.count, Set(allIDs).count, "同一事项不得落进两个桶")
        XCTAssertEqual(result.overdue.count, 1)
        XCTAssertEqual(result.today.count, 1)
        XCTAssertEqual(result.thisWeek.count, 1, "超出本周的事项不进聚合")
    }

    func testCountsMatchDetailLists() {
        let items = (0..<10).map { i in
            TodoTimeSnapshot(
                dueAt: date(2026, 10, 20 + i),
                createdAt: date(2026, 10, 1)
            )
        }
        let result = TodoTimeAggregator.bucket(items, now: now, calendar: calendar)
        for kind in TodoTimeBucketKind.allCases {
            XCTAssertEqual(result.count(for: kind), result.ids(for: kind).count)
        }
    }

    // MARK: - 逾期桶

    func testItemDueYesterdayIsOverdue() {
        let item = TodoTimeSnapshot(dueAt: date(2026, 10, 26, 23, 30), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.overdue, [item.id])
    }

    func testItemDueEarlierTodayIsTodayNotOverdue() {
        // 今天上午 9 点到期、现在 10 点 —— 属于「今天该做的」，不是逾期
        let item = TodoTimeSnapshot(dueAt: date(2026, 10, 27, 9, 0), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.today, [item.id])
        XCTAssertTrue(result.overdue.isEmpty)
    }

    func testItemDueExactlyAtStartOfTodayIsToday() {
        let startOfToday = calendar.startOfDay(for: now)
        let item = TodoTimeSnapshot(dueAt: startOfToday, createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.today, [item.id])
    }

    // MARK: - 今天桶

    func testItemDueLaterTodayIsToday() {
        let item = TodoTimeSnapshot(dueAt: date(2026, 10, 27, 18, 0), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.today, [item.id])
    }

    func testNoDateItemCreatedTodayIsToday() {
        let item = TodoTimeSnapshot(dueAt: nil, createdAt: date(2026, 10, 27, 8, 0))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.today, [item.id])
    }

    func testNoDateItemCreatedYesterdayIsNotBucketed() {
        let item = TodoTimeSnapshot(dueAt: nil, createdAt: date(2026, 10, 26, 22, 0))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty, "昨天创建的无日期事项不进时间聚合")
    }

    // MARK: - 本周桶

    func testItemDueTomorrowIsThisWeek() {
        let item = TodoTimeSnapshot(dueAt: date(2026, 10, 28), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.thisWeek, [item.id])
    }

    func testItemDueOnWeekendIsThisWeek() {
        // 2026-10-27 是周二（firstWeekday=2），本周末为 11-01 周日（区间终点 11-02 零点）
        let item = TodoTimeSnapshot(dueAt: date(2026, 10, 31, 20, 0), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.thisWeek, [item.id])
    }

    func testItemDueAfterEndOfWeekIsExcluded() {
        let item = TodoTimeSnapshot(dueAt: date(2026, 11, 2), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty, "下周及以后的事项不进聚合")
    }

    func testThisWeekIsEmptyWhenTodayIsLastDayOfWeek() {
        // 2026-11-01（周日）是本周最后一天：明天起属下周
        let sundayNow = date(2026, 11, 1, 10, 0)
        let monday = TodoTimeSnapshot(dueAt: date(2026, 11, 2), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([monday], now: sundayNow, calendar: calendar)
        XCTAssertTrue(result.thisWeek.isEmpty)
    }

    // MARK: - 改期优先与完成排除

    func testReminderOverrideTakesPrecedenceOverDueAt() {
        // 原定昨天（逾期），改期到周五 → 落本周桶
        let item = TodoTimeSnapshot(
            dueAt: date(2026, 10, 26),
            reminderOverrideAt: date(2026, 10, 30),
            createdAt: date(2026, 10, 1)
        )
        let result = TodoTimeAggregator.bucket([item], now: now, calendar: calendar)
        XCTAssertEqual(result.thisWeek, [item.id])
        XCTAssertTrue(result.overdue.isEmpty)
    }

    func testDoneItemsAreExcluded() {
        let items = [
            TodoTimeSnapshot(dueAt: date(2026, 10, 20), createdAt: date(2026, 10, 1), isDone: true),
            TodoTimeSnapshot(dueAt: date(2026, 10, 27), createdAt: date(2026, 10, 1), isDone: true),
            TodoTimeSnapshot(dueAt: date(2026, 10, 29), createdAt: date(2026, 10, 1), isDone: true)
        ]
        let result = TodoTimeAggregator.bucket(items, now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 排序

    func testOverdueSortedByEffectiveDateAscending() {
        let older = TodoTimeSnapshot(dueAt: date(2026, 10, 20), createdAt: date(2026, 10, 1))
        let newer = TodoTimeSnapshot(dueAt: date(2026, 10, 25), createdAt: date(2026, 10, 1))
        let result = TodoTimeAggregator.bucket([newer, older], now: now, calendar: calendar)
        XCTAssertEqual(result.overdue, [older.id, newer.id], "更早到期的排前面")
    }

    func testEmptyInputProducesEmptyBuckets() {
        let result = TodoTimeAggregator.bucket([], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result, .empty)
    }
}
