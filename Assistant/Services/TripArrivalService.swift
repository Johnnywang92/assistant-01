import CoreMotion
import Foundation
import SwiftData
import UserNotifications
import AssistantCore

/// 到站/落地前的随身物品清点提醒。
/// 分工与 AssistantCore 的 TripArrivalSchedule 一致：票面或用户手选决定交通方式，
/// CoreMotion 只用于判断「先前在途、最近已停下」以提前发提醒，时间负责兜底。
/// 说明：系统只在 App 存活时投递运动更新，因此机票/车票行程以排期通知为准，
/// 开车/骑行行程在 App 可用时才能享受「刚停下就提醒」。
@MainActor
final class TripArrivalService {
    static let shared = TripArrivalService()

    static let categoryIdentifier = "TRIP_ARRIVAL_CATEGORY"
    static let actionStartCheck = "ACTION_TRIP_START_CHECK"
    static let actionSnooze10M = "ACTION_TRIP_SNOOZE_10M"

    private static let userInfoType = "tripArrival"

    private let motionManager = CMMotionActivityManager()
    private let motionQueue = OperationQueue()
    /// 滚动保留的近期运动采样，仅用于停走判定
    private var recentSamples: [TripArrivalSchedule.MotionSample] = []
    private var isMonitoringMotion = false

    private init() {
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.name = "com.yifanwang.assistant01.triparrival.motion"
    }

    static func notificationId(for itemId: UUID) -> String {
        "trip-arrival-\(itemId.uuidString)"
    }

    /// 点「10 分钟后再提醒」用的独立标识：必须与主提醒分开，
    /// 否则下一次前台全量对账会因为「本次已提醒过」把它一并撤掉。
    static func snoozeNotificationId(for itemId: UUID) -> String {
        "trip-arrival-\(itemId.uuidString)-snooze"
    }

    // MARK: - 通知分类

