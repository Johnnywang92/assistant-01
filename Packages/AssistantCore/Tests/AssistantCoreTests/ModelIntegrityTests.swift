import XCTest
@testable import AssistantCore

/// 模型发布指纹比对器的回归测试。
///
/// 这块逻辑直接决定「用户的 1GB 模型文件算不算通过」，
/// 判据一旦漂移就是静默的数据信任问题，所以边界逐条钉死。
final class ModelIntegrityTests: XCTestCase {

    private let release = ModelReleaseIntegrity(
        releaseVersion: "unsloth/Qwen3-1.7B-GGUF@1e3f4948",
        byteSize: 1_107_409_472,
        sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897"
    )

    private let otherDigest = "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"

    // MARK: - 判定

    func testExactReleaseIsMatched() {
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: release.byteSize,
            actualDigest: release.sha256,
            releases: [release]
        )
        XCTAssertEqual(verdict, .matched(release))
        XCTAssertTrue(verdict.isAcceptable)
        XCTAssertTrue(verdict.isBackedByPublishedRelease)
        XCTAssertNil(verdict.failureKind)
    }

    func testSameSizeDifferentDigestIsDigestMismatch() {
        // 体积一样但内容不同 = 拿到了别的文件（不是「没下完」）
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: release.byteSize,
            actualDigest: otherDigest,
            releases: [release]
        )
        XCTAssertEqual(verdict, .digestMismatch(expected: [release.sha256], actual: otherDigest))
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(verdict.failureKind, .digestMismatch)
    }

    func testTruncatedFileIsSizeMismatch() {
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: release.byteSize - 4096,
            actualDigest: "deadbeef",
            releases: [release]
        )
        XCTAssertEqual(verdict, .sizeMismatch(expected: [release.byteSize], actual: release.byteSize - 4096))
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(verdict.failureKind, .sizeMismatch)
    }

    func testEmptyReleaseListMeansNoPublishedBacking() {
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: release.byteSize,
            actualDigest: release.sha256,
            releases: []
        )
        XCTAssertEqual(verdict, .noPublishedRelease)
        // 无背书 ≠ 不可用，但要能和「已核验」区分开
        XCTAssertTrue(verdict.isAcceptable)
        XCTAssertFalse(verdict.isBackedByPublishedRelease)
        XCTAssertNil(verdict.failureKind)
    }

    func testDigestComparisonIgnoresCaseAndWhitespace() {
        let messy = "  " + release.sha256.uppercased() + "\n"
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: release.byteSize,
            actualDigest: messy,
            releases: [release]
        )
        XCTAssertEqual(verdict, .matched(release))
    }

    func testMultipleAcceptedReleasesAllMatch() {
        // 上游重新量化时是「追加」而不是「替换」——旧版本仍应被认作合法产物
        let second = ModelReleaseIntegrity(
            releaseVersion: "unsloth/Qwen3-1.7B-GGUF@republish",
            byteSize: release.byteSize,
            sha256: otherDigest
        )
        XCTAssertEqual(
            ModelIntegrityEvaluator.evaluate(actualSize: second.byteSize, actualDigest: otherDigest, releases: [release, second]),
            .matched(second)
        )
    }

    func testDigestMismatchReportsAllExpectedDigests() {
        let second = ModelReleaseIntegrity(
            releaseVersion: "second",
            byteSize: release.byteSize,
            sha256: otherDigest
        )
        let verdict = ModelIntegrityEvaluator.evaluate(
            actualSize: release.byteSize,
            actualDigest: "00112233",
            releases: [release, second]
        )
        guard case .digestMismatch(let expected, _) = verdict else {
            return XCTFail("体积相同应判为校验值不符，实际：\(verdict)")
        }
        XCTAssertEqual(expected.count, 2)
    }

    // MARK: - 清单自检

    func testWellFormedReleasePasses() {
        XCTAssertTrue(ModelIntegrityEvaluator.isWellFormed(release))
    }

    func testMalformedDigestIsRejected() {
        // 哈希抄错一位 → 清单自身不合法，必须在发布前就被发现，
        // 否则所有用户都会看到「文件无效」却查不出原因
        XCTAssertFalse(ModelIntegrityEvaluator.isWellFormed(
            ModelReleaseIntegrity(releaseVersion: "x", byteSize: 100, sha256: "abc123")
        ))
        XCTAssertFalse(ModelIntegrityEvaluator.isWellFormed(
            ModelReleaseIntegrity(releaseVersion: "x", byteSize: 100, sha256: String(repeating: "z", count: 64))
        ))
    }

    func testNonPositiveSizeIsRejected() {
        XCTAssertFalse(ModelIntegrityEvaluator.isWellFormed(
            ModelReleaseIntegrity(releaseVersion: "x", byteSize: 0, sha256: String(repeating: "a", count: 64))
        ))
    }

    func testEmptyReleaseVersionIsRejected() {
        XCTAssertFalse(ModelIntegrityEvaluator.isWellFormed(
            ModelReleaseIntegrity(releaseVersion: "", byteSize: 100, sha256: String(repeating: "a", count: 64))
        ))
    }

    func testNormalizeDigestTrimsAndLowercases() {
        XCTAssertEqual(ModelIntegrityEvaluator.normalizeDigest("  ABCdef\n"), "abcdef")
    }

    // MARK: - 发布清单自检（防手抄错误）

    /// 清单里的哈希是手抄常量：抄错一位会让所有下载全被判「文件无效」。
    /// 这条断言是发布前的最后一道闸。
    func testPublishedCatalogEntriesAreWellFormed() {
        for entry in ModelReleaseCatalog.all {
            XCTAssertTrue(
                ModelIntegrityEvaluator.isWellFormed(entry.integrity),
                "发布清单条目格式非法：\(entry.id)"
            )
        }
    }

    func testPublishedCatalogIdsAreUnique() {
        let ids = ModelReleaseCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "发布清单存在重复 id")
    }

    func testPublishedCatalogDigestsAreUnique() {
        let digests = ModelReleaseCatalog.all.map { ModelIntegrityEvaluator.normalizeDigest($0.sha256) }
        XCTAssertEqual(Set(digests).count, digests.count, "发布清单存在重复哈希")
    }

    func testPublishedCatalogEntryLookupById() {
        for entry in ModelReleaseCatalog.all {
            XCTAssertEqual(ModelReleaseCatalog.entry(id: entry.id), entry)
        }
        XCTAssertNil(ModelReleaseCatalog.entry(id: "not_a_model"))
    }

    func testPublishedCatalogSizesMatchRealPublishedBytes() {
        // 钉住三个模型的精确体积：体积用于「没下完」的快速判定，
        // 与发布方标注不一致会让正常的下载被误判为截断。
        XCTAssertEqual(ModelReleaseCatalog.qwen3_1_7b.byteSize, 1_107_409_472)
        XCTAssertEqual(ModelReleaseCatalog.qwen3_4b.byteSize, 2_497_280_256)
        XCTAssertEqual(ModelReleaseCatalog.qwen2_5_1_5b.byteSize, 1_117_320_736)
    }

    func testEachCatalogEntryMatchesItself() {
        for entry in ModelReleaseCatalog.all {
            let verdict = ModelIntegrityEvaluator.evaluate(
                actualSize: entry.byteSize,
                actualDigest: entry.sha256,
                releases: [entry.integrity]
            )
            XCTAssertEqual(verdict, .matched(entry.integrity))
        }
    }
}
