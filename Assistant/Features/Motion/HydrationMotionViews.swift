import AssistantCore
import SwiftUI

/// 饮水打卡微动效数据模型
public struct HydrationMotionData: Equatable {
    public var beverage: HydrationBeverageType
    public var volumeML: Double
    public var effectiveML: Double
    public var isGoalAchieved: Bool
    public var id: UUID

    public init(
        beverage: HydrationBeverageType,
        volumeML: Double,
        effectiveML: Double,
        isGoalAchieved: Bool = false
    ) {
        self.beverage = beverage
        self.volumeML = volumeML
        self.effectiveML = effectiveML
        self.isGoalAchieved = isGoalAchieved
        self.id = UUID()
    }
}

// MARK: - 真实物理双层流体水波视图（支持动态涌动与气泡）

public struct FluidWaveView: View {
    var progress: Double // 0.0 ~ 1.0+
    var waveColor: Color = Color(.systemCyan)
    var isSurging: Bool = false

    public init(progress: Double, waveColor: Color = Color(.systemCyan), isSurging: Bool = false) {
        self.progress = progress
        self.waveColor = waveColor
        self.isSurging = isSurging
    }

    public var body: some View {
        if AppMotion.reduceMotion {
            GeometryReader { geo in
                let clampedProgress = min(max(progress, 0.0), 1.0)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    waveColor.opacity(0.68)
                        .frame(height: geo.size.height * CGFloat(clampedProgress))
                }
            }
        } else {
            TimelineView(.animation) { context in
                Canvas { ctx, size in
                    let now = context.date.timeIntervalSinceReferenceDate
                    let width = size.width
                    let height = size.height
                    let clampedProgress = min(max(progress, 0.0), 1.0)
                    let waterHeight = height * (1.0 - CGFloat(clampedProgress))
                    let ampMultiplier: CGFloat = isSurging ? 1.8 : 1.0

                    // 1. 后层微透水波（较浅、速度稍慢）
                    let backPath = generateWavePath(
                        width: width,
                        height: height,
                        waterY: waterHeight,
                        time: now * 2.2,
                        amplitude: 3.5 * ampMultiplier,
                        frequency: 0.038,
                        phaseOffset: .pi / 2.0
                    )
                    ctx.fill(backPath, with: .color(waveColor.opacity(0.38)))

                    // 2. 前层主水波（饱和度高、速度稍快、相位错开）
                    let frontPath = generateWavePath(
                        width: width,
                        height: height,
                        waterY: waterHeight,
                        time: now * 3.0,
                        amplitude: 5.0 * ampMultiplier,
                        frequency: 0.045,
                        phaseOffset: 0.0
                    )
                    ctx.fill(frontPath, with: .color(waveColor.opacity(0.72)))

                    // 3. 内部微小气泡动态上浮
                    if clampedProgress > 0.15 {
                        drawBubbles(ctx: ctx, size: size, waterY: waterHeight, time: now, color: waveColor)
                    }
                }
            }
        }
    }

    private func generateWavePath(
        width: CGFloat,
        height: CGFloat,
        waterY: CGFloat,
        time: Double,
        amplitude: CGFloat,
        frequency: CGFloat,
        phaseOffset: Double
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: waterY))

        let step: CGFloat = 3.0
        for x in stride(from: 0, through: width + step, by: step) {
            let relativeX = x * frequency
            let y = waterY + sin(relativeX + CGFloat(time) + CGFloat(phaseOffset)) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }

    private func drawBubbles(ctx: GraphicsContext, size: CGSize, waterY: CGFloat, time: Double, color: Color) {
        let bubbleCount = 4
        for i in 0..<bubbleCount {
            let offsetI = Double(i) * 1.75
            let cycle = (time * 0.8 + offsetI).truncatingRemainder(dividingBy: 2.0) / 2.0 // 0...1
            let bubbleY = size.height - CGFloat(cycle) * (size.height - waterY)
            let bubbleX = size.width * (0.25 + 0.5 * CGFloat(sin(offsetI * 3.0 + time * 1.2) * 0.5 + 0.5))
            let radius: CGFloat = 1.8 + CGFloat(i) * 0.4
            let opacity = max(0, min(1, sin(cycle * .pi))) * 0.65

            let rect = CGRect(x: bubbleX - radius, y: bubbleY - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(opacity)))
        }
    }
}

// MARK: - 环形注水进度组件（替换/升级普通圆环）

