import Foundation

extension CapabilityDescriptor {
    static let lifeRecord = CapabilityDescriptor(
        id: "life.record",
        ownerModuleID: "life",
        displayName: "生活档案",
        systemImage: "sparkles.rectangle.stack.fill",
        params: [
            .init("domain", .enumeration(["pet", "vehicle", "child", "skill", "document", "event"])),
            .init("title", .text),
            .init("detail", .text, required: false),
            .init("value", .number, required: false)
        ],
        undoKinds: [.petRecord, .vehicleRecord, .childRecord, .skillRecord, .idDocument, .lifeEvent],
        grammar: GrammarFragment(
            ruleName: "cap-life-record",
            ruleBody: #""{" ws "\"capability\":\"life.record\"" "," ws "\"domain\":\"" cap-life-domain "\"" "," ws "\"title\":\"" text "\"" ("," ws "\"detail\":\"" text "\"")? ("," ws "\"value\":\"" number "\"")? "}""#,
            terminals: [
                .init(
                    name: "cap-life-domain",
                    body: #""pet" | "vehicle" | "child" | "skill" | "document" | "event""#
                )
            ]
        ),
        promptExample: #"家庭生活档案：{"capability":"life.record","domain":"pet|vehicle|child|skill|document|event","title":"事项或对象名","detail":"详情说明可省","value":"数值可省"}"#,
        intentToken: "F",
        intentLegendName: "生活档案"
    )
}
