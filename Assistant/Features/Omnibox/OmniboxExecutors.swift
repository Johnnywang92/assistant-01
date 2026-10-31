import AssistantCore
import Foundation
import SwiftData

// MARK: - 执行器派发：模块只认识 Capability，不认识输入形态

/// 派发器本身不认识任何业务。新增模块 = 一个 `CapabilityProvider` 文件 + 注册表一行，
/// 这里零改动；`ActionCapability` 与 `ActionUndoToken.Kind` 的归属由 Core 的 `CapabilityRegistry` 校验。
@MainActor
enum OmniboxExecutor {

    /// 按拓扑序执行一批已勾选动作，返回逐条回执
    static func executeTopologically(
        _ actions: [PlannedAction],
        context: ModelContext
    ) -> [ActionExecutionOutcome] {
        var outcomes: [ActionExecutionOutcome] = []
        var priorResults: [UUID: String] = [:]
        var done = Set<UUID>()

        var pending = actions
        while !pending.isEmpty {
            var progressed = false
            pending = pending.filter { action in
                let depsSatisfied = action.dependsOn.allSatisfy { done.contains($0) }
                if depsSatisfied {
                    defer {
                        done.insert(action.id)
                        progressed = true
                    }
                    let outcome = execute(action, prior: priorResults, context: context)
                    if let summary = outcome.summary { priorResults[action.id] = summary }
                    outcomes.append(outcome)
                    return false
                }
                return true
            }
            if !progressed {
                // 依赖环兜底：剩余动作直接顺序执行
                for action in pending {
                    let outcome = execute(action, prior: priorResults, context: context)
                    if let summary = outcome.summary { priorResults[action.id] = summary }
                    outcomes.append(outcome)
                }
                break
            }
        }
        return outcomes
    }

    /// 执行单个动作
    static func execute(
        _ action: PlannedAction,
        prior: [UUID: String],
        context: ModelContext
    ) -> ActionExecutionOutcome {
        guard let provider = OmniboxProviderRegistry.provider(for: action.capability) else {
            return ActionExecutionOutcome(
                id: action.id, action: action, summary: "",
                undo: OmniboxUndoToken(kind: .memoLine),
                errorText: OmniboxError.unregisteredCapability(action.capability.rawValue).localizedDescription
            )
        }
        do {
            return try provider.execute(action, prior: prior, context: context)
        } catch {
            return ActionExecutionOutcome(
                id: action.id, action: action, summary: "",
                undo: OmniboxUndoToken(kind: .memoLine),
                errorText: error.localizedDescription
            )
        }
    }

    // MARK: - 撤销（回执即事务：每个执行器必须支持 undo）

    /// 按执行逆序撤销一批回执
    static func undo(_ outcomes: [ActionExecutionOutcome], context: ModelContext) throws {
        try undoTokens(outcomes.filter(\.succeeded).map(\.undo), context: context)
    }

    /// 直接撤销令牌列表（历史页跨启动撤销用，令牌来自 OmniboxTransaction.undoJSON）
    static func undoTokens(_ tokens: [OmniboxUndoToken], context: ModelContext) throws {
        for token in tokens.reversed() {
            try undoToken(token, context: context)
        }
    }

    static func undoToken(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard let provider = OmniboxProviderRegistry.provider(for: token.kind) else {
            throw OmniboxError.unregisteredUndoKind(token.kind.rawValue)
        }
        try provider.undo(token, context: context)
    }

    // MARK: - 供视图复用的模块内工具（保持旧调用点不变）

    static func resolveDueAt(params: [String: String]) -> Date? {
        TodoCapabilityProvider.resolveDueAt(params: params)
    }

    static var memoFileURL: URL {
        MemoCapabilityProvider.memoFileURL
    }
}

enum OmniboxError: LocalizedError {
    case invalidParams(String)
    /// 本地数据读不出来（不是参数问题）：如实告知，不做任何写入
    case dataUnavailable(String)
    /// 注册表缺项属于契约错误：开发期断言，线上如实回执
    case unregisteredCapability(String)
    case unregisteredUndoKind(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let reason):
            return L10n.tr("参数不完整：") + reason
        case .dataUnavailable(let reason):
            return reason
        case .unregisteredCapability(let id):
            return L10n.tr("动作未注册执行器：") + id
        case .unregisteredUndoKind(let kind):
            return L10n.tr("撤销类型未注册：") + kind
        }
    }
}
