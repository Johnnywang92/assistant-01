import AssistantCore
import XCTest

final class PleasureIndexEvaluatorTests: XCTestCase {

    func testEmptySnapshotProducesSafeDefault() {
        let eval = PleasureIndexEvaluator.evaluate(snapshot: nil)
        XCTAssertEqual(eval.pleasureScore, 70)
        XCTAssertEqual(eval.state, .serene)
        XCTAssertEqual(eval.stressScore, 30)
        XCTAssertEqual(eval.stressLevel, .moderate)
        XCTAssertEqual(eval.autonomicBalance, .balanced)
        XCTAssertTrue(eval.details.isEmpty)
    }

    func testHighHRVAndOptimalSleepProducesEuphoricState() {
        let day = Date()
        let values: [HealthMetricKind: HealthMetricValue] = [
            .heartRateVariability: HealthMetricValue(kind: .heartRateVariability, value: 65.0, day: day), // baseline is 42, +1.5 std
            .restingHeartRate: HealthMetricValue(kind: .restingHeartRate, value: 54.0, day: day),        // baseline is 65, -1.8 std
            .sleep: HealthMetricValue(kind: .sleep, value: 7.8, day: day),
            .sleepREM: HealthMetricValue(kind: .sleepREM, value: 1.8, day: day), // ~23% REM
            .sleepDeep: HealthMetricValue(kind: .sleepDeep, value: 1.5, day: day), // ~19% Deep
            .stepCount: HealthMetricValue(kind: .stepCount, value: 8500, day: day)
        ]
        let snapshot = HealthDaySnapshot(day: day, values: values)

        let eval = PleasureIndexEvaluator.evaluate(snapshot: snapshot)

        XCTAssertGreaterThanOrEqual(eval.pleasureScore, 85)
        XCTAssertEqual(eval.state, .euphoric)
        XCTAssertLessThanOrEqual(eval.stressScore, 25)
        XCTAssertEqual(eval.stressLevel, .low)
        XCTAssertEqual(eval.autonomicBalance, .parasympatheticDominant)
        XCTAssertFalse(eval.details.isEmpty)
    }

    func testDepressedHRVAndPoorSleepProducesOverloadedOrFatiguedState() {
        let day = Date()
        let values: [HealthMetricKind: HealthMetricValue] = [
            .heartRateVariability: HealthMetricValue(kind: .heartRateVariability, value: 18.0, day: day), // baseline 42, -1.6 std
            .restingHeartRate: HealthMetricValue(kind: .restingHeartRate, value: 82.0, day: day),        // baseline 65, +2.8 std
            .sleep: HealthMetricValue(kind: .sleep, value: 4.2, day: day),                               // 睡眠严重短缺
            .sleepREM: HealthMetricValue(kind: .sleepREM, value: 0.3, day: day),
            .stepCount: HealthMetricValue(kind: .stepCount, value: 1500, day: day)
        ]
        let snapshot = HealthDaySnapshot(day: day, values: values)

        let eval = PleasureIndexEvaluator.evaluate(snapshot: snapshot)

        XCTAssertLessThanOrEqual(eval.pleasureScore, 40)
        XCTAssertTrue(eval.state == .fatigued || eval.state == .overloaded)
        XCTAssertGreaterThanOrEqual(eval.stressScore, 70)
        XCTAssertEqual(eval.autonomicBalance, .sympatheticDominant)
    }

    func testPartialDataWithOnlySleepCalculatesGracefully() {
        let day = Date()
        let values: [HealthMetricKind: HealthMetricValue] = [
            .sleep: HealthMetricValue(kind: .sleep, value: 8.0, day: day),
            .sleepREM: HealthMetricValue(kind: .sleepREM, value: 1.8, day: day),
            .stepCount: HealthMetricValue(kind: .stepCount, value: 7000, day: day)
        ]
        let snapshot = HealthDaySnapshot(day: day, values: values)

        let eval = PleasureIndexEvaluator.evaluate(snapshot: snapshot)

        XCTAssertGreaterThanOrEqual(eval.pleasureScore, 70)
        XCTAssertTrue(eval.state == .serene || eval.state == .euphoric)
        XCTAssertGreaterThanOrEqual(eval.sleepRecoveryScore, 85)
    }

    func testPartialDataWithOnlyHRVCalculatesGracefully() {
        let day = Date()
        let values: [HealthMetricKind: HealthMetricValue] = [
            .heartRateVariability: HealthMetricValue(kind: .heartRateVariability, value: 50.0, day: day),
            .restingHeartRate: HealthMetricValue(kind: .restingHeartRate, value: 62.0, day: day)
        ]
        let snapshot = HealthDaySnapshot(day: day, values: values)

        let eval = PleasureIndexEvaluator.evaluate(snapshot: snapshot)

        XCTAssertGreaterThanOrEqual(eval.pleasureScore, 60)
        XCTAssertLessThanOrEqual(eval.stressScore, 45)
    }

    func testCustomPersonalBaseline() {
        let day = Date()
        // 假设用户是一个日常 HRV 偏低的特殊个体（个人均值只有 28ms）
        let customBaseline = HealthBaseline(meanHRV: 28.0, stdHRV: 6.0, meanRestingHR: 70.0, stdRestingHR: 5.0)

        // 当他测得 32ms 时，相对于他自己是高于均值的良好状态
        let values: [HealthMetricKind: HealthMetricValue] = [
            .heartRateVariability: HealthMetricValue(kind: .heartRateVariability, value: 32.0, day: day),
            .restingHeartRate: HealthMetricValue(kind: .restingHeartRate, value: 68.0, day: day),
            .sleep: HealthMetricValue(kind: .sleep, value: 7.5, day: day)
        ]
        let snapshot = HealthDaySnapshot(day: day, values: values)

        let eval = PleasureIndexEvaluator.evaluate(snapshot: snapshot, baseline: customBaseline)

        // 经个人基线标准化后，自主神经得分应当是良好正向的
        XCTAssertGreaterThanOrEqual(eval.autonomicScore, 55)
        XCTAssertLessThanOrEqual(eval.stressScore, 50)
    }
}
