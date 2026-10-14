import XCTest
@testable import AssistantCore

final class TaskPlanningInferenceTests: XCTestCase {

    // MARK: - 阶段推导

    func testInferPhaseByKeywords() {
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "提前30天办理签证"), .prepare)
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "购买露营帐篷与气垫"), .execute)
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "出发前一晚核对行李清单"), .sprint)
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "回程后整理装备与报销"), .followup)
    }

    func testInferPhaseByProgressWhenNoKeywords() {
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "步骤一", index: 0, total: 4), .prepare)
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "步骤二", index: 1, total: 4), .execute)
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "步骤三", index: 2, total: 4), .execute)
        XCTAssertEqual(TaskPlanningInference.inferPhase(title: "步骤四", index: 3, total: 4), .followup)
    }

    // MARK: - 偏移天数抽取

    func testExtractOffsetDays() {
        XCTAssertEqual(TaskPlanningInference.extractOffsetDays(from: "提前30天办理护照"), -30)
        XCTAssertEqual(TaskPlanningInference.extractOffsetDays(from: "前一周购买物资"), -7)
        XCTAssertEqual(TaskPlanningInference.extractOffsetDays(from: "出发前一天打包"), -1)
        XCTAssertEqual(TaskPlanningInference.extractOffsetDays(from: "当天出发"), 0)
        XCTAssertEqual(TaskPlanningInference.extractOffsetDays(from: "活动后第2天报销"), 2)
        XCTAssertNil(TaskPlanningInference.extractOffsetDays(from: "普通事项没有时间信息"))
    }

    // MARK: - 截止日期计算

    func testCalculateDueDateWithExplicitOffset() {
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 5
        let anchor = calendar.date(from: comps)! // 2026-11-05

        // 显式提前 10 天
        let dueExplicit = TaskPlanningInference.calculateDueDate(
            anchorDate: anchor,
            offsetDays: -10,
            phase: .prepare,
            calendar: calendar
        )
        let dayExplicit = calendar.component(.day, from: dueExplicit)
        let monthExplicit = calendar.component(.month, from: dueExplicit)
        XCTAssertEqual(monthExplicit, 10)
        XCTAssertEqual(dayExplicit, 26) // 11-05 - 10 = 10-26
    }

    func testCalculateDueDateDefaultsByPhaseWhenOffsetNil() {
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 5
        let anchor = calendar.date(from: comps)! // 2026-11-05

        // prepare 阶段默认 −7 天 -> 10-29
        let duePrepare = TaskPlanningInference.calculateDueDate(
            anchorDate: anchor,
            offsetDays: nil,
            phase: .prepare,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: duePrepare), 29)

        // sprint 阶段默认 −1 天 -> 11-04
        let dueSprint = TaskPlanningInference.calculateDueDate(
            anchorDate: anchor,
            offsetDays: nil,
            phase: .sprint,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: dueSprint), 4)

        // followup 阶段默认 +2 天 -> 11-07
        let dueFollowup = TaskPlanningInference.calculateDueDate(
            anchorDate: anchor,
            offsetDays: nil,
            phase: .followup,
            calendar: calendar
        )
        XCTAssertEqual(calendar.component(.day, from: dueFollowup), 7)
    }

    // MARK: - 类型推导

    func testInferTodoTypeIdentifier() {
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "购买高铁车票"), "travelBooking")
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "早晨空腹抽血体检"), "medication")
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "给充电宝充好电"), "charging")
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "全屋断舍离打扫"), "housework")
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "检查汽车机油与胎压"), "vehicleCare")
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "买生日蛋糕"), "anniversary")
        XCTAssertEqual(TaskPlanningInference.inferTodoTypeIdentifier(title: "周五下午进行述职汇报"), "work")
    }
}