    /// 「开始清点」立刻拉起到灵动岛/Mac 都能点的动作，默认点横幅也进清点页
    func registerCategory() async {
        let startCheck = UNNotificationAction(
            identifier: Self.actionStartCheck,
            title: L10n.tr("开始清点"),
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "checklist")
        )
        let snooze = UNNotificationAction(
            identifier: Self.actionSnooze10M,
            title: L10n.tr("10 分钟后"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [startCheck, snooze],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.insert(category)
        center.setNotificationCategories(updated)
    }

    // MARK: - 排期

    /// 依据待办的到达时间排期或撤销到站清点提醒
    func syncReminder(for item: TodoItem, now: Date = .now) {
        guard item.status == .active, let arrival = item.arrivalReminderAt else {
            cancelReminder(for: item.id)
            return
        }
        let kind = item.arrivalTransportKind
        let windowStart = arrival.addingTimeInterval(-TripArrivalSchedule.advanceLead(for: kind))
        let deadline = arrival.addingTimeInterval(TripArrivalSchedule.backstopGrace)

        if let fired = item.arrivalCheckFiredAt,
           fired >= windowStart.addingTimeInterval(-TripArrivalSchedule.firedTolerance) {
            cancelReminder(for: item.id)
            return
        }
        guard now < deadline else {
            cancelReminder(for: item.id)
            return
        }
        // 还没进提前窗口就按提前点排期；已经进了窗口就改按到达时间挂一条兜底排期——
        // evaluate 只在 App 活着时才跑得到，App 一被杀掉这趟行程不能一条提醒都不剩。
        let fireDate = windowStart > now ? windowStart : arrival
        guard fireDate > now else {
            cancelReminder(for: item.id)
            return
        }

        let content = makeContent(for: item, kind: kind)
        let request = UNNotificationRequest(
            identifier: Self.notificationId(for: item.id),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireDate.timeIntervalSinceNow),
                repeats: false
            )
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("⚠️ [TripArrival] 到站清点提醒排期失败: \(error)") }
        }
    }

    func cancelReminder(for itemId: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationId(for: itemId)])
    }

    /// 行程真正结束（完成/删除/重排）时把主提醒与延后提醒一起撤掉
    func cancelAllReminders(for itemId: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.notificationId(for: itemId),
            Self.snoozeNotificationId(for: itemId)
        ])
    }

    /// 全量对账：设了到达时间的活跃待办重新排期，已完成/已提醒/过期的撤销
    func syncAllReminders(context: ModelContext) {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.arrivalReminderAt != nil })
        for item in (try? context.fetch(descriptor)) ?? [] {
            syncReminder(for: item)
        }
    }

    /// 用户改到达时间后清掉上一趟行程的残留横幅，避免新行程被旧横幅误判为已提醒
    func clearHistory(for itemId: UUID) {
        let ids = [Self.notificationId(for: itemId), Self.snoozeNotificationId(for: itemId)]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func makeContent(for item: TodoItem, kind: TripArrivalSchedule.TransportKind) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = L10n.tr(Self.headlineKey(for: kind))
        let showDetails = TodoNotificationManager.shared.showSensitiveDetails
        if showDetails {
            let conciseTitle = item.displayConciseTitle.isEmpty ? item.title : item.displayConciseTitle
            content.subtitle = [conciseTitle, item.displayLocationText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            content.body = L10n.choose("下车/落地前核对座位与行李架，轻点「开始清点」逐项确认。", "Check your seat and rack before leaving. Tap Start Check below.")
        } else {
            content.subtitle = kind.displayName
            content.body = L10n.tr("到站前核对随身物品，点「开始清点」逐项确认。")
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 0.9
        content.threadIdentifier = "trip-arrival"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "type": Self.userInfoType,
            "todoId": item.id.uuidString
        ]
        return content
    }

    private static func headlineKey(for kind: TripArrivalSchedule.TransportKind) -> String {
        switch kind {
        case .flight: return "飞机即将落地，检查随身物品"
        case .train: return "列车即将到站，检查随身物品"
        case .metro: return "地铁即将到站，检查随身物品"
        case .bus: return "公交即将到站，检查随身物品"
        case .automobile: return "即将到达，检查后座与后备箱"
        case .bicycle: return "即将到达，检查随身物品"
        case .unknown: return "行程即将到达，检查随身物品"
        }
    }

    // MARK: - 巡检与运动证据

    /// 对所有开启到站清点的活跃待办做一次判定：该弹就弹，该撤就撤。
    func evaluate(context: ModelContext, now: Date = .now) async {
        let items = pendingItems(context: context)
        guard !items.isEmpty else {
            stopMotionMonitoring()
            return
        }

        let identifiers = Set(items.map { Self.notificationId(for: $0.id) })
        let delivered = await deliveredIdentifiers(matching: identifiers)

        var needsMotionWatch = false
        for item in items {
            let kind = item.arrivalTransportKind
            // 系统横幅已经弹过但没写回时间（用户在通知里直接划掉）：按已提醒处理，不再补发
            if item.arrivalCheckFiredAt == nil,
               delivered.contains(Self.notificationId(for: item.id)),
               let arrival = item.arrivalReminderAt {
                item.arrivalCheckFiredAt = arrival.addingTimeInterval(
                    -TripArrivalSchedule.advanceLead(for: kind)
                )
            }
            let stopped = kind.supportsMotionEvidence && TripArrivalSchedule.isStoppedAfterTransit(
                samples: recentSamples,
                transportKind: kind,
                now: now
            )
            let outcome = TripArrivalSchedule.decide(
                expectedArrivalAt: item.arrivalReminderAt,
                firedAt: item.arrivalCheckFiredAt,
                transportKind: kind,
                stoppedConfirmed: stopped,
                now: now
            )
            switch outcome {
            case .fire(let trigger):
                fire(item: item, trigger: trigger, now: now)
            case .notYet(let reason):
                if reason == .awaitingStopEvidence, kind.supportsMotionEvidence {
                    needsMotionWatch = true
                }
            case .expired:
                cancelReminder(for: item.id)
            }
        }

        try? context.save()
        updateMotionMonitoring(needsWatch: needsMotionWatch)
    }

    /// 提前量窗口内由运动证据或到点触发的即时提醒
    private func fire(item: TodoItem, trigger: TripArrivalSchedule.Trigger, now: Date) {
        item.arrivalCheckFiredAt = now
        let id = Self.notificationId(for: item.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id, Self.snoozeNotificationId(for: item.id)])
        let content = makeContent(for: item, kind: item.arrivalTransportKind)
        if trigger == .motionStopped {
            content.body = L10n.tr("已检测到停车/下车，趁刚下车清点一遍随身物品。")
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func pendingItems(context: ModelContext) -> [TodoItem] {
        let activeRaw = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate {
            $0.statusRaw == activeRaw && $0.arrivalReminderAt != nil
        })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func deliveredIdentifiers(matching identifiers: Set<String>) async -> Set<String> {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return Set(delivered.map(\.request.identifier)).intersection(identifiers)
    }

    // MARK: - 运动采样

    /// 运动权限按需申请：只在用户为某个待办开启到站提醒、且方式靠运动提前时才弹系统框
    func requestMotionAuthorizationIfNeeded(for kind: TripArrivalSchedule.TransportKind) {
        guard kind.supportsMotionEvidence else { return }
        guard CMPedometer.authorizationStatus() == .notDetermined else { return }
        // 用一次性历史查询触发系统授权弹窗，结果不关心
        motionManager.queryActivityStarting(
            from: Date(timeIntervalSinceNow: -60),
            to: Date(),
            to: motionQueue
        ) { [weak self] activities, _ in
            DispatchQueue.main.async { self?.ingest(activities ?? [], now: Date()) }
        }
    }

    private func updateMotionMonitoring(needsWatch: Bool) {
        guard CMPedometer.authorizationStatus() == .authorized else {
            stopMotionMonitoring()
            return
        }
        if needsWatch {
            startMotionMonitoring()
        } else {
            stopMotionMonitoring()
        }
    }

    private func startMotionMonitoring() {
        guard !isMonitoringMotion else { return }
        isMonitoringMotion = true
        motionManager.startActivityUpdates(to: motionQueue) { [weak self] activity in
            guard let activity else { return }
            DispatchQueue.main.async {
                self?.ingest([activity], now: Date())
            }
        }
    }

    private func stopMotionMonitoring() {
        guard isMonitoringMotion else { return }
        isMonitoringMotion = false
        motionManager.stopActivityUpdates()
    }

    private func ingest(_ activities: [CMMotionActivity], now: Date) {
        let cutoff = now.addingTimeInterval(-TripArrivalSchedule.motionLookback)
        recentSamples.append(contentsOf: activities.map { sample(from: $0) })
        recentSamples.removeAll { $0.date < cutoff || $0.date > now }
    }

    private func sample(from activity: CMMotionActivity) -> TripArrivalSchedule.MotionSample {
        let kind: TripArrivalSchedule.MotionSample.Activity
        if activity.automotive {
            kind = .automotive
        } else if activity.cycling {
            kind = .cycling
        } else if activity.running {
            kind = .running
        } else if activity.walking {
            kind = .walking
        } else if activity.stationary {
            kind = .stationary
        } else {
            kind = .unknown
        }
        let confidence: TripArrivalSchedule.MotionSample.Confidence
        switch activity.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        case .low: confidence = .low
        @unknown default: confidence = .unknown
        }
        return TripArrivalSchedule.MotionSample(
            date: Date(timeIntervalSince1970: activity.timestamp),
            activity: kind,
            confidence: confidence
        )
    }

    // MARK: - 通知交互

    /// NavigationRouter 在 didReceive 里判过 type 后调用
    static func handle(_ response: UNNotificationResponse, context: ModelContext) {
        guard response.notification.request.content.userInfo["type"] as? String == userInfoType,
              let idString = response.notification.request.content.userInfo["todoId"] as? String,
              let todoId = UUID(uuidString: idString) else { return }
        let actionId = response.actionIdentifier
        guard actionId == actionStartCheck
            || actionId == actionSnooze10M
            || actionId == UNNotificationDefaultActionIdentifier else { return }

        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == todoId })
        guard let item = (try? context.fetch(descriptor))?.first else { return }

        let now = Date.now
        switch actionId {
        case actionSnooze10M:
            // 只再问一次：改写触发时间并撤掉本次排期，不改动到达时间本身
            item.arrivalCheckFiredAt = now
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [notificationId(for: todoId)])
            let content = UNMutableNotificationContent()
            content.title = L10n.tr("该清点随身物品了")
            content.body = L10n.tr("上一趟行程还没确认，点「开始清点」逐项核对。")
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = ["type": userInfoType, "todoId": todoId.uuidString]
            center.add(UNNotificationRequest(
                identifier: snoozeNotificationId(for: todoId),
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
            ))
            try? context.save()

        default:
            item.arrivalCheckFiredAt = now
            try? context.save()
            Task { @MainActor in
                NavigationRouter.shared.selectedTab = .departure
                // 抬腕/锁屏点「开始清点」时顺手把清单推上灵动岛，摘下手机也能逐项确认
                let checkItems = (try? context.fetch(FetchDescriptor<DepartureCheckItem>())) ?? []
                if !LiveActivityService.hasDepartureActivity {
                    _ = LiveActivityService.startDepartureChecklist(sceneName: L10n.tr("到站清点"), items: checkItems)
                }
            }
        }
    }
}

extension TripArrivalSchedule.TransportKind {
    var displayName: String {
        switch self {
        case .flight: return L10n.tr("飞机")
        case .train: return L10n.tr("火车/高铁")
        case .metro: return L10n.tr("地铁")
        case .bus: return L10n.tr("公交车")
        case .automobile: return L10n.tr("开车/打车")
        case .bicycle: return L10n.tr("骑行")
        case .unknown: return L10n.tr("暂不确定")
        }
    }

    var iconName: String {
        switch self {
        case .flight: return "airplane"
        case .train: return "train.side.front.car"
        case .metro: return "tram.fill"
        case .bus: return "bus.fill"
        case .automobile: return "car.fill"
        case .bicycle: return "bicycle"
        case .unknown: return "questionmark.circle"
        }
    }

    var advanceLeadMinutes: Int {
        Int(TripArrivalSchedule.advanceLead(for: self) / 60)
    }
}
