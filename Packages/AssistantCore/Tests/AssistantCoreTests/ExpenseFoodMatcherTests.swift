import XCTest
@testable import AssistantCore

final class ExpenseFoodMatcherTests: XCTestCase {

    func testMilkTeaBrandMatchesCatalog() throws {
        let s = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "喜茶多肉葡萄奶茶"))
        XCTAssertEqual(s.foodID, "milk_tea")
        XCTAssertEqual(s.fullPortionCalories, 350, accuracy: 1)
        XCTAssertEqual(s.origin, .catalog)
    }

    func testLatteIsNotTreatedAsBlackCoffee() throws {
        let latte = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "瑞幸拿铁"))
        XCTAssertEqual(latte.foodID, "latte")
        XCTAssertGreaterThan(latte.fullPortionCalories, 100)
        let americano = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "星巴克美式"))
        XCTAssertEqual(americano.foodID, "coffee")
        XCTAssertLessThan(americano.fullPortionCalories, 50)
    }

    func testSizeAndSugarModifiers() throws {
        let regular = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "奶茶"))
        let large = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "大杯奶茶"))
        let halfSugar = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "奶茶半糖"))
        XCTAssertGreaterThan(large.fullPortionCalories, regular.fullPortionCalories)
        XCTAssertEqual(large.portion, .large)
        XCTAssertLessThan(halfSugar.fullPortionCalories, regular.fullPortionCalories)
    }

    func testSnackMatches() throws {
        let s = try XCTUnwrap(ExpenseFoodMatcher.suggest(title: "乐事薯片"))
        XCTAssertEqual(s.foodID, "chips")
    }

    func testUnknownTitleReturnsNil() {
        XCTAssertNil(ExpenseFoodMatcher.suggest(title: "滴滴打车"))
        XCTAssertNil(ExpenseFoodMatcher.suggest(title: "  "))
    }

    func testLLMSuggestionBounds() {
        let ok = FoodLLMOutputParser.Parsed(foodName: "麻辣烫", calories: 520, portion: nil, confidence: 0.95)
        let s = ExpenseFoodMatcher.suggestion(fromLLM: ok)
        XCTAssertEqual(s?.origin, .llm)
        XCTAssertEqual(s?.confidence ?? 0, 0.3, accuracy: 0.001, "不采信模型自评置信度")

        for bad in [0.0, 5, 99_999] {
            let p = FoodLLMOutputParser.Parsed(foodName: "麻辣烫", calories: bad, portion: nil, confidence: nil)
            XCTAssertNil(ExpenseFoodMatcher.suggestion(fromLLM: p), "\(bad) 千卡应被丢弃")
        }
        XCTAssertNil(ExpenseFoodMatcher.suggestion(
            fromLLM: .init(foodName: "", calories: 300, portion: nil, confidence: nil)))
    }

    func testLLMCaloriesReconciledWithCatalogBaseline() throws {
        // 给米饭估 900 千卡（标准份约 232）→ 回退食物库基准
        let p = FoodLLMOutputParser.Parsed(foodName: "米饭", calories: 900, portion: nil, confidence: nil)
        let s = try XCTUnwrap(ExpenseFoodMatcher.suggestion(fromLLM: p))
        XCTAssertEqual(s.fullPortionCalories, 232, accuracy: 1)
        XCTAssertEqual(s.foodID, "rice")
    }

    func testMealSlot() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ h: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: h))!
        }
        XCTAssertEqual(ExpenseFoodMatcher.mealSlot(for: date(8), calendar: cal), .breakfast)
        XCTAssertEqual(ExpenseFoodMatcher.mealSlot(for: date(12), calendar: cal), .lunch)
        XCTAssertEqual(ExpenseFoodMatcher.mealSlot(for: date(19), calendar: cal), .dinner)
        XCTAssertEqual(ExpenseFoodMatcher.mealSlot(for: date(23), calendar: cal), .lateNight)
        XCTAssertEqual(ExpenseFoodMatcher.mealSlot(for: date(12), foodID: "milk_tea", calendar: cal), .snack)
    }
}
