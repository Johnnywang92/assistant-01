import XCTest
@testable import AssistantCore

final class WaterHydrationTrackerTests: XCTestCase {

    func testBeverageHydrationFactors() {
        XCTAssertEqual(HydrationBeverageType.plainWater.defaultHydrationFactor, 1.0)
        XCTAssertEqual(HydrationBeverageType.pureTea.defaultHydrationFactor, 1.0)
        XCTAssertEqual(HydrationBeverageType.blackCoffee.defaultHydrationFactor, 1.0)
        XCTAssertEqual(HydrationBeverageType.latte.defaultHydrationFactor, 0.85)
        XCTAssertEqual(HydrationBeverageType.milk.defaultHydrationFactor, 0.85)
        XCTAssertEqual(HydrationBeverageType.milkTea.defaultHydrationFactor, 0.60)
        XCTAssertEqual(HydrationBeverageType.sugaryDrink.defaultHydrationFactor, 0.60)
    }

    func testSingleSnapshotCalculations() {
        // 500ml 奶茶
        let milkTea = WaterIntakeSnapshot(
            beverageType: .milkTea,
            volumeML: 500
        )
        XCTAssertEqual(milkTea.effectiveHydrationML, 300) // 500 * 0.6
        XCTAssertEqual(milkTea.estimatedCalories, 325)    // 500 / 100 * 65
        XCTAssertEqual(milkTea.estimatedCaffeineMG, 100)  // 500 / 100 * 20

        // 250ml 黑咖啡
        let blackCoffee = WaterIntakeSnapshot(
            beverageType: .blackCoffee,
            volumeML: 250
        )
        XCTAssertEqual(blackCoffee.effectiveHydrationML, 250) // 250 * 1.0
        XCTAssertEqual(blackCoffee.estimatedCaffeineMG, 100)  // 250 / 100 * 40
        XCTAssertEqual(blackCoffee.estimatedCalories, 5)     // 250 / 100 * 2

        // 300ml 白开水
        let water = WaterIntakeSnapshot(
            beverageType: .plainWater,
            volumeML: 300
        )
        XCTAssertEqual(water.effectiveHydrationML, 300)
        XCTAssertEqual(water.estimatedCaffeineMG, 0)
        XCTAssertEqual(water.estimatedCalories, 0)
    }

    func testDailyHydrationSummary() {
        let snapshots = [
            WaterIntakeSnapshot(beverageType: .plainWater, volumeML: 500),
            WaterIntakeSnapshot(beverageType: .blackCoffee, volumeML: 250),
            WaterIntakeSnapshot(beverageType: .milkTea, volumeML: 500),
            WaterIntakeSnapshot(beverageType: .latte, volumeML: 200)
        ]

        let summary = DailyHydrationSummary(targetML: 1700, snapshots: snapshots)

        // 物理总容量: 500 + 250 + 500 + 200 = 1450 ml
        XCTAssertEqual(summary.totalVolumeML, 1450)

        // 生理折算净补水: 500 + 250 + 300 + 170 = 1220 ml
        XCTAssertEqual(summary.effectiveHydrationML, 1220)

        // 咖啡因: 0 + 100 + 100 + 60 = 260 mg
        XCTAssertEqual(summary.totalCaffeineMG, 260)
        XCTAssertFalse(summary.isCaffeineHigh)
        XCTAssertNil(summary.caffeineWarning)

        // 未达成 1700
        XCTAssertFalse(summary.isGoalAchieved)
        XCTAssertEqual(summary.progressRatio, 1220.0 / 1700.0, accuracy: 0.01)

        // 超过咖啡因报警测试
        let highCaffeineSnapshots = [
            WaterIntakeSnapshot(beverageType: .blackCoffee, volumeML: 1000) // 400mg caffeine
        ]
        let highCaffeineSummary = DailyHydrationSummary(targetML: 1700, snapshots: highCaffeineSnapshots)
        XCTAssertTrue(highCaffeineSummary.isCaffeineHigh)
        XCTAssertNotNil(highCaffeineSummary.caffeineWarning)
    }

    func testHydrationFAQContent() {
        XCTAssertEqual(HydrationScienceFAQ.items.count, 4)
        XCTAssertTrue(HydrationScienceFAQ.items.contains { $0.question.contains("黑咖啡") })
        XCTAssertTrue(HydrationScienceFAQ.items.contains { $0.question.contains("奶茶") })
    }

    func testHydrationNaturalLanguageParser() {
        // 1. 喝水
        let water = HydrationNaturalLanguageParser.parse("喝了500ml水")
        XCTAssertNotNil(water)
        XCTAssertEqual(water?.beverageType, .plainWater)
        XCTAssertEqual(water?.volumeML, 500)

        // 2. 冰美式
        let coffee = HydrationNaturalLanguageParser.parse("喝了一杯冰美式")
        XCTAssertNotNil(coffee)
        XCTAssertEqual(coffee?.beverageType, .blackCoffee)
        XCTAssertEqual(coffee?.volumeML, 300)
        XCTAssertEqual(coffee?.customName, "冰美式")

        // 3. 珍珠奶茶
        let milkTea = HydrationNaturalLanguageParser.parse("喝了一杯珍珠奶茶")
        XCTAssertNotNil(milkTea)
        XCTAssertEqual(milkTea?.beverageType, .milkTea)
        XCTAssertEqual(milkTea?.volumeML, 450)

        // 4. 乌龙茶一瓶
        let tea = HydrationNaturalLanguageParser.parse("喝了一瓶乌龙茶")
        XCTAssertNotNil(tea)
        XCTAssertEqual(tea?.beverageType, .pureTea)
        XCTAssertEqual(tea?.volumeML, 500)

        // 5. 带有正餐食物的陈述不走纯饮水
        let meal = HydrationNaturalLanguageParser.parse("早饭吃了一根玉米和一杯牛奶")
        XCTAssertNil(meal, "含固体食物陈述应由 food.record 处理")

        // 6. 消费语句不走纯饮水
        let expense = HydrationNaturalLanguageParser.parse("买咖啡花了35元")
        XCTAssertNil(expense, "含消费金额语句应由 expense 处理")
    }
}
