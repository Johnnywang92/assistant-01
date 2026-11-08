import XCTest
@testable import AssistantCore

/// 分享卡片内容规则的回归测试。
///
/// 核心约束：**分享出的图片无法携带声音**。
/// 因此语音块在卡片上只能呈现为「原声片段 + 时间区间」的可视标识，
/// 不能让人以为原声已经发出去了。
final class MemoShareCardContentTests: XCTestCase {

    private func blocks() -> [MemoBlock] {
        [
            MemoBlock(kind: .heading, text: "改进方向："),
            MemoBlock(kind: .paragraph, text: "正文一段"),
            MemoBlock(kind: .bullet, text: "要点一"),
            MemoBlock(kind: .todo, text: "待办一", isDone: true),
            MemoBlock(kind: .quote, text: "引用一句"),
            MemoBlock(kind: .image, imageFileName: "a.png", imageCaption: "白板"),
            MemoBlock(kind: .audio, text: "原声", timeRange: MemoTimeRange(start: 12, end: 65))
        ]
    }

    func testMapsEveryBlockKind() {
        let items = MemoShareCardContent.items(from: blocks())
        let kinds = items.map(\.kind)

        XCTAssertEqual(kinds, [.heading, .paragraph, .bullet, .todo, .quote, .image, .audio])
    }

    func testImagesAreCappedAndOverflowIsCounted() {
        var many: [MemoBlock] = (0..<5).map { index in MemoBlock(kind: .image, imageFileName: "\(index).png") }
        many.append(MemoBlock(kind: .paragraph, text: "尾段"))

        let items = MemoShareCardContent.items(from: many)
        let imageCount = items.filter { $0.kind == .image }.count

        XCTAssertEqual(imageCount, MemoShareCardContent.maxImages)
        XCTAssertEqual(items.count, MemoShareCardContent.maxImages + 1)

        // 被折叠的图片必须被计数，否则用户以为图片丢了
        let hidden = MemoShareCardContent.hiddenCounts(from: many)
        XCTAssertEqual(hidden.images, 2)
        XCTAssertEqual(hidden.audio, 0)
    }

    func testAudioClipsAreCapped() {
        var many: [MemoBlock] = (0..<4).map { index in
            MemoBlock(kind: .audio, text: "原声", timeRange: MemoTimeRange(start: 0, end: 10))
        }
        many.append(MemoBlock(kind: .paragraph, text: "尾段"))

        let items = MemoShareCardContent.items(from: many)
        XCTAssertEqual(items.filter { $0.kind == .audio }.count, MemoShareCardContent.maxAudioClips)
        XCTAssertEqual(MemoShareCardContent.hiddenCounts(from: many).audio, 2)
    }

    func testExcludingAudioCountsThemAsHidden() {
        // 用户关掉「包含语音片段」时，这些片段是「被排除」而非「不存在」，
        // 计数上要能区分出来，否则提示语会误导。
        let hidden = MemoShareCardContent.hiddenCounts(from: blocks(), includeAudio: false)
        XCTAssertEqual(hidden.audio, 1)
    }

    func testAudioCaptionContainsRangeAndDisclosure() {
        let caption = MemoShareCardContent.audioCaption(for: MemoTimeRange(start: 12, end: 65))
        XCTAssertTrue(caption.contains("00:12"))
        XCTAssertTrue(caption.contains("01:05"))
        // 必须说明原声要另外获取，不能让人误以为已经发出
        XCTAssertTrue(caption.contains("完整录音可听"))
    }

    func testAudioCaptionWithoutRangeDoesNotFabricateTime() {
        let caption = MemoShareCardContent.audioCaption(for: nil)
        XCTAssertFalse(caption.contains("00:00"))
        XCTAssertTrue(caption.contains("完整录音可听"))
    }

    func testAudioCaptionWithInvalidRangeDoesNotFabricateTime() {
        let caption = MemoShareCardContent.audioCaption(for: MemoTimeRange(start: 30, end: 10))
        XCTAssertFalse(caption.contains("00:30"))
    }

    func testFormatTime() {
        XCTAssertEqual(MemoShareCardContent.format(0), "00:00")
        XCTAssertEqual(MemoShareCardContent.format(65), "01:05")
        XCTAssertEqual(MemoShareCardContent.format(3725), "1:02:05")
        XCTAssertEqual(MemoShareCardContent.format(-5), "00:00")
    }

