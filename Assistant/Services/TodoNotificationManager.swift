import Foundation
import SwiftData
import SwiftUI
@preconcurrency import UserNotifications
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

    /// 默认开启通知详情展示；若用户在设置中手动关闭，则仅隐藏取件码、地点和个人备注，仍保留事项标题与时间副标题（对齐 Apple 原生提醒事项通知样式）。
    public var showSensitiveDetails: Bool {
        get { UserDefaults.standard.object(forKey: "todo_notification_show_sensitive_details") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "todo_notification_show_sensitive_details") }
    }

    /// 构造通知交互分类（对齐 Apple Watch 原生「提醒事项」图标按钮与精简文案）
    private func makeCategory() -> UNNotificationCategory {
        let markDoneAction = UNNotificationAction(
            identifier: Self.actionMarkDone,
            title: L10n.choose("完成", "Complete"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle.fill")
        )
        let snooze10mAction = UNNotificationAction(
            identifier: Self.actionSnooze10M,
            title: L10n.choose("10 分钟后", "In 10 Min"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")
        )
        let snoozeAction = UNNotificationAction(
            identifier: Self.actionSnooze1H,
            title: L10n.choose("1 小时后", "In 1 Hour"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock")
        )
        let snoozeTomorrowAction = UNNotificationAction(
            identifier: Self.actionSnoozeTomorrow,
            title: L10n.choose("明早 9 点", "Tomorrow 9 AM"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "sunrise.fill")
        )
        return UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            // 默认点击通知本身即可打开待办，因此把名额留给更多稍后选项。
            actions: [markDoneAction, snooze10mAction, snoozeAction, snoozeTomorrowAction],
            intentIdentifiers: [],
            options: []
        )
    }

    /// 异步注册交互式通知分类，避免冷启动时多模块并发读写 notificationCategories 造成覆盖丢失
    public func registerCategoriesAsync() async {
        let category = makeCategory()
        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.insert(category)
        center.setNotificationCategories(updated)
    }

    /// 注册交互式通知分类与快捷操作按钮（完成、推迟、查看）
    public func registerCategories() {
        Task {
            await registerCategoriesAsync()
        }
    }

    /// 判断是否为由 HabitAndMedicationScheduler 按日物化的服药计划待办。
    /// 仅由服药计划物化生成的「服药：XXX（HH:mm）」待办由专属每日循环通知负责；
    /// 用户手动新建或通过投喂口、语音创建的独立吃药待办，仍由本管理器正常排期提醒。
    private func isManagedByMedicationScheduler(_ item: TodoItem) -> Bool {
        item.type == .medication && MedicationTodoMaterializer.isMaterializedTitle(item.title)
    }

    /// 确保已取得系统通知授权后再入队通知请求，消除首次创建带时间待办时「申请权限」与「排期通知」的异步竞态
    private func enqueueNotificationRequests(_ requests: [UNNotificationRequest]) {
        guard !requests.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let submit = {
                for request in requests {
                    center.add(request) { error in
                        if let error = error {
                            print("Failed to schedule todo notification (\(request.identifier)): \(error)")
                        }
                    }
                }
            }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        submit()
                    }
                }
            } else {
                submit()
            }
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

        // 由 HabitAndMedicationScheduler 物化的每日服药计划待办已注册专属「💊 服药提醒」，
        // 不重复注册通用「待办提醒」；但用户手动新建的独立用药待办仍正常排期。
        if isManagedByMedicationScheduler(item) {
            cancelNotification(for: item.id)
            return
        }

        // 重排时先移除旧的主提醒和逾期提醒，避免编辑截止时间后留下旧通知。
        cancelNotification(for: item.id)
        let now = Date.now
        // 提前量与 override 的取舍、是否还值得排期，均由 Core 纯函数判定。
        guard let plannedReminder = TodoReminderSchedule.mainReminderDate(
            dueAt: dueAt,
            remindBeforeMinutes: item.remindBeforeMinutes,
            reminderOverrideAt: item.reminderOverrideAt,
            now: now
        ) else {
            cancelNotification(for: item.id)
            return
        }

        var pendingRequests: [UNNotificationRequest] = []

        // 仅当主提醒时刻仍在未来时排期主通知；若主提醒已过点（仅余逾期补提醒），
        // 不再在回前台对账时按 1 秒立即补发，避免总在手机亮屏前台时消耗掉通知而无法镜像到手表。
        if plannedReminder > now {
            let content = makeMainNotificationContent(for: item, dueAt: dueAt)
            let interval = max(1, plannedReminder.timeIntervalSince(now))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(
                identifier: notificationId(for: item.id),
                content: content,
                trigger: trigger
            )
            pendingRequests.append(request)
        }

        // 如果是快递包裹待办，自动同步驿站地理围栏（批量排期时统一同步，避免循环内多次派发）
        if syncGeofences && (item.type == .parcel || item.type == .returnParcel) {
            Task { @MainActor in
                LocationReminderService.shared.syncParcelStationGeofences()
            }
        }

        // 到期后仍未完成时再提醒几次，避免一次通知被忽略后事项悄悄过期。
        for offset in TodoReminderSchedule.futureOverdueOffsets(dueAt: dueAt, now: now) {
            let fireDate = dueAt.addingTimeInterval(offset)
            let overdueContent = makeOverdueNotificationContent(for: item, dueAt: dueAt, offset: offset)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let overdueRequest = UNNotificationRequest(
                identifier: overdueNotificationId(for: item.id, offset: offset),
                content: overdueContent,
                trigger: trigger
            )
            pendingRequests.append(overdueRequest)
        }

        enqueueNotificationRequests(pendingRequests)
    }

    // MARK: - Apple 原生「提醒事项 / 日历」风格通知排版（Title / Subtitle / Body 三层视觉层级）

    private func makeMainNotificationContent(for item: TodoItem, dueAt: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let conciseTitle = item.displayConciseTitle.isEmpty ? item.title : item.displayConciseTitle

        // 1. Title：直接使用事项精简标题（watchOS 顶部横幅已自带应用图标与名称，去掉冗余的「待办提醒：」前缀，突出核心事项）
        content.title = conciseTitle

        // 2. Subtitle：模拟 Apple「提醒事项 / 日历」的副标题行（展示时间、提前量或快递取件码）
        let dueTimeText = formattedWatchTime(dueAt)
        let leadText: String? = {
            guard item.remindBeforeMinutes > 0, item.reminderOverrideAt == nil else { return nil }
            if item.remindBeforeMinutes >= 1440, item.remindBeforeMinutes % 1440 == 0 {
                let days = item.remindBeforeMinutes / 1440
                return L10n.choose("提前 \(days) 天", "\(days)d early")
            } else if item.remindBeforeMinutes >= 60, item.remindBeforeMinutes % 60 == 0 {
                let hours = item.remindBeforeMinutes / 60
                return L10n.choose("提前 \(hours) 小时", "\(hours)h early")
            } else {
                return L10n.choose("提前 \(item.remindBeforeMinutes) 分钟", "\(item.remindBeforeMinutes)m early")
            }
        }()

        let place = [item.station, item.location]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let code = item.pickupCode?.trimmingCharacters(in: .whitespacesAndNewlines)

        if showSensitiveDetails, let code, !code.isEmpty {
            let codeLabel = item.type == .returnParcel
                ? L10n.choose("寄件码 \(code)", "Return Code \(code)")
                : L10n.choose("取件码 \(code)", "Pickup \(code)")
            content.subtitle = [codeLabel, place].compactMap { $0 }.joined(separator: " · ")
        } else {
            content.subtitle = [dueTimeText, leadText ?? item.type.displayName].compactMap { $0 }.joined(separator: " · ")
        }

        // 3. Body：结构化展示地点、精简备注与周期标签，避免杂乱拼接
        if showSensitiveDetails {
            var lines: [String] = []
            if (code == nil || code?.isEmpty == true), let place {
                lines.append("📍 \(place)")
            }
            if let detail = item.displayConciseDetail, !detail.isEmpty, detail != place {
                lines.append(detail)
            }
            var tags: [String] = []
            if item.isRecurring {
                tags.append("🔁 \(item.recurrenceSummaryText)")
            }
            if WeChatCommunicationHelper.isWeChatCommunication(title: item.title, detail: item.detail) {
                let kind = WeChatCommunicationHelper.communicationKind(title: item.title, detail: item.detail)
                tags.append("💬 \(kind.buttonTitle)")
            }
            if !tags.isEmpty {
                lines.append(tags.joined(separator: "  "))
            }
            content.body = lines.isEmpty
                ? L10n.choose("轻点下方按钮可直接完成或推迟。", "Tap below to complete or snooze.")
                : lines.joined(separator: "\n")
        } else {
            content.body = L10n.choose("详情已隐藏 · 轻点下方按钮可直接完成或推迟。", "Details hidden · Tap below to complete or snooze.")
        }

        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = item.remindBeforeMinutes > 0 ? 0.9 : 0.85
        content.threadIdentifier = "todo-\(item.type.rawValue)"
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "todoId": item.id.uuidString,
            "type": "todo"
        ]
        return content
    }

    private func makeOverdueNotificationContent(for item: TodoItem, dueAt: Date, offset: TimeInterval) -> UNMutableNotificationContent {
        let overdueContent = UNMutableNotificationContent()
        let conciseTitle = item.displayConciseTitle.isEmpty ? item.title : item.displayConciseTitle
        overdueContent.title = conciseTitle

        let overdueBadge: String = {
            let hours = Int(round(offset / 3600))
            if hours >= 24 {
                let days = max(1, hours / 24)
                return L10n.choose("已逾期 \(days) 天", "\(days)d Overdue")
            }
            return L10n.choose("已逾期 \(max(1, hours)) 小时", "\(max(1, hours))h Overdue")
        }()
        let dueTimeText = formattedWatchTime(dueAt)
        overdueContent.subtitle = L10n.choose("\(overdueBadge) · 原定 \(dueTimeText)", "\(overdueBadge) · Due \(dueTimeText)")

        if showSensitiveDetails {
            let place = [item.station, item.location]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            var snippets: [String] = []
            if let code = item.pickupCode, !code.isEmpty {
                snippets.append(L10n.choose("取件码 \(code)", "Code \(code)"))
            }
            if let place {
                snippets.append("📍 \(place)")
            }
            if let detail = item.displayConciseDetail, !detail.isEmpty, detail != place {
                snippets.append(detail)
            }
            overdueContent.body = snippets.isEmpty
                ? L10n.choose("事项尚未完成，轻点下方可标记完成或推迟。", "Still pending. Tap below to complete or snooze.")
                : snippets.joined(separator: " · ")
        } else {
            overdueContent.body = L10n.choose("事项尚未完成，轻点下方可标记完成或推迟。", "Still pending. Tap below to complete or snooze.")
        }

        overdueContent.sound = .default
        overdueContent.interruptionLevel = .timeSensitive
        overdueContent.relevanceScore = 0.95
        overdueContent.threadIdentifier = "todo-\(item.type.rawValue)"
        overdueContent.categoryIdentifier = Self.categoryIdentifier
        overdueContent.userInfo = ["todoId": item.id.uuidString, "type": "todo"]
        return overdueContent
    }

    private func formattedWatchTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let timeStr = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return L10n.choose("今天 \(timeStr)", "Today \(timeStr)")
        } else if calendar.isDateInTomorrow(date) {
            return L10n.choose("明天 \(timeStr)", "Tomorrow \(timeStr)")
        } else if calendar.isDateInYesterday(date) {
            return L10n.choose("昨天 \(timeStr)", "Yesterday \(timeStr)")
        } else {
            return date.formatted(date: .abbreviated, time: .shortened)
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
        // 仅排除由 HabitAndMedicationScheduler 按日物化的服药计划待办；
        // 用户手动创建的独立用药待办仍纳入通用通知排期。
        let schedulableItems = allItems.filter { !isManagedByMedicationScheduler($0) }
        // 筛选、排序与 15 项截断口径下沉到 Core；这里只做快照转换与回填。
        let itemByID = Dictionary(schedulableItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshots = schedulableItems.map {
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
