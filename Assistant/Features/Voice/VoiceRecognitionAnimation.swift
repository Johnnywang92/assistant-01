import SwiftUI

/// 语音识别三阶段状态机：
/// - listening：聆听中（麦克风向外扩散波纹 + 声波条随音量跳动）
/// - recognizing：识别中（声波条回落变淡 + 三个小点依次跳动）
/// - result：识别结果（文字逐字打出 + 闪烁光标）
/// - idle：无动画（默认态）
enum VoiceVisualPhase: Equatable {
    case idle
    case listening
    case recognizing
    case result
}

// MARK: - 麦克风 + 向外扩散波纹

struct MicPulseView: View {
    var active: Bool
    var tint: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 1.8 + Double(i) / 3.0).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(tint.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 56, height: 56)
                        .scaleEffect(0.8 + 1.1 * p)
                        .opacity(active ? (1 - p) * 0.9 : 0)
                }
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "mic.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
            }
            .animation(.easeOut(duration: 0.3), value: active)
        }
    }
}

// MARK: - 声波条（随音量大小跳动；识别阶段回落变淡）

struct WaveformView: View {
    /// 当前麦克风音量强度，0...1
    var level: CGFloat
    /// 是否处于「识别中/结果」阶段：true 时声波条回落并淡出
    var reduced: Bool
    /// 阶段切换时间戳，用于平滑过渡
    var changedAt: Date
    var tint: Color

    private let barCount = 41
    private let barWidth: CGFloat = 4
    private let spacing: CGFloat = 4

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = context.date
                let elapsed = now.timeIntervalSince(changedAt)
                let mix = 1 - exp(-max(0, elapsed) * 5)

                let eff: CGFloat
                let opacity: CGFloat
                if reduced {
                    // 回落：从当前音量缓动到极低的平直线，并整体淡出
                    eff = level * (1 - mix) + 0.05 * mix
                    opacity = (1 - mix) * 0.85 + 0.12
                } else {
                    eff = max(0.06, level)
                    opacity = 1.0
                }

                let t = now.timeIntervalSinceReferenceDate
                let totalW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
                let startX = (size.width - totalW) / 2

                for i in 0..<barCount {
                    let d = (Double(i) - Double(barCount - 1) / 2) / (Double(barCount - 1) / 2)
                    let envelope = exp(-d * d * 2.2)
                    let n = 0.5 + 0.5 * sin(t * 6 + Double(i) * 0.9) * sin(t * 3.1 + Double(i) * 0.35)
                    let h = max(4, 6 + 58 * eff * envelope * (0.25 + 0.75 * n))
                    let rect = CGRect(
                        x: startX + CGFloat(i) * (barWidth + spacing),
                        y: (size.height - h) / 2,
                        width: barWidth,
                        height: h
                    )
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(tint.opacity(opacity))
                    )
                }
            }
        }
    }
}

// MARK: - 识别中的三个跳动点

struct ThinkingDotsView: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let s = (sin((t - Double(i) * 0.15) * 2 * .pi) + 1) / 2
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(active ? 0.25 + 0.75 * s : 0.2)
                        .offset(y: active ? -4 * s : 0)
                }
            }
        }
    }
}

// MARK: - 闪烁光标

struct BlinkingCursor: View {
    var tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0
            Rectangle()
                .fill(tint)
                .frame(width: 2, height: 18)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - 三阶段可视化容器（真实语音交互集成用）

struct VoiceListeningVisualizer: View {
    let phase: VoiceVisualPhase
    let level: CGFloat
    let changedAt: Date
    /// 聆听中实时流式识别文本（由 SFSpeechRecognizer 持续推送）
    var liveText: String = ""
    /// 识别结果阶段逐字打出的最终文本
    var resultText: String = ""
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 16) {
            MicPulseView(active: phase == .listening, tint: tint)
                .frame(width: 92, height: 92)

            WaveformView(level: level, reduced: phase != .listening, changedAt: changedAt, tint: tint)
                .frame(height: 56)
                .padding(.horizontal, 24)

            // 识别中显示三个跳动点；其它阶段保留同高避免布局跳动
            ZStack {
                if phase == .recognizing {
                    ThinkingDotsView(active: true)
                }
            }
            .frame(height: 18)

            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // 实时转写：聆听中同步显示流式识别文本（次要色），
            // 识别结果阶段再将最终文本逐字打出（主色 + 光标）
            HStack(spacing: 2) {
                Text(displayText)
                    .font(phase == .result ? .title3.weight(.medium) : .callout)
                    .foregroundStyle(phase == .result ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.18), value: displayText)
                if phase == .result {
                    BlinkingCursor(tint: tint)
                }
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 24)
        }
    }

    private var statusText: String {
        switch phase {
        case .idle: return ""
        case .listening: return "聆听中…"
        case .recognizing: return "识别中…"
        case .result: return "识别结果"
        }
    }

    private var displayText: String {
        switch phase {
        case .listening: return liveText
        case .result: return resultText
        default: return ""
        }
    }
}

// MARK: - 独立演示（可在 Xcode 画布中预览完整三阶段循环）

struct VoiceRecognitionView: View {
    var phrases: [String] = ["你好，小助", "今天吃什么对肠道好", "帮我看看检测报告"]
    var tint: Color = .accentColor

    @State private var phase: VoiceVisualPhase = .listening
    @State private var phaseChangedAt = Date()
    @State private var text = ""

    private var syntheticLevel: CGFloat {
        let t = Date().timeIntervalSinceReferenceDate
        return CGFloat(0.55 + 0.45 * sin(t * 2.3) * sin(t * 0.7))
    }

    var body: some View {
        VoiceListeningVisualizer(
            phase: phase,
            level: syntheticLevel,
            changedAt: phaseChangedAt,
            resultText: text,
            tint: tint
        )
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .task { await runLoop() }
    }

    private func setPhase(_ p: VoiceVisualPhase) {
        phase = p
        phaseChangedAt = Date()
    }

    private func runLoop() async {
        var index = 0
        while !Task.isCancelled {
            text = ""
            setPhase(.listening)
            try? await Task.sleep(for: .seconds(3.2))

            setPhase(.recognizing)
            try? await Task.sleep(for: .seconds(1.5))

            setPhase(.result)
            let phrase = phrases[index % phrases.count]
            for ch in phrase {
                text.append(ch)
                try? await Task.sleep(for: .milliseconds(110))
            }
            index += 1
            try? await Task.sleep(for: .seconds(2.2))
        }
    }
}

#Preview {
    VoiceRecognitionView()
        .frame(width: 360)
}
