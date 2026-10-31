import AssistantCore
import Foundation
import SwiftData

/// 常去地点块。
struct PlacePromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .place

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let places = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let placeText: String = places.isEmpty ? "未学习" : places.prefix(3).map { "\($0.category.rawValue)：\($0.name)" }.joined(separator: "、")
        return PromptBlock(id: id, text: "• 常去地点：\(placeText)")
    }
}
