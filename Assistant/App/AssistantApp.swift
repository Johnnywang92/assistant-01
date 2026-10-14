import SwiftData
import SwiftUI

@main
struct AssistantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lockManager = AppLockManager.shared
    @StateObject private var router = NavigationRouter.shared
    @StateObject private var bgManager = AppBackgroundManager.shared
    @StateObject private var seniorManager = SeniorModeManager.shared
    @StateObject private var langManager = LanguageManager.shared
    @StateObject private var pinManager = MigrationPinManager.shared

    init() {
        // 注册小组件/实时活动桥接钩子：AppIntent 在主应用进程（Siri、操作按钮、快捷指令）
        // 执行时直连 SwiftData；扩展进程执行时走 App Group 指令队列。
        WidgetBridge.appHook = WidgetSnapshotSyncController.shared
        // 注册后台定时巡检任务 (BGAppRefreshTask)
        BackgroundRefreshCoordinator.shared.registerBackgroundTask()
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
            .applySeniorMode(manager: seniorManager)
            .preferredColorScheme(bgManager.currentStyle.preferredColorScheme)
            .animation(.easeInOut(duration: 0.25), value: isAppLocked)
            .task {
                guard Persistence.recoveryError == nil else { return }
                // 密码迁移不再在冷启动主线程执行：全表拉取 + 可触发 SQLite VACUUM，
                // 改由打开保险箱时（PasswordVaultView.onAppear）惰性地按需迁移。
                router.registerDynamicShortcuts()
                TodoNotificationManager.shared.registerCategories()
                // 取件销号通知的「已取件 / 全部取齐」按钮，抬腕即可点
                await PickupCheckoutService.registerCategory()
                // 护航/清点伴随通知的「关闭卡片」按钮，手表与 Mac 上都能一键收卡
                await LiveActivityControlNotifications.registerCategories()
                // 优先刷新桌面小组件/锁屏组件共享快照，并对账扩展侧产生的指令
                WidgetSnapshotSyncController.shared.refreshSnapshot(context: Persistence.shared.mainContext)

                // 延后耗时的后台通知全量对账与排期，优先保证首帧渲染顺畅秒开
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    TodoNotificationManager.shared.syncAllTodoNotifications(context: Persistence.shared.mainContext)
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
                    // 让出主线程，等待首帧转场动画和手势响应完成
                    try? await Task.sleep(nanoseconds: 350_000_000)

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
