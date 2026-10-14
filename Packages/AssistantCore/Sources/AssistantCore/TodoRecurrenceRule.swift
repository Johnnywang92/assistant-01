import Foundation

/// 待办重复周期规则。
/// 下沉自 Assistant/Models/Models.swift：枚举本体只含纯数据（rawValue、图标名、天数换算），
/// 依赖 L10n 的展示名 `displayLabel` 留在 app 侧扩展里。
public enum TodoRecurrenceRule: String, Codable, CaseIterable, Identifiable {
    case none = "不重复"
    case daily = "每天"
    case everyOtherDay = "每2天（隔天）"
    case everyThreeDays = "每3天"
    case weekly = "每周"
    case biweekly = "每两周"
    case monthly = "每月"
    case custom = "自定义天数"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .none: return "slash.circle"
        case .daily: return "repeat"
        case .everyOtherDay, .everyThreeDays, .custom: return "repeat.1"
        case .weekly, .biweekly: return "calendar.badge.clock"
        case .monthly: return "calendar"
        }
    }

    public func dayInterval(customDays: Int = 1) -> Int {
        switch self {
        case .none: return 0
        case .daily: return 1
        case .everyOtherDay: return 2
        case .everyThreeDays: return 3
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        case .custom: return max(1, customDays)
        }
    }
}
