import Foundation

extension CapabilityDescriptor {
    /// 收集箱兜底。若备忘里含饮食内容，执行器会额外建一条食物记录，
    /// 所以撤销令牌可能是备忘录行，也可能同时带上食物记录 ID。
    static let memoInbox = CapabilityDescriptor(
        id: "memo.inbox",
        ownerModuleID: "memo",
        displayName: "收集箱",
        systemImage: "tray.full.fill",
        params: [
            .init("memo", .text)
        ],
        undoKinds: [.memoLine, .foodRecord],
        grammar: GrammarFragment(
            ruleName: "cap-memo-inbox",
            ruleBody: #""{" ws "\"capability\":\"memo.inbox\"" "," ws "\"memo\":\"" text "\"" "}""#
        ),
        promptExample: #"收集箱：{"capability":"memo.inbox","memo":"原文摘录"}"#,
        intentToken: "8",
        intentLegendName: "收入收集箱",
        isCore: true
    )
}
