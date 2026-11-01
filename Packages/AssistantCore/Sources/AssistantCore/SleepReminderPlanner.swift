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

/// 季节节律（顺应四季四时规律调节睡眠）
public enum Season: String, Equatable, Sendable, CaseIterable {
    case spring = "春季"
    case summer = "夏季"
    case autumn = "秋季"
    case winter = "冬季"

    public static func current(for date: Date, calendar: Calendar = .current) -> Season {
        let month = calendar.component(.month, from: date)
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }
}

/// 睡前提醒的多维情景感知因素（运动、饮食、天气、温度、季节、药物、活力指数、屏幕时间等）
public struct SleepContextFactors: Equatable, Sendable {
    /// 今日运动总时长（分钟）
    public var workoutMinutes: Double?
    /// 今日活动能量消耗（千卡）
    public var activeEnergyBurned: Double?
    /// 最近一次运动结束时间（晚间剧烈运动需延长放松缓冲）
    public var lastWorkoutEndTime: Date?

    /// 今日饮食估算摄入总热量（千卡）
    public var foodCalories: Double?
    /// 最近一次进餐时间（夜宵或晚间进餐）
    public var lastFoodIntakeTime: Date?
    /// 是否午后或晚间摄入了咖啡因/刺激性饮品（咖啡、奶茶、浓茶、功能饮料）
    public var hasLateCaffeineIntake: Bool

    /// 天气描述（如 "晴", "阴", "小雨", "雷阵雨"）
    public var weatherDescription: String?
    /// 是否降雨或降雪
    public var isRainyOrSnowy: Bool
    /// 当前或晚间温度（℃）
    public var temperatureCelsius: Double?
    /// 是否存在气温骤降预警（>= 6℃）
    public var isTempDropAlert: Bool

    /// 当前季节（默认可自动推断）
    public var season: Season?

    /// 待服用的睡前药物名称列表
    public var pendingBedtimeMedications: [String]

    /// 身体活力指数（0~100）
    public var vitalityScore: Double?
    /// 活力级别
    public var vitalityLevel: VitalityLevel?

    /// 今日手机屏幕使用时长（分钟）
    public var screenTimeMinutes: Int?

    /// 心率变异性 HRV（SDNN 毫秒）
    public var hrvSDNN: Double?

    public init(
        workoutMinutes: Double? = nil,
        activeEnergyBurned: Double? = nil,
        lastWorkoutEndTime: Date? = nil,
        foodCalories: Double? = nil,
        lastFoodIntakeTime: Date? = nil,
        hasLateCaffeineIntake: Bool = false,
        weatherDescription: String? = nil,
        isRainyOrSnowy: Bool = false,
        temperatureCelsius: Double? = nil,
        isTempDropAlert: Bool = false,
        season: Season? = nil,
        pendingBedtimeMedications: [String] = [],
        vitalityScore: Double? = nil,
        vitalityLevel: VitalityLevel? = nil,
        screenTimeMinutes: Int? = nil,
        hrvSDNN: Double? = nil
    ) {
        self.workoutMinutes = workoutMinutes
        self.activeEnergyBurned = activeEnergyBurned
        self.lastWorkoutEndTime = lastWorkoutEndTime
        self.foodCalories = foodCalories
        self.lastFoodIntakeTime = lastFoodIntakeTime
        self.hasLateCaffeineIntake = hasLateCaffeineIntake
        self.weatherDescription = weatherDescription
        self.isRainyOrSnowy = isRainyOrSnowy
        self.temperatureCelsius = temperatureCelsius
        self.isTempDropAlert = isTempDropAlert
        self.season = season
        self.pendingBedtimeMedications = pendingBedtimeMedications
        self.vitalityScore = vitalityScore
        self.vitalityLevel = vitalityLevel
        self.screenTimeMinutes = screenTimeMinutes
        self.hrvSDNN = hrvSDNN
    }
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
    /// 活力指数修正：活力低需提前就寝补充恢复
    case vitalityAdjustment(level: VitalityLevel, score: Double?, minutes: Int, detail: String)
    /// 运动情况修正：高运动量需提前就寝；晚间剧烈运动需延长缓冲
    case exerciseAdjustment(workoutMinutes: Double?, activeCalories: Double?, minutes: Int, detail: String)
    case lateWorkoutWarning(windDownExtension: Int, detail: String)
    /// 饮食与摄入修正：夜宵/晚进餐需消化缓冲；咖啡因建议远离屏幕
    case foodIntakeAdjustment(detail: String)
    case lateCaffeineWarning(detail: String)
    /// 天气与气温修正：低温/骤降建议提前保暖；舒适雨声助眠
    case weatherAdjustment(detail: String)
    /// 季节作息节律：冬季早卧晚起，夏季顺应昼长
    case seasonAdjustment(season: Season, minutes: Int, detail: String)
    /// 手机屏幕使用时间过长：蓝光抑制褪黑素，延长准备缓冲
    case screenTimeWarning(minutes: Int, windDownExtension: Int, detail: String)
    /// 睡前待服药物提醒
    case pendingMedicationReminder(medNames: [String])
    /// 自主神经张力 / HRV 偏低恢复提醒
    case hrvStressAdjustment(minutes: Int, detail: String)
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
    /// 多维感知上下文因素
    public let contextFactors: SleepContextFactors?
    /// 实际准备就寝缓冲分钟数（含屏幕、咖啡、晚运动等动态延长）
    public let effectiveWindDownMinutes: Int

