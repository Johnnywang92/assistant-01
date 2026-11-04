import AssistantCore
import Foundation
import UIKit

/// 食物照片热量估算的编排服务。
///
/// ## 降级链（每一步都可能失败，必须能优雅退化）
/// 1. **Vision 通用分类** → 具体食物候选（披萨/汉堡准，沙拉这类可能只给泛类）。
/// 2. **端侧 LLM 细化** → 结合候选推断更准的菜名、份量与热量。
///    - 端侧模型是 1.5B 小模型，且**看不到照片**，只能基于候选做推断，
///      所以它的输出**必须**经过 `FoodLLMOutputParser` 的严格校验才采信。
/// 3. **手动选择** → 候选为空或置信度过低时，引导用户从食物库直接选。
///
/// ## 诚实性约束
/// - 识别不出就**说识别不出**，不编造菜名与热量。
/// - LLM 解析失败时保留 Vision 候选，而不是丢弃全部结果。
/// - 份量是热量估算的最大误差源，因此 UI 必须提供手动调整（含吃剩比例）。
@MainActor
final class FoodEstimationService: ObservableObject {

    static let shared = FoodEstimationService()

    /// 估算结果。
    @Published private(set) var estimate: FoodCalorieEstimate?
    /// 候选列表（供用户改选）。
    @Published private(set) var candidates: [FoodCandidate] = []
    /// 估算状态。
    @Published private(set) var isEstimating = false
    /// 失败或降级的可读说明。
    @Published private(set) var statusMessage: String?
    /// 是否需要用户手动选择（识别不可靠）。
    @Published private(set) var needsManualSelection = false

    private let vision = FoodVisionService.shared

    private init() {}

    /// 从历史记录聚合用户常吃偏好与近期饮食先验
    static func buildHistoryPrior(from records: [FoodIntakeRecord]) -> FoodHistoryPrior {
        var counts: [String: Int] = [:]
        var recentIDs = Set<String>()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now

        for record in records {
            if let ids = record.foodID?.components(separatedBy: "+") {
                for rawID in ids {
                    let clean = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    counts[clean, default: 0] += 1
                    if record.date >= sevenDaysAgo {
                        recentIDs.insert(clean)
                    }
                }
            }
        }
        return FoodHistoryPrior(frequentItemCounts: counts, recentItemIDs: recentIDs)
    }

