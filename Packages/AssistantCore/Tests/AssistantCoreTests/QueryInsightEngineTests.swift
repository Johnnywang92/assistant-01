import XCTest
@testable import AssistantCore

final class QueryInsightEngineTests: XCTestCase {

    // MARK: - 非查询句必须放过（防记账被劫持）

    func testExpenseStatementIsNotQuery() {
        XCTAssertNil(QueryInsightEngine.parse("昨天花了69.9"))
        XCTAssertNil(QueryInsightEngine.parse("咖啡10.9元，午餐22元"))
        XCTAssertNil(QueryInsightEngine.parse("中午吃麦当劳花了38块"))
    }

    func testTodoStatementIsNotQuery() {
        XCTAssertNil(QueryInsightEngine.parse("提醒我明天下午交报告"))
        XCTAssertNil(QueryInsightEngine.parse("安排一下明天的会议"))
    }

    func testEmptyAndOverlongIsNotQuery() {
        XCTAssertNil(QueryInsightEngine.parse(""))
        XCTAssertNil(QueryInsightEngine.parse("   "))
        let overlong = "查" + String(repeating: "账", count: 90)
        XCTAssertNil(QueryInsightEngine.parse(overlong))
    }

    // MARK: - 消费汇总

    func testExpenseAggregateThisWeek() {
        let insight = QueryInsightEngine.parse("本周花了多少")
        XCTAssertEqual(insight?.domain, .expense)
        XCTAssertEqual(insight?.kind, .aggregate)
        XCTAssertEqual(insight?.timeRange, .thisWeek)
    }

    func testExpenseAggregateLastWeek() {
        let insight = QueryInsightEngine.parse("上周消费多少")
        XCTAssertEqual(insight?.domain, .expense)
        XCTAssertEqual(insight?.timeRange, .lastWeek)
    }

    func testExpenseAggregateLastMonth() {
        let insight = QueryInsightEngine.parse("上个月的开销一共多少")
        XCTAssertEqual(insight?.domain, .expense)
        XCTAssertEqual(insight?.timeRange, .lastMonth)
    }

    func testExpenseDefaultRangeIsThisMonth() {
        let insight = QueryInsightEngine.parse("查账")
        XCTAssertEqual(insight?.domain, .expense)
        XCTAssertEqual(insight?.kind, .aggregate)
        XCTAssertEqual(insight?.timeRange, .thisMonth)
    }

    func testYesterdayExpense() {
        let insight = QueryInsightEngine.parse("昨天的账单花了多少")
        XCTAssertEqual(insight?.timeRange, .yesterday)
    }

    // MARK: - 趋势

    func testExpenseTrend() {
        let insight = QueryInsightEngine.parse("最近消费趋势怎么样")
        XCTAssertEqual(insight?.domain, .expense)
        XCTAssertEqual(insight?.kind, .trend)
    }

    func testExpenseTrendCompareLastWeek() {
        let insight = QueryInsightEngine.parse("这周比上周花得多吗")
        XCTAssertEqual(insight?.domain, .expense)
        XCTAssertEqual(insight?.kind, .trend)
        XCTAssertEqual(insight?.timeRange, .thisWeek)
    }

    func testDietTrend() {
        let insight = QueryInsightEngine.parse("最近饮食趋势怎么样")
        XCTAssertEqual(insight?.domain, .diet)
        XCTAssertEqual(insight?.kind, .trend)
        // 趋势默认窗口：饮食近30天
        XCTAssertEqual(insight?.timeRange, .lastNDays(30))
    }

    func testTrendDefaultWindowIsSixMonths() {
        let insight = QueryInsightEngine.parse("消费趋势")
        XCTAssertEqual(insight?.kind, .trend)
        XCTAssertEqual(insight?.timeRange, .lastNMonths(6))
    }

    // MARK: - 日程

    func testTodayAgenda() {
        let insight = QueryInsightEngine.parse("今天有什么安排")
        XCTAssertEqual(insight?.domain, .todo)
        XCTAssertEqual(insight?.kind, .agenda)
        XCTAssertEqual(insight?.timeRange, .today)
    }

