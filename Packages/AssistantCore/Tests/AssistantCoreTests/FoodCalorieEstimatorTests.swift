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

    // MARK: - 早餐包子与鸡蛋热量标定及量词解析测试

    /// 回归测试：早餐输入「包子，鸡蛋」必须估算为合理的 260~300 千卡区间（约 287 千卡），
    /// 不能虚高达 423 千卡（之前包子按 150g 算 345 卡，且鸡蛋名称错误混杂西红柿炒鸡蛋）。
    func testBreakfastBunAndEggRealisticCalories() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "包子，鸡蛋")
        XCTAssertNotNil(meal)
        guard let m = meal else { return }

        XCTAssertEqual(m.dishes.count, 2)
        let dishNames = m.dishes.map(\.food.name)
        XCTAssertTrue(dishNames.contains(where: { $0.contains("包子") }))
        XCTAssertTrue(dishNames.contains(where: { $0.contains("鸡蛋") || $0.contains("茶叶蛋") }))

        // 单个标准肉包约 200~250 千卡 (90g * 2.3 = 207 千卡)
        let bunDish = m.dishes.first(where: { $0.food.id == "steamed_bun" })
        XCTAssertNotNil(bunDish)
        XCTAssertEqual(bunDish?.fullPortionCalories ?? 0, 207, accuracy: 5.0)

        // 单颗水煮蛋/茶叶蛋约 70~80 千卡 (55g * 1.45 = 79.75 千卡)
        let eggDish = m.dishes.first(where: { $0.food.id == "egg" })
        XCTAssertNotNil(eggDish)
        XCTAssertEqual(eggDish?.fullPortionCalories ?? 0, 80, accuracy: 5.0)

        // 整餐总热量落在 260~300 千卡合理区间
        XCTAssertGreaterThanOrEqual(m.fullPortionCalories, 260.0)
        XCTAssertLessThanOrEqual(m.fullPortionCalories, 300.0)
    }

    /// 回归测试：口语「一个肉包加一颗茶叶蛋」能正确解析数量并落在 260~300 千卡
    func testBreakfastOneMeatBunAndOneTeaEgg() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "一个肉包加一颗茶叶蛋")
        XCTAssertNotNil(meal)
        guard let m = meal else { return }

        XCTAssertEqual(m.dishes.count, 2)
        XCTAssertGreaterThanOrEqual(m.fullPortionCalories, 260.0)
        XCTAssertLessThanOrEqual(m.fullPortionCalories, 300.0)
    }

    /// 回归测试：输入多个量词时能够正确翻倍计算热量
    func testQuantityMultipliersAndPortions() {
        // 2 个肉包 + 1 颗茶叶蛋 -> 207 * 2 + 80 = 494 千卡
        let doubleBunMeal = FoodCalorieEstimator.estimateMeal(fromHint: "2个肉包加一颗茶叶蛋")
        XCTAssertNotNil(doubleBunMeal)
        guard let db = doubleBunMeal else { return }

        XCTAssertEqual(db.dishes.count, 2)
        let bunDish = db.dishes.first(where: { $0.food.id == "steamed_bun" })
        XCTAssertEqual(bunDish?.fullPortionCalories ?? 0, 414.0, accuracy: 10.0)
        XCTAssertEqual(db.fullPortionCalories, 494.0, accuracy: 15.0)

        // 半碗米饭 -> 150g / 2 = 75g -> 195 * 0.5 = 97.5 千卡
        let halfRiceMeal = FoodCalorieEstimator.estimateMeal(fromHint: "半碗米饭")
        XCTAssertNotNil(halfRiceMeal)
        XCTAssertEqual(halfRiceMeal?.fullPortionCalories ?? 0, 97.5, accuracy: 5.0)
    }

    /// 回归测试：量词修饰剥离不能误伤词尾为量词的食物名（如「肉包」被误切为「肉」、「油条」被误切为「油」）
    func testStripPortionModifiersPreservesFoodWordsEndingInMeasureChars() {
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("一个肉包"), "肉包")
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("一根油条"), "油条")
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("一包薯片"), "薯片")
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("两串羊肉串"), "羊肉串")
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("肉包（1个，约80–100g）"), "肉包")
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("大份牛肉面"), "牛肉面")
        XCTAssertEqual(FoodCatalog.stripPortionModifiers("米饭一份"), "米饭")

        let bun = FoodCatalog.item(matchingNameStrict: "一个肉包")
        XCTAssertEqual(bun?.id, "steamed_bun")

        let youtiao = FoodCatalog.item(matchingNameStrict: "一根油条")
        XCTAssertTrue(youtiao?.name.contains("油条") ?? false)
    }

    /// 回归测试：鸡蛋与蛋类菜品细分，不再将茶叶蛋/水煮蛋混为「西红柿炒鸡蛋/荷包蛋」
    func testEggCategorySeparation() {
        let teaEgg = FoodCatalog.item(matchingNameStrict: "茶叶蛋")
        XCTAssertEqual(teaEgg?.id, "egg")
        XCTAssertTrue(teaEgg?.name.contains("茶叶蛋") ?? false)
        XCTAssertFalse(teaEgg?.name.contains("西红柿") ?? false)
        XCTAssertEqual(teaEgg?.standardServingCalories ?? 0, 79.75, accuracy: 2.0)

        let friedEgg = FoodCatalog.item(matchingNameStrict: "荷包蛋")
        XCTAssertEqual(friedEgg?.id, "fried_egg")
        XCTAssertEqual(friedEgg?.standardServingCalories ?? 0, 101.75, accuracy: 2.0)

        let tomatoEgg = FoodCatalog.item(matchingNameStrict: "西红柿炒鸡蛋")
        XCTAssertEqual(tomatoEgg?.id, "tomato_scrambled_egg")
        XCTAssertEqual(tomatoEgg?.standardServingCalories ?? 0, 220.0, accuracy: 5.0)

        let shengjian = FoodCatalog.item(matchingNameStrict: "生煎包")
        XCTAssertEqual(shengjian?.id, "shengjian_xiaolong")
        XCTAssertEqual(shengjian?.standardServingCalories ?? 0, 345.0, accuracy: 5.0)

        let xiaolong = FoodCatalog.item(matchingNameStrict: "小笼包")
        XCTAssertTrue(xiaolong?.name.contains("小笼包") ?? false)
    }

    /// 回归测试：件数换算与防热量膨胀（如「10个水饺」应为单件约20g累加，而不是整份200g翻10倍变成4800卡）
    func testDumplingAndSkewerPieceUnitsRealisticCalories() {
        // 10 个水饺 -> 10 * 20g = 200g -> 480 千卡
        let dumplings10 = FoodCalorieEstimator.estimateMeal(fromHint: "10个水饺")
        XCTAssertNotNil(dumplings10)
        XCTAssertEqual(dumplings10?.fullPortionCalories ?? 0, 480.0, accuracy: 20.0)

        // 5 个水饺 -> 5 * 20g = 100g -> 240 千卡
        let dumplings5 = FoodCalorieEstimator.estimateMeal(fromHint: "5个水饺")
        XCTAssertEqual(dumplings5?.fullPortionCalories ?? 0, 240.0, accuracy: 15.0)

        // 1 个水饺 -> 20g -> 48 千卡
        let dumpling1 = FoodCalorieEstimator.estimateMeal(fromHint: "1个水饺")
        XCTAssertEqual(dumpling1?.fullPortionCalories ?? 0, 48.0, accuracy: 5.0)

        // 一份水饺 / 一盘水饺 -> 整份 200g -> 480 千卡
        let dumplingServing = FoodCalorieEstimator.estimateMeal(fromHint: "一份水饺")
        XCTAssertEqual(dumplingServing?.fullPortionCalories ?? 0, 480.0, accuracy: 10.0)

        // 5 串羊肉串 -> 5 * 35g = 175g -> (175/100) * 260 = 455 千卡
        let skewers = FoodCalorieEstimator.estimateMeal(fromHint: "5串羊肉串")
        XCTAssertNotNil(skewers)
        XCTAssertEqual(skewers?.fullPortionCalories ?? 0, 455.0, accuracy: 20.0)

        // 4 个生煎 -> 4 * 35g = 140g -> (140/100) * 230 = 322 千卡
        let shengjian4 = FoodCalorieEstimator.estimateMeal(fromHint: "4个生煎")
        XCTAssertNotNil(shengjian4)
        XCTAssertEqual(shengjian4?.fullPortionCalories ?? 0, 322.0, accuracy: 15.0)

        // 2 片饼干 -> 2 * 10g = 20g -> (20/100) * 480 = 96 千卡
        let cookies2 = FoodCalorieEstimator.estimateMeal(fromHint: "2片饼干")
        XCTAssertNotNil(cookies2)
        XCTAssertEqual(cookies2?.fullPortionCalories ?? 0, 96.0, accuracy: 10.0)
    }

    /// 回归测试：显式输入克数/毫升数/两（如 200g米饭、二两面条、500ml牛奶）能够精准计算热量
    func testExplicitGramsAndWeightUnits() {
        // 200g 米饭 -> 200 * 1.30 = 260 千卡 (USDA f001 override)
        let rice200g = FoodCalorieEstimator.estimateMeal(fromHint: "200g米饭")
        XCTAssertNotNil(rice200g)
        XCTAssertEqual(rice200g?.fullPortionCalories ?? 0, 260.0, accuracy: 5.0)

        // 150克 鸡胸肉 -> 150 * 1.65 = 247.5 千卡
        let chicken150g = FoodCalorieEstimator.estimateMeal(fromHint: "150克鸡胸肉")
        XCTAssertNotNil(chicken150g)
        XCTAssertEqual(chicken150g?.fullPortionCalories ?? 0, 247.5, accuracy: 5.0)

        // 二两面条 -> 100g -> 100 * 1.38 = 138 千卡 (USDA f007 override)
        let noodles2liang = FoodCalorieEstimator.estimateMeal(fromHint: "二两面条")
        XCTAssertNotNil(noodles2liang)
        XCTAssertEqual(noodles2liang?.fullPortionCalories ?? 0, 138.0, accuracy: 5.0)

        // 500ml 纯牛奶 -> 500g -> 500 * 0.61 = 305 千卡 (USDA f052 override)
        let milk500ml = FoodCalorieEstimator.estimateMeal(fromHint: "500ml纯牛奶")
        XCTAssertNotNil(milk500ml)
        XCTAssertEqual(milk500ml?.fullPortionCalories ?? 0, 305.0, accuracy: 10.0)

        // 330ml 可乐 -> 330 * 0.42 = 138.6 千卡
        let cola330ml = FoodCalorieEstimator.estimateMeal(fromHint: "330ml可乐")
        XCTAssertNotNil(cola330ml)
        XCTAssertEqual(cola330ml?.fullPortionCalories ?? 0, 138.6, accuracy: 5.0)
    }

    /// 回归测试：复合数量（一个半、两碗半）及大于十的中文数字解析
    func testCompoundAndExtendedChineseNumbers() {
        // 一个半肉包 -> 207 * 1.5 = 310.5 千卡
        let bunOneAndHalf = FoodCalorieEstimator.estimateMeal(fromHint: "一个半肉包")
        XCTAssertNotNil(bunOneAndHalf)
        XCTAssertEqual(bunOneAndHalf?.fullPortionCalories ?? 0, 310.5, accuracy: 10.0)

        // 两碗半米饭 -> 195 * 2.5 = 487.5 千卡 (USDA f001 override)
        let riceTwoAndHalf = FoodCalorieEstimator.estimateMeal(fromHint: "两碗半米饭")
        XCTAssertNotNil(riceTwoAndHalf)
        XCTAssertEqual(riceTwoAndHalf?.fullPortionCalories ?? 0, 487.5, accuracy: 15.0)

        // 十二个水饺 -> 12 * 20g = 240g -> 576 千卡
        let dumplings12 = FoodCalorieEstimator.estimateMeal(fromHint: "十二个水饺")
        XCTAssertNotNil(dumplings12)
        XCTAssertEqual(dumplings12?.fullPortionCalories ?? 0, 576.0, accuracy: 25.0)

        // 十五个生煎 -> 15 * 35g = 525g -> (525/100) * 230 = 1207.5 千卡
        let shengjian15 = FoodCalorieEstimator.estimateMeal(fromHint: "十五个生煎")
        XCTAssertNotNil(shengjian15)
        XCTAssertEqual(shengjian15?.fullPortionCalories ?? 0, 1207.5, accuracy: 30.0)
    }

    /// 回归测试：无标点自然口语连贯输入多菜（如「两个包子一碗粥」「一个肉包一杯豆浆」）能无缝切分
    func testSpokenMultiDishPhrasesWithoutDelimiters() {
        let bunAndCongee = FoodCalorieEstimator.estimateMeal(fromHint: "两个包子一碗粥")
        XCTAssertNotNil(bunAndCongee)
        XCTAssertEqual(bunAndCongee?.dishes.count, 2)
        let dishNames = bunAndCongee?.dishes.map(\.food.name) ?? []
        XCTAssertTrue(dishNames.contains(where: { $0.contains("包子") }))
        XCTAssertTrue(dishNames.contains(where: { $0.contains("粥") }))

        let bunAndSoyMilk = FoodCalorieEstimator.estimateMeal(fromHint: "一个肉包一杯豆浆")
        XCTAssertNotNil(bunAndSoyMilk)
        XCTAssertEqual(bunAndSoyMilk?.dishes.count, 2)

        let eggAndCongee = FoodCalorieEstimator.estimateMeal(fromHint: "两个鸡蛋一碗小米粥")
        XCTAssertNotNil(eggAndCongee)
        XCTAssertEqual(eggAndCongee?.dishes.count, 2)

        let riceAndCola = FoodCalorieEstimator.estimateMeal(fromHint: "一份炒饭一瓶可乐")
        XCTAssertNotNil(riceAndCola)
        XCTAssertEqual(riceAndCola?.dishes.count, 2)
    }

    /// 回归测试：饮品糖度系数与温度前缀安全剥离
    func testSugarAndTemperatureModifiers() {
        // 半糖奶茶 -> 350 * 0.85 = 297.5 千卡
        let halfSugar = FoodCalorieEstimator.estimateMeal(fromHint: "一杯半糖奶茶")
        XCTAssertNotNil(halfSugar)
        XCTAssertEqual(halfSugar?.fullPortionCalories ?? 0, 297.5, accuracy: 10.0)

        // 大杯无糖奶茶 -> 350 * 1.8 * 0.65 = 409.5 千卡
        let largeZeroSugar = FoodCalorieEstimator.estimateMeal(fromHint: "大杯无糖奶茶")
        XCTAssertNotNil(largeZeroSugar)
        XCTAssertEqual(largeZeroSugar?.fullPortionCalories ?? 0, 409.5, accuracy: 15.0)

        // 冰美式 -> coffee
        let icedAmericano = FoodCatalog.item(matchingNameStrict: "冰美式")
        XCTAssertEqual(icedAmericano?.id, "coffee")

        // 热拿铁 -> latte
        let hotLatte = FoodCatalog.item(matchingNameStrict: "热拿铁")
        XCTAssertEqual(hotLatte?.id, "latte")

        // 去冰奶茶 -> milk_tea
        let destirredMilkTea = FoodCatalog.item(matchingNameStrict: "去冰奶茶")
        XCTAssertEqual(destirredMilkTea?.id, "milk_tea")

        // 热干面不能误剥离「热」而变成「干面」
        let reganmian = FoodCatalog.item(matchingNameStrict: "热干面")
        XCTAssertEqual(reganmian?.id, "cn_n019")
        XCTAssertTrue(reganmian?.name.contains("热干面") ?? false)

        // 热狗不能误剥离「热」
        let hotdog = FoodCatalog.item(matchingNameStrict: "热狗")
        XCTAssertEqual(hotdog?.id, "hotdog")

        // 冰淇淋不能误剥离「冰」
        let iceCream = FoodCatalog.item(matchingNameStrict: "冰淇淋")
        XCTAssertEqual(iceCream?.id, "ice_cream")
    }

    /// 回归测试：三大宏量营养素（蛋白质、脂肪、碳水化合物）自动汇总与简报
    func testMacronutrientCalculations() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "200g米饭加150克鸡胸肉")
        XCTAssertNotNil(meal)
        guard let m = meal else { return }

        // 米饭 200g: 碳水 ~51.8g, 蛋白 ~5.2g
        // 鸡胸肉 150g: 蛋白 ~46.5g, 脂肪 ~5.4g
        XCTAssertGreaterThan(m.totalProtein, 45.0)
        XCTAssertGreaterThan(m.totalCarbs, 45.0)
        XCTAssertGreaterThan(m.totalFat, 4.0)

        let summary = FoodCalorieEstimator.summary(for: m, includeMacros: true)
        XCTAssertTrue(summary.contains("碳水"))
        XCTAssertTrue(summary.contains("蛋白质"))
        XCTAssertTrue(summary.contains("脂肪"))
    }

    /// 回归测试：带骨食材（如排骨，可食率 72%）必须按可食净重计算热量，不能把骨头当成纯肉计算
    func testEdibleRatioCalculatesNetEdibleCaloriesForBoneInMeats() {
        let ribsFood = FoodCatalog.item(id: "braised_meat")! // 红烧肉/红烧排骨, edibleRatio = 0.72
        XCTAssertTrue(ribsFood.hasBoneOrShell)
        XCTAssertEqual(ribsFood.edibleRatio, 0.72, accuracy: 0.01)

        let dish = FoodDishEstimate(food: ribsFood, customGrams: 200.0)
        XCTAssertEqual(dish.currentGrams, 200.0)
        XCTAssertEqual(dish.edibleGrams, 144.0, accuracy: 0.1)

        // 200g 毛重，净肉 144g，按 245 kcal / 100g 计算，整份热量应约为 144 * 2.45 = 352.8 kcal
        // 而不是 200 * 2.45 = 490 kcal
        let expectedBaseCal = (144.0 / 100.0) * ribsFood.caloriesPer100g
        XCTAssertEqual(dish.fullPortionCalories, expectedBaseCal, accuracy: 1.0)
    }

    /// 回归测试：烹饪方式（如油炸、重油）只增加油脂/热量，严格守恒蛋白质与碳水
    func testMacronutrientConservationWhenCookingMethodChanges() {
        let chicken = FoodCatalog.item(id: "chicken_breast")! // 鸡胸肉
        let steamedDish = FoodDishEstimate(food: chicken, cookingMethod: .steamedOrBoiled, customGrams: 100.0)
        let friedDish = FoodDishEstimate(food: chicken, cookingMethod: .deepFriedOrBreaded, oilSauceLevel: .heavy, customGrams: 100.0)

        // 油炸和重油大幅增加热量与脂肪
        XCTAssertGreaterThan(friedDish.fullPortionCalories, steamedDish.fullPortionCalories * 1.3)
        XCTAssertGreaterThan(friedDish.fat, steamedDish.fat * 2.0)

        // 但基准鸡胸肉的蛋白质绝不能因为加了油或油炸而凭空增加！
        XCTAssertEqual(friedDish.protein, steamedDish.protein, accuracy: 0.5, "油炸加烹调油不得虚报暴增蛋白质")
    }

    /// 回归测试：文本手输显式克数（如「米饭 250克」）必须被 FoodDishEstimate 完整保留
    func testCustomGramsPropagationFromHintText() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "米饭 250克")
        XCTAssertNotNil(meal)
        guard let m = meal, let dish = m.dishes.first else { return }

        XCTAssertEqual(dish.currentGrams, 250.0, accuracy: 0.1, "手输克数 250g 必须完整保留，不能回退到默认 150g")
        XCTAssertEqual(dish.customGrams, 250.0)
    }

    /// 回归测试：多菜组合的置信区间使用高斯独立误差均方根合成，避免简单线性累加导致区间虚高
    func testGaussianErrorPropagationInCalorieRange() {
        let rice = FoodCatalog.item(id: "rice")!
        let beef = FoodCatalog.item(id: "beef")!
        let veg = FoodCatalog.item(id: "vegetable_dish")!
        let soup = FoodCatalog.item(id: "soup")!

        let dish1 = FoodDishEstimate(food: rice, customGrams: 150)
        let dish2 = FoodDishEstimate(food: beef, customGrams: 150)
        let dish3 = FoodDishEstimate(food: veg, customGrams: 150)
        let dish4 = FoodDishEstimate(food: soup, customGrams: 200)

        let meal = FoodCalorieEstimate(dishes: [dish1, dish2, dish3, dish4])
        let range = meal.calorieRange

        let linearDelta = (dish1.calorieRange.high - dish1.consumedCalories)
            + (dish2.calorieRange.high - dish2.consumedCalories)
            + (dish3.calorieRange.high - dish3.consumedCalories)
            + (dish4.calorieRange.high - dish4.consumedCalories)

        let actualDelta = range.high - meal.consumedCalories

        // 独立误差合成的标准差必定严格小于直接线性求和 (sqrt(sum(a_i^2)) < sum(a_i))
        XCTAssertLessThan(actualDelta, linearDelta)
        XCTAssertGreaterThan(range.low, 0)
        XCTAssertGreaterThan(range.high, range.low)
    }

    /// 回归测试：生熟称重状态换算（生米膨胀 ~2.3，生肉熟化脱水 ~0.75）
    func testPreparationStateRawToCookedConversion() {
        let rice = FoodCatalog.item(id: "rice")!
        let cookedDish = FoodDishEstimate(food: rice, preparationState: .cooked, customGrams: 100.0)
        let rawDish = FoodDishEstimate(food: rice, preparationState: .raw, customGrams: 100.0)

        // 100g 生大米蒸熟后为 ~230g 熟米饭，热量约为熟米饭 100g 的 2.3 倍
        XCTAssertEqual(rawDish.fullPortionCalories, cookedDish.fullPortionCalories * 2.3, accuracy: 5.0)
    }

    // MARK: - 回归（CORE-09）：同一食物重复出现要合并份量，不能丢菜

    func testDuplicateDishMergesQuantityInsteadOfDropping() {
        guard let one = FoodCalorieEstimator.estimateMeal(fromHint: "一个包子"),
              let two = FoodCalorieEstimator.estimateMeal(fromHint: "两个包子"),
              let twoPlusOne = FoodCalorieEstimator.estimateMeal(fromHint: "两个包子一个肉包") else {
            return XCTFail("基础用例解析失败")
        }
        // 「肉包」是包子的同一食物条目：应合并成一道菜、热量等于 3 份
        XCTAssertEqual(twoPlusOne.dishes.count, 1)
        XCTAssertEqual(twoPlusOne.dishes.first?.food.id, two.dishes.first?.food.id)
        XCTAssertEqual(twoPlusOne.consumedCalories,
                       two.consumedCalories + one.consumedCalories,
                       accuracy: 1.0)
        XCTAssertTrue(twoPlusOne.unmatchedHints.isEmpty)
    }

    func testMixedMealKeepsAllDistinctDishes() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "两个包子一碗粥一个肉包一杯豆浆两个鸡蛋")
        guard let meal else { return XCTFail("多菜解析失败") }
        // 包子（两份合并）+ 粥 + 豆浆 + 鸡蛋
        XCTAssertEqual(meal.dishes.count, 4)
        let bun = meal.dishes.first { $0.food.id.hasPrefix("steamed_bun") || $0.food.id == "steamed_bun" }
        XCTAssertNotNil(bun)
        if let bun {
            let singleBun = FoodCalorieEstimator.estimateMeal(fromHint: "一个包子")
            // 「两个包子 + 一个肉包」= 同一食物 3 份，热量应为单份的 3 倍
            XCTAssertEqual(bun.fullPortionCalories,
                           (singleBun?.fullPortionCalories ?? 0) * 3,
                           accuracy: 3.0,
                           "重复出现的同类菜应合并份量，而不是被丢弃")
        }
    }

    func testUnmatchedFragmentsAreReported() {
        let meal = FoodCalorieEstimator.estimateMeal(fromHint: "一个包子一盘恐龙肉")
        guard let meal else { return XCTFail("解析失败") }
        XCTAssertFalse(meal.unmatchedHints.isEmpty, "没认出来的片段应出现在 unmatchedHints 里")
        XCTAssertTrue(meal.unmatchedHints.contains { $0.contains("恐龙肉") },
                      "实际 hints：\(meal.unmatchedHints)")
    }
}
