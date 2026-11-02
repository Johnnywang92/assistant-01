import AssistantCore
import SwiftUI

/// 物品收纳打卡微动效数据模型
public struct StoredItemMotionData: Equatable {
    public var itemName: String
    public var roomArea: String
    public var location: String
    public var isEditing: Bool
    public var id: UUID

    public init(
        itemName: String,
        roomArea: String,
        location: String,
        isEditing: Bool = false
    ) {
        self.itemName = itemName
        self.roomArea = roomArea
        self.location = location
        self.isEditing = isEditing
        self.id = UUID()
    }
}

/// 物品收纳交互微动效全屏覆盖层（非阻塞，支持物品入箱归位、锁扣弹动、星芒与触觉同频）
public struct StorageItemMotionOverlay: View {
    @Binding var motionData: StoredItemMotionData?

    public init(motionData: Binding<StoredItemMotionData?>) {
        self._motionData = motionData
    }

    public var body: some View {
        ZStack {
            if let active = motionData {
                if AppMotion.reduceMotion {
                    ReducedMotionStorageBadge(data: active) {
                        dismiss()
                    }
                    .id(active.id)
                } else {
                    StorageBoxAnimationCanvas(data: active) {
                        dismiss()
                    }
                    .id(active.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false) // 穿透点击，绝不阻塞用户操作
    }

    private func dismiss() {
        AppMotion.animate(.easeOut(duration: 0.22)) {
            motionData = nil
        }
    }
}

// MARK: - 完整动效画布：收纳箱盖开合、标签入箱、星芒绽放

private struct StorageBoxAnimationCanvas: View {
    let data: StoredItemMotionData
    let onFinished: () -> Void

    @State private var animPhase: CGFloat = 0.0
    @State private var boxScale: CGFloat = 0.4
    @State private var boxOpacity: Double = 0.0
    @State private var itemTagOffset: CGFloat = -110
    @State private var itemTagOpacity: Double = 0.0
    @State private var itemTagScale: CGFloat = 0.8
    @State private var badgeOffset: CGFloat = 50
    @State private var badgeOpacity: Double = 0.0
    @State private var rippleScale: CGFloat = 0.5
    @State private var rippleOpacity: Double = 0.0
    @State private var sparkleScale: CGFloat = 0.0

    var body: some View {
        ZStack {
            // 1. 中心柔和紫晶/靛蓝光晕
            RadialGradient(
                colors: [
                    Color.indigo.opacity(0.32),
                    Color.purple.opacity(0.12),
                    Color.clear
                ],
                center: .center,
                startRadius: 8,
                endRadius: 88
            )
            .frame(width: 176, height: 176)
            .scaleEffect(boxScale)
            .opacity(boxOpacity)

            // 2. 闭合卡扣波纹
            Circle()
                .stroke(Color.indigo.opacity(rippleOpacity * 0.45), lineWidth: 2)
                .frame(width: 76, height: 76)
                .scaleEffect(rippleScale)

            // 3. 收纳箱体（带渐变与锁扣）
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.42, green: 0.38, blue: 0.88), Color(red: 0.32, green: 0.28, blue: 0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 66, height: 66)
                    .shadow(color: Color.indigo.opacity(0.38), radius: 10, y: 4)

                Image(systemName: data.isEditing ? "shippingbox.and.arrow.backward.fill" : "archivebox.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(boxScale)
            .opacity(boxOpacity)

            // 4. 从上方滑入箱中的物品标签微卡片
            HStack(spacing: 4) {
                Image(systemName: "tag.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.indigo)
                Text(data.itemName)
                    .font(.caption.bold())
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xs)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                    .overlay(
                        Capsule().stroke(Color.indigo.opacity(0.3), lineWidth: 1)
                    )
            )
            .offset(y: itemTagOffset)
            .scaleEffect(itemTagScale)
            .opacity(itemTagOpacity)

            // 5. 封存完成向四周散开的星芒微粒子
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * (.pi / 3.0)
                let distance = 46.0 * animPhase
                Image(systemName: "sparkle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 1.0))
                    .scaleEffect(sparkleScale)
                    .opacity(Double(1.0 - animPhase))
                    .offset(
                        x: cos(angle) * distance,
                        y: sin(angle) * distance
                    )
            }

            // 6. 悬浮归位成功胶囊条
            floatingSummaryBadge
        }
        .onAppear {
            playAnimation()
        }
    }

    private var floatingSummaryBadge: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote.bold())
                .foregroundStyle(Color.indigo)

            Text(data.isEditing ? "收纳位置已更新" : "妥善收纳入库")
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(AppColor.text)

            Text("「\(data.roomArea) · \(data.location)」")
                .font(.caption2)
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                .overlay(
                    Capsule().stroke(Color.indigo.opacity(0.28), lineWidth: 1)
                )
        )
        .offset(y: badgeOffset)
        .opacity(badgeOpacity)
    }

    private func playAnimation() {
        // 1. 箱体弹性涌现
        AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.68)) {
            boxScale = 1.0
            boxOpacity = 1.0
        }

        // 2. 标签从上方下落并缩小滑入箱内
        itemTagOpacity = 1.0
        AppMotion.animate(.easeIn(duration: 0.28).delay(0.06)) {
            itemTagOffset = 0
            itemTagScale = 0.5
        }

        // 3. 入箱闭合瞬间（t = 0.34s）：弹性挤压回弹 + 涟漪散开 + 星芒炸开
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            Haptic.impact(style: .medium)

            AppMotion.animate(.easeOut(duration: 0.55)) {
                itemTagOpacity = 0.0
                animPhase = 1.0
                rippleScale = 2.2
                rippleOpacity = 0.8
                sparkleScale = 1.15
            }

            AppMotion.animate(.spring(response: 0.28, dampingFraction: 0.5)) {
                boxScale = 1.12
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                AppMotion.animate(.spring(response: 0.28, dampingFraction: 0.65)) {
                    boxScale = 1.0
                }
                Haptic.success()
            }

            AppMotion.animate(.easeOut(duration: 0.3).delay(0.25)) {
                rippleOpacity = 0.0
            }
        }

        // 4. 悬浮结果胶囊条滑出
        AppMotion.animate(.spring(response: 0.4, dampingFraction: 0.72).delay(0.2)) {
            badgeOffset = 62
            badgeOpacity = 1.0
        }

        // 5. 收尾淡出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.88) {
            AppMotion.animate(.easeOut(duration: 0.25)) {
                boxOpacity = 0.0
                badgeOpacity = 0.0
                badgeOffset = 48
            }
        }

        // 6. 回调完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.16) {
            onFinished()
        }
    }
}

// MARK: - 无障碍降级视图

private struct ReducedMotionStorageBadge: View {
    let data: StoredItemMotionData
    let onFinished: () -> Void

    @State private var opacity: Double = 0.0

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "archivebox.fill")
                .font(.headline)
                .foregroundStyle(Color.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.isEditing ? "收纳位置已更新" : "物品已妥善收纳")
                    .font(.caption2)
                    .foregroundStyle(AppColor.secondaryText)
                Text("\(data.itemName) → \(data.roomArea) · \(data.location)")
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

