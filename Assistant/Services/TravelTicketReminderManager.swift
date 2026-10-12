import CoreLocation
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// 出行购票与文博景区预约所处的阶段
public enum TravelTicketStage: Equatable {
    case flightBooking(daysUntilTrainSale: Int) // 机票进入 15~30 天黄金预订期，距离火车票开售还有 X 天
    case trainSaleToday                         // 火车票今日正式开售（刚好提前 15 天）
    case trainOnSale(daysUntilDeparture: Int)   // 火车票热销/抢票中（距离出行还有 8~14 天）
    case scenicSpotSaleToday                    // 热门文博与景区今日起放票预约（刚好提前 7 天）
    case scenicSpotBooking(daysUntilDeparture: Int) // 文博景区门票分时段抢约中（距离出行还有 4~6 天）
    case imminent                               // 临近出发（3 天内，候补捡漏与行李清点）
}

/// 临近出行（节假日/出差/旅游）购票与文博景区预约提醒数据模型
public struct UpcomingTravelTicketInfo: Identifiable, Equatable {
    public let id: String
    public let title: String                    // 例如："国庆长假"、"去北京出差"、"成都亲子游"
    public let departureDate: Date             // 出行目标日期
    public let daysUntilDeparture: Int         // 距离出行天数
    public let isHoliday: Bool                 // 是否为法定节假日
    public let trainSaleDate: Date             // 火车票起售日（出行前 15 天）
    public let flightBookingStartDate: Date    // 机票黄金预订开始日（出行前 30 天）
    public let scenicBookingDate: Date         // 热门博物馆/景区开约日（出行前 7 天）
    public let destinationGuide: String?       // 目的地城市专属文博场馆放票规则
    public let stage: TravelTicketStage

    public init(
        id: String,
        title: String,
        departureDate: Date,
        daysUntilDeparture: Int,
        isHoliday: Bool,
        trainSaleDate: Date,
        flightBookingStartDate: Date,
        scenicBookingDate: Date,
        destinationGuide: String?,
        stage: TravelTicketStage
    ) {
        self.id = id
        self.title = title
        self.departureDate = departureDate
        self.daysUntilDeparture = daysUntilDeparture
        self.isHoliday = isHoliday
        self.trainSaleDate = trainSaleDate
        self.flightBookingStartDate = flightBookingStartDate
        self.scenicBookingDate = scenicBookingDate
        self.destinationGuide = destinationGuide
        self.stage = stage
    }

    /// 格式化出行日期
    public var departureFormatted: String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.choose("M月d日", "MMM d")
        return f.string(from: departureDate)
    }

    /// 格式化火车票开售日期
    public var trainSaleFormatted: String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.choose("M月d日", "MMM d")
        return f.string(from: trainSaleDate)
    }

    /// 格式化热门场馆与景区开约日期
    public var scenicBookingFormatted: String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.choose("M月d日", "MMM d")
        return f.string(from: scenicBookingDate)
    }

    /// 阶段标签文本
    public var stageBadgeText: String {
        switch stage {
        case .trainSaleToday:
            return L10n.tr("火车票今日开售 (提前15天)")
        case .trainOnSale(let days):
            return L10n.choose("火车票抢票中 (还有\(days)天出行)", "Train Tickets On Sale (\(days)d until trip)")
        case .scenicSpotSaleToday:
            return L10n.tr("文博/景区今日开抢 (提前7天)")
        case .scenicSpotBooking(let days):
            return L10n.choose("文博/景区预约中 (还有\(days)天出发)", "Attraction Booking Open (\(days)d until trip)")
        case .flightBooking(let daysUntilTrain):
            return daysUntilTrain > 0
                ? L10n.choose("机票预订期 · \(daysUntilTrain)天后开售火车票", "Flight Window · Train tickets in \(daysUntilTrain)d")
                : L10n.tr("机票最佳预订期")
        case .imminent:
            return L10n.tr("临近出行 · 候补捡漏")
        }
    }

    /// 阶段核心建议描述
    public var recommendationDescription: String {
        switch stage {
        case .trainSaleToday:
            return L10n.tr("12306 火车票今日正式放票（提前15天），建议立即定好闹钟前往抢票！")
        case .trainOnSale:
            return L10n.tr("已进入火车票开售期，若无直达票建议尽快提交候补或预订机票行程。")
        case .scenicSpotSaleToday:
            if let guide = destinationGuide {
                return L10n.choose("热门文博与景区门票今日起开放预约（提前7天）！\(guide)", "Popular museum & attraction reservations open today (7 days ahead)! \(guide)")
            }
            return L10n.tr("目的地国家级/省级博物馆（如故宫/国博/省博等提前7天放票）与热门5A景区门票今日起放票预约，请记得准点抢约！")
        case .scenicSpotBooking:
            if let guide = destinationGuide {
                return L10n.choose("已进入场馆抢约期！\(guide)", "Venue booking window open! \(guide)")
            }
            return L10n.tr("距离出行不足7天，目的地热门博物馆与景区门票已开放分时段预约，请提前锁定入场名额。")
        case .flightBooking:
            return L10n.tr("当前处于机票黄金预订期（提前15-30天），价格相对平稳，建议提前比价锁定。")
        case .imminent:
            return L10n.tr("行程即将开始，若尚未购票请留意 12306 候补退票或选择公路/临时航班。")
        }
    }
}

