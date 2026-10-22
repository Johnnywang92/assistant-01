import XCTest
@testable import AssistantCore

final class ExpenseWaterMatcherTests: XCTestCase {

    func testCoffeeRecognition() {
        // 纯咖啡/美式
        let coffee = ExpenseWaterMatcher.match(title: "买咖啡 18 元")
        XCTAssertNotNil(coffee)
        XCTAssertEqual(coffee?.beverageType, .blackCoffee)
        XCTAssertEqual(coffee?.volumeML, 350.0)
        XCTAssertEqual(coffee?.hydrationFactor, 1.0)
        XCTAssertEqual(coffee?.effectiveHydrationML, 350.0)
        XCTAssertTrue((coffee?.caffeineMG ?? 0) > 100) // 350ml * 40mg/100ml = 140mg

        // 星巴克大杯美式
        let ventiAmericano = ExpenseWaterMatcher.match(title: "星巴克大杯美式")
        XCTAssertNotNil(ventiAmericano)
        XCTAssertEqual(ventiAmericano?.beverageType, .blackCoffee)
        XCTAssertEqual(ventiAmericano?.volumeML, 500.0)

        // 拿铁 / 奶咖
        let latte = ExpenseWaterMatcher.match(title: "瑞幸生椰拿铁 15元")
        XCTAssertNotNil(latte)
        XCTAssertEqual(latte?.beverageType, .latte)
        XCTAssertEqual(latte?.hydrationFactor, 0.85)
        XCTAssertEqual(latte?.effectiveHydrationML, (350.0 * 0.85).rounded())
    }

    func testMilkTeaRecognition() {
        // 喜茶波波奶茶
        let milkTea = ExpenseWaterMatcher.match(title: "喜茶烤黑糖波波奶茶 22元")
        XCTAssertNotNil(milkTea)
        XCTAssertEqual(milkTea?.beverageType, .milkTea)
        XCTAssertEqual(milkTea?.volumeML, 450.0)
        XCTAssertEqual(milkTea?.hydrationFactor, 0.60)
        XCTAssertEqual(milkTea?.effectiveHydrationML, (450.0 * 0.60).rounded())

        // 霸王茶姬
        let bwcj = ExpenseWaterMatcher.match(title: "霸王茶姬伯牙绝弦")
        XCTAssertNotNil(bwcj)
        XCTAssertEqual(bwcj?.beverageType, .milkTea)
    }

    func testTeaAndSoftDrinks() {
        // 东方树叶纯茶
        let tea = ExpenseWaterMatcher.match(title: "东方树叶茉莉花茶 5元")
        XCTAssertNotNil(tea)
        XCTAssertEqual(tea?.beverageType, .pureTea)
        XCTAssertEqual(tea?.hydrationFactor, 1.0)

        // 可乐
        let cola = ExpenseWaterMatcher.match(title: "买了一听可乐 3块")
        XCTAssertNotNil(cola)
        XCTAssertEqual(cola?.beverageType, .sugaryDrink)
        XCTAssertEqual(cola?.volumeML, 330.0)
    }

    func testMultiplierAndVolumeExtraction() {
        // 两杯拿铁
        let twoLattes = ExpenseWaterMatcher.match(title: "买了两杯拿铁")
        XCTAssertNotNil(twoLattes)
        XCTAssertEqual(twoLattes?.beverageType, .latte)
        XCTAssertEqual(twoLattes?.volumeML, 700.0)

        // 明确容量：500ml 冰美式
        let explicitVolume = ExpenseWaterMatcher.match(title: "500ml 冰美式")
        XCTAssertNotNil(explicitVolume)
        XCTAssertEqual(explicitVolume?.volumeML, 500.0)
    }

    func testNonDrinkExclusions() {
        // 咖啡豆/机、食物
        XCTAssertNil(ExpenseWaterMatcher.match(title: "买了一袋咖啡豆"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "德龙咖啡机 2500元"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "可乐鸡翅"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "茶叶蛋两个 4元"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "奶茶色毛衣"))

        // 普通食物
        XCTAssertNil(ExpenseWaterMatcher.match(title: "麦当劳巨无霸汉堡"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "兰州拉面 18元"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "打车到公司 25元"))
        XCTAssertNil(ExpenseWaterMatcher.match(title: "看电影两张票 90元"))
    }
}
