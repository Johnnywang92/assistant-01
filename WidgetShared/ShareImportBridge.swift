import Foundation

/// 分享扩展 → 主 App 的 App Group 交接层。
///
/// 设计约束（见 `Persistence.swift` 与 `todo.md` 实施记录）：**扩展进程绝不触碰 SwiftData**，
/// 以免多进程写库冲突。扩展只把分享到的图片/文本/链接落入 App Group 的「中转区」，
/// 主 App 回前台（或经 URL 唤起）时排空、解析、落库——读取即删除，保证幂等、不重复入库。
///
/// 本文件位于 `WidgetShared/`，同时编译进主 App 与分享扩展两个 target。
public enum ShareImportBridge {
    /// 复用与小组件/实时活动同一 App Group
    public static let appGroupID = WidgetBridgeConstants.appGroupID

    /// 中转目录名：<App Group 容器>/ShareInbox
    private static let inboxDirName = "ShareInbox"

    public enum Kind: String, Codable {
        case image
        case text
        case url
    }

    /// 单条分享载荷。图片字节单独存文件（体积大，不进 JSON），此处仅记录文件名。
    public struct Payload: Codable {
        public let id: String
        public let kind: Kind
        public let text: String?
        public let imageFile: String?
        public let source: String
        public let createdAt: Date

        public init(id: String, kind: Kind, text: String?, imageFile: String?, source: String, createdAt: Date) {
            self.id = id
            self.kind = kind
            self.text = text
            self.imageFile = imageFile
            self.source = source
            self.createdAt = createdAt
        }
    }

    // MARK: - 目录

    private static var inboxDir: URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return base.appendingPathComponent(inboxDirName, isDirectory: true)
    }

    @discardableResult
    private static func ensureInboxDir() -> URL? {
        guard let dir = inboxDir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 写入端（扩展进程）

    /// 写入一条文本/链接载荷。
    @discardableResult
    public static func writeText(_ text: String, kind: Kind, source: String) -> Bool {
        guard let dir = ensureInboxDir() else { return false }
        let payload = Payload(id: UUID().uuidString, kind: kind, text: text, imageFile: nil, source: source, createdAt: .now)
        return write(payload, to: dir)
    }

    /// 写入一条图片载荷：图片字节另存为独立文件，JSON 仅记录文件名。
    @discardableResult
    public static func writeImage(_ data: Data, source: String) -> Bool {
        guard let dir = ensureInboxDir() else { return false }
        let imageFile = "\(UUID().uuidString).img"
        let imageURL = dir.appendingPathComponent(imageFile)
        do {
            try data.write(to: imageURL)
        } catch {
            return false
        }
        let payload = Payload(id: UUID().uuidString, kind: .image, text: nil, imageFile: imageFile, source: source, createdAt: .now)
        return write(payload, to: dir)
    }

    private static func write(_ payload: Payload, to dir: URL) -> Bool {
        let jsonURL = dir.appendingPathComponent("\(payload.id).json")
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            try data.write(to: jsonURL)
            return true
        } catch {
            // 写 JSON 失败时清掉孤立的图片文件，避免残留
            if let imageFile = payload.imageFile {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(imageFile))
            }
            return false
        }
    }

    // MARK: - 读取端（主 App 进程）

    /// 读取中转区全部待处理载荷（不立即删除文件，供逐条处理成功后再调用 `remove(_:)` 确认移除）。
    /// 损坏的 JSON 文件会被自动清理。返回按 createdAt 升序排列。
    public static func peekAll() -> [(payload: Payload, imageData: Data?)] {
        guard let dir = inboxDir,
              FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }

        var results: [(payload: Payload, imageData: Data?)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                try? fm.removeItem(at: file)
                continue
            }
            var imageData: Data?
            if let imageFile = payload.imageFile {
                let imageURL = dir.appendingPathComponent(imageFile)
                imageData = try? Data(contentsOf: imageURL)
            }
            results.append((payload, imageData))
        }
        return results.sorted { $0.payload.createdAt < $1.payload.createdAt }
    }

    /// 确认单条分享载荷已处理完毕，删除对应的 JSON 与图片文件。
    public static func remove(_ payload: Payload) {
        guard let dir = inboxDir else { return }
        let fm = FileManager.default
        if let imageFile = payload.imageFile {
            try? fm.removeItem(at: dir.appendingPathComponent(imageFile))
        }
        try? fm.removeItem(at: dir.appendingPathComponent("\(payload.id).json"))
    }

    /// 排空中转区：读出全部载荷并删除文件（读取即清空）。图片载荷会顺带加载字节。
    /// 返回按 createdAt 升序排列，保证处理顺序稳定。
    public static func drainAll() -> [(payload: Payload, imageData: Data?)] {
        let items = peekAll()
        for (payload, _) in items {
            remove(payload)
        }
        return items
    }

    /// 测试 / 维护用：整目录清空。
    public static func clear() {
        guard let dir = inboxDir else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
