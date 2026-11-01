import AppIntents
import Foundation

/// 快捷指令动作：上报今日手机屏幕使用时间（供用户通过快捷指令自动化定时上报系统屏幕时长）
struct ReportScreenTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "上报屏幕使用时间"
    static var description = IntentDescription("上报今日手机屏幕使用时长（分钟），供睡眠作息算法结合蓝光与晚间用机负荷调整提醒与准备缓冲。")
    static var openAppWhenRun = false

    @Parameter(title: "使用时长（分钟）", default: 180)
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tracker = ScreenTimeTracker.shared
        tracker.recordScreenTime(minutes: minutes)
        // 重新同步晚间就寝计划
        await SleepReminderScheduler.shared.syncSleepReminders()
        let hrs = Double(minutes) / 60.0
        return .result(value: "已记录今日屏幕使用时间：\(minutes) 分钟（约 \(String(format: "%.1f", hrs)) 小时）")
    }
}
