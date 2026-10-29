import Foundation

// MARK: - 睡前提醒时间的计算规则（纯逻辑下沉 Core，可单测）

/// 计划输出的结局。
public enum SleepPlanOutcome: String, Equatable, Sendable {
    /// T_fire 在未来：按点发一条通知
    case scheduled
    /// T_fire ≤ now < T_bed：直接在「今晚睡眠」卡展示，**不发通知**（发了也是前台静默，还可能重复）
    case immediate
    /// 已过就寝点 / 基准越界：当晚不再安排提醒
    case skipped
}

/// 推荐结论的依据（与产生数值的同一组输入同源生成，杜绝文案与实际时间不符）。
public enum SleepPlanReason: Equatable, Sendable {
    /// 基准 = 习惯中位（w = 1）
    case habitAnchor(offset: Int)
    /// 基准 = 习惯与期望的加权混合（w < 1）
    case blendedAnchor(habitOffset: Int, desiredOffset: Int, habitWeight: Double)
    /// 基准 = 用户填写的期望就寝时间（无习惯样本）
    case desiredAnchor(offset: Int)
    /// 基准 = 默认 23:00（什么数据都没有）
    case defaultAnchor
    /// 样本偏少，基准可信度有限
    case weakPrior(sampleCount: Int)
    /// 睡眠债修正：近 7 夜总睡眠比目标欠 debtMinutes，时刻提前 adjustment 分钟
    case sleepDebt(debtMinutes: Int, adjustment: Int)
    /// 被「期望就寝时间 ±60min」夹住
    case clampedByDesired
    /// 被全局合理区间 [21:30, 01:30] 夹住
    case clampedByRange
    /// 基准本身落在提醒范围外（夜班、极晚睡）→ 不静默改写，直接跳过
    case outOfRange(baselineOffset: Int)
    /// T_fire 已过但未到就寝点
    case immediateNow
    /// 已过就寝点
    case pastBedtime
}

/// 睡眠计划：一晚的建议就寝时刻与提醒时刻。
public struct SleepPlan: Equatable, Sendable {
    public let nightKey: Date
    public let outcome: SleepPlanOutcome
    /// 建议就寝 offset（距该夜 12:00 的分钟数）；outcome == .skipped 时为 nil
    public let bedtimeOffset: Int?
    /// 提醒 offset；outcome != .scheduled 时为 nil
    public let fireOffset: Int?
    public let bedtime: Date?
    public let fireAt: Date?
    /// 基准 offset（= anchor：习惯与期望加权后的锚点）
    public let baselineOffset: Int
    /// baselineOffset − bedtimeOffset 的**真实**分钟数（正 = 比基准提前；文案唯一数据源）
    public let shiftMinutes: Int
    /// 实际参与中位数计算的样本组大小（桶回退到混合时是混合组的 n）
    public let effectiveSampleCount: Int
    /// 习惯中位（无样本时 nil）——与 baselineOffset 区分：w < 1 时 anchor ≠ habit
    public let habitOffset: Int?
    public let reasons: [SleepPlanReason]
    public let confidence: SleepPlanConfidence

    public enum SleepPlanConfidence: String, Equatable, Sendable {
        case strong        // n_eff ≥ 7
        case weakPrior     // 0 < n_eff < 7 或仅期望
        case defaultFallback // 无任何依据
    }
}

/// 全部规则的入口。上下文形参（now / calendar）必须真用——禁用 isDateInToday 等墙上时钟 API。
public enum SleepReminderPlanner {

    /// 全局合理提醒范围：21:30–次日 01:30（offset 570–810）
    public static let minBedtimeOffset = 570
    public static let maxBedtimeOffset = 810
    /// 漂移硬边界：期望就寝时间 ±60min（防锚点被提醒自身单向带偏）
    public static let desiredBand = 60
    /// 单晚修正幅度封顶（相对 anchor）
    public static let maxShift = 45

    // MARK: 输入

