import AssistantCore
import Foundation
import SwiftData

struct AnniversaryCapabilityProvider: CapabilityProvider {
    let moduleID = "anniversary"
    let capabilities: [ActionCapability] = [.anniversaryCreate]
    let undoKinds: [ActionUndoToken.Kind] = [.anniversary, .subscription, .itemExpiry]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .anniversaryCreate else {
            throw OmniboxError.invalidParams("anniversary 模块不认识该动作")
        }
        return try executeAnniversaryCreate(action, context: context)
    }

    // MARK: anniversary.create

    private func executeAnniversaryCreate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let title = action.params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw OmniboxError.invalidParams("名称不能为空") }
        let category = action.params["category"] ?? "纪念日"
        let date = OmniboxPlanner.parseParamDate(action.params["targetDate"]) ?? .now

        if category == "订阅续费" {
            let price = action.params["price"] ?? "待确认"
            let sub = SubscriptionItem(name: title, priceString: price, nextBillingDate: date)
            context.insert(sub)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .anniversaryCreate, params: action.params),
                undo: OmniboxUndoToken(kind: .subscription, recordID: sub.id)
            )
        } else if category == "保质期" {
            let item = ItemExpiryItem(title: title, expireDate: date)
            context.insert(item)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .anniversaryCreate, params: action.params),
                undo: OmniboxUndoToken(kind: .itemExpiry, recordID: item.id)
            )
        } else {
            let anniv = AnniversaryItem(title: title, category: category, targetDate: date)
            context.insert(anniv)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .anniversaryCreate, params: action.params),
                undo: OmniboxUndoToken(kind: .anniversary, recordID: anniv.id)
            )
        }
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        switch token.kind {
        case .anniversary:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<AnniversaryItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .subscription:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<SubscriptionItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .itemExpiry:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<ItemExpiryItem>(predicate: #Predicate { $0.id == id })
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
