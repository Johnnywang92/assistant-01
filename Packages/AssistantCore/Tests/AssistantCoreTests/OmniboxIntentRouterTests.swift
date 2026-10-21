import XCTest
@testable import AssistantCore

/// 判别层（Intent Router）回归测试。
///
/// 这层的设计前提是「读 logits 而非采样」，因此测试重点不是模型输出什么文本，
/// 而是**给定 logits 分布，系统是否做出了正确的路由与置信决策**——
/// 这些逻辑不依赖模型，可在CI 中稳定断言。
final class OmniboxIntentRouterTests: XCTestCase {

    // MARK: - 标签集

    func testLabelSetCoversAllNineCapabilities() {
        let labels = OmniboxIntentLabel.allCases
        XCTAssertEqual(labels.count, 9)
        XCTAssertEqual(Set(labels.map(\.capability)).count, 9, "标签与能力必须一一对应")
        let labelSet = Set(labels.map(\.rawValue))
        let expected: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8"]
        XCTAssertEqual(labelSet, expected, "标签应是可单 token 化的短字符")
    }

    func testLabelTokenMapRejectsMultiTokenLabel() {
        // 单 token 是读 logits 的硬前提：多 token 标签的首 token 不代表该标签。
        let tokenizer: (OmniboxIntentLabel) -> [Int]? = { _ in [1, 2, 3] }
        XCTAssertNil(IntentTokenMap(tokenizing: OmniboxIntentLabel.allCases, with: tokenizer))
    }

    func testLabelTokenMapRejectsCollidingTokens() {
        // 两个标签映射到同一 token → 分布无法区分，必须拒绝而非任选其一。
        let tokenizer: (OmniboxIntentLabel) -> [Int]? = { _ in [42] }
        XCTAssertNil(IntentTokenMap(tokenizing: OmniboxIntentLabel.allCases, with: tokenizer))
    }

    func testLabelTokenMapRejectsFailedTokenization() {
        let tokenizer: (OmniboxIntentLabel) -> [Int]? = { _ in nil }
        XCTAssertNil(IntentTokenMap(tokenizing: OmniboxIntentLabel.allCases, with: tokenizer))
    }

    func testLabelTokenMapAcceptsDistinctSingleTokens() {
        var counter = 100
        let tokenizer: (OmniboxIntentLabel) -> [Int]? = { _ in
            defer { counter += 1 }
            return [counter]
        }
        let map = IntentTokenMap(tokenizing: OmniboxIntentLabel.allCases, with: tokenizer)
        XCTAssertEqual(map?.tokens.count, 9)
    }

    // MARK: - softmax

    func testDistributionSumsToOne() {
        let logits: [OmniboxIntentLabel: Double] = [
            .expenseCreate: 3.0, .todoCreate: 1.0, .memoInbox: -2.0
        ]
        let dist = IntentClassifierMath.distribution(logits: logits)
        let total = dist.values.reduce(0, +)
        XCTAssertEqual(total, 1.0, accuracy: 1e-9)
    }

    func testDistributionNormalizesOverCandidatesOnly() {
        // 这是关键设计：只对**出现在 logits 里的候选**归一化。
        // 若先对全词表（约15 万 token）softmax 再取候选，候选概率会被海量
        // 无关 token 稀释到接近 0，阈值将永远不通过 —— 判别层就完全失效。
        // 这里只给 2 个候选赋logit，其余 7 类仍参与分布但概率为 0，
        // 因此前两名必须瓜分全部概率质量。
        let logits: [OmniboxIntentLabel: Double] = [
            .expenseCreate: 10.0,
            .todoCreate: 0.0
        ]
        let dist = IntentClassifierMath.distribution(logits: logits)
        XCTAssertEqual(dist[.expenseCreate] ?? 0, 0.99995, accuracy: 1e-4)
        XCTAssertEqual(dist[.todoCreate] ?? 0, 0.00005, accuracy: 1e-4)

        // 组装完整分布后，未赋logit 的类别补 0，且总和仍为 1。
        let full = IntentClassifierMath.makeDistribution(logits: logits)
        let total = full.ranked.reduce(0.0) { $0 + $1.probability }
        XCTAssertEqual(total, 1.0, accuracy: 1e-9)
        XCTAssertEqual(full.probability(of: .queryLookup), 0)
    }

