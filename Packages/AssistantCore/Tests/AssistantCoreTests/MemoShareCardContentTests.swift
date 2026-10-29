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
}
