import AssistantCore
import Foundation
import SwiftData

/// 待办单次 O(N) 极速分类存储，避免视图每次刷新时连续发起十余次全量数组 filter
struct TodoClassification {
    var active: [TodoItem] = []
    var review: [TodoItem] = []
    var done: [TodoItem] = []
    var recurring: [TodoItem] = []
    var overdue: [TodoItem] = []

    var todayTodos: [TodoItem] = []
    var generals: [TodoItem] = []
    var works: [TodoItem] = []
    var parcels: [TodoItem] = []
    var returnParcels: [TodoItem] = []
    var medications: [TodoItem] = []
    var chargings: [TodoItem] = []
    var houseworks: [TodoItem] = []
    var subscriptions: [TodoItem] = []
    var expiries: [TodoItem] = []
    var anniversaries: [TodoItem] = []
    var passwordTodos: [TodoItem] = []
    var vehicleTodos: [TodoItem] = []
    var parentingTodos: [TodoItem] = []
    var petTodos: [TodoItem] = []
    var others: [TodoItem] = []

    var doneGenerals: [TodoItem] = []
    var doneRecurring: [TodoItem] = []
    var doneParcels: [TodoItem] = []
    var doneLife: [TodoItem] = []
    var doneAlerts: [TodoItem] = []

    /// 初始化：活跃与已完成分开喂入，避免调用方先拼一个上万条的合并数组。
    /// 两段在数据源上本就互斥（`@Query` 用 `statusRaw != "done"` 与 `== "done"` 分开订阅），
    /// 拆开喂与合并喂的分桶结果完全一致，但省掉一次 O(N) 数组拷贝。
    init(active activeItems: [TodoItem], done doneItems: [TodoItem]) {
        let now = Date.now
        for item in activeItems {
            switch item.status {
            case .pendingReview:
                review.append(item)
            case .active:
                active.append(item)
                if let due = item.dueAt, due < now {
                    overdue.append(item)
                }
            case .done:
                break
            }
        }
        for item in doneItems {
            switch item.status {
            case .done:
                done.append(item)
                if item.isRecurring { doneRecurring.append(item) }
                switch item.type {
                case .general, .event, .travelBooking: doneGenerals.append(item)
                case .skillLearning: doneGenerals.append(item)
                case .parcel, .returnParcel: doneParcels.append(item)
                case .medication, .housework, .exercise, .charging: doneLife.append(item)
                case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare: doneAlerts.append(item)
                default: break
                }
            case .pendingReview, .active:
                break
            }
        }
        // 先对所有活跃待办按“紧急性 60% + 重要性 40%”进行单次全局排序，逾期事项按截止时间升序
        TodoPriority.sort(&active)
        overdue.sort { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        // 各活跃分组直接沿用已排好序的 active 流进行分发，天然保持正确优先级，避免 15 次冗余全量排序
        for item in active {
            if Self.isTodayItem(item, cal: cal, startOfToday: startOfToday) {
                todayTodos.append(item)
            }
            if item.isRecurring { recurring.append(item) }
            switch item.type {
            case .general, .event, .travelBooking: generals.append(item)
            case .skillLearning: generals.append(item)
            case .work: works.append(item)
            case .parcel: parcels.append(item)
            case .returnParcel: returnParcels.append(item)
            case .medication: medications.append(item)
            case .charging: chargings.append(item)
            case .housework, .exercise: houseworks.append(item)
            case .subscription, .bill: subscriptions.append(item)
            case .itemExpiry: expiries.append(item)
            case .anniversary: anniversaries.append(item)
            case .passwordSecurity: passwordTodos.append(item)
            case .vehicleCare: vehicleTodos.append(item)
            case .childVaccine, .childGrowth, .childMilestone, .childHealth: parentingTodos.append(item)
            case .pet: petTodos.append(item)
            case .other: others.append(item)
            default: others.append(item)
            }
        }
    }

    static func isTodayItem(_ item: TodoItem, cal: Calendar, startOfToday: Date) -> Bool {
        if let override = item.reminderOverrideAt {
            if cal.isDateInToday(override) || override < startOfToday {
                return true
            }
        }
        if let due = item.dueAt {
            return cal.isDateInToday(due) || due < startOfToday
        }
        return cal.isDateInToday(item.createdAt)
    }
}
