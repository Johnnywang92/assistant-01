import Foundation

// MARK: - 身体活力值评估引擎（纯逻辑下沉 Core）
//
// 核心逻辑：
// 结合 Apple 健康指标（睡眠、体温、身体总耗能/活动能量/静息能量、健身记录、心率、血氧、步行速度、体征等）
// 与通过照片/手动记录推测的食物摄入能量，经过多维生理与代谢模型综合推算出一个「活力值」（0~100 分），
// 并提炼出精简、抓重点的关键健康指标摘要，供日报呈现与生活调养。
//
// 评估四大支柱：
// 1. 睡眠深度恢复（时长与规律性，7.0~8.5 小时为黄金区间）
// 2. 能量收支平衡（食物摄入热量 vs 身体总耗能，评估供能充足度与代谢负荷）
// 3. 身体活动与健身（活动能量、步数、健身记录，心肺与肌肉适度激活）
// 4. 核心体征平稳性（心率、血氧、体温、呼吸频率、步速基线安全）

/// 活力状态级别。
public enum VitalityLevel: String, Sendable, CaseIterable {
    /// 活力充沛（85 ~ 100 分）
    case peak = "活力充沛"
    /// 状态良好（70 ~ 84 分）
    case good = "状态良好"
    /// 平和蓄力（55 ~ 69 分）
    case balanced = "平和蓄力"
    /// 能量偏低（40 ~ 54 分）
    case low = "能量偏低"
    /// 疲劳待恢复（< 40 分）
    case exhausted = "疲劳待恢复"

    /// 图标名（SF Symbols）
    public var icon: String {
        switch self {
        case .peak: return "bolt.fill"
        case .good: return "sparkles"
        case .balanced: return "leaf.fill"
        case .low: return "battery.25percent"
        case .exhausted: return "battery.0percent"
        }
    }

    /// 带 Emoji 的标签
    public var badge: String {
        switch self {
        case .peak: return "⚡️ 活力充沛"
        case .good: return "🌟 状态良好"
        case .balanced: return "🌿 平和蓄力"
        case .low: return "🔋 能量偏低"
        case .exhausted: return "🛌 疲劳待恢复"
        }
    }
}

/// 能量收支状态（食物摄入 vs 身体耗能）。
public struct EnergyBalanceStatus: Equatable, Sendable {
    /// 食物推测摄入总能量（千卡）
    public let intakeCalories: Double?
    /// 身体总耗能（千卡，静息 + 活动）
    public let burnedCalories: Double?
    /// 静息能量（千卡）
    public let restingCalories: Double?
    /// 活动能量（千卡）
    public let activeCalories: Double?

    public init(
        intakeCalories: Double?,
        burnedCalories: Double?,
        restingCalories: Double? = nil,
        activeCalories: Double? = nil
    ) {
        self.intakeCalories = intakeCalories
        self.burnedCalories = burnedCalories
        self.restingCalories = restingCalories
        self.activeCalories = activeCalories
    }

    /// 净差值（千卡）= 摄入 - 消耗
    public var netDifference: Double? {
        guard let intakeCalories, let burnedCalories else { return nil }
        return intakeCalories - burnedCalories
    }

    /// 精炼文字描述
    public var summaryText: String {
        guard let net = netDifference else {
            if let intake = intakeCalories {
                return "摄入约 \(Int(intake.rounded())) 千卡（身体消耗待补充）"
            } else if let burned = burnedCalories {
                return "身体总耗能 \(Int(burned.rounded())) 千卡（饮食记录待补充）"
            }
            return "能量数据待补充"
        }
        let netInt = Int(abs(net).rounded())
        if abs(net) <= 250 {
            return "能量收支基本平衡（差值 \(net >= 0 ? "+" : "-")\(netInt) kcal）"
        } else if net > 250 {
            return "能量适度盈余（+\(netInt) kcal）"
        } else {
            return "处于热量赤字（-\(netInt) kcal，燃脂中）"
        }
    }
}

/// 精简重点条目（抓重点、精简呈现）。
public struct VitalityHighlight: Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let icon: String
    public let title: String
    public let valueText: String
    public let statusText: String
    public let isPositive: Bool

    public init(
        icon: String,
        title: String,
        valueText: String,
        statusText: String,
        isPositive: Bool = true
    ) {
        self.icon = icon
        self.title = title
        self.valueText = valueText
        self.statusText = statusText
        self.isPositive = isPositive
    }
}

/// 活力值综合评估结果。
public struct VitalityEvaluation: Equatable, Sendable {
    /// 活力分（0 ~ 100）
    public let score: Int
    /// 状态等级
    public let level: VitalityLevel
    /// 能量平衡
    public let energyBalance: EnergyBalanceStatus
    /// 核心总结（1~2 句话精简提炼）
    public let summary: String
    /// 关键指标精简亮点
    public let highlights: [VitalityHighlight]
    /// 生活调养建议
    public let suggestion: String

