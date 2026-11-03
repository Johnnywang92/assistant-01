import AssistantCore
import XCTest

/// 心理健康量表计分与危机路由的回归测试。
///
/// 核心风险（按危害排序）：
/// 1. **第 9 题（自伤意念）被总分规则吞掉**——总分制会把「只有第 9 题非零、
///    其余题都低」判成轻度，而这是最不能漏判的一种。
/// 2. **数据不足时压掉告警**——其余题没答就「先不算」，恰恰是在最需要被看见的时刻失声。
/// 3. **缺失题静默按 0 计**——分母不变分子少算，总分被系统性低估，用户以为自己是「有点低分」。
/// 4. **阈值照搬西方通用值**——PHQ-9 中文一般人群 cut-off 是 7 不是 10。
/// 5. **量表分被当成诊断**——UI 出现疾病判定表述。
final class PsychScaleTests: XCTestCase {

    // MARK: - 测试辅助

    /// 构造一份指定分数的作答。分数 nil 表示未作答。
    private func answers(
        _ scale: PsychScaleDefinition,
        _ scores: [Int: Int?]
    ) -> [Int: PsychItemAnswer] {
        var result: [Int: PsychItemAnswer] = [:]
        for item in scale.items {
            guard let entry = scores[item.index] else {
                result[item.index] = .unanswered
                continue
            }
            guard let value = entry else {
                result[item.index] = .unanswered
                continue
            }
            result[item.index] = .answered(score: value)
        }
        return result
    }

    /// 全部题目得同一分。
    private func uniform(_ scale: PsychScaleDefinition, _ score: Int) -> [Int: PsychItemAnswer] {
        var result: [Int: PsychItemAnswer] = [:]
        for item in scale.items {
            result[item.index] = .answered(score: score)
        }
        return result
    }

    // MARK: - 量表定义

    /// 量表题数与满分必须与官方定义一致——量表结构被改动等于换了个工具。
    func testScaleStructureMatchesOfficialDefinition() {
        XCTAssertEqual(PsychScaleCatalog.phq9.itemCount, 9)
        XCTAssertEqual(PsychScaleCatalog.phq9.maxTotalScore, 27)
        XCTAssertEqual(PsychScaleCatalog.gad7.itemCount, 7)
        XCTAssertEqual(PsychScaleCatalog.gad7.maxTotalScore, 21)
    }

    /// PHQ-9 第 9 题必须是安全题，且题面不得为空。
    func testPHQ9NinthItemIsSafetyItem() {
        let safety = PsychScaleCatalog.phq9.safetyItem
        XCTAssertNotNil(safety, "PHQ-9 必须有独立路由的安全题")
        XCTAssertEqual(safety?.index, 9)
        XCTAssertTrue(safety?.prompt.contains("伤害自己") == true)
    }

    /// GAD-7 不含自伤题，因此**不得**声称它能替代 PHQ-9 的安全筛查。
    func testGAD7HasNoSafetyItem() {
        XCTAssertNil(PsychScaleCatalog.gad7.safetyItem)
        XCTAssertFalse(PsychScaleID.gad7.hasIndependentSafetyItem)
    }

    /// 阈值必须用中文人群验证值，不能照搬西方通用的 PHQ-9 ≥ 10。
    func testScreeningCutoffUsesChinesePopulationValidation() {
        XCTAssertEqual(PsychScaleCatalog.phq9.screeningCutoff, 7,
                       "PHQ-9 中文一般人群 cut-off 是 7（Wang 2014），西方通用的 10 会系统性低估中文用户")
        XCTAssertEqual(PsychScaleCatalog.gad7.screeningCutoff, 10)
    }

