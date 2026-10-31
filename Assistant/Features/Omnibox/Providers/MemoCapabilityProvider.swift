import AssistantCore
import Foundation
import SwiftData

struct MemoCapabilityProvider: CapabilityProvider {
    let moduleID = "memo"
    let capabilities: [ActionCapability] = [.memoInbox]
    let undoKinds: [ActionUndoToken.Kind] = [.memoLine]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .memoInbox else {
            throw OmniboxError.invalidParams("memo 模块不认识该动作")
        }
        return try executeMemo(action, context: context)
    }

    // MARK: memo.inbox

    private func executeMemo(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        guard let memo = action.params["memo"]?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty else {
            throw OmniboxError.invalidParams("备忘内容为空")
        }
        let line = "[\(Self.memoFormatter.string(from: .now))] \(memo.replacingOccurrences(of: "\n", with: " "))"
        let url = Self.memoFileURL

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = existing.isEmpty ? line + "\n" : existing.ensureTrailingNewline() + line + "\n"
        try updated.write(to: url, atomically: true, encoding: .utf8)

        // 若备忘包含饮食/食物摄入（如“早饭吃了一根玉米和一杯牛奶”），联动分析热量并入库
        var foodRecordID: UUID?
        var foodRecordSummary = ""
        if let estimate = FoodCalorieEstimator.estimateMeal(fromHint: memo) {
            let foodRecord = FoodIntakeRecord(
                date: .now,
                foodName: estimate.displayName,
                foodID: estimate.food.id,
                portion: estimate.portion,
                fullPortionCalories: estimate.fullPortionCalories,
                consumedRatio: 1.0,
                confidence: 0.85,
                isManuallyAdjusted: false,
                source: .manual
            )
            context.insert(foodRecord)
            try? context.save()
            foodRecordID = foodRecord.id
            foodRecordSummary = " · 已录入饮食：\(estimate.displayName)（约 \(Int(estimate.fullPortionCalories))千卡）"
        }

        let baseSummary = OmniboxPlanner.summary(for: .memoInbox, params: action.params)
        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: baseSummary + foodRecordSummary,
            undo: OmniboxUndoToken(kind: .memoLine, recordID: foodRecordID, memoLine: line)
        )
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard case .memoLine = token.kind else { return }
        if let line = token.memoLine {
            let url = Self.memoFileURL
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let filtered = existing
                .components(separatedBy: .newlines)
                .filter { $0 != line }
                .joined(separator: "\n")
            try? filtered.write(to: url, atomically: true, encoding: .utf8)
        }
        if let foodID = token.recordID {
            let descriptor = FetchDescriptor<FoodIntakeRecord>(predicate: #Predicate { $0.id == foodID })
            if let food = try? context.fetch(descriptor).first {
                context.delete(food)
            }
        }
        try context.save()
    }

    // MARK: - 收集箱文件（Documents/omnibox_memo.txt）

    static var memoFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("omnibox_memo.txt")
    }

    private static let memoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

private extension String {
    func ensureTrailingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }
}
