import XCTest
@testable import AssistantCore

final class VitalityEvaluatorTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_780_300_800)

    private func value(_ kind: HealthMetricKind, _ v: Double) -> HealthMetricValue {
        HealthMetricValue(kind: kind, value: v, day: day)
    }

    func testEmptyDataProducesDefaultBalancedVitality() {
        let result = VitalityEvaluator.evaluate(snapshot: nil, foodIntakeCalories: nil)
        XCTAssertEqual(result.score, 65)
        XCTAssertEqual(result.level, .balanced)
        XCTAssertTrue(result.highlights.isEmpty)
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertFalse(result.suggestion.isEmpty)
    }

    func testPeakVitalityWithGoodSleepWorkoutAndBalancedEnergy() {
        let snapshot = HealthDaySnapshot(
            day: day,
            values: [
                .sleep: value(.sleep, 7.8),
                .activeEnergy: value(.activeEnergy, 450),
                .restingEnergy: value(.restingEnergy, 1600),
                .stepCount: value(.stepCount, 10500),
                .heartRate: value(.heartRate, 62),
                .bloodOxygen: value(.bloodOxygen, 98),
                .bodyTemperature: value(.bodyTemperature, 36.6),
                .walkingSpeed: value(.walkingSpeed, 4.8)
            ],
            workoutSummary: WorkoutRecordSummary(count: 1, totalDurationMinutes: 40, totalEnergyBurned: 350, activityNames: ["跑步"])
        )

        // 摄入 2100，消耗 1600 + 450 = 2050，差值 +50 kcal（完美收支平衡）
        let result = VitalityEvaluator.evaluate(snapshot: snapshot, foodIntakeCalories: 2100)

        XCTAssertGreaterThanOrEqual(result.score, 85)
        XCTAssertEqual(result.level, .peak)
        XCTAssertEqual(result.energyBalance.netDifference, 50)
        XCTAssertFalse(result.highlights.isEmpty)
        XCTAssertTrue(result.highlights.contains { $0.title == "能量平衡" })
        XCTAssertTrue(result.highlights.contains { $0.title == "睡眠恢复" })
        XCTAssertTrue(result.highlights.contains { $0.title == "健身与活动" })
        XCTAssertTrue(result.highlights.contains { $0.title == "核心体征" })
    }

    func testSevereSleepDeprivationAndHighDeficitLowersScore() {
        let snapshot = HealthDaySnapshot(
            day: day,
            values: [
                .sleep: value(.sleep, 4.2),
                .activeEnergy: value(.activeEnergy, 600),
                .restingEnergy: value(.restingEnergy, 1600),
                .heartRate: value(.heartRate, 95)
            ]
        )

        // 摄入仅 500 kcal，消耗 2200 kcal，巨大赤字 -1700 kcal
        let result = VitalityEvaluator.evaluate(snapshot: snapshot, foodIntakeCalories: 500)

        XCTAssertLessThan(result.score, 50)
        XCTAssertTrue(result.level == .low || result.level == .exhausted)
        XCTAssertEqual(result.energyBalance.netDifference, -1700)
    }

    func testNewHealthMetricKindsAndFormatting() {
        XCTAssertEqual(HealthMetrics.format(1650, for: .restingEnergy), "1650 千卡")
        XCTAssertEqual(HealthMetrics.format(36.6, for: .bodyTemperature), "36.6 ℃")
        XCTAssertEqual(HealthMetrics.format(72, for: .heartRate), "72 次/分")
        XCTAssertEqual(HealthMetrics.format(0.98, for: .bloodOxygen), "98%")
        XCTAssertEqual(HealthMetrics.format(98, for: .bloodOxygen), "98%")
        XCTAssertEqual(HealthMetrics.format(4.5, for: .walkingSpeed), "4.5 km/h")
        XCTAssertEqual(HealthMetrics.format(16, for: .respiratoryRate), "16 次/分")
        XCTAssertEqual(HealthMetrics.format(45, for: .workoutDuration), "45 分钟")
    }

    func testWorkoutRecordSummaryText() {
        let empty = WorkoutRecordSummary(count: 0, totalDurationMinutes: 0)
        XCTAssertEqual(empty.summaryText, "今日暂无健身记录")

        let workout = WorkoutRecordSummary(count: 2, totalDurationMinutes: 65, totalEnergyBurned: 420, activityNames: ["跑步", "力量训练"])
        XCTAssertEqual(workout.summaryText, "跑步、力量训练 2 次 · 65 分钟 · 消耗 420 千卡")
    }

    func testTotalEnergyBurnedCalculatesActivePlusResting() {
        let snapshot = HealthDaySnapshot(
            day: day,
            values: [
                .activeEnergy: value(.activeEnergy, 420),
                .restingEnergy: value(.restingEnergy, 1580)
            ]
        )
        XCTAssertEqual(snapshot.totalEnergyBurned, 2000)
        XCTAssertEqual(snapshot.activeEnergy, 420)
        XCTAssertEqual(snapshot.restingEnergy, 1580)
    }
}
