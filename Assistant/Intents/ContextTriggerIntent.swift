import AppIntents
import CoreLocation
import Foundation

/// 快捷指令动作：环境联动与智能情景触发
/// 可在快捷指令的「自动化」中配置：
/// 1. 当加入指定 Wi-Fi / 断开 Wi-Fi 时运行
/// 2. 当到达指定地点 / 离开地点时运行
/// 3. 当特定时间点（如早上 8:00、晚上 19:00）时运行
struct ContextTriggerIntent: AppIntent {
    static var title: LocalizedStringResource = "触发情境智能提醒"
    static var description = IntentDescription("结合当前 Wi-Fi、地点、时间或天气，智能分析待办事项并进行情景化通知。")
    static var openAppWhenRun = false

    @Parameter(title: "情景类型", default: "离开家/断开家庭Wi-Fi")
    var scenario: String

    @Parameter(title: "Wi-Fi名称", default: nil)
    var wifiName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let reason: ContextTriggerReason = switch scenario {
        case "到家/连接家庭Wi-Fi": .arriveHomeOrConnectWiFi
        case "早晨出门简报": .morningBriefing
        case "晚间提醒": .eveningBriefing
        case "到达指定地点": .locationArrive
        default: .leaveHomeOrDisconnectWiFi
        }

        let advisor = ContextSmartAdvisor()
        let result = await advisor.evaluate(reason: reason, wifiSSID: wifiName)

        // 同时将这次 Wi-Fi 与时间驻留事实作为正向样本，喂入学习引擎进行画像增强
        if let wifi = wifiName, !wifi.isEmpty {
            let engine = PlaceLearningEngine(context: Persistence.shared.mainContext)
            _ = try? engine.recordObservation(
                coordinate: .init(latitude: 0, longitude: 0),
                wifiSSID: wifi
            )
        }

        if let advice = result {
            NotificationService.post(title: "情境提醒 · \(reason.rawValue)", body: advice)
            return .result(value: advice)
        } else {
            return .result(value: "当前情境无待办提醒")
        }
    }
}
