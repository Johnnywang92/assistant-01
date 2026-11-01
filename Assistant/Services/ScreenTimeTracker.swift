import Foundation
import SwiftUI

/// 手机屏幕使用时间追踪与管理服务。
///
/// ## iOS 系统限制与合规设计
/// - iOS 系统的 Screen Time（屏幕使用时间）出于极端隐私考虑，禁止普通第三方 App 直接后台读取系统全局或其它 App 的屏幕时长。
/// - 本服务采用三层数据汇聚结构：
///   1. **快捷指令自动化接入**：提供 `ReportScreenTimeIntent`（AppIntent），用户可在 iOS「快捷指令」中配置每日定时自动化上报系统屏幕使用时间；
///   2. **主动设置与调节**：在健康与睡眠设置中支持用户手动滑动录入或查看今日屏幕使用时间；
///   3. **应用前台活跃时长保底**：自动记录本应用在前台活跃的累计分钟数，保证无快捷指令时也有基线数据支撑。
@MainActor
public final class ScreenTimeTracker: ObservableObject {
    public static let shared = ScreenTimeTracker()

    private enum Keys {
        static let screenTimeMinutes = "screentime.todayMinutes"
        static let recordedDay = "screentime.recordedDayKey"
        static let inAppActiveSeconds = "screentime.inAppActiveSeconds"
    }

    /// 今日手机屏幕使用总时长（分钟）
    @Published public var todayScreenTimeMinutes: Int {
        didSet {
            UserDefaults.standard.set(todayScreenTimeMinutes, forKey: Keys.screenTimeMinutes)
            UserDefaults.standard.set(todayDayKeyString(), forKey: Keys.recordedDay)
        }
    }

    private var activeSessionStart: Date?

    private init() {
        let savedDate = UserDefaults.standard.string(forKey: Keys.recordedDay)
        let todayStr = Self.formatDayKey(Date.now)
        if savedDate == todayStr {
            self.todayScreenTimeMinutes = UserDefaults.standard.integer(forKey: Keys.screenTimeMinutes)
        } else {
            self.todayScreenTimeMinutes = 0
            UserDefaults.standard.set(0, forKey: Keys.screenTimeMinutes)
            UserDefaults.standard.set(todayStr, forKey: Keys.recordedDay)
        }
    }

    /// 上报或更新今日屏幕使用时间（如由快捷指令或用户手动调整传入）
    public func recordScreenTime(minutes: Int) {
        checkDayRollover()
        self.todayScreenTimeMinutes = max(0, minutes)
    }

    /// 标记进入前台，开始会话计时
    public func appWillEnterForeground() {
        checkDayRollover()
        activeSessionStart = Date.now
    }

    /// 标记进入后台，累加应用活跃时间
    public func appDidEnterBackground() {
        checkDayRollover()
        if let start = activeSessionStart {
            let elapsedSec = Date.now.timeIntervalSince(start)
            activeSessionStart = nil
            if elapsedSec > 5 {
                let currentInApp = UserDefaults.standard.double(forKey: Keys.inAppActiveSeconds) + elapsedSec
                UserDefaults.standard.set(currentInApp, forKey: Keys.inAppActiveSeconds)
                // 若用户未通过快捷指令上报更高屏幕时间，则至少以本应用前台时长作为底线
                let inAppMinutes = Int(currentInApp / 60.0)
                if inAppMinutes > todayScreenTimeMinutes {
                    self.todayScreenTimeMinutes = inAppMinutes
                }
            }
        }
    }

    private func checkDayRollover() {
        let savedDate = UserDefaults.standard.string(forKey: Keys.recordedDay)
        let todayStr = todayDayKeyString()
        if savedDate != todayStr {
            todayScreenTimeMinutes = 0
            UserDefaults.standard.set(0, forKey: Keys.screenTimeMinutes)
            UserDefaults.standard.set(0.0, forKey: Keys.inAppActiveSeconds)
            UserDefaults.standard.set(todayStr, forKey: Keys.recordedDay)
        }
    }

    private func todayDayKeyString() -> String {
        Self.formatDayKey(Date.now)
    }

    private static func formatDayKey(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
