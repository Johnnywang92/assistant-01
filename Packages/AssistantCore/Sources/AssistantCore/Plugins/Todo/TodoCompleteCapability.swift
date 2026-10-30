import Foundation

extension CapabilityDescriptor {
    static let todoComplete = CapabilityDescriptor(
        id: "todo.complete",
        ownerModuleID: "todo",
        displayName: "完成待办",
        systemImage: "checkmark.circle.fill",
        params: [
            .init("target", .text)
        ],
        undoKinds: [.todo],
        grammar: GrammarFragment(
            ruleName: "cap-todo-complete",
            ruleBody: #""{" ws "\"capability\":\"todo.complete\"" "," ws "\"target\":\"" text "\"" "}""#
        ),
        promptExample: #"完成待办：{"capability":"todo.complete","target":"待完成事项匹配词"}"#
    )
}
