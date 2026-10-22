import Foundation

// MARK: - 今日安心花（Safe-to-Spend）纯逻辑模型与计算引擎

/// 消费节奏分配模式
public enum SpendingRhythmMode: String, CaseIterable, Sendable, Codable {
    /// 工作日与周末平均分配（传统平摊）
    case flat = "工作日与周末均摊"
    /// 工作日蓄水 · 周末充裕（周一至周五轻量消费，节余蓄水至周六日 1.8x 大额池，聚餐娱乐更从容）
    case weekendLeisure = "工作日蓄水 · 周末充裕"

    public var shortTitle: String {
        switch self {
        case .flat: return "均摊模式"
        case .weekendLeisure: return "工作日蓄水"
        }
    }
}

/// 计算所需的输入快照（纯数据模型，无数据库依赖）
public struct SafeToSpendInput: Equatable, Sendable {
    public var monthlyBudget: Double             // 用户设定的月度弹性预算
    public var fixedMonthlyTotal: Double         // 固定周期支出折算月额（房租、订阅、车贷等）
    public var flexibleSpentThisMonth: Double    // 本月已发生的弹性支出总额（含今日已花）
    public var fixedSpentThisMonth: Double       // 本月已自动入账的固定支出
    public var yesterdayFlexibleSpend: Double    // 昨日弹性支出（用于计算滚入结余）
    public var todayFlexibleSpend: Double        // 今日已花弹性支出
    public var rhythmMode: SpendingRhythmMode    // 消费节奏模式
    public var weekdaySavedSoFarThisWeek: Double // 本周一至昨日在工作日省下的累计金额

    public init(
        monthlyBudget: Double,
        fixedMonthlyTotal: Double,
        flexibleSpentThisMonth: Double,
        fixedSpentThisMonth: Double = 0,
        yesterdayFlexibleSpend: Double = 0,
        todayFlexibleSpend: Double = 0,
        rhythmMode: SpendingRhythmMode = .flat,
        weekdaySavedSoFarThisWeek: Double = 0
    ) {
        self.monthlyBudget = monthlyBudget
        self.fixedMonthlyTotal = fixedMonthlyTotal
        self.flexibleSpentThisMonth = flexibleSpentThisMonth
        self.fixedSpentThisMonth = fixedSpentThisMonth
        self.yesterdayFlexibleSpend = yesterdayFlexibleSpend
        self.todayFlexibleSpend = todayFlexibleSpend
        self.rhythmMode = rhythmMode
        self.weekdaySavedSoFarThisWeek = weekdaySavedSoFarThisWeek
    }
}

/// 「今日安心花」计算结果
public struct SafeToSpendResult: Equatable, Sendable {
    public var isEnabled: Bool             // 预算是否已设置（> 0）
    public var disposableBudget: Double    // 弹性预算总池 = 月预算 - 固定支出折算月额
    public var remainingThisMonth: Double  // 本月弹性剩余（可为负 = 超支）
    public var daysLeft: Int               // 距月底天数（含今天）
    public var daysInMonth: Int
    public var todayAllowance: Double      // 今日起始基准额度（含历史结余滚入与周末权重）
    public var todayFlexibleSpend: Double  // 今日已花弹性支出
    public var safeToSpendToday: Double    // 今天还能安心花的剩余金额（≥ 0，随今日新增记账实时递减）
    public var isTodayOverspent: Bool      // 今日实际花费是否已超过今日基准额度
    public var todayOverspentAmount: Double // 今日超额金额（≥ 0）
    public var todaySpentRatio: Double     // 今日已花占今日基准额度比例（0~1+，用于今日安心花消耗进度条）
    public var savedYesterday: Double      // 昨日省下并滚入今天的金额（≥ 0）
    public var isOverBudget: Bool          // 本月全局弹性预算已超支（remainingThisMonth < 0）
    public var spentRatio: Double          // 本月已花弹性占弹性预算比例（0~1+）
    public var rhythmMode: SpendingRhythmMode // 消费节奏模式
    public var isWeekend: Bool             // 今天是否为周末（周六/周日）
    public var workdayAllowance: Double    // 工作日基准额度
    public var weekendAllowance: Double    // 周末基准额度
    public var weekendReservoirTotal: Double // 本周工作日累计蓄水总额
    public var rhythmAdviceText: String?   // 消费节奏懂你建议

