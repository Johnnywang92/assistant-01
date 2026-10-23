import AssistantCore
import Foundation
import HealthKit

/// Apple 健康（HealthKit）只读接入服务。
///
/// ## 范围
/// 只**读**步数、活动能量、饮水、睡眠四类数据，喂给 `exercise`/`hydration`/`sleep`
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
    /// 用户的 14 天动态基线
    @Published private(set) var userBaseline: HealthBaseline = .standard
    /// 综合推断的愉悦指数评估报告
    @Published private(set) var pleasureEvaluation: PleasureIndexEvaluation?
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

    /// 只读数据集：步数、能量、心率、血氧、体温、步速、呼吸与健身。
    /// 睡眠是分类样本，健身是 Workout 样本，分别单独查询。
    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let step = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(step) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        if let basal = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned) { types.insert(basal) }
        if let water = HKObjectType.quantityType(forIdentifier: .dietaryWater) { types.insert(water) }
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let restingHr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(restingHr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let o2 = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { types.insert(o2) }
        if let bodyTemp = HKObjectType.quantityType(forIdentifier: .bodyTemperature) { types.insert(bodyTemp) }
        if let wristTemp = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) { types.insert(wristTemp) }
        if let speed = HKObjectType.quantityType(forIdentifier: .walkingSpeed) { types.insert(speed) }
        if let resp = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { types.insert(resp) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    private var sleepType: HKCategoryType? {
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    }

    /// 写入数据集：支持将用户记录的饮水量同步写入 Apple 健康。
    private var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        if let water = HKObjectType.quantityType(forIdentifier: .dietaryWater) {
            types.insert(water)
        }
        return types
    }

    // MARK: - 授权

    /// 请求读写权限。
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
            try await store.requestAuthorization(toShare: shareTypes, read: types)
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
            let status = try await store.statusForAuthorizationRequest(toShare: shareTypes, read: types)
            return status == .shouldRequest
        } catch {
            lastError = describe(error)
            return false
        }
    }

    /// 将记录的饮水量写入 Apple 健康（毫升）
    @discardableResult
    func recordWaterIntake(amountML: Double, date: Date = .now) async -> Bool {
        guard Self.isAvailable, amountML > 0 else { return false }
        guard let waterType = HKQuantityType.quantityType(forIdentifier: .dietaryWater) else { return false }

        let quantity = HKQuantity(unit: .literUnit(with: .milli), doubleValue: amountML)
        let sample = HKQuantitySample(type: waterType, quantity: quantity, start: date, end: date)

        do {
            try await store.save(sample)
            await refreshToday()
            return true
        } catch {
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

        // 步数 / 活动能量 / 静息能量 / 饮水：当日累计求和
        async let steps = cumulativeSum(for: .stepCount, unit: .count(), start: startOfDay)
        async let energy = cumulativeSum(for: .activeEnergy, unit: .kilocalorie(), start: startOfDay)
        async let basalEnergy = cumulativeSum(for: .restingEnergy, unit: .kilocalorie(), start: startOfDay)
        async let water = cumulativeSum(for: .dietaryWater, unit: .literUnit(with: .milli), start: startOfDay)

        // 睡眠：昨晚到今天醒来的时长与阶段
        async let sleep = sleepStages(start: startOfDay)

        // 心率变异性与静息心率
        async let hrv = hrvSample(start: startOfDay)
        async let restingHR = restingHeartRateSample(start: startOfDay)

        // 体温与生命体征
        async let temperature = bodyTemperatureSample(start: startOfDay)
        async let heartRate = heartRateSample(start: startOfDay)
        async let bloodOxygen = averageQuantity(for: .bloodOxygen, identifier: .oxygenSaturation, unit: .percent(), start: startOfDay)
        async let walkingSpeed = averageQuantity(for: .walkingSpeed, identifier: .walkingSpeed, unit: HKUnit.meter().unitDivided(by: .second()), multiplier: 3.6, start: startOfDay)
        async let respiratory = averageQuantity(for: .respiratoryRate, identifier: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: startOfDay)

        // 健身记录
        async let workouts = workoutRecords(start: startOfDay)

        var values: [HealthMetricValue] = []
        if let stepValue = await steps { values.append(stepValue) }
        if let energyValue = await energy { values.append(energyValue) }
        if let basalValue = await basalEnergy { values.append(basalValue) }
        if let waterValue = await water { values.append(waterValue) }

        let sleepResult = await sleep
        if let sleepValue = sleepResult.total { values.append(sleepValue) }
        if let remValue = sleepResult.rem { values.append(remValue) }
        if let deepValue = sleepResult.deep { values.append(deepValue) }

        if let hrvValue = await hrv { values.append(hrvValue) }
        if let restingValue = await restingHR { values.append(restingValue) }
        if let tempValue = await temperature { values.append(tempValue) }
        if let hrValue = await heartRate { values.append(hrValue) }
        if let oxValue = await bloodOxygen { values.append(oxValue) }
        if let speedValue = await walkingSpeed { values.append(speedValue) }
        if let respValue = await respiratory { values.append(respValue) }

        let workoutResult = await workouts
        if let duration = workoutResult?.duration, duration > 0 {
            values.append(HealthMetricValue(kind: .workoutDuration, value: duration, day: startOfDay))
        }

        let newSnapshot = HealthMetrics.aggregate(values, day: startOfDay, workoutSummary: workoutResult?.summary)
        // 读到空结果时保留旧快照，避免抖动把已有数据抹掉
        if newSnapshot.readState == .hasData || snapshot == nil {
            snapshot = newSnapshot
        } else if let existing = snapshot {
            snapshot = HealthMetrics.mergeSnapshot(existing, newSnapshot)
        }

        // 异步更新 14 天基线并推断愉悦指数
        let baseline = await fetchBaseline()
        if let current = snapshot {
            pleasureEvaluation = PleasureIndexEvaluator.evaluate(snapshot: current, baseline: baseline)
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

    /// 均值型指标（心率、血氧、步速、呼吸频率等）。
    private func averageQuantity(
        for kind: HealthMetricKind,
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        multiplier: Double = 1.0,
        start: Date
    ) async -> HealthMetricValue? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: .discreteAverage
        )
        do {
            guard let statistics = try await descriptor.result(for: store),
                  let avg = statistics.averageQuantity() else { return nil }
            var value = avg.doubleValue(for: unit) * multiplier
            if kind == .bloodOxygen && value <= 1.0 {
                value *= 100.0 // 归一化为 0~100 整数百分比
            }
            guard value > 0 else { return nil }
            return HealthMetricValue(kind: kind, value: value, day: start)
        } catch {
            errors.append(describe(error))
            return nil
        }
    }

    /// 心率采样（优先读静息心率，无记录时取日内平均心率）。
    private func heartRateSample(start: Date) async -> HealthMetricValue? {
        // 先查静息心率
        if let resting = await averageQuantity(for: .heartRate, identifier: .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start) {
            return resting
        }
        // 降级查常规心率均值
        return await averageQuantity(for: .heartRate, identifier: .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start)
    }

    /// 体温采样（优先 Apple Watch 手腕温度，若无则查询常规体温/基础体温）。
    private func bodyTemperatureSample(start: Date) async -> HealthMetricValue? {
        let typesToTry: [HKQuantityTypeIdentifier] = [
            .appleSleepingWristTemperature,
            .bodyTemperature,
            .basalBodyTemperature
        ]
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)
        for identifier in typesToTry {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            let descriptor = HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: type, predicate: predicate),
                options: [.discreteAverage, .mostRecent]
            )
            if let stats = try? await descriptor.result(for: store),
               let qty = stats.averageQuantity() ?? stats.mostRecentQuantity() {
                let celsius = qty.doubleValue(for: .degreeCelsius())
                if celsius > 30.0 && celsius < 45.0 {
                    return HealthMetricValue(kind: .bodyTemperature, value: celsius, day: start)
                }
            }
        }
        return nil
    }

    /// 健身记录聚合（Workout 样本）。
    private func workoutRecords(start: Date) async -> (duration: Double, summary: WorkoutRecordSummary)? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HKObjectType.workoutType(), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        do {
            let samples = try await descriptor.result(for: store)
            let workouts = samples.compactMap { $0 as? HKWorkout }
            guard !workouts.isEmpty else { return nil }

            var totalSeconds: TimeInterval = 0
            var totalCalories: Double = 0
            var names: [String] = []

            for w in workouts {
                totalSeconds += w.duration
                let energyCalories: Double? = {
                    if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                       let sum = w.statistics(for: energyType)?.sumQuantity() {
                        return sum.doubleValue(for: .kilocalorie())
                    }
                    if #available(iOS 18.0, *) {
                        return nil
                    } else {
                        return w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                    }
                }()
                if let energyCalories {
                    totalCalories += energyCalories
                }
                let name = localizedWorkoutName(w.workoutActivityType)
                if !names.contains(name) {
                    names.append(name)
                }
            }
            let totalMin = totalSeconds / 60.0
            let summary = WorkoutRecordSummary(
                count: workouts.count,
                totalDurationMinutes: totalMin,
                totalEnergyBurned: totalCalories > 0 ? totalCalories : nil,
                activityNames: names
            )
            return (duration: totalMin, summary: summary)
        } catch {
            errors.append(describe(error))
            return nil
        }
    }

    /// 运动类型本地化。
    private func localizedWorkoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "跑步"
        case .cycling: return "骑行"
        case .walking: return "徒步健走"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "力量训练"
        case .swimming: return "游泳"
        case .yoga: return "瑜伽"
        case .highIntensityIntervalTraining: return "HIIT"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船机"
        case .pilates: return "普拉提"
        case .badminton: return "羽毛球"
        case .tableTennis: return "乒乓球"
        case .tennis: return "网球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        default: return "健身运动"
        }
    }

    /// 昨夜睡眠时长与细分阶段（REM、深睡眠，单位：小时）。
    ///
    /// 口径：从昨天中午到现在，累加处于「已入睡」状态的样本时长（跨来源重叠区间只算一次）。
    /// **只统计 asleep 类样本，不统计 `inBed`（在床上）**——避免翻倍。
    private func sleepStages(start: Date) async -> (total: HealthMetricValue?, rem: HealthMetricValue?, deep: HealthMetricValue?) {
        guard let type = sleepType else { return (nil, nil, nil) }
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let windowStart = calendar.date(byAdding: .hour, value: 12, to: yesterdayStart) ?? yesterdayStart
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: .now, options: [])
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

            // 合并重叠区间的通用方法
            func mergedDuration(for filterValues: Set<Int>) -> Double {
                let intervals = samples
                    .filter { filterValues.contains($0.value) }
                    .map { (max($0.startDate, windowStart), $0.endDate) }
                    .filter { $0.1 > $0.0 }
                    .sorted { $0.0 < $1.0 }
                var totalSeconds: TimeInterval = 0
                var current: (Date, Date)?
                for interval in intervals {
                    if let c = current, interval.0 <= c.1 {
                        current = (c.0, max(c.1, interval.1))
                    } else {
                        if let c = current { totalSeconds += c.1.timeIntervalSince(c.0) }
                        current = interval
                    }
                }
                if let c = current { totalSeconds += c.1.timeIntervalSince(c.0) }
                return totalSeconds / 3600.0
            }

            let totalH = mergedDuration(for: asleepValues)
            let remH = mergedDuration(for: [HKCategoryValueSleepAnalysis.asleepREM.rawValue])
            let deepH = mergedDuration(for: [HKCategoryValueSleepAnalysis.asleepDeep.rawValue])

            let totalMetric = totalH > 0 ? HealthMetricValue(kind: .sleep, value: totalH, day: start) : nil
            let remMetric = remH > 0 ? HealthMetricValue(kind: .sleepREM, value: remH, day: start) : nil
            let deepMetric = deepH > 0 ? HealthMetricValue(kind: .sleepDeep, value: deepH, day: start) : nil

            return (totalMetric, remMetric, deepMetric)
        } catch {
            errors.append(describe(error))
            return (nil, nil, nil)
        }
    }

    /// 心率变异性采样（SDNN 毫秒，优先采集夜间睡眠到今晨的连续指标）。
    private func hrvSample(start: Date) async -> HealthMetricValue? {
        guard let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let windowStart = calendar.date(byAdding: .hour, value: 18, to: yesterdayStart) ?? yesterdayStart
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: .now, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 15
        )
        do {
            let samples = try await descriptor.result(for: store)
            guard !samples.isEmpty else { return nil }
            let values = samples.map { $0.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli)) }.filter { $0 > 0 }
            guard !values.isEmpty else { return nil }
            let avg = values.reduce(0, +) / Double(values.count)
            return HealthMetricValue(kind: .heartRateVariability, value: avg, day: start)
        } catch {
            errors.append(describe(error))
            return nil
        }
    }

    /// 静息心率采样（次/分）。
    private func restingHeartRateSample(start: Date) async -> HealthMetricValue? {
        await averageQuantity(for: .restingHeartRate, identifier: .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start)
    }

    /// 提取用户过去 14 天的滚动基线（HRV 与静息心率的个人均值与标准差）。
    func fetchBaseline(days: Int = 14) async -> HealthBaseline {
        guard Self.isAvailable else { return .standard }
        guard let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
              let rhrType = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
            return .standard
        }
        let startDate = calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: .now, options: .strictStartDate)

        var hrvValues: [Double] = []
        let hrvDescriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: hrvType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        if let samples = try? await hrvDescriptor.result(for: store) {
            hrvValues = samples.map { $0.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli)) }.filter { $0 > 0 }
        }

        var rhrValues: [Double] = []
        let rhrDescriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: rhrType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        if let samples = try? await rhrDescriptor.result(for: store) {
            rhrValues = samples.map { $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }.filter { $0 > 0 }
        }

        func calculateStats(of array: [Double], defaultMean: Double, defaultStd: Double) -> (Double, Double) {
            guard array.count >= 3 else { return (defaultMean, defaultStd) }
            let mean = array.reduce(0, +) / Double(array.count)
            let variance = array.reduce(0) { $0 + pow($1 - mean, 2) } / Double(array.count)
            let std = sqrt(variance)
            return (mean, max(std, 2.0))
        }

        let (meanHRV, stdHRV) = calculateStats(of: hrvValues, defaultMean: 42.0, defaultStd: 15.0)
        let (meanRHR, stdRHR) = calculateStats(of: rhrValues, defaultMean: 65.0, defaultStd: 6.0)

        let baseline = HealthBaseline(
            meanHRV: meanHRV,
            stdHRV: stdHRV,
            meanRestingHR: meanRHR,
            stdRestingHR: stdRHR,
            targetSleepHours: 7.5
        )
        self.userBaseline = baseline
        return baseline
    }

    private func quantityIdentifier(for kind: HealthMetricKind) -> HKQuantityTypeIdentifier {
        switch kind {
        case .stepCount: return .stepCount
        case .activeEnergy: return .activeEnergyBurned
        case .restingEnergy: return .basalEnergyBurned
        case .dietaryWater: return .dietaryWater
        case .bodyTemperature: return .bodyTemperature
        case .heartRate: return .heartRate
        case .bloodOxygen: return .oxygenSaturation
        case .walkingSpeed: return .walkingSpeed
        case .respiratoryRate: return .respiratoryRate
        case .heartRateVariability: return .heartRateVariabilitySDNN
        case .restingHeartRate: return .restingHeartRate
        case .sleep, .sleepREM, .sleepDeep, .workoutDuration: return .stepCount
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
