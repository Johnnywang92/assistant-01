import Foundation

// MARK: - 身体指标字段

/// 一次手动体征记录里可能出现的字段。
///
/// **只作记录与趋势展示，不做任何医学分级或诊断。** `rawValue` 是英文标识符，
/// 中文名由 App 层翻译（Core 不持有本地化文案，也不把 rawValue 当本地化 key）。
/// 新增字段时只需在这里加 case + 范围/单位，UI 与备份会自动跟着走。
public enum BodyMetricField: String, Codable, CaseIterable, Hashable, Sendable {
    case weightKg
    case systolic
    case diastolic
    case heartRate
    case bloodGlucose
    case bodyTemperature
    case bloodOxygen
    case bodyFat

    /// 展示单位（中文界面直接拼在数值后）。
    public var unit: String {
        switch self {
        case .weightKg: return "kg"
        case .systolic, .diastolic: return "mmHg"
        case .heartRate: return "次/分"
        case .bloodGlucose: return "mmol/L"
        case .bodyTemperature: return "°C"
        case .bloodOxygen, .bodyFat: return "%"
        }
    }

    /// 数值小数位。血压/心率是整数，体温/体重/血糖保留一位。
    public var decimalPlaces: Int {
        switch self {
        case .systolic, .diastolic, .heartRate: return 0
        case .weightKg, .bloodGlucose, .bodyTemperature, .bloodOxygen, .bodyFat: return 1
        }
    }

    /// **可录入范围**，只用来挡住明显输错的值（多打一位、单位填错），
    /// 不是「正常值范围」，绝不用于判断健康与否。
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .weightKg: return 2...400
        case .systolic: return 40...300
        case .diastolic: return 20...200
        case .heartRate: return 20...250
        case .bloodGlucose: return 1...50
        case .bodyTemperature: return 30...45
        case .bloodOxygen: return 50...100
        case .bodyFat: return 1...80
        }
    }
}

// MARK: - 录入校验

/// 手动体征录入的校验结果。
public enum BodyMetricValidation: Equatable, Sendable {
    case valid
    /// 数值超出「可录入范围」。associated value 是出问题的字段，供 UI 定位输入框。
    case outOfPlausibleRange(BodyMetricField)
    /// 血压收缩压必须严格大于舒张压。
    case systolicNotAboveDiastolic
    /// 收缩压与舒张压必须成对填写。
    case incompleteBloodPressure
    /// 一次记录至少要有一个指标，否则会存进一条空白历史。
    case emptyRecord

    /// 稳定的英文标识符，供日志/埋点使用；中文文案由 App 层给。
    public var identifier: String {
        switch self {
        case .valid: return "valid"
        case .outOfPlausibleRange(let field): return "outOfPlausibleRange.\(field.rawValue)"
        case .systolicNotAboveDiastolic: return "systolicNotAboveDiastolic"
        case .incompleteBloodPressure: return "incompleteBloodPressure"
        case .emptyRecord: return "emptyRecord"
        }
    }
}

public enum BodyMetricValidator {

    /// 身高可录入范围（cm）。同样只挡输错，不表示健康区间。
    public static let heightRange: ClosedRange<Double> = 30...250

    /// 出生日期不能晚于 `now`（显式注入，不读墙上时钟）。
    public static func isPlausibleBirthDate(_ date: Date, now: Date) -> Bool {
        date <= now
    }

    public static func isPlausibleHeight(_ centimeters: Double) -> Bool {
        heightRange.contains(centimeters)
    }

    /// 校验一次体征录入。
    ///
    /// - 空记录不许入库：留下一堆「只有时间、没有数值」的历史，
    ///   趋势与「最近一次」都会被这些空壳挤掉，是典型的静默数据污染。
    /// - 血压必须成对，且收缩压严格大于舒张压。只约束**数值关系**，
    ///   不对数值本身下任何医学结论。
    public static func validate(_ values: [BodyMetricField: Double]) -> BodyMetricValidation {
        guard !values.isEmpty else { return .emptyRecord }

        for (field, value) in values {
            guard field.plausibleRange.contains(value), value.isFinite else {
                return .outOfPlausibleRange(field)
            }
        }

        let systolic = values[.systolic]
        let diastolic = values[.diastolic]
        if (systolic == nil) != (diastolic == nil) {
            return .incompleteBloodPressure
        }
        if let systolic, let diastolic, systolic <= diastolic {
            return .systolicNotAboveDiastolic
        }
        return .valid
    }
}

// MARK: - 派生数值

public enum BodyMetricCalculator {