    /// 对一张食物照片做完整估算。
    ///
    /// - Parameters:
    ///   - image: 食物照片。
    ///   - userHint: 用户补充描述（如「这是麻辣香锅」）。可空。
    ///   - mealDate: 用餐时间（用于时段先验加权）。默认当前时间。
    ///   - history: 用户饮食偏好与常吃菜品先验。
    /// - Returns: 估算结果。识别不出来时返回 nil，且 `needsManualSelection` 为 true。
    @discardableResult
    func estimateCalories(for image: UIImage,
                          userHint: String? = nil,
                          mealDate: Date = .now,
                          history: FoodHistoryPrior? = nil) async -> FoodCalorieEstimate? {
        isEstimating = true
        statusMessage = nil
        needsManualSelection = false
        defer { isEstimating = false }

        // 第一步：Vision 全图 + 多区域分区识别（支持托盘/桌面多菜组合 + 时段先验与用户偏好重排序）
        let visionCandidates = await vision.recognize(in: image, mealDate: mealDate, history: history)
        candidates = visionCandidates
        let trimmedHint = userHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let multiDishBase = FoodCalorieEstimator.estimateMeal(
            from: visionCandidates,
            detectedDishes: vision.detectedMealDishes
        )

        // 若用户填写了补充描述（如「米饭、辣椒炒肉、凉拌海带丝」或「红烧肉」），优先结合描述构建或合并到整餐中
        if !trimmedHint.isEmpty,
           let hintedMeal = FoodCalorieEstimator.estimateMeal(fromHint: trimmedHint, confidence: 0.88) {
            if let base = multiDishBase, hintedMeal.dishes.count == 1, let singleHintDish = hintedMeal.dishes.first {
                // 如果照片已识别出米饭等主食，用户补充了具体菜名（如「辣椒炒肉」），将用户补充菜品并入本餐（若本餐已有泛类炒菜则替换）
                var mergedDishes = base.dishes.filter { dish in
                    if !singleHintDish.food.isStaple && dish.food.id == "stir_fry_meat" && singleHintDish.food.id != "stir_fry_meat" {
                        return false
                    }
                    return dish.food.id != singleHintDish.food.id
                }
                mergedDishes.append(singleHintDish)
                let combined = FoodCalorieEstimate(dishes: mergedDishes, portion: base.portion)
                estimate = combined
                statusMessage = "已结合照片与您的描述「\(combined.displayName)」汇总整餐热量，可在下方单独或整体调整百分比。"
                return combined
            } else {
                estimate = hintedMeal
                statusMessage = "已根据您的描述「\(hintedMeal.displayName)」估算，可在下方调整份量与吃剩比例。"
                return hintedMeal
            }
        }

        // 第二步：若多区域识别已发现多道菜（如「米饭 + 辣椒炒肉/家常小炒 + 凉拌海带丝/凉菜」），
        // 直接保留完整多菜组合并汇总全部菜品热量，不让单菜 LLM 输出冲掉其余配菜！
        if let base = multiDishBase, base.dishes.count > 1 {
            estimate = base
            statusMessage = "已识别到 \(base.dishes.count) 道菜品（\(base.displayName)）并汇总热量，可按菜品或整餐调整吃剩百分比。"
            return base
        }

        // 第三步：单菜或补充说明场景下，交给端侧 LLM（如 Qwen3）细化
        if !visionCandidates.isEmpty || !trimmedHint.isEmpty {
            if let refined = await refineWithLLM(candidates: visionCandidates, userHint: trimmedHint) {
                estimate = refined
                let modelLabel = LLMModelManager.shared.selectedPreset.shortName
                statusMessage = "已结合「\(refined.displayName)」与 \(modelLabel) 估算，可在下方调整份量与吃剩比例。"
                return refined
            }
        }

        // 第四步：退到 Vision 整餐/最佳候选
        if let best = multiDishBase ?? FoodCalorieEstimator.estimate(from: visionCandidates) {
            estimate = best
            if best.confidenceLevel == .low {
                needsManualSelection = true
                statusMessage = "照片识别不太确定，建议手动选择或添加菜品。"
            } else {
                statusMessage = "已根据照片估算，可在下方添加配菜或调整吃剩比例。"
            }
            return best
        }

        // 第五步：彻底认不出
        estimate = nil
        needsManualSelection = true
        statusMessage = "没能从照片认出具体食物。请手动选择，或补充一句描述（例如「米饭、辣椒炒肉、海带丝」）再试。"
        return nil
    }

    /// 无照片时，直接根据用户手输或语音输入的食物名称估算整餐热量。
    @discardableResult
    func estimateCalories(fromText text: String, mealDate: Date = .now) async -> FoodCalorieEstimate? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        isEstimating = true
        statusMessage = nil
        needsManualSelection = false
        candidates = []
        defer { isEstimating = false }

        // 1. 本地规则与食物库匹配（支持多菜「米饭、辣椒炒肉」拆解）
        if let hinted = FoodCalorieEstimator.estimateMeal(fromHint: clean, confidence: 0.95) {
            estimate = hinted
            statusMessage = "已解析「\(hinted.displayName)」，可在下方调整份量或吃剩比例。"
            return hinted
        }

        // 2. 词库模糊搜索
        let matched = FoodCatalog.items(matchingName: clean)
        if let first = matched.first {
            let est = FoodCalorieEstimate(food: first, portion: .regular, confidence: 0.85)
            estimate = est
            statusMessage = "已匹配到食物「\(first.name)」。"
            return est
        }

        // 3. 端侧大模型推断
        let systemInstruction = """
        你是一个食物热量估算助手。根据用户输入的菜名或食物描述，
        判断是哪一种常见食物，并估算一份的标准热量（千卡）。
        只输出 JSON，格式为：{"food":"常见中文菜名","calories":数字,"portion":"标准份"}
        不要输出任何解释文字。
        """
        if let output = await LLMInferenceService.shared.generateCustomTask(
            systemInstruction: systemInstruction,
            userContent: "用户吃了：\(clean)。请估算热量。",
            maxNewTokens: 64
        ), let parsed = FoodLLMOutputParser.parse(output),
           let food = FoodCatalog.item(matchingNameStrict: parsed.foodName) ?? FoodCatalog.items(matchingName: parsed.foodName).first {
            let portion = parsed.portion ?? .regular
            let baseline = food.standardServingCalories
            let cal = parsed.calories > 0 ? Self.reconcile(llmCalories: parsed.calories, baseline: baseline) : baseline
            let est = FoodCalorieEstimate(food: food, portion: portion, confidence: 0.8)
                .withOverriddenCalories(cal)
            estimate = est
            statusMessage = "已结合 AI 解析出「\(food.name)」。"
            return est
        }