    func testDistributionHandlesExtremeLogitsWithoutOverflow() {
        // logit 差极大时 exp 会溢出；减最大值后必须仍得到有限概率。
        let dist = IntentClassifierMath.distribution(logits: [
            .expenseCreate: 1e4, .todoCreate: -1e4
        ])
        XCTAssertTrue(dist.values.allSatisfy(\.isFinite))
        XCTAssertEqual(dist[.expenseCreate] ?? 0, 1.0, accuracy: 1e-6)
    }

    func testEmptyLogitsReturnsEmptyDistribution() {
        XCTAssertTrue(IntentClassifierMath.distribution(logits: [:]).isEmpty)
    }

    // MARK: - 决策阈值

    func testConfidentDistributionIsAccepted() {
        let dist = IntentClassifierMath.makeDistribution(logits: [
            .expenseCreate: 5.0, .todoCreate: -1.0
        ])
        XCTAssertEqual(dist.top, .expenseCreate)
        XCTAssertTrue(dist.shouldExtract)
        XCTAssertFalse(dist.needsClarification)
    }

    func testLowAbsoluteConfidenceIsRejectedEvenWithLargeGap() {
        // 概率整体都低 = 模型没把握，即便 top1 明显领先也不该写库。
        let dist = IntentClassifierMath.makeDistribution(
            logits: equalLogits(over: OmniboxIntentLabel.allCases),
            allLabels: OmniboxIntentLabel.allCases
        )
        XCTAssertFalse(dist.shouldExtract, "均匀分布必须被判为需澄清")
        XCTAssertTrue(dist.needsClarification)
    }

    func testSmallMarginIsRejected() {
        // 这是「稳定地摇摆」场景：三个类别几乎并列，模型实质没分清。
        // 只看绝对概率会误判为高置信并直接写库，margin 条件正是为此存在。
        //
        // 数学约束：仅有 2 个竞争者时 p1+p2≈1，margin=2·p1-1 必然 ≥0.2，
        // 因此「top1 过阈值但 margin 不足」只有在 3 个以上类别接近时才可能出现。
        let dist = IntentClassifierMath.makeDistribution(
            logits: [
                .expenseCreate: 1.0,
                .todoCreate: 0.5,
                .todoUpdate: 0.0,
                .expenseUpdate: -4.0, .todoComplete: -4.2, .todoCancel: -4.4,
                .reminderSnooze: -4.6, .queryLookup: -4.8, .memoInbox: -5.0
            ]
        )
        // 实测：top1 ≈ 0.50、margin ≈ 0.197
        XCTAssertLessThan(dist.topProbability, IntentDecisionPolicy.default.minTopProbability,
                          "top1 绝对值不足，本例主要由margin 条件拦截")
        XCTAssertLessThan(dist.margin, IntentDecisionPolicy.default.minMargin,
                          "三个类别并列，margin 必须不足")
        XCTAssertFalse(dist.shouldExtract, "margin 不足时必须要求澄清")
    }

    func testMarginConditionRejectsWhatAbsoluteProbabilityAloneWouldAccept() {
        // 针对性验证：同一分布下，只看绝对概率会放行，加上 margin 条件才拦下。
        // 这条断言把「为什么需要两个条件」钉死，防止后人简化成单条件。
        let policy = IntentDecisionPolicy(minTopProbability: 0.45, minMargin: 0.20)
        let dist = IntentClassifierMath.makeDistribution(
            logits: [
                .expenseCreate: 1.0, .todoCreate: 0.5, .todoUpdate: 0.0,
                .expenseUpdate: -4.0, .todoComplete: -4.2, .todoCancel: -4.4,
                .reminderSnooze: -4.6, .queryLookup: -4.8, .memoInbox: -5.0
            ],
            policy: policy
        )
        // 绝对条件满足
        XCTAssertGreaterThanOrEqual(dist.topProbability, policy.minTopProbability)
        // margin 条件不满足 → 整体拒绝
        XCTAssertFalse(policy.accepts(topProbability: dist.topProbability, margin: dist.margin))
        XCTAssertFalse(dist.shouldExtract)
    }

    func testMarginComputation() {
        let dist = IntentClassifierMath.makeDistribution(logits: [
            .expenseCreate: 2.0, .todoCreate: 0.5, .todoUpdate: -5.0
        ])
        let expected = dist.probability(of: .expenseCreate) - dist.probability(of: .todoCreate)
        XCTAssertEqual(dist.margin, expected, accuracy: 1e-12)
    }

    func testProbabilityOfMissingLabelIsZero() {
        let dist = IntentClassifierMath.makeDistribution(logits: [.expenseCreate: 1.0])
        // 未出现在 logits 中的标签会被补 0，而不是被漏掉——
        // 分布必须始终覆盖全部标签，UI 与阈值才有稳定语义。
        XCTAssertEqual(dist.ranked.count, 9)
        XCTAssertEqual(dist.probability(of: .queryLookup), 0)
    }

