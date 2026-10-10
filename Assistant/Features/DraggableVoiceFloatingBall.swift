import SwiftUI

/// 可拖拽、自由吸附屏幕边缘的语音对话悬浮球
struct DraggableVoiceFloatingBall: View {
    @Binding var showVoice: Bool

    // 是否开启悬浮球
    @AppStorage("floating_voice_enabled") private var isFloatingVoiceEnabled: Bool = true
    // 持久化存储归一化位置 (0.0=靠左, 1.0=靠右; y 范围 0.0~1.0)
    @AppStorage("floating_voice_norm_x") private var normX: Double = 1.0 // 默认靠右
    @AppStorage("floating_voice_norm_y") private var normY: Double = 0.68 // 默认在右下角，最利于单手大拇指触达

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    private let ballSize: CGFloat = 52
    private let edgePadding: CGFloat = 12

    var body: some View {
        if isFloatingVoiceEnabled {
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
                // 背景渐变与毛玻璃投影
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: ballSize, height: ballSize)
                    .shadow(color: Color.indigo.opacity(isDragging ? 0.45 : 0.3), radius: isDragging ? 12 : 8, y: isDragging ? 6 : 4)

                // 动态微光光圈（拖拽时微放亮）
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: ballSize, height: ballSize)

                // 声波图标
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(isDragging ? 1.15 : 1.0)
            .position(x: currentX, y: currentY)
            // 仅在明确点击时触发（位移小于 8pt 时响应）
            .onTapGesture {
                guard !isDragging else { return }
                Haptic.medium()
                showVoice = true
            }
            // 拖拽手势：设置 minimumDistance: 8，手指滑动超过 8pt 才会识别为拖拽，且绝对不会触发 onTapGesture
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            Haptic.light()
                        }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        isDragging = false

                        // 计算最终停靠坐标
                        let rawFinalX = baseX + value.translation.width
                        let rawFinalY = baseY + value.translation.height

                        // 判断靠左还是靠右（智能贴边吸附）
                        let targetX: CGFloat = (rawFinalX < width / 2) ? minX : maxX
                        let targetY: CGFloat = min(max(rawFinalY, minY), maxY)

                        // 转换回归一化比例（0.0 ~ 1.0）
                        let finalNormX = (targetX - minX) / max(maxX - minX, 1)
                        let finalNormY = (targetY - minY) / max(maxY - minY, 1)

                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
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
