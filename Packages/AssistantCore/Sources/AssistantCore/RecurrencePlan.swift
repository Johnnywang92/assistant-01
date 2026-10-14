import Foundation

/// 周期性待办「母记录」的关键字段快照（纯函数输入，由 app 侧 TodoItem 填充）。
/// 注意：init 全部参数必填、无默认值——给待办新增需随下一期复制的字段时，
/// 编译器会强制这里与 NextOccurrenceFields、app 适配器同步更新，防止静默漏字段
/// （历史上曾漏复制技能路径四项，导致打卡后待办脱离学习路径）。
public struct RecurringTodoRecord: Hashable, Sendable {
    public var typeRaw: String
    public var statusRaw: String
    public var title: String
    public var detail: String?
    public var pickupCode: String?
    public var courier: String?
    public var station: String?
    public var location: String?
    public var dueAt: Date?
    public var sourceText: String?
    public var sortOrder: Int
    public var recurrenceRuleRaw: String?
    public var recurrenceIntervalDays: Int
    public var remindBeforeMinutes: Int
    public var skillPathID: UUID?
    public var skillStageIndex: Int
    public var isSkillPractice: Bool
    public var skillPracticeMinutes: Int

    public init(
        typeRaw: String,
        statusRaw: String,
        title: String,
        detail: String?,
        pickupCode: String?,
        courier: String?,
        station: String?,
        location: String?,
        dueAt: Date?,
        sourceText: String?,
        sortOrder: Int,
        recurrenceRuleRaw: String?,
        recurrenceIntervalDays: Int,
        remindBeforeMinutes: Int,
        skillPathID: UUID?,
        skillStageIndex: Int,
        isSkillPractice: Bool,
        skillPracticeMinutes: Int
    ) {
        self.typeRaw = typeRaw
        self.statusRaw = statusRaw
        self.title = title
        self.detail = detail
        self.pickupCode = pickupCode
        self.courier = courier
        self.station = station
        self.location = location
        self.dueAt = dueAt
        self.sourceText = sourceText
        self.sortOrder = sortOrder
        self.recurrenceRuleRaw = recurrenceRuleRaw
        self.recurrenceIntervalDays = recurrenceIntervalDays
        self.remindBeforeMinutes = remindBeforeMinutes
        self.skillPathID = skillPathID
        self.skillStageIndex = skillStageIndex
        self.isSkillPractice = isSkillPractice
        self.skillPracticeMinutes = skillPracticeMinutes
    }
}

/// 下一期活跃待办应有的字段（纯函数输出，字段名与 RecurringTodoRecord 一一对应）。
public struct NextOccurrenceFields: Hashable, Sendable {
    public var typeRaw: String
    /// 下一期恒为活跃；母记录已完成（statusRaw == "done"）不影响本值。
    public var statusRaw: String
    public var title: String
    public var detail: String?
    public var pickupCode: String?
    public var courier: String?
    public var station: String?
    public var location: String?
    /// 已滚动到参考时间之后的下一次截止时间
    public var dueAt: Date?
    public var sourceText: String?
    public var sortOrder: Int
    public var recurrenceRuleRaw: String?
    public var recurrenceIntervalDays: Int
    public var remindBeforeMinutes: Int
    public var skillPathID: UUID?
    public var skillStageIndex: Int
    public var isSkillPractice: Bool
    public var skillPracticeMinutes: Int

    public init(
        typeRaw: String,
        statusRaw: String,
        title: String,
        detail: String?,
        pickupCode: String?,
        courier: String?,
        station: String?,
        location: String?,
        dueAt: Date?,
        sourceText: String?,
        sortOrder: Int,
        recurrenceRuleRaw: String?,
        recurrenceIntervalDays: Int,
        remindBeforeMinutes: Int,
        skillPathID: UUID?,
        skillStageIndex: Int,
        isSkillPractice: Bool,
        skillPracticeMinutes: Int
    ) {
        self.typeRaw = typeRaw
        self.statusRaw = statusRaw
        self.title = title
        self.detail = detail
        self.pickupCode = pickupCode
        self.courier = courier
        self.station = station
        self.location = location
        self.dueAt = dueAt
        self.sourceText = sourceText
        self.sortOrder = sortOrder
        self.recurrenceRuleRaw = recurrenceRuleRaw
        self.recurrenceIntervalDays = recurrenceIntervalDays
        self.remindBeforeMinutes = remindBeforeMinutes
        self.skillPathID = skillPathID
        self.skillStageIndex = skillStageIndex
        self.isSkillPractice = isSkillPractice
        self.skillPracticeMinutes = skillPracticeMinutes
    }
}

/// 周期性待办完成后生成下一期的纯计算。
/// 下沉自 TodoItem.nextRecurringDueDate / markAsCompleted 的复制清单。
public enum RecurrencePlan {

    /// 下一期恒为活跃状态的原始值（对应 app 侧 TodoStatus.active.rawValue）。
    public static let activeStatusRaw = "active"

    /// 解析存储的重复规则原始值；未知值按「不重复」处理（与 TodoItem.recurrenceRule getter 一致）。
    public static func rule(fromRaw raw: String?) -> TodoRecurrenceRule {
        guard let raw else { return .none }
        return TodoRecurrenceRule(rawValue: raw) ?? .none
    }

    /// 计算下一次截止时间。
    /// 逻辑与原实现等价：基准日逐周期前进，直到严格晚于参考时间；
    /// 母记录无 dueAt 时从参考时间起加一个周期；周期天数 <=0（不重复）时返回参考时间。
    public static func nextDueDate(
        dueAt: Date?,
        rule: TodoRecurrenceRule,
        customDays: Int,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date {
        let days = rule.dayInterval(customDays: customDays)
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

    /// 由母待办算出下一期应有的字段；非周期（规则为空/不重复/未知）返回 nil，即不生成下一期。
    public static func nextFields(
        from parent: RecurringTodoRecord,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> NextOccurrenceFields? {
        let rule = rule(fromRaw: parent.recurrenceRuleRaw)
        guard rule != .none else { return nil }

        let nextDue = nextDueDate(
            dueAt: parent.dueAt,
            rule: rule,
            customDays: parent.recurrenceIntervalDays,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return NextOccurrenceFields(
            typeRaw: parent.typeRaw,
            statusRaw: activeStatusRaw,
            title: parent.title,
            detail: parent.detail,
            pickupCode: parent.pickupCode,
            courier: parent.courier,
            station: parent.station,
            location: parent.location,
            dueAt: nextDue,
            sourceText: parent.sourceText,
            sortOrder: parent.sortOrder,
            recurrenceRuleRaw: parent.recurrenceRuleRaw,
            recurrenceIntervalDays: parent.recurrenceIntervalDays,
            remindBeforeMinutes: parent.remindBeforeMinutes,
            skillPathID: parent.skillPathID,
            skillStageIndex: parent.skillStageIndex,
            isSkillPractice: parent.isSkillPractice,
            skillPracticeMinutes: parent.skillPracticeMinutes
        )
    }
}
