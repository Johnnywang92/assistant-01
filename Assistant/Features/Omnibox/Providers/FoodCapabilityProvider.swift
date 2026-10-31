import AssistantCore
import Foundation
import SwiftData

struct FoodCapabilityProvider: CapabilityProvider {
    let moduleID = "food"
    let capabilities: [ActionCapability] = [.foodRecord]
    let undoKinds: [ActionUndoToken.Kind] = [.foodRecord]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .foodRecord else {
            throw OmniboxError.invalidParams("food 模块不认识该动作")
        }
        return try executeFoodRecord(action, context: context)
    }

    // MARK: food.record

    private func executeFoodRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let foodName = action.params["foodName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !foodName.isEmpty else {
            throw OmniboxError.invalidParams("食物名称不能为空")
        }

        let date = OmniboxPlanner.parseParamDate(action.params["dateISO"]) ?? .now
        let parsedCalories = Double(action.params["calories"] ?? "")

        // 优先尝试从 foodName 或原句进行 FoodCalorieEstimator 细致估算
        let estimate = FoodCalorieEstimator.estimateMeal(fromHint: foodName)
            ?? (action.params["rawText"].flatMap { FoodCalorieEstimator.estimateMeal(fromHint: $0) })

        let finalCalories: Double = {
            if let parsedCalories = parsedCalories, parsedCalories > 0 {
                return parsedCalories
            }
            if let estimate = estimate {
                return estimate.fullPortionCalories
            }
            if let matched = FoodCatalog.item(matchingNameStrict: foodName) ?? FoodCatalog.items(matchingName: foodName).first {
                return Double(matched.standardServingCalories)
            }
            return 250.0 // 默认保底热量
        }()

        let foodID: String? = action.params["foodID"] ?? estimate?.food.id ?? (FoodCatalog.item(matchingNameStrict: foodName)?.id)

        let imageData: Data? = {
            if let base64 = action.params["imageDataBase64"],
               let data = Data(base64Encoded: base64) {
                return data
            }
            return nil
        }()

        let record = FoodIntakeRecord(
            date: date,
            foodName: foodName,
            foodID: foodID,
            portion: estimate?.portion ?? .regular,
            fullPortionCalories: finalCalories,
            consumedRatio: 1.0,
            confidence: parsedCalories != nil ? 0.9 : (estimate != nil ? 0.85 : 0.5),
            isManuallyAdjusted: false,
            source: imageData != nil ? .vision : .manual,
            imageData: imageData,
            linkedExpenseID: nil
        )

        context.insert(record)
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .foodRecord, params: action.params),
            undo: OmniboxUndoToken(kind: .foodRecord, recordID: record.id)
        )
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard case .foodRecord = token.kind else { return }
        if let foodID = token.recordID {
            let descriptor = FetchDescriptor<FoodIntakeRecord>(predicate: #Predicate { $0.id == foodID })
            if let food = try? context.fetch(descriptor).first {
                context.delete(food)
            }
        }
        try context.save()
    }
}
