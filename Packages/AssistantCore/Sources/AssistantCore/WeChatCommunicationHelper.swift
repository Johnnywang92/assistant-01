import Foundation

/// 微信沟通与音视频类待办识别辅助引擎
/// 针对国内日常社交场景（沟通99%为微信视频/语音/即时通讯）提供精准识别与快捷直达。
public enum WeChatCommunicationHelper: Sendable {
    private static let weChatKeywords: [String] = [
        "微信", "打视频", "视频通话", "微信视频", "微信语音",
        "微信电话", "发微信", "微信问", "微信联系", "微信回复",
        "打个视频", "打视频电话", "微信聊天", "微信打给"
    ]

    /// 判断标题或详情是否为微信沟通/视频类事项
    public static func isWeChatCommunication(title: String, detail: String? = nil) -> Bool {
        let text = (title + " " + (detail ?? "")).lowercased()
        for kw in weChatKeywords {
            if text.contains(kw) {
                return true
            }
        }
        return false
    }

    /// 提取沟通类型（视频 / 语音 / 消息）
    public static func communicationKind(title: String, detail: String? = nil) -> CommunicationKind {
        let text = (title + " " + (detail ?? "")).lowercased()
        if text.contains("视频") {
            return .video
        } else if text.contains("语音") || text.contains("电话") {
            return .audio
        } else {
            return .message
        }
    }

    public enum CommunicationKind: String, Sendable, CaseIterable {
        case video
        case audio
        case message

        public var buttonTitle: String {
            switch self {
            case .video: return "打开微信视频"
            case .audio: return "打开微信语音"
            case .message: return "打开微信"
            }
        }

        public var iconName: String {
            switch self {
            case .video: return "video.fill"
            case .audio: return "phone.fill"
            case .message: return "bubble.left.and.bubble.right.fill"
            }
        }
    }

    /// 微信应用 URL Scheme
    public static let weChatURLScheme = "weixin://"
}
