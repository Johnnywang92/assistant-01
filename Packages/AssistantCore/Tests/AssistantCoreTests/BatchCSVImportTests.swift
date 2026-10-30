import XCTest
@testable import AssistantCore

/// CSV 批量导入「解析 → 逐行校验 → 跳过回执」的回归测试。
///
/// 背景：密码/纪念日导入曾按裸逗号切分，含逗号的密码被截断后仍报「成功」，
/// 非法行也只是静默消失。这些用例锁定字段对齐、逐行跳过原因与物理行号。
final class BatchCSVImportTests: XCTestCase {

    func testPasswordWithQuotedCommaKeepsWholePassword() {
        let plan = BatchCSVImport.passwords(from: "公司网盘, user@company.com, \"P@ss,word\", 工作, 开了2FA")
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertTrue(plan.skipped.isEmpty)

        let row = plan.rows[0]
        XCTAssertEqual(row.title, "公司网盘")
        XCTAssertEqual(row.account, "user@company.com")
        XCTAssertEqual(row.password, "P@ss,word")
        XCTAssertEqual(row.category, "工作")
        XCTAssertEqual(row.notes, "开了2FA")
    }

    func testPasswordWithEscapedQuotesIsUnescaped() {
        let plan = BatchCSVImport.passwords(from: "路由器,admin,\"say \"\"hi\"\"\",设备,后台")
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].password, "say \"hi\"")
    }

    func testQuotedCommaInNotesKeepsFieldsAligned() {
        let plan = BatchCSVImport.passwords(from: "服务,账号,密码,分类,\"备注,含逗号\"")
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].notes, "备注,含逗号")
    }

    func testPasswordDefaultsCategoryAndNotes() {
        let plan = BatchCSVImport.passwords(from: "路由器,admin,admin888")
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].category, "日常账号")
        XCTAssertNil(plan.rows[0].notes)
    }

    func testInvalidDateIsSkippedWithLineAndReason() {
        let text = """
        恋爱纪念日,2022-05-20
        坏日期,2022-13-45
        """
        let plan = BatchCSVImport.anniversaries(from: text)

        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].title, "恋爱纪念日")
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertEqual(plan.skipped[0].line, 2)
        XCTAssertTrue(plan.skipped[0].reason.hasPrefix("日期无效"))
    }

    func testImpossibleCalendarDateIsSkipped() {
        let plan = BatchCSVImport.anniversaries(from: "坏日期,2022-02-31")
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(plan.skipped.count, 1)
    }

    func testAnniversaryDefaultsAndDateValue() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let plan = BatchCSVImport.anniversaries(from: "妈妈生日, 1970-10-15", timeZone: timeZone)

        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].category, "纪念日")
        XCTAssertNil(plan.rows[0].notes)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: plan.rows[0].date)
        XCTAssertEqual(components.year, 1970)
        XCTAssertEqual(components.month, 10)
        XCTAssertEqual(components.day, 15)
    }

    func testPasswordRowsMissingOrEmptyFieldsAreSkippedInOrder() {
        let text = """
        只有服务名
        service,acct,
        service,,pwd
        ,a,pwd
        """
        let plan = BatchCSVImport.passwords(from: text)

        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.line), [1, 2, 3, 4])
        XCTAssertTrue(plan.skipped[0].reason.hasPrefix("字段不足 3 列"))
        XCTAssertEqual(plan.skipped[1].reason, "密码为空")
        XCTAssertEqual(plan.skipped[2].reason, "账号为空")
        XCTAssertEqual(plan.skipped[3].reason, "服务名为空")
    }

    func testQuotedEmptyPasswordIsSkipped() {
        let plan = BatchCSVImport.passwords(from: "服务,账号,\"\"")
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.reason), ["密码为空"])
    }

    func testBlankLinesDoNotShiftReportedLineNumbers() {
        let text = "恋爱纪念日,2022-05-20\n\n坏日期,2022-13-01"
        let plan = BatchCSVImport.anniversaries(from: text)

        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.skipped.map(\.line), [3])
    }

    func testCarriageReturnLineEndingsDoNotBleedAcrossRows() {
        let text = "服务A,账号A,密码A\r\n服务B,账号B,\"密码,B\"\r\n"
        let plan = BatchCSVImport.passwords(from: text)

        XCTAssertEqual(plan.rows.map(\.title), ["服务A", "服务B"])
        XCTAssertEqual(plan.rows.map(\.password), ["密码A", "密码,B"])
        XCTAssertEqual(plan.skipped.count, 0)
    }

    func testReportCarriesImportedAndSkippedTogether() {
        let report = BatchImportReport(
            imported: 2,
            skipped: [.init(line: 3, reason: "名称为空")]
        )
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.skipped.map(\.line), [3])
    }
}
