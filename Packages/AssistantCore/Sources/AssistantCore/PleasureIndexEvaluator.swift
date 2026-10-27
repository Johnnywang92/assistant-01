import Foundation

// MARK: - 压力状态与身心愉悦指数推断引擎（纯逻辑下沉 Core）
//
// 科学背景与生理学模型：
// 1. Russell 情绪环状模型（Circumplex Model of Affect）：
//    可穿戴生理指标（心率变异性 HRV、静息心率 RHR）直接反映的是机体自主神经系统（ANS）的唤醒度（Arousal）与交感/副交感张力。
//    HRV（SDNN/RMSSD）上升 + RHR 下降 = 副交感神经占优，身心处于低压力、高韧性、深层蓄力状态；
//    HRV 骤降 + RHR 偏高 = 交感神经兴奋或疲倦代偿，身心处于紧绷、应激或耗竭状态。
// 2. 睡眠与情绪修复模型（REM & Deep Sleep Recovery）：
//    REM（快速眼动）睡眠是夜间心理复位、情绪应激去敏化的黄金窗口；
//    Deep（深睡眠）则是身体组织修复与精力恢复的关键基础。
// 3. 个人基线动态标准化（Z-score Normalization）：
//    HRV 存在巨大的先天与年龄个体差异，必须依托个人 7~14 天滚动基线（Baseline Mean & Std）做标准化比对，
//    杜绝跨人使用绝对阈值带来的误判。

// MARK: - 愉悦状态与压力等级定义

/// 身心愉悦状态等级。
public enum PleasureState: String, Sendable, CaseIterable {
    /// 🌟 欣快充沛（85 ~ 100 分）
    case euphoric = "欣快充沛"
    /// 🌿 平和舒畅（70 ~ 84 分）
    case serene = "平和舒畅"
    /// ⚡️ 适度紧绷（50 ~ 69 分）
    case strained = "适度紧绷"
    /// 🍂 情绪耗竭（35 ~ 49 分）。
    /// 不叫「能量偏低」——那是 VitalityLevel.low 的文案，两卡并排时会撞名；
    /// 这一级描述的是情绪调节资源耗竭，与身体能量是不同维度。
    case fatigued = "情绪耗竭"
    /// 🌧️ 身心超载（< 35 分）
    case overloaded = "身心超载"

    /// 图标名（SF Symbols）
    public var icon: String {
        switch self {
        case .euphoric: return "sun.max.fill"
        case .serene: return "sparkles"
        case .strained: return "bolt.fill"
        case .fatigued: return "battery.25percent"
        case .overloaded: return "cloud.rain.fill"
        }
    }

    /// 标签徽章
    public var badge: String {
        switch self {
        case .euphoric: return "🌟 欣快充沛"
        case .serene: return "🌿 平和舒畅"
        case .strained: return "⚡️ 适度紧绷"
        case .fatigued: return "🍂 情绪耗竭"
        case .overloaded: return "🌧️ 身心超载"
        }
    }

    /// 状态解读
    public var description: String {
        switch self {
        case .euphoric:
            return "副交感调控极佳，心理弹性高，身心处于深度放松与充沛愉悦的黄金窗口。"
        case .serene:
            return "生理与情绪稳态良好，自律神经协调平衡，适宜专注与平稳推进日常。"
        case .strained:
            return "交感神经轻度唤醒，机体正在积极应对负荷，建议穿插深呼吸或微休息。"
        case .fatigued:
            return "睡眠或自律神经张力显现疲劳，身心耐受度下降，注意避免过度劳累。"
        case .overloaded:
            return "生理负荷明显超常，自律神经张力紧绷，建议即时停下脚步做深层休整。"
        }
    }
}

/// 压力负荷状态。
public enum StressLevel: String, Sendable, CaseIterable {
    /// 低压力（0 ~ 25 分）
    case low = "平静放松"
    /// 适度压力（26 ~ 50 分）
    case moderate = "适度良好"
    /// 中度负荷（51 ~ 75 分）
    case elevated = "负荷偏高"
    /// 极高负荷（76 ~ 100 分）
    case high = "高度紧绷"

    public var badge: String {
        switch self {
        case .low: return "🍃 平静放松"
        case .moderate: return "👍 适度良好"
        case .elevated: return "⚠️ 负荷偏高"
        case .high: return "🚨 高度紧绷"
        }
    }
}

