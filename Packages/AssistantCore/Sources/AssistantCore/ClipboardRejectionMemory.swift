import CryptoKit
import Foundation

// MARK: - 剪贴板内容拒绝记忆（纯逻辑）

/// 记住「用户已经拒绝过的剪贴板内容」，同一条内容不再反复唤起投喂。
///
/// 背景：过去只按 `UIPasteboard.changeCount` 去重——同一条内容再复制一次
/// changeCount 就变了，于是同一条消息被反复带进万能投喂口。
/// 用户关掉过一次就是明确的「这条内容不需要」，必须按**内容身份**记住，而不是按剪贴板序号。
///
/// 设计约束：
/// 1. **只存哈希不存明文**——剪贴板里可能有密码/验证码/私人消息，
///    明文进 UserDefaults 是隐私泄漏。键是 SHA-256 摘要，不可逆推出原文。
/// 2. **精确匹配、不做模糊归一**——与 `IntentFeedbackMemory` 同一原则：
///    宁可少生效（差一个字仍会提示），不做模糊匹配把「需要的内容」误杀。
///    归一只做两端去空白（复制时最常见的无意义差异）。
/// 3. **有界 FIFO**——容量默认 30 条，超出丢最旧，避免无界增长。
public struct ClipboardRejectionMemory: Sendable {

    public static let defaultCapacity = 30

    private var keys: [String]
    private let capacity: Int

    public init(keys: [String] = [], capacity: Int = ClipboardRejectionMemory.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.keys = Array(keys.suffix(self.capacity))
    }

    public var all: [String] { keys }

    public func isRejected(_ key: String) -> Bool {
        keys.contains(key)
    }

    /// 记入拒绝名单（已存在则不重复、不改变顺序）。
    public mutating func markRejected(_ key: String) {
        guard !key.isEmpty, !keys.contains(key) else { return }
        keys.append(key)
        if keys.count > capacity {
            keys.removeFirst(keys.count - capacity)
        }
    }

    // MARK: 内容指纹

    /// 文本指纹：两端去空白后 SHA-256。大小写敏感——改了大小写就是另一条内容。
    public static func contentKey(forText text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return sha256Hex(Data(trimmed.utf8))
    }

    /// 图片指纹：原始字节 SHA-256。同一张截图重复拷贝字节相同 → 指纹相同。
    public static func contentKey(forImageData data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return sha256Hex(data)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
