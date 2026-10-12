import Foundation
import SwiftData
import AssistantCore

/// 学习路径状态
public enum SkillPathStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case completed
    case archived

    public var id: String { rawValue }

    public var displayName: String {
        let raw: String = switch self {
        case .active: "进行中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .archived: "已归档"
        }
        return L10n.tr(raw)
    }

    public var icon: String {
        switch self {
        case .active: "figure.walk"
        case .paused: "pause.circle"
        case .completed: "checkmark.seal.fill"
        case .archived: "archivebox"
        }
    }
}

/// 一条完整的技能学习路径。与阶段、待办之间用 `id` 软关联，
/// 避免 SwiftData 关系变更带来的迁移风险，也便于备份导出。
@Model
public final class SkillPath {
    public var id: UUID
    public var title: String
    public var categoryRaw: String
    /// 用可观察行为描述的目标
    public var goal: String
    public var weeklyMinutes: Int
    public var totalWeeks: Int
    public var startedAt: Date
    public var statusRaw: String
    public var currentStageIndex: Int
    /// 最近一次练习打卡日期（用于计算连续天数）
    public var lastPracticedAt: Date?
    public var practiceStreakDays: Int
    /// 累计练习次数
    public var practiceCount: Int

    public init(
        title: String,
        category: SkillCategory,
        goal: String,
        weeklyMinutes: Int,
        totalWeeks: Int,
        startedAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.categoryRaw = category.rawValue
        self.goal = goal
        self.weeklyMinutes = weeklyMinutes
        self.totalWeeks = totalWeeks
        self.startedAt = startedAt
        self.statusRaw = SkillPathStatus.active.rawValue
        self.currentStageIndex = 0
        self.lastPracticedAt = nil
        self.practiceStreakDays = 0
        self.practiceCount = 0
    }

    public var category: SkillCategory {
        get { SkillCategory(rawValue: categoryRaw) ?? .generic }
        set { categoryRaw = newValue.rawValue }
    }

    public var status: SkillPathStatus {
        get { SkillPathStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    public var totalDays: Int { max(7, totalWeeks * 7) }

    public var plannedEndAt: Date {
        Calendar.current.date(byAdding: .day, value: totalDays, to: startedAt) ?? startedAt
    }

    /// 距开始已过去的天数（至少 1 天）
    public func elapsedDays(now: Date = .now) -> Int {
        let days = Calendar.current.dateComponents([.day], from: startedAt, to: now).day ?? 0
        return max(1, days + 1)
    }
}

/// 学习路径中的一个阶段。只展开当前阶段，通关后解锁下一阶段。
@Model
public final class SkillStage {
    public var id: UUID
    public var pathID: UUID
    public var index: Int
    public var name: String
    /// 可观察的通关标准
    public var acceptance: String
    public var plannedDays: Int
    public var isUnlocked: Bool
    public var isCompleted: Bool
    public var completedAt: Date?
    /// 该阶段尚未展开时的任务模板（JSON）。解锁后才写成真实待办。
    public var tasksJSON: String

    public init(
        pathID: UUID,
        index: Int,
        name: String,
        acceptance: String,
        plannedDays: Int,
        isUnlocked: Bool,
        tasks: [PlannedSkillTask] = []
    ) {
        self.id = UUID()
        self.pathID = pathID
        self.index = index
        self.name = name
        self.acceptance = acceptance
        self.plannedDays = plannedDays
        self.isUnlocked = isUnlocked
        self.isCompleted = false
        self.completedAt = nil
        self.tasksJSON = (try? JSONEncoder().encode(tasks).base64EncodedString()) ?? ""
    }

    /// 阶段内尚未展开的任务模板
    public var plannedTasks: [PlannedSkillTask] {
        guard let data = Data(base64Encoded: tasksJSON),
              let tasks = try? JSONDecoder().decode([PlannedSkillTask].self, from: data) else { return [] }
        return tasks
    }
}

/// 一次练习打卡记录，用于统计连续天数与本周投入
@Model
public final class SkillPracticeLog {
    public var id: UUID
    public var pathID: UUID
    public var stageIndex: Int
    public var practicedAt: Date
    public var minutes: Int

    public init(pathID: UUID, stageIndex: Int, practicedAt: Date = .now, minutes: Int = 0) {
        self.id = UUID()
        self.pathID = pathID
        self.stageIndex = stageIndex
        self.practicedAt = practicedAt
        self.minutes = minutes
    }
}
