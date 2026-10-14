import ActivityKit
import Foundation

// MARK: - 实时活动数据模型（主应用发起/更新，扩展渲染）

/// 快递取件实时活动：一次可挂多个待取包裹
public struct PickupParcel: Codable, Hashable, Identifiable {
    public var id: UUID
    public var code: String
    public var courier: String?
    public var title: String

    public init(id: UUID, code: String, courier: String? = nil, title: String) {
        self.id = id
        self.code = code
        self.courier = courier
        self.title = title
    }
}

public struct PickupActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 已取件的包裹 id，用于锁屏/手表端大字展示剩余取件码
        public var completedIDs: [UUID]

        public init(completedIDs: [UUID] = []) {
            self.completedIDs = completedIDs
        }
    }

    public var station: String
    public var parcels: [PickupParcel]

    public init(station: String, parcels: [PickupParcel]) {
        self.station = station
        self.parcels = parcels
    }
}

/// 取件进度计算。灵动岛紧凑态与手表大字都必须用「下一个未取」，
/// 直接用 parcels.first 会导致取完第一件之后还一直显示已取件的旧码。
public enum PickupProgress {
    public static func nextPending(parcels: [PickupParcel], completedIDs: [UUID]) -> PickupParcel? {
        parcels.first { !completedIDs.contains($0.id) }
    }

    /// 用 filter 而不是 `总数 - 已完成数`：completedIDs 里可能存在不属于本批的遗留 id。
    public static func remainingCount(parcels: [PickupParcel], completedIDs: [UUID]) -> Int {
        parcels.filter { !completedIDs.contains($0.id) }.count
    }
}

/// 行程护航实时活动（车次/航班/日程出发倒计时）
public struct TravelActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var departureDate: Date
        public var note: String?

        public init(departureDate: Date, note: String? = nil) {
            self.departureDate = departureDate
            self.note = note
        }
    }

    public var title: String
    public var place: String?
    /// 车次/航班 + 座位的一行摘要，如 "G1234 · 5车 12A"（上岛前从短信原文抽取，抽不到为 nil）
    public var ticketSummary: String?
    /// 检票口 / 登机口，如 "B12"
    public var gate: String?

    public init(title: String, place: String? = nil, ticketSummary: String? = nil, gate: String? = nil) {
        self.title = title
        self.place = place
        self.ticketSummary = ticketSummary
        self.gate = gate
    }
}

/// 出门防丢清点实时活动（身·手·钥·耳式逐项确认）
public struct DepartureChecklistActivityAttributes: ActivityAttributes {
    public struct Item: Codable, Hashable, Identifiable {
        public var id: UUID
        public var title: String
        public var isEssential: Bool

        public init(id: UUID, title: String, isEssential: Bool) {
            self.id = id
            self.title = title
            self.isEssential = isEssential
        }
    }

    public struct ContentState: Codable, Hashable {
        public var checkedIDs: [UUID]

        public init(checkedIDs: [UUID] = []) {
            self.checkedIDs = checkedIDs
        }
    }

    public var sceneName: String
    public var items: [Item]

    public init(sceneName: String, items: [Item]) {
        self.sceneName = sceneName
        self.items = items
    }
}

// MARK: - 跨进程共用的活动辅助（主应用与扩展均可调用）

public enum PickupActivityHelper {
    /// 某个快递待办被完成后：更新实时活动状态；全部取完则自动收岛
    @MainActor
    public static func markCompleted(todoID: UUID) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<PickupActivityAttributes>.activities {
            guard activity.attributes.parcels.contains(where: { $0.id == todoID }) else { continue }
            var state = activity.content.state
            guard !state.completedIDs.contains(todoID) else { continue }
            state.completedIDs.append(todoID)
            let allDone = activity.attributes.parcels.allSatisfy { state.completedIDs.contains($0.id) }
            if allDone {
                Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
            } else {
                Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            }
        }
    }

    /// 兜底：直接结束与该待办相关的实时活动
    @MainActor
    public static func endActivity(for todoID: UUID) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<PickupActivityAttributes>.activities {
            guard activity.attributes.parcels.contains(where: { $0.id == todoID }) else { continue }
            Task { await activity.end(activity.content, dismissalPolicy: .immediate) }
        }
    }
}

public enum DepartureActivityHelper {
    @MainActor
    public static func setChecked(itemID: UUID, isChecked: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<DepartureChecklistActivityAttributes>.activities {
            var state = activity.content.state
            var changed = false
            if isChecked {
                if !state.checkedIDs.contains(itemID) {
                    state.checkedIDs.append(itemID)
                    changed = true
                }
            } else if state.checkedIDs.contains(itemID) {
                state.checkedIDs.removeAll { $0 == itemID }
                changed = true
            }
            // 已勾过的项不能提前跳过：补一次全勾判定，
            // 否则旧版遗留的「全部已勾但卡未收」死卡对「全部带齐」动作永远关不掉
            let allChecked = activity.attributes.items.allSatisfy { state.checkedIDs.contains($0.id) }
            guard changed || allChecked else { continue }
            if allChecked {
                Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
            } else {
                Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            }
        }
    }
}
