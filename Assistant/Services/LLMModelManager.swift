import Combine
import CryptoKit
import Foundation
import SwiftUI

/// 端侧可选大模型规格预设（支持升级切换至 Qwen3 系列）
public enum LLMModelPreset: String, CaseIterable, Identifiable, Sendable {
    case qwen3_1_7b = "qwen3_1_7b"
    case qwen3_4b = "qwen3_4b"
    case qwen2_5_1_5b = "qwen2_5_1_5b"

    public var id: String { rawValue }

    /// 模型展示名称
    public var displayName: String {
        switch self {
        case .qwen3_1_7b: return "Qwen3-1.7B-Instruct (推荐)"
        case .qwen3_4b: return "Qwen3-4B-Instruct (增强版)"
        case .qwen2_5_1_5b: return "Qwen2.5-1.5B-Instruct (轻量兼容)"
        }
    }

    /// 简短名称（用于导航栏、状态栏与提示词）
    public var shortName: String {
        switch self {
        case .qwen3_1_7b: return "Qwen3-1.7B"
        case .qwen3_4b: return "Qwen3-4B"
        case .qwen2_5_1_5b: return "Qwen2.5-1.5B"
        }
    }

    /// 模型能力与适用机型说明
    public var subtitle: String {
        switch self {
        case .qwen3_1_7b:
            return L10n.tr("新一代千问 Qwen3 架构 · 推理与指令遵循大幅提升，兼顾速度与低内存")
        case .qwen3_4b:
            return L10n.tr("40 亿参数高阶端侧模型 · 食物热量推断与复杂拆解更强（建议 8GB+ 内存机型）")
        case .qwen2_5_1_5b:
            return L10n.tr("经典轻量端侧模型 · 体积最小，兼容旧版已下载模型文件")
        }
    }

    /// 参数规模展示文案
    public var parameterCountText: String {
        switch self {
        case .qwen3_1_7b: return "17.2 亿 (1.7B)"
        case .qwen3_4b: return "40.2 亿 (4.0B)"
        case .qwen2_5_1_5b: return "15.4 亿 (1.54B)"
        }
    }

    /// 文件体积可读说明
    public var formattedExpectedSize: String {
        switch self {
        case .qwen3_1_7b: return L10n.tr("约 1.11 GB")
        case .qwen3_4b: return L10n.tr("约 2.50 GB")
        case .qwen2_5_1_5b: return L10n.tr("约 986 MB")
        }
    }

    /// 运行内存预估说明
    public var estimatedRAMText: String {
        switch self {
        case .qwen3_1_7b: return L10n.tr("约 1.2 GB")
        case .qwen3_4b: return L10n.tr("约 2.6 GB")
        case .qwen2_5_1_5b: return L10n.tr("约 980 MB")
        }
    }

