import Foundation

/// 视觉模型包里的一个文件部件。
///
/// **为什么不是一个模型一个文件。** 对话模型只需一个 GGUF；带图的模型在 llama.cpp 里是
/// 「语言模型 GGUF + mmproj（视觉编码器）GGUF」两个产物，`mtmd_init_from_file()` 只吃 mmproj，
/// 图像嵌入再由它写进语言模型的上下文。两者缺一都跑不起来，所以按部件建模，
/// 下载、校验、删除都以部件为粒度，「包已就绪」= 全部部件各自校验通过。
public struct VisionModelPart: Sendable, Equatable {

    public enum Role: String, Sendable, CaseIterable {
        /// 语言模型权重：文本与图像嵌入共同的解码器
        case languageModel
        /// 视觉编码器（mmproj）：把像素编码成图像 token 的嵌入
        case visionProjector
    }

    /// 与 `ModelReleaseCatalog.visionAll` 一一对应的稳定标识
    public let id: String
    public let role: Role
    /// UI 行标题，说明这一路文件是谁
    public let displayName: String
    /// 本地存储文件名（与下载地址末段一致，由 `validate()` 锁死）
    public let fileName: String
    /// 体积下限：低于它必定是没下完或拿错了文件
    public let minValidSizeBytes: Int64
    /// 各下载源地址。视觉包允许**少于**全部源——上游核验不到 HF 时只挂 ModelScope，
    /// 比「两条都配、其中一条没核过指纹」诚实。
    public let downloadURLs: [ModelDownloadSourceID: URL]

    public init(
        id: String,
        role: Role,
        displayName: String,
        fileName: String,
        minValidSizeBytes: Int64,
        downloadURLs: [ModelDownloadSourceID: URL]
    ) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.fileName = fileName
        self.minValidSizeBytes = minValidSizeBytes
        self.downloadURLs = downloadURLs
    }

    /// 已核验的发布产物指纹
    public var publishedReleases: [ModelReleaseIntegrity] {
        ModelReleaseCatalog.entry(id: id).map { [$0.integrity] } ?? []
    }

    /// 发布方标注的精确字节数
    public var expectedSizeBytes: Int64 {
        publishedReleases.first?.byteSize ?? 0
    }

    /// 实际配了地址的下载源（UI 的节点选择器按这个渲染，不展示没核验过的源）
    public var availableSources: [ModelDownloadSourceID] {
        ModelDownloadSourceID.allCases.filter { downloadURLs[$0] != nil }
    }

    /// 取指定源的地址；没配返回 nil，由调用方决定降级，而不是崩溃
    public func downloadURL(for source: ModelDownloadSourceID) -> URL? {
        downloadURLs[source]
    }
}

/// 一个视觉模型包：部件清单 + 展示文案 + 推理画像。
///
/// 与 `ModelDescriptor` 的关键区别是它**不参与对话模型单选**：VL 权重虽然能续写文本，
/// 但它的定位是「看图说菜名和估重」，把它放进「切换端侧模型规格」列表会让用户以为
/// 换了模型日常问答也走它——那是错的（图像 token 会把上下文预算吃光，且回答风格不同）。
public struct VisionModelBundle: Sendable, Equatable {

    public let id: String
    public let displayName: String
    public let shortName: String
    /// 能力与适用机型说明
    public let subtitle: String
    /// 用途说明：这台设备上它替谁干活
    public let usageNote: String
    public let parameterCountText: String
    /// 运行内存预估说明（未实测的必须写成区间/估算，不能写成结论）
    public let estimatedRAMText: String
    public let parts: [VisionModelPart]
    public let inference: ModelInferenceProfile

    /// 单张图允许的图像 token 上限。
    ///
    /// Qwen-VL 系是动态分辨率：图越大，图像 token 越多，prompt 处理的显存峰值跟着涨。
    /// 取默认值（读模型元数据）会在 4GB 内存机型上把窗口和显存一起吃掉，
    /// 所以上限由这里声明；识别食物菜名不需要看清盘中细小文字，512 够。
    public let imageMaxTokens: Int

