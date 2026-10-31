import Foundation

extension CapabilityDescriptor {
    static let anniversaryCreate = CapabilityDescriptor(
        id: "anniversary.create",
        ownerModuleID: "anniversary",
        displayName: "纪念日与到期",
        systemImage: "heart.text.square.fill",
        params: [
            .init("title", .text),
            .init("category", .enumeration(["纪念日", "生日", "倒数日", "订阅续费", "保质期"])),
            .init("targetDate", .date, required: false),
            .init("price", .text, required: false)
        ],
        undoKinds: [.anniversary, .subscription, .itemExpiry],
        grammar: GrammarFragment(
            ruleName: "cap-anniversary-create",
            ruleBody: #""{" ws "\"capability\":\"anniversary.create\"" "," ws "\"title\":\"" text "\"" "," ws "\"category\":\"" cap-anniversary-category "\"" ("," ws "\"targetDate\":\"" date "\"")? ("," ws "\"price\":\"" text "\"")? "}""#,
            terminals: [
                .init(
                    name: "cap-anniversary-category",
                    body: #""纪念日" | "生日" | "倒数日" | "订阅续费" | "保质期""#
                )
            ]
        ),
        promptExample: #"纪念日与到期预警：{"capability":"anniversary.create","title":"名称","category":"纪念日|生日|倒数日|订阅续费|保质期","targetDate":"yyyy-MM-dd可省","price":"金额可省"}"#,
        intentToken: "D",
        intentLegendName: "纪念日与到期"
    )
}
