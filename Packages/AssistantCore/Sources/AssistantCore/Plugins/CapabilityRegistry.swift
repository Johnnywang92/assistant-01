import Foundation

/// 内置能力注册表：能力 = 一个描述符文件 + 这里的一行。
///
/// 注册顺序即 `action` 备选顺序与提示词示例顺序，固定下来才能做文法快照。
public enum CapabilityRegistry {

    /// 16 个内置能力，顺序与旧 `ActionJSONGrammar` / `capabilitySchema` 一致。
    public static let builtIn: [CapabilityDescriptor] = [
        .expenseCreate,
        .expenseUpdate,
        .todoCreate,
        .todoUpdate,
        .todoComplete,
        .todoCancel,
        .reminderSnooze,
        .queryLookup,
        .memoInbox,
        .foodRecord,
        .waterRecord,
        .storageRecord,
        .habitLog,
        .anniversaryCreate,
        .departureAdd,
        .lifeRecord
    ]

    public static let builtInIDs: Set<String> = Set(builtIn.map(\.id))

    /// 撤销令牌类型 → 负责撤销它的模块。每个类型只能有一个归属，
    /// 描述符声明的 `undoKinds` 必须与其 `ownerModuleID` 一致。
    public static let undoHandlers: [ActionUndoToken.Kind: String] = [
        .todo: "todo",
        .expense: "expense",
        .memoLine: "memo",
        .foodRecord: "food",
        .waterRecord: "water",
        .storageRecord: "storage",
        .medicineRecord: "storage",
        .habitLog: "habit",
        .medicationLog: "habit",
        .anniversary: "anniversary",
        .subscription: "anniversary",
        .itemExpiry: "anniversary",
        .departureItem: "departure",
        .petRecord: "life",
        .vehicleRecord: "life",
        .childRecord: "life",
        .skillRecord: "life",
        .idDocument: "life",
        .lifeEvent: "life"
    ]

    /// 允许跨模块贡献的撤销类型。`memo.inbox` 识别到饮食内容时会顺带落一条 food 记录，
    /// 撤销由 food 模块负责；除此之外描述符的撤销归属必须等于自身模块。
    public static let crossModuleUndoKinds: [String: Set<ActionUndoToken.Kind>] = [
        "memo.inbox": [.foodRecord]
    ]

    public static func descriptor(id: String) -> CapabilityDescriptor? {
        builtIn.first { $0.id == id }
    }

    public static func descriptor(for capability: ActionCapability) -> CapabilityDescriptor? {
        descriptor(id: capability.rawValue)
    }

    /// 判别层标签 → 描述符。`intentToken` 与 `OmniboxIntentLabel.rawValue` 一一对应，
    /// 前者是声明、后者是运行时枚举；一致性由 `validate()` 双向检查。
    public static func descriptor(intentToken: String) -> CapabilityDescriptor? {
        builtIn.first { $0.intentToken == intentToken }
    }

    // MARK: - 文法

    private final class GrammarCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Set<String>: ComposedGrammar] = [:]

        func value(for key: Set<String>) -> ComposedGrammar? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func insert(_ grammar: ComposedGrammar, for key: Set<String>) {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = grammar
        }
    }

    private static let grammarCache = GrammarCache()

    /// 合成文法并按启用集合缓存。`nil` 表示全部启用。
    public static func grammar(enabledIDs: Set<String>? = nil) throws -> ComposedGrammar {
        let key = enabledIDs ?? builtInIDs
        if let cached = grammarCache.value(for: key) { return cached }

        let composed = try ActionGrammarComposer.compose(builtIn, enabledIDs: enabledIDs)
        grammarCache.insert(composed, for: key)
        return composed
    }

    /// 全量文法。合成失败属于契约错误，开发期直接断言，线上回退到旧文法保证可用。
    public static var grammarText: String {
        do {
            return try grammar(enabledIDs: nil).text
        } catch {
            assertionFailure("能力文法合成失败：\(error)")
            return ActionJSONGrammar.gbnf
        }
    }

    // MARK: - 契约自检

    /// 返回注册表自身的不一致项；空数组表示契约完整。测试与调试入口共用。
    public static func validate() -> [String] {
        var issues: [String] = []
        var seenIDs = Set<String>()
        for descriptor in builtIn {
            if !seenIDs.insert(descriptor.id).inserted {
                issues.append("能力重复注册：\(descriptor.id)")
            }
            guard descriptor.actionCapability != nil else {
                issues.append("描述符 id 不是合法 ActionCapability：\(descriptor.id)")
                continue
            }
            if descriptor.surfaces.contains(.model) && descriptor.grammar == nil {
                issues.append("\(descriptor.id) 可被模型产出但缺少文法片段")
            }
            for kind in descriptor.undoKinds {
                guard let owner = undoHandlers[kind] else {
                    issues.append("\(descriptor.id) 的撤销类型 \(kind.rawValue) 没有处理器")
                    continue
                }
                if owner != descriptor.ownerModuleID,
                   crossModuleUndoKinds[descriptor.id]?.contains(kind) != true {
                    issues.append("\(descriptor.id) 的撤销类型 \(kind.rawValue) 归属 \(owner)，与模块 \(descriptor.ownerModuleID) 不一致且未登记为跨模块贡献")
                }
            }
        }
        for capability in ActionCapability.allCases where descriptor(for: capability) == nil {
            issues.append("能力缺少描述符：\(capability.rawValue)")
        }
        issues += intentContractIssues(builtIn)
        do {
            _ = try grammar(enabledIDs: nil)
        } catch {
            issues.append("文法合成失败：\(error)")
        }
        return issues
    }

    /// 判别标签与 `OmniboxIntentLabel` 之间的双向一致检查。
    ///
    /// 单独成函数（而不是散在 `validate()` 里）是为了能跑负例：漏声明一个 token、
    /// 或声明一个枚举里没有的 token，后果都是判别空间静默少一类——模型照样输出，
    /// 只是那一类永远选不中，线上看不出来。这类破损必须能被构造出来验。
    static func intentContractIssues(_ descriptors: [CapabilityDescriptor]) -> [String] {
        var issues: [String] = []
        var seenTokens = Set<String>()
        for descriptor in descriptors {
            if descriptor.intentToken.isEmpty {
                issues.append("\(descriptor.id) 未声明判别标签")
            } else if !seenTokens.insert(descriptor.intentToken).inserted {
                issues.append("判别标签重复声明：\(descriptor.intentToken)（\(descriptor.id)）")
            }
            if descriptor.intentLegendName.isEmpty {
                issues.append("\(descriptor.id) 的判别标签 \(descriptor.intentToken) 没有图例释义")
            }
        }
        for token in seenTokens where OmniboxIntentLabel(rawValue: token) == nil {
            issues.append("判别标签 \(token) 在 OmniboxIntentLabel 里没有对应 case")
        }
        for label in OmniboxIntentLabel.allCases {
            guard let descriptor = descriptors.first(where: { $0.intentToken == label.rawValue }) else {
                issues.append("判别标签 \(label.rawValue) 没有描述符声明")
                continue
            }
            if descriptor.actionCapability != label.capability {
                issues.append("判别标签 \(label.rawValue) 的枚举指向 \(label.capability.rawValue)，描述符却声明为 \(descriptor.id)")
            }
        }
        return issues
    }
}
