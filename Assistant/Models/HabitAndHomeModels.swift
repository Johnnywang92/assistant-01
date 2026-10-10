import Foundation
import SwiftData

/// 周期性重复规则
public enum RecurrenceInterval: String, Codable, CaseIterable {
    case daily = "每天"
    case everyOtherDay = "每隔一天"
    case weekly = "每周"
    case biweekly = "每两周"
    case monthly = "每月"

    public var dayInterval: Int {
        switch self {
        case .daily: 1
        case .everyOtherDay: 2
        case .weekly: 7
        case .biweekly: 14
        case .monthly: 30
        }
    }
}

/// 周期性家务与习惯规则模型
@Model
public final class PeriodicHabit {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var recurrenceRaw: String
    /// 提醒的具体时间（例如每天 08:30 或 21:00）
    public var preferredHour: Int
    public var preferredMinute: Int
    public var lastCompletedAt: Date?
    public var nextDueAt: Date
    public var isEnabled: Bool
    /// 是否联动智能家居（例如：触发扫地机器人清扫场景）
    public var triggerHomeKitScene: String?

    public init(
        title: String,
        detail: String? = nil,
        recurrence: RecurrenceInterval = .weekly,
        preferredHour: Int = 10,
        preferredMinute: Int = 0,
        triggerHomeKitScene: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.detail = detail
        self.recurrenceRaw = recurrence.rawValue
        self.preferredHour = preferredHour
        self.preferredMinute = preferredMinute
        self.isEnabled = true
        self.triggerHomeKitScene = triggerHomeKitScene

        // 计算初始下次到期时间
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: .now)
        comps.hour = preferredHour
        comps.minute = preferredMinute
        self.nextDueAt = cal.date(from: comps) ?? .now
    }

    public var recurrence: RecurrenceInterval {
        get { RecurrenceInterval(rawValue: recurrenceRaw) ?? .weekly }
        set { recurrenceRaw = newValue.rawValue }
    }

    /// 完成一次打卡，并自动推导下一次到期时间
    public func completeOnce() {
        self.lastCompletedAt = .now
        let cal = Calendar.current
        if let next = cal.date(byAdding: .day, value: recurrence.dayInterval, to: .now) {
            var comps = cal.dateComponents([.year, .month, .day], from: next)
            comps.hour = preferredHour
            comps.minute = preferredMinute
            self.nextDueAt = cal.date(from: comps) ?? next
        }
    }
}

/// 充电监控设备类型
public enum ChargeDeviceType: String, Codable, CaseIterable {
    case phone = "手机"
    case watch = "Apple Watch 手表"
    case airpods = "AirPods 耳机"

    public var icon: String {
        switch self {
        case .phone: "iphone"
        case .watch: "applewatch"
        case .airpods: "airpodspro"
        }
    }
}

/// 周期性服药计划模型
@Model
public final class MedicationPlan {
    public var id: UUID
    public var medName: String
    public var dosage: String
    /// 每日服用时点（如 ["08:00", "13:00", "20:00"]）
    public var dailyTimePoints: [String]
    public var isEnabled: Bool
    public var notes: String?

    public init(
        medName: String,
        dosage: String,
        dailyTimePoints: [String],
        notes: String? = nil
    ) {
        self.id = UUID()
        self.medName = medName
        self.dosage = dosage
        self.dailyTimePoints = dailyTimePoints
        self.isEnabled = true
        self.notes = notes
    }
}
