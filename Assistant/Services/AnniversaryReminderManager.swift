import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// 临近纪念日筹备信息模型
public struct UpcomingAnniversaryInfo: Identifiable, Equatable {
    public let id: String                 // 唯一键标识
    public let title: String              // 纪念日标题
    public let targetDate: Date           // 周年日期
    public let daysUntil: Int             // 距离纪念日天数（0...7）
    public let yearsCount: Int            // 纪念周年数
    public let cycleYear: Int             // 年份周期

    public init(id: String, title: String, targetDate: Date, daysUntil: Int, yearsCount: Int, cycleYear: Int) {
        self.id = id
        self.title = title
        self.targetDate = targetDate
        self.daysUntil = daysUntil
        self.yearsCount = yearsCount
        self.cycleYear = cycleYear
    }
}

/// 纪念日临近智能备忘中枢（提前 5~7 天每天一次提醒，支持一键将鲜花、蛋糕、餐厅加入待办，支持不再提醒持久化）
@MainActor
public final class AnniversaryReminderManager: ObservableObject {
    public static let shared = AnniversaryReminderManager()

    @Published public var activeUpcoming: UpcomingAnniversaryInfo? = nil

    private let dismissedKey = "anniversary_dismissed_records"
    private let prepAddedKey = "anniversary_prep_added_records"
    private let lastNotificationDateKey = "anniversary_last_notification_dates"

    private init() {}

    // MARK: - 判定与刷新