/// 自律神经平衡状态。
public enum AutonomicBalanceState: String, Sendable {
    /// 副交感神经占优（深层放松、修复、蓄力）
    case parasympatheticDominant = "副交感占优"
    /// 自主神经平衡（健康稳态）
    case balanced = "自律神经平衡"
    /// 交感神经兴奋（警觉、应激、疲惫代偿）
    case sympatheticDominant = "交感张力偏高"

    public var summary: String {
        switch self {
        case .parasympatheticDominant:
            return "迷走神经活跃，机体处于深度自我修复与充能状态"
        case .balanced:
            return "交感与副交感神经协调稳健，心率节律富有弹性"
        case .sympatheticDominant:
            return "交感神经持续兴奋，提示可能处于紧张、焦虑、疲劳或代谢应激中"
        }
    }
}

// MARK: - 个人基线模型

/// 个人生理指标基线（基于 7~14 天滚动中位数/均值与标准差）。
public struct HealthBaseline: Equatable, Sendable {
    /// 个人 HRV 均值（SDNN，毫秒）
    public let meanHRV: Double
    /// 个人 HRV 标准差
    public let stdHRV: Double
    /// 个人静息心率均值（bpm）
    public let meanRestingHR: Double
    /// 个人静息心率标准差
    public let stdRestingHR: Double
    /// 目标睡眠时长（小时）
    public let targetSleepHours: Double

    public init(
        meanHRV: Double = 42.0,
        stdHRV: Double = 15.0,
        meanRestingHR: Double = 65.0,
        stdRestingHR: Double = 6.0,
        targetSleepHours: Double = 7.5
    ) {
        self.meanHRV = max(meanHRV, 10.0)
        self.stdHRV = max(stdHRV, 2.0)
        self.meanRestingHR = max(meanRestingHR, 40.0)
        self.stdRestingHR = max(stdRestingHR, 2.0)
        self.targetSleepHours = max(targetSleepHours, 4.0)
    }

    /// 默认成年人健康参考基线。
    public static let standard = HealthBaseline()
}

// MARK: - 评估结果与明细

/// 愉悦与压力推断的关键细分指标。
public struct PleasureDetailMetric: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let valueText: String
    public let statusText: String
    public let isPositive: Bool

    public init(title: String, valueText: String, statusText: String, isPositive: Bool) {
        self.title = title
        self.valueText = valueText
        self.statusText = statusText
        self.isPositive = isPositive
    }
}

/// 愉悦指数与压力综合推断报告。
public struct PleasureIndexEvaluation: Equatable, Sendable {
    /// 身心愉悦指数（0 ~ 100 分）
    public let pleasureScore: Int
    /// 愉悦状态级别
    public let state: PleasureState
    /// 压力指数（0 ~ 100 分，越低越轻松）
    public let stressScore: Int
    /// 压力级别
    public let stressLevel: StressLevel
    /// 自律神经恢复分（0 ~ 100 分）
    public let autonomicScore: Int
    /// 自律神经平衡状态
    public let autonomicBalance: AutonomicBalanceState
    /// 睡眠与情绪储备分（0 ~ 100 分）
    public let sleepRecoveryScore: Int
    /// 核心总结（1 句话）
    public let summary: String
    /// 行动与调养关怀建议
    public let advice: String
    /// 细分指标亮点
    public let details: [PleasureDetailMetric]

    public init(
        pleasureScore: Int,
        state: PleasureState,
        stressScore: Int,
        stressLevel: StressLevel,
        autonomicScore: Int,
        autonomicBalance: AutonomicBalanceState,
        sleepRecoveryScore: Int,
        summary: String,
        advice: String,
        details: [PleasureDetailMetric]
    ) {
        self.pleasureScore = pleasureScore
        self.state = state
        self.stressScore = stressScore
        self.stressLevel = stressLevel
        self.autonomicScore = autonomicScore
        self.autonomicBalance = autonomicBalance
        self.sleepRecoveryScore = sleepRecoveryScore
        self.summary = summary
        self.advice = advice
        self.details = details
    }
}

// MARK: - 推断核心算法

public enum PleasureIndexEvaluator {

