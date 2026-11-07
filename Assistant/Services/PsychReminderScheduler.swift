import AssistantCore
import Foundation
import SwiftData
import SwiftUI
@preconcurrency import UserNotifications

/// 心理状态提醒调度器。
///
/// ## 设计原则：不打扰优先
///
/// 心理健康场景里，通知是双刃剑：提醒得当能让人被看见，提醒过度则让人
/// 把「被提醒」读成「我有病」，进而关掉通知——这个功能就永久失效了。
///
/// 因此本调度器的排期策略是：
/// - **默认关闭**。用户主动开启后才排期。
/// - **只在两种情况下发声**：到期该复评、或趋势连续上行。
/// - **低分档完全不发声**（判定在 Core 的 `PsychReminderPolicy` 里）。
/// - **冷却期去重**：同一件事 14 天内不重复提醒。
///
/// ## 为什么周度提醒用固定 weekday 是安全的
///
/// `UNCalendarNotificationTrigger` 在「当月没有这一天」时**静默不触发**——
/// 这就是「每月 31 号」的坑（2/4/6/9/11 月直接消失且不报错）。
/// 但**星期几永远存在**，所以 `weekday` + `hour` + `minute` 的重复触发器
/// 不会遇到短月失效问题，无需像月报那样枚举真实日期。
@MainActor
public final class PsychReminderScheduler {
    public static let shared = PsychReminderScheduler()

    private init() {}

    // MARK: - 偏好

    /// 通知总开关。
    @AppStorage("psych_reminder_enabled") public var isEnabled: Bool = false

    /// 每周复评提醒开关。
    @AppStorage("psych_reminder_assessment_enabled") public var isAssessmentReminderEnabled: Bool = true

    /// 趋势上行提醒开关。
    @AppStorage("psych_reminder_trend_enabled") public var isTrendReminderEnabled: Bool = true

    /// 每周提醒的星期几（1 = 周日 ... 7 = 周六）。默认周一。
    @AppStorage("psych_reminder_weekday") public var assessmentWeekday: Int = 2

    /// 每周提醒时刻（距当日零点的秒数）。默认 20:00。
    @AppStorage("psych_reminder_time_interval") private var assessmentTimeInterval: Double = 20 * 3600

    /// 趋势提醒时刻（距当日零点的秒数）。默认 19:00。
    @AppStorage("psych_reminder_trend_time_interval") private var trendTimeInterval: Double = 19 * 3600

    /// 上次提醒时间（用于冷却窗口）。
    ///
    /// 这是**运行时状态**不是用户偏好——换机后不该把「已经提醒过」搬过去，
    /// 所以不走 `@AppStorage` 白名单（那会让它进备份）。
    @AppStorage("psych_reminder_last_notified_at") private var lastNotifiedTimestamp: Double = 0

    /// 上次提醒类型（冷却窗口按类型分别计算）。同属运行时状态。
    @AppStorage("psych_reminder_last_kind") private var lastNotifiedKind: String = ""

    /// 通知前缀。用于批量清理旧通知。
    private static let notificationPrefix = "psych-reminder-"

    /// 通知分类标识。
    static let categoryIdentifier = "PSYCH_REMINDER"

    /// 上次提醒时间。
    private var lastNotifiedAt: Date? {
        get { lastNotifiedTimestamp > 0 ? Date(timeIntervalSince1970: lastNotifiedTimestamp) : nil }
        set { lastNotifiedTimestamp = newValue?.timeIntervalSince1970 ?? 0 }
    }

    // MARK: - 通知分类

