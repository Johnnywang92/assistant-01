import AssistantCore
import SwiftData
import SwiftUI
import UIKit

/// 语音备忘的社交分享卡片。
///
/// 复用 `ShareCardTheme` 四套主题与待办卡片同款的 3x 离屏光栅化管线，
/// 保证不同模块的分享卡片视觉一致。
///
/// **一条硬约束：图片无法携带声音。**
/// 因此语音片段块在卡片上只呈现为「原声片段 + 时间区间」的可视标识，
/// 并明确写出「完整录音可听」——不能让人误以为原声已经随图片发出去了。
struct VoiceMemoShareCardView: View {
    let title: String
    let items: [MemoShareCardItem]
    let hiddenImages: Int
    let hiddenAudio: Int
    let theme: ShareCardTheme
    let showWatermark: Bool

    static let sloganZh = "记所想，助所行"
    static let sloganEn = "Capture thoughts, empower actions."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 卡片头部：日期与标题
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VOICE MEMO")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accentColor)
                        .tracking(1.0)

                    Text(title)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            Rectangle().fill(theme.dividerColor).frame(height: 1)

            // 2. 内容块
            if items.isEmpty {
                Text("暂无可分享的内容")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryTextColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        row(for: item)
                    }
                }
            }

            // 3. 被折叠内容的显式提示（不能静默丢弃）
            if hiddenImages > 0 || hiddenAudio > 0 {
                HStack(spacing: 4) {
                    if hiddenImages > 0 {
                        Text("还有 \(hiddenImages) 张图片")
                    }
                    if hiddenImages > 0 && hiddenAudio > 0 {
                        Text("·")
                    }
                    if hiddenAudio > 0 {
                        Text("还有 \(hiddenAudio) 段原声")
                    }
                    Text("未在卡片中展示")
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)
            }

            // 4. 页脚水印
            if showWatermark {
                Rectangle().fill(theme.dividerColor).frame(height: 1).padding(.top, 4)
                HStack(spacing: 10) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("小助")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.textColor)
                        Text(Self.sloganZh)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                        Text(Self.sloganEn)
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    Spacer()
                    Text("JohnnyBoyStudio")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.secondaryTextColor)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 350, alignment: .leading)
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.6), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 5)
    }

    @ViewBuilder
    private func row(for item: MemoShareCardItem) -> some View {
        switch item.kind {
        case .heading:
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 16)
                Text(item.text)
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(theme.textColor)
            }
        case .paragraph:
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.textColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(theme.accentColor).frame(width: 4, height: 4).padding(.top, 7)
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textColor)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .todo:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.isDone ? theme.accentColor : theme.secondaryTextColor.opacity(0.7))
                Text(item.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(item.isDone ? theme.secondaryTextColor : theme.textColor)
                    .strikethrough(item.isDone)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.secondaryTextColor.opacity(0.6))
                    .frame(width: 2)
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryTextColor)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .image:
            imageRow(for: item)
        case .audio:
            // 图片无法携带声音：这里只做可视标识，并明确说明原声需另外获取
            HStack(spacing: 7) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accentColor)
                Text(MemoShareCardContent.audioCaption(for: item.timeRange))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.accentColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(theme.accentColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func imageRow(for item: MemoShareCardItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let name = item.imageFileName,
               let data = VoiceMemoImageStorage.loadData(name),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                // 图片文件丢了：明确写出来，不留一个空白框让人以为卡片坏了
                Label("图片已丢失", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryTextColor)
                    .padding(.vertical, 10)
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
    }
}

/// 语音备忘分享面板：卡片预览 + 样式切换 + 导出与分享。
struct VoiceMemoShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let memo: VoiceMemo

    @State private var theme: ShareCardTheme = .paper
    @State private var showWatermark = true
    @State private var includeImages = true
    @State private var includeAudio = true
    @State private var renderedImage: UIImage?
    @State private var showSystemShareSheet = false
    @State private var toastMessage: String?

    private var document: MemoDocument { memo.document }

    private var items: [MemoShareCardItem] {
        MemoShareCardContent.items(
            from: document.blocks,
            includeImages: includeImages,
            includeAudio: includeAudio
        )
    }

    private var hiddenCounts: (images: Int, audio: Int) {
        MemoShareCardContent.hiddenCounts(
            from: document.blocks,
            includeImages: includeImages,
            includeAudio: includeAudio
        )
    }

    private var cardView: VoiceMemoShareCardView {
        VoiceMemoShareCardView(
            title: document.title.isEmpty ? memo.title : document.title,
            items: items,
            hiddenImages: hiddenCounts.images,
            hiddenAudio: hiddenCounts.audio,
            theme: theme,
            showWatermark: showWatermark
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 1. 卡片预览
                    cardView
                        .padding(.top, 8)

                    // 2. 样式切换
                    themeSection

                    // 3. 导出选项
                    optionsSection

                    // 4. 分享目标
                    shareTargetsSection

                    // 5. 主操作
                    actionButtons
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享语音笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $showSystemShareSheet, onDismiss: { renderedImage = nil }) {
            if let renderedImage {
                ShareActivityView(activityItems: [renderedImage])
            }
        }
    }

    // MARK: - 样式切换

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("卡片样式")
                    .font(.headline)
                Spacer()
                Text("沿用待办卡片主题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ShareCardTheme.allCases) { option in
                        themeSwatch(option)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func themeSwatch(_ option: ShareCardTheme) -> some View {
        let isSelected = theme == option
        return Button {
            theme = option
            Haptic.selection()
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(option.backgroundColor)
                    .frame(width: 54, height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.red : Color(.separator),
                                lineWidth: isSelected ? 2 : 0.8
                            )
                    )
                    .overlay(
                        Text("Aa")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(option.textColor)
                    )
                Text(option.rawValue)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.red : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 导出选项

    private var optionsSection: some View {
        VStack(spacing: 0) {
            toggleRow(
                title: "显示品牌水印",
                isOn: $showWatermark
            )
            Divider().padding(.leading, 14)
            toggleRow(
                title: "包含图片",
                isOn: $includeImages
            )
            Divider().padding(.leading, 14)
            toggleRow(
                title: "包含原声片段",
                isOn: $includeAudio
            )
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.body)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 分享目标

    private var shareTargetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .foregroundStyle(.red)
                Text("分享到社交平台")
                    .font(.headline)
            }
            HStack(spacing: 12) {
                shareTarget("朋友圈", systemImage: "person.2.fill", tint: .green)
                shareTarget("小红书", systemImage: "book.fill", tint: .red)
                shareTarget("微博", systemImage: "at", tint: .orange)
                shareTarget("更多", systemImage: "ellipsis", tint: .secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func shareTarget(_ title: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    saveToPhotos()
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    shareImage()
                } label: {
                    Label("分享图片", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            // 隐私口径与现有分享卡片保持一致：图片在本机渲染，音频与转写不上传
            Text("图片在本机渲染生成，音频与转写不会上传")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 渲染与导出

    /// 3x 离屏光栅化，并压平透明通道（与待办分享卡片同款管线）。
    private func renderCard() -> UIImage? {
        ShareCardActions.render(cardView, flattenAlpha: true)
    }

    private func saveToPhotos() {
        guard let image = renderCard() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存到相册"))
        }
    }

    private func shareImage() {
        guard let image = renderCard() else {
            showToast("生成图片失败")
            return
        }
        renderedImage = image
        showSystemShareSheet = true
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { toastMessage = nil }
        }
    }
}
