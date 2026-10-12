import Foundation

/// 助手全局运行模式
public enum AssistantMode: String, CaseIterable, Codable {
    case quiet = "安静模式"
    case alert = "提醒模式"
    case recordOnly = "记录模式"

    public var icon: String {
        switch self {
        case .quiet: "bell.slash.fill"
        case .alert: "bell.and.waves.left.and.right.fill"
        case .recordOnly: "pencil.and.list.clipboard"
        }
    }

    public var displayName: String {
        L10n.tr(rawValue)
    }

    public var description: String {
        switch self {
        case .quiet:
            L10n.tr("不弹出任何横幅通知或声音，静默提取和归档所有信息与待办。")
        case .alert:
            L10n.tr("标准智能提醒模式：环境变化、出门带伞、到达驿站等主动弹出提醒与语音交互。")
        case .recordOnly:
            L10n.tr("纯备忘记录模式：只记录归档所有消息与轨迹，不生成任何主动提醒与待办催办。")
        }
    }
}
