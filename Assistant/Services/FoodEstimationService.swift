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

    /// 对一张食物照片做完整估算。
    ///
    /// - Parameters:
    ///   - image: 食物照片。
    ///   - userHint: 用户补充描述（如「这是麻辣香锅」）。可空。
    /// - Returns: 估算结果。识别不出来时返回 nil，且 `needsManualSelection` 为 true。
    @discardableResult
    func estimateCalories(for image: UIImage, userHint: String? = nil) async -> FoodCalorieEstimate? {
        isEstimating = true
        statusMessage = nil
        needsManualSelection = false
        defer { isEstimating = false }

        // 第一步：Vision 全图 + 多区域分区识别（支持托盘/桌面多菜组合）
        let visionCandidates = await vision.recognize(in: image)
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
        let multiplier = portion.multiplier
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
}