    public struct Input: Equatable, Sendable {
        public var now: Date
        public var calendar: Calendar
        /// 目标夜（兜底层预注册未来夜时传未来夜的 nightKey）
        public var nightKey: Date
        /// 近 28 夜样本（顺序无关，内部按 nightKey 排序）
        public var samples: [SleepNightSample]
        /// 期望就寝时间（引导页填写，或攒够 14 夜后冻结的 pseudo-desired）
        public var desiredBedtimeOffset: Int?
        public var sleepGoalMinutes: Int
        public var windDownMinutes: Int

        public init(
            now: Date,
            calendar: Calendar,
            nightKey: Date,
            samples: [SleepNightSample],
            desiredBedtimeOffset: Int?,
            sleepGoalMinutes: Int = 420,
            windDownMinutes: Int = 30
        ) {
            self.now = now
            self.calendar = calendar
            self.nightKey = nightKey
            self.samples = samples
            self.desiredBedtimeOffset = desiredBedtimeOffset
            self.sleepGoalMinutes = sleepGoalMinutes
            self.windDownMinutes = windDownMinutes
        }
    }

    // MARK: 主入口

    public static func plan(_ input: Input) -> SleepPlan {
        let calendar = input.calendar
        let nightKey = calendar.startOfDay(for: input.nightKey)
        let sorted = input.samples
            .map { (key: calendar.startOfDay(for: $0.nightKey), sample: $0) }
            .filter { $0.key < nightKey }   // 目标夜还没睡，不参与
            .sorted { $0.key < $1.key }
        let samples = sorted.map(\.sample)

        // ① 习惯中位（按夜归属日分桶：周五/周六夜为周末桶）
        let bucket = samples.filter {
            isWeekendNight($0.nightKey, calendar: calendar) == isWeekendNight(nightKey, calendar: calendar)
        }
        // n_bucket < 3 → 回退混合桶；n_effective = 实际参与中位数的那组的 n
        let usedGroup: [SleepNightSample] = bucket.count >= 3 ? bucket : samples
        let habitOffset: Int? = usedGroup.count >= 3
            ? round5(median(usedGroup.map(\.onsetOffset)))
            : nil
        let nEff = habitOffset != nil ? usedGroup.count : 0

        // ② 锚点（冷启动 n/7 渐变 + 防漂移）
        let desired = input.desiredBedtimeOffset.flatMap { (0..<1440).contains($0) ? $0 : nil }
        let baselineOffset: Int
        var reasons: [SleepPlanReason] = []
        var habitWeight = 1.0

        switch (habitOffset, desired) {
        case (let habit?, let desire?):
            habitWeight = min(1.0, Double(nEff) / 7.0)
            baselineOffset = round5(habitWeight * Double(habit) + (1 - habitWeight) * Double(desire))
            if habitWeight >= 1.0 {
                // 样本充足：anchor 就是习惯本身（期望只作 ±60 漂移边界），文案参照物应称「习惯」
                reasons.append(.habitAnchor(offset: habit))
            } else {
                reasons.append(.blendedAnchor(habitOffset: habit, desiredOffset: desire, habitWeight: habitWeight))
                reasons.append(.weakPrior(sampleCount: nEff))
            }
        case (let habit?, nil):
            baselineOffset = habit
            reasons.append(.habitAnchor(offset: habit))
            if nEff < 7 {
                reasons.append(.weakPrior(sampleCount: nEff))
            }
        case (nil, let desire?):
            baselineOffset = desire
            reasons.append(.desiredAnchor(offset: desire))
            reasons.append(.weakPrior(sampleCount: 0))
        case (nil, nil):
            baselineOffset = 660 // 默认 23:00
            reasons.append(.defaultAnchor)
        }

        // 基准本身越界（夜班 / 极晚睡）→ 不静默改写，跳过。
        // 判定对象：有习惯看**习惯本身**——混合锚点可能落回区间内，
        // 但对夜班族来说那已是「与习惯无关的时刻」；无习惯才看期望/默认。
        let rangeProbe = habitOffset ?? desired ?? 660
        if rangeProbe < minBedtimeOffset || rangeProbe > maxBedtimeOffset {
            reasons.append(.outOfRange(baselineOffset: rangeProbe))
            return SleepPlan(
                nightKey: nightKey,
                outcome: .skipped,
                bedtimeOffset: nil,
                fireOffset: nil,
                bedtime: nil,
                fireAt: nil,
                baselineOffset: baselineOffset,
                shiftMinutes: 0,
                effectiveSampleCount: nEff,
                habitOffset: habitOffset,
                reasons: reasons,
                confidence: confidence(nEff: nEff, hasHabit: habitOffset != nil, hasDesired: desired != nil)
            )
        }

        // ③ 修正（单向只提前；energyAdj 在 P1 恒为 0，见 energyAdjustment）
        let debt = sleepDebtMinutes(samples: samples, goalMinutes: input.sleepGoalMinutes)
        let debtAdj = debtAdjustment(debtMinutes: debt)
        if debtAdj != 0 {
            reasons.append(.sleepDebt(debtMinutes: debt, adjustment: debtAdj))
        }
        let energyAdj = energyAdjustment(daytimeEnergyScore: nil) // P1 不接白天分
        let totalAdj = max(-maxShift, min(0, debtAdj + energyAdj))

        // ④ 三道 clamp
        var bedtime = baselineOffset + totalAdj
        bedtime = min(max(bedtime, baselineOffset - maxShift), baselineOffset + maxShift)
        if let desire = desired {
            let clamped = min(max(bedtime, desire - desiredBand), desire + desiredBand)
            if clamped != bedtime {
                bedtime = clamped
                reasons.append(.clampedByDesired)
            }
        }
        do {
            let clamped = min(max(bedtime, minBedtimeOffset), maxBedtimeOffset)
            if clamped != bedtime {
                bedtime = clamped
                reasons.append(.clampedByRange)
            }
        }
        let fire = bedtime - input.windDownMinutes

        guard let bedtimeDate = SleepNightNormalizer.date(nightKey: nightKey, offset: bedtime, calendar: calendar),
              let fireDate = SleepNightNormalizer.date(nightKey: nightKey, offset: fire, calendar: calendar) else {
            reasons.append(.outOfRange(baselineOffset: baselineOffset))
            return SleepPlan(
                nightKey: nightKey, outcome: .skipped,
                bedtimeOffset: nil, fireOffset: nil, bedtime: nil, fireAt: nil,
                baselineOffset: baselineOffset, shiftMinutes: 0,
                effectiveSampleCount: nEff, habitOffset: habitOffset,
                reasons: reasons,
                confidence: confidence(nEff: nEff, hasHabit: habitOffset != nil, hasDesired: desired != nil)
            )
        }

        // ⑤ 迟到策略（每夜最多一次提醒的前提；重复进前台的去重由 Policy 管）
        let outcome: SleepPlanOutcome
        var fireOffsetOut: Int? = fire
        var fireAtOut: Date? = fireDate
        if input.now >= bedtimeDate {
            outcome = .skipped
            reasons.append(.pastBedtime)
            fireOffsetOut = nil
            fireAtOut = nil
        } else if input.now >= fireDate {
            outcome = .immediate
            reasons.append(.immediateNow)
            fireOffsetOut = nil
            fireAtOut = nil
        } else {
            outcome = .scheduled
        }

        return SleepPlan(
            nightKey: nightKey,
            outcome: outcome,
            bedtimeOffset: bedtime,
            fireOffset: fireOffsetOut,
            bedtime: bedtimeDate,
            fireAt: fireAtOut,
            baselineOffset: baselineOffset,
            shiftMinutes: baselineOffset - bedtime,
            effectiveSampleCount: nEff,
            habitOffset: habitOffset,
            reasons: reasons,
            confidence: confidence(nEff: nEff, hasHabit: habitOffset != nil, hasDesired: desired != nil)
        )
    }

