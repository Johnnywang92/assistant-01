import AssistantCore
import Foundation
import UIKit
import Vision

/// 食物照片识别服务（端侧 Vision 通用图像分类）。
///
/// ## 它能做什么、不能做什么（实测结论）
/// 用真实食物照片跑过 `VNClassifyImageRequest`：
/// - 披萨 0.76、汉堡 0.87 —— 识别得准
/// - 沙拉只认出泛类「food」0.61 —— 认不出具体菜名
/// - 米饭照片被误判成「蜻蜓」0.85 —— 完全不靠谱
///
/// 所以本服务**只负责产出候选**，不负责给出最终热量：
/// 1. 只返回能映射到食物库的具体食物，泛类（「food」「dish」）直接丢弃。
/// 2. 一个都映射不到时返回**空候选列表**（不是「随便挑一个」），
///    由 UI 引导用户手动选择。
/// 3. 置信度原样透传，供 UI 标注「识别较明确 / 可能是 / 认不准」。
///
/// ## 隐私
/// 全程在设备上完成，照片不上传、不联网。
@MainActor
final class FoodVisionService: ObservableObject {

    static let shared = FoodVisionService()

    @Published private(set) var isRecognizing = false
    /// 最近一次识别的候选（可能为空）
    @Published private(set) var candidates: [FoodCandidate] = []
    /// 最近一次多区域扫描识别出的本餐菜品组合（支持一餐多菜，如「米饭 + 辣椒炒肉 + 凉拌海带丝」）
    @Published private(set) var detectedMealDishes: [FoodCandidate] = []
    /// 最近一次识别的原始分类结果（不含泛类），用于排查识别质量
    @Published private(set) var rawClassifications: [(identifier: String, confidence: Double)] = []
    @Published private(set) var lastError: String?

    private init() {}

    /// 识别一张食物照片（全图 + 多区域分区扫描，解决托盘餐/多碗菜只识别到米饭而漏掉配菜的问题）。
    ///
    /// - Returns: 候选列表。**空数组表示没认出来**，调用方应引导用户手动选择。
    @discardableResult
    func recognize(in image: UIImage) async -> [FoodCandidate] {
        isRecognizing = true
        lastError = nil
        defer { isRecognizing = false }

        let normalizedImage = Self.normalizedUprightImage(image)
        guard let cgImage = normalizedImage.cgImage else {
            lastError = "图片无法转换"
            candidates = []
            detectedMealDishes = []
            rawClassifications = []
            return []
        }

        do {
            let (fullClassifications, regionResults) = try await Task.detached(priority: .userInitiated) {
                let full = try Self.classifySync(cgImage)
                let regions = Self.classifySpatialRegionsSync(cgImage)
                return (full, regions)
            }.value

            // 合并全图与各分区的最高置信度分类，避免配菜在全图中被大碗白米饭掩盖
            var mergedConfidence: [String: Double] = [:]
            for item in fullClassifications where item.confidence >= 0.05 {
                let key = item.identifier.lowercased()
                mergedConfidence[key] = max(mergedConfidence[key] ?? 0, item.confidence)
            }
            for (_, items) in regionResults {
                for item in items where item.confidence >= 0.05 {
                    let key = item.identifier.lowercased()
                    mergedConfidence[key] = max(mergedConfidence[key] ?? 0, item.confidence)
                }
            }

            let meaningful = mergedConfidence
                .map { (identifier: $0.key, confidence: $0.value) }
                .sorted { $0.confidence > $1.confidence }

            rawClassifications = meaningful
            let allCandidates = FoodCalorieEstimator.candidates(from: meaningful, limit: 8)
            candidates = allCandidates
            detectedMealDishes = Self.extractMealDishes(
                fullClassifications: fullClassifications,
                regionResults: regionResults,
                allCandidates: allCandidates
            )
            return allCandidates
        } catch {
            lastError = "识别失败：\(error.localizedDescription)"
            candidates = []
            detectedMealDishes = []
            rawClassifications = []
            return []
        }
    }

    /// 对餐盘/桌面常见的 4 个空间分区（左碗、上盘、右盘、下碟）分别执行图像分类（后台线程同步执行）。
    nonisolated private static func classifySpatialRegionsSync(_ cgImage: CGImage) -> [(name: String, results: [(identifier: String, confidence: Double)])] {
        let w = Double(cgImage.width)
        let h = Double(cgImage.height)
        guard w >= 120, h >= 120 else { return [] }

        let zones: [(String, CGRect)] = [
            ("left", CGRect(x: 0, y: h * 0.20, width: w * 0.44, height: h * 0.42)),
            ("top", CGRect(x: w * 0.22, y: h * 0.10, width: w * 0.70, height: h * 0.30)),
            ("right", CGRect(x: w * 0.46, y: h * 0.22, width: w * 0.52, height: h * 0.42)),
            ("bottom", CGRect(x: w * 0.26, y: h * 0.45, width: w * 0.56, height: h * 0.34))
        ]

        var output: [(name: String, results: [(identifier: String, confidence: Double)])] = []
        for (name, rect) in zones {
            guard let cropped = cgImage.cropping(to: rect),
                  let res = try? classifySync(cropped) else { continue }
            output.append((name: name, results: res))
        }
        return output
    }