public struct FluidWaveCircleProgress: View {
    var progressRatio: Double
    var isGoalAchieved: Bool
    var diameter: CGFloat = 78

    @State private var isSurging: Bool = false

    public init(progressRatio: Double, isGoalAchieved: Bool, diameter: CGFloat = 78) {
        self.progressRatio = progressRatio
        self.isGoalAchieved = isGoalAchieved
        self.diameter = diameter
    }

    private var themeColor: Color {
        isGoalAchieved ? AppColor.success : Color(.systemCyan)
    }

    public var body: some View {
        ZStack {
            // 1. 底层水球容器
            Circle()
                .fill(Color(.secondarySystemFill).opacity(0.35))
                .frame(width: diameter, height: diameter)

            // 2. 内部流体波浪注水（裁切在圆形容器内）
            FluidWaveView(
                progress: progressRatio,
                waveColor: themeColor,
                isSurging: isSurging
            )
            .clipShape(Circle())
            .frame(width: diameter, height: diameter)

            // 3. 外部纤细圆环进度刻度
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 3.5)
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0, to: CGFloat(min(progressRatio, 1.0)))
                .stroke(
                    themeColor,
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .responsiveAnimation(.easeInOut(duration: 0.45), value: progressRatio)

            // 4. 浮于水球中央的呼吸感图标/完成标记
            Image(systemName: isGoalAchieved ? "checkmark" : "drop.fill")
                .font(.system(size: diameter * 0.28, weight: .bold))
                .foregroundStyle(
                    isGoalAchieved
                        ? Color.white
                        : (progressRatio > 0.5 ? Color.white : themeColor)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 2, y: 1)
                .scaleEffect(isSurging ? 1.15 : 1.0)
        }
        .onChange(of: progressRatio) { _, _ in
            triggerSurge()
        }
    }

    private func triggerSurge() {
        withAnimation(.easeOut(duration: 0.15)) {
            isSurging = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeInOut(duration: 0.4)) {
                isSurging = false
            }
        }
    }
}

// MARK: - 喝水全屏交互微动效覆盖层（水滴入水 + 涟漪 + 气泡浮动，非阻塞）

public struct HydrationLogOverlay: View {
    @Binding var motionData: HydrationMotionData?

    public init(motionData: Binding<HydrationMotionData?>) {
        self._motionData = motionData
    }

    public var body: some View {
        ZStack {
            if let active = motionData {
                if AppMotion.reduceMotion {
                    ReducedMotionHydrationBadge(data: active) {
                        dismiss()
                    }
                    .id(active.id)
                } else {
                    HydrationDropletCanvas(data: active) {
                        dismiss()
                    }
                    .id(active.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false) // 穿透点击，绝不阻塞用户连续记录
    }

    private func dismiss() {
        AppMotion.animate(.easeOut(duration: 0.22)) {
            motionData = nil
        }
    }
}

// MARK: - 动效画布：水滴下落、溅射珍珠水珠与同心涟漪

private struct HydrationDropletCanvas: View {
    let data: HydrationMotionData
    let onFinished: () -> Void

    @State private var animProgress: CGFloat = 0.0
    @State private var dropletOffset: CGFloat = -110
    @State private var dropletOpacity: Double = 0.0
    @State private var rippleScale: CGFloat = 0.3
    @State private var rippleOpacity: Double = 0.0
    @State private var badgeOffset: CGFloat = 46
    @State private var badgeOpacity: Double = 0.0
    @State private var celebrationScale: CGFloat = 0.2
    @State private var celebrationOpacity: Double = 0.0

    private var themeColor: Color {
        data.isGoalAchieved ? AppColor.success : Color(.systemCyan)
    }

    var body: some View {
        ZStack {
            // 1. 水面同心涟漪
            Circle()
                .stroke(themeColor.opacity(rippleOpacity * 0.5), lineWidth: 2)
                .frame(width: 80, height: 80)
                .scaleEffect(rippleScale)

            Circle()
                .stroke(themeColor.opacity(rippleOpacity * 0.25), lineWidth: 1.5)
                .frame(width: 80, height: 80)
                .scaleEffect(rippleScale * 1.5)

            // 2. 下落的大水滴（从上方下落并融入水面）
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.85),
                                themeColor,
                                themeColor.opacity(0.85)
                            ],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 22
                        )
                    )
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: themeColor.opacity(0.4), radius: 6, y: 3)

