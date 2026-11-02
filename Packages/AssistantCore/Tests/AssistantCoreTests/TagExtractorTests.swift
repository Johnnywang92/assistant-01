import XCTest
@testable import AssistantCore

final class TagExtractorTests: XCTestCase {

    func testEmptyAndWhitespaceInput() {
        let (clean1, tags1) = TagExtractor.extractTags(from: "")
        XCTAssertEqual(clean1, "")
        XCTAssertTrue(tags1.isEmpty)

        let (clean2, tags2) = TagExtractor.extractTags(from: "   \n\t  ")
        XCTAssertEqual(clean2, "")
        XCTAssertTrue(tags2.isEmpty)
    }

    func testNoTagsReturnsOriginalCleanText() {
        let input = "周五前完成系统登录页重构"
        let (clean, tags) = TagExtractor.extractTags(from: input)
        XCTAssertEqual(clean, input)
        XCTAssertTrue(tags.isEmpty)
    }

    func testSingleTagAtEnd() {
        let input = "周五前交付初稿 #客户A"
        let (clean, tags) = TagExtractor.extractTags(from: input)
        XCTAssertEqual(clean, "周五前交付初稿")
        XCTAssertEqual(tags, ["客户A"])
    }

    func testMultipleTagsAtDifferentPositions() {
        let input = "#紧急 周五前交付初稿 #客户A ，顺便准备发票 #项目结项"
        let (clean, tags) = TagExtractor.extractTags(from: input)
        XCTAssertEqual(clean, "周五前交付初稿 ，顺便准备发票")
        XCTAssertEqual(tags, ["紧急", "客户A", "项目结项"])
    }

    func testTagDeduplicationMaintainsOrder() {
        let input = "#设计 做一套图标 #UI #设计"
        let (clean, tags) = TagExtractor.extractTags(from: input)
        XCTAssertEqual(clean, "做一套图标")
        XCTAssertEqual(tags, ["设计", "UI"])
    }

    func testTagBoundaryWithPunctuation() {
        let input = "提醒我联系张总#客户B，下周一确认报价#报价单。"
        let (clean, tags) = TagExtractor.extractTags(from: input)
        XCTAssertEqual(tags, ["客户B", "报价单"])
        XCTAssertFalse(clean.contains("#"))
    }

    func testFormatDisplayTag() {
        XCTAssertEqual(TagExtractor.formatDisplayTag("客户A"), "#客户A")
        XCTAssertEqual(TagExtractor.formatDisplayTag("#客户A"), "#客户A")
    }
}

