import Combine
import Foundation
import SwiftUI

/// 下载源选择
public enum LLMDownloadSource: String, CaseIterable, Identifiable {
    case modelScope = "ModelScope (魔搭社区 · 阿里国内极速)"
    case huggingFace = "Hugging Face (官方海外源)"

    public var id: String { rawValue }

    public var downloadURL: URL {
        switch self {
        case .modelScope:
            return URL(string: "https://www.modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
        case .huggingFace:
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
        }
    }
}

/// Qwen2.5-1.5B-Instruct 本地大模型文件管理与极速下载器
@MainActor
public final class LLMModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = LLMModelManager()

    public static let modelFileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
    public static let expectedSizeApproxBytes: Int64 = 986_000_000 // 约 986 MB

    // 模型存储目录
    public var modelsDirectory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public var localModelURL: URL {
        modelsDirectory.appendingPathComponent(Self.modelFileName)
    }

    // 状态发布
    @Published public var isModelDownloaded: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadedBytes: Int64 = 0
    @Published public var totalBytes: Int64 = expectedSizeApproxBytes
    @Published public var downloadSpeedMBps: Double = 0.0
    @Published public var errorMessage: String?
    @Published public var selectedSource: LLMDownloadSource = .modelScope

    private var downloadTask: URLSessionDownloadTask?
    private var lastSpeedCheckTime: Date = .now
    private var lastSpeedBytes: Int64 = 0
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        checkModelStatus()
    }

    /// 检查本地模型是否存在且完整
    public func checkModelStatus() {
        let path = localModelURL.path
        if FileManager.default.fileExists(atPath: path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64, size > 100_000_000 { // 检查有效大小大于 100MB
                isModelDownloaded = true
                downloadedBytes = size
                totalBytes = size
                return
            }
        }
        isModelDownloaded = false
    }

    /// 获取模型文件大小的可读文本
    public var formattedModelSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        if isModelDownloaded {
            return formatter.string(fromByteCount: downloadedBytes)
        }
        return "约 986 MB"
    }

    /// 开启模型下载
    public func startDownload(source: LLMDownloadSource? = nil) {
        guard !isDownloading else { return }
        let src = source ?? selectedSource
        self.selectedSource = src
        self.errorMessage = nil
        self.downloadProgress = 0.0
        self.downloadedBytes = 0
        self.downloadSpeedMBps = 0.0
        self.lastSpeedCheckTime = .now
        self.lastSpeedBytes = 0

        // 确保目标目录存在
        _ = modelsDirectory

        downloadTask = urlSession.downloadTask(with: src.downloadURL)
        downloadTask?.resume()
        isDownloading = true
        Haptic.light()
    }

    /// 取消下载
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0.0
        downloadSpeedMBps = 0.0
        Haptic.warning()
    }

    /// 删除已下载的本地模型释放空间
    public func deleteModel() {
        cancelDownload()
        try? FileManager.default.removeItem(at: localModelURL)
        checkModelStatus()
        Haptic.warning()
    }

    /// 从「文件」App 导入外部已有模型文件
    public func importModel(from sourceURL: URL) throws {
        guard sourceURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "LLMModelManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "无法访问所选文件权限"])
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        _ = modelsDirectory
        if FileManager.default.fileExists(atPath: localModelURL.path) {
            try FileManager.default.removeItem(at: localModelURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: localModelURL)
        self.errorMessage = nil
        checkModelStatus()
        Haptic.success()
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.expectedSizeApproxBytes
            self.totalBytes = expected
            self.downloadProgress = Double(totalBytesWritten) / Double(expected)

            // 计算即时下载速率 (MB/s)
            let now = Date.now
            let timeInterval = now.timeIntervalSince(self.lastSpeedCheckTime)
            if timeInterval >= 0.5 {
                let bytesDiff = totalBytesWritten - self.lastSpeedBytes
                self.downloadSpeedMBps = (Double(bytesDiff) / 1024.0 / 1024.0) / timeInterval
                self.lastSpeedCheckTime = now
                self.lastSpeedBytes = totalBytesWritten
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 重要：根据苹果 URLSession 规范，此委托方法返回后系统会立即清除临时文件（CFNetworkDownload_xxx.tmp）！
        // 必须在此方法同步返回前，将文件从临时位置移动到持久化沙盒目录中。
        let targetDir = URL.documentsDirectory.appendingPathComponent("Models", isDirectory: true)
        let targetURL = targetDir.appendingPathComponent(Self.modelFileName)

        var moveError: Error?
        do {
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dirURL = targetDir
            try? dirURL.setResourceValues(values)

            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }

            // 优先使用快速移动 moveItem；若跨存储分区受限则降级 copyItem
            do {
                try FileManager.default.moveItem(at: location, to: targetURL)
            } catch {
                try FileManager.default.copyItem(at: location, to: targetURL)
                try? FileManager.default.removeItem(at: location)
            }
        } catch {
            moveError = error
        }

        Task { @MainActor in
            if let error = moveError {
                self.errorMessage = "保存模型文件失败：\(error.localizedDescription)"
                self.isDownloading = false
                Haptic.error()
            } else {
                self.errorMessage = nil
                self.isDownloading = false
                self.checkModelStatus()
                Haptic.success()
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            if let error = error as NSError?, error.code != NSURLErrorCancelled {
                self.errorMessage = "下载失败：\(error.localizedDescription)（建议切换至 ModelScope 镜像重试）"
                self.isDownloading = false
                Haptic.error()
            }
        }
    }
}
