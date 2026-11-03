import AssistantCore
import XCTest

/// 三通道合并解读的回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **时间窗语义搞反**——量表问的是「过去两周」，微记录是「当下」。
///    把「最近好转了」当成「与量表矛盾」，结论方向完全错，
///    而错误的结论会让用户以为自己的状态没有改善。
/// 2. **把一次波动当趋势**——微记录方向判定必须要求足够样本 + 超过噪声阈值。
/// 3. **无数据通道被当成正常**——读不到就是读不到，不能拿来当安慰。
/// 4. **用因果措辞**——观察性数据支撑不了「因为…所以…」。
/// 5. **单通道数据被当成多通道结论**。
final class PsychChannelMergerTests: XCTestCase {

    // MARK: - 测试辅助

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return cal
    }()

    /// 基准日：2026-11-02 00:00:00 +0800
    private let now = Date(timeIntervalSince1970: 1_792_819_200)

    /// 相对基准日偏移若干天的**归属日**（当天零点）。
    /// `daysAgo` 为正数表示过去，为负数表示未来。
    private func day(_ daysAgo: Int) -> Date {
        let raw = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return calendar.startOfDay(for: raw)
    }

    /// 构造量表计分结果。
    private func scale(
        total: Int,
        daysAgo: Int,
        scaleID: PsychScaleID = .phq9,
        safetyScore: Int = 0
    ) -> PsychScaleScore {
        let definition = PsychScaleCatalog.definition(for: scaleID)
        var answers: [Int: PsychItemAnswer] = [:]
        var remaining = total
        for item in definition.items {
            if item.isSafetyItem {
                answers[item.index] = .answered(score: safetyScore)
                continue
            }
            let v = min(3, max(0, remaining))
            answers[item.index] = .answered(score: v)
            remaining -= v
        }
        return PsychScaleScorer.score(
            answers: answers,
            definition: definition,
            completedAt: day(daysAgo)
        )
    }

    /// 构造微记录。
    private func mood(
        daysAgo: Int,
        mood: Int = 3,
        energy: Int = 3,
        stress: Int = 2
    ) -> MoodCheckInEntry {
        MoodCheckInEntry(
            day: day(daysAgo),
            moodScore: mood,
            energyScore: energy,
            stressScore: stress
        )
    }

    private func physiology(stress: Int) -> PleasureIndexEvaluation {
        PleasureIndexEvaluation(
            pleasureScore: 100 - stress,
            state: stress >= 60 ? .strained : .serene,
            stressScore: stress,
            stressLevel: stress >= 60 ? .elevated : .low,
            autonomicScore: 100 - stress,
            autonomicBalance: stress >= 60 ? .sympatheticDominant : .balanced,
            sleepRecoveryScore: 70,
            summary: "测试",
            advice: "测试",
            details: []
        )
    }

    private func merge(
        scales: [PsychScaleScore] = [],
        moods: [MoodCheckInEntry] = [],
        physiology: PleasureIndexEvaluation? = nil,
        sleep: Double? = nil,
        now: Date? = nil
    ) -> MentalHealthCombinedReading {
        PsychChannelMerger.merge(
            scaleScores: scales,
            moodEntries: moods,
            physiology: physiology,
            recentAverageSleepHours: sleep,
            now: now ?? self.now,
            calendar: calendar
        )
    }

    private func reading(_ reading: MentalHealthCombinedReading, _ channel: PsychChannel) -> PsychChannelReading {
        reading.channels.first { $0.channel == channel } ?? .unavailable(channel)
    }

    // MARK: - 时间窗语义（核心风险 1）

    /// 核心风险 1：问卷尚可、但更近的微记录在变差 → 应识别为「问卷滞后」。
    func testRecentDeteriorationIsDetectedWhenDailyIsNewerThanScale() {
        // 量表在 14 天前完成 → 回忆窗 = [28 天前, 14 天前]
        // 微记录全在最近 7 天 → 晚于量表
        let scales = [scale(total: 3, daysAgo: 14)]
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let result = merge(scales: scales, moods: moods)

        XCTAssertEqual(result.timeline, .dailyIsNewer)
        XCTAssertEqual(result.agreement, .recentDeterioration,
                       "问卷滞后于当下时必须指出「最近的情况更值得当真」")
    }

    /// 核心风险 1 的反向：问卷有困扰、但更近的微记录在好转 → 「正在改善」。
    func testRecentImprovementIsDetectedWhenDailyIsNewerThanScale() {
        let scales = [scale(total: 12, daysAgo: 14)]
        // 近 7 天明显好转（对比更早的 7 天）
        let moods = (7..<14).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }
            + (0..<7).map { mood(daysAgo: $0, mood: 4, energy: 4, stress: 1) }

        let result = merge(scales: scales, moods: moods)

        XCTAssertEqual(result.timeline, .dailyIsNewer)
        XCTAssertEqual(result.agreement, .recentImprovement)
    }

    /// 核心风险 1：微记录与量表**同期**时，不该说「问卷滞后」。
    /// 同期方向相反是「同期不一致」，不是「最近在变差」。
    func testOverlappingTimelineIsNotTreatedAsLaggingQuestionnaire() {
        // 量表今天完成 → 回忆窗 [14 天前, 今天]
        // 微记录全在最近 7 天 → 落在回忆窗内
        let scales = [scale(total: 3, daysAgo: 0)]
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let result = merge(scales: scales, moods: moods)

        XCTAssertEqual(result.timeline, .overlapping)
        XCTAssertNotEqual(result.agreement, .recentDeterioration,
                          "同期数据不该被解读成「问卷滞后于当下」")
    }

    /// 微记录全在量表回忆窗之前 → 同期的另一种形态。
    func testTimelineOverlappingWhenMoodPredatesScale() {
        let scales = [scale(total: 12, daysAgo: 0)]
        // 微记录在 8~13 天前，落在 [14 天前, 今天] 回忆窗内
        let moods = (8..<14).map { mood(daysAgo: $0, mood: 4, energy: 4, stress: 1) }

        let result = merge(scales: scales, moods: moods)
        XCTAssertEqual(result.timeline, .overlapping)
    }

    // MARK: - 互相印证

    /// 问卷有困扰 + 微记录也偏低 → 互相印证。
    func testCorroborationWhenQuestionnaireAndDailyAgree() {
        let scales = [scale(total: 12, daysAgo: 0)]
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let result = merge(scales: scales, moods: moods)
        XCTAssertEqual(result.agreement, .corroborated)
    }

    /// 问卷有困扰 + 生理负荷高 → 互相印证。
    func testCorroborationWhenQuestionnaireAndPhysiologyAgree() {
        let scales = [scale(total: 12, daysAgo: 0)]
        let result = merge(scales: scales, physiology: physiology(stress: 80))
        XCTAssertEqual(result.agreement, .corroborated)
    }

    // MARK: - 方向判定（核心风险 2）

    /// 核心风险 2：样本不足时不得给出方向。
    func testDirectionRequiresEnoughSamples() {
        // 近窗口只有 1 条记录
        let moods = [mood(daysAgo: 0, mood: 1, energy: 1, stress: 5)]
        let result = merge(scales: [scale(total: 12, daysAgo: 0)], moods: moods)
        XCTAssertEqual(reading(result, .daily).direction, .unknown,
                       "样本不足时不得编造方向")
    }

    /// 核心风险 2：变化小于阈值时视为平稳，不算变差。
    func testTinyFluctuationIsTreatedAsStable() {
        // 心情 3 → 3.4 级别的微小变化（用 3 → 3 的等值近似，阈值 0.5）
        let moods = (7..<14).map { mood(daysAgo: $0, mood: 3, energy: 3, stress: 2) }
            + (0..<7).map { mood(daysAgo: $0, mood: 3, energy: 3, stress: 2) }

        let result = merge(scales: [scale(total: 12, daysAgo: 0)], moods: moods)
        XCTAssertEqual(reading(result, .daily).direction, .stable,
                       "噪声级别的波动不得被判成趋势")
    }

    /// 三个维度中两个变差即判为恶化。
    func testTwoDeterioratedDimensionsImpliesWorsening() {
        let moods = (7..<14).map { mood(daysAgo: $0, mood: 4, energy: 4, stress: 1) }
            + (0..<7).map { mood(daysAgo: $0, mood: 3, energy: 2, stress: 4) }

        let result = merge(scales: [scale(total: 12, daysAgo: 0)], moods: moods)
        XCTAssertEqual(reading(result, .daily).direction, .worsening)
    }

    // MARK: - 无数据处理（核心风险 3）

    /// 核心风险 3：没有微记录时，该通道必须是无数据而不是「平稳」。
    func testMissingDailyChannelIsUnavailableNotStable() {
        let result = merge(scales: [scale(total: 12, daysAgo: 0)])
        let daily = reading(result, .daily)
        XCTAssertFalse(daily.hasData)
        XCTAssertEqual(daily.direction, .unknown)
        XCTAssertEqual(daily.level, .unknown)
    }

    /// 核心风险 3：没有生理数据时，该通道必须无数据。
    func testMissingPhysiologyIsUnavailable() {
        let result = merge(scales: [scale(total: 12, daysAgo: 0)])
        XCTAssertFalse(reading(result, .physiological).hasData)
    }

    /// 核心风险 5：只有一条通道有数据时，关系是 singleChannel。
    func testSingleChannelIsReportedAsSuch() {
        let result = merge(scales: [scale(total: 12, daysAgo: 0)])
        XCTAssertEqual(result.agreement, .singleChannel)
        XCTAssertTrue(result.summary.contains("只有"),
                      "单通道时必须说明「只有一路数据」，不能假装做了交叉验证")
    }

    // MARK: - 措辞纪律（核心风险 4）

    /// 核心风险 4：合并结论不得使用因果措辞。
    func testCombinedSummaryAvoidsCausalWording() {
        let scales = [scale(total: 12, daysAgo: 0)]
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }
        let result = merge(scales: scales, moods: moods, physiology: physiology(stress: 80))

        let forbidden = ["因为", "导致", "造成"]
        for word in forbidden {
            XCTAssertFalse(result.summary.contains(word),
                           "合并结论不得使用因果措辞「\(word)」：\(result.summary)")
        }
    }

    /// 核心风险 4：合并结论里也不该出现疾病判定。
    func testCombinedSummaryContainsNoDiagnosis() {
        let scales = [scale(total: 22, daysAgo: 0)]
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 1, energy: 1, stress: 5) }
        let result = merge(scales: scales, moods: moods)

        let forbidden = ["抑郁症", "焦虑症", "确诊", "诊断为", "你得了"]
        for word in forbidden {
            XCTAssertFalse(result.summary.contains(word),
                           "合并结论不得出现疾病判定「\(word)」：\(result.summary)")
        }
    }

    // MARK: - 与解读器的集成

    /// 合并读数应被解读器接住，且结论采用合并后的说法。
    func testInsightUsesCombinedReading() {
        let scales = [scale(total: 12, daysAgo: 0)]
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: scales,
                physiology: physiology(stress: 80),
                moodEntries: moods
            )
        )
        XCTAssertNotNil(insight.combinedReading)
        XCTAssertEqual(insight.combinedReading?.agreement, .corroborated)
        XCTAssertTrue(insight.headline.contains("指向同一件事"),
                      "解读结论应采用合并后的说法，实际：\(insight.headline)")
    }

    /// 数据不足（没做量表）时不产出合并读数——连分档都没有，谈三路关系没意义。
    func testNoCombinedReadingWhenNoScaleData() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [])
        )
        XCTAssertNil(insight.combinedReading)
    }

    /// 微记录显示在变差时，主动作应优先指向「走出门」这类行为激活。
    func testWorseningDailyDrivesActionableAction() {
        let scales = [scale(total: 9, daysAgo: 0)]
        let moods = (7..<14).map { mood(daysAgo: $0, mood: 4, energy: 4, stress: 1) }
            + (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: scales,
                moodEntries: moods,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertEqual(insight.primaryAction, .walk,
                       "微记录在恶化时，应优先给出可立即执行的行为激活动作")
    }

    /// 解读器必须真的使用传入的 `now`——
    /// 硬编码墙上时钟会让窗口整体错位，这条规则就失去了单测能力。
    func testInsightHonorsProvidedNow() {
        let scales = [scale(total: 9, daysAgo: 0)]
        let moods = (7..<14).map { mood(daysAgo: $0, mood: 4, energy: 4, stress: 1) }
            + (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: scales,
                moodEntries: moods,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertEqual(
            insight.combinedReading?.channels.first { $0.channel == .daily }?.direction,
            .worsening,
            "解读器必须用传入的 now 切窗口，而不是墙上时钟"
        )
    }

    /// 主页与结果页喂入的量表序列顺序不同（主页倒序、结果页「本次 + 历史」），
    /// 但**结论必须一致**——否则用户会看到「主页说在恶化、结果页说平稳」。
    func testInsightIsIndependentOfScaleSequenceOrder() {
        let latest = scale(total: 13, daysAgo: 0)
        let previous = scale(total: 9, daysAgo: 14)
        let moods = (0..<7).map { mood(daysAgo: $0, mood: 2, energy: 2, stress: 4) }

        // 主页的顺序：倒序（最新在前）
        let homeOrder = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [latest, previous],
                moodEntries: moods,
                now: now,
                calendar: calendar
            )
        )
        // 结果页的顺序：本次 + 历史
        let resultOrder = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [latest, previous],
                moodEntries: moods,
                now: now,
                calendar: calendar
            )
        )

        XCTAssertEqual(homeOrder.combinedReading, resultOrder.combinedReading)
        XCTAssertEqual(homeOrder.headline, resultOrder.headline)
    }

    /// 量表按**完成时间**判方向，不是按分数高低——
    /// 分数高低不代表时间先后，按分数排序会把「先做的分高、后做的分低」读成上升。
    func testScaleDirectionUsesCompletionTimeNotScore() {
        // 先做的分数 9（8 天前），后做的分数 5（1 天前）→ 实际是**下降**
        let earlierHigher = scale(total: 9, daysAgo: 8)
        let laterLower = scale(total: 5, daysAgo: 1)

        let result = merge(scales: [earlierHigher, laterLower])
        XCTAssertEqual(
            reading(result, .questionnaire).direction,
            .improving,
            "分数下降应读为好转；按分数排序会误判成上升"
        )
    }

    /// 「处置强度看最高档」与「描述当前状态看最近一次」是两个不同的东西。
    ///
    /// 当历史上有更严重的一次、最近这次已经回落时：
    /// - 处置强度仍按最高档（安全兜底，不该因最近好转就抹掉曾有的严重程度）；
    /// - 但文案必须**显式说明**「之前有过更重的一次」，
    ///   否则用户会看到「已经回落到轻度」+「中重度，建议专业支持」这种自相矛盾。
    func testSeverityNoteAppearsWhenWorstAssessmentIsNotLatest() {
        // 30 天前那次很重（总分 22 → 中重度），今天这次很轻（总分 2 → 无明显症状）
        let oldSevere = scale(total: 22, daysAgo: 30)
        let recentMild = scale(total: 2, daysAgo: 0)

        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [recentMild, oldSevere],
                now: now,
                calendar: calendar
            )
        )

        XCTAssertTrue(
            insight.headline.contains("之前有过一次分数更高"),
            "最高档与最近一次不同时必须说明，实际：\(insight.headline)"
        )
        // 处置强度仍按最高档（安全兜底）。
        XCTAssertEqual(insight.supportLevel, .professional,
                       "曾达到中重度时不该因为最近好转就降低处置强度")
    }

    /// 只有一次评估时不应出现「之前有过一次」的说明。
    func testNoSeverityNoteWhenOnlyOneAssessment() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [scale(total: 13, daysAgo: 0)],
                now: now,
                calendar: calendar
            )
        )
        XCTAssertFalse(insight.headline.contains("之前有过一次分数更高"),
                       "只有一次评估时不该出现历史说明")
    }
}
