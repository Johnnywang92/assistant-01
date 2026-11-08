import AssistantCore
import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// 语音备忘录分类标签
enum VoiceMemoTag: String, Codable, CaseIterable, Identifiable {
    case inspiration = "灵感"
    case work = "工作"
    case meeting = "会议"
    case life = "生活"
    case children = "小朋友"
    case pets = "宠物"
    case study = "学习"
    case other = "其他"

    var id: String { rawValue }

    var displayName: String { L10n.tr(rawValue) }

    var icon: String {
        switch self {
        case .inspiration: return "lightbulb.fill"
        case .work: return "briefcase.fill"
        case .meeting: return "person.3.fill"
        case .life: return "house.fill"
        case .children: return "figure.and.child.holdinghands"
        case .pets: return "pawprint.fill"
        case .study: return "book.fill"
        case .other: return "tag.fill"
        }
    }
}

/// 语音备忘录（原始音频持久化保存，与「语音对话」用完即弃的指令拾音完全独立）
@Model
final class VoiceMemo {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    /// 音频文件名（位于 Application Support/VoiceMemos/ 下）
    var audioFileName: String
    /// 离线转写全文
    var transcription: String?
    /// 结构化笔记块（JSON 编码，规则见 `AssistantCore.MemoBlock`）。
    ///
    /// 为什么不用 SwiftData 的 transformable / 关系模型：
    /// 块结构会演进（新增 kind、改字段），JSON 的 `Codable` 对缺字段天然容错，
    /// 旧数据读不出来时降级为「用转写全文重建」，而不是整条记录报废。
    ///
    /// **`transcription` 继续保留**并与块内容保持同步——
    /// 备份包、全局检索、以及「分享转写文字」都还在读它。
    var blocksData: Data?
    /// 要点摘要（规则提炼）
    var summary: String?
    var tagRaw: String
    var isBookmarked: Bool

    // MARK: V12 纯加法字段（全部可选，旧库为 NULL 时回落旧语义）

    /// 有序录音片段（JSON）。nil = V11 及更早的存量单段数据，
    /// 读取时用 `audioFileName` + `duration` 回落构造一个片段，行为与旧版完全一致。
    /// **刻意不建新的 @Model / @Relationship**：V1~V11 共用同一个运行时类型，
    /// 追加关系会让历史库迁移失败甚至白屏。
    var segmentsData: Data?
    /// 分享卡自定义标题；nil 表示跟随来源，不写回 `title`。
    var shareTitle: String?
    /// `ShareCardTitleSource.rawValue`；nil = 跟随备忘标题。
    var shareTitleSourceRaw: String?
    /// 用户手改过备忘标题。为 true 后自动标题不再覆盖。
    var titleIsUserEditedRaw: Bool?
    /// 纯文字备忘（没有音频文件）。
    var isTextOnlyRaw: Bool?

    init(
        title: String,
        duration: TimeInterval,
        audioFileName: String,
        tag: VoiceMemoTag = .other,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.transcription = nil
        self.blocksData = nil
        self.summary = nil
        self.tagRaw = tag.rawValue
        self.isBookmarked = false
        self.segmentsData = nil
        self.shareTitle = nil
        self.shareTitleSourceRaw = nil
        self.titleIsUserEditedRaw = nil
        self.isTextOnlyRaw = nil
    }

    var tag: VoiceMemoTag {
        get { VoiceMemoTag(rawValue: tagRaw) ?? .other }
        set { tagRaw = newValue.rawValue }
    }

    var audioURL: URL {
        VoiceMemoStorage.url(for: audioFileName)
    }

