import XCTest
@testable import AssistantCore

/// 预算告警的判定与跨月重置测试。
///
/// 这套逻辑决定「什么时候打扰用户」。判错两种方向都伤：
/// 天天提醒会被静音，真超支时反而不提醒等于没有这功能。
final class BudgetAlertEngineTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    // MARK: - 档位判定

    func testNoBudgetMeansNoAlert() {
        XCTAssertEqual(BudgetAlertEngine.level(monthlyBudget: 0, spentThisMonth: 9999), .none)
        let decision = BudgetAlertEngine.decide(
            monthlyBudget: 0, spentThisMonth: 9999, state: .empty, now: date(2026, 10, 5)
        )
        XCTAssertFalse(decision.shouldNotify)
    }

    func testBelowThresholdIsNone() {
        XCTAssertEqual(BudgetAlertEngine.level(monthlyBudget: 1000, spentThisMonth: 799), .none)
    }

    func testApproachingThreshold() {
        XCTAssertEqual(BudgetAlertEngine.level(monthlyBudget: 1000, spentThisMonth: 800), .approaching)
    }

    func testExceededThreshold() {
        XCTAssertEqual(BudgetAlertEngine.level(monthlyBudget: 1000, spentThisMonth: 1000), .exceeded)
    }

    func testSevereThreshold() {
        XCTAssertEqual(BudgetAlertEngine.level(monthlyBudget: 1000, spentThisMonth: 1200), .severe)
    }

    // MARK: - 决策

    func testDecisionCarriesRemainingAndOverspent() {
        let decision = BudgetAlertEngine.decide(
            monthlyBudget: 1000, spentThisMonth: 1250, state: .empty, now: date(2026, 10, 5)
        )
        XCTAssertEqual(decision.level, .severe)
        XCTAssertTrue(decision.shouldNotify)
        XCTAssertEqual(decision.remaining, -250, accuracy: 0.0001)
        XCTAssertEqual(decision.overspent, 250, accuracy: 0.0001)
        XCTAssertEqual(decision.spentRatio, 1.25, accuracy: 0.0001)
    }

    /// 同一档位每月只提醒一次
    func testSameLevelDoesNotNotifyTwice() {
        let now = date(2026, 10, 5)
        let first = BudgetAlertEngine.decide(
            monthlyBudget: 1000, spentThisMonth: 850, state: .empty, now: now
        )
        XCTAssertTrue(first.shouldNotify)

        let state = BudgetAlertEngine.markingNotified(.empty, level: first.level, now: now)
        let second = BudgetAlertEngine.decide(
            monthlyBudget: 1000, spentThisMonth: 880, state: state, now: now
        )
        XCTAssertFalse(second.shouldNotify, "同一档位不应重复提醒")
    }

    /// 档位升级要能再提醒一次（80% → 100%）
    func testEscalatingLevelNotifiesAgain() {
        let now = date(2026, 10, 5)
        var state = BudgetAlertEngine.markingNotified(
            .empty, level: .approaching, now: now
        )
        let decision = BudgetAlertEngine.decide(
            monthlyBudget: 1000, spentThisMonth: 1050, state: state, now: now
        )
        XCTAssertEqual(decision.level, .exceeded)
        XCTAssertTrue(decision.shouldNotify, "档位升级应再次提醒")
        state = BudgetAlertEngine.markingNotified(state, level: decision.level, now: now)
        XCTAssertEqual(state.notifiedLevels, [BudgetAlertLevel.approaching.rawValue, BudgetAlertLevel.exceeded.rawValue])
    }

    // MARK: - 跨月重置

    /// 跨月自动重置：新的一月重新可以提醒
    func testMonthRolloverResetsNotifiedLevels() {
        let october = date(2026, 10, 20)
        let november = date(2026, 11, 2)
        let state = BudgetAlertEngine.markingNotified(.empty, level: .exceeded, now: october)

        let rolled = BudgetAlertEngine.rolledOver(state, now: november, calendar: calendar)
        XCTAssertTrue(rolled.notifiedLevels.isEmpty, "跨月应清空已提醒记录")
        XCTAssertEqual(rolled.year, 2026)
        XCTAssertEqual(rolled.month, 11)

        let decision = BudgetAlertEngine.decide(
            monthlyBudget: 1000, spentThisMonth: 1100, state: state, now: november, calendar: calendar
        )
        XCTAssertTrue(decision.shouldNotify, "新的一月应能再次提醒")
    }

    /// 跨年也要重置（12 月 → 1 月）
    func testYearRolloverResetsNotifiedLevels() {
        let december = date(2026, 12, 28)
        let january = date(2027, 1, 3)
        let state = BudgetAlertEngine.markingNotified(.empty, level: .severe, now: december)
        let rolled = BudgetAlertEngine.rolledOver(state, now: january, calendar: calendar)
        XCTAssertTrue(rolled.notifiedLevels.isEmpty)
        XCTAssertEqual(rolled.year, 2027)
        XCTAssertEqual(rolled.month, 1)
    }

    /// 同月内不得重置（否则每次评估都会重复提醒）
    func testSameMonthKeepsNotifiedLevels() {
        let now = date(2026, 10, 20)
        let state = BudgetAlertEngine.markingNotified(.empty, level: .approaching, now: now)
        let rolled = BudgetAlertEngine.rolledOver(state, now: date(2026, 10, 25), calendar: calendar)
        XCTAssertEqual(rolled, state)
    }

    /// 标记提醒时也会顺带做跨月重置（避免旧状态粘在新月份上）
    func testMarkingNotifiedAppliesRollover() {
        let state = BudgetAlertState(year: 2026, month: 9, notifiedLevels: [BudgetAlertLevel.exceeded.rawValue])
        let marked = BudgetAlertEngine.markingNotified(state, level: .approaching, now: date(2026, 10, 1), calendar: calendar)
        XCTAssertEqual(marked.year, 2026)
        XCTAssertEqual(marked.month, 10)
        XCTAssertEqual(marked.notifiedLevels, [BudgetAlertLevel.approaching.rawValue])
    }

    /// 档位顺序：none < approaching < exceeded < severe
    func testLevelOrdering() {
        XCTAssertLessThan(BudgetAlertLevel.none, BudgetAlertLevel.approaching)
        XCTAssertLessThan(BudgetAlertLevel.approaching, BudgetAlertLevel.exceeded)
        XCTAssertLessThan(BudgetAlertLevel.exceeded, BudgetAlertLevel.severe)
    }
}
