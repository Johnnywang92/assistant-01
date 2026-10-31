import XCTest
@testable import AssistantCore

/// 推理后端契约测试。
///
/// 盯的都是「抄错只会表现为一句含糊文案」的字面量：Ollama 的字段名、超时、以及
/// 后端尝试顺序。顺序本身也是被测对象——它是用户能看见的降级路径，不该由一次重构顺带改掉。
final class BackendContractTests: XCTestCase {

    // MARK: - 尝试顺序与身份

    func testAttemptOrderIsPinned() {
        // 端侧优先 → 局域网 Ollama；改这里等于改产品行为，必须显式承认
        XCTAssertEqual(InferenceBackendID.attemptOrder, [.onDeviceGguf, .remoteOllama])
    }

    func testEveryBackendIsAttemptedExactlyOnce() {
        XCTAssertEqual(InferenceBackendID.allCases.count, InferenceBackendID.attemptOrder.count)
        XCTAssertEqual(Set(InferenceBackendID.attemptOrder), Set(InferenceBackendID.allCases))
    }

    // MARK: - 能力位：编排层读的就是这三项

    func testCapabilityFlagsMatchDocumentedBehavior() {
        // 端侧：要预算、挂文法、超窗即停
        XCTAssertTrue(InferenceBackendID.onDeviceGguf.requiresTokenBudget)
        XCTAssertTrue(InferenceBackendID.onDeviceGguf.supportsGrammarConstraint)
        XCTAssertTrue(InferenceBackendID.onDeviceGguf.stopsOnContextOverflow)
        // 远程：窗口充裕不裁剪、无文法入口、失败就跳过下一个后端
        XCTAssertFalse(InferenceBackendID.remoteOllama.requiresTokenBudget)
        XCTAssertFalse(InferenceBackendID.remoteOllama.supportsGrammarConstraint)
        XCTAssertFalse(InferenceBackendID.remoteOllama.stopsOnContextOverflow)
    }

    func testUnsupportedGrammarNeverImpliesBudgetFree() {
        // 一条隐含约束：不能挂文法的后端也不该被要求查端侧预算，
        // 否则编排会拿端侧窗口去裁剪一份远程用得上的长提示词
        for backend in InferenceBackendID.allCases where !backend.supportsGrammarConstraint {
            XCTAssertFalse(backend.requiresTokenBudget, backend.rawValue)
        }
    }

    // MARK: - Ollama 请求形状（原两份手抄拷贝的公共部分）

    func testGeneratePathAndTimeoutArePinned() {
        XCTAssertEqual(RemoteOllamaRequest.generatePath, "api/generate")
        XCTAssertEqual(RemoteOllamaRequest.contentType, "application/json")
        XCTAssertEqual(RemoteOllamaRequest.timeoutInterval, 15)
        XCTAssertEqual(
            RemoteOllamaRequest.url(from: URL(string: "http://192.168.1.5:11434")!).absoluteString,
            "http://192.168.1.5:11434/api/generate"
        )
    }

    func testRequestBodyFieldsArePinned() throws {
        let data = try JSONEncoder().encode(
            RemoteOllamaRequest.Body(model: "qwen3:1.7b", prompt: "你好")
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("请求体不是 JSON 对象")
        }
        XCTAssertEqual(Set(json.keys), ["model", "prompt", "stream"])
        XCTAssertEqual(json["model"] as? String, "qwen3:1.7b")
        XCTAssertEqual(json["prompt"] as? String, "你好")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testReplyParsingMatchesLegacyShape() {
        func reply(_ raw: String) -> String? {
            RemoteOllamaRequest.reply(from: Data(raw.utf8))
        }
        XCTAssertEqual(reply("{\"response\":\"今天花了 32 元\"}"), "今天花了 32 元")
        XCTAssertNil(reply("{\"message\":\"没有 response 字段\"}"))
        // response 不是字符串：旧实现 `as? String` 得到 nil，不能变成崩溃或空串冒充有效回复
        XCTAssertNil(reply("{\"response\":123}"))
        XCTAssertNil(reply("not json"))
        XCTAssertNil(reply(""))
    }
}
