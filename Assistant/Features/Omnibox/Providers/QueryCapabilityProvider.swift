import AssistantCore
import Foundation
import SwiftData

struct QueryCapabilityProvider: CapabilityProvider {
    let moduleID = "query"
    let capabilities: [ActionCapability] = [.queryLookup]
    let undoKinds: [ActionUndoToken.Kind] = []

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .queryLookup else {
            throw OmniboxError.invalidParams("query 模块不认识该动作")
        }
        return executeLookup(action, context: context)
    }

    /// 查询执行入口：结构化查询意图（汇总/趋势/日程/查找）走 `LifeQueryService` 一句话回答，
    /// 取数全部谓词 + fetchLimit 下推 SQLite（原四表全扫已消除）。
    private func executeLookup(_ action: PlannedAction, context: ModelContext) -> ActionExecutionOutcome {
        let rawText = (action.params["query"] ?? action.params["target"] ?? "查询事项")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 结构化查询意图：「上周花了多少」「今天有什么安排」「最近消费趋势」「护照放哪了」
        if let insight = QueryInsightEngine.parse(rawText) {
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: LifeQueryService.answer(insight, context: context),
                undo: OmniboxUndoToken(kind: .memoLine)
            )
        }

        // 2. 纯关键词查找（「查找发票」这类无领域词检索）
        let keyword = QueryInsightEngine.extractLookupKeyword(rawText) ?? rawText
        let lookupInsight = QueryInsight(
            domain: .storage,
            kind: .lookup,
            timeRange: .allTime,
            keyword: keyword,
            rawText: rawText
        )
        return ActionExecutionOutcome(
            id: action.id, action: action,
            summary: LifeQueryService.lookup(insight: lookupInsight, context: context),
            undo: OmniboxUndoToken(kind: .memoLine)
        )
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {}
}
