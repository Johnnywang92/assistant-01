import Foundation
import SwiftData

/// 用户常驻地点分类
public enum PlaceCategory: String, Codable, CaseIterable {
    case home = "家"
    case company = "公司"
    case parcelStation = "常用驿站"
    case other = "其他地点"

    public var icon: String {
        switch self {
        case .home: "house.fill"
        case .company: "building.2.fill"
        case .parcelStation: "shippingbox.fill"
        case .other: "mappin.and.ellipse"
        }
    }
}

/// 学习到的地点档案
@Model
public final class LearnedPlace {
    public var id: UUID
    public var name: String
    public var categoryRaw: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    /// 绑定的常用 Wi-Fi BSSID 或 SSID 列表（如家庭 Wi-Fi 名称）
    public var associatedWiFiSSIDs: [String]
    /// 累积停留访问次数
    public var visitCount: Int
    /// 统计规律：夜间停留概率（0.0 ~ 1.0）
    public var nightStayProbability: Double
    /// 统计规律：工作日白天停留概率（0.0 ~ 1.0）
    public var workdayDayStayProbability: Double
    /// 是否已被用户确认（若未确认，则为自学习推测）
    public var isUserConfirmed: Bool
    public var lastVisitedAt: Date

    public init(
        name: String,
        category: PlaceCategory,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 150,
        associatedWiFiSSIDs: [String] = [],
        visitCount: Int = 1,
        nightStayProbability: Double = 0.0,
        workdayDayStayProbability: Double = 0.0,
        isUserConfirmed: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.categoryRaw = category.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.associatedWiFiSSIDs = associatedWiFiSSIDs
        self.visitCount = visitCount
        self.nightStayProbability = nightStayProbability
        self.workdayDayStayProbability = workdayDayStayProbability
        self.isUserConfirmed = isUserConfirmed
        self.lastVisitedAt = .now
    }

    public var category: PlaceCategory {
        get { PlaceCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
}

/// 历史足迹与驻留采样（离线聚合学习）
@Model
public final class LocationStaySample {
    public var id: UUID
    public var latitude: Double
    public var longitude: Double
    public var wifiSSID: String?
    public var timestamp: Date
    public var hourOfDay: Int
    public var isWeekend: Bool

    public init(
        latitude: Double,
        longitude: Double,
        wifiSSID: String?,
        timestamp: Date = .now
    ) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.wifiSSID = wifiSSID
        self.timestamp = timestamp

        let cal = Calendar.current
        self.hourOfDay = cal.component(.hour, from: timestamp)
        self.isWeekend = cal.isDateInWeekend(timestamp)
    }
}
