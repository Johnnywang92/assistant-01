import AssistantCore
import SwiftUI
import UIKit

/// 物品收纳视觉卡片（用于离线长图导出与社交分享）
public struct StoredItemShareCard: View {
    public let item: StoredItem

    public init(item: StoredItem) {
        self.item = item
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. 顶部 Header
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(Color.indigo.gradient)
                        .frame(width: 36, height: 36)

                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ITEM STORAGE · 物品收纳备忘")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.secondary)
                        .tracking(0.8)

                    Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                Text("家庭空间共享")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.1))
                    .clipShape(Capsule())
            }

            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 1)

            // 2. 物品核心信息
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(Color.indigo)

                    Text("\(item.roomArea) · \(item.location)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.indigo.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            }

            // 3. 物品实拍照片（若存在）
            if let imgData = item.imageData, let uiImg = UIImage(data: imgData) {
                Image(uiImage: uiImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    )
            }

            // 4. 补充备注
            if let notes = item.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("存放备注")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(notes)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            }

            // 5. 底部品牌落款
            HStack(spacing: 8) {
                Image("AssistantAppIcon")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous))

                Text("小助 · 记所想，助所行")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(20)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
    }
}

/// 物品收纳分享弹出面板（支持碰一碰直传、相册卡片导出、微信口令与 AirDrop）
public struct StoredItemShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let item: StoredItem

    @State private var toastMessage: String?
    @State private var renderedImage: UIImage?
    @State private var showSystemShareSheet: Bool = false
    @State private var showNearbySheet: Bool = false
    @State private var showAirDropSheet: Bool = false
    @State private var airdropItems: [Any] = []

    public init(item: StoredItem) {
        self.item = item
    }

    private var storageEnvelope: UniversalShareEnvelope {
        UniversalShareEnvelope.forStorage(item: item)
    }

    private var cardView: StoredItemShareCard {
        StoredItemShareCard(item: item)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    // 操作按钮组
                    VStack(spacing: 12) {
                        // 碰一碰直传
                        Button {
                            showNearbySheet = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wave.3.forward.circle.fill")
                                    .font(.title3)
                                Text("碰一碰 · 附近设备直传")
                            }
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.indigo)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存收纳卡片到相册")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            Button {
                                copyShareToken()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.on.doc")
                                    Text("复制微信口令")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button {
                                shareViaAirDrop()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "airdrop")
                                    Text("AirDrop 文件")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            shareViaSystem()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("直接分享卡片图片")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享收纳位置")
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
        .sheet(isPresented: $showSystemShareSheet, onDismiss: { renderedImage = nil }) {
            if let renderedImage {
                ShareActivityView(activityItems: [renderedImage])
            }
        }
        .sheet(isPresented: $showNearbySheet) {
            NearbyInteractionSheet(envelope: storageEnvelope)
        }
        .sheet(isPresented: $showAirDropSheet, onDismiss: { airdropItems = [] }) {
            ShareActivityView(activityItems: airdropItems)
        }
    }

    @MainActor
    private func renderImage() -> UIImage? {
        ShareCardActions.render(cardView)
    }

    private func saveToPhotos() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存收纳卡片至相册 📸"))
        }
    }

    private func shareViaSystem() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        self.renderedImage = image
        self.showSystemShareSheet = true
        Haptic.light()
    }

    private func copyShareToken() {
        UIPasteboard.general.string = storageEnvelope.generateShareText()
        Haptic.success()
        showToast("已复制物品收纳口令 📦")
    }

    private func shareViaAirDrop() {
        if let fileURL = AssistantPackageService.createPackageFile(for: storageEnvelope) {
            self.airdropItems = [fileURL]
            self.showAirDropSheet = true
            Haptic.selection()
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}
