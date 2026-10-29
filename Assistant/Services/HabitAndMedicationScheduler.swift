import AssistantCore
import Foundation
import SwiftData
import UserNotifications

/// 周期性家务检查与服药定时调度器
@MainActor
struct HabitAndMedicationScheduler {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 检查是否有到达周期的运动计划，若到达则自动生成待办
    public func evaluatePeriodicHabits() async {
        let descriptor = FetchDescriptor<PeriodicHabit>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let habits = try? context.fetch(descriptor) else { return }

        for habit in habits {
            if habit.nextDueAt <= .now {
                let exercise = TodoType.exercise.rawValue
                let active = TodoStatus.active.rawValue
                let title = "运动：\(habit.title)"

                // 查重：避免同一家务重复生成未完成的待办
                let existing = (try? context.fetch(FetchDescriptor<TodoItem>(
                    predicate: #Predicate { $0.title == title && $0.typeRaw == exercise && $0.statusRaw == active }
                ))) ?? []

                if existing.isEmpty {
                    let todo = TodoItem(
                        type: .exercise,
                        status: .active,
                        title: title,
                        detail: habit.detail,
                        dueAt: habit.nextDueAt
                    )
                    context.insert(todo)

                    // 联动 HomeKit 智能家居场景（例如触发扫地机打扫）
                    if let scene = habit.triggerHomeKitScene, !scene.isEmpty {
                        _ = await SmartHomeService.shared.triggerScene(named: scene)
                    }

                    NotificationService.post(
                        title: "🧹 家务周期提醒",
                        body: "今天是「\(habit.title)」的日子，请记得完成！",
                        id: "habit-\(habit.id.uuidString)"
                    )
                }
            }
        }
        try? context.save()
    }

    /// 取消指定服药计划的所有定时推送通知
    public static func cancelMedicationReminders(for planId: UUID) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let prefix = "med-\(planId.uuidString)-"
            let stale = requests.filter { $0.identifier.hasPrefix(prefix) }.map { $0.identifier }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
    }

    /// 注册每天的服药本地通知日程（先清理失效或停用的推送，再重新为已启用的计划排期）
    public func scheduleMedicationReminders() {
        let descriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let plans = try? context.fetch(descriptor) else { return }

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            // 清除所有历史服药推送，避免停用或删除后的幽灵通知
            let existingMedIds = requests.filter { $0.identifier.hasPrefix("med-") }.map { $0.identifier }
            if !existingMedIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: existingMedIds)
            }

            for plan in plans {
                for timePoint in plan.dailyTimePoints {
                    let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 2 else { continue }
                    let hour = parts[0]
                    let minute = parts[1]

                    let content = UNMutableNotificationContent()
                    content.title = "💊 服药提醒 · \(plan.mealRelation.shortTitle)"
                    content.body = "该吃药了：\(plan.medName)（\(plan.dosage) · \(plan.mealRelation.displayName)）"
                    content.sound = .default

                    var dateComponents = DateComponents()
                    dateComponents.hour = hour
                    dateComponents.minute = minute

                    let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                    let reqId = "med-\(plan.id.uuidString)-\(hour)-\(minute)"
                    center.add(UNNotificationRequest(identifier: reqId, content: content, trigger: trigger))
                }
            }
        }
    }

    /// 把启用中的服药计划物化为当天首页可勾选的服药待办（幂等）。
    ///
    /// 系统推送是「每天重复」的，待办也必须按天物化，否则会出现
    /// 「药品有提醒、首页待办却常年空」的断层——本方法正是补上这条链路：
    /// 前台巡检每日调用一次，设置提醒的保存路径也即时调用一次。
    /// 去重规则见 AssistantCore.MedicationTodoMaterializer（纯规则、有回归测试）：
    /// 同名未完成条目保留为逾期供补打卡，今日已打卡则不再生成。
    public func ensureTodayMedicationTodos() {
        let descriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let plans = try? context.fetch(descriptor) else { return }
        for plan in plans {
            materializeTodayTodos(for: plan)
        }
    }

    /// 为单条服药计划补建当天待办（不检查 isEnabled，由调用方决定启停语义；
    /// 设置弹层里「关推送、开今日待办」的组合依赖此入口）。
    public func ensureTodayMedicationTodos(for plan: MedicationPlan) {
        materializeTodayTodos(for: plan)
    }

    private func materializeTodayTodos(for plan: MedicationPlan) {
        let now = Date.now
        let cal = Calendar.current
        let medTypeRaw = TodoType.medication.rawValue
        let slots = MedicationTodoMaterializer.daySlots(
            medName: plan.medName,
            dailyTimePoints: plan.dailyTimePoints,
            on: now,
            calendar: cal
        )
        var inserted = false
        for slot in slots {
            let title = slot.title
            let existing = (try? context.fetch(FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.title == title && $0.typeRaw == medTypeRaw }
            ))) ?? []
            let hasActive = existing.contains { $0.status == .active }
            let hasCompletedToday = existing.contains {
                $0.status == .done && ($0.completedAt.map { cal.isDateInToday($0) } ?? false)
            }
            guard MedicationTodoMaterializer.shouldMaterialize(
                hasActive: hasActive,
                hasCompletedToday: hasCompletedToday
            ) else { continue }

            var detailParts = [plan.dosage, plan.mealRelation.displayName]
            if let notes = plan.notes, !notes.isEmpty {
                detailParts.append(notes)
            }
            let todo = TodoItem(
                type: .medication,
                status: .active,
                title: title,
                detail: detailParts.joined(separator: " · "),
                dueAt: slot.dueAt
            )
            context.insert(todo)
            inserted = true
        }
        if inserted {
            try? context.save()
        }
    }
}
