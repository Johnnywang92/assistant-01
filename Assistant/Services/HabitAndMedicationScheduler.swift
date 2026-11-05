import AssistantCore
import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// 服药提醒的纯值快照：异步对账只捕获 Sendable 值，
/// 不把 SwiftData 模型（`MedicationPlan`）带出主 actor。
private struct MedicationReminderEntry: Sendable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let hour: Int
    let minute: Int
    let planId: String
    let medName: String
}

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

        // 顺序约束（审计 SVC-04）：先一次落库，成功后才排通知 / 发提醒 / 触发 HomeKit。
        // 旧实现边插边排通知、最后 `try? context.save()`，保存失败时通知与智能家居已经触发，
        // 待办却不存在。
        var newTodos: [(todo: TodoItem, habit: PeriodicHabit)] = []
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
                    newTodos.append((todo, habit))
                }
            }
        }
        guard !newTodos.isEmpty else { return }
        guard context.saveReportingFailure({ error in
            print("⚠️ [HabitAndMedication] 周期家务待办落库失败，本轮不排通知: \(error.localizedDescription)")
        }) else { return }

        for (todo, habit) in newTodos {
            TodoNotificationManager.shared.scheduleNotification(for: todo)

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

    /// 注册每天的服药本地通知日程（差量对账，审计 SVC-06）。
    ///
    /// 旧实现：先删掉**所有** `med-` 前缀通知，再全量重加、且 `add` 无 completion——
    /// 删完被系统挂起就丢当天全部服药提醒，失败也完全不可见。
    /// 新实现：
    /// - 只删「不在期望集合」或「内容/触发时刻已变化」的旧通知；
    /// - 只加「缺失或变化」的通知，`add` 用 async 抛错版本把失败记录到日志；
    /// - 服药是通知预算里的最高优先级：名额不足时由 `NotificationBudget` 裁掉低优先级模块。
    public func scheduleMedicationReminders() {
        let descriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let plans = try? context.fetch(descriptor) else { return }

        // 在仍处于主演员隔离时把模型快照为纯值条目：异步对账只接触 Sendable 值，
        // 不把 SwiftData 模型 / ModelContext 带出主 actor（上下文非 Sendable）。
        let entries: [MedicationReminderEntry] = plans.flatMap { plan in
            plan.dailyTimePoints.compactMap { timePoint -> MedicationReminderEntry? in
                let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                let hour = parts[0]
                let minute = parts[1]
                let body: String
                if let notes = plan.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    body = notes
                } else {
                    body = "到点服药提醒，服用后可在今日待办中打卡记录。"
                }
                return MedicationReminderEntry(
                    id: "med-\(plan.id.uuidString)-\(hour)-\(minute)",
                    title: plan.medName,
                    subtitle: "\(timePoint) · \(plan.dosage) · \(plan.mealRelation.displayName)",
                    body: body,
                    hour: hour,
                    minute: minute,
                    planId: plan.id.uuidString,
                    medName: plan.medName
                )
            }
        }
        Task { await Self.reconcileMedicationReminders(entries) }
    }

    /// 服药提醒差量对账（主 actor、async）。只做集合差，不改文案 / 触发时间 / 业务语义。
    private static func reconcileMedicationReminders(_ entries: [MedicationReminderEntry]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let existingMedRequests = pending.filter { $0.identifier.hasPrefix("med-") }
        let existingByID = Dictionary(
            existingMedRequests.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var staleIDs = Set<String>()
        var toAdd: [UNNotificationRequest] = []
        for entry in entries {
            let desired = makeMedicationRequest(for: entry)
            if let existing = existingByID[desired.identifier] {
                if NotificationBudget.fingerprint(of: existing) != NotificationBudget.fingerprint(of: desired) {
                    // 同一 identifier 但内容/触发时刻变了：删旧加新（只这一项，不是全量重排）。
                    staleIDs.insert(desired.identifier)
                    toAdd.append(desired)
                }
            } else {
                toAdd.append(desired)
            }
        }
        let desiredIDs = Set(entries.map(\.id))
        for existing in existingMedRequests where !desiredIDs.contains(existing.identifier) {
            staleIDs.insert(existing.identifier)
        }

        // 先剔除本轮确定要删的旧通知，再按预算申请名额（服药优先级最高，只裁更低优先级）。
        let admission = NotificationBudget.admit(
            pending: pending.filter { !staleIDs.contains($0.identifier) },
            requested: toAdd.map { NotificationBudget.Item(request: $0, priority: .medication) },
            source: "medication"
        )
        let removals = staleIDs.union(admission.evictedIdentifiers)
        if !removals.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(removals))
        }
        for item in admission.accepted {
            do {
                try await center.add(item.request)
            } catch {
                print("⚠️ [HabitAndMedication] 服药提醒排期失败 \(item.request.identifier): \(error.localizedDescription)")
            }
        }
        if !admission.rejected.isEmpty {
            print("⚠️ [HabitAndMedication] 通知预算不足，\(admission.rejected.count) 条服药提醒本轮未排期，下次前台对账重试")
        }
    }

    /// 构造单条服药提醒请求（repeating 日历触发器，文案与触发时刻与原实现完全一致）。
    private static func makeMedicationRequest(for entry: MedicationReminderEntry) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = entry.title
        content.subtitle = entry.subtitle
        content.body = entry.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 0.9
        content.threadIdentifier = "medication-reminders"
        content.userInfo = [
            "type": "medication",
            "planId": entry.planId,
            "medName": entry.medName
        ]

        var dateComponents = DateComponents()
        dateComponents.hour = entry.hour
        dateComponents.minute = entry.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        return UNNotificationRequest(identifier: entry.id, content: content, trigger: trigger)
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
            // 服药待办是每天物化的派生数据：失败只记日志，下次回前台巡检会补建，
            // 但不假装成功（审计 SVC-04）。
            context.saveReportingFailure { error in
                print("⚠️ [HabitAndMedication] 今日服药待办落库失败: \(error.localizedDescription)")
            }
        }
    }
}