    public init(
        isEnabled: Bool,
        disposableBudget: Double,
        remainingThisMonth: Double,
        daysLeft: Int,
        daysInMonth: Int,
        todayAllowance: Double,
        todayFlexibleSpend: Double,
        safeToSpendToday: Double,
        isTodayOverspent: Bool,
        todayOverspentAmount: Double,
        todaySpentRatio: Double,
        savedYesterday: Double,
        isOverBudget: Bool,
        spentRatio: Double,
        rhythmMode: SpendingRhythmMode = .flat,
        isWeekend: Bool = false,
        workdayAllowance: Double = 0,
        weekendAllowance: Double = 0,
        weekendReservoirTotal: Double = 0,
        rhythmAdviceText: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.disposableBudget = disposableBudget
        self.remainingThisMonth = remainingThisMonth
        self.daysLeft = daysLeft
        self.daysInMonth = daysInMonth
        self.todayAllowance = todayAllowance
        self.todayFlexibleSpend = todayFlexibleSpend
        self.safeToSpendToday = safeToSpendToday
        self.isTodayOverspent = isTodayOverspent
        self.todayOverspentAmount = todayOverspentAmount
        self.todaySpentRatio = todaySpentRatio
        self.savedYesterday = savedYesterday
        self.isOverBudget = isOverBudget
        self.spentRatio = spentRatio
        self.rhythmMode = rhythmMode
        self.isWeekend = isWeekend
        self.workdayAllowance = workdayAllowance
        self.weekendAllowance = weekendAllowance
        self.weekendReservoirTotal = weekendReservoirTotal
        self.rhythmAdviceText = rhythmAdviceText
    }

    public static func == (lhs: SafeToSpendResult, rhs: SafeToSpendResult) -> Bool {
        lhs.isEnabled == rhs.isEnabled
            && abs(lhs.safeToSpendToday - rhs.safeToSpendToday) < 0.005
            && abs(lhs.todayAllowance - rhs.todayAllowance) < 0.005
            && abs(lhs.todayFlexibleSpend - rhs.todayFlexibleSpend) < 0.005
            && abs(lhs.todaySpentRatio - rhs.todaySpentRatio) < 0.005
            && abs(lhs.savedYesterday - rhs.savedYesterday) < 0.005
            && lhs.daysLeft == rhs.daysLeft
            && lhs.isOverBudget == rhs.isOverBudget
            && lhs.isTodayOverspent == rhs.isTodayOverspent
            && lhs.rhythmMode == rhs.rhythmMode
            && lhs.isWeekend == rhs.isWeekend
    }
}

public enum SafeToSpendCalculator {
    /// 固定支出自动入账时写入 rawText 的前缀，用于从账本中区分固定/弹性支出
    public static let fixedExpenseRawTextPrefixes = ["周期自动记账:", "周期固定支出:"]

    /// 一笔账目是否属于固定周期支出的自动入账
    public static func isFixedExpenseRecord(_ rawText: String) -> Bool {
        fixedExpenseRawTextPrefixes.contains { rawText.hasPrefix($0) }
    }