    /// 本地存储文件名
    public var fileName: String {
        switch self {
        case .qwen3_1_7b: return "Qwen3-1.7B-Q4_K_M.gguf"
        case .qwen3_4b: return "Qwen3-4B-Q4_K_M.gguf"
        case .qwen2_5_1_5b: return "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        }
    }

    /// 预期字节大小（用于下载进度预估）
    public var expectedSizeApproxBytes: Int64 {
        switch self {
        case .qwen3_1_7b: return 1_110_000_000
        case .qwen3_4b: return 2_500_000_000
        case .qwen2_5_1_5b: return 986_000_000
        }
    }

    /// 校验时的最小合法字节数
    public var minValidSizeBytes: Int64 {
        switch self {
        case .qwen3_1_7b: return 900_000_000
        case .qwen3_4b: return 2_000_000_000
        case .qwen2_5_1_5b: return 850_000_000
        }
    }

    /// 对应局域网 Ollama 推荐模型名
    public var ollamaModelTag: String {
        switch self {
        case .qwen3_1_7b: return "qwen3:1.7b"
        case .qwen3_4b: return "qwen3:4b"
        case .qwen2_5_1_5b: return "qwen2.5:1.5b"
        }
    }

    /// 是否属于 Qwen3 架构家族（支持 `<think>` 思考标签控制）
    public var isQwen3Family: Bool {
        switch self {
        case .qwen3_1_7b, .qwen3_4b: return true
        case .qwen2_5_1_5b: return false
        }
    }

    /// 获取指定下载源的下载地址
    public func downloadURL(for source: LLMDownloadSource) -> URL {
        switch (self, source) {
        case (.qwen3_1_7b, .modelScope):
            return URL(string: "https://www.modelscope.cn/models/unsloth/Qwen3-1.7B-GGUF/resolve/master/Qwen3-1.7B-Q4_K_M.gguf")!
        case (.qwen3_1_7b, .huggingFace):
            return URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!
        case (.qwen3_4b, .modelScope):
            return URL(string: "https://www.modelscope.cn/models/Qwen/Qwen3-4B-GGUF/resolve/master/Qwen3-4B-Q4_K_M.gguf")!
        case (.qwen3_4b, .huggingFace):
            return URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!
        case (.qwen2_5_1_5b, .modelScope):
            return URL(string: "https://www.modelscope.cn/models/qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
        case (.qwen2_5_1_5b, .huggingFace):
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!
        }
    }
}

/// 下载源选择
public enum LLMDownloadSource: String, CaseIterable, Identifiable {
    case modelScope = "ModelScope (魔搭社区 · 阿里国内极速)"
    case huggingFace = "Hugging Face (官方海外源)"

    public var id: String { rawValue }

    public var displayName: String { L10n.tr(rawValue) }

    public var downloadURL: URL {
        LLMModelPreset.qwen3_1_7b.downloadURL(for: self)
    }
}

/// 模型完整性校验状态：把「文件存在」与「校验通过」拆开，校验未出结论前 UI 不得显示就绪
public enum LLMModelValidationStatus: Equatable {
    case noModelFile
    case validating
    case validated
    case validationFailed(reason: String)
}

/// 本地大模型（Qwen3 / Qwen2.5）文件管理与极速下载器
@MainActor
public final class LLMModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = LLMModelManager()

    nonisolated public static let modelFileName = LLMModelPreset.qwen2_5_1_5b.fileName
    nonisolated public static let expectedSizeApproxBytes: Int64 = LLMModelPreset.qwen3_1_7b.expectedSizeApproxBytes
    private static let selectedPresetKey = "llm_selected_model_preset_v1"

    // 模型存储目录
    public var modelsDirectory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 当前选中的端侧模型规格（支持在 Qwen3-1.7B / Qwen3-4B / Qwen2.5-1.5B 之间切换）
    @Published public var selectedPreset: LLMModelPreset = .qwen3_1_7b {
        didSet {
            guard oldValue != selectedPreset else { return }
            UserDefaults.standard.set(selectedPreset.rawValue, forKey: Self.selectedPresetKey)
            handlePresetSwitch(from: oldValue, to: selectedPreset)
        }
    }

    public func modelURL(for preset: LLMModelPreset) -> URL {
        modelsDirectory.appendingPathComponent(preset.fileName)
    }

    public var localModelURL: URL {
        modelURL(for: selectedPreset)
    }

    /// 断点续传数据持久化路径（按模型规格隔离，切换模型不会冲掉另一模型的下载进度）
    public var resumeDataURL: URL {
        resumeDataURL(for: selectedPreset)
    }

    private func resumeDataURL(for preset: LLMModelPreset) -> URL {
        modelsDirectory.appendingPathComponent("\(preset.rawValue)_download.resume_data")
    }

    private func validatedDigestKey(for preset: LLMModelPreset) -> String {
        switch preset {
        case .qwen2_5_1_5b:
            return "llm_model_validated_sha256_v1"
        default:
            return "llm_model_validated_sha256_\(preset.rawValue)"
        }
    }

    private var validatedDigestKey: String {
        validatedDigestKey(for: selectedPreset)
    }

    /// 判断某个预设模型文件是否已存在于本地磁盘
    public func hasModelFileOnDisk(for preset: LLMModelPreset) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: preset).path)
    }

    // 状态发布
    @Published public var validationStatus: LLMModelValidationStatus = .noModelFile
    /// 兼容旧调用方的语义并收紧为「完整性校验通过」：修复校验完成前误报就绪的缺陷
    public var isModelDownloaded: Bool { validationStatus == .validated }
    @Published public var isDownloading: Bool = false
    @Published public var hasResumeData: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var downloadedBytes: Int64 = 0
    @Published public var totalBytes: Int64 = LLMModelPreset.qwen3_1_7b.expectedSizeApproxBytes
    @Published public var downloadSpeedMBps: Double = 0.0
    @Published public var errorMessage: String?
    @Published public var selectedSource: LLMDownloadSource = .modelScope

    private var downloadTask: URLSessionDownloadTask?
    private var downloadingPreset: LLMModelPreset?
    private var validationGeneration = 0
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
        if let savedRaw = UserDefaults.standard.string(forKey: Self.selectedPresetKey),
           let saved = LLMModelPreset(rawValue: savedRaw) {
            self.selectedPreset = saved
        } else {
            // 若旧版已下载过 Qwen2.5-1.5B 且尚未下载 Qwen3，则自动保持选中已下载的模型；新用户默认选中 Qwen3-1.7B
            let qwen3_1_7bExists = FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(LLMModelPreset.qwen3_1_7b.fileName).path)
            let qwen3_4bExists = FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(LLMModelPreset.qwen3_4b.fileName).path)
            let legacyExists = FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent(LLMModelPreset.qwen2_5_1_5b.fileName).path)
            if qwen3_4bExists {
                self.selectedPreset = .qwen3_4b
            } else if qwen3_1_7bExists {
                self.selectedPreset = .qwen3_1_7b
            } else if legacyExists {
                self.selectedPreset = .qwen2_5_1_5b
            } else {
                self.selectedPreset = .qwen3_1_7b
            }
        }
        self.totalBytes = selectedPreset.expectedSizeApproxBytes
        checkModelStatus()
    }

    private func handlePresetSwitch(from oldPreset: LLMModelPreset, to newPreset: LLMModelPreset) {
        if isDownloading {
            pauseDownload()
        }
        errorMessage = nil
        downloadProgress = 0.0
        downloadedBytes = 0
        totalBytes = newPreset.expectedSizeApproxBytes
        Task {
            await LLMInferenceService.shared.unloadLocalModel()
        }
        checkModelStatus()
    }

    /// 快速同步校验本地 GGUF 模型文件头与体积是否有效（毫秒级，不阻塞主线程）
    public var hasValidLocalGGUFFile: Bool {
        let url = localModelURL
        let minSize = selectedPreset.minValidSizeBytes
        guard FileManager.default.fileExists(atPath: url.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size >= min(minSize, 300_000_000),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8),
              header.count == 8,
              String(data: header.prefix(4), encoding: .ascii) == "GGUF" else {
            return false
        }
        return true
    }

    /// 检查本地模型是否存在，并异步进行完整性校验；校验通过前状态保持「校验中」
    public func checkModelStatus() {
        validationGeneration += 1
        let generation = validationGeneration
        let url = localModelURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            validationStatus = .noModelFile
            UserDefaults.standard.removeObject(forKey: validatedDigestKey)
            hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)
            return
        }

        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
            // 若文件小于 10MB（如之前 404 错误响应保存的数百字节碎片），自动清除并重置为未下载态，避免用户持续卡在校验失败
            if size < 10_000_000 {
                try? FileManager.default.removeItem(at: url)
                clearResumeData()
                validationStatus = .noModelFile
                UserDefaults.standard.removeObject(forKey: validatedDigestKey)
                self.downloadedBytes = 0
                self.totalBytes = selectedPreset.expectedSizeApproxBytes
                hasResumeData = false
                return
            }
            self.downloadedBytes = size
            self.totalBytes = size
        }
        // 文件存在 ≠ 完整：SHA-256 结论前不得放行「就绪」，防止断网推理加载截断文件
        validationStatus = .validating

        let expectedDigest = UserDefaults.standard.string(forKey: validatedDigestKey)
        let minSize = selectedPreset.minValidSizeBytes
        Task.detached(priority: .utility) {
            let result = Result { try Self.validateModel(at: url, minSizeBytes: minSize) }
            await MainActor.run {
                guard generation == self.validationGeneration else { return }
                switch result {
                case .success(let validated):
                    if let expectedDigest, expectedDigest != validated.digest {
                        self.markValidationFailed("模型文件校验值已变化，请重新导入。")
                        return
                    }
                    UserDefaults.standard.set(validated.digest, forKey: self.validatedDigestKey)
                    self.downloadedBytes = validated.size
                    self.totalBytes = validated.size
                    self.errorMessage = nil
                    self.validationStatus = .validated
                    self.clearResumeData()
                case .failure(let error):
                    self.markValidationFailed(L10n.choose("模型文件无效：\(error.localizedDescription)", "Invalid model file: \(error.localizedDescription)"))
                }
            }
        }
        hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)
    }

    private func markValidationFailed(_ reason: String) {
        // 失败原因随状态发布，由 UI 直接展示，避免 errorMessage 与状态徽标双重来源
        validationStatus = .validationFailed(reason: reason)
    }

    /// 等待完整校验结束后返回模型是否可用。加载前调用此方法，仅「校验通过」才放行推理。
    public func validateModelStatusAndWait() async -> Bool {
        validationGeneration += 1
        let generation = validationGeneration
        let url = localModelURL
        let minSize = selectedPreset.minValidSizeBytes

        guard FileManager.default.fileExists(atPath: url.path) else {
            validationStatus = .noModelFile
            UserDefaults.standard.removeObject(forKey: validatedDigestKey)
            hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)
            return false
        }

        validationStatus = .validating
        let result = await Task.detached(priority: .utility) {
            Result { try Self.validateModel(at: url, minSizeBytes: minSize) }
        }.value

        guard generation == validationGeneration else { return isModelDownloaded }
        hasResumeData = FileManager.default.fileExists(atPath: resumeDataURL.path)

        switch result {
        case .success(let validated):
            if let expectedDigest = UserDefaults.standard.string(forKey: validatedDigestKey),
               expectedDigest != validated.digest {
                markValidationFailed("模型文件校验值已变化，请重新导入。")
                return false
            }
            UserDefaults.standard.set(validated.digest, forKey: validatedDigestKey)
            downloadedBytes = validated.size
            totalBytes = validated.size
            errorMessage = nil
            validationStatus = .validated
            clearResumeData()
            return true
        case .failure(let error):
            markValidationFailed(L10n.choose("模型文件无效：\(error.localizedDescription)", "Invalid model file: \(error.localizedDescription)"))
            return false
        }
    }

    nonisolated private static func validateModel(at url: URL, minSizeBytes: Int64 = 300_000_000) throws -> (size: Int64, digest: String) {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minSizeBytes else { throw ModelValidationError.invalidSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8, String(data: header.prefix(4), encoding: .ascii) == "GGUF" else {
            throw ModelValidationError.invalidHeader
        }
        let version = header.suffix(4).enumerated().reduce(UInt32(0)) { value, byte in
            value | (UInt32(byte.element) << (UInt32(byte.offset) * 8))
        }
        guard version == 2 || version == 3 else { throw ModelValidationError.invalidVersion }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private enum ModelValidationError: LocalizedError {
        case invalidSize, invalidHeader, invalidVersion
        var errorDescription: String? {
            switch self {
            case .invalidSize: L10n.tr("文件体积与预期模型不符。")
            case .invalidHeader: L10n.tr("文件不是支持的 GGUF 格式。")
            case .invalidVersion: L10n.tr("GGUF 文件格式版本不支持。")
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
        return selectedPreset.formattedExpectedSize
    }

    /// 开启或继续模型下载（支持断点续传）
    public func startDownload(source: LLMDownloadSource? = nil, forceRestart: Bool = false) {
        guard !isDownloading else { return }
        let src = source ?? selectedSource
        self.selectedSource = src
        self.downloadingPreset = selectedPreset
        self.errorMessage = nil
        self.downloadSpeedMBps = 0.0
        self.lastSpeedCheckTime = .now
        self.lastSpeedBytes = 0
        self.totalBytes = selectedPreset.expectedSizeApproxBytes

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
            let downloadURL = selectedPreset.downloadURL(for: src)
            let task = urlSession.downloadTask(with: downloadURL)
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
        Task {
            await LLMInferenceService.shared.unloadLocalModel()
        }
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
            let fallbackExpected = (self.downloadingPreset ?? self.selectedPreset).expectedSizeApproxBytes
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackExpected
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
        // 严格检查 HTTP 状态码：若非 2xx（如 404/500/403），代表下载到的是错误页面而非模型二进制，避免将其当作 GGUF 校验报「校验失败」
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            Task { @MainActor in
                self.errorMessage = "下载失败：HTTP \(httpResponse.statusCode)（服务器资源未找到或暂时不可用，建议切换下载节点重试）"
                self.isDownloading = false
                self.clearResumeData()
                Haptic.error()
            }
            return
        }

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
        Task { @MainActor in
            let minSize = (self.downloadingPreset ?? self.selectedPreset).minValidSizeBytes
            let result = await Task.detached(priority: .utility) {
                Result { try Self.validateModel(at: candidateURL, minSizeBytes: minSize) }
            }.value
            self.completeDownloadedModel(candidateURL: candidateURL, validation: result)
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
            markValidationFailed(L10n.choose("模型文件无效：\(error.localizedDescription)", "Invalid model file: \(error.localizedDescription)"))
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
