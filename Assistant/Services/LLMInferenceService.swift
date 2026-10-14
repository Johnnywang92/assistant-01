import AssistantCore
import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(LlamaSwift)
import LlamaSwift
#elseif canImport(llama)
import llama
#endif

/// 端侧 llama.cpp 推理错误定义
public enum LlamaInferenceError: LocalizedError {
    case modelFileNotFound(String)
    case modelLoadFailed(String)
    case contextInitFailed
    case vocabUnavailable
    case tokenizationFailed
    case decodeFailed(Int32)
    case samplerInitFailed
    case frameworkNotLinked
    /// 提示词超出模型窗口。**不再用静默截尾兜底**，改为向上报错由调用方降预算重试。
    case contextOverflow(required: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case .modelFileNotFound(let path):
            return "未找到 GGUF 模型文件：\(path)"
        case .modelLoadFailed(let path):
            return "GGUF 模型加载失败（文件可能损坏或内存不足）：\(path)"
        case .contextInitFailed:
            return "llama.cpp 推理上下文初始化失败（内存不足）"
        case .vocabUnavailable:
            return "无法读取 GGUF 模型词表 (Vocab)"
        case .tokenizationFailed:
            return "提示词分词 (Tokenize) 失败"
        case .decodeFailed(let code):
            return "llama_decode 推理执行异常 (code: \(code))"
        case .samplerInitFailed:
            return "采样器初始化失败"
        case .frameworkNotLinked:
            return "当前编译环境未链接 LlamaSwift / llama.xcframework 二进制库"
        case .contextOverflow(let required, let available):
            return "提示词需 \(required) token，模型可用仅 \(available) token，已超出上下文窗口"
        }
    }
}

