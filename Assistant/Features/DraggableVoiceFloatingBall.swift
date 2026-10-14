import SwiftUI

/// 可拖拽、自由吸附屏幕边缘的语音对话悬浮球（支持长按直启语音输入，单击展开面板，拖拽贴边）
struct DraggableVoiceFloatingBall: View {
    @Binding var showVoice: Bool
    @Binding var autoStartListening: Bool
    var onDirectVoiceConversation: (() -> Void)?

    // 是否开启悬浮球
    @AppStorage("floating_voice_enabled") private var isFloatingVoiceEnabled: Bool = true
    // 持久化存储归一化位置 (0.0=靠左, 1.0=靠右; y 范围 0.0~1.0)
    @AppStorage("floating_voice_norm_x") private var normX: Double = 1.0 // 默认靠右
    @AppStorage("floating_voice_norm_y") private var normY: Double = 0.68 // 默认在右下角，最利于单手大拇指触达

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    @State private var isLongPressing: Bool = false
    @ObservedObject private var memoAudio = VoiceMemoAudioService.shared
    @ObservedObject private var seniorManager = SeniorModeManager.shared

    private var ballSize: CGFloat {
        seniorManager.isSeniorModeEnabled ? 64 : 52
    }
    private let edgePadding: CGFloat = 12

    init(showVoice: Binding<Bool>, autoStartListening: Binding<Bool> = .constant(false), onDirectVoiceConversation: (() -> Void)? = nil) {
        self._showVoice = showVoice
        self._autoStartListening = autoStartListening
        self.onDirectVoiceConversation = onDirectVoiceConversation
    }

    var body: some View {
        // 语音备忘录制中隐藏悬浮球，避免麦克风被抢占
        if isFloatingVoiceEnabled && !memoAudio.isRecording {
            GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom
            let width = proxy.size.width
            let height = proxy.size.height

            // 安全活动边界（避开顶部刘海/灵动岛与底部 Tab 栏）
            let minX = edgePadding + ballSize / 2
            let maxX = width - edgePadding - ballSize / 2
            let minY = safeTop + ballSize / 2 + 12
            let maxY = height - safeBottom - 64 - ballSize / 2

            // 当前基准中心位置
            let baseX = minX + CGFloat(normX) * (maxX - minX)
            let baseY = minY + CGFloat(normY) * (maxY - minY)

            // 叠加拖拽位移后的当前临时坐标
            let currentX = min(max(baseX + dragOffset.width, minX), maxX)
            let currentY = min(max(baseY + dragOffset.height, minY), maxY)

            // 悬浮球主体 (移除 Button 避免拖动松手时触发点击事件)
            ZStack {
                // 长按过程中的外圈声波脉冲微光
                if isLongPressing {
                    Circle()
                        .stroke(Color.red.opacity(0.4), lineWidth: 4)
                        .frame(width: ballSize + 14, height: ballSize + 14)
                        .scaleEffect(1.15)
                }

                // 背景渐变与毛玻璃投影（长按时呈现拾音专属红橙色渐变）
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isLongPressing ? [Color.red, Color.orange] : [Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: ballSize, height: ballSize)
                    .shadow(
                        color: (isLongPressing ? Color.red : Color.indigo).opacity(isDragging || isLongPressing ? 0.55 : 0.3),
                        radius: isDragging || isLongPressing ? 12 : 8,
                        y: isDragging || isLongPressing ? 6 : 4
                    )

                // 动态微光光圈
                Circle()
                    .strokeBorder(Color.white.opacity(isLongPressing ? 0.6 : 0.35), lineWidth: 1.5)
                    .frame(width: ballSize, height: ballSize)

                // 状态图标（长按时切换为麦克风提示，常规为声波）
                Image(systemName: isLongPressing ? "mic.fill" : "waveform")
                    .font(.system(size: isLongPressing ? 23 : 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isDragging ? 1.15 : (isLongPressing ? 1.24 : 1.0))
            .responsiveAnimation(.spring(response: 0.3, dampingFraction: 0.65), value: isLongPressing)
            .responsiveAnimation(.spring(response: 0.3, dampingFraction: 0.65), value: isDragging)
            .position(x: currentX, y: currentY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("语音助手")
            .accessibilityHint("双击打开对话，长按开始语音输入")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                autoStartListening = false
                showVoice = true
            }
            // VoiceOver 专属操作：让仅用屏幕阅读器的用户也能直达录音（等效长按手势）
            .accessibilityAction(named: "开始语音输入") {
                autoStartListening = true
                showVoice = true
            }
            // 长按手势：按住 0.45 秒直接开始录音，不打开对话页面
            .onLongPressGesture(minimumDuration: 0.45, pressing: { pressing in
                guard !isDragging else {
                    isLongPressing = false
                    return
                }
                AppMotion.animate(.spring(response: 0.3, dampingFraction: 0.65)) {
                    isLongPressing = pressing
                }
                if pressing {
                    Haptic.light()
                }
            }) {
                guard !isDragging else { return }
                isLongPressing = false
                Haptic.heavy()
                if let onDirectVoiceConversation {
                    onDirectVoiceConversation()
                } else {
                    autoStartListening = true
                    showVoice = true
                }
            }
            // 仅在明确单击时触发（位移小于 8pt，打开面板但不自动录音）
            .onTapGesture {
                guard !isDragging else { return }
                Haptic.medium()
                autoStartListening = false
                showVoice = true
            }
            // 拖拽手势：设置 minimumDistance: 8，手指滑动超过 8pt 才会识别为拖拽，且绝对不会触发 onTapGesture 或长按
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        if isLongPressing {
                            isLongPressing = false
                        }
                        if !isDragging {
                            isDragging = true
                            Haptic.light()
                        }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        isDragging = false
                        isLongPressing = false

                        // 计算最终停靠坐标
                        let rawFinalX = baseX + value.translation.width
                        let rawFinalY = baseY + value.translation.height

                        // 判断靠左还是靠右（智能贴边吸附）
                        let targetX: CGFloat = (rawFinalX < width / 2) ? minX : maxX
                        let targetY: CGFloat = min(max(rawFinalY, minY), maxY)

                        // 转换回归一化比例（0.0 ~ 1.0）
                        let finalNormX = (targetX - minX) / max(maxX - minX, 1)
                        let finalNormY = (targetY - minY) / max(maxY - minY, 1)

                        AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.72)) {
                            dragOffset = .zero
                            normX = Double(finalNormX)
                            normY = Double(finalNormY)
                        }

                        Haptic.light()
                    }
            )
        }
        }
    }
}