        // 4. 无法自动解析，提示手动选择
        needsManualSelection = true
        statusMessage = "未能在食物库中直接找到「\(clean)」，请点击「从食物库选择」挑选相近菜品。"
        return nil
    }

    /// 用端侧 LLM 细化候选。
    ///
    /// 只在「有候选」或「用户提供了补充描述」时调用：不让小模型在毫无信息时凭空猜。
    private func refineWithLLM(candidates: [FoodCandidate],
                               userHint: String?) async -> FoodCalorieEstimate? {
        let hintText = userHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = vision.promptCandidatesSummary()
        guard summary != nil || !hintText.isEmpty else { return nil }

        let visionContext = summary.map { "图像识别给出的可能食物是：\($0)。" } ?? "图像识别未能确定具体菜品。"
        let systemInstruction = """
        你是一个食物热量估算助手。用户上传了一张食物照片，\(visionContext)
        请判断最可能是哪一种食物，并估算一份的标准热量（千卡）。
        只输出 JSON，格式为：{"food":"菜名","calories":数字,"portion":"小份或标准份或大份"}
        要求：food 必须是常见食物的中文名；calories 是**整份**的热量；不要输出任何解释文字。
        """
        let userContent = hintText.isEmpty
            ? "请估算这份食物的热量。"
            : "用户补充说明：\(hintText)。请估算这份食物的热量。"

        guard let output = await LLMInferenceService.shared.generateCustomTask(
            systemInstruction: systemInstruction,
            userContent: userContent,
            maxNewTokens: 96
        ) else { return nil }

        guard let parsed = FoodLLMOutputParser.parse(output) else { return nil }

        // 严格校验：菜名必须在食物库中精确匹配，否则不采信
        guard let food = FoodCatalog.item(matchingNameStrict: parsed.foodName) else { return nil }

        // LLM 给的热量与食物库基准差异过大时，以食物库为准——
        // 小模型容易给出离谱数字（如给米饭估 900 千卡）。
        let baseline = food.standardServingCalories
        guard parsed.calories > 0 else { return nil }
        let calories = Self.reconcile(llmCalories: parsed.calories, baseline: baseline)

        // 份量：LLM 给了就用，否则按基准份
        let portion = parsed.portion ?? .regular
        let scaled = FoodCalorieEstimate(
            food: food,
            portion: portion,
            // LLM 的自评置信度不可全信（1.5B 模型常给 0.9），取与 Vision 候选置信度的较小值
            confidence: min(parsed.confidence ?? 0.5, Self.bestCandidateConfidence(for: food.id, in: candidates)),
            consumedRatio: 1.0
        )
        // 用调和后的热量覆盖（保留份量与置信度）
        return FoodCalorieEstimate(
            food: food,
            portion: portion,
            confidence: scaled.confidence,
            consumedRatio: 1.0
        ).withOverriddenCalories(calories)
    }

    /// 把 LLM 给的热量与食物库基准调和。
    ///
    /// 差异在 ±60% 内视为合理（份量/做法差异），采信 LLM 值；
    /// 超出则回退到食物库基准——宁可给个保守的参考值，
    /// 也不要把离谱数字写进用户的健康记录。
    private static func reconcile(llmCalories: Double, baseline: Double) -> Double {
        guard baseline > 0 else { return llmCalories }
        let ratio = llmCalories / baseline
        if ratio >= 0.4 && ratio <= 1.6 { return llmCalories }
        return baseline
    }

    private static func bestCandidateConfidence(for foodId: String, in candidates: [FoodCandidate]) -> Double {
        candidates.first { $0.food.id == foodId }?.confidence ?? 0.5
    }

    /// 用户手动选择食物后更新估算（替换整餐为单个食物）。
    func selectManually(food: FoodItem, portion: FoodPortion = .regular, consumedRatio: Double = 1.0) {
        estimate = FoodCalorieEstimate(food: food,
                                       portion: portion,
                                       confidence: 1.0,
                                       consumedRatio: consumedRatio)
        needsManualSelection = false
        statusMessage = "已手动选择「\(food.name)」。"
    }

    /// 向本餐追加一道菜品（例如在已识别出米饭的基础上，手动或从候选中点击加入配菜，热量自动累加）。
    func addDish(food: FoodItem, portion: FoodPortion = .regular, consumedRatio: Double = 1.0) {
        let newDish = FoodDishEstimate(
            food: food,
            portion: portion,
            confidence: 0.9,
            consumedRatio: consumedRatio
        )
        if let current = estimate {
            let updated = current.addingDish(newDish)
            estimate = updated
            statusMessage = "已将「\(food.name)」加入本餐，当前共 \(updated.dishes.count) 道菜品（合计 \(Int(updated.consumedCalories.rounded())) 千卡）。"
        } else {
            estimate = FoodCalorieEstimate(dishes: [newDish], portion: portion)
            statusMessage = "已添加「\(food.name)」。"
        }
        needsManualSelection = false
    }

    /// 从本餐移除某一道菜品。
    func removeDish(dishID: String) {
        guard let current = estimate, current.dishes.count > 1 else { return }
        let updated = current.removingDish(dishID: dishID)
        estimate = updated
        statusMessage = "已更新本餐菜品（共 \(updated.dishes.count) 道，合计 \(Int(updated.consumedCalories.rounded())) 千卡）。"
    }

    /// 用户修改整餐的自定义展示名称（如「工作日减脂午餐」或覆盖自动识别出的菜名拼装）。
    func updateMealDisplayName(_ name: String) {
        guard let current = estimate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        estimate = current.withCustomDisplayName(trimmed.isEmpty ? nil : trimmed)
        statusMessage = trimmed.isEmpty ? "已恢复默认菜品名称。" : "已更新本餐名称为「\(trimmed)」。"
    }

    /// 替换某一道识别出的菜品（换菜，从食物库选其他菜或自定义食物）。
    func replaceDish(dishID: String, with food: FoodItem) {
        guard let current = estimate else { return }
        let updated = current.replacingDish(dishID: dishID, with: food)
        estimate = updated
        statusMessage = "已将该道菜替换为「\(food.name)」（整餐合计 \(Int(updated.consumedCalories.rounded())) 千卡）。"
    }

    /// 修改某一道菜的具体信息（直接修改菜名、手动输入热量千卡数值）。
    func updateDishDetails(dishID: String, name: String? = nil, calories: Double? = nil) {
        guard let current = estimate else { return }
        let updated = current.updatingDish(dishID: dishID, name: name, calories: calories)
        estimate = updated
        statusMessage = "已修改菜品明细与热量数值（整餐合计 \(Int(updated.consumedCalories.rounded())) 千卡）。"
    }

    /// 单独调整本餐中某一道菜吃掉的百分比（例如米饭吃了一半 50%，菜吃完了 100%）。
    func updateDishConsumedRatio(dishID: String, ratio: Double) {
        guard let current = estimate else { return }
        estimate = current.updatingDishConsumedRatio(dishID: dishID, ratio: ratio)
    }

    /// 单独调整本餐中某一道菜的份量（小份/标准份/大份）。
    func updateDishPortion(dishID: String, portion: FoodPortion) {
        guard let current = estimate else { return }
        estimate = current.updatingDishPortion(dishID: dishID, portion: portion)
    }

    /// 单独调整本餐中某一道菜的具体克数。
    func updateDishGrams(dishID: String, grams: Double) {
        guard let current = estimate else { return }
        estimate = current.updatingDishGrams(dishID: dishID, grams: grams)
    }

    /// 单独调整本餐中某一道菜的烹饪方式。
    func updateDishCookingMethod(dishID: String, method: FoodCookingMethod) {
        guard let current = estimate else { return }
        estimate = current.updatingDishCookingMethod(dishID: dishID, method: method)
    }

    /// 单独调整本餐中某一道菜的用油/酱汁档位。
    func updateDishOilSauceLevel(dishID: String, level: FoodOilSauceLevel) {
        guard let current = estimate else { return }
        estimate = current.updatingDishOilSauceLevel(dishID: dishID, level: level)
    }

    /// 单独调整本餐中某一道菜的称重状态（熟重/生重）。
    func updateDishPreparationState(dishID: String, state: FoodPreparationState) {
        guard let current = estimate else { return }
        estimate = current.updatingDishPreparationState(dishID: dishID, state: state)
    }

    /// 综合配置某一道菜的明细（名称、克数、烹饪方式、用油量、称量状态、手动热量）。
    func updateDishConfig(
        dishID: String,
        name: String? = nil,
        grams: Double? = nil,
        cookingMethod: FoodCookingMethod? = nil,
        oilSauceLevel: FoodOilSauceLevel? = nil,
        preparationState: FoodPreparationState? = nil,
        calories: Double? = nil
    ) {
        guard let current = estimate else { return }
        let updated = current.updatingDishConfig(
            dishID: dishID,
            name: name,
            grams: grams,
            cookingMethod: cookingMethod,
            oilSauceLevel: oilSauceLevel,
            preparationState: preparationState,
            calories: calories
        )
        estimate = updated
        statusMessage = "已校准「\(name ?? "菜品")」的估算参数（整餐合计 \(Int(updated.consumedCalories.rounded())) 千卡）。"
    }

    /// 用户调整整餐份量。
    func updatePortion(_ portion: FoodPortion) {
        guard let current = estimate else { return }
        estimate = current.withPortion(portion)
    }

    /// 用户调整整餐吃剩比例（核心需求：有时候没吃完）。
    func updateConsumedRatio(_ ratio: Double) {
        guard let current = estimate else { return }
        estimate = current.withConsumedRatio(ratio)
    }

    /// 用户手动微调「整份热量」基准（同时按当前吃剩比例实时重算实际摄入热量）。
    func updateFullPortionCalories(_ calories: Double) {
        guard let current = estimate, calories > 0, calories <= 5000 else { return }
        estimate = current.withOverriddenCalories(calories)
    }

    /// 保存记录后清空当前估算草稿。
    func clearDraft() {
        estimate = nil
        candidates = []
        statusMessage = nil
        needsManualSelection = false
    }

    // MARK: - 宴席 / 聚餐多菜品场景快捷估算

    /// 根据聚餐/宴席场景、个人进食程度与席间饮品，构建符合成人单人真实摄入结构的整餐估算
    static func buildBanquetEstimate(
        scene: FoodBanquetScene,
        appetite: FoodBanquetAppetiteLevel,
        drinkAddon: FoodBanquetDrinkAddon
    ) -> FoodCalorieEstimate {
        let scale = appetite.gramsMultiplier
        var dishes: [FoodDishEstimate] = []

        for spec in scene.dishSpecs {
            guard let baseItem = FoodCatalog.item(id: spec.foodID) else { continue }
            let item = spec.customName.map { baseItem.withCustom(name: $0) } ?? baseItem
            let grams = max(20, (spec.baseGrams * scale).rounded())
            dishes.append(
                FoodDishEstimate(
                    id: "\(spec.foodID)_\(dishes.count)",
                    food: item,
                    portion: .regular,
                    confidence: 0.9,
                    consumedRatio: 1.0,
                    cookingMethod: spec.cookingMethod,
                    oilSauceLevel: spec.oilLevel,
                    customGrams: grams
                )
            )
        }

        if let drinkSpec = drinkAddon.dishSpec,
           let drinkItem = FoodCatalog.item(id: drinkSpec.foodID) {
            let item = drinkSpec.customName.map { drinkItem.withCustom(name: $0) } ?? drinkItem
            dishes.append(
                FoodDishEstimate(
                    id: "\(drinkSpec.foodID)_drink",
                    food: item,
                    portion: .regular,
                    confidence: 0.9,
                    consumedRatio: 1.0,
                    customGrams: drinkSpec.baseGrams
                )
            )
        }

        let mealTitle = "\(scene.title)（\(appetite.shortTitle)）"
        return FoodCalorieEstimate(
            dishes: dishes,
            portion: .regular,
            customDisplayName: mealTitle
        )
    }

    /// 应用宴席/聚餐预设到当前估算草稿
    func applyBanquetPreset(
        scene: FoodBanquetScene,
        appetite: FoodBanquetAppetiteLevel,
        drinkAddon: FoodBanquetDrinkAddon
    ) {
        let built = Self.buildBanquetEstimate(scene: scene, appetite: appetite, drinkAddon: drinkAddon)
        estimate = built
        needsManualSelection = false
        statusMessage = "已按「\(scene.title) · \(appetite.title)」折算单人进食明细（共 \(built.dishes.count) 类代表菜品，合计约 \(Int(built.consumedCalories.rounded())) 千卡），可继续增删微调或直接保存。"
    }
}

