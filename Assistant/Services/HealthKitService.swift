import AssistantCore
import Foundation
import HealthKit

/// Apple 健康（HealthKit）只读接入服务。
///
/// ## 范围
/// 只**读**步数、活动能量、饮水、睡眠四类数据，喂给 `exercise`/`hydration`/`medication`
/// 三类待办的打卡页。**不写入**任何健康数据（`toShare` 传空集），
/// 因此不需要 `NSHealthUpdateUsageDescription` 之外的写权限负担。
///
/// ## 三条必须记住的 HealthKit 事实
/// 1. **App 无法查询自己的读权限状态**。这是 Apple 的隐私设计：拒绝读取后，
///    查询静默返回空，与「已授权但今天没数据」表现完全一致。
///    因此本服务**不提供** `isAuthorized` 这类字段，只暴露
///    `HealthReadState`（未请求过 / 请求过但无数据 / 有数据）。
/// 2. `requestAuthorization` 的 `success` 只表示**权限面板处理完成**，
///    不表示用户同意了。把它当成「已授权」是 HealthKit 最常见的误用。
/// 3. iPad 等设备上 `HKHealthStore.isHealthDataAvailable()` 为 false，
///    必须先查再操作，否则会抛异常。
///
/// ## 后台投递
/// 本工程**不使用** `enableBackgroundDelivery`：免费个人团队的 provisioning profile
/// 不支持 HealthKit 后台投递能力，且 7 天重签会让后台注册频繁失效。
/// 改为前台按需拉取（进入页面 / 回前台时），配合本地快照缓存。
@MainActor
final class HealthKitService: ObservableObject {
    static let shared = HealthKitService()

    /// 当前读到的当日快照。`nil` 表示尚未拉取过。
    @Published private(set) var snapshot: HealthDaySnapshot?
    /// 拉取失败时的可诊断描述（面向开发者，不直接展示给用户）。
    @Published private(set) var lastError: String?
    /// 是否正在拉取。
    @Published private(set) var isLoading = false
    /// 是否已向用户发起过授权请求。
    @Published private(set) var hasRequestedAuthorization = false

    private let store = HKHealthStore()
    private let calendar = Calendar.current
    /// 本次刷新中各子查询的错误描述。多个指标同时失败时全部保留，
    /// 便于定位是「全部读不到」还是「只有某一项失败」。
    private var errors: [String] = []

    private init() {}

    // MARK: - 能力可用性

