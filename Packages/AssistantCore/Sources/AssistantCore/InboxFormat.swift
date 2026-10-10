import Foundation

/// 收件箱文件格式：快捷指令每收到一条短信，就追加一段
///
///     ===MSG===
///     <短信内容>
///
/// App 启动时读出所有条目补录，然后清空文件。
public enum InboxFormat {
    public static let separator = "===MSG==="

    public static func entries(from content: String) -> [String] {
        content
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