// MARK: - 宴席 / 聚餐场景模型

enum FoodBanquetScene: String, CaseIterable, Identifiable {
    case chineseBanquet = "中式酒席/桌餐"
    case hotpot = "火锅聚餐"
    case barbecue = "烤肉/烧烤局"
    case buffet = "自助大餐"

    var id: String { rawValue }
    var title: String { rawValue }

    var subtitle: String {
        switch self {
        case .chineseBanquet:
            return "喜宴/家宴/商务圆桌，10~16 道菜每样夹几筷"
        case .hotpot:
            return "涮肥牛羊肉、虾滑毛肚、豆制品与时蔬菌菇"
        case .barbecue:
            return "炭火烤串、韩式烤五花/牛肉、烤鸡翅与素菜"
        case .buffet:
            return "海鲜刺身、牛排铁板、热菜沙拉与餐后甜点"
        }
    }

    var icon: String {
        switch self {
        case .chineseBanquet: return "person.3.fill"
        case .hotpot: return "flame.fill"
        case .barbecue: return "sparkles"
        case .buffet: return "fork.knife.circle.fill"
        }
    }

    struct DishSpec {
        let foodID: String
        let customName: String?
        let baseGrams: Double
        let cookingMethod: FoodCookingMethod?
        let oilLevel: FoodOilSauceLevel
    }

