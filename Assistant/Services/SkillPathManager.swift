import Foundation
import SwiftData
import AssistantCore

/// 学习路径的进度快照
struct SkillProgress {
    var stageIndex: Int
    var stageName: String
    var stageAcceptance: String
    var milestonesDone: Int
    var milestonesTotal: Int
    var practiceCount: Int
    var streakDays: Int
    var minutesThisWeek: Int
    var weeklyTargetMinutes: Int
    var overallRatio: Double

    var milestoneRatio: Double {
        guard milestonesTotal > 0 else { return 0 }
        return Double(milestonesDone) / Double(milestonesTotal)
    }

    /// 本周目标完成度（超过 1 表示超额，展示时截断）
    var weeklyRatio: Double {
        guard weeklyTargetMinutes > 0 else { return 0 }
        return Double(minutesThisWeek) / Double(weeklyTargetMinutes)
    }
}

/// 学习路径中枢：保存草稿、按阶段展开待办、推进阶段并统计进度
@MainActor
final class SkillPathManager {
    static let shared = SkillPathManager()

    private init() {}

    // MARK: - 保存

    /// 保存草稿：写入路径与全部阶段，但只把第 0 阶段展开为真实待办
    @discardableResult
    func save(draft: SkillPathDraft, context: ModelContext) -> SkillPath {
        let path = SkillPath(
            title: draft.title,
            category: draft.category,
            goal: draft.goal,
            weeklyMinutes: draft.weeklyMinutes,
            totalWeeks: draft.totalWeeks
        )
        context.insert(path)

        for stage in draft.stages {
            context.insert(
                SkillStage(
                    pathID: path.id,
                    index: stage.index,
                    name: stage.name,
                    acceptance: stage.acceptance,
                    plannedDays: stage.plannedDays,
                    isUnlocked: stage.index == 0,
                    tasks: stage.tasks
                )
            )
        }

        if let first = draft.stages.first {
            materialize(stageIndex: first.index, tasks: first.tasks, path: path, context: context)
        }
        try? context.save()
        Haptic.success()
        return path
    }

    // MARK: - 展开阶段任务

    /// 把某阶段的任务写成真实待办：里程碑带截止日，练习打卡带重复规则
    private func materialize(
        stageIndex: Int,
        tasks: [PlannedSkillTask],
        path: SkillPath,
        context: ModelContext
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        for (order, task) in tasks.enumerated() {
            var item: TodoItem
            if task.kind == .practice {
                var comps = calendar.dateComponents([.year, .month, .day], from: today)
                comps.hour = 21
                let rule: TodoRecurrenceRule = task.recurrenceDays == 1 ? .daily
                    : (task.recurrenceDays == 2 ? .everyOtherDay : .custom)
                item = TodoItem(
                    type: .skillLearning,
                    status: .active,
                    title: task.title,
                    detail: task.detail,
                    dueAt: calendar.date(from: comps) ?? today,
                    sourceText: "来自学习路径：\(path.title)",
                    sortOrder: order,
                    recurrenceRuleRaw: rule.rawValue,
                    recurrenceIntervalDays: rule == .custom ? task.recurrenceDays : rule.dayInterval(),
                    skillPathID: path.id,
                    skillStageIndex: stageIndex,
                    isSkillPractice: true,
                    skillPracticeMinutes: task.minutes
                )
            } else {
                let base = calendar.date(byAdding: .day, value: task.dayOffset, to: today) ?? today
                var comps = calendar.dateComponents([.year, .month, .day], from: base)
                comps.hour = 20
                item = TodoItem(
                    type: .skillLearning,
                    status: .active,
                    title: task.title,
                    detail: task.detail,
                    dueAt: calendar.date(from: comps) ?? base,
                    sourceText: "来自学习路径：\(path.title)",
                    sortOrder: order,
                    skillPathID: path.id,
                    skillStageIndex: stageIndex,
                    isSkillPractice: false,
                    skillPracticeMinutes: task.minutes
                )
            }
            context.insert(item)
            TodoNotificationManager.shared.scheduleNotification(for: item)
        }
    }

    // MARK: - 推进与统计

