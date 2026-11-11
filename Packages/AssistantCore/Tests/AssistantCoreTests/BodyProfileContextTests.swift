import XCTest
@testable import AssistantCore

final class BodyProfileContextTests: XCTestCase {

    /// 固定时刻：2027-01-15 前后，全部相对它构造，绝不读墙上时钟。
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func sample(_ daysAgo: Double, _ values: [BodyMetricField: Double]) -> BodyMetricSample {
        BodyMetricSample(measuredAt: now.addingTimeInterval(-daysAgo * day), values: values)
    }

    /// 4 条平稳记录：体重 70、收缩压 118、心率 68、体温 36.6。
    private func stableSamples() -> [BodyMetricSample] {
        (0..<4).map { index in
            sample(Double(3 - index), [
                .weightKg: 70, .systolic: 118, .diastolic: 76,
                .heartRate: 68, .bodyTemperature: 36.6
            ])
        }
    }

    private func adultContext(
        samples: [BodyMetricSample],
        sex: BodyBiologicalSex = .male,
        heightCm: Double? = 175,
        ageYears: Int? = 30,
        referenceNow: Date? = nil
    ) -> BodyProfileContext {
        BodyProfileContext(
            heightCm: heightCm,
            ageYears: ageYears,
            biologicalSex: sex,
            samples: samples,
            now: referenceNow ?? now
        )
    }

    // MARK: - 输入缺失 / 陈旧：一律中性

    func testNoProfileIsNeutral() {
        let adjustment = BodyProfileModifier.evaluate(nil)
        XCTAssertEqual(adjustment, .neutral)
        XCTAssertEqual(adjustment.vitalityDelta, 0)
        XCTAssertEqual(adjustment.pleasureDelta, 0)
        XCTAssertEqual(adjustment.stressDelta, 0)
        XCTAssertFalse(adjustment.hasUsableData)
    }

