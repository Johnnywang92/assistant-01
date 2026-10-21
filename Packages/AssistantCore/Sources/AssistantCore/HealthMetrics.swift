import Foundation

// MARK: - Apple 健康（HealthKit）只读接入的纯逻辑
//
// 为什么要下沉到 Core：app target 没有测试 scheme，写在 app 里的判定逻辑等于没有防线。
// 这里只放**不依赖 HealthKit 框架**的纯函数与数据模型，HealthKit 查询本身留在 app 侧。
//
// 贯穿全文件的一条铁律（来自 HealthKit 的隐私设计）：
// **App 无法查询自己的读权限状态**。用户拒绝读取后，查询会静默返回空，
// 与「已授权但今天确实没数据」在表现上完全一致。
// 因此本文件不做「已授权 / 未授权」二元判断，只描述「我们实际观察到了什么」，
// 避免 UI 谎报授权状态（参见 `HealthReadState`）。

// MARK: - 指标种类

/// 接入的只读指标种类。范围刻意收窄：只取能喂给现有待办类型的四项。
public enum HealthMetricKind: String, CaseIterable, Sendable {
    /// 步数（步）
    case stepCount
    /// 活动能量（千卡）
    case activeEnergy
    /// 饮水（毫升）
    case dietaryWater
    /// 睡眠时长（小时）
    case sleep

    /// 中文显示名。
    public var displayName: String {
        switch self {
        case .stepCount: return "步数"
        case .activeEnergy: return "活动能量"
        case .dietaryWater: return "饮水"
        case .sleep: return "睡眠"
        }
    }

    /// 图标名（SF Symbols）。
    public var iconName: String {
        switch self {
        case .stepCount: return "figure.walk"
        case .activeEnergy: return "flame.fill"
        case .dietaryWater: return "drop.fill"
        case .sleep: return "bed.double.fill"
        }
    }

    /// 该指标服务于哪一类待办。用于把健康侧数值与本地打卡待办关联起来。
    public var relatedTodoType: HealthRelatedTodoType {
        switch self {
        case .stepCount, .activeEnergy: return .exercise
        case .dietaryWater: return .hydration
        case .sleep: return .medication
        }
    }
}

/// 健康指标所服务的本地待办类型。
/// 取值与 app 侧 `TodoType` 的 rawValue 一致，但**不依赖 app 侧枚举**，
/// 避免 Core 反向依赖 UI 层（app 侧用 `TodoType(rawValue:)` 还原）。
public enum HealthRelatedTodoType: String, CaseIterable, Sendable {
    case exercise
    case hydration
    case medication

    public var displayName: String {
        switch self {
        case .exercise: return "运动提醒"
        case .hydration: return "喝水提醒"
        case .medication: return "服药提醒"
        }
    }
}

// MARK: - 单项指标值

/// 单项健康指标的一个观测值。
/// 用 `Double` 承载数值、`unit` 标识单位，避免为四种单位各造一个类型。
public struct HealthMetricValue: Equatable, Sendable {
    public let kind: HealthMetricKind
    /// 数值。单位随 `kind` 固定：步 / 千卡 / 毫升 / 小时。
    public let value: Double
    /// 该数值属于哪一天（按本地日历的日界）。睡眠归属到「醒来的那天」。
    public let day: Date

    public init(kind: HealthMetricKind, value: Double, day: Date) {
        self.kind = kind
        self.value = value
        self.day = day
    }
}

// MARK: - 目标

/// 单项指标的目标值与达成判定。
public struct HealthGoal: Equatable, Sendable {
    public let kind: HealthMetricKind
    /// 目标数值。单位与 `HealthMetricKind` 一致。
    public let target: Double

    public init(kind: HealthMetricKind, target: Double) {
        self.kind = kind
        self.target = target
    }

