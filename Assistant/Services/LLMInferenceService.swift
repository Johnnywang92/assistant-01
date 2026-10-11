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
        }
    }
}

/// 端侧 llama.cpp (GGUF + Metal) 独立推理引擎 Actor
actor LlamaCppEngine {
    static let shared = LlamaCppEngine()

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

    /// 执行流式 ChatML 端侧推理
    func generate(
        prompt: String,
        modelURL: URL,
        maxNewTokens: Int = 256,
        onPartialOutput: @Sendable (String) async -> Void
    ) async throws -> String {
        try ensureModelLoaded(at: modelURL)
        guard let model, let vocab else {
            throw LlamaInferenceError.modelLoadFailed(modelURL.lastPathComponent)
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
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

        // 截断超长输入以留出生成空间
        let maxPromptLength = Int(ctxParams.n_ctx) - maxNewTokens - 16
        if promptTokens.count > maxPromptLength && maxPromptLength > 64 {
            promptTokens = Array(promptTokens.suffix(maxPromptLength))
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
        onPartialOutput: @Sendable (String) async -> Void
    ) async throws -> String {
        throw LlamaInferenceError.frameworkNotLinked
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

    private init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let service = LLMInferenceService.shared
                guard !service.isGenerating else { return }
                await service.unloadLocalModel()
            }
        }
        #endif
    }

    /// 预加载本地 GGUF 模型至 Metal / 内存
    public func preloadLocalModel() async {
        let manager = LLMModelManager.shared
        manager.checkModelStatus()
        guard manager.isModelDownloaded else {
            localEngineStatus = "未下载 GGUF 模型"
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

    /// 提取用户全模块生活数据并构建 ChatML 提示词模板（覆盖快递、待办、记账、纪念日、收纳、用药习惯、订阅保质期、萌宠、育儿、爱车、证件到期、语音备忘与常去地点）
    public func buildPrompt(query: String, context: ModelContext, actionExecutionNote: String? = nil) -> String {
        let name = assistantName.isEmpty ? "小助" : assistantName
        let now = Date.now.formatted(date: .complete, time: .shortened)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

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
        let records = ((try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []).sorted { $0.date > $1.date }

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
        let recentExpenseText = records.filter { !$0.isIncome }.prefix(5)
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

        // 4. 纪念日与倒数日
        let anniversaries = ((try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? [])
            .sorted { $0.daysUntilNext < $1.daysUntilNext }
        let anniText: String = anniversaries.isEmpty ? "无" : anniversaries.prefix(3).map {
            "\($0.title)（还有 \($0.daysUntilNext) 天）"
        }.joined(separator: "、")

        // 5. 物品收纳箱（优先匹配问题关键词）
        let storedItems = (try? context.fetch(FetchDescriptor<StoredItem>())) ?? []
        let matchedStored = storedItems.filter { q.contains($0.name) || q.contains($0.roomArea) || $0.name.contains(q) }
        let displayStored = matchedStored.isEmpty ? Array(storedItems.prefix(5)) : Array(matchedStored.prefix(6))
        let storageText: String = displayStored.isEmpty ? "未录入" : displayStored.map {
            "\($0.name) -> \($0.roomArea)·\($0.location)"
        }.joined(separator: "；")

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

        // 9. 语音备忘录与常去地点
        let memos = ((try? context.fetch(FetchDescriptor<VoiceMemo>())) ?? []).sorted { $0.createdAt > $1.createdAt }
        let memoText: String = memos.isEmpty ? "无" : memos.prefix(2).map { m in
            let snippet = (m.summary ?? m.transcription ?? "").prefix(30)
            return snippet.isEmpty ? m.title : "\(m.title)：\(snippet)"
        }.joined(separator: "；")

        let places = (try? context.fetch(FetchDescriptor<LearnedPlace>())) ?? []
        let placeText: String = places.isEmpty ? "未学习" : places.prefix(3).map { "\($0.category.rawValue)：\($0.name)" }.joined(separator: "、")

        let userTitle = AppSettings.userTitle
        let isFinanceQuestion = q.contains("花") || q.contains("消费") || q.contains("支出") ||
            q.contains("开销") || q.contains("账") || q.contains("钱") || q.contains("元") || q.contains("块")
        let verifiedFinanceHint: String = {
            if let note = actionExecutionNote {
                return "\n• 【刚刚完成的本机操作与精确统计（必须优先以此回答）】：\(note)"
            } else if isFinanceQuestion {
                let exactAnswer = VoiceIntentProcessor(context: context).queryExpenses(query: q)
                return "\n• 【本轮账单精确核实结论（回答金额与日期时必须严格以此为准）】：\(exactAnswer)"
            }
            return ""
        }()

        // 组合 Qwen2.5 ChatML 格式
        let prompt = """
        <|im_start|>system
        你是运行在用户 iPhone 本地的全能私人管家「\(name)」（基于 Qwen2.5-1.5B 与 llama.cpp 端侧引擎）。
        当前对用户的称呼：\(userTitle)
        当前时间：\(now)
        【用户全模块实时生活档案】：
        • 待取快递：\(parcelText)
        • 日常待办与日程：\(todoText)
        • 财务账本：\(financeOverview)\(topCatText.isEmpty ? "" : "；主要分类：\(topCatText)")\(recentExpenseText.isEmpty ? "" : "；近期逐笔明细：\(recentExpenseText)")
        • 纪念日倒数：\(anniText)
        • 物品收纳位置：\(storageText)
        • 用药与习惯打卡：\(habitMedText)
        • 证件/订阅/保质期：\(vaultAlertText)
        • 家庭档案(萌宠/育儿/爱车)：\(familyText)
        • 近期语音备忘：\(memoText)
        • 常去地点：\(placeText)\(verifiedFinanceHint)
        【作答规则】：
        1. 用自然口语化、精准、贴心的中文回答，适合直接阅读或语音朗读；适当时称呼用户为「\(userTitle)」；
        2. 篇幅控制在 1-3 句话之内，直奔重点，不要输出多余格式符号；
        3. 如涉及上述任何生活模块数据，严格依据【用户全模块实时生活档案】如实回答，严禁编造数据；
        4. 当回答账单/消费问题时：请严格参考【本轮账单精确核实结论】与近期逐笔明细中的日期（今天/昨天/前天），若今天未消费但昨天有消费，必须明确说出昨天花了多少钱及具体项目，切勿生硬只说“今天消费了0元”。<|im_end|>
        <|im_start|>user
        \(query)<|im_end|>
        <|im_start|>assistant
        """
        return prompt
    }

    /// 供 App 各内容模块（周期复盘润色、语音备忘提炼、自定义任务拆解、记账洞察等）调用的专项端侧推理接口
    public func generateCustomTask(
        systemInstruction: String,
        userContent: String,
        maxNewTokens: Int = 256
    ) async -> String? {
        let modelManager = LLMModelManager.shared
        modelManager.checkModelStatus()

        let chatMLPrompt = """
        <|im_start|>system
        \(systemInstruction)<|im_end|>
        <|im_start|>user
        \(userContent)<|im_end|>
        <|im_start|>assistant
        """

        if modelManager.isModelDownloaded || modelManager.hasValidLocalGGUFFile {
            isGenerating = true
            currentOutput = ""
            defer { isGenerating = false }

            localEngineStatus = isLocalModelLoaded ? "正在端侧推理 (Metal)..." : "正在加载 GGUF 模型..."
            do {
                let output = try await LlamaCppEngine.shared.generate(
                    prompt: chatMLPrompt,
                    modelURL: modelManager.localModelURL,
                    maxNewTokens: maxNewTokens
                ) { partial in
                    await MainActor.run {
                        let service = LLMInferenceService.shared
                        service.isLocalModelLoaded = true
                        service.localEngineStatus = "正在生成回复 (Metal)..."
                        service.currentOutput = partial
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

    /// 判断用户输入是否属于明确的写库指令（记一笔账 / 新建提醒待办），如是则先落库并返回执行摘要
    private func executeSideEffectIfNeeded(query: String, context: ModelContext) async -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isQuestionTone = trimmed.contains("多少") || trimmed.contains("几笔") || trimmed.contains("吗") ||
            trimmed.contains("？") || trimmed.contains("?") || trimmed.contains("是不是") || trimmed.contains("有没有") ||
            trimmed.contains("哪些") || trimmed.contains("什么") || trimmed.contains("查") || trimmed.contains("看")
        let isExpenseIntent = !isQuestionTone &&
            ExpenseNaturalLanguageParser.parse(trimmed) != nil &&
            (trimmed.contains("花") || trimmed.contains("元") || trimmed.contains("块") ||
             trimmed.contains("支出") || trimmed.contains("收入") || trimmed.contains("买") ||
             trimmed.contains("付") || trimmed.contains("记账") || trimmed.contains("记一笔") || trimmed.contains("消费"))

        let isExplicitTodoIntent = trimmed.hasPrefix("记一下") || trimmed.hasPrefix("添加待办") ||
            trimmed.hasPrefix("提醒我") || trimmed.hasPrefix("帮我记") ||
            trimmed.hasPrefix("帮我建") || trimmed.hasPrefix("建立待办") ||
            trimmed.contains("提醒我")

        guard isExpenseIntent || isExplicitTodoIntent else {
            return nil
        }
        return await VoiceIntentProcessor(context: context).process(query: trimmed)
    }

    /// 明确的查询类指令交给规则处理器，确保金额、日期和数据库记录不被小模型猜错。
    private func shouldRouteQueryToRules(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookupKeywords = [
            "快递", "取件", "包裹", "流量", "话费", "哪里", "地点", "开销", "支出",
            "消费", "花销", "账单", "账本", "花了多少", "消费了多少", "纪念日", "生日",
            "倒数", "待办", "要做", "安排", "出门", "防丢", "忘带", "随身", "日报",
            "周报", "月报", "复盘", "今天总结", "今日总结", "本周总结", "本月总结"
        ]
        guard lookupKeywords.contains(where: text.contains) else { return false }
        let questionMarkers = ["多少", "几笔", "吗", "？", "?", "是不是", "有没有", "哪些", "什么", "查", "看", "今天", "昨天", "本月", "本周", "最近", "当前"]
        return questionMarkers.contains(where: text.contains)
    }

    /// 执行智能生成推理（优先使用端侧 GGUF + llama.cpp，其次局域网 Ollama，最后规则引擎兜底）
    public func generate(query: String, context: ModelContext) async -> String {
        isGenerating = true
        currentOutput = ""
        defer { isGenerating = false }

        // 0. 若包含明确的新建待办/记账写库意图，先执行写库操作以免只聊天不落库
        let sideEffectNote = await executeSideEffectIfNeeded(query: query, context: context)

        // 查询类指令直接读取 SwiftData 后返回，避免端侧小模型对金额、日期或清单内容产生幻觉。
        if sideEffectNote == nil && shouldRouteQueryToRules(query) {
            return await VoiceIntentProcessor(context: context).process(query: query)
        }

        // 1. 优先检查本地 GGUF 模型文件是否已下载，执行真正的端侧 llama.cpp 推理
        let modelManager = LLMModelManager.shared
        modelManager.checkModelStatus()
        if modelManager.isModelDownloaded {
            let prompt = buildPrompt(query: query, context: context, actionExecutionNote: sideEffectNote)
            localEngineStatus = isLocalModelLoaded ? "正在端侧推理 (Metal)..." : "正在加载 GGUF 模型..."
            do {
                let output = try await LlamaCppEngine.shared.generate(
                    prompt: prompt,
                    modelURL: modelManager.localModelURL,
                    maxNewTokens: 256
                ) { partial in
                    await MainActor.run {
                        let service = LLMInferenceService.shared
                        service.isLocalModelLoaded = true
                        service.localEngineStatus = "正在生成回复 (Metal)..."
                        service.currentOutput = partial
                    }
                }
                isLocalModelLoaded = true
                localEngineStatus = "已就绪 (llama.cpp Metal)"
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedOutput.isEmpty {
                    currentOutput = trimmedOutput
                    return trimmedOutput
                }
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
            if let result = await generateViaRemoteOllama(query: query, endpoint: endpointURL, context: context, actionExecutionNote: sideEffectNote) {
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
        actionExecutionNote: String? = nil
    ) async -> String? {
        let prompt = buildPrompt(query: query, context: context, actionExecutionNote: actionExecutionNote)
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
