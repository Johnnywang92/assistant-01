import XCTest
@testable import AssistantCore

final class IntentThresholdCalibratorTests: XCTestCase {

    /// 构造一条反馈样本
    private func sample(top: Double, margin: Double, verdict: JudgmentFeedback.Verdict) -> JudgmentFeedback {
        JudgmentFeedback(
            inputText: "样本\(top)-\(margin)-\(verdict.rawValue)",
            labelRaw: "0",
            verdict: verdict,
            topProbability: top,
            margin: margin
        )
    }

    // MARK: - 语料不足

    func testEmptyCorpusKeepsDefault() {
        let report = IntentThresholdCalibrator.calibrate(samples: [])
        XCTAssertFalse(report.isReliable)
        XCTAssertEqual(report.recommendedPolicy, .default)
        XCTAssertNotNil(report.unreliabilityReason)
    }

    func testTooFewSamplesKeepsDefault() {
        let samples = (0..<5).map { _ in sample(top: 0.9, margin: 0.5, verdict: .up) }
            + (0..<3).map { _ in sample(top: 0.2, margin: 0.05, verdict: .down) }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        XCTAssertFalse(report.isReliable)
        XCTAssertEqual(report.recommendedPolicy, .default)
    }

    func testMissingDownsIsUnreliable() {
        // 全是点赞：学不出「什么该拦」
        let samples = (0..<30).map { _ in sample(top: 0.9, margin: 0.5, verdict: .up) }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        XCTAssertFalse(report.isReliable)
        XCTAssertEqual(report.downCount, 0)
        XCTAssertNotNil(report.unreliabilityReason)
    }

    func testMissingUpsIsUnreliable() {
        let samples = (0..<30).map { _ in sample(top: 0.9, margin: 0.5, verdict: .down) }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        XCTAssertFalse(report.isReliable)
        XCTAssertEqual(report.upCount, 0)
    }

    // MARK: - 剔除无概率快照样本

    func testZeroProbabilitySamplesExcluded() {
        let valid = (0..<12).map { _ in sample(top: 0.9, margin: 0.4, verdict: .up) }
            + (0..<8).map { _ in sample(top: 0.2, margin: 0.05, verdict: .down) }
        let noise = (0..<7).map { _ in sample(top: 0, margin: 0, verdict: .up) }
        let report = IntentThresholdCalibrator.calibrate(samples: valid + noise)
        XCTAssertEqual(report.sampleCount, 20)
        XCTAssertEqual(report.excludedCount, 7)
    }

    // MARK: - 推荐逻辑

    /// 构造可分语料：点赞都在高概率区，点踩都在低概率区 → 推荐应能全对
    func testSeparableCorpusRecommendsPerfectPolicy() {
        var samples: [JudgmentFeedback] = []
        for _ in 0..<15 {
            samples.append(sample(top: 0.85, margin: 0.4, verdict: .up))
        }
        for _ in 0..<10 {
            samples.append(sample(top: 0.35, margin: 0.08, verdict: .down))
        }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        XCTAssertTrue(report.isReliable)
        XCTAssertEqual(report.recommended.wrongAccepts, 0, "可分语料上不应有错误放行")
        XCTAssertEqual(report.recommended.correctAccepts, 15, "可分语料上应全部正确放行")
    }

    /// 错误放行优先于放行量：宁可多拦，不可错放
    func testWrongAcceptsAreMinimizedFirst() {
        // 构造：宽策略能放行 20 个正确但会错放 2 个；严策略只放行 10 个正确但 0 错放
        var samples: [JudgmentFeedback] = []
        // 高置信正确样本（任何策略都接受）
        for _ in 0..<10 {
            samples.append(sample(top: 0.95, margin: 0.5, verdict: .up))
        }
        // 中置信正确样本（top=0.58 margin=0.22：0.55/0.20 接受，0.60/0.25 拒绝）
        for _ in 0..<10 {
            samples.append(sample(top: 0.58, margin: 0.22, verdict: .up))
        }
        // 危险负例（top=0.57 margin=0.21：0.55/0.20 错放，0.60/0.25 正确拦截）
        for _ in 0..<2 {
            samples.append(sample(top: 0.57, margin: 0.21, verdict: .down))
        }
        // 低置信负例（都拦得住）
        for _ in 0..<5 {
            samples.append(sample(top: 0.3, margin: 0.05, verdict: .down))
        }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        XCTAssertTrue(report.isReliable)
        XCTAssertEqual(report.recommended.wrongAccepts, 0,
                       "即使损失中置信正确样本，也不允许错误放行")
    }

