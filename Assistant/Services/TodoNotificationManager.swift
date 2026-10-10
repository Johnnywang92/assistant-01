import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// 待办事项本地通知调度与交互管理中心
public final class TodoNotificationManager {
    public static let shared = TodoNotificationManager()

    public static let categoryIdentifier = "TODO_REMINDER_CATEGORY"
    public static let actionMarkDone = "ACTION_TODO_MARK_DONE"
    public static let actionSnooze1H = "ACTION_TODO_SNOOZE_1H"
    public static let actionView = "ACTION_TODO_VIEW"

    private init() {}

    /// 注册交互式通知分类与快捷操作按钮（完成、推迟、查看）
    public func registerCategories() {
        let markDoneAction = UNNotificationAction(
            identifier: Self.actionMarkDone,
            title: "完成事项",
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: Self.actionSnooze1H,
            title: "稍后推迟 1 小时",
            options: []
        )
        let viewAction = UNNotificationAction(
            identifier: Self.actionView,
            title: "查看待办",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [markDoneAction, snoozeAction, viewAction],
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

    /// 为单个待办事项排期提醒通知
    public func scheduleNotification(for item: TodoItem) {
        // 仅对活跃且设定了未来截止时间的事项进行提醒排期
        guard item.status == .active, let dueAt = item.dueAt, dueAt > .now else {
            cancelNotification(for: item.id)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "待办提醒：\(item.title)"

        var bodySnippets: [String] = []
        if let code = item.pickupCode, !code.isEmpty {
            bodySnippets.append("取件码: \(code)")
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

        if bodySnippets.isEmpty {
            content.body = "事项已到达提醒时间，请及时处理。"
        } else {
            content.body = bodySnippets.joined(separator: " · ")
        }

        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "todoId": item.id.uuidString,
            "type": "todo"
        ]

        let interval = max(1, dueAt.timeIntervalSinceNow)
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
    }

    /// 取消单个待办的通知
    public func cancelNotification(for itemId: UUID) {
        let reqId = notificationId(for: itemId)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reqId])
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
            Haptic.success()

        case Self.actionSnooze1H:
            // 顺延 1 小时
            let newDue = Calendar.current.date(byAdding: .hour, value: 1, to: item.dueAt ?? .now) ?? .now
            item.dueAt = newDue
            scheduleNotification(for: item)
            try? context.save()
            Haptic.light()

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

        let descriptor = FetchDescriptor<TodoItem>()
        guard let allItems = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let activeItemsWithDue = allItems.filter { $0.status == .active && ($0.dueAt ?? .distantPast) > now }

        for item in activeItemsWithDue {
            scheduleNotification(for: item)
        }
    }
}
