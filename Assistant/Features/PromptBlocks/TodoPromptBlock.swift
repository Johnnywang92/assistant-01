import AssistantCore
import Foundation
import SwiftData

/// 日常待办与日程块。
struct TodoPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .todo

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let active = TodoStatus.active.rawValue
        let parcelType = TodoType.parcel.rawValue
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw != parcelType && $0.statusRaw == active }
        ))) ?? []
        let todoText: String = todos.isEmpty ? "暂无未完成待办" : todos.prefix(6).map { item in
            var parts = [item.title]
            if let due = item.dueAt {
                parts.append(due.formatted(date: .abbreviated, time: .shortened))
            }
            if let loc = item.location, !loc.isEmpty {
                parts.append("@\(loc)")
            }
            return parts.joined(separator: " ")
        }.joined(separator: "；")
        return PromptBlock(id: id, text: "• 日常待办与日程：\(todoText)")
    }
}
