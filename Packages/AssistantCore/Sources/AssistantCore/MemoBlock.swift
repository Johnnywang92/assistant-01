import Foundation

/// 语音备忘笔记的**块类型**。
///
/// 为什么用枚举而不是字符串：块的种类决定渲染方式（正文、小标题、列表、待办、
/// 引用、图片、语音片段），也决定它能否被转写自动生成。
/// 枚举让「拼错一个字符串就静默降级成正文」这类错误在编译期暴露。
public enum MemoBlockKind: String, Codable, CaseIterable, Sendable {
    /// 普通段落
    case paragraph
    /// 小标题（带强调色竖条）
    case heading
    /// 无序列表项
    case bullet
    /// 待办项（带勾选框）
    case todo
    /// 引用块
    case quote
    /// 图片（正文为空，引用图片文件）
    case image
    /// 语音片段（引用同一条录音的区间）
    case audio

    /// 是否是**由转写自动生成**的块。
    ///
    /// 图片与语音片段只能由用户手动插入，转写切分永远不该产出它们——
    /// 否则会出现「凭空多出一张图」这种无法解释的内容。
    public var isTranscriptionGenerated: Bool {
        switch self {
        case .paragraph, .heading, .bullet, .todo, .quote: return true
        case .image, .audio: return false
        }
    }

    /// 是否承载**文字内容**。
    ///
    /// 图片块与语音片段块的 `text` 为空，它们的内容在别的字段里。
    public var carriesText: Bool {
        switch self {
        case .paragraph, .heading, .bullet, .todo, .quote: return true
        case .image, .audio: return false
        }
    }
}

/// 块内文字的**强调样式**。
public enum MemoBlockStyle: String, Codable, CaseIterable, Sendable {
    case plain
    case bold
    case highlight
}

/// 一段时间区间（秒）。用于把文字段落 / 语音片段对齐到录音的某一处。
///
/// 用 `TimeInterval`（Double 秒）而不是帧号或采样点：录音文件的长度就是秒，
/// 展示与跳转都只需要秒，中间任何换算只会引入舍入误差。
public struct MemoTimeRange: Codable, Equatable, Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    /// 时长（秒）。区间不合法时返回 0，不返回负数。
    public var duration: TimeInterval {
        max(0, end - start)
    }

    /// 区间是否有效：起点非负、终点大于起点。
    public var isValid: Bool {
        start >= 0 && end > start
    }

    /// 是否落在录音时长范围内。
    ///
    /// 用于「读到了但数据不合理」的兜底：录音只有 10 秒，
    /// 却对齐出 00:30 的区间，那一定是错的，宁可不给时间戳。
    public func fits(inDuration duration: TimeInterval) -> Bool {
        isValid && duration > 0 && end <= duration + 0.5
    }
}

/// 笔记中的一个**块**。
///
/// 这是「转写不再是 String」的核心数据结构：一个备忘由若干块组成，
/// 块可以是文字（带类型与样式）、图片（带文件名）或语音片段（带区间）。
public struct MemoBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MemoBlockKind
    /// 文字内容。图片块与语音片段块为空字符串。
    public var text: String
    /// 对齐到录音的区间。无法对齐时为 nil（**不是 0**，0 会被当成「录音开头」）。
    public var timeRange: MemoTimeRange?
    public var style: MemoBlockStyle
    /// 图片文件名（相对 `VoiceMemos/Images/`）。仅 `.image` 有效。
    public var imageFileName: String?
    /// 图片说明文字。
    public var imageCaption: String?
    /// 待办是否已完成。仅 `.todo` 有效。
    public var isDone: Bool

    public init(
        id: UUID = UUID(),
        kind: MemoBlockKind = .paragraph,
        text: String = "",
        timeRange: MemoTimeRange? = nil,
        style: MemoBlockStyle = .plain,
        imageFileName: String? = nil,
        imageCaption: String? = nil,
        isDone: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timeRange = timeRange
        self.style = style
        self.imageFileName = imageFileName
        self.imageCaption = imageCaption
        self.isDone = isDone
    }

    /// 是否为空块（没有任何可见内容）。空块不应落库，也不该计入段落数。
    public var isEmpty: Bool {
        switch kind {
        case .paragraph, .heading, .bullet, .todo, .quote:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            return (imageFileName?.isEmpty ?? true)
        case .audio:
            return false
        }
    }

    /// 是否可跳回录音。
    ///
    /// 只有带**有效**区间的文字块才能跳转；图片与语音片段不是转写位置。
    public var isSeekable: Bool {
        kind.isTranscriptionGenerated && (timeRange?.isValid ?? false)
    }
}

/// 整个笔记的块集合。
public struct MemoDocument: Codable, Equatable, Sendable {
    public var title: String
    public var blocks: [MemoBlock]

    public init(title: String = "", blocks: [MemoBlock] = []) {
        self.title = title
        self.blocks = blocks
    }

    public var isEmpty: Bool {
        blocks.allSatisfy(\.isEmpty)
    }

    /// 拼接所有文字块的纯文本（用于全文检索与旧字段兼容）。
    public var plainText: String {
        blocks
            .filter(\.kind.carriesText)
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}

/// 块的**序列化**工具。
///
/// 为什么用 JSON 而不是 SwiftData 的 transformable / 关系模型：
/// 块结构会演进（新增 kind、改字段），JSON 的 `Codable` 对缺字段天然容错
/// （`decodeIfPresent`），旧数据读不出来时降级为「保留原文文本」而不是整条记录报废。
public enum MemoBlockCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 编码为 JSON 数据。失败返回 nil（调用方应保留原文本，而不是写入半截数据）。
    public static func encode(_ document: MemoDocument) -> Data? {
        try? encoder.encode(document)
    }

    /// 解码。**结构损坏时返回 nil**，绝不返回「空文档」——
    /// 空文档与「用户清空了笔记」在数据上无法区分，混淆会造成静默数据丢失。
    public static func decode(_ data: Data?) -> MemoDocument? {
        guard let data, !data.isEmpty else { return nil }
        return try? decoder.decode(MemoDocument.self, from: data)
    }

    /// 安全解码：损坏时用纯文本兜底重建一个只有一段的文档。
    ///
    /// 兜底的语义是「至少别把用户的内容弄丢」——
    /// 转写原文仍在 `transcription` 字段里，这里只是把它重新变成可编辑的段落。
    public static func decodeOrFallback(_ data: Data?, plainText: String) -> MemoDocument {
        if let document = decode(data) { return document }
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MemoDocument() }
        return MemoDocument(
            title: "",
            blocks: [MemoBlock(kind: .paragraph, text: trimmed)]
        )
    }
}