/// 端侧 llama.cpp (GGUF + Metal) 独立推理引擎 Actor
actor LlamaCppEngine {
    static let shared = LlamaCppEngine()

    /// 端侧推理上下文窗口上限。KV 缓存按 token 线性增长（Qwen2.5-1.5B 约 28KB/token），
    /// 4096 token ≈ 115MB，是安全上界；再高在低端机有 jetsam 风险。
    static let maxContextTokens = 4096
    /// 读不到模型训练窗时的兜底值（与旧实现写死的 2048 对齐，保证退化行为不变）
    static let fallbackContextTokens = 2048
    /// 为生成长度与 KV 对齐预留的 token 数
    static let contextSafetyMargin = 32

    /// 由总窗口推算可用于提示词正文的预算。与 `generate` 内的校验共用这一处算法，
    /// 避免装配与推理两边对预算的理解不一致。
    static func promptBudget(contextTokens: Int, maxNewTokens: Int) -> Int {
        max(256, contextTokens - maxNewTokens - contextSafetyMargin)
    }

    #if canImport(LlamaSwift) || canImport(llama)
    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedModelPath: String?
    private var isBackendInitialized = false

    private init() {
        llama_backend_init()
        isBackendInitialized = true
    }

    var isLoaded: Bool {
        model != nil
    }

    /// 预加载或确保指定路径的 GGUF 模型已映射至内存/Metal
    func ensureModelLoaded(at modelURL: URL) throws {
        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw LlamaInferenceError.modelFileNotFound(modelURL.lastPathComponent)
        }

        if model != nil, loadedModelPath == path, vocab != nil {
            return
        }

        unloadModel()

        if !isBackendInitialized {
            llama_backend_init()
            isBackendInitialized = true
        }

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99 // 启用 Apple Silicon Metal GPU 全层加速
        #endif

        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw LlamaInferenceError.modelLoadFailed(modelURL.lastPathComponent)
        }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            throw LlamaInferenceError.vocabUnavailable
        }

        self.model = loadedModel
        self.vocab = loadedVocab
        self.loadedModelPath = path
    }

    /// 释放模型权重与显存占用
    func unloadModel() {
        if let model {
            llama_model_free(model)
        }
        self.model = nil
        self.vocab = nil
        self.loadedModelPath = nil
    }

    /// 申请多少上下文窗口：取模型训练窗与设备上限的较小值。
    private static func requestedContextTokens(for model: OpaquePointer) -> Int {
        let train = Int(llama_model_n_ctx_train(model))
        let resolved = train > 0 ? train : fallbackContextTokens
        return max(512, min(resolved, maxContextTokens))
    }

    /// 供上层在**装配提示词之前**查询可用预算，避免先拼完超长文本再发现装不下。
    /// 模型加载失败时不报错：返回兜底预算，让调用方照常装配出一份可用的短提示词。
    func promptTokenBudget(at modelURL: URL, reservingForGeneration maxNewTokens: Int) -> Int {
        let fallback = Self.promptBudget(contextTokens: Self.fallbackContextTokens, maxNewTokens: maxNewTokens)
        do {
            try ensureModelLoaded(at: modelURL)
            guard let model else { return fallback }
            return Self.promptBudget(contextTokens: Self.requestedContextTokens(for: model), maxNewTokens: maxNewTokens)
        } catch {
            return fallback
        }
    }

    /// 执行流式 ChatML 端侧推理
    func generate(
        prompt: String,
        modelURL: URL,
        maxNewTokens: Int = 256,
        grammar: String? = nil,
        grammarRoot: String = "root",
        onPartialOutput: @Sendable (String) async -> Void
    ) async throws -> String {
        try ensureModelLoaded(at: modelURL)
        guard let model, let vocab else {
            throw LlamaInferenceError.modelLoadFailed(modelURL.lastPathComponent)
        }

        var ctxParams = llama_context_default_params()
        // 窗口按模型训练窗取、封顶在 maxContextTokens。写死 2048 会让「12 段生活档案」
        // 必然溢出，而溢出后的截断又会吃掉最该留的数据。
        ctxParams.n_ctx = UInt32(Self.requestedContextTokens(for: model))
        ctxParams.n_batch = 512
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let threadCount = Int32(max(2, min(6, cpuCount - 1)))
        ctxParams.n_threads = threadCount
        ctxParams.n_threads_batch = threadCount

        guard let context = llama_init_from_model(model, ctxParams) else {
            throw LlamaInferenceError.contextInitFailed
        }
        defer {
            llama_free(context)
        }

        // 1. 将 ChatML Prompt 转换为 Token 序列
        let utf8Count = Int32(prompt.utf8.count)
        var maxTokenCapacity = Int(utf8Count) + 32
        var promptTokens = [llama_token](repeating: 0, count: maxTokenCapacity)

        var tokenCount = prompt.withCString { cStr in
            llama_tokenize(
                vocab,
                cStr,
                utf8Count,
                &promptTokens,
                Int32(maxTokenCapacity),
                true,
                true
            )
        }

        if tokenCount < 0 {
            maxTokenCapacity = Int(-tokenCount) + 8
            promptTokens = [llama_token](repeating: 0, count: maxTokenCapacity)
            tokenCount = prompt.withCString { cStr in
                llama_tokenize(
                    vocab,
                    cStr,
                    utf8Count,
                    &promptTokens,
                    Int32(maxTokenCapacity),
                    true,
                    true
                )
            }
        }

        guard tokenCount > 0 else {
            throw LlamaInferenceError.tokenizationFailed
        }
        promptTokens.removeSubrange(Int(tokenCount)..<promptTokens.count)

        // 实际生效窗口可能与申请值不同（llama.cpp 会按内存与类型自行调整），
        // 头文件明确要求用 llama_n_ctx() 回查，预算必须以回查值为准。
        let effectiveContextTokens = Int(llama_n_ctx(context))
        let availableForPrompt = max(0, effectiveContextTokens - maxNewTokens - Self.contextSafetyMargin)
        guard promptTokens.count <= availableForPrompt else {
            // 这里**不做** suffix() 截尾：截尾保留的是尾部，丢掉的会是开头的 system 人格
            // 与紧随其后、排在最前的快递/待办档案，还把 ChatML 起始结构截成残缺体——
            // 模型收到一段没有主人格的碎片却照样产出通顺答案，错误会静默变成答非所问。
            // 超窗一律向上抛错，由调用方降预算重建或降级到规则引擎。
            throw LlamaInferenceError.contextOverflow(required: promptTokens.count, available: availableForPrompt)
        }

        // 2. 分批 Prefill 评估输入 Token
        let batchSize = Int(ctxParams.n_batch)
        var offset = 0
        while offset < promptTokens.count {
            try Task.checkCancellation()
            let end = min(offset + batchSize, promptTokens.count)
            var chunk = Array(promptTokens[offset..<end])
            let batch = chunk.withUnsafeMutableBufferPointer { buf in
                llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            }
            let decodeStatus = llama_decode(context, batch)
            if decodeStatus != 0 {
                throw LlamaInferenceError.decodeFailed(decodeStatus)
            }
            offset = end
        }

        // 3. 构建采样器链 (Top-K + Top-P + Temperature)
        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw LlamaInferenceError.samplerInitFailed
        }
        defer {
            llama_sampler_free(sampler)
        }

        // GBNF 语法约束必须放在链首（对齐 llama.cpp examples/main 的用法）：
        // 若排在 top-k/top-p 之后，截断可能把文法允许的 token 全部剪掉导致无法收尾；
        // chain 接管 grammar sampler 生命周期，勿另行 free。
        if let grammar {
            let grammarSampler = grammar.withCString { grammarStr in
                grammarRoot.withCString { rootStr in
                    llama_sampler_init_grammar(vocab, grammarStr, rootStr)
                }
            }
            if let grammarSampler {
                llama_sampler_chain_add(sampler, grammarSampler)
            } else {
                // 头文件约定：文法串解析失败返回 NULL。降级为不加约束继续推理，不能让整次生成崩掉。
                print("⚠️ GBNF 文法解析失败，本次推理未挂语法约束")
            }
        }

        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.90, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.60))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        // 4. 自回归解码循环（使用 UTF-8 字节缓冲避免中文多字节 BPE 拆字乱码）
        var utf8Bytes: [UInt8] = []
        var pieceBuffer = [CChar](repeating: 0, count: 256)

        for _ in 0..<maxNewTokens {
            try Task.checkCancellation()

            let newTokenId = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, newTokenId)

            if llama_vocab_is_eog(vocab, newTokenId) {
                break
            }

            let byteCount = llama_token_to_piece(
                vocab,
                newTokenId,
                &pieceBuffer,
                Int32(pieceBuffer.count),
                0,
                false
            )

            if byteCount > 0 {
                for i in 0..<Int(byteCount) {
                    utf8Bytes.append(UInt8(bitPattern: pieceBuffer[i]))
                }

                let rawDecoded = String(decoding: utf8Bytes, as: UTF8.self)
                if rawDecoded.contains("<|im_end|>") || rawDecoded.contains("<|endoftext|>") {
                    break
                }

                let cleaned = Self.cleanChatMLOutput(rawDecoded)
                if !cleaned.isEmpty {
                    await onPartialOutput(cleaned)
                }
            }

            var nextToken = [newTokenId]
            let nextBatch = nextToken.withUnsafeMutableBufferPointer { buf in
                llama_batch_get_one(buf.baseAddress, 1)
            }
            let status = llama_decode(context, nextBatch)
            if status != 0 {
                break
            }
        }

        let finalRaw = String(decoding: utf8Bytes, as: UTF8.self)
        return Self.cleanChatMLOutput(finalRaw)
    }
    #else
    private init() {}

    var isLoaded: Bool { false }

    func ensureModelLoaded(at modelURL: URL) throws {
        throw LlamaInferenceError.frameworkNotLinked
    }

    func unloadModel() {}

    func generate(
        prompt: String,
        modelURL: URL,
        maxNewTokens: Int = 256,
        grammar: String? = nil,
        grammarRoot: String = "root",
        onPartialOutput: @Sendable (String) async -> Void
    ) async throws -> String {
        throw LlamaInferenceError.frameworkNotLinked
    }

    func promptTokenBudget(at modelURL: URL, reservingForGeneration maxNewTokens: Int) -> Int {
        Self.promptBudget(contextTokens: Self.fallbackContextTokens, maxNewTokens: maxNewTokens)
    }
    #endif

    private static func cleanChatMLOutput(_ text: String) -> String {
        var result = text
        let stopMarkers = ["<|im_end|>", "<|endoftext|>", "<|im_start|>"]
        for marker in stopMarkers {
            if let range = result.range(of: marker) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 端侧 Qwen2.5-1.5B GGUF (llama.cpp) 推理服务，兼顾局域网 Ollama 联调与规则助手兜底
@MainActor
public final class LLMInferenceService: ObservableObject {
    public static let shared = LLMInferenceService()

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("llm_developer_endpoint") public var developerEndpoint: String = "" // 如 http://192.168.1.5:11434 (局域网 Ollama)
    @AppStorage("llm_remote_context_consent") public var remoteContextConsent: Bool = false
    @Published public var isGenerating: Bool = false
    @Published public var currentOutput: String = ""
    @Published public var remoteConnectionStatus: String = "未连接"
    @Published public var localEngineStatus: String = "待机中"
    @Published public var isLocalModelLoaded: Bool = false

    /// 流式输出合帧节流：token 回调频率可达 10–30Hz，逐 token 写 @Published
    /// 会让千行级视图每 token 全量重渲染；限流到 ~20Hz 并只在首个 token 更新状态。
    private var lastPartialPublish: Date = .distantPast
    private var didMarkStreaming: Bool = false

    private func handlePartialOutput(_ partial: String) {
        if !didMarkStreaming {
            didMarkStreaming = true
            isLocalModelLoaded = true
            localEngineStatus = "正在生成回复 (Metal)..."
        }
        let now = Date()
        guard now.timeIntervalSince(lastPartialPublish) >= 0.05 else { return }
        lastPartialPublish = now
        currentOutput = partial
    }

    private func beginStreamingSession() {
        lastPartialPublish = .distantPast
        didMarkStreaming = false
    }

    private init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let service = self else { return }
            Task { @MainActor [weak service] in
                guard let service, !service.isGenerating else { return }
                await service.unloadLocalModel()
            }
        }
        #endif
    }

    /// 预加载本地 GGUF 模型至 Metal / 内存
    public func preloadLocalModel() async {
        let manager = LLMModelManager.shared
        guard await manager.validateModelStatusAndWait() else {
            localEngineStatus = manager.validationStatus == .noModelFile ? "未下载 GGUF 模型" : "模型文件校验未通过"
            isLocalModelLoaded = false
            return
        }

        localEngineStatus = "正在加载 GGUF 模型 (Metal)..."
        do {
            try await LlamaCppEngine.shared.ensureModelLoaded(at: manager.localModelURL)
            isLocalModelLoaded = true
            localEngineStatus = "已就绪 (llama.cpp Metal)"
        } catch {
            isLocalModelLoaded = false
            localEngineStatus = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 释放已加载的本地 GGUF 模型内存
    public func unloadLocalModel() async {
        await LlamaCppEngine.shared.unloadModel()
        isLocalModelLoaded = false
        localEngineStatus = "已释放内存"
    }

    /// 生活档案类段落：预算不足时按 `PromptBlockID.dropRank` 整块丢弃。
    private static let lifeProfileBlockIDs: Set<PromptBlockID> = [
        .parcel, .todo, .finance, .anniversary, .storage, .habit, .vault, .family, .memo, .place
    ]

    /// 提取用户全模块生活数据并构建 ChatML 提示词模板（覆盖快递、待办、记账、纪念日、收纳、用药习惯、订阅保质期、萌宠、育儿、爱车、证件到期、语音备忘与常去地点）
    ///
    /// 各模块数据以「整块」参与预算取舍：要么一段数据完整在场，要么整段不在。
    /// - Parameters:
    ///   - budgetTokens: 可用于提示词正文的 token 上限；`nil` 表示不做裁剪（局域网 Ollama 窗口充裕）。
    ///   - includeLifeProfile: `false` 时只装配人格/规则/问句，用于寒暄与通识问答。
    /// - Returns: ChatML 提示词；若连必留块都装不下则返回空串，调用方应据此降级到规则引擎。
    public func buildPrompt(
        query: String,
        context: ModelContext,
        actionExecutionNote: String? = nil,
        history: [(role: String, text: String)] = [],
        budgetTokens: Int? = nil,
        includeLifeProfile: Bool = true
    ) -> String {
        let name = assistantName.isEmpty ? "小助" : assistantName
        let now = Date.now.formatted(date: .complete, time: .shortened)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = q
        var blocks: [PromptBlock] = []

        // 必留：Persona
        let userTitle = AppSettings.userTitle
        let personaText = """
        <|im_start|>system
        你是运行在用户 iPhone 本地的全能私人管家「\(name)」（基于 Qwen2.5-1.5B 与 llama.cpp 端侧引擎）。
        当前对用户的称呼：\(userTitle)
        当前时间：\(now)
        """
        blocks.append(PromptBlock(id: .persona, text: personaText))

        if includeLifeProfile {
            // 1. 快递信息
            let active = TodoStatus.active.rawValue
            let parcelType = TodoType.parcel.rawValue
            let parcels = (try? context.fetch(FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.typeRaw == parcelType && $0.statusRaw == active }
            ))) ?? []
            let parcelText: String = parcels.isEmpty ? "暂无待取包裹" : parcels.prefix(6).map {
                let code = $0.pickupCode ?? "无取件码"
                let loc = $0.location ?? $0.station ?? "暂存点"
                return "\($0.courier ?? "快递")（码：\(code)，在 \(loc)）"
            }.joined(separator: "；")
            blocks.append(PromptBlock(id: .parcel, text: "• 待取快递：\(parcelText)"))

            // 2. 待办与活动日程
            let todos = (try? context.fetch(FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.typeRaw != parcelType && $0.statusRaw == active }
            ))) ?? []
            let todoText: String = todos.isEmpty ? "暂无未完成待办" : todos.prefix(6).map { item in
                var parts = [item.title]
                if let due = item.dueAt {
                    parts.append(due.formatted(date: .abbreviated, time: .shortened))
                }
                if let loc = item.location, !loc.isEmpty {
                    parts.append("@\(loc)")
                }
                return parts.joined(separator: " ")
            }.joined(separator: "；")
            blocks.append(PromptBlock(id: .todo, text: "• 日常待办与日程：\(todoText)"))

            // 3. 记账开销与近期明细（细分今日、昨日、前天、本周、本月及带日期的逐笔明细）
            let calendar = Calendar.current
            let currentMonth = calendar.component(.month, from: .now)
            let currentYear = calendar.component(.year, from: .now)
            let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: .now) ?? .now
            var todayExpense: Double = 0
            var yesterdayExpense: Double = 0
            var dayBeforeYesterdayExpense: Double = 0
            var weekExpense: Double = 0
            var monthExpense: Double = 0
            var monthIncome: Double = 0
            var categoryTotals: [String: Double] = [:]
            let windowStart = min(
                calendar.date(from: DateComponents(year: currentYear, month: currentMonth, day: 1)) ?? .now,
                calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now,
                calendar.startOfDay(for: twoDaysAgo)
            )
            let records = ((try? context.fetch(FetchDescriptor<ExpenseRecord>(
                predicate: #Predicate { $0.date >= windowStart },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            ))) ?? [])

            var recentExpenseDescriptor = FetchDescriptor<ExpenseRecord>(
                predicate: #Predicate { !$0.isIncome },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            recentExpenseDescriptor.fetchLimit = 5
            let recentExpenseRecords = (try? context.fetch(recentExpenseDescriptor)) ?? []

            let formatAmt: (Double) -> String = { val in
                if val.truncatingRemainder(dividingBy: 1) == 0 {
                    return String(format: "%.0f", val)
                } else if (val * 10).truncatingRemainder(dividingBy: 1) == 0 {
                    return String(format: "%.1f", val)
                } else {
                    return String(format: "%.2f", val)
                }
            }
            let relDayLabel: (Date) -> String = { d in
                if calendar.isDateInToday(d) { return "今天" }
                if calendar.isDateInYesterday(d) { return "昨天" }
                if calendar.isDate(d, inSameDayAs: twoDaysAgo) { return "前天" }
                return "\(calendar.component(.month, from: d))月\(calendar.component(.day, from: d))日"
            }

            for r in records {
                let isThisMonth = calendar.component(.year, from: r.date) == currentYear &&
                    calendar.component(.month, from: r.date) == currentMonth
                if r.isIncome {
                    if isThisMonth { monthIncome += r.amount }
                } else {
                    if calendar.isDateInToday(r.date) { todayExpense += r.amount }
                    if calendar.isDateInYesterday(r.date) { yesterdayExpense += r.amount }
                    if calendar.isDate(r.date, inSameDayAs: twoDaysAgo) { dayBeforeYesterdayExpense += r.amount }
                    if calendar.isDate(r.date, equalTo: .now, toGranularity: .weekOfYear) { weekExpense += r.amount }
                    if isThisMonth {
                        monthExpense += r.amount
                        categoryTotals[r.categoryRaw, default: 0] += r.amount
                    }
                }
            }
            let topCatText = categoryTotals.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) ¥\(formatAmt($0.value))" }
                .joined(separator: "、")
            let recentExpenseText = recentExpenseRecords
                .map { "[\(relDayLabel($0.date))·\($0.categoryRaw)] \($0.title.isEmpty ? $0.categoryRaw : $0.title) ¥\(formatAmt($0.amount))" }
                .joined(separator: "、")

            let financeOverview: String = {
                var parts: [String] = []
                if todayExpense > 0 {
                    parts.append("今天已消费 ¥\(formatAmt(todayExpense))")
                } else if yesterdayExpense > 0 {
                    parts.append("今天暂未产生消费，昨天消费了 ¥\(formatAmt(yesterdayExpense))")
                } else {
                    parts.append("今天与昨天暂未记账")
                }
                if todayExpense > 0 && yesterdayExpense > 0 {
                    parts.append("昨天消费 ¥\(formatAmt(yesterdayExpense))")
                }
                if dayBeforeYesterdayExpense > 0 {
                    parts.append("前天消费 ¥\(formatAmt(dayBeforeYesterdayExpense))")
                }
                parts.append("本周累计消费 ¥\(formatAmt(weekExpense))")
                parts.append("本月累计消费 ¥\(formatAmt(monthExpense))（收入 ¥\(formatAmt(monthIncome))）")
                return parts.joined(separator: "，")
            }()
            let financeDetails = "\(financeOverview)\(topCatText.isEmpty ? "" : "；主要分类：\(topCatText)")\(recentExpenseText.isEmpty ? "" : "；近期逐笔明细：\(recentExpenseText)")"
            blocks.append(PromptBlock(id: .finance, text: "• 财务账本：\(financeDetails)"))

            // 4. 纪念日与倒数日
            let anniversaries = ((try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? [])
                .map { ($0, $0.daysUntilNext) }
                .sorted { $0.1 < $1.1 }
            let anniText: String = anniversaries.isEmpty ? "无" : anniversaries.prefix(3).map {
                "\($0.0.title)（还有 \($0.1) 天）"
            }.joined(separator: "、")
            blocks.append(PromptBlock(id: .anniversary, text: "• 纪念日倒数：\(anniText)"))

            // 5. 物品收纳箱（优先匹配问题关键词）
            let storedItems = (try? context.fetch(FetchDescriptor<StoredItem>())) ?? []
            let matchedStored = storedItems.filter { [queryText] item in
                queryText.contains(item.name) || queryText.contains(item.roomArea) || item.name.contains(queryText)
            }
            let displayStored = matchedStored.isEmpty ? Array(storedItems.prefix(5)) : Array(matchedStored.prefix(6))
            let storageText: String = displayStored.isEmpty ? "未录入" : displayStored.map {
                "\($0.name) -> \($0.roomArea)·\($0.location)"
            }.joined(separator: "；")
            blocks.append(PromptBlock(id: .storage, text: "• 物品收纳位置：\(storageText)"))

            // 6. 习惯打卡与每日服药计划
            let habits = ((try? context.fetch(FetchDescriptor<PeriodicHabit>())) ?? []).filter { $0.isEnabled }
            let meds = ((try? context.fetch(FetchDescriptor<MedicationPlan>())) ?? []).filter { $0.isEnabled }
            var habitMedParts: [String] = []
            if !meds.isEmpty {
                habitMedParts.append("用药：" + meds.prefix(4).map { "\($0.medName) \($0.dosage)（\($0.dailyTimePoints.joined(separator: "/"))）" }.joined(separator: "、"))
            }
            if !habits.isEmpty {
                habitMedParts.append("习惯：" + habits.prefix(4).map { "\($0.title)（\($0.recurrenceRaw)）" }.joined(separator: "、"))
            }
            let habitMedText = habitMedParts.isEmpty ? "无" : habitMedParts.joined(separator: "；")
            blocks.append(PromptBlock(id: .habit, text: "• 用药与习惯打卡：\(habitMedText)"))

            // 7. 订阅扣费与物品/证件保质期预警
            let subs = (try? context.fetch(FetchDescriptor<SubscriptionItem>())) ?? []
            let expiries = ((try? context.fetch(FetchDescriptor<ItemExpiryItem>())) ?? []).filter { !$0.isResolved }
            let idDocs = (try? context.fetch(FetchDescriptor<IDDocumentItem>())) ?? []
            var alertParts: [String] = []
            if !subs.isEmpty {
                alertParts.append("订阅：" + subs.prefix(3).map { "\($0.name) \($0.priceString)" }.joined(separator: "、"))
            }
            if !expiries.isEmpty {
                alertParts.append("保质期：" + expiries.prefix(3).map { "\($0.title)（\($0.expireDate.formatted(date: .abbreviated, time: .omitted))到期）" }.joined(separator: "、"))
            }
            if !idDocs.isEmpty {
                alertParts.append("已存证件：" + idDocs.prefix(4).map { doc in
                    if doc.isPermanent { return "\(doc.title)(长期)" }
                    if let exp = doc.expiryDate { return "\(doc.title)(\(exp.formatted(date: .abbreviated, time: .omitted))到期)" }
                    return doc.title
                }.joined(separator: "、"))
            }
            let vaultAlertText = alertParts.isEmpty ? "无" : alertParts.joined(separator: "；")
            blocks.append(PromptBlock(id: .vault, text: "• 证件/订阅/保质期：\(vaultAlertText)"))

            // 8. 家庭关怀：萌宠、宝贝育儿与爱车档案
            let pets = (try? context.fetch(FetchDescriptor<PetProfile>())) ?? []
            let children = (try? context.fetch(FetchDescriptor<ChildProfile>())) ?? []
            let vehicles = (try? context.fetch(FetchDescriptor<VehicleProfile>())) ?? []
            var familyParts: [String] = []
            if !pets.isEmpty {
                familyParts.append("宠物：" + pets.prefix(2).map { pet in
                    let w = pet.weightKg.map { String(format: "%.1fkg", $0) } ?? ""
                    return "\(pet.name)(\(pet.breed) \(w))"
                }.joined(separator: "、"))
            }
            if !children.isEmpty {
                familyParts.append("宝贝：" + children.prefix(2).map { child in
                    let h = child.effectiveHeightCm.map { String(format: "身高%.0fcm", $0) } ?? ""
                    let w = child.effectiveWeightKg.map { String(format: "体重%.1fkg", $0) } ?? ""
                    return "\(child.name)(\(child.ageDescription) \(h) \(w))".trimmingCharacters(in: .whitespaces)
                }.joined(separator: "、"))
            }
            if !vehicles.isEmpty {
                familyParts.append("爱车：" + vehicles.prefix(2).map { v in
                    "\(v.name)(\(v.plateNumber)，距保养\(v.daysUntilNextMaintenance)天)"
                }.joined(separator: "、"))
            }
            let familyText = familyParts.isEmpty ? "未录入" : familyParts.joined(separator: "；")
            blocks.append(PromptBlock(id: .family, text: "• 家庭档案(萌宠/育儿/爱车)：\(familyText)"))

            // 9. 语音备忘与常去地点
            var memoDescriptor = FetchDescriptor<VoiceMemo>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            memoDescriptor.fetchLimit = 2
            let memos = (try? context.fetch(memoDescriptor)) ?? []
            let memoText: String = memos.isEmpty ? "无" : memos.prefix(2).map { m in
                let snippet = (m.summary ?? m.transcription ?? "").prefix(30)
                return snippet.isEmpty ? m.title : "\(m.title)：\(snippet)"
            }.joined(separator: "；")
            blocks.append(PromptBlock(id: .memo, text: "• 近期语音备忘：\(memoText)"))

            let places = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
            let placeText: String = places.isEmpty ? "未学习" : places.prefix(3).map { "\($0.category.rawValue)：\($0.name)" }.joined(separator: "、")
            blocks.append(PromptBlock(id: .place, text: "• 常去地点：\(placeText)"))
        }

        // 财务/操作精确回执（必留）
        let isFinanceQuestion = q.contains("花") || q.contains("消费") || q.contains("支出") ||
            q.contains("开销") || q.contains("账") || q.contains("钱") || q.contains("元") || q.contains("块")
        if let note = actionExecutionNote {
            blocks.append(PromptBlock(id: .verified, text: "• 【刚刚完成的本机操作与精确统计（必须优先以此回答）】：\(note)"))
        } else if isFinanceQuestion {
            let exactAnswer = VoiceIntentProcessor(context: context).queryExpenses(query: q)
            blocks.append(PromptBlock(id: .verified, text: "• 【本轮账单精确核实结论（回答金额与日期时必须严格以此为准）】：\(exactAnswer)"))
        }

        // 必留：作答规则
        let rulesText = """
        【作答规则】：
        1. 用自然口语化、精准、贴心的中文回答，适合直接阅读或语音朗读；适当时称呼用户为「\(userTitle)」；
        2. 篇幅控制在 1-3 句话之内，直奔重点，不要输出多余格式符号；
        3. 如涉及上述任何生活模块数据，严格依据【用户全模块实时生活档案】如实回答，严禁编造数据；
        4. 当回答账单/消费问题时：请严格参考【本轮账单精确核实结论】与近期逐笔明细中的日期（今天/昨天/前天），若今天未消费但昨天有消费，必须明确说出昨天花了多少钱及具体项目，切勿生硬只说“今天消费了0元”。<|im_end|>
        """
        blocks.append(PromptBlock(id: .rules, text: rulesText))

        // 对话历史
        if !history.isEmpty {
            let historyText = history.map { turn in
                "<|im_start|>\(turn.role)\n\(turn.text)<|im_end|>"
            }.joined(separator: "\n")
            blocks.append(PromptBlock(id: .history, text: historyText))
        }

        // 必留：用户问句
        let queryBlockText = """
        <|im_start|>user
        \(query)<|im_end|>
        <|im_start|>assistant
        """
        blocks.append(PromptBlock(id: .query, text: queryBlockText))

        let keptBlocks: [PromptBlock]
        if let budget = budgetTokens {
            let fit = PromptBudget.fit(blocks: blocks, budgetTokens: budget)
            if fit.overflow {
                // 连必留块都超出预算，按契约返回空串，调用方降级到规则引擎
                return ""
            }
            keptBlocks = fit.blocks
        } else {
            keptBlocks = blocks
        }

        guard let personaBlock = keptBlocks.first(where: { $0.id == .persona }),
              let rulesBlock = keptBlocks.first(where: { $0.id == .rules }),
              let queryBlock = keptBlocks.first(where: { $0.id == .query }) else {
            return ""
        }

        var parts: [String] = [personaBlock.text]
        let profileBlocks = keptBlocks.filter { Self.lifeProfileBlockIDs.contains($0.id) || $0.id == .verified }
        if !profileBlocks.isEmpty {
            parts.append("【用户全模块实时生活档案】：")
            for b in profileBlocks {
                parts.append(b.text)
            }
        }
        parts.append(rulesBlock.text)

        if let historyBlock = keptBlocks.first(where: { $0.id == .history }) {
            parts.append(historyBlock.text)
        }
        parts.append(queryBlock.text)

        return parts.joined(separator: "\n")
    }

    /// 供 App 各内容模块（周期复盘润色、语音备忘提炼、自定义任务拆解、记账洞察等）调用的专项端侧推理接口
    /// - Parameter grammarGBNF: 非 nil 时对端侧 llama.cpp 推理挂 GBNF 语法约束；
    ///   局域网 Ollama 联调通道不支持自定义文法，该路径靠上层宽容解析与重试兜底。
    public func generateCustomTask(
        systemInstruction: String,
        userContent: String,
        maxNewTokens: Int = 256,
        grammarGBNF: String? = nil
    ) async -> String? {
        let modelManager = LLMModelManager.shared
        let modelReady = await modelManager.validateModelStatusAndWait()

        let chatMLPrompt = """
        <|im_start|>system
        \(systemInstruction)<|im_end|>
        <|im_start|>user
        \(userContent)<|im_end|>
        <|im_start|>assistant
        """

        if modelReady {
            isGenerating = true
            currentOutput = ""
            beginStreamingSession()
            defer { isGenerating = false }

            localEngineStatus = isLocalModelLoaded ? "正在端侧推理 (Metal)..." : "正在加载 GGUF 模型..."
            do {
                let output = try await LlamaCppEngine.shared.generate(
                    prompt: chatMLPrompt,
                    modelURL: modelManager.localModelURL,
                    maxNewTokens: maxNewTokens,
                    grammar: grammarGBNF
                ) { partial in
                    await MainActor.run {
                        LLMInferenceService.shared.handlePartialOutput(partial)
                    }
                }
                isLocalModelLoaded = true
                localEngineStatus = "已就绪 (llama.cpp Metal)"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    currentOutput = trimmed
                    return trimmed
                }
            } catch {
                isLocalModelLoaded = false
                localEngineStatus = "端侧推理异常：\(error.localizedDescription)"
            }
        }

        // 若启用了局域网 Ollama 联调，也支持作为备选
        if remoteContextConsent,
           !developerEndpoint.trimmingCharacters(in: .whitespaces).isEmpty,
           let endpointURL = URL(string: developerEndpoint) {
            let apiURL = endpointURL.appendingPathComponent("api/generate")
            var request = URLRequest(url: apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            let body: [String: Any] = [
                "model": "qwen2.5:1.5b",
                "prompt": chatMLPrompt,
                "stream": false
            ]
            if let httpBody = try? JSONSerialization.data(withJSONObject: body) {
                request.httpBody = httpBody
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reply = json["response"] as? String {
                    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }

        return nil
    }

    /// 判断用户输入是否属于明确的写库指令（记账 / 待办 / 修改 / 完成 / 取消 / 推迟），
    /// 统一走 OmniboxPlanner (LLM -> Rules 动作规划) 并由 OmniboxExecutor 拓扑执行，
    /// 保证两通道写库行为、目标解析与可撤销性完全合流。
    private func executeSideEffectIfNeeded(query: String, context: ModelContext) async -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isQuestionTone = trimmed.contains("多少") || trimmed.contains("几笔") || trimmed.contains("吗") ||
            trimmed.contains("？") || trimmed.contains("?") || trimmed.contains("是不是") || trimmed.contains("有没有") ||
            trimmed.contains("哪些") || trimmed.contains("什么") || trimmed.contains("查") || trimmed.contains("看")

        let hasActionAffordance = trimmed.contains("记") || trimmed.contains("花") || trimmed.contains("支出") ||
            trimmed.contains("买") || trimmed.contains("付") || trimmed.contains("提醒") || trimmed.contains("待办") ||
            trimmed.contains("完成") || trimmed.contains("取消") || trimmed.contains("推迟") || trimmed.contains("顺延") ||
            trimmed.contains("改")

        guard hasActionAffordance && !isQuestionTone else {
            return nil
        }

        // 统一走 OmniboxPlanner 规划动作（LLM 优先，规则兜底）
        let capture = OmniboxCapture(payloads: [.text(trimmed)], source: .voice)
        let planResult = await OmniboxPlanner().plan(capture: capture)
        let executableActions = planResult.actions.filter {
            $0.capability != .queryLookup && $0.capability != .memoInbox
        }
        guard !executableActions.isEmpty else {
            return nil
        }

        // 拓扑执行并获取回执
        let outcomes = OmniboxExecutor.executeTopologically(executableActions, context: context)
        let summaries = outcomes.compactMap { outcome -> String? in
            if outcome.succeeded {
                return outcome.summary
            } else if let err = outcome.errorText {
                return "执行异常：\(err)"
            }
            return nil
        }
        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: "；")
    }

    /// 明确的查询类指令交给规则处理器，确保金额、日期和数据库记录不被小模型猜错。
    private func shouldRouteQueryToRules(_ query: String) -> Bool {
        DialogueRouter.shouldRouteQueryToRules(query)
    }

    /// 闲聊与轻度交流：不加载 12 段生活档案，走轻量提示词
    private func isSmallTalk(_ query: String) -> Bool {
        DialogueRouter.isSmallTalk(query)
    }

    /// 执行智能生成推理（优先使用端侧 GGUF + llama.cpp，其次局域网 Ollama，最后规则引擎兜底）
    public func generate(query: String, sessionID: UUID? = nil, context: ModelContext) async -> String {
        isGenerating = true
        currentOutput = ""
        beginStreamingSession()
        defer { isGenerating = false }

        // 0. 若包含明确的新建待办/记账/完成等写库意图，统一经 Omnibox 拓扑执行
        let sideEffectNote = await executeSideEffectIfNeeded(query: query, context: context)

        // 查询类指令直接读取 SwiftData 后返回，避免端侧小模型对金额、日期或清单内容产生幻觉。
        if sideEffectNote == nil && shouldRouteQueryToRules(query) {
            return await VoiceIntentProcessor(context: context).process(query: query)
        }

        let isSmall = isSmallTalk(query)
        // 多轮记忆注入：读取当前会话最近轮次（保留策略为 .none 时返回空数组）
        let history = DialogueHistoryManager.shared.recentTurns(sessionID: sessionID, limit: 8, context: context)

        // 1. 优先检查本地 GGUF 模型文件是否已下载，执行真正的端侧 llama.cpp 推理
        let modelManager = LLMModelManager.shared
        let modelReady = await modelManager.validateModelStatusAndWait()
        if modelReady {
            let maxNewTokens = 256
            let budget = await LlamaCppEngine.shared.promptTokenBudget(
                at: modelManager.localModelURL,
                reservingForGeneration: maxNewTokens
            )
            let prompt = buildPrompt(
                query: query,
                context: context,
                actionExecutionNote: sideEffectNote,
                history: history,
                budgetTokens: budget,
                includeLifeProfile: !isSmall
            )

            if prompt.isEmpty {
                // 必留块自身超预算，降级到规则引擎
                return await VoiceIntentProcessor(context: context).process(query: query)
            }

            localEngineStatus = isLocalModelLoaded ? "正在端侧推理 (Metal)..." : "正在加载 GGUF 模型..."
            do {
                let output = try await LlamaCppEngine.shared.generate(
                    prompt: prompt,
                    modelURL: modelManager.localModelURL,
                    maxNewTokens: maxNewTokens
                ) { partial in
                    await MainActor.run {
                        LLMInferenceService.shared.handlePartialOutput(partial)
                    }
                }
                isLocalModelLoaded = true
                localEngineStatus = "已就绪 (llama.cpp Metal)"
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedOutput.isEmpty {
                    currentOutput = trimmedOutput
                    return trimmedOutput
                }
            } catch LlamaInferenceError.contextOverflow {
                // 真分词后仍超预算，安全降级到规则引擎
                localEngineStatus = "上下文超窗，已降级规则引擎"
                return await VoiceIntentProcessor(context: context).process(query: query)
            } catch {
                isLocalModelLoaded = false
                localEngineStatus = "端侧推理异常：\(error.localizedDescription)"
            }
        } else {
            localEngineStatus = "未下载本地 GGUF 模型"
        }

        // 2. 若未下载本地模型（或本地加载失败），且用户明确授权启用了局域网 Ollama
        if remoteContextConsent,
           !developerEndpoint.trimmingCharacters(in: .whitespaces).isEmpty,
           let endpointURL = URL(string: developerEndpoint) {
            remoteConnectionStatus = "连接中"
            if let result = await generateViaRemoteOllama(
                query: query,
                endpoint: endpointURL,
                context: context,
                actionExecutionNote: sideEffectNote,
                history: history,
                includeLifeProfile: !isSmall
            ) {
                remoteConnectionStatus = "已连接"
                return result
            }
            remoteConnectionStatus = "连接失败，已使用本机规则"
        } else {
            remoteConnectionStatus = remoteContextConsent ? "请填写有效端点" : "未启用"
        }

        // 3. 兜底：使用本机规则引擎
        if let sideEffectNote {
            return sideEffectNote
        }
        let baseReply = await VoiceIntentProcessor(context: context).process(query: query)
        if case .validationFailed(let reason) = modelManager.validationStatus {
            // 文件存在但完整性校验失败：明确展示原因，不能静默回落成「未下载」或「就绪」
            return "\(baseReply)\n\n⚠️ 模型文件校验未通过（\(L10n.tr(reason))），已切换至本机规则助手回答，可在「设置 → AI 模型」中重新校验或重新导入。"
        }
        if !modelManager.isModelDownloaded {
            return "\(baseReply)\n\n💡 当前尚未下载本地 GGUF 模型，已使用本机规则助手回答（可在「设置 → AI 模型」中下载 Qwen2.5-1.5B 开启端侧推理）。"
        } else {
            return "\(baseReply)\n\n⚠️ 端侧模型推理未就绪（\(localEngineStatus)），已切换至本机规则助手回答。"
        }
    }

    /// 局域网 Ollama 快速对接（方便电脑开启 `ollama run qwen2.5:1.5b` 时手机直接联调）
    private func generateViaRemoteOllama(
        query: String,
        endpoint: URL,
        context: ModelContext,
        actionExecutionNote: String? = nil,
        history: [(role: String, text: String)] = [],
        includeLifeProfile: Bool = true
    ) async -> String? {
        let prompt = buildPrompt(
            query: query,
            context: context,
            actionExecutionNote: actionExecutionNote,
            history: history,
            includeLifeProfile: includeLifeProfile
        )
        let apiURL = endpoint.appendingPathComponent("api/generate")
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "qwen2.5:1.5b",
            "prompt": prompt,
            "stream": false
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reply = json["response"] as? String {
                return reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }
        return nil
    }
}
