import AssistantCore
import Foundation

// MARK: - 月预算设置（UserDefaults 持久化）

/// 月度弹性预算设置。预算指扣除固定刚性支出后、用户希望本月弹性消费的总额上限。
public enum BudgetSettings {
    /// 每月弹性消费预算（¥）。0 表示未设置，不显示安心花卡片。
    public static var monthlyBudget: Double {
        get { UserDefaults.standard.object(forKey: "expense_monthly_budget") as? Double ?? 0 }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "expense_monthly_budget") }
    }
}

// MARK: - 今日安心花（Safe-to-Spend）数据归集扩展（依赖 ExpenseRecord 模型）

extension SafeToSpendCalculator {
    /// 从账本记录一次性 O(N) 归集安心花输入快照（视图卡片与周期报告共用）
    public static func inputFromRecords(
        records: [ExpenseRecord],
        fixedMonthlyTotal: Double,
        monthlyBudget: Double = BudgetSettings.monthlyBudget,
        rhythmMode: SpendingRhythmMode = .weekendLeisure,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> SafeToSpendInput {
        var flexibleMonth = 0.0
        var fixedMonth = 0.0
        var flexibleYesterday = 0.0
        var flexibleToday = 0.0

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        // 计算本周一起始点
        let weekday = calendar.component(.weekday, from: now)
        let daysFromMonday = (weekday == 1) ? 6 : (weekday - 2)
        let startOfWeekMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfToday) ?? startOfToday

        // 统计本周前几个工作日的支出，用于计算蓄水池
        var workdaySpendsByDay: [Date: Double] = [:]

        for record in records where !record.isIncome {
            let isFixed = isFixedExpenseRecord(record.rawText)
            if calendar.isDate(record.date, equalTo: now, toGranularity: .month) {
                if isFixed { fixedMonth += record.amount } else { flexibleMonth += record.amount }
            }
            if calendar.isDate(record.date, inSameDayAs: now) {
                if !isFixed { flexibleToday += record.amount }
            } else if let startOfYesterday, calendar.isDate(record.date, inSameDayAs: startOfYesterday) {
                if !isFixed { flexibleYesterday += record.amount }
            }

            // 本周一至昨天的过去工作日支出
            if !isFixed && record.date >= startOfWeekMonday && record.date < startOfToday {
                let recWeekday = calendar.component(.weekday, from: record.date)
                if recWeekday >= 2 && recWeekday <= 6 { // 周一至周五工作日
                    let recDay = calendar.startOfDay(for: record.date)
                    workdaySpendsByDay[recDay, default: 0] += record.amount
                }
            }
        }
        _ = fixedMonth // 本月固定入账仅作展示参考，预算池由 fixedMonthlyTotal 统一扣除

        // 估算本周工作日蓄水池节余：以粗略日均额度为基准评估每个过去工作日省下的钱
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = calendar.component(.day, from: now)
        let daysLeft = max(1, daysInMonth - dayOfMonth + 1)
        let disposable = max(0, monthlyBudget - fixedMonthlyTotal)
        let currentPool = max(0, disposable - flexibleMonth + flexibleToday)
        let approxDailyAllowance = daysLeft > 0 ? (currentPool / Double(daysLeft)) : 0

        var weekdaySavingsTotal = 0.0
        for (_, daySpend) in workdaySpendsByDay {
            if approxDailyAllowance > daySpend {
                weekdaySavingsTotal += (approxDailyAllowance - daySpend)
            }
        }

        return SafeToSpendInput(
            monthlyBudget: monthlyBudget,
            fixedMonthlyTotal: fixedMonthlyTotal,
            flexibleSpentThisMonth: flexibleMonth,
            fixedSpentThisMonth: fixedMonth,
            yesterdayFlexibleSpend: flexibleYesterday,
            todayFlexibleSpend: flexibleToday,
            rhythmMode: rhythmMode,
            weekdaySavedSoFarThisWeek: weekdaySavingsTotal
        )
    }
}

// MARK: - 物品日均持有成本（Cost Per Day）计算

