import AssistantCore
import Foundation
import SwiftData

/// 近期语音备忘块。
struct MemoPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .memo

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        var memoDescriptor = FetchDescriptor<VoiceMemo>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        memoDescriptor.fetchLimit = 2
        let memos = (try? context.fetch(memoDescriptor)) ?? []
        let memoText: String = memos.isEmpty ? "无" : memos.prefix(2).map { m in
            let snippet = (m.summary ?? m.transcription ?? "").prefix(30)
            return snippet.isEmpty ? m.title : "\(m.title)：\(snippet)"
        }.joined(separator: "；")
        return PromptBlock(id: id, text: "• 近期语音备忘：\(memoText)")
    }
}
