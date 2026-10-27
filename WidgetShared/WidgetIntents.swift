import ActivityKit
import AppIntents
import WidgetKit

/// 主应用注册的桥接钩子：AppIntent 在主应用进程执行时直连 SwiftData，
/// 在扩展进程执行时走 App Group 指令队列（主应用回前台后对账）。
@MainActor
public protocol WidgetBridgeAppHook: AnyObject {
    func handleCompleteTodo(id: UUID)
    func handleSnoozeTodo(id: UUID, minutes: Int)
    func handleSnoozeTomorrow(id: UUID)
    func handleToggleDeparture(id: UUID, isChecked: Bool)
    func handleQuickAddExpense(text: String) async -> String?
    func handleQuickAddTodo(text: String) async -> String?
    func handleQueryParcels() async -> String
    func handleQueryBudget() async -> String
    func handleQueryTodayTodos() async -> String
}

public enum WidgetBridge {
    /// 由主应用在启动时注册；扩展进程保持 nil
    @MainActor public static weak var appHook: WidgetBridgeAppHook?

    /// 扩展进程侧的即时本地突变（快照 + 组件刷新 + 实时活动状态）
    @MainActor
    static func applyCompletionLocally(id: UUID) {
        WidgetSnapshotStore.applyCompletionLocally(id: id)
        WidgetCenter.shared.reloadAllTimelines()
        PickupActivityHelper.markCompleted(todoID: id)
    }

    @MainActor
    static func applyDepartureToggleLocally(id: UUID, isChecked: Bool) {
        DepartureActivityHelper.setChecked(itemID: id, isChecked: isChecked)
    }
}

// MARK: - 完成待办（桌面小组件勾选 / 灵动岛"已取件"按钮）

public struct CompleteTodoIntent: AppIntent {
    public static let title: LocalizedStringResource = "完成待办"

    /// 不主动把 App 拉到前台：Siri / Apple Watch 抬腕说一句就内联回显结果，
    /// 从灵动岛或桌面小组件点按钮时也不会打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("将一条待办或快递取件标记为已完成，并同步灵动岛与 Apple Watch")

    @Parameter(title: "待办ID")
    public var todoID: String

    public init() {}

    public init(todoID: String) {
        self.todoID = todoID
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = UUID(uuidString: todoID) else {
            return .result(dialog: "未找到该待办")
        }
        if let hook = WidgetBridge.appHook {
            hook.handleCompleteTodo(id: id)
        } else {
            WidgetSnapshotStore.enqueue(.completeTodo(id))
            WidgetBridge.applyCompletionLocally(id: id)
        }
        return .result(dialog: "已完成 ✓")
    }
}

// MARK: - 出门清单逐项确认（灵动岛/手表卡片按钮）

public struct ToggleDepartureItemIntent: AppIntent {
    public static let title: LocalizedStringResource = "确认随身物品"

    /// 不主动把 App 拉到前台：Siri / Apple Watch 抬腕说一句就内联回显结果，
    /// 从灵动岛或桌面小组件点按钮时也不会打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("在出门清点实时活动中逐项确认随身物品")

    @Parameter(title: "清单项ID")
    public var itemID: String

    @Parameter(title: "是否已带上")
    public var isChecked: Bool

    public init() {}

    public init(itemID: String, isChecked: Bool) {
        self.itemID = itemID
        self.isChecked = isChecked
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = UUID(uuidString: itemID) else {
            return .result(dialog: "未找到清单项")
        }
        if let hook = WidgetBridge.appHook {
            hook.handleToggleDeparture(id: id, isChecked: isChecked)
        } else {
            WidgetSnapshotStore.enqueue(.toggleDeparture(id, isChecked))
            WidgetBridge.applyDepartureToggleLocally(id: id, isChecked: isChecked)
        }
        return .result(dialog: isChecked ? "已带上 ✓" : "已取消确认")
    }
}

// MARK: - 结束行程护航活动（"已出发"）

public struct EndTravelActivityIntent: AppIntent {
    public static let title: LocalizedStringResource = "已出发"

    /// 不主动把 App 拉到前台：Siri / Apple Watch 抬腕说一句就内联回显结果，
    /// 从灵动岛或桌面小组件点按钮时也不会打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("结束行程护航实时活动")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return .result(dialog: "实时活动不可用")
        }
        let activities = Activity<TravelActivityAttributes>.activities
        for activity in activities {
            Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: activities.isEmpty ? "当前没有护航中的行程" : "已结束护航，一路顺利 🚄")
    }
}

