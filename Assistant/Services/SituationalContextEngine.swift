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

    // MARK: - 业务输出：出门防遗忘场景动态推荐

    /// 根据情境给出的场景排序列表
    public func sortedDepartureScenes() -> [DepartureScene] {
        guard isAdaptiveSortingEnabled else {
            return DepartureScene.allCases
        }

        let ctx = currentContext()
        switch ctx {
        case .holidayTravel, .eveOfHoliday:
            // 节假日或前夕：出差旅行排第一位！
            return [.travel, .casual, .commute, .workout, .rainy]

        case .weekendLeisure:
            // 周末休闲：日常轻装/运动健身排前面
            return [.casual, .workout, .commute, .travel, .rainy]

        case .workCommute:
            // 工作日通勤：工作通勤排第一位！
            return [.commute, .casual, .workout, .travel, .rainy]
        }
    }

    /// 当前最推荐的默认选中场景
    public func recommendedDefaultDepartureScene() -> DepartureScene {
        guard isAdaptiveSortingEnabled else { return .commute }
        return sortedDepartureScenes().first ?? .commute
    }

    /// 在出门防遗忘视图顶部显示的智能情境徽标提示
    public func departureContextBadge() -> (text: String, icon: String, color: Color)? {
        guard isAdaptiveSortingEnabled else { return nil }
        let ctx = currentContext()
        switch ctx {
        case .holidayTravel(let holiday):
            return ("\(holiday)期间 · 已智能置顶「出差旅行」清单", "airplane.departure", .purple)
        case .eveOfHoliday(let holiday):
            return ("\(holiday)前夕 · 提前为您准备远行与随身行李", "suitcase.fill", .indigo)
        case .weekendLeisure:
            return ("周末闲暇时光 · 优先展示日常出行与运动", "sun.max.fill", .green)
        case .workCommute(let isMorning):
            if isMorning {
                return ("工作日早高峰 · 优先清点工牌工位通勤装备", "briefcase.fill", .blue)
            } else {
                return ("工作日日程中 · 优先工作通勤清单", "building.2.fill", .blue)
            }
        }
    }

    // MARK: - 业务输出：语音助手推荐快捷气泡

    /// 语音对话界面的快捷提问动态气泡
    public func dynamicVoicePrompts() -> [String] {
        guard isAdaptiveSortingEnabled else {
            return ["今天有哪些待办？", "出门防丢该带什么？", "今天花了多少钱？", "查一下待取快递", "记一下开会安排"]
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
