import AVFoundation
import Foundation
import Speech

/// 「有一条备忘的录音被中断了」的恢复标记。
///
/// 只记录**已经落库**的备忘 ID：中断时正在写的那一段没有保存，不承诺能找回；
/// 恢复卡说的是「前几段都还在，可以接着录下一段」，这才是真实状态。
/// 用 UserDefaults 持久化，App 重启后目标备忘仍在，标记就不会变成谎话。
struct VoiceMemoResumeMarker: Codable, Equatable, Sendable {
    let memoID: UUID
    let interruptedAt: Date
}

/// 隔离非 Sendable 的 AVFoundation 对象的线程传递封装，用于避开 iOS 26/27 之前系统缺少 Sendable 声明的编译限制
private final class AudioUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

/// 语音备忘录音频服务：录音（带实时电平）、回放（倍速/拖动/快进退）、离线整段转写。
/// 与 VoiceDialogueService 互斥：开始录音前会停止对话拾音与朗读；录音期间对话服务拒绝开麦。
@MainActor
final class VoiceMemoAudioService: NSObject, ObservableObject {
    static let shared = VoiceMemoAudioService()

    private static let resumeMarkerKey = "voice_memo_pending_resume_marker"

    // MARK: 录音状态
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    /// 本次录音被系统（来电等）中断过，录音页据此提示「这一段可以收进原备忘」。
    @Published private(set) var wasInterruptedBySystem = false
    /// 续录时的目标备忘；nil = 新建一条备忘。
    var recordingTargetMemoID: UUID?
    /// 有待续录的备忘。列表页与详情页据此显示恢复卡；收尾或明确放弃后清空。
    @Published private(set) var pendingResume: VoiceMemoResumeMarker?
    /// 最近一段电平采样（0~1），用于绘制实时波形
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0.05, count: 48)

    // MARK: 回放状态
    @Published private(set) var playingFileName: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    /// 合并播放时待播的后续片段文件名。空 = 单段播放。
    @Published private(set) var playbackQueue: [String] = []
    @Published var playbackRate: Float = 1.0 {
        didSet { player?.rate = playbackRate }
    }

    // MARK: 转写状态
    /// 以音频文件名为去重键：续录后可以只转写新增的那一段。
    @Published private(set) var transcribingFileNames: Set<String> = []

    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var currentRecordingFile: String?
    private var meterTimer: Timer?
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    /// 激活会话是异步的：期间可能被 stopPlayback（离开页面、语音对话插话）打断，
    /// 用它判断这次播放请求是否已经作废，避免播放器没人持有却还在响
    private var playbackGeneration = 0

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.resumeMarkerKey),
           let marker = try? JSONDecoder().decode(VoiceMemoResumeMarker.self, from: data) {
            pendingResume = marker
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // MARK: - 中断恢复标记

    /// 续录被系统中断时记录目标备忘。**新建录音不写标记**：
    /// 那时还没有任何片段落库，显示「内容已保留」会是虚假承诺。
    func markPendingResume(memoID: UUID) {
        let marker = VoiceMemoResumeMarker(memoID: memoID, interruptedAt: .now)
        pendingResume = marker
        if let data = try? JSONEncoder().encode(marker) {
            UserDefaults.standard.set(data, forKey: Self.resumeMarkerKey)
        }
    }

    /// 收尾成功、用户明确放弃或点「以后再说」后清掉标记。
    func clearPendingResume() {
        pendingResume = nil
        UserDefaults.standard.removeObject(forKey: Self.resumeMarkerKey)
    }

    // MARK: - 权限

    func requestMicPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    // MARK: - 录音

    func startRecording() async throws {
        guard !isRecording else { return }
        // 与语音对话互斥
        VoiceDialogueService.shared.stopListening()
        VoiceDialogueService.shared.stopSpeaking()
        stopPlayback()
        errorMessage = nil

        try await AudioSessionConfigurator.activate(
            category: .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        // 激活期间录音页可能已被关掉（.task 随之取消），别再开一个没人管的录音
        guard !Task.isCancelled else { return }

        let fileName = VoiceMemoStorage.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let url = VoiceMemoStorage.url(for: fileName)
        // 录音器初始化与 record() 涉及同步 XPC 握手，移至后台任务避免阻塞主线程（AVAudioSession Hang Risk）
        let box = try await Task.detached(priority: .userInitiated) { () -> AudioUncheckedBox<AVAudioRecorder> in
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                throw VoiceMemoError.recordFailed
            }
            return AudioUncheckedBox(r)
        }.value
        let rec = box.value
        guard !Task.isCancelled else {
            rec.stop()
            VoiceMemoStorage.delete(fileName)
            return
        }
        rec.delegate = self

        recorder = rec
        currentRecordingFile = fileName
        isRecording = true
        isPaused = false
        recordingDuration = 0
        wasInterruptedBySystem = false
        levels = Array(repeating: 0.05, count: levels.count)
        startMeterTimer()
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
    }

    func resumeRecording() async {
        guard isRecording, isPaused else { return }
        await AudioSessionConfigurator.reactivate()
        recorder?.record()
        isPaused = false
    }

    /// 结束录音，返回音频文件名与时长；时长过短（<1 秒）则丢弃并返回 nil
    @discardableResult
    func finishRecording() -> (fileName: String, duration: TimeInterval)? {
        guard isRecording, let rec = recorder, let fileName = currentRecordingFile else { return nil }
        let duration = rec.currentTime
        rec.stop()
        resetRecordingState()

        // 以文件实际时长为准
        let realDuration = (try? AVAudioPlayer(contentsOf: VoiceMemoStorage.url(for: fileName)).duration) ?? duration
        if realDuration < 1 {
            VoiceMemoStorage.delete(fileName)
            return nil
        }
        return (fileName, realDuration)
    }

    func cancelRecording() {
        guard isRecording else { return }
        recorder?.stop()
        recorder?.deleteRecording()
        resetRecordingState()
    }

    private func resetRecordingState() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        currentRecordingFile = nil
        isRecording = false
        isPaused = false
        // 无论「完成收尾」还是「明确放弃」，这次中断都算处理完了。
        // 同时清掉目标 ID：否则下一次「新建录音」被中断会误把恢复卡挂到上一条备忘上。
        clearPendingResume()
        recordingTargetMemoID = nil
        AudioSessionConfigurator.deactivateInBackground()
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleMeter() }
        }
    }

    private func sampleMeter() {
        guard let rec = recorder, isRecording else { return }
        recordingDuration = rec.currentTime
        var level: CGFloat = 0.03
        if !isPaused {
            rec.updateMeters()
            let db = rec.averagePower(forChannel: 0) // -160 ~ 0
            level = CGFloat(max(0.03, min(1, pow(10, db / 40))))
        }
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: - 回放

    func togglePlayback(fileName: String) async {
        if playingFileName == fileName, let p = player {
            if p.isPlaying {
                p.pause()
                isPlaying = false
                playbackTime = p.currentTime
                playbackTimer?.invalidate()
                playbackTimer = nil
            } else {
                let generation = playbackGeneration
                await activatePlaybackSession()
                guard generation == playbackGeneration, player === p else { return }
                p.play()
                isPlaying = true
                playbackTime = p.currentTime
                // 预加载只建 player 不建计时器：恢复播放必须在这里补上
                startPlaybackTimer()
            }
            return
        }
        await play(fileName: fileName)
    }

    func play(fileName: String) async {
        playbackQueue = []
        await startPlaying(fileName: fileName)
    }

    /// 按录制顺序连续播放多个片段。每个片段是独立文件，
    /// 一段自然播完后由 `AVAudioPlayerDelegate` 接着播下一段。
    func playSequence(fileNames: [String]) async {
        guard let first = fileNames.first else { return }
        playbackQueue = Array(fileNames.dropFirst())
        await startPlaying(fileName: first)
    }

    private func startPlaying(fileName: String) async {
        guard !isRecording else {
            playbackQueue = []
            return
        }
        stopPlayback(preservingQueue: true)
        let generation = playbackGeneration
        VoiceDialogueService.shared.stopSpeaking()
        do {
            await activatePlaybackSession()
            guard generation == playbackGeneration, !isRecording else { return }
            let url = VoiceMemoStorage.url(for: fileName)
            let rate = playbackRate
            // 播放器构造与 prepareToPlay() 涉及音频解码器分配与硬件握手，移至后台任务避免卡顿主线程
            let box = try await Task.detached(priority: .userInitiated) { () -> AudioUncheckedBox<AVAudioPlayer> in
                let player = try AVAudioPlayer(contentsOf: url)
                player.enableRate = true
                player.rate = rate
                player.prepareToPlay()
                return AudioUncheckedBox(player)
            }.value
            guard generation == playbackGeneration, !isRecording else { return }
            let p = box.value
            p.delegate = self
            p.play()
            player = p
            playingFileName = fileName
            playbackDuration = p.duration
            playbackTime = 0
            isPlaying = true
            startPlaybackTimer()
        } catch {
            errorMessage = L10n.choose("音频文件无法播放：\(error.localizedDescription)", "Cannot play audio file: \(error.localizedDescription)")
        }
    }

    /// 进度计时器全局唯一：开始/恢复播放时重建，暂停与收尾时失效
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.playbackTime = p.currentTime
            }
        }
    }

    /// 为指定文件预加载时长（详情页打开时未播放也能显示进度条）
    func prepare(fileName: String) {
        guard playingFileName != fileName else { return }
        let url = VoiceMemoStorage.url(for: fileName)
        let rate = playbackRate
        let generation = playbackGeneration
        // 移至后台任务异步加载解码，防止进入详情页时在主线程触发 AVAudioSession Hang
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.enableRate = true
            p.rate = rate
            p.prepareToPlay()
            let duration = p.duration
            let box = AudioUncheckedBox(p)
            await self?.finishPreparing(box: box, fileName: fileName, duration: duration, generation: generation)
        }
    }

    private func finishPreparing(box: AudioUncheckedBox<AVAudioPlayer>, fileName: String, duration: TimeInterval, generation: Int) {
        guard generation == playbackGeneration, !isPlaying else { return }
        stopPlayback(preservingQueue: false)
        let p = box.value
        p.delegate = self
        player = p
        playingFileName = fileName
        playbackDuration = duration
        playbackTime = 0
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        playbackTime = p.currentTime
    }

    func skip(by delta: TimeInterval) {
        // 以 player 的实际播放位置为基准：playbackTime 最多滞后一个计时周期，
        // 连续快进时会越跳越偏
        seek(to: (player?.currentTime ?? playbackTime) + delta)
    }

    func stopPlayback() {
        stopPlayback(preservingQueue: false)
    }

    /// `preservingQueue: true` 只用于串播换段：不能把待播的后继片段一起清掉。
    private func stopPlayback(preservingQueue: Bool) {
        playbackGeneration &+= 1
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        playingFileName = nil
        isPlaying = false
        playbackTime = 0
        playbackDuration = 0
        if !preservingQueue { playbackQueue = [] }
    }

    private func activatePlaybackSession() async {
        try? await AudioSessionConfigurator.activate(category: .playback, mode: .spokenAudio)
    }

    // MARK: - 离线整段转写

    func isTranscribing(_ memo: VoiceMemo) -> Bool {
        transcribingFileNames.contains(memo.audioFileName)
    }

    /// 整条备忘的离线转写入口（读第一段，兼容旧调用）。
    func transcribe(memo: VoiceMemo) async throws -> String {
        try await transcribe(fileName: memo.audioFileName)
    }

    /// 离线转写指定音频文件（续录时只转新段，不重复转已有内容，不上传网络）。
    func transcribe(fileName: String) async throws -> String {
        guard !transcribingFileNames.contains(fileName) else { throw VoiceMemoError.busy }
        guard await requestSpeechPermission() else { throw VoiceMemoError.speechDenied }
        let primaryRecognizer = SFSpeechRecognizer(locale: Locale(identifier: L10n.speechLocaleIdentifier))
        let fallbackRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer = (primaryRecognizer?.isAvailable == true ? primaryRecognizer : fallbackRecognizer),
              recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceMemoError.onDeviceUnsupported
        }

        transcribingFileNames.insert(fileName)
        defer { transcribingFileNames.remove(fileName) }

        let request = SFSpeechURLRecognitionRequest(url: VoiceMemoStorage.url(for: fileName))
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    // 静音/无语音时系统返回错误，视为空文本
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                        cont.resume(returning: "")
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - 中断处理（来电等）

    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .began else { return }
        Task { @MainActor in
            if self.isRecording {
                // 不在这里 finish 落库：来电/切后台时页面状态与后台写库都不可靠，
                // 只暂停并标记，用户回来点「完成」即可把这一段收进同一条备忘，
                // 也不会留下没人引用的孤儿音频。
                self.wasInterruptedBySystem = true
                self.pauseRecording()
                // 只有续录（已有落库片段）才登记恢复卡；新建录音没有任何可恢复内容。
                if let targetID = self.recordingTargetMemoID {
                    self.markPendingResume(memoID: targetID)
                }
            }
            if self.isPlaying {
                self.player?.pause()
                self.isPlaying = false
                // 被来电等中断时同时停表，恢复播放会重建
                self.playbackTimer?.invalidate()
                self.playbackTimer = nil
            }
        }
    }
}

