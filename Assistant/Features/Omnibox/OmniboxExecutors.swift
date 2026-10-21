import AssistantCore
import Foundation
import SwiftData

// MARK: - 执行器：模块只认识 Capability，不认识输入形态

/// 执行器注册与派发。新增模块 = 在 `execute` 中注册一个分支并实现 undo，Omnibox 其余部分零改动。
@MainActor
enum OmniboxExecutor {

    /// 按拓扑序执行一批已勾选动作，返回逐条回执
    static func executeTopologically(
        _ actions: [PlannedAction],
        context: ModelContext
    ) -> [ActionExecutionOutcome] {
        var outcomes: [ActionExecutionOutcome] = []
        var priorResults: [UUID: String] = [:]
        var done = Set<UUID>()

        var pending = actions
        while !pending.isEmpty {
            var progressed = false
            pending = pending.filter { action in
                let depsSatisfied = action.dependsOn.allSatisfy { done.contains($0) }
                if depsSatisfied {
                    defer {
                        done.insert(action.id)
                        progressed = true
                    }
                    let outcome = execute(action, prior: priorResults, context: context)
                    if let summary = outcome.summary { priorResults[action.id] = summary }
                    outcomes.append(outcome)
                    return false
                }
                return true
            }
            if !progressed {
                // 依赖环兜底：剩余动作直接顺序执行
                for action in pending {
                    let outcome = execute(action, prior: priorResults, context: context)
                    if let summary = outcome.summary { priorResults[action.id] = summary }
                    outcomes.append(outcome)
                }
                break
            }
        }
        return outcomes
    }

    /// 执行单个动作
    static func execute(
        _ action: PlannedAction,
        prior: [UUID: String],
        context: ModelContext
    ) -> ActionExecutionOutcome {
        do {
            switch action.capability {
            case .expenseCreate:
                return try executeExpense(action, context: context)
            case .expenseUpdate:
                return try executeExpenseUpdate(action, context: context)
            case .todoCreate:
                return try executeTodo(action, prior: prior, context: context)
            case .todoUpdate:
                return try executeTodoUpdate(action, context: context)
            case .todoComplete:
                return try executeTodoComplete(action, context: context)
            case .todoCancel:
                return try executeTodoCancel(action, context: context)
            case .reminderSnooze:
                return try executeReminderSnooze(action, context: context)
            case .memoInbox:
                return try executeMemo(action, context: context)
            case .queryLookup:
                return executeLookup(action, context: context)
            }
        } catch {
            return ActionExecutionOutcome(
                id: action.id, action: action, summary: "",
                undo: OmniboxUndoToken(kind: .memoLine),
                errorText: error.localizedDescription
            )
        }
    }

    // MARK: expense.create

