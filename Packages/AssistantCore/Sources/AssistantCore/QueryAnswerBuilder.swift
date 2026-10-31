import Foundation

// MARK: - 查询应答文案（纯函数）
//
// 把数据快照渲染成一句话回答。只做「数字 → 文案」，
// 不碰 SwiftData——数据获取在 App 侧 `LifeQueryService` 完成后把快照喂进来。
// 中文文案直接内置（与投喂口回执同口径）；如需英文可后补 L10n。

public enum QueryAnswerBuilder {

    // MARK: 消费汇总

    /// 一笔消费快照（仅应答所需字段）
    public struct ExpenseLine: Equatable, Sendable {
        public let title: String
        public let amount: Double
        public let isIncome: Bool
        public let categoryRaw: String

        public init(title: String, amount: Double, isIncome: Bool, categoryRaw: String) {
            self.title = title
            self.amount = amount
            self.isIncome = isIncome
            self.categoryRaw = categoryRaw
        }
    }

    /// 消费汇总应答：总额 / 笔数 / 收入 / 最大一笔。
    public static func expenseSummary(
        rangeLabel: String,
        lines: [ExpenseLine],
        previousTotal: Double? = nil
    ) -> String {
        let expenses = lines.filter { !$0.isIncome }
        let incomes = lines.filter(\.isIncome)
        let total = expenses.reduce(0.0) { $0 + $1.amount }
        let income = incomes.reduce(0.0) { $0 + $1.amount }

        if lines.isEmpty {
            return "\(rangeLabel)没有记账记录。对我说「午饭35元」就能快速记一笔。"
        }

        var parts: [String] = []
        if expenses.isEmpty {
            parts.append("\(rangeLabel)暂无支出（收入 \(formatAmount(income)) 元）")
        } else {
            parts.append("\(rangeLabel)共支出 \(formatAmount(total)) 元（\(expenses.count) 笔）")
            if income > 0 {
                parts.append("收入 \(formatAmount(income)) 元")
            }
            if let biggest = expenses.max(by: { $0.amount < $1.amount }) {
                parts.append("最大一笔是「\(displayTitle(biggest))」\(formatAmount(biggest.amount)) 元")
            }
        }

        if let previousTotal, previousTotal > 0 {
            let delta = total - previousTotal
            let pct = Int((delta / previousTotal * 100).rounded())
            let trend = delta >= 0 ? "多 \(pct)%" : "少 \(-pct)%"
            parts.append("比上一周期\(trend)")
        }
        return parts.joined(separator: "，") + "。"
    }

    // MARK: 消费趋势

    /// 消费趋势应答：月均 / 本月 / 环比 / 类别涨跌。
    public static func expenseTrendNarrative(_ trend: TrendAnalytics.ExpenseTrend) -> String {
        guard let current = trend.months.last else {
            return "还没有消费数据，记几笔账后就能看到趋势。"
        }
        var parts: [String] = []
        parts.append("近\(trend.months.count)个月月均支出 \(formatAmount(trend.averageExpense)) 元")
        parts.append("\(current.month)月 \(formatAmount(current.expense)) 元")

        if let ratio = trend.changeRatio {
            let pct = Int((ratio * 100).rounded())
            parts.append("环比\(ratio >= 0 ? "上涨" : "下降") \(abs(pct))%")
        } else {
            parts.append("上月无支出基线，暂无环比")
        }

        if let growing = trend.growingCategory {
            parts.append("增长最快的是\(displayCategory(growing.categoryRaw))（\(formatAmount(growing.from))→\(formatAmount(growing.to)) 元）")
        }
        if let shrinking = trend.shrinkingCategory {
            parts.append("降温最明显的是\(displayCategory(shrinking.categoryRaw))（\(formatAmount(shrinking.from))→\(formatAmount(shrinking.to)) 元）")
        }
        return parts.joined(separator: "，") + "。"
    }

    // MARK: 饮食趋势

    /// 饮食趋势应答：日均 / 有记录天数 / 半段对比 / 极值。
    public static func dietTrendNarrative(_ trend: TrendAnalytics.DietTrend) -> String {
        if trend.recordedDays == 0 {
            return "这段时间还没有饮食记录，拍照估算或记账推测后就能看到摄入趋势。"
        }
        var parts: [String] = []
        parts.append("近\(trend.days.count)天有 \(trend.recordedDays) 天记录，日均摄入 \(Int(trend.averageCalories.rounded())) 千卡")

        if let ratio = trend.changeRatio {
            let pct = Int((ratio * 100).rounded())
            parts.append("后半段比前半段\(ratio >= 0 ? "上升" : "下降") \(abs(pct))%")
        }
        if let max = trend.maxDayCalories {
            parts.append("最高一天 \(Int(max.rounded())) 千卡")
        }
        return parts.joined(separator: "，") + "。"
    }

