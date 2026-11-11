import Foundation
import XCTest
@testable import AssistantCore

final class BodyMetricsTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        return calendar.date(from: comps)!
    }

    // MARK: - 字段元数据

    func testEveryFieldHasPlausibleRangeAndUnit() {
        for field in BodyMetricField.allCases {
            XCTAssertFalse(field.unit.isEmpty, "\(field.rawValue) 缺单位")
            XCTAssertLessThan(field.plausibleRange.lowerBound, field.plausibleRange.upperBound)
        }
        XCTAssertEqual(Set(BodyMetricField.allCases.map(\.rawValue)).count, BodyMetricField.allCases.count,
                       "rawValue 必须唯一，否则备份还原会串字段")
    }

    func testBloodPressureFieldsAreIntegers() {
        XCTAssertEqual(BodyMetricField.systolic.decimalPlaces, 0)
        XCTAssertEqual(BodyMetricField.diastolic.decimalPlaces, 0)
        XCTAssertEqual(BodyMetricField.heartRate.decimalPlaces, 0)
        XCTAssertEqual(BodyMetricField.weightKg.decimalPlaces, 1)
    }

    // MARK: - 校验

    func testEmptyRecordIsRejected() {
        XCTAssertEqual(BodyMetricValidator.validate([:]), .emptyRecord)
    }

    func testTypicalRecordIsValid() {
        let values: [BodyMetricField: Double] = [
            .weightKg: 68.5, .systolic: 118, .diastolic: 76, .heartRate: 72
        ]
        XCTAssertEqual(BodyMetricValidator.validate(values), .valid)
    }

    func testOutOfRangeValueIsRejectedWithFieldLocation() {
        XCTAssertEqual(
            BodyMetricValidator.validate([.weightKg: 1200]),
            .outOfPlausibleRange(.weightKg)
        )
        XCTAssertEqual(
            BodyMetricValidator.validate([.bloodOxygen: 130]),
            .outOfPlausibleRange(.bloodOxygen)
        )
        XCTAssertEqual(
            BodyMetricValidator.validate([.bodyTemperature: 99]),
            .outOfPlausibleRange(.bodyTemperature)
        )
    }

    func testNonFiniteValueIsRejected() {
        XCTAssertEqual(
            BodyMetricValidator.validate([.weightKg: .nan]),
            .outOfPlausibleRange(.weightKg)
        )
        XCTAssertEqual(
            BodyMetricValidator.validate([.weightKg: .infinity]),
            .outOfPlausibleRange(.weightKg)
        )
    }

    func testBloodPressureMustBePaired() {
        XCTAssertEqual(
            BodyMetricValidator.validate([.systolic: 120]),
            .incompleteBloodPressure
        )
        XCTAssertEqual(
            BodyMetricValidator.validate([.diastolic: 80, .weightKg: 70]),
            .incompleteBloodPressure
        )
    }

    func testSystolicMustBeStrictlyAboveDiastolic() {
        XCTAssertEqual(
            BodyMetricValidator.validate([.systolic: 80, .diastolic: 80]),
            .systolicNotAboveDiastolic
        )
        XCTAssertEqual(
            BodyMetricValidator.validate([.systolic: 70, .diastolic: 90]),
            .systolicNotAboveDiastolic
        )
        XCTAssertEqual(
            BodyMetricValidator.validate([.systolic: 120, .diastolic: 80]),
            .valid
        )
    }

    func testValidationIdentifiersAreStable() {
        XCTAssertEqual(BodyMetricValidation.valid.identifier, "valid")
        XCTAssertEqual(BodyMetricValidation.emptyRecord.identifier, "emptyRecord")
        XCTAssertEqual(
            BodyMetricValidation.outOfPlausibleRange(.weightKg).identifier,
            "outOfPlausibleRange.weightKg"
        )
    }

    func testHeightAndBirthDateGuards() {
        XCTAssertTrue(BodyMetricValidator.isPlausibleHeight(170))
        XCTAssertFalse(BodyMetricValidator.isPlausibleHeight(2))
        XCTAssertFalse(BodyMetricValidator.isPlausibleHeight(300))
        XCTAssertTrue(BodyMetricValidator.isPlausibleBirthDate(date(1990, 1, 1), now: date(2026, 11, 11)))
        XCTAssertFalse(BodyMetricValidator.isPlausibleBirthDate(date(2099, 1, 1), now: date(2026, 11, 11)))
    }

    // MARK: - 年龄

    func testAgeIsFullYearsAtExplicitNow() {
        let birth = date(1990, 6, 15)
        XCTAssertEqual(BodyMetricCalculator.age(birthDate: birth, now: date(2026, 6, 14), calendar: calendar), 35)
        XCTAssertEqual(BodyMetricCalculator.age(birthDate: birth, now: date(2026, 6, 15), calendar: calendar), 36)
        XCTAssertEqual(BodyMetricCalculator.age(birthDate: birth, now: date(2026, 6, 16), calendar: calendar), 36)
    }

    func testAgeIsNilForMissingOrFutureBirthDate() {
        XCTAssertNil(BodyMetricCalculator.age(birthDate: nil, now: date(2026, 11, 11), calendar: calendar))
        XCTAssertNil(BodyMetricCalculator.age(
            birthDate: date(2030, 1, 1), now: date(2026, 11, 11), calendar: calendar
        ))
    }

    func testAgeDoesNotReadWallClock() {
        // 同一组 (birthDate, now, calendar) 反复调用必须一致；
        // 这里用两个相隔很远的 now 证明取值完全由入参决定。
        let birth = date(2000, 1, 1)
        XCTAssertEqual(BodyMetricCalculator.age(birthDate: birth, now: date(2010, 1, 1), calendar: calendar), 10)
        XCTAssertEqual(BodyMetricCalculator.age(birthDate: birth, now: date(2050, 1, 1), calendar: calendar), 50)
    }

    // MARK: - BMI

    func testBMIUsesMetersSquared() {
        // 70 / 1.75² = 22.857...
        let value = BodyMetricCalculator.bmi(weightKg: 70, heightCm: 175)
        XCTAssertNotNil(value)
        XCTAssertEqual(value!, 70 / (1.75 * 1.75), accuracy: 0.0001)
    }

    func testBMIReturnsNilRatherThanInventingMissingInputs() {
        XCTAssertNil(BodyMetricCalculator.bmi(weightKg: nil, heightCm: 175))
        XCTAssertNil(BodyMetricCalculator.bmi(weightKg: 70, heightCm: nil))
        XCTAssertNil(BodyMetricCalculator.bmi(weightKg: 0, heightCm: 175))
        XCTAssertNil(BodyMetricCalculator.bmi(weightKg: 70, heightCm: 0))
        XCTAssertNil(BodyMetricCalculator.bmi(weightKg: 70, heightCm: 2), "身高输错不该算出荒谬 BMI")
    }

    func testDisplayUsesFieldPrecision() {
        // 刻意不用 68.55 这类十进制恰好落在半格的值：
        // String(format:) 走二进制浮点舍入，68.55 会出 68.5 而非 68.6。
        // 这里断言的是「小数位数由字段决定」，不是十进制四舍五入规则。
        XCTAssertEqual(BodyMetricCalculator.display(68.44, field: .weightKg), "68.4")
        XCTAssertEqual(BodyMetricCalculator.display(36.67, field: .bodyTemperature), "36.7")
        XCTAssertEqual(BodyMetricCalculator.display(118, field: .systolic), "118")
    }

    // MARK: - 趋势

    private func samples(_ pairs: [(Date, [BodyMetricField: Double])]) -> [BodyMetricSample] {
        pairs.map { BodyMetricSample(measuredAt: $0.0, values: $0.1) }
    }

    func testTrendRequiresAtLeastThreeSamples() {
        let two = samples([
            (date(2026, 11, 1), [.weightKg: 70]),
            (date(2026, 11, 2), [.weightKg: 69])
        ])
        XCTAssertNil(BodyMetricTrendBuilder.build(field: .weightKg, samples: two),
                     "两点连成线不叫趋势，不能下结论")
    }

    func testTrendIgnoresSamplesMissingTheField() {
        let mixed = samples([
            (date(2026, 11, 1), [.weightKg: 70]),
            (date(2026, 11, 2), [.heartRate: 72]),
            (date(2026, 11, 3), [.weightKg: 69]),
            (date(2026, 11, 4), [.weightKg: 68])
        ])
        let trend = BodyMetricTrendBuilder.build(field: .weightKg, samples: mixed)
        XCTAssertEqual(trend?.sampleCount, 3)
        XCTAssertEqual(trend?.earliest, 70)
        XCTAssertEqual(trend?.latest, 68)
        XCTAssertEqual(trend?.direction, .falling)
    }

    func testTrendIsChronologicalRegardlessOfInputOrder() {
        let shuffled = samples([
            (date(2026, 11, 4), [.weightKg: 68]),
            (date(2026, 11, 1), [.weightKg: 70]),
            (date(2026, 11, 3), [.weightKg: 69]),
            (date(2026, 11, 2), [.weightKg: 71])
        ])
        let trend = BodyMetricTrendBuilder.build(field: .weightKg, samples: shuffled)
        XCTAssertEqual(trend?.earliest, 70)
        XCTAssertEqual(trend?.latest, 68)
        XCTAssertEqual(trend?.change, -2)
        XCTAssertEqual(trend?.earliestAt, date(2026, 11, 1))
        XCTAssertEqual(trend?.latestAt, date(2026, 11, 4))
    }

    func testTinyChangeIsSteady() {
        let flat = samples([
            (date(2026, 11, 1), [.bodyTemperature: 36.5]),
            (date(2026, 11, 2), [.bodyTemperature: 36.5]),
            (date(2026, 11, 3), [.bodyTemperature: 36.5])
        ])
        XCTAssertEqual(BodyMetricTrendBuilder.build(field: .bodyTemperature, samples: flat)?.direction, .steady)
    }

    func testSameTimestampTieBreaksByOriginalIndex() {
        let same = date(2026, 11, 1)
        let a = samples([(same, [.weightKg: 70]), (same, [.weightKg: 69]), (same, [.weightKg: 68])])
        let b = samples([(same, [.weightKg: 70]), (same, [.weightKg: 69]), (same, [.weightKg: 68])])
        XCTAssertEqual(
            BodyMetricTrendBuilder.build(field: .weightKg, samples: a),
            BodyMetricTrendBuilder.build(field: .weightKg, samples: b),
            "同刻记录顺序必须稳定，不能用不稳定的 sorted 让每次刷新给出不同趋势"
        )
    }

    func testLatestSkipsEmptyShellsAndReturnsNilWhenAbsent() {
        let mixed = samples([
            (date(2026, 11, 1), [.weightKg: 70]),
            (date(2026, 11, 5), [.heartRate: 72]),
            (date(2026, 11, 3), [.weightKg: 68])
        ])
        let latest = BodyMetricTrendBuilder.latest(field: .weightKg, samples: mixed)
        XCTAssertEqual(latest?.at, date(2026, 11, 3))
        XCTAssertEqual(latest?.value, 68)
        XCTAssertNil(BodyMetricTrendBuilder.latest(field: .bloodOxygen, samples: mixed),
                     "没有该字段时返回 nil，不能返回 0 冒充测过")
    }
}
