import AssistantCore
import Foundation
import SwiftData

/// 记账预算超支提醒。
///
/// 之前预算只写在页面上（一句「已超支」）：用户不打开记账页就永远不知道超了。
/// 这里把超支变成**主动提醒**：已用 80% 提醒一次、超支提醒一次、严重超支再提醒一次；
/// 同一档位每月只发一次，跨月自动重置。
///
/// 判定逻辑（档位、去重、跨月重置）在 Core 的 `BudgetAlertEngine`，
/// 有单测覆盖——这里的职责只有「取数、发通知、存状态」。
@MainActor
public final class BudgetAlertService: ObservableObject {
    public static let shared = BudgetAlertService()
    private init() {}

    private static let stateKey = "expense_budget_alert_state_v1"

    /// 最近一次判定结果（供 UI 展示提醒状态）
    @Published public private(set) var lastDecision: BudgetAlertDecision?

    /// 读取提醒状态
    private func loadState() -> BudgetAlertState {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.stateKey) else { return .empty }
        let year = raw["year"] as? Int ?? 0
        let month = raw["month"] as? Int ?? 0
        let levels = Set((raw["levels"] as? [Int]) ?? [])
        return BudgetAlertState(year: year, month: month, notifiedLevels: levels)
    }

    private func save(_ state: BudgetAlertState) {
        UserDefaults.standard.set([
            "year": state.year,
            "month": state.month,
            "levels": Array(state.notifiedLevels)
        ], forKey: Self.stateKey)
    }

    /// 评估并在需要时发出提醒（基于 ModelContext，供后台巡检及快捷记账调用）。
    @discardableResult
    public func evaluateAndNotify(context: ModelContext, now: Date = .now) -> BudgetAlertDecision {
        let descriptor = FetchDescriptor<ExpenseRecord>()
        let records = (try? context.fetch(descriptor)) ?? []
        return evaluateAndNotify(records: records, now: now)
    }

    /// 评估并在需要时发出提醒。
    ///
    /// 口径与「今日安心花」一致：比的是**弹性**支出，固定支出已从预算池扣除，
    /// 否则固定支出入账时就会误报超支。
    @discardableResult
    public func evaluateAndNotify(records: [ExpenseRecord], now: Date = .now) -> BudgetAlertDecision {
        let budget = BudgetSettings.monthlyBudget
        guard budget > 0 else {
            let decision = BudgetAlertDecision(
                level: .none, shouldNotify: false, spentRatio: 0, remaining: 0, overspent: 0
            )
            lastDecision = decision
            return decision
        }

        let input = SafeToSpendCalculator.inputFromRecords(
            records: records,
            fixedMonthlyTotal: RecurringExpenseManager.shared.monthlyEstimatedTotal,
            now: now
        )
        let state = loadState()
        let decision = BudgetAlertEngine.decide(
            monthlyBudget: budget,
            spentThisMonth: input.flexibleSpentThisMonth,
            state: state,
            now: now
        )
        lastDecision = decision
        guard decision.shouldNotify else { return decision }

        // 先落状态再发通知：反过来的话，一旦投递失败就会留下「已提醒」的假状态，
        // 用户再也收不到这条提醒
        save(BudgetAlertEngine.markingNotified(state, level: decision.level, now: now))
        postNotification(decision)
        return decision
    }

    private func postNotification(_ decision: BudgetAlertDecision) {
        let percent = Int((decision.spentRatio * 100).rounded())
        let remaining = Int(decision.remaining.rounded())
        let overspent = Int(decision.overspent.rounded())

        let title: String
        let body: String
        switch decision.level {
        case .none:
            return
        case .approaching:
            title = L10n.choose(
                "本月预算已用 \(percent)%",
                "Monthly budget \(percent)% used"
            )
            body = L10n.choose(
                "弹性支出已到预算的 \(percent)%，剩余可花约 ¥\(remaining)。",
                "Flexible spending reached \(percent)% of budget. About ¥\(remaining) left."
            )
        case .exceeded:
            title = L10n.choose("本月已超预算", "Monthly budget exceeded")
            body = L10n.choose(
                "已超出月预算 ¥\(overspent)，本月剩下几天留意一下。",
                "Over budget by ¥\(overspent). Mind spending for the rest of the month."
            )
        case .severe:
            title = L10n.choose("本月严重超预算", "Monthly budget severely exceeded")
            body = L10n.choose(
                "已超出月预算 ¥\(overspent)（用掉 \(percent)%），建议尽快调整。",
                "Over budget by ¥\(overspent) (\(percent)% of budget used). Consider adjusting now."
            )
        }

        NotificationService.post(
            title: title,
            body: body,
            id: "budget_alert_\(decision.level.rawValue)"
        )
    }
}