    /// 计算今日安心花额度
    ///
    /// ## 核心逻辑（实时递减与自动滚入）
    /// 1. 今日起始可用池 = 本月弹性预算 - 今日之前的已发生弹性支出 = remainingThisMonth + todayFlexibleSpend
    /// 2. 今日基准额度 todayAllowance = max(0, poolStartOfToday) / daysLeft
    /// 3. 今日剩余可安心花 safeToSpendToday = max(0, todayAllowance - todayFlexibleSpend)
    ///    - 当今日有新增支出时，todayFlexibleSpend 增加，safeToSpendToday 精确按该金额等额扣减；
    ///    - 当今日花费超过 todayAllowance 时，safeToSpendToday 为 0，标记今日超支并均摊到后续天数；
    ///    - 昨天未花完的额度自然保留在可用池中，由 daysLeft 均摊体现在 todayAllowance 中，并单独计算 savedYesterday 提供正向激励。
    public static func compute(
        input: SafeToSpendInput,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> SafeToSpendResult {
        let isEnabled = input.monthlyBudget > 0
        let disposable = max(0, input.monthlyBudget - input.fixedMonthlyTotal)

        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let dayOfMonth = components.day ?? 1
        let daysLeft = max(1, daysInMonth - dayOfMonth + 1)

        let remaining = disposable - input.flexibleSpentThisMonth

        // 1. 今日早晨起始时的可用池（加回今日已花，还原今日 00:00 的池子）
        let poolStartOfToday = max(0, remaining + input.todayFlexibleSpend)

        // 2. 统计从今天到月底剩余天数中工作日与周末分布
        let todayWeekday = calendar.component(.weekday, from: now) // 1=周日, 7=周六
        let isTodayWeekend = (todayWeekday == 1 || todayWeekday == 7)

        var remainingWorkdays = 0
        var remainingWeekendDays = 0
        for offset in 0..<daysLeft {
            if let targetDate = calendar.date(byAdding: .day, value: offset, to: now) {
                let w = calendar.component(.weekday, from: targetDate)
                if w == 1 || w == 7 {
                    remainingWeekendDays += 1
                } else {
                    remainingWorkdays += 1
                }
            }
        }

        let todayAllowance: Double
        let workdayAllowance: Double
        let weekendAllowance: Double

        if input.rhythmMode == .weekendLeisure && poolStartOfToday > 0 {
            // 周末聚餐与娱乐消费权重系数设为 1.8x
            let weekendMultiplier = 1.8
            let totalWeightedUnits = Double(remainingWorkdays) + Double(remainingWeekendDays) * weekendMultiplier
            if totalWeightedUnits > 0 {
                workdayAllowance = poolStartOfToday / totalWeightedUnits
                weekendAllowance = workdayAllowance * weekendMultiplier
            } else {
                workdayAllowance = poolStartOfToday / Double(daysLeft)
                weekendAllowance = workdayAllowance
            }
            todayAllowance = isTodayWeekend ? weekendAllowance : workdayAllowance
        } else {
            todayAllowance = Double(daysLeft) > 0 ? (poolStartOfToday / Double(daysLeft)) : 0
            workdayAllowance = todayAllowance
            weekendAllowance = todayAllowance
        }

        // 3. 今日还可以安心花金额：随今日新增记账实时等额递减
        let safeToday = max(0, todayAllowance - input.todayFlexibleSpend)
        let isTodayOverspent = input.todayFlexibleSpend > todayAllowance
        let todayOverspentAmount = max(0, input.todayFlexibleSpend - todayAllowance)
        let todaySpentRatio = todayAllowance > 0
            ? input.todayFlexibleSpend / todayAllowance
            : (input.todayFlexibleSpend > 0 ? 1.0 : 0.0)

        // 4. 昨日节余滚入计算
        let remainingBeforeYesterday = remaining + input.todayFlexibleSpend + input.yesterdayFlexibleSpend
        let yesterdayAllowance = max(0, remainingBeforeYesterday) / Double(daysLeft + 1)
        let savedYesterday = dayOfMonth >= 2 ? max(0, yesterdayAllowance - input.yesterdayFlexibleSpend) : 0

        // 5. 节奏建议与蓄水池激励文案
        let rhythmAdviceText: String?
        if input.rhythmMode == .weekendLeisure && isEnabled {
            if isTodayWeekend {
                if input.weekdaySavedSoFarThisWeek >= 10 {
                    rhythmAdviceText = "🎉 周末充裕池已激活！本周工作日已蓄水 ¥\(Int(input.weekdaySavedSoFarThisWeek.rounded()))，周末额度 ¥\(Int(weekendAllowance.rounded()))/天，尽情放松！"
                } else {
                    rhythmAdviceText = "🎉 周末休闲模式：安心花基准已提升至 ¥\(Int(weekendAllowance.rounded()))/天，放松享受聚餐与娱乐！"
                }
            } else if todayWeekday == 6 { // 周五
                let hour = calendar.component(.hour, from: now)
                if hour >= 16 {
                    rhythmAdviceText = "🌟 周五傍晚蓄水成功！本周工作日已为周末聚餐蓄水，周末额度约 ¥\(Int(weekendAllowance.rounded()))/天。"
                } else {
                    rhythmAdviceText = "💼 工作日轻量消费中：基准 ¥\(Int(workdayAllowance.rounded()))/天，省下的额度今晚自动注入周末聚餐池！"
                }
            } else {
                rhythmAdviceText = "💼 工作日蓄水节奏：基准 ¥\(Int(workdayAllowance.rounded()))/天，工作日省下的额度将自动滚入周末池。"
            }
        } else {
            rhythmAdviceText = nil
        }

        return SafeToSpendResult(
            isEnabled: isEnabled,
            disposableBudget: disposable,
            remainingThisMonth: remaining,
            daysLeft: daysLeft,
            daysInMonth: daysInMonth,
            todayAllowance: todayAllowance,
            todayFlexibleSpend: input.todayFlexibleSpend,
            safeToSpendToday: safeToday,
            isTodayOverspent: isTodayOverspent,
            todayOverspentAmount: todayOverspentAmount,
            todaySpentRatio: todaySpentRatio,
            savedYesterday: savedYesterday,
            isOverBudget: remaining < 0,
            spentRatio: disposable > 0 ? input.flexibleSpentThisMonth / disposable : 1,
            rhythmMode: input.rhythmMode,
            isWeekend: isTodayWeekend,
            workdayAllowance: workdayAllowance,
            weekendAllowance: weekendAllowance,
            weekendReservoirTotal: input.weekdaySavedSoFarThisWeek,
            rhythmAdviceText: rhythmAdviceText
        )
    }
}
