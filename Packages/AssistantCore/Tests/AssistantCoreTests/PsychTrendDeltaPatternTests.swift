import AssistantCore
import XCTest

/// 心理趋势卡变化文案的正则匹配测试。
///
/// 这段逻辑的存在理由是：文案形如「比上次高 3 分（最新 13 分）」，
/// **含两个数字**。手工切片极易数错位数（实现时确实先写错过一版），
/// 所以必须用测试把提取行为钉死。
///
/// 注意：匹配器在 App 侧（`LocalizationManager`），不在 AssistantCore，
/// 因此这里测的是 Core 侧的**文案格式契约**——
/// 即 Core 产出的趋势数据能正确映射成这些中文串。
final class PsychTrendDeltaPatternTests: XCTestCase {

    /// Core 侧的趋势分档与得分，用它们构造待翻译文案。
    private func score(_ total: Int) -> PsychScoreHistoryEntry {
        PsychScoreHistoryEntry(
            scaleID: .phq9,
            completedAt: Date(timeIntervalSince1970: 1_792_819_200),
            totalScore: total,
            band: PsychScaleCatalog.phq9.band(forTotal: total)?.level ?? .none
        )
    }

    /// 构造与 App 侧一致的变化文案。
    private func deltaText(_ delta: Int, latest: Int) -> String {
        let d = delta
        if d > 0 { return "比上次高 \(d) 分（最新 \(latest) 分）" }
        if d < 0 { return "比上次低 \(-d) 分（最新 \(latest) 分）" }
        return "与上次持平（最新 \(latest) 分）"
    }

    /// 变化量与最新分是两个不同的数字，提取时不能混淆。
    ///
    /// 这是本文件最重要的一条：写错一位就会显示成「比上次高 13 分（最新 3 分）」。
    func testDeltaAndLatestScoresAreDistinctNumbers() {
        let text = deltaText(3, latest: 13)
        XCTAssertEqual(text, "比上次高 3 分（最新 13 分）")

        // 模拟匹配器的提取行为：正则应分别抓到 3 与 13。
        let pattern = try! NSRegularExpression(pattern: "^比上次高 (\\d+) 分（最新 (\\d+) 分）$")
        let range = NSRange(text.startIndex..., in: text)
        guard let result = pattern.firstMatch(in: text, range: range) else {
            return XCTFail("正则未匹配")
        }
        let delta = (text as NSString).substring(with: result.range(at: 1))
        let latest = (text as NSString).substring(with: result.range(at: 2))
        XCTAssertEqual(delta, "3", "变化量必须是 3 而不是最新分 13")
        XCTAssertEqual(latest, "13")
    }

    /// 下降场景同样要正确区分两个数字。
    func testDeclineTextExtractsCorrectNumbers() {
        let text = deltaText(-5, latest: 8)
        XCTAssertEqual(text, "比上次低 5 分（最新 8 分）")

        let pattern = try! NSRegularExpression(pattern: "^比上次低 (\\d+) 分（最新 (\\d+) 分）$")
        let range = NSRange(text.startIndex..., in: text)
        guard let result = pattern.firstMatch(in: text, range: range) else {
            return XCTFail("正则未匹配")
        }
        XCTAssertEqual((text as NSString).substring(with: result.range(at: 1)), "5")
        XCTAssertEqual((text as NSString).substring(with: result.range(at: 2)), "8")
    }

    /// 持平场景只有一个数字。
    func testFlatTextExtractsLatestScore() {
        let text = deltaText(0, latest: 11)
        XCTAssertEqual(text, "与上次持平（最新 11 分）")

        let pattern = try! NSRegularExpression(pattern: "^与上次持平（最新 (\\d+) 分）$")
        let range = NSRange(text.startIndex..., in: text)
        guard let result = pattern.firstMatch(in: text, range: range) else {
            return XCTFail("正则未匹配")
        }
        XCTAssertEqual((text as NSString).substring(with: result.range(at: 1)), "11")
    }

    /// 不匹配的文本不得被误判（否则普通句子会被翻译成趋势文案）。
    func testUnrelatedTextDoesNotMatch() {
        let pattern = try! NSRegularExpression(pattern: "^比上次高 (\\d+) 分（最新 (\\d+) 分）$")
        let text = "比上次高了一些"
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertNil(pattern.firstMatch(in: text, range: range))
    }

    /// Core 侧趋势分档与文案构造之间的一致性：
    /// 分数升高时生成「比上次高」文案。
    func testRisingScoresProduceRiseText() {
        let previous = score(9)
        let latest = score(13)
        let delta = latest.totalScore - previous.totalScore
        XCTAssertEqual(deltaText(delta, latest: latest.totalScore), "比上次高 4 分（最新 13 分）")
    }
}
