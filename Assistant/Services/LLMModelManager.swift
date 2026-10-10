import Combine
import CryptoKit
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

    nonisolated public static let modelFileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
    nonisolated public static let expectedSizeApproxBytes: Int64 = 986_000_000 // 约 986 MB

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

    /// 断点续传数据持久化路径
    public var resumeDataURL: URL {
        modelsDirectory.appendingPathComponent("qwen_download.resume_data")
    }

    // 状态发布
    @Published public var isModelDownloaded: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var hasResumeData: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadedBytes: Int64 = 0
    @Published public var totalBytes: Int64 = expectedSizeApproxBytes
    @Published public var downloadSpeedMBps: Double = 0.0
    @Published public var errorMessage: String?
    @Published public var selectedSource: LLMDownloadSource = .modelScope

    private var downloadTask: URLSessionDownloadTask?
    private var validationGeneration = 0
    private let validatedDigestKey = "llm_model_validated_sha256_v1"
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
        isModelDownloaded = false
        validationGeneration += 1
        let generation = validationGeneration
        let url = localModelURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: validatedDigestKey)
            hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)
            return
        }
        let expectedDigest = UserDefaults.standard.string(forKey: validatedDigestKey)
        Task.detached(priority: .utility) {
            let result = Result { try Self.validateModel(at: url) }
            await MainActor.run {
                guard generation == self.validationGeneration else { return }
                switch result {
                case .success(let validated):
                    if let expectedDigest, expectedDigest != validated.digest {
                        self.errorMessage = "模型文件校验值已变化，请重新导入。"
                        return
                    }
                    UserDefaults.standard.set(validated.digest, forKey: self.validatedDigestKey)
                    self.downloadedBytes = validated.size
                    self.totalBytes = validated.size
                    self.isModelDownloaded = true
                    self.clearResumeData()
                case .failure(let error):
                    self.errorMessage = "模型文件无效：\(error.localizedDescription)"
                }
            }
        }
        hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)
    }

    nonisolated private static func validateModel(at url: URL) throws -> (size: Int64, digest: String) {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 850_000_000 else { throw ModelValidationError.invalidSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8, String(data: header.prefix(4), encoding: .ascii) == "GGUF" else {
            throw ModelValidationError.invalidHeader
        }
        let version = header.suffix(4).enumerated().reduce(UInt32(0)) { value, byte in
            value | (UInt32(byte.element) << (UInt32(byte.offset) * 8))
        }
        guard version == 2 || version == 3 else { throw ModelValidationError.invalidHeader }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private enum ModelValidationError: LocalizedError {
        case invalidSize, invalidHeader
        var errorDescription: String? {
            switch self {
            case .invalidSize: "文件体积与预期模型不符。"
            case .invalidHeader: "文件不是支持的 GGUF 格式。"
            }
        }
    }

    /// 保存断点续传数据
    public func saveResumeData(_ data: Data) {
        do {
            try data.write(to: resumeDataURL, options: .atomic)
            hasResumeData = true
        } catch {
            print("⚠️ 保存断点续传数据失败: \(error)")
        }
    }

    /// 加载断点续传数据
    public func loadResumeData() -> Data? {
        guard FileManager.default.fileExists(atPath: resumeDataURL.path) else { return nil }
        return try? Data(contentsOf: resumeDataURL)
    }

    /// 清空断点续传数据
    public func clearResumeData() {
        try? FileManager.default.removeItem(at: resumeDataURL)
        hasResumeData = false
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

    /// 开启或继续模型下载（支持断点续传）
    public func startDownload(source: LLMDownloadSource? = nil, forceRestart: Bool = false) {
        guard !isDownloading else { return }
        let src = source ?? selectedSource
        self.selectedSource = src
        self.errorMessage = nil
        self.downloadSpeedMBps = 0.0
        self.lastSpeedCheckTime = .now
        self.lastSpeedBytes = 0

        // 确保目标目录存在
        _ = modelsDirectory

        if forceRestart {
            clearResumeData()
            self.downloadProgress = 0.0
            self.downloadedBytes = 0
        }

        // 优先检查是否有断点续传数据
        if !forceRestart, let resumeData = loadResumeData() {
            let task = urlSession.downloadTask(withResumeData: resumeData)
            downloadTask = task
            task.resume()
            isDownloading = true
            Haptic.medium()
        } else {
            clearResumeData()
            self.downloadProgress = 0.0
            self.downloadedBytes = 0
            let task = urlSession.downloadTask(with: src.downloadURL)
            downloadTask = task
            task.resume()
            isDownloading = true
            Haptic.light()
        }
    }

    /// 暂停下载并保留断点进度数据
    public func pauseDownload() {
        guard isDownloading, let task = downloadTask else { return }
        task.cancel { [weak self] resumeData in
            Task { @MainActor in
                if let data = resumeData {
                    self?.saveResumeData(data)
                }
                self?.downloadTask = nil
                self?.isDownloading = false
                self?.downloadSpeedMBps = 0.0
                Haptic.light()
            }
        }
    }

    /// 取消下载并保留当前已下载的断点进度（用于用户临时取消或退出）
    public func cancelDownload() {
        pauseDownload()
    }

    /// 彻底放弃进度并重新归零
    public func discardProgressAndReset() {
        downloadTask?.cancel()
        downloadTask = nil
        clearResumeData()
        isDownloading = false
        downloadProgress = 0.0
        downloadedBytes = 0
        downloadSpeedMBps = 0.0
        errorMessage = nil
        Haptic.warning()
    }

    /// 删除已下载的本地模型释放空间
    public func deleteModel() {
        downloadTask?.cancel()
        downloadTask = nil
        clearResumeData()
        try? FileManager.default.removeItem(at: localModelURL)
        UserDefaults.standard.removeObject(forKey: validatedDigestKey)
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
        let candidate = modelsDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: candidate) }
        try FileManager.default.copyItem(at: sourceURL, to: candidate)
        let validated = try Self.validateModel(at: candidate)
        let oldModel = modelsDirectory.appendingPathComponent(UUID().uuidString + ".previous")
        let hadOldModel = FileManager.default.fileExists(atPath: localModelURL.path)
        if hadOldModel { try FileManager.default.moveItem(at: localModelURL, to: oldModel) }
        do {
            try FileManager.default.moveItem(at: candidate, to: localModelURL)
            UserDefaults.standard.set(validated.digest, forKey: validatedDigestKey)
            if hadOldModel { try? FileManager.default.removeItem(at: oldModel) }
        } catch {
            if hadOldModel { try? FileManager.default.moveItem(at: oldModel, to: localModelURL) }
            throw error
        }
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
        let candidateURL = targetDir.appendingPathComponent(UUID().uuidString + ".pending")

        var moveError: Error?
        do {
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dirURL = targetDir
            try? dirURL.setResourceValues(values)

            // 优先使用快速移动 moveItem；若跨存储分区受限则降级 copyItem
            do {
                try FileManager.default.moveItem(at: location, to: candidateURL)
            } catch {
                try FileManager.default.copyItem(at: location, to: candidateURL)
                try? FileManager.default.removeItem(at: location)
            }
        } catch {
            moveError = error
        }

        if let moveError {
            Task { @MainActor in
                self.errorMessage = "保存模型文件失败：\(moveError.localizedDescription)"
                self.isDownloading = false
                Haptic.error()
            }
            return
        }
        Task.detached(priority: .utility) {
            let result = Result { try Self.validateModel(at: candidateURL) }
            await MainActor.run {
                self.completeDownloadedModel(candidateURL: candidateURL, validation: result)
            }
        }
    }

    private func completeDownloadedModel(candidateURL: URL, validation: Result<(size: Int64, digest: String), Error>) {
        defer { try? FileManager.default.removeItem(at: candidateURL) }
        isDownloading = false
        do {
            let validated = try validation.get()
            let oldModel = modelsDirectory.appendingPathComponent(UUID().uuidString + ".previous")
            let hadOldModel = FileManager.default.fileExists(atPath: localModelURL.path)
            if hadOldModel { try FileManager.default.moveItem(at: localModelURL, to: oldModel) }
            do {
                try FileManager.default.moveItem(at: candidateURL, to: localModelURL)
            } catch {
                if hadOldModel { try? FileManager.default.moveItem(at: oldModel, to: localModelURL) }
                throw error
            }
            if hadOldModel { try? FileManager.default.removeItem(at: oldModel) }
            UserDefaults.standard.set(validated.digest, forKey: validatedDigestKey)
            clearResumeData()
            errorMessage = nil
            checkModelStatus()
            Haptic.success()
        } catch {
            errorMessage = "模型校验失败：\(error.localizedDescription)"
            Haptic.error()
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            if let error = error as NSError? {
                // 自动保存网络中断或异常时的断点续传数据
                if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    self.saveResumeData(resumeData)
                }

                if error.code != NSURLErrorCancelled {
                    if self.hasResumeData {
                        self.errorMessage = "下载中断：\(error.localizedDescription)（已保留当前进度，点击可直接断点续传）"
                    } else {
                        self.errorMessage = "下载失败：\(error.localizedDescription)（建议切换至 ModelScope 镜像重试）"
                    }
                    self.isDownloading = false
                    Haptic.error()
                }
            }
        }
    }
}
