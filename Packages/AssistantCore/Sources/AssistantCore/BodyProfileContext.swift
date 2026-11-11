import Foundation

// MARK: - 身体档案参与健康计算的单一真源
//
// ## 为什么需要这一层
//
// 上一轮新增的「身体档案」存了身高 / 出生日期 / 体重 / 血压 / 心率 / 血糖 /
// 体温 / 血氧 / 体脂率，但**两个指数（活力值、身心愉悦指数）以及饮水与热量目标
// 完全没读这些数据**——档案是孤岛。本文件把它们收束成一份纯值上下文，
// 由 App 侧构建一次、Core 侧统一计算，避免 9 个调用点各写一套口径。
//
// ## 两条不可退让的约束
//
// 1. **不做医学分级 / 不自动解读数值。**
//    绝不出现「血压 > 140 扣 5 分」「BMI > 24 算超重」这类绝对阈值判断：
//    那是把 App 变成诊断工具，也与身体档案页「不做自动解读」的承诺冲突。
//    这里唯一使用的信号是**相对本人自己历史基线的偏离幅度**，且上下同向
//    等价（变高与变低都只算「波动」，不说哪个方向更糟）。
//    不评价数值本身，只描述「和你自己平时比，最近变动有多大」。
//
// 2. **缺失 ≠ 健康，陈旧 ≠ 当前。**
//    少于 `minimumDeviationSamples` 条记录的字段不参与；最近一次记录超过
//    `freshnessLimit` 天则整份档案不参与（返回中性修正）。三个月前量的一次
//    血压不该拖累今天的指数。任何情况下都不会因为「用户没填」而给奖励分。
//
// ## 身高 / 体重 / 年龄如何进入指数
//
// 不直接当加分/扣分项（体型与年龄不是当日状态），而是通过
// `BodyMetabolism` 推算基础代谢 BMR（Mifflin-St Jeor，成人适用），
// 把活力指数里写死的 `1200~2400 kcal`、以及饮水目标的固定 1700ml，
// 换成按本人身体构成缩放的参考值。年龄只进 BMR，不用来
// 「按人群均值」修正 HRV / 静息心率——那同样是拿群体统计给个人下结论，
// 个人 HRV 基线应由本人的历史观测决定（`HealthBaseline`）。
//
// 所有派生量都是**参考值**，用户显式设置的目标永远优先。

// MARK: - 生理性别（仅服务于 BMR 公式）

/// 生理性别。BMR 公式需要该参数；`unspecified` 取男女常数中点，
/// 不猜测、不默认成男性。
public enum BodyBiologicalSex: String, Equatable, Sendable {
    case male
    case female
    case unspecified

    /// Mifflin-St Jeor 的性别常数（kcal）。未指定时取 +5 / −161 的中点 −78。
    public var bmrConstant: Double {
        switch self {
        case .male: return 5
        case .female: return -161
        case .unspecified: return -78
        }
    }
}

// MARK: - 代谢与参考目标

public enum BodyMetabolism {

    /// 轻体力活动的活动系数（Mifflin-St Jeor BMR × 1.375 ≈ 日常总消耗参考）。
    public static let lightActivityFactor: Double = 1.375

    /// 每公斤体重的参考补水量（ml/kg）。常用估算口径，仅作参考。
    public static let waterMLPerKg: Double = 30

    /// 参考补水量的上下界，避免极端体重给出荒谬数字。
    public static let waterBounds: ClosedRange<Double> = 1200...3000

    /// Mifflin-St Jeor 公式的成人适用范围（周岁）。范围外返回 nil，
    /// 不把成人公式套到儿童/高龄用户身上，也不悄悄钳到边界值。
    public static let supportedAgeRange: ClosedRange<Int> = 18...90

    /// 用于缩放能量收支阈值的参考日消耗（无档案时的历史常量）。
    public static let legacyReferenceEnergyKcal: Double = 2000

    /// 参与「本人基线偏离」计算的最少样本数。与趋势口径一致：两点连不成线。
    public static let minimumDeviationSamples = 3

