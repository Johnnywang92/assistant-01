import XCTest
@testable import AssistantCore

final class OmniboxRuleSupportTests: XCTestCase {

    // MARK: 子句切分

    func testSplitCompoundInputOnFuhaoAndConjunctions() {
        XCTAssertEqual(
            OmniboxClauseSplitter.split("完成晨跑打卡，顺便喝了500ml水"),
            ["完成晨跑打卡", "喝了500ml水"]
        )
        XCTAssertEqual(
            OmniboxClauseSplitter.split("记一笔打车30元；然后提醒我明天开会"),
            ["记一笔打车30元", "提醒我明天开会"]
        )
        XCTAssertEqual(
            OmniboxClauseSplitter.split("早饭吃了包子。顺便喝了杯牛奶"),
            ["早饭吃了包子", "喝了杯牛奶"]
        )
    }

    func testSplitKeepsSingleClauseIntact() {
        XCTAssertEqual(OmniboxClauseSplitter.split("消费99.00元，商户美团"), ["消费99.00元，商户美团"])
        XCTAssertEqual(OmniboxClauseSplitter.split("把那笔账改成30"), ["把那笔账改成30"])
    }

    func testSplitIgnoresOrdinaryCommaAndSentencePeriod() {
        // 逗号/句号不切：短信模板不能被拆碎（拆开后「余额1250元」会被宽松金额兜底误判成新账）
        let sms = "【银行】您于10月23日消费99.00元（美团）。余额1,250.00元"
        XCTAssertEqual(OmniboxClauseSplitter.split(sms), [sms])
    }

    func testSplitDropsEmptySegments() {
        XCTAssertEqual(OmniboxClauseSplitter.split("顺便喝了500ml水"), ["喝了500ml水"])
    }

    // MARK: 修改账目

    func testExtractExpenseUpdateAmount() {
        let result = OmniboxUpdateExtractor.extractExpenseUpdate(from: "把打车改成30")
        XCTAssertEqual(result?.target, "打车")
        XCTAssertEqual(result?.newAmount, "30")
        XCTAssertNil(result?.newTitle)
    }

    func testExtractExpenseUpdateDecimalAmountNotTruncated() {
        // [0-9]+ 后接小数点时禁止回溯截断——"1234.56" 不能被截成 "56"
        let result = OmniboxUpdateExtractor.extractExpenseUpdate(from: "把打车改成1234.56元")
        XCTAssertEqual(result?.newAmount, "1234.56")
    }

    func testExtractExpenseUpdateStripsFillerTarget() {
        let result = OmniboxUpdateExtractor.extractExpenseUpdate(from: "把那笔账改成30")
        XCTAssertEqual(result?.newAmount, "30")
        // 填充词剥完为空时保留原文，交给目标解析器模糊匹配
        XCTAssertFalse(result?.target.isEmpty ?? true)
    }

    func testExtractExpenseUpdateKeepsRealTarget() {
        let result = OmniboxUpdateExtractor.extractExpenseUpdate(from: "把昨天的打车费改成28.5")
        // 目标剥掉「费」等填充词，保留核心名词，供目标解析器模糊匹配
        XCTAssertEqual(result?.target.contains("打车"), true)
        XCTAssertEqual(result?.newAmount, "28.5")
    }

    func testExtractExpenseUpdateTitleChangeInExpenseContext() {
        let result = OmniboxUpdateExtractor.extractExpenseUpdate(from: "把那笔买菜的账改成买水果")
        XCTAssertEqual(result?.newTitle, "买水果")
        XCTAssertEqual(result?.newAmount, "")
    }

    func testExtractExpenseUpdateRejectsTodoContextTitleChange() {
        XCTAssertNil(OmniboxUpdateExtractor.extractExpenseUpdate(from: "把明天的会议改成周会"))
    }

    // MARK: 修改待办

    func testExtractTodoUpdateDueDate() {
        let result = OmniboxUpdateExtractor.extractTodoUpdate(from: "待办改到后天")
        XCTAssertEqual(result?.dueAtDays, 2)
    }

    func testExtractTodoUpdateTomorrowMorning() {
        let result = OmniboxUpdateExtractor.extractTodoUpdate(from: "把会议改到明天上午")
        XCTAssertEqual(result?.target, "会议")
        XCTAssertEqual(result?.dueAtDays, 1)
        XCTAssertEqual(result?.dueAtTime, "09:00")
    }

    func testExtractTodoUpdatePostponeToTomorrow() {
        let result = OmniboxUpdateExtractor.extractTodoUpdate(from: "把体检推迟到明天")
        XCTAssertEqual(result?.dueAtDays, 1)
    }

    func testExtractTodoUpdateExplicitTime() {
        let result = OmniboxUpdateExtractor.extractTodoUpdate(from: "把答辩改到14:30")
        XCTAssertEqual(result?.dueAtTime, "14:30")
        XCTAssertEqual(result?.dueAtDays, 0)
    }

    func testExtractTodoUpdateDaysLater() {
        let result = OmniboxUpdateExtractor.extractTodoUpdate(from: "把交房租改到5天后")
        XCTAssertEqual(result?.dueAtDays, 5)
    }

    func testExtractTodoUpdateTitleChange() {
        let result = OmniboxUpdateExtractor.extractTodoUpdate(from: "把周会改成双周会")
        XCTAssertEqual(result?.target, "周会")
        XCTAssertEqual(result?.newTitle, "双周会")
    }

    func testExtractTodoUpdateRejectsPlainSentence() {
        XCTAssertNil(OmniboxUpdateExtractor.extractTodoUpdate(from: "今天天气不错"))
    }

    // MARK: 时间片段解析

    func testParseDueRelativeDays() {
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "今天")?.days, 0)
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "明天")?.days, 1)
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "后天")?.days, 2)
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "大后天")?.days, 3)
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "7天后")?.days, 7)
    }

    func testParseDueTimeOfDay() {
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "明早")?.days, 1)
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "明早")?.time, "09:00")
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "今晚")?.time, "20:00")
        XCTAssertEqual(OmniboxUpdateExtractor.parseDue(from: "下午")?.time, "15:00")
    }

    func testParseDueRejectsNonDate() {
        XCTAssertNil(OmniboxUpdateExtractor.parseDue(from: "周会"))
        XCTAssertNil(OmniboxUpdateExtractor.parseDue(from: ""))
    }
}
