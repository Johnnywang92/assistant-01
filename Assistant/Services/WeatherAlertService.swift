import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import UserNotifications
import WeatherKit

/// 气象局严重天气预警、气温骤降与天气突变检测器
/// 支持首页横幅胶囊展示、即时推送、以及前瞻预排期次日早间主动推送到 iPhone 与 Apple Watch（解决早晨未打开 App 查看的问题）
@MainActor
public final class WeatherAlertService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = WeatherAlertService()

    public static let categoryIdentifier = "WEATHER_ALERT"
    public static let actionDismiss = "WEATHER_ACTION_DISMISS"
    public static let actionView = "WEATHER_ACTION_VIEW"
    public static let immediateNotificationId = "weather-alert-active"
    public static let morningNotificationId = "weather-alert-morning"

    public struct AlertBanner: Identifiable, Equatable {
        public enum AlertType: String, Equatable, Sendable {
            case severeWeather = "severeWeather" // 气象局严重预警（暴雨、大风、台风、冰雹、雷电等）
            case tempDrop = "tempDrop"           // 气温骤降突变（降温 >= 6°C）
            case rainSnow = "rainSnow"           // 雨雪天气与出门带伞
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
    /// 早间主动推送时间设置（默认 07:30，格式 "HH:mm"）
    @AppStorage("weather_morning_push_time") public var morningPushTime: String = "07:30"

    // 防打扰与历史温差对比数据（持久化在 UserDefaults）
    @AppStorage("weather_last_dismissed_date") private var lastDismissedDateString: String = ""
    @AppStorage("weather_yesterday_max_temp") private var yesterdayMaxTemp: Double = -999.0
    @AppStorage("weather_last_recorded_date") private var lastRecordedDateString: String = ""
    /// 今日已记录的最高温与日期（用于跨次评估，避免日内二次查询破坏前一日基准）
    @AppStorage("weather_today_recorded_date") private var todayRecordedDateString: String = ""
    @AppStorage("weather_today_max_temp") private var todayRecordedMaxTemp: Double = -999.0
    /// 记录最后一次推送通知的日期与类型，避免同一天内重复打扰
    @AppStorage("weather_last_notified_date") private var lastNotifiedDateString: String = ""
    @AppStorage("weather_last_notified_type") private var lastNotifiedType: String = ""
    /// 最近一次评估停在哪一步。真机排查「为什么没提醒」时唯一可见的证据
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
        public let tomorrowMaxCelsius: Double?
        public let tomorrowConditionDescription: String?

        public var formattedTemperature: String {
            "\(Int(temperatureCelsius.rounded()))°C"
        }

        public init(
            temperatureCelsius: Double,
            symbolName: String,
            conditionDescription: String,
            isRainyOrSnowy: Bool,
            todayMaxCelsius: Double?,
            tomorrowMaxCelsius: Double? = nil,
            tomorrowConditionDescription: String? = nil
        ) {
            self.temperatureCelsius = temperatureCelsius
            self.symbolName = symbolName
            self.conditionDescription = conditionDescription
            self.isRainyOrSnowy = isRainyOrSnowy
            self.todayMaxCelsius = todayMaxCelsius
            self.tomorrowMaxCelsius = tomorrowMaxCelsius
            self.tomorrowConditionDescription = tomorrowConditionDescription
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

            var tomorrowMax: Double? = nil
            var tomorrowDesc: String? = nil
            if weather.dailyForecast.count > 1 {
                let tomorrow = weather.dailyForecast[1]
                tomorrowMax = tomorrow.highTemperature.converted(to: .celsius).value
                tomorrowDesc = L10n.tr(tomorrow.condition.description)
            }

            let snapshot = CurrentWeatherSnapshot(
                temperatureCelsius: tempC,
                symbolName: symbol,
                conditionDescription: L10n.tr(desc),
                isRainyOrSnowy: isRainy,
                todayMaxCelsius: todayMax,
                tomorrowMaxCelsius: tomorrowMax,
                tomorrowConditionDescription: tomorrowDesc
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
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,weather_code&timezone=auto&forecast_days=3"
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
            var tomorrowMax: Double? = nil
            var tomorrowDesc: String? = nil
            if let daily = json["daily"] as? [String: Any] {
                if let maxArr = daily["temperature_2m_max"] as? [Double], !maxArr.isEmpty {
                    todayMax = maxArr.first
                    if maxArr.count > 1 {
                        tomorrowMax = maxArr[1]
                    }
                }
                if let codeArr = daily["weather_code"] as? [Int], codeArr.count > 1 {
                    tomorrowDesc = Self.mapWMOWeatherCode(codeArr[1], isDay: true).description
                }
            }

            let mapped = Self.mapWMOWeatherCode(code, isDay: isDay)
            return CurrentWeatherSnapshot(
                temperatureCelsius: temp,
                symbolName: mapped.symbol,
                conditionDescription: mapped.description,
                isRainyOrSnowy: mapped.isRainyOrSnowy,
                todayMaxCelsius: todayMax,
                tomorrowMaxCelsius: tomorrowMax,
                tomorrowConditionDescription: tomorrowDesc
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

    /// 检查突发气象预警、骤降温差与雨雪突变（在 App 启动、进入前台、后台巡检或情景触发时调用）
    public func checkAlertsIfNeeded(location: CLLocation? = nil) async {
        guard isAlertsEnabled else {
            currentBanner = nil
            cancelAllAlertNotifications()
            return
        }

        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let todayStr = currentDateString()

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

            let current = weather.currentWeather
            let symbol = current.symbolName
            let isRainyOrSnowy = symbol.contains("rain") || symbol.contains("snow") || symbol.contains("drizzle")
            let desc = L10n.tr(current.condition.description)

            let todayMax = weather.dailyForecast.first?.highTemperature.converted(to: .celsius).value ?? current.temperature.converted(to: .celsius).value
            var tomorrowMax: Double? = nil
            var tomorrowDesc: String? = nil
            if weather.dailyForecast.count > 1 {
                let tomorrow = weather.dailyForecast[1]
                tomorrowMax = tomorrow.highTemperature.converted(to: .celsius).value
                tomorrowDesc = L10n.tr(tomorrow.condition.description)
            }

            // 1. 优先检测：气象局严重天气预警 (weather.weatherAlerts)
            var hasSevereAlert = false
            if let alerts = weather.weatherAlerts, !alerts.isEmpty {
                let firstAlert = alerts[0]
                let summary = firstAlert.summary
                let detail = firstAlert.region ?? L10n.tr("官方发布严重气象警报，外出请注意安全！")

                let banner = AlertBanner(
                    type: .severeWeather,
                    title: L10n.choose("气象预警 · \(summary)", "Weather Alert · \(summary)"),
                    detail: detail,
                    icon: "exclamationmark.triangle.fill",
                    color: Color.orange,
                    timestamp: .now
                )
                self.currentBanner = banner
                postAlertNotificationIfNeeded(banner: banner, todayStr: todayStr)
                hasSevereAlert = true
            }

            // 2. 评估今日气温骤降与雨雪天气（若未命中严重预警）
            if !hasSevereAlert {
                evaluateTodayWeather(
                    todayMax: todayMax,
                    isRainyOrSnowy: isRainyOrSnowy,
                    conditionDesc: desc,
                    todayStr: todayStr
                )
            }

            // 3. 次日前瞻预排期：若明天将骤降（≥6°C）或雨雪，直接预先排期到明早设定时间（推送到手机与 Watch）
            scheduleMorningNotificationIfNeeded(
                todayMax: todayMax,
                tomorrowMax: tomorrowMax,
                tomorrowDesc: tomorrowDesc
            )
        } catch {
            // WeatherKit 不可用时使用 Open-Meteo 降级检测
            if let fallback = await fetchOpenMeteoWeather(for: loc),
               let todayMax = fallback.todayMaxCelsius {
                recordCheckStatus("open-meteo-ok")
                evaluateTodayWeather(
                    todayMax: todayMax,
                    isRainyOrSnowy: fallback.isRainyOrSnowy,
                    conditionDesc: fallback.conditionDescription,
                    todayStr: todayStr
                )
                scheduleMorningNotificationIfNeeded(
                    todayMax: todayMax,
                    tomorrowMax: fallback.tomorrowMaxCelsius,
                    tomorrowDesc: fallback.tomorrowConditionDescription
                )
            } else {
                recordCheckStatus("weatherkit-failed-and-no-fallback")
            }
        }
    }

    private func evaluateTodayWeather(
        todayMax: Double,
        isRainyOrSnowy: Bool,
        conditionDesc: String,
        todayStr: String
    ) {
        // 更新温差基准跟踪：跨天切换时将上一天的最后测值滚动为基准
        if todayRecordedDateString != todayStr {
            if !todayRecordedDateString.isEmpty && todayRecordedMaxTemp > -100 {
                yesterdayMaxTemp = todayRecordedMaxTemp
                lastRecordedDateString = todayRecordedDateString
            }
            todayRecordedDateString = todayStr
            todayRecordedMaxTemp = todayMax
        } else {
            todayRecordedMaxTemp = todayMax
        }

        // 今日若已被用户手动划掉关闭，遵循防打扰机制，不展示横幅也不弹窗
        if lastDismissedDateString == todayStr {
            recordCheckStatus("dismissed-today")
            return
        }

        // 1. 优先检测：气温骤降突变（对比今日最高温 vs 上次记录最高温）
        if yesterdayMaxTemp > -100 {
            let drop = yesterdayMaxTemp - todayMax
            if drop >= 6.0 {
                let dropInt = Int(round(drop))
                let todayMaxInt = Int(round(todayMax))
                let yesterdayMaxInt = Int(round(yesterdayMaxTemp))

                let title: String
                let detail: String
                let icon: String

                if isRainyOrSnowy {
                    title = L10n.choose("气温骤降 \(dropInt)°C · 伴有雨雪", "Temp Drop \(dropInt)°C · Rainy/Snowy")
                    detail = L10n.choose(
                        "今日最高仅 \(todayMaxInt)°C（\(baselineLabel())记录最高 \(yesterdayMaxInt)°C）且伴有\(conditionDesc)，温差突变明显，请添衣并携带雨具！",
                        "Today's high is only \(todayMaxInt)°C vs \(yesterdayMaxInt)°C on \(baselineLabel()) with \(conditionDesc). Please dress warmly and take an umbrella!"
                    )
                    icon = "thermometer.snowflake"
                } else {
                    title = L10n.choose("气温骤降 \(dropInt)°C · 出门建议添衣", "Temp Drop \(dropInt)°C · Dress Warmly")
                    detail = L10n.choose(
                        "今日最高仅 \(todayMaxInt)°C（\(baselineLabel())记录最高 \(yesterdayMaxInt)°C），温差突变明显，预防受凉感冒！",
                        "Today's high is only \(todayMaxInt)°C vs \(yesterdayMaxInt)°C on \(baselineLabel()). Stay warm!"
                    )
                    icon = "thermometer.snowflake"
                }

                let banner = AlertBanner(
                    type: .tempDrop,
                    title: title,
                    detail: detail,
                    icon: icon,
                    color: Color.blue,
                    timestamp: .now
                )
                self.currentBanner = banner
                postAlertNotificationIfNeeded(banner: banner, todayStr: todayStr)
                return
            }
        }

        // 2. 次级检测：今日雨雪天气与带伞防滑提醒
        if isRainyOrSnowy {
            let banner = AlertBanner(
                type: .rainSnow,
                title: L10n.choose("今日有雨雪 · 出门建议带伞", "Rain/Snow Today · Take Umbrella"),
                detail: L10n.choose(
                    "预计今日有\(conditionDesc)，出门请携带雨具并注意路滑防跌倒！",
                    "Expected \(conditionDesc) today. Please take an umbrella and watch your step!"
                ),
                icon: "cloud.rain.fill",
                color: Color.teal,
                timestamp: .now
            )
            self.currentBanner = banner
            postAlertNotificationIfNeeded(banner: banner, todayStr: todayStr)
            return
        }

        // 若今天既无气象预警、也无骤降与雨雪，清空当前的非严重预警横幅
        if currentBanner?.type != .severeWeather {
            self.currentBanner = nil
        }
    }

    /// 即时向系统通知中心（iPhone 与 Apple Watch）投递提醒
    private func postAlertNotificationIfNeeded(banner: AlertBanner, todayStr: String) {
        guard isAlertsEnabled else { return }

        // 今日若已被用户手动划掉关闭，遵循防打扰机制
        if lastDismissedDateString == todayStr {
            return
        }

        // 避免同一天内重复推送同一类通知（但如果此前是降温/雨雪，现在来了气象局严重预警，允许升级推送）
        let typeKey = banner.type.rawValue
        if lastNotifiedDateString == todayStr {
            if lastNotifiedType == typeKey || (lastNotifiedType == AlertBanner.AlertType.severeWeather.rawValue && banner.type != .severeWeather) {
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.detail
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "weather-alert"
        content.userInfo = [
            "type": "weatherAlert",
            "date": todayStr,
            "alertType": typeKey
        ]

        let request = UNNotificationRequest(
            identifier: Self.immediateNotificationId,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error == nil {
                Task { @MainActor [weak self] in
                    self?.lastNotifiedDateString = todayStr
                    self?.lastNotifiedType = typeKey
                    // 既然今天已经即时提醒并生效，移除今日可能遗留的早间待触发通知
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.morningNotificationId])
                }
            }
        }
    }

    /// 前瞻预排期：将次日早晨的天气变化预先注册至系统调度，即使用户早晨未打开 App，也准时推送到手机与手表
    private func scheduleMorningNotificationIfNeeded(
        todayMax: Double,
        tomorrowMax: Double?,
        tomorrowDesc: String?
    ) {
        guard isAlertsEnabled, let tomorrowMax else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.morningNotificationId])
            return
        }

        let drop = todayMax - tomorrowMax
        let conditionDesc = tomorrowDesc ?? L10n.tr("雨雪")
        let isRainyTomorrow = conditionDesc.contains("雨") || conditionDesc.contains("雪") || conditionDesc.contains("rain") || conditionDesc.contains("snow")

        // 仅在明日有骤降（>=6°C）或雨雪天气时进行次日早间预排期
        guard drop >= 6.0 || isRainyTomorrow else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.morningNotificationId])
            return
        }

        let dropInt = Int(round(drop))
        let tomorrowMaxInt = Int(round(tomorrowMax))
        let todayMaxInt = Int(round(todayMax))

        let title: String
        let detail: String

        // 早间触发时，对用户而言已经是「今日」
        if drop >= 6.0 && isRainyTomorrow {
            title = L10n.choose("气温骤降 \(dropInt)°C · 伴有雨雪", "Temp Drop \(dropInt)°C · Rainy/Snowy")
            detail = L10n.choose(
                "今日最高仅 \(tomorrowMaxInt)°C（昨日记录最高 \(todayMaxInt)°C）且伴有\(conditionDesc)，早晨出门请务必添衣防寒并携带雨具！",
                "Today's high is only \(tomorrowMaxInt)°C (vs \(todayMaxInt)°C yesterday) with \(conditionDesc). Please dress warmly and take an umbrella!"
            )
        } else if drop >= 6.0 {
            title = L10n.choose("气温骤降 \(dropInt)°C · 出门建议添衣", "Temp Drop \(dropInt)°C · Dress Warmly")
            detail = L10n.choose(
                "今日最高仅 \(tomorrowMaxInt)°C（昨日记录最高 \(todayMaxInt)°C），温差突变明显，早晨出门请注意添衣防寒！",
                "Today's high is only \(tomorrowMaxInt)°C vs \(todayMaxInt)°C yesterday. Significant temp drop, stay warm!"
            )
        } else {
            title = L10n.choose("今日有雨雪 · 出门建议带伞", "Rain/Snow Today · Take Umbrella")
            detail = L10n.choose(
                "预计今日有\(conditionDesc)，早晨出门请带好雨具并注意路滑防跌倒！",
                "Expected \(conditionDesc) today. Please take an umbrella and watch your step!"
            )
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = "weather-alert"

        let calendar = Calendar.current
        guard let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: Date()) else { return }
        var comps = calendar.dateComponents([.year, .month, .day], from: tomorrowDate)

        let timeParts = morningPushTime.split(separator: ":").compactMap { Int($0) }
        comps.hour = timeParts.count == 2 ? timeParts[0] : 7
        comps.minute = timeParts.count == 2 ? timeParts[1] : 30
        comps.second = 0

        content.userInfo = [
            "type": "weatherAlert",
            "date": Self.dayFormatter.string(from: tomorrowDate),
            "alertType": drop >= 6.0 ? AlertBanner.AlertType.tempDrop.rawValue : AlertBanner.AlertType.rainSnow.rawValue,
            "isPreScheduled": true
        ]

        if let scheduledDate = calendar.date(from: comps), scheduledDate > Date() {
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.morningNotificationId,
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    print("⚠️ [WeatherAlert] 预排期明早天气提醒失败: \(error)")
                } else {
                    print("🌤 [WeatherAlert] 已成功预排期明早 \(comps.hour ?? 7):\(comps.minute ?? 30) 天气变化提醒至 iPhone 与 Apple Watch")
                }
            }
        }
    }

    /// 取消所有天气预警相关的通知排期
    public func cancelAllAlertNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            Self.immediateNotificationId,
            Self.morningNotificationId
        ])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            Self.immediateNotificationId,
            Self.morningNotificationId
        ])
    }

    /// 构造天气预警通知交互分类对象
    public static func makeCategory() -> UNNotificationCategory {
        let dismiss = UNNotificationAction(
            identifier: actionDismiss,
            title: L10n.choose("我知道了", "Dismiss"),
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark")
        )
        let view = UNNotificationAction(
            identifier: actionView,
            title: L10n.choose("查看详情", "View Details"),
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app")
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [view, dismiss],
            intentIdentifiers: [],
            options: []
        )
    }

    /// 异步向系统注册天气预警通知交互分类（对齐 Apple Watch 原生按钮与精简交互）
    public static func registerCategory() async {
        let category = makeCategory()
        let center = UNUserNotificationCenter.current()
        var updated = await center.notificationCategories()
        updated.insert(category)
        center.setNotificationCategories(updated)
    }

    /// 用户主动忽略关闭当前横幅
    public func dismissCurrentBanner() {
        lastDismissedDateString = currentDateString()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            currentBanner = nil
        }
        Haptic.light()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            Self.immediateNotificationId,
            Self.morningNotificationId
        ])
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