// MARK: - 结束出门清点活动（全带齐后的「关闭卡片」）

public struct EndDepartureActivityIntent: AppIntent {
    public static let title: LocalizedStringResource = "关闭清点卡片"

    /// 不主动把 App 拉到前台：从灵动岛/锁屏/Mac 通知中心点按钮时不打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("结束出门清点实时活动，收起锁屏与灵动岛卡片")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return .result(dialog: "实时活动不可用")
        }
        let activities = Activity<DepartureChecklistActivityAttributes>.activities
        for activity in activities {
            Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: activities.isEmpty ? "当前没有清点卡片" : "已结束出门清点，一路顺利 🎒")
    }
}

// MARK: - 一键批量取齐（锁屏大按钮，省去逐行点小勾选）

public struct CompleteAllParcelsIntent: AppIntent {
    public static let title: LocalizedStringResource = "全部取齐"

    /// 不主动把 App 拉到前台：从灵动岛/锁屏/Mac 通知中心点按钮时不打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("一次点完本批全部待取包裹，灵动岛与手表卡片同步收起")

    /// 逗号分隔的 UUID 列表：Button(intent:) 携带数组参数在扩展侧不便序列化，用标量拼串。
    @Parameter(title: "包裹ID列表")
    public var parcelIDs: String

    public init() {}

    public init(parcelIDs: String) {
        self.parcelIDs = parcelIDs
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let ids = parcelIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else {
            return .result(dialog: "没有待取的包裹")
        }
        if let hook = WidgetBridge.appHook {
            for id in ids { hook.handleCompleteTodo(id: id) }
        } else {
            for id in ids {
                WidgetSnapshotStore.enqueue(.completeTodo(id))
                WidgetBridge.applyCompletionLocally(id: id)
            }
        }
        return .result(dialog: "已全部取齐 ✓")
    }
}

// MARK: - 一键全部带齐（锁屏大按钮，点一次即收卡）

public struct CheckAllDepartureItemsIntent: AppIntent {
    public static let title: LocalizedStringResource = "全部带齐"

    /// 不主动把 App 拉到前台：从灵动岛/锁屏/Mac 通知中心点按钮时不打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("一次确认出门清点全部项，灵动岛与手表卡片同步收起")

    @Parameter(title: "清单项ID列表")
    public var itemIDs: String

    public init() {}

    public init(itemIDs: String) {
        self.itemIDs = itemIDs
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let ids = itemIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else {
            return .result(dialog: "没有待确认的清单项")
        }
        if let hook = WidgetBridge.appHook {
            for id in ids { hook.handleToggleDeparture(id: id, isChecked: true) }
        } else {
            for id in ids {
                WidgetSnapshotStore.enqueue(.toggleDeparture(id, true))
                WidgetBridge.applyDepartureToggleLocally(id: id, isChecked: true)
            }
        }
        return .result(dialog: "已全部带齐 ✓")
    }
}

// MARK: - 一句话记账（Siri / 操作按钮 / 手表快捷指令，运行于主应用进程）

public struct QuickAddExpenseIntent: AppIntent {
    public static let title: LocalizedStringResource = "一句话记账"

    /// 不主动把 App 拉到前台：Siri / Apple Watch 抬腕说一句就内联回显结果，
    /// 从灵动岛或桌面小组件点按钮时也不会打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("说一句话快速记一笔账，例如：咖啡 18 元")

    @Parameter(title: "内容")
    public var text: String?

    public init() {}

    public init(text: String) {
        self.text = text
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let input: String
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = text
        } else {
            input = try await $text.requestValue("想记一笔什么？例如：咖啡 18 元")
        }
        if let hook = WidgetBridge.appHook {
            if let reply = await hook.handleQuickAddExpense(text: input) {
                return .result(dialog: IntentDialog(stringLiteral: reply))
            }
            return .result(dialog: "没能识别金额，请打开小助手动记账")
        }
        WidgetSnapshotStore.enqueue(.quickAddExpense(input))
        return .result(dialog: "已记录，打开小助后自动入账")
    }
}

// MARK: - 快速新建待办（Siri / 操作按钮 / 手表快捷指令）

public struct QuickAddTodoIntent: AppIntent {
    public static let title: LocalizedStringResource = "新建待办"

    /// 不主动把 App 拉到前台：Siri / Apple Watch 抬腕说一句就内联回显结果，
    /// 从灵动岛或桌面小组件点按钮时也不会打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("说一句话快速创建一条待办，例如：明天下午三点取快递")

    @Parameter(title: "内容")
    public var text: String?

