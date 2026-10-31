import AssistantCore
import Foundation
import SwiftData

/// 生活档案提示词块的贡献契约。
///
/// 模块只负责自己那一段文本；输出顺序、预算裁剪与丢弃优先级由内核统一决定，
/// 模块之间不互相引用。
@MainActor
protocol PromptBlockProvider {
    var id: PromptBlockID { get }
    func makeBlock(context: ModelContext, query: String) -> PromptBlock
}

/// 生活档案块注册表。装配顺序来自 Core 的 `PromptBlockID.lifeProfileOrder`，
/// 新增模块 = 一个 Provider 文件 + 这里一行注册。
@MainActor
enum PromptBlockProviders {

    private static let byID: [PromptBlockID: any PromptBlockProvider] = {
        let providers: [any PromptBlockProvider] = [
            ParcelPromptBlock(),
            TodoPromptBlock(),
            FinancePromptBlock(),
            AnniversaryPromptBlock(),
            StoragePromptBlock(),
            HabitPromptBlock(),
            VaultPromptBlock(),
            FamilyPromptBlock(),
            MemoPromptBlock(),
            PlacePromptBlock()
        ]
        var map: [PromptBlockID: any PromptBlockProvider] = [:]
        for provider in providers {
            assert(map[provider.id] == nil, "提示词块重复注册：\(provider.id.rawValue)")
            map[provider.id] = provider
        }
        return map
    }()

    static func lifeProfileBlocks(context: ModelContext, query: String) -> [PromptBlock] {
        #if DEBUG
        assert(
            Set(byID.keys) == Set(PromptBlockID.lifeProfileOrder),
            "提示词块注册表与 Core 顺序契约不一致"
        )
        #endif
        return PromptBlockID.lifeProfileOrder.compactMap { id in
            guard let provider = byID[id] else {
                assertionFailure("缺少提示词块提供者：\(id.rawValue)")
                return nil
            }
            return provider.makeBlock(context: context, query: query)
        }
    }
}