                Image(systemName: data.beverage.iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .offset(y: dropletOffset)
            .opacity(dropletOpacity)
            .scaleEffect(dropletOffset >= 0 ? 0.8 : 1.0)

            // 3. 入水溅射的 4 颗小水珠
            ForEach(0..<4, id: \.self) { i in
                let angle = Double(i) * (.pi / 2.0) + (.pi / 4.0)
                let distance = animProgress * 36.0
                Circle()
                    .fill(themeColor)
                    .frame(width: 6, height: 6)
                    .offset(
                        x: cos(angle) * distance,
                        y: sin(angle) * distance * 0.65 - (animProgress < 0.5 ? 8 * sin(animProgress * .pi) : 0)
                    )
                    .opacity(Double(max(0, 1.0 - animProgress * 1.2)))
            }

            // 4. 达标祝贺光环（如达成 100% 目标）
            if data.isGoalAchieved {
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        let angle = Double(i) * (.pi / 3.0)
                        Image(systemName: "sparkle")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.yellow)
                            .offset(
                                x: cos(angle) * (56.0 * celebrationScale),
                                y: sin(angle) * (56.0 * celebrationScale)
                            )
                            .opacity(celebrationOpacity)
                    }
                }
            }

            // 5. 悬浮打卡成功胶囊条
            floatingSummaryBadge
        }
        .onAppear {
            playAnimation()
        }
    }

    private var floatingSummaryBadge: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: data.beverage.iconName)
                .font(.footnote.bold())
                .foregroundStyle(themeColor)

            Text("+\(Int(data.volumeML)) ml")
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(AppColor.text)

            Text("有效补水 +\(Int(data.effectiveML))ml")
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)

            if data.isGoalAchieved {
                Text("🎉 今日达标")
                    .font(.caption2.bold())
                    .foregroundStyle(AppColor.success)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                .overlay(
                    Capsule()
                        .stroke(themeColor.opacity(0.3), lineWidth: 1)
                )
        )
        .offset(y: badgeOffset)
        .opacity(badgeOpacity)
    }

    private func playAnimation() {
        // 1. 水滴从上方落入
        dropletOpacity = 1.0
        AppMotion.animate(.easeIn(duration: 0.28)) {
            dropletOffset = 0
        }

        // 2. 接触水面瞬间（t = 0.28s）：触感反馈 + 涟漪散开 + 水珠溅射
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            Haptic.impact(style: .light)

            AppMotion.animate(.easeOut(duration: 0.55)) {
                animProgress = 1.0
                rippleScale = 2.4
                rippleOpacity = 0.8
                dropletOpacity = 0.0
            }

            AppMotion.animate(.easeOut(duration: 0.35).delay(0.2)) {
                rippleOpacity = 0.0
            }

            if data.isGoalAchieved {
                AppMotion.animate(.spring(response: 0.45, dampingFraction: 0.65)) {
                    celebrationScale = 1.0
                    celebrationOpacity = 1.0
                }
                Haptic.success()
            }
        }

        // 3. 悬浮打卡胶囊条滑出
        AppMotion.animate(.spring(response: 0.38, dampingFraction: 0.72).delay(0.15)) {
            badgeOffset = 62
            badgeOpacity = 1.0
        }

        // 4. 收尾淡出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            AppMotion.animate(.easeOut(duration: 0.25)) {
                badgeOpacity = 0.0
                badgeOffset = 48
                celebrationOpacity = 0.0
            }
        }

        // 5. 回调完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            onFinished()
        }
    }
}

// MARK: - 无障碍降级视图

private struct ReducedMotionHydrationBadge: View {
    let data: HydrationMotionData
    let onFinished: () -> Void

    @State private var opacity: Double = 0.0

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: data.beverage.iconName)
                .font(.headline)
                .foregroundStyle(Color(.systemCyan))

            VStack(alignment: .leading, spacing: 2) {
                Text("已记录一杯 \(data.beverage.displayName)")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Text("+\(Int(data.volumeML)) ml (有效补水 +\(Int(data.effectiveML))ml)")
                    .font(.subheadline.bold())
                    .foregroundStyle(AppColor.text)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card)
                .fill(AppColor.surface)
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
        )
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.2)) {
                opacity = 1.0
            }
            Haptic.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                withAnimation(.easeOut(duration: 0.2)) {
                    opacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    onFinished()
                }
            }
        }
    }
}

