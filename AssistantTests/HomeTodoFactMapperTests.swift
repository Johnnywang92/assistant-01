import AssistantCore
import XCTest

@testable import Assistant

/// 首页「今日口径」的 App 层映射测试。
///
/// 对应 docs/home-redesign-handoff.md §6 / §7：
/// SwiftData 模型 → Core 纯值事实的映射只在 App 层，Core 单测覆盖不到。
///
/// 这类筛选条件是**静默失败高发**点：
/// - 无日期的待办若不限定「今天新建」，全库陈年待办会把概览卡的分母撑爆；
/// - 已完成事项若不看完成时刻，昨天的完成会一直挂在今天的环上；
/// - 提醒时间被改过时（`reminderOverrideAt`）必须以改后的时间为准。
final class HomeTodoFactMapperTests: XCTestCase {

    /// 固定时区与固定时刻，测试完全可复现（禁止读墙上时钟）。
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

    private func map(
        dueAt: Date? = nil,
        reminderOverrideAt: Date? = nil,
        createdAt: Date,
        completedAt: Date? = nil,
        isDone: Bool = false
    ) -> HomeTodoCandidate {
        HomeTodoFactMapper.map(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            isDone: isDone,
            dueAt: dueAt,
            reminderOverrideAt: reminderOverrideAt,
            createdAt: createdAt,
            completedAt: completedAt,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - 计入规则

    /// 今天到期的活跃待办计入。
    func testActiveTodoDueTodayIsIncluded() {
        let result = map(dueAt: date(2026, 11, 10, 9, 0), createdAt: date(2026, 11, 9))

        XCTAssertTrue(result.isIncluded)
        XCTAssertEqual(result.fact?.isDone, false)
        XCTAssertEqual(result.fact?.dueAt, date(2026, 11, 10, 9, 0))
    }

    /// 逾期但仍在今天之前 → 计入且标记 overdue（逾期是今天之前的日期，不是未来）。
    func testOverdueTodoIsIncludedAndFlagged() {
        let result = map(dueAt: date(2026, 11, 8, 9, 0), createdAt: date(2026, 11, 7))

        XCTAssertTrue(result.isIncluded)
        XCTAssertEqual(result.fact?.isOverdue, true)
    }

    /// 明天到期 → 不计入今天的环。
    func testTomorrowDueIsExcluded() {
        let result = map(dueAt: date(2026, 11, 11, 9, 0), createdAt: date(2026, 11, 9))

        XCTAssertFalse(result.isIncluded)
        XCTAssertNil(result.fact)
    }

    /// 无日期 + 今天新建 → 计入。
    func testNoDateCreatedTodayIsIncluded() {
        let result = map(createdAt: date(2026, 11, 10, 8, 0))

        XCTAssertTrue(result.isIncluded)
        XCTAssertNil(result.fact?.dueAt)
        XCTAssertEqual(result.fact?.isOverdue, false, "无日期不算逾期")
    }

    /// 无日期 + 早于今天新建 → **不计入**。这是防止分母被陈年待办撑爆的关键。
    func testNoDateCreatedBeforeTodayIsExcluded() {
        let result = map(createdAt: date(2025, 1, 1, 8, 0))

        XCTAssertFalse(result.isIncluded, "陈年无日期待办不能计入今天的环")
        XCTAssertNil(result.fact)
    }

    // MARK: - 提醒时间覆盖

    /// 提醒时间被改过 → 以改后的时间为准，且只在改后的时间落在今天时计入。
    func testReminderOverrideTakesPrecedence() {
        // 原到期在昨天，但提醒被改到今天 → 计入
        let included = map(
            dueAt: date(2026, 11, 9, 9, 0),
            reminderOverrideAt: date(2026, 11, 10, 15, 0),
            createdAt: date(2026, 11, 9)
        )
        XCTAssertTrue(included.isIncluded)
        XCTAssertEqual(included.fact?.dueAt, date(2026, 11, 10, 15, 0))

        // 原到期在今天，但提醒被改到明天 → 不计入
        let excluded = map(
            dueAt: date(2026, 11, 10, 9, 0),
            reminderOverrideAt: date(2026, 11, 11, 15, 0),
            createdAt: date(2026, 11, 9)
        )
        XCTAssertFalse(excluded.isIncluded)
    }

    // MARK: - 已完成

    /// 今天完成的 → 计入且 isDone 为 true。
    func testCompletedTodayIsIncluded() {
        let result = map(
            createdAt: date(2026, 11, 9),
            completedAt: date(2026, 11, 10, 11, 0),
            isDone: true
        )

        XCTAssertTrue(result.isIncluded)
        XCTAssertEqual(result.fact?.isDone, true)
        XCTAssertEqual(result.fact?.isOverdue, false, "已完成不算逾期")
    }

    /// 昨天完成的 → 不计入今天（否则昨天的完成会一直挂在今天的环上）。
    func testCompletedYesterdayIsExcluded() {
        let result = map(
            createdAt: date(2026, 11, 8),
            completedAt: date(2026, 11, 9, 11, 0),
            isDone: true
        )

        XCTAssertFalse(result.isIncluded)
        XCTAssertNil(result.fact)
    }

    /// 标记完成但没有完成时刻 → 不计入（不能因为"已完成"就默认计入今天）。
    func testDoneWithoutCompletionTimestampIsExcluded() {
        let result = map(createdAt: date(2026, 11, 9), completedAt: nil, isDone: true)

        XCTAssertFalse(result.isIncluded)
    }

    // MARK: - 与 Core 的一致性

    /// 映射出的事实直接喂给 Core，端到端口径一致：
    /// 2 件今天到期 + 1 件今天完成 → 环显示 1/3。
    func testMappedFactsFeedCoreSnapshotConsistently() {
        let candidates = [
            map(dueAt: date(2026, 11, 10, 9, 0), createdAt: date(2026, 11, 9)),
            map(dueAt: date(2026, 11, 10, 11, 0), createdAt: date(2026, 11, 9)),
            map(createdAt: date(2026, 11, 9), completedAt: date(2026, 11, 10, 12, 0), isDone: true),
            // 明天到期，不计入
            map(dueAt: date(2026, 11, 11, 9, 0), createdAt: date(2026, 11, 9)),
            // 陈年无日期，不计入
            map(createdAt: date(2024, 1, 1))
        ]
        let facts = candidates.compactMap(\.fact)

        let snapshot = HomeSnapshotBuilder.make(
            todos: facts,
            schedule: .unscheduled,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.total, 3)
        XCTAssertEqual(snapshot.done, 1)
        XCTAssertEqual(snapshot.state, .partial(done: 1, total: 3))
    }
}
