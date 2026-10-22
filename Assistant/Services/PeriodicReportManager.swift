import AssistantCore
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// 报告周期类型
enum ReportPeriodType: String, CaseIterable, Identifiable, Sendable {
    case daily = "日报"
    case weekly = "周报"
    case monthly = "月报"
    case quarterly = "季报"
    case yearly = "年报"

    var id: String { rawValue }

    var displayName: String { L10n.tr(rawValue) }

    var icon: String {
        switch self {
        case .daily: return "calendar.day.timeline.leading"
        case .weekly: return "chart.bar.xaxis"
        case .monthly: return "calendar.badge.clock"
        case .quarterly: return "chart.pie.fill"
        case .yearly: return "calendar"
        }
    }

    var description: String {
        switch self {
        case .daily: return L10n.tr("每日晚间生活与待办复盘")
        case .weekly: return L10n.tr("周度执行力与财务全景回顾")
        case .monthly: return L10n.tr("全月成果沉淀与次月规划")
        case .quarterly: return L10n.tr("季度目标与财务深度复盘")
        case .yearly: return L10n.tr("自然年度生活、目标与财务总览")
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

/// 报告行动建议（基于真实数据提炼的可执行提示）
struct ReportSuggestion: Identifiable, Sendable {
    enum Tone: Int, Sendable {
        case urgent = 0    // 需要立即注意（红色）
        case action = 1    // 今天就可以做的事（橙色）
        case positive = 2  // 正向激励（绿色）
    }

    let id = UUID()
    let tone: Tone
    let icon: String   // SF Symbol
    let title: String
    let detail: String
}

/// 长周期（月/季/年报）回顾对比数据：与紧邻的上一等长周期比较
struct PeriodComparison: Sendable {
    /// 单个类别的上期→本期金额变化
    struct CategoryShift: Sendable {
        let category: ExpenseCategory
        let from: Double
        let to: Double
    }

    let prevExpense: Double          // 上期总支出
    let prevExpenseCount: Int        // 上期记账笔数
    let expenseChangeRatio: Double   // 支出环比（(本期-上期)/上期，负 = 下降）
    let prevCompletedCount: Int      // 上期完成待办数
    let growingCategory: CategoryShift?    // 增长最多的类别
    let shrinkingCategory: CategoryShift?  // 降温最多的类别
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
    let dueTodayTodos: [TodoItem]
    let overdueTodos: [TodoItem]
    let tomorrowTodos: [TodoItem]
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

    // 财务深度联动：安心花（仅当日日报）、月预算执行（仅月报）、物品日均持有成本榜（月报/年报）
    let safeToSpend: SafeToSpendResult?
    let budgetOverview: BudgetOverviewResult?
    let itemCostEntries: [ItemCostReportEntry]

    // 行动建议（基于真实数据的可执行提示，urgent > action > positive）
    let suggestions: [ReportSuggestion]

    // 周期回顾：与上一等长周期的环比对比（仅月/季/年报）
    let comparison: PeriodComparison?

    // 身体活力与健康评估（Apple 健康与饮食热量推测）
    let vitality: VitalityEvaluation?
    let healthSnapshot: HealthDaySnapshot?

    // 成就等级评估
    var achievementLevel: String {
        if completionRate >= 0.8 && completedTodos.count >= 3 {
            return L10n.tr("超额完成 🌟")
        } else if completionRate >= 0.5 || completedTodos.count >= 1 {
            return L10n.tr("稳步推进 🚀")
        } else if createdTodos.isEmpty && completedTodos.isEmpty {
            return L10n.tr("从容惬意 ☕️")
        } else {
            return L10n.tr("蓄力前行 💪")
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
        case .quarterly:
            let year = cal.component(.year, from: targetDate)
            let quarter = (cal.component(.month, from: targetDate) - 1) / 3 + 1
            return "小助复盘季报_\(year)年第\(quarter)季度"
        case .yearly:
            df.dateFormat = "yyyy年"
            return "小助自然年报_\(df.string(from: targetDate))"
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
        // 身体活力与健康简报（抓重点、精简呈现）
        if let v = vitality {
            lines.append("## ⚡️ 身体活力与健康简报")
            lines.append("")
            lines.append("> 🔋 **活力指数**：\(v.score) 分 · \(v.level.badge)  ")
            lines.append("> 💡 **核心状态**：\(v.summary)  ")
            lines.append("> 🌿 **调养建议**：\(v.suggestion)")
            lines.append("")
            lines.append("### 关键指标精简速览：")
            for h in v.highlights {
                lines.append("- \(h.icon) **\(h.title)**：\(h.valueText) （\(h.statusText)）")
            }
            lines.append("")
        }
        // 行动建议（基于真实数据提炼，urgent > action > positive）
        if !suggestions.isEmpty {
            lines.append("## 🎯 行动建议")
            lines.append("")
            for s in suggestions {
                lines.append("- \(s.icon) **\(s.title)**：\(s.detail)")
            }
            lines.append("")
        }
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
        // 周期回顾：与上一等长周期环比（月/季/年报导出）
        if let cmp = comparison {
            lines.append("### 🔄 周期回顾（与上期对比）")
            lines.append("")
            lines.append("| 指标 | 本期 | 上期 | 变化 |")
            lines.append("| :--- | :--- | :--- | :--- |")
            let changeText = cmp.prevExpense > 0
                ? (cmp.expenseChangeRatio >= 0 ? "+\(Int(cmp.expenseChangeRatio * 100))%" : "-\(Int(-cmp.expenseChangeRatio * 100))%")
                : "—"
            lines.append("| 总支出 | ¥\(String(format: "%.2f", totalExpense))（\(expenseCount) 笔） | ¥\(String(format: "%.2f", cmp.prevExpense))（\(cmp.prevExpenseCount) 笔） | \(changeText) |")
            lines.append("| 完成待办 | \(completedTodos.count) 项 | \(cmp.prevCompletedCount) 项 | \(completedTodos.count - cmp.prevCompletedCount >= 0 ? "+" : "")\(completedTodos.count - cmp.prevCompletedCount) 项 |")
            if let g = cmp.growingCategory {
                lines.append("")
                lines.append("- 📈 增长最快：**\(g.category.rawValue)** ¥\(String(format: "%.0f", g.from)) → ¥\(String(format: "%.0f", g.to))（+¥\(String(format: "%.0f", g.to - g.from))）")
            }
            if let s = cmp.shrinkingCategory {
                lines.append("- 📉 降温最明显：**\(s.category.rawValue)** ¥\(String(format: "%.0f", s.from)) → ¥\(String(format: "%.0f", s.to))（-¥\(String(format: "%.0f", s.from - s.to))）")
            }
            lines.append("")
        }
        // 今日安心花（仅当天的日报导出）
        if let sts = safeToSpend {
            lines.append("### 🛡️ 今日安心花")
            lines.append("")
            if sts.isOverBudget {
                lines.append("- ⚠️ 本月弹性预算已超支 ¥\(String(format: "%.0f", -sts.remainingThisMonth))，今天尽量少花")
            } else {
                lines.append("- 距月底还有 \(sts.daysLeft) 天，**今天还可以安心花 ¥\(String(format: "%.0f", sts.safeToSpendToday))**")
            }
            lines.append("- 月度弹性预算 ¥\(String(format: "%.0f", sts.disposableBudget))（已扣除固定支出），本月弹性已花 ¥\(String(format: "%.2f", sts.disposableBudget - sts.remainingThisMonth))")
            if sts.savedYesterday >= 0.5 {
                lines.append("- 💰 昨日省下 ¥\(String(format: "%.0f", sts.savedYesterday))，已自动滚入今日额度")
            }
            lines.append("")
        }
        // 月预算执行（仅月报导出）
        if let bo = budgetOverview {
            lines.append("### 📊 月预算执行")
            lines.append("")
            lines.append("| 项目 | 金额 (元) |")
            lines.append("| :--- | :--- |")
            lines.append("| 月度弹性预算 | ¥\(String(format: "%.2f", bo.monthlyBudget)) |")
            lines.append("| 固定支出月额（自动扣除） | ¥\(String(format: "%.2f", bo.fixedMonthlyTotal)) |")
            lines.append("| 本月弹性支出 | ¥\(String(format: "%.2f", bo.flexibleSpent)) |")
            lines.append("| 剩余额度 | ¥\(String(format: "%.2f", bo.remaining)) |")
            if bo.isCurrentMonth {
                lines.append("| 距月底 | \(bo.daysLeft) 天 |")
                lines.append("| 今日后日均可用 | ¥\(String(format: "%.2f", bo.dailyAllowance)) |")
            }
            lines.append("")
            lines.append("弹性预算已使用 \(Int(min(max(bo.spentRatio, 0), 2) * 100))%。")
            lines.append("")
        }
        // 物品日均持有成本（月报/季报/年报导出）
        if period == .monthly || period == .quarterly || period == .yearly, !itemCostEntries.isEmpty {
            lines.append("## 🏷️ 物品日均持有成本")
            lines.append("")
            lines.append("| 物品 | 所在区域 | 购入渠道 | 累计投入 (元) | 已持有天数 | 日均成本 (元/天) | 转卖回血 (元) | 净成本 (元) |")
            lines.append("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |")
            for entry in itemCostEntries {
                let channel = entry.summary.isSecondHand ? "二手" : "全新"
                let resale = entry.summary.resalePrice > 0 ? "¥\(String(format: "%.0f", entry.summary.resalePrice))" : "—"
                lines.append("| \(entry.name) | \(entry.roomArea) | \(channel) | ¥\(String(format: "%.2f", entry.summary.totalCost)) | \(entry.summary.daysHeld) 天 | ¥\(String(format: "%.1f", entry.summary.dailyCost)) | \(resale) | ¥\(String(format: "%.2f", entry.summary.netCost)) |")
            }
            lines.append("")
            for entry in itemCostEntries {
                if let milestone = entry.summary.milestoneText {
                    lines.append("- \(entry.name)：\(milestone)")
                }
            }
            lines.append("")
            lines.append("> ♻️ **二手交易与实际持有成本**：实际持有成本 = 累计投入 − 转卖回血。不常用的物品转卖为二手后，持有天数截至转卖日，闲置期间不再摊高日均成本，净成本被回血金额直接摊薄；二手购入的物品买入价更低，日均成本从一开始就低于全新购入。闲置物品定期断舍离转卖，是把沉没成本变成现金流最直接的方式。")
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

        // 当前仍未完成的活跃事项；日报只纳入今天真正需要处理的事项，避免远期活动拉低完成率。
        let nextDayStart = cal.date(byAdding: .day, value: 1, to: startDate) ?? endDate
        let dayAfterNextStart = cal.date(byAdding: .day, value: 2, to: startDate) ?? nextDayStart
        let dueTodayTodos = allTodos.filter { todo in
            guard todo.status == .active, let due = todo.dueAt else { return false }
            return due >= startDate && due <= endDate
        }
        let overdueTodos = allTodos.filter { todo in
            guard todo.status == .active, let due = todo.dueAt else { return false }
            return due < startDate
        }
        let tomorrowTodos = allTodos.filter { todo in
            guard todo.status == .active, let due = todo.dueAt else { return false }
            return due >= nextDayStart && due < dayAfterNextStart
        }
        let pendingInPeriod = period == .daily
            ? dueTodayTodos + overdueTodos
            : allTodos.filter { $0.status == .active }

        let parcelCount = allTodos.filter { todo in
            (todo.type == .parcel || todo.type == .returnParcel) &&
            ((todo.completedAt != nil && todo.completedAt! >= startDate && todo.completedAt! <= endDate) ||
             (todo.createdAt >= startDate && todo.createdAt <= endDate))
        }.count

        let totalTargetCount = period == .daily
            ? completedInPeriod.count + dueTodayTodos.count
            : completedInPeriod.count + pendingInPeriod.count
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
        let futureDays = period == .daily ? 3 : (period == .monthly || period == .quarterly ? 15 : 7)
        let futureLimit = cal.date(byAdding: .day, value: futureDays, to: endDate) ?? endDate
        let upcomingTodos = allTodos.filter { todo in
            guard todo.status == .active, let due = todo.dueAt else { return false }
            return due > endDate && due <= futureLimit
        }.sorted(by: { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) })

        // 4.5 饮食摄入热量与 Apple 健康指标聚合（活力值评估）
        let allFoodRecords = (try? context.fetch(FetchDescriptor<FoodIntakeRecord>())) ?? []
        let foodRecordsInPeriod = allFoodRecords.filter { $0.date >= startDate && $0.date <= endDate }
        let totalFoodCalories = foodRecordsInPeriod.reduce(0.0) { $0 + $1.consumedCalories }
        let foodIntakeCalories: Double? = foodRecordsInPeriod.isEmpty ? nil : totalFoodCalories

        // 日报优先读取健康快照（如果是今天，优先使用 HealthKitService.shared.snapshot）
        let healthSnapshot: HealthDaySnapshot? = period == .daily ? HealthKitService.shared.snapshot : nil
        let vitality: VitalityEvaluation? = (healthSnapshot != nil || foodIntakeCalories != nil)
            ? VitalityEvaluator.evaluate(snapshot: healthSnapshot, foodIntakeCalories: foodIntakeCalories)
            : nil

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
            upcomingCount: upcomingTodos.count,
            vitality: vitality
        )

        // 6. 财务深度联动：今日安心花（仅「今天」的日报）
        let storedItems = (try? context.fetch(FetchDescriptor<StoredItem>())) ?? []
        var safeToSpend: SafeToSpendResult? = nil
        var stsInput: SafeToSpendInput? = nil
        if period == .daily, cal.isDateInToday(targetDate), BudgetSettings.monthlyBudget > 0 {
            stsInput = SafeToSpendCalculator.inputFromRecords(
                records: allExpenses,
                fixedMonthlyTotal: RecurringExpenseManager.shared.monthlyEstimatedTotal
            )
            safeToSpend = SafeToSpendCalculator.compute(input: stsInput!)
        }

        // 7. 月预算执行概览（仅月报）
        var budgetOverview: BudgetOverviewResult? = nil
        if period == .monthly {
            budgetOverview = BudgetOverviewCalculator.compute(
                records: allExpenses,
                monthDate: targetDate,
                fixedMonthlyTotal: RecurringExpenseManager.shared.monthlyEstimatedTotal
            )
        }

        // 8. 物品日均持有成本榜（全周期计算；UI 卡片与导出仅月报/季报/年报展示，日报用于提炼建议）
        let itemCostEntries = ItemCostCalculator.reportEntries(items: storedItems, records: allExpenses, limit: 5)

        // 9. 大额支出未关联收纳物品（本月内，¥200 以上，非固定支出自动入账）
        let unlinkedLargeExpenses = allExpenses
            .filter {
                !$0.isIncome
                    && !SafeToSpendCalculator.isFixedExpenseRecord($0.rawText)
                    && $0.linkedItemID == nil
                    && $0.amount >= 200
                    && cal.isDate($0.date, equalTo: targetDate, toGranularity: .month)
            }
            .sorted { $0.amount > $1.amount }

        // 10. 长周期回顾对比（月/季/年报：与紧邻上一等长周期比支出、完成量与类别结构）
        var comparison: PeriodComparison? = nil
        if period == .monthly || period == .quarterly || period == .yearly {
            let duration = endDate.timeIntervalSince(startDate)
            let prevEnd = startDate.addingTimeInterval(-1)
            let prevStart = prevEnd.addingTimeInterval(-duration)

            let prevExpenses = allExpenses.filter { !$0.isIncome && $0.date >= prevStart && $0.date <= prevEnd }
            let prevTotal = prevExpenses.reduce(0.0) { $0 + $1.amount }

            var prevCatMap: [ExpenseCategory: Double] = [:]
            for exp in prevExpenses {
                let cat = ExpenseCategory(rawValue: exp.categoryRaw) ?? .other
                prevCatMap[cat, default: 0] += exp.amount
            }
            var curCatMap: [ExpenseCategory: Double] = [:]
            for stat in categoryStats { curCatMap[stat.category] = stat.amount }

            var growing: PeriodComparison.CategoryShift? = nil
            var shrinking: PeriodComparison.CategoryShift? = nil
            for (cat, curAmt) in curCatMap {
                let prevAmt = prevCatMap[cat] ?? 0
                let diff = curAmt - prevAmt
                if diff > 0, growing == nil || diff > (growing!.to - growing!.from) {
                    growing = .init(category: cat, from: prevAmt, to: curAmt)
                }
            }
            for (cat, prevAmt) in prevCatMap {
                let curAmt = curCatMap[cat] ?? 0
                let diff = curAmt - prevAmt
                if diff < 0, shrinking == nil || diff < (shrinking!.to - shrinking!.from) {
                    shrinking = .init(category: cat, from: prevAmt, to: curAmt)
                }
            }

            let prevCompleted = allTodos.filter { todo in
                guard todo.status == .done else { return false }
                if let comp = todo.completedAt { return comp >= prevStart && comp <= prevEnd }
                return todo.createdAt >= prevStart && todo.createdAt <= prevEnd
            }

            let expenseChange = prevTotal > 0
                ? (totalExpense - prevTotal) / prevTotal
                : (totalExpense > 0 ? 1.0 : 0.0)

            comparison = PeriodComparison(
                prevExpense: prevTotal,
                prevExpenseCount: prevExpenses.count,
                expenseChangeRatio: expenseChange,
                prevCompletedCount: prevCompleted.count,
                growingCategory: growing,
                shrinkingCategory: shrinking
            )
        }

        // 11. 行动建议引擎
        let periodDays = max(1, Int((endDate.timeIntervalSince(startDate) / 86400).rounded()) + 1)
        let suggestions = generateSuggestions(
            period: period,
            calendar: cal,
            targetDate: targetDate,
            stsInput: stsInput,
            safeToSpend: safeToSpend,
            budgetOverview: budgetOverview,
            overdueTodos: overdueTodos,
            dueTodayTodos: dueTodayTodos,
            tomorrowTodos: tomorrowTodos,
            upcomingTodos: upcomingTodos,
            categoryStats: categoryStats,
            maxExpenseItem: maxExpenseItem,
            habitStreakCount: habitStreakCount,
            unlinkedLargeExpenses: unlinkedLargeExpenses,
            itemCostEntries: itemCostEntries,
            comparison: comparison,
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            expenseCount: expenseOnly.count,
            periodDays: periodDays,
            vitality: vitality
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
            dueTodayTodos: dueTodayTodos,
            overdueTodos: overdueTodos,
            tomorrowTodos: tomorrowTodos,
            completionRate: completionRate,
            parcelCount: parcelCount,
            totalExpense: totalExpense,
            totalIncome: totalIncome,
            expenseCount: expenseOnly.count,
            categoryStats: categoryStats,
            maxExpenseItem: maxExpenseItem,
            habitStreakCount: habitStreakCount,
            upcomingTodos: upcomingTodos,
            smartSummary: smartSummary,
            safeToSpend: safeToSpend,
            budgetOverview: budgetOverview,
            itemCostEntries: itemCostEntries,
            suggestions: suggestions,
            comparison: comparison,
            vitality: vitality,
            healthSnapshot: healthSnapshot
        )
    }

    // MARK: - 日期范围与标题计算

    private func calculateDateRange(period: ReportPeriodType, targetDate: Date, calendar cal: Calendar) -> (Date, Date, String, String) {
        switch period {
        case .daily:
            let start = cal.startOfDay(for: targetDate)
            let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: start) ?? start
            let isToday = cal.isDateInToday(targetDate)
            let titlePrefix = isToday
                ? L10n.tr("今日生活日报")
                : (L10n.isEnglish
                    ? targetDate.formatted(.dateTime.month().day().locale(L10n.locale)) + " Daily Report"
                    : targetDate.formatted(.dateTime.month().day()) + " 日报")
            let sub = targetDate.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: L10n.locale))
            return (start, end, titlePrefix, sub)

        case .weekly:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: targetDate)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: targetDate)
            let end = cal.date(byAdding: .day, value: 6, to: start).flatMap {
                cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0)
            } ?? targetDate
            let weekNumber = cal.component(.weekOfYear, from: targetDate)
            let year = cal.component(.year, from: targetDate)
            let title = L10n.choose("\(year)年第 \(weekNumber) 周 · 复盘周报", "Week \(weekNumber), \(year) · Weekly Report")
            let sub = "\(start.formatted(.dateTime.month().day().locale(L10n.locale))) ~ \(end.formatted(.dateTime.month().day().locale(L10n.locale)))"
            return (start, end, title, sub)

        case .quarterly:
            // 季报采用自然季度：季度首月 1 日 00:00:00 至季末月最后一天 23:59:59。
            let year = cal.component(.year, from: targetDate)
            let month = cal.component(.month, from: targetDate)
            let quarter = (month - 1) / 3 + 1
            let startMonth = (quarter - 1) * 3 + 1
            let start = cal.date(from: DateComponents(year: year, month: startMonth, day: 1)) ?? cal.startOfDay(for: targetDate)
            let endMonth = startMonth + 2
            let endMonthFirst = cal.date(from: DateComponents(year: year, month: endMonth, day: 1)) ?? start
            let daysInEnd = cal.range(of: .day, in: .month, for: endMonthFirst)?.count ?? 31
            let endCandidate = cal.date(from: DateComponents(year: year, month: endMonth, day: daysInEnd)) ?? targetDate
            let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: endCandidate) ?? targetDate
            let title = L10n.choose("\(year)年第 \(quarter) 季度 · 复盘季报", "Q\(quarter) \(year) · Quarterly Report")
            let sub = "\(year)年\(startMonth)月1日 ~ \(endMonth)月\(daysInEnd)日"
            return (start, end, title, sub)

        case .yearly:
            // 年报采用自然年：当年 1 月 1 日 00:00:00 至 12 月 31 日 23:59:59。
            let year = cal.component(.year, from: targetDate)
            let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? cal.startOfDay(for: targetDate)
            let nextYear = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? targetDate
            let end = cal.date(byAdding: .second, value: -1, to: nextYear) ?? targetDate
            let title = L10n.choose("\(year)年 · 自然年报", "\(year) · Annual Report")
            let sub = L10n.choose("\(year)年1月1日 ~ \(year)年12月31日", "Jan 1, \(year) ~ Dec 31, \(year)")
            return (start, end, title, sub)

        case .monthly:
            let comps = cal.dateComponents([.year, .month], from: targetDate)
            let start = cal.date(from: comps) ?? cal.startOfDay(for: targetDate)
            let range = cal.range(of: .day, in: .month, for: targetDate)?.count ?? 30
            let end = cal.date(byAdding: .day, value: range - 1, to: start).flatMap {
                cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0)
            } ?? targetDate
            let monthName = targetDate.formatted(.dateTime.year().month().locale(L10n.locale))
            let title = L10n.choose("\(monthName) · 成果月报", "\(monthName) · Monthly Report")
            let sub = L10n.choose("\(monthName) 1日 ~ \(range)日", "\(monthName) 1 ~ \(range)")
            return (start, end, title, sub)
        }
    }

    // MARK: - 行动建议引擎（基于真实数据的可执行提示）

    /// 按紧急度排序提炼建议：urgent（需立即注意）> action（今天可做）> positive（正反馈），最多 5 条
    private func generateSuggestions(
        period: ReportPeriodType,
        calendar cal: Calendar,
        targetDate: Date,
        stsInput: SafeToSpendInput?,
        safeToSpend: SafeToSpendResult?,
        budgetOverview: BudgetOverviewResult?,
        overdueTodos: [TodoItem],
        dueTodayTodos: [TodoItem],
        tomorrowTodos: [TodoItem],
        upcomingTodos: [TodoItem],
        categoryStats: [CategoryExpenseStat],
        maxExpenseItem: ExpenseRecord?,
        habitStreakCount: Int,
        unlinkedLargeExpenses: [ExpenseRecord],
        itemCostEntries: [ItemCostReportEntry],
        comparison: PeriodComparison?,
        totalExpense: Double,
        totalIncome: Double,
        expenseCount: Int,
        periodDays: Int,
        vitality: VitalityEvaluation? = nil
    ) -> [ReportSuggestion] {
        var suggestions: [ReportSuggestion] = []
        let isDaily = period == .daily

        // 1. 未设预算 → 引导开通「今日安心花」
        if BudgetSettings.monthlyBudget <= 0 {
            suggestions.append(ReportSuggestion(
                tone: .action, icon: "shield.lefthalf.filled.badge.plus",
                title: "花 1 分钟设置月预算",
                detail: "设置后每天自动计算「今日安心花」额度，房租、订阅等固定支出自动扣除，今天省下的钱会滚入明天。"
            ))
        }

        // 2. 弹性预算超支 → 指向最高占比类别给出削减抓手
        if let sts = safeToSpend, sts.isOverBudget {
            let cutHint: String
            if let top = categoryStats.first {
                cutHint = "本月「\(top.category.rawValue)」花了 ¥\(String(format: "%.0f", top.amount))（占 \(Int(top.ratio * 100))%），先从这个类别的非必要开销砍起。"
            } else {
                cutHint = "接下来几天尽量只保留必要开销，把缺口控制住。"
            }
            suggestions.append(ReportSuggestion(
                tone: .urgent, icon: "exclamationmark.triangle.fill",
                title: String(format: "弹性预算已超支 ¥%.0f", -sts.remainingThisMonth),
                detail: cutHint
            ))
        }

        // 3. 预算节奏超前（未超支，但消耗速度明显快于时间进度）
        if let sts = safeToSpend, !sts.isOverBudget {
            let monthElapsed = Double(sts.daysInMonth - sts.daysLeft + 1) / Double(sts.daysInMonth)
            let paceGap = sts.spentRatio - monthElapsed
            if paceGap > 0.15, sts.spentRatio < 1 {
                let projected = sts.disposableBudget * sts.spentRatio / max(monthElapsed, 0.01) - sts.disposableBudget
                if projected > 50 {
                    suggestions.append(ReportSuggestion(
                        tone: .urgent, icon: "speedometer",
                        title: String(format: "预算消耗超前 %d%%", Int(paceGap * 100)),
                        detail: String(
                            format: "本月已过 %d%%，弹性预算已用 %d%%。按当前节奏月底将超支约 ¥%.0f，今天起日均控制在 ¥%.0f 以内。",
                            Int(monthElapsed * 100), Int(sts.spentRatio * 100), projected, max(sts.safeToSpendToday, 0)
                        )
                    ))
                }
            }
        }

        // 4. 今天已花超当日额度（未到月度超支，但当日节奏失守）
        if let sts = safeToSpend, !sts.isOverBudget, let input = stsInput,
           input.todayFlexibleSpend > sts.safeToSpendToday {
            suggestions.append(ReportSuggestion(
                tone: .action, icon: "hourglass",
                title: String(format: "今天已花超当日额度 ¥%.0f", input.todayFlexibleSpend - sts.safeToSpendToday),
                detail: "超出的部分会自动从明天的额度里扣，今晚就收手吧。"
            ))
        }

        // 5. 逾期待办 → 指名最早的一项
        let sortedOverdue = overdueTodos.sorted { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
        if let first = sortedOverdue.first {
            suggestions.append(ReportSuggestion(
                tone: .urgent, icon: "clock.badge.exclamationmark",
                title: "有 \(sortedOverdue.count) 项逾期待办",
                detail: "最早的是「\(first.title)」。先清掉它，今天的清单才不会被旧账压住。"
            ))
        }

        // 6. 明天到期 → 睡前预排
        if isDaily, !tomorrowTodos.isEmpty {
            suggestions.append(ReportSuggestion(
                tone: .action, icon: "sun.haze",
                title: "明天有 \(tomorrowTodos.count) 项事项到期",
                detail: "睡前花 2 分钟把它们排进明天的时间段，早上直接开工。"
            ))
        }

        // 7. 大额支出未关联收纳物品 → 提示接入持有成本跟踪
        if isDaily, let rec = unlinkedLargeExpenses.first {
            suggestions.append(ReportSuggestion(
                tone: .action, icon: "link.badge.plus",
                title: String(format: "「%@」¥%.0f 还没关联收纳物品", rec.title, rec.amount),
                detail: "关联后自动计入日均持有成本，回本进度一目了然。"
            ))
        }

        // 8. 高日均成本在持物品 → 转卖回血建议
        if let top = itemCostEntries.first, !top.summary.isResold,
           top.summary.dailyCost > 10, top.summary.daysHeld >= 30 {
            suggestions.append(ReportSuggestion(
                tone: .action, icon: "arrow.uturn.backward.circle",
                title: String(format: "「%@」日均成本 ¥%.1f", top.name, top.summary.dailyCost),
                detail: "已持有 \(top.summary.daysHeld) 天。若最近很少用到，转卖回血能直接摊薄净成本。"
            ))
        }

        // 9. 昨日省下滚入（正反馈）
        if let sts = safeToSpend, sts.savedYesterday >= 1 {
            suggestions.append(ReportSuggestion(
                tone: .positive, icon: "hand.thumbsup.fill",
                title: String(format: "昨日省下 ¥%.0f，已滚入今日额度", sts.savedYesterday),
                detail: "少花一天，明天的余量就多一分——这个节奏保持住。"
            ))
        }

        // ===== 长周期（月/季/年）回顾类建议：全部由环比真实数据驱动 =====
        if let cmp = comparison {
            let expenseDiff = totalExpense - cmp.prevExpense

            // 9a. 支出环比显著上升 → 指认增长来源类别
            if cmp.expenseChangeRatio > 0.2, expenseDiff > 100 {
                var detail = "本期 ¥\(String(format: "%.0f", totalExpense)) ← 上期 ¥\(String(format: "%.0f", cmp.prevExpense))。"
                if let g = cmp.growingCategory {
                    detail += "主要来自「\(g.category.rawValue)」：¥\(String(format: "%.0f", g.from)) → ¥\(String(format: "%.0f", g.to))（+\(String(format: "%.0f", g.to - g.from))）。先确认其中是否含一次性大额，再决定下期是否收紧该类别。"
                } else {
                    detail += "先回看几笔最大的开支是否必要，再决定下期节奏。"
                }
                suggestions.append(ReportSuggestion(
                    tone: .urgent, icon: "chart.line.uptrend.xyaxis",
                    title: String(format: "支出比上期增加 %d%%", Int(cmp.expenseChangeRatio * 100)),
                    detail: detail
                ))
            }

            // 9b. 支出环比明显下降 → 肯定并提示守住
            if cmp.expenseChangeRatio < -0.1, expenseDiff < -100 {
                var detail = "上期 ¥\(String(format: "%.0f", cmp.prevExpense)) → 本期 ¥\(String(format: "%.0f", totalExpense))。"
                if let s = cmp.shrinkingCategory {
                    detail += "「\(s.category.rawValue)」降温最明显：¥\(String(format: "%.0f", s.from)) → ¥\(String(format: "%.0f", s.to))。"
                }
                detail += "省钱不是压到最低，而是稳在能长期执行的区间。"
                suggestions.append(ReportSuggestion(
                    tone: .positive, icon: "chart.line.downtrend.xyaxis",
                    title: String(format: "支出比上期减少 ¥%.0f（-%d%%）", -expenseDiff, Int(-cmp.expenseChangeRatio * 100)),
                    detail: detail
                ))
            }

            // 9c. 记账频次偏低 → 数据可信度提示
            if expenseCount < periodDays / 3, expenseCount > 0 {
                suggestions.append(ReportSuggestion(
                    tone: .action, icon: "square.and.pencil",
                    title: "本周期仅记账 \(expenseCount) 笔",
                    detail: "平均每天不到 1 笔，统计可能漏掉不少零散开销。保持随手记，下期的回顾建议才会更有依据。"
                ))
            }

            // 9d. 支出高度集中于单一类别
            if let top = categoryStats.first, top.ratio > 0.5, categoryStats.count >= 2 {
                suggestions.append(ReportSuggestion(
                    tone: .action, icon: "circle.lefthalf.filled",
                    title: String(format: "「%@」占本周期支出的 %d%%", top.category.rawValue, Int(top.ratio * 100)),
                    detail: "单一类别占比过半。若属房租、订阅等固定属性，可在记账中设为周期固定支出自动扣除，让预算只管弹性部分。"
                ))
            }

            // 9e. 收不抵支（仅在录入了收入数据时才可判定）
            if totalIncome > 0, totalIncome < totalExpense {
                suggestions.append(ReportSuggestion(
                    tone: .urgent, icon: "trending.down.square",
                    title: String(format: "本周期入不敷出 ¥%.0f", totalExpense - totalIncome),
                    detail: String(format: "收入 ¥%.0f < 支出 ¥%.0f。对照上面的分类构成，优先压缩非必要类别；连续两期出现就该重排预算了。", totalIncome, totalExpense)
                ))
            }
        }

        // 9.5 身体活力与机能建议
        if let v = vitality {
            if v.level == .exhausted || v.level == .low {
                suggestions.append(ReportSuggestion(
                    tone: .urgent, icon: "bed.double.fill",
                    title: "活力预警与修复",
                    detail: v.suggestion
                ))
            } else if v.level == .peak {
                suggestions.append(ReportSuggestion(
                    tone: .positive, icon: "bolt.fill",
                    title: "活力充沛",
                    detail: v.suggestion
                ))
            }
        }

        // 10. 兜底正反馈：没有任何异常信号时给出稳定确认
        if suggestions.isEmpty {
            suggestions.append(ReportSuggestion(
                tone: .positive, icon: "checkmark.seal.fill",
                title: isDaily ? "今天节奏很稳" : "本周期一切在轨道上",
                detail: "支出与待办都没有异常信号，省下的额度会自动滚入后续日子，继续保持。"
            ))
        }

        return Array(suggestions.sorted { $0.tone.rawValue < $1.tone.rawValue }.prefix(6))
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
        upcomingCount: Int,
        vitality: VitalityEvaluation? = nil
    ) -> String {
        var segments: [String] = []

        // 待办执行力评价
        switch period {
        case .daily:
            if completedCount > 0 {
                segments.append(L10n.choose(
                    "今天你一共干脆利落地完成了 \(completedCount) 项待办，执行力非常棒！",
                    "You completed \(completedCount) to-do\(completedCount == 1 ? "" : "s") today—great execution!"
                ))
            } else if pendingCount > 0 {
                segments.append(L10n.choose(
                    "今天主要以平稳休整为主，当前手头有 \(pendingCount) 项进行中的事项。",
                    "A steady day today with \(pendingCount) ongoing item\(pendingCount == 1 ? "" : "s")."
                ))
            } else {
                segments.append(L10n.tr("今天所有事项均已清空，尽情享受轻松惬意的夜晚吧！"))
            }

            if parcelCount > 0 {
                segments.append(L10n.choose(
                    "收发了 \(parcelCount) 件快递包裹。",
                    "Handled \(parcelCount) parcel\(parcelCount == 1 ? "" : "s")."
                ))
            }

            if totalExpense > 0 {
                let topCat = L10n.tr(categoryStats.first?.category.rawValue ?? "日常")
                segments.append(L10n.choose(
                    "今日记账支出 ¥\(String(format: "%.2f", totalExpense))，主要在「\(topCat)」。",
                    "Today's spending totaled ¥\(String(format: "%.2f", totalExpense)), mostly on \(topCat)."
                ))
            } else {
                segments.append(L10n.tr("今天保持了极简消费，未产生额外记账支出。"))
            }

            if let v = vitality {
                segments.append(L10n.choose(
                    "身体活力指数 \(v.score) 分（\(v.level.badge)）。\(v.summary)",
                    "Vitality index is \(v.score) (\(v.level.rawValue)). \(v.summary)"
                ))
            }

            if upcomingCount > 0 {
                segments.append(L10n.choose(
                    "明天还有 \(upcomingCount) 个事项需要关注，今晚建议按时作息、保持充沛精力。",
                    "You have \(upcomingCount) item\(upcomingCount == 1 ? "" : "s") coming up tomorrow—get a good night's rest!"
                ))
            }

        case .weekly:
            segments.append(L10n.choose(
                "本周全周期累计搞定 \(completedCount) 项任务，待办达成率达 \(Int(completionRate * 100))%。",
                "Completed \(completedCount) task\(completedCount == 1 ? "" : "s") this week with a \(Int(completionRate * 100))% completion rate."
            ))
            if totalExpense > 0 {
                segments.append(L10n.choose(
                    "本周生活总支出为 ¥\(String(format: "%.2f", totalExpense))。",
                    "Total weekly spending was ¥\(String(format: "%.2f", totalExpense))."
                ))
                if let top = categoryStats.first {
                    segments.append(L10n.choose(
                        "开支大头集中在「\(top.category.rawValue)」（占比 \(Int(top.ratio * 100))%）。",
                        "Top category was \(L10n.tr(top.category.rawValue)) (\(Int(top.ratio * 100))%)."
                    ))
                }
            }
            if upcomingCount > 0 {
                segments.append(L10n.choose(
                    "新的一周已规划了 \(upcomingCount) 项重要行程与备忘，提前规划让生活更从容。",
                    "\(upcomingCount) upcoming item\(upcomingCount == 1 ? "" : "s") planned for next week."
                ))
            }

        case .monthly:
            segments.append(L10n.choose(
                "全月硕果累累，累计完成了 \(completedCount) 个生活与工作目标。",
                "Completed \(completedCount) life and work goal\(completedCount == 1 ? "" : "s") this month."
            ))
            if totalExpense > 0 {
                segments.append(L10n.choose(
                    "月度财务支出总计 ¥\(String(format: "%.2f", totalExpense))。",
                    "Monthly expenses totaled ¥\(String(format: "%.2f", totalExpense))."
                ))
            }
            segments.append(L10n.tr("下一月度将迎来新的周期节奏，记得关注即将到期的订阅扣款与重要纪念日。"))

        case .quarterly:
            segments.append(L10n.choose(
                "本季度累计完成了 \(completedCount) 个生活与工作目标，季度待办达成率 \(Int(completionRate * 100))%。",
                "Completed \(completedCount) goal\(completedCount == 1 ? "" : "s") this quarter with a \(Int(completionRate * 100))% completion rate."
            ))
            if totalExpense > 0 {
                segments.append(L10n.choose(
                    "季度记账支出总计 ¥\(String(format: "%.2f", totalExpense))。",
                    "Quarterly spending totaled ¥\(String(format: "%.2f", totalExpense))."
                ))
                if let top = categoryStats.first {
                    segments.append(L10n.choose(
                        "季度开支大头集中在「\(top.category.rawValue)」（占比 \(Int(top.ratio * 100))%）。",
                        "Top quarterly expense category was \(L10n.tr(top.category.rawValue)) (\(Int(top.ratio * 100))%)."
                    ))
                }
            }
            segments.append(L10n.tr("以季度为单位回顾一次节奏，正适合校准目标方向：下季度重点投入哪几件事，现在就定下来。"))

        case .yearly:
            segments.append(L10n.choose(
                "这一自然年累计完成了 \(completedCount) 个生活与工作目标，年度待办达成率 \(Int(completionRate * 100))%。",
                "Completed \(completedCount) goal\(completedCount == 1 ? "" : "s") this year with a \(Int(completionRate * 100))% completion rate."
            ))
            if totalExpense > 0 {
                segments.append(L10n.choose(
                    "全年记账支出总计 ¥\(String(format: "%.2f", totalExpense))。",
                    "Annual spending totaled ¥\(String(format: "%.2f", totalExpense))."
                ))
                if let top = categoryStats.first {
                    segments.append(L10n.choose(
                        "年度开支大头集中在「\(top.category.rawValue)」（占比 \(Int(top.ratio * 100))%）。",
                        "Top annual expense category was \(L10n.tr(top.category.rawValue)) (\(Int(top.ratio * 100))%)."
                    ))
                }
            }
            segments.append(L10n.tr("新的一年继续保持节奏，按自己的目标稳步前进。"))
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
            content.title = L10n.tr("📊 今日生活日报已生成")
            content.body = L10n.tr("今日待办完成情况与消费账单已复盘完毕，点击查看今日专属总结。")
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"
            content.userInfo = ["type": "periodic-report", "period": "daily"]

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
            content.title = L10n.tr("📈 本周复盘周报已出炉")
            content.body = L10n.tr("回溯本周目标达成、支出趋势与下周计划，保持节奏迎接新一周！")
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
            content.title = L10n.tr("📅 月度生活成果月报已生成")
            content.body = L10n.tr("全月生活资产与支出账单结构大盘点，点击开启本月新展望。")
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: true)
            let req = UNNotificationRequest(identifier: "periodic-report-monthly", content: content, trigger: trigger)
            center.add(req)
        }
    }
}
