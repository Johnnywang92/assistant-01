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
                // 优先刷新桌面小组件/锁屏组件共享快照，并对账扩展侧产生的指令
                StartupMetrics.measure("refreshSnapshot") { WidgetSnapshotSyncController.shared.refreshSnapshot(context: Persistence.shared.mainContext) }
                StartupMetrics.mark("root.task end")

                // 延后耗时的后台通知全量对账与排期，优先保证首帧渲染顺畅秒开
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    TodoNotificationManager.shared.syncAllTodoNotifications(context: Persistence.shared.mainContext)
                    TripArrivalService.shared.syncAllReminders(context: Persistence.shared.mainContext)
                    ExpiryReminder.schedule()
                    PeriodicReportManager.shared.scheduleNotifications()
                    // 冷启动也排空一次分享中转区（scenePhase 首帧即为 active 时 onChange 不补触发）
                    await ShareInboxService.processAll()
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

                // 异步平滑派发前台巡检与收件箱任务，避免阻塞首屏渲染与用户交互手势
                Task {
                    StartupMetrics.mark("foreground.audit scheduled")
                    // 让出主线程，等待首帧转场动画和手势响应完成
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    StartupMetrics.mark("foreground.audit begin")

                    let context = Persistence.shared.mainContext
                    // 1/4/9/11: 共用 BackgroundRefreshCoordinator 幂等巡检
                    await BackgroundRefreshCoordinator.shared.performIdempotentAudits(context: context)

                    // 2. 检查手机低电量
                    _ = BatteryReminderService(context: context).checkDeviceBattery()
                    // 3. 评估周期性家务与服药日程
                    let scheduler = HabitAndMedicationScheduler(context: context)
                    await scheduler.evaluatePeriodicHabits()
                    scheduler.scheduleMedicationReminders()

                    // 5. 执行对话记录超期自动滚动清理 (7天/30天自动保留)
                    DialogueHistoryManager.shared.cleanExpiredRecords(context: context)

                    // 5.1 如果用户在 App 里手动勾掉了已上岛的包裹，同步撤掉手腕上的销号通知
                    PickupCheckoutService.reconcile(context: context)
                    // 5.2 护航/清点卡已收时，同步摘掉对应的伴随控制通知
                    LiveActivityControlNotifications.reconcile()

                    // 6. 前台低功耗单次位置采样，自动喂入常驻地点自主学习引擎
                    _ = await LocationReminderService.shared.requestSingleLocationSample(context: context)

                    // 7. 同步定期复盘报告定时推送日程
                    PeriodicReportManager.shared.scheduleNotifications()

                    // 8. 巡检查验并同步待办事项通知排期
                    TodoNotificationManager.shared.syncAllTodoNotifications(context: context)

                    // 8.1 到站/落地清点提醒：撤掉已失效排期，并在提前窗口内用运动证据判断是否该提醒
                    TripArrivalService.shared.syncAllReminders(context: context)
                    await TripArrivalService.shared.evaluate(context: context)

                    // 10. 对账扩展侧（小组件/手表卡片）产生的指令并刷新共享快照
                    WidgetSnapshotSyncController.shared.processPendingCommands(context: context)
                }
            } else if phase == .background {
                lockManager.appDidEnterBackground()
                // 回后台前把最新数据写入共享快照，供桌面/锁屏组件读取
                WidgetSnapshotSyncController.shared.refreshSnapshot(context: Persistence.shared.mainContext)
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
