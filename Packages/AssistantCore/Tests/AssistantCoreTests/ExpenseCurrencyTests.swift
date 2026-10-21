import XCTest
@testable import AssistantCore

final class ExpenseCurrencyTests: XCTestCase {

    func testConvertToCNYWithDefaultAndCustomRates() {
        let suiteName = "assistant.tests.currency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 默认参考汇率折算：1000 日元 ≈ 47.00 人民币；100 美元 = 720.00 人民币
        XCTAssertEqual(ExpenseCurrency.jpy.convertToCNY(1000, rate: ExpenseCurrency.jpy.currentRateToCNY(in: defaults)), 47.00, accuracy: 0.01)
        XCTAssertEqual(ExpenseCurrency.usd.convertToCNY(100, rate: ExpenseCurrency.usd.currentRateToCNY(in: defaults)), 720.00, accuracy: 0.01)
        XCTAssertEqual(ExpenseCurrency.cny.convertToCNY(88.5), 88.50, accuracy: 0.01)

        // 自定义汇率持久化与重置
        ExpenseCurrency.jpy.setCustomRateToCNY(0.0500, in: defaults)
        XCTAssertTrue(ExpenseCurrency.jpy.hasCustomRate(in: defaults))
        XCTAssertEqual(ExpenseCurrency.jpy.currentRateToCNY(in: defaults), 0.0500, accuracy: 0.0001)
        XCTAssertEqual(ExpenseCurrency.jpy.convertToCNY(2000, rate: ExpenseCurrency.jpy.currentRateToCNY(in: defaults)), 100.00, accuracy: 0.01)

        ExpenseCurrency.jpy.resetRateToDefault(in: defaults)
        XCTAssertFalse(ExpenseCurrency.jpy.hasCustomRate(in: defaults))
        XCTAssertEqual(ExpenseCurrency.jpy.currentRateToCNY(in: defaults), ExpenseCurrency.jpy.defaultRateToCNY, accuracy: 0.0001)
    }

    func testDetectExplicitCurrencyForCommonTravelInputs() {
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "一兰拉面 1200日元"), .jpy)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "便利店买水 160円"), .jpy)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "药妆店 JP¥8500"), .jpy)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "星巴克 $6.5"), .usd)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "打车花了 28 美元"), .usd)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "买鞋 85 刀"), .usd)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "博物馆门票 25欧元"), .eur)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "晚餐 €48"), .eur)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "茶餐厅 HK$85"), .hkd)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "烤肉 45000韩元"), .krw)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "按摩 600泰铢"), .thb)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "音乐剧 £65"), .gbp)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "肉骨茶 S$28"), .sgd)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "夜市 350新台币"), .twd)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "榴莲 RM45"), .myr)
        XCTAssertEqual(ExpenseCurrency.detectExplicitCurrency(in: "麦当劳花了 38 元"), .cny)
        XCTAssertNil(ExpenseCurrency.detectExplicitCurrency(in: "便利店买水 150"))
    }

    func testPreferredCurrencyPersistence() {
        let suiteName = "assistant.tests.prefcurrency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ExpenseCurrency.preferred(in: defaults), .cny)
        ExpenseCurrency.setPreferred(.jpy, in: defaults)
        XCTAssertEqual(ExpenseCurrency.preferred(in: defaults), .jpy)
    }
}
