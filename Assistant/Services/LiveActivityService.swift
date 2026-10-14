import ActivityKit
import AssistantCore
import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// 主应用侧实时活动管理：从 SwiftData 模型发起/结束灵动岛实时活动。
/// 扩展侧的按钮交互通过 WidgetShared 中的 Helper 与 Intent 完成，不依赖本文件。
@MainActor
enum LiveActivityService {
    static var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - 场景 1：快递取件码上岛

    /// 将一批待取快递推上灵动岛与 Apple Watch 智能叠放，返回是否成功
    @discardableResult
    static func startPickupActivity(for items: [TodoItem]) -> Bool {
        guard activitiesEnabled else { return false }
        let parcels = items
            .filter { ($0.pickupCode ?? "").isEmpty == false }
            .map { PickupParcel(id: $0.id, code: $0.pickupCode ?? "", courier: $0.courier, title: $0.displayConciseTitle) }
        guard !parcels.isEmpty else { return false }

        // 已在岛上的包裹不重复挂载
        let existingIDs = Set(Activity<PickupActivityAttributes>.activities.flatMap { $0.attributes.parcels.map(\.id) })
        let newParcels = parcels.filter { !existingIDs.contains($0.id) }
        guard !newParcels.isEmpty else { return true }

        let station = items.first { ($0.station ?? "").isEmpty == false }?.station
            ?? items.first { ($0.location ?? "").isEmpty == false }?.location
            ?? "驿站"

        let attributes = PickupActivityAttributes(station: station, parcels: newParcels)
        let state = PickupActivityAttributes.ContentState()
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            // 上岛只是「让手腕看得到」，真正能点的是这条通知：
            // 手表智能叠放里的实时活动没有 watchOS App 时不可交互，通知 action 才点得动。
            PickupCheckoutService.begin(
                parcels: newParcels.map { (id: $0.id, code: $0.code) },
                station: station
            )
            return true
        } catch {
            print("Failed to start pickup activity: \(error)")
            return false
        }
    }

    // MARK: - 场景 2：行程护航上岛

    @discardableResult
    static func startTravelActivity(for item: TodoItem) -> Bool {
        guard activitiesEnabled else { return false }
        let departure = item.dueAt ?? Date().addingTimeInterval(3600)
        // 座位号/检票口国内票面短信里通常就在详情或原文里，上岛前抽一次，
        // 抬腕就能直接看到，不用再去翻截图。抽不到就只显示倒计时，不硬凑。
        let ticket = TicketDetailsExtractor.extract(from: [item.detail, item.sourceText, item.title])
        let attributes = TravelActivityAttributes(
            title: item.displayConciseTitle,
            place: item.displayLocationText,
            ticketSummary: ticket.vehicleAndSeatLine,
            gate: ticket.gate
        )
        let state = TravelActivityAttributes.ContentState(departureDate: departure, note: item.displayConciseDetail)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            // 护航卡没有取件那样的销号会话，单独补一条带「已出发」动作的伴随通知，
            // 否则在手表上根本找不到能把卡片关掉的可点入口。
            LiveActivityControlNotifications.announceTravel(title: item.displayConciseTitle)
            return true
        } catch {
            print("Failed to start travel activity: \(error)")
            return false
        }
    }

    // MARK: - 场景 2：出门防丢清点上岛

    @discardableResult
    static func startDepartureChecklist(sceneName: String, items: [DepartureCheckItem]) -> Bool {
        guard activitiesEnabled, !items.isEmpty else { return false }
        // 全部已勾完时不再上岛：否则锁屏会挂出一张没有待办行、又没有收卡入口的死卡
        guard items.contains(where: { !$0.isChecked }) else { return false }
        let checklistItems = items.map {
            DepartureChecklistActivityAttributes.Item(id: $0.id, title: $0.title, isEssential: $0.isEssential)
        }
        let attributes = DepartureChecklistActivityAttributes(sceneName: sceneName, items: checklistItems)
        let state = DepartureChecklistActivityAttributes.ContentState(
            checkedIDs: items.filter(\.isChecked).map(\.id)
        )
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            LiveActivityControlNotifications.announceDeparture(sceneName: sceneName)
            return true
        } catch {
            print("Failed to start departure checklist activity: \(error)")
            return false
        }
    }

    // MARK: - 结束活动

    static func endPickupActivities() {
        for activity in Activity<PickupActivityAttributes>.activities {
            Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        }
    }

    static func endTravelActivities() {
        for activity in Activity<TravelActivityAttributes>.activities {
            Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        }
    }

    static func endDepartureActivities() {
        for activity in Activity<DepartureChecklistActivityAttributes>.activities {
            Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        }
    }
}

