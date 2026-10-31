import AssistantCore
import Foundation
import SwiftData

/// 待取快递块。数据源是待办模块的 parcel 子类型。
struct ParcelPromptBlock: PromptBlockProvider {
    let id: PromptBlockID = .parcel

    func makeBlock(context: ModelContext, query: String) -> PromptBlock {
        let active = TodoStatus.active.rawValue
        let parcelType = TodoType.parcel.rawValue
        let parcels = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == parcelType && $0.statusRaw == active }
        ))) ?? []
        let parcelText: String = parcels.isEmpty ? "暂无待取包裹" : parcels.prefix(6).map {
            let code = $0.pickupCode ?? "无取件码"
            let loc = $0.location ?? $0.station ?? "暂存点"
            return "\($0.courier ?? "快递")（码：\(code)，在 \(loc)）"
        }.joined(separator: "；")
        return PromptBlock(id: id, text: "• 待取快递：\(parcelText)")
    }
}
