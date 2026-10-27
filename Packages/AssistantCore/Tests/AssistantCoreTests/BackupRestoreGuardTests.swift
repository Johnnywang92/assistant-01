import XCTest
@testable import AssistantCore

/// 备份 / 还原的故障注入测试。
///
/// 这里测的不是「正常路径能不能跑通」，而是**故障路径会不会骗人**：
/// 附件读不到时会不会假装成功、引用集查询失败时会不会把文件删光、
/// 数据少导入几条时会不会被报告成「还原成功」。
/// 这三类都是**静默**的——用户拿到手时毫无察觉，损失事后才发现。
final class BackupRestoreGuardTests: XCTestCase {

    private typealias Guard = BackupRestoreGuard

    // MARK: - 附件核对

    /// 正常情况：所有该带的附件都带上了
    func testAttachmentAuditCompleteWhenAllDataPresent() {
        let audit = Guard.auditAttachments([
            Guard.AttachmentExpectation(ownerTitle: "身份证", kind: .idPhotoFront, fileName: "a.jpg", hasData: true),
            Guard.AttachmentExpectation(ownerTitle: "身份证", kind: .idPhotoBack, fileName: "b.jpg", hasData: true)
        ])
        XCTAssertEqual(audit, .complete)
    }

    /// 记录本来就没有附件 → 不算缺失（否则会给用户报一堆假警报）
    func testAttachmentAuditIgnoresItemsWithoutAttachment() {
        let audit = Guard.auditAttachments([
            Guard.AttachmentExpectation(ownerTitle: "护照", kind: .idPhotoFront, fileName: nil, hasData: false),
            Guard.AttachmentExpectation(ownerTitle: "护照", kind: .idPhotoBack, fileName: nil, hasData: false)
        ])
        XCTAssertEqual(audit, .complete)
    }

    /// 故障注入：文件存在但读不出字节 → 必须判为缺失，不能放过
    func testAttachmentAuditDetectsUnreadableFile() {
        let expectation = Guard.AttachmentExpectation(
            ownerTitle: "身份证", kind: .idPhotoFront, fileName: "a.jpg", hasData: false
        )
        let audit = Guard.auditAttachments([expectation])
        XCTAssertEqual(audit, .incomplete(missing: [expectation]))
    }

    func testAttachmentAuditReportsEveryMissingItem() {
        let front = Guard.AttachmentExpectation(ownerTitle: "身份证", kind: .idPhotoFront, fileName: "a.jpg", hasData: false)
        let audio = Guard.AttachmentExpectation(ownerTitle: "备忘", kind: .voiceMemoAudio, fileName: "m.m4a", hasData: false)
        let ok = Guard.AttachmentExpectation(ownerTitle: "护照", kind: .idPhotoBack, fileName: "b.jpg", hasData: true)
        let audit = Guard.auditAttachments([front, audio, ok])
        guard case .incomplete(let missing) = audit else {
            return XCTFail("应判为不完整，实际：\(audit)")
        }
        XCTAssertEqual(missing.count, 2)
    }

    /// 缺失描述要能指认到具体条目，且同一证件的两面不刷屏
    func testDescribeMissingAttachmentsDeduplicates() {
        let items = [
            Guard.AttachmentExpectation(ownerTitle: "身份证", kind: .idPhotoFront, fileName: "a.jpg", hasData: false),
            Guard.AttachmentExpectation(ownerTitle: "身份证", kind: .idPhotoFront, fileName: "a2.jpg", hasData: false),
            Guard.AttachmentExpectation(ownerTitle: "备忘", kind: .voiceMemoAudio, fileName: "m.m4a", hasData: false)
        ]
        let described = Guard.describeMissingAttachments(items)
        XCTAssertEqual(described.count, 2)
        XCTAssertTrue(described.contains { $0.contains("身份证") })
        XCTAssertTrue(described.contains { $0.contains("备忘") })
    }

    // MARK: - 孤儿文件清理闸

    /// 故障注入：引用集查询失败 → 必须跳过清理。
    /// 旧实现拿空集合去「保留」，等于把用户的证件照片和语音全删光。
    func testPruneIsSkippedWhenReferenceLookupFails() {
        let decision = Guard.pruneDecision(referenceLookupSucceeded: false, referencedFileNames: [])
        XCTAssertEqual(decision, .skipped(reason: .referenceLookupFailed))
    }

    /// 查询成功但确实没有引用文件 → 无需清理（清也是空转）
    func testPruneIsSkippedWhenNoReferences() {
        let decision = Guard.pruneDecision(referenceLookupSucceeded: true, referencedFileNames: [])
        XCTAssertEqual(decision, .skipped(reason: .noReferences))
    }

    func testPruneKeepsReferencedFiles() {
        let decision = Guard.pruneDecision(referenceLookupSucceeded: true, referencedFileNames: ["a.jpg", "m.m4a"])
        XCTAssertEqual(decision, .prune(keeping: ["a.jpg", "m.m4a"]))
    }

    /// 故障注入：查询失败时即便拿到了部分引用，也一样不清——
    /// 部分引用集同样会误删「没被查到」的那部分文件。
    func testPruneIsSkippedEvenWithPartialReferenceSet() {
        let decision = Guard.pruneDecision(referenceLookupSucceeded: false, referencedFileNames: ["a.jpg"])
        XCTAssertEqual(decision, .skipped(reason: .referenceLookupFailed))
    }

    // MARK: - 导入结果台账

    func testImportVerdictCompleteWhenAllImported() {
        let verdict = Guard.importVerdict([
            Guard.ImportExpectation(key: "todos", expectedCount: 10, importedCount: 10)
        ])
        XCTAssertEqual(verdict, .complete)
    }

    /// 合并策略：本机已有的被跳过，不算丢失
    func testImportVerdictTreatsAlreadyPresentAsNotLost() {
        let verdict = Guard.importVerdict([
            Guard.ImportExpectation(key: "todos", expectedCount: 10, importedCount: 4, alreadyPresentCount: 6)
        ])
        XCTAssertEqual(verdict, .complete)
    }

    /// 故障注入：少导入了几条 → 必须判为部分成功，不能报告成全量成功
    func testImportVerdictDetectsShortfall() {
        let verdict = Guard.importVerdict([
            Guard.ImportExpectation(key: "todos", expectedCount: 10, importedCount: 8),
            Guard.ImportExpectation(key: "expenses", expectedCount: 5, importedCount: 5)
        ])
        XCTAssertEqual(verdict, .partial(missingByKey: ["todos": 2]))
    }

    /// 导入数比预期还多（重复导入等）→ 不该报缺失
    func testImportVerdictIgnoresSurplus() {
        let verdict = Guard.importVerdict([
            Guard.ImportExpectation(key: "todos", expectedCount: 3, importedCount: 5)
        ])
        XCTAssertEqual(verdict, .complete)
    }

    /// 重复 key 不能让台账崩溃（`Dictionary(uniqueKeysWithValues:)` 会 trap）
    func testImportVerdictHandlesDuplicateKeys() {
        let verdict = Guard.importVerdict([
            Guard.ImportExpectation(key: "todos", expectedCount: 10, importedCount: 8),
            Guard.ImportExpectation(key: "todos", expectedCount: 10, importedCount: 9)
        ])
        guard case .partial(let missing) = verdict else {
            return XCTFail("应判为部分成功，实际：\(verdict)")
        }
        XCTAssertEqual(missing["todos"], 1)
    }
}
