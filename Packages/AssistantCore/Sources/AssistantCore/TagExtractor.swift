import Foundation

/// 任务与账目标签提取器（纯逻辑，下沉 AssistantCore）
/// 支持自然语言中提取 `#客户A`、`#原型交付`、`#v1.0` 等标签，
/// 提取后返回去除标签符号后的干净正文与规范化标签数组。
public enum TagExtractor {

    // 匹配 #xxx，支持中英文、数字、下划线、中划线，遇空格、换行、中文标点或下一个 # 截止
    private static let tagRegex: NSRegularExpression = {
        let pattern = #"#([^\s#，,。！？!?；;：:\(\)\[\]（）]+)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// 从文本中提取所有以 # 开头的标签，并返回剥离标签后的干净文本与去重标签数组
    /// - Parameter text: 原始输入字符串
    /// - Returns:
    ///   - cleanText: 剔除标签声明后的纯净文本（两端去空白）
    ///   - tags: 提取出的标签名数组（已去除 `#` 前缀且已去重，保持输入先后顺序）
    public static func extractTags(from text: String) -> (cleanText: String, tags: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", []) }

        let nsString = trimmed as NSString
        let matches = tagRegex.matches(in: trimmed, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return (trimmed, []) }

        var tags: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else { continue }
            let tag = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty && !tags.contains(tag) {
                tags.append(tag)
            }
        }

        // 将原句中的 #标签 替换为空白，并整理多余连续空格
        let stripped = tagRegex.stringByReplacingMatches(
            in: trimmed,
            range: NSRange(location: 0, length: nsString.length),
            withTemplate: " "
        )
        let clean = stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (clean.isEmpty ? trimmed : clean, tags)
    }

    /// 格式化标签用于展示（自动补齐 # 前缀）
    public static func formatDisplayTag(_ tag: String) -> String {
        tag.hasPrefix("#") ? tag : "#\(tag)"
    }
}