    /// 默认目标。取值参考一般成年人建议量，可在设置里覆盖。
    /// 睡眠目标取 7 小时下限——低于 7 小时即视为未达标，不做「越多越好」的处理
    /// （睡眠时长不是线性收益指标，多睡不等于更健康）。
    public static let defaults: [HealthGoal] = [
        HealthGoal(kind: .stepCount, target: 8000),
        HealthGoal(kind: .activeEnergy, target: 400),
        HealthGoal(kind: .dietaryWater, target: 2000),
        HealthGoal(kind: .sleep, target: 7)
    ]

    /// 目标是否有效（必须为正数，否则达成判定无意义）。
    public var isValid: Bool { target > 0 }
}

/// 某项指标的达成情况。
public struct HealthGoalProgress: Equatable, Sendable {
    public let goal: HealthGoal
    /// 实际值。`nil` 表示当天没有观测到该指标的数据。
    public let actual: Double?

    public init(goal: HealthGoal, actual: Double?) {
        self.goal = goal
        self.actual = actual
    }

    /// 完成比例（0...1）。无数据时返回 0。
    /// 上限截到 1，避免超额完成时进度条溢出。
    public var ratio: Double {
        guard let actual, goal.isValid else { return 0 }
        return min(max(actual / goal.target, 0), 1)
    }

    /// 是否达成。**无数据时一律为 false**——不能因为「没读到」就报「已达标」。
    public var isAchieved: Bool {
        guard let actual, goal.isValid else { return false }
        return actual >= goal.target
    }

    /// 达成状态的三态。UI 用它区分「达标 / 未达标 / 没数据」，
    /// 避免把「读不到」误渲染成「已完成」。
    ///
    /// 目标值非法（非正数）时同样归入 `.noData`：此时既无法判定达标，
    /// 也不该断言「未达标」——那是在没有依据时下结论。
    public var status: HealthGoalStatus {
        guard goal.isValid, actual != nil else { return .noData }
        return isAchieved ? .achieved : .notAchieved
    }
}

/// 目标达成状态。
public enum HealthGoalStatus: String, Sendable {
    case achieved
    case notAchieved
    /// 当天没有观测到数据（可能未授权，也可能确实没有记录）
    case noData
}

// MARK: - 读权限状态（关键：HealthKit 不允许查询读权限）

/// 对「读权限实际表现」的诚实描述。
///
/// **不要试图把它映射成「已授权 / 未授权」**——HealthKit 出于隐私设计不向 App
/// 暴露读权限状态，拒绝读取与无数据在表现上完全一致。
/// 只能区分「还没请求过」与「请求过了」：
/// - `.notDetermined`：从未调用过授权请求，用户没机会拒绝过
/// - `.requestedNoData`：请求过，但没读到任何数据（可能是拒绝了读取，也可能是真没数据）
/// - `.hasData`：请求过，且读到了数据
public enum HealthReadState: String, Sendable {
    case notDetermined
    case requestedNoData
    case hasData

    /// 是否已经向用户发过授权请求。
    public var hasRequested: Bool { self != .notDetermined }

    /// 是否实际读到了数据。
    public var hasData: Bool { self == .hasData }
}

// MARK: - 快照聚合

/// 一天的健康指标快照。同一 `day` 下的多项指标聚合在一起。
public struct HealthDaySnapshot: Equatable, Sendable {
    /// 归属日（当天 00:00）。
    public let day: Date
    /// 各项指标值。缺失的指标不在字典里。
    public let values: [HealthMetricKind: HealthMetricValue]

    public init(day: Date, values: [HealthMetricKind: HealthMetricValue]) {
        self.day = day
        self.values = values
    }

    /// 取某项指标值。
    public func value(for kind: HealthMetricKind) -> HealthMetricValue? {
        values[kind]
    }

    /// 读状态：任一指标有值即视为读到了数据。
    public var readState: HealthReadState {
        values.isEmpty ? .requestedNoData : .hasData
    }

    /// 空快照（请求过但什么都没读到）。
    public static func empty(day: Date) -> HealthDaySnapshot {
        HealthDaySnapshot(day: day, values: [:])
    }
}

// MARK: - 聚合与判定

