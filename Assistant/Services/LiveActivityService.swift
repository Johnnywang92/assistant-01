import ActivityKit
import AssistantCore
import Foundation
import SwiftData

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
            return true
        } catch {
            print("Failed to start departure checklist activity: \(error)")
            return false
        }
    }

    // MARK: - 结束活动

    static func endPickupActivities() {
        for activity in Activity<PickupActivityAttributes>.activities {
            Task { await activity.end(using: activity.content.state, dismissalPolicy: .immediate) }
        }
    }

    static func endTravelActivities() {
        for activity in Activity<TravelActivityAttributes>.activities {
            Task { await activity.end(using: activity.content.state, dismissalPolicy: .immediate) }
        }
    }

    static func endDepartureActivities() {
        for activity in Activity<DepartureChecklistActivityAttributes>.activities {
            Task { await activity.end(using: activity.content.state, dismissalPolicy: .immediate) }
        }
    }
}