/// 待用户确认新增的出行购票与预约待办数据模型
public struct ProposedTicketTodo: Identifiable, Hashable, Equatable, Sendable {
    public let id: UUID
    public var categoryKey: String // "train", "flight", "scenic"
    public var title: String
    public var subtitle: String
    public var detail: String
    public var dueAt: Date
    public var remindBeforeMinutes: Int
    public var isSelected: Bool
    public var isCustomized: Bool
    public var icon: String
    public var badge: String

    public init(
        id: UUID = UUID(),
        categoryKey: String,
        title: String,
        subtitle: String,
        detail: String,
        dueAt: Date,
        remindBeforeMinutes: Int,
        isSelected: Bool = true,
        isCustomized: Bool = false,
        icon: String,
        badge: String
    ) {
        self.id = id
        self.categoryKey = categoryKey
        self.title = L10n.tr(title)
        self.subtitle = L10n.tr(subtitle)
        self.detail = L10n.tr(detail)
        self.dueAt = dueAt
        self.remindBeforeMinutes = remindBeforeMinutes
        self.isSelected = isSelected
        self.isCustomized = isCustomized
        self.icon = icon
        self.badge = L10n.tr(badge)
    }
}

/// 出行购票与文博景区预约智能备忘中枢（统筹节假日与出差旅游、火车票提前15天、机票提前15-30天、热门展览/博物馆/景区提前7天预约）
@MainActor
public final class TravelTicketReminderManager: ObservableObject {
    public static let shared = TravelTicketReminderManager()

    @Published public var activeUpcomingTicket: UpcomingTravelTicketInfo? = nil

    private let dismissedKey = "travel_ticket_dismissed_records"
    private let addedTodoKey = "travel_ticket_added_records"
    private let notificationKey = "travel_ticket_notified_dates"

    private init() {}

    // MARK: - 判定与刷新

    /// 评估当前是否有处于购票窗口（1~30 天）且尚未忽略的出行提醒
    public func refreshUpcomingTickets(context: ModelContext) {
        let cal = Calendar.current
        let now = cal.startOfDay(for: .now)

        // 1. 优先扫描用户创建的出差、旅行待办事项（含 TodoType == .travelBooking 或包含出差/旅游关键词且有 dueAt 的活跃事项）
        if let userTicket = scanUserTravelTodos(context: context, now: now, cal: cal) {
            self.activeUpcomingTicket = userTicket
            return
        }

        // 2. 扫描未来重大法定节假日购票窗口（提前 15~30 天机票、提前 15 天火车票、提前 7 天景区预约）
        if let holidayTicket = scanUpcomingHolidayTicket(now: now, cal: cal) {
            self.activeUpcomingTicket = holidayTicket
            return
        }

        self.activeUpcomingTicket = nil
    }

