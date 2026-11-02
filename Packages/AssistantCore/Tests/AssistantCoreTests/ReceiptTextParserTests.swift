import XCTest
@testable import AssistantCore

final class ReceiptTextParserTests: XCTestCase {

    // MARK: - 合计标签金额

    func testLabeledTotalWinsOverCandidates() {
        let text = """
        星巴克咖啡
        拿铁 ¥38.00
        可颂 ¥25.00
        合计：¥63.00
        """
        let result = ReceiptTextParser.parse(text)
        XCTAssertEqual(result.amount, 63.0)
        XCTAssertTrue(result.hasLabeledTotal)
        XCTAssertEqual(result.confidence, 0.92)
        XCTAssertEqual(result.title, "星巴克咖啡")
        XCTAssertEqual(result.categoryRaw, "餐饮美食")
    }

    func testLabeledTotalWithCommaThousands() {
        // 千分位逗号必须被剥掉，不能截成小数（金额解析铁律）
        let text = "王府井百货\n合计：¥1,250.00"
        XCTAssertEqual(ReceiptTextParser.extractLabeledTotalAmount(from: text), 1250.0)
    }

    func testPaidLabelVariants() {
        XCTAssertEqual(ReceiptTextParser.extractLabeledTotalAmount(from: "实付 88.5"), 88.5)
        XCTAssertEqual(ReceiptTextParser.extractLabeledTotalAmount(from: "应付:42"), 42)
        XCTAssertEqual(ReceiptTextParser.extractLabeledTotalAmount(from: "TOTAL ¥99.90"), 99.9)
    }

    func testLabeledTotalIgnoresZeroOrNegative() {
        XCTAssertNil(ReceiptTextParser.extractLabeledTotalAmount(from: "合计：¥0"))
    }

    // MARK: - 无标签时的最大金额兜底

    func testMaxCandidateFallbackWhenNoLabel() {
        let text = "某餐厅\n菜A ¥30\n菜B ¥45.5\n优惠 -5"
        let result = ReceiptTextParser.parse(text)
        XCTAssertFalse(result.hasLabeledTotal)
        XCTAssertEqual(result.amount, 45.5)
        XCTAssertEqual(result.confidence, 0.60)
        XCTAssertNotNil(result.confidenceReason)
    }

    func testNoAmountAtAll() {
        let result = ReceiptTextParser.parse("纯文字没有任何金额")
        XCTAssertEqual(result.amount, 0)
        XCTAssertEqual(result.confidence, 0.25)
        XCTAssertTrue(result.candidateAmounts.isEmpty)
    }

    /// 回溯陷阱：「¥1234.56」不得被截成 56（见 ExpenseAmountExtractor 铁律）
    func testDoesNotTruncateLongDecimals() {
        let text = "消费金额：¥1234.56"
        XCTAssertEqual(ReceiptTextParser.extractLabeledTotalAmount(from: text), 1234.56)
    }

    // MARK: - 商户名提取

    func testExplicitMerchantLabel() {
        XCTAssertEqual(ReceiptTextParser.extractMerchantOrTitle(from: "商户名称：海底捞火锅"), "海底捞火锅")
        XCTAssertEqual(ReceiptTextParser.extractMerchantOrTitle(from: "欢迎光临 麦当劳"), "麦当劳")
    }

    func testMerchantSkipsHeaderNoise() {
        let text = "销售小票\n12345678\n星巴克臻选店\n合计：¥40"
        XCTAssertEqual(ReceiptTextParser.extractMerchantOrTitle(from: text), "星巴克臻选店")
    }

    func testMerchantFallback() {
        XCTAssertEqual(ReceiptTextParser.extractMerchantOrTitle(from: "111111"), "小票消费")
    }

    // MARK: - 分类

