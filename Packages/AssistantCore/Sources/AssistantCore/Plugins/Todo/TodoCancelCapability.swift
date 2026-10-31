import Foundation

extension CapabilityDescriptor {
    /// 取消/删除待办。破坏性动作，强制确认。
    static let todoCancel = CapabilityDescriptor(
        id: "todo.cancel",
        ownerModuleID: "todo",
        displayName: "取消待办",
        systemImage: "xmark.circle.fill",
        params: [
            .init("target", .text)
        ],
        isDestructive: true,
        undoKinds: [.todo],
        grammar: GrammarFragment(
            ruleName: "cap-todo-cancel",
            ruleBody: #""{" ws "\"capability\":\"todo.cancel\"" "," ws "\"target\":\"" text "\"" "}""#
        ),
        promptExample: #"取消待办：{"capability":"todo.cancel","target":"待取消事项匹配词"}"#,
        intentToken: "5",
        intentLegendName: "取消待办"
    )
}
