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

    /// 稳定的英文标识，用于通知 userInfo 等跨语言场景。
    ///
    /// `rawValue` 是中文（同时充当本地化 key），不适合当持久化标识——
    /// 中文文案一旦改动，依赖它的 userInfo 匹配就会静默失效。
    var identifier: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .quarterly: return "quarterly"
        case .yearly: return "yearly"
        }
    }

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
    /// 同色位内的排序权重（越小越靠前）。默认 10；趋势洞察类用 0 以确保不被通用建议挤掉。
    let priority: Int

    init(tone: Tone, icon: String, title: String, detail: String, priority: Int = 10) {
        self.tone = tone
        self.icon = icon
        self.title = title
        self.detail = detail
        self.priority = priority
    }
}

/// 周期报告类型 → Core 的周期粒度。
///
/// 报告窗口与趋势序列必须用同一套边界规则（Core 的 `ReportPeriodWindow`），
/// 否则「本期」和「趋势里的最后一期」会落在不同区间，环比就成了拿上上周比上周。
extension ReportPeriodType {
    var granularity: ReportPeriodWindow.Granularity {
        switch self {
        case .daily: return .day
        case .weekly: return .week
        case .monthly: return .month
        case .quarterly: return .quarter
        case .yearly: return .year
        }
    }

    /// 趋势分析回溯的周期个数。
    ///
    /// 周报看 8 周（近两个月）、月报看 12 个月（近一年）、
    /// 季报看 8 个季度（近两年）、年报看 5 年。
    /// 少于 3 期时趋势结论不可靠，Core 侧会拒绝下结论。
    var trendHistoryCount: Int {
        switch self {
        case .daily: return 0
        case .weekly: return 8
        case .monthly: return 12
        case .quarterly: return 8
        case .yearly: return 5
        }
    }

    /// 是否需要跨期趋势分析（日报只看当天，不做对比）。
    var supportsTrendAnalysis: Bool { self != .daily }
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

