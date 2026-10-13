import AppIntents
import Foundation

/// 快捷指令动作：导入短信。由「信息」自动化调用，后台运行，不打开 App。
struct ImportSMSIntent: AppIntent {
    static var title: LocalizedStringResource = "导入短信"
    static var description = IntentDescription("解析短信内容（快递取件、已取件、流量），自动生成或完成待办。")
    static var openAppWhenRun = false

    @Parameter(title: "短信内容", default: "")
    var text: String

    @Parameter(title: "发件人", default: nil)
    var sender: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = Persistence.shared.mainContext
        let result = try ImportService(context: context).ingest(text, source: "sms", sender: sender)
        if result.isNotable {
            NotificationService.post(title: AppSettings.assistantName, body: result.summary)
        }
        return .result(value: result.summary)
    }
}

/// 快捷指令动作：处理收件箱文件（可选，作为兜底）。
struct DrainInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "处理短信收件箱"
    static var description = IntentDescription("导入 inbox.txt 中积压的短信。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let n = await InboxService.drain(context: Persistence.shared.mainContext)
        return .result(value: n)
    }
}