    /// 本设备是否支持健康数据。
    /// iPad（及未支持 HealthKit 的设备）返回 false，此时 UI 应整体隐藏健康入口。
    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 只读数据集：步数、活动能量、饮水。
    /// 睡眠是分类样本，单独在 `sleepHours` 里查。
    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let step = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(step) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        if let water = HKObjectType.quantityType(forIdentifier: .dietaryWater) { types.insert(water) }
        return types
    }

    private var sleepType: HKCategoryType? {
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    }

    // MARK: - 授权

    /// 请求读权限。
    ///
    /// - 返回值 `true` 表示**权限面板已处理完毕**，**不代表用户同意了读取**。
    ///   Apple 出于隐私考虑不向 App 暴露读权限的真实结果，
    ///   因此本方法不试图解析授权结果，只把「已发起过请求」这一事实记录下来。
    /// - 拒绝授权不会抛出错误，表现为后续查询返回空。
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard Self.isAvailable else {
            lastError = "设备不支持健康数据"
            return false
        }
        var types = readTypes
        if let sleep = sleepType { types.insert(sleep) }

        do {
            // toShare 传空集：本 App 只读，不写任何健康数据。
            try await store.requestAuthorization(toShare: [], read: types)
            hasRequestedAuthorization = true
            lastError = nil
            return true
        } catch {
            hasRequestedAuthorization = true
            lastError = describe(error)
            return false
        }
    }

    /// 当前是否需要向用户展示授权面板。
    /// `unnecessary` 表示系统认为已做出过选择（无论同意还是拒绝），此时不该再弹面板。
    func needsAuthorizationRequest() async -> Bool {
        guard Self.isAvailable else { return false }
        var types = readTypes
        if let sleep = sleepType { types.insert(sleep) }
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: types)
            return status == .shouldRequest
        } catch {
            lastError = describe(error)
            return false
        }
    }

    // MARK: - 查询

    /// 拉取当天的健康指标快照。
    ///
    /// 查询失败时**保留上一次快照**并记录错误，不把已有数据清空——
    /// 一次网络/数据库抖动不该让用户已经看到的数字消失。
    @discardableResult
    func refreshToday() async -> HealthDaySnapshot? {
        guard Self.isAvailable else {
            lastError = "设备不支持健康数据"
            return snapshot
        }
        isLoading = true
        errors = []
        defer { isLoading = false }

        let startOfDay = calendar.startOfDay(for: .now)

        // 步数 / 活动能量 / 饮水：当日累计求和
        // 三个子查询各自吞掉异常并把描述记进 errors，避免单个指标失败拖垮整次刷新
        async let steps = cumulativeSum(for: .stepCount, unit: .count(), start: startOfDay)
        async let energy = cumulativeSum(for: .activeEnergy, unit: .kilocalorie(), start: startOfDay)
        async let water = cumulativeSum(for: .dietaryWater, unit: .literUnit(with: .milli), start: startOfDay)
        // 睡眠：昨晚到今天醒来的时长
        async let sleep = sleepHours(start: startOfDay)

        var values: [HealthMetricValue] = []
        if let stepValue = await steps { values.append(stepValue) }
        if let energyValue = await energy { values.append(energyValue) }
        if let waterValue = await water { values.append(waterValue) }
        if let sleepValue = await sleep { values.append(sleepValue) }

        let newSnapshot = HealthMetrics.aggregate(values, day: startOfDay)
        // 读到空结果时保留旧快照，避免抖动把已有数据抹掉
        if newSnapshot.readState == .hasData || snapshot == nil {
            snapshot = newSnapshot
        } else if let existing = snapshot {
            snapshot = HealthMetrics.mergeSnapshot(existing, newSnapshot)
        }
        // 保留子查询记录的错误描述：整次刷新成功不代表每个指标都成功
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return snapshot
    }

    /// 某项数量型指标当天的累计值。
    private func cumulativeSum(for kind: HealthMetricKind,
                               unit: HKUnit,
                               start: Date) async -> HealthMetricValue? {
        guard let type = HKObjectType.quantityType(forIdentifier: quantityIdentifier(for: kind)) else {
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        do {
            guard let statistics = try await descriptor.result(for: store),
                  let sum = statistics.sumQuantity() else { return nil }
            let value = sum.doubleValue(for: unit)
            // 累计值非负；出现负数说明数据异常，直接丢弃而不是展示荒谬数字
            guard value >= 0 else { return nil }
            return HealthMetricValue(kind: kind, value: value, day: start)
        } catch {
            errors.append(describe(error))
            return nil
        }
    }

    /// 昨夜睡眠时长（小时）。
    ///
    /// 口径：从昨天中午到今天中午之间，累加处于「已入睡」状态的样本时长。
    /// **只统计 asleep 类样本，不统计 `inBed`（在床上）**——后者与 asleep 区间重叠，
    /// 一起累加会让睡眠时长翻倍。
    private func sleepHours(start: Date) async -> HealthMetricValue? {
        guard let type = sleepType else { return nil }
        // 从昨天中午开始，覆盖前一晚入睡到今天醒来的完整窗口
        let windowStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: .now, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: []
        )
        do {
            let samples = try await descriptor.result(for: store)
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            var totalSeconds: TimeInterval = 0
            for sample in samples {
                guard asleepValues.contains(sample.value) else { continue }
                totalSeconds += sample.endDate.timeIntervalSince(sample.startDate)
            }
            guard totalSeconds > 0 else { return nil }
            let hours = totalSeconds / 3600.0
            return HealthMetricValue(kind: .sleep, value: hours, day: start)
        } catch {
            errors.append(describe(error))
            return nil
        }
    }

    private func quantityIdentifier(for kind: HealthMetricKind) -> HKQuantityTypeIdentifier {
        switch kind {
        case .stepCount: return .stepCount
        case .activeEnergy: return .activeEnergyBurned
        case .dietaryWater: return .dietaryWater
        case .sleep: return .stepCount // 睡眠不走数量型分支
        }
    }

    // MARK: - 错误描述

    /// 把底层错误翻译成可诊断的中文描述。
    /// 严格区分「权限被拒」与「数据不存在」——两者在 HealthKit 里的表现不同。
    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == "com.apple.healthkit" else {
            return nsError.localizedDescription
        }
        switch nsError.code {
        case 4:
            return "缺少 HealthKit entitlement（com.apple.developer.healthkit）"
        case 5:
            return "健康数据事务失败，通常是授权流程尚未完成就发起了查询"
        default:
            return "健康数据读取失败：\(nsError.localizedDescription)"
        }
    }
}