    func testEmptySamplesIsNeutral() {
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: []))
        XCTAssertEqual(adjustment, .neutral)
    }

    func testFewerThanThreeSamplesDoesNotJudge() {
        // 两点连不成线，也不该从一次血压就推断「波动大」。
        let samples = [sample(2, [.systolic: 118]), sample(0, [.systolic: 150])]
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: samples))
        XCTAssertEqual(adjustment, .neutral)
    }

    func testStaleRecordsDoNotDragTodaysIndex() {
        let samples = stableSamples().map { sample in
            BodyMetricSample(
                measuredAt: sample.measuredAt.addingTimeInterval(-10 * day),
                values: sample.values
            )
        }
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: samples))
        XCTAssertTrue(adjustment.isStale)
        XCTAssertFalse(adjustment.hasUsableData)
        XCTAssertEqual(adjustment.vitalityDelta, 0)
        XCTAssertEqual(adjustment.pleasureDelta, 0)
        XCTAssertEqual(adjustment.stressDelta, 0)
    }

    func testFutureDatedRecordIsRejected() {
        let samples = stableSamples().map { sample in
            BodyMetricSample(
                measuredAt: now.addingTimeInterval(2 * day),
                values: sample.values
            )
        }
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: samples))
        XCTAssertTrue(adjustment.isStale, "未来时刻（系统时钟异常）不能被当成当前数据")
        XCTAssertEqual(adjustment.vitalityDelta, 0)
    }

    // MARK: - 偏离度是中性且对称的

    func testStableRecordsGiveSmallPositiveBoundedDelta() {
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: stableSamples()))
        XCTAssertTrue(adjustment.hasUsableData)
        XCTAssertEqual(adjustment.meanAbsoluteDeviation, 0, accuracy: 0.0001)
        XCTAssertEqual(adjustment.vitalityDelta, 3)
        XCTAssertEqual(adjustment.pleasureDelta, 2)
        XCTAssertEqual(adjustment.stressDelta, 0)
        XCTAssertTrue(BodyProfileModifier.isStable(adjustment))
    }

    func testDeviationDirectionDoesNotMatter() {
        // 同一组历史，最后一次「变高」与「变低」必须给出完全相同的修正量。
        func adjustment(latest: Double) -> BodyProfileAdjustment {
            var samples = (1...3).map { index in
                sample(Double(4 - index), [.systolic: 120])
            }
            samples.append(sample(0, [.systolic: latest]))
            return BodyProfileModifier.evaluate(adultContext(samples: samples))
        }
        let up = adjustment(latest: 160)
        let down = adjustment(latest: 80)
        XCTAssertEqual(up.meanAbsoluteDeviation, down.meanAbsoluteDeviation, accuracy: 0.0001)
        XCTAssertEqual(up.vitalityDelta, down.vitalityDelta)
        XCTAssertEqual(up.pleasureDelta, down.pleasureDelta)
        XCTAssertEqual(up.stressDelta, down.stressDelta)
        XCTAssertTrue(up.vitalityDelta < 0, "明显波动应带来有界负修正")
    }

    func testDeltasStayWithinHardBounds() {
        var samples = (1...3).map { index in
            sample(Double(4 - index), [
                .weightKg: 60, .systolic: 100, .heartRate: 55,
                .bloodGlucose: 4.5, .bodyTemperature: 36.2,
                .bloodOxygen: 99, .bodyFat: 15
            ])
        }
        samples.append(sample(0, [
            .weightKg: 120, .systolic: 250, .heartRate: 180,
            .bloodGlucose: 20, .bodyTemperature: 40,
            .bloodOxygen: 60, .bodyFat: 50
        ]))
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: samples))
        XCTAssertGreaterThanOrEqual(adjustment.vitalityDelta, -6)
        XCTAssertLessThanOrEqual(adjustment.vitalityDelta, 3)
        XCTAssertGreaterThanOrEqual(adjustment.pleasureDelta, -4)
        XCTAssertLessThanOrEqual(adjustment.pleasureDelta, 2)
        XCTAssertLessThanOrEqual(adjustment.stressDelta, 6)
        XCTAssertGreaterThanOrEqual(adjustment.stressDelta, 0)
    }

    func testBloodPressureIsNotDoubleCounted() {
        let adjustment = BodyProfileModifier.evaluate(adultContext(samples: stableSamples()))
        // 平稳样本里 weightKg / systolic / heartRate / bodyTemperature 共 4 项有值，
        // diastolic 即使填了也不该单独计一次（与收缩压高度相关）。
        XCTAssertEqual(adjustment.factors.count, 4)
        XCTAssertFalse(adjustment.factors.contains { $0.field == .diastolic })
        XCTAssertTrue(adjustment.factors.contains { $0.field == .systolic })
    }

    func testSameTimestampUsesStableOriginalOrder() {
        let samples = (0..<4).map { index in
            BodyMetricSample(
                measuredAt: now.addingTimeInterval(-day),
                values: [.systolic: 120 + Double(index)]
            )
        }
        let first = BodyProfileModifier.evaluate(adultContext(samples: samples))
        let second = BodyProfileModifier.evaluate(adultContext(samples: samples))
        XCTAssertEqual(first, second, "同刻记录必须可复现，不能受 Array.sorted 不稳定性影响")
    }

    // MARK: - BMR / BMI / 参考目标

    func testMifflinStJeorBMR() {
        // 10*70 + 6.25*175 - 5*30 + const
        XCTAssertEqual(
            BodyMetabolism.bmrKcal(weightKg: 70, heightCm: 175, ageYears: 30, biologicalSex: .male)!,
            1648.75, accuracy: 0.0001
        )
        XCTAssertEqual(
            BodyMetabolism.bmrKcal(weightKg: 70, heightCm: 175, ageYears: 30, biologicalSex: .female)!,
            1482.75, accuracy: 0.0001
        )
        XCTAssertEqual(
            BodyMetabolism.bmrKcal(weightKg: 70, heightCm: 175, ageYears: 30, biologicalSex: .unspecified)!,
            1565.75, accuracy: 0.0001
        )
    }

    func testBMRRefusesToInventMissingInputs() {
        XCTAssertNil(BodyMetabolism.bmrKcal(weightKg: nil, heightCm: 175, ageYears: 30, biologicalSex: .male))
        XCTAssertNil(BodyMetabolism.bmrKcal(weightKg: 70, heightCm: nil, ageYears: 30, biologicalSex: .male))
        XCTAssertNil(BodyMetabolism.bmrKcal(weightKg: 70, heightCm: 175, ageYears: nil, biologicalSex: .male))
        // 成人公式不套用到儿童/高龄，也不悄悄钳到边界
        XCTAssertNil(BodyMetabolism.bmrKcal(weightKg: 70, heightCm: 175, ageYears: 10, biologicalSex: .male))
        XCTAssertNil(BodyMetabolism.bmrKcal(weightKg: 70, heightCm: 175, ageYears: 95, biologicalSex: .male))
    }

    func testContextDerivedValues() {
        let context = adultContext(samples: stableSamples())
        XCTAssertEqual(context.latestWeightKg, 70)
        XCTAssertEqual(context.bmi!, 70 / (1.75 * 1.75), accuracy: 0.0001)
        XCTAssertEqual(context.bmrKcal!, 1648.75, accuracy: 0.0001)
        XCTAssertEqual(context.referenceEnergyKcal!, 1648.75 * 1.375, accuracy: 0.0001)
        XCTAssertEqual(context.referenceWaterML, 2100)
        XCTAssertTrue(context.isFresh)
    }

    func testLatestWeightSkipsEmptyShells() {
        var samples = stableSamples()
        samples.append(sample(0, [.heartRate: 72])) // 最近的记录没称体重
        XCTAssertEqual(adultContext(samples: samples).latestWeightKg, 70)
    }

    func testWaterReferenceIsClampedAndNeverInvented() {
        XCTAssertNil(BodyMetabolism.referenceWaterML(weightKg: nil))
        XCTAssertEqual(BodyMetabolism.referenceWaterML(weightKg: 20)!, 1200)
        XCTAssertEqual(BodyMetabolism.referenceWaterML(weightKg: 200)!, 3000)
    }

    func testEnergyThresholdsLegacyAndScaled() {
        let legacy = BodyMetabolism.energyThresholds(referenceEnergyKcal: nil)
        XCTAssertEqual(legacy.balanced, 250)
        XCTAssertEqual(legacy.deficit, 600)
        XCTAssertEqual(legacy.surplus, 550)
        XCTAssertEqual(legacy.heavy, 800)

        let scaled = BodyMetabolism.energyThresholds(referenceEnergyKcal: 2400)
        XCTAssertEqual(scaled.balanced, 300, accuracy: 0.0001)
        XCTAssertEqual(scaled.surplus, 660, accuracy: 0.0001)

        let capped = BodyMetabolism.energyThresholds(referenceEnergyKcal: 10000)
        XCTAssertEqual(capped.balanced, 250 * 1.35, accuracy: 0.0001)
    }

    func testIntakeBand() {
        XCTAssertNil(BodyMetabolism.intakeBand(referenceEnergyKcal: nil))
        let band = BodyMetabolism.intakeBand(referenceEnergyKcal: 2000)!
        XCTAssertEqual(band.lower, 1200)
        XCTAssertEqual(band.upper, 2400)
        XCTAssertEqual(band.tooLow, 800)
    }

    // MARK: - 两个指数确实发生变化，且默认路径零回归

    func testVitalityWithNilProfileIsByteIdenticalToLegacy() {
        let withoutProfile = VitalityEvaluator.evaluate(snapshot: nil, foodIntakeCalories: 800)
        let explicitNil = VitalityEvaluator.evaluate(snapshot: nil, foodIntakeCalories: 800, profile: nil)
        XCTAssertEqual(withoutProfile, explicitNil)
        XCTAssertEqual(withoutProfile.score, 69)
        XCTAssertFalse(withoutProfile.highlights.contains { $0.title == "身体档案" })
    }

    func testVitalityIncorporatesProfileInEnergyBandAndScore() {
        let context = adultContext(samples: stableSamples())
        let result = VitalityEvaluator.evaluate(snapshot: nil, foodIntakeCalories: 800, profile: context)
        // 800 kcal 在历史口径下落进「已记录热量」(+4)，
        // 按 70kg/175cm/30岁男性的个人参考消耗则明显偏低(-6)，
        // 再叠加平稳档案的 +3 修正。
        XCTAssertEqual(result.score, 62)
        XCTAssertTrue(result.highlights.contains { $0.title == "身体档案" })
        XCTAssertEqual(result.highlights.last?.statusText, "近期较平时平稳")
    }

    func testVitalityEnergyThresholdsScaleWithBMR() {
        let snapshot = HealthDaySnapshot(
            day: now,
            values: [
                .restingEnergy: HealthMetricValue(kind: .restingEnergy, value: 2000, day: now)
            ]
        )
        // 摄入 2300 / 消耗 2000，差值 +300：
        // 历史口径 >250 → +8「适度盈余」；个人化阈值 337.5 → 落在平衡区 +15。
        let legacy = VitalityEvaluator.evaluate(snapshot: snapshot, foodIntakeCalories: 2300)
        let heavyContext = BodyProfileContext(
            heightCm: 190, ageYears: 25, biologicalSex: .male,
            samples: [sample(0, [.weightKg: 100])], now: now
        )
        let personalized = VitalityEvaluator.evaluate(
            snapshot: snapshot, foodIntakeCalories: 2300, profile: heavyContext
        )
        XCTAssertTrue(
            personalized.score > legacy.score,
            "按本人基础代谢缩放后，同样 300 kcal 盈余不再被判成失衡"
        )
    }

    func testPleasureWithNilProfileKeepsLegacyDefault() {
        let evaluation = PleasureIndexEvaluator.evaluate(snapshot: nil)
        XCTAssertEqual(evaluation.pleasureScore, 70)
        XCTAssertEqual(evaluation.stressScore, 30)
        XCTAssertFalse(evaluation.details.contains { $0.title == "身体档案" })
    }

    func testPleasureUsesProfileEvenWithoutHealthKitData() {
        // HealthKit 拒绝授权时，手动体征仍应产生有依据的修正，
        // 但保底文案仍明确说明「尚无足够手环生理数据」。
        let context = adultContext(samples: stableSamples())
        let evaluation = PleasureIndexEvaluator.evaluate(snapshot: nil, profile: context)
        XCTAssertEqual(evaluation.pleasureScore, 72)
        XCTAssertEqual(evaluation.stressScore, 30)
        XCTAssertTrue(evaluation.details.contains { $0.title == "身体档案" })
        XCTAssertTrue(evaluation.advice.contains("尚无足够手环生理数据"))
    }

    func testPleasureWithSnapshotAppliesBodyModifier() {
        let snapshot = HealthDaySnapshot(
            day: now,
            values: [
                .sleep: HealthMetricValue(kind: .sleep, value: 7.5, day: now),
                .heartRateVariability: HealthMetricValue(kind: .heartRateVariability, value: 42, day: now),
                .restingHeartRate: HealthMetricValue(kind: .restingHeartRate, value: 65, day: now)
            ]
        )
        let baseline = PleasureIndexEvaluator.evaluate(snapshot: snapshot)
        let withProfile = PleasureIndexEvaluator.evaluate(
            snapshot: snapshot, profile: adultContext(samples: stableSamples())
        )
        XCTAssertEqual(withProfile.pleasureScore, baseline.pleasureScore + 2)
        XCTAssertEqual(withProfile.stressScore, baseline.stressScore)
        XCTAssertTrue(withProfile.details.contains { $0.title == "身体档案" })
    }
}
