import AssistantCore
import Foundation

/// 局域网 Ollama 联调后端（方便电脑 `ollama run qwen3:4b` 时手机直接接上）。
///
/// 这条通道**不挂 GBNF 文法、不做 token 预算裁剪**：请求体只有 `model` / `prompt` /
/// `stream=false` 三个字段，没有文法入口，窗口也充裕。两条编排路径原先各抄一份同样的请求，
/// 现在形状由 `RemoteOllamaRequest`（Core）声明并被测试盯着，这里只负责传输。
///
/// 失败一律归为 `remoteUnavailable`：非 200、应答缺 `response`、请求体编码失败、网络错误。
/// 与旧实现一致——它们都只让上层「拿不到结果」，不带原因。
struct RemoteOllamaBackend: InferenceBackend {
    let id: InferenceBackendID = .remoteOllama

    func generate(_ request: InferenceRequest) async throws -> String {
        guard let target = request.remote else { throw InferenceBackendError.remoteUnavailable }

        var urlRequest = URLRequest(url: RemoteOllamaRequest.url(from: target.endpointURL))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(RemoteOllamaRequest.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = RemoteOllamaRequest.timeoutInterval
        guard let httpBody = try? JSONEncoder().encode(
            RemoteOllamaRequest.Body(model: target.model, prompt: request.prompt)
        ) else {
            throw InferenceBackendError.remoteUnavailable
        }
        urlRequest.httpBody = httpBody

        guard let (data, response) = try? await URLSession.shared.data(for: urlRequest),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = RemoteOllamaRequest.reply(from: data) else {
            throw InferenceBackendError.remoteUnavailable
        }
        return LlamaCppEngine.cleanChatMLOutput(reply)
    }
}
