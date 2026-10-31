import Foundation

extension CapabilityDescriptor {
    static let reminderSnooze = CapabilityDescriptor(
        id: "reminder.snooze",
        ownerModuleID: "todo",
        displayName: "推迟提醒",
        systemImage: "clock.arrow.circlepath",
        params: [
            .init("target", .text),
            .init("duration", .enumeration(["10分钟", "1小时", "明早"]), required: false, default: "1小时")
        ],
        undoKinds: [.todo],
        grammar: GrammarFragment(
            ruleName: "cap-reminder-snooze",
            ruleBody: #""{" ws "\"capability\":\"reminder.snooze\"" "," ws "\"target\":\"" text "\"" ("," ws "\"duration\":\"" cap-reminder-snooze-duration "\"")? "}""#,
            terminals: [
                .init(name: "cap-reminder-snooze-duration", body: #""10分钟" | "1小时" | "明早""#)
            ]
        ),
        promptExample: #"推迟提醒：{"capability":"reminder.snooze","target":"提醒事项匹配词","duration":"10分钟|1小时|明早"}"#,
        intentToken: "6",
        intentLegendName: "推迟提醒"
    )
}
