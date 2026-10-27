import XCTest
@testable import AssistantCore

final class IntentConfidenceCalibratorTests: XCTestCase {

    private func action(
        capability: ActionCapability = .expenseCreate,
        confidence: Double = 0.85,
        isSelected: Bool = true
    ) -> ActionItem {
        ActionItem(
            capability: capability,
            params: ["amount": "30"],
            confidence: confidence,
            isSelected: isSelected,
            summary: "测试动作"
        )
    }

    private func distribution(
        top: OmniboxIntentLabel,
        topProbability: Double,
        second: OmniboxIntentLabel,
        secondProbability: Double
    ) -> IntentDistribution {
        IntentDistribution(ranked: [
            IntentScore(label: top, probability: topProbability),
            IntentScore(label: second, probability: secondProbability)
        ], policy: .default)
    }

    // MARK: 基础校准

    func testRoundedConfidenceStepsBy005() {
        XCTAssertEqual(IntentConfidenceCalibrator.roundedConfidence(0.623), 0.6)
        XCTAssertEqual(IntentConfidenceCalibrator.roundedConfidence(0.64), 0.65)
        XCTAssertEqual(IntentConfidenceCalibrator.roundedConfidence(0.9), 0.9)
    }

    func testCalibrationReplacesConstantConfidence() {
        let dist = distribution(top: .expenseCreate, topProbability: 0.72, second: .todoCreate, secondProbability: 0.10)
        let result = IntentConfidenceCalibrator.apply(to: [action()], distribution: dist)
        XCTAssertEqual(result[0].confidence, 0.7, accuracy: 0.001)
        XCTAssertTrue(result[0].isSelected)
        XCTAssertFalse(result[0].needsConfirmation)
    }

    func testCalibrationSkipsMismatchedCapability() {
        let dist = distribution(top: .todoCreate, topProbability: 0.9, second: .expenseCreate, secondProbability: 0.05)
        let result = IntentConfidenceCalibrator.apply(to: [action(capability: .expenseCreate)], distribution: dist)
        // 不用「判别成待办」的概率去标注记账动作
        XCTAssertEqual(result[0].confidence, 0.85)
    }

    func testCalibrationSkipsDestructiveActions() {
        let dist = distribution(top: .todoCancel, topProbability: 0.3, second: .todoCreate, secondProbability: 0.2)
        let result = IntentConfidenceCalibrator.apply(to: [action(capability: .todoCancel)], distribution: dist)
        // 破坏性动作本就强制确认，概率压低反而出现误导解释
        XCTAssertEqual(result[0].confidence, 0.85)
    }

    // MARK: P2-5：判别不确定必须映射为待确认

    func testUncertainMarginForcesConfirmationEvenWhenRoundedEqualsThreshold() {
        // top1=0.605 → 四舍五入恰为 0.60；margin=0.02 不足 → needsClarification。
        // 旧行为：confidence=0.60 不 < 0.6 → 徽章不出现且默认勾选（缝隙）。
        let dist = distribution(top: .expenseCreate, topProbability: 0.605, second: .todoCreate, secondProbability: 0.585)
        XCTAssertTrue(dist.needsClarification)

        let result = IntentConfidenceCalibrator.apply(to: [action()], distribution: dist)
        // 新行为：强制压到阈值之下并默认不勾选
        XCTAssertLessThan(result[0].confidence, ActionItem.lowConfidenceThreshold)
        XCTAssertTrue(result[0].needsConfirmation)
        XCTAssertFalse(result[0].isSelected)
    }

    func testUncertainLowMarginCapsConfidence() {
        let dist = distribution(top: .foodRecord, topProbability: 0.9, second: .waterRecord, secondProbability: 0.85)
        XCTAssertTrue(dist.needsClarification) // margin 0.05 < 0.20
        let result = IntentConfidenceCalibrator.apply(to: [action(capability: .foodRecord)], distribution: dist)
        XCTAssertLessThanOrEqual(result[0].confidence, IntentConfidenceCalibrator.uncertainConfidenceCap)
        XCTAssertFalse(result[0].isSelected)
    }

    func testHighConfidenceStillDefaultSelected() {
        let dist = distribution(top: .expenseCreate, topProbability: 0.95, second: .todoCreate, secondProbability: 0.02)
        let result = IntentConfidenceCalibrator.apply(to: [action()], distribution: dist)
        XCTAssertTrue(result[0].isSelected)
        XCTAssertFalse(result[0].needsConfirmation)
    }

    // MARK: 低置信一定会触发确认（防「confidence 被写成常量」静默失效）

    func testLowConfidenceAlwaysTriggersConfirmation() {
        for confidence in [0.0, 0.3, 0.55, 0.59] {
            let item = action(confidence: confidence)
            XCTAssertTrue(item.needsConfirmation, "confidence=\(confidence) 必须触发待确认")
        }
    }

    func testThresholdBoundaryIsExclusive() {
        // 阈值语义：< 0.6 才是低置信；恰好 0.6 边界由 uncertain 分支兜住
        XCTAssertFalse(action(confidence: 0.6).needsConfirmation)
        XCTAssertTrue(action(confidence: 0.59).needsConfirmation)
    }

    // MARK: 默认勾选策略

    func testSelectionPolicyUnchecksLowConfidence() {
        let result = IntentConfidenceCalibrator.applySelectionPolicy([action(confidence: 0.55)])
        XCTAssertFalse(result[0].isSelected)
    }

    func testSelectionPolicyKeepsDestructiveChecked() {
        // 破坏性动作带强制确认徽章，保持勾选让用户在确认卡看到将发生什么
        let result = IntentConfidenceCalibrator.applySelectionPolicy([action(capability: .todoCancel, confidence: 0.9)])
        XCTAssertTrue(result[0].isSelected)
        XCTAssertTrue(result[0].needsConfirmation)
    }

    func testSelectionPolicyLeavesConfidentActionsAlone() {
        let result = IntentConfidenceCalibrator.applySelectionPolicy([action(confidence: 0.9)])
        XCTAssertTrue(result[0].isSelected)
    }

    // MARK: needsClarification 由最终动作推导

    func testNeedsClarificationUsesFinalActionConfidence() {
        XCTAssertTrue(IntentConfidenceCalibrator.needsClarification([action(confidence: 0.5)]))
        XCTAssertFalse(IntentConfidenceCalibrator.needsClarification([action(confidence: 0.9)]))
        // 规则引擎从扣款短信抽出的确定动作不该被低置信标记
        XCTAssertFalse(IntentConfidenceCalibrator.needsClarification([]))
    }
}