/// 物品持有成本结果
public struct ItemCostSummary: Equatable {
    public var isTracked: Bool        // 是否已有可计算的成本数据
    public var totalCost: Double      // 累计投入 = 购入价 + 关联记账金额
    public var daysHeld: Int          // 已持有天数（从购入/建档日起；已转卖则截至转卖日）
    public var dailyCost: Double      // 日均持有成本（总投入口径）
    public var milestoneText: String? // 如 "再用 45 天，日均成本就低于 ¥10 啦"

    // 二手市场联动：转卖回血与净持有成本
    public var isSecondHand: Bool     // 是否二手购入（买入价更低，日均成本起点也更低）
    public var isResold: Bool         // 是否已转卖
    public var resalePrice: Double    // 转卖所得（未转卖为 0）
    public var netCost: Double        // 净持有成本 = 累计投入 − 转卖回血（未转卖时等于累计投入）
    public var netDailyCost: Double   // 净日均持有成本 = 净成本 ÷ 持有天数
}

public enum ItemCostCalculator {
    /// 里程碑提示的日均成本档位（元/天）
    private static let milestoneThresholds: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500]

    /// 计算物品日均持有成本与下一个里程碑
    ///
    /// - Parameters:
    ///   - purchasePrice: 物品购入价（收纳档案填写）
    ///   - purchaseDate: 购入日期；为空时回退到建档日期
    ///   - fallbackStartDate: 建档日期（purchaseDate 为空时使用）
    ///   - linkedExpenseTotal: 关联记账的总金额（保养、配件、维修等后续投入）
    ///   - isSecondHand: 是否二手购入（买入价更低，净成本起点也更低）
    ///   - resalePrice: 转卖所得（已转卖时从总投入中回血扣除）
    ///   - resoldDate: 转卖日期；非空表示已转卖，持有天数截至该日
    public static func summary(
        purchasePrice: Double?,
        purchaseDate: Date?,
        fallbackStartDate: Date,
        linkedExpenseTotal: Double = 0,
        isSecondHand: Bool = false,
        resalePrice: Double? = nil,
        resoldDate: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ItemCostSummary {
        let totalCost = (purchasePrice ?? 0) + linkedExpenseTotal
        guard totalCost > 0 else {
            return ItemCostSummary(
                isTracked: false, totalCost: 0, daysHeld: 0, dailyCost: 0, milestoneText: nil,
                isSecondHand: isSecondHand, isResold: false, resalePrice: 0, netCost: 0, netDailyCost: 0
            )
        }

        let isResold = resoldDate != nil
        let recovered = isResold ? (resalePrice ?? 0) : 0
        let netCost = totalCost - recovered

        // 已转卖的物品持有天数截至转卖日，之后的闲置时间不再摊高日均成本
        let end = isResold ? resoldDate! : now
        let start = purchaseDate ?? fallbackStartDate
        let daysHeld = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0) + 1)
        let dailyCost = totalCost / Double(daysHeld)
        let netDailyCost = netCost / Double(daysHeld)

        // 里程碑文案：已转卖讲"回血"故事，在持物品讲"跌破整数价"故事
        var milestone: String? = nil
        if isResold {
            let formatted = String(format: "%.1f", netDailyCost)
            if netCost <= 0 {
                milestone = "转卖回血 ¥\(String(format: "%.0f", recovered))，相当于零成本持有 🎉"
            } else {
                milestone = "转卖回血 ¥\(String(format: "%.0f", recovered))，实际净成本仅 ¥\(formatted)/天"
            }
        } else if let threshold = milestoneThresholds.last(where: { $0 < dailyCost }) {
            // 需要 totalCost / 天数 < threshold，即天数 > totalCost / threshold
            let daysNeeded = Int(totalCost / threshold) - daysHeld + 1
            if daysNeeded > 0, daysNeeded <= 3650 {
                let formatted = threshold.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", threshold)
                    : String(format: "%.1f", threshold)
                milestone = "再用 \(daysNeeded) 天，日均成本就低于 ¥\(formatted) 啦"
            }
        }

        return ItemCostSummary(
            isTracked: true,
            totalCost: totalCost,
            daysHeld: daysHeld,
            dailyCost: dailyCost,
            milestoneText: milestone,
            isSecondHand: isSecondHand,
            isResold: isResold,
            resalePrice: recovered,
            netCost: netCost,
            netDailyCost: netDailyCost
        )
    }

    /// 归集关联记账投入：itemID -> 该物品累计后继投入金额
    public static func linkedExpenseTotals(records: [ExpenseRecord]) -> [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for record in records where !record.isIncome {
            if let itemID = record.linkedItemID {
                totals[itemID, default: 0] += record.amount
            }
        }
        return totals
    }
}