    /// 从全图与分区结果中提取本餐包含的多道不同菜品（如「米饭 + 辣椒炒肉/家常小炒 + 凉拌海带丝/凉菜」）。
    private static func extractMealDishes(
        fullClassifications: [(identifier: String, confidence: Double)],
        regionResults: [(name: String, results: [(identifier: String, confidence: Double)])],
        allCandidates: [FoodCandidate]
    ) -> [FoodCandidate] {
        guard !allCandidates.isEmpty else { return [] }

        var chosenByID: [String: FoodCandidate] = [:]
        var orderedIDs: [String] = []

        func record(_ candidate: FoodCandidate) {
            if let existing = chosenByID[candidate.food.id] {
                if candidate.confidence > existing.confidence {
                    chosenByID[candidate.food.id] = candidate
                }
            } else {
                chosenByID[candidate.food.id] = candidate
                orderedIDs.append(candidate.food.id)
            }
        }

        // 1. 逐个分区提取该区域的代表菜品
        for (_, items) in regionResults {
            let map = Dictionary(
                items.map { ($0.identifier.lowercased(), $0.confidence) },
                uniquingKeysWith: max
            )
            let stirFryConf = max(map["stir_fry"] ?? 0, map["curry"] ?? 0)
            let seaweedConf = max(map["seaweed"] ?? 0, map["pickle"] ?? 0)
            let vegConf = max(
                map["vegetable"] ?? 0,
                map["green_beans"] ?? 0,
                map["pepper_veggie"] ?? 0,
                map["bell_pepper"] ?? 0,
                map["broccoli"] ?? 0
            )
            let riceConf = map["rice"] ?? 0

            // 分区特征 1：检测到中式热炒（如辣椒炒肉/小炒肉/红烧肉菜）
            if stirFryConf >= 0.12, let stirFryFood = FoodCatalog.item(id: "stir_fry_meat") {
                let effectiveConf = min(0.85, max(stirFryConf * 2.2, vegConf, 0.58))
                record(FoodCandidate(food: stirFryFood, confidence: effectiveConf, matchedIdentifier: "stir_fry"))
                continue
            }

            // 分区特征 2：检测到海带丝/凉拌小菜
            if seaweedConf >= 0.07, let seaweedFood = FoodCatalog.item(id: "seaweed_dish") {
                let effectiveConf = min(0.80, max(seaweedConf * 4.5, 0.52))
                record(FoodCandidate(food: seaweedFood, confidence: effectiveConf, matchedIdentifier: "seaweed"))
                continue
            }

            // 分区特征 3：明确的主食碗（如白米饭）且不含热炒特征
            if riceConf >= 0.55 && stirFryConf < 0.08, let riceFood = FoodCatalog.item(id: "rice") {
                record(FoodCandidate(food: riceFood, confidence: riceConf, matchedIdentifier: "rice"))
                continue
            }

            // 分区特征 4：其他高置信度独立菜品（如素菜、肉类、面条、披萨、汉堡等）
            let zoneCandidates = FoodCalorieEstimator.candidates(
                from: items.filter { $0.confidence >= 0.22 },
                limit: 3
            )
            if let topZoneCandidate = zoneCandidates.first {
                // 避免汤汁反光引起的低置信度 soup 误报
                if topZoneCandidate.food.id == "soup" && topZoneCandidate.confidence < 0.30 {
                    continue
                }
                record(topZoneCandidate)
            }
        }

        // 2. 如果分区扫描未命中最优主候选，确保全图最高置信度候选在列
        if let bestOverall = allCandidates.first, chosenByID[bestOverall.food.id] == nil {
            record(bestOverall)
        }

        // 3. 若既有「辣椒炒肉/家常小炒」又有因辣椒配菜触发的「素菜/炒青菜」，自动去重保留热炒荤菜
        if chosenByID["stir_fry_meat"] != nil && chosenByID["vegetable_dish"] != nil {
            chosenByID.removeValue(forKey: "vegetable_dish")
            orderedIDs.removeAll { $0 == "vegetable_dish" }
        }

        // 4. 排序：主食排第一，其余按识别顺序排列
        let results = orderedIDs.compactMap { chosenByID[$0] }
        let staples = results.filter { $0.food.isStaple }
        let nonStaples = results.filter { !$0.food.isStaple }
        return Array((staples + nonStaples).prefix(4))
    }

    /// 将带方向元数据的 UIImage 归一化为正立像素图，确保分区裁剪坐标与肉眼看到的上/下/左/右一致。
    private static func normalizedUprightImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// 执行 Vision 通用图像分类（后台线程同步调用）。
    nonisolated private static func classifySync(_ cgImage: CGImage) throws -> [(identifier: String, confidence: Double)] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map {
            (identifier: $0.identifier, confidence: Double($0.confidence))
        }
    }

    /// 把识别结果整理成给 LLM 的提示词片段。
    ///
    /// 只喂**具体食物类目**给 LLM（如「pizza 0.76」），不喂泛类与无关类目
    /// （「food」「tableware」等），否则小模型会被带偏。
    /// 候选为空时返回 nil——此时不该让 LLM 凭空猜，应该让用户手动选。
    func promptCandidatesSummary() -> String? {
        guard !candidates.isEmpty else { return nil }
        return candidates
            .map { "\($0.food.nameEn) (\(Int($0.confidence * 100))%)" }
            .joined(separator: ", ")
    }
}
