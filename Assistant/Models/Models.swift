import Foundation
import SwiftData
import AssistantCore

enum TodoType: String, Codable, CaseIterable, Hashable {
    case parcel, data, bill, event, general
    case work          // 工作待办（会议、周报、项目交付、汇报评审）
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
    case pet              // 宠物照护
    case skillLearning    // 技能学习路径的阶段任务与练习打卡

    var icon: String {
        switch self {
        case .parcel: "shippingbox.fill"
        case .returnParcel: "arrow.uturn.backward.circle.fill"
        case .data: "antenna.radiowaves.left.and.right"
        case .bill: "yensign.circle.fill"
        case .event: "calendar"
        case .general: "checkmark.circle"
        case .work: "briefcase.fill"
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
        case .pet: "pawprint.fill"
        case .skillLearning: "book.fill"
        }
    }

    var displayName: String {
        let raw: String = switch self {
        case .general: "日常待办"
        case .work: "工作待办"
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
        case .pet: "宠物照护"
        case .bill: "信用卡账单"
        case .event: "日程事项"
        case .data: "流量预警"
        case .skillLearning: "技能学习"
        }
        return L10n.tr(raw)
    }
}

enum TodoStatus: String, Codable {
    /// 规则无法识别，等待用户确认
    case pendingReview
    case active
    case done
}

/// 待办排序采用“紧急性 60% + 重要性 40%”。分数只用于排序，不改变用户设置的截止时间。
enum TodoPriority {
    static func score(for item: TodoItem, now: Date = .now) -> Int {
        urgencyScore(for: item, now: now) * 6 + importanceScore(for: item) * 4
    }

    static func sort(_ items: inout [TodoItem], now: Date = .now) {
        // 预计算每项分数：比较器退化为纯整数/日期比较，
        // 避免 O(N log N) 次重复构建词表与本地化字符串匹配导致主线程掉帧。
        let scored = items.map { (item: $0, score: score(for: $0, now: now)) }
        items = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            switch ($0.item.dueAt, $1.item.dueAt) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.item.sortOrder < $1.item.sortOrder
            }
        }.map(\.item)
    }

    /// 截止时间越近，紧急性越高；逾期事项始终位于最前。
    private static func urgencyScore(for item: TodoItem, now: Date) -> Int {
        guard let due = item.dueAt else { return 15 }
        let hours = due.timeIntervalSince(now) / 3600
        if hours < 0 { return 100 }
        if hours <= 2 { return 95 }
        if hours <= 24 { return 80 }
        if hours <= 72 { return 60 }
        if hours <= 168 { return 35 }
        return 15
    }

    /// 重要性由事项类型和标题中的风险词推断，涉及健康、财务、安全和硬截止日期的事项更重要。
    /// 词表提升为静态常量，匹配用直接 contains 替代 ICU 本地化搜索（关键词均为中文，语义不变）。
    private static let highImportanceTypes: Set<TodoType> = [.medication, .bill, .itemExpiry, .passwordSecurity, .childVaccine, .childHealth, .returnParcel]
    private static let mediumImportanceTypes: Set<TodoType> = [.event, .travelBooking, .subscription, .vehicleCare, .parcel, .childGrowth, .childMilestone, .pet]
    private static let criticalWords = ["必须", "紧急", "还款", "缴费", "截止", "逾期", "疫苗", "用药", "证件", "安全"]

    private static func importanceScore(for item: TodoItem) -> Int {
        var score: Int = highImportanceTypes.contains(item.type) ? 90 : (mediumImportanceTypes.contains(item.type) ? 60 : 35)
        let text = item.title + " " + (item.detail ?? "")
        if criticalWords.contains(where: text.contains) {
            score = min(100, score + 20)
        }
        return score
    }
}

