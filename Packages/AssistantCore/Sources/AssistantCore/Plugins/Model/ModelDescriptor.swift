import Foundation

/// 一个端侧模型作为「插件」需要的全部静态事实。
///
/// **为什么需要它。** 这些事实原先挤在 App 侧 `LLMModelPreset` 的 10 个 `switch` 计算属性与
/// `downloadURL(for:)` 的 6 条手写 URL 里：新增一个模型要改 11 处，而其中文件名、SHA-256、
/// 下载地址都是**手抄的常量**——抄错一位的代价是所有下载被判「文件无效」，用户只看到四个字。
/// 下沉到 Core 后，这些常量在 `swift test` 阶段就有自检（见 `ModelRegistry.validate`）。
///
/// 与能力描述符同一套纪律：这里只放数据。下载、加载与推理参数仍归 App 侧引擎。
public struct ModelDescriptor: Sendable, Equatable {

    /// 稳定标识，与 App 侧 `LLMModelPreset.rawValue` 一一对应。
    /// 该值已持久化在 UserDefaults（`llm_selected_model_preset_v1`），**不能改名**。
    public let id: String

    // MARK: 展示

    /// 列表主标题（含推荐语）
    public let displayName: String
    /// 导航栏、状态栏与提示词里用的短名
    public let shortName: String
    /// 能力与适用机型说明
    public let subtitle: String
    /// 参数规模文案
    public let parameterCountText: String
    /// 文件体积可读说明
    public let expectedSizeText: String
    /// 运行内存预估说明
    public let estimatedRAMText: String

    // MARK: 文件与发布

    /// 本地存储文件名
    public let fileName: String
    /// 完整性校验的最小合法字节数；低于它必定是没下完或拿错了文件
    public let minValidSizeBytes: Int64
    /// 各下载源地址。缺源属于注册错误。
    public let downloadURLs: [ModelDownloadSourceID: URL]

    // MARK: 推理侧元数据

    /// ChatML 解码方言
    public let chatDialect: ModelChatDialect
    /// 对应的局域网 Ollama 模型 tag
    public let ollamaModelTag: String
    /// 上下文窗口与采样参数
    public let inference: ModelInferenceProfile

    public init(
        id: String,
        displayName: String,
        shortName: String,
        subtitle: String,
        parameterCountText: String,
        expectedSizeText: String,
        estimatedRAMText: String,
        fileName: String,
        minValidSizeBytes: Int64,
        downloadURLs: [ModelDownloadSourceID: URL],
        chatDialect: ModelChatDialect,
        ollamaModelTag: String,
        inference: ModelInferenceProfile
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.subtitle = subtitle
        self.parameterCountText = parameterCountText
        self.expectedSizeText = expectedSizeText
        self.estimatedRAMText = estimatedRAMText
        self.fileName = fileName
        self.minValidSizeBytes = minValidSizeBytes
        self.downloadURLs = downloadURLs
        self.chatDialect = chatDialect
        self.ollamaModelTag = ollamaModelTag
        self.inference = inference
    }

    // MARK: 由发布清单派生（清单本体在 `ModelReleaseCatalog`）

    /// 已核验的发布产物指纹
    public var publishedReleases: [ModelReleaseIntegrity] {
        guard let entry = ModelReleaseCatalog.entry(id: id) else { return [] }
        return [entry.integrity]
    }

    /// 预期字节大小（取发布产物精确体积，不用估算值）
    public var expectedSizeApproxBytes: Int64 {
        publishedReleases.first?.byteSize ?? 0
    }

    /// 取指定源的下载地址
    public func downloadURL(for source: ModelDownloadSourceID) -> URL {
        guard let url = downloadURLs[source] else {
            preconditionFailure("模型 \(id) 未配置下载源 \(source.rawValue)")
        }
        return url
    }
}
