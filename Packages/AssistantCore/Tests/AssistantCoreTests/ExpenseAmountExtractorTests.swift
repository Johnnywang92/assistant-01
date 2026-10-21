import XCTest
@testable import AssistantCore

/// 一句话记账的金额提取回归测试。
///
/// 这组用例全部来自真实 bug：用户反馈「记账时只记录最后两位数字」。
/// 两个根因（详见 `ExpenseAmountExtractor` 顶部注释）：
///   1. 口语金额正则的数字部分不支持小数 → "花了1234.56元" 只捕获 "56"
///   2. 千分位正则用 `\b` 收尾 → "1,250元" 的逗号没被剥掉，金额截成 "250"
///
/// **改动金额正则前请先跑这个文件**，并在新增用例里写清对应的真实输入。
final class ExpenseAmountExtractorTests: XCTestCase {

    private func amount(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Double? {
        ExpenseAmountExtractor.extract(from: text)
    }

    private func assertAmount(
        _ text: String,
        _ expected: Double,
        accuracy: Double = 0.005,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = amount(text) else {
            XCTFail("「\(text)」未能提取出金额", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, "「\(text)」金额错误", file: file, line: line)
    }

    // MARK: - 回归：小数金额被截成末两位

    func testDecimalAmountIsNotTruncatedToTrailingDigits() {
        assertAmount("花了1234.56元", 1234.56)
        assertAmount("午饭38.5元", 38.50)
        assertAmount("打车12.80块", 12.80)
        assertAmount("买菜28.6元", 28.60)
        assertAmount("餐费88.88元", 88.88)
        assertAmount("买奶粉458.5元", 458.50)
        assertAmount("物业费2860.50元", 2860.50)
        assertAmount("京东下单1999.99元", 1999.99)
        assertAmount("超市花了12,345.67元", 12345.67)
        assertAmount("买了1234.56块钱的菜", 1234.56)
        assertAmount("外卖点了48.90元", 48.90)
        assertAmount("收入20000.88元", 20000.88)
        assertAmount("房租和水电一共2350.60元", 2350.60)
        assertAmount("车险花了5230.40元", 5230.40)
        // 无货币单位的裸数字（含空格与紧贴汉字两种情形）
        assertAmount("午饭 38.5", 38.50)
        assertAmount("午饭38.5", 38.50)
        assertAmount("打车 12.80", 12.80)
        assertAmount("买菜28.60", 28.60)
        assertAmount("打车 25", 25.00)
        assertAmount("打车25", 25.00)
        assertAmount("发工资 15000", 15000.00)
    }

    // MARK: - 回归：千分位逗号截断

    func testThousandsSeparatorIsStrippedBeforeChineseUnit() {
        // 「\b」在「数字↔汉字」边界不成立，逗号残留会让金额从千位截断
        assertAmount("机票1,250元", 1250)
        assertAmount("买了1,234元的东西", 1234)
        assertAmount("1,200日元", 1200)
        assertAmount("买了1,299.00元的东西", 1299.00)
        assertAmount("超市花了12,345.67元", 12345.67)
    }

    func testThousandsSeparatorOnlyStrippedForValidGrouping() {
        // 非千分位的逗号不能被误删（如 "1,23" 不是合法的三位分组）
        XCTAssertEqual(ExpenseAmountExtractor.normalize("1,23元"), "1,23元")
        XCTAssertEqual(ExpenseAmountExtractor.normalize("12,3456"), "12,3456")
        XCTAssertEqual(ExpenseAmountExtractor.normalize("1,234,567元"), "1234567元")
        XCTAssertEqual(ExpenseAmountExtractor.normalize("午饭   38.5"), "午饭 38.5")
        XCTAssertEqual(ExpenseAmountExtractor.normalize("water  bill  50"), "water bill 50")
    }

    // MARK: - 原有正常行为（防回归）

    func testCommonChineseAmountsStillParse() {
        assertAmount("中午吃麦当劳花了38块", 38)
        assertAmount("地铁3元", 3)
        assertAmount("昨天烤肉200元", 200)
        assertAmount("话费充值100元", 100)
        assertAmount("学费24000元", 24000)
        assertAmount("收入12000元", 12000)
        assertAmount("房租4500元", 4500)
    }

    func testSpokenAndChineseNumeralAmounts() {
        assertAmount("加油三百五十元", 350)
        assertAmount("超市花了一百二十三元", 123)
        assertAmount("咖啡35块5毛", 35.50)
        assertAmount("中石化加油加了三百二十八块五毛", 328.50)
        assertAmount("一兰拉面1200日元", 1200)
        assertAmount("星巴克$6.5", 6.5)
    }

    func testReturnsNilWhenNoAmountPresent() {
        XCTAssertNil(amount("今天天气不错"))
        XCTAssertNil(amount(""))
        XCTAssertNil(amount("   "))
    }

    // MARK: - 中文数字转换

    func testChineseNumberConversion() {
        XCTAssertEqual(ExpenseAmountExtractor.numberValue("一百二十三")!, 123, accuracy: 0.001)
        XCTAssertEqual(ExpenseAmountExtractor.numberValue("三百五十")!, 350, accuracy: 0.001)
        XCTAssertEqual(ExpenseAmountExtractor.numberValue("两千")!, 2000, accuracy: 0.001)
        XCTAssertEqual(ExpenseAmountExtractor.numberValue("一万二千")!, 12000, accuracy: 0.001)
        XCTAssertEqual(ExpenseAmountExtractor.numberValue("十")!, 10, accuracy: 0.001)
        // 阿拉伯数字直通
        XCTAssertEqual(ExpenseAmountExtractor.numberValue("1234.56")!, 1234.56, accuracy: 0.001)
        // 含非法字符返回 nil
        XCTAssertNil(ExpenseAmountExtractor.numberValue("abc"))
    }
}