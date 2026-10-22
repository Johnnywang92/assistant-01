import Foundation

/// 药物与饮食的时效对应关系（如饭前空腹、随餐、饭后防胃刺激等）
public enum MedicationMealRelation: Hashable, Equatable, Sendable, Codable {
    case unrestricted             // 不限时间，空腹饱腹均可
    case beforeMeal(minutes: Int) // 饭前服用（默认提前 30 分钟，吸收更充分）
    case withMeal                 // 随餐同服（减少胃刺激或随脂类吸收）
    case afterMeal(minutes: Int)  // 饭后服用（默认饭后 15~30 分钟，保护胃黏膜）
    case bedtime                  // 睡前服用（如特定降压、安神或降脂药）

    public var rawValue: String {
        switch self {
        case .unrestricted:
            return "unrestricted"
        case .beforeMeal(let min):
            return "beforeMeal_\(min)"
        case .withMeal:
            return "withMeal"
        case .afterMeal(let min):
            return "afterMeal_\(min)"
        case .bedtime:
            return "bedtime"
        }
    }

    public init(rawValue: String) {
        if rawValue == "unrestricted" {
            self = .unrestricted
        } else if rawValue.hasPrefix("beforeMeal_") {
            let minStr = rawValue.replacingOccurrences(of: "beforeMeal_", with: "")
            self = .beforeMeal(minutes: Int(minStr) ?? 30)
        } else if rawValue == "withMeal" {
            self = .withMeal
        } else if rawValue.hasPrefix("afterMeal_") {
            let minStr = rawValue.replacingOccurrences(of: "afterMeal_", with: "")
            self = .afterMeal(minutes: Int(minStr) ?? 30)
        } else if rawValue == "bedtime" {
            self = .bedtime
        } else {
            self = .afterMeal(minutes: 30)
        }
    }

    public var displayName: String {
        switch self {
        case .unrestricted:
            return "不限时间"
        case .beforeMeal(let min):
            return "饭前 \(min) 分钟"
        case .withMeal:
            return "随餐同服"
        case .afterMeal(let min):
            return "饭后 \(min) 分钟"
        case .bedtime:
            return "睡前服用"
        }
    }

    public var shortTitle: String {
        switch self {
        case .unrestricted: return "不限"
        case .beforeMeal: return "饭前"
        case .withMeal: return "随餐"
        case .afterMeal: return "饭后"
        case .bedtime: return "睡前"
        }
    }

    public var iconName: String {
        switch self {
        case .unrestricted: return "clock"
        case .beforeMeal: return "fork.knife.circle"
        case .withMeal: return "fork.knife"
        case .afterMeal: return "cup.and.saucer.fill"
        case .bedtime: return "moon.stars.fill"
        }
    }
}

/// 饮食与药物相互作用冲突类型
public enum DietaryConflictType: String, Equatable, Sendable, CaseIterable {
    case caffeine = "咖啡因相互作用"       // 咖啡/奶茶/浓茶
    case grapefruit = "西柚代谢酶抑制"     // 葡萄柚/西柚汁抑制肝脏 CYP3A4 酶
    case dairyCalcium = "高钙/乳制品络合" // 牛奶/酸奶阻碍特定抗生素吸收
    case alcohol = "酒精双硫仑/肝损伤"     // 酒精与头孢类/甲硝唑等严重反应

    public var icon: String {
        switch self {
        case .caffeine: return "cup.and.saucer.fill"
        case .grapefruit: return "exclamationmark.triangle.fill"
        case .dairyCalcium: return "takeoutbag.and.cup.and.straw.fill"
        case .alcohol: return "wineglass.fill"
        }
    }

    public var warningColorName: String {
        switch self {
        case .caffeine: return "orange"
        case .grapefruit: return "red"
        case .dairyCalcium: return "purple"
        case .alcohol: return "red"
        }
    }
}

