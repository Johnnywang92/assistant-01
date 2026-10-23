import AVFoundation
import Foundation
import Speech

/// 离线语音对话管理服务（基于系统离线 ASR 与系统离线 TTS）
@MainActor
final class VoiceDialogueService: NSObject, ObservableObject {
    static let shared = VoiceDialogueService()

    private let zhRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let enRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var speechRecognizer: SFSpeechRecognizer? {
        L10n.isEnglish ? (enRecognizer ?? zhRecognizer) : (zhRecognizer ?? enRecognizer)
    }
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var isTapInstalled = false

    @Published public var isListening = false
    @Published public var isSpeaking = false
    @Published public var recognizedText = ""
    @Published public var lastAssistantReply = ""
    @Published public var errorMessage: String?
    /// 实时麦克风音量强度（0...1），供语音聆听动画的声波条跳动使用
    @Published public var audioLevel: Float = 0

    private override init() {
        super.init()
        zhRecognizer?.delegate = self
        enRecognizer?.delegate = self
        synthesizer.delegate = self
    }

    /// 请求语音识别与麦克风权限
    public func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        let micAuth: Bool
        if #available(iOS 17.0, *) {
            micAuth = await AVAudioApplication.requestRecordPermission()
        } else {
            micAuth = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        return speechAuth && micAuth
    }

    /// 开始离线录音与语音识别
    public func startListening() throws {
        // 与语音备忘录互斥：录制中不抢占麦克风；回放中先停止
        if VoiceMemoAudioService.shared.isRecording {
            throw VoiceError.memoRecordingInProgress
        }
        VoiceMemoAudioService.shared.stopPlayback()

        stopListening()
        stopSpeaking()
        errorMessage = nil
        recognizedText = ""

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw VoiceError.recognizerUnavailable
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw VoiceError.requestCreationFailed
        }

        // 强行指定：要求离线设备端识别（完全不联网）
        if recognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        if isTapInstalled {
            inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let request = recognitionRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            let rms = Self.computeRMS(buffer)
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                let target = min(1.0, rms * 9.0)
                self.audioLevel = self.audioLevel * 0.55 + target * 0.45
            }
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            if isTapInstalled {
                inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            self.recognitionRequest = nil
            throw error
        }

        isListening = true
        audioLevel = 0

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let transcript {
                    self.recognizedText = transcript
                }
                if hasError || isFinal {
                    self.stopListening()
                }
            }
        }
    }

    /// 停止录音
    public func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
        audioLevel = 0
    }

    /// 离线朗读语音回答 (TTS)
    public func speak(text: String) {
        guard AppSettings.voiceReplyEnabled else { return }
        guard AppSettings.currentMode != .quiet else { return }

        stopSpeaking()
        lastAssistantReply = text

        let utterance = AVSpeechUtterance(string: text)
        let containsCJK = text.range(of: "\\p{Han}", options: .regularExpression) != nil
        let voiceLang = (L10n.isEnglish && !containsCJK) ? "en-US" : "zh-CN"
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLang)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    /// 计算音频缓冲的 RMS 均方根能量，作为麦克风音量大小的近似度量
    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        return sqrt(sum / Float(frames))
    }
}

// MARK: - AVSpeechSynthesizerDelegate & SFSpeechRecognizerDelegate
extension VoiceDialogueService: SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
}

public enum VoiceError: LocalizedError {
    case recognizerUnavailable
    case requestCreationFailed
    case memoRecordingInProgress

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return L10n.tr("当前离线语音识别器不可用")
        case .requestCreationFailed:
            return L10n.tr("创建语音请求失败")
        case .memoRecordingInProgress:
            return L10n.tr("正在录制语音备忘，请先结束录制")
        }
    }
}
