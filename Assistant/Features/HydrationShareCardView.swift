import AssistantCore
import Photos
import SwiftUI
import UIKit

/// 方案一：清爽水光打卡卡片 (Hydration & Coffee Share Card)
///
/// 专为小红书、朋友圈等社交媒体设计的 4:5 黄金比例打卡图片，
/// 包含科学补水折算、咖啡因安全值、记账自动联动明细，
/// 并按规范展示 App 图标与 JohnnyBoyStudio 品牌标识。
public struct HydrationShareCardView: View {
    public let date: Date
    public let records: [WaterIntakeRecord]
    public let targetML: Double
    public let effectiveML: Double
    public let caffeineMG: Double

    public init(
        date: Date = .now,
        records: [WaterIntakeRecord],
        targetML: Double = 2000.0,
        effectiveML: Double,
        caffeineMG: Double
    ) {
        self.date = date
        self.records = records
        self.targetML = targetML
        self.effectiveML = effectiveML
        self.caffeineMG = caffeineMG
    }

    private var completionRatio: Double {
        guard targetML > 0 else { return 0 }
        return min(effectiveML / targetML, 1.5)
    }

    private var percentText: String {
        "\(Int((completionRatio * 100).rounded()))%"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. 顶部 Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DAILY HYDRATION · 科学补水")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cyan)
                        .tracking(0.8)

                    Text("今日水分与咖啡因日签")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text(date.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Spacer()

                // 达成率胶囊
                VStack(alignment: .trailing, spacing: 1) {
                    Text("达成率")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.cyan.opacity(0.8))
                    Text(percentText)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.cyan)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.cyan.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.3), lineWidth: 0.8)
                )
            }

            // 2. 核心大指标网格
            HStack(spacing: 10) {
                // 有效补水
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("💧")
                            .font(.system(size: 12))
                        Text("有效补水")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(effectiveML))")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("ml")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    let diff = Int(targetML - effectiveML)
                    Text(diff > 0 ? "目标 \(Int(targetML))ml · 差 \(diff)ml" : "已超额完成今日补水目标 🎉")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.cyan.opacity(0.9))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )

                // 累计咖啡因
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("☕️")
                            .font(.system(size: 12))
                        Text("累计咖啡因")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(caffeineMG))")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(caffeineMG > 400 ? Color.orange : Color(red: 1.0, green: 0.82, blue: 0.4))
                        Text("mg")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    Text(caffeineMG > 400 ? "超过每日 400mg 建议限额" : "安全上限 400mg · 健康无忧")
                        .font(.system(size: 9.5))
                        .foregroundStyle(caffeineMG > 400 ? Color.orange : Color.green.opacity(0.9))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )
            }

            // 3. 今日摄入流水（最多显示前 4 条）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("今日摄入明细")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Spacer()
                    if records.contains(where: { $0.linkedExpenseID != nil }) {
                        Text("含记账自动联动")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.cyan.opacity(0.85))
                    }
                }

                if records.isEmpty {
                    Text("今日尚无饮水记录")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.vertical, 8)
                } else {
                    let displayRecords = Array(records.prefix(4))
                    VStack(spacing: 6) {
                        ForEach(displayRecords) { record in
                            HStack(spacing: 8) {
                                Image(systemName: record.beverageType.iconName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.cyan)
                                    .frame(width: 24, height: 24)
                                    .background(Color.cyan.opacity(0.18))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(record.customName ?? record.beverageType.displayName)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(.white)

                                        if record.linkedExpenseID != nil {
                                            Text("记账联动")
                                                .font(.system(size: 8, weight: .bold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.green.opacity(0.2))
                                                .foregroundStyle(Color.green)
                                                .clipShape(Capsule())
                                        }
                                    }

                                    HStack(spacing: 4) {
                                        Text(record.date, format: .dateTime.hour().minute())
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(Color.white.opacity(0.5))
                                        if record.caffeineMG > 0 {
                                            Text("· 咖啡因 \(Int(record.caffeineMG))mg")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(Color.orange.opacity(0.8))
                                        }
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("+\(Int(record.effectiveHydrationML)) ml")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.cyan)
                                    if record.hydrationFactor < 1.0 {
                                        Text("原 \(Int(record.volumeML))ml")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.white.opacity(0.4))
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }

            // 4. 底部品牌栏 (App 图标 + JohnnyBoyStudio)
            VStack(spacing: 8) {
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
                    .background(Color.cyan.opacity(0.18))
                    .foregroundStyle(Color.cyan)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.cyan.opacity(0.3), lineWidth: 0.6)
                    )
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 350)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.10),
                    Color(red: 0.03, green: 0.12, blue: 0.18),
                    Color(red: 0.04, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
    }
}

/// 饮水打卡社交分享弹窗
public struct HydrationShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let records: [WaterIntakeRecord]
    public let targetML: Double
    public let effectiveML: Double
    public let caffeineMG: Double

    @State private var toastMessage: String?
    @State private var showSystemShareSheet: Bool = false
    @State private var renderedImage: UIImage?

    public init(
        records: [WaterIntakeRecord],
        targetML: Double = 2000.0,
        effectiveML: Double,
        caffeineMG: Double
    ) {
        self.records = records
        self.targetML = targetML
        self.effectiveML = effectiveML
        self.caffeineMG = caffeineMG
    }

    private var cardView: HydrationShareCardView {
        HydrationShareCardView(
            records: records,
            targetML: targetML,
            effectiveML: effectiveML,
            caffeineMG: caffeineMG
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 卡片预览
                    cardView
                        .padding(.top, 10)

                    // 导出操作按钮组
                    VStack(spacing: 12) {
                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存水光卡片至相册 (社交分享)")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.cyan)
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
            .navigationTitle("分享补水日签")
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
        renderer.scale = 3.0 // 3x 超高清光栅化
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
                showToast("已保存高清补水卡片至相册 📸")
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