    // MARK: - 扫描用户自建出行待办（自动过滤同城活动与已预约门票）

    private func scanUserTravelTodos(context: ModelContext, now: Date, cal: Calendar) -> UpcomingTravelTicketInfo? {
        let activeRaw = TodoStatus.active.rawValue

        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        )
        guard let items = try? context.fetch(descriptor) else { return nil }

        let userCity = Self.currentUserCity(context: context)

        for item in items {
            guard let due = item.dueAt else { continue }
            let targetDay = cal.startOfDay(for: due)
            guard let daysUntil = cal.dateComponents([.day], from: now, to: targetDay).day,
                  daysUntil >= 1 && daysUntil <= 35 else {
                continue
            }

            guard Self.shouldSuggestCrossCityTickets(
                title: item.title,
                station: item.station,
                location: item.location,
                detail: item.detail,
                hasQRCodeOrTicket: item.hasQRCodeOrTicket,
                type: item.type,
                userCity: userCity
            ) else {
                continue
            }

            let itemId = "todo_travel_\(item.id.uuidString)_\(daysUntil)"
            if isDismissed(id: itemId) || isTodoAdded(id: itemId) {
                continue
            }

            return buildInfo(
                id: itemId,
                title: item.title,
                departureDate: targetDay,
                daysUntil: daysUntil,
                isHoliday: false,
                cal: cal
            )
        }

