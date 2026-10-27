import XCTest
@testable import AssistantCore

final class ClipboardRejectionMemoryTests: XCTestCase {

    // MARK: 内容指纹

    func testTextKeyIgnoresSurroundingWhitespace() {
        XCTAssertEqual(
            ClipboardRejectionMemory.contentKey(forText: "  记一笔打车30  "),
            ClipboardRejectionMemory.contentKey(forText: "记一笔打车30")
        )
    }

    func testTextKeyDistinguishesDifferentContent() {
        XCTAssertNotEqual(
            ClipboardRejectionMemory.contentKey(forText: "记一笔打车30"),
            ClipboardRejectionMemory.contentKey(forText: "记一笔打车31")
        )
    }

    func testTextKeyIsEmptyForBlankText() {
        XCTAssertEqual(ClipboardRejectionMemory.contentKey(forText: "   \n\t"), "")
        XCTAssertEqual(ClipboardRejectionMemory.contentKey(forText: ""), "")
    }

    func testTextKeyIsHashNotPlaintext() {
        // 隐私约束：键里绝不能出现原文（剪贴板可能有密码/验证码）
        let key = ClipboardRejectionMemory.contentKey(forText: "password-123456")
        XCTAssertFalse(key.contains("password"))
        XCTAssertFalse(key.contains("123456"))
    }

    func testImageKeyIsStableForSameBytes() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(
            ClipboardRejectionMemory.contentKey(forImageData: data),
            ClipboardRejectionMemory.contentKey(forImageData: data)
        )
        XCTAssertNotEqual(
            ClipboardRejectionMemory.contentKey(forImageData: data),
            ClipboardRejectionMemory.contentKey(forImageData: Data([0x01, 0x02, 0x03, 0x05]))
        )
    }

    func testImageKeyIsEmptyForEmptyData() {
        XCTAssertEqual(ClipboardRejectionMemory.contentKey(forImageData: Data()), "")
    }

    // MARK: 拒绝记忆

    func testMarkAndQuery() {
        var memory = ClipboardRejectionMemory()
        let key = ClipboardRejectionMemory.contentKey(forText: "会议纪要")
        XCTAssertFalse(memory.isRejected(key))
        memory.markRejected(key)
        XCTAssertTrue(memory.isRejected(key))
    }

    func testMarkRejectedIgnoresDuplicates() {
        var memory = ClipboardRejectionMemory()
        let key = ClipboardRejectionMemory.contentKey(forText: "重复内容")
        memory.markRejected(key)
        memory.markRejected(key)
        XCTAssertEqual(memory.all.count, 1)
    }

    func testMarkRejectedIgnoresEmptyKey() {
        var memory = ClipboardRejectionMemory()
        memory.markRejected("")
        XCTAssertTrue(memory.all.isEmpty)
    }

    func testCapacityIsBoundedFIFO() {
        var memory = ClipboardRejectionMemory(capacity: 3)
        let keys = (1...5).map { ClipboardRejectionMemory.contentKey(forText: "内容\($0)") }
        for key in keys { memory.markRejected(key) }
        // 超出容量后丢最旧
        XCTAssertFalse(memory.isRejected(keys[0]))
        XCTAssertFalse(memory.isRejected(keys[1]))
        XCTAssertTrue(memory.isRejected(keys[2]))
        XCTAssertTrue(memory.isRejected(keys[3]))
        XCTAssertTrue(memory.isRejected(keys[4]))
        XCTAssertEqual(memory.all.count, 3)
    }

    func testRejectionMatchesAcrossEquivalentText() {
        // 同一条内容不同两端空白写法必须都命中
        var memory = ClipboardRejectionMemory()
        memory.markRejected(ClipboardRejectionMemory.contentKey(forText: "把账改成30"))
        XCTAssertTrue(memory.isRejected(ClipboardRejectionMemory.contentKey(forText: "  把账改成30　")))
    }
}
