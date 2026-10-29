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

    static func defaultTitle(for date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.isEnglish ? "MMM d HH:mm" : "M月d日 HH:mm"
        return L10n.isEnglish ? "Voice Memo \(f.string(from: date))" : "语音备忘 \(f.string(from: date))"
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

/// 时长格式化 mm:ss / h:mm:ss
func formatMemoDuration(_ t: TimeInterval) -> String {
    let total = max(0, Int(t.rounded(.down)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