    public init(
        score: Int,
        level: VitalityLevel,
        energyBalance: EnergyBalanceStatus,
        summary: String,
        highlights: [VitalityHighlight],
        suggestion: String
    ) {
        self.score = score
        self.level = level
        self.energyBalance = energyBalance
        self.summary = summary
        self.highlights = highlights
        self.suggestion = suggestion
    }
}

/// 活力值评估核心入口。
public enum VitalityEvaluator {

    /// 评估身体活力值。
    /// - Parameters:
    ///   - snapshot: Apple 健康当日快照（可包含睡眠、体温、能量、健身、心率等）
    ///   - foodIntakeCalories: 当日食物照片或手动录入推测的摄入热量（千卡）
    public static func evaluate(
        snapshot: HealthDaySnapshot?,
        foodIntakeCalories: Double?
    ) -> VitalityEvaluation {
        var score: Double = 65.0 // 基准分

        // 1. 睡眠维度（-16 ~ +15）
        let sleepHours = snapshot?.sleepHours
        var sleepDelta: Double = 0.0
        var sleepHighlight: VitalityHighlight?

        if let sleep = sleepHours {
            if sleep >= 7.0 && sleep <= 8.5 {
                sleepDelta = 15.0
                sleepHighlight = VitalityHighlight(
                    icon: "bed.double.fill",
                    title: "睡眠恢复",
                    valueText: String(format: "%.1f 小时", sleep),
                    statusText: "黄金深度修复",
                    isPositive: true
                )
            } else if sleep >= 6.0 && sleep < 7.0 {
                sleepDelta = 8.0
                sleepHighlight = VitalityHighlight(
                    icon: "bed.double.fill",
                    title: "睡眠恢复",
                    valueText: String(format: "%.1f 小时", sleep),
                    statusText: "基本充足",
                    isPositive: true
                )
            } else if sleep > 8.5 && sleep <= 10.0 {
                sleepDelta = 8.0
                sleepHighlight = VitalityHighlight(
                    icon: "bed.double.fill",
                    title: "睡眠恢复",
                    valueText: String(format: "%.1f 小时", sleep),
                    statusText: "睡眠充裕",
                    isPositive: true
                )
            } else if sleep >= 5.0 && sleep < 6.0 {
                sleepDelta = -6.0
                sleepHighlight = VitalityHighlight(
                    icon: "bed.double.fill",
                    title: "睡眠恢复",
                    valueText: String(format: "%.1f 小时", sleep),
                    statusText: "睡眠略显不足",
                    isPositive: false
                )
            } else {
                sleepDelta = -16.0
                sleepHighlight = VitalityHighlight(
                    icon: "bed.double.fill",
                    title: "睡眠恢复",
                    valueText: String(format: "%.1f 小时", sleep),
                    statusText: "严重缺乏睡眠",
                    isPositive: false
                )
            }
        }

        // 2. 能量收支维度（-10 ~ +15）
        let burned = snapshot?.totalEnergyBurned
        let resting = snapshot?.restingEnergy
        let active = snapshot?.activeEnergy
        let energyStatus = EnergyBalanceStatus(
            intakeCalories: foodIntakeCalories,
            burnedCalories: burned,
            restingCalories: resting,
            activeCalories: active
        )
        var energyDelta: Double = 0.0
        var energyHighlight: VitalityHighlight?

        if let intake = foodIntakeCalories {
            if let burned {
                let diff = intake - burned
                if abs(diff) <= 250 {
                    energyDelta = 15.0
                    energyHighlight = VitalityHighlight(
                        icon: "flame.fill",
                        title: "能量平衡",
                        valueText: "摄入 \(Int(intake.rounded())) / 消耗 \(Int(burned.rounded())) kcal",
                        statusText: "收支基本平衡",
                        isPositive: true
                    )
                } else if diff >= -600 && diff < -250 {
                    energyDelta = 10.0
                    energyHighlight = VitalityHighlight(
                        icon: "flame.fill",
                        title: "能量平衡",
                        valueText: "赤字 \(Int(abs(diff).rounded())) kcal",
                        statusText: "适度燃脂状态",
                        isPositive: true
                    )
                } else if diff > 250 && diff <= 550 {
                    energyDelta = 8.0
                    energyHighlight = VitalityHighlight(
                        icon: "flame.fill",
                        title: "能量平衡",
                        valueText: "盈余 \(Int(diff.rounded())) kcal",
                        statusText: "体能储备充沛",
                        isPositive: true
                    )
                } else if diff < -800 {
                    energyDelta = -10.0
                    energyHighlight = VitalityHighlight(
                        icon: "flame.fill",
                        title: "能量平衡",
                        valueText: "赤字 \(Int(abs(diff).rounded())) kcal",
                        statusText: "热量缺口偏大",
                        isPositive: false
                    )
                } else if diff > 800 {
                    energyDelta = -8.0
                    energyHighlight = VitalityHighlight(
                        icon: "flame.fill",
                        title: "能量平衡",
                        valueText: "盈余 \(Int(diff.rounded())) kcal",
                        statusText: "摄入负荷较重",
                        isPositive: false
                    )
                } else {
                    energyDelta = 5.0
                    energyHighlight = VitalityHighlight(
                        icon: "flame.fill",
                        title: "能量平衡",
                        valueText: "差值 \(Int(diff.rounded())) kcal",
                        statusText: "处于正常区间",
                        isPositive: true
                    )
                }
            } else {
                if intake >= 1200 && intake <= 2400 {
                    energyDelta = 8.0
                    energyHighlight = VitalityHighlight(
                        icon: "fork.knife",
                        title: "饮食摄入",
                        valueText: "\(Int(intake.rounded())) 千卡",
                        statusText: "热量摄入适度",
                        isPositive: true
                    )
                } else if intake < 800 {
                    energyDelta = -6.0
                    energyHighlight = VitalityHighlight(
                        icon: "fork.knife",
                        title: "饮食摄入",
                        valueText: "\(Int(intake.rounded())) 千卡",
                        statusText: "摄入热量过少",
                        isPositive: false
                    )
                } else {
                    energyDelta = 4.0
                    energyHighlight = VitalityHighlight(
                        icon: "fork.knife",
                        title: "饮食摄入",
                        valueText: "\(Int(intake.rounded())) 千卡",
                        statusText: "已记录热量",
                        isPositive: true
                    )
                }
            }
        } else if let burned {
            energyDelta = 5.0
            let restingText = resting.map { "静息 \(Int($0.rounded())) + " } ?? ""
            let activeText = active.map { "活动 \(Int($0.rounded()))" } ?? ""
            energyHighlight = VitalityHighlight(
                icon: "flame.fill",
                title: "身体耗能",
                valueText: "\(Int(burned.rounded())) 千卡",
                statusText: "\(restingText)\(activeText)",
                isPositive: true
            )
        }

        // 3. 运动健身维度（-5 ~ +15）
        let workoutMin = snapshot?.workoutMinutes ?? 0
        let activeCal = snapshot?.activeEnergy ?? 0
        let steps = snapshot?.stepCount ?? 0
        let walkingSpeed = snapshot?.walkingSpeed
        var activityDelta: Double = 0.0
        var activityHighlight: VitalityHighlight?

        if workoutMin >= 30 || activeCal >= 450 || steps >= 10000 {
            activityDelta = 13.0
            let text = workoutMin > 0 ? "健身 \(Int(workoutMin.rounded())) 分钟 · \(Int(steps.rounded())) 步" : "\(Int(steps.rounded())) 步"
            activityHighlight = VitalityHighlight(
                icon: "figure.run",
                title: "健身与活动",
                valueText: text,
                statusText: "运动量充沛达标",
                isPositive: true
            )
        } else if workoutMin >= 15 || activeCal >= 250 || steps >= 6000 {
            activityDelta = 8.0
            let text = workoutMin > 0 ? "健身 \(Int(workoutMin.rounded())) 分钟 · \(Int(steps.rounded())) 步" : "\(Int(steps.rounded())) 步"
            activityHighlight = VitalityHighlight(
                icon: "figure.run",
                title: "健身与活动",
                valueText: text,
                statusText: "日常活动良好",
                isPositive: true
            )
        } else if activeCal >= 120 || steps >= 3500 {
            activityDelta = 4.0
            activityHighlight = VitalityHighlight(
                icon: "figure.walk",
                title: "日常活动",
                valueText: "\(Int(steps.rounded())) 步",
                statusText: "有基础活动量",
                isPositive: true
            )
        } else if steps > 0 && steps < 2000 && workoutMin == 0 {
            activityDelta = -5.0
            activityHighlight = VitalityHighlight(
                icon: "figure.walk",
                title: "日常活动",
                valueText: "\(Int(steps.rounded())) 步",
                statusText: "偏久坐少动",
                isPositive: false
            )
        }

        // 4. 生理体征维度（-15 ~ +10）
        var vitalsDelta: Double = 0.0
        var vitalParts: [String] = []
        var vitalsAreNormal = true

        if let ox = snapshot?.bloodOxygen {
            let pct = ox > 1.0 ? ox : ox * 100.0
            vitalParts.append("血氧 \(Int(pct.rounded()))%")
            if pct >= 97 {
                vitalsDelta += 3.0
            } else if pct >= 95 {
                vitalsDelta += 1.0
            } else {
                vitalsDelta -= 12.0
                vitalsAreNormal = false
            }
        }

        if let hr = snapshot?.heartRate {
            vitalParts.append("心率 \(Int(hr.rounded())) bpm")
            if hr >= 50 && hr <= 75 {
                vitalsDelta += 4.0
            } else if hr > 75 && hr <= 85 {
                vitalsDelta += 1.0
            } else if hr > 90 {
                vitalsDelta -= 6.0
                vitalsAreNormal = false
            }
        }

        if let temp = snapshot?.bodyTemperature {
            vitalParts.append(String(format: "体温 %.1f℃", temp))
            if temp >= 36.0 && temp <= 37.2 {
                vitalsDelta += 2.0
            } else if temp > 37.3 {
                vitalsDelta -= 12.0
                vitalsAreNormal = false
            }
        }

        if let resp = snapshot?.respiratoryRate {
            vitalParts.append("呼吸 \(Int(resp.rounded())) 次/分")
            if resp >= 12 && resp <= 20 {
                vitalsDelta += 1.0
            } else if resp > 22 {
                vitalsDelta -= 4.0
            }
        }

        if let speed = walkingSpeed, speed > 0 {
            vitalParts.append(String(format: "步速 %.1f km/h", speed))
        }

        var vitalsHighlight: VitalityHighlight?
        if !vitalParts.isEmpty {
            vitalsHighlight = VitalityHighlight(
                icon: "heart.text.square.fill",
                title: "核心体征",
                valueText: vitalParts.prefix(3).joined(separator: " · "),
                statusText: vitalsAreNormal ? "生理指标平稳正常" : "体征指标需留意",
                isPositive: vitalsAreNormal
            )
        }

        // 汇总总分
        score += (sleepDelta + energyDelta + activityDelta + vitalsDelta)
        let finalScore = min(max(Int(score.rounded()), 10), 100)

        // 评定等级
        let level: VitalityLevel
        if finalScore >= 85 {
            level = .peak
        } else if finalScore >= 70 {
            level = .good
        } else if finalScore >= 55 {
            level = .balanced
        } else if finalScore >= 40 {
            level = .low
        } else {
            level = .exhausted
        }

        // 精炼亮点组合（抓重点、按重要性排序）
        var highlights: [VitalityHighlight] = []
        if let energyHighlight { highlights.append(energyHighlight) }
        if let sleepHighlight { highlights.append(sleepHighlight) }
        if let activityHighlight { highlights.append(activityHighlight) }
        if let vitalsHighlight { highlights.append(vitalsHighlight) }

        // 生成精简提炼总结与建议
        let summary: String
        let suggestion: String

        switch level {
        case .peak:
            summary = "今日身心状态处于高光期，睡眠与能量代谢形成良性闭环，身体活力饱满。"
            suggestion = "体能储备极佳，适合挑战高专注工作或高强度训练，注意训练后及时补水。"
        case .good:
            summary = "整体生理状态平稳向好，能量收支有序，各项核心体征指标健康。"
            suggestion = "保持当前作息与运动节奏，入夜后减少蓝光照射有助于维持良好状态。"
        case .balanced:
            summary = "身心处于平衡蓄力区间，日常消耗适度，整体机能运转平稳。"
            suggestion = "建议适度补充优质蛋白质与温水，白天增加 10 分钟轻量拉伸活动。"
        case .low:
            if sleepDelta < 0 {
                summary = "受昨夜睡眠不足影响，今日精力储备偏低，容易出现午后倦怠。"
                suggestion = "今晚建议在 22:30 前就寝，避免剧烈运动，为机能深度修复留出时间。"
            } else if energyDelta < 0 {
                summary = "热量收支缺口较大，身体供能处于紧张状态，略显疲惫。"
                suggestion = "建议适量加餐全谷物或坚果，及时弥补能量缺口，避免体能过度透支。"
            } else {
                summary = "今日身体活力指数偏低，肌肉与神经系统处于恢复期。"
                suggestion = "减少高强度体力支出，温水泡脚或听舒缓音乐，让身心放松。"
            }
        case .exhausted:
            summary = "监测到多项指标（睡眠/能量/体征）出现明显透支预警，身心处于疲劳待恢复状态。"
            suggestion = "务必停下繁重事务立即安排休息，今晚优先保障 8 小时高质量连续睡眠。"
        }

        return VitalityEvaluation(
            score: finalScore,
            level: level,
            energyBalance: energyStatus,
            summary: summary,
            highlights: highlights,
            suggestion: suggestion
        )
    }
}
