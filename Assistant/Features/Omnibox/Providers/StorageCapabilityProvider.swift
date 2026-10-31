import AssistantCore
import Foundation
import SwiftData

struct StorageCapabilityProvider: CapabilityProvider {
    let moduleID = "storage"
    let capabilities: [ActionCapability] = [.storageRecord]
    let undoKinds: [ActionUndoToken.Kind] = [.storageRecord, .medicineRecord]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .storageRecord else {
            throw OmniboxError.invalidParams("storage 模块不认识该动作")
        }
        return try executeStorageRecord(action, context: context)
    }

    // MARK: storage.record

    private func executeStorageRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let name = action.params["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            throw OmniboxError.invalidParams("物品名称不能为空")
        }
        let location = action.params["location"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "默认位置"
        let roomArea = action.params["roomArea"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "主卧"
        let isMedicine = action.params["isMedicine"] == "true"

        if isMedicine {
            let medItem = MedicineItem(
                name: name,
                storageLocation: location,
                roomArea: roomArea
            )
            context.insert(medItem)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .storageRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .medicineRecord, recordID: medItem.id)
            )
        } else {
            let item = StoredItem(
                name: name,
                location: location,
                roomArea: roomArea
            )
            context.insert(item)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .storageRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .storageRecord, recordID: item.id)
            )
        }
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        switch token.kind {
        case .storageRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .medicineRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<MedicineItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        default:
            return
        }
        try context.save()
    }
}
