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
            case .foodRecord:
                return try executeFoodRecord(action, context: context)
            case .waterRecord:
                return try executeWaterRecord(action, context: context)
            case .storageRecord:
                return try executeStorageRecord(action, context: context)
            case .habitLog:
                return try executeHabitLog(action, context: context)
            case .anniversaryCreate:
                return try executeAnniversaryCreate(action, context: context)
            case .departureAdd:
                return try executeDepartureAdd(action, context: context)
            case .lifeRecord:
                return try executeLifeRecord(action, context: context)
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

        // 联动餐饮食物热量估算与饮水记录
        if record.category == .food {
            ExpenseCalorieService.handleSaved(record, propose: true, context: context)
            ExpenseWaterService.handleSaved(record, context: context)
        }

        if !record.isIncome {
            BudgetAlertService.shared.evaluateAndNotify(context: context)
        }

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
        if record.category == .food {
            ExpenseWaterService.handleSaved(record, context: context)
        }
        if !record.isIncome {
            BudgetAlertService.shared.evaluateAndNotify(context: context)
        }

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

    /// 查询执行入口：结构化查询意图（汇总/趋势/日程/查找）走 `LifeQueryService` 一句话回答，
    /// 取数全部谓词 + fetchLimit 下推 SQLite（原四表全扫已消除）。
    private static func executeLookup(_ action: PlannedAction, context: ModelContext) -> ActionExecutionOutcome {
        let rawText = (action.params["query"] ?? action.params["target"] ?? "查询事项")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 结构化查询意图：「上周花了多少」「今天有什么安排」「最近消费趋势」「护照放哪了」
        if let insight = QueryInsightEngine.parse(rawText) {
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: LifeQueryService.answer(insight, context: context),
                undo: OmniboxUndoToken(kind: .memoLine)
            )
        }

        // 2. 纯关键词查找（「查找发票」这类无领域词检索）
        let keyword = QueryInsightEngine.extractLookupKeyword(rawText) ?? rawText
        let lookupInsight = QueryInsight(
            domain: .storage,
            kind: .lookup,
            timeRange: .allTime,
            keyword: keyword,
            rawText: rawText
        )
        return ActionExecutionOutcome(
            id: action.id, action: action,
            summary: LifeQueryService.lookup(insight: lookupInsight, context: context),
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

        // 若备忘包含饮食/食物摄入（如“早饭吃了一根玉米和一杯牛奶”），联动分析热量并入库
        var foodRecordID: UUID?
        var foodRecordSummary = ""
        if let estimate = FoodCalorieEstimator.estimateMeal(fromHint: memo) {
            let foodRecord = FoodIntakeRecord(
                date: .now,
                foodName: estimate.displayName,
                foodID: estimate.food.id,
                portion: estimate.portion,
                fullPortionCalories: estimate.fullPortionCalories,
                consumedRatio: 1.0,
                confidence: 0.85,
                isManuallyAdjusted: false,
                source: .manual
            )
            context.insert(foodRecord)
            try? context.save()
            foodRecordID = foodRecord.id
            foodRecordSummary = " · 已录入饮食：\(estimate.displayName)（约 \(Int(estimate.fullPortionCalories))千卡）"
        }

        let baseSummary = OmniboxPlanner.summary(for: .memoInbox, params: action.params)
        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: baseSummary + foodRecordSummary,
            undo: OmniboxUndoToken(kind: .memoLine, recordID: foodRecordID, memoLine: line)
        )
    }

    // MARK: food.record

    private static func executeFoodRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let foodName = action.params["foodName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !foodName.isEmpty else {
            throw OmniboxError.invalidParams("食物名称不能为空")
        }

        let date = OmniboxPlanner.parseParamDate(action.params["dateISO"]) ?? .now
        let parsedCalories = Double(action.params["calories"] ?? "")

        // 优先尝试从 foodName 或原句进行 FoodCalorieEstimator 细致估算
        let estimate = FoodCalorieEstimator.estimateMeal(fromHint: foodName)
            ?? (action.params["rawText"].flatMap { FoodCalorieEstimator.estimateMeal(fromHint: $0) })

        let finalCalories: Double = {
            if let parsedCalories = parsedCalories, parsedCalories > 0 {
                return parsedCalories
            }
            if let estimate = estimate {
                return estimate.fullPortionCalories
            }
            if let matched = FoodCatalog.item(matchingNameStrict: foodName) ?? FoodCatalog.items(matchingName: foodName).first {
                return Double(matched.standardServingCalories)
            }
            return 250.0 // 默认保底热量
        }()

        let foodID: String? = action.params["foodID"] ?? estimate?.food.id ?? (FoodCatalog.item(matchingNameStrict: foodName)?.id)

        let imageData: Data? = {
            if let base64 = action.params["imageDataBase64"],
               let data = Data(base64Encoded: base64) {
                return data
            }
            return nil
        }()

        let record = FoodIntakeRecord(
            date: date,
            foodName: foodName,
            foodID: foodID,
            portion: estimate?.portion ?? .regular,
            fullPortionCalories: finalCalories,
            consumedRatio: 1.0,
            confidence: parsedCalories != nil ? 0.9 : (estimate != nil ? 0.85 : 0.5),
            isManuallyAdjusted: false,
            source: imageData != nil ? .vision : .manual,
            imageData: imageData,
            linkedExpenseID: nil
        )

        context.insert(record)
        try context.save()

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .foodRecord, params: action.params),
            undo: OmniboxUndoToken(kind: .foodRecord, recordID: record.id)
        )
    }

    // MARK: water.record

    private static func executeWaterRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let volumeML = Double(action.params["volumeML"] ?? "") ?? 250.0
        let bevLabel = action.params["customName"] ?? action.params["beverageType"] ?? "白开水"
        let bevType = HydrationBeverageType.fromLabel(action.params["beverageType"] ?? bevLabel)
        let date = OmniboxPlanner.parseParamDate(action.params["dateISO"]) ?? .now

        let record = WaterIntakeRecord(
            date: date,
            beverageType: bevType,
            volumeML: volumeML,
            customName: bevLabel,
            note: "万能入口快速录入"
        )
        context.insert(record)
        try context.save()

        // 异步同步到 HealthKit
        Task {
            _ = await HealthKitService.shared.recordWaterIntake(
                amountML: record.effectiveHydrationML,
                date: record.date
            )
        }

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .waterRecord, params: action.params),
            undo: OmniboxUndoToken(kind: .waterRecord, recordID: record.id)
        )
    }

    // MARK: storage.record

    private static func executeStorageRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let name = action.params["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            throw OmniboxError.invalidParams("物品名称不能为空")
        }
        let location = action.params["location"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "默认位置"
        let roomArea = action.params["roomArea"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "主卧"
        let isMedicine = action.params["isMedicine"] == "true"

        if isMedicine {
            let medItem = MedicineItem(
                name: name,
                storageLocation: location,
                roomArea: roomArea
            )
            context.insert(medItem)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .storageRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .medicineRecord, recordID: medItem.id)
            )
        } else {
            let item = StoredItem(
                name: name,
                location: location,
                roomArea: roomArea
            )
            context.insert(item)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .storageRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .storageRecord, recordID: item.id)
            )
        }
    }

    // MARK: habit.log

    private static func executeHabitLog(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
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

    // MARK: anniversary.create

    private static func executeAnniversaryCreate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let title = action.params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw OmniboxError.invalidParams("名称不能为空") }
        let category = action.params["category"] ?? "纪念日"
        let date = OmniboxPlanner.parseParamDate(action.params["targetDate"]) ?? .now

        if category == "订阅续费" {
            let price = action.params["price"] ?? "待确认"
            let sub = SubscriptionItem(name: title, priceString: price, nextBillingDate: date)
            context.insert(sub)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .anniversaryCreate, params: action.params),
                undo: OmniboxUndoToken(kind: .subscription, recordID: sub.id)
            )
        } else if category == "保质期" {
            let item = ItemExpiryItem(title: title, expireDate: date)
            context.insert(item)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .anniversaryCreate, params: action.params),
                undo: OmniboxUndoToken(kind: .itemExpiry, recordID: item.id)
            )
        } else {
            let anniv = AnniversaryItem(title: title, category: category, targetDate: date)
            context.insert(anniv)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .anniversaryCreate, params: action.params),
                undo: OmniboxUndoToken(kind: .anniversary, recordID: anniv.id)
            )
        }
    }

    // MARK: departure.add

    private static func executeDepartureAdd(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let title = action.params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw OmniboxError.invalidParams("随身物品不能为空") }
        let sceneName = action.params["scene"] ?? "工作通勤"
        let scene: DepartureScene = switch sceneName {
        case "运动健身": .workout
        case "出差旅行": .travel
        case "带娃出行": .parenting
        case "遛狗随行": .petWalk
        case "雨雪出行": .rainy
        default: .commute
        }
        let loc = action.params["location"]
        let item = DepartureCheckItem(title: title, scene: scene, isEssential: true, storageLocationNote: loc)
        context.insert(item)
        try context.save()
        return ActionExecutionOutcome(
            id: action.id, action: action,
            summary: OmniboxPlanner.summary(for: .departureAdd, params: action.params),
            undo: OmniboxUndoToken(kind: .departureItem, recordID: item.id)
        )
    }

    // MARK: life.record

    private static func executeLifeRecord(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let domain = action.params["domain"] ?? "pet"
        let title = action.params["title"] ?? "生活档案"
        let detail = action.params["detail"] ?? ""

        switch domain {
        case "pet":
            let desc = FetchDescriptor<PetProfile>()
            let pets = (try? context.fetch(desc)) ?? []
            let pet = pets.first ?? {
                let p = PetProfile(name: "毛孩子", type: .cat)
                context.insert(p)
                return p
            }()
            let snapshot: [String: String] = [
                "lastExternalDewormDate": pet.lastExternalDewormDate?.ISO8601Format() ?? "",
                "lastInternalDewormDate": pet.lastInternalDewormDate?.ISO8601Format() ?? "",
                "lastVaccineDate": pet.lastVaccineDate?.ISO8601Format() ?? "",
                "lastBathDate": pet.lastBathDate?.ISO8601Format() ?? ""
            ]
            if detail.contains("体外驱虫") { pet.lastExternalDewormDate = .now }
            else if detail.contains("体内驱虫") { pet.lastInternalDewormDate = .now }
            else if detail.contains("疫苗") { pet.lastVaccineDate = .now }
            else if detail.contains("洗澡") { pet.lastBathDate = .now }
            else if let val = Double(action.params["value"] ?? "") { pet.weightKg = val }
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .petRecord, recordID: pet.id, snapshotJSON: ActionUndoToken.makeSnapshotData(snapshot))
            )

        case "vehicle":
            let desc = FetchDescriptor<VehicleProfile>()
            let vehicles = (try? context.fetch(desc)) ?? []
            let vehicle = vehicles.first ?? {
                let v = VehicleProfile(name: "爱车", plateNumber: "待完善")
                context.insert(v)
                return v
            }()
            let snapshot: [String: String] = [
                "lastEnergyRefillDate": vehicle.lastEnergyRefillDate?.ISO8601Format() ?? "",
                "lastMaintenanceDate": vehicle.lastMaintenanceDate?.ISO8601Format() ?? ""
            ]
            if detail.contains("补能") || detail.contains("加油") || detail.contains("充电") {
                vehicle.completeEnergyRefill()
            } else if detail.contains("保养") {
                vehicle.completeMaintenance()
            } else if let val = Double(action.params["value"] ?? "") {
                vehicle.currentMileage = val
            }
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .vehicleRecord, recordID: vehicle.id, snapshotJSON: ActionUndoToken.makeSnapshotData(snapshot))
            )

        case "child":
            let desc = FetchDescriptor<ChildProfile>()
            let children = (try? context.fetch(desc)) ?? []
            let child = children.first ?? {
                let c = ChildProfile(name: "宝宝")
                context.insert(c)
                return c
            }()
            let record = ChildMilestoneRecord(title: detail.isEmpty ? title : detail, child: child)
            context.insert(record)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .childRecord, recordID: record.id)
            )

        case "skill":
            let desc = FetchDescriptor<SkillPath>()
            let skills = (try? context.fetch(desc)) ?? []
            let skill = skills.first ?? {
                let s = SkillPath(title: title, category: .generic, goal: "持续练习与提升", weeklyMinutes: 120, totalWeeks: 12)
                context.insert(s)
                return s
            }()
            let log = SkillPracticeLog(
                pathID: skill.id,
                stageIndex: skill.currentStageIndex,
                practicedAt: .now,
                minutes: Int(action.params["value"] ?? "") ?? 30
            )
            skill.lastPracticedAt = .now
            skill.practiceCount += 1
            context.insert(log)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .skillRecord, recordID: log.id)
            )

        case "document":
            let doc = IDDocumentItem(title: title, notes: detail)
            context.insert(doc)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .idDocument, recordID: doc.id)
            )

        default:
            let defaultTargetDate = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
            let project = LifeEventProject(title: title, template: .custom, targetDate: defaultTargetDate)
            context.insert(project)
            try context.save()
            return ActionExecutionOutcome(
                id: action.id, action: action,
                summary: OmniboxPlanner.summary(for: .lifeRecord, params: action.params),
                undo: OmniboxUndoToken(kind: .lifeEvent, recordID: project.id)
            )
        }
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
                    ExpenseCalorieService.handleDeleted(expenseID: record.id, context: context)
                    ExpenseWaterService.handleDeleted(expenseID: record.id, context: context)
                    context.delete(record)
                }
            }
        case .memoLine:
            if let line = token.memoLine {
                let url = memoFileURL
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let filtered = existing
                    .components(separatedBy: .newlines)
                    .filter { $0 != line }
                    .joined(separator: "\n")
                try? filtered.write(to: url, atomically: true, encoding: .utf8)
            }
            if let foodID = token.recordID {
                let descriptor = FetchDescriptor<FoodIntakeRecord>(predicate: #Predicate { $0.id == foodID })
                if let food = try? context.fetch(descriptor).first {
                    context.delete(food)
                }
            }
        case .foodRecord:
            if let foodID = token.recordID {
                let descriptor = FetchDescriptor<FoodIntakeRecord>(predicate: #Predicate { $0.id == foodID })
                if let food = try? context.fetch(descriptor).first {
                    context.delete(food)
                }
            }
        case .waterRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<WaterIntakeRecord>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .storageRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .medicineRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<MedicineItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
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
        case .anniversary:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<AnniversaryItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .subscription:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<SubscriptionItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .itemExpiry:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<ItemExpiryItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .departureItem:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<DepartureCheckItem>(predicate: #Predicate { $0.id == id })
                if let record = try? context.fetch(descriptor).first {
                    context.delete(record)
                }
            }
        case .petRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<PetProfile>(predicate: #Predicate { $0.id == id })
                if let pet = try? context.fetch(descriptor).first, let snap = token.decodeSnapshot() {
                    let f = ISO8601DateFormatter()
                    if let iso = snap["lastExternalDewormDate"] { pet.lastExternalDewormDate = f.date(from: iso) }
                    if let iso = snap["lastInternalDewormDate"] { pet.lastInternalDewormDate = f.date(from: iso) }
                    if let iso = snap["lastVaccineDate"] { pet.lastVaccineDate = f.date(from: iso) }
                    if let iso = snap["lastBathDate"] { pet.lastBathDate = f.date(from: iso) }
                }
            }
        case .vehicleRecord:
            if let id = token.recordID {
                let descriptor = FetchDescriptor<VehicleProfile>(predicate: #Predicate { $0.id == id })
                if let v = try? context.fetch(descriptor).first, let snap = token.decodeSnapshot() {
                    let f = ISO8601DateFormatter()
                    if let iso = snap["lastEnergyRefillDate"] { v.lastEnergyRefillDate = f.date(from: iso) }
                    if let iso = snap["lastMaintenanceDate"] { v.lastMaintenanceDate = f.date(from: iso) }
                }
            }
        case .childRecord:
            if let id = token.recordID {
                let descGrowth = FetchDescriptor<ChildGrowthRecord>(predicate: #Predicate { $0.id == id })
                if let g = try? context.fetch(descGrowth).first { context.delete(g) }
                let descMilestone = FetchDescriptor<ChildMilestoneRecord>(predicate: #Predicate { $0.id == id })
                if let m = try? context.fetch(descMilestone).first { context.delete(m) }
            }
        case .skillRecord:
            if let id = token.recordID {
                let desc = FetchDescriptor<SkillPracticeLog>(predicate: #Predicate { $0.id == id })
                if let log = try? context.fetch(desc).first { context.delete(log) }
            }
        case .idDocument:
            if let id = token.recordID {
                let desc = FetchDescriptor<IDDocumentItem>(predicate: #Predicate { $0.id == id })
                if let doc = try? context.fetch(desc).first { context.delete(doc) }
            }
        case .lifeEvent:
            if let id = token.recordID {
                let desc = FetchDescriptor<LifeEventProject>(predicate: #Predicate { $0.id == id })
                if let p = try? context.fetch(desc).first { context.delete(p) }
            }
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
