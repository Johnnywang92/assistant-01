import AssistantCore
import Foundation
import SwiftData

// MARK: - 能力标识（基于 AssistantCore.ActionCapability 扩充展示属性）

typealias OmniboxCapability = ActionCapability

extension ActionCapability {
    /// 展示名与图标来自能力描述符，新增能力不再需要改这里。
    var displayName: String {
        L10n.tr(CapabilityRegistry.descriptor(for: self)?.displayName ?? rawValue)
    }

    var systemImage: String {
        CapabilityRegistry.descriptor(for: self)?.systemImage ?? "questionmark.circle"
    }
}

// MARK: - 统一 Capture 协议（文字/图片/语音在进入理解层前归一）

public enum OmniboxPayload: Sendable {
    case text(String)
    case image(Data)
    case audioTranscript(String)
}

struct OmniboxCapture: Sendable {
    enum Source: String, Codable, Sendable {
        case paste      // 首页粘贴文字
        case dragDrop   // 拖入/选取图片
        case voice      // 语音转写
        case mixed
    }

    var id: UUID = UUID()
    var payloads: [OmniboxPayload] = []
    var source: Source = .paste
    var capturedAt: Date = .now
}

// MARK: - 计划动作与撤销令牌类型桥接

typealias PlannedAction = ActionItem
typealias OmniboxUndoToken = ActionUndoToken

// MARK: - 执行回执条目

struct ActionExecutionOutcome: Identifiable {
    var id: UUID
    var action: PlannedAction
    var summary: String?
    var undo: OmniboxUndoToken
    var errorText: String?
    var succeeded: Bool { errorText == nil }
}

// MARK: - 投喂事务（SwiftData 持久化，用于回执追溯与审计）

/// 一次投喂产生一个 transaction：记录输入、拆解出的动作与执行状态
@Model
final class OmniboxTransaction {
    var id: UUID
    var createdAt: Date
    var sourceRaw: String
    var inputText: String
    var imageCount: Int
    /// 计划动作（含参数）的 JSON 编码
    var actionsJSON: Data
    /// planned / executed / undone
    var statusRaw: String
    var executedAt: Date?
    /// 使用的理解引擎：llm / rules
    var engineRaw: String = "rules"
    /// 撤销令牌 JSON（[OmniboxUndoToken]），status == executed 时可用于跨启动撤销
    var undoJSON: Data?

    init(capture: OmniboxCapture, actions: [PlannedAction], engine: String) {
        self.id = UUID()
        self.createdAt = .now
        self.sourceRaw = capture.source.rawValue
        self.inputText = capture.payloads.compactMap { payload in
            switch payload {
            case .text(let t), .audioTranscript(let t): return t
            case .image: return nil
            }
        }.joined(separator: "\n")
        self.imageCount = capture.payloads.filter {
            if case .image = $0 { return true }
            return false
        }.count
        self.actionsJSON = (try? JSONEncoder().encode(actions)) ?? Data()
        self.statusRaw = "planned"
        self.engineRaw = engine
    }

    var status: OmniboxTransactionStatus {
        get { OmniboxTransactionStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }

    var decodedActions: [PlannedAction] {
        (try? JSONDecoder().decode([PlannedAction].self, from: actionsJSON)) ?? []
    }
}

enum OmniboxTransactionStatus: String, Codable {
    case planned
    case executed
    case undone
}

// MARK: - 判别反馈（点赞/点踩，SwiftData 持久化）

/// 用户对「这次意图判断准不准」的反馈。回流到 `IntentFeedbackMemory` 提升下次判断：
/// 被点踩的输入下次强制确认，被点赞的意图下次优先预填。
/// 同时快照 topProbability/margin，为判别层阈值校准积累真实语料。
@Model
final class OmniboxJudgmentFeedback {
    var id: UUID
    var createdAt: Date
    /// 归一化后的输入文本（IntentFeedbackMemory.normalize）
    var inputText: String
    /// 反馈时刻判别的标签（OmniboxIntentLabel.rawValue）
    var labelRaw: String
    /// up / down
    var verdictRaw: String
    var topProbability: Double
    var margin: Double
    /// 判别时次选标签（top2）快照。点踩且未纠正时，与 labelRaw 构成疑似混淆对。
    var runnerUpLabelRaw: String?
    /// 点踩后用户点选的正确标签。与 labelRaw 构成实锤混淆对（判成 X、实际 Y）。
    var correctedLabelRaw: String?

    init(_ feedback: JudgmentFeedback) {
        self.id = feedback.id
        self.createdAt = feedback.createdAt
        self.inputText = feedback.inputText
        self.labelRaw = feedback.labelRaw
        self.verdictRaw = feedback.verdict.rawValue
        self.topProbability = feedback.topProbability
        self.margin = feedback.margin
        self.runnerUpLabelRaw = feedback.runnerUpLabelRaw
        self.correctedLabelRaw = feedback.correctedLabelRaw
    }

    var feedback: JudgmentFeedback {
        JudgmentFeedback(
            id: id,
            inputText: inputText,
            labelRaw: labelRaw,
            verdict: JudgmentFeedback.Verdict(rawValue: verdictRaw) ?? .up,
            topProbability: topProbability,
            margin: margin,
            runnerUpLabelRaw: runnerUpLabelRaw,
            correctedLabelRaw: correctedLabelRaw,
            createdAt: createdAt
        )
    }
}
