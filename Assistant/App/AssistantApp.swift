import SwiftData
import SwiftUI
import os

/// 冷启动埋点：进程内相对时刻 + 单段同步耗时。仅 DEBUG 构建输出，发布构建为空操作。
enum StartupMetrics {
    private static let start = CFAbsoluteTimeGetCurrent()
    private static let logger = Logger(subsystem: "assistant.startup", category: "timing")
    #if DEBUG
    private static let seenNodesLock = OSAllocatedUnfairLock(initialState: Set<String>())
    #endif

    static func mark(_ node: String) {
        #if DEBUG
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        logger.log("t+\(elapsed, privacy: .public)ms  \(node, privacy: .public)")
        #endif
    }

    /// 只输出一次的节点（SwiftUI body / onAppear 会被反复求值）。key 固定用于去重，detail 懒求值。
    static func markOnce(_ key: String, _ detail: @autoclosure () -> String = "") {
        #if DEBUG
        let inserted = seenNodesLock.withLock { $0.insert(key).inserted }
        if !inserted { return }
        let extra = detail()
        mark(extra.isEmpty ? key : "\(key) \(extra)")
        #endif
    }

    @discardableResult
    static func measure<R>(_ node: String, _ body: () throws -> R) rethrows -> R {
        #if DEBUG
        let begin = CFAbsoluteTimeGetCurrent()
        let result = try body()
        logger.log("cost \(Int((CFAbsoluteTimeGetCurrent() - begin) * 1000), privacy: .public)ms  \(node, privacy: .public)")
        return result
        #else
        return try body()
        #endif
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
                // 密码迁移不再在冷启动主线程执行：全表拉取 + 可触发 SQLite VACUUM，
                // 改由打开保险箱时（PasswordVaultView.onAppear）惰性地按需迁移。
                StartupMetrics.measure("registerDynamicShortcuts") { router.registerDynamicShortcuts() }
                TodoNotificationManager.shared.registerCategories()
                // 取件销号通知的「已取件 / 全部取齐」按钮，抬腕即可点
                await PickupCheckoutService.registerCategory()
                // 护航/清点伴随通知的「关闭卡片」按钮，手表与 Mac 上都能一键收卡
                await LiveActivityControlNotifications.registerCategories()
                // 到站/落地清点提醒的「开始清点」按钮，锁屏上点一下就进清单
                await TripArrivalService.shared.registerCategory()
                StartupMetrics.mark("notifyCategories ready")
                // 优先对账扩展侧（小组件/手表卡片）指令并刷新共享快照
                StartupMetrics.measure("refreshSnapshot") { WidgetSnapshotSyncController.shared.refreshSnapshot(context: Persistence.shared.mainContext) }
                StartupMetrics.mark("root.task end")

                // 冷启动首帧已处于 active 时 onChange(of: scenePhase) 可能不补触发，统一走防抖前台巡检
                if scenePhase == .active {
                    ForegroundAuditCoordinator.shared.scheduleAudit(delayNanoseconds: 250_000_000)
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
                // 回前台第一时间对账小组件/手表指令，确保 UI 立即反映用户在组件上的打勾/记账操作
                WidgetSnapshotSyncController.shared.processPendingCommands(context: Persistence.shared.mainContext)
                ForegroundAuditCoordinator.shared.scheduleAudit(delayNanoseconds: 350_000_000)
            } else if phase == .background {
                lockManager.appDidEnterBackground()
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

            // 0. 优先对账扩展侧（小组件/手表卡片）产生的指令
            WidgetSnapshotSyncController.shared.processPendingCommands(context: context)

            // 1. 共用 BackgroundRefreshCoordinator 幂等巡检（收件箱、防扣款/临期、周期记账、分享中转区、到站提醒）
            await BackgroundRefreshCoordinator.shared.performIdempotentAudits(context: context)
            guard !Task.isCancelled else { return }

            // 2. 检查手机低电量 & 临期提醒
            _ = BatteryReminderService(context: context).checkDeviceBattery()
            ExpiryReminder.schedule()

            // 3. 评估周期性家务与服药日程
            let scheduler = HabitAndMedicationScheduler(context: context)
            await scheduler.evaluatePeriodicHabits()
            scheduler.scheduleMedicationReminders()

            // 4. 执行对话记录超期自动滚动清理 (7天/30天自动保留)
            DialogueHistoryManager.shared.cleanExpiredRecords(context: context)

            // 5. 同步灵动岛/手表伴随通知状态
            PickupCheckoutService.reconcile(context: context)
            LiveActivityControlNotifications.reconcile()

            // 6. 同步定期复盘报告与待办通知排期（以及驿站地理围栏）
            PeriodicReportManager.shared.scheduleNotifications()
            TodoNotificationManager.shared.syncAllTodoNotifications(context: context)

            self.lastCompletedAt = CFAbsoluteTimeGetCurrent()

            // 7. 低功耗单次位置采样独立异步执行（室内 GPS 耗时可达数秒，不阻塞主巡检流水线）
            Task { @MainActor in
                _ = await LocationReminderService.shared.requestSingleLocationSample(context: context)
                LocationReminderService.shared.syncParcelStationGeofences(context: context)
            }
        }
    }
}
