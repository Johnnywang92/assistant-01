import XCTest
@testable import AssistantCore

/// CSV 导入解析的回归测试。
///
/// 背景：密码/纪念日批量导入曾按裸逗号切分，`"a,b"` 这类合法字段会被截断，
/// 且回执仍报「成功」。这些用例锁定引号、转义与行号，防止再退回字符串切割。
final class CSVParserTests: XCTestCase {

    func testQuotedCommaStaysInOneField() {
        let records = CSVParser.parse("a,\"b,c\",d")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].fields, ["a", "b,c", "d"])
        XCTAssertEqual(records[0].line, 1)
    }

    func testEscapedQuotesAreUnescaped() {
        let records = CSVParser.parse("\"he said \"\"hi\"\"\",x,y")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].fields, ["he said \"hi\"", "x", "y"])
    }

    func testTrailingEmptyFieldIsPreserved() {
        let records = CSVParser.parse("a,b,")
        XCTAssertEqual(records[0].fields, ["a", "b", ""])
    }

    func testLeadingEmptyFieldIsPreserved() {
        let records = CSVParser.parse(",a,b")
        XCTAssertEqual(records[0].fields, ["", "a", "b"])
    }

    func testQuotedFieldMayContainNewlineAndLineNumberReflectsIt() {
        let records = CSVParser.parse("\"first\nsecond\",b\nc,d")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].fields, ["first\nsecond", "b"])
        XCTAssertEqual(records[0].line, 1)
        XCTAssertEqual(records[1].fields, ["c", "d"])
        XCTAssertEqual(records[1].line, 3)
    }

    func testCRLFAndCRAreSupported() {
        XCTAssertEqual(
            CSVParser.parse("a,b\r\nc,d").map(\.fields),
            [["a", "b"], ["c", "d"]]
        )
        XCTAssertEqual(
            CSVParser.parse("a,b\rc,d").map(\.fields),
            [["a", "b"], ["c", "d"]]
        )
    }

    func testBlankLinesAreSkippedButLineNumbersStayPhysical() {
        let records = CSVParser.parse("a,b\n\n   \nc,d")
        XCTAssertEqual(records.map(\.line), [1, 4])
        XCTAssertEqual(records.map(\.fields), [["a", "b"], ["c", "d"]])
    }

    func testBOMIsStripped() {
        let records = CSVParser.parse("\u{FEFF}title,account,password")
        XCTAssertEqual(records[0].fields, ["title", "account", "password"])
    }

    func testWhitespaceTrimmedForBareFieldsButKeptInsideQuotes() {
        let records = CSVParser.parse(" a ,\" b \", c ")
        XCTAssertEqual(records[0].fields, ["a", " b ", "c"])
    }

    func testQuoteInsideBareFieldIsLiteral() {
        let records = CSVParser.parse("12\" screen,a")
        XCTAssertEqual(records[0].fields, ["12\" screen", "a"])
    }

    func testEmptyInputYieldsNoRecords() {
        XCTAssertTrue(CSVParser.parse("").isEmpty)
        XCTAssertTrue(CSVParser.parse("\n\r\n").isEmpty)
    }
}