    /// 批量推进所有进行中的路径：只做一次全量读取，避免每条路径重复扫描
    func refreshAll(context: ModelContext) {
        let paths = (try? context.fetch(FetchDescriptor<SkillPath>())) ?? []
        guard paths.contains(where: { $0.status == .active }) else { return }

        let stages = (try? context.fetch(FetchDescriptor<SkillStage>())) ?? []
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<SkillPracticeLog>())) ?? []

        for path in paths where path.status == .active {
            refresh(path: path, stages: stages, todos: todos, logs: logs, context: context)
        }
        try? context.save()
    }

    /// 检查当前阶段是否通关；通关则解锁并展开下一阶段
    func refresh(path: SkillPath, context: ModelContext) {
        refresh(
            path: path,
            stages: (try? context.fetch(FetchDescriptor<SkillStage>())) ?? [],
            todos: (try? context.fetch(FetchDescriptor<TodoItem>())) ?? [],
            logs: (try? context.fetch(FetchDescriptor<SkillPracticeLog>())) ?? [],
            context: context
        )
        try? context.save()
    }

    private func refresh(
        path: SkillPath,
        stages allStages: [SkillStage],
        todos allTodos: [TodoItem],
        logs allLogs: [SkillPracticeLog],
        context: ModelContext
    ) {
        let stages = allStages.filter { $0.pathID == path.id }.sorted { $0.index < $1.index }
        let todos = allTodos.filter { $0.skillPathID == path.id }

        for stage in stages where stage.isUnlocked && !stage.isCompleted {
            let milestones = todos.filter { $0.skillStageIndex == stage.index && !$0.isSkillPractice }
            guard !milestones.isEmpty else { continue }
            if milestones.allSatisfy({ $0.status == .done }) {
                stage.isCompleted = true
                stage.completedAt = .now
            }
        }

        if let current = stages.first(where: { $0.index == path.currentStageIndex }), current.isCompleted {
            if let next = stages.first(where: { $0.index == path.currentStageIndex + 1 }) {
                if !next.isUnlocked {
                    next.isUnlocked = true
                    materialize(stageIndex: next.index, tasks: next.plannedTasks, path: path, context: context)
                }
                path.currentStageIndex = next.index
            } else {
                path.status = .completed
            }
        }

        let logs = allLogs.filter { $0.pathID == path.id }
        path.practiceCount = logs.count
        path.practiceStreakDays = Self.streakDays(from: logs.map { $0.practicedAt }, now: .now)
        path.lastPracticedAt = logs.map { $0.practicedAt }.max()
    }

    /// 一次性算出所有路径的进度，供列表使用（避免每行各扫一次全表）
    func progressByPath(context: ModelContext, now: Date = .now) -> [UUID: SkillProgress] {
        let paths = (try? context.fetch(FetchDescriptor<SkillPath>())) ?? []
        let stages = (try? context.fetch(FetchDescriptor<SkillStage>())) ?? []
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let logs = (try? context.fetch(FetchDescriptor<SkillPracticeLog>())) ?? []

        var result: [UUID: SkillProgress] = [:]
        for path in paths {
            result[path.id] = Self.computeProgress(
                path: path,
                stages: stages,
                todos: todos,
                logs: logs,
                now: now
            )
        }
        return result
    }

    func progress(for path: SkillPath, context: ModelContext) -> SkillProgress {
        Self.computeProgress(
            path: path,
            stages: (try? context.fetch(FetchDescriptor<SkillStage>())) ?? [],
            todos: (try? context.fetch(FetchDescriptor<TodoItem>())) ?? [],
            logs: (try? context.fetch(FetchDescriptor<SkillPracticeLog>())) ?? [],
            now: .now
        )
    }

    private static func computeProgress(
        path: SkillPath,
        stages allStages: [SkillStage],
        todos allTodos: [TodoItem],
        logs allLogs: [SkillPracticeLog],
        now: Date
    ) -> SkillProgress {
        let stages = allStages.filter { $0.pathID == path.id }.sorted { $0.index < $1.index }
        let todos = allTodos.filter { $0.skillPathID == path.id }
        let logs = allLogs.filter { $0.pathID == path.id }

        let currentIndex = path.currentStageIndex
        let currentStage = stages.first { $0.index == currentIndex }
        let stageTodos = todos.filter { $0.skillStageIndex == currentIndex && !$0.isSkillPractice }
        let doneCount = stageTodos.filter { $0.status == .done }.count

        let completedStages = stages.filter { $0.isCompleted }.count
        let stageRatio = stageTodos.isEmpty ? 0 : Double(doneCount) / Double(stageTodos.count)
        let overall = stages.isEmpty
            ? 0
            : (Double(completedStages) + stageRatio) / Double(stages.count)

        return SkillProgress(
            stageIndex: currentIndex,
            stageName: currentStage?.name ?? "进行中",
            stageAcceptance: currentStage?.acceptance ?? "",
            milestonesDone: doneCount,
            milestonesTotal: stageTodos.count,
            practiceCount: logs.count,
            streakDays: Self.streakDays(from: logs.map { $0.practicedAt }, now: now),
            minutesThisWeek: Self.minutesThisWeek(from: logs, now: now),
            weeklyTargetMinutes: path.weeklyMinutes,
            overallRatio: min(max(overall, 0), 1)
        )
    }

    /// 最近一周（含今天）的练习分钟数
    static func minutesThisWeek(from logs: [SkillPracticeLog], now: Date) -> Int {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        return logs.filter { $0.practicedAt >= start }.reduce(0) { $0 + $1.minutes }
    }

    /// 连续打卡天数：今天还没打卡时允许从昨天起算，隔一天即断
    static func streakDays(from dates: [Date], now: Date) -> Int {
        let calendar = Calendar.current
        let unique = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !unique.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor = unique.contains(today) ? today : (unique.contains(yesterday) ? yesterday : today)

        var streak = 0
        while unique.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

}
