import AssistantCore
import Foundation
import SwiftData

/// 记账 → 饮水记录自动联动服务
///
/// 场景：当用户在记账中记录咖啡、奶茶、茶饮、饮料等时，自动同步创建或更新对应的饮水记录（`WaterIntakeRecord`），
/// 折算生理有效补水量、咖啡因与热量，并支持自动同步 Apple 健康。
/// 账单修改或删除时，联动更新或删除对应的饮水记录。
@MainActor
public enum ExpenseWaterService {

    // MARK: - 记账保存后联动

    /// 账单保存（新建或编辑）后调用。
    ///
    /// 允许失败的派生路径（审计 SVC-04 明确豁免）：主账单已由调用方先落库，
    /// 这里只维护「记账 → 饮水」的派生联动记录，失败不阻断主流程；
    /// 但不能再 `try?` 静默吞错——统一走 `saveLinked` 回滚 + 日志。
    public static func handleSaved(_ expense: ExpenseRecord, context: ModelContext) {
        let linked = linkedRecord(for: expense.id, context: context)

        // 仅餐饮美食支出允许联动饮水记录
        guard isEligible(expense) else {
            if let linked {
                context.delete(linked)
                _ = saveLinked(context, action: "删除非餐饮的联动饮水记录")
            }
            return
        }

        // 尝试匹配饮品
        guard let suggestion = ExpenseWaterMatcher.match(title: expense.title) else {
            // 若用户将标题改成了非饮品（如「拉面」），则移除先前的饮水记录
            if let linked {
                context.delete(linked)
                _ = saveLinked(context, action: "删除不再匹配饮品的联动记录")
            }
            return
        }

        if let existing = linked {
            // 已存在联动记录：同步最新数据
            existing.date = expense.date
            existing.beverageTypeRaw = suggestion.beverageType.rawValue
            existing.volumeML = suggestion.volumeML
            existing.hydrationFactor = suggestion.hydrationFactor
            existing.effectiveHydrationML = suggestion.effectiveHydrationML
            existing.caffeineMG = suggestion.caffeineMG
            existing.calories = suggestion.calories
            existing.customName = suggestion.customName
            existing.note = "记账自动联动（\(expense.title)）"
            _ = saveLinked(context, action: "同步饮水记录")
        } else {
            // 不存在联动记录：新建并插入
            let newRecord = WaterIntakeRecord(
                date: expense.date,
                beverageType: suggestion.beverageType,
                volumeML: suggestion.volumeML,
                hydrationFactor: suggestion.hydrationFactor,
                customName: suggestion.customName,
                note: "记账自动联动（\(expense.title)）",
                syncedToHealthKit: false,
                linkedExpenseID: expense.id
            )
            context.insert(newRecord)
            guard saveLinked(context, action: "新建联动饮水记录") else {
                // 联动记录没落库就不要再去写 Apple 健康，否则健康数据里会出现一条
                // 账本/待办都找不到来源的孤立饮水记录。
                return
            }

            // 尝试同步到 Apple 健康（HealthKit）
            Task {
                let success = await HealthKitService.shared.recordWaterIntake(
                    amountML: newRecord.effectiveHydrationML,
                    date: newRecord.date
                )
                if success {
                    await MainActor.run {
                        newRecord.syncedToHealthKit = true
                        _ = saveLinked(context, action: "回写已同步 HealthKit 标记")
                    }
                }
            }
        }
    }

    // MARK: - 记账删除联动

    /// 账单删除前或删除时调用
    public static func handleDeleted(expenseID: UUID, context: ModelContext) {
        if let linked = linkedRecord(for: expenseID, context: context) {
            context.delete(linked)
        }
    }

    // MARK: - 孤儿记录兜底清理

    /// 兜底清理：清理那些关联账单已被删除的遗留饮水记录
    public static func reconcileOrphans(context: ModelContext) {
        let descriptor = FetchDescriptor<WaterIntakeRecord>(
            predicate: #Predicate { $0.linkedExpenseID != nil }
        )
        guard let linked = try? context.fetch(descriptor), !linked.isEmpty else { return }
        var changed = false
        for item in linked {
            guard let expenseID = item.linkedExpenseID else { continue }
            var probe = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.id == expenseID })
            probe.fetchLimit = 1
            if (try? context.fetch(probe))?.isEmpty ?? false {
                context.delete(item)
                changed = true
            }
        }
        if changed {
            _ = saveLinked(context, action: "清理孤儿饮水记录")
        }
    }

    /// 派生联动落库的统一出口：允许失败（主账单已落库），但不静默吞错。
    /// 失败时回滚并记一条日志；调用方可据此跳过后续派生动作（如 HealthKit 写入）。
    @discardableResult
    private static func saveLinked(_ context: ModelContext, action: String) -> Bool {
        context.saveReportingFailure { error in
            print("⚠️ [ExpenseWater] \(action)落库失败（派生联动允许失败，下次编辑账单会重建）: \(error.localizedDescription)")
        }
    }

    // MARK: - 内部辅助

    private static func isEligible(_ expense: ExpenseRecord) -> Bool {
        guard !expense.isIncome, expense.category == .food else { return false }
        let title = expense.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title != expense.category.rawValue
    }

    public static func linkedRecord(for expenseID: UUID, context: ModelContext) -> WaterIntakeRecord? {
        let target: UUID? = expenseID
        var descriptor = FetchDescriptor<WaterIntakeRecord>(
            predicate: #Predicate { $0.linkedExpenseID == target }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
