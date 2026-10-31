import XCTest
@testable import AssistantCore

/// 模型描述符与注册表的契约测试。
///
/// 与能力契约测试同构：这一族的断言全是**黄金快照**——被搬移的常量必须在搬移前后逐字相同，
/// 因为它们在真机上只表现为「文件无效」「下载失败」这类无从排查的短句。
final class ModelContractTests: XCTestCase {

    // MARK: - 注册表完整性

    func testRegistryValidatesClean() {
        XCTAssertEqual(ModelRegistry.validate(), [])
    }

    func testBuiltInOrderIsPinned() {
        // 顺序即「设置 → AI 模型」列表顺序，改它要显式承认
        XCTAssertEqual(ModelRegistry.builtIn.map(\.id), ["qwen3_1_7b", "qwen3_4b", "qwen2_5_1_5b"])
    }

    func testEveryCatalogEntryHasDescriptorAndViceVersa() {
        let registryIDs = Set(ModelRegistry.builtIn.map(\.id))
        XCTAssertEqual(registryIDs, Set(ModelReleaseCatalog.all.map(\.id)))
    }

    func testDescriptorCountMatchesCatalog() {
        XCTAssertEqual(ModelRegistry.builtIn.count, ModelReleaseCatalog.all.count)
    }

    // MARK: - 发布指纹配对（哈希本体由 ModelIntegrityTests 自检）

    func testPublishedReleasesResolveFromCatalog() {
        for model in ModelRegistry.builtIn {
            let entry = ModelReleaseCatalog.entry(id: model.id)
            XCTAssertEqual(model.publishedReleases, [entry?.integrity].compactMap { $0 })
            XCTAssertEqual(model.expectedSizeApproxBytes, entry?.byteSize)
        }
    }

    // MARK: - 黄金快照：文件名与体积阈值