    public init(
        id: String,
        displayName: String,
        shortName: String,
        subtitle: String,
        usageNote: String,
        parameterCountText: String,
        estimatedRAMText: String,
        parts: [VisionModelPart],
        inference: ModelInferenceProfile,
        imageMaxTokens: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.subtitle = subtitle
        self.usageNote = usageNote
        self.parameterCountText = parameterCountText
        self.estimatedRAMText = estimatedRAMText
        self.parts = parts
        self.inference = inference
        self.imageMaxTokens = imageMaxTokens
    }

    /// 全包体积（各部件发布体积之和）
    public var totalSizeBytes: Int64 {
        parts.reduce(0) { $0 + $1.expectedSizeBytes }
    }

    /// 各部件共同支持的下载源：只有每个部件都有的源才算可用
    public var availableSources: [ModelDownloadSourceID] {
        guard let first = parts.first else { return [] }
        return first.availableSources.filter { source in
            parts.allSatisfy { $0.downloadURLs[source] != nil }
        }
    }

    public func part(role: VisionModelPart.Role) -> VisionModelPart? {
        parts.first { $0.role == role }
    }
}

extension VisionModelBundle {

    /// Qwen3-VL-2B-Instruct · Q4_K_M + mmproj Q8_0（专用于照片识别）
    public static let qwen3Vl2BInstruct = VisionModelBundle(
        id: "qwen3_vl_2b",
        displayName: "Qwen3-VL-2B-Instruct (图像识别专用)",
        shortName: "Qwen3-VL-2B",
        subtitle: "带视觉编码器的千问多模态模型 · 直接看照片认菜名与份量（建议 6GB+ 内存机型）",
        usageNote: "用于「拍照算热量」：认出菜名并估重，替代通用图像分类器只能报 1,303 个泛类标签的上限。不参与日常问答。",
        parameterCountText: "21 亿 (2.0B) + 视觉编码器",
        estimatedRAMText: "约 2.6–3.2 GB（含图像编码，待真机实测）",
        parts: [
            VisionModelPart(
                id: "qwen3_vl_2b_llm",
                role: .languageModel,
                displayName: "语言模型 Q4_K_M",
                fileName: "Qwen3VL-2B-Instruct-Q4_K_M.gguf",
                minValidSizeBytes: 900_000_000,
                downloadURLs: [
                    .modelScope: URL(string: "https://www.modelscope.cn/models/Qwen/Qwen3-VL-2B-Instruct-GGUF/resolve/master/Qwen3VL-2B-Instruct-Q4_K_M.gguf")!
                ]
            ),
            VisionModelPart(
                id: "qwen3_vl_2b_mmproj",
                role: .visionProjector,
                displayName: "视觉编码器 mmproj Q8_0",
                fileName: "mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf",
                minValidSizeBytes: 350_000_000,
                downloadURLs: [
                    .modelScope: URL(string: "https://www.modelscope.cn/models/Qwen/Qwen3-VL-2B-Instruct-GGUF/resolve/master/mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf")!
                ]
            )
        ],
        // 采样参数按「看图报事实」调低温度：视觉描述要稳定复现菜名与克数，
        // 不需要对话那样的多样性。窗口与图像 token 上限是内存决策，待真机验证。
        inference: ModelInferenceProfile(
            maxContextTokens: 8192, fallbackContextTokens: 4096,
            topK: 40, topP: 0.80, temperature: 0.20
        ),
        imageMaxTokens: 512
    )
}

/// 内置视觉模型注册表：一个包 = 一段描述符 + 这里的一行。
public enum VisionModelRegistry {

    public static let builtIn: [VisionModelBundle] = [
        .qwen3Vl2BInstruct
    ]

    /// 当前用于照片识别的包。今天只有一个，留一层查表是为了不让调用方写死下标。
    public static var defaultBundle: VisionModelBundle { builtIn[0] }

    public static func bundle(id: String) -> VisionModelBundle? {
        builtIn.first { $0.id == id }
    }

    /// 按本地文件名反查推理画像（引擎只握着文件 URL，握不住包 id）。
    /// 返回 nil 表示这是注册表里没有的 GGUF，调用方应退回默认画像而不是猜。
    public static func inferenceProfile(fileName: String) -> ModelInferenceProfile? {
        for bundle in builtIn where bundle.parts.contains(where: { $0.fileName == fileName }) {
            return bundle.inference
        }
        return nil
    }