    /// 评估身心愉悦指数与压力状态。
    /// - Parameters:
    ///   - snapshot: Apple 健康当日快照（包含 HRV、睡眠分期、心率等）
    ///   - baseline: 个人动态基线（若为 nil 则采用标准经验基线）
    public static func evaluate(
        snapshot: HealthDaySnapshot?,
        baseline: HealthBaseline = .standard
    ) -> PleasureIndexEvaluation {
        // 1. 无数据时的保底稳健处理
        guard let snapshot, snapshot.readState == .hasData else {
            return defaultEvaluation(baseline: baseline, reason: "尚无足够手环生理数据，保持作息规律，佩戴手环入睡后将自动生成精准指数。")
        }

        var details: [PleasureDetailMetric] = []

        // 2. 自律神经维度计算（HRV & 静息心率）
        let (autonomicScore, stressScore, balanceState, autonomicDetails) = evaluateAutonomic(
            snapshot: snapshot,
            baseline: baseline
        )
        details.append(contentsOf: autonomicDetails)

        // 3. 睡眠与情绪修复储备计算（总睡眠、REM、Deep）
        let (sleepScore, sleepDetails) = evaluateSleepRecovery(
            snapshot: snapshot,
            baseline: baseline
        )
        details.append(contentsOf: sleepDetails)

        // 4. 活动能量与身体激活奖励/调节（0 ~ 100）
        let activityScore = evaluateActivity(snapshot: snapshot)

        // 5. 综合加权计算「愉悦指数」
        // 若同时有自律神经与睡眠：权重 45% 自主神经 + 45% 睡眠储备 + 10% 活动激活
        // 若无 HRV（如用户只在白天摘新手表）：平滑降权
        let hasHRV = snapshot.heartRateVariability != nil
        let hasSleep = snapshot.sleepHours != nil

        let finalScore: Double
        if hasHRV && hasSleep {
            finalScore = (Double(autonomicScore) * 0.45) + (Double(sleepScore) * 0.45) + (Double(activityScore) * 0.10)
        } else if hasHRV {
            finalScore = (Double(autonomicScore) * 0.70) + (Double(sleepScore) * 0.20) + (Double(activityScore) * 0.10)
        } else if hasSleep {
            finalScore = (Double(sleepScore) * 0.65) + (Double(autonomicScore) * 0.25) + (Double(activityScore) * 0.10)
        } else {
            finalScore = (Double(autonomicScore) * 0.50) + (Double(sleepScore) * 0.30) + (Double(activityScore) * 0.20)
        }

        let clampedPleasure = min(max(Int(finalScore.rounded()), 0), 100)
        let state = pleasureState(for: clampedPleasure)
        let stressLvl = stressLevel(for: stressScore)

        // 6. 生成核心文案与调养建议
        let (summary, advice) = generateSummaryAndAdvice(
            state: state,
            stressLevel: stressLvl,
            balance: balanceState,
            hasHRV: hasHRV,
            hasSleep: hasSleep,
            snapshot: snapshot
        )

        return PleasureIndexEvaluation(
            pleasureScore: clampedPleasure,
            state: state,
            stressScore: stressScore,
            stressLevel: stressLvl,
            autonomicScore: autonomicScore,
            autonomicBalance: balanceState,
            sleepRecoveryScore: sleepScore,
            summary: summary,
            advice: advice,
            details: details
        )
    }

    // MARK: - 子模块评估

