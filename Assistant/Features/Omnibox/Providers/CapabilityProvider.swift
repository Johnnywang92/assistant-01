import AssistantCore
import Foundation
import SwiftData

/// 一个模块对「执行 + 撤销」的贡献。模块只实现自己的动作，
/// 派发与撤销路由由注册表按 Core 的能力契约校验。
@MainActor
protocol CapabilityProvider {
    /// 必须与 `CapabilityDescriptor.ownerModuleID` 一致
    var moduleID: String { get }
    var capabilities: [ActionCapability] { get }
    var undoKinds: [ActionUndoToken.Kind] { get }
    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome
    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws
}

/// 执行器注册表。新增模块 = 一个 Provider 文件 + 这里一行。
@MainActor
enum OmniboxProviderRegistry {

    static let all: [any CapabilityProvider] = [
        ExpenseCapabilityProvider(),
        TodoCapabilityProvider(),
        QueryCapabilityProvider(),
        MemoCapabilityProvider(),
        FoodCapabilityProvider(),
        WaterCapabilityProvider(),
        StorageCapabilityProvider(),
        HabitCapabilityProvider(),
        AnniversaryCapabilityProvider(),
        DepartureCapabilityProvider(),
        LifeCapabilityProvider()
    ]

    private static let capabilityMap: [ActionCapability: any CapabilityProvider] = {
        var map: [ActionCapability: any CapabilityProvider] = [:]
        for provider in all {
            for capability in provider.capabilities {
                map[capability] = provider
            }
        }
        return map
    }()

    private static let undoMap: [ActionUndoToken.Kind: any CapabilityProvider] = {
        var map: [ActionUndoToken.Kind: any CapabilityProvider] = [:]
        for provider in all {
            for kind in provider.undoKinds {
                map[kind] = provider
            }
        }
        return map
    }()

    static func provider(for capability: ActionCapability) -> (any CapabilityProvider)? {
        #if DEBUG
        assert(contractIssues.isEmpty, "执行器注册表与能力契约不一致：\(contractIssues)")
        #endif
        return capabilityMap[capability]
    }

    static func provider(for kind: ActionUndoToken.Kind) -> (any CapabilityProvider)? {
        #if DEBUG
        assert(contractIssues.isEmpty, "撤销注册表与能力契约不一致：\(contractIssues)")
        #endif
        return undoMap[kind]
    }

    #if DEBUG
    /// 注册表自检：每个能力恰好一个执行者、每个撤销类型恰好一个归属，
    /// 且与 Core 描述符的 ownerModuleID 一致。漏注册会在首次派发时断言。
    private static let contractIssues: [String] = {
        var issues: [String] = []
        var seenCapabilities: Set<ActionCapability> = []
        for provider in all {
            for capability in provider.capabilities {
                if !seenCapabilities.insert(capability).inserted {
                    issues.append("能力重复注册执行者：\(capability.rawValue)")
                }
                guard let descriptor = CapabilityRegistry.descriptor(for: capability) else {
                    issues.append("能力缺少描述符：\(capability.rawValue)")
                    continue
                }
                if descriptor.ownerModuleID != provider.moduleID {
                    issues.append("能力 \(capability.rawValue) 归属 \(descriptor.ownerModuleID)，执行器却在 \(provider.moduleID)")
                }
            }
        }
        for capability in ActionCapability.allCases where !seenCapabilities.contains(capability) {
            issues.append("能力缺少执行者：\(capability.rawValue)")
        }

        var seenKinds: Set<ActionUndoToken.Kind> = []
        for provider in all {
            for kind in provider.undoKinds {
                if !seenKinds.insert(kind).inserted {
                    issues.append("撤销类型重复注册：\(kind.rawValue)")
                }
                if CapabilityRegistry.undoHandlers[kind] != provider.moduleID {
                    issues.append("撤销类型 \(kind.rawValue) 应由 \(CapabilityRegistry.undoHandlers[kind] ?? "未登记") 处理，实际在 \(provider.moduleID)")
                }
            }
        }
        for kind in ActionUndoToken.Kind.allCases where !seenKinds.contains(kind) {
            issues.append("撤销类型缺少执行者：\(kind.rawValue)")
        }
        return issues
    }()
    #endif
}
