import XCTest
@testable import AssistantCore

final class ActionModelsTests: XCTestCase {

    // MARK: - ActionCapability & 确认规则

    func testDestructiveCapabilitiesRequireConfirmation() {
        XCTAssertTrue(ActionCapability.todoCancel.isDestructive)
        XCTAssertTrue(ActionCapability.todoCancel.requiresConfirmation)
        XCTAssertTrue(ActionCapability.expenseUpdate.isDestructive)
        XCTAssertTrue(ActionCapability.expenseUpdate.requiresConfirmation)

        XCTAssertFalse(ActionCapability.todoComplete.isDestructive)
        XCTAssertFalse(ActionCapability.todoCreate.isDestructive)
        XCTAssertFalse(ActionCapability.expenseCreate.isDestructive)
        XCTAssertFalse(ActionCapability.reminderSnooze.isDestructive)
    }

    func testPlannedActionNeedsConfirmationRespectsDestructiveFlag() {
        // 即便模型自称 confidence = 0.99，破坏性动作仍强制 needsConfirmation == true
        let cancelAction = ActionItem(
            capability: .todoCancel,
            params: ["target": "去医院取报告"],
            confidence: 0.99
        )
        XCTAssertTrue(cancelAction.needsConfirmation, "破坏性动作不能信任模型自报的高置信度")

        let completeAction = ActionItem(
            capability: .todoComplete,
            params: ["target": "买咖啡"],
            confidence: 0.95
        )
        XCTAssertFalse(completeAction.needsConfirmation)

        // 低置信度的普通动作进入确认卡
        let lowConfAction = ActionItem(
            capability: .todoComplete,
            params: ["target": "买咖啡"],
            confidence: 0.4
        )
        XCTAssertTrue(lowConfAction.needsConfirmation)
    }

    // MARK: - ActionUndoToken 快照式还原

    func testUndoTokenWithSnapshotRoundTrip() {
        let originalFields = [
            "title": "原标题：下午开会",
            "dueAtISO": "2026-10-15T15:00:00Z",
            "detail": "原备注：准备材料"
        ]
        let data = ActionUndoToken.makeSnapshotData(originalFields)
        XCTAssertNotNil(data)

        let id = UUID()
        let token = ActionUndoToken(kind: .todo, recordID: id, snapshotJSON: data)
        let restored = token.decodeSnapshot()
        XCTAssertEqual(restored, originalFields, "修改前字段快照还原后必须与原字典逐项一致")
    }

    func testLegacyUndoTokenWithoutSnapshotDecodesNil() {
        let token = ActionUndoToken(kind: .expense, recordID: UUID())
        XCTAssertNil(token.snapshotJSON)
        XCTAssertNil(token.decodeSnapshot())
    }

    // MARK: - ActionParser 宽容解析

    func testParseStandardJSON() {
        let raw = """
        [
            {"capability": "todo.complete", "target": "取快递"},
            {"capability": "reminder.snooze", "target": "吃药", "duration": "1小时"}
        ]
        """
        let actions = ActionParser.parseActionJSON(raw)
        XCTAssertEqual(actions?.count, 2)
        XCTAssertEqual(actions?[0].capability, .todoComplete)
        XCTAssertEqual(actions?[0].params["target"], "取快递")
        XCTAssertEqual(actions?[1].capability, .reminderSnooze)
        XCTAssertEqual(actions?[1].params["duration"], "1小时")
    }

    func testParseMarkdownFencedJSON() {
        let raw = """
        ```json
        [
            {"capability": "todo.create", "title": "明天去医院", "dueAtDays": "1"}
        ]
        ```
        """
        let actions = ActionParser.parseActionJSON(raw)
        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?[0].capability, .todoCreate)
        XCTAssertEqual(actions?[0].params["title"], "明天去医院")
    }

    func testParseJSONWithTrailingCommas() {
        // 小模型常见错误：数组末尾或对象末尾带多余逗号
        let raw = """
        [
            {"capability": "todo.cancel", "target": "退票",},
        ]
        """
        let actions = ActionParser.parseActionJSON(raw)
        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?[0].capability, .todoCancel)
        XCTAssertEqual(actions?[0].params["target"], "退票")
    }

    func testParseJSONWithNumericParameters() {
        let raw = """
        [
            {"capability": "expense.create", "amount": 18.5, "isIncome": false, "title": "午餐"}
        ]
        """
        let actions = ActionParser.parseActionJSON(raw)
        XCTAssertEqual(actions?.count, 1)
        XCTAssertEqual(actions?[0].params["amount"], "18.5")
        XCTAssertEqual(actions?[0].params["title"], "午餐")
    }

    func testParseMangledGarbageReturnsNil() {
        XCTAssertNil(ActionParser.parseActionJSON("不好意思我没听懂你的意思"))
        XCTAssertNil(ActionParser.parseActionJSON("[{invalid json"))
    }
}
