import Foundation

/// 局域网 Ollama `api/generate` 通道的请求与应答形状。
///
/// 这个形状原先在 `LLMInferenceService` 里手抄了两遍（`generateCustomTask` 内联一份、
/// `generateViaRemoteOllama` 一份），两处逐字相同的部分是：路径 `api/generate`、
/// `Content-Type: application/json`、超时 15 秒、请求体三字段 `model` / `prompt` /
/// `stream=false`、状态码 200、取 `response` 字段。抄错任一字段名的表现是同一条
/// 「连接失败，已使用本机规则」——从那句话根本反推不出是字段名写错，所以把它做成
/// Core 的纯数据并纳入 `swift test`。
///
/// 只搬「形状」：POST 方法、 URLSession、状态码判定留在调用侧，因为它们要和
/// `remoteConnectionStatus` 这类 UI 状态一起更新。
public enum RemoteOllamaRequest {

    /// Ollama 生成接口相对端点的路径
    public static let generatePath = "api/generate"

    /// 请求头 `Content-Type`
    public static let contentType = "application/json"

    /// 请求超时（秒）
    public static let timeoutInterval: TimeInterval = 15

    /// 由用户填写的基址拼出生成接口地址
    public static func url(from endpoint: URL) -> URL {
        endpoint.appendingPathComponent(generatePath)
    }

    /// 请求体。`stream` 恒为 false：两处调用都在等整段回复，没有流式消费。
    public struct Body: Codable, Sendable, Equatable {
        public let model: String
        public let prompt: String
        public let stream: Bool

        public init(model: String, prompt: String) {
            self.model = model
            self.prompt = prompt
            self.stream = false
        }
    }

    /// 从应答里取出文本。缺字段、类型不符、非 JSON 一律返回 nil——
    /// 与旧实现一致：猜不得，也不能让一次联调请求把崩溃带给上层。
    public static func reply(from data: Data) -> String? {
        struct Reply: Decodable { let response: String }
        return try? JSONDecoder().decode(Reply.self, from: data).response
    }
}
