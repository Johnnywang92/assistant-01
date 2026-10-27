import Foundation
import SwiftData
import SwiftUI
import UserNotifications
import AssistantCore

/// 待办事项本地通知调度与交互管理中心
public final class TodoNotificationManager {
    public static let shared = TodoNotificationManager()

    public static let categoryIdentifier = "TODO_REMINDER_CATEGORY"
    public static let actionMarkDone = "ACTION_TODO_MARK_DONE"
    public static let actionSnooze10M = "ACTION_TODO_SNOOZE_10M"
    public static let actionSnooze1H = "ACTION_TODO_SNOOZE_1H"
    public static let actionSnoozeTomorrow = "ACTION_TODO_SNOOZE_TOMORROW"
    public static let actionView = "ACTION_TODO_VIEW"

    // 逾期补提醒偏移与排期项上限的判定口径下沉到 AssistantCore.TodoReminderSchedule（可单测）。
    private var overdueOffsets: [TimeInterval] { TodoReminderSchedule.overdueOffsets }

    private init() {}

    /// 默认隐藏取件码、地点和个人备注，避免锁屏横幅泄露信息。
    public var showSensitiveDetails: Bool {
        get { UserDefaults.standard.bool(forKey: "todo_notification_show_sensitive_details") }
        set { UserDefaults.standard.set(newValue, forKey: "todo_notification_show_sensitive_details") }
    }