    func testAgendaPhrases() {
        XCTAssertEqual(QueryInsightEngine.parse("今日安排")?.kind, .agenda)
        XCTAssertEqual(QueryInsightEngine.parse("明天的安排")?.timeRange, .tomorrow)
        XCTAssertEqual(QueryInsightEngine.parse("有什么待办")?.kind, .agenda)
    }

    func testTodoKeywordQuery() {
        let insight = QueryInsightEngine.parse("查看待办")
        XCTAssertEqual(insight?.domain, .todo)
        XCTAssertEqual(insight?.kind, .agenda)
    }

    // MARK: - 查找

    func testStorageLookup() {
        let insight = QueryInsightEngine.parse("护照放哪了")
        XCTAssertEqual(insight?.domain, .document) // 护照命中证件词表
        XCTAssertEqual(insight?.kind, .lookup)
        XCTAssertEqual(insight?.keyword, "护照")
    }

    func testStorageLookupWhereIs() {
        let insight = QueryInsightEngine.parse("充电宝在哪里")
        XCTAssertEqual(insight?.domain, .storage)
        XCTAssertEqual(insight?.kind, .lookup)
        XCTAssertEqual(insight?.keyword, "充电宝")
    }

    func testExplicitFindPrefix() {
        let insight = QueryInsightEngine.parse("查找布洛芬")
        XCTAssertEqual(insight?.domain, .medicine)
        XCTAssertEqual(insight?.kind, .lookup)
        XCTAssertEqual(insight?.keyword, "布洛芬")
    }

    // MARK: - 相对时间窗

    func testRelativeRangeParsing() {
        XCTAssertEqual(QueryInsightEngine.parse("最近3天花了多少")?.timeRange, .lastNDays(3))
        XCTAssertEqual(QueryInsightEngine.parse("近一周消费多少")?.timeRange, .lastNDays(7))
        XCTAssertEqual(QueryInsightEngine.parse("近半个月的开销有多少")?.timeRange, .lastNDays(15))
        XCTAssertEqual(QueryInsightEngine.parse("近半年消费趋势")?.timeRange, .lastNMonths(6))
        XCTAssertEqual(QueryInsightEngine.parse("最近3个月花了多少")?.timeRange, .lastNMonths(3))
    }