    // MARK: 分件规则

    /// 近 7 夜**总**睡眠（asleepMinutes，不是最长段）的缺口分钟数。
    /// 有效夜 < 3 → 返回 0（诚实降级，不猜）。
    public static func sleepDebtMinutes(samples: [SleepNightSample], goalMinutes: Int) -> Int {
        let recent = samples.sorted { $0.nightKey < $1.nightKey }.suffix(7)
        guard recent.count >= 3 else { return 0 }
        let mean = Double(recent.map(\.asleepMinutes).reduce(0, +)) / Double(recent.count)
        return max(0, Int((Double(goalMinutes) - mean).rounded()))
    }

    /// 睡眠债 → 提前分钟数。线性：每欠 1 分钟提前 0.5 分钟，round5，封顶 45。
    /// （48 欠账 → −25；100 欠账 → −45。阶梯口径会得 −15，是错的。）
    public static func debtAdjustment(debtMinutes: Int) -> Int {
        guard debtMinutes > 0 else { return 0 }
        return -min(maxShift, round5(Double(debtMinutes) * 0.5))
    }

    /// 白天精力修正。**P1 恒为 0**：activityAdj 已移出公式（证据弱），
    /// 且拆掉 sleepDelta 重标定后的阈值未校准、白天分项在晚间窗口是残缺值。
    /// 校准任务完成前不得改为非 0；nil（数据缺失）口径也是 0。
    public static func energyAdjustment(daytimeEnergyScore: Double?) -> Int {
        _ = daytimeEnergyScore
        return 0
    }