    /// 记录新鲜度上限。超过这个时长的档案不再影响当日指数。
    public static let freshnessLimit: TimeInterval = 7 * 24 * 3600

    /// 基础代谢率（kcal/day）。四个输入缺一或超出成人范围时返回 nil，
    /// **不用默认身高/体重/年龄凑数**。
    public static func bmrKcal(
        weightKg: Double?,
        heightCm: Double?,
        ageYears: Int?,
        biologicalSex: BodyBiologicalSex
    ) -> Double? {
        guard let weightKg, let heightCm, let ageYears,
              weightKg > 0, heightCm > 0,
              weightKg.isFinite, heightCm.isFinite,
              BodyMetricValidator.isPlausibleHeight(heightCm),
              supportedAgeRange.contains(ageYears) else { return nil }
        let value = 10 * weightKg + 6.25 * heightCm
            - 5 * Double(ageYears) + biologicalSex.bmrConstant
        return value > 0 && value.isFinite ? value : nil
    }

    /// 日常总消耗参考（kcal）= BMR × 轻体力活动系数。
    public static func referenceEnergyKcal(bmr: Double?) -> Double? {
        guard let bmr, bmr > 0 else { return nil }
        return bmr * lightActivityFactor
    }

    /// 参考补水量（ml）= 体重 × 30，钳在水安全区间内。
    /// 无体重时返回 nil——不拿 1700 冒充「按你算出来的」。
    public static func referenceWaterML(weightKg: Double?) -> Double? {
        guard let weightKg, weightKg > 0, weightKg.isFinite else { return nil }
        return min(max(weightKg * waterMLPerKg, waterBounds.lowerBound), waterBounds.upperBound)
    }

    /// 能量收支判定阈值。无档案时返回**历史常量**（保证既有行为一字不变）；
    /// 有档案时按「本人参考消耗 / 2000」等比例缩放，并限幅防止极端体型
    /// 把阈值放大到失真。
    ///
    /// - Returns: `balanced` = 收支基本平衡的差值上限；
    ///   `deficit` / `surplus` = 适度赤字 / 适度盈余的边界（历史口径两者略有差异，保留）；
    ///   `heavy` = 明显失衡的边界。
    public static func energyThresholds(referenceEnergyKcal: Double?) -> (
        balanced: Double, deficit: Double, surplus: Double, heavy: Double
    ) {
        guard let reference = referenceEnergyKcal, reference > 0 else {
            return (250, 600, 550, 800)
        }
        let scale = min(max(reference / legacyReferenceEnergyKcal, 0.75), 1.35)
        return (250 * scale, 600 * scale, 550 * scale, 800 * scale)
    }

    /// 无「身体耗能」数据时，判断摄入是否落在合理参考带内。
    /// 仅用于替代历史写死的 1200~2400 kcal，不做营养学结论。
    public static func intakeBand(referenceEnergyKcal: Double?) -> (lower: Double, upper: Double, tooLow: Double)? {
        guard let reference = referenceEnergyKcal, reference > 0 else { return nil }
        return (reference * 0.6, reference * 1.2, reference * 0.4)
    }
}

// MARK: - 档案上下文（App 构建、Core 消费）

/// 一次评估所需的全部身体档案事实。纯值、可复现：`now` 由调用方显式注入，
/// 年龄已由 App 用 `BodyMetricCalculator.age(birthDate:now:calendar:)` 算好，
/// Core 不再持有 `Calendar`，也不读墙上时钟。
public struct BodyProfileContext: Equatable, Sendable {
    /// 身高（cm）。未填为 nil。
    public let heightCm: Double?
    /// 周岁年龄。未填出生日期为 nil。
    public let ageYears: Int?
    public let biologicalSex: BodyBiologicalSex
    /// 手动体征记录（无需预排序，Core 内部按时间 + 原始下标稳定排序）。
    public let samples: [BodyMetricSample]
    /// 评估时刻。用于判断记录是否陈旧。
    public let now: Date