        return nil
    }

    // MARK: - 同城 vs 异地跨城判断（避免在用户所在城市看展/活动时误提示购买火车票/机票）

    /// 判断某待办事项是否属于需要提前购买火车票/机票的跨城出行
    static func shouldSuggestCrossCityTickets(
        title: String,
        station: String? = nil,
        location: String? = nil,
        detail: String? = nil,
        hasQRCodeOrTicket: Bool = false,
        type: TodoType = .general,
        userCity: String? = nil
    ) -> Bool {
        // 1. 已经带有预约二维码或门票凭证的事项，说明用户已完成预约，不再提示购票
        if hasQRCodeOrTicket {
            return false
        }

        let combined = [title, station, location, detail]
            .compactMap { $0 }
            .joined(separator: " ")

        let currentCity = userCity ?? currentUserCity(context: nil)

        // 2. 若识别出事项发生城市与用户当前所在城市一致（例如用户当前在上海，活动也在上海/西岸/徐汇），无需购买火车票或机票
        if let eventCity = detectCity(in: combined), eventCity == currentCity {
            return false
        }

        // 3. 显式跨城出行类型或包含明确远行交通词
        let crossCityTravelKeywords = ["出差", "旅行", "旅游", "度假", "回老家", "返乡", "探亲", "飞往", "高铁", "火车票", "飞机", "机票"]
        let hasCrossCityKeyword = (type == .travelBooking) || crossCityTravelKeywords.contains { title.contains($0) }

        if hasCrossCityKeyword {
            return true
        }

        // 4. 若是文博/景区/展览关键词，仅当明确指向异地城市（eventCity != nil && eventCity != currentCity）时才提示购买火车票/机票
        let scenicKeywords = ["故宫", "国博", "兵马俑", "三星堆", "莫高窟"]
        if scenicKeywords.contains(where: { title.contains($0) }) {
            if let eventCity = detectCity(in: combined), eventCity != currentCity {
                return true
            }
        }

        return false
    }

    /// 获取用户当前所在城市（优先读取实时定位坐标或常驻地点采样，默认兜底上海）
    static func currentUserCity(context: ModelContext? = nil) -> String {
        if let loc = CLLocationManager().location,
           let city = cityFromCoordinate(loc.coordinate) {
            UserDefaults.standard.set(city, forKey: "cached_user_current_city")
            return city
        }

        if let context {
            var sampleDesc = FetchDescriptor<LocationStaySample>(
                sortBy: [SortDescriptor(\LocationStaySample.timestamp, order: .reverse)]
            )
            sampleDesc.fetchLimit = 1
            if let latestSample = (try? context.fetch(sampleDesc))?.first,
               let city = cityFromCoordinate(CLLocationCoordinate2D(latitude: latestSample.latitude, longitude: latestSample.longitude)) {
                return city
            }

            if let place = (try? context.fetch(FetchDescriptor<LearnedPlace>()))?.first,
               let city = cityFromCoordinate(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) {
                return city
            }
        }

        if let cached = UserDefaults.standard.string(forKey: "cached_user_current_city"), !cached.isEmpty {
            return cached
        }

        return "上海"
    }

    /// 根据经纬度快速离线映射主要城市
    private static func cityFromCoordinate(_ coord: CLLocationCoordinate2D) -> String? {
        let lat = coord.latitude
        let lon = coord.longitude
        if (30.65...31.90).contains(lat) && (120.85...122.25).contains(lon) { return "上海" }
        if (39.40...41.10).contains(lat) && (115.40...117.55).contains(lon) { return "北京" }
        if (22.40...23.95).contains(lat) && (112.90...114.05).contains(lon) { return "广州" }
        if (22.40...22.88).contains(lat) && (113.70...114.65).contains(lon) { return "深圳" }
        if (29.80...30.60).contains(lat) && (119.70...120.75).contains(lon) { return "杭州" }
        if (30.80...31.65).contains(lat) && (120.20...120.84).contains(lon) { return "苏州" }
        if (31.60...32.60).contains(lat) && (118.30...119.25).contains(lon) { return "南京" }
        if (30.10...31.40).contains(lat) && (103.40...104.85).contains(lon) { return "成都" }
        if (29.90...31.30).contains(lat) && (113.70...115.10).contains(lon) { return "武汉" }
        if (33.70...34.75).contains(lat) && (108.20...109.80).contains(lon) { return "西安" }
        return nil
    }

    /// 从标题、场馆或地址文本中识别所属城市（含上海市各区与知名地标识别）
    static func detectCity(in text: String) -> String? {
        let shanghaiMarkers = [
            "上海", "西岸", "徐汇", "浦东", "黄浦", "静安", "长宁", "普陀", "虹口", "杨浦",
            "闵行", "宝山", "嘉定", "松江", "青浦", "奉贤", "崇明", "陆家嘴", "外滩", "张江",
            "上博", "龙耀路"
        ]
        if shanghaiMarkers.contains(where: { text.contains($0) }) {
            return "上海"
        }

        let cityMap: [(city: String, markers: [String])] = [
            ("北京", ["北京", "故宫", "国博", "天坛", "颐和园", "朝阳区", "海淀区"]),
            ("广州", ["广州", "粤博", "天河区", "越秀区"]),
            ("深圳", ["深圳", "南山区", "福田区"]),
            ("杭州", ["杭州", "西湖", "良渚"]),
            ("苏州", ["苏州", "苏博", "拙政园"]),
            ("南京", ["南京", "南博"]),
            ("成都", ["成都", "三星堆"]),
            ("西安", ["西安", "陕历博", "兵马俑"]),
            ("武汉", ["武汉", "黄鹤楼"]),
            ("长沙", ["长沙", "岳麓"]),
            ("重庆", ["重庆", "洪崖洞"]),
            ("敦煌", ["敦煌", "莫高窟"]),
            ("洛阳", ["洛阳", "龙门石窟"]),
            ("三亚", ["三亚"]),
            ("厦门", ["厦门", "鼓浪屿"]),
            ("青岛", ["青岛"])
        ]

        for entry in cityMap {
            if entry.markers.contains(where: { text.contains($0) }) {
                return entry.city
            }
        }
        return nil
    }

    // MARK: - 扫描即将到来的法定节假日

    private func scanUpcomingHolidayTicket(now: Date, cal: Calendar) -> UpcomingTravelTicketInfo? {
        let holidays = calculateHolidays(around: now, cal: cal)

        for holiday in holidays {
            let holidayStart = cal.startOfDay(for: holiday.date)
            guard let daysUntil = cal.dateComponents([.day], from: now, to: holidayStart).day,
                  daysUntil >= 1 && daysUntil <= 32 else {
                continue
            }

            let year = cal.component(.year, from: holidayStart)
            let holidayId = "holiday_\(holiday.name)_\(year)"

            if isDismissed(id: holidayId) || isTodoAdded(id: holidayId) {
                continue
            }

            return buildInfo(
                id: holidayId,
                title: holiday.name,
                departureDate: holidayStart,
                daysUntil: daysUntil,
                isHoliday: true,
                cal: cal
            )
        }

        return nil
    }

    // MARK: - 阶段与模型构造

    private func buildInfo(
        id: String,
        title: String,
        departureDate: Date,
        daysUntil: Int,
        isHoliday: Bool,
        cal: Calendar
    ) -> UpcomingTravelTicketInfo {
        let trainSaleDate = cal.date(byAdding: .day, value: -15, to: departureDate) ?? departureDate
        let flightStartDate = cal.date(byAdding: .day, value: -30, to: departureDate) ?? departureDate
        let scenicBookingDate = cal.date(byAdding: .day, value: -7, to: departureDate) ?? departureDate

        let destinationGuide = Self.detectDestinationGuide(for: title)

        let stage: TravelTicketStage
        if daysUntil == 15 {
            stage = .trainSaleToday
        } else if daysUntil > 15 {
            let daysUntilTrain = daysUntil - 15
            stage = .flightBooking(daysUntilTrainSale: daysUntilTrain)
        } else if daysUntil == 7 {
            stage = .scenicSpotSaleToday
        } else if daysUntil > 7 {
            stage = .trainOnSale(daysUntilDeparture: daysUntil)
        } else if daysUntil >= 4 {
            stage = .scenicSpotBooking(daysUntilDeparture: daysUntil)
        } else {
            stage = .imminent
        }

        return UpcomingTravelTicketInfo(
            id: id,
            title: title,
            departureDate: departureDate,
            daysUntilDeparture: daysUntil,
            isHoliday: isHoliday,
            trainSaleDate: trainSaleDate,
            flightBookingStartDate: flightStartDate,
            scenicBookingDate: scenicBookingDate,
            destinationGuide: destinationGuide,
            stage: stage
        )
    }

    // MARK: - 热门旅游目的地城市文博景区放票规则智能识别

    public static func detectDestinationGuide(for text: String) -> String? {
        if text.contains("北京") || text.contains("故宫") || text.contains("国博") {
            return "北京文博：故宫提前7天20:00放票、中国国家博物馆提前7天17:00放票、天坛/颐和园提前7天预约"
        } else if text.contains("西安") || text.contains("陕历博") || text.contains("兵马俑") {
            return "西安文博：陕西历史博物馆提前3天放票（每日10/11/18/19点）、秦始皇陵兵马俑提前7天预约"
        } else if text.contains("成都") || text.contains("四川") || text.contains("三星堆") {
            return "四川文博：三星堆博物馆提前5天20:00放票、成都大熊猫繁育基地提前7天预约、成都博物馆提前3天"
        } else if text.contains("南京") || text.contains("南博") {
            return "南京文博：南京博物院提前7天18:00放票、侵华日军南京大屠杀遇难同胞纪念馆提前7天"
        } else if text.contains("上海") || text.contains("上博") || text.contains("迪士尼") {
            return "上海文博：上海博物馆提前7天12:00放票、迪士尼提前10-30天早鸟票、中华艺术宫提前实名预约"
        } else if text.contains("苏州") || text.contains("苏博") {
            return "苏州文博：苏州博物馆提前7天08:00放票、拙政园/狮子林提前7天预约"
        } else if text.contains("敦煌") || text.contains("莫高窟") {
            return "敦煌文博：莫高窟提前30天每日07:00抢A类正常参观票、鸣沙山月牙泉实名预约"
        } else if text.contains("杭州") || text.contains("西湖") || text.contains("良渚") {
            return "杭州文博：良渚博物院提前7天预约、浙江省博物馆之江馆提前7天、西湖游船实名购票"
        } else if text.contains("广州") || text.contains("深圳") || text.contains("粤博") {
            return "广深文博：广东省博物馆提前7天22:00放票、南越王博物院提前7天预约"
        } else if text.contains("武汉") || text.contains("湖北") || text.contains("省博") {
            return "湖北文博：湖北省博物馆提前5天放票、黄鹤楼提前7天预约"
        } else if text.contains("长沙") || text.contains("湖南") {
            return "湖南文博：湖南历史博物馆提前7天20:00放票、岳麓书院提前3天预约"
        } else if text.contains("洛阳") || text.contains("河南") {
            return "河南文博：河南博物院提前3天放票、龙门石窟提前7天预约、洛阳古墓博物馆提前3天"
        }
        return nil
    }

    // MARK: - 中国主要法定节假日日期推算

    private struct HolidayEntry {
        let name: String
        let date: Date
    }

    private func calculateHolidays(around baseDate: Date, cal: Calendar) -> [HolidayEntry] {
        let currentYear = cal.component(.year, from: baseDate)
        var entries: [HolidayEntry] = []

        for year in [currentYear, currentYear + 1] {
            // 1. 元旦 (1月1日)
            if let d = cal.date(from: DateComponents(year: year, month: 1, day: 1)) {
                entries.append(HolidayEntry(name: "元旦假期", date: d))
            }
            // 2. 清明节 (通常公历 4月4日 或 4月5日)
            if let d = cal.date(from: DateComponents(year: year, month: 4, day: 4)) {
                entries.append(HolidayEntry(name: "清明假期", date: d))
            }
            // 3. 劳动节 (5月1日)
            if let d = cal.date(from: DateComponents(year: year, month: 5, day: 1)) {
                entries.append(HolidayEntry(name: "五一假期", date: d))
            }
            // 4. 国庆长假 (10月1日)
            if let d = cal.date(from: DateComponents(year: year, month: 10, day: 1)) {
                entries.append(HolidayEntry(name: "国庆长假", date: d))
            }

            // 5. 农历节日：春节、端午、中秋
            let lunarCal = Calendar(identifier: .chinese)
            // 扫描该年份内的农历匹配
            if let springFestival = findDateInYear(year: year, targetLunarMonth: 1, targetLunarDay: 1, lunarCal: lunarCal, cal: cal) {
                entries.append(HolidayEntry(name: "春节长假", date: springFestival))
            }
            if let dragonBoat = findDateInYear(year: year, targetLunarMonth: 5, targetLunarDay: 5, lunarCal: lunarCal, cal: cal) {
                entries.append(HolidayEntry(name: "端午假期", date: dragonBoat))
            }
            if let midAutumn = findDateInYear(year: year, targetLunarMonth: 8, targetLunarDay: 15, lunarCal: lunarCal, cal: cal) {
                entries.append(HolidayEntry(name: "中秋假期", date: midAutumn))
            }
        }

        return entries.sorted { $0.date < $1.date }
    }

    private func findDateInYear(year: Int, targetLunarMonth: Int, targetLunarDay: Int, lunarCal: Calendar, cal: Calendar) -> Date? {
        // 从该年 1 月 1 日到次年 2 月 28 日遍历查找
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
        for offset in 0...390 {
            if let checkDate = cal.date(byAdding: .day, value: offset, to: start) {
                let m = lunarCal.component(.month, from: checkDate)
                let d = lunarCal.component(.day, from: checkDate)
                if m == targetLunarMonth && d == targetLunarDay {
                    return checkDate
                }
            }
        }
        return nil
    }

    // MARK: - 交互操作：生成预选建议与用户显式确认新增待办

    /// 根据出行信息推算待用户确认的购票与预约事项
    public func generateProposedTicketTodos(for info: UpcomingTravelTicketInfo) -> [ProposedTicketTodo] {
        return generateProposedTicketTodos(
            title: info.title,
            departureDate: info.departureDate,
            daysUntilDeparture: info.daysUntilDeparture,
            destinationGuide: info.destinationGuide
        )
    }

    /// 通用待办建议生成（支持自建待办或预警卡片联动）
    public func generateProposedTicketTodos(
        title: String,
        departureDate: Date,
        daysUntilDeparture: Int? = nil,
        destinationGuide: String? = nil
    ) -> [ProposedTicketTodo] {
        let cal = Calendar.current
        let now = Date.now
        let departure = cal.startOfDay(for: departureDate)
        let days = daysUntilDeparture ?? (cal.dateComponents([.day], from: cal.startOfDay(for: now), to: departure).day ?? 15)

        var items: [ProposedTicketTodo] = []

        let trainSaleDate = cal.date(byAdding: .day, value: -15, to: departure) ?? departure
        let scenicBookingDate = cal.date(byAdding: .day, value: -7, to: departure) ?? departure

        let trainFmt: String = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return formatter.string(from: trainSaleDate)
        }()
        let departureFmt: String = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return formatter.string(from: departure)
        }()

        // 1. 火车票提醒（提前15天放票日 08:00）
        let trainDue: Date
        if trainSaleDate > now {
            trainDue = cal.date(bySettingHour: 8, minute: 0, second: 0, of: trainSaleDate) ?? trainSaleDate
        } else {
            trainDue = cal.date(byAdding: .hour, value: 2, to: now) ?? now
        }

        let trainItem = ProposedTicketTodo(
            categoryKey: "train",
            title: "🚂 抢购【\(title)】火车票（提前15天）",
            subtitle: "放票日：\(trainFmt) 08:00起分批开售",
            detail: "出行日期 \(departureFmt)。12306 火车票于 \(trainFmt) 正式起售，请提前设好闹钟抢票或提交候补。",
            dueAt: trainDue,
            remindBeforeMinutes: 30,
            isSelected: true,
            icon: "train.side.front.car",
            badge: "提前15天开售"
        )
        items.append(trainItem)

        // 2. 机票/酒店提前比价预订（提前 15~30 天）
        let flightDue: Date
        if days >= 28 {
            flightDue = now
        } else if days >= 15 {
            flightDue = cal.date(byAdding: .hour, value: 4, to: now) ?? now
        } else {
            flightDue = now
        }

        let flightItem = ProposedTicketTodo(
            categoryKey: "flight",
            title: "✈️ 预订【\(title)】机票与酒店（提前15-30天）",
            subtitle: "特惠机票与紧俏房源黄金比价期",
            detail: "出行日期 \(departureFmt)。当前处于 15~30 天机票特惠预订黄金期，建议尽早比对折扣机票与紧俏酒店。",
            dueAt: flightDue,
            remindBeforeMinutes: 0,
            isSelected: true,
            icon: "airplane",
            badge: "提前15-30天"
        )
        items.append(flightItem)

        // 3. 热门博物馆/展览/景区门票提前预约（提前 7 天）
        let scenicDue: Date
        if scenicBookingDate > now {
            scenicDue = cal.date(bySettingHour: 10, minute: 0, second: 0, of: scenicBookingDate) ?? scenicBookingDate
        } else {
            scenicDue = cal.date(byAdding: .hour, value: 3, to: now) ?? now
        }

        let scenicFmt: String = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return formatter.string(from: scenicBookingDate)
        }()
        let guide = destinationGuide ?? Self.detectDestinationGuide(for: title)
        let scenicDetailPrefix = guide != nil ? "【重点场馆放票指南】：\(guide!)。" : ""

        let scenicItem = ProposedTicketTodo(
            categoryKey: "scenic",
            title: "🏛️ 预约【\(title)】热门博物馆/特展与景区门票（提前7天）",
            subtitle: guide != nil ? "含目的地文博放票指南 · 放票日：\(scenicFmt)" : "国家级与省级文博场馆 · 放票日：\(scenicFmt)",
            detail: "出行日期 \(departureFmt)。\(scenicDetailPrefix)国家级与省级热门博物馆（如故宫、国博、省博等提前7天放票）及5A景区均需实名分时段预约，请提前关注放票整点并锁定入场名额。",
            dueAt: scenicDue,
            remindBeforeMinutes: 60,
            isSelected: true,
            icon: "building.columns.fill",
            badge: "提前7天预约"
        )
        items.append(scenicItem)

        return items
    }

    /// 用户显式确认后，将勾选的事项批量写入待办清单
    @discardableResult
    public func confirmAndInsertTicketTodos(
        _ items: [ProposedTicketTodo],
        for info: UpcomingTravelTicketInfo,
        context: ModelContext
    ) -> Int {
        var count = 0
        for item in items where item.isSelected {
            let noteSuffix = item.isCustomized ? "\n（注：预约时间已由用户核对并自定义确认）" : ""
            let fullDetail = item.detail + noteSuffix
            let todo = TodoItem(
                type: .travelBooking,
                status: .active,
                title: item.title,
                detail: fullDetail,
                dueAt: item.dueAt,
                remindBeforeMinutes: item.remindBeforeMinutes
            )
            context.insert(todo)
            TodoNotificationManager.shared.scheduleNotification(for: todo)
            count += 1
        }

        try? context.save()
        markTodoAdded(id: info.id)
        self.activeUpcomingTicket = nil
        return count
    }

    /// 一键将出行购票与文博景区预约提醒加入系统待办清单（全量新增快捷方法）
    public func addTicketTodos(for info: UpcomingTravelTicketInfo, context: ModelContext) {
        let proposed = generateProposedTicketTodos(for: info)
        _ = confirmAndInsertTicketTodos(proposed, for: info, context: context)
    }

    /// 设置本周期不再提醒该出行
    public func dismiss(for info: UpcomingTravelTicketInfo) {
        markDismissed(id: info.id)
        self.activeUpcomingTicket = nil
    }

    // MARK: - 每日通知推送巡检

    /// 每日痛点与通知巡检时联动触发
    public func checkAndSendDailyNotifications(context: ModelContext) {
        refreshUpcomingTickets(context: context)
        guard let info = activeUpcomingTicket else { return }

        let notifId = "ticket_daily_\(info.id)_\(info.daysUntilDeparture)"
        let cal = Calendar.current
        let dateKey = "notif_sent_\(notifId)"

        if let lastDate = UserDefaults.standard.object(forKey: dateKey) as? Date,
           cal.isDateInToday(lastDate) {
            return
        }

        let title: String
        let body: String

        if info.daysUntilDeparture == 7 {
            title = "🏛️ 热门文博与景区今日起预约（提前7天）"
            let guideDesc = info.destinationGuide != nil ? "（\(info.destinationGuide!)）" : "（如故宫、国博、省博等热门场馆）"
            body = "距离「\(info.title)」还有 7 天，目的地热门博物馆与景区门票今日起开放预约\(guideDesc)，请留意放票整点准时抢约！"
        } else if info.daysUntilDeparture == 15 {
            title = "🚂 12306 火车票今日开售提醒"
            body = "「\(info.title)」将于 \(info.departureFormatted) 开始，提前 15 天火车票今日正式放票，请记得准时抢票！"
        } else if info.daysUntilDeparture == 30 {
            title = "✈️ 出行机票黄金预订期开启"
            body = "距离「\(info.title)」还有 30 天，机票进入 15~30 天最佳预订折扣期，建议提前锁定行程。"
        } else {
            return
        }

        UserDefaults.standard.set(Date.now, forKey: dateKey)
        NotificationService.post(title: title, body: body, id: notifId)
    }

    // MARK: - 内部持久化辅助

    private func isDismissed(id: String) -> Bool {
        let set = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        return set.contains(id)
    }

    private func markDismissed(id: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        set.insert(id)
        UserDefaults.standard.set(Array(set), forKey: dismissedKey)
    }

    private func isTodoAdded(id: String) -> Bool {
        let set = Set(UserDefaults.standard.stringArray(forKey: addedTodoKey) ?? [])
        return set.contains(id)
    }

    private func markTodoAdded(id: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: addedTodoKey) ?? [])
        set.insert(id)
        UserDefaults.standard.set(Array(set), forKey: addedTodoKey)
    }
}
