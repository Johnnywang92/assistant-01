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
    /// 最近一次评估停在哪一步。真机排查「为什么没提醒」时唯一可见的证据，
    /// 早退分支若不落盘就永远只是猜测。
    @AppStorage("weather_last_check_status") private var lastCheckStatus: String = ""

    private let locationManager = CLLocationManager()
    private var isChecking = false

    private override init() {
        super.init()
        locationManager.delegate = self
    }

    public struct CurrentWeatherSnapshot: Equatable {
        public let temperatureCelsius: Double
        public let symbolName: String
        public let conditionDescription: String
        public let isRainyOrSnowy: Bool
        public let todayMaxCelsius: Double?

        public var formattedTemperature: String {
            "\(Int(temperatureCelsius.rounded()))°C"
        }
    }

    @AppStorage("weather_cached_temp") private var cachedTemp: Double = -999.0
    @AppStorage("weather_cached_symbol") private var cachedSymbol: String = "cloud.sun.fill"
    @AppStorage("weather_cached_desc") private var cachedDesc: String = "多云"

    public var cachedWeatherSnapshot: CurrentWeatherSnapshot? {
        guard cachedTemp > -100 else { return nil }
        let isRainy = cachedSymbol.contains("rain") || cachedSymbol.contains("snow") || cachedSymbol.contains("drizzle")
        return CurrentWeatherSnapshot(
            temperatureCelsius: cachedTemp,
            symbolName: cachedSymbol,
            conditionDescription: L10n.tr(cachedDesc),
            isRainyOrSnowy: isRainy,
            todayMaxCelsius: nil
        )
    }

    /// 获取当前天气（优先使用 Apple WeatherKit；若未配置 WeatherKit 权限或签名受限，自动降级为免密钥 Open-Meteo 气象接口）
    public func fetchCurrentWeather(for location: CLLocation) async -> CurrentWeatherSnapshot? {
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let tempC = current.temperature.converted(to: .celsius).value
            let symbol = current.symbolName
            let desc = current.condition.description
            let isRainy = symbol.contains("rain") || symbol.contains("snow") || symbol.contains("drizzle")
            let todayMax = weather.dailyForecast.first?.highTemperature.converted(to: .celsius).value

            let snapshot = CurrentWeatherSnapshot(
                temperatureCelsius: tempC,
                symbolName: symbol,
                conditionDescription: L10n.tr(desc),
                isRainyOrSnowy: isRainy,
                todayMaxCelsius: todayMax
            )
            saveCache(snapshot)
            return snapshot
        } catch {
            if let fallback = await fetchOpenMeteoWeather(for: location) {
                saveCache(fallback)
                return fallback
            }
            return cachedWeatherSnapshot
        }
    }

    private func saveCache(_ snapshot: CurrentWeatherSnapshot) {
        cachedTemp = snapshot.temperatureCelsius
        cachedSymbol = snapshot.symbolName
        cachedDesc = snapshot.conditionDescription
    }

    private func fetchOpenMeteoWeather(for location: CLLocation) async -> CurrentWeatherSnapshot? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max&timezone=auto&forecast_days=1"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double else {
                return nil
            }
            let code = (current["weather_code"] as? Int) ?? 0
            let isDay = ((current["is_day"] as? Int) ?? 1) == 1

            var todayMax: Double? = nil
            if let daily = json["daily"] as? [String: Any],
               let maxArr = daily["temperature_2m_max"] as? [Double],
               let firstMax = maxArr.first {
                todayMax = firstMax
            }

            let mapped = Self.mapWMOWeatherCode(code, isDay: isDay)
            return CurrentWeatherSnapshot(
                temperatureCelsius: temp,
                symbolName: mapped.symbol,
                conditionDescription: mapped.description,
                isRainyOrSnowy: mapped.isRainyOrSnowy,
                todayMaxCelsius: todayMax
            )
        } catch {
            return nil
        }
    }

    private static func mapWMOWeatherCode(_ code: Int, isDay: Bool) -> (symbol: String, description: String, isRainyOrSnowy: Bool) {
        switch code {
        case 0:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", L10n.tr("晴"), false)
        case 1, 2:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", L10n.tr("多云"), false)
        case 3:
            return ("cloud.fill", L10n.tr("阴"), false)
        case 45, 48:
            return ("cloud.fog.fill", L10n.tr("雾"), false)
        case 51, 53, 55, 56, 57:
            return ("cloud.drizzle.fill", L10n.tr("毛毛雨"), true)
        case 61, 63, 80, 81:
            return ("cloud.rain.fill", L10n.tr("小到中雨"), true)
        case 65, 66, 67, 82:
            return ("cloud.heavyrain.fill", L10n.tr("大雨"), true)
        case 71, 73, 75, 77, 85, 86:
            return ("cloud.snow.fill", L10n.tr("降雪"), true)
        case 95, 96, 99:
            return ("cloud.bolt.rain.fill", L10n.tr("雷阵雨"), true)
        default:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", L10n.tr("多云"), false)
        }
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
            recordCheckStatus("dismissed-today")
            return
        }

        // 位置三级回退。本服务自己的 CLLocationManager 只设过 delegate、从未启动更新，
        // 不能当唯一来源；真正在跑 GPS 的是 LocationReminderService（地理围栏与单次采样）。
        guard let loc = location
                ?? LocationReminderService.shared.lastKnownLocation
                ?? locationManager.location else {
            recordCheckStatus("no-location")
            return
        }

        do {
            let weather = try await WeatherService.shared.weather(for: loc)
            recordCheckStatus("weatherkit-ok")

            // 1. 优先检测：气象局严重天气预警 (weather.weatherAlerts)
            if let alerts = weather.weatherAlerts, !alerts.isEmpty {
                let firstAlert = alerts[0]
                let summary = firstAlert.summary
                let detail = firstAlert.region ?? L10n.tr("官方发布严重气象警报，外出请注意安全！")

                self.currentBanner = AlertBanner(
                    type: .severeWeather,
                    title: L10n.choose("气象预警 · \(summary)", "Weather Alert · \(summary)"),
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
                evaluateTempDrop(todayMax: todayMax, todayStr: todayStr)
            }
        } catch {
            // WeatherKit 不可用时使用 Open-Meteo 最高温降级检测降温预警
            if let fallback = await fetchOpenMeteoWeather(for: loc),
               let todayMax = fallback.todayMaxCelsius {
                recordCheckStatus("open-meteo-ok")
                evaluateTempDrop(todayMax: todayMax, todayStr: todayStr)
            } else {
                recordCheckStatus("weatherkit-failed-and-no-fallback")
            }
        }
    }

    private func evaluateTempDrop(todayMax: Double, todayStr: String) {
        if yesterdayMaxTemp > -100 && lastRecordedDateString != todayStr {
            let drop = yesterdayMaxTemp - todayMax
            if drop >= 6.0 {
                let dropInt = Int(round(drop))
                let todayMaxInt = Int(round(todayMax))
                let yesterdayMaxInt = Int(round(yesterdayMaxTemp))

                self.currentBanner = AlertBanner(
                    type: .tempDrop,
                    title: L10n.choose("气温骤降 \(dropInt)°C · 出门建议添衣", "Temp Drop \(dropInt)°C · Dress Warmly"),
                    detail: L10n.choose(
                        "今日最高仅 \(todayMaxInt)°C（\(baselineLabel())记录最高 \(yesterdayMaxInt)°C），温差突变明显，预防受凉感冒！",
                        "Today's high is only \(todayMaxInt)°C vs \(yesterdayMaxInt)°C on \(baselineLabel()). Stay warm!"
                    ),
                    icon: "thermometer.snowflake",
                    color: Color.blue,
                    timestamp: .now
                )
            }
        }

        if lastRecordedDateString != todayStr {
            yesterdayMaxTemp = todayMax
            lastRecordedDateString = todayStr
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

    /// 温差基准的措辞必须反映快照的真实记录日：App 可能隔好几天才成功评估一次，
    /// 继续沿用「昨日最高」是在报一个对不上的基准。
    private func baselineLabel() -> String {
        guard let date = Self.dayParser.date(from: lastRecordedDateString) else {
            return L10n.choose("上次记录", "the last record")
        }
        // 展示用的格式化器不能做成 static：语言/区域是运行时可变的，缓存会把文案冻在旧区域设置上。
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(L10n.isEnglish ? "MMM d" : "M月d日")
        return formatter.string(from: date)
    }

    private func recordCheckStatus(_ status: String) {
        lastCheckStatus = "\(currentDateString()) \(status)"
        print("🌤 [WeatherAlert] \(status)")
    }

    private func currentDateString() -> String {
        Self.dayFormatter.string(from: Date.now)
    }

    /// 落盘用的日期串必须与系统日历无关：跟随 Current locale 时，
    /// 用户改历法（如佛历）会让 `lastRecordedDateString` 的比对整体失真。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - CLLocationManagerDelegate

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                await self.checkAlertsIfNeeded()
            }
        }
    }
}
