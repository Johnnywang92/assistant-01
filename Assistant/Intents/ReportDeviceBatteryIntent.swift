import AppIntents
import Foundation

/// 快捷指令动作：报告设备电量（用于 Apple Watch 或 AirPods 低电量时自动化通知助手）
struct ReportDeviceBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "汇报设备电量"
    static var description = IntentDescription("上报 iPhone、Apple Watch 或耳机电量，低电量时自动生成充电待办。")
    static var openAppWhenRun = false

    @Parameter(title: "设备类型", default: "Apple Watch 手表")
    var deviceName: String

    @Parameter(title: "电量百分比", default: 20)
    var percent: Int

    @Parameter(title: "是否正在充电", default: false)
    var isCharging: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let type: ChargeDeviceType = switch deviceName {
        case "AirPods 耳机": .airpods
        case "手机": .phone
        default: .watch
        }

        let service = BatteryReminderService()
        let result = service.handleExternalDeviceBattery(device: type, percent: percent, isCharging: isCharging)

        return .result(value: result ?? "\(deviceName) 电量状态正常")
    }
}