    public init(
        nightKey: Date,
        outcome: SleepPlanOutcome,
        bedtimeOffset: Int?,
        fireOffset: Int?,
        bedtime: Date?,
        fireAt: Date?,
        baselineOffset: Int,
        shiftMinutes: Int,
        effectiveSampleCount: Int,
        habitOffset: Int?,
        reasons: [SleepPlanReason],
        confidence: SleepPlanConfidence,
        contextFactors: SleepContextFactors? = nil,
        effectiveWindDownMinutes: Int = 30
    ) {
        self.nightKey = nightKey
        self.outcome = outcome
        self.bedtimeOffset = bedtimeOffset
        self.fireOffset = fireOffset
        self.bedtime = bedtime
        self.fireAt = fireAt
        self.baselineOffset = baselineOffset
        self.shiftMinutes = shiftMinutes
        self.effectiveSampleCount = effectiveSampleCount
        self.habitOffset = habitOffset
        self.reasons = reasons
        self.confidence = confidence
        self.contextFactors = contextFactors
        self.effectiveWindDownMinutes = effectiveWindDownMinutes
    }

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
        /// 多维情景感知因素（运动、饮食、天气、温度、季节、药物、活力、屏幕时间等）
        public var contextFactors: SleepContextFactors?

        public init(
            now: Date,
            calendar: Calendar,
            nightKey: Date,
            samples: [SleepNightSample],
            desiredBedtimeOffset: Int?,
            sleepGoalMinutes: Int = 420,
            windDownMinutes: Int = 30,
            contextFactors: SleepContextFactors? = nil
        ) {
            self.now = now
            self.calendar = calendar
            self.nightKey = nightKey
            self.samples = samples
            self.desiredBedtimeOffset = desiredBedtimeOffset
            self.sleepGoalMinutes = sleepGoalMinutes
            self.windDownMinutes = windDownMinutes
            self.contextFactors = contextFactors
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
                confidence: confidence(nEff: nEff, hasHabit: habitOffset != nil, hasDesired: desired != nil),
                contextFactors: input.contextFactors,
                effectiveWindDownMinutes: input.windDownMinutes
            )
        }

        // ③ 修正（单向主要提前；结合睡眠债、活力指数、运动量、天气气温、季节等）
        let debt = sleepDebtMinutes(samples: samples, goalMinutes: input.sleepGoalMinutes)
        let debtAdj = debtAdjustment(debtMinutes: debt)
        if debtAdj != 0 {
            reasons.append(.sleepDebt(debtMinutes: debt, adjustment: debtAdj))
        }

        var vitalityAdj = 0
        var exerciseAdj = 0
        var seasonAdj = 0
        var weatherAdj = 0
        var foodAdj = 0
        var effectiveWindDown = input.windDownMinutes

        if let factors = input.contextFactors {
            // 活力指数
            if let level = factors.vitalityLevel {
                switch level {
                case .exhausted:
                    vitalityAdj = -20
                    reasons.append(.vitalityAdjustment(level: .exhausted, score: factors.vitalityScore, minutes: -20, detail: "身体处于疲劳待恢复状态，建议提前入睡促进深层细胞修复"))
                case .low:
                    vitalityAdj = -10
                    reasons.append(.vitalityAdjustment(level: .low, score: factors.vitalityScore, minutes: -10, detail: "今日活力偏低，建议适当早睡蓄力"))
                case .peak, .good:
                    reasons.append(.vitalityAdjustment(level: level, score: factors.vitalityScore, minutes: 0, detail: "活力状态良好，保持规律作息即可"))
                case .balanced:
                    break
                }
            } else if let score = factors.vitalityScore {
                if score < 40 {
                    vitalityAdj = -20
                    reasons.append(.vitalityAdjustment(level: .exhausted, score: score, minutes: -20, detail: "身体处于疲劳待恢复状态（活力分 \(Int(score.rounded()))），建议提前入睡"))
                } else if score < 55 {
                    vitalityAdj = -10
                    reasons.append(.vitalityAdjustment(level: .low, score: score, minutes: -10, detail: "今日活力偏低（活力分 \(Int(score.rounded()))），建议适当早睡"))
                }
            }

            // 运动情况
            let workoutMin = factors.workoutMinutes ?? 0
            let activeCal = factors.activeEnergyBurned ?? 0
            if workoutMin >= 45 || activeCal >= 500 {
                exerciseAdj = -10
                reasons.append(.exerciseAdjustment(
                    workoutMinutes: factors.workoutMinutes,
                    activeCalories: factors.activeEnergyBurned,
                    minutes: -10,
                    detail: "今日运动量充沛（\(Int(workoutMin)) 分钟 / \(Int(activeCal)) kcal），适当早睡利于机能超量恢复"
                ))
            }
            if let lastWorkout = factors.lastWorkoutEndTime,
               let baseBedtimeDate = SleepNightNormalizer.date(nightKey: nightKey, offset: baselineOffset, calendar: calendar),
               lastWorkout.timeIntervalSince(baseBedtimeDate) > -2.5 * 3600 && lastWorkout <= input.now {
                effectiveWindDown += 15
                reasons.append(.lateWorkoutWarning(windDownExtension: 15, detail: "晚间运动结束较晚，交感神经仍处于兴奋期，建议延长睡前准备缓冲放松身心"))
            }

            // 季节节律
            let season = factors.season ?? Season.current(for: nightKey, calendar: calendar)
            if season == .winter {
                seasonAdj = -10
                reasons.append(.seasonAdjustment(season: .winter, minutes: -10, detail: "冬季遵循「早卧晚起」养生节律，顺应天时早睡蓄阳"))
            } else if season == .summer {
                reasons.append(.seasonAdjustment(season: .summer, minutes: 0, detail: "夏季昼长夜短，保持规律作息即可"))
            }

            // 天气与温度
            if factors.isTempDropAlert || (factors.temperatureCelsius != nil && factors.temperatureCelsius! < 8) {
                weatherAdj = -5
                let desc = factors.isTempDropAlert
                    ? "气象监测有降温突变，建议提前钻入温暖被窝并调节室温"
                    : "夜间气温较低（\(Int(factors.temperatureCelsius?.rounded() ?? 0))°C），建议做好保暖提前休息"
                reasons.append(.weatherAdjustment(detail: desc))
            } else if let temp = factors.temperatureCelsius, temp > 28 {
                effectiveWindDown += 10
                reasons.append(.weatherAdjustment(detail: "夜间闷热（\(Int(temp.rounded()))°C），建议保持卧室凉爽通风（18~22°C）助眠"))
            } else if factors.isRainyOrSnowy {
                reasons.append(.weatherAdjustment(detail: "伴随雨雪天气，环境舒适适宜早睡放松"))
            }

            // 饮食与摄入
            if let lastFood = factors.lastFoodIntakeTime,
               let baseBedtimeDate = SleepNightNormalizer.date(nightKey: nightKey, offset: baselineOffset, calendar: calendar),
               lastFood.timeIntervalSince(baseBedtimeDate) > -2.5 * 3600 && lastFood <= input.now {
                foodAdj = 5
                effectiveWindDown += 10
                reasons.append(.foodIntakeAdjustment(detail: "就餐距离就寝较近，预留消化缓冲避免胃肠负担与反流"))
            }
            if factors.hasLateCaffeineIntake {
                effectiveWindDown += 10
                reasons.append(.lateCaffeineWarning(detail: "午后摄入咖啡因类饮品，建议睡前提前远离屏幕并饮用温水"))
            }

            // 手机屏幕使用时间
            if let screenTime = factors.screenTimeMinutes, screenTime >= 240 {
                effectiveWindDown += 15
                let hrs = Double(screenTime) / 60.0
                reasons.append(.screenTimeWarning(
                    minutes: screenTime,
                    windDownExtension: 15,
                    detail: "今日屏幕使用达 \(String(format: "%.1f", hrs)) 小时，屏幕蓝光会抑制褪黑素释放，建议睡前 30 分钟放下手机"
                ))
            }

            // 药物待服提醒
            if !factors.pendingBedtimeMedications.isEmpty {
                effectiveWindDown += 5
                reasons.append(.pendingMedicationReminder(medNames: factors.pendingBedtimeMedications))
            }

            // 心率变异性 HRV
            if let hrv = factors.hrvSDNN, hrv < 30 {
                effectiveWindDown += 10
                reasons.append(.hrvStressAdjustment(minutes: 10, detail: "心率变异性(HRV)偏低（\(Int(hrv.rounded())) ms），提示自主神经偏紧张，建议配合深呼吸深层放松"))
            }
        }

        // 封顶缓冲时间（15 ~ 60 分钟）
        effectiveWindDown = min(60, max(15, effectiveWindDown))

        let rawShift = debtAdj + vitalityAdj + exerciseAdj + seasonAdj + weatherAdj + foodAdj
        let totalAdj = max(-maxShift, min(15, rawShift))

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
        let fire = bedtime - effectiveWindDown

        guard let bedtimeDate = SleepNightNormalizer.date(nightKey: nightKey, offset: bedtime, calendar: calendar),
              let fireDate = SleepNightNormalizer.date(nightKey: nightKey, offset: fire, calendar: calendar) else {
            reasons.append(.outOfRange(baselineOffset: baselineOffset))
            return SleepPlan(
                nightKey: nightKey, outcome: .skipped,
                bedtimeOffset: nil, fireOffset: nil, bedtime: nil, fireAt: nil,
                baselineOffset: baselineOffset, shiftMinutes: 0,
                effectiveSampleCount: nEff, habitOffset: habitOffset,
                reasons: reasons,
                confidence: confidence(nEff: nEff, hasHabit: habitOffset != nil, hasDesired: desired != nil),
                contextFactors: input.contextFactors,
                effectiveWindDownMinutes: effectiveWindDown
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
            confidence: confidence(nEff: nEff, hasHabit: habitOffset != nil, hasDesired: desired != nil),
            contextFactors: input.contextFactors,
            effectiveWindDownMinutes: effectiveWindDown
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
                if case .vitalityAdjustment(let level, _, _, _) = reason {
                    if level == .exhausted || level == .low {
                        parts.append("今日\(level.rawValue)")
                    }
                }
                if case .exerciseAdjustment = reason {
                    parts.append("今日运动量充沛")
                }
                if case .seasonAdjustment(let s, let min, _) = reason, min < 0 {
                    parts.append("\(s.rawValue)顺应早卧")
                }
                if case .weatherAdjustment(let d) = reason, d.contains("降温") || d.contains("较低") {
                    parts.append("夜间气温较低")
                }
                if case .screenTimeWarning(let mins, _, _) = reason {
                    parts.append("屏幕使用 \(mins / 60) 小时建议早放下手机")
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
            var text = parts.joined(separator: "，") + "。"
            if let medReason = plan.reasons.first(where: {
                if case .pendingMedicationReminder = $0 { return true }
                return false
            }) {
                if case .pendingMedicationReminder(let meds) = medReason {
                    text += " ⚠️ 睡前记得服用：\(meds.joined(separator: "、"))。"
                }
            }
            return text
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
            case .vitalityAdjustment(_, _, _, let detail):
                lines.append("身体活力指数：\(detail)")
            case .exerciseAdjustment(_, _, _, let detail):
                lines.append("日间运动量：\(detail)")
            case .lateWorkoutWarning(_, let detail):
                lines.append("晚间运动缓冲：\(detail)")
            case .foodIntakeAdjustment(let detail):
                lines.append("就餐消化间隔：\(detail)")
            case .lateCaffeineWarning(let detail):
                lines.append("咖啡因影响：\(detail)")
            case .weatherAdjustment(let detail):
                lines.append("天气与气温环境：\(detail)")
            case .seasonAdjustment(_, _, let detail):
                lines.append("时令季节节律：\(detail)")
            case .screenTimeWarning(_, _, let detail):
                lines.append("屏幕使用时间：\(detail)")
            case .pendingMedicationReminder(let medNames):
                lines.append("睡前药物提醒：待服用 \(medNames.joined(separator: "、"))")
            case .hrvStressAdjustment(_, let detail):
                lines.append("心率变异性与压力：\(detail)")
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
