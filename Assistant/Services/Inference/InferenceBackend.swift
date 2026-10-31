import AssistantCore
import Foundation

/// 一次后端调用的输入。
///
/// 字段不平均是刻意的：`modelURL` 只有端侧后端读，`remote` 只有远程后端读。
/// 后端由注册表持有（无状态、可在任意线程调用），而端点、模型名、GGUF 路径都要在
/// `@MainActor` 上从 `LLMModelManager` / `@AppStorage` 取——所以由服务在主 actor 上
/// 一次性解析好塞进请求，而不是让后端自己去读主 actor 状态。
struct InferenceRequest: Sendable {
    let prompt: String
    /// 端侧要加载的 GGUF 路径
    let modelURL: URL
    /// 生成长度上限。这是任务事实（各模块 40–400 不等），不属于模型画像，由调用点决定。
    let maxNewTokens: Int
    /// GBNF 文法。编排层只会给 `supportsGrammarConstraint` 的后端填这里。
    let grammar: String?
    /// 局域网 Ollama 的目标；`nil` 表示未授权或端点无效，远程后端据此判定不可用
    let remote: RemoteOllamaTarget?
    /// 流式增量回调（两个入口给的是同一个闭包）
    let onPartialOutput: @Sendable (String) async -> Void
}

/// 局域网 Ollama 的目标：主 actor 上解析好的端点与模型名
struct RemoteOllamaTarget: Sendable {
    let endpointURL: URL
    let model: String
}

/// 后端侧的失败。端侧的失败直接用既有的 `LlamaInferenceError`，不套一层。
enum InferenceBackendError: Error, Equatable {
    /// 远程通道没给出可用回复：未授权、端点无效、非 200、应答缺字段、网络错误
    case remoteUnavailable
}

/// 一个可被编排层尝试的推理后端。
///
/// 约定：返回去空白后的整段回复；抛错表示这次尝试失败。**空串不是错误**，
/// 「空串要不要继续降级」由各入口自己决定——今天 `generate` 与 `generateCustomTask`
/// 对空回复的走向本就不同，这里不把它们抹平。
protocol InferenceBackend: Sendable {
    var id: InferenceBackendID { get }
    func generate(_ request: InferenceRequest) async throws -> String
}
