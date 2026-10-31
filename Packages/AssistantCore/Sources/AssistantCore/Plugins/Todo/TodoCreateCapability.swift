import Foundation

extension CapabilityDescriptor {
    /// 新建待办。dueAtTime 在文法里嵌套在 dueAtDays 之后。
    static let todoCreate = CapabilityDescriptor(
        id: "todo.create",
        ownerModuleID: "todo",
        displayName: "待办",
        systemImage: "checklist",
        params: [
            .init("title", .text),
            .init("detail", .text, required: false),
            .init("dueAtDays", .integer, required: false),
            .init("dueAtTime", .time, required: false, requires: ["dueAtDays"]),
            // 票务 / OCR / 分享管线注入，模型不可产出
            .init("dueAtISO", .dateTime, .nonModel, required: false),
            .init("typeRaw", .text, .nonModel, required: false),
            .init("pickupCode", .text, .nonModel, required: false),
            .init("station", .text, .nonModel, required: false),
            .init("location", .text, .nonModel, required: false),
            .init("sourceText", .text, .nonModel, required: false),
            .init("qrCodePayload", .text, .nonModel, required: false),
            .init("arrivalAtISO", .dateTime, .nonModel, required: false),
            .init("arrivalTransport", .text, .nonModel, required: false),
            .init("travelPickupMode", .text, .nonModel, required: false)
        ],
        undoKinds: [.todo],
        grammar: GrammarFragment(
            ruleName: "cap-todo-create",
            ruleBody: #""{" ws "\"capability\":\"todo.create\"" "," ws "\"title\":\"" text "\"" ("," ws "\"detail\":\"" text "\"" ("," ws "\"dueAtDays\":\"" days "\"" ("," ws "\"dueAtTime\":\"" time "\"")?)?)? "}""#
        ),
        promptExample: #"待办新建：{"capability":"todo.create","title":"待办标题","detail":"补充说明，可省","dueAtDays":"相对今天的天数，可省","dueAtTime":"HH:mm，可省"}"#,
        intentToken: "2",
        intentLegendName: "新建待办"
    )
}
