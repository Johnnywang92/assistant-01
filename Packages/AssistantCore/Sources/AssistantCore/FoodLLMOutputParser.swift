import Foundation

// MARK: - 端侧 LLM 食物估算输出的解析
//
// 为什么单独成文件：模型输出是**最不可靠**的输入环节。
// 端侧 1.5B 小模型对「只输出 JSON」指令的遵守度不稳定，可能返回：
//   - 纯散文：「看起来像是一份披萨，大概 300 千卡左右」
//   - 多个数字：「约 250 到 300 千卡」
//   - 带解释的 JSON：「{"food":"披萨","calories":300}  （因为图中有芝士）」
//   - 空字符串 / 拒答
//
// 解析策略必须**保守**：宁可解析失败退回候选列表，也不猜。
// 猜错的后果是用户得到完全错误的热量并照着记录。

/// 从端侧 LLM 的自由文本输出中解析出食物估算结果。
public enum FoodLLMOutputParser {

    /// 解析成功的结果。
    public struct Parsed: Equatable, Sendable {
        /// 识别出的菜名
        public let foodName: String
        /// 估算的热量（千卡，整份）
        public let calories: Double
        /// 份量（若模型给出）
        public let portion: FoodPortion?
        /// 模型自评置信度（若给出）
        public let confidence: Double?

        public init(foodName: String, calories: Double, portion: FoodPortion?, confidence: Double?) {
            self.foodName = foodName
            self.calories = calories
            self.portion = portion
            self.confidence = confidence
        }
    }