    public init(
        heightCm: Double? = nil,
        ageYears: Int? = nil,
        biologicalSex: BodyBiologicalSex = .unspecified,
        samples: [BodyMetricSample] = [],
        now: Date
    ) {
        self.heightCm = heightCm
        self.ageYears = ageYears
        self.biologicalSex = biologicalSex
        self.samples = samples
        self.now = now
    }

    /// 最近一次体重。没有体重记录时返回 nil，不用 0 或「上次的值」冒充。
    public var latestWeightKg: Double? {
        BodyMetricTrendBuilder.latest(field: .weightKg, samples: samples)?.value
    }

    /// BMI（由 Core 的 `BodyMetricCalculator` 算，口径只有一处）。
    public var bmi: Double? {
        BodyMetricCalculator.bmi(weightKg: latestWeightKg, heightCm: heightCm)
    }

    /// 基础代谢率（kcal/day）。
    public var bmrKcal: Double? {
        BodyMetabolism.bmrKcal(
            weightKg: latestWeightKg,
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: biologicalSex
        )
    }

    /// 日常总消耗参考（kcal/day）。
    public var referenceEnergyKcal: Double? {
        BodyMetabolism.referenceEnergyKcal(bmr: bmrKcal)
    }

    /// 参考补水量（ml/day）。
    public var referenceWaterML: Double? {
        BodyMetabolism.referenceWaterML(weightKg: latestWeightKg)
    }

    /// 全档案中最近一次测量的时刻（跨字段取最大）。
    public var latestMeasuredAt: Date? {
        samples.map(\.measuredAt).max()
    }

    /// 最近一次记录是否在新鲜度窗口内。未来时刻（系统时钟被改过）同样判为不可用。
    public var isFresh: Bool {
        guard let latestMeasuredAt else { return false }
        let age = now.timeIntervalSince(latestMeasuredAt)
        return age >= 0 && age <= BodyMetabolism.freshnessLimit
    }
}

// MARK: - 偏离度事实与修正量

/// 某个体征字段相对**本人**历史基线的偏离事实。
/// `deviation` 是有符号的 Z 值（钳在 ±2.5），正负只表示方向，不代表好/坏。
public struct BodyProfileFactor: Equatable, Sendable {
    /// 稳定英文标识，供日志 / 埋点 / App 文案映射。
    public var identifier: String { field.rawValue }
    public let field: BodyMetricField
    public let deviation: Double
    public let sampleCount: Int
    public let latestAt: Date
}

/// 两个指数的身体档案修正量。
///
/// `hasUsableData == false` 时三个 delta 恒为 0（中性），调用方行为与
/// 没有档案时逐字一致。所有 delta 都有硬上界，保证指数仍以客观
/// 可穿戴数据为主导，手动录入不会反客为主。
public struct BodyProfileAdjustment: Equatable, Sendable {
    public let vitalityDelta: Double
    public let pleasureDelta: Double
    public let stressDelta: Int
    public let factors: [BodyProfileFactor]
    /// 平均绝对偏离（0 ~ 2.5）。UI 用它决定「平稳 / 有波动」的中性措辞。
    public let meanAbsoluteDeviation: Double
    public let hasUsableData: Bool
    /// 有记录但已过期；UI 应提示「记录超过 7 天，暂不参与指数」。
    public let isStale: Bool

    public static let neutral = BodyProfileAdjustment(
        vitalityDelta: 0,
        pleasureDelta: 0,
        stressDelta: 0,
        factors: [],
        meanAbsoluteDeviation: 0,
        hasUsableData: false,
        isStale: false
    )
}

public enum BodyProfileModifier {

    /// 参与计算的字段。
    ///
    /// **不含 `diastolic`**：收缩压/舒张压高度相关，两个都算等于把同一个
    /// 信号计两次。血压仍按成对规则校验，只是偏离度只取收缩压作代表。
    public static let stabilityFields: [BodyMetricField] = [
        .weightKg, .systolic, .heartRate,
        .bloodGlucose, .bodyTemperature, .bloodOxygen, .bodyFat
    ]