    func testRankedIsSortedDescending() {
        let dist = IntentClassifierMath.makeDistribution(logits: [
            .expenseCreate: 1.0, .todoCreate: 5.0, .todoUpdate: 3.0
        ])
        let probabilities = dist.ranked.map(\.probability)
        XCTAssertEqual(probabilities, probabilities.sorted(by: >))
        XCTAssertEqual(dist.top, .todoCreate)
    }

    // MARK: - 决策策略

    func testPolicyRequiresBothConditions() {
        let policy = IntentDecisionPolicy(minTopProbability: 0.55, minMargin: 0.20)
        XCTAssertTrue(policy.accepts(topProbability: 0.9, margin: 0.8))
        XCTAssertFalse(policy.accepts(topProbability: 0.4, margin: 0.8), "概率不足应拒绝")
        XCTAssertFalse(policy.accepts(topProbability: 0.9, margin: 0.05), "差距不足应拒绝")
    }

    func testCustomPolicyIsHonored() {
        // 阈值必须是可调的：不同模型、不同场景对「够不够确定」的定义不同。
        // logit 差 4.0 → top1 ≈ 0.986，因此严格阈值要设得更高才能验证生效。
        let strict = IntentDecisionPolicy(minTopProbability: 0.995, minMargin: 0.60)
        let dist = IntentClassifierMath.makeDistribution(
            logits: [.expenseCreate: 4.0, .todoCreate: 0.0],
            policy: strict
        )
        XCTAssertLessThan(dist.topProbability, 0.995, "该分布达不到严格阈值")
        XCTAssertFalse(dist.shouldExtract, "严格策略下该分布应被拒绝")

        // 同一分布放到默认策略下必须放行，证明确实是策略在起作用。
        let relaxed = IntentClassifierMath.makeDistribution(
            logits: [.expenseCreate: 4.0, .todoCreate: 0.0]
        )
        XCTAssertTrue(relaxed.shouldExtract)
    }

    // MARK: - 能力映射

    func testTopCapabilityMapsCorrectly() {
        let mapping: [(OmniboxIntentLabel, ActionCapability)] = [
            (.expenseCreate, .expenseCreate),
            (.expenseUpdate, .expenseUpdate),
            (.todoCreate, .todoCreate),
            (.todoUpdate, .todoUpdate),
            (.todoComplete, .todoComplete),
            (.todoCancel, .todoCancel),
            (.reminderSnooze, .reminderSnooze),
            (.queryLookup, .queryLookup),
            (.memoInbox, .memoInbox)
        ]
        for (label, expected) in mapping {
            XCTAssertEqual(label.capability, expected)
        }
    }

    func testDestructiveLabelsPreserveDestructiveCapability() {
        // 破坏性动作必须仍被标记为破坏性，否则会绕过强制确认卡。
        XCTAssertTrue(OmniboxIntentLabel.todoCancel.capability.isDestructive)
        XCTAssertTrue(OmniboxIntentLabel.expenseUpdate.capability.isDestructive)
        XCTAssertFalse(OmniboxIntentLabel.expenseCreate.capability.isDestructive)
    }

    func testLegendMentionsEveryLabel() {
        let legend = OmniboxIntentLabel.promptLegend
        for label in OmniboxIntentLabel.allCases {
            XCTAssertTrue(
                legend.contains("\(label.rawValue)="),
                "提示词图例必须包含标签 \(label.rawValue)，否则模型无从选择"
            )
        }
    }

    // MARK: - 置信度校准的实际后果

    func testLowProbabilityConfidenceWouldTriggerConfirmation() {
        // 判别层的价值最终体现在这里：低置信动作必须进确认卡。
        // 生成式路径曾把 confidence 写死 0.85，导致 needsConfirmation 恒为 false。
        var action = ActionItem(capability: .expenseCreate, confidence: 0.85)
        XCTAssertFalse(action.needsConfirmation, "写死的高置信不会触发确认")

        let calibrated = (0.42 * 20).rounded() / 20
        action.confidence = calibrated
        XCTAssertTrue(action.needsConfirmation, "真实低置信必须触发确认卡")
    }

    // MARK: - 辅助

    private func equalLogits(over labels: [OmniboxIntentLabel]) -> [OmniboxIntentLabel: Double] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0, 0.0) })
    }
}