    /// 构造通知分类（带「现在去测」按钮）。
    public static func makeCategory() -> UNNotificationCategory {
        let open = UNNotificationAction(
            identifier: "PSYCH_ACTION_OPEN",
            title: L10n.tr("现在去测"),
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
    }

    // MARK: - 合并式重排（串行，杜绝回调清空的竞态）

    /// 正在执行的重排任务；对它的读写都在主线程，天然串行。
    private var rescheduleTask: Task<Void, Never>?
    /// 重排期间又有设置变更 → 结束后按最新期望再跑一轮。
    private var needsAnotherPass = false
    /// 最新一轮的期望请求，由同步入口构造好（纯计算，不碰系统）。
    private var pendingDesired: [UNNotificationRequest] = []

    /// 重新排期心理提醒（同步壳，供开关 Binding 与前台巡检调用）。
    ///
    /// 旧实现在 `getPendingNotificationRequests` 的**异步回调**里按前缀清空，
    /// 紧接着同步 `center.add` —— 两者没有顺序保证；固定 identifier 的
    /// `psych-reminder-assessment` 必然落在待删清单里，remove 晚于 add 就会
    /// 把刚排好的提醒一起删掉，表现为「打开开关后每周复评不响」。
    /// 现在只做合并入队，系统读写全部在一条串行链路里 `await`。
    public func rescheduleNotifications(context: ModelContext) {
        let desired = makeDesiredRequests(context: context, now: .now)
        enqueueReschedule(desired: desired)
    }

    /// 前台巡检专用：等本轮重排真正结束再返回，避免 fire-and-forget 把
    /// 系统读写挂到切后台之后、或让节流提前记账。
    public func rescheduleNotificationsAndWait(context: ModelContext) async {
        let desired = makeDesiredRequests(context: context, now: .now)
        enqueueReschedule(desired: desired)
        await rescheduleTask?.value
    }

    private func enqueueReschedule(desired: [UNNotificationRequest]) {
        pendingDesired = desired
        if rescheduleTask != nil {
            needsAnotherPass = true
            return
        }
        // 不取消正在写入的任务（会留下半套排期）；期间有新变更就补跑一轮。
        rescheduleTask = Task { @MainActor [weak self] in
            defer { self?.rescheduleTask = nil }
            while !Task.isCancelled {
                guard let self else { break }
                self.needsAnotherPass = false
                let batch = self.pendingDesired
                await self.rebuildNotifications(desired: batch)
                guard self.needsAnotherPass else { break }
            }
        }
    }

    /// 一次完整重排：读存量 → 差量对账 → 授权 → 先删 → 逐条注册。
    /// 与 `TodoNotificationManager` / `PeriodicReportManager` 的对账口径一致。
    private func rebuildNotifications(desired: [UNNotificationRequest]) async {
        let center = UNUserNotificationCenter.current()
        let prefix = Self.notificationPrefix
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()

        // 权限被关掉时清掉本模块残留：日后重新授权不该突然冒出旧时间点。
        if settings.authorizationStatus == .denied {
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
            return
        }

        let existing = pending.filter { $0.identifier.hasPrefix(prefix) }
        var expected: [String: UNNotificationRequest] = [:]
        for request in desired { expected[request.identifier] = request }

        // 差量对账：内容 / 触发时刻没变的通知保持原样，不再每轮全删全加。
        // 趋势提醒的一次性通知 identifier 带 fireDate 时间戳，跨天自然换新。
        var staleIDs = Set<String>()
        var toAdd: [UNNotificationRequest] = []
        for request in existing {
            guard let want = expected[request.identifier] else {
                // 总开关关掉、复评开关关掉、或趋势不再上行。
                staleIDs.insert(request.identifier)
                continue
            }
            if NotificationBudget.fingerprint(of: request) != NotificationBudget.fingerprint(of: want) {
                staleIDs.insert(request.identifier)
                toAdd.append(want)
            }
        }
        let existingIDs = Set(existing.map(\.identifier))
        for (identifier, want) in expected where !existingIDs.contains(identifier) {
            toAdd.append(want)
        }

        // 统一过预算：与报告 / 待办 / 服药共用一套优先级和抑制名单。
        // 这一步同时解决「心理模块绕开预算直接 add」和「被统一裁剪后立刻加回」。
        let admission = NotificationBudget.admit(
            pending: pending.filter { !staleIDs.contains($0.identifier) },
            requested: toAdd.map { NotificationBudget.Item(request: $0, priority: .psych) },
            source: "psychReminders"
        )
        // 被预算拒绝的「替换型」请求保留旧通知，避免出现「旧的删了、新的没排上」。
        let rejectedIDs = Set(admission.rejected.map { $0.request.identifier })
        let stale = staleIDs.subtracting(rejectedIDs)
        let removals = stale.union(admission.evictedIdentifiers)
        if !removals.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(removals))
        }

