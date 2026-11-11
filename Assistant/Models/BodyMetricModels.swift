import AssistantCore
import Foundation
import SwiftData

// MARK: - 身体基础档案（单例式）

/// 用户手动维护的身体基础档案：身高 / 出生日期（年龄由 Core 推导）/ 生理性别。
///
/// 设计约束：
/// - **年龄不落库**。存一个会过期的数字，明年不打开 App 也不会自己变；
///   存出生日期、由 `BodyMetricCalculator.age(birthDate:now:calendar:)` 现算。
/// - **不与健康快照 / 待办建立任何 @Relationship**。历史上向已存在的 @Model
///   追加指向新模型的关系会让 V1~V13 共用运行时类型时迁移失败（白屏），
///   因此本模块全部是独立表，靠 `id` 软关联即可。
/// - 全局只应有一条档案；视图层用 `ensureProfile(in:)` 幂等取用，
///   不靠「取数组第一个」这种在多条脏数据下会随机漂移的写法。
@Model
public final class BodyMetricProfile {
    public var id: UUID
    /// 身高（cm）。未填为 nil，不写 0——0 会被当成「量过、身高 0」。
    public var heightCm: Double?
    /// 出生日期。未填为 nil；未来日期在 UI 层由 Core 校验拦下。
    public var birthDate: Date?
    /// 生理性别原始值（可选）。Core 不认识 App 枚举，存原始字符串。
    public var biologicalSexRaw: String?
    /// 备注（如过敏史、既往病史等用户自愿填写的自由文本）。
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        heightCm: Double? = nil,
        birthDate: Date? = nil,
        biologicalSexRaw: String? = nil,
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.heightCm = heightCm
        self.birthDate = birthDate
        self.biologicalSexRaw = biologicalSexRaw
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// 计算成员放 extension：@Model 宏只处理存储属性，减少宏展开的可见面。
extension BodyMetricProfile {
    /// 幂等取全局档案：有多条时只保留最早一条并删除其余，
    /// 避免「随机取到一条」导致用户改了身高却看着没变化。
    @MainActor
    public static func ensureProfile(in context: ModelContext) -> BodyMetricProfile {
        let descriptor = FetchDescriptor<BodyMetricProfile>(
            sortBy: [SortDescriptor(\BodyMetricProfile.createdAt, order: .forward)]
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        if let first = existing.first {
            if existing.count > 1 {
                for duplicate in existing.dropFirst() {
                    context.delete(duplicate)
                }
            }
            return first
        }
        let profile = BodyMetricProfile()
        context.insert(profile)
        return profile
    }
}

// MARK: - 体征记录（时间序列）

/// 一次手动录入的体征快照。
///
/// 各字段全部可选：用户可能只量了血压，也可能只称了体重。
/// **空记录禁止入库**（由 `BodyMetricValidator.validate` 保证），否则趋势与
/// 「最近一次」会被一堆只有时间没有数值的空壳挤掉。
///
/// 数值合法性范围只用于挡住明显输错（多打一位、单位填错），
/// 本模型与 Core 规则**都不做医学分级或诊断**。
@Model
public final class BodyVitalRecord {
    public var id: UUID
    public var measuredAt: Date

    public var weightKg: Double?
    public var systolic: Double?
    public var diastolic: Double?
    public var heartRate: Double?
    public var bloodGlucose: Double?
    public var bodyTemperature: Double?
    public var bloodOxygen: Double?
    public var bodyFat: Double?

    public var note: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        measuredAt: Date = .now,
        weightKg: Double? = nil,
        systolic: Double? = nil,
        diastolic: Double? = nil,
        heartRate: Double? = nil,
        bloodGlucose: Double? = nil,
        bodyTemperature: Double? = nil,
        bloodOxygen: Double? = nil,
        bodyFat: Double? = nil,
        note: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.weightKg = weightKg
        self.systolic = systolic
        self.diastolic = diastolic
        self.heartRate = heartRate
        self.bloodGlucose = bloodGlucose
        self.bodyTemperature = bodyTemperature
        self.bloodOxygen = bloodOxygen
        self.bodyFat = bodyFat
        self.note = note
        self.createdAt = createdAt
    }
}

// 计算成员放 extension：@Model 宏只处理存储属性。
extension BodyVitalRecord {
    /// 转成 Core 的纯值输入。字段映射集中在这一处，避免视图和快照各写一份。
    public var metricValues: [BodyMetricField: Double] {
        var values: [BodyMetricField: Double] = [:]
        if let weightKg { values[.weightKg] = weightKg }
        if let systolic { values[.systolic] = systolic }
        if let diastolic { values[.diastolic] = diastolic }
        if let heartRate { values[.heartRate] = heartRate }
        if let bloodGlucose { values[.bloodGlucose] = bloodGlucose }
        if let bodyTemperature { values[.bodyTemperature] = bodyTemperature }
        if let bloodOxygen { values[.bloodOxygen] = bloodOxygen }
        if let bodyFat { values[.bodyFat] = bodyFat }
        return values
    }

    /// 用 Core 校验通过的一组值回写；未在集合里的字段一律清空。
    public func apply(values: [BodyMetricField: Double]) {
        weightKg = values[.weightKg]
        systolic = values[.systolic]
        diastolic = values[.diastolic]
        heartRate = values[.heartRate]
        bloodGlucose = values[.bloodGlucose]
        bodyTemperature = values[.bodyTemperature]
        bloodOxygen = values[.bloodOxygen]
        bodyFat = values[.bodyFat]
    }

    /// 本条记录填了几个字段，供历史列表显示「本次记了 3 项」。
    public var filledFieldCount: Int { metricValues.count }
}

// MARK: - 展示元数据（App 层文案，Core 只给标识符与单位）

/// 身体指标的中文名与图标。与 `BodyMetricField` 一一对应，
/// 新增字段时漏了这里会编译报错（switch 穷尽）。
public enum BodyMetricDisplay {
    public static func name(_ field: BodyMetricField) -> String {
        switch field {
        case .weightKg: return "体重"
        case .systolic: return "收缩压"
        case .diastolic: return "舒张压"
        case .heartRate: return "心率"
        case .bloodGlucose: return "血糖"
        case .bodyTemperature: return "体温"
        case .bloodOxygen: return "血氧"
        case .bodyFat: return "体脂率"
        }
    }

    public static func icon(_ field: BodyMetricField) -> String {
        switch field {
        case .weightKg: return "scalemass.fill"
        case .systolic, .diastolic: return "heart.pulse.fill"
        case .heartRate: return "heart.fill"
        case .bloodGlucose: return "drop.fill"
        case .bodyTemperature: return "thermometer.medium"
        case .bloodOxygen: return "lungs.fill"
        case .bodyFat: return "figure.stand"
        }
    }

    /// 录入提示。只说明单位与量法，不给任何「正常值」暗示。
    public static func hint(_ field: BodyMetricField) -> String {
        switch field {
        case .weightKg: return "单位 kg"
        case .systolic: return "高压 · mmHg"
        case .diastolic: return "低压 · mmHg"
        case .heartRate: return "静息或即时心率 · 次/分"
        case .bloodGlucose: return "mmol/L"
        case .bodyTemperature: return "°C"
        case .bloodOxygen: return "%"
        case .bodyFat: return "%"
        }
    }
}