    /// 从模型输出中解析。
    /// - Returns: 解析失败返回 nil（调用方应保留 Vision 候选结果）。
    public static func parse(_ raw: String) -> Parsed? {
        let text = stripThinkingBlocks(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { return nil }

        // 1. 优先尝试 JSON（允许模型在 JSON 前后附带解释文字）
        if let parsed = parseJSON(text) {
            return parsed
        }
        // 2. 退化到散文解析
        return parseProse(text)
    }

    /// 剥离 Qwen3 等推理模型可能输出的 `<think>...</think>` 思考过程块，
    /// 避免思考过程里的数字或候选菜名干扰最终 JSON / 散文抽取。
    private static func stripThinkingBlocks(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result = String(result[..<start.lowerBound])
                break
            }
        }
        if let strayClose = result.range(of: "</think>") {
            result = String(result[strayClose.upperBound...])
        }
        return result
    }

    // MARK: - JSON 解析

    private static func parseJSON(_ text: String) -> Parsed? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8) else { return nil }

        // 允许模型漏引号等轻微格式错误：先按标准 JSON 试，失败再清洗
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let result = parseDictionary(obj) { return result }
        }
        let cleaned = cleanLooseJSON(jsonText)
        guard let data2 = cleaned.data(using: .utf8),
              let obj2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any] else { return nil }
        return parseDictionary(obj2)
    }

    /// 清洗小模型常见的 JSON 瑕疵：尾随逗号、单引号、未加引号的键。
    private static func cleanLooseJSON(_ json: String) -> String {
        var text = json
        // 去掉尾随逗号
        text = text.replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)
        // 单引号 → 双引号（仅当不含双引号时）
        if !text.contains("\"") {
            text = text.replacingOccurrences(of: "'", with: "\"")
        }
        return text
    }

    private static func parseDictionary(_ obj: [String: Any]) -> Parsed? {
        // 菜名：兼容 food / name / dish / food_name 等多种键名
        let nameKeys = ["food", "name", "dish", "food_name", "foodName", "菜名", "食物"]
        var foodName: String?
        for key in nameKeys {
            if let value = obj[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                foodName = value.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let name = foodName, !name.isEmpty, name.count <= 40 else { return nil }

        // 菜名必须能在食物库里**严格匹配**到对应项。
        // 模型有时会编造菜名（「外星烧烤」），若原样放行，UI 会展示一个
        // 不存在的食物配一个看似合理的热量——比解析失败更糟。
        guard FoodCatalog.item(matchingNameStrict: name) != nil else { return nil }

        // 热量：兼容 calories / kcal / energy / calories_per_serving 等
        let calorieKeys = ["calories", "kcal", "energy", "calories_per_serving", "热量", "卡路里"]
        var calories: Double?
        for key in calorieKeys {
            if let value = numericValue(obj[key]) {
                calories = value
                break
            }
        }
        guard let cal = calories, cal.isFinite, cal > 0 else { return nil }
        // 合理区间：单餐热量超过 5000 千卡几乎必然是解析错误
        guard cal <= 5000 else { return nil }

        // 份量
        var portion: FoodPortion?
        if let portionText = obj["portion"] as? String {
            portion = parsePortion(portionText)
        } else if let portionValue = obj["portion"] as? Double {
            portion = portionFromMultiplier(portionValue)
        }

        // 置信度
        var confidence: Double?
        if let conf = numericValue(obj["confidence"]) {
            confidence = min(max(conf, 0), 1)
        }

        return Parsed(foodName: name, calories: cal, portion: portion, confidence: confidence)
    }

    // MARK: - 散文解析

    /// 从「看起来像披萨，大概 300 千卡」这类文本里抽取菜名与热量。
    private static func parseProse(_ text: String) -> Parsed? {
        // 热量：取第一个「数字 + 千卡/大卡/kcal/cal」模式
        let caloriePattern = try? NSRegularExpression(
            pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(?:千卡|大卡|卡|kcal|cal)",
            options: [.caseInsensitive]
        )
        guard let caloriePattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = caloriePattern.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Double(text[valueRange]) else { return nil }
        guard value > 0, value <= 5000 else { return nil }

        // 菜名：从文本里匹配已知食物的中文名或别名
        guard let food = FoodCatalog.item(matchingNameStrict: extractNameCandidate(text))
                ?? matchKnownFood(in: text) else { return nil }

        return Parsed(foodName: food.name, calories: value, portion: nil, confidence: nil)
    }

    /// 从文本中截取可能的菜名片段（去掉标点与数量词）。
    private static func extractNameCandidate(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: "[，,。.！!？?；;：:、\\s]+",
            with: " ",
            options: .regularExpression
        )
        // 取「像/是/看起来像」之后的短片段
        let markers = ["像", "是", "看起来", "应该是", "估计是"]
        for marker in markers {
            if let range = cleaned.range(of: marker) {
                let after = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let firstChunk = after.split(separator: " ").first.map(String.init) ?? after
                if !firstChunk.isEmpty { return firstChunk }
            }
        }
        return cleaned
    }

    /// 在整段文本里查找是否出现已知食物名。
    ///
    /// 注意：这里用**精确匹配已知菜名**，而不是「菜名包含别名」。
    /// 否则模型编造的复合菜名（如「外星烧烤」）会因为包含「烧烤」而被误判为合法。
    private static func matchKnownFood(in text: String) -> FoodItem? {
        // 按名称长度倒序，保证「炸鸡」优先于「鸡胸肉」这类包含关系
        for food in FoodCatalog.items.sorted(by: { $0.name.count > $1.name.count }) {
            if text.contains(food.name) { return food }
        }
        for food in FoodCatalog.items.sorted(by: { $0.aliases.count > $1.aliases.count }) {
            for alias in food.aliases where alias.count >= 2 && text.contains(alias) {
                return food
            }
        }
        return nil
    }

    // MARK: - 辅助

    private static func numericValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String {
            let cleaned = s.replacingOccurrences(of: "[^0-9.\\-]", with: "", options: .regularExpression)
            return Double(cleaned)
        }
        return nil
    }

    /// 从「标准份/大份/小份」这类文本解析份量。
    public static func parsePortion(_ text: String) -> FoodPortion? {
        let t = text.lowercased()
        if t.contains("大份") || t.contains("large") || t.contains("大") { return .large }
        if t.contains("小份") || t.contains("small") || t.contains("小") { return .small }
        if t.contains("标准") || t.contains("常规") || t.contains("普通") || t.contains("regular") || t.contains("normal") {
            return .regular
        }
        return nil
    }

    /// 从份量倍数（1.0 / 0.5 / 1.8）反查份量档位。
    private static func portionFromMultiplier(_ value: Double) -> FoodPortion? {
        if abs(value - FoodPortion.small.multiplier) < 0.15 { return .small }
        if abs(value - FoodPortion.regular.multiplier) < 0.15 { return .regular }
        if abs(value - FoodPortion.large.multiplier) < 0.25 { return .large }
        return nil
    }
}
