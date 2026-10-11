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
    case vehicleCare      // 爱车守护（加油/加电/定期保养/车险年检）
    case returnParcel     // 网购待退货与售后寄件截止倒数
    case travelBooking    // 出行购票提醒（火车票提前15天，机票提前15-30天）
    case exercise         // 运动提醒
    case childVaccine     // 亲子育儿疫苗
    case childGrowth      // 亲子育儿成长测量
    case childMilestone   // 亲子育儿里程碑
    case childHealth      // 亲子育儿健康随访

    var icon: String {
        switch self {
        case .parcel: "shippingbox.fill"
        case .returnParcel: "arrow.uturn.backward.circle.fill"
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
        case .vehicleCare: "car.fill"
        case .travelBooking: "ticket.fill"
        case .exercise: "figure.run"
        case .childVaccine: "syringe.fill"
        case .childGrowth: "chart.xyaxis.line"
        case .childMilestone: "sparkles"
        case .childHealth: "cross.case.fill"
        }
    }

    var displayName: String {
        switch self {
        case .general: "日常待办"
        case .parcel: "快递取件"
        case .returnParcel: "退货寄件"
        case .medication: "服药提醒"
        case .charging: "设备充电"
        case .housework: "周期家务"
        case .subscription: "自动续费"
        case .itemExpiry: "物品临期"
        case .hydration: "喝水提醒"
        case .anniversary: "纪念日"
        case .passwordSecurity: "密码安全"
        case .vehicleCare: "爱车守护"
        case .travelBooking: "出行购票"
        case .exercise: "运动提醒"
        case .childVaccine: "疫苗接种"
        case .childGrowth: "成长测量"
        case .childMilestone: "成长里程碑"
        case .childHealth: "健康随访"
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

/// 待办重复周期规则
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

    public func displayLabel(customDays: Int = 1) -> String {
        switch self {
        case .custom:
            return "每\(max(1, customDays))天"
        default:
            return rawValue
        }
    }
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
    /// 用户自定义上下展示次序（数字越小越靠前）
    var sortOrder: Int = 0
    /// 来源短信/文本原文
    var sourceText: String?
    /// 重复规则原始字符串
    var recurrenceRuleRaw: String?
    /// 重复周期天数（自定义天数或预设天数）
    var recurrenceIntervalDays: Int = 0
    /// 到期前提醒分钟数；0 表示到期时提醒。
    var remindBeforeMinutes: Int = 0
    /// 通知中的“稍后提醒”只改变下次提醒时间，不改变待办截止时间。
    var reminderOverrideAt: Date?
    /// 预约/门票/取件二维码原始载荷内容
    var qrCodePayload: String?
    /// 从原图精准裁剪出的预约二维码图片数据
    @Attribute(.externalStorage)
    var qrCodeImageData: Data?
    /// 关联的完整订单/预约截图凭证数据
    @Attribute(.externalStorage)
    var attachmentImageData: Data?

    init(type: TodoType, status: TodoStatus = .active, title: String, detail: String? = nil,
         pickupCode: String? = nil, courier: String? = nil, station: String? = nil, location: String? = nil,
         dueAt: Date? = nil, sourceText: String? = nil, sortOrder: Int = 0,
         recurrenceRuleRaw: String? = nil, recurrenceIntervalDays: Int = 0,
         remindBeforeMinutes: Int = 0,
         qrCodePayload: String? = nil, qrCodeImageData: Data? = nil, attachmentImageData: Data? = nil) {
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
        self.sortOrder = sortOrder
        self.recurrenceRuleRaw = recurrenceRuleRaw
        self.recurrenceIntervalDays = recurrenceIntervalDays
        self.remindBeforeMinutes = remindBeforeMinutes
        self.qrCodePayload = qrCodePayload
        self.qrCodeImageData = qrCodeImageData
        self.attachmentImageData = attachmentImageData
    }

    /// 是否包含可快速调出的预约二维码或图片凭证
    var hasQRCodeOrTicket: Bool {
        qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true)) || attachmentImageData != nil
    }

    /// 是否包含预约二维码
    var hasQRCode: Bool {
        qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true))
    }

    /// 列表卡片精简展示标题（自动缩减冗余副标题与修饰词，兼容已存旧数据）
    var displayConciseTitle: String {
        OCRService.condenseEventTitle(title)
    }

    /// 列表卡片精简展示详情（去除重复日期、展期与脱敏身份证号，合并为清爽单行摘要）
    var displayConciseDetail: String? {
        OCRService.condenseEventDetail(detail, hasDueAt: dueAt != nil)
    }

    /// 组合场馆与详细地址展示文本
    var displayLocationText: String? {
        let st = station?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLoc: String? = {
            if let st, !st.isEmpty, let loc, !loc.isEmpty {
                if loc.contains(st) { return loc }
                if st.contains(loc) { return st }
                return "\(st) · \(loc)"
            }
            if let loc, !loc.isEmpty { return loc }
            if let st, !st.isEmpty { return st }
            return nil
        }()
        return rawLoc?.replacingOccurrences(of: "上海市", with: "")
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

    var recurrenceRule: TodoRecurrenceRule {
        get {
            guard let raw = recurrenceRuleRaw else { return .none }
            return TodoRecurrenceRule(rawValue: raw) ?? .none
        }
        set {
            recurrenceRuleRaw = newValue == .none ? nil : newValue.rawValue
        }
    }

    var isRecurring: Bool {
        recurrenceRule != .none
    }

    var effectiveRecurrenceDays: Int {
        if recurrenceRule == .custom {
            return max(1, recurrenceIntervalDays)
        }
        return recurrenceRule.dayInterval(customDays: recurrenceIntervalDays)
    }

    var recurrenceSummaryText: String {
        if recurrenceRule == .custom {
            return "每\(max(1, recurrenceIntervalDays))天"
        }
        return recurrenceRule.rawValue
    }

    /// 计算下一次循环的截止时间
    func nextRecurringDueDate(from referenceDate: Date = .now) -> Date {
        let calendar = Calendar.current
        let days = effectiveRecurrenceDays
        guard days > 0 else { return referenceDate }

        if let baseDue = dueAt {
            var nextDate = calendar.date(byAdding: .day, value: days, to: baseDue) ?? referenceDate
            while nextDate <= referenceDate {
                guard let advanced = calendar.date(byAdding: .day, value: days, to: nextDate) else { break }
                nextDate = advanced
            }
            return nextDate
        } else {
            return calendar.date(byAdding: .day, value: days, to: referenceDate) ?? referenceDate
        }
    }

    /// 完成该事项。如果为周期性待办，会自动生成下一期活跃待办事项并插入 ModelContext
    @discardableResult
    func markAsCompleted(in context: ModelContext) -> TodoItem? {
        self.status = .done
        TodoNotificationManager.shared.cancelNotification(for: self.id)

        guard isRecurring else { return nil }

        let nextDue = nextRecurringDueDate(from: .now)
        let nextItem = TodoItem(
            type: self.type,
            status: .active,
            title: self.title,
            detail: self.detail,
            pickupCode: self.pickupCode,
            courier: self.courier,
            station: self.station,
            location: self.location,
            dueAt: nextDue,
            sourceText: self.sourceText,
            sortOrder: self.sortOrder,
            recurrenceRuleRaw: self.recurrenceRuleRaw,
            recurrenceIntervalDays: self.recurrenceIntervalDays,
            remindBeforeMinutes: self.remindBeforeMinutes
        )
        context.insert(nextItem)
        TodoNotificationManager.shared.scheduleNotification(for: nextItem)
        return nextItem
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
