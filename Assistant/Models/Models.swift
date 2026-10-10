import Foundation
import SwiftData

enum TodoType: String, Codable, CaseIterable {
    case parcel, data, bill, event, general
    case medication    // 吃药提醒
    case charging      // 手机/耳机/手表充电提醒
    case housework     // 周期性家务 (扫地/洗床单/换滤网/浇花)
    case subscription  // 连续包月/自动续费防被坑
    case itemExpiry    // 证件/食品/药品保质期临期预警
    case hydration     // 喝水与久坐起立活动提醒
    case anniversary   // 纪念日/生日倒数与提醒
    case passwordSecurity // 密码轮换与安全提醒

    var icon: String {
        switch self {
        case .parcel: "shippingbox.fill"
        case .data: "antenna.radiowaves.left.and.right"
        case .bill: "yensign.circle.fill"
        case .event: "calendar"
        case .general: "checkmark.circle"
        case .medication: "pills.fill"
        case .charging: "bolt.batteryblock.fill"
        case .housework: "bubbles.and.sparkles.fill"
        case .subscription: "creditcard.and.123"
        case .itemExpiry: "hourglass.bottomhalf.filled"
        case .hydration: "drop.fill"
        case .anniversary: "gift.fill"
        case .passwordSecurity: "key.fill"
        }
    }

    var displayName: String {
        switch self {
        case .general: "日常待办"
        case .parcel: "快递取件"
        case .medication: "服药提醒"
        case .charging: "设备充电"
        case .housework: "周期家务"
        case .subscription: "自动续费"
        case .itemExpiry: "物品临期"
        case .hydration: "喝水提醒"
        case .anniversary: "纪念日"
        case .passwordSecurity: "密码安全"
        case .bill: "信用卡账单"
        case .event: "日程事项"
        case .data: "流量预警"
        }
    }
}

enum TodoStatus: String, Codable {
    /// 规则无法识别，等待用户确认
    case pendingReview
    case active
    case done
}

@Model
final class TodoItem {
    var id: UUID
    var typeRaw: String
    var statusRaw: String
    var title: String
    var detail: String?
    var pickupCode: String?
    var courier: String?
    var station: String?
    var location: String?
    var dueAt: Date?
    var createdAt: Date
    var completedAt: Date?
    /// 来源短信/文本原文
    var sourceText: String?

    init(type: TodoType, status: TodoStatus = .active, title: String, detail: String? = nil,
         pickupCode: String? = nil, courier: String? = nil, station: String? = nil, location: String? = nil,
         dueAt: Date? = nil, sourceText: String? = nil) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.statusRaw = status.rawValue
        self.title = title
        self.detail = detail
        self.pickupCode = pickupCode
        self.courier = courier
        self.station = station
        self.location = location
        self.dueAt = dueAt
        self.createdAt = .now
        self.sourceText = sourceText
    }

    var type: TodoType {
        get { TodoType(rawValue: typeRaw) ?? .general }
        set { typeRaw = newValue.rawValue }
    }

    var status: TodoStatus {
        get { TodoStatus(rawValue: statusRaw) ?? .active }
        set {
            statusRaw = newValue.rawValue
            completedAt = newValue == .done ? .now : nil
        }
    }
}

@Model
final class RawMessage {
    var id: UUID
    var source: String
    var sender: String?
    var content: String
    var receivedAt: Date
    /// 解析结果简述，便于排查规则
    var parseSummary: String?

    init(source: String, sender: String?, content: String) {
        self.id = UUID()
        self.source = source
        self.sender = sender
        self.content = content
        self.receivedAt = .now
    }
}

@Model
final class DataUsageRecord {
    var id: UUID
    var operatorName: String?
    var remainingMB: Double?
    var usedMB: Double?
    var usedPercent: Double?
    var recordedAt: Date

    init(operatorName: String?, remainingMB: Double?, usedMB: Double?, usedPercent: Double?, recordedAt: Date = .now) {
        self.id = UUID()
        self.operatorName = operatorName
        self.remainingMB = remainingMB
        self.usedMB = usedMB
        self.usedPercent = usedPercent
        self.recordedAt = recordedAt
    }
}
