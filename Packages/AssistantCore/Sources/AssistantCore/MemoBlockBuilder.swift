import Foundation

/// 把**整段转写文本**切分成结构化块。
///
/// 为什么要专门切分：整段转写是一大坨文字，用户真正的抱怨正是
/// 「重点和闲聊混在一起，二次编辑成本很高」。切分规则决定了第一屏长什么样，
/// 是整个功能的地基，因此下沉 Core 并配单元测试。
///
/// 三条硬约束（改这个文件前先读测试）：
///
/// 1. **没有真实偏移量就绝不给时间戳。**
///    系统 `SFSpeechRecognizer` 整段转写**不返回逐句时间戳**，
///    所以在没有外部对齐数据时，时间戳只能是 `nil`，
///    绝不能按字数比例**估算**——估出来的时间戳会让用户以为
///    「点这一句能听到对应的原声」，点下去却对不上，那是骗人。
///    本切分器因此默认产出**无时间戳**的块；
///    拿到真实分段结果时请走 `MemoBlockBuilder.build(fromSegments:)`。
///
/// 2. **切分点用中文标点 + 长度双约束。**
///    只按标点切会被「。」结尾的短句切得过碎；
///    只按长度切会把从句拦腰截断。两者结合才接近人工整理的段落感。
///
/// 3. **标题与列表是识别出来的，不是猜出来的。**
///    只有原文里**本来就有**编号列表（「1.」「2.」「-」）才切成列表块；
///    「三个改进方向」这种小标题靠语义识别，但只在短句且以冒号结尾时才成立。
public enum MemoBlockBuilder {

    // MARK: - 切分参数

    /// 段落最小长度：短于它的句子会与前一句合并。
    private static let minParagraphLength = 12
    /// 段落最大长度：超过它会在逗号处再切一刀，避免一整屏都是一坨。
    private static let maxParagraphLength = 120
    /// 识别为小标题的最大长度（小标题就该短）。
    private static let maxHeadingLength = 24
    /// 列表项编号前缀。
    private static let listPrefixes = ["- ", "• ", "* ", "· "]
    /// 列表项数字编号前缀（1. 2. 3. …，最多到 20）。
    private static let numberedPrefixPattern = try? NSRegularExpression(pattern: "^(\\d{1,2})[.、]\\s*")
    /// 句末标点（切分点）。
    private static let sentenceTerminators: Set<Character> = [
        "。", "！", "？", "；", "!", "?", ";", "\n", "…"
    ]
    /// 句中可切分标点（超长段落在此处再切）。
    private static let clauseSeparators: Set<Character> = [",", "，", "、"]

    // MARK: - 入口

    /// 从**纯文本**构建块列表（无时间戳）。
    ///
    /// - Parameters:
    ///   - text: 整段转写文本。
    ///   - title: 文档标题（通常取备忘标题）。
    public static func build(from text: String, title: String = "") -> MemoDocument {
        let segments = splitIntoSegments(text)
        let blocks = segments.compactMap { segment -> MemoBlock? in
            let block = block(fromSegment: segment)
            return block.isEmpty ? nil : block
        }
        return MemoDocument(title: title, blocks: blocks)
    }

    /// 从**带真实时间戳的分段结果**构建块列表。
    ///
    /// 这是拿到真实对齐数据时的正确入口：每段自带起止时间，
    /// 因此产出的块可以跳回录音。
    ///
    /// - Parameter segments: 段落文本与它对应的录音区间。
    public static func build(fromSegments segments: [MemoSegment]) -> MemoDocument {
        let blocks = segments.compactMap { segment -> MemoBlock? in
            let block = block(fromSegment: segment.text, timeRange: segment.timeRange)
            return block.isEmpty ? nil : block
        }
        return MemoDocument(title: "", blocks: blocks)
    }

    /// 一段文本及其真实录音区间。
    public struct MemoSegment: Equatable, Sendable {
        public var text: String
        public var timeRange: MemoTimeRange?

