import XCTest
@testable import AssistantCore

/// 打卡待办 ↔ 打卡计划关联规则的回归测试。
///
/// 这组用例守护的是「点击后没反应」这类静默失败：
/// 打卡待办是系统自动关联到计划上的，用户直接勾完成时，
/// 关联必须能被解析回计划，且解析**精确**——药名/习惯名互为子串时
/// 认错计划就会漏服或误完成。
final class CheckInTodoLinkTests: XCTestCase {

    // MARK: - 服药待办标题反解析

    func testMedNameRoundTripsWithGeneratedTitle() {
        let title = MedicationTodoMaterializer.todoTitle(medName: "维生素D", timePoint: "08:00")
        XCTAssertEqual(title, "服药：维生素D（08:00）")
        XCTAssertEqual(MedicationTodoMaterializer.medName(fromMaterializedTitle: title), "维生素D")
        XCTAssertEqual(MedicationTodoMaterializer.timePoint(fromMaterializedTitle: title), "08:00")
    }

    /// 药名互为子串时必须完整解析，不能截断成另一个药。
    func testMedNameDoesNotTruncateSubstringNames() {
        let d3 = MedicationTodoMaterializer.todoTitle(medName: "维生素D3", timePoint: "08:00")
        let d = MedicationTodoMaterializer.todoTitle(medName: "维生素D", timePoint: "08:00")
        XCTAssertEqual(MedicationTodoMaterializer.medName(fromMaterializedTitle: d3), "维生素D3")
        XCTAssertEqual(MedicationTodoMaterializer.medName(fromMaterializedTitle: d), "维生素D")
    }

    /// 非法标题一律解析失败——宁可漏联动，也不能错联动。
    func testMedNameRejectsNonMaterializedTitles() {
        let invalid = [
            "吃药",
            "服药：维生素D",
            "服药：维生素D（8）",
            "服药：维生素D（25:00）",
            "服药：（08:00）",
            ""
        ]
        for title in invalid {
            XCTAssertNil(MedicationTodoMaterializer.medName(fromMaterializedTitle: title),
                         "不该被解析成药名: \(title)")
            XCTAssertNil(MedicationTodoMaterializer.timePoint(fromMaterializedTitle: title),
                         "不该被解析成时点: \(title)")
        }
    }

    /// 时点归一化成两位，避免「8:00」与「08:00」两个字符串对不上。
    func testTimePointIsNormalizedToTwoDigits() {
        let title = MedicationTodoMaterializer.todoTitle(medName: "阿莫西林", timePoint: "8:05")
        XCTAssertEqual(MedicationTodoMaterializer.timePoint(fromMaterializedTitle: title), "08:05")
    }

    // MARK: - 运动待办标题（生成端与匹配端同一真源）

    func testHabitTitleRoundTrip() {
        let title = CheckInTodoLink.habitTodoTitle(habitName: "夜跑")
        XCTAssertEqual(title, "运动：夜跑")
        XCTAssertEqual(CheckInTodoLink.habitName(fromTodoTitle: title), "夜跑")
    }

    /// 习惯名互为子串时不能认错计划（「跑步」⊂「夜跑」）。
    func testHabitNameKeepsFullName() {
        XCTAssertEqual(CheckInTodoLink.habitName(fromTodoTitle: "运动：夜跑"), "夜跑")
        XCTAssertEqual(CheckInTodoLink.habitName(fromTodoTitle: "运动：夜跑 3 公里"), "夜跑 3 公里")
    }

    func testHabitNameRejectsNonHabitTitles() {
        XCTAssertNil(CheckInTodoLink.habitName(fromTodoTitle: "跑步"))
        XCTAssertNil(CheckInTodoLink.habitName(fromTodoTitle: "运动："))
        XCTAssertNil(CheckInTodoLink.habitName(fromTodoTitle: ""))
    }

    // MARK: - 关联目标

    func testMedicationTargetResolvesExactMedName() {
        let target = CheckInTodoLink.medicationTarget(fromTodoTitle: "服药：维生素D3（08:00）")
        XCTAssertEqual(target, .medication(medName: "维生素D3"))
    }

    func testHabitTargetResolvesExactHabitName() {
        let target = CheckInTodoLink.habitTarget(fromTodoTitle: "运动：夜跑")
        XCTAssertEqual(target, .habit(habitName: "夜跑"))
    }

    func testTargetsAreNilForForeignTitles() {
        XCTAssertNil(CheckInTodoLink.medicationTarget(fromTodoTitle: "运动：夜跑"))
        XCTAssertNil(CheckInTodoLink.habitTarget(fromTodoTitle: "服药：维生素D（08:00）"))
    }
}