    /// 单人正常聚餐（1.0x）下各代表性菜类的实际入肚克数（已按圆桌多人分食折算为个人进食量）
    var dishSpecs: [DishSpec] {
        switch self {
        case .chineseBanquet:
            return [
                DishSpec(foodID: "braised_meat", customName: "席间红烧硬菜(肘子/红烧肉/排骨)", baseGrams: 75, cookingMethod: .braisedOrSauced, oilLevel: .heavy),
                DishSpec(foodID: "roast_duck", customName: "冷盘卤味与烧腊拼盘", baseGrams: 65, cookingMethod: .panFriedOrGrilled, oilLevel: .standard),
                DishSpec(foodID: "fish", customName: "清蒸鱼/海鲜主菜", baseGrams: 90, cookingMethod: .steamedOrBoiled, oilLevel: .standard),
                DishSpec(foodID: "shrimp", customName: "白灼虾/贝类河鲜", baseGrams: 75, cookingMethod: .steamedOrBoiled, oilLevel: .low),
                DishSpec(foodID: "stir_fry_meat", customName: "热炒荤素小炒(2~3道合算)", baseGrams: 110, cookingMethod: .stirFried, oilLevel: .standard),
                DishSpec(foodID: "vegetable_dish", customName: "宴席清炒时蔬与菌菇", baseGrams: 120, cookingMethod: .stirFried, oilLevel: .standard),
                DishSpec(foodID: "pork_ribs_soup", customName: "席间老火炖汤/羹", baseGrams: 180, cookingMethod: .soupOrStew, oilLevel: .standard),
                DishSpec(foodID: "rice", customName: "席间主食点心(小半份)", baseGrams: 80, cookingMethod: .steamedOrBoiled, oilLevel: .low)
            ]
        case .hotpot:
            return [
                DishSpec(foodID: "beef", customName: "涮肥牛/肥羊卷", baseGrams: 140, cookingMethod: .soupOrStew, oilLevel: .heavy),
                DishSpec(foodID: "shrimp", customName: "虾滑/毛肚/海鲜涮品", baseGrams: 100, cookingMethod: .soupOrStew, oilLevel: .standard),
                DishSpec(foodID: "pork", customName: "午餐肉/丸滑荤菜", baseGrams: 85, cookingMethod: .soupOrStew, oilLevel: .heavy),
                DishSpec(foodID: "tofu", customName: "冻豆腐/响铃卷/豆制品", baseGrams: 90, cookingMethod: .soupOrStew, oilLevel: .heavy),
                DishSpec(foodID: "vegetable_dish", customName: "涮绿叶菜与菌菇拼盘", baseGrams: 160, cookingMethod: .soupOrStew, oilLevel: .standard),
                DishSpec(foodID: "noodles", customName: "火锅面/宽粉/蘸料折算", baseGrams: 90, cookingMethod: .braisedOrSauced, oilLevel: .heavy)
            ]
        case .barbecue:
            return [
                DishSpec(foodID: "barbecue", customName: "碳火羊肉串/猪肉串", baseGrams: 140, cookingMethod: .panFriedOrGrilled, oilLevel: .heavy),
                DishSpec(foodID: "beef", customName: "烤牛五花/牛肉粒", baseGrams: 110, cookingMethod: .panFriedOrGrilled, oilLevel: .heavy),
                DishSpec(foodID: "chicken_breast", customName: "烤鸡翅/掌中宝", baseGrams: 90, cookingMethod: .panFriedOrGrilled, oilLevel: .standard),
                DishSpec(foodID: "vegetable_dish", customName: "烤韭菜/金针菇/茄子", baseGrams: 130, cookingMethod: .panFriedOrGrilled, oilLevel: .heavy),
                DishSpec(foodID: "bread", customName: "烤馒头片/主食小吃", baseGrams: 55, cookingMethod: .panFriedOrGrilled, oilLevel: .standard)
            ]
        case .buffet:
            return [
                DishSpec(foodID: "steak", customName: "铁板牛排/烤肉档口", baseGrams: 130, cookingMethod: .panFriedOrGrilled, oilLevel: .standard),
                DishSpec(foodID: "sushi", customName: "三文鱼刺身与寿司", baseGrams: 120, cookingMethod: .readyToEat, oilLevel: .low),
                DishSpec(foodID: "shrimp", customName: "海鲜大虾/蟹腿贝类", baseGrams: 140, cookingMethod: .steamedOrBoiled, oilLevel: .low),
                DishSpec(foodID: "fried_chicken", customName: "中西热菜与炸物小食", baseGrams: 90, cookingMethod: .deepFriedOrBreaded, oilLevel: .standard),
                DishSpec(foodID: "cake", customName: "自助甜品小蛋糕/冰淇淋", baseGrams: 85, cookingMethod: .readyToEat, oilLevel: .standard),
                DishSpec(foodID: "fruit", customName: "餐后鲜切水果", baseGrams: 130, cookingMethod: .readyToEat, oilLevel: .low)
            ]
        }
    }
}

