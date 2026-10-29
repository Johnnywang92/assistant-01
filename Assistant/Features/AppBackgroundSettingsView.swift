import PhotosUI
import SwiftUI

/// App 背景与主题外观设置界面
@MainActor
struct AppBackgroundSettingsView: View {
    @ObservedObject private var manager = AppBackgroundManager.shared
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        let customImage = manager.customImage
        Form {
            // MARK: - 1. 实时微缩预览窗
            Section {
                VStack(spacing: 12) {
                    // 微缩预览卡片
                    ZStack {
                        // 预览背景层
                        AppBackgroundView()

                        // 预览前景仿真界面
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("小助 · 预览效果")
                                    .font(.system(size: 11, weight: .bold))
                                Spacer()
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tint)
                            }

                            // 仿真待办卡片
                            HStack(spacing: 8) {
                                Image(systemName: "cube.box.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("顺丰速运（取件码 8-204）")
                                        .font(.system(size: 10, weight: .medium))
                                    Text("菜鸟驿站北门架 02")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(Color(.secondarySystemGroupedBackground).opacity(0.88))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))

                            // 仿真记账卡片
                            HStack {
                                Text("今日已支出 ¥38.00")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("已清点完成")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 2)
                        }
                        .padding(14)
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 3)

                    HStack {
                        Text("当前主题：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr(manager.currentStyle.rawValue))
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                        Spacer()
                        Text(manager.currentStyle.description)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("实机效果预览")
            }

            // MARK: - 2. 预设背景主题库
            Section("精选质感主题") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(AppBackgroundStyle.allCases) { style in
                        ThemeOptionCard(style: style, isSelected: manager.currentStyle == style) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                manager.currentStyle = style
                            }
                            Haptic.selection()
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            // MARK: - 3. 自选壁纸微调面板
            if manager.currentStyle == .customImage {
                Section("自定义壁纸参数微调") {
                    // 相册选取照片
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack {
                            Label(customImage == nil ? "从相册选择照片壁纸" : "更换相册壁纸", systemImage: "photo.badge.plus")
                            Spacer()
                            if let img = customImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                            }
                        }
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task { @MainActor in
                            if let data = try? await newItem?.loadTransferable(type: Data.self),
                               let uiImg = UIImage(data: data) {
                                manager.saveCustomImage(uiImg)
                            }
                        }
                    }

                    if customImage != nil {
                        // 毛玻璃模糊度滑块
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("毛玻璃模糊度")
                                Spacer()
                                Text("\(Int(manager.blurRadius)) pt")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $manager.blurRadius, in: 0...30, step: 1)
                        }

                        // 暗度遮罩滑块
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("暗色遮罩透明度 (提升文字可读性)")
                                Spacer()
                                Text("\(Int(manager.dimOpacity * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $manager.dimOpacity, in: 0.0...0.7, step: 0.05)
                        }

                        Button("移除自选壁纸", role: .destructive) {
                            withAnimation {
                                manager.removeCustomImage()
                            }
                            Haptic.light()
                        }
                    }
                }
            }

            // MARK: - 4. 恢复默认
            if manager.isCustomBackgroundActive {
                Section {
                    Button("恢复系统默认背景") {
                        withAnimation {
                            manager.currentStyle = .system
                        }
                        Haptic.light()
                    }
                }
            }
        }
        .scrollContentBackground(manager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedAppBackground()
        .themedRow()
        .navigationTitle("主题与背景设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 主题卡片单元
private struct ThemeOptionCard: View {
    let style: AppBackgroundStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // 色块预览小圆球与图标
                HStack {
                    ZStack {
                        previewSwatch(for: style)
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())

                        Image(systemName: style.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(iconColor(for: style))
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .font(.subheadline)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr(style.rawValue))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)

                    Text(style.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(isSelected ? Color.tintColorOrAccent.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func previewSwatch(for style: AppBackgroundStyle) -> some View {
        switch style {
        case .system:
            Color(.systemGray4)
        case .aurora:
            LinearGradient(colors: [.cyan, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .midnight:
            LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
        case .sunset:
            LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mint:
            LinearGradient(colors: [.mint, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .paper:
            Color(hex: "F8F6F0")
        case .pureDark:
            Color.black
        case .customImage:
            Color(.systemBlue).opacity(0.25)
        }
    }

    private func iconColor(for style: AppBackgroundStyle) -> Color {
        switch style {
        case .midnight, .pureDark: return .white
        case .paper: return .black
        default: return .primary
        }
    }
}

extension Color {
    fileprivate static var tintColorOrAccent: Color {
        .accentColor
    }
}