    /// 同等错放时，正确放行多者胜
    func testTieBreakPrefersMoreCorrectAccepts() {
        var samples: [JudgmentFeedback] = []
        for _ in 0..<10 {
            samples.append(sample(top: 0.9, margin: 0.45, verdict: .up))
        }
        // 中置信正确样本：0.55/0.20 放行，0.60/0.25 拦截
        for _ in 0..<10 {
            samples.append(sample(top: 0.58, margin: 0.22, verdict: .up))
        }
        for _ in 0..<6 {
            samples.append(sample(top: 0.35, margin: 0.1, verdict: .down))
        }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        // 0.55/0.20 与 0.60/0.25 都 0 错放；前者多放 10 个中置信正确样本
        XCTAssertEqual(report.recommendedPolicy.minTopProbability, 0.55, accuracy: 0.001)
        XCTAssertEqual(report.recommendedPolicy.minMargin, 0.20, accuracy: 0.001)
        XCTAssertEqual(report.recommended.correctAccepts, 20)
        XCTAssertEqual(report.recommended.wrongAccepts, 0)
    }

    /// 稳定摇摆（三类接近）：top1 过阈但 margin 不足 → 应被拦
    func testMarginGuardStillApplies() {
        let policy = IntentDecisionPolicy(minTopProbability: 0.55, minMargin: 0.20)
        // top1=0.62 但次选紧咬（margin=0.08）——判对了但分布摇摆
        let candidate = IntentThresholdCalibrator.evaluate(
            policy: policy,
            on: [sample(top: 0.62, margin: 0.08, verdict: .up)]
        )
        XCTAssertEqual(candidate.wrongRejects, 1, "margin 不足时应保守拒绝")
        XCTAssertEqual(candidate.acceptedCount, 0)
    }

    // MARK: - 评估指标

    func testEvaluateCounts() {
        let policy = IntentDecisionPolicy(minTopProbability: 0.55, minMargin: 0.20)
        let samples = [
            sample(top: 0.9, margin: 0.5, verdict: .up),     // 正确放行
            sample(top: 0.6, margin: 0.25, verdict: .down),  // 错误放行
            sample(top: 0.5, margin: 0.3, verdict: .up),     // 过度拦截（top 不足）
            sample(top: 0.8, margin: 0.1, verdict: .up),     // 过度拦截（margin 不足）
            sample(top: 0.3, margin: 0.05, verdict: .down)   // 正确拦截
        ]
        let result = IntentThresholdCalibrator.evaluate(policy: policy, on: samples)
        XCTAssertEqual(result.correctAccepts, 1)
        XCTAssertEqual(result.wrongAccepts, 1)
        XCTAssertEqual(result.wrongRejects, 2)
        XCTAssertEqual(result.correctRejects, 1)
        XCTAssertEqual(result.acceptedCount, 2)
        XCTAssertEqual(result.precision, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.coverage, 2.0 / 5.0, accuracy: 0.001)
    }

    func testEvaluateEmptySamples() {
        let result = IntentThresholdCalibrator.evaluate(policy: .default, on: [])
        XCTAssertEqual(result.acceptedCount, 0)
        XCTAssertEqual(result.precision, 1, "无接受样本时 precision 记 1（没有错误放行）")
        XCTAssertEqual(result.coverage, 0)
    }

    // MARK: - 基线与网格

    func testBaselineAlwaysIncluded() {
        let report = IntentThresholdCalibrator.calibrate(samples: [])
        XCTAssertTrue(report.rankedCandidates.contains { $0.policy == .default },
                      "经验值 0.55/0.20 必须在候选网格里")
    }

    func testRecommendationIsDeterministic() {
        var samples: [JudgmentFeedback] = []
        for _ in 0..<12 {
            samples.append(sample(top: 0.8, margin: 0.35, verdict: .up))
        }
        for _ in 0..<8 {
            samples.append(sample(top: 0.3, margin: 0.1, verdict: .down))
        }
        let a = IntentThresholdCalibrator.calibrate(samples: samples)
        let b = IntentThresholdCalibrator.calibrate(samples: samples)
        XCTAssertEqual(a.recommendedPolicy, b.recommendedPolicy)
        XCTAssertEqual(a.rankedCandidates.map(\.policy), b.rankedCandidates.map(\.policy))
    }

    func testRankedCandidatesSortedByRule() {
        var samples: [JudgmentFeedback] = []
        for _ in 0..<10 {
            samples.append(sample(top: 0.85, margin: 0.4, verdict: .up))
        }
        for _ in 0..<10 {
            samples.append(sample(top: 0.4, margin: 0.1, verdict: .down))
        }
        let report = IntentThresholdCalibrator.calibrate(samples: samples)
        let wrongAccepts = report.rankedCandidates.map(\.wrongAccepts)
        XCTAssertEqual(wrongAccepts, wrongAccepts.sorted(), "错误放行必须非递减排序")
        XCTAssertEqual(report.rankedCandidates.first?.wrongAccepts, 0)
    }
}
