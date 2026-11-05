import BackgroundTasks
import Foundation
import SwiftData

/// 前台巡检分级节流（审计 SVC-08）。
///
/// 每次 `.active` 都把全部巡检串行跑在 MainActor 上，其中「9 个全表审计」「28 夜
/// HealthKit 拉取」「报告排期」「天气网络请求」等是重活，且随数据量线性恶化。
/// 这里按「上次执行时间 + 最小间隔」做节流：
/// - 时间戳持久化在 Caches 目录下的运行态 JSON（`foreground-audit-cadence.json`），
///   杀进程后仍有效；被系统清理时退回「全部到期」，所以只会多跑、不会永久跳过；
/// - **只延后、不永久跳过**：时间戳只在任务真正执行完之后写入，下一次 `.active`
///   （以及 4 小时后的 BGAppRefresh）间隔到了自然会执行；
/// - 冷启动 / 从后台回前台都会走到 `isDue`，因此节流不会让巡检永远不跑；
/// - 各步骤间隔默认值见 `defaultInterval`，可用 `setIntervalOverride(_:for:)` 覆盖；
///   `setThrottlingEnabled(false)` 可整体关掉，便于真机对比。
///
/// 为什么用运行态文件而不是 UserDefaults：这是可随时重建的设备级缓存，不属于用户偏好，
/// 不应进备份，也就不该占用偏好键闸门（check_settings_keys.py）的白名单 / 豁免额度。
@MainActor
enum ForegroundAuditCadence {
    enum Step: String {
        /// 自动续费防扣款 / 证件临期等 9 个全表审计。
        case dailyAudit
        /// 后台零成本路径的天气评估（BG 刷新也走这里）。
        case weatherCached
        /// 前台拿到 GPS 采样后的天气评估（WeatherKit 网络请求）。
        case weatherLocated
        /// NAS / 私有云盘静默加密备份。
        case webdav
        /// 今日健康指标（13 个 HealthKit 查询）。
        case healthToday
        /// 定期复盘报告的通知排期。
        case reportNotifications
        /// 对话记录超期滚动清理（7 天 / 30 天保留）。
        case dialogueCleanup
    }

    /// 运行态节流状态（持久化到 Caches 的 JSON；所有字段都是可随时重建的缓存值）。
    private struct State: Codable {
        /// step.rawValue -> 上次执行完成时间（timeIntervalSince1970）
        var lastRunAt: [String: Double] = [:]
        /// step.rawValue -> 覆盖的最小间隔（秒），供调试 / 设置页使用
        var intervalOverrides: [String: Double] = [:]
        /// 总开关；false 时所有步骤每次执行（真机对比用）
        var enabled: Bool = true
    }

    private static let stateFileName = "foreground-audit-cadence.json"
    /// 进程内缓存：一次前台最多 7 个步骤，避免每次 `isDue` 都读盘。
    private static var cachedState: State?

    /// 节流总开关（默认开）。真机排查「某个提醒为什么没刷新」时可临时关掉对比。
    static var isThrottlingEnabled: Bool {
        currentState().enabled
    }

    /// 各步骤的默认最小间隔与依据：
    /// - dailyAudit 10 分钟：全表审计但事件本质是「天级」的（续费/证件临期），10 分钟足够新鲜；
    /// - 天气 15 分钟：WeatherKit 网络请求 + 突降温告警需要一定时效；
    /// - WebDAV 30 分钟：真正是否备份由服务内部的「上次备份时间」决定，这里只削掉重复探测；
    /// - 今日健康指标 15 分钟：13 个 HK 查询，指标本身分钟级变化；
    /// - 报告通知排期 30 分钟：报告触发时刻按天/周/月，30 分钟足以对账；
    /// - 对话清理 60 分钟：保留期是 7 天 / 30 天，小时级足够。
    static func defaultInterval(for step: Step) -> TimeInterval {
        switch step {
        case .dailyAudit: return 10 * 60
        case .weatherCached: return 15 * 60
        case .weatherLocated: return 15 * 60
        case .webdav: return 30 * 60
        case .healthToday: return 15 * 60
        case .reportNotifications: return 30 * 60
        case .dialogueCleanup: return 60 * 60
        }
    }