        public init(text: String, timeRange: MemoTimeRange? = nil) {
            self.text = text
            self.timeRange = timeRange
        }
    }

    // MARK: - 切分

    /// 把整段文本切成候选段落。
    public static func splitIntoSegments(_ text: String) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        // 先按硬标点与换行切
        var pieces: [String] = []
        var current = ""
        for ch in normalized {
            current.append(ch)
            if sentenceTerminators.contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }

        // 再合并过短的片段
        var merged: [String] = []
        for piece in pieces {
            if let last = merged.last,
               last.count < minParagraphLength,
               listItem(in: piece) == nil,
               !isHeadingCandidate(piece) {
                merged[merged.count - 1] = last + piece
            } else {
                merged.append(piece)
            }
        }

        // 最后按长度上限在逗号处再切
        var result: [String] = []
        for item in merged {
            result.append(contentsOf: splitLongSegment(item))
        }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 超长段落：在句中逗号处切开，避免一整屏一坨。
    private static func splitLongSegment(_ segment: String) -> [String] {
        guard segment.count > maxParagraphLength else { return [segment] }
        var result: [String] = []
        var current = ""
        for ch in segment {
            current.append(ch)
            if clauseSeparators.contains(ch), current.count >= minParagraphLength {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        // 切完仍过长（例如整段没有逗号）就原样保留，不硬切。
        return result
    }

    // MARK: - 块类型判定

    /// 由一段文本构造块。
    public static func block(fromSegment text: String, timeRange: MemoTimeRange? = nil) -> MemoBlock {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let (kind, body) = listItem(in: trimmed) {
            return MemoBlock(kind: kind, text: body, timeRange: validRange(timeRange))
        }
        if isHeadingCandidate(trimmed) {
            return MemoBlock(kind: .heading, text: trimmed, timeRange: validRange(timeRange))
        }
        return MemoBlock(kind: .paragraph, text: trimmed, timeRange: validRange(timeRange))
    }

    /// 判定列表项。返回 (类型, 去掉前缀的正文)。
    ///
    /// 数字编号的项在转写里通常是要点，于是归为 `.todo`；
    /// 符号前缀的归为 `.bullet`。
    private static func listItem(in text: String) -> (MemoBlockKind, String)? {
        for prefix in listPrefixes where text.hasPrefix(prefix) {
            let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (.bullet, body)
        }
        if let regex = numberedPrefixPattern,
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let number = Int(text[range]) {
            // 1~20 的编号视为待办序列，超过这个范围更可能是叙述里的数字。
            if (1...20).contains(number) {
                let body = String(text.dropFirst(match.range.location + match.range.length))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (.todo, body)
            }
        }
        return nil
    }

    /// 判定小标题。
    ///
    /// 条件较严：短句 + 以冒号结尾 + 不是列表项。
    /// 宁可漏判（保持为正文，用户可一键改标题）也不要误判——
    /// 误判会让正文突然变成红条标题，比漏判更突兀。
    private static func isHeadingCandidate(_ text: String) -> Bool {
        guard text.count <= maxHeadingLength, text.count >= 3 else { return false }
        guard listItem(in: text) == nil else { return false }
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.hasSuffix("：") || stripped.hasSuffix(":") else { return false }
        // 冒号前的内容不能太长，否则更像一句普通的「说明：……」
        let head = stripped.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return !head.isEmpty && head.count <= maxHeadingLength - 1
    }

    /// 校验时间区间有效性，无效则丢弃（返回 nil）。
    ///
    /// **绝不返回 `MemoTimeRange(start: 0, end: 0)`**——
    /// 那会被当成「录音开头的一段真实内容」，是臆造。
    private static func validRange(_ range: MemoTimeRange?) -> MemoTimeRange? {
        guard let range, range.isValid else { return nil }
        return range
    }

    // MARK: - 全文同步

    /// 把块的纯文本回写成一段全文（用于同步 `transcription` 兼容字段）。
    public static func plainText(from blocks: [MemoBlock]) -> String {
        blocks
            .filter(\.kind.carriesText)
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}
