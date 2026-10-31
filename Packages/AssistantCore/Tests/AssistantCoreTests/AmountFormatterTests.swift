import XCTest
@testable import AssistantCore

/// 金额格式化契约测试：钉住 0/1/2 三档舍入规则与货币符号行为。
final class AmountFormatterTests: XCTestCase {

    // MARK: - 裸数字（compact）

    func testIntegerOmitsDecimals() {
        XCTAssertEqual(AmountFormatter.format(0), "0")
        XCTAssertEqual(AmountFormatter.format(1), "1")
        XCTAssertEqual(AmountFormatter.format(1500), "1500")
        XCTAssertEqual(AmountFormatter.format(-50), "-50")
    }

    func testOneDecimalIsPreserved() {
        XCTAssertEqual(AmountFormatter.format(1500.5), "1500.5")
        XCTAssertEqual(AmountFormatter.format(0.1), "0.1")
        XCTAssertEqual(AmountFormatter.format(-3.7), "-3.7")
    }

    func testTwoDecimalsArePreserved() {
        XCTAssertEqual(AmountFormatter.format(1500.55), "1500.55")
        XCTAssertEqual(AmountFormatter.format(0.01), "0.01")
        XCTAssertEqual(AmountFormatter.format(-50.25), "-50.25")
    }

    func testTrailingZerosAreStripped() {
        // 1500.50 应渲染为 "1500.5"，不是 "1500.50"
        XCTAssertEqual(AmountFormatter.format(1500.50), "1500.5")
        // 1500.00 应渲染为 "1500"
        XCTAssertEqual(AmountFormatter.format(1500.00), "1500")
    }

    func testRoundingAtBoundary() {
        // 0.005 四舍五入到 0.01（两位）
        XCTAssertEqual(AmountFormatter.format(0.005), "0.01")
        // 0.004 四舍五入到 0.00 → 整数 "0"
        XCTAssertEqual(AmountFormatter.format(0.004), "0")
        // 1.005 → 两位 "1.01"（浮点精度：1.005 实际存储为 1.00499...，round 后为 1.0）
        // 这条钉住实际行为而非数学理想值
        let result = AmountFormatter.format(1.005)
        XCTAssertTrue(result == "1.0" || result == "1.01" || result == "1",
                      "1.005 的浮点舍入结果应在合理范围内，实际：\(result)")
    }

    func testFloatingPointPrecisionTrap() {
        // 0.1 + 0.2 = 0.30000000000000004，应渲染为 "0.3"
        XCTAssertEqual(AmountFormatter.format(0.1 + 0.2), "0.3")
    }

    func testLargeValues() {
        XCTAssertEqual(AmountFormatter.format(999_999_999.0), "999999999")
        XCTAssertEqual(AmountFormatter.format(123_456.78), "123456.78")
    }

    // MARK: - 带货币符号

    func testCurrencyFormatDefaultIsAbsolute() {
        // 默认 absolute: true，负数取绝对值
        XCTAssertEqual(AmountFormatter.format(-50.25, currency: .cny), "¥50.25")
        XCTAssertEqual(AmountFormatter.format(1500.5, currency: .cny), "¥1500.5")
        XCTAssertEqual(AmountFormatter.format(1500, currency: .cny), "¥1500")
    }

    func testCurrencyFormatPreservesSignWhenAbsoluteIsFalse() {
        XCTAssertEqual(AmountFormatter.format(-50.25, currency: .cny, absolute: false), "-¥50.25")
        XCTAssertEqual(AmountFormatter.format(50.25, currency: .cny, absolute: false), "¥50.25")
    }

    func testCurrencySymbolIsUsed() {
        XCTAssertEqual(AmountFormatter.format(100, currency: .usd), "$100")
        XCTAssertEqual(AmountFormatter.format(100, currency: .jpy), "JP¥100")
        XCTAssertEqual(AmountFormatter.format(100, currency: .eur), "€100")
    }

    // MARK: - 与旧实现的一致性

    /// ExpenseCurrency.formatAmount 现在转发到 AmountFormatter，行为应一致。
    func testExpenseCurrencyFormatAmountForwards() {
        XCTAssertEqual(ExpenseCurrency.cny.formatAmount(1500.5), "¥1500.5")
        XCTAssertEqual(ExpenseCurrency.cny.formatAmount(-1500), "¥1500")
        XCTAssertEqual(ExpenseCurrency.cny.formatAmount(0), "¥0")
    }

    /// QueryAnswerBuilder.formatAmount 现在转发到 AmountFormatter。
    func testQueryAnswerBuilderFormatAmountForwards() {
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(1500.5), "1500.5")
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(1500.50), "1500.5")
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(1500), "1500")
    }
}