    /// 攒够 14 夜且从未填写期望时，把当前 habit 冻结为 pseudo-desired（防锚点单向漂移）。
    public static func shouldFreezePseudoDesired(hasDesired: Bool, sampleCount: Int) -> Bool {
        !hasDesired && sampleCount >= 14
    }

    /// 通知 identifier：夜归属日编码进 ID，凌晨重算只覆盖本夜。
    public static func notificationID(nightKey: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: nightKey)
        return String(format: "sleep-bedtime-%04d%02d%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    // MARK: 小工具

    /// 夜归属日是否周末桶（周五/周六夜）。调休/法定假日不识别——已知限制，文案不得宣称「已区分工作日」。
    public static func isWeekendNight(_ nightKey: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: nightKey) // 1=周日 … 6=周五, 7=周六
        return weekday == 6 || weekday == 7
    }

    static func median(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[mid]) }
        return Double(sorted[mid - 1] + sorted[mid]) / 2.0
    }

    static func round5(_ x: Double) -> Int {
        Int((x / 5.0).rounded()) * 5
    }

    private static func confidence(nEff: Int, hasHabit: Bool, hasDesired: Bool) -> SleepPlan.SleepPlanConfidence {
        if !hasHabit && !hasDesired { return .defaultFallback }
        if hasHabit && nEff >= 7 { return .strong }
        return .weakPrior
    }
}

// MARK: - 文案（参照物统一叫「基准」，分钟数一律来自 shiftMinutes）

public enum SleepPlanCopy {

    /// 基准标签：明确它等于 anchor（混合时不是单纯习惯）。
    public static func baselineLabel(for plan: SleepPlan) -> String {
        if plan.reasons.contains(where: {
            if case .blendedAnchor = $0 { return true }
            return false
        }) {
            return "作息基准"
        }
        if plan.reasons.contains(where: {
            if case .habitAnchor = $0 { return true }
            return false
        }) {
            return "你的习惯"
        }
        if plan.reasons.contains(where: {
            if case .desiredAnchor = $0 { return true }
            return false
        }) {
            return "你填写的就寝时间"
        }
        return "默认时间"
    }

    /// 通知标题。
    public static func headline(for plan: SleepPlan) -> String {
        switch plan.outcome {
        case .skipped:
            if plan.reasons.contains(where: {
                if case .outOfRange = $0 { return true }
                return false
            }) {
                return "你的作息超出提醒范围"
            }
            return "今晚已过就寝时间"
        case .immediate, .scheduled:
            let time = SleepNightNormalizer.hourMinute(offset: plan.bedtimeOffset ?? plan.baselineOffset)
            return "该准备睡了 · 建议 \(time) 入睡"
        }
    }

