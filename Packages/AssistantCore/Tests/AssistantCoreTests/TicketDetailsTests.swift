import XCTest
@testable import AssistantCore

final class TicketDetailsTests: XCTestCase {

    func testExtracts12306Message() {
        let text = "您购买的10月12日G1234次列车 北京南站14:30开，5车厢12A号，检票口B12。请提前候车。"
        let info = TicketDetailsExtractor.extract(from: text)
        XCTAssertEqual(info.vehicleNumber, "G1234")
        XCTAssertEqual(info.carNumber, "5")
        XCTAssertEqual(info.seatNumber, "12A")
        XCTAssertEqual(info.gate, "B12")
        XCTAssertEqual(info.seatLine, "5车 12A")
        XCTAssertEqual(info.wristSummary, "G1234 · 5车 12A · 检票口B12")
    }

    func testExtractsFlightGate() {
        let text = "航班MU5102 上海虹桥T2 登机口C23 座位32A 起飞时间08:15"
        let info = TicketDetailsExtractor.extract(from: text)
        XCTAssertEqual(info.vehicleNumber, "MU5102")
        XCTAssertEqual(info.gate, "C23")
        XCTAssertEqual(info.seatNumber, "32A")
    }

    func testLabelledVehicleWins() {
        let text = "车次 D2286，车厢 7，检票口 A1"
        let info = TicketDetailsExtractor.extract(from: text)
        XCTAssertEqual(info.vehicleNumber, "D2286")
        XCTAssertEqual(info.carNumber, "7")
        XCTAssertEqual(info.gate, "A1")
    }

    func testFullwidthGateIsNormalized() {
        let text = "检票口：Ｂ７"
        let info = TicketDetailsExtractor.extract(from: text)
        XCTAssertEqual(info.gate, "B7")
    }

    func testEmptyResultWhenNothingMatches() {
        let info = TicketDetailsExtractor.extract(from: "明天下午三点记得带伞")
        XCTAssertTrue(info.isEmpty)
        XCTAssertNil(info.wristSummary)
    }

    func testEmptyInput() {
        let info = TicketDetailsExtractor.extract(from: "")
        XCTAssertTrue(info.isEmpty)
    }

    func testSeatDoesNotSwallowTrainNumber() {
        // C2002 是车次，不应被拆出 "2A" 之类的座位号
        let info = TicketDetailsExtractor.extract(from: "城际列车 车次C2002 检票口 3")
        XCTAssertEqual(info.vehicleNumber, "C2002")
        XCTAssertNil(info.seatNumber)
        XCTAssertEqual(info.gate, "3")
    }

    func testExtractFromMultipleTexts() {
        let info = TicketDetailsExtractor.extract(from: [
            "标题：高铁票",
            nil,
            "10月12日 K1234 次 8车厢 15车 22B"
        ])
        XCTAssertEqual(info.vehicleNumber, "K1234")
        XCTAssertEqual(info.carNumber, "8")
        XCTAssertEqual(info.seatNumber, "22B")
    }
}