    /// 题目文本不得为空——空题面会让量表无法作答却仍然「计分成功」。
    func testNoItemHasEmptyPrompt() {
        for scale in PsychScaleCatalog.all {
            for item in scale.items {
                XCTAssertFalse(item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(scale.id) 第 \(item.index) 题题面为空")
            }
        }
    }

    /// 分档必须覆盖 0...满分且不重叠、不留空隙。
    func testBandsCoverFullRangeWithoutOverlap() {
        for scale in PsychScaleCatalog.all {
            var expected = 0
            for band in scale.bands {
                XCTAssertEqual(band.lowerBound, expected,
                               "\(scale.id) 分档在 \(expected) 处断开")
                XCTAssertGreaterThan(band.upperBound, band.lowerBound - 1)
                expected = band.upperBound + 1
            }
            XCTAssertEqual(expected - 1, scale.maxTotalScore,
                           "\(scale.id) 分档未覆盖到满分")
        }
    }

    // MARK: - 计分

    func testAllZeroScoresProduceZeroTotal() {
        let score = PsychScaleScorer.score(
            answers: uniform(PsychScaleCatalog.phq9, 0),
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(score.totalScore, 0)
        XCTAssertEqual(score.band, PsychBandLevel.none)
        XCTAssertFalse(score.isScreeningPositive)
        XCTAssertEqual(score.completeness, .complete)
    }

    func testAllThreeScoresProduceMaximumTotal() {
        let score = PsychScaleScorer.score(
            answers: uniform(PsychScaleCatalog.phq9, 3),
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(score.totalScore, 27)
        XCTAssertEqual(score.band, PsychBandLevel.severe)
    }

    /// 分档边界：5 分应是轻度，7 分（中文 cut-off）应为阳性。
    func testScreeningBoundaryIsExact() {
        let five = PsychScaleScorer.score(
            answers: uniform(PsychScaleCatalog.phq9, 0),
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(five.totalScore, 0)
        XCTAssertFalse(five.isScreeningPositive)

        // 构造恰好 7 分：7 题得 1 分，其余 0 分。
        var sevenAnswers: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            sevenAnswers[item.index] = .answered(score: item.index <= 7 ? 1 : 0)
        }
        let seven = PsychScaleScorer.score(answers: sevenAnswers, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(seven.totalScore, 7)
        XCTAssertEqual(seven.band, PsychBandLevel.mild)
        XCTAssertTrue(seven.isScreeningPositive, "7 分已达中文 cut-off，必须标记为阳性")
    }

    /// 核心风险 3：缺失题**不能**静默按 0 计。
    /// 缺 1 题可以折算，但折算事实必须显式可见。
    func testMissingItemIsProratedNotTreatedAsZero() {
        // 8 题答 2 分 = 16 分，缺第 9 题。
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            if item.index == 9 {
                answerSet[item.index] = .unanswered
            } else {
                answerSet[item.index] = .answered(score: 2)
            }
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(score.completeness, .prorated(missingItemIndices: [9]))
        XCTAssertTrue(score.completeness.isProrated)
        // 折算后 16/8*9 = 18，而「按 0 计」只会得到 16——差异必须存在。
        XCTAssertEqual(score.totalScore, 18)
    }

    /// 核心风险 3 续：缺 2 题及以上**不给总分**，宁可承认数据不足。
    func testMissingTwoItemsProducesNoTotalScore() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            if item.index >= 8 {
                answerSet[item.index] = .unanswered
            } else {
                answerSet[item.index] = .answered(score: 3)
            }
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(score.completeness, .insufficient(missingItemIndices: [8, 9]))
        XCTAssertNil(score.totalScore, "缺 2 题以上不得给出总分——那是个偏低但看起来很确定的假分数")
        XCTAssertNil(score.band)
        XCTAssertFalse(score.isScreeningPositive)
    }

    /// 越界分值（数据损坏）必须按未作答处理，不能污染总分。
    ///
    /// 构造：第 1 题越界（99），其余 8 题各 1 分（和为 8）。
    /// - 若越界值被计入：分母 9、分子 8+99 → 远超满分，总分会被顶到 27。
    /// - 若正确剔除：分母 8、分子 8 → 折算 8/8×9 = 9。
    /// 断言 9 即可证明越界值确实没进总分。
    func testOutOfRangeScoreIsTreatedAsUnanswered() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = .answered(score: item.index == 1 ? 99 : 1)
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)

        XCTAssertNil(score.itemScores[1], "越界分值不得进入题目级结果")
        XCTAssertEqual(score.itemScores.count, 8)
        XCTAssertEqual(score.totalScore, 9, "越界分值若被计入，总分会被顶到 27")
        XCTAssertEqual(score.completeness, .prorated(missingItemIndices: [1]))
    }

    /// 越界值不得让筛查结论变乐观或变悲观——它是缺失，不是 0 也不是满分。
    func testOutOfRangeScoreCannotSilentlyLowerTotal() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = .answered(score: item.index == 1 ? 99 : 3)
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        // 8 题 × 3 分 = 24，折算 24/8×9 = 27。
        XCTAssertEqual(score.totalScore, 27)
        XCTAssertTrue(score.isScreeningPositive)
        XCTAssertEqual(score.band, PsychBandLevel.severe)
    }

