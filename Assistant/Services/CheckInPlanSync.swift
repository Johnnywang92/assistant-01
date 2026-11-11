import AssistantCore
import Foundation
import SwiftData

/// 打卡待办 ↔ 打卡计划（用药 / 周期习惯）的状态联动。
///
/// ## 这类待办是「自动关联」出来的
///
/// - 服药待办：`MedicationTodoMaterializer` 每日物化，标题 `服药：药名（HH:mm）`
/// - 运动待办：`HabitAndMedicationScheduler` 按周期生成，标题 `运动：习惯名`
///
/// ## 改动前只有正向通，反向整个缺失
///
/// | 方向 | 含义 | 改动前 |
/// |---|---|---|
/// | 正向 | 打卡动作 → 计划状态更新 + 待办完成 | 通 |
/// | 反向 | 待办完成 → 计划状态更新 | **缺失** |
///
/// 反向缺失有两个用户可见后果：
///
/// 1. **运动待办勾完就复活**：`PeriodicHabit.nextDueAt` 没推进，
///    下一轮前台巡检（`evaluatePeriodicHabits`）又判定「到点了」→ 又生成一条
///    同名待办。用户看到的就是「点了没反应，但记录确实完成了」。
/// 2. **服药待办勾完，组件数字不动**：`MedicationPlan.lastTakenAt` 没更新 →
///    小组件与首页汇总仍显示「待服 N 次」→ 计划状态与待办状态对不上。
///
/// ## 分层
///
/// 规则（标题 ↔ 计划名）全在 Core 的 `CheckInTodoLink`，这里只做 App 侧接线：
/// 按待办类型找到对应计划，回写状态。
///
/// 不标 `@MainActor`：与同族的 `LifeEventTodoLink` 保持同一形状，
/// 这样 `TodoItem.markAsCompleted` 这类非隔离方法可以直接调用。
enum CheckInPlanSync {

    /// 待办完成 → 回写关联计划的打卡状态。
    ///
    /// 无关联（手建待办、标题对不上计划）时静默跳过，不报错、不猜。
    static func syncPlan(for todo: TodoItem, in context: ModelContext) {
        switch todo.type {
        case .medication:
            guard let target = CheckInTodoLink.medicationTarget(fromTodoTitle: todo.title),
                  case .medication(let medName) = target else { return }
            // 写下服药打卡确认时刻：这是「今天到底服了哪几顿」的**唯一精确证据**。
            //
            // 「完成」不等于「服用」：逾期清理里的「算了不做」也会把待办标记为完成。
            // 拿那种完成当证据，放弃的那一顿会被算成「已服」→ 漏服被静默掩盖。
            todo.doseConfirmedAt = .now
            markMedicationTaken(medName: medName, at: .now, in: context)
        case .exercise:
            guard let target = CheckInTodoLink.habitTarget(fromTodoTitle: todo.title),
                  case .habit(let habitName) = target else { return }
            completeHabit(habitName: habitName, at: .now, in: context)
        default:
            return
        }
    }

    /// 待办恢复为未完成 → 回滚关联计划的打卡状态。
    ///
    /// 不回滚的后果：用户撤销了「已服药」，计划仍显示已服 → 组件与 App 对不上，
    /// 而这类「两边说法不一致」正是最难查的一类静默失败。
    ///
    /// 调用前必须先清掉待办的 `doseConfirmedAt`（本方法会做），
    /// 否则证据里还留着这一条，回滚会把它算回去。
    static func undoPlan(for todo: TodoItem, in context: ModelContext) {
        switch todo.type {
        case .medication:
            guard let target = CheckInTodoLink.medicationTarget(fromTodoTitle: todo.title),
                  case .medication(let medName) = target else { return }
            // 服药打卡确认也要撤销：否则证据里还留着这一顿，
            // 组件会把没吃的那顿算成已服。
            todo.doseConfirmedAt = nil
            undoMedication(medName: medName, in: context)
        case .exercise:
            guard let target = CheckInTodoLink.habitTarget(fromTodoTitle: todo.title),
                  case .habit(let habitName) = target else { return }
            undoHabit(habitName: habitName, in: context)
        default:
            return
        }
    }

