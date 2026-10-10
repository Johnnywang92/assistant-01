import Foundation
import SwiftUI

/// 用户生活方式与作息身份
public enum UserLifestyleProfile: String, CaseIterable, Identifiable, Codable {
    case officeWorker = "上班族 (周一至周五通勤)"
    case flexible = "自由职业 / 弹性作息"
    case student = "学生 (周中上课/周末假期)"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .officeWorker: return "上班族"
        case .flexible: return "自由职业"
        case .student: return "学生"
        }
    }

    public var icon: String {
        switch self {
        case .officeWorker: return "briefcase.fill"
        case .flexible: return "laptopcomputer"
        case .student: return "graduationcap.fill"
        }
    }
}

/// 当前推断出的生活时空情境
public enum SituationalState: Equatable {
    case workCommute(isMorning: Bool)  // 工作日通勤（早高峰出门 vs 下班/日间）
    case eveOfHoliday(holidayName: String) // 假日前夕（周五傍晚或长假前夕）
    case holidayTravel(holidayName: String) // 主要节假日远行/出游
    case weekendLeisure                // 普通周末休闲日常
}

/// 本地情境感知中枢（零网络、零耗电、毫秒级本地计算）
@MainActor
public final class SituationalContextEngine: ObservableObject {
    public static let shared = SituationalContextEngine()

    /// 用户身份偏好（默认：普通上班族）
    @AppStorage("user_lifestyle_profile") public var lifestyleProfile: UserLifestyleProfile = .officeWorker
    /// 是否开启全 App 场景智能重排（默认开启）
    @AppStorage("context_adaptive_sorting_enabled") public var isAdaptiveSortingEnabled: Bool = true
    /// 默认下班时间（小时，默认 18:00）
    @AppStorage("user_off_work_hour") public var offWorkHour: Int = 18

    /// 出门清单持久化选中的场景类型 RawValue（"ALL" 表示全部）
    @AppStorage("departure_selected_scene_raw") public var savedDepartureSceneRaw: String = ""
    /// 出门清单用户上次选择该场景的时间戳
    @AppStorage("departure_selected_scene_timestamp") public var savedDepartureSceneTimestamp: Double = 0

    private init() {}

    /// 获取当前时空情境
    public func currentContext(at date: Date = .now) -> SituationalState {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date) // 1=周日, 2=周一 ... 7=周六
        let hour = calendar.component(.hour, from: date)

        // 1. 判断是否处于主要法定节假日中
        if let holiday = detectMajorHoliday(month: month, day: day, date: date) {
            return .holidayTravel(holidayName: holiday)
        }

        // 2. 判断是否处于节假日前夕（例如假日前一天下午 15 点后）
        if let tomorrowHoliday = detectMajorHolidayTomorrow(from: date), hour >= 15 {
            return .eveOfHoliday(holidayName: tomorrowHoliday)
        }

