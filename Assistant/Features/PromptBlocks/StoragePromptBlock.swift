import AssistantCore
import Foundation
import SwiftData

/// 物品收纳位置块，优先匹配问题关键词。
struct StoragePromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .storage

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let storedItems = (try? context.fetch(FetchDescriptor<StoredItem>())) ?? []
        let matchedStored = storedItems.filter { item in
            query.contains(item.name) || query.contains(item.roomArea) || item.name.contains(query)
        }
        let displayStored = matchedStored.isEmpty ? Array(storedItems.prefix(5)) : Array(matchedStored.prefix(6))
        let storageText: String = displayStored.isEmpty ? "未录入" : displayStored.map {
            "\($0.name) -> \($0.roomArea)·\($0.location)"
        }.joined(separator: "；")
        return PromptBlock(id: id, text: "• 物品收纳位置：\(storageText)")
    }
}
