import Foundation
import SwiftData

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

/// 时长格式化 mm:ss / h:mm:ss
func formatMemoDuration(_ t: TimeInterval) -> String {
    let total = max(0, Int(t.rounded(.down)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