// MARK: - 手表 / Mac 上的一键「点关闭」伴随通知
//
// 没有 watchOS App 时，手表智能叠放里的实时活动整卡不可交互；Mac 通知中心
// 镜像的卡片按钮又小又难点中。通知 action 是手腕上最大的原生可点单位，在 Mac
// 横幅上也是一眼就能展开点到的按钮——所以每次护航/清点上岛时同步挂一条静默
// 伴随通知，提供语义一致的「点一下即关闭」入口。与取件场景的销号通知同一套路。
@MainActor
enum LiveActivityControlNotifications {
    static let travelCategoryIdentifier = "TRAVEL_ESCORT_CATEGORY"
    static let travelActionEnd = "ACTION_TRAVEL_ENDED"
    static let departureCategoryIdentifier = "DEPARTURE_CHECK_CATEGORY"
    static let departureActionCheckAll = "ACTION_DEPARTURE_CHECKED_ALL"

    private static let travelNotificationIdentifier = "travel-escort-session"
    private static let departureNotificationIdentifier = "departure-check-session"

    static func registerCategories() async {
        let endTravel = UNNotificationAction(
            identifier: travelActionEnd,
            title: "已出发，关闭卡片",
            options: []
        )
        let travelCategory = UNNotificationCategory(
            identifier: travelCategoryIdentifier,
            actions: [endTravel],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        let checkAll = UNNotificationAction(
            identifier: departureActionCheckAll,
            title: "全部带齐，关闭卡片",
            options: []
        )
        let departureCategory = UNNotificationCategory(
            identifier: departureCategoryIdentifier,
            actions: [checkAll],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.insert(travelCategory)
        updated.insert(departureCategory)
        center.setNotificationCategories(updated)
    }

    static func announceTravel(title: String) {
        deliver(
            identifier: travelNotificationIdentifier,
            category: travelCategoryIdentifier,
            title: "🚄 行程护航 · \(title)",
            body: "在手表或 Mac 上点「已出发，关闭卡片」，一键收起灵动岛与手表上的护航卡",
            userInfo: ["type": "liveActivityControl", "subtype": "travel"]
        )
    }

    static func announceDeparture(sceneName: String) {
        deliver(
            identifier: departureNotificationIdentifier,
            category: departureCategoryIdentifier,
            title: "🎒 出门清点 · \(sceneName)",
            body: "在手表或 Mac 上点「全部带齐，关闭卡片」，一键确认并收起清点卡",
            userInfo: ["type": "liveActivityControl", "subtype": "departure"]
        )
    }

    /// NavigationRouter 在 didReceive 里先判过 type 后调用；只认自己的 action，
    /// 点卡片本体 / ✕ 删除走系统默认行为，不动活动状态。
    static func handle(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        guard userInfo["type"] as? String == "liveActivityControl" else { return }
        let subtype = userInfo["subtype"] as? String
        switch (subtype, response.actionIdentifier) {
        case ("travel", travelActionEnd):
            LiveActivityService.endTravelActivities()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [travelNotificationIdentifier])
        case ("departure", departureActionCheckAll):
            checkAllDepartureItems()
        default:
            break
        }
    }

    /// 卡片已被其它路径（岛内按钮、自动 end）关闭时，回前台把伴随通知摘掉，不留幽灵通知
    static func reconcile() {
        if Activity<TravelActivityAttributes>.activities.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [travelNotificationIdentifier])
        }
        if Activity<DepartureChecklistActivityAttributes>.activities.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [departureNotificationIdentifier])
        }
    }

    private static func checkAllDepartureItems() {
        // 逐项走既有桥接钩子：同时写回 DepartureCheckItem 与活动状态，
        // 最后一项勾完时 DepartureActivityHelper 会自动 end 活动
        for activity in Activity<DepartureChecklistActivityAttributes>.activities {
            for item in activity.attributes.items {
                WidgetSnapshotSyncController.shared.handleToggleDeparture(id: item.id, isChecked: true)
            }
        }
        reconcile()
    }

    private static func deliver(identifier: String, category: String, title: String, body: String, userInfo: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        // 伴随通知是安静的控制入口，不铃响打断
        content.sound = nil
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("Live activity control notification failed: \(error)") }
        }
    }
}