    /// 注册交互式通知分类与快捷操作按钮（完成、推迟、查看）
    public func registerCategories() {
        let markDoneAction = UNNotificationAction(
            identifier: Self.actionMarkDone,
            title: L10n.tr("完成事项"),
            options: []
        )
        let snooze10mAction = UNNotificationAction(
            identifier: Self.actionSnooze10M,
            title: L10n.tr("10 分钟后提醒"),
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: Self.actionSnooze1H,
            title: L10n.tr("稍后推迟 1 小时"),
            options: []
        )
        let snoozeTomorrowAction = UNNotificationAction(
            identifier: Self.actionSnoozeTomorrow,
            title: L10n.tr("明早 9 点提醒"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            // 默认点击通知本身即可打开待办，因此把名额留给更多稍后选项。
            actions: [markDoneAction, snooze10mAction, snoozeAction, snoozeTomorrowAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var updated = existing
            updated.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(updated)
        }
    }

    /// 构造通知标识符
    public func notificationId(for itemId: UUID) -> String {
        "todo-\(itemId.uuidString)"
    }

    private func overdueNotificationId(for itemId: UUID, offset: TimeInterval) -> String {
        "todo-\(itemId.uuidString)-overdue-\(Int(offset))"
    }

    /// 为单个待办事项排期提醒通知
    func scheduleNotification(for item: TodoItem, syncGeofences: Bool = true) {
        // 仅对活跃且设定了未来截止时间的事项进行提醒排期
        guard item.status == .active, let dueAt = item.dueAt else {
            cancelNotification(for: item.id)
            return
        }
        // 重排时先移除旧的主提醒和逾期提醒，避免编辑截止时间后留下旧通知。
        cancelNotification(for: item.id)
        // 提前量与 override 的取舍、是否还值得排期，均由 Core 纯函数判定。
        guard let plannedReminder = TodoReminderSchedule.mainReminderDate(
            dueAt: dueAt,
            remindBeforeMinutes: item.remindBeforeMinutes,
            reminderOverrideAt: item.reminderOverrideAt,
            now: .now
        ) else {
            cancelNotification(for: item.id)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = showSensitiveDetails
            ? L10n.choose("待办提醒：\(item.title)", "To-Do Reminder: \(item.title)")
            : L10n.tr("待办提醒")

        var bodySnippets: [String] = []
        if let code = item.pickupCode, !code.isEmpty {
            bodySnippets.append(L10n.choose("取件码: \(code)", "Pickup Code: \(code)"))
        }
        if let place = item.station ?? item.location, !place.isEmpty {
            bodySnippets.append(place)
        }
        if let detail = item.detail, !detail.isEmpty {
            bodySnippets.append(detail)
        }
        if item.isRecurring {
            bodySnippets.append("[\(item.recurrenceSummaryText)]")
        }
        if WeChatCommunicationHelper.isWeChatCommunication(title: item.title, detail: item.detail) {
            let kind = WeChatCommunicationHelper.communicationKind(title: item.title, detail: item.detail)
            bodySnippets.append("💬 \(kind.buttonTitle)")
        }

        if !showSensitiveDetails {
            content.body = L10n.tr("有一项待办已到提醒时间，请解锁后查看。")
        } else if bodySnippets.isEmpty {
            content.body = L10n.tr("事项已到达提醒时间，请及时处理。")
        } else {
            content.body = bodySnippets.joined(separator: " · ")
        }

        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "todoId": item.id.uuidString,
            "type": "todo"
        ]

        let interval = max(1, plannedReminder.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationId(for: item.id),
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule todo notification: \(error)")
            }
        }

        // 如果是快递包裹待办，自动同步驿站地理围栏（批量排期时统一同步，避免循环内多次派发）
        if syncGeofences && (item.type == .parcel || item.type == .returnParcel) {
            Task { @MainActor in
                LocationReminderService.shared.syncParcelStationGeofences()
            }
        }

        // 到期后仍未完成时再提醒几次，避免一次通知被忽略后事项悄悄过期。
        for offset in TodoReminderSchedule.futureOverdueOffsets(dueAt: dueAt, now: .now) {
            let fireDate = dueAt.addingTimeInterval(offset)
            let overdueContent = UNMutableNotificationContent()
            overdueContent.title = showSensitiveDetails
                ? L10n.choose("待办已逾期：\(item.title)", "To-Do Overdue: \(item.title)")
                : L10n.tr("待办已逾期")
            overdueContent.body = showSensitiveDetails
                ? L10n.tr("这项待办尚未完成，请及时处理。")
                : L10n.tr("有一项待办尚未完成，请解锁后查看。")
            overdueContent.sound = .default
            overdueContent.categoryIdentifier = Self.categoryIdentifier
            overdueContent.userInfo = ["todoId": item.id.uuidString, "type": "todo"]
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let overdueRequest = UNNotificationRequest(
                identifier: overdueNotificationId(for: item.id, offset: offset),
                content: overdueContent,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(overdueRequest)
        }
    }

    /// 取消单个待办的通知
    public func cancelNotification(for itemId: UUID) {
        let ids = [notificationId(for: itemId)] + overdueOffsets.map { overdueNotificationId(for: itemId, offset: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// 处理锁屏/横幅通知交互响应（标记完成、推迟、跳转查看）
    public func handleNotificationResponse(_ response: UNNotificationResponse, context: ModelContext) {
        guard let todoIdStr = response.notification.request.content.userInfo["todoId"] as? String,
              let todoId = UUID(uuidString: todoIdStr) else {
            return
        }

        let actionId = response.actionIdentifier
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == todoId })

        guard let item = (try? context.fetch(descriptor))?.first else {
            return
        }

        switch actionId {
        case Self.actionMarkDone:
            // 标记完成当前待办，若为周期事项将自动生成下一期并注册下次通知
            item.markAsCompleted(in: context)
            try? context.save()
            Task { @MainActor in Haptic.success() }

        case Self.actionSnooze10M:
            item.reminderOverrideAt = Date.now.addingTimeInterval(10 * 60)
            scheduleNotification(for: item)
            try? context.save()
            Task { @MainActor in Haptic.light() }

        case Self.actionSnooze1H:
            // 只推迟通知，不改变原截止时间。
            item.reminderOverrideAt = Calendar.current.date(byAdding: .hour, value: 1, to: .now)
            scheduleNotification(for: item)
            try? context.save()
            Task { @MainActor in Haptic.light() }

        case Self.actionSnoozeTomorrow:
            var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            components.day = (components.day ?? 0) + 1
            components.hour = 9
            components.minute = 0
            item.reminderOverrideAt = Calendar.current.date(from: components)
            scheduleNotification(for: item)
            try? context.save()
            Task { @MainActor in Haptic.light() }

        case Self.actionView, UNNotificationDefaultActionIdentifier:
            // 打开并路由至待办页面
            Task { @MainActor in
                NavigationRouter.shared.selectedTab = .todos
            }

        default:
            break
        }
    }

    /// 同步并排期所有活跃且在未来的待办事项通知（应用启动或回到前台时巡检）
    public func syncAllTodoNotifications(context: ModelContext) {
        registerCategories()

        // 只物化活跃待办：已完成/待确认历史无需参与通知排期对账
        let activeRaw = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.statusRaw == activeRaw })
        guard let allItems = try? context.fetch(descriptor) else { return }

        let now = Date.now
        // 筛选、排序与 15 项截断口径下沉到 Core；这里只做快照转换与回填。
        let itemByID = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshots = allItems.map {
            TodoReminderSchedule.Item(
                id: $0.id,
                dueAt: $0.dueAt,
                reminderOverrideAt: $0.reminderOverrideAt,
                remindBeforeMinutes: $0.remindBeforeMinutes
            )
        }
        // iOS 对应用待处理通知数量有限制；每项最多 4 个请求，因此优先排期最近的 15 项。
        let scheduledSnapshots = TodoReminderSchedule.selectItemsForRescheduling(snapshots, now: now)
        let validIDs = Set(scheduledSnapshots.flatMap { item in
            [notificationId(for: item.id)] + overdueOffsets.map { overdueNotificationId(for: item.id, offset: $0) }
        })
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix("todo-") && !validIDs.contains($0) }
            if !stale.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
        for snapshot in scheduledSnapshots {
            if let item = itemByID[snapshot.id] {
                scheduleNotification(for: item, syncGeofences: false)
            }
        }

        // 同步驿站地理围栏
        Task { @MainActor in
            LocationReminderService.shared.syncParcelStationGeofences(context: context)
        }
    }
}
