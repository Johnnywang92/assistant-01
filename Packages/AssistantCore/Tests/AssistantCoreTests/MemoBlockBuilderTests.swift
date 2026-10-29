import XCTest
@testable import AssistantCore

/// 语音备忘「转写 → 结构化块」的回归测试。
///
/// 这组用例锁住三条纪律（详见 `MemoBlockBuilder` 顶部注释）：
///   1. **没有真实偏移量绝不给时间戳**——估出来的时间戳会让用户以为
///      「点这句能听到对应原声」，点下去对不上，那是骗人。
///   2. 切分不能把短句切碎，也不能把长句拦腰截断到读不下去。
///   3. 结构损坏时必须降级为「保留原文」，而不是把内容弄丢。
///
/// 改动块切分规则前请先跑这个文件。
final class MemoBlockBuilderTests: XCTestCase {

    // MARK: - 切分

    func testSplitsOnChineseTerminators() {
        let text = "上周收集了 42 条语音备忘的用户反馈。最集中的抱怨是转写结果没法直接用。"
        let document = MemoBlockBuilder.build(from: text)

        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].text, "上周收集了 42 条语音备忘的用户反馈。")
        XCTAssertEqual(document.blocks[1].text, "最集中的抱怨是转写结果没法直接用。")
    }

    func testMergesTooShortFragments() {
        // 第一句太短，应与后一句合并，而不是变成孤零零的一个块
        let text = "好的。上周我们收集了 42 条语音备忘的用户反馈。"
        let document = MemoBlockBuilder.build(from: text)

        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertTrue(document.blocks[0].text.contains("好的。"))
        XCTAssertTrue(document.blocks[0].text.contains("42 条语音备忘"))
    }

    func testSplitsOverlongSegmentAtClauseBoundary() {
        let long = String(repeating: "这是一段很长的口述内容，", count: 12)
        let document = MemoBlockBuilder.build(from: long + "。")

        XCTAssertGreaterThan(document.blocks.count, 1)
        for block in document.blocks {
            XCTAssertLessThanOrEqual(block.text.count, 140, "切分后仍过长，切点没落在逗号处")
        }
    }

    func testEmptyTextProducesNoBlocks() {
        XCTAssertTrue(MemoBlockBuilder.build(from: "   \n ").blocks.isEmpty)
    }

    // MARK: - 时间戳纪律（最重要的一组）

    func testPlainTextNeverGetsTimestamps() {
        // 整段转写没有逐句偏移量，切分器不得按字数比例估算时间戳
        let text = "上周收集了 42 条语音备忘的用户反馈。最集中的抱怨是转写结果没法直接用。"
        let document = MemoBlockBuilder.build(from: text)

        XCTAssertFalse(document.blocks.isEmpty)
        for block in document.blocks {
            XCTAssertNil(block.timeRange, "整段转写没有真实偏移量，不应产生时间戳")
            XCTAssertFalse(block.isSeekable)
        }
    }

    func testInvalidTimeRangeIsDroppedNotZeroed() {
        // 起点为负 / 终点不大于起点，都是无效区间——必须丢弃，
        // 绝不能退化成 (0, 0)，那会被当成「录音开头的一段真实内容」。
        let negative = MemoBlockBuilder.block(fromSegment: "一段话", timeRange: MemoTimeRange(start: -1, end: 5))
        XCTAssertNil(negative.timeRange)

        let inverted = MemoBlockBuilder.block(fromSegment: "一段话", timeRange: MemoTimeRange(start: 10, end: 5))
        XCTAssertNil(inverted.timeRange)

        let zero = MemoBlockBuilder.block(fromSegment: "一段话", timeRange: MemoTimeRange(start: 0, end: 0))
        XCTAssertNil(zero.timeRange)
    }

    func testSegmentsWithRealTimestampsKeepThem() {
        let segments = [
            MemoBlockBuilder.MemoSegment(
                text: "上周收集了 42 条语音备忘的用户反馈。",
                timeRange: MemoTimeRange(start: 12, end: 65)
            ),
            MemoBlockBuilder.MemoSegment(
                text: "最集中的抱怨是转写结果没法直接用。",
                timeRange: MemoTimeRange(start: 65, end: 98)
            )
        ]
        let document = MemoBlockBuilder.build(fromSegments: segments)

        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].timeRange, MemoTimeRange(start: 12, end: 65))
        XCTAssertTrue(document.blocks[0].isSeekable)
        XCTAssertEqual(document.blocks[1].timeRange, MemoTimeRange(start: 65, end: 98))
    }

    func testTimeRangeMustFitRecordingDuration() {
        // 录音只有 10 秒，却对齐出 00:30 的区间 —— 数据不合理，宁可不给时间戳
        let range = MemoTimeRange(start: 30, end: 45)
        XCTAssertFalse(range.fits(inDuration: 10))
        XCTAssertTrue(MemoTimeRange(start: 1, end: 5).fits(inDuration: 10))
    }

    // MARK: - 块类型判定

    func testDetectsBulletAndTodoItems() {
        let bullet = MemoBlockBuilder.block(fromSegment: "- 段落自动切分并带上时间戳")
        XCTAssertEqual(bullet.kind, .bullet)
        XCTAssertEqual(bullet.text, "段落自动切分并带上时间戳")

        let todo = MemoBlockBuilder.block(fromSegment: "1. 下周提交转写编辑器交互稿")
        XCTAssertEqual(todo.kind, .todo)
        XCTAssertEqual(todo.text, "下周提交转写编辑器交互稿")
    }

    func testNumberAboveRangeStaysParagraph() {
        // 42 条是叙述里的数字，不是待办序号
        let block = MemoBlockBuilder.block(fromSegment: "42. 这不是待办编号")
        XCTAssertEqual(block.kind, .paragraph)
    }

    func testDetectsHeadingByColonSuffix() {
        let block = MemoBlockBuilder.block(fromSegment: "三个改进方向：")
        XCTAssertEqual(block.kind, .heading)
    }

    func testLongSentenceWithColonIsNotHeading() {
        // 太长的「说明：……」不该变成标题，否则正文会突然变成红条标题
        let block = MemoBlockBuilder.block(
            fromSegment: "这是一句很长的说明文字后面跟着冒号：后面还有更多内容需要继续写下去"
        )
        XCTAssertEqual(block.kind, .paragraph)
    }

    func testImageAndAudioAreNeverTranscriptionGenerated() {
        // 转写切分永远不该产出图片/语音块，否则会出现「凭空多出一张图」
        XCTAssertFalse(MemoBlockKind.image.isTranscriptionGenerated)
        XCTAssertFalse(MemoBlockKind.audio.isTranscriptionGenerated)
        XCTAssertTrue(MemoBlockKind.paragraph.isTranscriptionGenerated)
        XCTAssertTrue(MemoBlockKind.heading.isTranscriptionGenerated)
    }

    // MARK: - 空块

    func testEmptyBlocksAreExcluded() {
        let document = MemoBlockBuilder.build(from: "。\n。\n。")
        for block in document.blocks {
            XCTAssertFalse(block.isEmpty)
        }
    }

    func testImageBlockWithoutFileIsEmpty() {
        XCTAssertTrue(MemoBlock(kind: .image, text: "说明文字").isEmpty)
        XCTAssertFalse(MemoBlock(kind: .image, imageFileName: "a.png").isEmpty)
    }
}