    // MARK: - 服药

    /// 标记某药已服用。
    ///
    /// 同名计划可能有多条（不同剂量 / 不同时点），全部标记——
    /// 与「吃1次」按钮（`MedicineReminderSupport.takeOneDose`）同口径。
    private static func markMedicationTaken(medName: String, at date: Date, in context: ModelContext) {
        let name = medName
        let descriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.medName == name })
        guard let plans = try? context.fetch(descriptor), !plans.isEmpty else { return }
        for plan in plans {
            plan.markTaken(at: date)
        }
    }

    /// 撤销某一顿服药 → 按**剩余证据**回填计划状态。
    ///
    /// 不是简单地清空 `lastTakenAt`：一天多顿的药，撤销 13:00 那顿时
    /// 08:00 那顿的证据还在，计划应回到「已服 08:00」而不是「今天没服过药」。
    private static func undoMedication(medName: String, in context: ModelContext) {
        let name = medName
        let descriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.medName == name })
        guard let plans = try? context.fetch(descriptor), !plans.isEmpty else { return }
        let entries = MedicationDoseEvidence.todayEntries(context: context)
        let latest = MedicationDoseEvidence.latestConfirmedAt(medName: name, entries: entries)
        for plan in plans {
            plan.lastTakenAt = latest
        }
    }

    // MARK: - 运动习惯

    /// 习惯打卡动作（正向）：推进计划到期时间 **+** 完成首页对应的运动待办。
    ///
    /// 「提醒中心」里给习惯打卡时，如果只推进计划、不完成待办，
    /// 首页那条「运动：夜跑」还挂着 → 用户看到「打卡了但待办没完成」。
    static func completeHabit(habit: PeriodicHabit, in context: ModelContext) {
        habit.completeOnce()
        completeHabitTodo(habitName: habit.title, in: context)
    }

    /// 完成首页上属于该习惯的运动待办（标题精确匹配，标题格式取 Core 单一真源）。
    static func completeHabitTodo(habitName: String, in context: ModelContext) {
        let title = CheckInTodoLink.habitTodoTitle(habitName: habitName)
        let exerciseRaw = TodoType.exercise.rawValue
        let activeRaw = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.title == title && $0.typeRaw == exerciseRaw && $0.statusRaw == activeRaw }
        )
        let todos = (try? context.fetch(descriptor)) ?? []
        for todo in todos {
            todo.markAsCompleted(in: context)
        }
    }

    /// 完成一次周期习惯打卡：推进下次到期时间。
    ///
    /// `nextDueAt` 必须推进，否则前台巡检会认为「今天还没到下一个周期」，
    /// 重新生成同一条运动待办——待办刚勾完又冒出来。
    private static func completeHabit(habitName: String, at date: Date, in context: ModelContext) {
        let name = habitName
        let descriptor = FetchDescriptor<PeriodicHabit>(predicate: #Predicate { $0.title == name })
        guard let habits = try? context.fetch(descriptor), !habits.isEmpty else { return }
        for habit in habits {
            habit.completeOnce()
        }
    }

    /// 撤销习惯打卡：回到「今天该打」的状态。
    ///
    /// `nextDueAt` 回到今天的提醒时刻（而不是留在未来），否则这条待办
    /// 再也不会被重新生成，用户撤销后就没法再打了。
    private static func undoHabit(habitName: String, in context: ModelContext) {
        let name = habitName
        let descriptor = FetchDescriptor<PeriodicHabit>(predicate: #Predicate { $0.title == name })
        guard let habits = try? context.fetch(descriptor), !habits.isEmpty else { return }
        let cal = Calendar.current
        let now = Date.now
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 0
        comps.minute = 0
        let todayStart = cal.date(from: comps) ?? now
        for habit in habits {
            habit.lastCompletedAt = nil
            var due = cal.dateComponents([.year, .month, .day], from: todayStart)
            due.hour = habit.preferredHour
            due.minute = habit.preferredMinute
            habit.nextDueAt = cal.date(from: due) ?? todayStart
        }
    }
}
