import XCTest
@testable import AssistantCore

/// `MedicationHabitDoseResolver` 的口径回归测试。
///
/// 这组用例的价值在于：**它们是「组件与 App 对不上」这类静默失败的护栏**。
/// 改动前四处判定各不相同（无窗口 / 3h / 4h / isDateInToday），
/// 这里统一钉住「唯一实现」的语义。
final class MedicationHabitDoseResolverTests: XCTestCase {

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

    // MARK: - 今日边界

    func testIsSameDayUsesInjectedNowNotWallClock() {
        // now 固定在 2026-11-10 15:00
        let now = date(2026, 11, 10, 15, 0)
        XCTAssertTrue(MedicationHabitDoseResolver.isSameDay(date(2026, 11, 10, 8, 0), now: now, calendar: calendar))
        XCTAssertTrue(MedicationHabitDoseResolver.isSameDay(date(2026, 11, 10, 23, 59), now: now, calendar: calendar))
        XCTAssertFalse(MedicationHabitDoseResolver.isSameDay(date(2026, 11, 9, 23, 59), now: now, calendar: calendar))
        XCTAssertFalse(MedicationHabitDoseResolver.isSameDay(date(2026, 11, 11, 0, 0), now: now, calendar: calendar))
    }

    func testEndOfTodayIsExclusiveNextDayStart() {
        let now = date(2026, 11, 10, 15, 0)
        let end = MedicationHabitDoseResolver.endOfToday(now: now, calendar: calendar)
        XCTAssertEqual(end, date(2026, 11, 11, 0, 0))
        // 今日最后一刻仍在今日内
        XCTAssertLessThan(date(2026, 11, 10, 23, 59), end)
    }

    // MARK: - 服药「今日是否已服」

    func testMedicationTakenTodayOnlyCountsSameCalendarDay() {
        let now = date(2026, 11, 10, 15, 0)
        XCTAssertTrue(MedicationHabitDoseResolver.isMedicationTakenToday(
            lastTakenAt: date(2026, 11, 10, 8, 0), now: now, calendar: calendar))
        // 昨天服过 → 今日不算已服
        XCTAssertFalse(MedicationHabitDoseResolver.isMedicationTakenToday(
            lastTakenAt: date(2026, 11, 9, 20, 0), now: now, calendar: calendar))
        // 明天（未来）的时间戳也不能算今日已服
        XCTAssertFalse(MedicationHabitDoseResolver.isMedicationTakenToday(
            lastTakenAt: date(2026, 11, 11, 8, 0), now: now, calendar: calendar))
        XCTAssertFalse(MedicationHabitDoseResolver.isMedicationTakenToday(
            lastTakenAt: nil, now: now, calendar: calendar))
    }

    func testTakenTodayIsIndependentOfElapsedHours() {
        // 改动前：药品库用 3h 窗口、小组件无窗口、看板 4h 窗口。
        // 现在「今日已服」只看日历日，几小时都不影响。
        let now = date(2026, 11, 10, 20, 0)
        XCTAssertTrue(MedicationHabitDoseResolver.isMedicationTakenToday(
            lastTakenAt: date(2026, 11, 10, 8, 0), now: now, calendar: calendar))
    }

    // MARK: - 防重复打卡窗口

    func testCooldownWindowBoundary() {
        let now = date(2026, 11, 10, 15, 0)
        // 刚打完 → 冷却中
        XCTAssertTrue(MedicationHabitDoseResolver.isMedicationWithinCooldown(
            lastTakenAt: date(2026, 11, 10, 14, 0), now: now))
        // 恰好 3 小时 → 不在窗口内（终点不含）
        XCTAssertFalse(MedicationHabitDoseResolver.isMedicationWithinCooldown(
            lastTakenAt: date(2026, 11, 10, 12, 0), now: now))
        // 未来时间戳（时钟回拨 / 数据异常）不当成冷却中
        XCTAssertFalse(MedicationHabitDoseResolver.isMedicationWithinCooldown(
            lastTakenAt: date(2026, 11, 10, 16, 0), now: now))
        XCTAssertFalse(MedicationHabitDoseResolver.isMedicationWithinCooldown(lastTakenAt: nil, now: now))
    }

    func testSafetyIntervalIsLongerThanTapCooldown() {
        // 3h = UI 防抖，4h = 服药安全间隔。两者语义不同，不该被合并成一个数。
        XCTAssertEqual(MedicationHabitDoseResolver.tapCooldown, 3 * 3600)
        XCTAssertEqual(MedicationHabitDoseResolver.safetyInterval, 4 * 3600)
        XCTAssertGreaterThan(
            MedicationHabitDoseResolver.safetyInterval,
            MedicationHabitDoseResolver.tapCooldown
        )
    }

    // MARK: - 打卡「今日是否该打」

    func testHabitDueTodayCoversOverdueButNotTomorrow() {
        let now = date(2026, 11, 10, 15, 0)
        // 昨天到期、今天没打 → 仍算今日该打卡（含逾期）
        XCTAssertTrue(MedicationHabitDoseResolver.isHabitDueToday(
            nextDueAt: date(2026, 11, 9, 8, 0), lastCompletedAt: nil, now: now, calendar: calendar))
        // 今天晚上到期 → 今天该打卡
        XCTAssertTrue(MedicationHabitDoseResolver.isHabitDueToday(
            nextDueAt: date(2026, 11, 10, 21, 0), lastCompletedAt: nil, now: now, calendar: calendar))
        // 明天到期 → 不算
        XCTAssertFalse(MedicationHabitDoseResolver.isHabitDueToday(
            nextDueAt: date(2026, 11, 11, 8, 0), lastCompletedAt: nil, now: now, calendar: calendar))
    }

