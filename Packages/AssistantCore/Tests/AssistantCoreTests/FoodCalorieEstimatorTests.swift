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
            XCTAssertGreaterThanOrEqual(calories, 0, "\(item.name) 的标准份热量不能为负")
            XCTAssertLessThan(calories, 1500, "\(item.name) 的标准份热量异常偏高：\(calories)")
        }
    }

    func testCoffeeHasLowCaloriePerServing() {
        let coffee = FoodCatalog.item(id: "coffee")!
        XCTAssertLessThan(coffee.standardServingCalories, 50, "一杯咖啡不应超过 50 千卡")
    }

    func testUSDAReferenceOverridesEnergyAndServingTogether() throws {
        XCTAssertEqual(USDAFoodReference.entriesByID.count, 143)
        let rice = try XCTUnwrap(FoodCatalog.item(id: "rice"))
        XCTAssertEqual(rice.caloriesPer100g, 130, accuracy: 0.01)
        XCTAssertEqual(rice.standardServingGrams, 150, accuracy: 0.01)
        XCTAssertEqual(rice.standardServingCalories, 195, accuracy: 0.01)
        XCTAssertEqual(rice.fdcID, "168878")

        let burger = try XCTUnwrap(FoodCatalog.item(id: "hamburger"))
        XCTAssertEqual(burger.standardServingGrams, 110, accuracy: 0.01)
        XCTAssertEqual(burger.standardServingCalories, 289.3, accuracy: 0.01)
        XCTAssertEqual(burger.fdcID, "170694")
    }

    func testUSDAZeroEnergyAndQuestionableMapping() throws {
        let cola = try XCTUnwrap(FoodCatalog.item(id: "sugar_free_cola"))
        XCTAssertEqual(cola.standardServingCalories, 0, accuracy: 0.01)
        XCTAssertEqual(cola.fdcID, "2438151")
        // 原资料中的“芒果”对应罐装芒果汁，不能覆盖水果条目。
        XCTAssertNil(FoodCatalog.item(id: "usda_f094"))
        XCTAssertNil(FoodCatalog.item(id: "latte")?.fdcID)
    }

    func testUSDAAdditionalFoodsKeepPreparationState() throws {
        let egg = try XCTUnwrap(FoodCatalog.item(id: "usda_f048"))
        XCTAssertEqual(egg.name, "水煮蛋")
        XCTAssertEqual(egg.standardServingCalories, 77.5, accuracy: 0.01)
        XCTAssertEqual(egg.fdcID, "173424")
        let broccoli = try XCTUnwrap(FoodCatalog.item(id: "usda_f058"))
        XCTAssertTrue(broccoli.name.contains("生"))
        XCTAssertEqual(FoodCatalog.item(matchingNameStrict: "橙子")?.id, "usda_f087")
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

    // MARK: - 修改识别结果与扩充食物测试

    /// 测试修改整餐自定义展示名称
    func testCustomMealDisplayName() {
        let rice = FoodCatalog.item(id: "rice")!
        let meal = FoodCalorieEstimate(food: rice, portion: .regular, confidence: 0.9)
        XCTAssertEqual(meal.displayName, "米饭")

        let renamed = meal.withCustomDisplayName("工作日减脂午餐")
        XCTAssertEqual(renamed.displayName, "工作日减脂午餐")

        let cleared = renamed.withCustomDisplayName("")
        XCTAssertEqual(cleared.displayName, "米饭")
    }

    /// 测试替换识别菜品（换菜）
    func testReplacingDishInMeal() {
        let rice = FoodCatalog.item(id: "rice")!
        let beef = FoodCatalog.item(id: "beef")!
        let pork = FoodCatalog.item(id: "pork")!
        let meal = FoodCalorieEstimate(dishes: [
            FoodDishEstimate(food: rice),
            FoodDishEstimate(food: beef)
        ])

        let replaced = meal.replacingDish(dishID: "beef", with: pork)
        XCTAssertEqual(replaced.dishes.count, 2)
        XCTAssertFalse(replaced.dishes.contains { $0.food.id == "beef" })
        XCTAssertTrue(replaced.dishes.contains { $0.food.id == "pork" })
        XCTAssertEqual(replaced.fullPortionCalories, rice.standardServingCalories + pork.standardServingCalories, accuracy: 0.1)
    }

    /// 测试直接修改菜品名称和自定义整份热量
    func testUpdatingDishDetails() {
        let rice = FoodCatalog.item(id: "rice")!
        let meal = FoodCalorieEstimate(food: rice, portion: .regular, confidence: 0.9)

        let updated = meal.updatingDish(dishID: "rice", name: "五谷杂粮饭", calories: 180.0)
        XCTAssertEqual(updated.dishes[0].food.name, "五谷杂粮饭")
        XCTAssertEqual(updated.dishes[0].fullPortionCalories, 180.0, accuracy: 0.1)
        XCTAssertEqual(updated.consumedCalories, 180.0, accuracy: 0.1)
    }

    /// 测试自定义食物与分类
    func testCustomFoodItemCreation() {
        let customFood = FoodItem.custom(name: "妈妈自制牛肉酱", calories: 250.0, category: .meat)
        XCTAssertEqual(customFood.name, "妈妈自制牛肉酱")
        XCTAssertEqual(customFood.category, .meat)
        XCTAssertEqual(customFood.standardServingCalories, 250.0, accuracy: 0.1)
    }

    /// 测试所有分类均收录条目
    func testAllCategoriesHaveItems() {
        for category in FoodCategory.allCases {
            let count = FoodCatalog.items.filter { $0.category == category }.count
            XCTAssertGreaterThan(count, 0, "分类 \(category.rawValue) 必须收录食物条目")
        }
        XCTAssertGreaterThanOrEqual(FoodCatalog.items.count, 70, "食物库条目扩充后应至少包含 70 种食物")
    }

    /// 测试自然口语用餐「早饭吃了一根玉米和一杯牛奶」能被准确拆解出两道菜且正确估算热量
    func testEstimateMealFromBreakfastCornAndMilk() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "早饭吃了一根玉米和一杯牛奶")
        XCTAssertNotNil(meal)
        guard let m = meal else { return }
        XCTAssertEqual(m.dishes.count, 2)
        let dishIDs = m.dishes.map(\.food.id)
        XCTAssertTrue(dishIDs.contains("corn_sweetpotato"), "应识别出玉米")
        XCTAssertTrue(dishIDs.contains("pure_milk"), "应识别出纯牛奶")
        XCTAssertGreaterThan(m.fullPortionCalories, 200)
    }

    /// 测试图片视觉识别候选构造整餐估算
    func testEstimateMealFromVisionCandidates() {
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("pizza", 0.85),
            ("coke", 0.70)
        ])
        XCTAssertFalse(candidates.isEmpty)
        let estimate = FoodCalorieEstimator.estimateMeal(from: candidates)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate?.food.id, "pizza")
        XCTAssertEqual(estimate?.fullPortionCalories ?? 0, 428.8, accuracy: 0.1)
    }

    /// 测试用餐时段先验加权：在早餐时段，包子等早点得到权重加成，火锅等夜宵/大菜被降权
    func testMealTimePeriodPriorWeightsBreakfastAndDinner() {
        let breakfastBun = FoodCatalog.item(id: "steamed_bun")!
        let hotpot = FoodCatalog.item(id: "hotpot")!

        XCTAssertGreaterThan(MealTimePeriod.breakfast.priorMultiplier(for: breakfastBun), 1.2)
        XCTAssertLessThan(MealTimePeriod.breakfast.priorMultiplier(for: hotpot), 0.7)

        // 模拟早晨 08:30 时段
        var cal = Calendar.current
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 10
        comps.day = 26
        comps.hour = 8
        comps.minute = 30
        let morning = cal.date(from: comps)!
        let period = MealTimePeriod.from(date: morning, calendar: cal)
        XCTAssertEqual(period, .breakfast)

        // 当分类器同时给出置信度相同的包子和火锅时，早餐时段包子排第一
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("hotpot", 0.50),
            ("bun", 0.50)
        ], limit: 2, mealTime: period)

        XCTAssertEqual(candidates.first?.food.id, "steamed_bun", "早餐时段应优先排包子")
    }

    /// 测试用户常吃历史先验：高频食用菜品在相近置信度下获得先验提升
    func testFoodHistoryPriorPromotesFrequentUserDishes() {
        // 用户常吃米饭（10次），最近刚吃过
        let prior = FoodHistoryPrior(frequentItemCounts: ["rice": 10], recentItemIDs: ["rice"])
        XCTAssertGreaterThan(prior.multiplier(for: "rice"), 1.2)

        // 即使原始分类置信度稍微偏低，常吃加权也能使其超越不常吃的候选
        let candidates = FoodCalorieEstimator.candidates(from: [
            ("sushi", 0.45),
            ("rice", 0.40)
        ], limit: 2, history: prior)

        XCTAssertEqual(candidates.first?.food.id, "rice", "用户常吃菜品加权后应浮现至首位")
    }
}
