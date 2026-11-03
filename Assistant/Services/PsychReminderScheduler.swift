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

    // MARK: - 排期

    /// 重新排期心理提醒。
    ///
    /// 每次进前台调用。做法与 `PeriodicReportManager` 一致：
    /// **按前缀批量清理**旧的，再重新注册——
    /// 只按固定 identifier 删会漏掉带日期后缀的一次性触发器，
    /// 改开关后旧通知仍然会响。
    public func rescheduleNotifications(context: ModelContext) {
        let center = UNUserNotificationCenter.current()

        // 1. 清理旧通知（按前缀批量删）。
        let prefix = Self.notificationPrefix
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }

        // 2. 总开关关闭 → 只清理，不排期。
        guard isEnabled else { return }

        let cal = Calendar.current

        // 3. 每周复评提醒（固定 weekday，星期几永远存在，不会短月失效）。
        if isAssessmentReminderEnabled {
            var comps = DateComponents()
            comps.weekday = assessmentWeekday
            let hour = Int(assessmentTimeInterval / 3600) % 24
            let minute = Int(assessmentTimeInterval.truncatingRemainder(dividingBy: 3600) / 60)
            comps.hour = hour
            comps.minute = minute

            let content = UNMutableNotificationContent()
            content.title = L10n.tr("该做一次心理状态评估了")
            content.body = L10n.tr("两分钟，问自己九个问题。分数只描述这两周的状态，不做任何诊断。")
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = ["type": "psych-reminder", "kind": "assessment-due"]

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let req = UNNotificationRequest(
                identifier: "\(Self.notificationPrefix)assessment",
                content: content,
                trigger: trigger
            )
            center.add(req)
        }

        // 4. 趋势上行提醒（一次性，排到下一个提醒时刻）。
        if isTrendReminderEnabled {
            let history = loadHistory(context: context)
            let decision = PsychReminderPolicy.decide(
                history: history,
                lastNotifiedAt: lastNotifiedAt,
                now: .now,
                calendar: cal
            )
            // 只在「趋势上行」这一种情况下排期；
            // 「到期复评」已由上面的每周定时通知覆盖，不必重复。
            if decision.kind == .risingTrend, let score = decision.latestScore {
                let fireDate = nextFireDate(
                    hour: Int(trendTimeInterval / 3600) % 24,
                    minute: Int(trendTimeInterval.truncatingRemainder(dividingBy: 3600) / 60),
                    calendar: cal
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
                let req = UNNotificationRequest(
                    identifier: "\(Self.notificationPrefix)trend-\(Int(fireDate.timeIntervalSince1970))",
                    content: content,
                    trigger: trigger
                )
                center.add(req)
            }
        }
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
    private func nextFireDate(hour: Int, minute: Int, calendar: Calendar) -> Date {
        let now = Date.now
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = calendar.date(from: comps) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
    }
}
