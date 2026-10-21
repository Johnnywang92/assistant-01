import XCTest
@testable import AssistantCore

/// 端侧 LLM 食物估算输出的解析测试。
///
/// 核心风险：1.5B 小模型的输出格式极不稳定，解析器若过于宽松，
/// 会把「无法理解的内容」解析成一个看似合理的热量值——
/// 用户据此记录，误差直接进入健康数据。
final class FoodLLMOutputParserTests: XCTestCase {

    // MARK: - 标准 JSON

    func testParsesStandardJSON() {
        let raw = #"{"food":"披萨","calories":520,"portion":"标准份","confidence":0.8}"#
        let parsed = FoodLLMOutputParser.parse(raw)
        XCTAssertEqual(parsed?.foodName, "披萨")
        XCTAssertEqual(parsed?.calories ?? 0, 520, accuracy: 0.01)
        XCTAssertEqual(parsed?.portion, .regular)
        XCTAssertEqual(parsed?.confidence ?? 0, 0.8, accuracy: 0.001)
    }

    func testParsesJSONWithExtraProseAroundIt() {
        let raw = "好的，我看出来了：{\"food\":\"汉堡\",\"calories\":400} 这个热量是估算值。"
        let parsed = FoodLLMOutputParser.parse(raw)
        XCTAssertEqual(parsed?.foodName, "汉堡")
        XCTAssertEqual(parsed?.calories ?? 0, 400, accuracy: 0.01)
    }

    func testParsesAlternateKeyNames() {
        let raw = #"{"name":"拉面","kcal":350}"#
        let parsed = FoodLLMOutputParser.parse(raw)
        XCTAssertEqual(parsed?.foodName, "拉面")
        XCTAssertEqual(parsed?.calories ?? 0, 350, accuracy: 0.01)
    }

    func testParsesNumericStringCalories() {
        let raw = #"{"food":"米饭","calories":"230"}"#
        XCTAssertEqual(FoodLLMOutputParser.parse(raw)?.calories ?? 0, 230, accuracy: 0.01)
    }

    func testParsesJSONWithTrailingComma() {
        let raw = #"{"food":"寿司","calories":300,}"#
        XCTAssertEqual(FoodLLMOutputParser.parse(raw)?.foodName, "寿司")
    }

    func testParsesQwen3OutputWithThinkingBlock() {
        let raw = """
        <think>
        候选有米饭(116 kcal/100g)和披萨(265 kcal/100g)，根据视觉置信度 0.76，这是一份标准披萨。
        </think>
        {"food":"披萨","calories":530,"portion":"标准份","confidence":0.82}
        """
        let parsed = FoodLLMOutputParser.parse(raw)
        XCTAssertEqual(parsed?.foodName, "披萨")
        XCTAssertEqual(parsed?.calories ?? 0, 530, accuracy: 0.01)
        XCTAssertEqual(parsed?.portion, .regular)
    }

    // MARK: - 散文

    func testParsesProseWithCalorieNumber() {
        let raw = "看起来像是一份披萨，大概 520 千卡左右。"
        let parsed = FoodLLMOutputParser.parse(raw)
        XCTAssertEqual(parsed?.foodName, "披萨")
        XCTAssertEqual(parsed?.calories ?? 0, 520, accuracy: 0.01)
    }

    func testParsesProseWithKcalUnit() {
        let raw = "This looks like fried chicken, about 300 kcal."
        let parsed = FoodLLMOutputParser.parse(raw)
        XCTAssertEqual(parsed?.calories ?? 0, 300, accuracy: 0.01)
    }

    // MARK: - 必须失败的输入

    func testEmptyInputReturnsNil() {
        XCTAssertNil(FoodLLMOutputParser.parse(""))
        XCTAssertNil(FoodLLMOutputParser.parse("   \n "))
    }

    /// 核心风险：没有热量数字时不得凭空造一个。
    func testMissingCaloriesReturnsNil() {
        XCTAssertNil(FoodLLMOutputParser.parse(#"{"food":"披萨"}"#))
    }

    func testUnknownFoodWithCaloriesReturnsNil() {
        // 热量有但菜名不认识 → 不能瞎猜一个食物
        XCTAssertNil(FoodLLMOutputParser.parse(#"{"food":"外星烧烤","calories":400}"#))
    }

    func testProseWithoutCaloriesReturnsNil() {
        XCTAssertNil(FoodLLMOutputParser.parse("看起来像是一份披萨。"))
    }

    func testNonNumericCaloriesReturnsNil() {
        XCTAssertNil(FoodLLMOutputParser.parse(#"{"food":"披萨","calories":"很多"}"#))
    }

    /// 明显离谱的热量（>5000）应判为解析错误。
    func testImplausibleCaloriesRejected() {
        XCTAssertNil(FoodLLMOutputParser.parse(#"{"food":"披萨","calories":99999}"#))
    }

    func testZeroOrNegativeCaloriesRejected() {
        XCTAssertNil(FoodLLMOutputParser.parse(#"{"food":"披萨","calories":0}"#))
        XCTAssertNil(FoodLLMOutputParser.parse(#"{"food":"披萨","calories":-100}"#))
    }

    func testOverlyLongInputRejected() {
        let raw = String(repeating: "啊", count: 3000)
        XCTAssertNil(FoodLLMOutputParser.parse(raw))
    }

    // MARK: - 份量解析

    func testPortionParsing() {
        XCTAssertEqual(FoodLLMOutputParser.parsePortion("大份"), .large)
        XCTAssertEqual(FoodLLMOutputParser.parsePortion("小份"), .small)
        XCTAssertEqual(FoodLLMOutputParser.parsePortion("标准份"), .regular)
        XCTAssertEqual(FoodLLMOutputParser.parsePortion("常规"), .regular)
        XCTAssertEqual(FoodLLMOutputParser.parsePortion("大"), .large)
        XCTAssertNil(FoodLLMOutputParser.parsePortion("随便"))
    }
}
