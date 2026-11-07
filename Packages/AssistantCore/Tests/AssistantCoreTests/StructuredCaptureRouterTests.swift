import XCTest
@testable import AssistantCore

final class StructuredCaptureRouterTests: XCTestCase {

    /// 用户 2026-11-07 反馈的真实短信：曾被拆成「纪念日与到期 49%」。
    private let fengchaoSMS = "【丰巢】凭取件码69628356至安阁苑南区进门左侧1号丰巢柜取件。快递员及畅存规则p.fcbox.com/3gyD8"

    private func drafts(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [StructuredCaptureRouter.ParcelDraft]? {
        guard case .parcel(let drafts) = StructuredCaptureRouter.route(text) else {
            XCTFail("应直通为快递待办：\(text)", file: file, line: line)
            return nil
        }
        return drafts
    }

    // MARK: - 直通命中

    func testFengchaoPickupSMSIsRoutedToParcel() {
        guard let result = drafts(fengchaoSMS) else { return }
        XCTAssertEqual(result.count, 1)
        let draft = result[0]
        XCTAssertEqual(draft.pickupCode, "69628356")
        XCTAssertEqual(draft.station, "丰巢")
        XCTAssertEqual(draft.title, "丰巢 · 取件码 69628356")
        XCTAssertTrue(draft.location?.contains("安阁苑南区") == true)
        XCTAssertEqual(draft.sourceText, fengchaoSMS)
    }

    func testLineBreakInsideSMSDoesNotBlockRouting() {
        let text = "【菜鸟驿站】\n取件码：8-2-3021，请到北门菜鸟驿站取件"
        guard let result = drafts(text) else { return }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].pickupCode, "8-2-3021")
        XCTAssertEqual(result[0].sourceText, text)
    }

    func testMultipleCodesProduceOneDraftEach() {
        let text = "【菜鸟驿站】请凭取件码 123456、654321 到阳光小区菜鸟驿站取件"
        guard let result = drafts(text) else { return }
        XCTAssertEqual(result.map(\.pickupCode), ["123456", "654321"])
    }

    // MARK: - 不得劫持

    func testOrdinaryTodoIsNotStructured() {
        XCTAssertEqual(StructuredCaptureRouter.route("明天下午三点开会，记得带电脑"), .notStructured)
    }

    func testAlreadyPickedUpSMSIsNotStructured() {
        // 已取件要匹配并销号既有待办，不能直通成「再建一条」
        XCTAssertEqual(
            StructuredCaptureRouter.route("【丰巢】您的快递已被取走，如非本人操作请联系客服"),
            .notStructured
        )
    }

    func testVerificationCodeSMSIsNotStructured() {
        XCTAssertEqual(
            StructuredCaptureRouter.route("【某银行】您的验证码为 834921，5分钟内有效，请勿泄露。"),
            .notStructured
        )
    }

    func testLongMixedTextIsNotStructured() {
        let long = String(repeating: "随便记点什么。", count: 30) + fengchaoSMS
        XCTAssertGreaterThan(long.count, StructuredCaptureRouter.maxSMSLength)
        XCTAssertEqual(StructuredCaptureRouter.route(long), .notStructured)
    }

    func testEmptyTextIsNotStructured() {
        XCTAssertEqual(StructuredCaptureRouter.route("  \n  "), .notStructured)
    }
}