    func testEmptyBlocksAreSkipped() {
        let items = MemoShareCardContent.items(from: [
            MemoBlock(kind: .paragraph, text: "   "),
            MemoBlock(kind: .paragraph, text: "有效")
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "有效")
    }

    // MARK: - 只出一张长图：内容不切分、不折叠、不丢弃

    func testAllBlocksStayInTheSingleCard() {
        // 长笔记不再被拆页或切片，全部内容都交给同一张卡片渲染。
        let sentence = "这是一段关于工作与分享的随感，写下来是为了以后还能想起当时的判断和取舍。"
        let items = (0..<40).map { index in
            MemoShareCardItem(kind: .paragraph, text: sentence + "第\(index)段。")
        }
        XCTAssertEqual(items.count, 40)
        XCTAssertGreaterThan(
            MemoShareCardContent.estimatedCardHeight(for: items),
            MemoShareCardContent.cardChromeAllowance
        )
        // 内容顺序与文本原样保留
        XCTAssertEqual(items.last?.text, sentence + "第39段。")
    }

    func testEstimatedCardHeightIncludesChromeAndGrowsWithContent() {
        let empty = MemoShareCardContent.estimatedCardHeight(for: [])
        XCTAssertEqual(empty, MemoShareCardContent.cardChromeAllowance)

        let one = MemoShareCardContent.estimatedCardHeight(for: [
            MemoShareCardItem(kind: .paragraph, text: "一段文字")
        ])
        XCTAssertGreaterThan(one, empty)

        let many = MemoShareCardContent.estimatedCardHeight(for: (0..<10).map { _ in
            MemoShareCardItem(kind: .paragraph, text: "一段文字")
        })
        XCTAssertGreaterThan(many, one)
    }

    func testEstimatedHeightIsAlwaysPositive() {
        for kind in [MemoShareCardItem.Kind.paragraph, .bullet, .todo, .quote, .heading] {
            let item = MemoShareCardItem(kind: kind, text: "")
            XCTAssertGreaterThan(MemoShareCardContent.estimatedHeight(for: item), 0)
        }
    }

    // MARK: - 渲染倍率：一张长图靠降倍率压进上限，而不是切成多张

    func testShortCardKeepsPreferredScale() {
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 350, preferred: 3), 3)
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 1000, preferred: 3), 3)
    }

    func testLongCardLowersScaleWithoutExceedingLimit() {
        // 5000pt @3x = 15000px 超限；8192/5000 = 1.6 → 1x，仍是完整一张图。
        let scale = ShareCardRenderScale.safeScale(longestSide: 5000, preferred: 3)
        XCTAssertEqual(scale, 1)
        XCTAssertTrue(ShareCardRenderScale.isWithinLimit(points: 5000, scale: scale))
        // 回归：旧实现写成 preferred * maxPixelSide / longestSide，
        // 这里会算出比 3 更大的数，把「降倍率」变成放大。
        XCTAssertLessThanOrEqual(scale, 3)
    }

    func testScaleNeverExceedsPreferred() {
        // 内容很矮时 fitted 会很大，仍必须守住期望倍率。
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 10, preferred: 2), 2)
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 100, preferred: 1), 1)
    }

    func testExtremeOrInvalidInputFallsBackToOneX() {
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 100_000, preferred: 3), 1)
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 0, preferred: 3), 1)
        XCTAssertEqual(ShareCardRenderScale.safeScale(longestSide: 350, preferred: 0), 1)
    }

    func testRealisticLongNoteStillRendersAsOneImage() {
        // 约两千字的整篇转写：仍是一张图，且能保持 3x 清晰度。
        let sentence = String(repeating: "这是一段很长的转写内容，用来验证整张长图仍能一次渲染完整。", count: 3)
        let items = (0..<20).map { _ in MemoShareCardItem(kind: .paragraph, text: sentence) }
        let points = MemoShareCardContent.estimatedCardHeight(for: items)
        let scale = ShareCardRenderScale.safeScale(longestSide: points, preferred: 3)

        XCTAssertGreaterThan(scale, 0)
        XCTAssertTrue(ShareCardRenderScale.isWithinLimit(points: points, scale: scale))
    }

    func testExtremelyLongNoteIsRejectedRatherThanTruncated() {
        // 连 1x 都放不下的极端长度：App 侧会明确提示失败，绝不输出残图。
        let points = 10_000.0
        let scale = ShareCardRenderScale.safeScale(longestSide: points, preferred: 3)
        XCTAssertEqual(scale, 1)
        XCTAssertFalse(ShareCardRenderScale.isWithinLimit(points: points, scale: scale))
    }

    func testIsWithinLimitRejectsOversizedRenders() {
        XCTAssertFalse(ShareCardRenderScale.isWithinLimit(points: 3000, scale: 3))
        XCTAssertTrue(ShareCardRenderScale.isWithinLimit(points: 3000, scale: 2))
    }
}
