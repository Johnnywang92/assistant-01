import Foundation

/// 出门与随身出行场景
public enum DepartureScene: String, Codable, CaseIterable, Identifiable, Sendable {
    case commute = "工作通勤"
    case workout = "运动健身"
    case travel = "出差旅行"
    case parenting = "带娃出行"
    case petWalk = "遛狗随行"
    case rainy = "雨雪恶劣"
    case casual = "日常轻装"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .commute: return "briefcase.fill"
        case .workout: return "figure.run"
        case .travel: return "airplane"
        case .parenting: return "figure.and.child.holdinghands"
        case .petWalk: return "pawprint.fill"
        case .rainy: return "cloud.rain.fill"
        case .casual: return "bag.fill"
        }
    }

    public var colorName: String {
        switch self {
        case .commute: return "blue"
        case .workout: return "orange"
        case .travel: return "purple"
        case .parenting: return "pink"
        case .petWalk: return "teal"
        case .rainy: return "teal"
        case .casual: return "green"
        }
    }
}

/// 纯逻辑输入：天气环境快照
public struct DepartureWeatherContext: Equatable, Sendable {
    public let isRainyOrSnowy: Bool
    public let temperatureCelsius: Double?
    public let tempDropDegrees: Double?
    public let isSevereAlert: Bool
    public let weatherDescription: String

    public init(
        isRainyOrSnowy: Bool = false,
        temperatureCelsius: Double? = nil,
        tempDropDegrees: Double? = nil,
        isSevereAlert: Bool = false,
        weatherDescription: String = ""
    ) {
        self.isRainyOrSnowy = isRainyOrSnowy
        self.temperatureCelsius = temperatureCelsius
        self.tempDropDegrees = tempDropDegrees
        self.isSevereAlert = isSevereAlert
        self.weatherDescription = weatherDescription
    }
}

/// 纯逻辑输入：今日日程/待办事件快照
public struct DepartureScheduleEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let dueDate: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        notes: String? = nil,
        isCompleted: Bool = false,
        dueDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
    }
}

/// 纯逻辑输入：物品收纳档案快照（StoredItem 抽象）
public struct DepartureStoredItemSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let location: String
    public let roomArea: String
    public let notes: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        location: String,
        roomArea: String,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.roomArea = roomArea
        self.notes = notes
    }

    /// 格式化存放描述，如 "玄关 · 玄关钥匙收纳盒"
    public var formattedStorageDescription: String {
        if location.hasPrefix(roomArea) {
            return location
        } else {
            return "\(roomArea) · \(location)"
        }
    }
}

/// 推荐建议增补的物品
public struct DepartureSuggestedItem: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let scene: DepartureScene
    public let isEssential: Bool
    public let reason: String
    public let defaultLocation: String?

    public init(
        title: String,
        scene: DepartureScene,
        isEssential: Bool = false,
        reason: String,
        defaultLocation: String? = nil
    ) {
        self.title = title
        self.scene = scene
        self.isEssential = isEssential
        self.reason = reason
        self.defaultLocation = defaultLocation
    }
}

/// 自适应分析建议输出结果
public struct DepartureAdaptiveAdvice: Equatable, Sendable {
    /// 建议聚焦/切换到的出行场景（若有）
    public let recommendedScene: DepartureScene?
    /// 建议横幅主标题
    public let bannerTitle: String?
    /// 建议横幅副标题/详细说明
    public let bannerDetail: String?
    /// 图标 SF Symbol
    public let bannerIcon: String?
    /// 主题颜色名
    public let bannerColorName: String?
    /// 匹配并高亮/置顶的物品关键词（不区分大小写）
    public let priorityItemKeywords: [String]
    /// 建议补充的清单项（当前清单若缺少可一键快捷加入）
    public let suggestedItemsToAdd: [DepartureSuggestedItem]
    /// 指差确认第四字诀自适应文字
    public let ritualFourthWord: String
    public let ritualFourthSubtitle: String
    /// 是否激活雨具强提醒状态
    public let isRainWarningActive: Bool

    public init(
        recommendedScene: DepartureScene? = nil,
        bannerTitle: String? = nil,
        bannerDetail: String? = nil,
        bannerIcon: String? = nil,
        bannerColorName: String? = nil,
        priorityItemKeywords: [String] = [],
        suggestedItemsToAdd: [DepartureSuggestedItem] = [],
        ritualFourthWord: String = "耳/伞",
        ritualFourthSubtitle: String = "耳机/雨具",
        isRainWarningActive: Bool = false
    ) {
        self.recommendedScene = recommendedScene
        self.bannerTitle = bannerTitle
        self.bannerDetail = bannerDetail
        self.bannerIcon = bannerIcon
        self.bannerColorName = bannerColorName
        self.priorityItemKeywords = priorityItemKeywords
        self.suggestedItemsToAdd = suggestedItemsToAdd
        self.ritualFourthWord = ritualFourthWord
        self.ritualFourthSubtitle = ritualFourthSubtitle
        self.isRainWarningActive = isRainWarningActive
    }
}