    /// 各字段的**测量噪声 / 预期自然漂移下限**，用于避免标准差为 0 时除零，
    /// 也避免「完全没有波动」被放大成天文数字的 Z 值。
    /// 这些是量测精度量级，不是健康阈值，不参与任何好坏判断。
    public static func deviationFloor(_ field: BodyMetricField) -> Double {
        switch field {
        case .weightKg: return 1.0        // 体重日内波动 + 有意的增减
        case .systolic, .diastolic: return 4.0
        case .heartRate: return 4.0
        case .bloodGlucose: return 0.4
        case .bodyTemperature: return 0.15
        case .bloodOxygen: return 0.8
        case .bodyFat: return 0.8
        }
    }

    /// 计算身体档案修正量。
    ///
    /// 算法：对每个字段取「最近一次值」与「此前所有值的均值/总体标准差」比较，
    /// 得到钳位后的 Z 值；跨字段取**绝对值的平均**，映射成有界的分数修正。
    /// 取绝对值是有意为之：升高与降低都只是「和你平时不一样」，
    /// 方向性的好坏判断属于医学解读，不在本 App 的能力范围内。
    public static func evaluate(_ context: BodyProfileContext?) -> BodyProfileAdjustment {
        guard let context, !context.samples.isEmpty else {
            return .neutral
        }
        guard context.isFresh else {
            return BodyProfileAdjustment(
                vitalityDelta: 0, pleasureDelta: 0, stressDelta: 0,
                factors: [], meanAbsoluteDeviation: 0,
                hasUsableData: false, isStale: true
            )
        }

        var factors: [BodyProfileFactor] = []
        for field in stabilityFields {
            // 与 BodyMetricTrendBuilder 同一套稳定排序：时间升序，同刻用原始下标兜底。
            let indexed = context.samples.enumerated().compactMap { index, sample -> (Int, Date, Double)? in
                guard let value = sample.values[field], value.isFinite else { return nil }
                return (index, sample.measuredAt, value)
            }
            guard indexed.count >= BodyMetabolism.minimumDeviationSamples else { continue }
            let ordered = indexed.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0 < rhs.0
            }
            guard let latest = ordered.last else { continue }
            let history = ordered.dropLast().map(\.2)
            guard !history.isEmpty else { continue }

            let mean = history.reduce(0, +) / Double(history.count)
            let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count)
            let std = max(sqrt(variance), deviationFloor(field))
            let z = min(max((latest.2 - mean) / std, -2.5), 2.5)

            factors.append(BodyProfileFactor(
                field: field,
                deviation: z,
                sampleCount: ordered.count,
                latestAt: latest.1
            ))
        }

        guard !factors.isEmpty else { return .neutral }
        let meanAbs = factors.reduce(0) { $0 + abs($1.deviation) } / Double(factors.count)

        // 有界修正：完全平稳 +3 / +2，剧烈波动 −6 / −4 / +6 压力。
        // 单份手动档案最多改变 6 分，不会盖过睡眠 / HRV 等客观主导项。
        let vitality = min(max(3.0 - 3.0 * meanAbs, -6.0), 3.0)
        let pleasure = min(max(2.0 - 2.0 * meanAbs, -4.0), 2.0)
        let stress = meanAbs > 0.8 ? Int(min((2.0 * meanAbs).rounded(), 6.0)) : 0

        return BodyProfileAdjustment(
            vitalityDelta: vitality,
            pleasureDelta: pleasure,
            stressDelta: stress,
            factors: factors,
            meanAbsoluteDeviation: meanAbs,
            hasUsableData: true,
            isStale: false
        )
    }

    /// 中性的中文状态措辞由 App 层给；Core 只提供阈值判定，方便单测钉住口径。
    public static func isStable(_ adjustment: BodyProfileAdjustment) -> Bool {
        adjustment.hasUsableData && adjustment.meanAbsoluteDeviation < 0.5
    }
}
