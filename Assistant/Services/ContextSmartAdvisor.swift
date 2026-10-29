import CoreLocation
import Foundation
import SwiftData
import WeatherKit

/// 上下文环境触发类型
public enum ContextTriggerReason: String, Sendable {
    case leaveHomeOrDisconnectWiFi = "离开家/断开家庭Wi-Fi"
    case arriveHomeOrConnectWiFi = "到家/连接家庭Wi-Fi"
    case morningBriefing = "早晨出门简报"
    case eveningBriefing = "晚间提醒"
    case locationArrive = "到达指定地点"

    public var displayName: String { L10n.tr(rawValue) }
}

/// 上下文环境智能决策服务
@MainActor
struct ContextSmartAdvisor {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 评估环境上下文，生成贴合当前情景的通知与提醒
    /// - Parameters:
    ///   - reason: 触发原因（Wi-Fi 连接/断开、时间点、地点到达）
    ///   - wifiSSID: 当前或变更的 Wi-Fi 名称（可选）
    ///   - location: 当前经纬度（可选，用于查询离线/天气）
    /// - Returns: 提醒文本（如果有需要提醒的事项）
    public func evaluate(
        reason: ContextTriggerReason,
        wifiSSID: String? = nil,
        location: CLLocation? = nil
    ) async -> String? {
        let active = TodoStatus.active.rawValue
        let allActive = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == active }
        ))) ?? []

        let parcels = allActive.filter { $0.type == .parcel }
        let events = allActive.filter { $0.type == .event }
        let generals = allActive.filter { $0.type == .general || $0.type == .bill }

        // 调用方没带位置时回退到定位服务的最近一次采样：此前天气分支只在「调用方显式传
        // location」时才执行，而全仓库唯一调用点（快捷指令 ContextTriggerIntent）并不传，
        // 等于整条天气链路——包括拼进通知文案的预警横幅——永远进不来。
        let resolvedLocation = location ?? LocationReminderService.shared.lastKnownLocation

        // 0. 自动学习与推断当前地点（家/公司/其他）
        let learningEngine = PlaceLearningEngine(context: context)
        let resolvedPlace = learningEngine.resolveCurrentPlace(wifiSSID: wifiSSID, coordinate: resolvedLocation?.coordinate)
        let placeName = resolvedPlace.map { L10n.tr($0.name.isEmpty ? $0.category.rawValue : $0.name) } ?? ""

        // 1. 根据天气环境决策（出门带伞、雨天提醒、气象突变与降温添衣）
        var weatherNotice: String?
        if let resolvedLocation {
            weatherNotice = await fetchWeatherNotice(for: resolvedLocation)
            await WeatherAlertService.shared.checkAlertsIfNeeded(location: resolvedLocation)
            if let banner = WeatherAlertService.shared.currentBanner {
                let alertPrefix = "\(banner.title)：\(banner.detail)"
                weatherNotice = (weatherNotice != nil) ? "\(alertPrefix)\n\(weatherNotice!)" : alertPrefix
            }
        }

        var adviceParts: [String] = []

        switch reason {
        case .leaveHomeOrDisconnectWiFi, .morningBriefing:
            // 出门/离家/离开公司情景
            let fromDesc = placeName.isEmpty ? L10n.choose("出门", "Leaving") : L10n.choose("离开\(placeName)", "Leaving \(placeName)")
            if let weatherNotice {
                adviceParts.append(weatherNotice)
            }

            // 如果顺路有待取件
            if !parcels.isEmpty {
                let codes = parcels.compactMap(\.pickupCode).joined(separator: ", ")
                adviceParts.append(L10n.choose(
                    "📦 \(fromDesc)别忘顺路取件：\(parcels.count)个包裹（取件码: \(codes)）",
                    "📦 \(fromDesc): Don't forget \(parcels.count) parcel(s) (Code: \(codes))"
                ))
            }

            // 今天到期的日程
            let todayEvents = filterTodayEvents(events)
            if !todayEvents.isEmpty {
                let titles = todayEvents.map(\.title).joined(separator: "；")
                adviceParts.append(L10n.choose("📅 今日待办日程：\(titles)", "📅 Today's schedule: \(titles)"))
            }

        case .arriveHomeOrConnectWiFi, .eveningBriefing:
            // 到家或到达公司情景
            let atDesc = placeName.isEmpty ? L10n.choose("到家", "Home") : L10n.choose("已到达\(placeName)", "Arrived at \(placeName)")
            if !parcels.isEmpty {
                let codes = parcels.compactMap(\.pickupCode).joined(separator: ", ")
                adviceParts.append(L10n.choose(
                    "⚠️ \(atDesc)提醒：还有 \(parcels.count) 个快递尚未取走（取件码: \(codes)）",
                    "⚠️ \(atDesc) reminder: \(parcels.count) parcel(s) waiting (Code: \(codes))"
                ))
            }

            // 晚间常规待办
            if !generals.isEmpty {
                adviceParts.append(L10n.choose("📝 还有 \(generals.count) 项待办待完成", "📝 \(generals.count) to-do item(s) remaining"))
            }

        case .locationArrive:
            let atDesc = placeName.isEmpty ? L10n.choose("目标区域", "destination") : placeName
            if !parcels.isEmpty {
                let codes = parcels.compactMap(\.pickupCode).joined(separator: ", ")
                adviceParts.append(L10n.choose("📦 已到达 \(atDesc)：待取件 \(codes)", "📦 Arrived at \(atDesc): Parcel code \(codes)"))
            }
        }

        guard !adviceParts.isEmpty else { return nil }
        return adviceParts.joined(separator: "\n")
    }

    // MARK: - 天气感知 (WeatherKit + Open-Meteo 自动降级)

    private func fetchWeatherNotice(for location: CLLocation) async -> String? {
        guard let current = await WeatherAlertService.shared.fetchCurrentWeather(for: location) else {
            return nil
        }
        let temp = current.formattedTemperature
        if current.isRainyOrSnowy {
            return L10n.choose(
                "🌧️ 当前天气：\(temp) \(current.conditionDescription)，外出请记得带伞！",
                "🌧️ Current weather: \(temp) \(current.conditionDescription). Don't forget an umbrella!"
            )
        } else {
            return L10n.choose(
                "⛅ 当前气温 \(temp)，\(current.conditionDescription)",
                "⛅ Current temperature: \(temp), \(current.conditionDescription)"
            )
        }
    }

    private func filterTodayEvents(_ items: [TodoItem]) -> [TodoItem] {
        let cal = Calendar.current
        return items.filter { item in
            guard let due = item.dueAt else { return false }
            return cal.isDateInToday(due)
        }
    }
}
