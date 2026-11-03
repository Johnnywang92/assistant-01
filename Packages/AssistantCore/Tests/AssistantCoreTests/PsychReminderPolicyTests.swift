import AssistantCore
import XCTest

/// 心理提醒决策的回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **低分档用户被反复打扰**——心理健康场景里「被提醒」会被读成「我有病」，
///    持续骚扰会导致用户直接关掉通知，这个功能就永久失效了。
/// 2. **把一次波动当趋势**——「比上次高」不等于「连续两周上行」，
///    单点波动就推送会让提醒失去可信度。
/// 3. **冷却窗口失效**——用户连续几天收到同一句提醒，直接关通知。
/// 4. **规则用了 `now` 却拿墙上时钟比对**——`now` 形同虚设，规则失去单测能力。
/// 5. **决策依赖传入顺序**——App 侧查询顺序一变，判定结果就变。
final class PsychReminderPolicyTests: XCTestCase {

    // MARK: - 测试辅助

    /// 固定日历时区，避免测试随时区漂移。
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()

    /// 基准日：2026-11-02 00:00:00 +0800
    private let baseDate = Date(timeIntervalSince1970: 1_792_819_200)

    private func entry(
        daysAgo: Int,
        score: Int,
        band: PsychBandLevel? = nil,
        scale: PsychScaleID = .phq9
    ) -> PsychScoreHistoryEntry {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: baseDate) ?? baseDate
        let resolvedBand = band ?? PsychScaleCatalog.phq9.band(forTotal: score)?.level ?? .none
        return PsychScoreHistoryEntry(
            scaleID: scale,
            completedAt: date,
            totalScore: score,
            band: resolvedBand
        )
    }

    private func decide(
        _ history: [PsychScoreHistoryEntry],
        lastNotifiedAt: Date? = nil,
        now: Date? = nil
    ) -> PsychReminderDecision {
        PsychReminderPolicy.decide(
            history: history,
            lastNotifiedAt: lastNotifiedAt,
            now: now ?? baseDate,
            calendar: calendar
        )
    }

    // MARK: - 低分不打扰（核心风险 1）

    /// 核心风险 1：低分档即使连续上升也不该打扰。
    ///
    /// 「连续两次上升」但分数仍低（如 0→1→2，都在轻度以下），
    /// 推送这种提醒既没有信息量，又会让用户把「被提醒」读成「我有病」。
    func testLowBandNeverNotifiesEvenWhenRising() {
        let history = [
            entry(daysAgo: 21, score: 0, band: .none),
            entry(daysAgo: 14, score: 1, band: .none),
            entry(daysAgo: 7, score: 2, band: .none)
        ]
        let decision = decide(history)
        XCTAssertFalse(decision.shouldNotify, "低分档不得打扰——这是最容易被违反的一条")
        XCTAssertNil(decision.kind)
    }

    /// 低分档且距上次评估很久，同样不提醒（到期提醒也不该给低分用户发）。
    func testLowBandDoesNotNotifyEvenWhenAssessmentOverdue() {
        let history = [
            entry(daysAgo: 60, score: 1, band: .none),
            entry(daysAgo: 40, score: 0, band: .none)
        ]
        let decision = decide(history)
        XCTAssertFalse(decision.shouldNotify)
    }

    // MARK: - 连续上行判定（核心风险 2）

    /// 核心风险 2：两个点只能说明「比上次高」，那是波动不是趋势，不该推送。
    func testSingleRiseWithOnlyTwoSamplesDoesNotTriggerTrendAlert() {
        let history = [
            entry(daysAgo: 7, score: 6, band: .mild),
            entry(daysAgo: 0, score: 10, band: .moderate)
        ]
        let decision = decide(history)
        XCTAssertNotEqual(decision.kind, .risingTrend, "两个点不足以判断连续上行")
    }

    /// 三个点、连续两次上升 → 触发趋势提醒。
    func testConsecutiveRisesTriggerTrendAlert() {
        let history = [
            entry(daysAgo: 21, score: 5, band: .mild),
            entry(daysAgo: 14, score: 9, band: .mild),
            entry(daysAgo: 7, score: 13, band: .moderate)
        ]
        let decision = decide(history)
        XCTAssertEqual(decision.kind, .risingTrend)
        XCTAssertEqual(decision.latestScore, 13)
    }

    /// 中间被打断的上升不算「连续」：`[5, 9, 4, 13]` 末尾只有 1 次上升。
    func testInterruptedRiseDoesNotCountAsConsecutive() {
        let history = [
            entry(daysAgo: 28, score: 5, band: .mild),
            entry(daysAgo: 21, score: 9, band: .mild),
            entry(daysAgo: 14, score: 4, band: .none),
            entry(daysAgo: 7, score: 13, band: .moderate)
        ]
        let decision = decide(history)
        XCTAssertNotEqual(decision.kind, .risingTrend, "被下降打断的上升不算连续")
    }

    /// 连续上升次数计算：末尾连续上升的段长度。
    func testConsecutiveRiseCountCountsTailOnly() {
        let history = [
            entry(daysAgo: 28, score: 3, band: .none),
            entry(daysAgo: 21, score: 5, band: .none),
            entry(daysAgo: 14, score: 9, band: .mild),
            entry(daysAgo: 7, score: 12, band: .moderate)
        ]
        let sorted = history.sorted { $0.completedAt < $1.completedAt }
        XCTAssertEqual(PsychReminderPolicy.consecutiveRiseCount(in: sorted), 3)
    }

    /// 下降趋势不触发。
    func testDecliningTrendDoesNotNotify() {
        let history = [
            entry(daysAgo: 21, score: 15, band: .moderatelySevere),
            entry(daysAgo: 14, score: 10, band: .moderate),
            entry(daysAgo: 7, score: 6, band: .mild)
        ]
        let decision = decide(history)
        XCTAssertNotEqual(decision.kind, .risingTrend)
    }

    // MARK: - 到期提醒

    /// 距上次评估超过建议间隔 → 提示该做量表了。
    func testAssessmentDueWhenIntervalElapsed() {
        let history = [
            entry(daysAgo: 20, score: 6, band: .mild),
            entry(daysAgo: 14, score: 5, band: .mild)
        ]
        let decision = decide(history)
        XCTAssertEqual(decision.kind, .assessmentDue)
    }

    /// 刚做完量表 → 不提醒。
    func testNoAssessmentReminderWhenJustCompleted() {
        let history = [
            entry(daysAgo: 4, score: 6, band: .mild),
            entry(daysAgo: 1, score: 5, band: .mild)
        ]
        let decision = decide(history)
        XCTAssertFalse(decision.shouldNotify)
    }

    /// 只有一个样本时什么都不提醒——没有对比基准。
    func testSingleSampleNeverNotifies() {
        let decision = decide([entry(daysAgo: 3, score: 12, band: .moderate)])
        XCTAssertFalse(decision.shouldNotify)
    }

    // MARK: - 冷却窗口（核心风险 3）

    /// 核心风险 3：冷却期内不重复提醒。
    func testCooldownWindowSuppressesRepeatNotification() {
        let history = [
            entry(daysAgo: 21, score: 5, band: .mild),
            entry(daysAgo: 14, score: 9, band: .mild),
            entry(daysAgo: 7, score: 13, band: .moderate)
        ]
        // 上次提醒是 3 天前，冷却期 14 天 → 应被压制。
        let lastNotified = calendar.date(byAdding: .day, value: -3, to: baseDate)
        let decision = decide(history, lastNotifiedAt: lastNotified)
        XCTAssertFalse(decision.shouldNotify, "冷却期内不得重复提醒同一件事")
    }

    /// 冷却期结束后重新允许提醒。
    func testNotificationAllowedAfterCooldownExpires() {
        let history = [
            entry(daysAgo: 21, score: 5, band: .mild),
            entry(daysAgo: 14, score: 9, band: .mild),
            entry(daysAgo: 7, score: 13, band: .moderate)
        ]
        let lastNotified = calendar.date(byAdding: .day, value: -20, to: baseDate)
        let decision = decide(history, lastNotifiedAt: lastNotified)
        XCTAssertEqual(decision.kind, .risingTrend)
    }

    /// 冷却按**日历天**算：昨天同一时刻提醒过，今天同一时刻仍处于冷却期。
    func testCooldownUsesCalendarDaysNotAbsoluteSeconds() {
        let history = [
            entry(daysAgo: 21, score: 5, band: .mild),
            entry(daysAgo: 14, score: 9, band: .mild),
            entry(daysAgo: 7, score: 13, band: .moderate)
        ]
        // 昨天同一时刻（间隔仅 24 小时，但跨了日历天 → 1 天 < 14 天冷却）
        let lastNotified = calendar.date(byAdding: .day, value: -1, to: baseDate)
        let decision = decide(history, lastNotifiedAt: lastNotified)
        XCTAssertFalse(decision.shouldNotify)
    }

    // MARK: - 顺序无关（核心风险 5）

    /// 核心风险 5：决策不能依赖传入顺序。
    func testDecisionIsIndependentOfInputOrder() {
        let ascending = [
            entry(daysAgo: 21, score: 5, band: .mild),
            entry(daysAgo: 14, score: 9, band: .mild),
            entry(daysAgo: 7, score: 13, band: .moderate)
        ]
        let shuffled = [
            ascending[2],
            ascending[0],
            ascending[1]
        ]
        XCTAssertEqual(decide(ascending), decide(shuffled))
    }

    // MARK: - 上下文形参真的被使用（核心风险 4）

    /// 核心风险 4：传入不同的 `now` 必须得出不同结论——
    /// 这证明 `now` 真的参与了判定，而不是拿墙上时钟代替。
    func testNowParameterActuallyAffectsDecision() {
        let history = [
            entry(daysAgo: 20, score: 6, band: .mild),
            entry(daysAgo: 14, score: 5, band: .mild)
        ]
        // 以基准日判定：距上次 14 天 → 到期提醒。
        let atBase = decide(history, now: baseDate)
        XCTAssertEqual(atBase.kind, .assessmentDue)

        // 把 now 往前拨 10 天：距上次只有 4 天 → 不该提醒。
        let earlier = calendar.date(byAdding: .day, value: -10, to: baseDate) ?? baseDate
        let atEarlier = decide(history, now: earlier)
        XCTAssertFalse(atEarlier.shouldNotify, "now 必须真的参与判定")
    }
}