    static func interval(for step: Step) -> TimeInterval {
        if let override = currentState().intervalOverrides[step.rawValue] {
            return max(30, override)
        }
        return defaultInterval(for: step)
    }

    static func lastRun(for step: Step) -> Date? {
        guard let timestamp = currentState().lastRunAt[step.rawValue], timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func isDue(_ step: Step, now: Date = .now) -> Bool {
        guard isThrottlingEnabled else { return true }
        guard let last = lastRun(for: step) else { return true }
        return now.timeIntervalSince(last) >= interval(for: step)
    }

    /// 任务真正执行完之后才写入时间戳；中途被取消 / 进程被杀则保持旧值，下次重新执行。
    static func markRun(_ step: Step, now: Date = .now) {
        updateState { state in
            state.lastRunAt[step.rawValue] = now.timeIntervalSince1970
        }
    }

    /// 调试 / 设置页可用：整体关闭或恢复节流。
    static func setThrottlingEnabled(_ enabled: Bool) {
        updateState { state in
            state.enabled = enabled
        }
    }

    /// 调试 / 设置页可用：覆盖某个步骤的最小间隔；传 nil 恢复默认。
    static func setIntervalOverride(_ interval: TimeInterval?, for step: Step) {
        updateState { state in
            if let interval = interval {
                state.intervalOverrides[step.rawValue] = max(30, interval)
            } else {
                state.intervalOverrides.removeValue(forKey: step.rawValue)
            }
        }
    }

    /// 到期才执行 `body`；返回是否真的执行了。未到期时打一行可观测日志（便于真机确认是节流而非漏跑）。
    @discardableResult
    static func runIfDue(_ step: Step, now: Date = .now, _ body: () async -> Void) async -> Bool {
        guard isDue(step, now: now) else {
            let elapsedText = lastRun(for: step).map { "距上次 \(durationText(now.timeIntervalSince($0)))" } ?? "无记录"
            print("⏳ [ForegroundAudit] 节流跳过 \(step.rawValue)：\(elapsedText) < 最小间隔 \(durationText(interval(for: step)))")
            return false
        }
        await body()
        // 被取消（例如用户很快又切了一次后台）不记账，保证下一轮还会执行。
        guard !Task.isCancelled else { return false }
        markRun(step)
        return true
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m\(remainder)s"
        }
        return "\(seconds)s"
    }

    // MARK: - 运行态状态存取

    private static func currentState() -> State {
        if let cachedState { return cachedState }
        let loaded = loadState()
        cachedState = loaded
        return loaded
    }

    private static func updateState(_ mutate: (inout State) -> Void) {
        var state = currentState()
        mutate(&state)
        cachedState = state
        persist(state)
    }

    private static func stateFileURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent(stateFileName)
    }

    private static func loadState() -> State {
        guard let url = stateFileURL() else { return State() }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            // 首次运行 / Caches 被清理 / 文件损坏：一律视为「全部到期」，宁可多跑一次也不永久跳过。
            return State()
        }
    }

    private static func persist(_ state: State) {
        guard let url = stateFileURL() else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // 写失败只丢节流记忆（下一轮照常执行），不能因此影响巡检本身。
            print("⚠️ [ForegroundAudit] 节流状态写入失败（本轮照常执行）: \(error.localizedDescription)")
        }
    }
}

/// 负责 BGAppRefreshTask 后台巡检任务的注册、调度与执行
/// 搬迁原前台 active 下的幂等巡检任务，使系统在夜间或用户未打开 App 时自主评估并触发提醒。
@MainActor
final class BackgroundRefreshCoordinator {
    static let shared = BackgroundRefreshCoordinator()

    static let taskIdentifier = "com.yifanwang.assistant01.refresh"

    private init() {}

