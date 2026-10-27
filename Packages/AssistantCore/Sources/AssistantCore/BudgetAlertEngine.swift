import Foundation

/// 预算告警档位。数值越大越严重。
public enum BudgetAlertLevel: Int, Comparable, Sendable, CaseIterable {
    /// 未达提醒线
    case none = 0
    /// 已用 ≥ 80%：还来得及收手
    case approaching = 1
    /// 已用 ≥ 100%：本月已超支
    case exceeded = 2
    /// 已用 ≥ 120%：超支幅度明显
    case severe = 3

    public static func < (lhs: BudgetAlertLevel, rhs: BudgetAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 预算告警决策
public struct BudgetAlertDecision: Equatable, Sendable {
    /// 当前档位
    public let level: BudgetAlertLevel
    /// 是否需要发出提醒（同一档位每月只提醒一次）
    public let shouldNotify: Bool
    /// 已用占预算比例（未设预算时为 0）
    public let spentRatio: Double
    /// 剩余可花金额（负数代表已超支）
    public let remaining: Double
    /// 超支金额（≥ 0）
    public let overspent: Double

    public init(level: BudgetAlertLevel, shouldNotify: Bool, spentRatio: Double, remaining: Double, overspent: Double) {
        self.level = level
        self.shouldNotify = shouldNotify
        self.spentRatio = spentRatio
        self.remaining = remaining
        self.overspent = overspent
    }
}

/// 提醒状态：按「年月 + 已提醒档位」记录。
///
/// 为什么要带年月：预算用量天然随月份归零，但**提醒记录不会**——
/// 如果不按月清空，用户三月超支过一次，四月再超支就不会再收到提醒，
/// 「跨月自动重置」这条验收就废了。
public struct BudgetAlertState: Equatable, Sendable {
    public var year: Int
    public var month: Int
    /// 已提醒过的档位（存 `BudgetAlertLevel.rawValue`）
    public var notifiedLevels: Set<Int>

    public init(year: Int, month: Int, notifiedLevels: Set<Int> = []) {
        self.year = year
        self.month = month
        self.notifiedLevels = notifiedLevels
    }

    /// 空状态（尚未提醒过任何档位）
    public static let empty = BudgetAlertState(year: 0, month: 0, notifiedLevels: [])
}

/// 预算告警判定（纯函数）。
///
/// 与「安心花」共用同一套预算口径：月预算是**弹性**预算，
/// 固定支出（房租/订阅）已由预算池扣除，所以这里比的是弹性支出，
/// 否则提醒会在固定支出入账时误报超支。
public enum BudgetAlertEngine {
    /// 提醒线：已用 80%
    public static let approachingRatio: Double = 0.8
    /// 超支线：已用 100%
    public static let exceededRatio: Double = 1.0
    /// 严重超支线：已用 120%
    public static let severeRatio: Double = 1.2

    /// 当前档位判定
    public static func level(monthlyBudget: Double, spentThisMonth: Double) -> BudgetAlertLevel {
        guard monthlyBudget > 0 else { return .none }
        let ratio = spentThisMonth / monthlyBudget
        if ratio >= severeRatio { return .severe }
        if ratio >= exceededRatio { return .exceeded }
        if ratio >= approachingRatio { return .approaching }
        return .none
    }

    /// 判定是否需要提醒
    public static func decide(
        monthlyBudget: Double,
        spentThisMonth: Double,
        state: BudgetAlertState,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> BudgetAlertDecision {
        let ratio = monthlyBudget > 0 ? spentThisMonth / monthlyBudget : 0
        let level = level(monthlyBudget: monthlyBudget, spentThisMonth: spentThisMonth)
        let remaining = monthlyBudget > 0 ? monthlyBudget - spentThisMonth : 0
        let rolled = rolledOver(state, now: now, calendar: calendar)
        let shouldNotify = level != .none && !rolled.notifiedLevels.contains(level.rawValue)
        return BudgetAlertDecision(
            level: level,
            shouldNotify: shouldNotify,
            spentRatio: ratio,
            remaining: remaining,
            overspent: max(0, -remaining)
        )
    }

    /// 记录某档位已提醒
    public static func markingNotified(
        _ state: BudgetAlertState,
        level: BudgetAlertLevel,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> BudgetAlertState {
        var rolled = rolledOver(state, now: now, calendar: calendar)
        rolled.notifiedLevels.insert(level.rawValue)
        return rolled
    }

    /// 跨月自动重置：年月一变，已提醒记录清空
    public static func rolledOver(
        _ state: BudgetAlertState,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> BudgetAlertState {
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        guard state.year != year || state.month != month else { return state }
        return BudgetAlertState(year: year, month: month, notifiedLevels: [])
    }
}
