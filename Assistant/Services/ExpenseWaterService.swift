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
    public static func handleSaved(_ expense: ExpenseRecord, context: ModelContext) {
        let linked = linkedRecord(for: expense.id, context: context)

        // 仅餐饮美食支出允许联动饮水记录
        guard isEligible(expense) else {
            if let linked {
                context.delete(linked)
                try? context.save()
            }
            return
        }

        // 尝试匹配饮品
        guard let suggestion = ExpenseWaterMatcher.match(title: expense.title) else {
            // 若用户将标题改成了非饮品（如「拉面」），则移除先前的饮水记录
            if let linked {
                context.delete(linked)
                try? context.save()
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
            try? context.save()
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
            try? context.save()

            // 尝试同步到 Apple 健康（HealthKit）
            Task {
                let success = await HealthKitService.shared.recordWaterIntake(
                    amountML: newRecord.effectiveHydrationML,
                    date: newRecord.date
                )
                if success {
                    await MainActor.run {
                        newRecord.syncedToHealthKit = true
                        try? context.save()
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
            try? context.save()
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