    /// 自律神经（ANS）与压力评估。
    private static func evaluateAutonomic(
        snapshot: HealthDaySnapshot,
        baseline: HealthBaseline
    ) -> (autonomicScore: Int, stressScore: Int, balance: AutonomicBalanceState, details: [PleasureDetailMetric]) {
        var details: [PleasureDetailMetric] = []

        let hrv = snapshot.heartRateVariability
        let rhr = snapshot.restingHeartRate ?? snapshot.heartRate

        // 标准化 Z-score
        let zHRV: Double? = hrv.map { min(max(($0 - baseline.meanHRV) / baseline.stdHRV, -2.5), 2.5) }
        let zRHR: Double? = rhr.map { min(max(($0 - baseline.meanRestingHR) / baseline.stdRestingHR, -2.5), 2.5) }

        var autonomicVal: Double = 65.0
        var stressVal: Double = 35.0

        if let zH = zHRV, let zR = zRHR {
            autonomicVal = 50.0 + (zH * 20.0) - (zR * 18.0)
            stressVal = 50.0 - (zH * 22.0) + (zR * 22.0)
        } else if let zH = zHRV {
            autonomicVal = 50.0 + (zH * 25.0)
            stressVal = 50.0 - (zH * 25.0)
        } else if let zR = zRHR {
            autonomicVal = 65.0 - (zR * 20.0)
            stressVal = 35.0 + (zR * 22.0)
        }

        // 截断到 0 ~ 100
        let autonomicScore = min(max(Int(autonomicVal.rounded()), 0), 100)
        let stressScore = min(max(Int(stressVal.rounded()), 0), 100)

        // 判定平衡状态
        let balance: AutonomicBalanceState
        if let zH = zHRV {
            if zH >= 0.6 {
                balance = .parasympatheticDominant
            } else if zH <= -0.8 {
                balance = .sympatheticDominant
            } else {
                balance = .balanced
            }
        } else {
            balance = stressScore > 55 ? .sympatheticDominant : .balanced
        }

        // 构造细分展示
        if let hrv {
            let z = zHRV ?? 0
            let status = z >= 0.5 ? "高于平时基线" : (z <= -0.5 ? "低于平时基线" : "在正常基线范围")
            details.append(PleasureDetailMetric(
                title: "心率变异性 (HRV)",
                valueText: "\(Int(hrv.rounded())) ms",
                statusText: status,
                isPositive: z >= -0.3
            ))
        }

        if let rhr {
            let z = zRHR ?? 0
            let status = z <= -0.3 ? "心率平稳静息" : (z >= 0.8 ? "偏高，有唤醒/疲惫迹象" : "正常静息水平")
            details.append(PleasureDetailMetric(
                title: "静息心率",
                valueText: "\(Int(rhr.rounded())) 次/分",
                statusText: status,
                isPositive: z <= 0.5
            ))
        }

        return (autonomicScore, stressScore, balance, details)
    }

    /// 睡眠与情绪修复评估。
    private static func evaluateSleepRecovery(
        snapshot: HealthDaySnapshot,
        baseline: HealthBaseline
    ) -> (score: Int, details: [PleasureDetailMetric]) {
        var details: [PleasureDetailMetric] = []
        guard let totalSleep = snapshot.sleepHours else {
            return (65, details)
        }

        // 1. 时长得分计算
        var durationScore: Double = 65.0
        if totalSleep >= 7.0 && totalSleep <= 8.5 {
            durationScore = 95.0
        } else if totalSleep >= 6.0 && totalSleep < 7.0 {
            durationScore = 78.0
        } else if totalSleep > 8.5 && totalSleep <= 9.5 {
            durationScore = 88.0
        } else if totalSleep >= 5.0 && totalSleep < 6.0 {
            durationScore = 55.0
        } else if totalSleep < 5.0 {
            durationScore = 30.0
        } else {
            durationScore = 70.0 // > 9.5h
        }

        details.append(PleasureDetailMetric(
            title: "昨夜睡眠时长",
            valueText: String(format: "%.1f 小时", totalSleep),
            statusText: totalSleep >= 7.0 ? "修复充分" : "睡眠略欠账",
            isPositive: totalSleep >= 6.5
        ))

        // 2. 情绪修复：REM 快速眼动睡眠（正常成年人占 20%~25%）
        var remScore: Double = durationScore
        if let rem = snapshot.sleepREM, totalSleep > 0 {
            let remRatio = rem / totalSleep
            if remRatio >= 0.18 && remRatio <= 0.28 {
                remScore = min(durationScore + 10.0, 100.0)
                details.append(PleasureDetailMetric(
                    title: "REM 情绪修复",
                    valueText: String(format: "%.1f 小时 (%.0f%%)", rem, remRatio * 100),
                    statusText: "心理应激重置良好",
                    isPositive: true
                ))
            } else if remRatio < 0.14 {
                remScore = max(durationScore - 12.0, 20.0)
                details.append(PleasureDetailMetric(
                    title: "REM 情绪修复",
                    valueText: String(format: "%.1f 小时 (%.0f%%)", rem, remRatio * 100),
                    statusText: "占比偏低，情绪易感",
                    isPositive: false
                ))
            } else {
                details.append(PleasureDetailMetric(
                    title: "REM 情绪修复",
                    valueText: String(format: "%.1f 小时 (%.0f%%)", rem, remRatio * 100),
                    statusText: "基本稳定",
                    isPositive: true
                ))
            }
        }

        // 3. 身体修复：深睡眠（正常 15%~22%）
        var deepScore: Double = durationScore
        if let deep = snapshot.sleepDeep, totalSleep > 0 {
            let deepRatio = deep / totalSleep
            if deepRatio >= 0.15 {
                deepScore = min(durationScore + 8.0, 100.0)
                details.append(PleasureDetailMetric(
                    title: "深度睡眠",
                    valueText: String(format: "%.1f 小时 (%.0f%%)", deep, deepRatio * 100),
                    statusText: "体能恢复优良",
                    isPositive: true
                ))
            } else {
                details.append(PleasureDetailMetric(
                    title: "深度睡眠",
                    valueText: String(format: "%.1f 小时 (%.0f%%)", deep, deepRatio * 100),
                    statusText: "体能修复偏浅",
                    isPositive: false
                ))
            }
        }

        let combined = (durationScore * 0.5) + (remScore * 0.3) + (deepScore * 0.2)
        return (min(max(Int(combined.rounded()), 0), 100), details)
    }