/// 待办重复周期规则的枚举本体已下沉到 AssistantCore.TodoRecurrenceRule（可脱离 app 单测）；
/// 这里只补依赖本地化的展示名。
extension TodoRecurrenceRule {
    public func displayLabel(customDays: Int = 1) -> String {
        switch self {
        case .custom:
            return L10n.tr("每\(max(1, customDays))天")
        default:
            return L10n.tr(rawValue)
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
    /// 归属的学习路径 ID（软关联，旧数据为 nil）
    var skillPathID: UUID?
    /// 归属的学习阶段序号（仅当 skillPathID 非空时有效）
    var skillStageIndex: Int = 0
    /// 是否为学习路径中的周期性练习打卡任务
    var isSkillPractice: Bool = false
    /// 该条打卡的预估投入分钟数
    var skillPracticeMinutes: Int = 0
    /// 写入系统日历后的 EKEvent identifier（用于双向同步与删除，防止孤儿日程）
    var calendarItemIdentifier: String?
    /// 到站/落地前清点随身物品的提醒时刻；非 nil 即表示该待办开启了到站提醒。
    var arrivalReminderAt: Date?
    /// 到站提醒的交通方式原始值（TripArrivalSchedule.TransportKind.rawValue）
    var arrivalTransportRaw: String?
    /// 本次行程到站提醒的已触发时间，用于去重，避免一次行程反复弹窗
    var arrivalCheckFiredAt: Date?

    init(type: TodoType, status: TodoStatus = .active, title: String, detail: String? = nil,
         pickupCode: String? = nil, courier: String? = nil, station: String? = nil, location: String? = nil,
         dueAt: Date? = nil, sourceText: String? = nil, sortOrder: Int = 0,
         recurrenceRuleRaw: String? = nil, recurrenceIntervalDays: Int = 0,
         remindBeforeMinutes: Int = 0,
         qrCodePayload: String? = nil, qrCodeImageData: Data? = nil, attachmentImageData: Data? = nil,
         skillPathID: UUID? = nil, skillStageIndex: Int = 0,
         isSkillPractice: Bool = false, skillPracticeMinutes: Int = 0,
         calendarItemIdentifier: String? = nil,
         arrivalReminderAt: Date? = nil, arrivalTransportRaw: String? = nil) {
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
        self.skillPathID = skillPathID
        self.skillStageIndex = skillStageIndex
        self.isSkillPractice = isSkillPractice
        self.skillPracticeMinutes = skillPracticeMinutes
        self.calendarItemIdentifier = calendarItemIdentifier
        self.arrivalReminderAt = arrivalReminderAt
        self.arrivalTransportRaw = arrivalTransportRaw
    }

    /// 到站提醒的交通方式；未知时按 unknown 走时间兜底，不会丢提醒
    var arrivalTransportKind: TripArrivalSchedule.TransportKind {
        get { TripArrivalSchedule.transportKind(fromRaw: arrivalTransportRaw) }
        set { arrivalTransportRaw = newValue.rawValue }
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
        // custom 分支在原实现里等价于 dayInterval 自身的 max(1, customDays)，统一走 Core 换算
        recurrenceRule.dayInterval(customDays: recurrenceIntervalDays)
    }

    var recurrenceSummaryText: String {
        if recurrenceRule == .custom {
            return L10n.tr("每\(max(1, recurrenceIntervalDays))天")
        }
        return L10n.tr(recurrenceRule.rawValue)
    }

    /// 计算下一次循环的截止时间（薄适配：判定逻辑在 AssistantCore.RecurrencePlan，可单测）
    func nextRecurringDueDate(from referenceDate: Date = .now) -> Date {
        RecurrencePlan.nextDueDate(
            dueAt: dueAt,
            rule: recurrenceRule,
            customDays: recurrenceIntervalDays,
            referenceDate: referenceDate
        )
    }

    /// 全库最小 sortOrder：新建待办以 min-1 插入置顶。
    /// sortBy + fetchLimit 1 把排序与取最小值下推给 SQLite，
    /// 不再为算一个最小值把整表（含全部已完成历史与附件字段）物化到主线程。
    static func minimumSortOrder(in context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.sortOrder, order: .forward)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.sortOrder ?? 0
    }

    /// 完成该事项。如果为周期性待办，会自动生成下一期活跃待办事项并插入 ModelContext
    @discardableResult
    func markAsCompleted(in context: ModelContext) -> TodoItem? {
        self.status = .done
        TodoNotificationManager.shared.cancelNotification(for: self.id)
        // 行程已完成，到站清点提醒随之撤销（递归事项下一期不继承该提醒）
        Task { @MainActor in TripArrivalService.shared.cancelAllReminders(for: self.id) }

        // 学习路径的练习打卡：写一条流水，供连续天数与投入时长统计重算
        if isSkillPractice, let pathID = skillPathID {
            context.insert(
                SkillPracticeLog(
                    pathID: pathID,
                    stageIndex: skillStageIndex,
                    practicedAt: .now,
                    minutes: skillPracticeMinutes
                )
            )
        }

        guard isRecurring else { return nil }

        // 下一期字段清单在 AssistantCore.RecurrencePlan（纯函数、有回归测试）；
        // RecurringTodoRecord 的 init 参数全必填，漏登记新字段会编译失败。
        guard let next = RecurrencePlan.nextFields(from: RecurringTodoRecord(item: self), referenceDate: .now) else {
            return nil
        }
        let nextItem = TodoItem(
            type: TodoType(rawValue: next.typeRaw) ?? .general,
            status: TodoStatus(rawValue: next.statusRaw) ?? .active,
            title: next.title,
            detail: next.detail,
            pickupCode: next.pickupCode,
            courier: next.courier,
            station: next.station,
            location: next.location,
            dueAt: next.dueAt,
            sourceText: next.sourceText,
            sortOrder: next.sortOrder,
            recurrenceRuleRaw: next.recurrenceRuleRaw,
            recurrenceIntervalDays: next.recurrenceIntervalDays,
            remindBeforeMinutes: next.remindBeforeMinutes,
            // 学习路径关联必须随下一期一起复制，否则打卡一次后新待办会脱离原路径
            skillPathID: next.skillPathID,
            skillStageIndex: next.skillStageIndex,
            isSkillPractice: next.isSkillPractice,
            skillPracticeMinutes: next.skillPracticeMinutes
        )
        context.insert(nextItem)
        TodoNotificationManager.shared.scheduleNotification(for: nextItem)
        return nextItem
    }

    /// 同步清除外部集成（本地通知与系统日历关联日程，防止孤儿日程）
    func cleanupExternalIntegrations() {
        TodoNotificationManager.shared.cancelNotification(for: self.id)
        Task { @MainActor in
            TripArrivalService.shared.cancelAllReminders(for: self.id)
        }
        if let calId = self.calendarItemIdentifier {
            Task { @MainActor in
                try? await CalendarAgendaService.shared.deleteEvent(identifier: calId)
            }
        }
    }
}

/// TodoItem → Core 纯函数输入快照的薄适配；这里登记的字段即随下一期复制的全集。
extension RecurringTodoRecord {
    init(item: TodoItem) {
        self.init(
            typeRaw: item.type.rawValue,
            statusRaw: item.status.rawValue,
            title: item.title,
            detail: item.detail,
            pickupCode: item.pickupCode,
            courier: item.courier,
            station: item.station,
            location: item.location,
            dueAt: item.dueAt,
            sourceText: item.sourceText,
            sortOrder: item.sortOrder,
            recurrenceRuleRaw: item.recurrenceRuleRaw,
            recurrenceIntervalDays: item.recurrenceIntervalDays,
            remindBeforeMinutes: item.remindBeforeMinutes,
            skillPathID: item.skillPathID,
            skillStageIndex: item.skillStageIndex,
            isSkillPractice: item.isSkillPractice,
            skillPracticeMinutes: item.skillPracticeMinutes
        )
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
