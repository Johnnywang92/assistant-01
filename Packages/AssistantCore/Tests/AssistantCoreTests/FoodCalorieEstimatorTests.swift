import XCTest
@testable import AssistantCore

/// 食物照片热量估算的回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **识别不到却编造热量**——Vision 认不出沙拉时若随便挑一个食物填上，
///    用户会得到完全错误的数值并照着记录。
/// 2. **吃剩比例算错**——用户明确要求「没吃完要手动调整百分比」，
///    比例没乘上去等于白做。
/// 3. **非法比例未收敛**——负数或 >1 的比例会算出负热量或离谱数值。
/// 4. **LLM 输出解析太宽松**——模型可能返回散文或多个数字，不能盲取第一个。
final class FoodCalorieEstimatorTests: XCTestCase {

    // MARK: - 候选构造

    /// 核心风险 1：识别不到任何食物时必须返回空，不得凑数。
    func testNoRecognizableFoodYieldsNoCandidates() {
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("animal", 0.85), ("arthropods", 0.85), ("insect", 0.85), ("dragonfly", 0.85)
        ])
        XCTAssertTrue(candidates.isEmpty, "认不出食物时必须返回空，让用户手动选，不能硬凑")
    }

    func testRecognizesPizzaFromVisionIdentifier() {
        let candidates = FoodCalorieEstimator.candidates(from: [("pizza", 0.76), ("food", 0.90)])
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.contains { $0.food.id == "pizza" })
        // 置信度应保留 Vision 给出的原值
        let pizza = candidates.first { $0.food.id == "pizza" }
        XCTAssertEqual(pizza?.confidence ?? 0, 0.76, accuracy: 0.001)
    }

    /// 同一食物被多个类目命中时只保留最高置信度的一条。
    func testDuplicateFoodKeepsHighestConfidence() {
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("meat", 0.60), ("hamburger", 0.87), ("beef", 0.30)
        ])
        let hamburgers = candidates.filter { $0.food.id == "hamburger" }
        XCTAssertEqual(hamburgers.count, 1, "同一食物重复命中只应出现一次")
        XCTAssertEqual(hamburgers.first?.confidence ?? 0, 0.87, accuracy: 0.001)
    }

    func testCandidatesSortedByConfidenceDescending() {
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("cake", 0.30), ("pizza", 0.76), ("salad", 0.45)
        ])
        XCTAssertEqual(candidates.map(\.confidence), candidates.map(\.confidence).sorted(by: >))
    }

    func testCandidatesRespectLimit() {
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("pizza", 0.7), ("salad", 0.6), ("cake", 0.5), ("egg", 0.4), ("soup", 0.3)
        ], limit: 3)
        XCTAssertEqual(candidates.count, 3)
    }

    // MARK: - 估算

    func testEstimateFromCandidatesUsesFirstCandidate() {
        let candidates = FoodCalorieEstimator.candidates(from: [("pizza", 0.76), ("cake", 0.4)])
        let estimate = FoodCalorieEstimator.estimate(from: candidates)
        XCTAssertEqual(estimate?.food.id, "pizza")
        XCTAssertEqual(estimate?.portion, .regular)
    }

    func testEstimateReturnsNilWhenNoCandidates() {
        XCTAssertNil(FoodCalorieEstimator.estimate(from: []))
    }

    /// 核心风险 1 的延伸：按菜名反查不到时不得编造。
    func testEstimateByUnknownNameReturnsNil() {
        XCTAssertNil(FoodCalorieEstimator.estimate(foodName: "外星特产料理", confidence: 0.9))
    }

    func testEstimateByChineseNameSucceeds() {
        let estimate = FoodCalorieEstimator.estimate(foodName: "披萨", confidence: 0.8)
        XCTAssertEqual(estimate?.food.id, "pizza")
    }

    func testEstimateByAliasSucceeds() {
        let estimate = FoodCalorieEstimator.estimate(foodName: "汉堡", confidence: 0.8)
        XCTAssertEqual(estimate?.food.id, "hamburger")
    }

    // MARK: - 份量与热量换算

    func testPortionMultiplierScalesCalories() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let regular = FoodCalorieEstimator.fullPortionCalories(food: pizza, portion: .regular)
        let large = FoodCalorieEstimator.fullPortionCalories(food: pizza, portion: .large)
        let small = FoodCalorieEstimator.fullPortionCalories(food: pizza, portion: .small)
        XCTAssertEqual(large, regular * 1.8, accuracy: 0.01)
        XCTAssertEqual(small, regular * 0.5, accuracy: 0.01)
    }

    /// 核心风险 2：吃剩比例必须乘到摄入热量上。
    func testConsumedRatioScalesConsumedCalories() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let full = FoodCalorieEstimator.fullPortionCalories(food: pizza, portion: .regular)
        let half = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8, consumedRatio: 0.5)
        XCTAssertEqual(half.fullPortionCalories, full, accuracy: 0.01, "整份热量不应受吃剩比例影响")
        XCTAssertEqual(half.consumedCalories, full * 0.5, accuracy: 0.01, "摄入热量必须乘上吃剩比例")
    }

    func testWithConsumedRatioProducesNewEstimate() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let base = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8)
        let quarter = base.withConsumedRatio(0.25)
        XCTAssertEqual(quarter.consumedRatio, 0.25, accuracy: 0.001)
        XCTAssertEqual(quarter.consumedCalories, base.fullPortionCalories * 0.25, accuracy: 0.01)
        // 原对象不受影响（值类型语义）
        XCTAssertEqual(base.consumedRatio, 1.0, accuracy: 0.001)
    }

    func testWithPortionKeepsConsumedRatio() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let base = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8, consumedRatio: 0.6)
        let large = base.withPortion(.large)
        XCTAssertEqual(large.portion, .large)
        XCTAssertEqual(large.consumedRatio, 0.6, accuracy: 0.001, "换份量不应重置吃剩比例")
    }

    func testWithConsumedRatioPreservesOverriddenFullPortionCalories() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let overridden = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8)
            .withOverriddenCalories(600)
        let halfEaten = overridden.withConsumedRatio(0.5)
        XCTAssertEqual(halfEaten.fullPortionCalories, 600, accuracy: 0.01, "调整吃剩百分比不应丢失已覆盖的整份热量")
        XCTAssertEqual(halfEaten.consumedCalories, 300, accuracy: 0.01)
    }

    // MARK: - 比例边界

    /// 核心风险 3：非法比例必须收敛。
    func testClampRatioConvergesOutOfRangeValues() {
        XCTAssertEqual(FoodCalorieEstimator.clampRatio(-0.5), 0, accuracy: 0.001)
        XCTAssertEqual(FoodCalorieEstimator.clampRatio(1.8), 1, accuracy: 0.001)
        XCTAssertEqual(FoodCalorieEstimator.clampRatio(0.42), 0.42, accuracy: 0.001)
    }

    func testNaNRatioFallsBackToFull() {
        XCTAssertEqual(FoodCalorieEstimator.clampRatio(Double.nan), 1.0, accuracy: 0.001)
    }

    func testNegativeRatioDoesNotProduceNegativeCalories() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let estimate = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8, consumedRatio: -2)
        XCTAssertGreaterThanOrEqual(estimate.consumedCalories, 0, "非法比例不得产出负热量")
    }

    // MARK: - 置信度分级

    func testConfidenceLevelsThresholds() {
        XCTAssertEqual(FoodConfidenceLevel(confidence: 0.85), .high)
        XCTAssertEqual(FoodConfidenceLevel(confidence: 0.6), .high)
        XCTAssertEqual(FoodConfidenceLevel(confidence: 0.45), .medium)
        XCTAssertEqual(FoodConfidenceLevel(confidence: 0.35), .medium)
        XCTAssertEqual(FoodConfidenceLevel(confidence: 0.2), .low)
    }

    // MARK: - 摘要文案

    func testSummaryOmitsRatioWhenFullyConsumed() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let estimate = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8, consumedRatio: 1.0)
        let summary = FoodCalorieEstimator.summary(for: estimate)
        XCTAssertTrue(summary.contains("披萨"))
        XCTAssertFalse(summary.contains("吃了"), "全部吃完时不必显示百分比")
    }

    func testSummaryShowsRatioWhenPartiallyConsumed() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let estimate = FoodCalorieEstimate(food: pizza, portion: .regular, confidence: 0.8, consumedRatio: 0.5)
        let summary = FoodCalorieEstimator.summary(for: estimate)
        XCTAssertTrue(summary.contains("50%"), "吃剩比例必须体现在摘要里")
    }

    func testSummaryShowsPortionWhenNotRegular() {
        let pizza = FoodCatalog.item(id: "pizza")!
        let estimate = FoodCalorieEstimate(food: pizza, portion: .large, confidence: 0.8)
        XCTAssertTrue(FoodCalorieEstimator.summary(for: estimate).contains("大份"))
    }

    // MARK: - 食物库

    func testCatalogContainsCommonFoods() {
        for id in ["rice", "pizza", "hamburger", "salad", "noodles", "coffee", "milk_tea", "steak", "egg"] {
            XCTAssertNotNil(FoodCatalog.item(id: id), "食物库应包含 \(id)")
        }
    }

    /// 每条食物的标准份热量必须落在合理区间——数据填错会静默产出离谱数值。
    func testAllFoodsHavePlausibleServingCalories() {
        for item in FoodCatalog.items {
            let calories = item.standardServingCalories
            XCTAssertGreaterThan(calories, 0, "\(item.name) 的标准份热量应为正")
            XCTAssertLessThan(calories, 1500, "\(item.name) 的标准份热量异常偏高：\(calories)")
        }
    }

    func testCoffeeHasLowCaloriePerServing() {
        let coffee = FoodCatalog.item(id: "coffee")!
        XCTAssertLessThan(coffee.standardServingCalories, 50, "一杯咖啡不应超过 50 千卡")
    }

    // MARK: - 多菜托盘餐组合与热量累加回归测试

    /// 回归测试：中式托盘餐（米饭 + 辣椒炒肉/家常小炒 + 凉拌海带丝）必须把所有配菜识别并累加热量，不能只算米饭。
    func testTrayMealCombinesRiceAndDishesCalories() {
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("rice", 0.89),
            ("green_beans", 0.44),
            ("stir_fry", 0.27),
            ("soup", 0.12),
            ("seaweed", 0.12)
        ], limit: 8)

        let meal = FoodCalorieEstimator.estimateMeal(from: candidates)
        XCTAssertNotNil(meal)
        let dishIDs = meal?.dishes.map(\.food.id) ?? []
        XCTAssertTrue(dishIDs.contains("rice"), "应包含米饭")
        XCTAssertTrue(dishIDs.contains("stir_fry_meat"), "应识别出辣椒炒肉/家常小炒")
        XCTAssertTrue(dishIDs.contains("seaweed_dish"), "应识别出凉拌海带丝/凉菜")
        XCTAssertFalse(dishIDs.contains("vegetable_dish"), "辣椒炒肉中的辣椒不应重复计为第二份炒青菜")

        let riceCal = FoodCatalog.item(id: "rice")!.standardServingCalories
        let stirFryCal = FoodCatalog.item(id: "stir_fry_meat")!.standardServingCalories
        let seaweedCal = FoodCatalog.item(id: "seaweed_dish")!.standardServingCalories
        XCTAssertEqual(meal?.fullPortionCalories ?? 0, riceCal + stirFryCal + seaweedCal, accuracy: 0.1)
        XCTAssertEqual(meal?.consumedCalories ?? 0, riceCal + stirFryCal + seaweedCal, accuracy: 0.1)
    }

    /// 回归测试：支持单独调整托盘餐中某一道菜吃掉的百分比（如米饭只吃一半 50%，菜全部吃完 100%）。
    func testUpdatingSingleDishConsumedRatioRecalculatesTotal() {
        let rice = FoodCatalog.item(id: "rice")!
        let stirFry = FoodCatalog.item(id: "stir_fry_meat")!
        let seaweed = FoodCatalog.item(id: "seaweed_dish")!
        let meal = FoodCalorieEstimate(dishes: [
            FoodDishEstimate(food: rice, consumedRatio: 1.0),
            FoodDishEstimate(food: stirFry, consumedRatio: 1.0),
            FoodDishEstimate(food: seaweed, consumedRatio: 1.0)
        ])

        let halfRiceMeal = meal.updatingDishConsumedRatio(dishID: "rice", ratio: 0.5)
        let expectedConsumed = rice.standardServingCalories * 0.5
            + stirFry.standardServingCalories
            + seaweed.standardServingCalories
        XCTAssertEqual(halfRiceMeal.consumedCalories, expectedConsumed, accuracy: 0.1)
        XCTAssertEqual(halfRiceMeal.fullPortionCalories, meal.fullPortionCalories, accuracy: 0.1)
    }

    /// 回归测试：支持手动向本餐添加或移除配菜并实时更新总热量。
    func testAddingAndRemovingDishInMeal() {
        let rice = FoodCatalog.item(id: "rice")!
        let stirFry = FoodCatalog.item(id: "stir_fry_meat")!
        let base = FoodCalorieEstimate(food: rice, portion: .regular, confidence: 0.9)
        let added = base.addingDish(FoodDishEstimate(food: stirFry))
        XCTAssertEqual(added.dishes.count, 2)
        XCTAssertEqual(added.fullPortionCalories, rice.standardServingCalories + stirFry.standardServingCalories, accuracy: 0.1)

        let removed = added.removingDish(dishID: "stir_fry_meat")
        XCTAssertEqual(removed.dishes.count, 1)
        XCTAssertEqual(removed.fullPortionCalories, rice.standardServingCalories, accuracy: 0.1)
    }

    /// 回归测试：用户补充多菜描述（如「米饭、辣椒炒肉、凉拌海带丝」）时能拆分识别并汇总整餐热量。
    func testEstimateMealFromMultiDishHint() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "米饭、辣椒炒肉、凉拌海带丝")
        XCTAssertNotNil(meal)
        XCTAssertEqual(meal?.dishes.count, 3)
        XCTAssertTrue(meal?.displayName.contains("米饭") ?? false)
        XCTAssertTrue(meal?.displayName.contains("辣椒炒肉") ?? false)
        XCTAssertTrue(meal?.displayName.contains("凉拌海带丝") ?? false)
    }
}
