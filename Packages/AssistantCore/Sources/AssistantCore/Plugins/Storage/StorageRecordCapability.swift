import Foundation

extension CapabilityDescriptor {
    static let storageRecord = CapabilityDescriptor(
        id: "storage.record",
        ownerModuleID: "storage",
        displayName: "物品收纳",
        systemImage: "shippingbox.fill",
        params: [
            .init("name", .text),
            .init("location", .text),
            // 旧文法把 roomArea 放成自由文本，提示词却列了固定区域；两边不一致，
            // 本批按文法原样保留，只在描述符里标注默认值。
            .init("roomArea", .text, required: false, default: "主卧"),
            .init("isMedicine", .booleanString, required: false)
        ],
        undoKinds: [.storageRecord, .medicineRecord],
        grammar: GrammarFragment(
            ruleName: "cap-storage-record",
            ruleBody: #""{" ws "\"capability\":\"storage.record\"" "," ws "\"name\":\"" text "\"" "," ws "\"location\":\"" text "\"" ("," ws "\"roomArea\":\"" text "\"")? ("," ws "\"isMedicine\":\"" is-income "\"")? "}""#
        ),
        promptExample: #"物品收纳与常备药：{"capability":"storage.record","name":"物品或药品名","location":"详细存放位置","roomArea":"主卧|次卧|客厅|书房|玄关|厨房|阳台|储物间","isMedicine":"true|false"}"#,
        intentToken: "B",
        intentLegendName: "物品收纳"
    )
}