    func testFileNamesArePinned() {
        // 已下载用户的磁盘上就是这些名字，改名等于让完好文件被判不存在
        let expected: [String: String] = [
            "qwen3_1_7b": "Qwen3-1.7B-Q4_K_M.gguf",
            "qwen3_4b": "Qwen3-4B-Q4_K_M.gguf",
            "qwen2_5_1_5b": "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        ]
        for model in ModelRegistry.builtIn {
            XCTAssertEqual(model.fileName, expected[model.id], model.id)
        }
    }

    func testMinValidSizesArePinned() {
        let expected: [String: Int64] = [
            "qwen3_1_7b": 900_000_000,
            "qwen3_4b": 2_000_000_000,
            "qwen2_5_1_5b": 850_000_000
        ]
        for model in ModelRegistry.builtIn {
            XCTAssertEqual(model.minValidSizeBytes, expected[model.id], model.id)
        }
    }

    // MARK: - 黄金快照：下载地址

    func testDownloadURLsArePinned() {
        let expected: [String: [ModelDownloadSourceID: String]] = [
            "qwen3_1_7b": [
                .modelScope: "https://www.modelscope.cn/models/unsloth/Qwen3-1.7B-GGUF/resolve/master/Qwen3-1.7B-Q4_K_M.gguf",
                .huggingFace: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf"
            ],
            "qwen3_4b": [
                .modelScope: "https://www.modelscope.cn/models/Qwen/Qwen3-4B-GGUF/resolve/master/Qwen3-4B-Q4_K_M.gguf",
                .huggingFace: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"
            ],
            "qwen2_5_1_5b": [
                .modelScope: "https://www.modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf",
                .huggingFace: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
            ]
        ]
        for model in ModelRegistry.builtIn {
            for source in ModelDownloadSourceID.allCases {
                XCTAssertEqual(
                    model.downloadURL(for: source).absoluteString,
                    expected[model.id]![source]!,
                    "\(model.id)/\(source.rawValue)"
                )
            }
        }
    }

    func testOllamaTagsArePinned() {
        let expected: [String: String] = [
            "qwen3_1_7b": "qwen3:1.7b",
            "qwen3_4b": "qwen3:4b",
            "qwen2_5_1_5b": "qwen2.5:1.5b"
        ]
        for model in ModelRegistry.builtIn {
            XCTAssertEqual(model.ollamaModelTag, expected[model.id], model.id)
        }
    }

    // MARK: - 黄金快照：UI 文案

    func testDisplayTextIsPinned() {
        let expected: [String: [String]] = [
            "qwen3_1_7b": [
                "Qwen3-1.7B-Instruct (推荐)", "Qwen3-1.7B",
                "新一代千问 Qwen3 架构 · 推理与指令遵循大幅提升，兼顾速度与低内存",
                "17.2 亿 (1.7B)", "约 1.11 GB", "约 1.2 GB"
            ],
            "qwen3_4b": [
                "Qwen3-4B-Instruct (增强版)", "Qwen3-4B",
                "40 亿参数高阶端侧模型 · 食物热量推断与复杂拆解更强（建议 8GB+ 内存机型）",
                "40.2 亿 (4.0B)", "约 2.50 GB", "约 2.6 GB"
            ],
            "qwen2_5_1_5b": [
                "Qwen2.5-1.5B-Instruct (轻量兼容)", "Qwen2.5-1.5B",
                "经典轻量端侧模型 · 体积最小，兼容旧版已下载模型文件",
                "15.4 亿 (1.54B)", "约 1.12 GB", "约 980 MB"
            ]
        ]
        for model in ModelRegistry.builtIn {
            let fields = [
                model.displayName, model.shortName, model.subtitle,
                model.parameterCountText, model.expectedSizeText, model.estimatedRAMText
            ]
            XCTAssertEqual(fields, expected[model.id]!, model.id)
        }
    }

    // MARK: - 黄金快照：ChatML 方言

    func testThinkBlockDialectsArePinned() {
        let qwen3 = Set(["qwen3_1_7b", "qwen3_4b"])
        for model in ModelRegistry.builtIn {
            let expectsClosedThink = qwen3.contains(model.id)
            XCTAssertEqual(
                model.chatDialect == .chatMLWithClosedThinkBlock,
                expectsClosedThink,
                model.id
            )
        }
    }

    func testAssistantStartSuffixIsExactChatML() {
        // 这段字符序列一旦改动，等价于给模型换了一套解码协议
        XCTAssertEqual(ModelChatDialect.plainChatML.assistantStartSuffix, "")
        XCTAssertEqual(
            ModelChatDialect.chatMLWithClosedThinkBlock.assistantStartSuffix,
            "\n<think>\n\n</think>\n\n"
        )
    }

    // MARK: - 黄金快照：推理画像

    func testInferenceProfilesArePinned() {
        // 这五个数 2026-10-30 从 `LlamaCppEngine` 的静态常量原值搬来，此前对所有 GGUF 一视同仁。
        // 逐字锁死是 C3 的等价性凭证：搬移只允许换「谁来声明」，不允许换值——
        // 窗口调大是内存决策（KV 缓存线性增长，低端机 jetsam），必须在真机验证后才能改。
        let expected = ModelInferenceProfile(
            maxContextTokens: 4096, fallbackContextTokens: 2048,
            topK: 40, topP: 0.90, temperature: 0.60
        )
        for model in ModelRegistry.builtIn {
            XCTAssertEqual(model.inference, expected, model.id)
        }
    }

    func testFileNameLookupResolvesTheSameDescriptor() {
        // 引擎只握着文件路径；按文件名反查必须命中同一个描述符，否则拿到的是别的模型的窗口
        for model in ModelRegistry.builtIn {
            XCTAssertEqual(ModelRegistry.descriptor(fileName: model.fileName)?.id, model.id)
        }
        XCTAssertNil(ModelRegistry.descriptor(fileName: "someone_elses_weights.gguf"))
    }

    // MARK: - validate 能抓到什么

    func testValidateFlagsDescriptorWithoutCatalogEntry() {
        let orphan = ModelDescriptor.qwen3_1_7b.replacing(id: "nonexistent_model")
        let issues = ModelRegistry.validate([orphan])
        XCTAssertTrue(issues.contains { $0.contains("没有已核验的发布条目") }, "\(issues)")
    }

    func testValidateFlagsMinSizeAboveReleaseSize() {
        let base = ModelRegistry.builtIn[0]
        let entry = ModelReleaseCatalog.entry(id: base.id)!
        let issues = ModelRegistry.validate([base.replacing(minValidSizeBytes: entry.byteSize + 1)])
        XCTAssertTrue(issues.contains { $0.contains("完整文件也会被判无效") }, "\(issues)")
    }

    func testValidateFlagsMissingDownloadSource() {
        let base = ModelRegistry.builtIn[0]
        let issues = ModelRegistry.validate([base.replacing(downloadURLs: [.modelScope: base.downloadURL(for: .modelScope)])])
        XCTAssertTrue(issues.contains { $0.contains("缺少 huggingFace 下载源") }, "\(issues)")
    }

    func testValidateFlagsPlainHTTPSourceAndFileNameMismatch() {
        let base = ModelRegistry.builtIn[0]
        let bad = base.replacing(downloadURLs: [
            .modelScope: URL(string: "http://example.com/other.gguf")!,
            .huggingFace: base.downloadURL(for: .huggingFace)
        ])
        let issues = ModelRegistry.validate([bad])
        XCTAssertTrue(issues.contains { $0.contains("不是 https") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("与本地文件名") }, "\(issues)")
    }

    func testValidateFlagsDuplicateFileName() {
        // 两个模型共用一个本地文件名：按文件名反查画像会静默命中第一个，
        // 于是第二个模型拿到不属于它的窗口去申请 KV 缓存
        let base = ModelRegistry.builtIn[0]
        let clashing = ModelRegistry.builtIn[1].replacing(fileName: base.fileName)
        let issues = ModelRegistry.validate([base, clashing])
        XCTAssertTrue(issues.contains { $0.contains("本地文件名与另一个模型重复") }, "\(issues)")
    }

    func testValidateFlagsFallbackContextAboveMax() {
        let base = ModelRegistry.builtIn[0]
        let bad = base.replacing(
            inference: ModelInferenceProfile(
                maxContextTokens: 2048, fallbackContextTokens: 4096,
                topK: 40, topP: 0.90, temperature: 0.60
            )
        )
        let issues = ModelRegistry.validate([bad])
        XCTAssertTrue(issues.contains { $0.contains("读不到训练窗时反而会开到超上限") }, "\(issues)")
    }

    func testValidateFlagsSamplingOutOfRange() {
        let base = ModelRegistry.builtIn[0]
        let badTopP = base.replacing(
            inference: ModelInferenceProfile(
                maxContextTokens: 4096, fallbackContextTokens: 2048,
                topK: 40, topP: 1.5, temperature: 0.60
            )
        )
        let badTopK = base.replacing(
            inference: ModelInferenceProfile(
                maxContextTokens: 4096, fallbackContextTokens: 2048,
                topK: 0, topP: 0.90, temperature: 0.60
            )
        )
        let topPIssues = ModelRegistry.validate([badTopP])
        XCTAssertTrue(topPIssues.contains { $0.contains("Top-P") }, "\(topPIssues)")
        let topKIssues = ModelRegistry.validate([badTopK])
        XCTAssertTrue(topKIssues.contains { $0.contains("Top-K") }, "\(topKIssues)")
    }
}

private extension ModelDescriptor {
    /// 只替换关心字段的副本，用于反向证明自检真的能抓到写错的常量
    func replacing(
        id: String? = nil,
        minValidSizeBytes: Int64? = nil,
        downloadURLs: [ModelDownloadSourceID: URL]? = nil,
        fileName: String? = nil,
        inference: ModelInferenceProfile? = nil
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: id ?? self.id,
            displayName: displayName, shortName: shortName, subtitle: subtitle,
            parameterCountText: parameterCountText, expectedSizeText: expectedSizeText,
            estimatedRAMText: estimatedRAMText, fileName: fileName ?? self.fileName,
            minValidSizeBytes: minValidSizeBytes ?? self.minValidSizeBytes,
            downloadURLs: downloadURLs ?? self.downloadURLs,
            chatDialect: chatDialect, ollamaModelTag: ollamaModelTag,
            inference: inference ?? self.inference
        )
    }
}
