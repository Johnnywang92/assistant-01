import AssistantCore
import Foundation

// MARK: - 投喂口意图判别器（编排层）
//
// 职责：把归一文本变成一个 `IntentDistribution`。
// - 构造极短提示词（标签图例 + 输入），让模型在下一 token 上只做单标签选择
// - 通过 `LlamaCppEngine.classify` 读该位置 logits，在标签集上 softmax 得真实概率
// - 任何一步失败都返回 nil，由调用方降级，**绝不伪造分布**
//
// 为什么不把判别做成一次 `generate`：generate 会采样，采样结果不含概率，
// 且top-k/top-p/temperature 会改写分布——判别层要的就是未经改写的相对偏好。

struct OmniboxIntentRouter {

    /// 判别层策略：低于阈值时不猜，交给调用方澄清或落收集箱。
    var policy: IntentDecisionPolicy = .default

    /// 判别层自身的失败（模型未就绪、logits 读不到、标签映射不成立）。
    /// 与「判别成功但置信不足」是两种不同状态，调用方需区别对待：
    /// 前者说明该降级到规则引擎，后者说明该问用户。
    enum RouterError: LocalizedError {
        case engineUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .engineUnavailable(let reason):
                return "意图判别不可用：\(reason)"
            }
        }
    }

    /// 判别结果 + 提示词，便于调试与日志核对。
    struct Result {
        var distribution: IntentDistribution
        var prompt: String
    }

    /// 对归一文本做意图判别。
    /// - Throws: 模型不可用 / logits 不可读 / 标签无法单token 化。
    func route(_ text: String) async throws -> Result {
        let modelManager = LLMModelManager.shared
        guard await modelManager.validateModelStatusAndWait() else {
            throw RouterError.engineUnavailable("模型尚未就绪")
        }
        // localModelURL 与 selectedPreset 是 @MainActor 隔离属性，必须回到主actor 取。
        let modelURL = await modelManager.localModelURL
        let isQwen3 = await modelManager.selectedPreset.isQwen3Family

        let prompt = Self.makePrompt(for: text, isQwen3Family: isQwen3)

        // 分类不生成任何 token，预算只需容纳提示词本身。
        let budget = await LlamaCppEngine.shared.promptTokenBudget(at: modelURL, reservingForGeneration: 0)
        guard prompt.utf8.count <= budget * 2 else {
            throw LlamaInferenceError.contextOverflow(required: prompt.utf8.count / 2, available: budget)
        }

        let engine = LlamaCppEngine.shared
        let labels = OmniboxIntentLabel.allCases
        guard let tokenMap = await buildTokenMap(labels: labels, modelURL: modelURL) else {
            throw LlamaInferenceError.tokenMapUnavailable
        }

        // IntentTokenMap 内部用 Int 存储，llama_token 是 Int32，转换点集中在这里。
        let candidates = labels.compactMap { tokenMap.tokens[$0].map(Int32.init) }
        guard candidates.count == labels.count else {
            throw LlamaInferenceError.tokenMapUnavailable
        }

        let rawLogits = try await engine.classify(
            prompt: prompt,
            modelURL: modelURL,
            candidateTokens: candidates
        )
        guard rawLogits.count == labels.count else {
            throw LlamaInferenceError.logitsUnavailable
        }

        var logitsByLabel: [OmniboxIntentLabel: Double] = [:]
        for (label, logit) in zip(labels, rawLogits) {
            logitsByLabel[label] = Double(logit)
        }

        let distribution = IntentClassifierMath.makeDistribution(
            logits: logitsByLabel,
            allLabels: labels,
            policy: policy
        )
        return Result(distribution: distribution, prompt: prompt)
    }

    /// 把标签映射为单 token。委托 Core 的校验规则，保证「单 token 且互不碰撞」
    /// 这条前提只有一处实现。
    ///
    /// 标签本身是「0」~「8」单字符，在 Qwen 词表下均为单token，
    /// 这里仍做校验以防将来换用分词粒度不同的模型。
    private func buildTokenMap(labels: [OmniboxIntentLabel], modelURL: URL) async -> IntentTokenMap? {
        let engine = LlamaCppEngine.shared
        // 分词是 actor 隔离的异步调用，而Core 的校验器收同步闭包。
        // 先一次性把所有标签的 token 取回，再用同步闭包做校验，
        // 避免把 async 闭包塞进同步签名（也便于未来把校验器改成 async）。
        var tokenIDs: [OmniboxIntentLabel: [Int]] = [:]
        for label in labels {
            let ids = await engine.tokenize(label.rawValue, loading: modelURL)
            guard !ids.isEmpty else { return nil }
            tokenIDs[label] = ids.map(Int.init)
        }
        let tokenizer: (OmniboxIntentLabel) -> [Int]? = { label in
            tokenIDs[label]
        }
        return IntentTokenMap(tokenizing: labels, with: tokenizer)
    }

    /// 构造判别提示词。
    ///
    ///刻意保持极短：判别是「9 选 1」，模型不需要被教怎么做，只需要被告知选项。
    /// 长提示词既拖慢推理，也会挤占分类路径本就更紧的上下文预算。
    /// 末尾的 `答案：` 让下一个 token 就是标签数字，读 logits 即可。
    static func makePrompt(for text: String, isQwen3Family: Bool = false) -> String {
        let body = """
        你是意图分类器。只输出一个数字标签，不要解释。
        \(OmniboxIntentLabel.promptLegend)

        今天：\(yyyyMMdd.string(from: Date()))。
        输入：\(text)
        答案：
        """
        let assistantSuffix = isQwen3Family ? "\n<think>\n\n</think>\n\n" : ""
        return """
        <|im_start|>system
        你是个人助手的意图分类器。把用户输入归入一个标签，只输出该标签的数字，不输出任何其它内容。<|im_end|>
        <|im_start|>user
        \(body)<|im_end|>
        <|im_start|>assistant\(assistantSuffix)
        """
    }

    private static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