    func testCategoryGuess() {
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "瑞幸咖啡", text: ""), "餐饮美食")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "全家便利店", text: ""), "居家日用")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "中石化加油站", text: ""), "交通出行")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "同仁堂药店", text: ""), "医疗健康")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "万达影城", text: ""), "休闲娱乐")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "华为专卖店", text: ""), "数码家电")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "猫砂工厂", text: ""), "宠物萌宠")
        XCTAssertEqual(ReceiptTextParser.guessCategoryRaw(merchant: "无名小店", text: "其他"), "购物消费")
    }

    // MARK: - 交易时间

    func testTransactionDateExtraction() {
        XCTAssertNotNil(TransactionDateExtractor.extract(from: "2026年10月26日 19:30 消费"))
        XCTAssertNotNil(TransactionDateExtractor.extract(from: "2026-10-26 12:00"))
        XCTAssertNotNil(TransactionDateExtractor.extract(from: "10月26日 08:15"))
        XCTAssertNotNil(TransactionDateExtractor.extract(from: "10月26日"))
        XCTAssertNil(TransactionDateExtractor.extract(from: "没有日期的文本"))
    }

    func testParseFallsBackToNowWithoutDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = ReceiptTextParser.parse("合计：¥10", now: now)
        XCTAssertEqual(result.date, now)
    }

    // MARK: - hasLabeledTotal 强判据

    func testHasLabeledTotal() {
        XCTAssertTrue(ReceiptTextParser.hasLabeledTotal("实付金额 55"))
        XCTAssertTrue(ReceiptTextParser.hasLabeledTotal("实付款 ¥128.00"))
        XCTAssertFalse(ReceiptTextParser.hasLabeledTotal("今天开会讨论金额上限55"))
    }

    // MARK: - 电商订单截图解析（淘宝、京东、支付宝等）

    func testTaobaoOrderParsing() {
        let text = """
        淘宝
        订单详情
        交易成功
        Apple Store 官方旗舰店 >
        iPhone 16 Pro 256GB 原色钛金属
        官方正品 现货速发
        ¥7999.00
        x1
        商品总价 ¥7999.00
        店铺优惠 -¥200.00
        红包抵扣 -¥100.00
        实付款 ¥7699.00
        订单编号: 123456789012345
        创建时间: 2026-10-28 10:15:30
        付款时间: 2026-10-28 10:16:02
        """
        let result = ReceiptTextParser.parse(text)
        XCTAssertEqual(result.amount, 7699.0, "实付款必须优先于商品总价被提取")
        XCTAssertTrue(result.hasLabeledTotal)
        XCTAssertTrue(result.title.contains("Apple") || result.title.contains("iPhone"))
        XCTAssertEqual(result.categoryRaw, "数码家电")
    }

    func testJDOrderParsing() {
        let text = """
        京东
        订单详情
        已完成
        京东自营
        罗技 (Logitech) M330 静音无线鼠标
        ¥79.00
        数量: 1
        商品总额 ¥79.00
        运费 ¥6.00
        运费券 -¥6.00
        实付款 ¥69.00
        在线支付
        订单编号: 28938472918
        下单时间: 2026-10-30 20:45:10
        """
        let result = ReceiptTextParser.parse(text)
        XCTAssertEqual(result.amount, 69.0, "实付款必须优先于商品总额被提取")
        XCTAssertTrue(result.hasLabeledTotal)
        XCTAssertTrue(result.title.contains("罗技") || result.title.contains("鼠标") || result.title.contains("自营"))
        XCTAssertEqual(result.categoryRaw, "数码家电")
    }

    func testAlipayPaymentScreenshot() {
        let text = """
        账单详情
        支付成功
        扫二维码付款-给**店
        -128.00
        商户全称 优衣库官方旗舰店
        实付金额 ¥128.00
        支付时间 2026-10-25 15:30:22
        """
        let result = ReceiptTextParser.parse(text)
        XCTAssertEqual(result.amount, 128.0)
        XCTAssertEqual(result.title, "优衣库官方旗舰店")
        XCTAssertEqual(result.categoryRaw, "购物消费")
    }
}
