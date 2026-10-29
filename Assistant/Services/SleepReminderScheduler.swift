import AssistantCore
import Foundation
import UserNotifications

/// 睡前提醒的调度层：把 Core 算出的 `SleepPlan` 变成系统通知/卡片状态。
///
/// ## 触发结构（两层，解决「不开 App 就没提醒」的单点失效）
/// - **兜底层**：每次进前台（任意时段）为「本夜 + 未来 2 夜」计算计划并注册通知。
///   计划的修正项只含睡眠债（基于近 7 夜，白天任意时刻都已是完整事实），
///   不依赖当日未收工的数据。identifier 按夜幂等，重复进前台只是覆盖时刻。
/// - **精修层**：夜间时段进前台时用最新数据重算本夜并覆盖同 identifier。
///   若原通知已送达（delivered），去重规则拦截，不会补发第二条。
///
/// P1 的 energyAdj 恒为 0（Core 侧 `SleepReminderPlanner.energyAdjustment`），
/// 两层在数值上暂时重合；P2 引入白天活力修正后自动获得「白天粗算、夜间精修」的分工。
///
/// ## 每夜最多提醒一次（审查 B）
/// `alreadyReminded` = delivered 含本夜 identifier ∨ `lastRemindedNightKey == 本夜`。
/// 一旦观察到送达就持久化 nightKey，用户清掉通知中心也不会导致重发。
/// `.immediate`（T_fire 已过、T_bed 未到）只推卡片状态，绝不发「now+2min」通知。
@MainActor
final class SleepReminderScheduler: ObservableObject {
    static let shared = SleepReminderScheduler()

    /// 今晚的计划（「今晚睡眠」卡的数据源）；nil = 尚未同步或本夜已跳过
    @Published private(set) var tonightPlan: SleepPlan?
    /// 通知权限被拒（UI 须显示去系统设置的降级文案，不得显示「已为你安排今晚提醒」）
    @Published private(set) var notificationDenied = false

    // MARK: 持久化设置

    private enum Keys {
        static let enabled = "sleepReminder.enabled"
        static let desiredHHmm = "sleepReminder.desiredBedtime"
        static let pseudoDesiredHHmm = "sleepReminder.pseudoDesiredBedtime"
        static let windDown = "sleepReminder.windDownMinutes"
        static let goal = "sleepReminder.sleepGoalMinutes"
        static let lastRemindedNight = "sleepReminder.lastRemindedNightKey"
    }

    /// 通知交互分类：「推迟 20 分钟」（用户显式要求的补提醒，不受「每夜一次」限制）
    static let categoryIdentifier = "SLEEP_BEDTIME_CATEGORY"
    static let actionSnooze20M = "ACTION_SLEEP_SNOOZE_20M"

