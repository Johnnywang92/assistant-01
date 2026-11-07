import CoreLocation
import SwiftData
import SwiftUI
import os

/// 冷启动埋点：进程内相对时刻 + 单段同步耗时。DEBUG 与 Release 均输出到统一日志
/// （subsystem `assistant.startup`），每启约二十行，开销可忽略；
/// 真机首启瓶颈需要用 Release 构建采样，Console.app 按 subsystem 过滤即可。
enum StartupMetrics {
    private static let start = CFAbsoluteTimeGetCurrent()
    private static let logger = Logger(subsystem: "assistant.startup", category: "timing")
    private static let seenNodesLock = OSAllocatedUnfairLock(initialState: Set<String>())

    static func mark(_ node: String) {
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        logger.log("t+\(elapsed, privacy: .public)ms  \(node, privacy: .public)")
    }

    /// 只输出一次的节点（SwiftUI body / onAppear 会被反复求值）。key 固定用于去重，detail 懒求值。
    static func markOnce(_ key: String, _ detail: @autoclosure () -> String = "") {
        let inserted = seenNodesLock.withLock { $0.insert(key).inserted }
        if !inserted { return }
        let extra = detail()
        mark(extra.isEmpty ? key : "\(key) \(extra)")
    }

    @discardableResult
    static func measure<R>(_ node: String, _ body: () throws -> R) rethrows -> R {
        let begin = CFAbsoluteTimeGetCurrent()
        let result = try body()
        logger.log("cost \(Int((CFAbsoluteTimeGetCurrent() - begin) * 1000), privacy: .public)ms  \(node, privacy: .public)")
        return result
    }
}

@main
struct AssistantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lockManager = StartupMetrics.measure("appLockManagerInit") { AppLockManager.shared }
    @StateObject private var router = NavigationRouter.shared
    @StateObject private var bgManager = AppBackgroundManager.shared
    @StateObject private var seniorManager = SeniorModeManager.shared
    @StateObject private var langManager = LanguageManager.shared
    @StateObject private var pinManager = StartupMetrics.measure("migrationPinManagerInit") { MigrationPinManager.shared }

    init() {
        StartupMetrics.mark("app.init begin")
        // 注册小组件/实时活动桥接钩子：AppIntent 在主应用进程（Siri、操作按钮、快捷指令）
        // 执行时直连 SwiftData；扩展进程执行时走 App Group 指令队列。
        WidgetBridge.appHook = StartupMetrics.measure("widgetHookInstall") { WidgetSnapshotSyncController.shared }
        // 注册后台定时巡检任务 (BGAppRefreshTask)
        StartupMetrics.measure("bgTaskRegister") { BackgroundRefreshCoordinator.shared.registerBackgroundTask() }
        StartupMetrics.mark("app.init end")
    }

    private var isAppLocked: Bool {
        lockManager.isAppLockEnabled && lockManager.hasPasscode && lockManager.isLocked
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let recoveryError = Persistence.recoveryError {
                    DataRecoveryView(error: recoveryError)
                } else {
                    MainTabView()
                }

                if isAppLocked {
                    AppLockScreen()
                        .transition(.opacity)
                }

                // 首次冷启动强制设置“备份与迁移”门禁 PIN（未配置前不可进入正常使用）
                if Persistence.recoveryError == nil && !pinManager.isConfigured {
                    MigrationPinSetupView()
                        .transition(.opacity)
                }
            }
            .id(langManager.effectiveLanguageCode)
            .environment(\.locale, langManager.locale)
            .environmentObject(langManager)
            .appMotionObserver()
            .applySeniorMode(manager: seniorManager)
            .preferredColorScheme(bgManager.currentStyle.preferredColorScheme)
            .responsiveAnimation(.easeInOut(duration: 0.25), value: isAppLocked)
            .task {
                guard Persistence.recoveryError == nil else { return }
                StartupMetrics.mark("root.task begin")
                // 让出首帧渲染窗口，确保主界面先上屏，再执行快捷方式、通知分类与小组件快照全表查询
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                // 密码迁移不再在冷启动主线程执行：全表拉取 + 可触发 SQLite VACUUM，
                // 改由打开保险箱时（PasswordVaultView.onAppear）惰性地按需迁移。
                StartupMetrics.measure("registerDynamicShortcuts") { router.registerDynamicShortcuts() }
                // 合并注册全部模块的通知交互分类：将 6 次独立 XPC 读写合并为单次，消除冷启动 IPC 堆叠
                await NotificationCategoryRegistry.registerAllCategoriesAsync()
                StartupMetrics.mark("notifyCategories ready")
                // 优先对账扩展侧（小组件/手表卡片）指令并刷新共享快照
                StartupMetrics.measure("refreshSnapshot") { WidgetSnapshotSyncController.shared.refreshSnapshot(context: Persistence.shared.mainContext) }
                StartupMetrics.mark("root.task end")

                // 冷启动首帧渲染优先：延后非关键巡检，给主线程留出充分的渲染与首帧动画窗口
                if scenePhase == .active {
                    ForegroundAuditCoordinator.shared.scheduleAudit(delayNanoseconds: 1_200_000_000)
                }
            }
            .onOpenURL { url in
                router.handleURL(url)
            }
        }
        .modelContainer(Persistence.shared)
        .onChange(of: scenePhase) { _, phase in
            guard Persistence.recoveryError == nil else { return }
            if phase == .active {
                lockManager.appWillEnterForeground()
                ScreenTimeTracker.shared.appWillEnterForeground()
                // 回前台第一时间对账小组件/手表指令，确保 UI 立即反映用户在组件上的打勾/记账操作
                WidgetSnapshotSyncController.shared.processPendingCommands(context: Persistence.shared.mainContext)
                ForegroundAuditCoordinator.shared.scheduleAudit(delayNanoseconds: 600_000_000)
            } else if phase == .background {
                lockManager.appDidEnterBackground()
                ScreenTimeTracker.shared.appDidEnterBackground()
                let bgContext = Persistence.shared.mainContext
                // 回后台前确保驿站围栏与最新待办同步
                LocationReminderService.shared.syncParcelStationGeofences(context: bgContext)
                // 回后台前把最新数据写入共享快照，供桌面/锁屏组件读取
                WidgetSnapshotSyncController.shared.refreshSnapshot(context: bgContext)
                // 预约下一次后台巡检（系统在 4 小时后允许唤醒评估）
                BackgroundRefreshCoordinator.shared.scheduleNextRefresh()
            }
        }
    }
}

