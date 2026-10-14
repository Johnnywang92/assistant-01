import AssistantCore
import Foundation
import SwiftData

// MARK: - 能力标识（基于 AssistantCore.ActionCapability 扩充展示属性）

typealias OmniboxCapability = ActionCapability

extension ActionCapability {
    var displayName: String {
        switch self {
        case .expenseCreate: return L10n.tr("记账")
        case .expenseUpdate: return L10n.tr("修改账目")
        case .todoCreate: return L10n.tr("待办")
        case .todoUpdate: return L10n.tr("修改待办")
        case .todoComplete: return L10n.tr("完成待办")
        case .todoCancel: return L10n.tr("取消待办")
        case .reminderSnooze: return L10n.tr("推迟提醒")
        case .memoInbox: return L10n.tr("收集箱")
        case .queryLookup: return L10n.tr("查询事项")
        }
    }

    var systemImage: String {
        switch self {
        case .expenseCreate: return "yensign.circle.fill"
        case .expenseUpdate: return "pencil.circle.fill"
        case .todoCreate: return "checklist"
        case .todoUpdate: return "pencil.and.list.clipboard"
        case .todoComplete: return "checkmark.circle.fill"
        case .todoCancel: return "xmark.circle.fill"
        case .reminderSnooze: return "clock.arrow.circlepath"
        case .memoInbox: return "tray.full.fill"
        case .queryLookup: return "magnifyingglass"
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
