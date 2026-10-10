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

    /// 检查是否有到达周期的家务，若到达则自动生成待办，并联动智能家居
    public func evaluatePeriodicHabits() async {
        let descriptor = FetchDescriptor<PeriodicHabit>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let habits = try? context.fetch(descriptor) else { return }

        for habit in habits {
            if habit.nextDueAt <= .now {
                let housework = TodoType.housework.rawValue
                let active = TodoStatus.active.rawValue
                let title = "周期家务：\(habit.title)"

                // 查重：避免同一家务重复生成未完成的待办
                let existing = (try? context.fetch(FetchDescriptor<TodoItem>(
                    predicate: #Predicate { $0.title == title && $0.typeRaw == housework && $0.statusRaw == active }
                ))) ?? []

                if existing.isEmpty {
                    let todo = TodoItem(
                        type: .housework,
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

    /// 注册每天的服药本地通知日程
    public func scheduleMedicationReminders() {
        let descriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let plans = try? context.fetch(descriptor) else { return }

        for plan in plans {
            for timePoint in plan.dailyTimePoints {
                let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                let hour = parts[0]
                let minute = parts[1]

                let content = UNMutableNotificationContent()
                content.title = "💊 服药提醒"
                content.body = "该吃药了：\(plan.medName)（\(plan.dosage)）"
                content.sound = .default

                var dateComponents = DateComponents()
                dateComponents.hour = hour
                dateComponents.minute = minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                let reqId = "med-\(plan.id.uuidString)-\(hour)-\(minute)"
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reqId, content: content, trigger: trigger))
            }
        }
    }
}
