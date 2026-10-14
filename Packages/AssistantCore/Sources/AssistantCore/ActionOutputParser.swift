import Foundation

// MARK: - 「LLM 输出 → 动作数组」分类与重试判定（纯函数，可脱离 app 测试）

/// 一次模型原始输出的解析结局
public enum ActionParseDecision: Equatable, Sendable {
    /// 至少解析出一个合法动作
    case ok([ActionItem])
    /// JSON 合法但数组为空：模型明确返回了「无动作」，不属于解析失败，不消耗重试
    case emptyArray
    /// 解析失败：可重试一次纠正
    case failed(reason: ActionParseFailure)
}

/// 解析失败的具体原因（rawValue 供日志与降级审计使用）
public enum ActionParseFailure: String, Equatable, Sendable, CaseIterable {
    case noArrayStart = "输出中未找到 JSON 数组起始符"
    case truncated = "数组未闭合，输出被截断"
    case invalidSyntax = "数组存在但 JSON 语法非法"
    case noValidCapability = "数组内所有元素均无合法 capability"
}

public enum ActionOutputParser {

    /// 解析失败后的纠正重试次数上限（项目决策：只重试 1 次，仍失败立即落规则兜底）
    public static let maxCorrectiveRetries = 1

    /// 分类模型原始输出：剥围栏 → 定位最外层数组 → 修尾逗号 → 解码 → 逐项映射 capability。
    public static func classify(_ raw: String) -> ActionParseDecision {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = s.firstIndex(of: "[") else {
            return .failed(reason: .noArrayStart)
        }
        guard let end = s.lastIndex(of: "]"), start < end else {
            return .failed(reason: .truncated)
        }
        let jsonString = String(s[start...end])

        // 宽容修复尾随逗号：例如 `{"a": 1,}` 或 `[1, 2,]`
        let repaired = jsonString.replacingOccurrences(
            of: #",\s*([}\]])"#,
            with: "$1",
            options: .regularExpression
        )

        guard let data = repaired.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [Any] else {
            return .failed(reason: .invalidSyntax)
        }
        if array.isEmpty {
            return .emptyArray
        }
        // 元素允许混入非法项：能解码成对象的进候选池，全池无合法 capability 才算失败
        let objects = array.compactMap { $0 as? [String: Any] }
        let actions = makeActions(from: objects)
        if actions.isEmpty {
            return .failed(reason: .noValidCapability)
        }
        return .ok(actions)
    }

    /// 重试判定：attempt 为 0 起的已尝试次数；仅解析失败且未超重试上限才重试。
    public static func shouldRetry(decision: ActionParseDecision, attempt: Int) -> Bool {
        guard case .failed = decision else { return false }
        return attempt < maxCorrectiveRetries
    }

    /// 纠正重试提示：把第一次畸形输出原样回灌进上下文。
    /// 比升温更稳——1.5B 小模型升温只会更容易跑偏，失败样本能让它照着格式改。
    public static func correctiveUserContent(original: String, failedOutput: String) -> String {
        let snippet = String(failedOutput.prefix(200))
        return """
        \(original)

        注意：你上一次的输出不是合法的 JSON 动作数组，无法被解析：
        \(snippet)
        请严格按照之前的格式要求，只输出一个 JSON 数组，不要输出任何其它文字。
        """
    }

    // MARK: - 数组元素 → ActionItem 映射（从 ActionParser.parseActionJSON 抽出共用）

    static func makeActions(from objects: [[String: Any]]) -> [ActionItem] {
        var actions: [ActionItem] = []
        for item in objects {
            guard let capRaw = item["capability"] as? String,
                  let capability = ActionCapability(rawValue: capRaw) else {
                continue
            }

            var params: [String: String] = [:]
            for (key, value) in item {
                if let str = value as? String {
                    params[key] = str
                } else if let num = value as? NSNumber {
                    params[key] = num.stringValue
                }
            }
            params.removeValue(forKey: "capability")

            let summary = ActionParser.generateSummary(for: capability, params: params)
            actions.append(ActionItem(
                id: UUID(),
                capability: capability,
                params: params,
                confidence: 0.85,
                summary: summary
            ))
        }

        // 拓扑隐式依赖：待办依赖同批次记账结果
        let expenseIDs = actions.filter { $0.capability == .expenseCreate }.map(\.id)
        if !expenseIDs.isEmpty {
            for index in actions.indices where actions[index].capability == .todoCreate {
                actions[index].dependsOn = expenseIDs
            }
        }
        return actions
    }
}
