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
    /// 纯文字备忘复用同一套卡面与主题，但眉标必须区分类型：
    /// 写着 VOICE MEMO 会让人以为这张图背后还有录音可听。
    var isTextOnly: Bool = false

    static let sloganZh = "记所想，助所行"
    static let sloganEn = "Capture thoughts, empower actions."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 卡片头部：日期与标题
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isTextOnly ? "TEXT NOTE" : "VOICE MEMO")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accentColor)
                        .tracking(1.0)

                    Text(title)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
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
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))

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
        .frame(width: 350, alignment: .leading)
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.6), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 5)
    }

    @ViewBuilder
    private func row(for item: MemoShareCardItem) -> some View {
        switch item.kind {
        case .heading:
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: AppRadius.hairline)
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
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(theme.accentColor).frame(width: 4, height: 4).padding(.top, 7)
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textColor)
                    .lineSpacing(3)
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
            }
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: AppRadius.hairline)
                    .fill(theme.secondaryTextColor.opacity(0.6))
                    .frame(width: 2)
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryTextColor)
                    .italic()
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
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
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
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
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
    /// 当前待分享的那一张完整长图。
    @State private var renderedImage: UIImage?
    @State private var showSystemShareSheet = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    /// 分享卡标题设置：与备忘标题解耦，只影响导出的这张图片。
    @State private var titleSource: ShareCardTitleSource = .followMemo
    @State private var cardTitleDraft = ""

    private var document: MemoDocument { memo.document }

    private var items: [MemoShareCardItem] {
        MemoShareCardContent.items(
            from: document.blocks,
            includeImages: includeImages,
            includeAudio: includeAudio,
            maxImages: 50
        )
    }

    private var hiddenCounts: (images: Int, audio: Int) {
        MemoShareCardContent.hiddenCounts(
            from: document.blocks,
            includeImages: includeImages,
            includeAudio: includeAudio,
            maxImages: 50
        )
    }

    /// 卡片标题只跟着设置走，不再读 `document.title`——
    /// 那是结构化笔记写入时冻结的快照，详情页改了备忘标题它也不会变。
    private var resolvedCardTitle: String {
        switch titleSource {
        case .followMemo:
            return memo.title
        case .transcriptFirstSentence:
            return VoiceMemoTextAnalyzer.suggestedTitle(from: memo.transcription ?? "") ?? memo.title
        case .custom:
            let trimmed = cardTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? memo.title : trimmed
        }
    }

    private func persistTitleSettings() {
        memo.shareTitleSource = titleSource
        memo.shareTitle = titleSource == .custom ? cardTitleDraft : nil
        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存分享卡标题") }
    }

    /// 始终只渲染一张卡片，全部内容都在里面。
    private var cardView: VoiceMemoShareCardView {
        VoiceMemoShareCardView(
            title: resolvedCardTitle,
            items: items,
            hiddenImages: hiddenCounts.images,
            hiddenAudio: hiddenCounts.audio,
            theme: theme,
            showWatermark: showWatermark,
            isTextOnly: memo.isTextOnly
        )
    }

    /// 渲染前估算整张长图的高度，用来挑一个不会把图撑爆的倍率。
    /// 规则在 AssistantCore，可单测。
    private var estimatedCardHeight: CGFloat {
        CGFloat(MemoShareCardContent.estimatedCardHeight(for: items))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 1. 卡片预览：始终是一张完整长图，不分页
                    VStack(spacing: 8) {
                        cardView
                        if estimatedCardHeight > 1500 {
                            Text("内容较长，导出时会自动调整清晰度，仍只生成一张完整长图")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)

                    // 2. 卡片标题（只影响这张图）
                    titleSection

                    // 3. 样式切换
                    themeSection

                    // 4. 导出选项
                    optionsSection

                    // 5. 主操作
                    actionButtons
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                titleSource = memo.shareTitleSource
                cardTitleDraft = memo.shareTitle ?? ""
            }
            .navigationTitle(memo.isTextOnly ? "分享文字笔记" : "分享语音笔记")
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

    // MARK: - 卡片标题

    /// 标题只作用于导出的图片；改动即时落库，不写回备忘标题。
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("卡片标题").font(.headline)
                Spacer()
                Text("只影响这张图片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("输入卡片标题", text: $cardTitleDraft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onChange(of: cardTitleDraft) { _, newValue in
                    if newValue.count > 24 {
                        cardTitleDraft = String(newValue.prefix(24))
                        return
                    }
                    // 直接往输入框里打字就自动切到「自定义」，否则预览不会跟着变、也不落库。
                    // 只在非空时切：「恢复默认」清空草稿时不会把来源误切回去。
                    if !newValue.isEmpty, titleSource != .custom {
                        titleSource = .custom
                    }
                    if titleSource == .custom { persistTitleSettings() }
                }

            HStack {
                Text(titleSource == .custom ? "\(cardTitleDraft.count) / 24 字" : "跟随来源，不受字数限制")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    titleSource = .followMemo
                    cardTitleDraft = ""
                    persistTitleSettings()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            Picker("标题来源", selection: $titleSource) {
                ForEach(ShareCardTitleSource.allCases) { source in
                    // 纯文字备忘没有「转写」，同一来源要说成正文首句。
                    Text(memo.isTextOnly && source == .transcriptFirstSentence
                         ? "用正文首句"
                         : source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: titleSource) { _, newValue in
                if newValue == .custom, cardTitleDraft.isEmpty {
                    cardTitleDraft = memo.title
                }
                persistTitleSettings()
            }

            Text("切换来源会实时更新上方预览；自定义标题不会写回备忘标题。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
        )
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
    }

    private func themeSwatch(_ option: ShareCardTheme) -> some View {
        let isSelected = theme == option
        return Button {
            theme = option
            Haptic.selection()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                        .fill(option.backgroundColor)
                        .frame(width: 54, height: 54)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.red : Color(.separator),
                                    lineWidth: isSelected ? 2.5 : 0.8
                                )
                        )
                        .overlay(
                            Text("Aa")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(option.textColor)
                        )
                        .shadow(color: isSelected ? Color.red.opacity(0.25) : .clear, radius: 4, y: 2)

                    if isSelected {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 4, y: -4)
                    }
                }

                Text(option.rawValue)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.red : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.rawValue)主题")
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
            // 纯文字备忘没有音频块，放一个「包含原声片段」开关只会让人以为漏了内容。
            if !memo.isTextOnly {
                Divider().padding(.leading, 14)
                toggleRow(
                    title: "包含原声片段",
                    isOn: $includeAudio
                )
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
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

    // MARK: - 操作

    // 「朋友圈 / 小红书 / 微博 / 更多」这四个图标此前只是 VStack，不是按钮，
    // 点了没有任何反应。iOS 也不允许 App 在未接入各平台 SDK 时直接分享到指定平台，
    // 真实入口只有系统分享面板，所以移除这组假按钮，统一由下方「分享图片」承担。



    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    saveToPhotos()
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)

                Button {
                    shareImage()
                } label: {
                    Label("分享图片", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.red, Color(red: 0.90, green: 0.18, blue: 0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        )
                        .foregroundStyle(.white)
                        .shadow(color: Color.red.opacity(items.isEmpty ? 0 : 0.28), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
            }

            if items.isEmpty {
                Text("这条备忘还没有可分享的内容，先补点文字或完成离线转写。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Text("只生成一张完整长图；内容较长时会自动调整清晰度，不会切成多张。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("点「分享图片」后，可在系统面板里选择微信、小红书、微博等 App。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // 隐私口径与现有分享卡片保持一致：图片在本机渲染，内容不上传
            Text(memo.isTextOnly
                 ? "图片在本机渲染生成，笔记内容不会上传"
                 : "图片在本机渲染生成，音频与转写不会上传")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 渲染与导出

    /// 渲染成**一张**完整长图。
    /// 先按估算高度挑安全倍率再渲染，不做分页、不切片、也不做二次压平画布
    /// （长图二次画布会再吃一倍内存，本身就是裁切风险）。
    private func renderCard() -> UIImage? {
        ShareCardActions.render(cardView, estimatedHeight: estimatedCardHeight)
    }

    /// 连 1x 都放不下时说清楚原因，不要只丢一句「生成失败」。
    private var renderFailureHint: String {
        estimatedCardHeight > CGFloat(ShareCardRenderScale.maxPixelSide)
            ? "内容太长，无法生成一张完整的图片"
            : ShareCardActions.renderFailureMessage
    }

    private func saveToPhotos() {
        guard !items.isEmpty else {
            showToast("还没有可分享的内容")
            return
        }
        guard let image = renderCard() else {
            showToast(renderFailureHint)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存到相册"))
        }
    }

    private func shareImage() {
        guard !items.isEmpty else {
            showToast("还没有可分享的内容")
            return
        }
        guard let image = renderCard() else {
            showToast(renderFailureHint)
            return
        }
        renderedImage = image
        showSystemShareSheet = true
    }

    private func showToast(_ message: String) {
        // 连续两次提示时，旧的定时清理不能把新提示提前抹掉。
        let token = UUID()
        toastToken = token
        withAnimation(.snappy) { toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard toastToken == token else { return }
            withAnimation(.snappy) { toastMessage = nil }
        }
    }
}