/// 块序列化与降级的回归测试。
final class MemoBlockCodecTests: XCTestCase {

    func testRoundTripPreservesBlocks() {
        let document = MemoDocument(
            title: "产品周会",
            blocks: [
                MemoBlock(kind: .heading, text: "改进方向："),
                MemoBlock(kind: .paragraph, text: "正文一段", timeRange: MemoTimeRange(start: 12, end: 40)),
                MemoBlock(kind: .todo, text: "下周提交交互稿", isDone: true),
                MemoBlock(kind: .image, imageFileName: "a.png", imageCaption: "白板"),
                MemoBlock(kind: .audio, text: "原声", timeRange: MemoTimeRange(start: 1, end: 9))
            ]
        )

        guard let data = MemoBlockCodec.encode(document) else {
            return XCTFail("编码失败")
        }
        guard let decoded = MemoBlockCodec.decode(data) else {
            return XCTFail("解码失败")
        }

        XCTAssertEqual(decoded, document)
    }

    func testDecodeReturnsNilOnCorruptData() {
        // 损坏时必须返回 nil，**不能**返回空文档——
        // 「空文档」与「用户清空了笔记」在数据上无法区分。
        let corrupt = Data("{ this is not json".utf8)
        XCTAssertNil(MemoBlockCodec.decode(corrupt))
    }

    func testFallbackKeepsPlainTextWhenDataCorrupt() {
        let corrupt = Data("garbage".utf8)
        let document = MemoBlockCodec.decodeOrFallback(corrupt, plainText: "别丢掉我的内容")

        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].text, "别丢掉我的内容")
        XCTAssertEqual(document.blocks[0].kind, .paragraph)
    }

    func testFallbackWithEmptyTextProducesEmptyDocument() {
        let document = MemoBlockCodec.decodeOrFallback(nil, plainText: "   ")
        XCTAssertTrue(document.blocks.isEmpty)
    }

    func testPlainTextSyncsOnlyTextBlocks() {
        let document = MemoDocument(blocks: [
            MemoBlock(kind: .paragraph, text: "第一段"),
            MemoBlock(kind: .image, imageFileName: "a.png"),
            MemoBlock(kind: .paragraph, text: "第二段")
        ])
        XCTAssertEqual(document.plainText, "第一段\n第二段")
    }
}
