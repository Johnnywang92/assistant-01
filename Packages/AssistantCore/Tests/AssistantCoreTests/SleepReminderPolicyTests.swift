import XCTest
@testable import AssistantCore

/// 睡前提醒去重决策的回归测试。
/// 核心风险：去重失效是「轰炸式」体验事故——同一夜切几次 App 就收几条推送；
/// 去重过头则静默漏提醒。两种方向都必须有断言钉住。
final class SleepReminderPolicyTests: XCTestCase {

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2026-10-28 00:00:00 UTC
    private let day = Date(timeIntervalSince1970: 1_793_145_600)

    /// 造一个 outcome=scheduled、T_fire 在未来的计划
    private func scheduledPlan(nowOffsetMinutes: Int = 20 * 60) -> SleepPlan {
        // 7 夜习惯 00:15(735) → T_bed 00:15、T_fire 23:45(705)
        let samples = [1, 2, 3, 6, 7, 8, 9].map { i -> SleepNightSample in
            let key = utcCalendar.date(byAdding: .day, value: -i, to: day)!
            return SleepNightSample(nightKey: key, onsetOffset: 735, asleepMinutes: 420)
        }
        let now = utcCalendar.date(byAdding: .minute, value: nowOffsetMinutes, to: day)!
        return SleepReminderPlanner.plan(.init(
            now: now,
            calendar: utcCalendar,
            nightKey: day,
            samples: samples,
            desiredBedtimeOffset: nil
        ))
    }

    // MARK: - 每夜最多一次（审查 B）

    func testFirstForegroundSchedulesOnceThenSubsequentOpensAreNoOps() {
        let plan = scheduledPlan()
        XCTAssertEqual(plan.outcome, .scheduled)

        // 第 1 次进前台：注册通知
        let first = SleepReminderPolicy.action(plan: plan, alreadyReminded: false, notificationAuthorized: true)
        guard case .schedule = first else {
            return XCTFail("首次应注册通知，实得 \(first)")
        }
        // 第 2、3 次进前台（已提醒过）：不再注册，也不会补发
        for _ in 0..<2 {
            let again = SleepReminderPolicy.action(plan: plan, alreadyReminded: true, notificationAuthorized: true)
            XCTAssertEqual(again, .none(.alreadyReminded))
        }
    }

    func testFallbackDeliveredThenRefineEarlierDoesNotResend() {
        // 兜底层已把 23:45 的通知送达（alreadyReminded=true）；
        // 精修层又算出更早的 T_fire——不允许补发第二条
        let plan = scheduledPlan()
        let action = SleepReminderPolicy.action(plan: plan, alreadyReminded: true, notificationAuthorized: true)
        XCTAssertEqual(action, .none(.alreadyReminded))
    }

    // MARK: - immediate 走卡片不发通知（审查 B）

    func testImmediateShowsCardOnlyNeverNotification() {
        // T_bed 00:15(735)、T_fire 23:45(705)；now=23:50 → immediate
        let plan = scheduledPlan(nowOffsetMinutes: 23 * 60 + 50)
        XCTAssertEqual(plan.outcome, .immediate)
        let action = SleepReminderPolicy.action(plan: plan, alreadyReminded: false, notificationAuthorized: true)
        XCTAssertEqual(action, .showCardOnly)
    }

    // MARK: - skipped 与权限（审查 A/B、次要问题）

    func testSkippedPlanProducesNothing() {
        // now=23:55 过了就寝点 23:45？不——T_bed 00:15，用 00:20 越过
        let plan = scheduledPlan(nowOffsetMinutes: 24 * 60 + 20)
        XCTAssertEqual(plan.outcome, .skipped)
        let action = SleepReminderPolicy.action(plan: plan, alreadyReminded: false, notificationAuthorized: true)
        XCTAssertEqual(action, .none(.planSkipped))
    }

    func testPermissionDeniedDegradesHonestly() {
        let plan = scheduledPlan()
        let action = SleepReminderPolicy.action(plan: plan, alreadyReminded: false, notificationAuthorized: false)
        XCTAssertEqual(action, .none(.permissionDenied))
        // 降级文案不得显示「已为你安排今晚提醒」
        let text = SleepPlanCopy.notificationDeniedText()
        XCTAssertTrue(text.contains("系统设置"))
        XCTAssertFalse(text.contains("已为你安排"))
    }

    func testPermissionDeniedAlsoBlocksImmediateCardClaim() {
        // 权限被拒时连 immediate 也不得走「已提醒」路径——宁可不承诺
        let plan = scheduledPlan(nowOffsetMinutes: 23 * 60 + 50)
        let action = SleepReminderPolicy.action(plan: plan, alreadyReminded: false, notificationAuthorized: false)
        XCTAssertEqual(action, .none(.permissionDenied))
    }
}
