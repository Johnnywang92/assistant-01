import SwiftData
import SwiftUI

@main
struct AssistantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lockManager = AppLockManager.shared
    @StateObject private var router = NavigationRouter.shared
    @StateObject private var bgManager = AppBackgroundManager.shared

    private var isAppLocked: Bool {
        lockManager.isAppLockEnabled && lockManager.hasPasscode && lockManager.isLocked
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainTabView()
                    .blur(radius: isAppLocked ? 20 : 0)

                if isAppLocked {
                    AppLockScreen()
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(bgManager.currentStyle.preferredColorScheme)
            .animation(.easeInOut(duration: 0.25), value: isAppLocked)
            .task {
                router.registerDynamicShortcuts()
                await NotificationService.requestAuthorization()
                ExpiryReminder.schedule()
            }
            .onOpenURL { url in
                router.handleURL(url)
            }
        }
        .modelContainer(Persistence.shared)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                lockManager.appWillEnterForeground()

                let context = Persistence.shared.mainContext
                // 1. 回到前台时补录收件箱里积压的短信
                InboxService.drain(context: context)
                // 2. 检查手机低电量
                _ = BatteryReminderService(context: context).checkDeviceBattery()
                // 3. 评估周期性家务与服药日程
                Task {
                    let scheduler = HabitAndMedicationScheduler(context: context)
                    await scheduler.evaluatePeriodicHabits()
                    scheduler.scheduleMedicationReminders()

                    // 4. 执行自动续费防扣款与证件临期巡检
                    let auditor = DailyPainPointAuditor(context: context)
                    auditor.auditAll()
                }
            } else if phase == .background {
                lockManager.appDidEnterBackground()
            }
        }
    }
}
