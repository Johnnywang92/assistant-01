import XCTest
@testable import AssistantCore

final class ActionOutputParserTests: XCTestCase {

    // MARK: - classify：合法输出

    func testClassifyValidJSON() {
        let raw = #"[{"capability":"todo.create","title":"买牛奶","dueAtDays":"1"}]"#
        let decision = ActionOutputParser.classify(raw)
        guard case .ok(let actions) = decision else {
            return XCTFail("合法 JSON 应判为 ok，实际 \(decision)")
        }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].capability, .todoCreate)
        XCTAssertEqual(actions[0].params["title"], "买牛奶")
        XCTAssertEqual(actions[0].params["dueAtDays"], "1")
    }

    func testClassifyMarkdownFencedJSON() {
        let raw = """
        ```json
        [{"capability":"todo.complete","target":"取快递"}]
        ```
        """
        guard case .ok(let actions) = ActionOutputParser.classify(raw), let first = actions.first else {
            return XCTFail("带围栏输出应判为 ok")
        }
        XCTAssertEqual(first.capability, .todoComplete)
        XCTAssertEqual(first.params["target"], "取快递")
    }

    func testClassifyTrailingCommaIsRepaired() {
        let raw = """
        [
            {"capability":"memo.inbox","memo":"给妈妈打电话",},
        ]
        """
        guard case .ok(let actions) = ActionOutputParser.classify(raw) else {
            return XCTFail("尾逗号应被修复后判为 ok")
        }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].capability, .memoInbox)
    }

    // MARK: - classify：各类失败

    func testClassifyEmptyArrayIsNotFailure() {
        // 空数组是「合法但无动作」：不触发重试，由调用方直接落规则并留痕
        guard case .emptyArray = ActionOutputParser.classify("[]") else {
            return XCTFail("[] 应判为 emptyArray")
        }
    }

    func testClassifyInvalidCapability() {
        let raw = #"[{"capability":"rocket.launch","target":"发射"}]"#
        let decision = ActionOutputParser.classify(raw)
        guard case .failed(let reason) = decision else {
            return XCTFail("全非法 capability 应判 failed，实际 \(decision)")
        }
        XCTAssertEqual(reason, .noValidCapability)
    }

    func testClassifyTruncatedOutput() {
        let raw = #"[{"capability":"query.lookup","target":"车钥匙"#  // 缺收尾引号与 ]
        guard case .failed(let reason) = ActionOutputParser.classify(raw) else {
            return XCTFail("截断输出应判 failed")
        }
        XCTAssertEqual(reason, .truncated)
    }

    func testClassifyNaturalLanguageHasNoArrayStart() {
        guard case .failed(let reason) = ActionOutputParser.classify("好的，我帮你记下了。") else {
            return XCTFail("无数组输出应判 failed")
        }
        XCTAssertEqual(reason, .noArrayStart)
    }

    func testClassifySyntaxErrorInsideArray() {
        // 有 [ 有 ] 但对象语法非法
        guard case .failed(let reason) = ActionOutputParser.classify("[{\"capability\": \"todo.complete\", x: }]") else {
            return XCTFail("数组内语法错误应判 failed")
        }
        XCTAssertEqual(reason, .invalidSyntax)
    }

    // MARK: - 重试判定

    func testShouldRetryOnlyOnceForFailure() {
        let failed = ActionParseDecision.failed(reason: .invalidSyntax)
        XCTAssertTrue(ActionOutputParser.shouldRetry(decision: failed, attempt: 0))
        XCTAssertFalse(ActionOutputParser.shouldRetry(decision: failed, attempt: 1))
        XCTAssertEqual(ActionOutputParser.maxCorrectiveRetries, 1)
    }

    func testShouldNotRetryForOKOrEmptyArray() {
        let ok = ActionParseDecision.ok([ActionItem(capability: .memoInbox, params: ["memo": "x"])])
        XCTAssertFalse(ActionOutputParser.shouldRetry(decision: ok, attempt: 0))
        XCTAssertFalse(ActionOutputParser.shouldRetry(decision: .emptyArray, attempt: 0))
    }

    func testCorrectiveUserContentCarriesFailedSample() {
        let corrective = ActionOutputParser.correctiveUserContent(
            original: "今天是2026-10-01 周四。\n输入：\n买咖啡15元",
            failedOutput: "好的，我帮你记下买咖啡15元"
        )
        XCTAssertTrue(corrective.contains("买咖啡15元"), "纠正提示必须保留原始输入")
        XCTAssertTrue(corrective.contains("好的，我帮你记下买咖啡15元"), "纠正提示必须回灌畸形输出供模型对照")
        XCTAssertTrue(corrective.contains("JSON 数组"))
    }

    // MARK: - 旧契约兼容：parseActionJSON 与 classify 结论一致

    func testParseActionJSONDelegatesToClassify() {
        XCTAssertEqual(ActionParser.parseActionJSON("[]")?.count, 0)
        XCTAssertNil(ActionParser.parseActionJSON(#"[{"capability":"bad.cap"}]"#))
        XCTAssertNil(ActionParser.parseActionJSON("纯文字输出"))
        XCTAssertNil(ActionParser.parseActionJSON("[{\"capability\":\"todo.complete\",\"target\":\""))
        XCTAssertEqual(
            ActionParser.parseActionJSON(#"[{"capability":"todo.complete","target":"取快递"}]"#)?.count,
            1
        )
    }

    func testMixedValidAndInvalidItemsKeepsValid() {
        let raw = #"[{"capability":"todo.cancel","target":"退票"},{"capability":"bad.one"},]"#
        guard case .ok(let actions) = ActionOutputParser.classify(raw) else {
            return XCTFail("混排时应保留合法项并判 ok")
        }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].capability, .todoCancel)
    }
}
