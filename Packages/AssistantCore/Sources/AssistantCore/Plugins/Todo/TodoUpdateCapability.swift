import Foundation

extension CapabilityDescriptor {
    /// 修改待办。文法要求 newTitle 在 dueAtDays 之前。
    static let todoUpdate = CapabilityDescriptor(
        id: "todo.update",
        ownerModuleID: "todo",
        displayName: "修改待办",
        systemImage: "pencil.and.list.clipboard",
        params: [
            .init("target", .text),
            .init("newTitle", .text, required: false),
            .init("dueAtDays", .integer, required: false, requires: ["newTitle"]),
            // 执行器支持，但文法未开放给模型
            .init("newDetail", .text, .nonModel, required: false),
            .init("dueAtTime", .time, .nonModel, required: false),
            .init("dueAtISO", .dateTime, .nonModel, required: false)
        ],
        undoKinds: [.todo],
        grammar: GrammarFragment(
            ruleName: "cap-todo-update",
            ruleBody: #""{" ws "\"capability\":\"todo.update\"" "," ws "\"target\":\"" text "\"" ("," ws "\"newTitle\":\"" text "\"" ("," ws "\"dueAtDays\":\"" days "\"")?)? "}""#
        ),
        promptExample: #"修改待办：{"capability":"todo.update","target":"原待办匹配关键词","newTitle":"新标题（可省）","dueAtDays":"新截止相对天数（可省）"}"#,
        intentToken: "3",
        intentLegendName: "修改待办"
    )
}
