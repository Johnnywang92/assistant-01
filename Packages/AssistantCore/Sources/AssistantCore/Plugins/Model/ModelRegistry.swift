import Foundation

/// 内置模型注册表：一个模型 = 一个描述符条目 + 这里的一行。
///
/// 注册顺序即「设置 → AI 模型」的列表顺序（与 `LLMModelPreset.allCases` 一致）。
public enum ModelRegistry {

    public static let builtIn: [ModelDescriptor] = [
        .qwen3_1_7b,
        .qwen3_4b,
        .qwen2_5_1_5b
    ]

    public static func descriptor(id: String) -> ModelDescriptor? {
        builtIn.first { $0.id == id }
    }

    /// 按本地文件名反查描述符。
    ///
    /// 引擎侧只握着模型文件的 URL，握不住 preset / id；`validate()` 已经锁死「下载地址的
    /// 文件名 == 描述符的 fileName」，所以文件名是引擎唯一可靠拿到画像的入口。
    /// 返回 nil 表示这是用户自行导入的、注册表里没有的 GGUF——调用方此时应当退回自己的默认值，
    /// 而不是猜一个画像。
    public static func descriptor(fileName: String) -> ModelDescriptor? {
        builtIn.first { $0.fileName == fileName }
    }

    /// 返回注册表自身的不一致项；空数组表示契约完整。测试与调试入口共用。
    ///
    /// 这里查的全是**手抄常量**能出错的形状：地址抄错一位、最小体积写得比真实体积还大、
    /// 描述符与发布清单对不上号——这些今天都只会表现为「文件无效」四个字，
    /// 用户在设备端根本查不出原因，所以必须在发布前判红。
    public static func validate() -> [String] {
        validate(builtIn)
    }

    /// 对任意描述符集合跑同一套自检，让「注册写错」能在测试里被反向证明。
    public static func validate(_ models: [ModelDescriptor]) -> [String] {
        var issues: [String] = []
        var seen = Set<String>()
        var seenFileNames = Set<String>()
        let registered = Set(models.map(\.id))
        for model in models {
            if !seen.insert(model.id).inserted {
                issues.append("模型重复注册：\(model.id)")
            }
            if !seenFileNames.insert(model.fileName).inserted {
                issues.append("\(model.id) 的本地文件名与另一个模型重复：\(model.fileName)。引擎按文件名反查推理画像，重复会让它静默拿到另一个模型的窗口")
            }
            let displayFields: [(String, String)] = [
                ("displayName", model.displayName),
                ("shortName", model.shortName),
                ("subtitle", model.subtitle),
                ("parameterCountText", model.parameterCountText),
                ("expectedSizeText", model.expectedSizeText),
                ("estimatedRAMText", model.estimatedRAMText)
            ]
            for (field, text) in displayFields where text.isEmpty {
                issues.append("\(model.id) 的 \(field) 为空")
            }
            guard let entry = ModelReleaseCatalog.entry(id: model.id) else {
                issues.append("\(model.id) 有描述符但没有已核验的发布条目")
                continue
            }
            if !model.fileName.hasSuffix(".gguf") {
                issues.append("\(model.id) 的本地文件名不是 GGUF：\(model.fileName)")
            }
            if model.minValidSizeBytes >= entry.byteSize {
                issues.append("\(model.id) 的最小合法体积 \(model.minValidSizeBytes) 不小于发布体积 \(entry.byteSize)，完整文件也会被判无效")
            }
            for source in ModelDownloadSourceID.allCases {
                guard let url = model.downloadURLs[source] else {
                    issues.append("\(model.id) 缺少 \(source.rawValue) 下载源")
                    continue
                }
                if url.scheme != "https" {
                    issues.append("\(model.id) 的 \(source.rawValue) 地址不是 https：\(url.absoluteString)")
                }
                if url.lastPathComponent != model.fileName {
                    issues.append("\(model.id) 的 \(source.rawValue) 文件名「\(url.lastPathComponent)」与本地文件名「\(model.fileName)」不一致")
                }
            }
            if !model.ollamaModelTag.contains(":") {
                issues.append("\(model.id) 的 Ollama tag 缺少版本分隔符：\(model.ollamaModelTag)")
            }
            let inference = model.inference
            if inference.maxContextTokens <= 0 {
                issues.append("\(model.id) 的上下文上限必须为正：\(inference.maxContextTokens)")
            }
            if inference.fallbackContextTokens > inference.maxContextTokens {
                issues.append("\(model.id) 的兜底窗口 \(inference.fallbackContextTokens) 大于上限 \(inference.maxContextTokens)，读不到训练窗时反而会开到超上限")
            }
            if inference.topK <= 0 {
                issues.append("\(model.id) 的 Top-K 必须为正：\(inference.topK)")
            }
            if inference.topP <= 0 || inference.topP > 1 {
                issues.append("\(model.id) 的 Top-P 要在 (0, 1] 内：\(inference.topP)")
            }
            if inference.temperature < 0 {
                issues.append("\(model.id) 的采样温度不能为负：\(inference.temperature)")
            }
        }
        for entry in ModelReleaseCatalog.all where !registered.contains(entry.id) {
            issues.append("发布条目 \(entry.id) 没有对应描述符")
        }
        return issues
    }
}
