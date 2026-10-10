import Foundation
import SwiftData
import SwiftUI

/// 规则问答与用户明确启用的局域网 Ollama 连接。GGUF 本地推理尚未接入。
@MainActor
public final class LLMInferenceService: ObservableObject {
    public static let shared = LLMInferenceService()

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("llm_developer_endpoint") public var developerEndpoint: String = "" // 如 http://192.168.1.5:11434 (局域网 Ollama)
    @AppStorage("llm_remote_context_consent") public var remoteContextConsent: Bool = false
    @Published public var isGenerating: Bool = false
    @Published public var currentOutput: String = ""
    @Published public var remoteConnectionStatus: String = "未连接"

    private init() {}

    /// 提取用户生活数据并构建 ChatML 提示词模板
    public func buildPrompt(query: String, context: ModelContext) -> String {
        let name = assistantName.isEmpty ? "小助" : assistantName
        let now = Date.now.formatted(date: .complete, time: .shortened)

        // 1. 快递信息
        let active = TodoStatus.active.rawValue
        let parcelType = TodoType.parcel.rawValue
        let parcels = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == parcelType && $0.statusRaw == active }
        ))) ?? []
        let parcelText: String
        if parcels.isEmpty {
            parcelText = "暂无待取包裹"
        } else {
            parcelText = parcels.map {
                let code = $0.pickupCode ?? "无取件码"
                let loc = $0.location ?? $0.station ?? "暂存点"
                return "\($0.courier ?? "快递")（码：\(code)，在 \(loc)）"
            }.joined(separator: "；")
        }

        // 2. 待办事项
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw != parcelType && $0.statusRaw == active }
        ))) ?? []
        let todoText: String
        if todos.isEmpty {
            todoText = "暂无未完成待办"
        } else {
            todoText = todos.prefix(5).map { $0.title }.joined(separator: "、")
        }

        // 3. 记账开销（单次 O(N) 循环聚合计算）
        let calendar = Calendar.current
        let currentMonth = calendar.component(.month, from: .now)
        let currentYear = calendar.component(.year, from: .now)
        var todayExpense: Double = 0
        var monthExpense: Double = 0
        let records = (try? context.fetch(FetchDescriptor<ExpenseRecord>())) ?? []
        for r in records where !r.isIncome {
            if calendar.isDateInToday(r.date) {
                todayExpense += r.amount
            }
            if calendar.component(.year, from: r.date) == currentYear &&
               calendar.component(.month, from: r.date) == currentMonth {
                monthExpense += r.amount
            }
        }

        // 4. 临近纪念日 (直接 O(N) 极速取最小)
        let anniversaries = (try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? []
        let nearestAnni = anniversaries.min(by: { $0.daysUntilNext < $1.daysUntilNext })
        let anniText: String
        if let nearestAnni {
            anniText = "\(nearestAnni.title)（还有 \(nearestAnni.daysUntilNext) 天）"
        } else {
            anniText = "无"
        }

        let userTitle = AppSettings.userTitle

        // 组合 Qwen2.5 ChatML 格式
        let prompt = """
        <|im_start|>system
        你是个人助理「\(name)」，由用户配置的局域网 Ollama 服务提供回答。
        当前对用户的称呼：\(userTitle)
        当前时间：\(now)
        【用户实时生活档案】：
        • 待取快递：\(parcelText)
        • 日常待办：\(todoText)
        • 财务支出：今日消费 ¥\(String(format: "%.1f", todayExpense))，本月累计消费 ¥\(String(format: "%.1f", monthExpense))
        • 最近纪念日：\(anniText)
        【作答规则】：
        1. 用口语化、精准、贴心的中文回答，适合语音朗读；适当时称呼用户为「\(userTitle)」；
        2. 篇幅控制在 1-3 句话之内，直奔重点，严禁废话；
        3. 如涉及生活数据，根据上述真实上下文如实汇报。<|im_end|>
        <|im_start|>user
        \(query)<|im_end|>
        <|im_start|>assistant
        
        """
        return prompt
    }

    /// 执行智能生成推理
    public func generate(query: String, context: ModelContext) async -> String {
        isGenerating = true
        currentOutput = ""
        defer { isGenerating = false }

        // 只有用户明确同意发送生活数据后，才连接局域网端点。
        if remoteContextConsent,
           !developerEndpoint.trimmingCharacters(in: .whitespaces).isEmpty,
           let endpointURL = URL(string: developerEndpoint) {
            remoteConnectionStatus = "连接中"
            if let result = await generateViaRemoteOllama(query: query, endpoint: endpointURL, context: context) {
                remoteConnectionStatus = "已连接"
                return result
            }
            remoteConnectionStatus = "连接失败，已使用本机规则"
        } else {
            remoteConnectionStatus = remoteContextConsent ? "请填写有效端点" : "未启用"
        }

        let baseReply = await VoiceIntentProcessor(context: context).process(query: query)
        let reason = remoteConnectionStatus == "连接失败，已使用本机规则"
            ? "局域网服务连接失败，已使用本机规则助手。"
            : "当前使用本机规则助手；已下载的 GGUF 文件尚未接入推理。"
        return "\(baseReply)\n\n\(reason)"
    }

    /// 局域网 Ollama 快速对接（方便电脑开启 `ollama run qwen2.5:1.5b` 时手机直接联调）
    private func generateViaRemoteOllama(query: String, endpoint: URL, context: ModelContext) async -> String? {
        let prompt = buildPrompt(query: query, context: context)
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