        // 3. 上班族模式逻辑
        if lifestyleProfile == .officeWorker || lifestyleProfile == .student {
            // 周五傍晚 16 点后 -> 周末前夕
            if weekday == 6 && hour >= 16 {
                return .eveOfHoliday(holidayName: "周末")
            }

            // 周六 (7) 或 周日 (1) -> 周末休闲
            if weekday == 1 || weekday == 7 {
                return .weekendLeisure
            }

            // 工作日周一至周五 (2...6)
            let isMorning = hour >= 6 && hour < 11
            return .workCommute(isMorning: isMorning)
        } else {
            // 自由职业：周末稍微偏向休闲，其他均匀
            if weekday == 1 || weekday == 7 {
                return .weekendLeisure
            }
            return .workCommute(isMorning: false)
        }
    }

    // MARK: - 节假日探测 (本地算法，含公历长假与农历除夕春节)

    private func detectMajorHoliday(month: Int, day: Int, date: Date) -> String? {
        // 元旦长假 (1.1 ~ 1.3)
        if month == 1 && day <= 3 { return "元旦假期" }
        // 劳动节长假 (5.1 ~ 5.5)
        if month == 5 && day <= 5 { return "五一假期" }
        // 国庆黄金周 (10.1 ~ 10.7)
        if month == 10 && day <= 7 { return "国庆长假" }

        // 农历计算（春节、中秋、端午）
        let lunarCal = Calendar(identifier: .chinese)
        let lunarMonth = lunarCal.component(.month, from: date)
        let lunarDay = lunarCal.component(.day, from: date)

        // 春节 (农历腊月廿九/除夕 至 正月初七)
        if (lunarMonth == 12 && lunarDay >= 29) || (lunarMonth == 1 && lunarDay <= 7) {
            return "春节长假"
        }
        // 端午 (农历五月初四至初六)
        if lunarMonth == 5 && (lunarDay >= 4 && lunarDay <= 6) {
            return "端午假期"
        }
        // 中秋 (农历八月十四至十六)
        if lunarMonth == 8 && (lunarDay >= 14 && lunarDay <= 16) {
            return "中秋假期"
        }

        return nil
    }

    private func detectMajorHolidayTomorrow(from date: Date) -> String? {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return nil }
        let m = Calendar.current.component(.month, from: tomorrow)
        let d = Calendar.current.component(.day, from: tomorrow)
        return detectMajorHoliday(month: m, day: d, date: tomorrow)
    }

    // MARK: - 业务输出：出门防遗忘场景动态推荐与选择持久化

    /// 根据时空情境、下班时段与气象预警给出的场景排序列表（严格按照可能性大小由高到低排序）
    public func sortedDepartureScenes(at date: Date = .now) -> [DepartureScene] {
        guard isAdaptiveSortingEnabled else {
            return DepartureScene.allCases
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let ctx = currentContext(at: date)
        var scenes: [DepartureScene]

        switch ctx {
        case .holidayTravel, .eveOfHoliday:
            // 节假日或前夕：出差旅行概率最高，其次亲子带娃、宠物日常休闲
            scenes = [.travel, .parenting, .petWalk, .casual, .workout, .commute, .rainy]

        case .weekendLeisure:
            // 周末休闲：带娃与遛狗随行、日常轻装/运动健身排前面
            if hour >= 18 {
                scenes = [.petWalk, .casual, .parenting, .workout, .travel, .commute, .rainy]
            } else {
                scenes = [.parenting, .casual, .petWalk, .workout, .commute, .travel, .rainy]
            }

        case .workCommute:
            // 工作日周一至周五：
            if hour < offWorkHour {
                // 没到下班时间：工作通勤概率最高
                scenes = [.commute, .parenting, .petWalk, .casual, .workout, .travel, .rainy]
            } else {
                // 已过下班时间：晚间遛狗散步、家庭亲子、健身运动概率提升
                scenes = [.petWalk, .workout, .parenting, .casual, .commute, .travel, .rainy]
            }
        }

        // 气象突变/预警联动：若检测到气象预警（如暴雨），将「雨雪恶劣」提升至首选前列
        if WeatherAlertService.shared.currentBanner != nil {
            scenes.removeAll { $0 == .rainy }
            scenes.insert(.rainy, at: 0)
        }

        return scenes
    }

    /// 当天最推荐的默认选中场景
    public func recommendedDefaultDepartureScene(at date: Date = .now) -> DepartureScene {
        guard isAdaptiveSortingEnabled else { return .commute }
        let sorted = sortedDepartureScenes(at: date)
        // 除非恶劣天气预警，否则默认推荐非雨雪的最高概率场景
        if WeatherAlertService.shared.currentBanner != nil {
            return sorted.first ?? .commute
        }
        return sorted.first(where: { $0 != .rainy }) ?? sorted.first ?? .commute
    }

    /// 持久化记录用户对出行场景的选择
    public func saveUserSelectedScene(_ scene: DepartureScene?) {
        if let scene = scene {
            savedDepartureSceneRaw = scene.rawValue
        } else {
            savedDepartureSceneRaw = "ALL"
        }
        savedDepartureSceneTimestamp = Date().timeIntervalSince1970
    }

    /// 获取当天生效的场景选择：
    /// 1. 一天以内严格持久化记住用户的选择
    /// 2. 如果用户选择了工作通勤，在未到下班时间前绝对不自动修改
    /// 3. 如果是全新的一天，则使用当天的推荐场景并持久化
    public func effectiveDepartureScene(at date: Date = .now) -> DepartureScene? {
        let calendar = Calendar.current
        let savedDate = Date(timeIntervalSince1970: savedDepartureSceneTimestamp)

        // 判断是否在同一天内且已有保存记录
        if savedDepartureSceneTimestamp > 0 && calendar.isDate(savedDate, inSameDayAs: date) {
            if savedDepartureSceneRaw == "ALL" {
                return nil
            } else if let scene = DepartureScene(rawValue: savedDepartureSceneRaw) {
                // 如果用户已经选择了工作，在未到下班时间前绝对不自动修改；即使过了下班时间也默认尊重用户的选择，仅提供建议与重排
                return scene
            }
        }

        // 新的一天，根据当天时空概率初始化推荐场景并保存
        let defaultScene = recommendedDefaultDepartureScene(at: date)
        saveUserSelectedScene(defaultScene)
        return defaultScene
    }

    /// 是否应展示下班场景智能切换建议横幅：
    /// 满足：工作日 + 已过下班时间 + 用户当前处于工作通勤场景
    public func shouldSuggestAfterWorkSwitch(currentScene: DepartureScene?, at date: Date = .now) -> Bool {
        guard isAdaptiveSortingEnabled else { return false }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)

        let isWorkday = (2...6).contains(weekday)
        let isAfterWork = hour >= offWorkHour
        let isWorkScene = currentScene == .commute

        return isWorkday && isAfterWork && isWorkScene
    }

    /// 在出门防遗忘视图顶部显示的智能情境徽标提示
    public func departureContextBadge(at date: Date = .now) -> (text: String, icon: String, color: Color)? {
        guard isAdaptiveSortingEnabled else { return nil }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let ctx = currentContext(at: date)

        switch ctx {
        case .holidayTravel(let holiday):
            return ("\(holiday)期间 · 已智能置顶「出差旅行」清单", "airplane.departure", .purple)
        case .eveOfHoliday(let holiday):
            return ("\(holiday)前夕 · 提前为您准备远行与随身行李", "suitcase.fill", .indigo)
        case .weekendLeisure:
            return ("周末闲暇时光 · 优先展示日常出行与运动", "sun.max.fill", .green)
        case .workCommute(let isMorning):
            if hour >= offWorkHour {
                return ("已到下班时间 · 选项已按晚间出行概率重排（推荐健身与休闲）", "moon.stars.fill", .purple)
            } else if isMorning {
                return ("工作日早高峰 · 优先清点工牌工位通勤装备", "briefcase.fill", .blue)
            } else {
                return ("工作日日间工作 · 保持工作通勤装备清点（\(offWorkHour):00 前不下班）", "building.2.fill", .blue)
            }
        }
    }

    // MARK: - 业务输出：语音助手推荐快捷气泡

    /// 语音对话界面的快捷提问动态气泡
    public func dynamicVoicePrompts() -> [String] {
        guard isAdaptiveSortingEnabled else {
            return ["今天有哪些待办？", "出门防丢该带什么？", "今天花了多少钱？", "查一下待取快递", "记一下开会安排"]
        }

        if let ticket = TravelTicketReminderManager.shared.activeUpcomingTicket {
            return [
                "查看「\(ticket.title)」购票建议",
                "提前15天提醒我抢火车票",
                "今天有哪些待办？",
                "今天花了多少钱？",
                "查一下待取快递"
            ]
        }

        let ctx = currentContext()
        switch ctx {
        case .holidayTravel(let holiday):
            return [
                "\(holiday)行李物品清点",
                "假期一共花了多少钱？",
                "查一下出行车票证件",
                "记一笔旅行消费",
                "查看生活纪念日"
            ]
        case .eveOfHoliday(let holiday):
            return [
                "\(holiday)出差旅行该带什么？",
                "今天还有哪些遗留工作？",
                "查一下待取快递",
                "记一笔今天开销",
                "出门指差防丢确认"
            ]
        case .weekendLeisure:
            return [
                "今天有什么休闲安排？",
                "周末家务与大扫除习惯",
                "今天花了多少钱？",
                "查一下待取包裹",
                "出门轻装防丢清点"
            ]
        case .workCommute:
            return [
                "今天有哪些工作待办？",
                "上班通勤防丢该带什么？",
                "查一下待取快递",
                "今天花了多少钱？",
                "记一下明天下午开会"
            ]
        }
    }

    // MARK: - 业务输出：记账高频分类重排

    /// 记账界面快捷高频分类排序
    public func prioritizedExpenseCategories() -> [ExpenseCategory] {
        guard isAdaptiveSortingEnabled else {
            return ExpenseCategory.allCases.filter { !$0.isIncome }
        }

        let ctx = currentContext()
        switch ctx {
        case .holidayTravel, .eveOfHoliday:
            // 节假日旅行：休闲娱乐、交通出行、餐饮美食、购物排前
            return [.entertainment, .transport, .food, .shopping, .living, .social, .digital, .medical, .pets, .other]
        case .weekendLeisure:
            // 周末聚会：餐饮美食、休闲娱乐、购物消费排前
            return [.food, .entertainment, .shopping, .transport, .living, .social, .pets, .digital, .medical, .other]
        case .workCommute:
            // 工作日：餐饮美食（工作餐）、交通出行（打车/地铁/油费）、居家日用
            return [.food, .transport, .shopping, .living, .entertainment, .digital, .social, .medical, .pets, .other]
        }
    }
}