/// 传入纯逻辑分析器的用药计划快照
public struct MedicationPlanSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let medName: String
    public let dosage: String
    public let mealRelation: MedicationMealRelation
    /// 每日计划时点字符串，如 ["08:00", "13:00", "20:00"]
    public let dailyTimePoints: [String]
    public let notes: String?
    public let isEnabled: Bool
    public let lastTakenAt: Date?

    public init(
        id: String = UUID().uuidString,
        medName: String,
        dosage: String,
        mealRelation: MedicationMealRelation = .afterMeal(minutes: 30),
        dailyTimePoints: [String] = ["08:00", "13:00", "20:00"],
        notes: String? = nil,
        isEnabled: Bool = true,
        lastTakenAt: Date? = nil
    ) {
        self.id = id
        self.medName = medName
        self.dosage = dosage
        self.mealRelation = mealRelation
        self.dailyTimePoints = dailyTimePoints
        self.notes = notes
        self.isEnabled = isEnabled
        self.lastTakenAt = lastTakenAt
    }
}

/// 传入纯逻辑分析器的近期用餐快照
public struct RecentMealSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let foodName: String
    public let calories: Double
    public let hasCaffeine: Bool
    public let hasGrapefruit: Bool
    public let hasDairy: Bool
    public let hasAlcohol: Bool

    public init(
        id: String = UUID().uuidString,
        date: Date,
        foodName: String,
        calories: Double = 0,
        hasCaffeine: Bool = false,
        hasGrapefruit: Bool = false,
        hasDairy: Bool = false,
        hasAlcohol: Bool = false
    ) {
        self.id = id
        self.date = date
        self.foodName = foodName
        self.calories = calories
        self.hasCaffeine = hasCaffeine
        self.hasGrapefruit = hasGrapefruit
        self.hasDairy = hasDairy
        self.hasAlcohol = hasAlcohol
    }
}

/// 当前时刻用药状态推断
public enum MedicationTimingStatus: Equatable, Sendable {
    /// 尚未到点，按原定时间正常等待
    case pendingScheduled(scheduledTime: Date)
    /// 到了预设计划时间，但未检测到进餐，智能顺延等待进餐防伤胃
    case waitingForMeal(scheduledTime: Date, reason: String)
    /// 刚刚用餐完毕，正处于餐后最佳服药黄金窗口
    case primeTimePostMeal(recommendedTime: Date, windowEnd: Date, mealName: String)
    /// 到了饭前服用时刻，建议服药后半小时内进餐
    case primeTimeBeforeMeal(recommendedTime: Date, suggestMealBy: Date)
    /// 今日该时段已打卡服用
    case takenToday(takenAt: Date)
    /// 存在明确饮食冲突（如咖啡因、西柚或牛奶），建议推迟服药
    case conflictAlert(type: DietaryConflictType, detail: String, safeTimeAfter: Date)
    /// 超过服药时间较长，给出漏服安全补服指引（切勿加倍服用）
    case missedDoseWarning(scheduledTime: Date, catchUpAdvice: String, canCatchUpNow: Bool)

    public var badgeTitle: String {
        switch self {
        case .pendingScheduled: return "待服用"
        case .waitingForMeal: return "等餐顺延中"
        case .primeTimePostMeal: return "餐后黄金用药窗口"
        case .primeTimeBeforeMeal: return "饭前最佳用药窗口"
        case .takenToday: return "今日已服"
        case .conflictAlert: return "饮食时效冲突"
        case .missedDoseWarning: return "漏服补服提醒"
        }
    }

    public var colorName: String {
        switch self {
        case .pendingScheduled: return "blue"
        case .waitingForMeal: return "orange"
        case .primeTimePostMeal: return "green"
        case .primeTimeBeforeMeal: return "green"
        case .takenToday: return "secondary"
        case .conflictAlert: return "red"
        case .missedDoseWarning: return "orange"
        }
    }
}

/// 自适应分析结果详情
public struct MedicationTimingEvaluation: Equatable, Sendable {
    public let planID: String
    public let medName: String
    public let dosage: String
    public let status: MedicationTimingStatus
    public let adaptiveNotificationTime: Date?
    public let headline: String
    public let actionTip: String
    public let isUrgent: Bool

    public init(
        planID: String,
        medName: String,
        dosage: String,
        status: MedicationTimingStatus,
        adaptiveNotificationTime: Date? = nil,
        headline: String,
        actionTip: String,
        isUrgent: Bool = false
    ) {
        self.planID = planID
        self.medName = medName
        self.dosage = dosage
        self.status = status
        self.adaptiveNotificationTime = adaptiveNotificationTime
        self.headline = headline
        self.actionTip = actionTip
        self.isUrgent = isUrgent
    }
}
