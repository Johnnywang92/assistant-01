import Foundation

extension CapabilityDescriptor {
    /// 只读查询，无副作用，不产出撤销令牌。
    static let queryLookup = CapabilityDescriptor(
        id: "query.lookup",
        ownerModuleID: "query",
        displayName: "查询事项",
        systemImage: "magnifyingglass",
        params: [
            .init("target", .text, aliases: ["query"])
        ],
        undoKinds: [],
        grammar: GrammarFragment(
            ruleName: "cap-query-lookup",
            ruleBody: #""{" ws "\"capability\":\"query.lookup\"" "," ws "\"target\":\"" text "\"" "}""#
        ),
        promptExample: #"查询事项：{"capability":"query.lookup","target":"查询关键词或完整问句（如「护照放哪了」「上周花了多少」「今天有什么安排」）"}"#,
        isCore: true
    )
}
