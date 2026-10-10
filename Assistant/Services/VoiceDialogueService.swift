import AVFoundation
import Foundation
import Speech

/// 离线语音对话管理服务（基于系统离线 ASR 与系统离线 TTS）
@MainActor
final class VoiceDialogueService: NSObject, ObservableObject {
    static let shared = VoiceDialogueService()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    @Published public var isListening = false
    @Published public var isSpeaking = false
    @Published public var recognizedText = ""
    @Published public var lastAssistantReply = ""
    @Published public var errorMessage: String?

    private override init() {
        super.init()
        speechRecognizer?.delegate = self
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
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                self.recognizedText = result.bestTranscription.formattedString
            }

            if error != nil || (result?.isFinal ?? false) {
                self.stopListening()
            }
        }
    }

    /// 停止录音
    public func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    /// 离线朗读语音回答 (TTS)
    public func speak(text: String) {
        guard AppSettings.voiceReplyEnabled else { return }
        guard AppSettings.currentMode != .quiet else { return }

        stopSpeaking()
        lastAssistantReply = text

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
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

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "当前离线语音识别器不可用"
        case .requestCreationFailed:
            return "创建语音请求失败"
        }
    }
}
