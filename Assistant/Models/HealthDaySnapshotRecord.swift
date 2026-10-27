import AssistantCore
import Foundation
import SwiftData

/// 每日健康指标快照（落库记录）。
///
/// HealthKit 每次查询返回的是「当天到目前为止」的累计值，无法回溯历史——
/// 不落库就没有睡眠/分数趋势。本模型把每日读到的快照按天持久化，
/// 与 Core 的 `HealthDaySnapshot` 一一对应。
///
/// ## 落库纪律
/// - **日唯一**：同一天重复刷新走 `upsert`，用 `HealthMetrics.mergeForStorage`
///   合并——新读到的指标覆盖旧值（全天累计重读），未读到的指标保留旧值（查询抖动不抹历史）。
/// - **缺失即缺失**：没读到的指标存 nil，**不用 0 顶替**——0 步与「没读到」在趋势里语义完全不同。
/// - **只写有数据的天**：空快照不建记录，趋势里无记录日 = 无数据点。
/// - 分数（活力分/愉悦分）**不落库**：活力分依赖当日饮食摄入，写入时点拿不全；
///   读趋势时用原始指标 + 当日 `FoodIntakeRecord` 现算，保证公式跨天一致。
@Model
public final class HealthDaySnapshotRecord {
    public var id: UUID
    /// 归属日（当天 00:00）。同一天只应有一条记录。
    public var day: Date

    // MARK: 指标（缺失为 nil，不伪造 0）

    /// 步数（步）
    public var stepCount: Double?
    /// 活动能量（千卡）
    public var activeEnergy: Double?
    /// 静息能量（千卡）
    public var restingEnergy: Double?
    /// 饮水（毫升）
    public var dietaryWater: Double?
    /// 睡眠时长（小时）
    public var sleepHours: Double?
    /// 快速眼动睡眠（小时）
    public var sleepREM: Double?
    /// 深度睡眠（小时）
    public var sleepDeep: Double?
    /// 心率（次/分）
    public var heartRate: Double?
    /// 静息心率（次/分）
    public var restingHeartRate: Double?
    /// 心率变异性（毫秒 SDNN）
    public var heartRateVariability: Double?
    /// 血氧（%）
    public var bloodOxygen: Double?
    /// 体温（℃）
    public var bodyTemperature: Double?
    /// 步行速度（km/h）
    public var walkingSpeed: Double?
    /// 呼吸频率（次/分）
    public var respiratoryRate: Double?
    /// 健身时长（分钟）
    public var workoutMinutes: Double?
    /// 健身次数
    public var workoutCount: Int?

    /// 最近一次落库时间
    public var updatedAt: Date

    public init(day: Date) {
        self.id = UUID()
        self.day = day
        self.updatedAt = .now
    }

    // MARK: - 快照互转

    /// 还原为 Core 快照（用于 `mergeForStorage` 合并与分数现算）。
    public func toSnapshot() -> HealthDaySnapshot {
        var values: [HealthMetricKind: HealthMetricValue] = [:]
        func put(_ kind: HealthMetricKind, _ v: Double?) {
            if let v { values[kind] = HealthMetricValue(kind: kind, value: v, day: day) }
        }
        put(.stepCount, stepCount)
        put(.activeEnergy, activeEnergy)
        put(.restingEnergy, restingEnergy)
        put(.dietaryWater, dietaryWater)
        put(.sleep, sleepHours)
        put(.sleepREM, sleepREM)
        put(.sleepDeep, sleepDeep)
        put(.heartRate, heartRate)
        put(.restingHeartRate, restingHeartRate)
        put(.heartRateVariability, heartRateVariability)
        put(.bloodOxygen, bloodOxygen)
        put(.bodyTemperature, bodyTemperature)
        put(.walkingSpeed, walkingSpeed)
        put(.respiratoryRate, respiratoryRate)
        put(.workoutDuration, workoutMinutes)
        let summary: WorkoutRecordSummary? = workoutCount.map {
            WorkoutRecordSummary(count: $0, totalDurationMinutes: workoutMinutes ?? 0)
        }
        return HealthDaySnapshot(day: day, values: values, workoutSummary: summary)
    }

    /// 把快照写进本记录（nil 字段保持不动，由 `mergeForStorage` 保证合并语义正确）。
    public func apply(_ snapshot: HealthDaySnapshot) {
        if let v = snapshot.value(for: .stepCount)?.value { stepCount = v }
        if let v = snapshot.value(for: .activeEnergy)?.value { activeEnergy = v }
        if let v = snapshot.value(for: .restingEnergy)?.value { restingEnergy = v }
        if let v = snapshot.value(for: .dietaryWater)?.value { dietaryWater = v }
        if let v = snapshot.value(for: .sleep)?.value { sleepHours = v }
        if let v = snapshot.value(for: .sleepREM)?.value { sleepREM = v }
        if let v = snapshot.value(for: .sleepDeep)?.value { sleepDeep = v }
        if let v = snapshot.value(for: .heartRate)?.value { heartRate = v }
        if let v = snapshot.value(for: .restingHeartRate)?.value { restingHeartRate = v }
        if let v = snapshot.value(for: .heartRateVariability)?.value { heartRateVariability = v }
        if let v = snapshot.value(for: .bloodOxygen)?.value { bloodOxygen = v }
        if let v = snapshot.value(for: .bodyTemperature)?.value { bodyTemperature = v }
        if let v = snapshot.value(for: .walkingSpeed)?.value { walkingSpeed = v }
        if let v = snapshot.value(for: .respiratoryRate)?.value { respiratoryRate = v }
        if let v = snapshot.value(for: .workoutDuration)?.value { workoutMinutes = v }
        if let count = snapshot.workoutSummary?.count {
            self.workoutCount = count
        }
    }

    // MARK: - 落库入口

    /// 把当日快照落库（幂等）：同一天先查旧记录，经 `mergeForStorage` 合并后写回。
    ///
    /// - Returns: 是否保存成功。失败时**不抛崩溃**，由调用方记录诊断信息——
    ///   落库失败不该打断健康页刷新，但也绝不能谎报成功。
    @discardableResult
    public static func upsert(
        day: Date,
        snapshot: HealthDaySnapshot,
        in context: ModelContext
    ) -> Bool {
        // 空快照不建记录：趋势里「无记录日」与「有记录但没睡眠」语义不同
        guard snapshot.readState == .hasData else { return true }

        let startOfDay = Calendar.current.startOfDay(for: day)
        var descriptor = FetchDescriptor<HealthDaySnapshotRecord>(
            predicate: #Predicate { $0.day == startOfDay }
        )
        descriptor.fetchLimit = 1
        let existing = (try? context.fetch(descriptor))?.first

        let merged = existing.map {
            HealthMetrics.mergeForStorage(previous: $0.toSnapshot(), new: snapshot)
        } ?? snapshot

        let record = existing ?? HealthDaySnapshotRecord(day: startOfDay)
        record.apply(merged)
        record.updatedAt = .now
        if existing == nil {
            context.insert(record)
        }
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
