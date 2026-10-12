import AVFoundation
import Foundation
import SwiftUI

/// 长辈大字字号级别
public enum SeniorFontScale: String, CaseIterable, Identifiable, Codable {
    case large = "适度大字"
    case extraLarge = "超大清晰字"
    case huge = "特大长辈字"

    public var id: String { rawValue }

    public var title: String { L10n.tr(rawValue) }

    public var description: String {
        switch self {
        case .large:
            return L10n.tr("适合日常视力稍弱或老花眼初期的长辈，整体放大约 35%")
        case .extraLarge:
            return L10n.tr("推荐模式！文字突出饱满，字号放大约 60%，阅读轻松无压力")
        case .huge:
            return L10n.tr("极致大字！文字放大超 100%，图标与按钮同步加宽，超大对比度")
        }
    }

    public var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .large:
            return .xxxLarge
        case .extraLarge:
            return .accessibility1
        case .huge:
            return .accessibility3
        }
    }

    public var fontScaleFactor: CGFloat {
        switch self {
        case .large: return 1.3
        case .extraLarge: return 1.55
        case .huge: return 1.95
        }
    }
}

/// 老年人关怀模式全局管理引擎
@MainActor
public final class SeniorModeManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = SeniorModeManager()

    // MARK: - 用户偏好持久化 (AppStorage)
    @AppStorage("senior_mode_enabled") public var isSeniorModeEnabled: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }

    @AppStorage("senior_font_scale_level") public var fontScaleLevelRaw: String = SeniorFontScale.extraLarge.rawValue {
        didSet {
            objectWillChange.send()
        }
    }

    @AppStorage("senior_high_contrast") public var isHighContrastEnabled: Bool = true {
        didSet {
            objectWillChange.send()
        }
    }

    @AppStorage("senior_voice_broadcast") public var isVoiceBroadcastEnabled: Bool = true {
        didSet {
            objectWillChange.send()
        }
    }

    @AppStorage("senior_large_touch_targets") public var isLargeTouchTargetsEnabled: Bool = true {
        didSet {
            objectWillChange.send()
        }
    }

    public var fontScale: SeniorFontScale {
        get { SeniorFontScale(rawValue: fontScaleLevelRaw) ?? .extraLarge }
        set { fontScaleLevelRaw = newValue.rawValue }
    }

    /// 当前作用于应用全局的动态字号等级
    public var effectiveDynamicTypeSize: DynamicTypeSize? {
        guard isSeniorModeEnabled else { return nil }
        return fontScale.dynamicTypeSize
    }

    // MARK: - 专属大声语音播报 (TTS)
    private let synthesizer = AVSpeechSynthesizer()
    @Published public var isSpeaking: Bool = false
    @Published public var currentSpeakingId: String? = nil

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 以缓慢、清晰、沉稳的长辈友好语速大声朗读文本
    public func speakSenior(text: String, id: String? = nil) {
        stopSpeaking()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        currentSpeakingId = id
        isSpeaking = true

        let utterance = AVSpeechUtterance(string: trimmed)
        let containsCJK = trimmed.range(of: "\\p{Han}", options: .regularExpression) != nil
        let voiceLang = (L10n.isEnglish && !containsCJK) ? "en-US" : "zh-CN"
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLang)
        // 长辈语音语速调整为 0.44 (比常规 0.5 稍慢)，发音字正腔圆，更易听清
        utterance.rate = 0.44
        utterance.pitchMultiplier = 1.02
        utterance.volume = 1.0

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        synthesizer.speak(utterance)
    }

    /// 停止语音播报
    public func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        currentSpeakingId = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentSpeakingId = nil
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentSpeakingId = nil
        }
    }
}
