import Foundation

extension CapabilityDescriptor {
    /// 修改既有账目。破坏性动作，强制确认。
    static let expenseUpdate = CapabilityDescriptor(
        id: "expense.update",
        ownerModuleID: "expense",
        displayName: "修改账目",
        systemImage: "pencil.circle.fill",
        params: [
            .init("target", .text),
            .init("newAmount", .number, aliases: ["amount"]),
            // 执行器支持，但文法未开放给模型；由确认卡编辑注入
            .init("newTitle", .text, .nonModel, required: false),
            .init("newCategory", .text, .nonModel, required: false)
        ],
        isDestructive: true,
        undoKinds: [.expense],
        grammar: GrammarFragment(
            ruleName: "cap-expense-update",
            ruleBody: #""{" ws "\"capability\":\"expense.update\"" "," ws "\"target\":\"" text "\"" "," ws "\"newAmount\":\"" number "\"" "}""#
        ),
        promptExample: #"修改账目：{"capability":"expense.update","target":"原账单事项名或关键词","newAmount":"修改后金额"}"#
    )
}