    /// 周岁年龄。`now` 与 `calendar` 必须显式传入，禁止读系统时钟，
    /// 否则「同一条档案在跨年那天给出两个年龄」无法复现测试。
    /// 未来日期返回 nil（不猜、不钳到 0）。
    public static func age(birthDate: Date?, now: Date, calendar: Calendar) -> Int? {
        guard let birthDate, birthDate <= now else { return nil }
        return calendar.dateComponents([.year], from: birthDate, to: now).year
    }

    /// BMI = 体重(kg) / 身高(m)²。两个输入缺一或非法时返回 nil，
    /// **不会**用「上次体重」「平均身高」之类的兜底值凑一个数。
    public static func bmi(weightKg: Double?, heightCm: Double?) -> Double? {
        guard let weightKg, let heightCm,
              weightKg > 0, heightCm > 0,
              weightKg.isFinite, heightCm.isFinite,
              BodyMetricValidator.isPlausibleHeight(heightCm) else { return nil }
        let meters = heightCm / 100
        let value = weightKg / (meters * meters)
        return value.isFinite ? value : nil
    }

    /// 格式化展示（不带单位），UI 自己拼 `field.unit`。
    public static func display(_ value: Double, field: BodyMetricField) -> String {
        String(format: "%.\(field.decimalPlaces)f", value)
    }

    /// 身高展示（cm，一位小数）。身高属于**基础档案**而非某次体征记录，
    /// 不在 `BodyMetricField` 里，但格式口径同样只在 Core 定义一次，
    /// 禁止 App 借用体重的字段来格式化身高。
    public static func displayHeight(_ centimeters: Double) -> String {
        String(format: "%.1f", centimeters)
    }

    /// BMI 展示（一位小数）。BMI 也不是一次「测量记录」，同样有独立格式口径；
    /// 不给任何分档标签（正常 / 偏重等），只输出数值本身。
    public static func displayBMI(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - 趋势

/// 单条体征样本（Core 的纯值输入，App 把 @Model 映射进来）。
public struct BodyMetricSample: Hashable, Sendable {
    public let measuredAt: Date
    public let values: [BodyMetricField: Double]

    public init(measuredAt: Date, values: [BodyMetricField: Double]) {
        self.measuredAt = measuredAt
        self.values = values
    }
}

public enum BodyMetricTrendDirection: String, Sendable {
    case rising
    case falling
    case steady
}

/// 某个字段的趋势事实。**只有 >= 3 个有效样本才给方向**（与周期报告同口径：
/// 两点连成线不叫趋势），不足时返回 nil，让 UI 显示「继续记录以查看趋势」。
public struct BodyMetricTrend: Equatable, Sendable {
    public let field: BodyMetricField
    public let sampleCount: Int
    public let earliest: Double
    public let latest: Double
    public let change: Double
    public let direction: BodyMetricTrendDirection
    public let earliestAt: Date
    public let latestAt: Date
}

public enum BodyMetricTrendBuilder {

    public static let minimumSamples = 3

    /// 构建趋势。`samples` 无需预先排序；内部按 `measuredAt` 升序，
    /// 同刻用原始下标兜底（`Array.sorted` 不稳定，同刻记录会随机换位）。
    ///
    /// 变化量小于半个显示精度时算 `steady`，避免「67.0 → 67.0」被报成上升。
    public static func build(
        field: BodyMetricField,
        samples: [BodyMetricSample]
    ) -> BodyMetricTrend? {
        let indexed = samples.enumerated().compactMap { index, sample -> (Int, Date, Double)? in
            guard let value = sample.values[field], value.isFinite else { return nil }
            return (index, sample.measuredAt, value)
        }
        guard indexed.count >= minimumSamples else { return nil }

        let ordered = indexed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        guard let first = ordered.first, let last = ordered.last else { return nil }

        let change = last.2 - first.2
        let precision = field.decimalPlaces == 0 ? 0.5 : 0.05
        let direction: BodyMetricTrendDirection = change > precision ? .rising
            : change < -precision ? .falling : .steady

        return BodyMetricTrend(
            field: field,
            sampleCount: ordered.count,
            earliest: first.2,
            latest: last.2,
            change: change,
            direction: direction,
            earliestAt: first.1,
            latestAt: last.1
        )
    }

    /// 返回某字段**最近一次**有值的样本时刻与数值。
    /// 没有该字段的记录时返回 nil，绝不返回 0 冒充「最近测过」。
    public static func latest(
        field: BodyMetricField,
        samples: [BodyMetricSample]
    ) -> (at: Date, value: Double)? {
        let indexed = samples.enumerated().compactMap { index, sample -> (Int, Date, Double)? in
            guard let value = sample.values[field], value.isFinite else { return nil }
            return (index, sample.measuredAt, value)
        }
        let ordered = indexed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 > rhs.0
        }
        guard let newest = ordered.first else { return nil }
        return (newest.1, newest.2)
    }
}
