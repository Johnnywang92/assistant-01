import Foundation

// MARK: - 睡前提醒的去重与注册决策（纯规则）

/// 每夜最多提醒一次的硬约束落点。
///
/// 反面场景（全部要有测试背书）：
/// 1. 同一夜反复进前台 → 精修层反复注册「now+2min」→ 用户收到多条；
/// 2. 兜底通知已送达后，精修又算出更早的 T_fire → 补发一条；
/// 3. `.immediate` 时发系统通知 → 前台默认不展示，白注册还可能与卡片重复；
/// 4. 通知权限被拒 → 还显示「已为你安排今晚提醒」→ 谎报。
public enum SleepReminderPolicy {

    public enum Action: Equatable, Sendable {
        /// 注册/覆盖一条定时通知（identifier 幂等，同 ID 覆盖不算重复）
        case schedule(fireAt: Date)
        /// 只在「今晚睡眠」卡上展示，不发系统通知
        case showCardOnly
        /// 什么都不做
        case none(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case alreadyReminded      // 本夜已提醒过（已送达 / 已记录）
        case planSkipped          // 计划本身就是 skipped
        case permissionDenied     // 通知权限被拒
        case cardOnly             // immediate 走卡片，不发通知
    }

    /// 注册决策。`alreadyReminded` 的判定来源（调用方聚合）：
    /// 本夜 identifier 已出现在 delivered 列表，或持久化的 lastRemindedNightKey == 本夜。
    public static func action(
        plan: SleepPlan,
        alreadyReminded: Bool,
        notificationAuthorized: Bool
    ) -> Action {
        // 权限被拒：宁可不承诺，也不注册一个发不出去的通知
        guard notificationAuthorized else { return .none(.permissionDenied) }
        // 本夜已提醒过 → 兜底已送达后精修更早也不补发
        if alreadyReminded { return .none(.alreadyReminded) }
        switch plan.outcome {
        case .skipped:
            return .none(.planSkipped)
        case .immediate:
            // 前台命中临场时段：直接卡片展示。发「now+2min」通知在前台默认静默，
            // 还会与卡片构成同一夜的两次提醒。
            return .showCardOnly
        case .scheduled:
            guard let fireAt = plan.fireAt else { return .none(.planSkipped) }
            return .schedule(fireAt: fireAt)
        }
    }
}
