import Foundation

extension CapabilityDescriptor {
    static let waterRecord = CapabilityDescriptor(
        id: "water.record",
        ownerModuleID: "water",
        displayName: "记录饮水",
        systemImage: "drop.fill",
        params: [
            .init("beverageType", .enumeration([
                "白开水", "纯茶", "黑咖啡", "拿铁", "牛奶", "奶茶", "含糖饮料", "苏打水"
            ])),
            .init("volumeML", .number),
            .init("customName", .text, required: false),
            // 拍照识别 / 快捷指令注入
            .init("dateISO", .dateTime, .nonModel, required: false)
        ],
        undoKinds: [.waterRecord],
        grammar: GrammarFragment(
            ruleName: "cap-water-record",
            ruleBody: #""{" ws "\"capability\":\"water.record\"" "," ws "\"beverageType\":\"" cap-water-beverage-type "\"" "," ws "\"volumeML\":\"" number "\"" ("," ws "\"customName\":\"" text "\"")? "}""#,
            terminals: [
                .init(
                    name: "cap-water-beverage-type",
                    body: #""白开水" | "纯茶" | "黑咖啡" | "拿铁" | "牛奶" | "奶茶" | "含糖饮料" | "苏打水""#
                )
            ]
        ),
        promptExample: #"饮水记录：{"capability":"water.record","beverageType":"白开水|纯茶|黑咖啡|拿铁|牛奶|奶茶|含糖饮料|苏打水","volumeML":"毫升数字","customName":"饮品名可省"}"#
    )
}
