import Combine
import Foundation
import SwiftUI
import AssistantCore

/// 端侧可选大模型规格预设（支持升级切换至 Qwen3 系列）
///
/// 这里只剩「预设 → 描述符」的一一对应：展示文案、本地文件名、发布指纹、下载地址与
/// ChatML 方言全部在 `AssistantCore.ModelRegistry`。新增一个模型 = Core 一个描述符条目
/// + `builtIn` 一行 + 下面一行 case。case 的 rawValue 已持久化在
/// `llm_selected_model_preset_v1`，**不能改名**。
public enum LLMModelPreset: String, CaseIterable, Identifiable, Sendable {
    case qwen3_1_7b = "qwen3_1_7b"
    case qwen3_4b = "qwen3_4b"
    case qwen2_5_1_5b = "qwen2_5_1_5b"

    public var id: String { rawValue }

    /// 刻意用穷尽 switch 而不是按 `rawValue` 查表：新增 case 忘记接描述符会是编译错误，
    /// 而不是运行期读到别的模型的文件名、把完好文件判成无效。
    public var descriptor: ModelDescriptor {
        let model: ModelDescriptor
        switch self {
        case .qwen3_1_7b: model = .qwen3_1_7b
        case .qwen3_4b: model = .qwen3_4b
        case .qwen2_5_1_5b: model = .qwen2_5_1_5b
        }
        #if DEBUG
        assert(model.id == rawValue, "描述符 \(model.id) 被接到预设 \(rawValue) 上")
        #endif
        return model
    }

    /// 列表主标题（含推荐语）
    public var displayName: String { descriptor.displayName }

    /// 简短名称（用于导航栏、状态栏与提示词）
    public var shortName: String { descriptor.shortName }

    /// 模型能力与适用机型说明
    public var subtitle: String { L10n.tr(descriptor.subtitle) }

    /// 参数规模展示文案
    public var parameterCountText: String { descriptor.parameterCountText }

    /// 文件体积可读说明
    public var formattedExpectedSize: String { L10n.tr(descriptor.expectedSizeText) }

    /// 运行内存预估说明
    public var estimatedRAMText: String { L10n.tr(descriptor.estimatedRAMText) }

    /// 本地存储文件名
    public var fileName: String { descriptor.fileName }

    /// 已核验的发布产物清单（发布方给出的权威指纹），清单本体在 Core
    public var publishedReleases: [ModelReleaseIntegrity] { descriptor.publishedReleases }

    /// 预期字节大小（取已核验发布产物的精确体积，不再用估算值）
    public var expectedSizeApproxBytes: Int64 { descriptor.expectedSizeApproxBytes }

    /// 校验时的最小合法字节数
    public var minValidSizeBytes: Int64 { descriptor.minValidSizeBytes }

    /// 对应局域网 Ollama 推荐模型名
    public var ollamaModelTag: String { descriptor.ollamaModelTag }

    /// ChatML 方言；`assistantStartSuffix` 决定助手起始标记后预填什么
    public var chatDialect: ModelChatDialect { descriptor.chatDialect }

    /// 获取指定下载源的下载地址
    public func downloadURL(for source: LLMDownloadSource) -> URL {
        descriptor.downloadURL(for: source.modelSourceID)
    }
}

/// 下载源选择
public enum LLMDownloadSource: String, CaseIterable, Identifiable {
    case modelScope = "ModelScope (魔搭社区 · 阿里国内极速)"
    case huggingFace = "Hugging Face (官方海外源)"

    public var id: String { rawValue }

    public var displayName: String { L10n.tr(rawValue) }

    /// UI 文案与稳定标识解耦：展示用整句中文，查描述符用 Core 的源 id
    var modelSourceID: ModelDownloadSourceID {
        switch self {
        case .modelScope: return .modelScope
        case .huggingFace: return .huggingFace
        }
    }

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
    /// 已核验的发布版本标识（如 `unsloth/Qwen3-1.7B-GGUF@1e3f4948`）。
    /// 为 nil 表示「尚未核验」或「无发布背书」，UI 不得据此宣称已就绪。
    @Published public var verifiedReleaseVersion: String?
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
        let releases = selectedPreset.publishedReleases

        let mtimeKey = "\(validatedDigestKey)_mtime"
        let sizeKey = "\(validatedDigestKey)_size"
        let cachedMtime = UserDefaults.standard.double(forKey: mtimeKey)
        let cachedSize = (UserDefaults.standard.object(forKey: sizeKey) as? NSNumber)?.int64Value ?? 0
        let currentMtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        if let expectedDigest,
           cachedSize == self.downloadedBytes,
           cachedMtime > 0,
           abs(cachedMtime - currentMtime) < 0.001 {
            // 文件大小与修改时间均未改变，直接复用已验证指纹，无需冷启动重新扫描数GB磁盘，避免内存与I/O激增
            let verdict = ModelIntegrityEvaluator.evaluate(
                actualSize: self.downloadedBytes,
                actualDigest: expectedDigest,
                releases: releases
            )
            self.verifiedReleaseVersion = ModelFileValidation.releaseVersionText(verdict)
            self.errorMessage = nil
            self.validationStatus = .validated
            self.clearResumeData()
            self.hasResumeData = false
            return
        }

