import Foundation

extension CapabilityDescriptor {
    /// 记一笔收支。文法体与旧 `ActionJSONGrammar` 的 expense-create 逐字一致。
    static let expenseCreate = CapabilityDescriptor(
        id: "expense.create",
        ownerModuleID: "expense",
        displayName: "记账",
        systemImage: "yensign.circle.fill",
        params: [
            .init("amount", .number),
            .init("isIncome", .booleanString),
            .init("category", .enumeration([
                "餐饮美食", "交通出行", "居家日用", "购物消费", "休闲娱乐", "医疗健康",
                "宠物萌宠", "数码家电", "人情社交", "职业收入", "其它收入", "其它支出"
            ])),
            .init("title", .text),
            .init("dateISO", .dateTime, required: false),
            // OCR / 小票管线注入，模型不可产出
            .init("currency", .text, .nonModel, required: false),
            .init("foreignAmount", .number, .nonModel, required: false),
            .init("exchangeRate", .number, .nonModel, required: false),
            .init("rawText", .text, .nonModel, required: false)
        ],
        undoKinds: [.expense],
        grammar: GrammarFragment(
            ruleName: "cap-expense-create",
            ruleBody: #""{" ws "\"capability\":\"expense.create\"" "," ws "\"amount\":\"" number "\"" "," ws "\"isIncome\":\"" is-income "\"" "," ws "\"category\":\"" cap-expense-category "\"" "," ws "\"title\":\"" text "\"" ("," ws "\"dateISO\":\"" datetime "\"")? "}""#,
            terminals: [
                .init(
                    name: "cap-expense-category",
                    body: #""餐饮美食" | "交通出行" | "居家日用" | "购物消费" | "休闲娱乐" | "医疗健康" | "宠物萌宠" | "数码家电" | "人情社交" | "职业收入" | "其它收入" | "其它支出""#
                )
            ]
        ),
        promptExample: #"记账：{"capability":"expense.create","amount":"数字","isIncome":"false","category":"餐饮美食|交通出行|居家日用|购物消费|休闲娱乐|医疗健康|宠物萌宠|数码家电|人情社交|职业收入|其它收入|其它支出","title":"简短事项名","dateISO":"yyyy-MM-dd HH:mm 可省"}"#
    )
}
