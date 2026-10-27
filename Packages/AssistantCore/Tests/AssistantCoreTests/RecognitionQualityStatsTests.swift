import XCTest
@testable import AssistantCore

final class RecognitionQualityStatsTests: XCTestCase {

    private func feedback(
        label: String,
        verdict: JudgmentFeedback.Verdict,
        top: Double = 0.8,
        margin: Double = 0.3,
        runnerUp: String? = nil,
        corrected: String? = nil
    ) -> JudgmentFeedback {
        JudgmentFeedback(
            inputText: "样本-\(label)-\(verdict.rawValue)-\(UUID().uuidString.prefix(4))",
            labelRaw: label,
            verdict: verdict,
            topProbability: top,
            margin: margin,
            runnerUpLabelRaw: runnerUp,
            correctedLabelRaw: corrected
        )
    }

    // MARK: - 命中率

    func testEmptyReportHasNilAccuracy() {
        let report = RecognitionQualityStats.report(from: [])
        XCTAssertNil(report.accuracy, "无样本时命中率必须是 nil，不能伪造 100%")
        XCTAssertEqual(report.sampleCount, 0)
        XCTAssertEqual(report.pendingCalibrationCount, 0)
        XCTAssertTrue(report.confusionPairs.isEmpty)
    }

    func testAccuracyIsUpOverTotal() {
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "todoCreate", verdict: .up),
            feedback(label: "todoCreate", verdict: .up),
            feedback(label: "expenseCreate", verdict: .down),
            feedback(label: "expenseCreate", verdict: .up)
        ])
        XCTAssertEqual(report.sampleCount, 4)
        XCTAssertEqual(report.upCount, 3)
        XCTAssertEqual(report.downCount, 1)
        XCTAssertEqual(report.accuracy ?? 0, 0.75, accuracy: 0.0001)
    }

    func testPendingCalibrationCountsOnlySnapshottedSamples() {
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "todoCreate", verdict: .up, top: 0.9),
            feedback(label: "todoCreate", verdict: .down, top: 0),      // 无快照
            feedback(label: "expenseCreate", verdict: .down, top: 0.4)
        ])
        XCTAssertEqual(report.sampleCount, 3)
        XCTAssertEqual(report.pendingCalibrationCount, 2)
    }

    // MARK: - 标签表现

    func testLabelPerformanceSortedByDownRateDescending() {
        let report = RecognitionQualityStats.report(from: [
            // A: 1/4 点踩
            feedback(label: "labelA", verdict: .up),
            feedback(label: "labelA", verdict: .up),
            feedback(label: "labelA", verdict: .up),
            feedback(label: "labelA", verdict: .down),
            // B: 2/2 点踩
            feedback(label: "labelB", verdict: .down),
            feedback(label: "labelB", verdict: .down),
            // C: 0/1 点踩
            feedback(label: "labelC", verdict: .up)
        ])
        let names = report.labelPerformance.map(\.labelRaw)
        XCTAssertEqual(names, ["labelB", "labelA", "labelC"], "点踩率高（薄弱）的标签排在前")
        XCTAssertEqual(report.labelPerformance.first?.downRate ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(report.labelPerformance.last?.downRate ?? 1, 0.0, accuracy: 0.0001)
    }

    func testLabelPerformanceTieBreaksOnTotalThenName() {
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "bbb", verdict: .down),
            feedback(label: "aaa", verdict: .down),
            feedback(label: "ccc", verdict: .up),
            feedback(label: "ccc", verdict: .down)
        ])
        // downRate: aaa/bbb=1.0, ccc=0.5 → aaa、bbb 在前；同率按样本数（各 1）→ 按名字典序
        XCTAssertEqual(report.labelPerformance.map(\.labelRaw), ["aaa", "bbb", "ccc"])
    }

    // MARK: - 混淆标签对

    func testConfirmedConfusionPairFromCorrection() {
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "expenseCreate", verdict: .down, runnerUp: "memoInbox", corrected: "todoCreate"),
            feedback(label: "expenseCreate", verdict: .down, runnerUp: "memoInbox", corrected: "todoCreate"),
            feedback(label: "expenseCreate", verdict: .down, runnerUp: "memoInbox", corrected: "memoInbox")
        ])
        let pairs = report.confusionPairs
        XCTAssertEqual(pairs.count, 2)
        // 实锤在前：expenseCreate→todoCreate ×2
        XCTAssertEqual(pairs[0].fromLabelRaw, "expenseCreate")
        XCTAssertEqual(pairs[0].toLabelRaw, "todoCreate")
        XCTAssertEqual(pairs[0].count, 2)
        XCTAssertTrue(pairs[0].isConfirmed)
        XCTAssertEqual(pairs[1].toLabelRaw, "memoInbox")
        XCTAssertTrue(pairs[1].isConfirmed)
    }

    func testSuspectedPairFromRunnerUpWhenNoCorrection() {
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "todoCreate", verdict: .down, runnerUp: "checkinCreate")
        ])
        XCTAssertEqual(report.confusionPairs.count, 1)
        let pair = report.confusionPairs[0]
        XCTAssertEqual(pair.fromLabelRaw, "todoCreate")
        XCTAssertEqual(pair.toLabelRaw, "checkinCreate")
        XCTAssertFalse(pair.isConfirmed, "无用户纠正时只能是疑似混淆")
    }

    func testCorrectionOverridesRunnerUp() {
        // 既有 corrected 又有 runnerUp：以 corrected（实锤）为准，不重复计疑似
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "todoCreate", verdict: .down, runnerUp: "memoInbox", corrected: "expenseCreate")
        ])
        XCTAssertEqual(report.confusionPairs.count, 1)
        XCTAssertEqual(report.confusionPairs[0].toLabelRaw, "expenseCreate")
        XCTAssertTrue(report.confusionPairs[0].isConfirmed)
    }

    func testUpFeedbackProducesNoConfusionPair() {
        // 点赞即便带 runnerUp 也不算混淆——判对了没有「判错」可言
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "todoCreate", verdict: .up, runnerUp: "memoInbox")
        ])
        XCTAssertTrue(report.confusionPairs.isEmpty)
    }

    func testSelfCorrectionIsNotConfusion() {
        // corrected == labelRaw：用户确认了原标签（反悔点踩），不是混淆
        let report = RecognitionQualityStats.report(from: [
            feedback(label: "todoCreate", verdict: .down, corrected: "todoCreate")
        ])
        XCTAssertTrue(report.confusionPairs.isEmpty)
    }

    func testConfirmedPairsSortedBeforeSuspected() {
        let report = RecognitionQualityStats.report(from: [
            // 疑似 ×3
            feedback(label: "a", verdict: .down, runnerUp: "x"),
            feedback(label: "a", verdict: .down, runnerUp: "x"),
            feedback(label: "a", verdict: .down, runnerUp: "x"),
            // 实锤 ×1
            feedback(label: "b", verdict: .down, corrected: "y")
        ])
        XCTAssertEqual(report.confusionPairs.count, 2)
        XCTAssertTrue(report.confusionPairs[0].isConfirmed, "实锤对排在疑似对之前")
        XCTAssertEqual(report.confusionPairs[0].fromLabelRaw, "b")
        XCTAssertFalse(report.confusionPairs[1].isConfirmed)
    }

    func testEmptyLabelRawIsIgnored() {
        let report = RecognitionQualityStats.report(from: [
            JudgmentFeedback(inputText: "空标签", labelRaw: "", verdict: .down, topProbability: 0.5)
        ])
        XCTAssertTrue(report.labelPerformance.isEmpty)
        XCTAssertTrue(report.confusionPairs.isEmpty)
        XCTAssertEqual(report.downCount, 1)
    }

    // MARK: - 确定性

    func testReportIsDeterministic() {
        let samples = (0..<12).map { i -> JudgmentFeedback in
            feedback(
                label: i % 2 == 0 ? "even" : "odd",
                verdict: i % 3 == 0 ? .down : .up,
                runnerUp: i % 3 == 0 ? "other" : nil
            )
        }
        let a = RecognitionQualityStats.report(from: samples)
        let b = RecognitionQualityStats.report(from: samples)
        XCTAssertEqual(a, b, "同输入必须同输出（Equatable 全字段比对）")
    }
}