    // MARK: 健康趋势

    /// 健康趋势应答：睡眠均值 / 半段变化 / 健康分数。**无数据就说无数据，不伪造 0 小时。**
    public static func healthTrendNarrative(_ trend: TrendAnalytics.HealthTrend) -> String {
        if trend.sleepRecordedDays == 0 && trend.scoreRecordedDays == 0 {
            return "这段时间还没有健康数据，进入健康页授权读取后就能看到睡眠与分数趋势。"
        }
        var parts: [String] = []
        if let avgSleep = trend.averageSleepHours {
            parts.append("近\(trend.days.count)天有 \(trend.sleepRecordedDays) 天睡眠数据，日均 \(String(format: "%.1f", avgSleep)) 小时")
        }
        if let ratio = trend.sleepChangeRatio {
            let pct = Int((ratio * 100).rounded())
            parts.append("后半段睡眠比前半段\(ratio >= 0 ? "上升" : "下降") \(abs(pct))%")
        }
        if let avgScore = trend.averageScore {
            parts.append("健康分日均 \(Int(avgScore.rounded()))")
        }
        if let ratio = trend.scoreChangeRatio {
            let pct = Int((ratio * 100).rounded())
            parts.append("分数\(ratio >= 0 ? "走高" : "走低") \(abs(pct))%")
        }
        return parts.joined(separator: "，") + "。"
    }

    /// 健康汇总应答：窗口内的睡眠 / 步数 / 健康分数。缺失指标不提，避免「读不到」被说成 0。
    public static func healthSummary(
        rangeLabel: String,
        sleepHours: Double? = nil,
        stepCount: Double? = nil,
        vitalityScore: Double? = nil
    ) -> String {
        var parts: [String] = []
        if let sleepHours {
            parts.append("睡眠 \(String(format: "%.1f", sleepHours)) 小时")
        }
        if let stepCount {
            parts.append("\(Int(stepCount.rounded())) 步")
        }
        if let vitalityScore {
            parts.append("健康分 \(Int(vitalityScore.rounded()))")
        }
        guard !parts.isEmpty else {
            return "\(rangeLabel)还没有健康数据。"
        }
        return "\(rangeLabel)\(parts.joined(separator: "，"))。"
    }

    // MARK: 日程

    /// 日程应答：当天/窗口内的待办清单。
    public struct AgendaLine: Equatable, Sendable {
        public let title: String
        /// 已格式化的时间片段（如 "14:00"），无时间则为 nil
        public let timeText: String?
        public let isOverdue: Bool

        public init(title: String, timeText: String? = nil, isOverdue: Bool = false) {
            self.title = title
            self.timeText = timeText
            self.isOverdue = isOverdue
        }
    }

    public static func agendaSummary(rangeLabel: String, lines: [AgendaLine], overflowCount: Int = 0) -> String {
        if lines.isEmpty {
            return "\(rangeLabel)没有待办安排。"
        }
        let shown = lines.prefix(6).map { line -> String in
            let time = line.timeText.map { "\($0) " } ?? ""
            let overdue = line.isOverdue ? "（已逾期）" : ""
            return "\(time)\(line.title)\(overdue)"
        }.joined(separator: "；")
        let overflow = overflowCount > 0 ? "，另有 \(overflowCount) 项" : ""
        return "\(rangeLabel)有 \(lines.count) 件安排：\(shown)\(overflow)。"
    }

    // MARK: 查找

    /// 找到实体时的一行回执
    public static func lookupHit(kind: String, name: String, detail: String) -> String {
        "🔍 找到\(kind)：\(name)｜\(detail)"
    }

    /// 未找到时的兜底（附带检索域提示，方便用户知道查过哪些地方）
    public static func lookupMiss(keyword: String, searchedKinds: [String]) -> String {
        let scope = searchedKinds.joined(separator: "、")
        return "🔍 未找到「\(keyword)」相关的\(scope)记录。换个说法或先记一条试试。"
    }

    // MARK: 数字格式化

    /// 金额展示：整数不带小数，小数保留两位并去尾零
    public static func formatAmount(_ value: Double) -> String {
        AmountFormatter.format(value)
    }

    private static func displayTitle(_ line: ExpenseLine) -> String {
        line.title.isEmpty ? displayCategory(line.categoryRaw) : line.title
    }

    /// 分类 rawValue → 展示名。`ExpenseCategory.rawValue` 本身即中文
    /// （如「餐饮美食」），原样返回即可；兜底处理意外空串。
    private static func displayCategory(_ raw: String) -> String {
        raw.isEmpty ? "其他" : raw
    }
}
