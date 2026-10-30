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
        // 刷新共享快照前先将扩展侧（小组件/手表）积压的指令落库，防止用旧库状态覆盖乐观快照
        _ = drainAndApplyPendingCommands(context: context)
        let snapshot = buildSnapshot(context: context)
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func buildSnapshot(context: ModelContext) -> WidgetSnapshot {
        // 谓词化只拉活跃待办，避免每次刷新都把全部已完成历史物化到主线程
        let activeRaw = TodoStatus.active.rawValue
        let activeItems = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        ))) ?? []
        var sorted = activeItems
        TodoPriority.sort(&sorted)

        let topEntries = sorted.prefix(6).map(Self.entry(for:))

        let parcelEntries = sorted
            .filter { $0.type == .parcel || $0.type == .returnParcel }
            .filter { !($0.pickupCode ?? "").isEmpty }
            .map(Self.entry(for:))

        let todayExpense = Self.todayExpenseTotal(context: context) ?? 0
        let todayPractice = Self.todayPracticeEntry(context: context)

        return WidgetSnapshot(
            topTodos: Array(topEntries),
            parcels: parcelEntries,
            todayExpense: todayExpense,
            todayPractice: todayPractice,
            generatedAt: .now
        )
    }

    /// 今日练习快照：只取最近活跃（最近打卡优先，否则最近开始）的进行中路径。
    /// 锁屏/桌面组件据此显示连续天数与今日是否打卡，点击深链到学习路径页。
    /// 按 pathID 谓词定向取数，不再为一条路径全表物化 stages/todos/logs。
    private static func todayPracticeEntry(context: ModelContext) -> WidgetPracticeEntry? {
        let activeRaw = SkillPathStatus.active.rawValue
        let paths = ((try? context.fetch(FetchDescriptor<SkillPath>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        ))) ?? [])
        guard let path = paths.sorted(by: {
            ($0.lastPracticedAt ?? $0.startedAt) > ($1.lastPracticedAt ?? $1.startedAt)
        }).first else { return nil }

        let pid = path.id
        let logs = (try? context.fetch(FetchDescriptor<SkillPracticeLog>(
            predicate: #Predicate { $0.pathID == pid }
        ))) ?? []
        let stages = (try? context.fetch(FetchDescriptor<SkillStage>(
            predicate: #Predicate { $0.pathID == pid }
        ))) ?? []
        let currentStage = stages.first { $0.index == path.currentStageIndex }

        return WidgetPracticeEntry(
            pathID: path.id,
            title: path.title,
            stageName: currentStage?.name ?? "进行中",
            streakDays: SkillPathManager.streakDays(from: logs.map { $0.practicedAt }, now: .now),
            minutesThisWeek: SkillPathManager.minutesThisWeek(from: logs, now: .now),
            weeklyTargetMinutes: path.weeklyMinutes,
            isPracticedToday: logs.contains { Calendar.current.isDateInToday($0.practicedAt) }
        )
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

    /// 今日弹性支出合计。查询抛错返回 nil：调用方据此省略或提示，
    /// 不能把「读失败」当成「今天没花钱」报给用户。
    private static func todayExpenseTotal(context: ModelContext) -> Double? {
        // 只取今日窗口内的账单，避免全量历史支出记录物化到主线程
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
        )
        guard let records = try? context.fetch(descriptor) else { return nil }
        return records
            .filter { !$0.isIncome }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - 指令对账（扩展 → 主应用）

    /// 单条指令的处理结果。只有 `.applied` / `.consumed` 才允许从队列摘除，
    /// `.retry` 必须留在队首——否则「报已成功、实际没落库」会再次发生。
    private enum CommandOutcome {
        /// 已产生变更，`context.save()` 成功后才能摘除
        case applied
        /// 重试也不会成功（条目已不存在、输入无法解析），直接摘除
        case consumed
        /// 暂时失败（查询异常等），保留在队首等下次对账
        case retry
    }

    private struct CommandBatchResult {
        var consumed = 0
        var hitRetry = false
    }

    @discardableResult
    private func drainAndApplyPendingCommands(context: ModelContext) -> Bool {
        var didProcess = false
        // 有界兜底循环：对账期间扩展可能继续入队，处理完再重读一轮
        for _ in 0..<3 {
            let commands = WidgetSnapshotStore.drainCommands()
            guard !commands.isEmpty else { break }
            let batch = processCommandBatch(commands, context: context)
            if batch.consumed > 0 { didProcess = true }
            // 队首指令暂时失败或整批都没推进：本轮到此为止，留待下次对账，不空转重试
            if batch.hitRetry || batch.consumed == 0 { break }
        }
        return didProcess
    }

    func processPendingCommands(context: ModelContext) {
        if drainAndApplyPendingCommands(context: context) {
            refreshSnapshot(context: context)
        }
    }

    /// 逐条执行队首指令，返回本次可以安全摘除的条数。
    /// 落库成功后才裁剪队列；`save` 失败则回滚并保留整批，下次对账重来。
    @discardableResult
    private func processCommandBatch(_ commands: [WidgetCommand], context: ModelContext) -> CommandBatchResult {
        var result = CommandBatchResult()
        for command in commands {
            switch apply(command, context: context) {
            case .applied, .consumed:
                result.consumed += 1
            case .retry:
                result.hitRetry = true
                // 已处理成功的队首前缀照常落库并摘除；失败的那条及之后的指令全部保留
                if result.consumed > 0, !commit(result.consumed, context: context) {
                    result.consumed = 0
                }
                return result
            }
        }
        if result.consumed > 0, !commit(result.consumed, context: context) {
            result.consumed = 0
        }
        return result
    }

    private func commit(_ count: Int, context: ModelContext) -> Bool {
        do {
            try context.save()
        } catch {
            context.rollback()
            print("⚠️ [WidgetSync] 指令落库失败，保留队列待下次对账: \(error.localizedDescription)")
            return false
        }
        WidgetSnapshotStore.removeFirst(count)
        return true
    }

    private func apply(_ command: WidgetCommand, context: ModelContext) -> CommandOutcome {
        switch command {
        case .completeTodo(let id):
            return completeInDB(id: id, context: context)

        case .snoozeTodo(let id, let minutes):
            return snoozeInDB(id: id, minutes: minutes, tomorrow: false, context: context)

        case .snoozeTomorrow(let id):
            return snoozeInDB(id: id, minutes: 0, tomorrow: true, context: context)

        case .toggleDeparture(let id, let isChecked):
            return toggleDepartureInDB(id: id, isChecked: isChecked, context: context)

        case .quickAddExpense(let text):
            return quickAddExpenseInDB(text: text, context: context)

        case .quickAddTodo(let text):
            return quickAddTodoInDB(text: text, context: context) == nil ? .consumed : .applied
        }
    }

    @discardableResult
    private func completeInDB(id: UUID, context: ModelContext) -> CommandOutcome {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        let items: [TodoItem]
        do {
            items = try context.fetch(descriptor)
        } catch {
            // 查询失败不能当成「待办不存在/已完成」：那会收起实时活动，而这条打勾指令随后也被摘除
            print("⚠️ [WidgetSync] 完成指令查询失败，保留队列重试: \(error.localizedDescription)")
            return .retry
        }
        guard let item = items.first, item.status == .active else {
            // 已在主应用完成过：仅确保实时活动收起（主进程长寿，允许异步收尾）
            Task { await PickupActivityHelper.endActivity(for: id) }
            return .consumed
        }
        item.markAsCompleted(in: context)
        Task { await PickupActivityHelper.markCompleted(todoID: id) }
        return .applied
    }

    @discardableResult
    private func snoozeInDB(id: UUID, minutes: Int, tomorrow: Bool, context: ModelContext) -> CommandOutcome {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        let item: TodoItem
        do {
            guard let found = try context.fetch(descriptor).first else { return .consumed }
            item = found
        } catch {
            print("⚠️ [WidgetSync] 稍后提醒查询失败，保留队列重试: \(error.localizedDescription)")
            return .retry
        }
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
        return .applied
    }

    @discardableResult
    private func toggleDepartureInDB(id: UUID, isChecked: Bool, context: ModelContext) -> CommandOutcome {
        let descriptor = FetchDescriptor<DepartureCheckItem>(predicate: #Predicate { $0.id == id })
        let checkItem: DepartureCheckItem
        do {
            guard let found = try context.fetch(descriptor).first else { return .consumed }
            checkItem = found
        } catch {
            print("⚠️ [WidgetSync] 出门清点查询失败，保留队列重试: \(error.localizedDescription)")
            return .retry
        }
        checkItem.isChecked = isChecked
        Task { await DepartureActivityHelper.setChecked(itemID: id, isChecked: isChecked) }
        return .applied
    }

    @discardableResult
    private func quickAddExpenseInDB(text: String, context: ModelContext) -> CommandOutcome {
        let results = ExpenseNaturalLanguageParser.parseMulti(text)
        guard !results.isEmpty else { return .consumed }
        for result in results {
            let record = ExpenseRecord(
                amount: result.amount,
                isIncome: result.isIncome,
                category: result.category,
                title: result.title,
                rawText: text,
                date: result.date,
                currencyCode: result.isForeignCurrency ? result.currency.rawValue : nil,
                foreignAmount: result.foreignAmount,
                exchangeRateToCNY: result.exchangeRateToCNY
            )
            context.insert(record)
        }
        return .applied
    }

    @discardableResult
    private func quickAddTodoInDB(text: String, context: ModelContext) -> TodoItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = TodoNaturalLanguageParser.parse(trimmed)
        let minOrder = TodoItem.minimumSortOrder(in: context)
        let item = TodoItem(
            type: parsed.type,
            status: .active,
            title: parsed.title.isEmpty ? trimmed : parsed.title,
            dueAt: parsed.dueAt,
            sourceText: trimmed,
            sortOrder: minOrder - 1,
            recurrenceRuleRaw: parsed.recurrenceRule == .none ? nil : parsed.recurrenceRule.rawValue,
            recurrenceIntervalDays: parsed.customIntervalDays
        )
        context.insert(item)
        TodoNotificationManager.shared.scheduleNotification(for: item)
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
        let results = ExpenseNaturalLanguageParser.parseMulti(text)
        guard !results.isEmpty else { return nil }
        var totalExpense = 0.0
        var titles: [String] = []
        for result in results {
            let record = ExpenseRecord(
                amount: result.amount,
                isIncome: result.isIncome,
                category: result.category,
                title: result.title,
                rawText: text,
                date: result.date,
                currencyCode: result.isForeignCurrency ? result.currency.rawValue : nil,
                foreignAmount: result.foreignAmount,
                exchangeRateToCNY: result.exchangeRateToCNY
            )
            context.insert(record)
            if !result.isIncome { totalExpense += result.amount }
            titles.append(result.title)
        }
        try? context.save()
        refreshSnapshot(context: context)

        if results.count == 1, let result = results.first {
            let amountText = String(format: result.amount.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", result.amount)
            if result.isIncome {
                return "已入账收入 \(amountText) 元：\(result.title)"
            }
            return "已记账 \(amountText) 元（\(result.category.displayName)）" + Self.todayExpenseSuffix(context: context)
        }
        let totalText = String(format: totalExpense.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", totalExpense)
        return "已记账 \(results.count) 笔合计 \(totalText) 元（\(titles.joined(separator: "、"))）" + Self.todayExpenseSuffix(context: context)
    }

    /// 「今日累计支出」后缀；读账本失败时整段省略，不回退成 0 元。
    private static func todayExpenseSuffix(context: ModelContext) -> String {
        guard let total = todayExpenseTotal(context: context) else { return "" }
        let text = String(format: total.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", total)
        return "，今日累计支出 \(text) 元"
    }

    func handleQuickAddTodo(text: String) async -> String? {
        let context = Persistence.shared.mainContext
        guard let item = quickAddTodoInDB(text: text, context: context) else { return nil }
        try? context.save()
        refreshSnapshot(context: context)
        if let due = item.dueAt {
            let dueStr = due.formatted(date: .abbreviated, time: .shortened)
            return "已创建待办「\(item.title)」，将于 \(dueStr) 提醒你"
        }
        return "已创建待办：\(item.title)"
    }

    func handleQueryParcels() async -> String {
        let context = Persistence.shared.mainContext
        let activeRaw = TodoStatus.active.rawValue
        let parcelRaw = TodoType.parcel.rawValue
        let returnParcelRaw = TodoType.returnParcel.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw && ($0.typeRaw == parcelRaw || $0.typeRaw == returnParcelRaw) }
        )
        let items = ((try? context.fetch(descriptor)) ?? [])
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

    func handleQueryBudget() async -> String {
        let context = Persistence.shared.mainContext
        guard let dayTotal = Self.todayExpenseTotal(context: context) else {
            return "暂时读不到账本，算不出今天的安心花额度，稍后再问我一次吧。"
        }
        let dayText = String(format: dayTotal.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", dayTotal)
        let monthlyBudget = BudgetSettings.monthlyBudget
        if monthlyBudget > 0 {
            // 只取本月 + 昨日 + 本周一至今，避免全表物化到主线程
            let window = ExpenseRecordWindow.budgetWindow()
            let windowStart = window.start
            let windowEnd = window.end
            let descriptor = FetchDescriptor<ExpenseRecord>(
                predicate: #Predicate { $0.date >= windowStart && $0.date < windowEnd }
            )
            let records: [ExpenseRecord]
            do {
                records = try context.fetch(descriptor)
            } catch {
                return "暂时读不到账本，算不出今天的安心花额度，稍后再问我一次吧。"
            }
            let fixedMonthlyTotal = RecurringExpenseManager.shared.monthlyEstimatedTotal
            let input = SafeToSpendCalculator.inputFromRecords(
                records: records,
                fixedMonthlyTotal: fixedMonthlyTotal,
                monthlyBudget: monthlyBudget
            )
            let result = SafeToSpendCalculator.compute(input: input)
            let safeText = String(format: "%.0f", result.safeToSpendToday)
            let remainMonthText = String(format: "%.0f", max(0, result.remainingThisMonth))
            if result.isTodayOverspent {
                let overText = String(format: "%.0f", result.todayOverspentAmount)
                return "今日已支出 \(dayText) 元（超支 \(overText) 元），本月剩余 ¥\(remainMonthText)。适度收一收，慢慢花。"
            } else {
                return "今日已支出 \(dayText) 元，今天还能安心花 ¥\(safeText)，本月剩余 ¥\(remainMonthText)。放宽心，慢慢花。"
            }
        }
        return "今日已累计支出 \(dayText) 元。放宽心，慢慢花。"
    }

    func handleQueryTodayTodos() async -> String {
        let context = Persistence.shared.mainContext
        let activeRaw = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        )
        var items = (try? context.fetch(descriptor)) ?? []
        TodoPriority.sort(&items)
        if items.isEmpty {
            return "今日待办已全部清空，好好休息吧！"
        }
        let topCount = min(3, items.count)
        let titles = items.prefix(topCount).map(\.displayConciseTitle).joined(separator: "、")
        var reply = "今日待办共有 \(items.count) 项。优先处理：\(titles)"
        if items.count > topCount {
            reply += " 等"
        }
        return reply
    }
}