    // 趋势与变化分析（周/月/季/年报；日报无跨期对比，为 nil）
    // 含多期序列、指标环比、类别结构变化、消费行为模式、准时率与下期目标
    let trendSummary: PeriodTrendSummary?

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
        // 趋势与变化分析（周/月/季/年报导出）
        if let trend = trendSummary {
            lines.append("## 📈 趋势与变化分析")
            lines.append("")

            // 多期序列
            if trend.points.count >= 2 {
                lines.append("### 近 \(trend.points.count) 期走势")
                lines.append("")
                lines.append("| 周期 | 支出 | 完成事项 |")
                lines.append("| :--- | ---: | ---: |")
                for point in trend.points {
                    let marker = point.label == trend.points.last?.label ? "（本期）" : ""
                    lines.append("| \(point.label)\(marker) | ¥\(String(format: "%.0f", point.expense)) | \(point.completedCount) 项 |")
                }
                lines.append("")

                // 趋势方向判读
                let expenseTrend = trend.expenseTrend
                let directionText: String
                switch expenseTrend.direction {
                case .rising: directionText = "📈 上升"
                case .falling: directionText = "📉 下降"
                case .flat: directionText = "➡️ 基本持平"
                }
                var trendLines: [String] = []
                trendLines.append("- 支出趋势：**\(directionText)**")
                if expenseTrend.streak != 0 {
                    trendLines.append(String(format: "- 连续变化：%@ %d 期", expenseTrend.streak > 0 ? "上升" : "下降", abs(expenseTrend.streak)))
                }
                if expenseTrend.slope != 0 {
                    trendLines.append(String(format: "- 每期变化：约 %@¥%.0f", expenseTrend.slope > 0 ? "+" : "", expenseTrend.slope))
                }
                if expenseTrend.baselineAverage > 0, let deviation = expenseTrend.currentVsBaseline {
                    trendLines.append(String(format: "- 相对历史均值：%@%.0f%%", deviation > 0 ? "+" : "", deviation * 100))
                }
                trendLines.append(String(format: "- 波动系数：%.0f%%", expenseTrend.volatility * 100))
                lines.append(contentsOf: trendLines)
                lines.append("")
            }

            // 指标环比
            if !trend.metricChanges.isEmpty {
                lines.append("### 关键指标环比")
                lines.append("")
                lines.append("| 指标 | 本期 | 上期 | 变化 |")
                lines.append("| :--- | ---: | ---: | :--- |")
                for change in trend.metricChanges {
                    let currentText = String(format: "%.0f", change.current)
                    let previousText = change.previous.map { String(format: "%.0f", $0) } ?? "—"
                    let deltaText: String
                    if let ratio = change.ratio {
                        deltaText = String(format: "%@%.0f%%", ratio > 0 ? "+" : "", ratio * 100)
                    } else if let delta = change.delta {
                        deltaText = String(format: "%@%.0f", delta > 0 ? "+" : "", delta)
                    } else {
                        deltaText = "—"
                    }
                    let verdictMark = change.verdict > 0 ? " ✅" : (change.verdict < 0 ? " ⚠️" : "")
                    lines.append("| \(change.title) | \(currentText) | \(previousText) | \(deltaText)\(verdictMark) |")
                }
                lines.append("")
            }

            // 类别结构变化
            if !trend.categoryChanges.isEmpty {
                lines.append("### 支出结构变化")
                lines.append("")
                lines.append("| 类别 | 本期金额 | 上期金额 | 金额变化 | 占比变化 |")
                lines.append("| :--- | ---: | ---: | ---: | ---: |")
                for change in trend.categoryChanges.prefix(8) {
                    let name = ExpenseCategory(rawValue: change.categoryRaw)?.rawValue ?? change.categoryRaw
                    let shareDeltaText = String(format: "%@%.1fpp", change.shareDelta > 0 ? "+" : "", change.shareDelta * 100)
                    lines.append("| \(name) | ¥\(String(format: "%.0f", change.current)) | ¥\(String(format: "%.0f", change.previous)) | \(String(format: "%@%.0f", change.delta > 0 ? "+" : "", change.delta)) | \(shareDeltaText) |")
                }
                lines.append("")
            }

            // 行为模式
            if let pattern = trend.spendingPattern {
                lines.append("### 消费行为模式")
                lines.append("")
                lines.append(String(format: "- 日均支出：¥%.0f（有效消费 %d 天 / 已过 %d 天）", pattern.dailyAverage, pattern.activeDays, pattern.elapsedDays))
                lines.append(String(format: "- 工作日日均 ¥%.0f · 周末日均 ¥%.0f · 周末占比 %.0f%%", pattern.weekdayDailyAverage, pattern.weekendDailyAverage, pattern.weekendShare * 100))
                if let peakWeekday = pattern.peakWeekdayIndex {
                    let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                    lines.append("- 消费高峰：\(names[peakWeekday])")
                }
                if pattern.peakDayAmount > 0 {
                    let dayText = pattern.peakDay.map { $0.formatted(.dateTime.month().day().locale(L10n.locale)) } ?? ""
                    lines.append(String(format: "- 单日最高：¥%.0f（%@）", pattern.peakDayAmount, dayText))
                }
                if pattern.smallTicketCount > 0 {
                    lines.append(String(format: "- 小额消费：%d 笔，合计 ¥%.0f", pattern.smallTicketCount, pattern.smallTicketTotal))
                }
                if pattern.noSpendDays > 0 {
                    lines.append(String(format: "- 零支出天数：%d 天", pattern.noSpendDays))
                }
                lines.append("")
            }

            // 准时率
            if let punctuality = trend.punctuality, punctuality.dueCompletedCount > 0 {
                lines.append("### 待办准时率")
                lines.append("")
                let rateText = punctuality.onTimeRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
                lines.append("- 准时率：**\(rateText)**（\(punctuality.onTimeCount)/\(punctuality.dueCompletedCount) 项按时完成）")
                if punctuality.averageDelayDays > 0 {
                    lines.append(String(format: "- 逾期完成平均拖延 %.1f 天", punctuality.averageDelayDays))
                }
                lines.append("")
            }

            // 下期目标
            if let targets = trend.nextTargets {
                lines.append("### 下期目标建议")
                lines.append("")
                if let cap = targets.expenseCap {
                    lines.append(String(format: "- 支出上限：**¥%.0f**", cap))
                }
                lines.append(String(format: "- 完成事项：**%d 项**", targets.completedTarget))
                if let rate = targets.savingsRateTarget {
                    lines.append(String(format: "- 储蓄率：**%.0f%%**", rate * 100))
                }
                lines.append("")
            }
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

    /// 季报是否开启（默认关闭）
    @AppStorage("periodic_report_quarterly_enabled") var isQuarterlyReportEnabled: Bool = false {
        didSet { scheduleNotifications() }
    }

    /// 季报提醒时间 (默认 21:00，季末当天推送)
    @AppStorage("periodic_report_quarterly_time_interval") private var quarterlyTimeInterval: Double = 21 * 3600 {
        didSet { scheduleNotifications() }
    }

    /// 年报是否开启（默认关闭）
    @AppStorage("periodic_report_yearly_enabled") var isYearlyReportEnabled: Bool = false {
        didSet { scheduleNotifications() }
    }

    /// 年报提醒时间 (默认 21:00，12 月 31 日推送)
    @AppStorage("periodic_report_yearly_time_interval") private var yearlyTimeInterval: Double = 21 * 3600 {
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

    var quarterlyTime: Date {
        get {
            let cal = Calendar.current
            let now = Date.now
            let hours = Int(quarterlyTimeInterval) / 3600
            let minutes = (Int(quarterlyTimeInterval) % 3600) / 60
            return cal.date(bySettingHour: hours, minute: minutes, second: 0, of: now) ?? now
        }
        set {
            let cal = Calendar.current
            let h = cal.component(.hour, from: newValue)
            let m = cal.component(.minute, from: newValue)
            quarterlyTimeInterval = Double(h * 3600 + m * 60)
        }
    }

    var yearlyTime: Date {
        get {
            let cal = Calendar.current
            let now = Date.now
            let hours = Int(yearlyTimeInterval) / 3600
            let minutes = (Int(yearlyTimeInterval) % 3600) / 60
            return cal.date(bySettingHour: hours, minute: minutes, second: 0, of: now) ?? now
        }
        set {
            let cal = Calendar.current
            let h = cal.component(.hour, from: newValue)
            let m = cal.component(.minute, from: newValue)
            yearlyTimeInterval = Double(h * 3600 + m * 60)
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
        // 区间语义为 [startDate, endDate)：endDate 是下一周期的起点，不含。
        let completedInPeriod = allTodos.filter { todo in
            guard todo.status == .done else { return false }
            if let comp = todo.completedAt {
                return comp >= startDate && comp < endDate
            }
            return todo.createdAt >= startDate && todo.createdAt < endDate
        }

        // 在时间跨度内新创建的事项
        let createdInPeriod = allTodos.filter { $0.createdAt >= startDate && $0.createdAt < endDate }

        // 当前仍未完成的活跃事项；日报只纳入今天真正需要处理的事项，避免远期活动拉低完成率。
        let nextDayStart = cal.date(byAdding: .day, value: 1, to: startDate) ?? endDate
        let dayAfterNextStart = cal.date(byAdding: .day, value: 2, to: startDate) ?? nextDayStart
        let dueTodayTodos = allTodos.filter { todo in
            guard todo.status == .active, let due = todo.dueAt else { return false }
            return due >= startDate && due < endDate
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
            ((todo.completedAt != nil && todo.completedAt! >= startDate && todo.completedAt! < endDate) ||
             (todo.createdAt >= startDate && todo.createdAt < endDate))
        }.count

        let totalTargetCount = period == .daily
            ? completedInPeriod.count + dueTodayTodos.count
            : completedInPeriod.count + pendingInPeriod.count
        let completionRate = totalTargetCount > 0 ? Double(completedInPeriod.count) / Double(totalTargetCount) : (completedInPeriod.isEmpty ? 0.0 : 1.0)

        // 2. 查询消费支出账单
        let allExpenses = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
        let expensesInPeriod = allExpenses.filter { $0.date >= startDate && $0.date < endDate }

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
        let foodRecordsInPeriod = allFoodRecords.filter { $0.date >= startDate && $0.date < endDate }
        let totalFoodCalories = foodRecordsInPeriod.reduce(0.0) { $0 + $1.consumedCalories }
        let foodIntakeCalories: Double? = foodRecordsInPeriod.isEmpty ? nil : totalFoodCalories

        // 日报优先读取健康快照（如果是今天，优先使用 HealthKitService.shared.snapshot）
        let healthSnapshot: HealthDaySnapshot? = period == .daily ? HealthKitService.shared.snapshot : nil
        let vitality: VitalityEvaluation? = (healthSnapshot != nil || foodIntakeCalories != nil)
            ? VitalityEvaluator.evaluate(snapshot: healthSnapshot, foodIntakeCalories: foodIntakeCalories)
            : nil

        // 4.6 趋势与变化分析（周/月/季/年报）：回溯多期数据，交给 Core 的纯函数算趋势
        // 必须早于智能小结与建议引擎生成——两者都要用到趋势结论。
        let trendSummary = buildTrendSummary(
            period: period,
            targetDate: targetDate,
            calendar: cal,
            allExpenses: allExpenses,
            allTodos: allTodos,
            currentExpense: totalExpense,
            currentIncome: totalIncome,
            currentCompletionRate: completionRate
        )

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
            vitality: vitality,
            trendSummary: trendSummary
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

        // 11. 行动建议引擎
        let periodDays = max(1, Int((endDate.timeIntervalSince(startDate) / 86400).rounded()))
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
            trendSummary: trendSummary,
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
            trendSummary: trendSummary,
            vitality: vitality,
            healthSnapshot: healthSnapshot
        )
    }

    // MARK: - 趋势与变化分析

    /// 回溯多期数据，构建趋势汇总。
    ///
    /// 每一期的窗口边界都来自 Core 的 `ReportPeriodWindow`，与「本期」窗口完全同源；
    /// 因此序列最后一期就是本期，环比永远拿「紧邻的上一期」比，
    /// 不会因为 2 月 28 天或闰年导致错位。
    private func buildTrendSummary(
        period: ReportPeriodType,
        targetDate: Date,
        calendar cal: Calendar,
        allExpenses: [ExpenseRecord],
        allTodos: [TodoItem],
        currentExpense: Double,
        currentIncome: Double,
        currentCompletionRate: Double
    ) -> PeriodTrendSummary? {
        guard period.supportsTrendAnalysis else { return nil }
        let historyCount = period.trendHistoryCount
        guard historyCount >= 2 else { return nil }

        let windows = ReportPeriodWindow.series(
            containing: targetDate,
            count: historyCount,
            granularity: period.granularity,
            calendar: cal
        )

        // 逐期汇总
        var points: [PeriodReportAnalytics.PeriodPoint] = []
        points.reserveCapacity(windows.count)

        for window in windows {
            let periodExpenses = allExpenses.filter { $0.date >= window.start && $0.date < window.end }
            let expense = periodExpenses.filter { !$0.isIncome }.reduce(0.0) { $0 + $1.amount }
            let income = periodExpenses.filter { $0.isIncome }.reduce(0.0) { $0 + $1.amount }

            let completed = allTodos.filter { todo in
                guard todo.status == .done else { return false }
                if let comp = todo.completedAt { return comp >= window.start && comp < window.end }
                return todo.createdAt >= window.start && todo.createdAt < window.end
            }.count

            let created = allTodos.filter { $0.createdAt >= window.start && $0.createdAt < window.end }.count

            points.append(PeriodReportAnalytics.PeriodPoint(
                label: trendPointLabel(for: window, period: period, calendar: cal),
                start: window.start,
                end: window.end,
                expense: expense,
                income: income,
                completedCount: completed,
                createdCount: created
            ))
        }

        guard let currentWindow = windows.last else { return nil }

        // 本期与上期的类别金额结构（用于类别占比变化）
        func categoryAmounts(in window: ReportPeriodWindow.Window) -> [String: Double] {
            var result: [String: Double] = [:]
            for exp in allExpenses where !exp.isIncome && exp.date >= window.start && exp.date < window.end {
                result[exp.categoryRaw, default: 0] += exp.amount
            }
            return result
        }
        let currentCategories = categoryAmounts(in: currentWindow)
        let previousCategories = windows.count >= 2 ? categoryAmounts(in: windows[windows.count - 2]) : [:]

        // 本期支出明细（行为模式）与完成明细（准时率）
        let expenseSnapshots: [(date: Date, amount: Double)] = allExpenses
            .filter { !$0.isIncome && $0.date >= currentWindow.start && $0.date < currentWindow.end }
            .map { ($0.date, $0.amount) }

        let completions: [(completedAt: Date, dueAt: Date?)] = allTodos.compactMap { todo in
            guard todo.status == .done, let comp = todo.completedAt else { return nil }
            guard comp >= currentWindow.start && comp < currentWindow.end else { return nil }
            return (comp, todo.dueAt)
        }

        // 上期达成率：按上期自身的完成/应完成口径计算
        var previousCompletionRate: Double?
        if windows.count >= 2 {
            let prevWindow = windows[windows.count - 2]
            let prevCompleted = allTodos.filter { todo in
                guard todo.status == .done else { return false }
                if let comp = todo.completedAt { return comp >= prevWindow.start && comp < prevWindow.end }
                return todo.createdAt >= prevWindow.start && todo.createdAt < prevWindow.end
            }.count
            let prevPending = allTodos.filter { todo in
                todo.status == .active && todo.createdAt < prevWindow.end
            }.count
            let prevTarget = prevCompleted + prevPending
            if prevTarget > 0 {
                previousCompletionRate = Double(prevCompleted) / Double(prevTarget)
            }
        }

        return PeriodTrendBuilder.build(
            points: points,
            currentCategoryAmounts: currentCategories,
            previousCategoryAmounts: previousCategories,
            expenseSnapshots: expenseSnapshots,
            completions: completions,
            currentIncome: currentIncome,
            currentCompletionRate: currentCompletionRate,
            previousCompletionRate: previousCompletionRate,
            now: .now,
            calendar: cal
        )
    }

    // MARK: - 日期范围与标题计算

    /// 计算报告周期窗口。**边界规则统一由 Core 的 `ReportPeriodWindow` 提供**，
    /// 保证「本期」与「趋势序列里的最后一期」落在完全相同的区间——
    /// 否则环比就成了拿上上周比上周，且周报在不同地区设置下会跨 6 天而非 7 天。
    ///
    /// 返回的 `end` 为**不含**的下一周期起点，与 Core 语义一致。
    private func calculateDateRange(period: ReportPeriodType, targetDate: Date, calendar cal: Calendar) -> (Date, Date, String, String) {
        let window = ReportPeriodWindow.window(
            containing: targetDate,
            granularity: period.granularity,
            calendar: cal
        )
        let start = window.start
        let end = window.end

        switch period {
        case .daily:
            let isToday = cal.isDateInToday(targetDate)
            let titlePrefix = isToday
                ? L10n.tr("今日生活日报")
                : (L10n.isEnglish
                    ? targetDate.formatted(.dateTime.month().day().locale(L10n.locale)) + " Daily Report"
                    : targetDate.formatted(.dateTime.month().day()) + " 日报")
            let sub = targetDate.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: L10n.locale))
            return (start, end, titlePrefix, sub)

        case .weekly:
            // 周窗口锚定周一~周日（Core 内部强制 firstWeekday = 2，不随地区设置漂移）
            let isoCal = ReportPeriodWindow.mondayFirstCalendar(base: cal)
            let weekNumber = isoCal.component(.weekOfYear, from: start)
            let year = isoCal.component(.yearForWeekOfYear, from: start)
            let title = L10n.choose("\(year)年第 \(weekNumber) 周 · 复盘周报", "Week \(weekNumber), \(year) · Weekly Report")
            let sub = "\(start.formatted(.dateTime.month().day().locale(L10n.locale))) ~ \(cal.date(byAdding: .day, value: -1, to: end)!.formatted(.dateTime.month().day().locale(L10n.locale)))"
            return (start, end, title, sub)

        case .quarterly:
            let year = cal.component(.year, from: targetDate)
            let month = cal.component(.month, from: targetDate)
            let quarter = (month - 1) / 3 + 1
            let startMonth = (quarter - 1) * 3 + 1
            let endMonth = startMonth + 2
            let daysInEnd = cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: year, month: endMonth, day: 1)) ?? start)?.count ?? 31
            let title = L10n.choose("\(year)年第 \(quarter) 季度 · 复盘季报", "Q\(quarter) \(year) · Quarterly Report")
            let sub = "\(year)年\(startMonth)月1日 ~ \(endMonth)月\(daysInEnd)日"
            return (start, end, title, sub)

        case .yearly:
            let year = cal.component(.year, from: targetDate)
            let title = L10n.choose("\(year)年 · 自然年报", "\(year) · Annual Report")
            let sub = L10n.choose("\(year)年1月1日 ~ \(year)年12月31日", "Jan 1, \(year) ~ Dec 31, \(year)")
            return (start, end, title, sub)

        case .monthly:
            let monthName = targetDate.formatted(.dateTime.year().month().locale(L10n.locale))
            let range = cal.range(of: .day, in: .month, for: targetDate)?.count ?? 30
            let title = L10n.choose("\(monthName) · 成果月报", "\(monthName) · Monthly Report")
            let sub = L10n.choose("\(monthName) 1日 ~ \(range)日", "\(monthName) 1 ~ \(range)")
            return (start, end, title, sub)
        }
    }

    /// 趋势序列里某一期的展示标签（如「6/15」「2026-06」「2026 Q2」「2026」）。
    private func trendPointLabel(
        for window: ReportPeriodWindow.Window,
        period: ReportPeriodType,
        calendar cal: Calendar
    ) -> String {
        switch period {
        case .daily:
            return window.start.formatted(.dateTime.month().day().locale(L10n.locale))
        case .weekly:
            return window.start.formatted(.dateTime.month().day().locale(L10n.locale))
        case .monthly:
            return window.start.formatted(.dateTime.year().month().locale(L10n.locale))
        case .quarterly:
            let comps = cal.dateComponents([.year, .month], from: window.start)
            let quarter = ((comps.month ?? 1) - 1) / 3 + 1
            return "\(comps.year ?? 0) Q\(quarter)"
        case .yearly:
            return String(cal.component(.year, from: window.start))
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
        trendSummary: PeriodTrendSummary?,
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

        // ===== 长周期（周/月/季/年）回顾类建议：全部由趋势与环比真实数据驱动 =====
        if let trend = trendSummary {
            let expenseDiff = totalExpense - (trend.previousExpense ?? 0)

            // 9a. 支出环比显著上升 → 指认增长来源类别
            if let prev = trend.previousExpense, prev > 0 {
                let changeRatio = (totalExpense - prev) / prev
                if changeRatio > 0.2, expenseDiff > 100 {
                    var detail = "本期 ¥\(String(format: "%.0f", totalExpense)) ← 上期 ¥\(String(format: "%.0f", prev))。"
                    if let growth = trend.categoryChanges.first(where: { $0.delta > 0 }) {
                        detail += "主要来自「\(growth.categoryRaw)」：¥\(String(format: "%.0f", growth.previous)) → ¥\(String(format: "%.0f", growth.current))（+\(String(format: "%.0f", growth.delta))）。先确认其中是否含一次性大额，再决定下期是否收紧该类别。"
                    } else {
                        detail += "先回看几笔最大的开支是否必要，再决定下期节奏。"
                    }
                    suggestions.append(ReportSuggestion(
                        tone: .urgent, icon: "chart.line.uptrend.xyaxis",
                        title: String(format: "支出比上期增加 %d%%", Int(changeRatio * 100)),
                        detail: detail
                    ))
                }

                // 9b. 支出环比明显下降 → 肯定并提示守住
                if changeRatio < -0.1, expenseDiff < -100 {
                    var detail = "上期 ¥\(String(format: "%.0f", prev)) → 本期 ¥\(String(format: "%.0f", totalExpense))。"
                    if let shrink = trend.categoryChanges.first(where: { $0.delta < 0 }) {
                        detail += "「\(shrink.categoryRaw)」降温最明显：¥\(String(format: "%.0f", shrink.previous)) → ¥\(String(format: "%.0f", shrink.current))。"
                    }
                    detail += "省钱不是压到最低，而是稳在能长期执行的区间。"
                    suggestions.append(ReportSuggestion(
                        tone: .positive, icon: "chart.line.downtrend.xyaxis",
                        title: String(format: "支出比上期减少 ¥%.0f（-%d%%）", -expenseDiff, Int(-changeRatio * 100)),
                        detail: detail
                    ))
                }
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

            // 9f. 多期趋势洞察：把统计结论翻译成可执行的建议
            suggestions.append(contentsOf: trendSuggestion(from: trend))
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

        return Array(
            suggestions
                .enumerated()
                .sorted { lhs, rhs in
                    // 先按色位，再按权重，最后按原始顺序兜底——
                    // Array.sorted 本身不保证稳定，必须显式带上原始下标，
                    // 否则同一份数据每次渲染出的建议顺序可能不同。
                    if lhs.element.tone.rawValue != rhs.element.tone.rawValue {
                        return lhs.element.tone.rawValue < rhs.element.tone.rawValue
                    }
                    if lhs.element.priority != rhs.element.priority {
                        return lhs.element.priority < rhs.element.priority
                    }
                    return lhs.offset < rhs.offset
                }
                .prefix(6)
                .map(\.element)
        )
    }

    // MARK: - 趋势洞察 → 建议文案

    /// 把 Core 产出的结构化洞察翻译成用户可读的建设性建议。
    ///
    /// 措辞刻意给出**下一步动作**而不是只陈述事实：
    /// 「支出连续 3 期上升」是事实，「先看最大的那一类，设定下期上限」才是建议。
    private func trendSuggestion(from trend: PeriodTrendSummary) -> [ReportSuggestion] {
        var result: [ReportSuggestion] = []

        for insight in PeriodTrendBuilder.insights(from: trend) {
            switch insight {
            case .expenseSustainedRise(let periods, let delta):
                result.append(ReportSuggestion(
                    tone: .action, icon: "chart.line.uptrend.xyaxis",
                    title: String(format: "支出已连续 %d 期上升", periods),
                    detail: String(
                        format: "每期平均多花 ¥%.0f。这不是偶然波动——先看金额最大的那一类，设定下期上限，把它压回原来的水平。",
                        abs(delta)
                    ),
                    priority: 0
                ))

            case .expenseSustainedFall(let periods, let delta):
                result.append(ReportSuggestion(
                    tone: .positive, icon: "chart.line.downtrend.xyaxis",
                    title: String(format: "支出已连续 %d 期下降", periods),
                    detail: String(
                        format: "每期平均少花 ¥%.0f。找到这期间刻意避开的那笔开销，把这个节奏固化下来——省钱靠的是可持续，不是压到最低。",
                        abs(delta)
                    ),
                    priority: 1
                ))

            case .expenseVolatile(let volatility):
                result.append(ReportSuggestion(
                    tone: .action, icon: "waveform.path.ecg",
                    title: "支出起伏较大，节奏不稳",
                    detail: String(
                        format: "各期波动系数 %.0f%%。忽高忽低通常意味着「没预算、凭感觉花」——给弹性支出设一个月度上限，比事后补救有效得多。",
                        volatility * 100
                    ),
                    priority: 2
                ))

            case .completionSustainedRise(let periods):
                result.append(ReportSuggestion(
                    tone: .positive, icon: "arrow.up.circle.fill",
                    title: String(format: "执行力连续 %d 期上升", periods),
                    detail: "完成量在稳步抬升，说明当前的拆解方式是有效的。趁着手感好，把这周验证过的做法固定成模板。",
                    priority: 1
                ))

            case .completionSustainedFall(let periods):
                result.append(ReportSuggestion(
                    tone: .action, icon: "arrow.down.circle.fill",
                    title: String(format: "完成量连续 %d 期下降", periods),
                    detail: "产出在滑坡，通常不是懒而是任务变大了或被打断得更频繁。先把清单砍到 3 件核心事项，保住完成率再谈扩张。",
                    priority: 0
                ))

            case .punctualityBelowTarget(let rate, let delay):
                result.append(ReportSuggestion(
                    tone: .action, icon: "clock.badge.exclamationmark",
                    title: String(format: "准时率仅 %.0f%%", rate * 100),
                    detail: String(
                        format: "有截止时间的事项里只有 %.0f%% 按时完成，平均拖延 %.1f 天。给关键事项提前一天设提醒，比临期才发现来不及有效。",
                        rate * 100, delay
                    ),
                    priority: 0
                ))

            case .punctualityHealthy(let rate):
                result.append(ReportSuggestion(
                    tone: .positive, icon: "checkmark.seal.fill",
                    title: String(format: "准时率 %.0f%%，节奏很稳", rate * 100),
                    detail: "有截止时间的事项基本都能按时交付。保持这个习惯，把省下的时间用在更重要的事上。",
                    priority: 2
                ))

            case .weekendSpendingHeavy(let share, let weekendDaily, let weekdayDaily):
                result.append(ReportSuggestion(
                    tone: .action, icon: "calendar.badge.clock",
                    title: String(format: "周末支出占 %.0f%%", share * 100),
                    detail: String(
                        format: "周末日均 ¥%.0f，工作日只有 ¥%.0f。把大额消费挪到工作日、或给周末设一个固定额度，是最容易见效的调整。",
                        weekendDaily, weekdayDaily
                    ),
                    priority: 2
                ))

            case .smallTicketFrequent(let count, let total):
                result.append(ReportSuggestion(
                    tone: .action, icon: "smallcircle.filled.circle",
                    title: String(format: "小额消费 %d 笔", count),
                    detail: String(
                        format: "合计 ¥%.0f 的零散小额支出。单笔不起眼，累积起来却可观——给这类消费也设个每日额度。",
                        total
                    ),
                    priority: 3
                ))

            case .categoryAppeared(let name, let amount):
                result.append(ReportSuggestion(
                    tone: .action, icon: "sparkles",
                    title: String(format: "新增了「%@」类支出", name),
                    detail: String(
                        format: "本期 ¥%.0f。这是新出现的开销，先确认是阶段性还是长期——长期的话要给它单独设上限。",
                        amount
                    ),
                    priority: 3
                ))

            case .categoryVanished(let name, let amount):
                result.append(ReportSuggestion(
                    tone: .positive, icon: "checkmark.circle",
                    title: String(format: "「%@」类支出已归零", name),
                    detail: String(
                        format: "上期的 ¥%.0f 这期没有再产生。这说明上次的调整见效了，保持住。",
                        amount
                    ),
                    priority: 3
                ))

            case .categoryShareUp(let name, let delta, let shareDelta):
                result.append(ReportSuggestion(
                    tone: .action, icon: "arrow.up.right.circle",
                    title: String(format: "「%@」占比上升 %.0f 个百分点", name, shareDelta * 100),
                    detail: String(
                        format: "金额增加 ¥%.0f，在支出结构里的权重明显变重。如果这是必要开销就接受它；如果不是，现在是最容易调整的时候。",
                        delta
                    ),
                    priority: 2
                ))

            case .categoryShareDown(let name, let delta, let shareDelta):
                result.append(ReportSuggestion(
                    tone: .positive, icon: "arrow.down.right.circle",
                    title: String(format: "「%@」占比下降 %.0f 个百分点", name, abs(shareDelta) * 100),
                    detail: String(
                        format: "金额减少 ¥%.0f，支出结构更集中了。结构变清晰通常意味着消费决策更有取舍。",
                        abs(delta)
                    ),
                    priority: 3
                ))

            case .nextPeriodTarget(let expenseCap, let completedTarget, let savingsRate):
                var parts: [String] = []
                if let cap = expenseCap {
                    parts.append(String(format: "支出控制在 ¥%.0f 以内", cap))
                }
                parts.append(String(format: "完成 %d 项事项", completedTarget))
                if let rate = savingsRate {
                    parts.append(String(format: "储蓄率保持 %.0f%%", rate * 100))
                }
                result.append(ReportSuggestion(
                    tone: .action, icon: "target",
                    title: "下期目标建议",
                    detail: String(format: "基于近几期的水平，下期可以试着：%@。目标定在「跳一跳够得着」的位置，比定一个够不到的更有用。", parts.joined(separator: "、")),
                    priority: 1
                ))
            }
        }

        return result
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
        vitality: VitalityEvaluation? = nil,
        trendSummary: PeriodTrendSummary? = nil
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
                    "活力指数 \(v.score) 分（\(v.level.badge)）。\(v.summary)",
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
            segments.append(contentsOf: trendSummarySentence(trendSummary, periodLabel: "周"))

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
            segments.append(contentsOf: trendSummarySentence(trendSummary, periodLabel: "月"))

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
            segments.append(contentsOf: trendSummarySentence(trendSummary, periodLabel: "季度"))

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
            segments.append(contentsOf: trendSummarySentence(trendSummary, periodLabel: "年度"))
        }

        return segments.joined(separator: " ")
    }

    /// 生成趋势描述句，融入智能复盘小结。
    ///
    /// 只在**有足够样本**（≥3 期）且趋势方向明确时才说话；
    /// 样本不足时宁可不说，也不编一个「稳步上升」出来。
    private func trendSummarySentence(_ trend: PeriodTrendSummary?, periodLabel: String) -> [String] {
        guard let trend, trend.hasMeaningfulTrend else { return [] }
        var sentences: [String] = []

        let expenseTrend = trend.expenseTrend
        if expenseTrend.direction == .rising, expenseTrend.streak >= 2 {
            sentences.append(String(
                format: "拉长看，近 %d 期的%s支出在持续走高，每期约多花 ¥%.0f，这已经是趋势而非偶然。",
                expenseTrend.streak + 1, periodLabel, abs(expenseTrend.slope)
            ))
        } else if expenseTrend.direction == .falling, expenseTrend.streak <= -2 {
            sentences.append(String(
                format: "近 %d 期的%s支出持续回落，每期约省下 ¥%.0f，省钱节奏已经形成。",
                abs(expenseTrend.streak) + 1, periodLabel, abs(expenseTrend.slope)
            ))
        }

        let completionTrend = trend.completionTrend
        if completionTrend.direction == .rising, completionTrend.streak >= 2 {
            sentences.append(String(
                format: "完成量同样在抬升，说明执行力在稳定变强。",
                completionTrend.streak + 1
            ))
        } else if completionTrend.direction == .falling, completionTrend.streak <= -2 {
            sentences.append(String(
                format: "完成量在连续回落，需要留意是任务变重了还是节奏被挤掉了。",
                abs(completionTrend.streak) + 1
            ))
        }

        if let punctuality = trend.punctuality, let rate = punctuality.onTimeRate {
            sentences.append(String(format: "有截止时间的事项准时率为 %.0f%%。", rate * 100))
        }

        return sentences
    }

    // MARK: - 本地通知定时调度

    /// 所有定期报告通知的 identifier 前缀。
    ///
    /// 月报/季报/年报用的是**按具体日期枚举**的一次性触发器（月末/季末/年末
    /// 不是固定日，固定 `day: 31` 会在短月静默失效），
    /// 所以 identifier 带日期后缀，重排时必须能按前缀整体清掉。
    private static let notificationPrefix = "periodic-report-"

    /// 统一注册所有已开启报告的本地通知日程。
    ///
    /// 幂等：每次调用都先清空本模块的全部待处理通知，再按当前开关重新注册。
    /// 依赖 App 每次进入前台的巡检（`AssistantApp` → `performForegroundAudit`）
    /// 来保持一次性触发器的滚动窗口始终覆盖未来。
    func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()

        // 移除现存旧定时通知。
        // 不能只按固定 identifier 删——枚举出来的一次性触发器带日期后缀，
        // 漏删会让「改开关后旧通知仍然会响」。
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.notificationPrefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }

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

        // 2. 周报定时通知（每周固定星期几）
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
            content.userInfo = ["type": "periodic-report", "period": "weekly"]

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: true)
            let req = UNNotificationRequest(identifier: "periodic-report-weekly", content: content, trigger: trigger)
            center.add(req)
        }

        // 3. 月报定时通知（每月最后一天）
        //
        // 为什么不能直接用 `dateComps.day = 31` 的重复触发器：
        // UNCalendarNotificationTrigger 在「当月没有这一天」时**静默不触发**——
        // 2 月、4 月、6 月、9 月、11 月的月报会直接消失，且没有任何报错。
        // 所以这里枚举未来 12 个「真实月末日」，各自注册一个一次性触发器。
        if isMonthlyReportEnabled {
            let h = cal.component(.hour, from: monthlyTime)
            let m = cal.component(.minute, from: monthlyTime)

            let content = UNMutableNotificationContent()
            content.title = L10n.tr("📅 月度生活成果月报已生成")
            content.body = L10n.tr("全月生活资产与支出账单结构大盘点，点击开启本月新展望。")
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"
            content.userInfo = ["type": "periodic-report", "period": "monthly"]

            // 枚举未来 12 个月末（含本月月末）。只注册尚未过去的那些。
            let monthEnds = ReportPeriodWindow.upcomingMonthEnds(from: .now, count: 12, calendar: cal)
            for day in monthEnds {
                guard let fireDate = cal.date(bySettingHour: h, minute: m, second: 0, of: day),
                      fireDate > .now else { continue }
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                comps.second = nil
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "periodic-report-monthly-\(cal.component(.year, from: fireDate))-\(cal.component(.month, from: fireDate))"
                let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                center.add(req)
            }
        }

        // 4. 季报定时通知（每季度最后一天）
        //
        // 同样不能依赖固定 day——季末可能是 3/31、6/30、9/30 或 12/31，
        // 所以枚举未来 8 个季末（两年）逐个注册。
        if isQuarterlyReportEnabled {
            let h = cal.component(.hour, from: quarterlyTime)
            let m = cal.component(.minute, from: quarterlyTime)

            let content = UNMutableNotificationContent()
            content.title = L10n.tr("🗓️ 季度深度复盘季报已生成")
            content.body = L10n.tr("回看本季度的目标达成、财务结构与习惯坚持情况，为下季度校准方向。")
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"
            content.userInfo = ["type": "periodic-report", "period": "quarterly"]

            let quarterEnds = ReportPeriodWindow.upcomingQuarterEnds(from: .now, count: 8, calendar: cal)
            for day in quarterEnds {
                guard let fireDate = cal.date(bySettingHour: h, minute: m, second: 0, of: day),
                      fireDate > .now else { continue }
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                comps.second = nil
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "periodic-report-quarterly-\(cal.component(.year, from: fireDate))-\(cal.component(.month, from: fireDate))"
                let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                center.add(req)
            }
        }

        // 5. 年报定时通知（每年 12 月 31 日）
        if isYearlyReportEnabled {
            let h = cal.component(.hour, from: yearlyTime)
            let m = cal.component(.minute, from: yearlyTime)

            let content = UNMutableNotificationContent()
            content.title = L10n.tr("🎊 年度生活全景年报已生成")
            content.body = L10n.tr("这一年的目标、财务与健康总览回顾，值得好好读一遍。")
            content.sound = .default
            content.categoryIdentifier = "PERIODIC_REPORT"
            content.userInfo = ["type": "periodic-report", "period": "yearly"]

            let yearEnds = ReportPeriodWindow.upcomingYearEnds(from: .now, count: 3, calendar: cal)
            for day in yearEnds {
                guard let fireDate = cal.date(bySettingHour: h, minute: m, second: 0, of: day),
                      fireDate > .now else { continue }
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                comps.second = nil
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "periodic-report-yearly-\(cal.component(.year, from: fireDate))"
                let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                center.add(req)
            }
        }
    }
}
