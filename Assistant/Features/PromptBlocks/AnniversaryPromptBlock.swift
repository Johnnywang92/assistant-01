import AssistantCore
import Foundation
import SwiftData

/// 纪念日与倒数日块。
struct AnniversaryPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .anniversary

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let anniversaries = ((try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? [])
            .map { ($0, $0.daysUntilNext) }
            .sorted { $0.1 < $1.1 }
        let anniText: String = anniversaries.isEmpty ? "无" : anniversaries.prefix(3).map {
            "\($0.0.title)（还有 \($0.1) 天）"
        }.joined(separator: "、")
        return PromptBlock(id: id, text: "• 纪念日倒数：\(anniText)")
    }
}
