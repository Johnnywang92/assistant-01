import Foundation

/// NSRegularExpression 的轻量封装，带编译缓存。
public enum Regex {
    private static let cache = NSCache<NSString, NSRegularExpression>()

    public static func compile(_ pattern: String) -> NSRegularExpression? {
        if let cached = cache.object(forKey: pattern as NSString) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            assertionFailure("Invalid regex: \(pattern)")
            return nil
        }
        cache.setObject(re, forKey: pattern as NSString)
        return re
    }

    public static func matches(_ pattern: String, in text: String) -> Bool {
        guard let re = compile(pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 第一个匹配的第 1 个捕获组。
    public static func firstGroup(_ pattern: String, in text: String) -> String? {
        firstGroups(pattern, in: text)?.first ?? nil
    }

    /// 第一个匹配的所有捕获组。
    public static func firstGroups(_ pattern: String, in text: String) -> [String?]? {
        guard let re = compile(pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(of: m, in: text)
    }

    /// 所有匹配的捕获组。
    public static func allGroups(_ pattern: String, in text: String) -> [[String?]] {
        guard let re = compile(pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { groups(of: $0, in: text) }
    }

    public static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = compile(pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func groups(of m: NSTextCheckingResult, in text: String) -> [String?] {
        guard m.numberOfRanges > 1 else { return [] }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: text) else { return nil }
            return String(text[range])
        }
    }
}