/// 健康指标的计算与判定入口（全部为纯函数）。
public enum HealthMetrics {

    /// 把散落的单项观测合并成一天一份的快照。
    ///
    /// 同一指标同一天出现多次时取**求和**（步数、能量、饮水都是累计型）。
    /// 睡眠时长若多次上报也取最大值而非求和——见 `mergeSnapshot` 的处理。
    public static func aggregate(_ values: [HealthMetricValue], day: Date) -> HealthDaySnapshot {
        var buckets: [HealthMetricKind: Double] = [:]
        for value in values {
            buckets[value.kind, default: 0] += value.value
        }
        let merged = buckets.reduce(into: [HealthMetricKind: HealthMetricValue]()) { result, pair in
            result[pair.key] = HealthMetricValue(kind: pair.key, value: pair.value, day: day)
        }
        return HealthDaySnapshot(day: day, values: merged)
    }

    /// 合并同一天的两份快照（例：后台与前台各拉一次）。
    /// 累计型指标求和，睡眠取较大值（避免把同一晚睡眠算成两倍）。
    public static func mergeSnapshot(_ lhs: HealthDaySnapshot, _ rhs: HealthDaySnapshot) -> HealthDaySnapshot {
        var values = lhs.values
        for (kind, rhsValue) in rhs.values {
            guard let lhsValue = values[kind] else {
                values[kind] = rhsValue
                continue
            }
            let mergedValue: Double
            if kind == .sleep {
                mergedValue = max(lhsValue.value, rhsValue.value)
            } else {
                mergedValue = lhsValue.value + rhsValue.value
            }
            values[kind] = HealthMetricValue(kind: kind, value: mergedValue, day: lhs.day)
        }
        return HealthDaySnapshot(day: lhs.day, values: values)
    }

    /// 计算所有目标的达成情况。缺失指标的 `actual` 为 nil，状态为 `.noData`。
    public static func progress(for snapshot: HealthDaySnapshot,
                                goals: [HealthGoal] = HealthGoal.defaults) -> [HealthGoalProgress] {
        goals.map { goal in
            HealthGoalProgress(goal: goal, actual: snapshot.value(for: goal.kind)?.value)
        }
    }

    /// 某类待办对应的目标达成情况。
    /// 用于把「今天走了多少步」和「今天的运动待办」在 UI 上并排呈现。
    public static func progress(for todoType: HealthRelatedTodoType,
                                snapshot: HealthDaySnapshot,
                                goals: [HealthGoal] = HealthGoal.defaults) -> HealthGoalProgress? {
        goals.first { $0.kind.relatedTodoType == todoType }
            .map { HealthGoalProgress(goal: $0, actual: snapshot.value(for: $0.kind)?.value) }
    }

    /// 把数值格式化为带单位的可读文本。
    /// 睡眠保留一位小数（7.5 小时有意义），其余取整。
    public static func format(_ value: Double, for kind: HealthMetricKind) -> String {
        switch kind {
        case .stepCount:
            return "\(Int(value.rounded())) 步"
        case .activeEnergy:
            return "\(Int(value.rounded())) 千卡"
        case .dietaryWater:
            return "\(Int(value.rounded())) 毫升"
        case .sleep:
            return String(format: "%.1f 小时", value)
        }
    }

    /// 生成一句话摘要，供卡片与语音播报使用。
    /// 无数据时明确说「暂无数据」，**不编造数值**。
    public static func summary(for progress: HealthGoalProgress) -> String {
        switch progress.status {
        case .noData:
            return "暂无\(progress.goal.kind.displayName)数据"
        case .achieved:
            let actual = progress.actual ?? 0
            return "\(progress.goal.kind.displayName)已达标（\(format(actual, for: progress.goal.kind))）"
        case .notAchieved:
            let actual = progress.actual ?? 0
            let remaining = max(progress.goal.target - actual, 0)
            return "\(progress.goal.kind.displayName)还差 \(format(remaining, for: progress.goal.kind))"
        }
    }
}
