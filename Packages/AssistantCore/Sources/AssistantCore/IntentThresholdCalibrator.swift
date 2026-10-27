import Foundation

// MARK: - 判别层阈值校准（纯逻辑，下沉 AssistantCore 便于测试覆盖）
//
// 背景：`IntentDecisionPolicy` 的 0.55 / 0.20 是经验值，而 `JudgmentFeedback`
// 已经在攒真实语料（topProbability / margin 快照 + 点赞/点踩结论）。
// 本层用语料离线网格搜索推荐阈值：**宁可少自动执行，不可错自动执行**——
// 「点踩样本被接受」（错误动作要写库）的代价远高于「点赞样本被拒绝」（多问一句）。
//
// 不做在线训练：输出是确定性的候选排序 + 一条推荐策略，行为可复现、可测试。

public enum IntentThresholdCalibrator {

    // MARK: 候选评估

    /// 一组阈值在语料上的表现
    public struct Candidate: Equatable, Sendable {
        public let policy: IntentDecisionPolicy
        /// 被该策略接受（会进入自动抽取）的样本数
        public let acceptedCount: Int
        /// 点赞且被接受（正确放行）
        public let correctAccepts: Int
        /// 点踩且被接受（**错误放行**——最高代价）
        public let wrongAccepts: Int
        /// 点赞但被拒绝（过度保守，多问一句）
        public let wrongRejects: Int
        /// 点踩且被拒绝（正确拦截）
        public let correctRejects: Int

        /// 接受样本里判对的比例；无接受样本时记 1（没有错误放行）
        public var precision: Double {
            acceptedCount > 0 ? Double(correctAccepts) / Double(acceptedCount) : 1
        }

        /// 接受样本占全部样本比例
        public var coverage: Double {
            let total = acceptedCount + correctRejects + wrongRejects
            return total > 0 ? Double(acceptedCount) / Double(total) : 0
        }

        public init(
            policy: IntentDecisionPolicy,
            acceptedCount: Int,
            correctAccepts: Int,
            wrongAccepts: Int,
            wrongRejects: Int,
            correctRejects: Int
        ) {
            self.policy = policy
            self.acceptedCount = acceptedCount
            self.correctAccepts = correctAccepts
            self.wrongAccepts = wrongAccepts
            self.wrongRejects = wrongRejects
            self.correctRejects = correctRejects
        }
    }

    /// 校准报告
    public struct Report: Equatable, Sendable {
        /// 参与校准的有效样本数（已剔除无概率快照的规则路径样本）
        public let sampleCount: Int
        /// 被剔除的样本数（topProbability ≤ 0）
        public let excludedCount: Int
        public let upCount: Int
        public let downCount: Int
        /// 现行 `.default` 在语料上的表现
        public let current: Candidate
        /// 推荐策略的表现（样本不足时等于 current）
        public let recommended: Candidate
        /// 全部候选（按优劣排序，调试页展示用）
        public let rankedCandidates: [Candidate]
        /// 语料是否足够支撑重设阈值
        public let isReliable: Bool
        /// 语料不够时的原因说明
        public let unreliabilityReason: String?

        public var recommendedPolicy: IntentDecisionPolicy { recommended.policy }
    }

    // MARK: 校准

    /// 最少有效样本数：低于该值不做推荐（沿用经验值）。
    public static let minReliableSamples = 20
    /// 负例（点踩）下限：没有负例就学不出「什么该拦」。
    public static let minReliableDowns = 5
    /// 正例（点赞）下限：没有正例就学不出「什么该放」。
    public static let minReliableUps = 5

    /// 候选网格。覆盖经验值 0.55/0.20 所在邻域。
    public static let topGrid: [Double] = stride(from: 0.30, through: 0.90, by: 0.05).map { ($0 * 100).rounded() / 100 }
    public static let marginGrid: [Double] = stride(from: 0.05, through: 0.50, by: 0.05).map { ($0 * 100).rounded() / 100 }

