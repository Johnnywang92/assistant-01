import Foundation

/// 能力所在消费面。一个能力可以同时被模型产出、被规则抽到、出现在意图面板。
public enum CapabilitySurface: Hashable, Sendable {
    case model
    case rules
    case ui
}

/// 能力参数声明。
///
/// `origin` 是硬边界：只有 `.model` 参数会进入 GBNF 与提示词示例；
/// `.nonModel` 参数由 OCR、票务结构化、快捷指令等管线注入，写进文法会让模型开始幻觉字段。
public struct ParamSpec: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case number
        case integer
        case booleanString
        case date
        case time
        case dateTime
        case enumeration([String])
    }

    public enum Origin: Sendable {
        case model
        case nonModel
    }

    public let key: String
    public let kind: Kind
    public let origin: Origin
    public let isRequired: Bool
    public let defaultValue: String?
    /// 文法里的嵌套可选：例如 todo.create 的 dueAtTime 必须先出现 dueAtDays
    public let requires: [String]
    /// 执行器同时接受的键名
    public let aliases: [String]

    public init(
        _ key: String,
        _ kind: Kind,
        _ origin: Origin = .model,
        required: Bool = true,
        default defaultValue: String? = nil,
        requires: [String] = [],
        aliases: [String] = []
    ) {
        self.key = key
        self.kind = kind
        self.origin = origin
        self.isRequired = required
        self.defaultValue = defaultValue
        self.requires = requires
        self.aliases = aliases
    }
}

/// GBNF 终结符定义。名字只允许小写字母、数字与连字符（llama.cpp 规则名限制）。
public struct GrammarTerminal: Equatable, Sendable {
    public let name: String
    public let body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }
}

/// 单个能力贡献的文法片段。
public struct GrammarFragment: Sendable {
    public let ruleName: String
    public let ruleBody: String
    public let terminals: [GrammarTerminal]

    public init(ruleName: String, ruleBody: String, terminals: [GrammarTerminal] = []) {
        self.ruleName = ruleName
        self.ruleBody = ruleBody
        self.terminals = terminals
    }
}

/// 能力对内核的完整声明。新增能力 = 一个描述符文件 + 注册表一行。
public struct CapabilityDescriptor: Sendable {
    public let id: String
    public let ownerModuleID: String
    /// 中文默认名，同时作为 L10n 的 key（与现有 `L10n.tr("记账")` 的用法一致）
    public let displayName: String
    public let systemImage: String
    public let params: [ParamSpec]
    public let isDestructive: Bool
    /// 本能力可能产出的撤销令牌类型。执行器按参数分支，可能落到多个类型。
    public let undoKinds: [ActionUndoToken.Kind]
    public let surfaces: Set<CapabilitySurface>
    public let grammar: GrammarFragment?
    public let promptExample: String
    /// 判别层的单字符标签（`OmniboxIntentLabel.rawValue`）。能力参与「16 选 1」意图判别，
    /// 靠这个 token 表达；它一旦被写入历史反馈记录就不再能改（`OmniboxJudgmentFeedback` 存原值）。
    public let intentToken: String
    /// 判别提示词图例里该标签的释义。与 `displayName` 刻意分开：面板叫「待办」，
    /// 而判别图例必须写成「新建待办」才不会和「修改待办」混淆。
    public let intentLegendName: String
    /// 核心能力（收集箱兜底、只读查询），不建议被用户禁用
    public let isCore: Bool

    public init(
        id: String,
        ownerModuleID: String,
        displayName: String,
        systemImage: String,
        params: [ParamSpec],
        isDestructive: Bool = false,
        undoKinds: [ActionUndoToken.Kind],
        surfaces: Set<CapabilitySurface> = [.model, .rules, .ui],
        grammar: GrammarFragment?,
        promptExample: String,
        intentToken: String,
        intentLegendName: String,
        isCore: Bool = false
    ) {
        self.id = id
        self.ownerModuleID = ownerModuleID
        self.displayName = displayName
        self.systemImage = systemImage
        self.params = params
        self.isDestructive = isDestructive
        self.undoKinds = undoKinds
        self.surfaces = surfaces
        self.grammar = grammar
        self.promptExample = promptExample
        self.intentToken = intentToken
        self.intentLegendName = intentLegendName
        self.isCore = isCore
    }

    public var actionCapability: ActionCapability? {
        ActionCapability(rawValue: id)
    }

    public var modelParams: [ParamSpec] {
        params.filter { $0.origin == .model }
    }
}

/// 合成后的文法与索引。
public struct ComposedGrammar: Equatable, Sendable {
    public let text: String
    public let actionLine: String
    public let capabilityRuleNames: [String: String]
    public let fingerprint: UInt64
}

public enum GrammarError: Error, Equatable, CustomStringConvertible {
    case duplicateCapability(String)
    case duplicateRule(String)
    case invalidRuleName(String)
    case missingFragment(String)
    case terminalConflict(String)
    case emptyActionSpace

    public var description: String {
        switch self {
        case .duplicateCapability(let id): return "能力重复注册：\(id)"
        case .duplicateRule(let name): return "规则名重复：\(name)"
        case .invalidRuleName(let name): return "规则名只允许 [a-z0-9-]：\(name)"
        case .missingFragment(let id): return "能力可被模型产出但没有文法片段：\(id)"
        case .terminalConflict(let name): return "终结符同名不同体：\(name)"
        case .emptyActionSpace: return "没有可被模型产出的能力，无法合成文法"
        }
    }
}