        let accepted = admission.accepted.map(\.request)
        // 心理健康场景 **默认关闭**：只有确实要新增通知、且授权还没问过时才弹权限框。
        // 否则光是进前台巡检就会为一个用户从没开过的功能索要通知权限。
        if !accepted.isEmpty && settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { return }
            } catch {
                print("⚠️ [PsychReminders] 请求通知授权失败：\(error)")
                return
            }
        }

        for request in accepted {
            do {
                try await center.add(request)
            } catch {
                print("⚠️ [PsychReminders] 注册失败 \(request.identifier)：\(error)")
            }
        }
        if !admission.rejected.isEmpty {
            print("⚠️ [PsychReminders] 通知预算不足，\(admission.rejected.count) 条提醒本轮未排期，下次前台对账重试")
        }
    }

    /// 按当前开关与历史得分构造本轮期望的请求（纯计算，无任何系统调用）。
    /// `now` 由调用方传入，保证一次重排内所有判定基于同一时刻。
    private func makeDesiredRequests(context: ModelContext, now: Date) -> [UNNotificationRequest] {
        guard isEnabled else { return [] }
        let cal = Calendar.current
        var result: [UNNotificationRequest] = []
        result.reserveCapacity(2)

        // 1. 每周复评提醒（固定 weekday，星期几永远存在，不会短月失效）。
        if isAssessmentReminderEnabled {
            var comps = DateComponents()
            comps.weekday = assessmentWeekday
            comps.hour = Int(assessmentTimeInterval / 3600) % 24
            comps.minute = Int(assessmentTimeInterval.truncatingRemainder(dividingBy: 3600) / 60)

            let content = UNMutableNotificationContent()
            content.title = L10n.tr("该做一次心理状态评估了")
            content.body = L10n.tr("两分钟，问自己九个问题。分数只描述这两周的状态，不做任何诊断。")
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = ["type": "psych-reminder", "kind": "assessment-due"]

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            result.append(UNNotificationRequest(
                identifier: "\(Self.notificationPrefix)assessment",
                content: content,
                trigger: trigger
            ))
        }

        // 2. 趋势上行提醒（一次性，排到下一个提醒时刻）。
        if isTrendReminderEnabled {
            let history = loadHistory(context: context)
            let decision = PsychReminderPolicy.decide(
                history: history,
                lastNotifiedAt: lastNotifiedAt,
                now: now,
                calendar: cal
            )
            // 只在「趋势上行」这一种情况下排期；
            // 「到期复评」已由上面的每周定时通知覆盖，不必重复。
            if decision.kind == .risingTrend, let score = decision.latestScore {
                let fireDate = nextFireDate(
                    hour: Int(trendTimeInterval / 3600) % 24,
                    minute: Int(trendTimeInterval.truncatingRemainder(dividingBy: 3600) / 60),
                    calendar: cal,
                    now: now
                )
                let content = UNMutableNotificationContent()
                content.title = L10n.tr("最近的状态在往上走")
                content.body = L10n.tr("最近一次评估是 \(score) 分，比之前高了些。可能是最近的事，也可能只是没睡好 —— 值得你自己看一眼。")
                content.sound = .default
                content.categoryIdentifier = Self.categoryIdentifier
                content.userInfo = ["type": "psych-reminder", "kind": "rising-trend"]

                let comps = cal.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                result.append(UNNotificationRequest(
                    identifier: "\(Self.notificationPrefix)trend-\(Int(fireDate.timeIntervalSince1970))",
                    content: content,
                    trigger: trigger
                ))
            }
        }
        return result
    }

    /// 记录一次已发出的提醒（用于冷却窗口）。
    public func markNotified(kind: PsychReminderKind, at date: Date = .now) {
        lastNotifiedAt = date
        lastNotifiedKind = kind.rawValue
    }

    /// 清除提醒状态（用户关闭提醒时用）。
    public func resetNotificationState() {
        lastNotifiedAt = nil
        lastNotifiedKind = ""
    }

    // MARK: - 数据

    /// 读取历史得分序列。
    ///
    /// 只取**有有效总分**的记录——数据不足的记录不进入序列，
    /// 否则会把「算不出分」误当成「分数低」。
    private func loadHistory(context: ModelContext) -> [PsychScoreHistoryEntry] {
        let records = PsychRecordStore.recentScaleRecords(limit: 60, in: context)
        return records.compactMap { record in
            let score = record.score()
            guard let total = score.totalScore, let band = score.band else { return nil }
            return PsychScoreHistoryEntry(
                scaleID: record.scaleID,
                completedAt: record.completedAt,
                totalScore: total,
                band: band
            )
        }
    }

    /// 计算下一个触发时刻（今天该点已过则顺延到明天）。
    private func nextFireDate(hour: Int, minute: Int, calendar: Calendar, now: Date) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = calendar.date(from: comps) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }
}
