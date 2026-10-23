import AssistantCore
import Photos
import SwiftUI
import UIKit

/// 健康数据与活力指数社交分享卡片 (Health & Vitality Share Card)
///
/// 专为小红书、朋友圈、即刻等社交媒体设计的 4:5 比例健康日报卡片，
/// 包含核心生理指标、活力指数、运动消耗、打卡协同，
/// 并按规范展示 App 图标与 JohnnyBoyStudio 品牌标识。
public struct HealthShareCardView: View {
    public let date: Date
    public let snapshot: HealthDaySnapshot?
    public let vitality: VitalityEvaluation?
    public let todayFoodCalories: Double?
    public let todayWaterML: Double?
    public let goals: [HealthGoal]

    public init(
        date: Date = .now,
        snapshot: HealthDaySnapshot?,
        vitality: VitalityEvaluation?,
        todayFoodCalories: Double? = nil,
        todayWaterML: Double? = nil,
        goals: [HealthGoal] = HealthGoal.defaults
    ) {
        self.date = date
        self.snapshot = snapshot
        self.vitality = vitality
        self.todayFoodCalories = todayFoodCalories
        self.todayWaterML = todayWaterML
        self.goals = goals
    }

    private var steps: Double? { snapshot?.stepCount }
    private var sleep: Double? { snapshot?.sleepHours }
    private var heartRate: Double? { snapshot?.heartRate }
    private var bloodOxygen: Double? { snapshot?.bloodOxygen }
    private var totalBurned: Double? { snapshot?.totalEnergyBurned }

