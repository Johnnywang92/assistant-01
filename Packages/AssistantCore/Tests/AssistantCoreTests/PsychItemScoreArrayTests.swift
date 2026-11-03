import AssistantCore
import XCTest

/// 题目级分数数组 ↔ 作答字典转换的回归测试。
///
/// ## 为什么这个转换需要单独钉住
///
/// 它是**安全关键路径**：落库用题目级数组，读出用作答字典，
/// 而作答字典直接喂给 `PsychSafetyRouter`。
/// 转换出错 = 第 9 题的告警可能失效。
///
/// 而且这个转换原先写在 App 侧的 SwiftData 模型里——app target 没有测试 scheme，
/// 等于完全没有防线。下沉到 Core 后才有回归测试。
///
/// ## 核心风险
/// 1. **「未作答」与「答了 0 分」混淆**——0 是「完全不会」这个真实答案，
///    与「没答」语义完全不同，混淆会让总分被系统性低估。
/// 2. **往返不一致**——存进去再读出来必须一模一样。
/// 3. **数组长度与题目数不匹配**——量表题目数变化后旧数据会错位。
final class PsychItemScoreArrayTests: XCTestCase {

    // MARK: - 数组 → 作答字典

    /// 核心风险 1：`nil` 必须还原成「未作答」，不能变成 0 分。
    func testNilBecomesUnansweredNotZero() {
        let answers = PsychItemScoreArray.answers(from: [nil, nil, 0])
        XCTAssertEqual(answers[1], .unanswered)
        XCTAssertEqual(answers[2], .unanswered)
        XCTAssertEqual(answers[3], .answered(score: 0),
                       "0 是「完全不会」这个真实答案，不能与未作答混淆")
        XCTAssertNil(answers[1]?.score, "未作答不得有分数")
        XCTAssertEqual(answers[3]?.score, 0)
    }

    /// 越界分值按未作答处理，不得进入计分。
    func testNegativeScoreTreatedAsUnanswered() {
        let answers = PsychItemScoreArray.answers(from: [-1, 2])
        XCTAssertEqual(answers[1], .unanswered)
        XCTAssertEqual(answers[2], .answered(score: 2))
    }

    /// 空数组 → 空字典，不崩。
    func testEmptyArrayProducesEmptyAnswers() {
        XCTAssertTrue(PsychItemScoreArray.answers(from: []).isEmpty)
    }

    // MARK: - 作答字典 → 数组

    /// 数组长度固定为量表题目数，避免题目数变化后旧数据错位。
    func testItemScoresArrayIsAlignedToItemCount() {
        let answers: [Int: PsychItemAnswer] = [
            1: .answered(score: 2),
            5: .answered(score: 1)
        ]
        let scores = PsychItemScoreArray.itemScores(from: answers, itemCount: 9)
        XCTAssertEqual(scores.count, 9)
        XCTAssertEqual(scores[0], 2)
        XCTAssertEqual(scores[4], 1)
        XCTAssertNil(scores[2], "未作答的题必须占位为 nil，不能跳过（否则题号会错位）")
    }

    /// 越界题号不得写入数组。
    func testOutOfRangeIndexIsIgnored() {
        let answers: [Int: PsychItemAnswer] = [
            0: .answered(score: 3),
            99: .answered(score: 3)
        ]
        let scores = PsychItemScoreArray.itemScores(from: answers, itemCount: 3)
        XCTAssertEqual(scores.count, 3)
        XCTAssertTrue(scores.allSatisfy { $0 == nil })
    }

    // MARK: - 往返一致性（核心风险 2）

    /// 核心风险 2：存进去再读出来必须一模一样。
    func testRoundTripPreservesAnswers() {
        var original: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            if item.index == 9 {
                original[item.index] = .answered(score: 1)
            } else if item.index % 3 == 0 {
                original[item.index] = .unanswered
            } else {
                original[item.index] = .answered(score: item.index % 4)
            }
        }

        let scores = PsychItemScoreArray.itemScores(from: original, itemCount: 9)
        let restored = PsychItemScoreArray.answers(from: scores)

