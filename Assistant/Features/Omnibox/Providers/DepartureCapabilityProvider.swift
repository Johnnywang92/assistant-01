import AssistantCore
import Foundation
import SwiftData

struct DepartureCapabilityProvider: CapabilityProvider {
    let moduleID = "departure"
    let capabilities: [ActionCapability] = [.departureAdd]
    let undoKinds: [ActionUndoToken.Kind] = [.departureItem]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .departureAdd else {
            throw OmniboxError.invalidParams("departure 模块不认识该动作")
        }
        return try executeDepartureAdd(action, context: context)
    }

    // MARK: departure.add

    private func executeDepartureAdd(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let title = action.params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw OmniboxError.invalidParams("随身物品不能为空") }
        let sceneName = action.params["scene"] ?? "工作通勤"
        let scene: DepartureScene = switch sceneName {
        case "运动健身": .workout
        case "出差旅行": .travel
        case "带娃出行": .parenting
        case "遛狗随行": .petWalk
        case "雨雪出行": .rainy
        default: .commute
        }
        let loc = action.params["location"]
        let item = DepartureCheckItem(title: title, scene: scene, isEssential: true, storageLocationNote: loc)
        context.insert(item)
        try context.save()
        return ActionExecutionOutcome(
            id: action.id, action: action,
            summary: OmniboxPlanner.summary(for: .departureAdd, params: action.params),
            undo: OmniboxUndoToken(kind: .departureItem, recordID: item.id)
        )
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard case .departureItem = token.kind else { return }
        if let id = token.recordID {
            let descriptor = FetchDescriptor<DepartureCheckItem>(predicate: #Predicate { $0.id == id })
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
            }
        }
        try context.save()
    }
}
