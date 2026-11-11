import AssistantCore
import AppIntents
import WidgetKit

// MARK: - 桌面组件一键服药打卡
//
// 复用既有的 `WidgetCommand.markMedicationTaken` —— 落库链路（写 lastTakenAt、
// 完成今日服药待办、扣减库存）在主 App 侧已经跑通且有回归测试。
// 这里只做「扩展侧入队 + 乐观更新本地快照」两件事。
//
// **乐观更新必须同步汇总数字**：否则用户点了「服药」，桌面仍显示「待服 2 项」，
// 直到用户打开 App 才对上——用户会以为没点上，再点一次。

public struct MarkMedicationTakenIntent: AppIntent {
    public static let title: LocalizedStringResource = "服药打卡"

    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("在桌面组件上标记一剂药已服用")

    @Parameter(title: "用药计划ID")
    public var planID: String

    /// 关联的今日服药待办 ID（可空）
    @Parameter(title: "服药待办ID")
    public var todoID: String?

    public init() {}

    public init(planID: String, todoID: String? = nil) {
        self.planID = planID
        self.todoID = todoID
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = UUID(uuidString: planID) else {
            return .result(dialog: "未找到该用药计划")
        }
        let todo = todoID.flatMap { UUID(uuidString: $0) }
        guard WidgetSnapshotStore.enqueue(.markMedicationTaken(planID: id, todoID: todo)) else {
            return .result(dialog: "没能同步到小助，请打开小助再试")
        }
        WidgetSnapshotStore.applyMedicationTakenLocally(planID: id)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "已记录服药 ✓")
    }
}

// MARK: - 桌面组件一键完成周期打卡

public struct CompleteHabitIntent: AppIntent {
    public static let title: LocalizedStringResource = "完成打卡"

    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("在桌面组件上完成一项运动或周期打卡")

    @Parameter(title: "习惯ID")
    public var habitID: String

    public init() {}

    public init(habitID: String) {
        self.habitID = habitID
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = UUID(uuidString: habitID) else {
            return .result(dialog: "未找到该打卡项")
        }
        guard WidgetSnapshotStore.enqueue(.completeHabit(habitID: id)) else {
            return .result(dialog: "没能同步到小助，请打开小助再试")
        }
        WidgetSnapshotStore.applyHabitCompletedLocally(habitID: id)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "已打卡 ✓")
    }
}
