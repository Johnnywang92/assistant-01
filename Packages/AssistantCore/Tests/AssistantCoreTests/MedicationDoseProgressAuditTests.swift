import XCTest
@testable import AssistantCore

/// 审查发现的真问题复现（先红后绿）。
///
/// 核心风险：**组件显示「待服 N 次」会让用户重复服药（过量）**。
/// 一天 3 次的药，用户 08:00 和 20:00 都服了，系统只留一个 `lastTakenAt`，
/// 若按「应服数 − 已服下界(1)」算，就会显示「还待服 2 次」→ 用户再吃 2 次。
final class MedicationDoseProgressAuditTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hh; comps.minute = mm
        return calendar.date(from: comps)!
    }

    // MARK: - P0：已服完却仍报「待服」

    /// 一天 3 次的药，20:05 服了最后一次 → 应服数 3、下界 1。
    ///
    /// 旧算法 `pendingCount = scheduledCount - takenLowerBound` = 3 − 1 = 2，
    /// **组件会显示「待服 2 次」→ 用户重复服药**。
    /// 正确：最后一次服药不早于最后一个时点 → 已服完，pendingCount = 0。
    func testFullySatisfiedMustNotReportPendingDoses() {
        let now = date(2026, 11, 10, 20, 30)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: date(2026, 11, 10, 20, 5),
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(progress.isFullySatisfied)
        XCTAssertEqual(
            progress.pendingCount, 0,
            "已服完却报待服 → 用户会重复服药（过量风险）"
        )
    }

    /// 保守下界只适用于「确实不知道」的情形；
    /// 已服完（有明确证据）时必须给出精确结论。
    func testPendingCountIsZeroWhenFullySatisfied() {
        let now = date(2026, 11, 10, 21, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: date(2026, 11, 10, 20, 0),
            dailyTimePoints: ["08:00", "20:00"],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(progress.pendingCount, 0)
    }

    /// 未服完时仍然按保守下界报（宁可多提醒也不漏服）。
    func testPendingCountStillConservativeWhenNotSatisfied() {
        let now = date(2026, 11, 10, 9, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: date(2026, 11, 10, 8, 0),
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(progress.isFullySatisfied)
        // 8:00 吃了，13:00 / 20:00 未到 → 保守报 2 次待服
        XCTAssertEqual(progress.pendingCount, 2)
    }

    // MARK: - P1：跨计划匹配服药待办

    /// 「维生素D」的计划不能匹配到「维生素D3」的待办。
    ///
    /// 旧实现用 `title.contains(plan.medName)`：待办「服药：维生素D3（08:00）」
    /// 包含「维生素D」→ 点「维生素D」的按钮会完成「维生素D3」的待办 → 漏服。
    func testSlotTitleMatchingIsExactNotSubstring() {
        let titles = MedicationTodoMaterializer.slotTitles(
            medName: "维生素D",
            dailyTimePoints: ["08:00"],
            on: date(2026, 11, 10, 8, 0),
            calendar: calendar
        )
        XCTAssertEqual(titles, ["服药：维生素D（08:00）"])

        // 「维生素D3」的待办标题不等于「维生素D」的槽位标题
        let otherTitles = MedicationTodoMaterializer.slotTitles(
            medName: "维生素D3",
            dailyTimePoints: ["08:00"],
            on: date(2026, 11, 10, 8, 0),
            calendar: calendar
        )
        XCTAssertFalse(
            titles.contains(otherTitles[0]),
            "「维生素D」的槽位标题不能匹配「维生素D3」的待办"
        )
    }

    /// 标题完全相同时必须能匹配上（否则功能直接失效）。
    func testSlotTitleMatchesIdenticalTodoTitle() {
        let titles = MedicationTodoMaterializer.slotTitles(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "20:00"],
            on: date(2026, 11, 10, 8, 0),
            calendar: calendar
        )
        XCTAssertEqual(titles, ["服药：阿莫西林（08:00）", "服药：阿莫西林（20:00）"])
    }

    // MARK: - P1：漏服时点必须被识别

    /// 08:00 的时点已过但没吃 → 必须能识别为「漏服」。
    ///
    /// 组件只显示「下一顿 13:00」会让用户以为 08:00 那顿不用管 → 漏服。
    func testMissedSlotIsDetected() {
        let now = date(2026, 11, 10, 9, 0)
        let missed = MedicationHabitDoseResolver.missedSlotText(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            completedTitles: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(missed, "08:00")
    }

    /// 已完成则没有漏服。
    func testNoMissedSlotWhenCompleted() {
        let now = date(2026, 11, 10, 9, 0)
        let completed = MedicationTodoMaterializer.slotTitles(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00"],
            on: now,
            calendar: calendar
        )
        let missed = MedicationHabitDoseResolver.missedSlotText(
            medName: "阿莫西林",
            dailyTimePoints: ["08:00", "13:00"],
            completedTitles: Set(completed),
            now: now,
            calendar: calendar
        )
        XCTAssertNil(missed)
    }
}