    public init() {}

    public init(text: String) {
        self.text = text
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let input: String
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = text
        } else {
            input = try await $text.requestValue("要记什么事？")
        }
        if let hook = WidgetBridge.appHook {
            if let reply = await hook.handleQuickAddTodo(text: input) {
                return .result(dialog: IntentDialog(stringLiteral: reply))
            }
            return .result(dialog: "已记录，打开小助后确认详情")
        }
        WidgetSnapshotStore.enqueue(.quickAddTodo(input))
        return .result(dialog: "已记录，打开小助后确认详情")
    }
}

// MARK: - 查询待取快递并把取件码推上灵动岛/手表

public struct QueryParcelsIntent: AppIntent {
    public static let title: LocalizedStringResource = "待取快递上岛"

    /// 不主动把 App 拉到前台：Siri / Apple Watch 抬腕说一句就内联回显结果，
    /// 从灵动岛或桌面小组件点按钮时也不会打断当前界面。
    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("播报所有待取快递的取件码，并推送到灵动岛与 Apple Watch 智能叠放")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let hook = WidgetBridge.appHook {
            let reply = await hook.handleQueryParcels()
            return .result(dialog: IntentDialog(stringLiteral: reply))
        }
        let snapshot = WidgetSnapshotStore.load()
        if snapshot.parcels.isEmpty {
            return .result(dialog: "目前没有待取的快递")
        }
        let codes = snapshot.parcels.prefix(5).compactMap { parcel -> String? in
            guard let code = parcel.pickupCode, !code.isEmpty else { return nil }
            if let st = parcel.stationName, !st.isEmpty {
                return "\(st) \(code)"
            }
            return code
        }
        let reply = "待取快递 \(snapshot.parcels.count) 件：" + codes.joined(separator: "、")
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

// MARK: - 查询今日预算与安心花额度（Siri / Apple Watch 抬腕即查）

public struct QueryBudgetIntent: AppIntent {
    public static let title: LocalizedStringResource = "查询预算与支出"

    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("播报今日已支出金额与安心花剩余额度，支持 Apple Watch 与 Siri 免开 App 抬腕即查")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let hook = WidgetBridge.appHook {
            let reply = await hook.handleQueryBudget()
            return .result(dialog: IntentDialog(stringLiteral: reply))
        }
        let snapshot = WidgetSnapshotStore.load()
        let amount = snapshot.todayExpense
        let amountText = String(format: amount.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", amount)
        let reply = "今日已累计支出 \(amountText) 元。放宽心，慢慢花。"
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

// MARK: - 查询今日待办（Siri / Apple Watch 抬腕即查）

public struct QueryTodayTodosIntent: AppIntent {
    public static let title: LocalizedStringResource = "查询今日待办"

    public static let openAppWhenRun: Bool = false

    public static let description = IntentDescription("播报今日最紧急的待办事项，支持 Apple Watch 与 Siri 免开 App 抬腕即查")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if let hook = WidgetBridge.appHook {
            let reply = await hook.handleQueryTodayTodos()
            return .result(dialog: IntentDialog(stringLiteral: reply))
        }
        let snapshot = WidgetSnapshotStore.load()
        if snapshot.topTodos.isEmpty {
            return .result(dialog: "今日待办已全部清空，好好休息吧！")
        }
        let topCount = min(3, snapshot.topTodos.count)
        let titles = snapshot.topTodos.prefix(topCount).map(\.title).joined(separator: "、")
        var reply = "今日待办共有 \(snapshot.topTodos.count) 项。优先处理：\(titles)"
        if snapshot.topTodos.count > topCount {
            reply += " 等"
        }
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

// MARK: - 小号组件显示模式（长按桌面组件配置）

public enum WidgetGlanceMode: String, AppEnum {
    case parcels
    case spending
    case practice

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "速览内容")
    }

    public static var caseDisplayRepresentations: [WidgetGlanceMode: DisplayRepresentation] {
        [
            .parcels: DisplayRepresentation(title: "待取快递码"),
            .spending: DisplayRepresentation(title: "今日支出"),
            .practice: DisplayRepresentation(title: "今日练习")
        ]
    }
}

public struct ParcelGlanceConfigurationIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "小助速览"
    public static let description = IntentDescription("选择小号组件显示待取快递码、今日支出或今日练习")

    @Parameter(title: "显示内容", default: .parcels)
    public var mode: WidgetGlanceMode

    public init() {}

    public init(mode: WidgetGlanceMode) {
        self.mode = mode
    }
}
