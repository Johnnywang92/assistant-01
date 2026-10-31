import AssistantCore
import Foundation
import SwiftData

struct HabitCapabilityProvider: CapabilityProvider {
    let moduleID = "habit"
    let capabilities: [ActionCapability] = [.habitLog]
    let undoKinds: [ActionUndoToken.Kind] = [.habitLog, .medicationLog]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        guard action.capability == .habitLog else {
            throw OmniboxError.invalidParams("habit 模块不认识该动作")
        }
        return try executeHabitLog(action, context: context)
    }

    // MARK: habit.log

    private func executeHabitLog(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let target = action.params["target"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !target.isEmpty else {
            throw OmniboxError.invalidParams("打卡目标不能为空")
        }
        let isMedication = action.params["kind"] == "medication"

        if isMedication {
            let desc = FetchDescriptor<MedicationPlan>()
            let plans = (try? context.fetch(desc)) ?? []
            if let matched = plans.first(where: { $0.medName.localizedStandardContains(target) || target.localizedStandardContains($0.medName) }) {
                let snapshot: [String: String] = [
                    "lastTakenAt": matched.lastTakenAt?.ISO8601Format() ?? ""
                ]
                matched.markTaken()
                try context.save()
                return ActionExecutionOutcome(
                    id: action.id, action: action,
                    summary: OmniboxPlanner.summary(for: .habitLog, params: action.params),
                    undo: OmniboxUndoToken(kind: .medicationLog, recordID: matched.id, snapshotJSON: ActionUndoToken.makeSnapshotData(snapshot))
                )
            } else {
                let newPlan = MedicationPlan(
                    medName: target,
                    dosage: action.params["dosage"] ?? "1次量",
                    dailyTimePoints: ["08:00"],
                    lastTakenAt: .now
                )
                context.insert(newPlan)
                try context.save()
                return ActionExecutionOutcome(
                    id: action.id, action: action,
                    summary: OmniboxPlanner.summary(for: .habitLog, params: action.params),
                    undo: OmniboxUndoToken(kind: .medicationLog, recordID: newPlan.id)
                )
            }
        } else {
            let desc = FetchDescriptor<PeriodicHabit>()
            let habits = (try? context.fetch(desc)) ?? []
            if let matched = habits.first(where: { $0.title.localizedStandardContains(target) || target.localizedStandardContains($0.title) }) {
                let snapshot: [String: String] = [
                    "lastCompletedAt": matched.lastCompletedAt?.ISO8601Format() ?? "",
                    "nextDueAt": matched.nextDueAt.ISO8601Format()
                ]
                matched.completeOnce()
                try context.save()
                return ActionExecutionOutcome(
                    id: action.id, action: action,
                    summary: OmniboxPlanner.summary(for: .habitLog, params: action.params),
                    undo: OmniboxUndoToken(kind: .habitLog, recordID: matched.id, snapshotJSON: ActionUndoToken.makeSnapshotData(snapshot))
                )
            } else {
                let newHabit = PeriodicHabit(title: target, recurrence: .daily)
                newHabit.completeOnce()
                context.insert(newHabit)
                try context.save()
                return ActionExecutionOutcome(
                    id: action.id, action: action,
                    summary: OmniboxPlanner.summary(for: .habitLog, params: action.params),
                    undo: OmniboxUndoToken(kind: .habitLog, recordID: newHabit.id)
                )
            }
        }
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        switch token.kind {
        case .habitLog:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<PeriodicHabit>(predicate: #Predicate { $0.id == id })
                if let habit = try? context.fetch(descriptor).first {
                    if let snap = token.decodeSnapshot(), let prevDateISO = snap["lastCompletedAt"], !prevDateISO.isEmpty {
                        habit.lastCompletedAt = ISO8601DateFormatter().date(from: prevDateISO)
                        if let nextISO = snap["nextDueAt"], let next = ISO8601DateFormatter().date(from: nextISO) {
                            habit.nextDueAt = next
                        }
                    } else {
                        context.delete(habit)
                    }
                }
            }
        case .medicationLog:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.id == id })
                if let plan = try? context.fetch(descriptor).first {
                    if let snap = token.decodeSnapshot(), let prevDateISO = snap["lastTakenAt"], !prevDateISO.isEmpty {
                        plan.lastTakenAt = ISO8601DateFormatter().date(from: prevDateISO)
                    } else {
                        context.delete(plan)
                    }
                }
            }
        default:
            return
        }
        try context.save()
    }
}
