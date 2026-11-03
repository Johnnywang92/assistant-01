import AssistantCore
import XCTest

/// 双通道交叉解读的回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **数据不足时给出「你可能有点问题」的猜测**——无依据的解读比不给解读更糟。
/// 2. **只给一个主动作的纪律被破坏**——结果页并列五六个建议，选择成本会高到用户干脆不做。
/// 3. **monitor 档仍然推送干预**——低分用户被反复提醒，会把「被提醒」当成「有问题」。
/// 4. **生理通道无数据时被当成「身体正常」**——读不到必须归入缺失，不能拿来当安慰。
/// 5. **专业档位给出轻量自助建议当主动作**——把该做的严肃事替换成了安慰。
final class MentalHealthInsightBuilderTests: XCTestCase {

    // MARK: - 辅助

    private func score(
        _ scale: PsychScaleDefinition,
        _ values: [Int: Int]
    ) -> PsychScaleScore {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in scale.items {
            if let v = values[item.index] {
                answers[item.index] = .answered(score: v)
            } else {
                answers[item.index] = .unanswered
            }
        }
        return PsychScaleScorer.score(answers: answers, definition: scale)
    }

    /// 构造一个指定总分与「安全题得 0 分」的 PHQ-9 结果。
    private func phq9(total: Int, safetyScore: Int = 0) -> PsychScaleScore {
        var answers: [Int: PsychItemAnswer] = [:]
        var remaining = total
        for item in PsychScaleCatalog.phq9.items {
            if item.index == 9 {
                answers[item.index] = .answered(score: safetyScore)
                continue
            }
            let v = min(3, remaining)
            answers[item.index] = .answered(score: v)
            remaining -= v
        }
        return PsychScaleScorer.score(answers: answers, definition: PsychScaleCatalog.phq9)
    }

    private func gad7(total: Int) -> PsychScaleScore {
        var answers: [Int: PsychItemAnswer] = [:]
        var remaining = total
        for item in PsychScaleCatalog.gad7.items {
            let v = min(3, remaining)
            answers[item.index] = .answered(score: v)
            remaining -= v
        }
        return PsychScaleScorer.score(answers: answers, definition: PsychScaleCatalog.gad7)
    }

    private func physiology(stress: Int, sleep: Double = 7.5) -> PleasureIndexEvaluation {
        PleasureIndexEvaluation(
            pleasureScore: 100 - stress,
            state: stress >= 60 ? .strained : .serene,
            stressScore: stress,
            stressLevel: stress >= 76 ? .high : (stress >= 51 ? .elevated : (stress >= 26 ? .moderate : .low)),
            autonomicScore: 100 - stress,
            autonomicBalance: stress >= 60 ? .sympatheticDominant : .balanced,
            sleepRecoveryScore: Int(sleep * 10),
            summary: "测试用",
            advice: "测试用",
            details: []
        )
    }

    // MARK: - 数据状态

