import Foundation

/// 把各能力的文法片段合成为一份完整 GBNF。
///
/// 与旧 `ActionJSONGrammar.gbnf` 的差异只有两处：能力规则加 `cap-` 前缀、
/// 能力私有词表加命名空间前缀。共享终结符与每条产生式的接受语言保持不变。
public enum ActionGrammarComposer {

    /// llama_sampler_init_grammar 的 grammar_root 起始符号名
    public static let rootName = "root"

    public static let rootRule = #"root ::= "[" ws action ("," ws action)* ws "]""#

    /// 内核共享终结符。能力描述符不得重新定义同名不同体的终结符。
    public static let kernelTerminals: [GrammarTerminal] = [
        .init(name: "ws", body: #"[ \t\n\r]*"#),
        .init(name: "number", body: #""-"? [0-9]+ ("." [0-9]+)?"#),
        .init(name: "days", body: #""-"? [0-9]+"#),
        .init(name: "time", body: #"("0" [0-9] | "1" [0-9] | "2" [0-3]) ":" [0-5] [0-9]"#),
        .init(name: "date", body: #"[0-9] [0-9] [0-9] [0-9] "-" [0-9] [0-9] "-" [0-9] [0-9]"#),
        .init(name: "datetime", body: #"date " " time"#),
        .init(name: "is-income", body: #""true" | "false""#),
        .init(name: "text", body: "char*"),
        .init(name: "char", body: #"[^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)"#),
        .init(name: "hex", body: "[0-9a-fA-F]")
    ]

    /// 合成文法。`enabledIDs` 为空表示不启用任何能力并直接报错，而不是产出空文法。
    public static func compose(
        _ descriptors: [CapabilityDescriptor],
        enabledIDs: Set<String>? = nil
    ) throws -> ComposedGrammar {
        let enabled = enabledIDs.map { ids in descriptors.filter { ids.contains($0.id) } } ?? descriptors
        let modelFacing = enabled.filter { $0.surfaces.contains(.model) }

        var rules: [(name: String, body: String)] = []
        var terminals = kernelTerminals
        var terminalByName: [String: String] = [:]
        for terminal in kernelTerminals { terminalByName[terminal.name] = terminal.body }

        var capabilityRuleNames: [String: String] = [:]
        var usedRuleNames = Set<String>()

        for descriptor in modelFacing {
            guard let fragment = descriptor.grammar else {
                throw GrammarError.missingFragment(descriptor.id)
            }
            guard capabilityRuleNames[descriptor.id] == nil else {
                throw GrammarError.duplicateCapability(descriptor.id)
            }
            guard fragment.ruleName.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
                throw GrammarError.invalidRuleName(fragment.ruleName)
            }
            guard !usedRuleNames.contains(fragment.ruleName) else {
                throw GrammarError.duplicateRule(fragment.ruleName)
            }
            usedRuleNames.insert(fragment.ruleName)
            capabilityRuleNames[descriptor.id] = fragment.ruleName
            rules.append((fragment.ruleName, fragment.ruleBody))

            for terminal in fragment.terminals {
                if let existing = terminalByName[terminal.name] {
                    guard existing == terminal.body else {
                        throw GrammarError.terminalConflict(terminal.name)
                    }
                } else {
                    terminalByName[terminal.name] = terminal.body
                    terminals.append(terminal)
                }
            }
        }

        guard !rules.isEmpty else { throw GrammarError.emptyActionSpace }

        // 备选顺序 = 注册表声明顺序：GBNF 备选语义上无序，但固定顺序让文法串可做快照
        let actionLine = "action ::= " + rules.map(\.name).joined(separator: " | ")
        let text = ([rootRule, actionLine]
            + rules.map { "\($0.name) ::= \($0.body)" }
            + terminals.map { "\($0.name) ::= \($0.body)" })
            .joined(separator: "\n\n")

        return ComposedGrammar(
            text: text,
            actionLine: actionLine,
            capabilityRuleNames: capabilityRuleNames,
            fingerprint: fingerprint(of: text)
        )
    }

    private static func fingerprint(of text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }
}