    /// 基于点赞/点踩语料推荐阈值。
    ///
    /// 排序规则（字典序，确定性）：
    /// 1. 错误放行（点踩被接受）越少越好——错误动作写库不可接受；
    /// 2. 正确放行（点赞被接受）越多越好——减少无谓澄清；
    /// 3. 与现行默认值偏差越小越好——同样表现时少折腾。
    public static func calibrate(
        samples: [JudgmentFeedback],
        baseline: IntentDecisionPolicy = .default
    ) -> Report {
        // 只有带概率快照的样本才有资格参与（规则路径回执的 0/0 快照是噪声）
        let valid = samples.filter { $0.topProbability > 0 && $0.topProbability <= 1 }
        let excludedCount = samples.count - valid.count
        let upCount = valid.filter { $0.verdict == .up }.count
        let downCount = valid.filter { $0.verdict == .down }.count

        var candidates: [Candidate] = []
        for top in topGrid {
            for margin in marginGrid {
                let policy = IntentDecisionPolicy(minTopProbability: top, minMargin: margin)
                candidates.append(evaluate(policy: policy, on: valid))
            }
        }
        // 确保经验值在网格里（即便网格调整也不丢基线）
        if !candidates.contains(where: { $0.policy == baseline }) {
            candidates.append(evaluate(policy: baseline, on: valid))
        }

        candidates.sort { lhs, rhs in
            if lhs.wrongAccepts != rhs.wrongAccepts {
                return lhs.wrongAccepts < rhs.wrongAccepts
            }
            if lhs.correctAccepts != rhs.correctAccepts {
                return lhs.correctAccepts > rhs.correctAccepts
            }
            let dL = distance(lhs.policy, baseline)
            let dR = distance(rhs.policy, baseline)
            if dL != dR {
                return dL < dR
            }
            // 距离并列时按阈值字典序兜底，保证排序全序、结果可复现
            if lhs.policy.minTopProbability != rhs.policy.minTopProbability {
                return lhs.policy.minTopProbability < rhs.policy.minTopProbability
            }
            return lhs.policy.minMargin < rhs.policy.minMargin
        }

        let current = evaluate(policy: baseline, on: valid)
        let isReliable = valid.count >= minReliableSamples
            && upCount >= minReliableUps
            && downCount >= minReliableDowns

        let reason: String? = {
            if valid.count < minReliableSamples {
                return "有效样本 \(valid.count)/\(minReliableSamples) 条，继续积累反馈后再校准"
            }
            if upCount < minReliableUps {
                return "点赞样本 \(upCount)/\(minReliableUps) 条，缺少正例"
            }
            if downCount < minReliableDowns {
                return "点踩样本 \(downCount)/\(minReliableDowns) 条，缺少负例"
            }
            return nil
        }()

        let best = candidates.first ?? current
        return Report(
            sampleCount: valid.count,
            excludedCount: excludedCount,
            upCount: upCount,
            downCount: downCount,
            current: current,
            recommended: isReliable ? best : current,
            rankedCandidates: candidates,
            isReliable: isReliable,
            unreliabilityReason: reason
        )
    }

    /// 单组阈值在语料上的表现
    public static func evaluate(
        policy: IntentDecisionPolicy,
        on samples: [JudgmentFeedback]
    ) -> Candidate {
        var correctAccepts = 0, wrongAccepts = 0, wrongRejects = 0, correctRejects = 0
        for sample in samples {
            let accepted = policy.accepts(topProbability: sample.topProbability, margin: sample.margin)
            switch (accepted, sample.verdict) {
            case (true, .up): correctAccepts += 1
            case (true, .down): wrongAccepts += 1
            case (false, .up): wrongRejects += 1
            case (false, .down): correctRejects += 1
            }
        }
        return Candidate(
            policy: policy,
            acceptedCount: correctAccepts + wrongAccepts,
            correctAccepts: correctAccepts,
            wrongAccepts: wrongAccepts,
            wrongRejects: wrongRejects,
            correctRejects: correctRejects
        )
    }

    /// 与基线的偏差（两个维度等权欧氏距离）
    private static func distance(_ policy: IntentDecisionPolicy, _ baseline: IntentDecisionPolicy) -> Double {
        let dTop = policy.minTopProbability - baseline.minTopProbability
        let dMargin = policy.minMargin - baseline.minMargin
        return (dTop * dTop + dMargin * dMargin).squareRoot()
    }
}
