import XCTest
@testable import AssistantCore

/// CORE-08 回归：中文数字解析统一到 `ChineseNumeralParser`，四个入口结果必须一致。
final class ChineseNumeralParserTests: XCTestCase {

    // MARK: - 表驱动：统一解析器

    func testUnifiedParserTable() {
        let cases: [(String, Double?)] = [
            ("一", 1), ("两", 2), ("三", 3), ("九", 9),
            ("十", 10), ("十五", 15), ("二十", 20), ("三十五", 35),
            ("半", 0.5), ("一半", 0.5),
            ("三百五", 350),          // 口语省略下级单位
            ("三百零五", 305),        // 「零」是显式个位
            ("一千零五", 1005),
            ("一万五", 15000),
            ("两百五", 250),
            ("12", 12), ("12.5", 12.5), ("．5", 0.5),
            ("", nil), ("abc", nil), ("半半", nil), ("三块五", nil)
        ]
        for (input, expected) in cases {
            let actual = ChineseNumeralParser.value(input)
            if let expected {
                XCTAssertEqual(actual ?? .nan, expected, accuracy: 0.0001, "「\(input)」解析错误")
            } else {
                XCTAssertNil(actual, "「\(input)」应判为不可解析")
            }
        }
    }

    func testIntegerEntryRejectsFraction() {
        XCTAssertEqual(ChineseNumeralParser.integer("一百"), 100)
        XCTAssertEqual(ChineseNumeralParser.integer("12"), 12)
        XCTAssertNil(ChineseNumeralParser.integer("半"))
        XCTAssertNil(ChineseNumeralParser.integer("12.5"))
    }

    // MARK: - 四个历史入口必须给出一致结果

    func testAllLegacyEntryPointsAgree() {
        let inputs = ["一", "两", "三", "十", "十五", "二十", "三十五", "三百五", "三百零五"]
        for input in inputs {
            guard let unified = ChineseNumeralParser.value(input) else {
                XCTFail("「\(input)」统一解析器不应失败")
                continue
            }
            XCTAssertEqual(ExpenseAmountExtractor.numberValue(input) ?? .nan, unified, accuracy: 0.0001,
                           "记账入口与统一实现不一致：\(input)")
            XCTAssertEqual(FoodCalorieEstimator.parseChineseQuantity(input), unified, accuracy: 0.0001,
                           "食物份量入口与统一实现不一致：\(input)")
            XCTAssertEqual(SkillPathPlanner.numericValue(input) ?? .nan, unified, accuracy: 0.0001,
                           "技能计划入口与统一实现不一致：\(input)")
            XCTAssertEqual(QueryInsightEngine.parseChineseNumber(input) ?? Int.min, Int(unified),
                           "查询入口与统一实现不一致：\(input)")
        }
    }

    // MARK: - 行为修复点

    /// 旧 `QueryInsightEngine.parseChineseNumber` 只支持 1–99，「一百天」解析失败；
    /// 统一后应返回 100（时间范围类查询依赖它）。
    func testQueryInsightNowSupportsHundreds() {
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("一百"), 100)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("三十"), 30)
        XCTAssertNil(QueryInsightEngine.parseChineseNumber("abc"))
    }

    /// 食物份量入口的旧语义是「解析失败按 1 份算」，统一后保留在**唯一一个显式默认值**上。
    func testFoodQuantityKeepsExplicitDefaultOfOne() {
        XCTAssertEqual(FoodCalorieEstimator.parseChineseQuantity("半"), 0.5)
        XCTAssertEqual(FoodCalorieEstimator.parseChineseQuantity("十五"), 15)
        XCTAssertEqual(FoodCalorieEstimator.parseChineseQuantity("半半"), 1.0, "不可解析时显式按一份")
        XCTAssertEqual(FoodCalorieEstimator.parseChineseQuantity("abc"), 1.0)
    }
}