    private static func executeExpense(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        guard let amountValue = Double(action.params["amount"] ?? ""), amountValue > 0 else {
            throw OmniboxError.invalidParams("金额无效")
        }
        let isIncome = action.params["isIncome"] == "true"
        let category = ExpenseCategory(rawValue: action.params["category"] ?? "") ?? (isIncome ? .otherIncome : .other)
        let title = action.params["title"]?.isEmpty == false ? action.params["title"]! : L10n.tr("投喂记录")
        // 短信/订单截图里识别出的交易时间优先于当前时间
        let transactionDate = OmniboxPlanner.parseParamDate(action.params["dateISO"]) ?? .now
        let currencyCode: String? = {
            guard let code = action.params["currency"],
                  let cur = ExpenseCurrency(rawValue: code),
                  cur != .cny else { return nil }
            return cur.rawValue
        }()
        let foreignAmount = currencyCode != nil ? Double(action.params["foreignAmount"] ?? "") : nil
        let exchangeRate = currencyCode != nil ? Double(action.params["exchangeRate"] ?? "") : nil

        let record = ExpenseRecord(
            amount: amountValue,
            isIncome: isIncome,
            category: category,
            title: title,
            rawText: action.summary,
            date: transactionDate,
            currencyCode: currencyCode,
            foreignAmount: foreignAmount,
            exchangeRateToCNY: exchangeRate
        )
        context.insert(record)
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .expenseCreate, params: action.params),
            undo: OmniboxUndoToken(kind: .expense, recordID: record.id)
        )
    }

    // MARK: expense.update

    private static func executeExpenseUpdate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["title"] ?? ""
        let amt = Double(action.params["amount"] ?? "")
        let resolution = ActionTargetResolver.resolveExpense(mention: mention, amount: amt, context: context)
        guard case .unique(let record) = resolution else {
            switch resolution {
            case .ambiguous(let candidates):
                throw OmniboxError.invalidParams("匹配到多笔账目（\(candidates.map(\.displayTitle).joined(separator: " / "))），请明确指定")
            case .none, .unique:
                throw OmniboxError.invalidParams("未找到与「\(mention)」相符的账单记录")
            }
        }

        let snapshot: [String: String] = [
            "title": record.title,
            "amount": String(record.amount),
            "categoryRaw": record.categoryRaw
        ]
        let snapshotData = ActionUndoToken.makeSnapshotData(snapshot)

        if let newAmt = Double(action.params["newAmount"] ?? action.params["amount"] ?? ""), newAmt > 0 {
            record.amount = newAmt
        }
        if let newTitle = action.params["newTitle"], !newTitle.isEmpty {
            record.title = newTitle
        }
        if let newCat = action.params["newCategory"], let cat = ExpenseCategory(rawValue: newCat) {
            record.category = cat
        }
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "已修改账目：\(record.title) ¥\(String(format: "%.2f", record.amount))",
            undo: OmniboxUndoToken(kind: .expense, recordID: record.id, snapshotJSON: snapshotData)
        )
    }

    // MARK: todo.create

    private static func executeTodo(
        _ action: PlannedAction,
        prior: [UUID: String],
        context: ModelContext
    ) throws -> ActionExecutionOutcome {
        guard let title = action.params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw OmniboxError.invalidParams("待办标题为空")
        }
        let detail = action.params["detail"]
        let dueAt = Self.resolveDueAt(params: action.params)

        let todo = TodoItem(
            type: .general,
            title: title,
            detail: detail,
            dueAt: dueAt,
            sourceText: "Omnibox投喂"
        )
        context.insert(todo)
        TodoNotificationManager.shared.scheduleNotification(for: todo)
        try context.save()

        var displayParams = action.params
        if displayParams["title"]?.isEmpty == false {
            displayParams["title"] = title
        }
        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .todoCreate, params: displayParams),
            undo: OmniboxUndoToken(kind: .todo, recordID: todo.id)
        )
    }

    // MARK: todo.update

    private static func executeTodoUpdate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["title"] ?? ""
        let resolution = ActionTargetResolver.resolveTodo(mention: mention, context: context)
        guard case .unique(let todo) = resolution else {
            switch resolution {
            case .ambiguous(let candidates):
                throw OmniboxError.invalidParams("匹配到多项待办（\(candidates.map(\.displayTitle).joined(separator: " / "))），请明确指定")
            case .none, .unique:
                throw OmniboxError.invalidParams("未找到与「\(mention)」相符的待办事项")
            }
        }

        var snapshot: [String: String] = [
            "title": todo.title,
            "detail": todo.detail ?? "",
            "statusRaw": todo.status.rawValue
        ]
        if let due = todo.dueAt {
            snapshot["dueAtISO"] = ISO8601DateFormatter().string(from: due)
        }
        let snapshotData = ActionUndoToken.makeSnapshotData(snapshot)

        if let newTitle = action.params["newTitle"], !newTitle.isEmpty {
            todo.title = newTitle
        }
        if let newDetail = action.params["newDetail"] {
            todo.detail = newDetail
        }
        if let due = Self.resolveDueAt(params: action.params) {
            todo.dueAt = due
            TodoNotificationManager.shared.scheduleNotification(for: todo)
        }
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "已修改待办：\(todo.title)",
            undo: OmniboxUndoToken(kind: .todo, recordID: todo.id, snapshotJSON: snapshotData)
        )
    }

    // MARK: todo.complete

    private static func executeTodoComplete(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["title"] ?? ""
        let resolution = ActionTargetResolver.resolveTodo(mention: mention, context: context)
        guard case .unique(let todo) = resolution else {
            switch resolution {
            case .ambiguous(let candidates):
                throw OmniboxError.invalidParams("匹配到多项待办（\(candidates.map(\.displayTitle).joined(separator: " / "))），请明确指定")
            case .none, .unique:
                throw OmniboxError.invalidParams("未找到与「\(mention)」相符的待办事项")
            }
        }

        let snapshot: [String: String] = [
            "title": todo.title,
            "statusRaw": todo.status.rawValue
        ]
        let snapshotData = ActionUndoToken.makeSnapshotData(snapshot)

        todo.markAsCompleted(in: context)
        TodoNotificationManager.shared.cancelNotification(for: todo.id)
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "已完成待办：\(todo.title)",
            undo: OmniboxUndoToken(kind: .todo, recordID: todo.id, snapshotJSON: snapshotData)
        )
    }

    // MARK: todo.cancel

    private static func executeTodoCancel(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["title"] ?? ""
        let resolution = ActionTargetResolver.resolveTodo(mention: mention, context: context)
        guard case .unique(let todo) = resolution else {
            switch resolution {
            case .ambiguous(let candidates):
                throw OmniboxError.invalidParams("匹配到多项待办（\(candidates.map(\.displayTitle).joined(separator: " / "))），请明确指定")
            case .none, .unique:
                throw OmniboxError.invalidParams("未找到与「\(mention)」相符的待办事项")
            }
        }

        var snapshot: [String: String] = [
            "title": todo.title,
            "detail": todo.detail ?? "",
            "typeRaw": todo.type.rawValue,
            "statusRaw": todo.status.rawValue
        ]
        if let due = todo.dueAt {
            snapshot["dueAtISO"] = ISO8601DateFormatter().string(from: due)
        }
        let snapshotData = ActionUndoToken.makeSnapshotData(snapshot)

        todo.cleanupExternalIntegrations()
        context.delete(todo)
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "已取消待办：\(snapshot["title"] ?? "")",
            undo: OmniboxUndoToken(kind: .todo, recordID: todo.id, snapshotJSON: snapshotData)
        )
    }

    // MARK: reminder.snooze

    private static func executeReminderSnooze(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["title"] ?? ""
        let resolution = ActionTargetResolver.resolveTodo(mention: mention, context: context)
        guard case .unique(let todo) = resolution else {
            switch resolution {
            case .ambiguous(let candidates):
                throw OmniboxError.invalidParams("匹配到多项提醒（\(candidates.map(\.displayTitle).joined(separator: " / "))），请明确指定")
            case .none, .unique:
                throw OmniboxError.invalidParams("未找到与「\(mention)」相符的提醒事项")
            }
        }

        var snapshot: [String: String] = [
            "title": todo.title
        ]
        if let due = todo.dueAt {
            snapshot["dueAtISO"] = ISO8601DateFormatter().string(from: due)
        }
        let snapshotData = ActionUndoToken.makeSnapshotData(snapshot)

        let duration = action.params["duration"] ?? "1小时"
        let baseDate = todo.dueAt ?? .now
        let newDate: Date
        if duration.contains("10分") {
            newDate = Calendar.current.date(byAdding: .minute, value: 10, to: baseDate) ?? baseDate
        } else if duration.contains("明早") || duration.contains("明天") {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            newDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        } else {
            newDate = Calendar.current.date(byAdding: .hour, value: 1, to: baseDate) ?? baseDate
        }

        todo.dueAt = newDate
        TodoNotificationManager.shared.scheduleNotification(for: todo)
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "已顺延提醒至 \(newDate.formatted(date: .abbreviated, time: .shortened))：\(todo.title)",
            undo: OmniboxUndoToken(kind: .todo, recordID: todo.id, snapshotJSON: snapshotData)
        )
    }

    // MARK: query.lookup

    private static func executeLookup(_ action: PlannedAction, context: ModelContext) -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["query"] ?? "查询事项"
        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "查询完成：\(mention)",
            undo: OmniboxUndoToken(kind: .memoLine)
        )
    }

    /// 支持 dueAtDays（相对今天）+ dueAtTime（HH:mm）组合，兼容绝对 ISO 日期
    static func resolveDueAt(params: [String: String]) -> Date? {
        if let iso = params["dueAtISO"], !iso.isEmpty {
            let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
            for format in formats {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                if let date = formatter.date(from: iso) {
                    return date
                }
            }
        }
        guard let daysText = params["dueAtDays"], let days = Int(daysText), days >= 0 else {
            return nil
        }
        var date = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: .now))
            ?? Calendar.current.startOfDay(for: .now)
        if let time = params["dueAtTime"], !time.isEmpty {
            let comps = time.split(separator: ":").compactMap { Int($0) }
            if comps.count >= 2 {
                date = Calendar.current.date(
                    bySettingHour: comps[0], minute: comps[1], second: 0, of: date
                ) ?? date
            }
        }
        return date
    }

    // MARK: memo.inbox

    private static func executeMemo(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        guard let memo = action.params["memo"]?.trimmingCharacters(in: .whitespacesAndNewlines), !memo.isEmpty else {
            throw OmniboxError.invalidParams("备忘内容为空")
        }
        let line = "[\(Self.memoFormatter.string(from: .now))] \(memo.replacingOccurrences(of: "\n", with: " "))"
        let url = Self.memoFileURL

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = existing.isEmpty ? line + "\n" : existing.ensureTrailingNewline() + line + "\n"
        try updated.write(to: url, atomically: true, encoding: .utf8)

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .memoInbox, params: action.params),
            undo: OmniboxUndoToken(kind: .memoLine, memoLine: line)
        )
    }

    // MARK: - 撤销（回执即事务：每个执行器必须支持 undo）

    /// 按执行逆序撤销一批回执
    static func undo(_ outcomes: [ActionExecutionOutcome], context: ModelContext) throws {
        try undoTokens(outcomes.filter(\.succeeded).map(\.undo), context: context)
    }

    /// 直接撤销令牌列表（历史页跨启动撤销用，令牌来自 OmniboxTransaction.undoJSON）
    static func undoTokens(_ tokens: [OmniboxUndoToken], context: ModelContext) throws {
        for token in tokens.reversed() {
            try undoToken(token, context: context)
        }
    }

    static func undoToken(_ token: OmniboxUndoToken, context: ModelContext) throws {
        switch token.kind {
        case .todo:
            guard let id = token.recordID else { return }
            let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
            if let todo = try context.fetch(descriptor).first {
                if let snapshot = token.decodeSnapshot() {
                    // 修改式回滚：按快照还原旧值
                    if let title = snapshot["title"] { todo.title = title }
                    if let detail = snapshot["detail"] { todo.detail = detail }
                    if let statusRaw = snapshot["statusRaw"], let status = TodoStatus(rawValue: statusRaw) {
                        todo.status = status
                    }
                    if let dueAtISO = snapshot["dueAtISO"] {
                        todo.dueAt = ISO8601DateFormatter().date(from: dueAtISO)
                    } else if snapshot.keys.contains("dueAtISO") {
                        todo.dueAt = nil
                    }
                    TodoNotificationManager.shared.scheduleNotification(for: todo)
                } else {
                    // 创建式回滚：删除新建待办
                    TodoNotificationManager.shared.cancelNotification(for: id)
                    context.delete(todo)
                }
            } else if let snapshot = token.decodeSnapshot() {
                // 已删除待办（取消式）回滚：按快照重新建回
                let title = snapshot["title"] ?? "未命名事项"
                let detail = snapshot["detail"]
                let typeRaw = snapshot["typeRaw"] ?? TodoType.general.rawValue
                let type = TodoType(rawValue: typeRaw) ?? .general
                let recreated = TodoItem(type: type, title: title, detail: detail)
                recreated.id = id
                if let dueAtISO = snapshot["dueAtISO"] {
                    recreated.dueAt = ISO8601DateFormatter().date(from: dueAtISO)
                }
                context.insert(recreated)
                TodoNotificationManager.shared.scheduleNotification(for: recreated)
            }
        case .expense:
            guard let id = token.recordID else { return }
            let descriptor = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.id == id })
            if let record = try context.fetch(descriptor).first {
                if let snapshot = token.decodeSnapshot() {
                    // 修改式回滚
                    if let amtStr = snapshot["amount"], let amt = Double(amtStr) {
                        record.amount = amt
                    }
                    if let title = snapshot["title"] { record.title = title }
                    if let catRaw = snapshot["categoryRaw"], let cat = ExpenseCategory(rawValue: catRaw) {
                        record.category = cat
                    }
                } else {
                    // 创建式回滚
                    context.delete(record)
                }
            }
        case .memoLine:
            guard let line = token.memoLine else { return }
            let url = memoFileURL
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let filtered = existing
                .components(separatedBy: .newlines)
                .filter { $0 != line }
                .joined(separator: "\n")
            try filtered.write(to: url, atomically: true, encoding: .utf8)
        }
        try context.save()
    }

    // MARK: - 收集箱文件（Documents/omnibox_memo.txt）

    static var memoFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("omnibox_memo.txt")
    }

    private static let memoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

enum OmniboxError: LocalizedError {
    case invalidParams(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let reason):
            return L10n.tr("参数不完整：") + reason
        }
    }
}

private extension String {
    func ensureTrailingNewline() -> String {
        hasSuffix("\n") ? self : self + "\n"
    }
}