        Task.detached(priority: .utility) {
            let result = Result { try ModelFileValidation.validate(at: url, minSizeBytes: minSize, releases: releases) }
            await MainActor.run {
                guard generation == self.validationGeneration else { return }
                switch result {
                case .success(let validated):
                    if let expectedDigest, expectedDigest != validated.digest {
                        self.markValidationFailed("模型文件校验值已变化，请重新导入。")
                        return
                    }
                    UserDefaults.standard.set(validated.digest, forKey: self.validatedDigestKey)
                    UserDefaults.standard.set(validated.size, forKey: "\(self.validatedDigestKey)_size")
                    let modTime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    UserDefaults.standard.set(modTime, forKey: "\(self.validatedDigestKey)_mtime")
                    self.downloadedBytes = validated.size
                    self.totalBytes = validated.size
                    self.verifiedReleaseVersion = ModelFileValidation.releaseVersionText(validated.verdict)
                    self.errorMessage = nil
                    self.validationStatus = .validated
                    self.clearResumeData()
                case .failure(let error):
                    self.verifiedReleaseVersion = nil
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
        let releases = selectedPreset.publishedReleases
        let result = await Task.detached(priority: .utility) {
            Result { try ModelFileValidation.validate(at: url, minSizeBytes: minSize, releases: releases) }
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
            verifiedReleaseVersion = ModelFileValidation.releaseVersionText(validated.verdict)
            errorMessage = nil
            validationStatus = .validated
            clearResumeData()
            return true
        case .failure(let error):
            verifiedReleaseVersion = nil
            markValidationFailed(L10n.choose("模型文件无效：\(error.localizedDescription)", "Invalid model file: \(error.localizedDescription)"))
            return false
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
        deleteModel(for: selectedPreset)
    }

    /// 删除指定规格的本地模型。
    ///
    /// 删非选中项时不碰引擎：用户正在用的那个模型不该因为清理另一规格的残留文件被卸载。
    /// 续传数据与核验摘要按规格隔离，所以这里必须用 preset 自己的键，不能用「当前选中」的。
    public func deleteModel(for preset: LLMModelPreset) {
        let isActiveDownload = isDownloading && (downloadingPreset ?? selectedPreset) == preset
        if isActiveDownload {
            downloadTask?.cancel()
            downloadTask = nil
            isDownloading = false
            downloadSpeedMBps = 0
        }
        try? FileManager.default.removeItem(at: resumeDataURL(for: preset))
        try? FileManager.default.removeItem(at: modelURL(for: preset))
        UserDefaults.standard.removeObject(forKey: validatedDigestKey(for: preset))
        UserDefaults.standard.removeObject(forKey: "\(validatedDigestKey(for: preset))_mtime")
        UserDefaults.standard.removeObject(forKey: "\(validatedDigestKey(for: preset))_size")
        if preset == selectedPreset {
            Task {
                await LLMInferenceService.shared.unloadLocalModel()
            }
            verifiedReleaseVersion = nil
            hasResumeData = false
            checkModelStatus()
        }
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
        // 先校验再替换：校验不通过时抛错，旧模型原封不动留在磁盘上
        let validated = try ModelFileValidation.validate(
            at: candidate,
            minSizeBytes: selectedPreset.minValidSizeBytes,
            releases: selectedPreset.publishedReleases
        )
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
        verifiedReleaseVersion = ModelFileValidation.releaseVersionText(validated.verdict)
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
            let preset = self.downloadingPreset ?? self.selectedPreset
            let minSize = preset.minValidSizeBytes
            let releases = preset.publishedReleases
            let result = await Task.detached(priority: .utility) {
                Result { try ModelFileValidation.validate(at: candidateURL, minSizeBytes: minSize, releases: releases) }
            }.value
            self.completeDownloadedModel(candidateURL: candidateURL, validation: result)
        }
    }

    private func completeDownloadedModel(
        candidateURL: URL,
        validation: Result<ModelFileValidation.Validated, Error>
    ) {
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
            verifiedReleaseVersion = ModelFileValidation.releaseVersionText(validated.verdict)
            clearResumeData()
            errorMessage = nil
            checkModelStatus()
            Haptic.success()
        } catch {
            verifiedReleaseVersion = nil
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
