import Foundation
import UserNotifications

@MainActor
public enum NotificationCategoryRegistry {
    /// 统一异步注册所有业务模块的交互式通知分类。
    /// 相比于此前各模块各自 await 并进行多次低效的 get+set IPC 往返，
    /// 本方法单次合并读写，将冷启动期间对系统通知守护进程 (usernoted) 的 XPC 往返降为 1 次。
    ///
    /// 定期报告通知原先只在 content 上写了 `PERIODIC_REPORT` 却从未注册分类，
    /// 这里补全注册，让锁屏上的「查看报告」动作真正可用。
    public static func registerAllCategoriesAsync() async {
        var categories: Set<UNNotificationCategory> = [
            TodoNotificationManager.shared.makeCategory(),
            SleepReminderScheduler.makeCategory(),
            PickupCheckoutService.makeCategory(),
            TripArrivalService.shared.makeCategory(),
            WeatherAlertService.makeCategory(),
            PsychReminderScheduler.makeCategory(),
            PeriodicReportManager.makeNotificationCategory()
        ]
        for cat in LiveActivityControlNotifications.makeCategories() {
            categories.insert(cat)
        }

        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.formUnion(categories)
        center.setNotificationCategories(updated)
    }
}

