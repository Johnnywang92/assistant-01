import AssistantCore
import Foundation
import SwiftData

/// 一条等待用户确认的「记账 → 热量」建议。
struct PendingCalorieSuggestion: Identifiable {
    let id = UUID()
    let expenseID: UUID
    /// 账单标题（展示用）
    let title: String
    let date: Date
    let suggestion: ExpenseFoodMatcher.Suggestion
    /// 非 nil：账单被改过，这是对已有热量记录的更新（拒绝时会移除旧记录）。
    let existingRecordID: UUID?
}

/// 待确认建议的承载点。UI 层用 `.expenseCalorieConfirmation()` 挂载确认弹窗。
@MainActor
final class ExpenseCalorieCenter: ObservableObject {
    static let shared = ExpenseCalorieCenter()
    @Published var pending: PendingCalorieSuggestion?
    private init() {}
}

/// 记账 → 饮食热量：推测、确认后入库、随账单编辑/删除同步。
///
/// 约束：
/// - **先确认再入库**：任何估算都只生成 `PendingCalorieSuggestion`，用户点「记录」后才写入。
/// - 匹配顺序：内置食物库 → 本地 LLM 兜底（模型未就绪则不兜底）。
/// - 同步靠 `FoodIntakeRecord.linkedExpenseID`：账单删除/改成非餐饮/改成收入 → 联动删除；
///   账单日期变化 → 联动改日期；标题变化 → 重新估算并再次确认。
@MainActor
enum ExpenseCalorieService {

    // MARK: 入口：账单保存后

    /// 账单保存（新建或编辑）后调用。
    /// - Parameter propose: 是否需要（重新）估算并请用户确认——
    ///   新建、标题变了、或刚被改成餐饮类时为 true。
    static func handleSaved(_ expense: ExpenseRecord, propose: Bool, context: ModelContext) {
        let linked = linkedRecord(for: expense.id, context: context)

        guard isEligible(expense) else {
            if let linked {
                context.delete(linked)
                try? context.save()
            }
            return
        }

        if let linked, linked.date != expense.date, !propose {
            linked.date = expense.date
            try? context.save()
        }
        guard propose else { return }

        let expenseID = expense.id
        let title = expense.title
        let date = expense.date
        let existingID = linked?.id
        Task { @MainActor in
            // 等记账弹窗收起，避免两个 sheet 抢占
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let suggestion = await makeSuggestion(title: title) else {
                // 标题变了但估不出来：旧热量记录已与账单不符，移除
                if let existingID, let stale = record(id: existingID, context: context) {
                    context.delete(stale)
                    try? context.save()
                }
                return
            }
            ExpenseCalorieCenter.shared.pending = PendingCalorieSuggestion(
                expenseID: expenseID, title: title, date: date,
                suggestion: suggestion, existingRecordID: existingID
            )
        }
    }

    /// 账单删除前调用。
    static func handleDeleted(expenseID: UUID, context: ModelContext) {
        if let linked = linkedRecord(for: expenseID, context: context) {
            context.delete(linked)
            // 由调用方随账单一起 save
        }
        if ExpenseCalorieCenter.shared.pending?.expenseID == expenseID {
            ExpenseCalorieCenter.shared.pending = nil
        }
    }

    /// 兜底清理：账单被其它路径删除（语音、Omnibox 等）后遗留的热量记录。
    static func reconcileOrphans(context: ModelContext) {
        let descriptor = FetchDescriptor<FoodIntakeRecord>(
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
        if changed { try? context.save() }
    }

    // MARK: 确认 / 拒绝

    /// 用户确认。`calories` 为用户最终确认的整份热量（可能手动改过）。
    static func confirm(_ pending: PendingCalorieSuggestion, calories: Double, context: ModelContext) {
        let s = pending.suggestion
        let adjusted = abs(calories - s.fullPortionCalories) > 0.5

        if let id = pending.existingRecordID, let existing = record(id: id, context: context) {
            existing.foodName = s.name
            existing.foodID = s.foodID
            existing.portion = s.portion
            existing.fullPortionCalories = calories
            existing.consumedRatio = 1.0
            existing.consumedCalories = calories
            existing.confidence = s.confidence
            existing.isManuallyAdjusted = adjusted
            existing.date = pending.date
        } else {
            context.insert(FoodIntakeRecord(
                date: pending.date,
                foodName: s.name,
                foodID: s.foodID,
                portion: s.portion,
                fullPortionCalories: calories,
                consumedRatio: 1.0,
                confidence: s.confidence,
                isManuallyAdjusted: adjusted,
                source: .expense,
                linkedExpenseID: pending.expenseID
            ))
        }
        try? context.save()
        ExpenseCalorieCenter.shared.pending = nil
    }

    /// 用户拒绝。若是对已有记录的更新，旧记录与新账单不符，一并移除。
    static func decline(_ pending: PendingCalorieSuggestion, context: ModelContext) {
        if let id = pending.existingRecordID, let stale = record(id: id, context: context) {
            context.delete(stale)
            try? context.save()
        }
        ExpenseCalorieCenter.shared.pending = nil
    }

    // MARK: 估算

    /// 食物库优先，本地 LLM 兜底。
    static func makeSuggestion(title: String) async -> ExpenseFoodMatcher.Suggestion? {
        if let hit = ExpenseFoodMatcher.suggest(title: title) { return hit }
        return await suggestViaLLM(title: title)
    }

    private static func suggestViaLLM(title: String) async -> ExpenseFoodMatcher.Suggestion? {
        let llm = LLMInferenceService.shared
        let remoteReady = llm.remoteContextConsent && llm.validatedEndpointURL != nil
        guard LLMModelManager.shared.isModelDownloaded || remoteReady else { return nil }

        let system = """
        你是食物热量估算助手。用户给出一条消费记录的名称，请判断吃或喝的是什么，并估算一份的热量（千卡）。
        只输出 JSON：{"food":"食物名","calories":数字,"portion":"小份或标准份或大份"}。
        calories 是整份的热量。如果这条记录不是食物或饮品，输出 {"food":"","calories":0}。不要输出任何解释文字。
        """
        guard let output = await llm.generateCustomTask(
            systemInstruction: system,
            userContent: "消费记录：\(title)",
            maxNewTokens: 96
        ), let parsed = FoodLLMOutputParser.parse(output) else { return nil }

        return ExpenseFoodMatcher.suggestion(fromLLM: parsed)
    }

    // MARK: 内部

    /// 只处理「餐饮美食」支出，且标题不是未填写时的默认类别名。
    private static func isEligible(_ expense: ExpenseRecord) -> Bool {
        guard !expense.isIncome, expense.category == .food else { return false }
        let title = expense.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title != expense.category.rawValue
    }

    private static func linkedRecord(for expenseID: UUID, context: ModelContext) -> FoodIntakeRecord? {
        let target: UUID? = expenseID
        var descriptor = FetchDescriptor<FoodIntakeRecord>(
            predicate: #Predicate { $0.linkedExpenseID == target }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func record(id: UUID, context: ModelContext) -> FoodIntakeRecord? {
        var descriptor = FetchDescriptor<FoodIntakeRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
