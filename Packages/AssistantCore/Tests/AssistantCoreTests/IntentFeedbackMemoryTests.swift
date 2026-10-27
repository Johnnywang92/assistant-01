import XCTest
@testable import AssistantCore

final class IntentFeedbackMemoryTests: XCTestCase {

    private func feedback(
        _ text: String,
        label: OmniboxIntentLabel,
        verdict: JudgmentFeedback.Verdict,
        at date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> JudgmentFeedback {
        JudgmentFeedback(
            inputText: IntentFeedbackMemory.normalize(text),
            labelRaw: label.rawValue,
            verdict: verdict,
            topProbability: 0.62,
            margin: 0.11,
            createdAt: date
        )
    }

    // MARK: 归一化

    func testNormalizeCollapsesWhitespaceAndPunctuation() {
        // 标点与空白全部剔除：同句不同写法必须归到同一个键
        XCTAssertEqual(IntentFeedbackMemory.normalize("  完成 晨跑  "), "完成晨跑")
        XCTAssertEqual(
            IntentFeedbackMemory.normalize("把那笔账改成30。"),
            IntentFeedbackMemory.normalize("把那笔账改成30.")
        )
        XCTAssertEqual(
            IntentFeedbackMemory.normalize("把账改成30，顺便喝水"),
            IntentFeedbackMemory.normalize("把账改成30 顺便喝水")
        )
    }

    // MARK: 点踩 → 争议输入

    func testDownVerdictMarksInputDisputed() {
        let memory = IntentFeedbackMemory(records: [feedback("取消明天的会", label: .todoCancel, verdict: .down)])
        XCTAssertTrue(memory.isDisputed("取消明天的会"))
        // 归一化等价输入同样命中
        XCTAssertTrue(memory.isDisputed("  取消明天的会。"))
        XCTAssertFalse(memory.isDisputed("取消后天的会"))
    }

    func testDisputedIsResolvedByLatestVerdict() {
        let memory = IntentFeedbackMemory(records: [
            feedback("取消明天的会", label: .todoCancel, verdict: .down, at: Date(timeIntervalSince1970: 1_000)),
            feedback("取消明天的会", label: .todoCancel, verdict: .up, at: Date(timeIntervalSince1970: 2_000))
        ])
        // 最近一次是点赞 → 不再算争议；且给出标签
        XCTAssertFalse(memory.isDisputed("取消明天的会"))
        XCTAssertEqual(memory.endorsedLabel(for: "取消明天的会"), .todoCancel)
    }

    func testLatestDownShadowsEarlierUp() {
        let memory = IntentFeedbackMemory(records: [
            feedback("取消明天的会", label: .todoCancel, verdict: .up, at: Date(timeIntervalSince1970: 1_000)),
            feedback("取消明天的会", label: .todoCancel, verdict: .down, at: Date(timeIntervalSince1970: 2_000))
        ])
        XCTAssertTrue(memory.isDisputed("取消明天的会"))
        XCTAssertNil(memory.endorsedLabel(for: "取消明天的会"))
    }

    // MARK: 点赞 → 优先预填

    func testUpVerdictEndorsesLabel() {
        let memory = IntentFeedbackMemory(records: [feedback("喝了500ml水", label: .waterRecord, verdict: .up)])
        XCTAssertEqual(memory.endorsedLabel(for: "喝了500ml水"), .waterRecord)
        XCTAssertFalse(memory.isDisputed("喝了500ml水"))
    }

    func testEndorsedLabelRequiresUpVerdict() {
        let memory = IntentFeedbackMemory(records: [feedback("喝了500ml水", label: .waterRecord, verdict: .down)])
        XCTAssertNil(memory.endorsedLabel(for: "喝了500ml水"))
    }

    func testNoFeedbackMeansNeutral() {
        let memory = IntentFeedbackMemory()
        XCTAssertFalse(memory.isDisputed("任意输入"))
        XCTAssertNil(memory.endorsedLabel(for: "任意输入"))
        XCTAssertNil(memory.latestFeedback(for: "任意输入"))
    }

    // MARK: 被点赞标签提升到分布首位（只换顺序，不改概率）

    private func makeDistribution() -> IntentDistribution {
        IntentDistribution(ranked: [
            IntentScore(label: .expenseCreate, probability: 0.55),
            IntentScore(label: .waterRecord, probability: 0.30),
            IntentScore(label: .todoCreate, probability: 0.15)
        ], policy: .default)
    }

    func testPromotedMovesEndorsedLabelToFrontWithoutChangingProbabilities() {
        let memory = IntentFeedbackMemory(records: [feedback("喝了500ml水", label: .waterRecord, verdict: .up)])
        let promoted = memory.promoted(makeDistribution(), for: "喝了500ml水")
        XCTAssertEqual(promoted.top, .waterRecord)
        // 概率原样保留——留给阈值校准做语料
        XCTAssertEqual(promoted.probability(of: .waterRecord), 0.30)
        XCTAssertEqual(promoted.probability(of: .expenseCreate), 0.55)
        XCTAssertEqual(promoted.ranked.map(\.label), [.waterRecord, .expenseCreate, .todoCreate])
    }

    func testPromotedIsNoOpWithoutEndorsement() {
        let memory = IntentFeedbackMemory(records: [feedback("喝了500ml水", label: .waterRecord, verdict: .down)])
        let base = makeDistribution()
        XCTAssertEqual(memory.promoted(base, for: "喝了500ml水"), base)
    }

    func testPromotedIsNoOpWhenEndorsedLabelAlreadyTop() {
        let memory = IntentFeedbackMemory(records: [feedback("打车30元", label: .expenseCreate, verdict: .up)])
        let base = makeDistribution()
        XCTAssertEqual(memory.promoted(base, for: "打车30元"), base)
    }

    // MARK: 快照字段用于阈值校准语料

    func testFeedbackSnapshotsProbabilityAndMargin() {
        let record = feedback("测试输入", label: .memoInbox, verdict: .up)
        XCTAssertEqual(record.topProbability, 0.62)
        XCTAssertEqual(record.margin, 0.11)
        XCTAssertEqual(record.label, .memoInbox)
    }
}
