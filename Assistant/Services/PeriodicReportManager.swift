import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// 报告周期类型
enum ReportPeriodType: String, CaseIterable, Identifiable, Sendable {
    case daily = "日报"
    case weekly = "周报"
    case monthly = "月报"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daily: return "calendar.day.timeline.leading"
        case .weekly: return "chart.bar.xaxis"
        case .monthly: return "calendar.badge.clock"
        }
    }

    var description: String {
        switch self {
        case .daily: return "每日晚间生活与待办复盘"
        case .weekly: return "周度执行力与财务全景回顾"
        case .monthly: return "全月成果沉淀与次月规划"
        }
    }
}

/// 类别支出聚合数据
struct CategoryExpenseStat: Identifiable, Sendable {
    var id: String { category.rawValue }
    let category: ExpenseCategory
    let amount: Double
    let count: Int
    let ratio: Double
}

/// 周期复盘聚合报告数据结构
struct PeriodicReportData: Identifiable {
    var id: String { "\(period.rawValue)-\(startDate.timeIntervalSince1970)" }
    let period: ReportPeriodType
    let targetDate: Date
    let startDate: Date
    let endDate: Date
    let title: String
    let subtitle: String

    // 待办统计
    let completedTodos: [TodoItem]
    let createdTodos: [TodoItem]
    let pendingTodos: [TodoItem]
    let completionRate: Double
    let parcelCount: Int

    // 收支统计
    let totalExpense: Double
    let totalIncome: Double
    let expenseCount: Int
    let categoryStats: [CategoryExpenseStat]
    let maxExpenseItem: ExpenseRecord?

    // 习惯与健康
    let habitStreakCount: Int

    // 下一周期前瞻预告
    let upcomingTodos: [TodoItem]

    // 智能总结评价
    let smartSummary: String

    // 成就等级评估
    var achievementLevel: String {
        if completionRate >= 0.8 && completedTodos.count >= 3 {
            return "超额完成 🌟"
        } else if completionRate >= 0.5 || completedTodos.count >= 1 {
            return "稳步推进 🚀"
        } else if createdTodos.isEmpty && completedTodos.isEmpty {
            return "从容惬意 ☕️"
        } else {
            return "蓄力前行 💪"
        }
    }

