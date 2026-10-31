import Foundation

/// 推理后端的稳定标识，以及它向编排层申报的能力位。
///
/// **为什么能力位要成数据而不是 if/else。** `LLMInferenceService` 里两条编排
/// （`generate` 与 `generateCustomTask`）各写了一遍「先端侧、再局域网 Ollama」，
/// 差异全埋在控制流里：端侧要先查 token 预算、超窗要单独降级到规则引擎、只有端侧挂得住
/// GBNF 文法、远程通道失败就静默跳过。这些判断散在两个函数中，新增一个后端就得两处都改，
/// 漏改不会编译报错，只会静默改变用户可观察的降级路径。写成后端自己的属性之后，
/// 编排读属性，新增后端必须显式回答这三问。
public enum InferenceBackendID: String, CaseIterable, Sendable {
    /// 端侧 GGUF + llama.cpp（Metal 全层加速）
    case onDeviceGguf
    /// 局域网 Ollama 联调通道
    case remoteOllama

    /// 能否挂 GBNF 自定义文法。Ollama 的 `api/generate` 没有文法入口，
    /// 该通道靠上层宽容解析与重试兜底——这是既有行为，不是本轮的退让。
    public var supportsGrammarConstraint: Bool {
        switch self {
        case .onDeviceGguf: return true
        case .remoteOllama: return false
        }
    }

    /// 装配提示词前是否必须先查 token 预算。
    /// 端侧窗口受模型画像上限约束；远程通道窗口充裕，原先就按 `budgetTokens: nil` 不裁剪。
    public var requiresTokenBudget: Bool {
        switch self {
        case .onDeviceGguf: return true
        case .remoteOllama: return false
        }
    }

    /// 上下文超窗时是否停止尝试、交给上层降级。
    /// 端侧必须停：截尾保留尾部，丢掉的是开头的 system 人格与排在最前的生活档案，
    /// 模型收到没有主人格的碎片却照样产出通顺答案，错误会静默变成答非所问。
    public var stopsOnContextOverflow: Bool {
        switch self {
        case .onDeviceGguf: return true
        case .remoteOllama: return false
        }
    }

    /// 尝试顺序，即用户可观察的降级路径：端侧优先，其次局域网 Ollama，
    /// 两者都拿不到结果才由上层兜到本机规则引擎。改这里的顺序是改产品行为。
    public static let attemptOrder: [InferenceBackendID] = [.onDeviceGguf, .remoteOllama]
}
