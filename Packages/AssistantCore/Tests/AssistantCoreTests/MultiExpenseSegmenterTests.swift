import XCTest

@testable import AssistantCore

/// 多笔消费拆分：决定「哪个金额配哪个标题」，拆错即静默记错账。
final class MultiExpenseSegmenterTests: XCTestCase {

    private func amounts(_ segments: [String]?) -> [Double]? {
        segments?.map { ExpenseAmountExtractor.extractAmount(from: $0) ?? -1 }
    }

    // MARK: - 基本拆分

    func testSplitsCommaSeparatedItems() {
        let result = MultiExpenseSegmenter.split("咖啡10.9元，午餐22元，公交1元")
        XCTAssertEqual(result, ["咖啡10.9元", "午餐22元", "公交1元"])
        XCTAssertEqual(amounts(result), [10.9, 22, 1])
    }

    func testSplitsDunhaoAndSemicolonSeparators() {
        let result = MultiExpenseSegmenter.split("打车15、地铁3；买水2元")
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(amounts(result), [15, 3, 2])
    }

    func testSplitsWith还有Connector() {
        let result = MultiExpenseSegmenter.split("咖啡10.9元，还有午餐22元")
        XCTAssertEqual(result, ["咖啡10.9元", "午餐22元"])
    }

    func testSingleItemReturnsNil() {
        XCTAssertNil(MultiExpenseSegmenter.split("咖啡10.9元"))
        XCTAssertNil(MultiExpenseSegmenter.split("中午吃麦当劳花了38块"))
    }

    // MARK: - 裸数字不算合格金额

    func testBareNumbersDoNotSplit() {
        // 「3人」的 3、「24期」的 24 是裸数字，不得拆成独立一笔
        XCTAssertNil(MultiExpenseSegmenter.split("AA制3人一共200元"))
        XCTAssertNil(MultiExpenseSegmenter.split("分24期买了手机花了6000元"))
    }

    func testQualifiedAmountRequiresUnitOrVerb() {
        XCTAssertTrue(MultiExpenseSegmenter.hasQualifiedAmount("咖啡10.9元"))
        XCTAssertTrue(MultiExpenseSegmenter.hasQualifiedAmount("花了38"))
        XCTAssertTrue(MultiExpenseSegmenter.hasQualifiedAmount("$6.5"))
        XCTAssertFalse(MultiExpenseSegmenter.hasQualifiedAmount("3人"))
        XCTAssertFalse(MultiExpenseSegmenter.hasQualifiedAmount("24期"))
    }

    // MARK: - 邻接拆分（无分隔符）

    func testSplitsAdjacentAmountsWithoutSeparators() {
        // 语音常见：无逗号。「10块9」整体是 10.9，切点必须落在「9」之后
        let result = MultiExpenseSegmenter.split("咖啡10块9午餐22元公交1元")
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(amounts(result), [10.9, 22, 1])
    }

    func testAdjacentSplitKeepsPrefixWithItem() {
        let result = MultiExpenseSegmenter.split("早餐包子5元午餐面22元")
        XCTAssertEqual(result?.count, 2)
        XCTAssertTrue(result?.first?.contains("包子") == true)
    }

    // MARK: - 汇总句剔除

    func testSummaryClauseIsDropped() {
        let result = MultiExpenseSegmenter.split("咖啡10.9元，午餐22元，一共33元")
        XCTAssertEqual(result, ["咖啡10.9元", "午餐22元"])
    }

    func testSummarySmallerThanItemsIsKeptAsRealExpense() {
        // 「一共花了100元」金额远小于分项之和(800)，不是总额 → 保留为真实一笔
        let result = MultiExpenseSegmenter.split("买包300元，买鞋500元，一共花了100元送人")
        XCTAssertEqual(result?.count, 3)
    }

    func testSummaryOnlyLeavesOneItemThenFallsBack() {
        // 剔除汇总后只剩 1 笔 → 不可拆（宁可不拆，不可拆错）
        XCTAssertNil(MultiExpenseSegmenter.split("咖啡10.9元，一共11元"))
    }

    // MARK: - 无金额片段合并

    func testLeadingFragmentMergesIntoNextItem() {
        let result = MultiExpenseSegmenter.split("打车去机场，花了50元，买咖啡10元")
        XCTAssertEqual(result?.count, 2)
        XCTAssertTrue(result?.first?.contains("打车去机场") == true)
    }

    func testMiddleFragmentMergesIntoPreviousItem() {
        let result = MultiExpenseSegmenter.split("咖啡10.9元，好喝，午餐22元")
        XCTAssertEqual(result?.count, 2)
        XCTAssertTrue(result?.first?.contains("好喝") == true)
    }

    // MARK: - 归一化与数字边界

    func testThousandsCommaDoesNotSplit() {
        let result = MultiExpenseSegmenter.split("买电脑1,250元，鼠标99元")
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(amounts(result), [1250, 99])
    }

    func testDecimalPointDoesNotSplit() {
        let result = MultiExpenseSegmenter.split("咖啡12.5元，蛋糕25.5元")
        XCTAssertEqual(amounts(result), [12.5, 25.5])
    }

    func testChineseSpokenAmounts() {
        let result = MultiExpenseSegmenter.split("打车三十五块，买水两元")
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(amounts(result), [35, 2])
    }

    func testEmptyAndNoAmountReturnsNil() {
        XCTAssertNil(MultiExpenseSegmenter.split(""))
        XCTAssertNil(MultiExpenseSegmenter.split("今天天气不错"))
        XCTAssertNil(MultiExpenseSegmenter.split("买了咖啡和面包"))
    }

    // MARK: - 混合收支

    func testMixedIncomeAndExpense() {
        let result = MultiExpenseSegmenter.split("工资8000元，交房租2500元")
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(amounts(result), [8000, 2500])
    }

    func testForeignCurrencyItems() {
        let result = MultiExpenseSegmenter.split("拉面1200日元，星巴克$6.5")
        XCTAssertEqual(result?.count, 2)
    }
}