    // 设置项 setter 触发 objectWillChange，让设置页/卡片上的 Binding 能即时刷新
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
        }
    }

    /// 期望就寝时间（引导页一次填写；"HH:mm"，00:30 表示次日凌晨）
    var desiredBedtimeHHmm: String? {
        get { UserDefaults.standard.string(forKey: Keys.desiredHHmm) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.desiredHHmm)
        }
    }

    /// 用户是否已填写期望就寝时间（空串/非法值视为未填写）
    var hasDesiredBedtime: Bool {
        desiredBedtimeHHmm.flatMap { SleepNightNormalizer.offset(hourMinute: $0) } != nil
    }

    /// 冻结的 pseudo-desired（14 夜后自动学习，只写一次）
    private var pseudoDesiredHHmm: String? {
        UserDefaults.standard.string(forKey: Keys.pseudoDesiredHHmm)
    }

    var windDownMinutes: Int {
        get { UserDefaults.standard.object(forKey: Keys.windDown) as? Int ?? 30 }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.windDown)
        }
    }

    var sleepGoalMinutes: Int {
        get { UserDefaults.standard.object(forKey: Keys.goal) as? Int ?? 420 }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.goal)
        }
    }

    // MARK: 通知分类与交互

    /// 注册睡前提醒的通知分类（「推迟 20 分钟」）。启动时调用一次。
    static func registerCategory() {
        let snooze = UNNotificationAction(
            identifier: actionSnooze20M,
            title: "推迟 20 分钟",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var updated = existing
            updated.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(updated)
        }
    }

    /// 通知快捷操作回调（AppDelegate 转发）。
    /// 「推迟 20 分钟」是用户显式要求的补提醒：绕过「每夜最多一条」，
    /// 用独立 identifier 注册一次性 +20min 通知，不覆盖本夜主提醒记录。
    static func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == actionSnooze20M else { return }
        let original = response.notification.request
        let content = UNMutableNotificationContent()
        content.title = original.content.title
        content.body = original.content.body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = original.content.userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 20 * 60, repeats: false)
        let request = UNNotificationRequest(
            identifier: original.identifier + "-snooze",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Failed to snooze sleep reminder: \(error)")
            }
        }
    }

    // MARK: 巡检入口

    /// 前台巡检调用（幂等）。计算本夜 + 未来 2 夜并注册/清理通知。
    func syncSleepReminders() async {
        guard isEnabled, HealthKitService.isAvailable else {
            tonightPlan = nil
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized = (settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral)
        notificationDenied = settings.authorizationStatus == .denied

        let now = Date.now
        let calendar = Calendar.current
        let samples = await HealthKitService.shared.fetchSleepNights(days: 28)
        let userDesiredOffset = desiredBedtimeHHmm.flatMap { SleepNightNormalizer.offset(hourMinute: $0) }

        // pseudo-desired：从未填写期望且样本攒够 14 夜 → 把当时习惯**冻结**为长期锚
        // （只冻结一次，此后不跟随习惯漂移——这正是防「提醒把习惯带偏」反馈环的目的）
        if userDesiredOffset == nil,
           SleepReminderPlanner.shouldFreezePseudoDesired(hasDesired: false, sampleCount: samples.count) {
            freezePseudoDesired(samples: samples, now: now, calendar: calendar)
        }
        let desiredOffset = userDesiredOffset
            ?? pseudoDesiredHHmm.flatMap { SleepNightNormalizer.offset(hourMinute: $0) }
        let tonightKey = SleepNightNormalizer.nightKey(for: now, calendar: calendar)

        // 查已送达（每夜最多一次的权威依据）；观察到送达即固化 nightKey，
        // 用户清掉通知中心也不会导致重发
        let deliveredIDs = Set(await center.deliveredNotifications().map(\.request.identifier))

        var tonight: SleepPlan?
        for dayOffset in 0...2 {
            guard let nightKey = calendar.date(byAdding: .day, value: dayOffset, to: tonightKey) else { continue }
            let plan = SleepReminderPlanner.plan(.init(
                now: now,
                calendar: calendar,
                nightKey: nightKey,
                samples: samples,
                desiredBedtimeOffset: desiredOffset,
                sleepGoalMinutes: sleepGoalMinutes,
                windDownMinutes: windDownMinutes
            ))

            let id = SleepReminderPlanner.notificationID(nightKey: plan.nightKey, calendar: calendar)
            let alreadyReminded = deliveredIDs.contains(id) || lastRemindedNightKey == plan.nightKey
            if deliveredIDs.contains(id) {
                lastRemindedNightKey = plan.nightKey
            }

            let action = SleepReminderPolicy.action(
                plan: plan,
                alreadyReminded: alreadyReminded,
                notificationAuthorized: authorized
            )

            switch action {
            case .schedule(let fireAt):
                registerNotification(plan: plan, fireAt: fireAt, id: id)
            case .showCardOnly:
                // 前台临场时段：只亮卡片，不发通知；清掉可能存在的旧注册
                await center.removePendingNotificationRequests(withIdentifiers: [id])
            case .none:
                // 已提醒过 / 计划跳过 / 权限拒绝：一律清掉本夜注册，杜绝补发
                await center.removePendingNotificationRequests(withIdentifiers: [id])
            }
            if dayOffset == 0 {
                tonight = plan // 卡片也展示 skipped（越界/过点时 UI 需要据此显示降级文案）
            }
        }
        tonightPlan = tonight
    }

    // MARK: 私有

    private var lastRemindedNightKey: Date? {
        get {
            guard let ts = UserDefaults.standard.object(forKey: Keys.lastRemindedNight) as? Double else { return nil }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970, forKey: Keys.lastRemindedNight)
        }
    }

    /// 冻结 pseudo-desired 时的锚点 = 习惯中位（当前样本组）。
    /// 只在 pseudo 为空时冻结一次。
    private func freezePseudoDesired(samples: [SleepNightSample], now: Date, calendar: Calendar) {
        guard pseudoDesiredHHmm == nil else { return }
        let plan = SleepReminderPlanner.plan(.init(
            now: now,
            calendar: calendar,
            nightKey: SleepNightNormalizer.nightKey(for: now, calendar: calendar),
            samples: samples,
            desiredBedtimeOffset: nil
        ))
        guard let habit = plan.habitOffset else { return }
        UserDefaults.standard.set(SleepNightNormalizer.hourMinute(offset: habit), forKey: Keys.pseudoDesiredHHmm)
    }

    private func registerNotification(plan: SleepPlan, fireAt: Date, id: String) {
        let content = UNMutableNotificationContent()
        content.title = SleepPlanCopy.headline(for: plan)
        content.body = SleepPlanCopy.body(for: plan)
        content.sound = .default
        // 挂上「推迟 20 分钟」动作；userInfo 供 AppDelegate 路由
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["type": "sleepBedtime", "nightId": id]

        // 墙上时钟触发（DST 安全）：一次性、不重复
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        comps.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        // 同 identifier 直接覆盖（幂等）；先移后加以保证覆盖语义一致
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(request) { error in
            if let error {
                print("Failed to schedule sleep reminder: \(error)")
            }
        }
    }
}
