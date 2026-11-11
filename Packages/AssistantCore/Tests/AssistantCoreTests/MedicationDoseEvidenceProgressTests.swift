import XCTest
@testable import AssistantCore

/// 服药进度的**证据口径**回归测试。
///
/// 背景：吃药待办是系统自动关联到用药计划上的，用户直接勾完成时，
/// 计划状态必须跟着变（否则「点了没反应」）。而计划只有一个时间戳，
/// 表达不了「今天服了哪几顿」——组件因此要么多报（用户重复服药），
/// 要么谎报已服完（漏服被掩盖）。
///
/// 证据 = 今日已完成的服药待办，精确到时点。这组用例把两种方向都钉死：
/// 宁可多提醒也不能漏服，也绝不能谎报完成。
final class MedicationDoseEvidenceProgressTests: XCTestCase {

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

    private let points = ["08:00", "13:00", "20:00"]

    private func progress(
        lastTakenAt: Date?,
        evidence: Set<String>?,
        now: Date
    ) -> MedicationDoseProgress {
        MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: lastTakenAt,
            dailyTimePoints: points,
            now: now,
            calendar: calendar,
            completedSlotTimes: evidence
        )
    }

    // MARK: - 无证据：保守口径（老行为不变）

    func testWithoutEvidenceKeepsConservativeBehavior() {
        let now = date(2026, 11, 10, 9, 0)
        let p = progress(lastTakenAt: date(2026, 11, 10, 8, 30), evidence: nil, now: now)
        XCTAssertEqual(p.scheduledCount, 3)
        XCTAssertEqual(p.takenLowerBound, 1)
        XCTAssertEqual(p.pendingCount, 2)
        XCTAssertFalse(p.isFullySatisfied)
    }

    // MARK: - 证据口径：精确

    func testEvidenceCountsExactlyTakenDoses() {
        let now = date(2026, 11, 10, 14, 0)
        let p = progress(lastTakenAt: date(2026, 11, 10, 13, 10), evidence: ["08:00", "13:00"], now: now)
        XCTAssertEqual(p.takenLowerBound, 2, "证据明确服了两顿，就该报两顿")
        XCTAssertEqual(p.pendingCount, 1, "不能多报待服次数——用户会照着提示重复服药")
        XCTAssertFalse(p.isFullySatisfied)
    }

    func testEvidenceAllDosesTakenIsExactlySatisfied() {
        let now = date(2026, 11, 10, 21, 0)
        let p = progress(
            lastTakenAt: date(2026, 11, 10, 20, 5),
            evidence: ["08:00", "13:00", "20:00"], now: now)
        XCTAssertEqual(p.takenLowerBound, 3)
        XCTAssertEqual(p.pendingCount, 0)
        XCTAssertTrue(p.isFullySatisfied, "三顿都有完成记录才算服完")
    }

    /// **最关键的一条**：只服了最后一顿、漏了前两顿时，绝不能显示「已服完」。
    ///
    /// 漏服被静默掩盖的代价是漏药；误报「已服完」的代价是用户以为不用补。
    func testOnlyLastDoseTakenDoesNotReportFullySatisfied() {
        let now = date(2026, 11, 10, 21, 0)
        let p = progress(
            lastTakenAt: date(2026, 11, 10, 20, 5),
            evidence: ["20:00"], now: now)
        XCTAssertEqual(p.takenLowerBound, 1)
        XCTAssertEqual(p.pendingCount, 2, "漏了两顿就还差两顿")
        XCTAssertFalse(p.isFullySatisfied, "漏服时不能谎报已服完")
    }

    /// 时间戳比证据新时（用户从药品库直接打卡、没走待办），取两者更大值：
    /// 既不谎报未服，也不因证据缺失漏掉已服。
    func testTimestampAndEvidenceTakeTheLargerCount() {
        let now = date(2026, 11, 10, 9, 0)
        let p = progress(lastTakenAt: date(2026, 11, 10, 8, 30), evidence: [], now: now)
        XCTAssertEqual(p.takenLowerBound, 1, "时间戳已能证明今天服过，不能报 0")
    }

    /// 证据里的时点不属于今日应服集合（历史残留）时不计入。
    func testEvidenceOutsideTodaySlotsIsIgnored() {
        let now = date(2026, 11, 10, 9, 0)
        let p = progress(
            lastTakenAt: date(2026, 11, 10, 8, 30),
            evidence: ["06:00", "23:30"], now: now)
        XCTAssertEqual(p.takenLowerBound, 1, "不认识的时点不作为证据")
        XCTAssertEqual(p.pendingCount, 2)
    }
}
