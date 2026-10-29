import ActivityKit
import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// 「免掏手机」取件销号闭环。
///
/// ## 为什么必须有这一层
/// watchOS 11 起 iPhone 的实时活动会自动出现在 Apple Watch 智能叠放，**不需要 watchOS App**。
/// 但在没有 watchOS App 的前提下它是**不可交互**的：整张卡片是单一点击目标，点了只会展开系统
/// 全屏视图并给出一个「在 iPhone 上打开」的按钮（WWDC24 Session 10098）。
/// 也就是说，实时活动卡片里的 `Button(intent:)` 在手腕上根本点不动。
///
/// 所以职责这样切：
/// - 灵动岛 + 手表智能叠放：负责「抬腕就看到大字取件码」（只读，但 100% 可靠）
/// - 本服务的可交互通知：负责「动手点一下」（通知 action 是手腕上唯一原生可点的单位，
///   且不需要 watchOS App，抬腕点按钮即可在主应用进程执行）
///
/// 两者同时出现在手腕上：上面看码，下面点「已取件」，点完灵动岛与手表卡片一起收起。
@MainActor
enum PickupCheckoutService {
    static let categoryIdentifier = "PICKUP_CHECKOUT_CATEGORY"
    static let actionTakeOne = "ACTION_PICKUP_TAKE_ONE"
    static let actionTakeAll = "ACTION_PICKUP_TAKE_ALL"
    static let actionClose = "ACTION_PICKUP_CLOSE"

    private static let notificationIdentifier = "pickup-checkout-session"
    private static let sessionKey = "pickup_checkout_session_v1"

    // MARK: - 通知分类注册

    // 采用 async/await 而非 getNotificationCategories 的 @Sendable 回调：
    // category/center 均为非 Sendable 类型，在回调里跨隔离捕获会报并发警告
    static func registerCategory() async {
        let takeOne = UNNotificationAction(
            identifier: actionTakeOne,
            title: "已取件",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle.fill")
        )
        let takeAll = UNNotificationAction(
            identifier: actionTakeAll,
            title: "全部取齐",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark.seal.fill")
        )
        let close = UNNotificationAction(
            identifier: actionClose,
            title: "收起卡片",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "xmark.circle")
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            // 手表上只展示前两个 action，把「收起卡片」排在第二：
            // 不想逐件销号时，抬腕就能一眼看到并点中收卡入口。
            actions: [takeOne, close, takeAll],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.insert(category)
        center.setNotificationCategories(updated)
    }

    // MARK: - 开启一次销号会话

    /// 上岛成功后调用。传入本次要销号的包裹（id + 取件码）与驿站名。
    /// 每次「上岛」都会开启一次新的会话，并把上一条销号通知替换掉。
    static func begin(parcels: [(id: UUID, code: String)], station: String) {
        let steps = parcels.map { Step(id: $0.id, code: $0.code) }
        guard !steps.isEmpty else { cancel(); return }
        session = Session(station: station, steps: steps)
        render()
    }

    static func cancel() {
        session = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }

    // MARK: - 会话持久化

    private struct Step: Codable {
        var id: UUID
        var code: String
    }

    private struct Session: Codable {
        var station: String
        var steps: [Step]
    }

    private static var session: Session? {
        get {
            guard let data = UserDefaults.standard.data(forKey: sessionKey),
                  let value = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
            return value
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: sessionKey)
                return
            }
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    // MARK: - 渲染（投递 / 替换 / 收起）

    private static func render() {
        guard let current = session, let first = current.steps.first else {
            cancel()
            return
        }
        let remaining = current.steps.count
        let content = UNMutableNotificationContent()
        content.title = "取件码 \(first.code)"
        content.subtitle = remaining > 1
            ? "\(current.station) · 待取 \(remaining) 件"
            : current.station
        content.body = remaining > 1
            ? "取到后轻点下方「已取件」，将自动切换至下一件包裹。"
            : "取到后轻点下方「已取件」，即可完成销号并收起卡片。"
        content.categoryIdentifier = categoryIdentifier
        content.relevanceScore = 0.95
        // 销号是一次安静的确认动作，不响铃；用户此时就看得到画面上的码。
        content.sound = nil
        content.threadIdentifier = "pickup-checkout"
        content.userInfo = ["type": "pickup"]

        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Pickup checkout notification failed: \(error)") }
        }
    }

    // MARK: - 手表 / 锁屏点击响应

    static func handle(_ response: UNNotificationResponse, context: ModelContext) {
        // 「关闭卡片」：不收销号通知里的进度，直接把会话与灵动岛/手表卡片一起关掉，不改动待办
        if response.actionIdentifier == actionClose {
            cancel()
            LiveActivityService.endPickupActivities()
            return
        }
        guard var current = session else { return }
        let takeAll = response.actionIdentifier == actionTakeAll
        guard takeAll || response.actionIdentifier == actionTakeOne else { return }

        let taken = takeAll ? current.steps : Array(current.steps.prefix(1))
        for step in taken {
            markDone(id: step.id, context: context)
        }
        current.steps.removeFirst(taken.count)
        try? context.save()

        if current.steps.isEmpty {
            // 全部取完：收起通知，实时活动由 PickupActivityHelper 自行判定并收岛
            cancel()
        } else {
            session = current
            render()
        }

        Task { @MainActor in
            Haptic.success()
            WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        }
    }

    private static func markDone(id: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        if let item = (try? context.fetch(descriptor))?.first, item.status == .active {
            item.markAsCompleted(in: context)
        }
        // 同步灵动岛 / 手表卡片的已取件状态；全部取完时它会自动 end 活动
        PickupActivityHelper.markCompleted(todoID: id)
        // 清掉这条待办原本排期的到期提醒，避免取完还响
        TodoNotificationManager.shared.cancelNotification(for: id)
        // 动态同步驿站地理围栏（包裹取完后自动清理硬件围栏）
        LocationReminderService.shared.syncParcelStationGeofences(context: context)
    }

    // MARK: - 对账

    /// 用户在 App 里手动勾掉了包裹时调用：把会话里已完成的步骤剔除，
    /// 手写销号后手表上的销号通知不会变成幽灵通知。
    static func reconcile(context: ModelContext) {
        guard var current = session, !current.steps.isEmpty else { return }
        let before = current.steps.count
        current.steps.removeAll { step in
            let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == step.id })
            let items: [TodoItem]
            do {
                items = try context.fetch(descriptor)
            } catch {
                // 查询失败不等于「待办已删」：误判会把整段销号会话判空并撤掉通知
                print("⚠️ [PickupCheckout] 对账查询失败，保留该步骤: \(error.localizedDescription)")
                return false
            }
            guard let item = items.first else { return true }
            return item.status != .active
        }
        guard current.steps.count != before else { return }
        if current.steps.isEmpty {
            cancel()
        } else {
            session = current
            render()
        }
    }
}
