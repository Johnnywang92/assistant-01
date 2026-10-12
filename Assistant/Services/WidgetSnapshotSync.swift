import Foundation
import SwiftData
import WidgetKit

/// 主应用侧快照同步与扩展指令对账：
/// 1. 启动 / 回前台 / 后台 / 通知交互后 → 从 SwiftData 刷新 App Group 快照，桌面与锁屏组件据此渲染；
/// 2. 扩展（小组件勾选 / 手表卡片按钮）产生的指令队列在此按序落库，保证三端最终一致。
@MainActor
final class WidgetSnapshotSyncController: WidgetBridgeAppHook {
    static let shared = WidgetSnapshotSyncController()

    private init() {}

    // MARK: - 快照构建

    func refreshSnapshot(context: ModelContext) {
        let snapshot = buildSnapshot(context: context)
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func buildSnapshot(context: ModelContext) -> WidgetSnapshot {
        let todoDescriptor = FetchDescriptor<TodoItem>()
        let activeItems = ((try? context.fetch(todoDescriptor)) ?? []).filter { $0.status == .active }
        var sorted = activeItems
        TodoPriority.sort(&sorted)

        let topEntries = sorted.prefix(6).map(Self.entry(for:))

        let parcelEntries = sorted
            .filter { $0.type == .parcel || $0.type == .returnParcel }
            .filter { !($0.pickupCode ?? "").isEmpty }
            .map(Self.entry(for:))

        let todayExpense = Self.todayExpenseTotal(context: context)
        let todayPractice = Self.todayPracticeEntry(context: context)

        return WidgetSnapshot(
            topTodos: Array(topEntries),
            parcels: parcelEntries,
            todayExpense: todayExpense,
            todayPractice: todayPractice,
            generatedAt: .now
        )
    }

    /// 今日练习快照：取最近活跃（最近打卡优先，否则最近开始）的进行中路径。
    /// 锁屏/桌面组件据此显示连续天数与今日是否打卡，点击深链到学习路径页。
    private static func todayPracticeEntry(context: ModelContext) -> WidgetPracticeEntry? {
        let paths = ((try? context.fetch(FetchDescriptor<SkillPath>())) ?? [])
            .filter { $0.status == .active }
        guard !paths.isEmpty else { return nil }

        let logs = (try? context.fetch(FetchDescriptor<SkillPracticeLog>())) ?? []
        let progressMap = SkillPathManager.shared.progressByPath(context: context)

        let sorted = paths.sorted { lhs, rhs in
            (lhs.lastPracticedAt ?? lhs.startedAt) > (rhs.lastPracticedAt ?? rhs.startedAt)
        }
        for path in sorted {
            guard let progress = progressMap[path.id] else { continue }
            let pathLogs = logs.filter { $0.pathID == path.id }
            let practicedToday = pathLogs.contains { Calendar.current.isDateInToday($0.practicedAt) }
            return WidgetPracticeEntry(
                pathID: path.id,
                title: path.title,
                stageName: progress.stageName,
                streakDays: progress.streakDays,
                minutesThisWeek: progress.minutesThisWeek,
                weeklyTargetMinutes: progress.weeklyTargetMinutes,
                isPracticedToday: practicedToday
            )
        }
        return nil
    }

    private static func entry(for item: TodoItem) -> WidgetTodoEntry {
        WidgetTodoEntry(
            id: item.id,
            title: item.displayConciseTitle,
            typeRaw: item.typeRaw,
            pickupCode: item.pickupCode,
            stationName: {
                let st = item.station?.trimmingCharacters(in: .whitespacesAndNewlines)
                let loc = item.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (st?.isEmpty == false ? st : loc)
            }(),
            dueAt: item.dueAt,
            isRecurring: item.isRecurring
        )
    }

    private static func todayExpenseTotal(context: ModelContext) -> Double {
        let descriptor = FetchDescriptor<ExpenseRecord>()
        let records = (try? context.fetch(descriptor)) ?? []
        let calendar = Calendar.current
        return records
            .filter { !$0.isIncome && calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - 指令对账（扩展 → 主应用）

    func processPendingCommands(context: ModelContext) {
        var didProcess = false
        // 有界兜底循环：对账期间扩展可能继续入队，处理完再重读一轮
        for _ in 0..<3 {
            let commands = WidgetSnapshotStore.drainCommands()
            guard !commands.isEmpty else { break }
            processCommandBatch(commands, context: context)
            didProcess = true
        }
        if didProcess {
            try? context.save()
            refreshSnapshot(context: context)
        }
    }

    private func processCommandBatch(_ commands: [WidgetCommand], context: ModelContext) {
        for command in commands {
            switch command {
            case .completeTodo(let id):
                completeInDB(id: id, context: context)

            case .snoozeTodo(let id, let minutes):
                snoozeInDB(id: id, minutes: minutes, tomorrow: false, context: context)

            case .snoozeTomorrow(let id):
                snoozeInDB(id: id, minutes: 0, tomorrow: true, context: context)

            case .toggleDeparture(let id, let isChecked):
                toggleDepartureInDB(id: id, isChecked: isChecked, context: context)

            case .quickAddExpense(let text):
                _ = quickAddExpenseInDB(text: text, context: context)

            case .quickAddTodo(let text):
                quickAddTodoInDB(text: text, context: context)
            }
        }
        // 先落库后只摘除已处理前缀；处理期间新入队的指令留在队尾等下轮
        WidgetSnapshotStore.removeProcessedPrefix(commands)
    }

    private func completeInDB(id: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        guard let item = (try? context.fetch(descriptor))?.first, item.status == .active else {
            // 已在主应用完成过：仅确保实时活动收起
            PickupActivityHelper.endActivity(for: id)
            return
        }
        item.markAsCompleted(in: context)
        PickupActivityHelper.markCompleted(todoID: id)
    }

    private func snoozeInDB(id: UUID, minutes: Int, tomorrow: Bool, context: ModelContext) {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        guard let item = (try? context.fetch(descriptor))?.first else { return }
        if tomorrow {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            components.day = (components.day ?? 0) + 1
            components.hour = 9
            components.minute = 0
            item.reminderOverrideAt = Calendar.current.date(from: components)
        } else {
            item.reminderOverrideAt = Date.now.addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
        }
        TodoNotificationManager.shared.scheduleNotification(for: item)
    }

    private func toggleDepartureInDB(id: UUID, isChecked: Bool, context: ModelContext) {
        let descriptor = FetchDescriptor<DepartureCheckItem>(predicate: #Predicate { $0.id == id })
        guard let checkItem = (try? context.fetch(descriptor))?.first else { return }
        checkItem.isChecked = isChecked
        DepartureActivityHelper.setChecked(itemID: id, isChecked: isChecked)
    }

    @discardableResult
    private func quickAddExpenseInDB(text: String, context: ModelContext) -> Double {
        guard let result = ExpenseNaturalLanguageParser.parse(text) else { return 0 }
        let record = ExpenseRecord(
            amount: result.amount,
            isIncome: result.isIncome,
            category: result.category,
            title: result.title,
            rawText: text,
            date: result.date
        )
        context.insert(record)
        WidgetSnapshotStore.applyExpenseLocally(amount: result.isIncome ? 0 : result.amount)
        return result.isIncome ? 0 : result.amount
    }

    @discardableResult
    private func quickAddTodoInDB(text: String, context: ModelContext) -> TodoItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TodoItem(type: .general, title: trimmed)
        context.insert(item)
        return item
    }

    // MARK: - WidgetBridgeAppHook（AppIntent 在主应用进程执行时走这里）

    func handleCompleteTodo(id: UUID) {
        let context = Persistence.shared.mainContext
        completeInDB(id: id, context: context)
        try? context.save()
        refreshSnapshot(context: context)
    }

    func handleSnoozeTodo(id: UUID, minutes: Int) {
        let context = Persistence.shared.mainContext
        snoozeInDB(id: id, minutes: minutes, tomorrow: false, context: context)
        try? context.save()
    }

    func handleSnoozeTomorrow(id: UUID) {
        let context = Persistence.shared.mainContext
        snoozeInDB(id: id, minutes: 0, tomorrow: true, context: context)
        try? context.save()
    }

    func handleToggleDeparture(id: UUID, isChecked: Bool) {
        let context = Persistence.shared.mainContext
        toggleDepartureInDB(id: id, isChecked: isChecked, context: context)
        try? context.save()
    }

    func handleQuickAddExpense(text: String) async -> String? {
        let context = Persistence.shared.mainContext
        guard let result = ExpenseNaturalLanguageParser.parse(text) else { return nil }
        let record = ExpenseRecord(
            amount: result.amount,
            isIncome: result.isIncome,
            category: result.category,
            title: result.title,
            rawText: text,
            date: result.date
        )
        context.insert(record)
        try? context.save()
        refreshSnapshot(context: context)

        let amountText = String(format: result.amount.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", result.amount)
        if result.isIncome {
            return "已入账收入 \(amountText) 元：\(result.title)"
        }
        let dayTotal = Self.todayExpenseTotal(context: context)
        let dayText = String(format: dayTotal.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", dayTotal)
        return "已记账 \(amountText) 元（\(result.category.displayName)），今日累计支出 \(dayText) 元"
    }

    func handleQuickAddTodo(text: String) async -> String? {
        let context = Persistence.shared.mainContext
        guard let item = quickAddTodoInDB(text: text, context: context) else { return nil }
        try? context.save()
        refreshSnapshot(context: context)
        return "已创建待办：\(item.title)"
    }

    func handleQueryParcels() async -> String {
        let context = Persistence.shared.mainContext
        let descriptor = FetchDescriptor<TodoItem>()
        let items = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.status == .active }
            .filter { $0.type == .parcel || $0.type == .returnParcel }
            .filter { !($0.pickupCode ?? "").isEmpty }
        guard !items.isEmpty else { return "目前没有待取的快递" }

        refreshSnapshot(context: context)
        let started = LiveActivityService.startPickupActivity(for: items)
        let codes = items.prefix(5).map { item -> String in
            let place = [item.station, item.location].compactMap { $0 }.first { !$0.isEmpty }
            return place.map { "\($0) \(item.pickupCode!)" } ?? item.pickupCode!
        }
        var reply = "待取快递 \(items.count) 件：" + codes.joined(separator: "、")
        if items.count > 5 { reply += " 等" }
        reply += started ? "，已送上灵动岛与手表 🏝️" : "（实时活动不可用，可在锁屏查看小组件）"
        return reply
    }
}
