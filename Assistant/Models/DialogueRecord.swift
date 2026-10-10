import Foundation
import SwiftData

/// 对话记录保留策略枚举
public enum DialogueRetentionPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case none = "none"           // 不保留（即用即走）
    case sevenDays = "7days"     // 保留 7 天
    case thirtyDays = "30days"   // 保留 30 天
    case forever = "forever"     // 永久保留

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "不保留 (即用即走)"
        case .sevenDays: return "自动保留 7 天"
        case .thirtyDays: return "自动保留 30 天"
        case .forever: return "永久保留"
        }
    }

    public var shortTitle: String {
        switch self {
        case .none: return "不保留"
        case .sevenDays: return "7天保留"
        case .thirtyDays: return "30天保留"
        case .forever: return "永久保留"
        }
    }

    public var retentionDays: Int {
        switch self {
        case .none: return 0
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .forever: return -1
        }
    }
}

/// 本地离线对话消息实体（纯端侧 SwiftData 存储）
@Model
final class DialogueMessageRecord {
    var id: UUID
    var roleRaw: String // "user" or "assistant"
    var text: String
    var timestamp: Date
    var sessionID: UUID?

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        timestamp: Date = .now,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.roleRaw = role
        self.text = text
        self.timestamp = timestamp
        self.sessionID = sessionID
    }

    var isUser: Bool {
        roleRaw == "user"
    }
}