enum FoodBanquetAppetiteLevel: String, CaseIterable, Identifiable {
    case light = "浅尝克制"
    case normal = "正常聚餐"
    case feast = "丰盛畅吃"

    var id: String { rawValue }
    var title: String { rawValue }

    var shortTitle: String {
        switch self {
        case .light: return "七分饱"
        case .normal: return "正常饱"
        case .feast: return "畅吃饱"
        }
    }

    var subtitle: String {
        switch self {
        case .light: return "每道菜尝一两筷、少吃肥腻与主食"
        case .normal: return "荤素搭配正常夹菜、吃饱为止"
        case .feast: return "硬菜主食甜点尽情享用、十成饱"
        }
    }

    var gramsMultiplier: Double {
        switch self {
        case .light: return 0.65
        case .normal: return 1.00
        case .feast: return 1.38
        }
    }
}

enum FoodBanquetDrinkAddon: String, CaseIterable, Identifiable {
    case none = "清茶/白水"
    case sweetDrink = "饮料/果汁"
    case alcohol = "小酌酒水"

    var id: String { rawValue }
    var title: String { rawValue }

    var subtitle: String {
        switch self {
        case .none: return "0 千卡"
        case .sweetDrink: return "约 1 杯 (250ml)"
        case .alcohol: return "啤酒/红酒约 300ml"
        }
    }

    var dishSpec: FoodBanquetScene.DishSpec? {
        switch self {
        case .none:
            return nil
        case .sweetDrink:
            return FoodBanquetScene.DishSpec(
                foodID: "juice",
                customName: "席间含糖饮料/果汁",
                baseGrams: 250,
                cookingMethod: .readyToEat,
                oilLevel: .standard
            )
        case .alcohol:
            return FoodBanquetScene.DishSpec(
                foodID: "alcohol",
                customName: "席间酒水小酌",
                baseGrams: 300,
                cookingMethod: .readyToEat,
                oilLevel: .standard
            )
        }
    }
}