    /// 日间活动激活度（0 ~ 100）。
    private static func evaluateActivity(snapshot: HealthDaySnapshot) -> Int {
        guard let steps = snapshot.stepCount else { return 70 }
        if steps >= 6000 && steps <= 14000 {
            return 90 // 黄金适度活动，分泌内啡肽与多巴胺
        } else if steps >= 3000 && steps < 6000 {
            return 75
        } else if steps > 14000 {
            return 78 // 超高活动，需注意体力消耗
        } else {
            return 60 // 久坐
        }
    }

    // MARK: - 等级映射与建议生成

    public static func pleasureState(for score: Int) -> PleasureState {
        switch score {
        case 85...100: return .euphoric
        case 70...84: return .serene
        case 50...69: return .strained
        case 35...49: return .fatigued
        default: return .overloaded
        }
    }

    public static func stressLevel(for score: Int) -> StressLevel {
        switch score {
        case 0...25: return .low
        case 26...50: return .moderate
        case 51...75: return .elevated
        default: return .high
        }
    }

    private static func generateSummaryAndAdvice(
        state: PleasureState,
        stressLevel: StressLevel,
        balance: AutonomicBalanceState,
        hasHRV: Bool,
        hasSleep: Bool,
        snapshot: HealthDaySnapshot
    ) -> (summary: String, advice: String) {
        switch state {
        case .euphoric:
            return (
                "身心储备充盈，自律神经调控卓越，处于高质量从容状态。",
                "当下的心理韧性极佳，适合应对高难度工作、重要决策，或尽情享受运动与人际社交。"
            )
        case .serene:
            return (
                "各项生命体征平顺，自主神经处于健康稳态，心态舒展。",
                "节奏舒适恰当，保持常规步调，下午适度补充水分或散步 10 分钟以延续好状态。"
            )
        case .strained:
            if balance == .sympatheticDominant {
                return (
                    "交感神经处于轻度亢奋与负荷代偿状态，略显紧绷。",
                    "建议每专注 45 分钟安排 3 分钟腹式深呼气（吸 4 秒呼 6 秒），有助于快速激活副交感平复张力。"
                )
            } else {
                return (
                    "身体在稳健适应当前工作节奏，轻度唤醒有助于专注冲刺。",
                    "注意避免连续久坐，适时站立伸展，午后可尝试一杯温水舒缓身心。"
                )
            }
        case .fatigued:
            let sleepReason = (snapshot.sleepHours ?? 8) < 6.5 ? "昨夜睡眠时长偏少，" : ""
            return (
                "\(sleepReason)机体生理能量偏低，身心调控耐受力处于收缩期。",
                "建议精简今日待办，将高耗能决策暂缓；今晚建议提早 30 分钟放下手机入睡。"
            )
        case .overloaded:
            return (
                "心率变异性显著偏离个人基线，交感神经负荷超载，机体亮起疲惫红灯。",
                "请将自我关怀置于首位：暂停紧绷任务，尝试闭目放空或温水浴，避免咖啡因刺激。"
            )
        }
    }

    private static func defaultEvaluation(baseline: HealthBaseline, reason: String) -> PleasureIndexEvaluation {
        PleasureIndexEvaluation(
            pleasureScore: 70,
            state: .serene,
            stressScore: 30,
            stressLevel: .moderate,
            autonomicScore: 70,
            autonomicBalance: .balanced,
            sleepRecoveryScore: 70,
            summary: "身心稳态基准良好",
            advice: reason,
            details: []
        )
    }
}
