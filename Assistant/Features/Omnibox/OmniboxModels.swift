import Foundation
import SwiftData

// MARK: - 能力标识（模块只注册 Capability，理解层不认识模块，只认识动作类型）

/// Omnibox 可派发的动作能力类型
enum OmniboxCapability: String, Codable, CaseIterable {
    /// 记一笔收支 → ExpenseRecord
    case expenseCreate = "expense.create"
    /// 建一条待办（可带截止时间）→ TodoItem
    case todoCreate = "todo.create"
    /// 无法归类的内容落入收集箱备忘
    case memoInbox = "memo.inbox"

    var displayName: String {
        switch self {
        case .expenseCreate: return L10n.tr("记账")
        case .todoCreate: return L10n.tr("待办")
        case .memoInbox: return L10n.tr("收集箱")
        }
    }

    var systemImage: String {
        switch self {
        case .expenseCreate: return "yensign.circle.fill"
        case .todoCreate: return "checklist"
        case .memoInbox: return "tray.full.fill"
        }
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

// MARK: - 计划动作（Planner 输出的动作 DAG 节点）

struct PlannedAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var capability: OmniboxCapability
    /// 能力所需参数（键值均为字符串，宽容解析 LLM/规则输出）
    var params: [String: String]
    /// 0~1，低于 omnibox_low_confidence_threshold 的在确认卡中灰显提示
    var confidence: Double
    /// 依赖的前序动作 id（执行按拓扑序，先记账拿到金额再建保修提醒）
    var dependsOn: [UUID] = []
    /// 用户在确认卡中是否勾选（默认勾选，低置信度默认不勾选）
    var isSelected: Bool = true
    /// 一句话预览（确认卡与回执展示）
    var summary: String = ""

    static let lowConfidenceThreshold = 0.6

    var needsConfirmation: Bool { confidence < PlannedAction.lowConfidenceThreshold }
}

// MARK: - 撤销令牌（每个执行器必须支持 undo，回执即事务）

struct OmniboxUndoToken: Codable {
    enum Kind: String, Codable {
        case todo
        case expense
        case memoLine
    }

    var kind: Kind
    var recordID: UUID?
    /// memo 行内容（按行删除用）
    var memoLine: String?
}

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