private struct DataRecoveryView: View {
    let error: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("数据暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("原始数据库已保留。请先将数据库及其附属文件导出，再排查迁移或存储问题。\n\n错误：\(error)")
            } actions: {
                if !Persistence.storeFiles.isEmpty {
                    ShareLink(items: Persistence.storeFiles) {
                        Label("导出原始数据库文件", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

fileprivate extension View {
    @ViewBuilder
    func applySeniorMode(manager: SeniorModeManager) -> some View {
        if manager.isSeniorModeEnabled {
            self.dynamicTypeSize(manager.fontScale.dynamicTypeSize)
        } else {
            self
        }
    }
}

/// 统一协调冷启动与回前台的异步巡检任务，合并短时间内的重复触发，并将耗时的 GPS 单次定位采样与核心数据对账解耦。
@MainActor
private final class ForegroundAuditCoordinator {
    static let shared = ForegroundAuditCoordinator()
    private var auditTask: Task<Void, Never>?
    private var lastCompletedAt: CFAbsoluteTime = 0

    func scheduleAudit(delayNanoseconds: UInt64) {
        // 2 秒内已完成过完整巡检则跳过重复触发（消除冷启动 root.task 与 scenePhase.active 的双重执行）
        if CFAbsoluteTimeGetCurrent() - lastCompletedAt < 2.0 {
            return
        }
        auditTask?.cancel()
        auditTask = Task { @MainActor in
            StartupMetrics.mark("foreground.audit scheduled")
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            StartupMetrics.mark("foreground.audit begin")

            let context = Persistence.shared.mainContext

            // 0. 优先对账扩展侧（小组件/手表卡片）产生的指令 —— 便宜且必须每次对账
            WidgetSnapshotSyncController.shared.processPendingCommands(context: context)
            StartupMetrics.mark("audit.widgetCommands")
            await Task.yield()
            guard !Task.isCancelled else { return }

            // 1. 共用 BackgroundRefreshCoordinator 幂等巡检（收件箱、防扣款/临期、周期记账、分享中转区、到站提醒）
            //    其中全表审计 / WebDAV / 天气缓存路径按 `ForegroundAuditCadence` 节流（审计 SVC-08）。
            await BackgroundRefreshCoordinator.shared.performIdempotentAudits(context: context)
            StartupMetrics.mark("audit.idempotentAudits")
            guard !Task.isCancelled else { return }

            // 2. 检查手机低电量 & 临期提醒 —— 便宜，每次
            _ = BatteryReminderService(context: context).checkDeviceBattery()
            ExpiryReminder.schedule()
            StartupMetrics.mark("audit.batteryExpiry")

            // 3. 评估周期性家务与服药日程（含按天物化首页服药待办）—— 每次：
            //    服药提醒已改差量对账，当天服药待办必须当天生效，不能延后。
            let scheduler = HabitAndMedicationScheduler(context: context)
            await scheduler.evaluatePeriodicHabits()
            StartupMetrics.mark("audit.periodicHabits")
            await scheduler.scheduleMedicationRemindersAndWait()
            StartupMetrics.mark("audit.medicationReminders")
            scheduler.ensureTodayMedicationTodos()
            StartupMetrics.mark("audit.medicationTodos")
            await Task.yield()
            guard !Task.isCancelled else { return }

            // 3.5 睡前提醒两层注册（兜底本夜+未来2夜，夜间进前台自动精修；每夜最多一条）。
            //     28 夜 HealthKit 样本在调度器内部做 10 分钟缓存，不重复全量拉取（审计 SVC-08）。
            await SleepReminderScheduler.shared.syncSleepReminders()
            StartupMetrics.mark("audit.sleepReminders")
            guard !Task.isCancelled else { return }

            // 3.6 健康数据前台巡检（13 个 HealthKit 查询）—— 15 分钟节流
            await ForegroundAuditCadence.runIfDue(.healthToday) {
                guard HealthKitService.isAvailable && HealthKitService.shared.hasEverConnected else { return }
                await HealthKitService.shared.refreshToday()
            }
            StartupMetrics.mark("audit.healthToday")

            // 4. 执行对话记录超期自动滚动清理（7天/30天自动保留）—— 60 分钟节流（保留期是天级的）
            await ForegroundAuditCadence.runIfDue(.dialogueCleanup) {
                DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
            }
            StartupMetrics.mark("audit.dialogueCleanup")

            // 5. 同步灵动岛/手表伴随通知状态 —— 便宜，每次
            PickupCheckoutService.reconcile(context: context)
            LiveActivityControlNotifications.reconcile()
            StartupMetrics.mark("audit.liveActivityReconcile")

            // 6. 通知排期：报告（30 分钟节流）→ 待办 → 心理，统一走 AndWait，
            //    保证下面第 6.6 步的全局预算裁决读到的是**完整** pending。
            //    若这里用 fire-and-forget 同步壳，裁决会基于残缺快照，
            //    下一轮差量对账又会把刚裁掉的通知加回来。
            await ForegroundAuditCadence.runIfDue(.reportNotifications) {
                await PeriodicReportManager.shared.scheduleNotificationsAndWait()
            }
            StartupMetrics.mark("audit.reportNotifications")
            await TodoNotificationManager.shared.syncAllTodoNotificationsAndWait(context: context)
            StartupMetrics.mark("audit.todoNotifications")

            // 6.5 心理状态提醒排期（低分档不打扰，判定规则在 Core 的 PsychReminderPolicy）
            await PsychReminderScheduler.shared.rescheduleNotificationsAndWait(context: context)
            StartupMetrics.mark("audit.psychReminders")

            // 6.6 所有通知排期结束后**只裁决一次**：各模块 admit 看到的是不同时刻的
            //     pending 快照，彼此会互相推翻；这里读真实存量兜底，被裁的 identifier
            //     进入抑制名单，下轮巡检不会立刻加回。第 7 步的天气 / 围栏是即时投递
            //     或少量排期，若产生带 trigger 的通知，下一轮巡检会被本步覆盖。
            await NotificationBudget.reconcile()
            StartupMetrics.mark("audit.notificationBudget")

            self.lastCompletedAt = CFAbsoluteTimeGetCurrent()
            StartupMetrics.mark("audit.end")

            // 7. 低功耗单次位置采样独立异步执行（室内 GPS 耗时可达数秒，不阻塞主巡检流水线）
            Task { @MainActor in
                let sampledCoordinate = await LocationReminderService.shared.requestSingleLocationSample(context: context)
                LocationReminderService.shared.syncParcelStationGeofences(context: context)
                // 7.5 天气评估搭在这次采样之后：首帧早已完成，此时位置要么真的拿到、
                // 要么明确拿不到，不会再出现「首页等天气、天气等 GPS」的互相拖累。
                // WeatherKit 是网络请求：与后台缓存路径分开计 15 分钟节流。
                if let sampledCoordinate {
                    await ForegroundAuditCadence.runIfDue(.weatherLocated) {
                        await WeatherAlertService.shared.checkAlertsIfNeeded(
                            location: CLLocation(
                                latitude: sampledCoordinate.latitude,
                                longitude: sampledCoordinate.longitude
                            )
                        )
                    }
                }
            }
        }
    }
}
