import AssistantCore
import Foundation
import SwiftData
@preconcurrency import UserNotifications

/// 睡前提醒的调度层：把 Core 算出的 `SleepPlan` 变成系统通知/卡片状态。
///
/// ## 触发结构（两层，解决「不开 App 就没提醒」的单点失效）
/// - **兜底层**：每次进前台（任意时段）为「本夜 + 未来 2 夜」计算计划并注册通知。
///   计划的修正项只含睡眠债（基于近 7 夜，白天任意时刻都已是完整事实），
///   不依赖当日未收工的数据。identifier 按夜幂等，重复进前台只是覆盖时刻。
/// - **精修层**：夜间时段进前台时用最新数据重算本夜并覆盖同 identifier。
///   若原通知已送达（delivered），去重规则拦截，不会补发第二条。
///
/// 综合考量：运动情况、食物摄入与夜宵/咖啡因、天气与气温突变、四季时令节律、
/// 睡前药物、身体活力指数、手机屏幕使用时长等全维度多源指标。
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
    /// 最近一次记录到的入睡起始时间点（昨夜实际入睡时刻）
    @Published private(set) var lastNightSleepOnset: Date?
    /// 最近一次记录到的总睡眠时长（小时）
    @Published private(set) var lastNightTotalSleepHours: Double?

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

    /// 异步注册睡前提醒的通知分类（「推迟 20 分钟」），避免冷启动并发覆盖
    static func registerCategoryAsync() async {
        let snooze = UNNotificationAction(
            identifier: actionSnooze20M,
            title: "20 分钟后",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snooze],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.insert(category)
        center.setNotificationCategories(updated)
    }

    /// 注册睡前提醒的通知分类（「推迟 20 分钟」）。启动时调用一次。
    static func registerCategory() {
        Task {
            await registerCategoryAsync()
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

    // MARK: 授权与巡检入口

    /// 显式请求系统通知权限（设置页开启开关或引导时调用）
    @discardableResult
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notificationDenied = !granted
            if granted {
                await syncSleepReminders()
            }
            return granted
        } catch {
            notificationDenied = true
            return false
        }
    }

    /// 前台与后台巡检调用（幂等）。计算本夜 + 未来 2 夜并注册/清理通知。
    func syncSleepReminders() async {
        guard isEnabled, HealthKitService.isAvailable else {
            tonightPlan = nil
            return
        }

        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        // 若处于未决状态且用户开启了提醒，主动尝试请求授权以唤醒系统权限弹窗
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        let authorized = (settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral)
        notificationDenied = settings.authorizationStatus == .denied

        let now = Date.now
        let calendar = Calendar.current
        let samples = await HealthKitService.shared.fetchSleepNights(days: 28)
        let userDesiredOffset = desiredBedtimeHHmm.flatMap { SleepNightNormalizer.offset(hourMinute: $0) }

        // 提取昨夜/最近一次的实际入睡起始时间点与总时长
        if let lastSample = samples.last {
            self.lastNightSleepOnset = SleepNightNormalizer.date(nightKey: lastSample.nightKey, offset: lastSample.onsetOffset, calendar: calendar)
            self.lastNightTotalSleepHours = Double(lastSample.asleepMinutes) / 60.0
        } else if let snapshotOnset = HealthKitService.shared.snapshot?.sleepOnset {
            self.lastNightSleepOnset = snapshotOnset
            self.lastNightTotalSleepHours = HealthKitService.shared.snapshot?.sleepHours
        }

        // pseudo-desired：从未填写期望且样本攒够 14 夜 → 把当时习惯**冻结**为长期锚
        if userDesiredOffset == nil,
           SleepReminderPlanner.shouldFreezePseudoDesired(hasDesired: false, sampleCount: samples.count) {
            freezePseudoDesired(samples: samples, now: now, calendar: calendar)
        }
        let desiredOffset = userDesiredOffset
            ?? pseudoDesiredHHmm.flatMap { SleepNightNormalizer.offset(hourMinute: $0) }

        // 关键修复：白天使用 upcomingNightKey 锁定今日即将到来的夜晚，避免清晨命中已过期的昨夜
        let tonightKey = SleepNightNormalizer.upcomingNightKey(for: now, calendar: calendar)

        // 查已送达（每夜最多一次的权威依据）
        let deliveredIDs = Set(await center.deliveredNotifications().map(\.request.identifier))

        // 汇聚当日多维情景感知因素（运动、饮食、天气、温度、季节、药物、活力、屏幕时间等）
        let context = Persistence.shared.mainContext
        let contextFactors = await collectContextFactors(context: context, calendar: calendar, targetNightKey: tonightKey)

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
                windDownMinutes: windDownMinutes,
                contextFactors: dayOffset == 0 ? contextFactors : nil
            ))

            let id = SleepReminderPlanner.notificationID(nightKey: plan.nightKey, calendar: calendar)
            let isDelivered = deliveredIDs.contains(id)
            let isLastRemindedSameDay = lastRemindedNightKey.map { calendar.isDate($0, inSameDayAs: plan.nightKey) } ?? false
            let alreadyReminded = isDelivered || isLastRemindedSameDay
            if isDelivered {
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
                center.removePendingNotificationRequests(withIdentifiers: [id])
            case .none:
                // 已提醒过 / 计划跳过 / 权限拒绝：一律清掉本夜注册，杜绝补发
                center.removePendingNotificationRequests(withIdentifiers: [id])
            }
            if dayOffset == 0 {
                tonight = plan // 卡片展示今晚建议
            }
        }
        tonightPlan = tonight
    }

    // MARK: 私有

    /// 汇聚今日情景感知各维因素
    private func collectContextFactors(
        context: ModelContext,
        calendar: Calendar,
        targetNightKey: Date
    ) async -> SleepContextFactors {
        let healthSnapshot = HealthKitService.shared.snapshot
        let workoutMin = healthSnapshot?.workoutMinutes
        let activeCal = healthSnapshot?.activeEnergy
        let hrv = healthSnapshot?.heartRateVariability

        // 饮食记录
        var foodCalories: Double?
        var lastFoodIntake: Date?
        var hasLateCaffeine = false

        let todayStart = calendar.startOfDay(for: .now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? .now
        let foodDesc = FetchDescriptor<FoodIntakeRecord>(
            predicate: #Predicate<FoodIntakeRecord> { record in
                record.date >= todayStart && record.date < tomorrowStart
            },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        if let foods = try? context.fetch(foodDesc), !foods.isEmpty {
            foodCalories = foods.reduce(0.0) { $0 + $1.consumedCalories }
            lastFoodIntake = foods.map(\.date).max()

            let caffeineKeywords = ["咖啡", "拿铁", "美式", "卡布", "摩卡", "生椰", "浓茶", "乌龙", "绿茶", "红茶", "普洱", "奶茶", "能量饮料", "红牛", "魔爪", "可乐", "caffeine", "coffee", "tea"]
            hasLateCaffeine = foods.contains { record in
                let lower = record.foodName.lowercased()
                let isCaff = caffeineKeywords.contains { lower.contains($0) }
                let hr = calendar.component(.hour, from: record.date)
                return isCaff && hr >= 14
            }
        }

        // 天气与温度
        let weather = WeatherAlertService.shared.cachedWeatherSnapshot
        let isTempDropAlert = WeatherAlertService.shared.currentBanner?.type == .tempDrop
        let weatherDesc = weather?.conditionDescription
        let isRainy = weather?.isRainyOrSnowy ?? false
        let tempC = weather?.temperatureCelsius

        // 季节节律
        let season = Season.current(for: targetNightKey, calendar: calendar)

        // 睡前待服药物
        var pendingMeds: [String] = []
        let medDesc = FetchDescriptor<MedicationPlan>()
        if let medPlans = try? context.fetch(medDesc) {
            for plan in medPlans where plan.isEnabled {
                let isBedtime = (plan.mealRelation == .bedtime)
                let isLatePoint = plan.dailyTimePoints.contains { tp in
                    guard let h = Int(tp.prefix(2)) else { return false }
                    return h >= 20
                }
                if isBedtime || isLatePoint {
                    let takenToday = plan.lastTakenAt.map { calendar.isDateInToday($0) } ?? false
                    if !takenToday {
                        pendingMeds.append(plan.medName)
                    }
                }
            }
        }

        // 活力指数
        let vitality = VitalityEvaluator.evaluate(
            snapshot: healthSnapshot ?? .empty(day: .now),
            foodIntakeCalories: foodCalories
        )

        // 屏幕时间
        let screenMinutes = ScreenTimeTracker.shared.todayScreenTimeMinutes

        return SleepContextFactors(
            workoutMinutes: workoutMin,
            activeEnergyBurned: activeCal,
            lastWorkoutEndTime: nil,
            foodCalories: foodCalories,
            lastFoodIntakeTime: lastFoodIntake,
            hasLateCaffeineIntake: hasLateCaffeine,
            weatherDescription: weatherDesc,
            isRainyOrSnowy: isRainy,
            temperatureCelsius: tempC,
            isTempDropAlert: isTempDropAlert,
            season: season,
            pendingBedtimeMedications: pendingMeds,
            vitalityScore: Double(vitality.score),
            vitalityLevel: vitality.level,
            screenTimeMinutes: screenMinutes > 0 ? screenMinutes : nil,
            hrvSDNN: hrv
        )
    }

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
        content.subtitle = L10n.choose("睡眠作息提醒 · 就寝准备", "Sleep Wind-Down")
        content.body = SleepPlanCopy.body(for: plan)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = "sleep-bedtime"
        // 挂上「推迟 20 分钟」动作；userInfo 供 AppDelegate 路由
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["type": "sleepBedtime", "nightId": id]

        // 墙上时钟触发（DST 安全）：一次性、不重复
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        comps.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            if let error {
                print("Failed to schedule sleep reminder: \(error)")
            }
        }
    }
}