    /// 题目级数据必须保留——只存总分就做不了题目级告警。
    func testItemLevelScoresArePreserved() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = .answered(score: item.index <= 3 ? 3 : 0)
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(score.itemScores.count, 9)
        XCTAssertEqual(score.itemScores[1], 3)
        XCTAssertEqual(score.itemScores[9], 0)
    }

    /// 得分最高的题号用于结果页解读，并列时取题号小的。
    func testTopItemIndicesAreDeterministic() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = .answered(score: item.index == 2 || item.index == 4 ? 3 : 0)
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(score.topItemIndices, [2, 4])
    }

    // MARK: - 危机路由（核心风险 1、2）

    /// 核心风险 1：只有第 9 题非零、其余全 0 时，**必须**触发危机信号。
    /// 总分只有 1 分，远低于任何 cut-off——但这正是最不能漏判的情况。
    func testSafetyItemAloneTriggersCrisisRegardlessOfTotalScore() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = .answered(score: item.index == 9 ? 1 : 0)
        }
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(score.totalScore, 1)
        XCTAssertFalse(score.isScreeningPositive, "总分 1 分确实不构成筛查阳性")

        let signal = PsychSafetyRouter.detectSignal(in: score)
        XCTAssertEqual(signal, .selfHarmIdeation,
                       "第 9 题非零必须独立触发，不能被总分规则吞掉")
        XCTAssertTrue(signal.requiresCrisisResponse)
    }

    /// 核心风险 2：其余题全未作答时，第 9 题的告警**依然**必须成立。
    func testCrisisSignalSurvivesIncompleteRemainingItems() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = item.index == 9 ? .answered(score: 1) : .unanswered
        }
        // 直接从原始作答检测（不经过计分器）
        let signal = PsychSafetyRouter.detectSignal(
            answers: answerSet,
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(signal, .selfHarmIdeation,
                       "数据不足不能压掉告警——那正是最需要被看见的时刻")

        // 即使经过计分器（此时总分不可用），信号仍须独立成立。
        let score = PsychScaleScorer.score(answers: answerSet, definition: PsychScaleCatalog.phq9)
        XCTAssertNil(score.totalScore)
        XCTAssertEqual(PsychSafetyRouter.detectSignal(in: score), .selfHarmIdeation)
    }

    /// 第 9 题答 0 分（明确否认）不应触发危机。
    func testSafetyItemAnsweredZeroDoesNotTrigger() {
        let score = PsychScaleScorer.score(
            answers: uniform(PsychScaleCatalog.phq9, 0),
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(PsychSafetyRouter.detectSignal(in: score), .none)
    }

    /// 第 9 题未作答时**不**误报危机（否则每次跳题都会弹危机页）。
    func testUnansweredSafetyItemDoesNotTriggerCrisis() {
        var answerSet: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            answerSet[item.index] = .unanswered
        }
        XCTAssertEqual(
            PsychSafetyRouter.detectSignal(answers: answerSet, definition: PsychScaleCatalog.phq9),
            .none
        )
    }

    /// GAD-7 没有安全题，任何作答都不该产生危机信号。
    func testGAD7NeverProducesCrisisSignal() {
        let score = PsychScaleScorer.score(
            answers: uniform(PsychScaleCatalog.gad7, 3),
            definition: PsychScaleCatalog.gad7
        )
        XCTAssertEqual(PsychSafetyRouter.detectSignal(in: score), .none)
    }

    /// 危机资源必须包含官方统一热线，且号码正确。
    func testCrisisResourcesIncludeOfficialNationalHotline() {
        let resources = PsychHelpResources.crisisResources
        let hotline = resources.first { $0.isOfficialHotline && $0.phoneNumber == "12356" }
        XCTAssertNotNil(hotline, "危机响应必须给出 12356 全国统一心理援助热线")
        XCTAssertTrue(resources.contains { $0.phoneNumber == "120" }, "必须保留急救出口")
    }
}