// MARK: - Delegates

extension VoiceMemoAudioService: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // 自然播完要停表并释放 player：单例里遗留的重复计时器会以 5Hz 空转整个进程生命周期，
            // 同时把解码后的音频缓冲一直留在内存里。
            self.playbackTimer?.invalidate()
            self.playbackTimer = nil
            self.player = nil
            self.isPlaying = false
            self.playbackTime = 0

            // 合并播放：还有后继片段就接着播，解码失败则停下避免连着报错。
            if !flag { self.playbackQueue = [] }
            if let next = self.playbackQueue.first {
                self.playbackQueue = Array(self.playbackQueue.dropFirst())
                await self.startPlaying(fileName: next)
            } else {
                self.playingFileName = nil
                self.playbackDuration = 0
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.errorMessage = L10n.choose(
                "录音编码出错：\(error?.localizedDescription ?? "未知错误")",
                "Recording encoding error: \(error?.localizedDescription ?? "Unknown error")"
            )
        }
    }
}

enum VoiceMemoError: LocalizedError {
    case recordFailed
    case speechDenied
    case onDeviceUnsupported
    case busy
    case micDenied

    var errorDescription: String? {
        switch self {
        case .recordFailed: return L10n.tr("无法开始录音，请检查麦克风是否被其他应用占用")
        case .speechDenied: return L10n.tr("未获得语音识别权限，请在系统设置中开启")
        case .onDeviceUnsupported: return L10n.tr("当前设备不支持离线中文识别，请在 设置 › 通用 › 键盘 中开启听写并下载中文语音包")
        case .busy: return L10n.tr("该备忘正在转写中")
        case .micDenied: return L10n.tr("未获得麦克风权限，请在系统设置中开启")
        }
    }
}