    /// 返回注册表自身的不一致项；空数组表示契约完整。
    ///
    /// 与 `ModelRegistry.validate()` 同一套纪律：查的全是手抄常量能出错的地方，
    /// 而这些错的运行期表现只有「文件无效」四个字。
    public static func validate() -> [String] {
        validate(builtIn)
    }

    public static func validate(_ bundles: [VisionModelBundle]) -> [String] {
        var issues: [String] = []
        var seen = Set<String>()
        var seenFileNames = Set<String>()
        let claimedIDs = Set(bundles.flatMap { $0.parts.map(\.id) })

        for bundle in bundles {
            if !seen.insert(bundle.id).inserted {
                issues.append("视觉包重复注册：\(bundle.id)")
            }
            let displayFields: [(String, String)] = [
                ("displayName", bundle.displayName),
                ("shortName", bundle.shortName),
                ("subtitle", bundle.subtitle),
                ("usageNote", bundle.usageNote),
                ("parameterCountText", bundle.parameterCountText),
                ("estimatedRAMText", bundle.estimatedRAMText)
            ]
            for (field, text) in displayFields where text.isEmpty {
                issues.append("\(bundle.id) 的 \(field) 为空")
            }
            if bundle.imageMaxTokens <= 0 {
                issues.append("\(bundle.id) 的图像 token 上限必须为正：\(bundle.imageMaxTokens)")
            }
            if bundle.inference.maxContextTokens <= bundle.imageMaxTokens {
                issues.append("\(bundle.id) 的上下文上限 \(bundle.inference.maxContextTokens) 不大于图像 token 上限 \(bundle.imageMaxTokens)，一张图就能把提示词预算吃光")
            }

            // 部件必须恰好覆盖「语言模型 + 视觉编码器」各一个：少一个跑不起来，多一个没意义
            for role in VisionModelPart.Role.allCases {
                let matches = bundle.parts.filter { $0.role == role }
                if matches.isEmpty {
                    issues.append("\(bundle.id) 缺少 \(role.rawValue) 部件，这个包无法完成图像推理")
                } else if matches.count > 1 {
                    issues.append("\(bundle.id) 有 \(matches.count) 个 \(role.rawValue) 部件，引擎不知道该加载哪一个")
                }
            }

            for part in bundle.parts {
                if !seenFileNames.insert(part.fileName).inserted {
                    issues.append("\(bundle.id)/\(part.id) 的本地文件名与另一个部件重复：\(part.fileName)")
                }
                if !part.fileName.hasSuffix(".gguf") {
                    issues.append("\(bundle.id)/\(part.id) 的本地文件名不是 GGUF：\(part.fileName)")
                }
                guard let entry = ModelReleaseCatalog.entry(id: part.id) else {
                    issues.append("\(bundle.id)/\(part.id) 有部件描述但没有已核验的发布条目")
                    continue
                }
                if part.minValidSizeBytes >= entry.byteSize {
                    issues.append("\(bundle.id)/\(part.id) 的最小合法体积 \(part.minValidSizeBytes) 不小于发布体积 \(entry.byteSize)，完整文件也会被判无效")
                }
                if part.downloadURLs.isEmpty {
                    issues.append("\(bundle.id)/\(part.id) 一个下载源都没有")
                }
                for (source, url) in part.downloadURLs {
                    if url.scheme != "https" {
                        issues.append("\(bundle.id)/\(part.id) 的 \(source.rawValue) 地址不是 https：\(url.absoluteString)")
                    }
                    if url.lastPathComponent != part.fileName {
                        issues.append("\(bundle.id)/\(part.id) 的 \(source.rawValue) 文件名「\(url.lastPathComponent)」与本地文件名「\(part.fileName)」不一致")
                    }
                }
            }
        }

        for entry in ModelReleaseCatalog.visionAll where !claimedIDs.contains(entry.id) {
            issues.append("视觉发布条目 \(entry.id) 没有对应部件")
        }
        return issues
    }
}