    /// 评估当前是否有处于提前 5~7 天（及临近 7 天内）且尚未被忽略的纪念日
    public func refreshActiveUpcoming(context: ModelContext) {
        let cal = Calendar.current
        let now = cal.startOfDay(for: .now)

        // 1. 优先扫描 AnniversaryItem（专业纪念日档案库）
        let descriptor = FetchDescriptor<AnniversaryItem>()
        if let items = try? context.fetch(descriptor) {
            for item in items {
                let nextDate = item.nextAnniversaryDate
                let daysUntil = item.daysUntilNext
                let cycleYear = cal.component(.year, from: nextDate)
                let itemId = "anni_\(item.id.uuidString)"

                // 提前 5~7 天开始提醒（0~7 天内若用户未处理或未忽略，体贴保持展示）
                if daysUntil >= 0 && daysUntil <= 7 {
                    if !isDismissed(id: itemId, year: cycleYear) && !isPrepAdded(id: itemId, year: cycleYear) {
                        self.activeUpcoming = UpcomingAnniversaryInfo(
                            id: itemId,
                            title: item.title,
                            targetDate: nextDate,
                            daysUntil: daysUntil,
                            yearsCount: item.nextYearsCount,
                            cycleYear: cycleYear
                        )
                        return
                    }
                }
            }
        }

        // 2. 补充扫描 TodoItem 中类型为 anniversary 的待办事宜
        let todoDescriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == "anniversary" && $0.statusRaw == "active" }
        )
        if let todoItems = try? context.fetch(todoDescriptor) {
            for todo in todoItems {
                guard let due = todo.dueAt else { continue }
                let targetDay = cal.startOfDay(for: due)
                let days = cal.dateComponents([.day], from: now, to: targetDay).day ?? -1
                let cycleYear = cal.component(.year, from: due)
                let todoId = "todo_\(todo.id.uuidString)"

                if days >= 0 && days <= 7 {
                    if !isDismissed(id: todoId, year: cycleYear) && !isPrepAdded(id: todoId, year: cycleYear) {
                        self.activeUpcoming = UpcomingAnniversaryInfo(
                            id: todoId,
                            title: todo.title,
                            targetDate: due,
                            daysUntil: days,
                            yearsCount: 1,
                            cycleYear: cycleYear
                        )
                        return
                    }
                }
            }
        }

        self.activeUpcoming = nil
    }

    // MARK: - 不再提醒状态持久化

    public func isDismissed(id: String, year: Int) -> Bool {
        let set = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        return set.contains("\(id)_\(year)")
    }

    public func dismiss(for upcoming: UpcomingAnniversaryInfo) {
        var list = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        let key = "\(upcoming.id)_\(upcoming.cycleYear)"
        if !list.contains(key) {
            list.append(key)
            UserDefaults.standard.set(list, forKey: dismissedKey)
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if self.activeUpcoming?.id == upcoming.id {
                self.activeUpcoming = nil
            }
        }
        Haptic.light()
    }

    // MARK: - 一键将准备鲜花、订蛋糕、订餐厅加入待办

    public func isPrepAdded(id: String, year: Int) -> Bool {
        let set = Set(UserDefaults.standard.stringArray(forKey: prepAddedKey) ?? [])
        return set.contains("\(id)_\(year)")
    }

    public func addPreparationTodos(for upcoming: UpcomingAnniversaryInfo, in context: ModelContext) {
        let cal = Calendar.current
        let anniDate = upcoming.targetDate

        // 1. 订浪漫餐厅（建议提前 5 天）
        let restaurantDue = cal.date(byAdding: .day, value: -min(5, max(1, upcoming.daysUntil - 1)), to: anniDate) ?? .now
        let restaurantTodo = TodoItem(
            type: .general,
            status: .active,
            title: "🍽️ 预订浪漫餐厅（为「\(upcoming.title)」）",
            detail: "挑选氛围好或对方喜爱的特色餐厅，提前电话或在线预订双人观景位。",
            dueAt: restaurantDue
        )
        context.insert(restaurantTodo)

        // 2. 预订定制蛋糕（建议提前 3 天）
        let cakeDue = cal.date(byAdding: .day, value: -min(3, max(1, upcoming.daysUntil - 1)), to: anniDate) ?? .now
        let cakeTodo = TodoItem(
            type: .general,
            status: .active,
            title: "🎂 预订定制蛋糕（为「\(upcoming.title)」）",
            detail: "挑选心仪口味与款式，确认蛋糕烘焙配送或自提时间。",
            dueAt: cakeDue
        )
        context.insert(cakeTodo)

        // 3. 准备鲜花与心意礼物（建议提前 1~2 天）
        let flowerDue = cal.date(byAdding: .day, value: -min(1, max(0, upcoming.daysUntil - 1)), to: anniDate) ?? .now
        let flowerTodo = TodoItem(
            type: .general,
            status: .active,
            title: "💐 准备鲜花与礼物（为「\(upcoming.title)」）",
            detail: "预订心仪花束（玫瑰/百合/郁金香），提前准备好节日礼物与贺卡惊喜。",
            dueAt: flowerDue
        )
        context.insert(flowerTodo)

        try? context.save()

        // 标记该年度周期已生成筹备待办
        var list = UserDefaults.standard.stringArray(forKey: prepAddedKey) ?? []
        let key = "\(upcoming.id)_\(upcoming.cycleYear)"
        if !list.contains(key) {
            list.append(key)
            UserDefaults.standard.set(list, forKey: prepAddedKey)
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if self.activeUpcoming?.id == upcoming.id {
                self.activeUpcoming = nil
            }
        }
        Haptic.success()
    }

    // MARK: - 每天一次本地推送提醒 (限频控流)

    public func checkAndSendDailyNotifications(context: ModelContext) {
        refreshActiveUpcoming(context: context)
        guard let upcoming = self.activeUpcoming else { return }

        // 必须处于提前 5~7 天（或者临近区间）
        guard upcoming.daysUntil >= 0 && upcoming.daysUntil <= 7 else { return }

        // 检查今天是否已经发送过提醒
        let notifDates = UserDefaults.standard.dictionary(forKey: lastNotificationDateKey) as? [String: TimeInterval] ?? [:]
        if let lastTimestamp = notifDates[upcoming.id] {
            let lastDate = Date(timeIntervalSince1970: lastTimestamp)
            if Calendar.current.isDateInToday(lastDate) {
                return
            }
        }

        // 发送每日一次本地推送通知
        let daysText = upcoming.daysUntil == 0 ? "就在今天！🎉" : "还有 \(upcoming.daysUntil) 天"
        let content = UNMutableNotificationContent()
        content.title = "💖 纪念日浪漫筹备提醒"
        content.body = "「\(upcoming.title)」\(daysText)！点击打开小助，一键加入准备鲜花、订蛋糕与订餐厅待办。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "anni_prep_\(upcoming.id)_\(upcoming.cycleYear)_\(Date.now.formatted(date: .numeric, time: .omitted))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)

        // 记录今天已提醒的时间戳
        var updated = notifDates
        updated[upcoming.id] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(updated, forKey: lastNotificationDateKey)
    }
}