// MARK: - 月预算执行概览（周期报告月报用）

/// 指定月份的预算执行情况
public struct BudgetOverviewResult: Equatable {
    public var monthlyBudget: Double
    public var fixedMonthlyTotal: Double
    public var flexibleSpent: Double       // 该月已发生弹性支出
    public var remaining: Double           // 剩余弹性额度（可为负 = 超支）
    public var isCurrentMonth: Bool
    public var daysLeft: Int               // 仅当月有意义，非当月为 0
    public var dailyAllowance: Double      // 仅当月有意义，非当月为 0
    public var spentRatio: Double
}

public enum BudgetOverviewCalculator {
    /// 计算某个月的预算执行情况；未设置预算时返回 nil
    public static func compute(
        records: [ExpenseRecord],
        monthDate: Date,
        fixedMonthlyTotal: Double,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> BudgetOverviewResult? {
        let budget = BudgetSettings.monthlyBudget
        guard budget > 0 else { return nil }

        let flexibleSpent = records.filter { record in
            !record.isIncome
                && !SafeToSpendCalculator.isFixedExpenseRecord(record.rawText)
                && calendar.isDate(record.date, equalTo: monthDate, toGranularity: .month)
        }.reduce(0.0) { $0 + $1.amount }

        let disposable = max(0, budget - fixedMonthlyTotal)
        let remaining = disposable - flexibleSpent
        let isCurrentMonth = calendar.isDate(monthDate, equalTo: now, toGranularity: .month)

        var daysLeft = 0
        var dailyAllowance = 0.0
        if isCurrentMonth {
            let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
            daysLeft = max(1, daysInMonth - (calendar.component(.day, from: now)) + 1)
            dailyAllowance = max(0, remaining) / Double(daysLeft)
        }

        return BudgetOverviewResult(
            monthlyBudget: budget,
            fixedMonthlyTotal: fixedMonthlyTotal,
            flexibleSpent: flexibleSpent,
            remaining: remaining,
            isCurrentMonth: isCurrentMonth,
            daysLeft: daysLeft,
            dailyAllowance: dailyAllowance,
            spentRatio: disposable > 0 ? flexibleSpent / disposable : 1
        )
    }
}

// MARK: - 周期报告物品成本榜

/// 报告中展示的单件物品持有成本条目
public struct ItemCostReportEntry: Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var roomArea: String
    public var summary: ItemCostSummary
}

extension ItemCostCalculator {
    /// 从收纳物品与账本生成报告用成本榜（按累计投入降序，取前 limit 件）
    public static func reportEntries(
        items: [StoredItem],
        records: [ExpenseRecord],
        limit: Int = 5
    ) -> [ItemCostReportEntry] {
        let totals = linkedExpenseTotals(records: records)
        return items.compactMap { item -> ItemCostReportEntry? in
            let summary = ItemCostCalculator.summary(
                purchasePrice: item.purchasePrice,
                purchaseDate: item.purchaseDate,
                fallbackStartDate: item.createdAt,
                linkedExpenseTotal: totals[item.id] ?? 0,
                isSecondHand: item.isSecondHand,
                resalePrice: item.resalePrice,
                resoldDate: item.resoldDate
            )
            guard summary.isTracked else { return nil }
            return ItemCostReportEntry(id: item.id, name: item.name, roomArea: item.roomArea, summary: summary)
        }
        .sorted { $0.summary.totalCost > $1.summary.totalCost }
        .prefix(limit)
        .map { $0 }
    }
}
