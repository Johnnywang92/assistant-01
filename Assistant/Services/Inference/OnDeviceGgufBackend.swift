import AssistantCore
import Foundation

/// 端侧 GGUF + llama.cpp（Metal）后端。
///
/// 只做一件事：把引擎调用与「去空白」收在一处，错误原样抛出。
/// 超窗（`LlamaInferenceError.contextOverflow`）是有语义的错误——上层要据此停止降级，
/// 所以这里不包装、不吞、不翻译成通用错误。
struct OnDeviceGgufBackend: InferenceBackend {
    let id: InferenceBackendID = .onDeviceGguf

    func generate(_ request: InferenceRequest) async throws -> String {
        let output = try await LlamaCppEngine.shared.generate(
            prompt: request.prompt,
            modelURL: request.modelURL,
            maxNewTokens: request.maxNewTokens,
            grammar: request.grammar,
            onPartialOutput: request.onPartialOutput
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