    func testHabitDueTodayFalseWhenCompletedToday() {
        let now = date(2026, 11, 10, 15, 0)
        // 今天已打卡 → 不该再提示
        XCTAssertFalse(MedicationHabitDoseResolver.isHabitDueToday(
            nextDueAt: date(2026, 11, 10, 8, 0),
            lastCompletedAt: date(2026, 11, 10, 9, 0), now: now, calendar: calendar))
        // 昨天打过卡 → 今天仍该打卡（不是今天完成的）
        XCTAssertTrue(MedicationHabitDoseResolver.isHabitDueToday(
            nextDueAt: date(2026, 11, 10, 8, 0),
            lastCompletedAt: date(2026, 11, 9, 9, 0), now: now, calendar: calendar))
    }

    func testHasReachedDueTimeIsSeparateFromIsDueToday() {
        let now = date(2026, 11, 10, 7, 0)
        // 今天 8:00 到期：按「今天该打卡」算要打卡，但此刻还没到点
        XCTAssertTrue(MedicationHabitDoseResolver.isHabitDueToday(
            nextDueAt: date(2026, 11, 10, 8, 0), lastCompletedAt: nil, now: now, calendar: calendar))
        XCTAssertFalse(MedicationHabitDoseResolver.hasReachedDueTime(
            nextDueAt: date(2026, 11, 10, 8, 0), now: now))
        // 过了点 → 两个都成立
        let later = date(2026, 11, 10, 9, 0)
        XCTAssertTrue(MedicationHabitDoseResolver.hasReachedDueTime(
            nextDueAt: date(2026, 11, 10, 8, 0), now: later))
    }

    // MARK: - 服药进度（保守口径）

    func testDoseProgressCountsScheduledSlots() {
        let now = date(2026, 11, 10, 15, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: nil,
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now, calendar: calendar)
        XCTAssertEqual(progress.scheduledCount, 3)
        XCTAssertEqual(progress.takenLowerBound, 0)
        XCTAssertEqual(progress.pendingCount, 3)
        XCTAssertFalse(progress.isFullySatisfied)
    }

    func testDoseProgressDoesNotOverclaimMultipleDoses() {
        // 单个 lastTakenAt 无法表达一天三次服药。
        // 吃了 1 次后不能报「已服 3 次」——谎报会让用户漏服。
        let now = date(2026, 11, 10, 9, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: date(2026, 11, 10, 8, 0),
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now, calendar: calendar)
        XCTAssertEqual(progress.scheduledCount, 3)
        XCTAssertEqual(progress.takenLowerBound, 1)
        // 8:00 那次服了，但 13:00 / 20:00 还没到 → 未满足
        XCTAssertFalse(progress.isFullySatisfied)
        XCTAssertEqual(progress.pendingCount, 2)
    }

    func testDoseProgressFullySatisfiedOnlyAfterLastSlot() {
        let now = date(2026, 11, 10, 21, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: date(2026, 11, 10, 20, 30),
            dailyTimePoints: ["08:00", "13:00", "20:00"],
            now: now, calendar: calendar)
        XCTAssertTrue(progress.isFullySatisfied)
        // 仍然是保守下界，不谎报「3 次全吃了」
        XCTAssertEqual(progress.takenLowerBound, 1)
    }

    func testDoseProgressWithNoSlotsIsSatisfiedAndNotDue() {
        let now = date(2026, 11, 10, 15, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: nil, dailyTimePoints: [], now: now, calendar: calendar)
        XCTAssertEqual(progress.scheduledCount, 0)
        XCTAssertEqual(progress.pendingCount, 0)
        XCTAssertTrue(progress.isFullySatisfied)
    }

    func testInvalidTimePointsAreSkippedNotFatal() {
        let now = date(2026, 11, 10, 15, 0)
        let progress = MedicationHabitDoseResolver.doseProgress(
            lastTakenAt: nil,
            dailyTimePoints: ["08:00", "不是时间", "25:00", "20:00"],
            now: now, calendar: calendar)
        XCTAssertEqual(progress.scheduledCount, 2)
    }

    // MARK: - 跨时区

    func testIsSameDayIsTimeZoneAware() {
        // 洛杉矶 2026-11-09 20:00 == 上海 2026-11-10 11:00
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let laNow = la.date(from: DateComponents(
            year: 2026, month: 11, day: 9, hour: 20, minute: 0))!

        // 用洛杉矶日历判定 → 那是 LA 的 11-09
        XCTAssertTrue(MedicationHabitDoseResolver.isSameDay(
            laNow, now: laNow, calendar: la))
        // 同一瞬间换上海日历 → 是上海的 11-10
        XCTAssertTrue(MedicationHabitDoseResolver.isSameDay(
            laNow, now: laNow, calendar: calendar))
        XCTAssertNotEqual(
            MedicationHabitDoseResolver.startOfToday(now: laNow, calendar: la),
            MedicationHabitDoseResolver.startOfToday(now: laNow, calendar: calendar)
        )
    }
}
