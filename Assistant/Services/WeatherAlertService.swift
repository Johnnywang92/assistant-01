import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import WeatherKit

/// 气象局严重天气预警与气温骤降突变检测器（极低开销，0 额外耗电，随前台激活或情景触发被动执行）
@MainActor
public final class WeatherAlertService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = WeatherAlertService()

    public struct AlertBanner: Identifiable, Equatable {
        public enum AlertType: Equatable {
            case severeWeather // 气象局严重预警（暴雨、大风、台风、冰雹、雷电等）
            case tempDrop      // 气温骤降突变（降温 >= 6°C）
        }

        public let id = UUID()
        public let type: AlertType
        public let title: String
        public let detail: String
        public let icon: String
        public let color: Color
        public let timestamp: Date
    }

    /// 当前在首页顶部显示的预警横幅（可手动划掉关闭）
    @Published public var currentBanner: AlertBanner?

    /// 设置项：是否开启气象突变与降温预警
    @AppStorage("weather_alerts_enabled") public var isAlertsEnabled: Bool = true

    // 防打扰与历史温差对比数据（持久化在 UserDefaults）
    @AppStorage("weather_last_dismissed_date") private var lastDismissedDateString: String = ""
    @AppStorage("weather_yesterday_max_temp") private var yesterdayMaxTemp: Double = -999.0
    @AppStorage("weather_last_recorded_date") private var lastRecordedDateString: String = ""

    private let locationManager = CLLocationManager()
    private var isChecking = false

    private override init() {
        super.init()
        locationManager.delegate = self
    }

    /// 检查突发气象预警与骤降温差（在 App 启动、进入前台、或情景触发时调用）
    public func checkAlertsIfNeeded(location: CLLocation? = nil) async {
        guard isAlertsEnabled else {
            currentBanner = nil
            return
        }

        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        // 今日若已被用户手动划掉关闭，遵循防打扰机制，今天不再弹出
        let todayStr = currentDateString()
        if lastDismissedDateString == todayStr && currentBanner == nil {
            return
        }

        // 尝试获取位置
        guard let loc = location ?? locationManager.location else {
            return
        }

        do {
            let weather = try await WeatherService.shared.weather(for: loc)

            // 1. 优先检测：气象局严重天气预警 (weather.weatherAlerts)
            if let alerts = weather.weatherAlerts, !alerts.isEmpty {
                let firstAlert = alerts[0]
                let summary = firstAlert.summary
                let detail = firstAlert.region ?? "官方发布严重气象警报，外出请注意安全！"

                self.currentBanner = AlertBanner(
                    type: .severeWeather,
                    title: "气象预警 · \(summary)",
                    detail: detail,
                    icon: "exclamationmark.triangle.fill",
                    color: Color.orange,
                    timestamp: .now
                )
                return
            }

            // 2. 检测：气温骤降突变（对比今日最高温 vs 昨日记录最高温）
            if let todayForecast = weather.dailyForecast.first {
                let todayMax = todayForecast.highTemperature.converted(to: .celsius).value

                // 如果已有昨日最高气温基准，且日期跨天
                if yesterdayMaxTemp > -100 && lastRecordedDateString != todayStr {
                    let drop = yesterdayMaxTemp - todayMax
                    if drop >= 6.0 {
                        let dropInt = Int(round(drop))
                        let todayMaxInt = Int(round(todayMax))
                        let yesterdayMaxInt = Int(round(yesterdayMaxTemp))

                        self.currentBanner = AlertBanner(
                            type: .tempDrop,
                            title: "气温骤降 \(dropInt)°C · 出门建议添衣",
                            detail: "今日最高仅 \(todayMaxInt)°C（昨日最高 \(yesterdayMaxInt)°C），温差突变明显，预防受凉感冒！",
                            icon: "thermometer.snowflake",
                            color: Color.blue,
                            timestamp: .now
                        )
                    }
                }

                // 每天滚动更新最高温度记录
                if lastRecordedDateString != todayStr {
                    yesterdayMaxTemp = todayMax
                    lastRecordedDateString = todayStr
                }
            }
        } catch {
            // WeatherKit 离线或不可用时静默降级
        }
    }

    /// 用户主动忽略关闭当前横幅
    public func dismissCurrentBanner() {
        lastDismissedDateString = currentDateString()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            currentBanner = nil
        }
        Haptic.light()
    }

    private func currentDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date.now)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                await self.checkAlertsIfNeeded()
            }
        }
    }
}
