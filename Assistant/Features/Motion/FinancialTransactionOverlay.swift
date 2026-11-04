import SwiftUI

/// 记账交易动效类型
public enum FinancialMotionType: Equatable {
    case income(amount: Double, id: UUID = UUID())
    case expense(amount: Double, id: UUID = UUID())

    public var isIncome: Bool {
        if case .income = self { return true }
        return false
    }

    public var amount: Double {
        switch self {
        case .income(let val, _): return val
        case .expense(let val, _): return val
        }
    }

    public var id: UUID {
        switch self {
        case .income(_, let id): return id
        case .expense(_, let id): return id
        }
    }
}

/// 记账交易全屏交互微动效覆盖层（非阻塞，支持收入存钱金币掉落、支出钞票飘飞与触觉同频）
public struct FinancialTransactionOverlay: View {
    @Binding var motion: FinancialMotionType?

    public init(motion: Binding<FinancialMotionType?>) {
        self._motion = motion
    }

    public var body: some View {
        ZStack {
            if let activeMotion = motion {
                if AppMotion.reduceMotion {
                    ReducedMotionTransactionBadge(motion: activeMotion) {
                        dismiss()
                    }
                    .id(activeMotion.id)
                } else {
                    TransactionAnimationCanvas(motion: activeMotion) {
                        dismiss()
                    }
                    .id(activeMotion.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false) // 穿透点击，绝不阻塞用户交互
    }

    private func dismiss() {
        AppMotion.animate(.easeOut(duration: 0.25)) {
            motion = nil
        }
    }
}

// MARK: - 完整动效画布（含物理落点、粒子与微弹回弹）

private struct TransactionAnimationCanvas: View {
    let motion: FinancialMotionType
    let onFinished: () -> Void

    @State private var animPhase: CGFloat = 0.0
    @State private var hubScale: CGFloat = 0.4
    @State private var hubOpacity: Double = 0.0
    @State private var badgeOffset: CGFloat = 50
    @State private var badgeOpacity: Double = 0.0
    @State private var rippleScale: CGFloat = 0.5
    @State private var rippleOpacity: Double = 0.8
    @State private var sparkleScale: CGFloat = 0.0

    var body: some View {
        ZStack {
            if motion.isIncome {
                // 1. 收入动效：金币入袋、光晕与星光绽放
                incomeAnimationView
            } else {
                // 2. 支出动效：钞票飘扬、水波散去与流光
                expenseAnimationView
            }

            // 3. 悬浮数字徽标（+¥金额 / -¥金额）
            floatingAmountBadge
        }
        .onAppear {
            playAnimation()
        }
    }

    // MARK: - 收入动画视图（存钱罐 / 钱包 + 金币掉落 + 金色星芒）

    private var incomeAnimationView: some View {
        ZStack {
            // 中心金色光芒光晕
            RadialGradient(
                colors: [
                    Color.yellow.opacity(0.35),
                    Color.orange.opacity(0.12),
                    Color.clear
                ],
                center: .center,
                startRadius: 8,
                endRadius: 90
            )
            .frame(width: 180, height: 180)
            .scaleEffect(hubScale)
            .opacity(hubOpacity)

            // 中心钱包/聚宝图标
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.82, blue: 0.28), Color(red: 0.96, green: 0.58, blue: 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.orange.opacity(0.4), radius: 10, y: 4)

                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(hubScale)
            .opacity(hubOpacity)

            // 金币下落（5 枚金币依次带着弹性物理轨迹落入中心）
            ForEach(0..<5, id: \.self) { i in
                singleCoinView(index: i)
            }

            // 金色粒子星芒（金币落地时向四周炸开）
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * (.pi / 4.0)
                let distance: CGFloat = 48.0 * animPhase
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.yellow)
                    .scaleEffect(sparkleScale)
                    .opacity(Double(1.0 - animPhase))
                    .offset(
                        x: cos(angle) * distance,
                        y: sin(angle) * distance
                    )
            }
        }
    }

