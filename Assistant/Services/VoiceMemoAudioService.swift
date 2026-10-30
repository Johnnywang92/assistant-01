import AVFoundation
import Foundation
import Speech

/// 语音备忘录音频服务：录音（带实时电平）、回放（倍速/拖动/快进退）、离线整段转写。
/// 与 VoiceDialogueService 互斥：开始录音前会停止对话拾音与朗读；录音期间对话服务拒绝开麦。
@MainActor
final class VoiceMemoAudioService: NSObject, ObservableObject {
    static let shared = VoiceMemoAudioService()

    // MARK: 录音状态
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    /// 最近一段电平采样（0~1），用于绘制实时波形
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0.05, count: 48)

    // MARK: 回放状态
    @Published private(set) var playingFileName: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0 {
        didSet { player?.rate = playbackRate }
    }

    // MARK: 转写状态
    @Published private(set) var transcribingIDs: Set<UUID> = []

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
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

        try await VoiceMemoAudioSession.activate(
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
        let rec = try AVAudioRecorder(url: VoiceMemoStorage.url(for: fileName), settings: settings)
        rec.isMeteringEnabled = true
        rec.delegate = self
        guard rec.record() else {
            throw VoiceMemoError.recordFailed
        }

        recorder = rec
        currentRecordingFile = fileName
        isRecording = true
        isPaused = false
        recordingDuration = 0
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
        await VoiceMemoAudioSession.reactivate()
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
        VoiceMemoAudioSession.deactivateInBackground()
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
        guard !isRecording else { return }
        stopPlayback()
        let generation = playbackGeneration
        VoiceDialogueService.shared.stopSpeaking()
        do {
            await activatePlaybackSession()
            guard generation == playbackGeneration, !isRecording else { return }
            let p = try AVAudioPlayer(contentsOf: VoiceMemoStorage.url(for: fileName))
            p.enableRate = true
            p.rate = playbackRate
            p.delegate = self
            p.prepareToPlay()
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
        if let p = try? AVAudioPlayer(contentsOf: VoiceMemoStorage.url(for: fileName)) {
            stopPlayback()
            p.enableRate = true
            p.rate = playbackRate
            p.delegate = self
            p.prepareToPlay()
            player = p
            playingFileName = fileName
            playbackDuration = p.duration
            playbackTime = 0
            isPlaying = false
        }
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
        playbackGeneration &+= 1
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        playingFileName = nil
        isPlaying = false
        playbackTime = 0
        playbackDuration = 0
    }

    private func activatePlaybackSession() async {
        try? await VoiceMemoAudioSession.activate(category: .playback, mode: .spokenAudio)
    }

    // MARK: - 离线整段转写

    func isTranscribing(_ memo: VoiceMemo) -> Bool {
        transcribingIDs.contains(memo.id)
    }

    /// 离线转写音频文件（优先端侧识别，不上传网络）
    func transcribe(memo: VoiceMemo) async throws -> String {
        guard !transcribingIDs.contains(memo.id) else { throw VoiceMemoError.busy }
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

        transcribingIDs.insert(memo.id)
        defer { transcribingIDs.remove(memo.id) }

        let request = SFSpeechURLRecognitionRequest(url: memo.audioURL)
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
            if self.isRecording { self.pauseRecording() }
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

// MARK: - 音频会话

/// 会话的设置、激活与停用都可能阻塞调用线程（挂起报告里被点名的是主线程调用），
/// 统一挪到专用串行队列：既不卡 UI，串行又能保证「停用录音 → 马上播放」时不会乱序。
private enum VoiceMemoAudioSession {
    private static let queue = DispatchQueue(label: "com.yifanwang.assistant01.audio-session", qos: .userInitiated)

    /// 设置分类并激活；返回时会话已就绪
    static func activate(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions = []
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(category, mode: mode, options: options)
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 按当前分类重新激活（暂停后恢复录音）
    static func reactivate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                try? AVAudioSession.sharedInstance().setActive(true)
                continuation.resume()
            }
        }
    }

    /// 结束录音后的停用不需要调用方等待，排队执行即可
    static func deactivateInBackground() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