    /// 通知正文 / 卡片说明。分钟数只引用 shiftMinutes，禁止手写概数。
    public static func body(for plan: SleepPlan) -> String {
        switch plan.outcome {
        case .skipped:
            if plan.reasons.contains(where: {
                if case .outOfRange = $0 { return true }
                return false
            }) {
                return "你的作息超出提醒范围（21:30–01:30），暂不安排晚间提醒。"
            }
            return "已过就寝时间，今晚不再提醒。"
        case .immediate, .scheduled:
            let label = baselineLabel(for: plan)
            let baseTime = SleepNightNormalizer.hourMinute(offset: plan.baselineOffset)
            let shift = plan.shiftMinutes
            let shiftText: String
            if shift > 0 {
                shiftText = "比\(label)（\(baseTime)）提前 \(shift) 分钟"
            } else if shift < 0 {
                shiftText = "比\(label)（\(baseTime)）延后 \(-shift) 分钟"
            } else {
                shiftText = "与\(label)（\(baseTime)）一致"
            }
            var parts = [shiftText]
            for reason in plan.reasons {
                if case .sleepDebt(let debt, _) = reason {
                    parts.append("近一周总睡眠比目标少 \(debt) 分钟")
                }
                if case .clampedByDesired = reason {
                    parts.append("已按你的期望就寝时间调整")
                }
                if case .clampedByRange = reason {
                    parts.append("已调整到合理作息范围")
                }
                if case .weakPrior = reason, plan.confidence == .weakPrior {
                    parts.append("样本较少，按初步习惯")
                }
                if case .defaultAnchor = reason {
                    parts.append("暂按默认时间，佩戴设备入睡后将自动学习你的作息")
                }
            }
            return parts.joined(separator: "，") + "。"
        }
    }

    /// 「为什么是这个时间」展开明细（健康页卡片用）。每条一行，
    /// 分钟数只引用 plan 的真实字段，与 body 同源，禁止手写概数。
    public static func reasonLines(for plan: SleepPlan) -> [String] {
        var lines: [String] = []
        for reason in plan.reasons {
            switch reason {
            case .habitAnchor(let offset):
                lines.append("习惯就寝时间 \(SleepNightNormalizer.hourMinute(offset: offset))：基于历史入睡记录的中位数")
            case .blendedAnchor(let habit, let desired, let weight):
                let pct = Int((weight * 100).rounded())
                lines.append("作息基准 = 习惯 \(SleepNightNormalizer.hourMinute(offset: habit)) 与期望 \(SleepNightNormalizer.hourMinute(offset: desired)) 加权（习惯占 \(pct)%）")
            case .desiredAnchor(let offset):
                lines.append("期望就寝时间 \(SleepNightNormalizer.hourMinute(offset: offset))：你填写的长期锚点")
            case .defaultAnchor:
                lines.append("暂无入睡记录，默认 23:00；佩戴设备入睡后将自动学习你的作息")
            case .weakPrior(let sampleCount):
                lines.append("历史样本仅 \(sampleCount) 夜，推荐可信度有限")
            case .sleepDebt(let debtMinutes, let adjustment):
                lines.append("近 7 夜总睡眠比目标少 \(debtMinutes) 分钟 → 就寝提前 \(-adjustment) 分钟")
            case .clampedByDesired:
                lines.append("已贴到期望就寝时间 ±\(SleepReminderPlanner.desiredBand) 分钟边界（防止提醒把作息越带越偏）")
            case .clampedByRange:
                lines.append("已贴到合理作息范围边界（21:30–01:30）")
            case .outOfRange(let baselineOffset):
                lines.append("作息基准 \(SleepNightNormalizer.hourMinute(offset: baselineOffset)) 超出提醒范围 21:30–01:30，今晚不安排提醒")
            case .immediateNow:
                lines.append("提醒时刻已过，建议现在就准备就寝")
            case .pastBedtime:
                lines.append("已过建议就寝时刻")
            }
        }
        return lines
    }

    /// 通知权限被拒时的降级文案（不得显示「已为你安排今晚提醒」）。
    public static func notificationDeniedText() -> String {
        "通知权限未开启，无法定时提醒。请到系统设置 › 通知中开启。"
    }
}