    private func singleCoinView(index: Int) -> some View {
        let xOffsets: [CGFloat] = [-36, 28, -16, 32, 0]
        let startY: CGFloat = -150
        let targetX = xOffsets[index] * (1.0 - min(animPhase * 1.5, 1.0))
        // 模拟重力加速下落与触底反弹：phase 0->0.7 下落，0.7->0.85 向上微弹，0.85->1.0 归位
        let progress = max(0, min(1.0, (animPhase - Double(index) * 0.08) / 0.65))
        let currentY: CGFloat
        if progress < 0.75 {
            currentY = startY + (progress / 0.75) * (-startY)
        } else if progress < 0.9 {
            let bounceT = (progress - 0.75) / 0.15
            currentY = -14.0 * sin(bounceT * .pi)
        } else {
            currentY = 0
        }

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.9, blue: 0.35), Color(red: 0.95, green: 0.68, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1.2)
                )
                .shadow(color: Color.orange.opacity(0.3), radius: 3, y: 2)

            Text("¥")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.05))
        }
        .offset(x: targetX, y: currentY)
        .opacity(progress > 0 && progress < 0.98 ? 1.0 : (progress >= 0.98 ? (1.0 - (animPhase - 0.8) * 4) : 0.0))
        .scaleEffect(progress > 0.7 ? 1.0 : 0.8)
    }

    // MARK: - 支出动画视图（钞票随风飘散 + 波纹能量扩散）

    private var expenseAnimationView: some View {
        ZStack {
            // 扩散涟漪光环
            Circle()
                .stroke(Color.orange.opacity(rippleOpacity * 0.4), lineWidth: 2)
                .frame(width: 72, height: 72)
                .scaleEffect(rippleScale)

            Circle()
                .stroke(Color.red.opacity(rippleOpacity * 0.25), lineWidth: 1.5)
                .frame(width: 72, height: 72)
                .scaleEffect(rippleScale * 1.35)

            // 两张轻微旋转并向上飘散的钞票
            singleBillView(
                initialRotation: -12,
                targetRotation: 20,
                xDrift: 42,
                yLift: -125,
                delay: 0.0
            )

            singleBillView(
                initialRotation: 15,
                targetRotation: -18,
                xDrift: -36,
                yLift: -105,
                delay: 0.1
            )
        }
    }

    private func singleBillView(
        initialRotation: Double,
        targetRotation: Double,
        xDrift: CGFloat,
        yLift: CGFloat,
        delay: Double
    ) -> some View {
        let progress = max(0, min(1.0, (animPhase - delay) / 0.8))
        let rotation = initialRotation + (targetRotation - initialRotation) * progress
        let currentX = xDrift * progress
        let currentY = yLift * sin(progress * (.pi / 2.0))
        let currentOpacity = progress < 0.65 ? 1.0 : (1.0 - (progress - 0.65) / 0.35)
        let currentScale = 1.0 - 0.25 * progress

        return ZStack {
            RoundedRectangle(cornerRadius: AppRadius.badge)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.42, blue: 0.35), Color(red: 0.92, green: 0.28, blue: 0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.badge)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: Color.red.opacity(0.25), radius: 5, y: 3)

            HStack(spacing: 3) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
        .rotationEffect(.degrees(rotation))
        .offset(x: currentX, y: currentY)
        .scaleEffect(currentScale)
        .opacity(currentOpacity)
    }

    // MARK: - 悬浮金额提示胶囊条

    private var floatingAmountBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: motion.isIncome ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                .font(.footnote.bold())
                .foregroundStyle(motion.isIncome ? AppColor.success : AppColor.danger)

            Text(motion.isIncome ? "+¥\(String(format: "%.2f", motion.amount))" : "-¥\(String(format: "%.2f", motion.amount))")
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(AppColor.text)

            Text(motion.isIncome ? "存入成功" : "已记支出")
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppColor.secondaryText)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
                .overlay(
                    Capsule()
                        .stroke(
                            (motion.isIncome ? AppColor.success : AppColor.danger).opacity(0.25),
                            lineWidth: 1
                        )
                )
        )
        .offset(y: badgeOffset)
        .opacity(badgeOpacity)
    }

    // MARK: - 动画驱动与触觉同频编排

    private func playAnimation() {
        // 1. 中心图标弹性浮现
        AppMotion.animate(.spring(response: 0.42, dampingFraction: 0.68)) {
            hubScale = 1.0
            hubOpacity = 1.0
        }

        // 2. 悬浮数字徽标从下方轻弹滑出
        AppMotion.animate(.spring(response: 0.45, dampingFraction: 0.72).delay(0.1)) {
            badgeOffset = 58
            badgeOpacity = 1.0
        }

        // 3. 驱动主物理阶段（金币/钞票物理动画）
        AppMotion.animate(.easeInOut(duration: 0.95)) {
            animPhase = 1.0
            rippleScale = 2.2
            rippleOpacity = 0.0
            sparkleScale = 1.15
        }

        // 4. 触觉分段精准触发
        if motion.isIncome {
            Haptic.light()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Haptic.selection()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Haptic.medium()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Haptic.success()
            }
        } else {
            Haptic.light()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                Haptic.medium()
            }
        }

        // 5. 保持展示供清晰阅读，适时温和收尾淡出（~1.55s 开始淡出）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) {
            AppMotion.animate(.easeOut(duration: 0.35)) {
                hubOpacity = 0.0
                badgeOpacity = 0.0
                badgeOffset = 46
            }
        }

        // 6. 结束回调（总时长约 1.95s，既不一闪而过，又绝不拖沓阻塞）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.95) {
            onFinished()
        }
    }
}

// MARK: - 无障碍降级：静止温和的轻提示

private struct ReducedMotionTransactionBadge: View {
    let motion: FinancialMotionType
    let onFinished: () -> Void

    @State private var opacity: Double = 0.0

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: motion.isIncome ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.headline)
                .foregroundStyle(motion.isIncome ? AppColor.success : AppColor.danger)

            VStack(alignment: .leading, spacing: 2) {
                Text(motion.isIncome ? "已存入一笔收入" : "已记录一笔支出")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Text(motion.isIncome ? "+¥\(String(format: "%.2f", motion.amount))" : "-¥\(String(format: "%.2f", motion.amount))")
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeOut(duration: 0.25)) {
                    opacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    onFinished()
                }
            }
        }
    }
}