    /// 核心风险 1：一题没答 → noData，不给分、不给分档、不给建议。
    func testNoDataProducesNoScoreAndNoAction() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [])
        )
        XCTAssertEqual(insight.dataStatus, .noData)
        XCTAssertNil(insight.topScore)
        XCTAssertNil(insight.band)
        XCTAssertNil(insight.primaryAction, "无数据时不得给出行动建议")
        XCTAssertFalse(insight.recommendsProfessionalCare)
    }

    /// 核心风险 1：答了但缺 2 题以上 → incomplete，与 noData 是不同状态。
    func testIncompleteDataIsDistinctFromNoData() {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answers[item.index] = item.index <= 3 ? .answered(score: 3) : .unanswered
        }
        let incomplete = PsychScaleScorer.score(answers: answers, definition: PsychScaleCatalog.phq9)
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [incomplete])
        )
        XCTAssertEqual(insight.dataStatus, .incomplete)
        XCTAssertNil(insight.band)
        XCTAssertNil(insight.primaryAction)
    }

    // MARK: - 分档到干预

    /// 核心风险 3：低分档（monitor）不得给出任何行动建议。
    ///
    /// 注意这里断言的是 `PsychBandLevel.none`（**确知**无明显症状），
    /// 而不是 `nil`（无法判定）——两者语义不同，不能混用 `.none` 简写。
    func testMonitorBandGivesNoAction() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 2)])
        )
        XCTAssertEqual(insight.band, PsychBandLevel.none)
        XCTAssertEqual(insight.supportLevel, .monitor)
        XCTAssertNil(insight.primaryAction, "低分档只记录不打扰——推送会让用户把「被提醒」当成「有问题」")
        XCTAssertTrue(insight.secondaryActions.isEmpty)
    }

    /// 「确知无明显症状」与「无法判定」必须能被区分开。
    /// 前者 band 有值但强度为 monitor，后者 band 为 nil。
    func testNoSymptomsIsDistinctFromUndeterminable() {
        let lowScore = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 2)])
        )
        let noData = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [])
        )
        XCTAssertEqual(lowScore.dataStatus, .ready)
        XCTAssertNotNil(lowScore.band, "确知无明显症状时分档有值")
        XCTAssertEqual(noData.dataStatus, .noData)
        XCTAssertNil(noData.band, "无法判定时分档必须为 nil，不能伪装成「无明显症状」")
    }

    /// 核心风险 2：结果页只给**一个**主动作。
    func testExactlyOnePrimaryActionIsGiven() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 12)])
        )
        XCTAssertNotNil(insight.primaryAction)
        XCTAssertFalse(insight.secondaryActions.contains(insight.primaryAction!),
                       "主动作不得同时出现在备选里")
    }

    /// 核心风险 5：专业档位的主动作必须是「联系专业支持」，
    /// 不能是呼吸练习这类轻量安慰。
    func testProfessionalBandPrioritizesProfessionalCare() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 22)])
        )
        XCTAssertEqual(insight.band, PsychBandLevel.severe)
        XCTAssertEqual(insight.supportLevel, .professional)
        XCTAssertEqual(insight.primaryAction, .professionalCare)
        XCTAssertTrue(insight.recommendsProfessionalCare)
    }

    /// 核心风险 5 续：即使生理数据很差，专业档位也不该被降级成自助建议。
    func testProfessionalBandNotDowngradedByPhysiology() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 18)],
                physiology: physiology(stress: 90)
            )
        )
        XCTAssertEqual(insight.primaryAction, .professionalCare)
    }

    /// 轻度困扰应落在自助档，且给出可执行动作。
    func testMildBandGivesSelfCareAction() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 8)])
        )
        XCTAssertEqual(insight.band, PsychBandLevel.mild)
        XCTAssertEqual(insight.supportLevel, .selfCare)
        XCTAssertNotNil(insight.primaryAction)
        XCTAssertFalse(insight.recommendsProfessionalCare)
    }

    // MARK: - 双通道交叉

    /// 双通道同向时，解读应指出两者指向同一件事。
    func testConcordantChannelsAreMentionedTogether() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 13)],
                physiology: physiology(stress: 75)
            )
        )
        XCTAssertTrue(
            insight.headline.contains("指向同一件事"),
            "问卷与生理同向时应点出这层关系，实际文案：\(insight.headline)"
        )
    }

    /// 双通道背离（问卷困扰但生理平稳）时，解读应指出「身体指标平稳但困扰是真实的」，
    /// 而不是反过来拿生理数据否定问卷。
    func testDiscordantChannelsDoNotDismissQuestionnaire() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 13)],
                physiology: physiology(stress: 20)
            )
        )
        XCTAssertTrue(
            insight.headline.contains("值得被认真对待"),
            "不得用生理数据否定问卷感受，实际文案：\(insight.headline)"
        )
    }

    /// 核心风险 4：生理通道无数据时，文案**不得**出现「身体指标看起来还算平稳」。
    func testMissingPhysiologyIsNotPresentedAsNormal() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 13)],
                physiology: nil
            )
        )
        XCTAssertFalse(insight.headline.contains("身体指标"))
        XCTAssertFalse(insight.headline.contains("可接受的范围内"),
                       "没有生理数据时不能暗示「一切正常」——读不到就是读不到")
    }

    /// 睡眠不足时应优先给出「提早上床」而不是通用走动。
    func testShortSleepPrioritizesSleepAction() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 9)],
                recentAverageSleepHours: 5.5
            )
        )
        XCTAssertEqual(insight.primaryAction, .sleepEarlier)
    }

    /// 生理压力高但睡眠正常时，应给出呼吸类动作。
    func testHighPhysiologicalStressPrioritizesBreathing() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 9)],
                physiology: physiology(stress: 70),
                recentAverageSleepHours: 7.5
            )
        )
        XCTAssertEqual(insight.primaryAction, .breathing)
    }

    // MARK: - 危机

    /// 危机信号必须穿透到解读结果，且不被分档稀释。
    func testCrisisSignalSurvivesIntoInsight() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 1, safetyScore: 1)])
        )
        XCTAssertEqual(insight.safetySignal, .selfHarmIdeation)
        XCTAssertTrue(insight.requiresCrisisResponse)
        XCTAssertFalse(insight.crisisResources.isEmpty, "危机响应必须带出求助资源")
    }

    /// 危机信号存在时，即使分档是中档，也必须给出危机资源。
    func testCrisisResourcesPresentEvenWithMildBand() {
        var answers: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answers[item.index] = .answered(score: item.index == 9 ? 1 : 0)
        }
        let score = PsychScaleScorer.score(answers: answers, definition: PsychScaleCatalog.phq9)
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [score])
        )
        XCTAssertTrue(insight.requiresCrisisResponse)
        XCTAssertTrue(insight.crisisResources.contains { $0.phoneNumber == "12356" })
    }

    /// 无危机信号时不得带出危机资源（避免平时就渲染求助板块）。
    func testNoCrisisResourcesWithoutSignal() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(questionnaireScores: [phq9(total: 3)])
        )
        XCTAssertEqual(insight.safetySignal, .none)
        XCTAssertTrue(insight.crisisResources.isEmpty)
    }

    // MARK: - 多量表

    /// 两张量表都作答时，取处置强度更高的一张。
    func testMultipleScalesTakeHighestSupportLevel() {
        let insight = MentalHealthInsightBuilder.build(
            from: MentalHealthInsightInput(
                questionnaireScores: [phq9(total: 4), gad7(total: 18)]
            )
        )
        XCTAssertEqual(insight.supportLevel, .professional)
        XCTAssertEqual(insight.topScaleID, .gad7)
    }
}
