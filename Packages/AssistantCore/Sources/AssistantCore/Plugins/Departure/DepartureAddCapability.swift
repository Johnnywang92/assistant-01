import Foundation

extension CapabilityDescriptor {
    static let departureAdd = CapabilityDescriptor(
        id: "departure.add",
        ownerModuleID: "departure",
        displayName: "出门清单",
        systemImage: "door.left.hand.open",
        params: [
            .init("title", .text),
            // 旧文法把 scene 放成自由文本，提示词列举固定场景；两边不一致，
            // 本批按文法原样保留。
            .init("scene", .text, required: false),
            .init("location", .text, required: false)
        ],
        undoKinds: [.departureItem],
        grammar: GrammarFragment(
            ruleName: "cap-departure-add",
            ruleBody: #""{" ws "\"capability\":\"departure.add\"" "," ws "\"title\":\"" text "\"" ("," ws "\"scene\":\"" text "\"")? ("," ws "\"location\":\"" text "\"")? "}""#
        ),
        promptExample: #"出门检查清单：{"capability":"departure.add","title":"随身物品名","scene":"工作通勤|运动健身|出差旅行|带娃出行|遛狗随行|雨雪出行|日常轻装","location":"放置位置可省"}"#,
        intentToken: "E",
        intentLegendName: "出门清单"
    )
}
