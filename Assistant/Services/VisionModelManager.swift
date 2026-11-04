import AssistantCore
import Combine
import Foundation
import SwiftUI

/// 视觉模型包（多文件）的本地管理：逐件下载、逐件校验、整包删除。
///
/// 对话模型是「1 预设 = 1 个文件」，视觉包是「1 个模型 = N 个必须同版本的部件」，所以这里
/// 的状态天然是**按部件**的。只有全部部件都校验通过，`isBundleReady` 才为真：缺 mmproj 时
/// llama.cpp 照样能加载权重、却认不出图，那比直接报「未就绪」更难排查。
///
/// 校验走 `ModelFileValidation`，与对话模型同一条判据——两套「什么算有效文件」会各自漂移，
/// 而漂移在设备上的表现同样只有「文件无效」四个字。
@MainActor
public final class VisionModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = VisionModelManager()

    public let bundle: VisionModelBundle
    public var parts: [VisionModelPart] { bundle.parts }

    /// 单个部件「在这台机器上现在怎么样」。UI 据此决定按钮可否点击。
    public struct PartState: Equatable {
        public var validation: LLMModelValidationStatus = .noModelFile
        public var sizeOnDiskBytes: Int64 = 0
        public var verifiedReleaseVersion: String?
        public var hasResumeData = false
        public var downloadedBytes: Int64 = 0
        public var totalBytes: Int64 = 0

        public var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1.0, Double(downloadedBytes) / Double(totalBytes))
        }

        public var isValidationFailed: Bool {
            if case .validationFailed = validation { return true }
            return false
        }
    }

    @Published public private(set) var states: [String: PartState] = [:]
    @Published public private(set) var isDownloading = false
    @Published public private(set) var downloadSpeedMBps: Double = 0.0
    @Published public var errorMessage: String?

    /// 可选源来自描述符，不在此处硬编码模型名。目前视觉包只挂 ModelScope（HF 还没做
    /// 双源交叉核验），加源时这里和 UI 的分段控件会一起变长，判据不用改。
    @Published public private(set) var selectedSource: ModelDownloadSourceID
    public var availableSources: [ModelDownloadSourceID] { bundle.availableSources }

    /// 与对话模型同一目录：文件名由 Core 钉过「与聊天模型不重名」，所以不会互相覆盖。
    public var modelsDirectory: URL { LLMModelManager.shared.modelsDirectory }

    /// 排队待下载的部件，**不含**当前正在下的那件（出队即交给 `activePart`）。
    private var queuedParts: [VisionModelPart] = []
    private var activePart: VisionModelPart?
    private var downloadTask: URLSessionDownloadTask?
    /// 整包代次。删除/放弃后自增，用来作废在途的下载回调——
    /// 否则「刚删掉的包」会被还在跑的下载回调重新装回去，用户看着像删除没生效。
    private var bundleEpoch = 0
    private var validationGenerations: [String: Int] = [:]
    private var lastSpeedCheckTime: Date = .now
    private var lastSpeedBytes: Int64 = 0
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    public init(bundle: VisionModelBundle = VisionModelRegistry.defaultBundle) {
        self.bundle = bundle
        self.selectedSource = bundle.availableSources.first ?? .modelScope
        super.init()
        var initial: [String: PartState] = [:]
        for part in bundle.parts { initial[part.id] = PartState(totalBytes: part.expectedSizeBytes) }
        self.states = initial
        checkStatus()
    }

    // MARK: - 路径与键

    public func part(id: String) -> VisionModelPart? {
        parts.first { $0.id == id }
    }

    public func partURL(for part: VisionModelPart) -> URL {
        modelsDirectory.appendingPathComponent(part.fileName)
    }

    /// 断点续传数据按「包 + 部件」隔离：两个部件的进度互不覆盖，也不会串到聊天模型头上
    /// （聊天用 `\(preset.rawValue)_download.resume_data`，前缀不同）。
    private func resumeDataURL(for part: VisionModelPart) -> URL {
        modelsDirectory.appendingPathComponent("\(bundle.id)_\(part.id)_download.resume_data")
    }

    private func digestKey(for part: VisionModelPart) -> String {
        "vision_model_validated_sha256_\(part.id)"
    }

    // MARK: - 状态读取

    public func state(for part: VisionModelPart) -> PartState {
        states[part.id] ?? PartState()
    }

    public func isPartReady(_ part: VisionModelPart) -> Bool {
        state(for: part).validation == .validated
    }

    public func part(with role: VisionModelPart.Role) -> VisionModelPart? {
        bundle.part(role: role)
    }

    /// 整包可用：语言模型与视觉编码器都在盘上且都校验通过。
    public var isBundleReady: Bool { parts.allSatisfy { isPartReady($0) } }

    public var hasAnyPartOnDisk: Bool {
        parts.contains { FileManager.default.fileExists(atPath: partURL(for: $0).path) }
    }

    /// 盘上真实占用的体积。删除前用它告诉用户能腾出多少空间——
    /// 用发布体积去报「能释放 X」会在只下了一半时把数字说大。
    public var bytesOnDisk: Int64 {
        parts.reduce(Int64(0)) { sum, part in
            let path = partURL(for: part).path
            guard FileManager.default.fileExists(atPath: path) else { return sum }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    public var hasAnyResumeData: Bool { parts.contains { state(for: $0).hasResumeData } }

    /// 需要下载的部件：未校验通过的全部（保持 Core 里的声明顺序，权重先、投影器后）。
    public var partsNeedingDownload: [VisionModelPart] { parts.filter { !isPartReady($0) } }

    public var totalExpectedBytes: Int64 { bundle.totalSizeBytes }

    /// 已就绪的按磁盘实际体积计，正在下的按已写字节计，排队的计 0。
    public var overallDownloadedBytes: Int64 {
        parts.reduce(Int64(0)) { sum, part in
            let s = state(for: part)
            if s.validation == .validated { return sum + s.sizeOnDiskBytes }
            if part.id == activePart?.id { return sum + s.downloadedBytes }
            return sum
        }
    }

    public var overallProgress: Double {
        guard totalExpectedBytes > 0 else { return 0 }
        return min(1.0, Double(overallDownloadedBytes) / Double(totalExpectedBytes))
    }

    public var formattedBundleSize: String {
        Self.byteText(isBundleReady ? overallDownloadedBytes : totalExpectedBytes)
    }

    public func formattedSize(for part: VisionModelPart) -> String {
        let onDisk = state(for: part).sizeOnDiskBytes
        return Self.byteText(onDisk > 0 ? onDisk : part.expectedSizeBytes)
    }

    private nonisolated static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 齐备时给出引擎需要的两条路径；缺任何一件返回 nil——调用方不得退化成「只加载权重」。
    public func readyBundlePaths() -> (languageModel: URL, visionProjector: URL)? {
        guard let lm = bundle.part(role: .languageModel),
              let projector = bundle.part(role: .visionProjector),
              isPartReady(lm), isPartReady(projector) else { return nil }
        return (partURL(for: lm), partURL(for: projector))
    }

    // MARK: - 检查与校验

    /// 逐件检查磁盘状态并异步校验；校验未出结论前该件不得算作就绪。
    public func checkStatus() {
        for part in parts { refreshStatus(of: part) }
    }

    public func checkStatus(of part: VisionModelPart) {
        refreshStatus(of: part)
    }

    private func refreshStatus(of part: VisionModelPart) {
        validationGenerations[part.id, default: 0] += 1
        let generation = validationGenerations[part.id] ?? 0
        let url = partURL(for: part)
        let resumeExists = FileManager.default.fileExists(atPath: resumeDataURL(for: part).path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: digestKey(for: part))
            UserDefaults.standard.removeObject(forKey: "\(digestKey(for: part))_mtime")
            UserDefaults.standard.removeObject(forKey: "\(digestKey(for: part))_size")
            setState(for: part) {
                $0.validation = .noModelFile
                $0.sizeOnDiskBytes = 0
                $0.verifiedReleaseVersion = nil
                $0.downloadedBytes = 0
                $0.totalBytes = part.expectedSizeBytes
                $0.hasResumeData = resumeExists
            }
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        // 小于 10MB 的碎片（典型是把 404 错误页存成了 .gguf）直接删掉回到未下载态，
        // 否则用户会反复卡在同一条校验失败上。
        if size < 10_000_000 {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: resumeDataURL(for: part))
            UserDefaults.standard.removeObject(forKey: digestKey(for: part))
            UserDefaults.standard.removeObject(forKey: "\(digestKey(for: part))_mtime")
            UserDefaults.standard.removeObject(forKey: "\(digestKey(for: part))_size")
            setState(for: part) {
                $0.validation = .noModelFile
                $0.sizeOnDiskBytes = 0
                $0.verifiedReleaseVersion = nil
                $0.downloadedBytes = 0
                $0.totalBytes = part.expectedSizeBytes
                $0.hasResumeData = false
            }
            return
        }

        setState(for: part) {
            $0.validation = .validating
            $0.sizeOnDiskBytes = size
            $0.downloadedBytes = size
            $0.totalBytes = size
            $0.hasResumeData = resumeExists
        }

        let expectedDigest = UserDefaults.standard.string(forKey: digestKey(for: part))
        let minSize = part.minValidSizeBytes
        let releases = part.publishedReleases

        let mtimeKey = "\(digestKey(for: part))_mtime"
        let sizeKey = "\(digestKey(for: part))_size"
        let cachedMtime = UserDefaults.standard.double(forKey: mtimeKey)
        let cachedSize = (UserDefaults.standard.object(forKey: sizeKey) as? NSNumber)?.int64Value ?? 0
        let currentMtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        if let expectedDigest,
           cachedSize == size,
           cachedMtime > 0,
           abs(cachedMtime - currentMtime) < 0.001 {
            // 文件大小与修改时间均未改变，直接复用已验证指纹，无需冷启动重新扫描数GB磁盘，避免并发哈希造成 OOM
            let verdict = ModelIntegrityEvaluator.evaluate(
                actualSize: size,
                actualDigest: expectedDigest,
                releases: releases
            )
            try? FileManager.default.removeItem(at: self.resumeDataURL(for: part))
            self.setState(for: part) {
                $0.validation = .validated
                $0.sizeOnDiskBytes = size
                $0.downloadedBytes = size
                $0.totalBytes = size
                $0.verifiedReleaseVersion = ModelFileValidation.releaseVersionText(verdict)
                $0.hasResumeData = false
            }
            return
        }

        Task.detached(priority: .utility) {
            let result = Result { try ModelFileValidation.validate(at: url, minSizeBytes: minSize, releases: releases) }
            await MainActor.run {
                guard generation == (self.validationGenerations[part.id] ?? 0) else { return }
                switch result {
                case .success(let validated):
                    if let expectedDigest, expectedDigest != validated.digest {
                        self.markFailed(part, L10n.tr("模型文件校验值已变化，请重新导入。"))
                        return
                    }
                    UserDefaults.standard.set(validated.digest, forKey: self.digestKey(for: part))
                    UserDefaults.standard.set(validated.size, forKey: "\(self.digestKey(for: part))_size")
                    let modTime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    UserDefaults.standard.set(modTime, forKey: "\(self.digestKey(for: part))_mtime")
                    try? FileManager.default.removeItem(at: self.resumeDataURL(for: part))
                    self.setState(for: part) {
                        $0.validation = .validated
                        $0.sizeOnDiskBytes = validated.size
                        $0.downloadedBytes = validated.size
                        $0.totalBytes = validated.size
                        $0.verifiedReleaseVersion = ModelFileValidation.releaseVersionText(validated.verdict)
                        $0.hasResumeData = false
                    }
                case .failure(let error):
                    self.setState(for: part) { $0.verifiedReleaseVersion = nil }
                    self.markFailed(
                        part,
                        L10n.choose(
                            "部件「\(part.displayName)」文件无效：\(error.localizedDescription)",
                            "The \"\(part.displayName)\" file is invalid: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func markFailed(_ part: VisionModelPart, _ reason: String) {
        setState(for: part) { $0.validation = .validationFailed(reason: reason) }
    }

    private func setState(for part: VisionModelPart, _ mutate: (inout PartState) -> Void) {
        var s = states[part.id] ?? PartState()
        mutate(&s)
        states[part.id] = s
    }

    // MARK: - 下载

    /// 只改选源，不顺手开下：分段控件换源时若自动开始下载，用户只是想比较速度就会被坑掉流量。
    public func selectSource(_ source: ModelDownloadSourceID) {
        guard availableSources.contains(source), source != selectedSource else { return }
        if isDownloading { pauseDownload() }
        selectedSource = source
        errorMessage = nil
    }

    /// 顺序下载全部缺失部件，每完成一件自动接下一件；已有断点进度的部件走续传。
    public func startDownload() {
        guard !isDownloading else { return }
        errorMessage = nil
        downloadSpeedMBps = 0
        lastSpeedBytes = 0
        lastSpeedCheckTime = .now
        queuedParts = partsNeedingDownload
        startNextQueuedPart()
    }

    private func startNextQueuedPart() {
        guard let next = queuedParts.first else {
            activePart = nil
            isDownloading = false
            downloadSpeedMBps = 0
            return
        }
        queuedParts.removeFirst()
        guard let url = next.downloadURL(for: selectedSource) else {
            errorMessage = L10n.choose(
                "部件「\(next.displayName)」在该源上没有下载地址。",
                "The \"\(next.displayName)\" part has no download URL on this source."
            )
            startNextQueuedPart()
            return
        }
        activePart = next
        isDownloading = true
        setState(for: next) {
            $0.downloadedBytes = 0
            $0.totalBytes = next.expectedSizeBytes
        }
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeDataURL(for: next)) {
            task = urlSession.downloadTask(withResumeData: resume)
            Haptic.medium()
        } else {
            task = urlSession.downloadTask(with: url)
            Haptic.light()
        }
        // 委托方法是非隔离的，只能从任务本身认回是哪个部件——不能读 MainActor 上的 activePart。
        task.taskDescription = next.id
        downloadTask = task
        task.resume()
    }

    /// 暂停当前部件并保留断点，链条同时停下；再点下载会从未完成的部件接着排队。
    public func pauseDownload() {
        guard isDownloading, let task = downloadTask else { return }
        queuedParts = []
        // 部件在暂停那一刻就定下来：取消回调是异步的，等它回来时 activePart 可能已经换成下一件，
        // 那时再取就会把续传数据写错部件。
        let pausedPart = activePart
        task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self, let part = pausedPart else { return }
                // 暂停后用户可能立刻点了「放弃进度」或「整包删除」（那时 activePart 已清空）。
                // 不挡住它，取消回调会把续传数据又写回来，用户刚清掉的进度凭空复活。
                guard self.activePart?.id == part.id else { return }
                if let data = resumeData {
                    try? data.write(to: self.resumeDataURL(for: part), options: .atomic)
                    self.setState(for: part) { $0.hasResumeData = true }
                }
                self.isDownloading = false
                self.downloadSpeedMBps = 0
                Haptic.light()
            }
        }
        downloadTask = nil
    }

    /// 放弃全部断点进度（不动已下载完成的部件文件）。
    public func discardProgress() {
        bundleEpoch += 1
        downloadTask?.cancel()
        downloadTask = nil
        queuedParts = []
        activePart = nil
        isDownloading = false
        downloadSpeedMBps = 0
        errorMessage = nil
        for part in parts {
            try? FileManager.default.removeItem(at: resumeDataURL(for: part))
            setState(for: part) {
                $0.downloadedBytes = 0
                $0.totalBytes = part.expectedSizeBytes
                $0.hasResumeData = false
            }
        }
        Haptic.warning()
    }

    /// 删除整个视觉包（两件一起删）：只留一半会让下一次「看着像已就绪，实则加载失败」。
    ///
    /// 引擎侧的视觉模型释放在 `VisionInferenceService` 接入时补（本批只到引擎层），
    /// 这里不去调聊天模型的 `unloadLocalModel()`——删视觉包不该把用户正在用的对话模型卸载掉。
    public func deleteBundle() {
        bundleEpoch += 1
        downloadTask?.cancel()
        downloadTask = nil
        queuedParts = []
        activePart = nil
        isDownloading = false
        downloadSpeedMBps = 0
        for part in parts {
            try? FileManager.default.removeItem(at: partURL(for: part))
            try? FileManager.default.removeItem(at: resumeDataURL(for: part))
            UserDefaults.standard.removeObject(forKey: digestKey(for: part))
            UserDefaults.standard.removeObject(forKey: "\(digestKey(for: part))_mtime")
            UserDefaults.standard.removeObject(forKey: "\(digestKey(for: part))_size")
            setState(for: part) {
                $0.validation = .noModelFile
                $0.sizeOnDiskBytes = 0
                $0.verifiedReleaseVersion = nil
                $0.downloadedBytes = 0
                $0.totalBytes = part.expectedSizeBytes
                $0.hasResumeData = false
            }
        }
        errorMessage = nil
        Haptic.warning()
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
            guard downloadTask === self.downloadTask, let part = self.activePart else { return }
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : part.expectedSizeBytes
            self.setState(for: part) {
                $0.downloadedBytes = totalBytesWritten
                $0.totalBytes = expected
            }
            let interval = Date.now.timeIntervalSince(self.lastSpeedCheckTime)
            if interval >= 0.5 {
                self.downloadSpeedMBps = Double(totalBytesWritten - self.lastSpeedBytes) / 1024 / 1024 / interval
                self.lastSpeedCheckTime = .now
                self.lastSpeedBytes = totalBytesWritten
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 非 2xx 时临时文件是错误页而不是模型二进制；先拦掉，免得后面报一串看不懂的校验错。
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            Task { @MainActor in
                self.stopWithError(L10n.choose(
                    "下载失败：HTTP \(response.statusCode)（资源未找到或暂时不可用）",
                    "Download failed: HTTP \(response.statusCode) (resource not found or unavailable)"
                ))
            }
            return
        }

        guard let partID = downloadTask.taskDescription else { return }
        // 按苹果规范，本方法返回后系统立刻清除临时文件，必须在这里同步移进沙盒。
        let targetDir = URL.documentsDirectory.appendingPathComponent("Models", isDirectory: true)
        let candidate = targetDir.appendingPathComponent(UUID().uuidString + ".pending")
        var moveError: Error?
        do {
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dirURL = targetDir
            try? dirURL.setResourceValues(values)
            do {
                try FileManager.default.moveItem(at: location, to: candidate)
            } catch {
                try FileManager.default.copyItem(at: location, to: candidate)
                try? FileManager.default.removeItem(at: location)
            }
        } catch {
            moveError = error
        }

        if let moveError {
            Task { @MainActor in
                self.stopWithError(L10n.choose(
                    "保存模型文件失败：\(moveError.localizedDescription)",
                    "Failed to save the model file: \(moveError.localizedDescription)"
                ))
            }
            return
        }

        Task { @MainActor in
            guard let part = self.part(id: partID) else {
                self.stopWithError(L10n.choose("未知的模型部件。", "Unknown model part."))
                return
            }
            // 下载期间用户可能整包删掉了：代次对不上就别把文件装回去。
            let epoch = self.bundleEpoch
            let minSize = part.minValidSizeBytes
            let releases = part.publishedReleases
            let result = await Task.detached(priority: .utility) {
                Result { try ModelFileValidation.validate(at: candidate, minSizeBytes: minSize, releases: releases) }
            }.value
            guard epoch == self.bundleEpoch else {
                try? FileManager.default.removeItem(at: candidate)
                return
            }
            self.completeDownloadedPart(candidate: candidate, part: part, validation: result)
        }
    }

    private func completeDownloadedPart(
        candidate: URL,
        part: VisionModelPart,
        validation: Result<ModelFileValidation.Validated, Error>
    ) {
        defer { try? FileManager.default.removeItem(at: candidate) }
        endActivePart()
        let target = partURL(for: part)
        do {
            let validated = try validation.get()
            // 同部件覆盖旧文件：先挪走旧的再放新的，中途失败把旧的还原回去。
            let backup = modelsDirectory.appendingPathComponent(UUID().uuidString + ".previous")
            let hadOld = FileManager.default.fileExists(atPath: target.path)
            if hadOld { try FileManager.default.moveItem(at: target, to: backup) }
            do {
                try FileManager.default.moveItem(at: candidate, to: target)
            } catch {
                if hadOld { try? FileManager.default.moveItem(at: backup, to: target) }
                throw error
            }
            if hadOld { try? FileManager.default.removeItem(at: backup) }
            UserDefaults.standard.set(validated.digest, forKey: digestKey(for: part))
            UserDefaults.standard.set(validated.size, forKey: "\(digestKey(for: part))_size")
            let modTime = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            UserDefaults.standard.set(modTime, forKey: "\(digestKey(for: part))_mtime")
            try? FileManager.default.removeItem(at: resumeDataURL(for: part))
            setState(for: part) {
                $0.validation = .validated
                $0.sizeOnDiskBytes = validated.size
                $0.downloadedBytes = validated.size
                $0.totalBytes = validated.size
                $0.verifiedReleaseVersion = ModelFileValidation.releaseVersionText(validated.verdict)
                $0.hasResumeData = false
            }
            errorMessage = nil
            Haptic.success()
            // 队列里还有下一件就接着下，用户不必逐件点。
            startNextQueuedPart()
        } catch {
            setState(for: part) { $0.verifiedReleaseVersion = nil }
            markFailed(
                part,
                L10n.choose(
                    "部件「\(part.displayName)」校验失败：\(error.localizedDescription)",
                    "The \"\(part.displayName)\" part failed verification: \(error.localizedDescription)"
                )
            )
            // 一件失败就不再往下下：继续下第二件只会得到「一半可用」的包。
            queuedParts = []
            isDownloading = false
            downloadSpeedMBps = 0
            Haptic.error()
        }
    }

    private func stopWithError(_ message: String) {
        errorMessage = message
        queuedParts = []
        endActivePart()
        Haptic.error()
    }

    private func endActivePart() {
        activePart = nil
        downloadTask = nil
        if queuedParts.isEmpty {
            isDownloading = false
            downloadSpeedMBps = 0
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error as NSError? else { return }
        Task { @MainActor in
            // 部件身份取自任务本身：`activePart` 会在下一件开始时被换掉，
            // 拿它写续传数据会把上一件的字节写进下一件的续传文件里。
            let part = task.taskDescription.flatMap { self.part(id: $0) }
            // 只接当前正在下的那件：用户点「放弃进度」或「整包删除」后 activePart 已清空，
            // 但取消回调仍会带着续传数据回来——不挡住它就把刚清掉的进度又写回磁盘。
            if let part, self.activePart?.id == part.id,
               let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? resume.write(to: self.resumeDataURL(for: part), options: .atomic)
                self.setState(for: part) { $0.hasResumeData = true }
            }
            // 主动暂停/重开会走这条，进度已由上面的续传数据接住，不当成失败播报。
            guard error.code != NSURLErrorCancelled else { return }
            guard self.isDownloading else { return }
            self.stopWithError(self.hasAnyResumeData
                ? L10n.choose(
                    "下载中断：\(error.localizedDescription)（已保留当前进度，点击可续传）",
                    "Download interrupted: \(error.localizedDescription). Progress is kept — tap to resume."
                )
                : L10n.choose(
                    "下载失败：\(error.localizedDescription)",
                    "Download failed: \(error.localizedDescription)"
                ))
        }
    }
}
