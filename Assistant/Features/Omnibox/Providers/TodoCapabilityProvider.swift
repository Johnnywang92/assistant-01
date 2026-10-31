import AssistantCore
import Foundation
import SwiftData

struct TodoCapabilityProvider: CapabilityProvider {
    let moduleID = "todo"
    let capabilities: [ActionCapability] = [.todoCreate, .todoUpdate, .todoComplete, .todoCancel, .reminderSnooze]
    let undoKinds: [ActionUndoToken.Kind] = [.todo]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        switch action.capability {
        case .todoCreate:
            return try executeCreate(action, prior: prior, context: context)
        case .todoUpdate:
            return try executeUpdate(action, context: context)
        case .todoComplete:
            return try executeComplete(action, context: context)
        case .todoCancel:
            return try executeCancel(action, context: context)
        case .reminderSnooze:
            return try executeSnooze(action, context: context)
        default:
            throw OmniboxError.invalidParams("todo 模块不认识该动作")
        }
    }

    // MARK: todo.create

    private func executeCreate(
        _ action: PlannedAction,
        prior: [UUID: String],
        context: ModelContext
    ) throws -> ActionExecutionOutcome {
        guard let title = action.params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw OmniboxError.invalidParams("待办标题为空")
        }
        let detail = action.params["detail"]
        let dueAt = Self.resolveDueAt(params: action.params)

        // 图片票务结构化识别的富参数（类型/取票码/站点/到站提醒）；缺省时保持旧行为
        let type = TodoType(rawValue: action.params["typeRaw"] ?? "") ?? .general
        let arrivalReminderAt: Date? = {
            guard action.params["travelPickupMode"] != "pickup",
                  let iso = action.params["arrivalAtISO"],
                  let date = OmniboxPlanner.parseParamDate(iso), date > .now else { return nil }
            return date
        }()

        let todo = TodoItem(
            type: type,
            title: title,
            detail: detail,
            pickupCode: action.params["pickupCode"],
            station: action.params["station"],
            location: action.params["location"],
            dueAt: dueAt,
            sourceText: action.params["sourceText"] ?? "Omnibox投喂",
            qrCodePayload: action.params["qrCodePayload"],
            arrivalReminderAt: arrivalReminderAt,
            arrivalTransportRaw: action.params["arrivalTransport"]
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

    private func executeUpdate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
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

    private func executeComplete(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
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

    private func executeCancel(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
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

    private func executeSnooze(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
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

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard case .todo = token.kind else { return }
        guard let id = token.recordID else { return }
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        if let todo = try context.fetch(descriptor).first {
            if let snapshot = token.decodeSnapshot() {
                // 修改式回滚：按快照还原旧值
                if let title = snapshot["title"] { todo.title = title }
                if let detail = snapshot["detail"] { todo.detail = detail }
                if let statusRaw = snapshot["statusRaw"], let status = TodoStatus(rawValue: statusRaw) {
                    todo.status = status
                    LifeEventTodoLink.syncTask(for: todo, in: context)
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
        try context.save()
    }
}
