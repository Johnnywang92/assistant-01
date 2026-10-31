import AssistantCore
import Foundation
import SwiftData

struct WaterCapabilityProvider: CapabilityProvider {
    let moduleID = "water"
    let capabilities: [ActionCapability] = [.waterRecord]
    let undoKinds: [ActionUndoToken.Kind] = [.waterRecord]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .waterRecord else {
            throw OmniboxError.invalidParams("water 模块不认识该动作")
        }
        return try executeWaterRecord(action, context: context)
    }

    // MARK: water.record

    private func executeWaterRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let volumeML = Double(action.params["volumeML"] ?? "") ?? 250.0
        let bevLabel = action.params["customName"] ?? action.params["beverageType"] ?? "白开水"
        let bevType = HydrationBeverageType.fromLabel(action.params["beverageType"] ?? bevLabel)
        let date = OmniboxPlanner.parseParamDate(action.params["dateISO"]) ?? .now

        let record = WaterIntakeRecord(
            date: date,
            beverageType: bevType,
            volumeML: volumeML,
            customName: bevLabel,
            note: "万能入口快速录入"
        )
        context.insert(record)
        try context.save()

        // 异步同步到 HealthKit
        Task {
            _ = await HealthKitService.shared.recordWaterIntake(
                amountML: record.effectiveHydrationML,
                date: record.date
            )
        }

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .waterRecord, params: action.params),
            undo: OmniboxUndoToken(kind: .waterRecord, recordID: record.id)
        )
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard case .waterRecord = token.kind else { return }
        if let id = token.recordID {
            let descriptor = FetchDescriptor<WaterIntakeRecord>(predicate: #Predicate { $0.id == id })
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
            }
        }
        try context.save()
    }
}
