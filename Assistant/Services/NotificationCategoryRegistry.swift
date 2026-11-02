import Foundation
import UserNotifications

@MainActor
public enum NotificationCategoryRegistry {
    /// 统一异步注册所有业务模块的交互式通知分类。
    /// 相比于此前各模块各自 await 并进行 6 次低效的 get+set IPC 往返，
    /// 本方法单次合并读写，将冷启动期间对系统通知守护进程 (usernoted) 的 XPC 往返降为 1 次。
    public static func registerAllCategoriesAsync() async {
        var categories: Set<UNNotificationCategory> = [
            TodoNotificationManager.shared.makeCategory(),
            SleepReminderScheduler.makeCategory(),
            PickupCheckoutService.makeCategory(),
            TripArrivalService.shared.makeCategory(),
            WeatherAlertService.makeCategory()
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

