import Foundation
import SwiftData
import UIKit

/// 手机/耳机/手表电量检查与低电量提醒服务
@MainActor
struct BatteryReminderService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 检查本设备（iPhone）电量并按需生成充电待办
    public func checkDeviceBattery(threshold: Float = 0.20) -> String? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState

        guard level >= 0 else { return nil } // 无法获取电量时忽略

        let percent = Int(level * 100)

        // 如果没有充电，且电量低于阈值（默认 20%）
        if state != .charging && state != .full && level <= threshold {
            let title = "手机电量仅剩 \(percent)%，请及时充电"
            // 先落库、再发低电量通知（审计 SVC-04）：保存失败时不发一条指向不存在待办的通知，
            // 返回 nil 表示本轮没有产出提醒。
            guard upsertChargingTodo(device: .phone, title: title, detail: "低于 \(Int(threshold * 100))% 预警") else {
                return nil
            }
            NotificationService.post(title: "⚡ 低电量提醒", body: title, id: "battery-phone")
            return title
        } else if state == .charging || state == .full {
            // 已插上充电，自动完成对应充电待办
            resolveChargingTodo(device: .phone)
        }
        return nil
    }

    /// 接收外部传入的手表/耳机电量报告（可来自快捷指令自动化触发）
    public func handleExternalDeviceBattery(
        device: ChargeDeviceType,
        percent: Int,
        isCharging: Bool
    ) -> String? {
        if !isCharging && percent <= 20 {
            let title = "\(device.rawValue) 电量仅剩 \(percent)%，别忘充电"
            guard upsertChargingTodo(device: device, title: title, detail: "\(device.rawValue) 离线电量汇报") else {
                return nil
            }
            NotificationService.post(title: "⚡ 设备低电量预警", body: title, id: "battery-\(device.rawValue)")
            return title
        } else if isCharging || percent >= 95 {
            resolveChargingTodo(device: device)
        }
        return nil
    }

    /// 写入低电量充电待办，返回是否落库成功（失败回滚 + 日志，调用方据此决定是否发通知）。
    @discardableResult
    private func upsertChargingTodo(device: ChargeDeviceType, title: String, detail: String) -> Bool {
        let charging = TodoType.charging.rawValue
        let active = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == charging && $0.statusRaw == active }
        )
        let existings = (try? context.fetch(descriptor)) ?? []

        if let matched = existings.first(where: { $0.title.contains(device.rawValue) || (device == .phone && $0.title.contains("手机")) }) {
            matched.title = title
        } else {
            let item = TodoItem(type: .charging, status: .active, title: title, detail: detail)
            context.insert(item)
        }
        return context.saveReportingFailure { error in
            print("⚠️ [Battery] 低电量待办落库失败: \(error.localizedDescription)")
        }
    }

    private func resolveChargingTodo(device: ChargeDeviceType) {
        let charging = TodoType.charging.rawValue
        let active = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == charging && $0.statusRaw == active }
        )
        let existings = (try? context.fetch(descriptor)) ?? []
        for item in existings where item.title.contains(device.rawValue) || (device == .phone && item.title.contains("手机")) {
            item.status = .done
        }
        // 充电后自动完成待办属于尽力而为：失败只记日志，下次电量检查会再判一次。
        _ = context.saveReportingFailure { error in
            print("⚠️ [Battery] 充电后完成待办落库失败: \(error.localizedDescription)")
        }
    }
}