    /// 建议导出的文件名（不带扩展名）
    var suggestedFileName: String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        switch period {
        case .daily:
            df.dateFormat = "yyyyMMdd"
            return "小助生活日报_\(df.string(from: targetDate))"
        case .weekly:
            let year = cal.component(.yearForWeekOfYear, from: targetDate)
            let week = cal.component(.weekOfYear, from: targetDate)
            return "小助复盘周报_\(year)年第\(week)周"
        case .monthly:
            df.dateFormat = "yyyy年MM月"
            return "小助成果月报_\(df.string(from: targetDate))"
        }
    }

    /// 将 Markdown 内容写入临时沙盒文件并返回文件 URL，用于系统分享与「存储到文件」
    func generateMarkdownFile() -> URL? {
        let md = exportMarkdown()
        let fileName = "\(suggestedFileName).md"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    /// 导出为结构化 Markdown 文本
    func exportMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("> 📅 统计周期：\(subtitle)  ")
        lines.append("> 🏆 状态评价：\(achievementLevel)  ")
        lines.append("> ⏱ 导出时间：\(Date.now.formatted(date: .numeric, time: .shortened)) · 由小助个人助手端侧生成")
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append("## 💡 智能复盘小结")
        lines.append("")
        lines.append(smartSummary)
        lines.append("")
        lines.append("## 📋 待办事项进展")
        lines.append("")
        lines.append("| 统计维度 | 数值 |")
        lines.append("| :--- | :--- |")
        lines.append("| 周期内已完成待办 | \(completedTodos.count) 件 |")
        lines.append("| 事项达成率 | \(Int(completionRate * 100))% |")
        lines.append("| 周期内新录入事项 | \(createdTodos.count) 件 |")
        lines.append("| 当前待推进事项 | \(pendingTodos.count) 件 |")
        lines.append("| 收发包裹快递 | \(parcelCount) 件 |")
        lines.append("")
        if !completedTodos.isEmpty {
            lines.append("### 已完成清单明细：")
            for item in completedTodos {
                let timeStr = item.completedAt.map { " (\($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
                lines.append("- [x] **\(item.title)**\(timeStr)")
                if let detail = item.detail, !detail.isEmpty {
                    lines.append("  > \(detail)")
                }
            }
            lines.append("")
        }
        lines.append("## 💰 财务与收支统计")
        lines.append("")
        lines.append("- **总支出**：¥\(String(format: "%.2f", totalExpense)) （共 \(expenseCount) 笔）")
        if totalIncome > 0 {
            lines.append("- **总收入**：¥\(String(format: "%.2f", totalIncome))")
        }
        if let maxItem = maxExpenseItem {
            lines.append("- **单笔最大开支**：¥\(String(format: "%.2f", maxItem.amount)) （\(maxItem.title)）")
        }
        if !categoryStats.isEmpty {
            lines.append("")
            lines.append("### 支出分类构成：")
            lines.append("| 类别 | 金额 (元) | 笔数 | 占比 |")
            lines.append("| :--- | :--- | :--- | :--- |")
            for stat in categoryStats {
                lines.append("| \(stat.category.rawValue) | ¥\(String(format: "%.2f", stat.amount)) | \(stat.count) 笔 | \(Int(stat.ratio * 100))% |")
            }
            lines.append("")
        }
        if !upcomingTodos.isEmpty {
            lines.append("## 🔭 下期前瞻备忘")
            lines.append("")
            for item in upcomingTodos {
                let dueStr = item.dueAt?.formatted(date: .numeric, time: .shortened) ?? "未设截止时间"
                lines.append("- [ ] **\(item.title)** （截止：\(dueStr)）")
                if let detail = item.detail, !detail.isEmpty {
                    lines.append("  > \(detail)")
                }
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("*本报告默认在设备上生成；仅在你开启局域网问答后，相关摘要可能发送到指定端点。*")
        return lines.joined(separator: "\n")
    }
}

/// 定期报告服务管理器
@MainActor
final class PeriodicReportManager: ObservableObject {
    static let shared = PeriodicReportManager()

    // MARK: - 用户偏好配置（日报默认开启）

    /// 日报是否开启（默认开启）
    @AppStorage("periodic_report_daily_enabled") var isDailyReportEnabled: Bool = true {
        didSet { scheduleNotifications() }
    }

    /// 日报提醒时间 (默认 21:30)
    @AppStorage("periodic_report_daily_time_interval") private var dailyTimeInterval: Double = 21 * 3600 + 30 * 60 {
        didSet { scheduleNotifications() }
    }

    /// 周报是否开启（默认关闭）
    @AppStorage("periodic_report_weekly_enabled") var isWeeklyReportEnabled: Bool = false {
        didSet { scheduleNotifications() }
    }

    /// 周报提醒日（1 代表周日，2 代表周一，默认周日 1）
    @AppStorage("periodic_report_weekly_weekday") var weeklyReportWeekday: Int = 1 {
        didSet { scheduleNotifications() }
    }

    /// 周报提醒时间 (默认 21:00)
    @AppStorage("periodic_report_weekly_time_interval") private var weeklyTimeInterval: Double = 21 * 3600 {
        didSet { scheduleNotifications() }
    }

    /// 月报是否开启（默认关闭）
    @AppStorage("periodic_report_monthly_enabled") var isMonthlyReportEnabled: Bool = false {
        didSet { scheduleNotifications() }
    }

    /// 月报提醒时间 (默认 21:00)
    @AppStorage("periodic_report_monthly_time_interval") private var monthlyTimeInterval: Double = 21 * 3600 {
        didSet { scheduleNotifications() }
    }

    // MARK: - 辅助计算属性

    var dailyTime: Date {
        get {
            let cal = Calendar.current
            let now = Date.now
            let hours = Int(dailyTimeInterval) / 3600
            let minutes = (Int(dailyTimeInterval) % 3600) / 60
            return cal.date(bySettingHour: hours, minute: minutes, second: 0, of: now) ?? now
        }
        set {
            let cal = Calendar.current
            let h = cal.component(.hour, from: newValue)
            let m = cal.component(.minute, from: newValue)
            dailyTimeInterval = Double(h * 3600 + m * 60)
        }
    }

    var weeklyTime: Date {
        get {
            let cal = Calendar.current
            let now = Date.now
            let hours = Int(weeklyTimeInterval) / 3600
            let minutes = (Int(weeklyTimeInterval) % 3600) / 60
            return cal.date(bySettingHour: hours, minute: minutes, second: 0, of: now) ?? now
        }
        set {
            let cal = Calendar.current
            let h = cal.component(.hour, from: newValue)
            let m = cal.component(.minute, from: newValue)
            weeklyTimeInterval = Double(h * 3600 + m * 60)
        }
    }

    var monthlyTime: Date {
        get {
            let cal = Calendar.current
            let now = Date.now
            let hours = Int(monthlyTimeInterval) / 3600
            let minutes = (Int(monthlyTimeInterval) % 3600) / 60
            return cal.date(bySettingHour: hours, minute: minutes, second: 0, of: now) ?? now
        }
        set {
            let cal = Calendar.current
            let h = cal.component(.hour, from: newValue)
            let m = cal.component(.minute, from: newValue)
            monthlyTimeInterval = Double(h * 3600 + m * 60)
        }
    }

    private init() {}

    // MARK: - 周期数据报告计算引擎

    /// 为指定日期生成指定周期的聚合报告数据
    func generateReport(period: ReportPeriodType, for targetDate: Date, context: ModelContext) -> PeriodicReportData {
        let cal = Calendar.current
        let (startDate, endDate, title, subtitle) = calculateDateRange(period: period, targetDate: targetDate, calendar: cal)

        // 1. 查询待办事项
        let allTodos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []

        // 在时间跨度内完成的事项 (通过 completedAt 判定，若无则降级看由于在区间内)
        let completedInPeriod = allTodos.filter { todo in
            guard todo.status == .done else { return false }
            if let comp = todo.completedAt {
                return comp >= startDate && comp <= endDate
            }
            return todo.createdAt >= startDate && todo.createdAt <= endDate
        }

        // 在时间跨度内新创建的事项
        let createdInPeriod = allTodos.filter { $0.createdAt >= startDate && $0.createdAt <= endDate }

        // 截止当前仍未完成的活跃事项
        let pendingInPeriod = allTodos.filter { $0.status == .active }

        let parcelCount = allTodos.filter { todo in
            (todo.type == .parcel || todo.type == .returnParcel) &&
            ((todo.completedAt != nil && todo.completedAt! >= startDate && todo.completedAt! <= endDate) ||
             (todo.createdAt >= startDate && todo.createdAt <= endDate))
        }.count

        let totalTargetCount = completedInPeriod.count + pendingInPeriod.count
        let completionRate = totalTargetCount > 0 ? Double(completedInPeriod.count) / Double(totalTargetCount) : (completedInPeriod.isEmpty ? 0.0 : 1.0)

        // 2. 查询消费支出账单
        let allExpenses = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
        let expensesInPeriod = allExpenses.filter { $0.date >= startDate && $0.date <= endDate }

        let expenseOnly = expensesInPeriod.filter { !$0.isIncome }
        let incomeOnly = expensesInPeriod.filter { $0.isIncome }

        let totalExpense = expenseOnly.reduce(0.0) { $0 + $1.amount }
        let totalIncome = incomeOnly.reduce(0.0) { $0 + $1.amount }
        let maxExpenseItem = expenseOnly.max(by: { $0.amount < $1.amount })

        // 分类支出占比分析
        var categoryMap: [ExpenseCategory: (amount: Double, count: Int)] = [:]
        for exp in expenseOnly {
            let cat = ExpenseCategory(rawValue: exp.categoryRaw) ?? .other
            let prev = categoryMap[cat] ?? (0.0, 0)
            categoryMap[cat] = (prev.amount + exp.amount, prev.count + 1)
        }

        let categoryStats: [CategoryExpenseStat] = categoryMap.map { (cat, val) in
            let ratio = totalExpense > 0 ? val.amount / totalExpense : 0.0
            return CategoryExpenseStat(category: cat, amount: val.amount, count: val.count, ratio: ratio)
        }.sorted(by: { $0.amount > $1.amount })

        // 3. 习惯与家务打卡统计
        let allHabits = (try? context.fetch(FetchDescriptor<PeriodicHabit>())) ?? []
        let habitStreakCount = allHabits.filter { habit in
            if let last = habit.lastCompletedAt {
                return last >= startDate && last <= endDate
            }
            return false
        }.count

        // 4. 下一周期前瞻 (在 endDate 之后最近 7 天内到期或未完成的待办)
        let futureLimit = cal.date(byAdding: .day, value: period == .monthly ? 15 : 7, to: endDate) ?? endDate
        let upcomingTodos = allTodos.filter { todo in
            guard todo.status == .active, let due = todo.dueAt else { return false }
            return due > endDate && due <= futureLimit
        }.sorted(by: { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) })

        // 5. 生成智能复盘总结
        let smartSummary = generateSmartSummary(
            period: period,
            completedCount: completedInPeriod.count,
            createdCount: createdInPeriod.count,
            pendingCount: pendingInPeriod.count,
            completionRate: completionRate,
            totalExpense: totalExpense,
            categoryStats: categoryStats,
            parcelCount: parcelCount,
            upcomingCount: upcomingTodos.count
        )

        return PeriodicReportData(
            period: period,
            targetDate: targetDate,
            startDate: startDate,
            endDate: endDate,
            title: title,
            subtitle: subtitle,
            completedTodos: completedInPeriod,
            createdTodos: createdInPeriod,
            pendingTodos: pendingInPeriod,
            completionRate: completionRate,
            parcelCount: parcelCount,
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            expenseCount: expenseOnly.count,
            categoryStats: categoryStats,
            maxExpenseItem: maxExpenseItem,
            habitStreakCount: habitStreakCount,
            upcomingTodos: upcomingTodos,
            smartSummary: smartSummary
        )
    }

    // MARK: - 日期范围与标题计算

    private func calculateDateRange(period: ReportPeriodType, targetDate: Date, calendar cal: Calendar) -> (Date, Date, String, String) {
        switch period {
        case .daily:
            let start = cal.startOfDay(for: targetDate)
            let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: start) ?? start
            let isToday = cal.isDateInToday(targetDate)
            let titlePrefix = isToday ? "今日生活日报" : targetDate.formatted(.dateTime.month().day()) + " 日报"
            let sub = targetDate.formatted(date: .complete, time: .omitted)
            return (start, end, titlePrefix, sub)

        case .weekly:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: targetDate)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: targetDate)
            let end = cal.date(byAdding: .day, value: 6, to: start).flatMap {
                cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0)
            } ?? targetDate
            let weekNumber = cal.component(.weekOfYear, from: targetDate)
            let title = "\(cal.component(.year, from: targetDate))年第 \(weekNumber) 周 · 复盘周报"
            let sub = "\(start.formatted(.dateTime.month().day())) ~ \(end.formatted(.dateTime.month().day()))"
            return (start, end, title, sub)

        case .monthly:
            let comps = cal.dateComponents([.year, .month], from: targetDate)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: targetDate)
            let range = cal.range(of: .day, in: .month, for: targetDate)?.count ?? 30
            let end = cal.date(byAdding: .day, value: range - 1, to: start).flatMap {
                cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0)
            } ?? targetDate
            let monthName = targetDate.formatted(.dateTime.year().month())
            let title = "\(monthName) · 成果月报"
            let sub = "\(monthName) 1日 ~ \(range)日"
            return (start, end, title, sub)
        }
    }

    // MARK: - 智能复盘寄语生成

    private func generateSmartSummary(
        period: ReportPeriodType,
        completedCount: Int,
        createdCount: Int,
        pendingCount: Int,
        completionRate: Double,
        totalExpense: Double,
        categoryStats: [CategoryExpenseStat],
        parcelCount: Int,
        upcomingCount: Int
    ) -> String {
        var segments: [String] = []

        // 待办执行力评价
        switch period {
        case .daily:
            if completedCount > 0 {
                segments.append("今天你一共干脆利落地完成了 \(completedCount) 项待办，执行力非常棒！")
            } else if pendingCount > 0 {
                segments.append("今天主要以平稳休整为主，当前手头有 \(pendingCount) 项进行中的事项。")
            } else {
                segments.append("今天所有事项均已清空，尽情享受轻松惬意的夜晚吧！")
            }

            if parcelCount > 0 {
                segments.append("收发了 \(parcelCount) 件快递包裹。")
            }

            if totalExpense > 0 {
                let topCat = categoryStats.first?.category.rawValue ?? "日常"
                segments.append("今日记账支出 ¥\(String(format: "%.2f", totalExpense))，主要在「\(topCat)」。")
            } else {
                segments.append("今天保持了极简消费，未产生额外记账支出。")
            }

            if upcomingCount > 0 {
                segments.append("明天还有 \(upcomingCount) 个事项需要关注，今晚建议按时作息、保持充沛精力。")
            }

        case .weekly:
            segments.append("本周全周期累计搞定 \(completedCount) 项任务，待办达成率达 \(Int(completionRate * 100))%。")
            if totalExpense > 0 {
                segments.append("本周生活总支出为 ¥\(String(format: "%.2f", totalExpense))。")
                if let top = categoryStats.first {
                    segments.append("开支大头集中在「\(top.category.rawValue)」（占比 \(Int(top.ratio * 100))%）。")
                }
            }
            if upcomingCount > 0 {
                segments.append("新的一周已规划了 \(upcomingCount) 项重要行程与备忘，提前规划让生活更从容。")
            }

        case .monthly:
            segments.append("全月硕果累累，累计完成了 \(completedCount) 个生活与工作目标。")
            if totalExpense > 0 {
                segments.append("月度财务支出总计 ¥\(String(format: "%.2f", totalExpense))。")
            }
            segments.append("下一月度将迎来新的周期节奏，记得关注即将到期的订阅扣款与重要纪念日。")
        }

        return segments.joined(separator: " ")
    }

    // MARK: - 本地通知定时调度

    /// 统一注册所有已开启报告的本地通知日程
    func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()

        // 移除现存旧定时通知
        center.removePendingNotificationRequests(withIdentifiers: [
            "periodic-report-daily",
            "periodic-report-weekly",
            "periodic-report-monthly"
        ])

        let cal = Calendar.current

        // 1. 日报定时通知（默认开启）
        if isDailyReportEnabled {
            let h = cal.component(.hour, from: dailyTime)
            let m = cal.component(.minute, from: dailyTime)

            var dateComps = DateComponents()
            dateComps.hour = h
            dateComps.minute = m

            let content = UNMutableNotificationContent()
            content.title = "📊 今日生活日报已生成"
            content.body = "今日待办完成情况与消费账单已复盘完毕，点击查看今日专属总结。"
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: true)
            let req = UNNotificationRequest(identifier: "periodic-report-daily", content: content, trigger: trigger)
            center.add(req)
        }

        // 2. 周报定时通知
        if isWeeklyReportEnabled {
            let h = cal.component(.hour, from: weeklyTime)
            let m = cal.component(.minute, from: weeklyTime)

            var dateComps = DateComponents()
            dateComps.weekday = weeklyReportWeekday
            dateComps.hour = h
            dateComps.minute = m

            let content = UNMutableNotificationContent()
            content.title = "📈 本周复盘周报已出炉"
            content.body = "回溯本周目标达成、支出趋势与下周计划，保持节奏迎接新一周！"
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: true)
            let req = UNNotificationRequest(identifier: "periodic-report-weekly", content: content, trigger: trigger)
            center.add(req)
        }

        // 3. 月报定时通知
        if isMonthlyReportEnabled {
            let h = cal.component(.hour, from: monthlyTime)
            let m = cal.component(.minute, from: monthlyTime)

            var dateComps = DateComponents()
            dateComps.day = 1 // 每月 1 日推送上一月汇总
            dateComps.hour = h
            dateComps.minute = m

            let content = UNMutableNotificationContent()
            content.title = "📅 月度生活成果月报已生成"
            content.body = "全月生活资产与支出账单结构大盘点，点击开启本月新展望。"
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: true)
            let req = UNNotificationRequest(identifier: "periodic-report-monthly", content: content, trigger: trigger)
            center.add(req)
        }
    }
}