    var hasTranscription: Bool {
        !(transcription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 是否带音频。纯文字备忘用 `isTextOnly` 标记，`audioFileName` 保持空串，
    /// 避免把非可选列改成可选带来的迁移风险。
    var hasAudio: Bool { !isTextOnly && !audioFileName.isEmpty }

    var isTextOnly: Bool {
        get { isTextOnlyRaw ?? false }
        set { isTextOnlyRaw = newValue }
    }

    var titleIsUserEdited: Bool {
        get { titleIsUserEditedRaw ?? false }
        set { titleIsUserEditedRaw = newValue }
    }

    var shareTitleSource: ShareCardTitleSource {
        get { ShareCardTitleSource(rawValue: shareTitleSourceRaw ?? "") ?? .followMemo }
        set { shareTitleSourceRaw = newValue.rawValue }
    }

    /// 分享卡标题：只影响导出的那张图片，永远不写回备忘标题。
    var shareCardTitle: String {
        switch shareTitleSource {
        case .custom:
            let trimmed = shareTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? title : trimmed
        case .transcriptFirstSentence:
            return VoiceMemoTextAnalyzer.suggestedTitle(from: transcription ?? "") ?? title
        case .followMemo:
            return title
        }
    }

    /// 有序片段。存量为 nil 时回落成单段，纯文字备忘为空数组。
    var segments: [MemoSegment] {
        if let data = segmentsData,
           let decoded = MemoSegmentCodec.decode(data),
           !decoded.isEmpty {
            return decoded
        }
        guard hasAudio else { return [] }
        return [MemoSegment(fileName: audioFileName, duration: duration, createdAt: createdAt)]
    }

    /// 总时长 = 各段之和。存量单段回落到 `duration`。
    var totalDuration: TimeInterval {
        let sum = segments.reduce(0) { $0 + $1.duration }
        return sum > 0 ? sum : duration
    }

    /// 全部音频文件名，供删除与孤儿文件清理使用。
    var segmentFileNames: Set<String> { Set(segments.map(\.fileName)) }

    /// 唯一写入口：同步 JSON、`audioFileName`（指向第一段）与兼容字段 `duration`。
    ///
    /// `duration` 刻意保留为**第一段时长**：详情页播放器只加载第一段，
    /// 若写成总和，进度条终点会超出实际可播放范围。总时长一律读 `totalDuration`。
    func setSegments(_ newSegments: [MemoSegment]) {
        segmentsData = MemoSegmentCodec.encode(newSegments)
        audioFileName = newSegments.first?.fileName ?? ""
        isTextOnly = newSegments.isEmpty
        // 删到一段不剩时必须归零：`totalDuration` 在 segments 为空时会回落到 duration，
        // 留着旧值会让一条纯文字备忘凭空显示一段录音时长。
        duration = newSegments.first?.duration ?? 0
    }

    /// 结构化笔记文档。
    ///
    /// 读不出来时**不会返回空文档**（空文档与「用户清空了笔记」无法区分），
    /// 而是用转写全文重建一段正文——宁可粗糙，也不要把用户的内容弄丢。
    var document: MemoDocument {
        MemoBlockCodec.decodeOrFallback(blocksData, plainText: transcription ?? "")
    }

    /// 写入块文档，并同步 `transcription` 全文字段。
    ///
    /// 编码失败时**不写** `blocksData`（避免存下半截数据），
    /// 但仍会同步全文——至少文字内容不会丢。
    func apply(document: MemoDocument) {
        blocksData = MemoBlockCodec.encode(document)
        let plain = MemoBlockBuilder.plainText(from: document.blocks)
        transcription = plain.isEmpty ? (document.blocks.isEmpty ? nil : plain) : plain
    }

    /// 系统生成的默认标题。
    ///
    /// 纯文字备忘**不能**叫「语音备忘」：那是标签错误，不是措辞偏好。
    /// 用户从「写一条」进来、没填标题，列表里却显示「语音备忘 11月8日 20:15」，
    /// 会让人以为自己误录了音频，也搜不到任何音频可听。
    static func defaultTitle(for date: Date = .now, isTextOnly: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.isEnglish ? "MMM d HH:mm" : "M月d日 HH:mm"
        let stamp = f.string(from: date)
        if L10n.isEnglish {
            return isTextOnly ? "Text Note \(stamp)" : "Voice Memo \(stamp)"
        }
        return isTextOnly ? "文字备忘 \(stamp)" : "语音备忘 \(stamp)"
    }

    /// 标题是否仍是系统生成的默认值（自动标题可以覆盖它）。
    ///
    /// 中英文都要认：旧版本存下来的标题是中文，切换语言后也不该被当成用户手写的。
    var hasDefaultTitle: Bool {
        ["语音备忘 ", "文字备忘 ", "Voice Memo ", "Text Note "].contains { title.hasPrefix($0) }
    }

    /// 展示用标题。
    ///
    /// 旧版本给纯文字备忘也写「语音备忘 <时间>」当默认标题（`defaultTitle()` 当时只有一种文案）。
    /// 读的时候按类型把默认标题纠正回来；用户手写的标题一律原样返回。
    /// 真正的写库修正在 `VoiceMemoActions.normalizeLegacyTextMemoTitles` 里跑一次，
    /// 这里只是兜底，保证列表/详情不会在修正落库前又闪出旧文案。
    var displayTitle: String {
        guard isTextOnly, title.hasPrefix("语音备忘 ") else { return title }
        return VoiceMemo.defaultTitle(for: createdAt, isTextOnly: true)
    }
}

// MARK: - 音频文件沙盒存储

enum VoiceMemoStorage {
    static var directory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL.documentsDirectory
        let dir = base.appendingPathComponent("VoiceMemos", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func newFileName() -> String {
        "\(UUID().uuidString).m4a"
    }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    static func deleteAll() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    static func pruneUnreferenced(keeping validFileNames: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !validFileNames.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    static func loadData(_ fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    /// 写入音频数据（用于迁移还原），返回新文件名
    static func save(data: Data, preferredName: String? = nil) -> String? {
        let name = (preferredName?.isEmpty == false && !exists(preferredName!)) ? preferredName! : newFileName()
        do {
            try data.write(to: url(for: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            return nil
        }
    }

    /// 本地语音备忘占用空间（字节）
    static func totalSize() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

// MARK: - 笔记图片存储

/// 笔记内嵌图片的沙盒存储。
///
/// 为什么图片单独存文件、block 里只存文件名：
/// 图片是二进制，直接塞进 SwiftData 会把数据库撑大、备份包臃肿，
/// 且大字段在 SwiftData 上的读取性能很差。项目里 `TodoItem.attachmentImageData`
/// 是直接存 Data 的做法，语音备忘这边**刻意不照抄**——
/// 笔记图片可能有多张，量级不同。
enum VoiceMemoImageStorage {
    /// 图片目录（位于 `VoiceMemos/Images/`）。
    static var directory: URL {
        let base = VoiceMemoStorage.directory.appendingPathComponent("Images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func newFileName() -> String {
        "\(UUID().uuidString).jpg"
    }

    static func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// 写入图片数据并返回文件名。
    ///
    /// 图片会先按最长边压缩再落盘：手机随手拍的照片动辄几 MB，
    /// 直接存会让备份包体积失控。压缩失败时**保留原数据**写入，
    /// 绝不因为压缩失败就丢掉用户的图片。
    static func save(data: Data, preferredName: String? = nil) -> String? {
        let name = (preferredName?.isEmpty == false && !exists(preferredName!)) ? preferredName! : newFileName()
        let target = url(for: name)
        do {
            if let compressed = compress(data), !compressed.isEmpty {
                try compressed.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return name
        } catch {
            return nil
        }
    }

    /// 读取图片数据。文件不存在时返回 nil（调用方需处理「图片丢了」的情况）。
    static func loadData(_ fileName: String) -> Data? {
        try? Data(contentsOf: url(for: fileName))
    }

    /// 按最长边压缩（上限 1600pt，JPEG 质量 0.8）。
    private static func compress(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return data }
        let scale = maxSide / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.8)
        #else
        return nil
        #endif
    }

    /// 清理没有被任何块引用的图片文件。
    ///
    /// - Parameter referencedFileNames: 全部备忘中被块引用的图片文件名集合。
    static func pruneUnreferenced(referencing referencedFileNames: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !referencedFileNames.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    /// 全部图片占用的字节数。
    static func totalSize() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

// MARK: - 录音片段（V12）

/// 一条语音备忘里的一个有序录音片段。
///
/// 每个片段是**独立的音频文件**：中断（来电 / 切后台 / 误关录音页）只收尾当前段，
/// 已有片段不受影响；续录时新音频追加为下一段，不会新建一条备忘。
struct MemoSegment: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var fileName: String
    var duration: TimeInterval
    var createdAt: Date
    /// 中断原因（"interruption" / "background" / "manual"），仅用于展示，不参与逻辑。
    var interruptionReasonRaw: String?
    /// 这一段转写生成的笔记块 ID。删段时据此同步移除对应文字。
    ///
    /// 放在 `segmentsData` 的 JSON 里而不是新开一列：片段结构以后还会长，
    /// V12 之后扩展字段不该再升 Schema（与 `TodoItem.scheduleRaw` 同一个道理）。
    /// nil 有两层含义——存量数据、或整篇重建后块 ID 已失效；这两种情况下
    /// 删段只删音频、不碰文字，宁可少删也不要误删别段的内容。
    var transcriptBlockIDs: [UUID]?

    init(
        id: UUID = UUID(),
        fileName: String,
        duration: TimeInterval,
        createdAt: Date = .now,
        interruptionReasonRaw: String? = nil,
        transcriptBlockIDs: [UUID]? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.duration = duration
        self.createdAt = createdAt
        self.interruptionReasonRaw = interruptionReasonRaw
        self.transcriptBlockIDs = transcriptBlockIDs
    }
}

enum MemoSegmentCodec {
    static func encode(_ segments: [MemoSegment]) -> Data? {
        try? JSONEncoder().encode(segments)
    }

    /// 解码失败返回 nil（调用方回落到旧的单段语义），绝不返回空数组——
    /// 空数组与「用户真的删光了片段」无法区分，会造成内容静默消失。
    static func decode(_ data: Data) -> [MemoSegment]? {
        guard let decoded = try? JSONDecoder().decode([MemoSegment].self, from: data),
              !decoded.isEmpty else { return nil }
        return decoded
    }
}

/// 分享卡标题的来源。与备忘标题解耦，只影响导出的图片。
enum ShareCardTitleSource: String, CaseIterable, Identifiable {
    case followMemo = "followMemo"
    case transcriptFirstSentence = "transcriptFirstSentence"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .followMemo: return L10n.choose("跟随备忘标题", "Follow memo title")
        case .transcriptFirstSentence: return L10n.choose("用转写首句", "Use first sentence")
        case .custom: return L10n.choose("自定义", "Custom")
        }
    }
}

/// 时长格式化 mm:ss / h:mm:ss
func formatMemoDuration(_ t: TimeInterval) -> String {
    let total = max(0, Int(t.rounded(.down)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