    private var energyBalanceBrief: String {
        guard let net = vitality?.energyBalance.netDifference else {
            return "静息与活动消耗"
        }
        let netInt = Int(abs(net).rounded())
        if abs(net) <= 250 {
            return "能量收支平衡"
        } else if net > 250 {
            return "适度盈余 +\(netInt) kcal"
        } else {
            return "热量赤字 -\(netInt) kcal"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 顶部 Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DAILY HEALTH · 健康体征日报")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.55))
                        .tracking(0.8)

                    Text("今日身体活力签")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text(date.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Spacer()

                // 活力分胶囊
                if let vitality {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(vitality.level.badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.55))
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(vitality.score)")
                                .font(.system(size: 22, weight: .black, design: .rounded))
                                .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.55))
                            Text("/100")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.3), lineWidth: 0.8)
                    )
                }
            }

            // 2. 活力简评横幅
            if let summary = vitality?.summary {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.55))
                    Text(summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // 3. 核心 4 大指标网格 (2x2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // 步数与健身
                statTile(
                    icon: "figure.walk",
                    tint: Color(red: 0.2, green: 0.85, blue: 0.55),
                    title: "今日步数",
                    value: steps.map { "\(Int($0.rounded())) 步" } ?? "待同步",
                    subtitle: snapshot?.workoutSummary?.count ?? 0 > 0 ? "健身 \(snapshot!.workoutSummary!.count) 次" : "日常行走"
                )

                // 消耗总能
                statTile(
                    icon: "flame.fill",
                    tint: Color.orange,
                    title: "身体总耗能",
                    value: totalBurned.map { "\(Int($0.rounded())) kcal" } ?? "待计算",
                    subtitle: energyBalanceBrief
                )

                // 睡眠恢复
                statTile(
                    icon: "bed.double.fill",
                    tint: Color.indigo,
                    title: "昨夜睡眠",
                    value: sleep.map { String(format: "%.1f 小时", $0) } ?? "待记录",
                    subtitle: (sleep ?? 0) >= 7.0 ? "睡眠充足恢复好" : "建议稍早作息"
                )

                // 核心体征
                statTile(
                    icon: "heart.fill",
                    tint: Color.red,
                    title: "静息心率 / 血氧",
                    value: formatVitals(),
                    subtitle: "生命体征平稳"
                )
            }

            // 4. 打卡目标协同清单
            VStack(alignment: .leading, spacing: 6) {
                Text("HEALTH GOALS · 目标协同")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .tracking(0.5)

                HStack(spacing: 8) {
                    ForEach(HealthRelatedTodoType.allCases, id: \.self) { todoType in
                        goalChip(todoType: todoType)
                    }
                }
            }

            // 5. 底部品牌与专属网站标识
            VStack(spacing: 12) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.8)

                HStack(alignment: .center, spacing: 10) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.black.opacity(0.2), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("小助 · 个人智能生活助理")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text("记所想，助所行")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 专属网站标识胶囊
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9))
                        Text("JohnnyBoyStudio")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.18))
                    .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.55))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.3), lineWidth: 0.6)
                    )
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 350)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.09, blue: 0.08),
                    Color(red: 0.03, green: 0.14, blue: 0.12),
                    Color(red: 0.04, green: 0.08, blue: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
    }

    private func statTile(icon: String, tint: Color, title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }

    private func formatVitals() -> String {
        var parts: [String] = []
        if let hr = heartRate { parts.append("\(Int(hr.rounded())) bpm") }
        if let ox = bloodOxygen {
            let pct = ox > 1.0 ? ox : ox * 100.0
            parts.append("\(Int(pct.rounded()))%")
        }
        return parts.isEmpty ? "指标正常" : parts.joined(separator: " · ")
    }

    private func goalChip(todoType: HealthRelatedTodoType) -> some View {
        let isAchieved: Bool = {
            guard let snapshot else { return false }
            return HealthMetrics.progress(for: todoType, snapshot: snapshot, goals: goals)?.isAchieved ?? false
        }()

        let title: String = switch todoType {
        case .exercise: "运动"
        case .hydration: "补水"
        case .sleep: "作息"
        }

        return HStack(spacing: 4) {
            Image(systemName: isAchieved ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(isAchieved ? Color(red: 0.2, green: 0.85, blue: 0.55) : Color.white.opacity(0.3))
            Text("\(title)\(isAchieved ? "达标" : "进行中")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isAchieved ? .white : Color.white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isAchieved ? Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.15) : Color.white.opacity(0.05))
        .clipShape(Capsule())
    }
}

/// 健康数据社交分享弹窗
public struct HealthShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let snapshot: HealthDaySnapshot?
    public let vitality: VitalityEvaluation?
    public let todayFoodCalories: Double?
    public let todayWaterML: Double?
    public let goals: [HealthGoal]

    @State private var toastMessage: String?
    @State private var showSystemShareSheet: Bool = false

    public init(
        snapshot: HealthDaySnapshot?,
        vitality: VitalityEvaluation?,
        todayFoodCalories: Double? = nil,
        todayWaterML: Double? = nil,
        goals: [HealthGoal] = HealthGoal.defaults
    ) {
        self.snapshot = snapshot
        self.vitality = vitality
        self.todayFoodCalories = todayFoodCalories
        self.todayWaterML = todayWaterML
        self.goals = goals
    }

    private var cardView: HealthShareCardView {
        HealthShareCardView(
            snapshot: snapshot,
            vitality: vitality,
            todayFoodCalories: todayFoodCalories,
            todayWaterML: todayWaterML,
            goals: goals
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.top, 10)

                    // 导出操作按钮组
                    VStack(spacing: 12) {
                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存健康卡片至相册 (社交分享)")
                            }
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.2, green: 0.85, blue: 0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        Button {
                            shareViaSystem()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("直接发送到社交平台")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享健康活力签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
    }

    @MainActor
    private func renderImage() -> UIImage? {
        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 3.0 // 3x 高清光栅化
        renderer.isOpaque = false
        return renderer.uiImage
    }

    private func saveToPhotos() {
        guard let image = renderImage() else {
            showToast("生成图片失败，请重试")
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    showToast("请在系统设置中允许小助访问相册")
                    return
                }

                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                Haptic.success()
                showToast("已保存高清健康卡片至相册 📸")
            }
        }
    }

    private func shareViaSystem() {
        guard let image = renderImage() else {
            showToast("生成图片失败，请重试")
            return
        }

        let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == msg { toastMessage = nil }
        }
    }
}