    /// 在应用启动（init 阶段）向系统注册任务
    func registerBackgroundTask() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                await self.handleAppRefresh(task: appRefreshTask)
            }
        }
        #endif
    }

    /// 向系统预约下一次后台刷新（默认 4 小时后）
    func scheduleNextRefresh() {
        #if canImport(BackgroundTasks)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("🕒 [BackgroundRefresh] 已向系统预约后台巡检: \(request.earliestBeginDate?.formatted() ?? "")")
        } catch {
            print("⚠️ [BackgroundRefresh] 预约后台任务失败: \(error)")
        }
        #endif
    }

    /// 执行后台巡检任务
    private func handleAppRefresh(task: BGAppRefreshTask) async {
        // 无论执行结果如何，首先预约下一次任务
        scheduleNextRefresh()

        var isExpired = false
        task.expirationHandler = {
            isExpired = true
        }

        let context = Persistence.shared.mainContext

        // 执行幂等巡检（分级节流与前台共用；BG 刷新间隔 ≥ 4h，重活必然到期）
        await performIdempotentAudits(context: context, isExpired: { isExpired })

        // 巡检查验并同步待办事项通知排期（内部为差量对账）
        if !isExpired {
            TodoNotificationManager.shared.syncAllTodoNotifications(context: context)
        }

        // 刷新小组件与桌面共享快照
        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)

        task.setTaskCompleted(success: !isExpired)
    }

    /// 幂等巡检核心实现：供后台任务与前台 active 共用。
    ///
    /// 分级（审计 SVC-08）：
    /// - **每次执行**：收件箱补录、周期支出入账 + 预算预警、分享扩展排空、到站/落地清点对账
    ///   —— 便宜且时效敏感（用户输入不能滞留、到站窗口分钟级）；
    /// - **节流执行**：全表审计（续费/临期）、WebDAV 静默备份、天气评估
    ///   —— 重活，间隔见 `ForegroundAuditCadence`，只延后不永久跳过。
    /// 不把 SwiftData `ModelContext` 传进后台线程（上下文非 Sendable），所有取数仍留在主 actor。
    func performIdempotentAudits(context: ModelContext, isExpired: () -> Bool = { false }) async {
        // 1. 回到前台或后台唤醒时补录收件箱里积压的短信（inbox.txt）—— 每次
        if !isExpired() {
            await InboxService.drain(context: context)
        }

        // 2. 自动续费防扣款与证件临期巡检（9 个全表审计）—— 10 分钟节流
        if !isExpired() {
            await ForegroundAuditCadence.runIfDue(.dailyAudit) {
                let auditor = DailyPainPointAuditor(context: context)
                auditor.auditAll()
            }
            await Task.yield()
        }

        // 3. 巡检查验固定周期支出并自动入账，随后评估预算超支预警 —— 每次（与钱有关，必须及时）
        if !isExpired() {
            RecurringExpenseManager.shared.processDueRecurringExpenses(in: context)
            BudgetAlertService.shared.evaluateAndNotify(context: context)
        }

        // 4. 排空分享扩展中转区 —— 每次（用户刚分享完就会切回来）
        if !isExpired() {
            await ShareInboxService.processAll(context: context)
        }

        // 5. 到站/落地清点提醒：先按到达时间对账排期，再用运动证据判断是否已停下 —— 每次（时效敏感）
        if !isExpired() {
            TripArrivalService.shared.syncAllReminders(context: context)
            await TripArrivalService.shared.evaluate(context: context)
        }

        // 6. 若开启了 NAS / 私有云盘自动同步，执行一次静默后台加密备份 —— 30 分钟节流（网络重活）
        if !isExpired() {
            await ForegroundAuditCadence.runIfDue(.webdav) {
                await WebDAVSyncService.shared.performBackgroundSyncIfNeeded(context: context)
            }
            await Task.yield()
        }

        // 7. 天气突变与降温评估。后台只走零成本路径：用定位服务的最近一次采样，
        // 不主动开 GPS——BGAppRefresh 预算只有几十秒，室内定位可能一直等不到结果。
        // 15 分钟节流：WeatherKit 是网络请求，且前台拿到 GPS 后会再走一次精修。
        if !isExpired() {
            await ForegroundAuditCadence.runIfDue(.weatherCached) {
                await WeatherAlertService.shared.checkAlertsIfNeeded()
            }
        }
    }
}