// MARK: - 文本分析（规则提炼要点 / 待办候选）

enum VoiceMemoTextAnalyzer {
    /// 按中英文标点切句
    static func sentences(from text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?；;\n.".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !s.isEmpty { result.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if !tail.isEmpty { result.append(tail) }
        // 无标点的长句按逗号再切
        if result.count == 1, let only = result.first, only.count > 40 {
            return only.split(whereSeparator: { "，,".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return result
    }

    private static let actionKeywords = [
        "要", "需要", "记得", "别忘", "提醒", "得去", "去买", "买", "交", "约", "联系", "打电话",
        "预约", "确认", "完成", "提交", "安排", "准备", "明天", "后天", "下周", "今晚", "周一", "周二",
        "周三", "周四", "周五", "周六", "周日", "点前", "之前", "截止",
        "need to", "remember", "don't forget", "remind", "buy", "pay", "call", "contact",
        "schedule", "book", "confirm", "finish", "submit", "prepare", "tomorrow", "tonight",
        "next week", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "before", "deadline", "due"
    ]

    /// 是否像一条待办
    static func looksLikeTodo(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        return sentence.count >= 4 && sentence.count <= 100 && actionKeywords.contains { lower.contains($0) }
    }

    static func todoCandidates(from text: String) -> [String] {
        sentences(from: text).filter(looksLikeTodo)
    }

    /// 规则提炼要点：优先含行动/时间关键词的句子，其次最长的信息句，最多 5 条
    static func summarize(_ text: String) -> String {
        let all = sentences(from: text)
        guard !all.isEmpty else { return "" }
        var picked = all.filter(looksLikeTodo)
        if picked.count < 3 {
            let rest = all.filter { !picked.contains($0) && $0.count >= 6 }.sorted { $0.count > $1.count }
            picked.append(contentsOf: rest.prefix(3 - picked.count))
        }
        // 保持原文顺序
        let ordered = all.filter { picked.contains($0) }.prefix(5)
        return ordered.map { "• \($0)" }.joined(separator: "\n")
    }

    /// 由转写首句生成标题
    static func suggestedTitle(from text: String) -> String? {
        guard let first = sentences(from: text).first, first.count >= 2 else { return nil }
        return first.count > 18 ? String(first.prefix(18)) + "…" : first
    }
}