    func testChineseNumberParsing() {
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("3"), 3)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("三"), 3)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("两"), 2)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("十"), 10)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("十五"), 15)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("二十"), 20)
        XCTAssertEqual(QueryInsightEngine.parseChineseNumber("三十"), 30)
        XCTAssertNil(QueryInsightEngine.parseChineseNumber("abc"))
    }

    // MARK: - 时间窗区间计算

    func testTodayInterval() {
        let cal = Calendar.current
        let now = Date()
        let interval = QueryInsight.TimeRange.today.interval(now: now, calendar: cal)
        XCTAssertTrue(cal.isDateInToday(interval.start))
        XCTAssertEqual(interval.duration, 24 * 3600, accuracy: 5)
    }

    func testLastNDaysIncludesToday() {
        let cal = Calendar.current
        let now = Date()
        let interval = QueryInsight.TimeRange.lastNDays(7).interval(now: now, calendar: cal)
        XCTAssertTrue(interval.contains(now))
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: interval.start), to: cal.startOfDay(for: now)).day
        XCTAssertEqual(days, 6) // 含今天共 7 天
    }

    func testLastMonthIntervalEndsAtThisMonthStart() {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 10
        comps.day = 15
        let now = cal.date(from: comps)!
        let interval = QueryInsight.TimeRange.lastMonth.interval(now: now, calendar: cal)
        let startComps = cal.dateComponents([.year, .month], from: interval.start)
        XCTAssertEqual(startComps.year, 2026)
        XCTAssertEqual(startComps.month, 9)
        let endComps = cal.dateComponents([.year, .month], from: interval.end)
        XCTAssertEqual(endComps.year, 2026)
        XCTAssertEqual(endComps.month, 10)
    }

    // MARK: - 关键词抽取（与规则路径共用）

    func testExtractLookupKeyword() {
        XCTAssertEqual(QueryInsightEngine.extractLookupKeyword("护照放哪了"), "护照")
        XCTAssertEqual(QueryInsightEngine.extractLookupKeyword("查找充电宝"), "充电宝")
        XCTAssertEqual(QueryInsightEngine.extractLookupKeyword("帮我查一下发票"), "发票")
        XCTAssertNil(QueryInsightEngine.extractLookupKeyword("记得买牛奶"))
    }

    // MARK: - 文案格式化

    func testFormatAmount() {
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(12), "12")
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(12.5), "12.5")
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(12.50), "12.5")
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(12.345), "12.35")
        XCTAssertEqual(QueryAnswerBuilder.formatAmount(0), "0")
    }

    func testExpenseSummaryEmpty() {
        let text = QueryAnswerBuilder.expenseSummary(rangeLabel: "本周", lines: [])
        XCTAssertTrue(text.contains("本周"))
        XCTAssertTrue(text.contains("没有记账"))
    }

    func testExpenseSummaryTotals() {
        let lines = [
            QueryAnswerBuilder.ExpenseLine(title: "午饭", amount: 35, isIncome: false, categoryRaw: "餐饮美食"),
            QueryAnswerBuilder.ExpenseLine(title: "打车", amount: 25.5, isIncome: false, categoryRaw: "交通出行"),
            QueryAnswerBuilder.ExpenseLine(title: "工资", amount: 8000, isIncome: true, categoryRaw: "职业收入")
        ]
        let text = QueryAnswerBuilder.expenseSummary(rangeLabel: "昨天", lines: lines)
        XCTAssertTrue(text.contains("60.5"), "支出合计应为 60.5，实际文案：\(text)")
        XCTAssertTrue(text.contains("2 笔"))
        XCTAssertTrue(text.contains("收入 8000"))
        XCTAssertTrue(text.contains("午饭"), "最大一笔应被点名")
    }

    func testExpenseSummaryWithComparison() {
        let lines = [
            QueryAnswerBuilder.ExpenseLine(title: "午饭", amount: 100, isIncome: false, categoryRaw: "餐饮美食")
        ]
        let text = QueryAnswerBuilder.expenseSummary(rangeLabel: "本周", lines: lines, previousTotal: 50)
        XCTAssertTrue(text.contains("多 100%"), "环比 +100%，实际文案：\(text)")
    }

    func testExpenseTrendNarrative() {
        let trend = TrendAnalytics.expenseTrend(
            entries: [
                .init(date: monthDate(0), amount: 1000, isIncome: false, categoryRaw: "餐饮美食"),
                .init(date: monthDate(1), amount: 600, isIncome: false, categoryRaw: "餐饮美食"),
                .init(date: monthDate(1), amount: 400, isIncome: false, categoryRaw: "交通出行")
            ],
            now: monthDate(0),
            monthCount: 3
        )
        let text = QueryAnswerBuilder.expenseTrendNarrative(trend)
        XCTAssertTrue(text.contains("近3个月"))
        XCTAssertTrue(text.contains("月均"))
        XCTAssertTrue(text.contains("环比"))
    }

    func testDietTrendNarrativeEmpty() {
        let trend = TrendAnalytics.dietTrend(entries: [], dayCount: 7)
        XCTAssertTrue(QueryAnswerBuilder.dietTrendNarrative(trend).contains("还没有饮食记录"))
    }

    func testDietTrendNarrativeWithData() {
        let trend = TrendAnalytics.dietTrend(
            entries: [
                .init(date: Date(), calories: 1800),
                .init(date: Date().addingTimeInterval(-86400), calories: 2000)
            ],
            dayCount: 7
        )
        let text = QueryAnswerBuilder.dietTrendNarrative(trend)
        XCTAssertTrue(text.contains("日均摄入"))
        XCTAssertTrue(text.contains("2 天"))
    }

    func testAgendaSummary() {
        let text = QueryAnswerBuilder.agendaSummary(rangeLabel: "今天", lines: [
            .init(title: "交报告", timeText: "14:00"),
            .init(title: "取快递", timeText: nil, isOverdue: true)
        ], overflowCount: 2)
        XCTAssertTrue(text.contains("今天有 2 件"))
        XCTAssertTrue(text.contains("14:00 交报告"))
        XCTAssertTrue(text.contains("已逾期"))
        XCTAssertTrue(text.contains("另有 2 项"))
    }

    func testAgendaSummaryEmpty() {
        XCTAssertTrue(QueryAnswerBuilder.agendaSummary(rangeLabel: "今天", lines: []).contains("没有待办"))
    }

    // MARK: - 健康域（睡眠 / 分数趋势）

    func testHealthTrendQuestion() {
        let insight = QueryInsightEngine.parse("我最近睡得怎么样")
        XCTAssertEqual(insight?.domain, .health)
        XCTAssertEqual(insight?.kind, .trend)
        XCTAssertEqual(insight?.timeRange, .lastNDays(7), "健康趋势兜底为近 7 天（日粒度）")
    }

    func testHealthTrendExplicitRange() {
        let insight = QueryInsightEngine.parse("这周睡眠趋势如何")
        XCTAssertEqual(insight?.domain, .health)
        XCTAssertEqual(insight?.kind, .trend)
        XCTAssertEqual(insight?.timeRange, .thisWeek)
    }

    func testHealthAggregateSleepHours() {
        let insight = QueryInsightEngine.parse("昨天睡了多少")
        XCTAssertEqual(insight?.domain, .health)
        XCTAssertEqual(insight?.kind, .aggregate)
        XCTAssertEqual(insight?.timeRange, .yesterday)
    }

    func testHealthAggregateDefaultRangeIsToday() {
        let insight = QueryInsightEngine.parse("步数多少")
        XCTAssertEqual(insight?.domain, .health)
        XCTAssertEqual(insight?.kind, .aggregate)
        XCTAssertEqual(insight?.timeRange, .today)
    }

    func testHealthStatementIsNotQuery() {
        // 陈述句（无疑问标记）不当成查询
        XCTAssertNil(QueryInsightEngine.parse("今天睡了八小时"))
    }

    func testHealthWordWithLocationIsStillLookup() {
        // 「健康证」含健康词，但放哪了是位置查找，不能被健康域劫持
        let insight = QueryInsightEngine.parse("健康证放哪了")
        XCTAssertEqual(insight?.domain, .storage)
        XCTAssertEqual(insight?.kind, .lookup)
    }

    func testHealthTrendNarrative() {
        let trend = TrendAnalytics.healthTrend(
            entries: [
                TrendAnalytics.HealthEntry(date: Date(), sleepHours: 7.5, vitalityScore: 80)
            ],
            dayCount: 7
        )
        let text = QueryAnswerBuilder.healthTrendNarrative(trend)
        XCTAssertTrue(text.contains("睡眠数据"))
        XCTAssertTrue(text.contains("7.5"))
    }

    func testHealthTrendNarrativeEmptyIsHonest() {
        let trend = TrendAnalytics.healthTrend(entries: [], dayCount: 7)
        XCTAssertTrue(QueryAnswerBuilder.healthTrendNarrative(trend).contains("还没有健康数据"))
    }

    func testHealthSummaryOmitsMissingMetrics() {
        let text = QueryAnswerBuilder.healthSummary(rangeLabel: "今天", sleepHours: 7.2)
        XCTAssertTrue(text.contains("睡眠 7.2 小时"))
        XCTAssertFalse(text.contains("步"), "缺失指标不应出现在应答里")
    }

    // MARK: - 辅助

    /// 第 offset 个月的 15 号（offset=0 为当月）
    private func monthDate(_ offset: Int) -> Date {
        let cal = Calendar.current
        let thisMonthStart = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let targetMonth = cal.date(byAdding: .month, value: -offset, to: thisMonthStart) ?? Date()
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: targetMonth) ?? targetMonth
    }
}
