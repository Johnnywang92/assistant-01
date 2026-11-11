import AssistantCore
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

    public var displayName: String { L10n.tr(rawValue) }

    /// 按周期把日期推进一格（只负责日期分量，提醒时刻由调用方回填）。
    ///
    /// 「每月」必须用日历加一个月，不能折算成固定 30 天：大小月交替时
    /// 30 天会逐月漂移（1/31 加 30 天落到 3/2，而非 2 月末），习惯的到期日
    /// 会越漂越偏。加一个月时目标月天数不足会自动收敛到月末（1/31 → 2/28）。
    /// 其余周期按日历天间隔加天（而非加秒），避免 DST 让时刻漂移一小时。
    public func advance(from date: Date, calendar: Calendar = .current) -> Date? {
        if self == .monthly {
            return calendar.date(byAdding: .month, value: 1, to: date)
        }
        return calendar.date(byAdding: .day, value: dayInterval, to: date)
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
    ///
    /// **同一天重复打卡不重复推进周期**：一天只该推进一次。
    /// 「提醒中心打卡」与「待办完成」两条路径都会调这里，不加守卫会把周期
    /// 一次跳过两格（下次到期直接推到两周后 → 习惯静默停摆）。
    public func completeOnce(now: Date = .now, calendar: Calendar = .current) {
        if let last = lastCompletedAt, calendar.isDate(last, inSameDayAs: now) {
            return
        }
        self.lastCompletedAt = now
        if let next = recurrence.advance(from: now, calendar: calendar) {
            var comps = calendar.dateComponents([.year, .month, .day], from: next)
            comps.hour = preferredHour
            comps.minute = preferredMinute
            self.nextDueAt = calendar.date(from: comps) ?? next
        }
    }
}

/// 充电监控设备类型
public enum ChargeDeviceType: String, Codable, CaseIterable {
    case phone = "手机"
    case watch = "Apple Watch 手表"
    case airpods = "AirPods 耳机"

    public var displayName: String { L10n.tr(rawValue) }

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
    /// 用餐时效关联关系原始值（如 "afterMeal_30", "beforeMeal_30", "withMeal", "bedtime", "unrestricted"）
    public var mealRelationRaw: String = "afterMeal_30"
    /// 今日最近一次服药打卡时间
    public var lastTakenAt: Date?

    public init(
        medName: String,
        dosage: String,
        dailyTimePoints: [String],
        notes: String? = nil,
        mealRelation: MedicationMealRelation = .afterMeal(minutes: 30),
        lastTakenAt: Date? = nil
    ) {
        self.id = UUID()
        self.medName = medName
        self.dosage = dosage
        self.dailyTimePoints = dailyTimePoints
        self.isEnabled = true
        self.notes = notes
        self.mealRelationRaw = mealRelation.rawValue
        self.lastTakenAt = lastTakenAt
    }

    public var mealRelation: MedicationMealRelation {
        get { MedicationMealRelation(rawValue: mealRelationRaw) }
        set { mealRelationRaw = newValue.rawValue }
    }

    /// 转换为纯逻辑分析快照
    public func toSnapshot() -> MedicationPlanSnapshot {
        MedicationPlanSnapshot(
            id: id.uuidString,
            medName: medName,
            dosage: dosage,
            mealRelation: mealRelation,
            dailyTimePoints: dailyTimePoints,
            notes: notes,
            isEnabled: isEnabled,
            lastTakenAt: lastTakenAt
        )
    }

    /// 标记一次服药完成
    public func markTaken(at date: Date = .now) {
        self.lastTakenAt = date
    }
}
