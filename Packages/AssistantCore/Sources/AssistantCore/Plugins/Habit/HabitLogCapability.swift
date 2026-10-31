import Foundation

extension CapabilityDescriptor {
    static let habitLog = CapabilityDescriptor(
        id: "habit.log",
        ownerModuleID: "habit",
        displayName: "习惯与服药",
        systemImage: "pills.fill",
        params: [
            .init("target", .text),
            .init("kind", .enumeration(["habit", "medication"])),
            .init("dosage", .text, required: false)
        ],
        undoKinds: [.habitLog, .medicationLog],
        grammar: GrammarFragment(
            ruleName: "cap-habit-log",
            ruleBody: #""{" ws "\"capability\":\"habit.log\"" "," ws "\"target\":\"" text "\"" "," ws "\"kind\":\"" cap-habit-kind "\"" ("," ws "\"dosage\":\"" text "\"")? "}""#,
            terminals: [
                .init(name: "cap-habit-kind", body: #""habit" | "medication""#)
            ]
        ),
        promptExample: #"习惯与服药打卡：{"capability":"habit.log","target":"习惯名或药品名","kind":"habit|medication","dosage":"剂量可省"}"#,
        intentToken: "C",
        intentLegendName: "习惯与服药打卡"
    )
}