        XCTAssertEqual(restored.count, original.count)
        for (index, answer) in original {
            XCTAssertEqual(restored[index], answer, "第 \(index) 题往返后不一致")
        }
    }

    /// 往返后计分结果必须一致（这才是用户真正在意的）。
    func testRoundTripPreservesScore() {
        var original: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            original[item.index] = item.index <= 5 ? .answered(score: 3) : .unanswered
        }
        let direct = PsychScaleScorer.score(answers: original, definition: PsychScaleCatalog.phq9)
        let roundTripped = PsychScaleScorer.score(
            answers: PsychItemScoreArray.answers(
                from: PsychItemScoreArray.itemScores(from: original, itemCount: 9)
            ),
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(direct.totalScore, roundTripped.totalScore)
        XCTAssertEqual(direct.band, roundTripped.band)
        XCTAssertEqual(direct.completeness, roundTripped.completeness)
    }

    /// 核心风险 1 的极端版本：只有第 9 题有非零作答时，往返后危机信号必须依然成立。
    ///
    /// 这是整套逻辑里最不能出错的一格——
    /// 存进数据库再读出来，第 9 题的告警不能丢。
    func testRoundTripPreservesSafetySignal() {
        var original: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            original[item.index] = item.index == 9 ? .answered(score: 1) : .answered(score: 0)
        }
        let direct = PsychSafetyRouter.detectSignal(answers: original, definition: PsychScaleCatalog.phq9)
        XCTAssertEqual(direct, .selfHarmIdeation)

        let roundTripped = PsychSafetyRouter.detectSignal(
            answers: PsychItemScoreArray.answers(
                from: PsychItemScoreArray.itemScores(from: original, itemCount: 9)
            ),
            definition: PsychScaleCatalog.phq9
        )
        XCTAssertEqual(roundTripped, .selfHarmIdeation, "往返后第 9 题的告警不能丢")
    }

    /// 未作答的第 9 题往返后仍是未作答——不会被误判成「答了 0 分」而误报危机。
    func testRoundTripKeepsSkippedSafetyItemUnanswered() {
        var original: [Int: PsychItemAnswer] = [:]
        for item in PsychScaleCatalog.phq9.items {
            original[item.index] = item.index == 9 ? .unanswered : .answered(score: 0)
        }
        let roundTripped = PsychItemScoreArray.answers(
            from: PsychItemScoreArray.itemScores(from: original, itemCount: 9)
        )
        XCTAssertEqual(roundTripped[9], .unanswered)
        XCTAssertEqual(
            PsychSafetyRouter.detectSignal(answers: roundTripped, definition: PsychScaleCatalog.phq9),
            .none,
            "跳过的安全题不得被误判成危机信号"
        )
    }

    // MARK: - App 层实际调用形态

    /// App 侧 `PsychRecordStore.save` 的确切调用形态：
    /// 作答字典 → 题目级数组（长度对齐量表题数）。
    ///
    /// 这一条直接对应落库路径，确保「存进去的数组长度与量表题数一致」——
    /// 长度不对会让还原时题号整体错位。
    func testAppSavePathProducesCorrectlySizedArray() {
        let definition = PsychScaleCatalog.phq9
        var answers: [Int: PsychItemAnswer] = [:]
        for item in definition.items {
            answers[item.index] = item.index == 9 ? .answered(score: 1) : .answered(score: 0)
        }
        let itemScores = PsychItemScoreArray.itemScores(from: answers, itemCount: definition.itemCount)
        XCTAssertEqual(itemScores.count, definition.itemCount)
        XCTAssertEqual(itemScores[8], 1, "第 9 题必须落在下标 8")

        // 还原后危机信号仍成立——这是「存进去再读出来」最不能丢的一格。
        let restored = PsychItemScoreArray.answers(from: itemScores)
        XCTAssertEqual(
            PsychSafetyRouter.detectSignal(answers: restored, definition: definition),
            .selfHarmIdeation
        )
    }

    /// 落库时若作答字典缺少某些题，数组对应位置必须是 nil 而不是 0。
    func testAppSavePathKeepsMissingItemsAsNil() {
        let definition = PsychScaleCatalog.gad7
        var answers: [Int: PsychItemAnswer] = [:]
        answers[1] = .answered(score: 2)
        answers[3] = .answered(score: 2)
        let itemScores = PsychItemScoreArray.itemScores(from: answers, itemCount: definition.itemCount)
        XCTAssertEqual(itemScores.count, 7)
        XCTAssertEqual(itemScores[0], 2)
        XCTAssertNil(itemScores[1], "第 2 题未作答，必须是 nil")
        XCTAssertEqual(itemScores[2], 2)
        XCTAssertNil(itemScores[3])
        XCTAssertTrue(itemScores[4...].allSatisfy { $0 == nil })
    }
}
