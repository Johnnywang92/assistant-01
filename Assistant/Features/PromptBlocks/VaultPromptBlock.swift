import AssistantCore
import Foundation
import SwiftData

/// 订阅扣费与物品/证件保质期预警块。
struct VaultPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .vault

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let subs = (try? context.fetch(FetchDescriptor<SubscriptionItem>())) ?? []
        let expiries = ((try? context.fetch(FetchDescriptor<ItemExpiryItem>())) ?? []).filter { !$0.isResolved }
        let idDocs = (try? context.fetch(FetchDescriptor<IDDocumentItem>())) ?? []
        var alertParts: [String] = []
        if !subs.isEmpty {
            alertParts.append("订阅：" + subs.prefix(3).map { "\($0.name) \($0.priceString)" }.joined(separator: "、"))
        }
        if !expiries.isEmpty {
            alertParts.append("保质期：" + expiries.prefix(3).map { "\($0.title)（\($0.expireDate.formatted(date: .abbreviated, time: .omitted))到期）" }.joined(separator: "、"))
        }
        if !idDocs.isEmpty {
            alertParts.append("已存证件：" + idDocs.prefix(4).map { doc in
                if doc.isPermanent { return "\(doc.title)(长期)" }
                if let exp = doc.expiryDate { return "\(doc.title)(\(exp.formatted(date: .abbreviated, time: .omitted))到期)" }
                return doc.title
            }.joined(separator: "、"))
        }
        let vaultAlertText = alertParts.isEmpty ? "无" : alertParts.joined(separator: "；")
        return PromptBlock(id: id, text: "• 证件/订阅/保质期：\(vaultAlertText)")
    }
}
