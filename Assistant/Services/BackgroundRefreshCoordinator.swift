import BackgroundTasks
import Foundation
import SwiftData

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

        // 执行 4 项幂等且关键的后台巡检
        await performIdempotentAudits(context: context, isExpired: { isExpired })

        // 巡检查验并同步待办事项通知排期
        if !isExpired {
            TodoNotificationManager.shared.syncAllTodoNotifications(context: context)
        }

        // 刷新小组件与桌面共享快照
        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)

        task.setTaskCompleted(success: !isExpired)
    }

    /// 幂等巡检核心实现：供后台任务与前台 active 共用
    func performIdempotentAudits(context: ModelContext, isExpired: () -> Bool = { false }) async {
        // 1. 回到前台或后台唤醒时补录收件箱里积压的短信（inbox.txt）
        if !isExpired() {
            await InboxService.drain(context: context)
        }

        // 2. 执行自动续费防扣款与证件临期巡检
        if !isExpired() {
            let auditor = DailyPainPointAuditor(context: context)
            auditor.auditAll()
        }

        // 3. 巡检查验固定周期支出并自动入账，随后评估预算超支预警
        if !isExpired() {
            RecurringExpenseManager.shared.processDueRecurringExpenses(in: context)
            BudgetAlertService.shared.evaluateAndNotify(context: context)
        }

        // 4. 排空分享扩展中转区
        if !isExpired() {
            await ShareInboxService.processAll(context: context)
        }

        // 5. 到站/落地清点提醒：先按到达时间对账排期，再用运动证据判断是否已停下
        if !isExpired() {
            TripArrivalService.shared.syncAllReminders(context: context)
            await TripArrivalService.shared.evaluate(context: context)
        }

        // 6. 若开启了 NAS / 私有云盘自动同步，执行一次静默后台加密备份
        if !isExpired() {
            await WebDAVSyncService.shared.performBackgroundSyncIfNeeded(context: context)
        }

        // 7. 天气突变与降温评估。后台只走零成本路径：用定位服务的最近一次采样，
        // 不主动开 GPS——BGAppRefresh 预算只有几十秒，室内定位可能一直等不到结果。
        if !isExpired() {
            await WeatherAlertService.shared.checkAlertsIfNeeded()
        }
    }
}
