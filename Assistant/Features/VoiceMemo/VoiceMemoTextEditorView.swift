import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI

/// 纯文字备忘的编辑页。
///
/// 与语音备忘共用同一个 `VoiceMemo` 模型、详情页、分享卡与备份链路，
/// 只是没有音频：`audioFileName` 为空串、`isTextOnly = true`、`segments` 为空。
/// 支持富文本正文、插入图片与拍照，生成精美图文笔记与分享长图。
struct VoiceMemoTextEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建；非 nil = 编辑已有文字备忘。
    let memo: VoiceMemo?

    @State private var title = ""
    @State private var bodyText = ""
    @State private var tag: VoiceMemoTag = .inspiration
    /// 附加的图片附件
    @State private var attachedImages: [AttachedImage] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showCamera = false
    /// 进页面时的标题原文，用来判断用户是否真的动过标题。
    @State private var originalTitle = ""
    @State private var saveError: String?
    @State private var alertTitle = "保存失败"
    /// 「保存并生成分享图」：先落库，再把分享面板挂在本页上方。
    @State private var shareTarget: VoiceMemo?
    @State private var showShareSheet = false

    struct AttachedImage: Identifiable, Equatable {
        let id: UUID
        var fileName: String
        var caption: String?

        init(id: UUID = UUID(), fileName: String, caption: String? = nil) {
            self.id = id
            self.fileName = fileName
            self.caption = caption
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("标题") {
                    TextField("给它起个标题", text: $title)
                        .font(.headline)
                }

                Section("分类") {
                    Picker("分类", selection: $tag) {
                        ForEach(VoiceMemoTag.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("正文") {
                    ZStack(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text("写下此时此刻的灵感、想法或备忘…")
                                .font(.callout)
                                .foregroundStyle(Color(.placeholderText))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $bodyText)
                            .frame(minHeight: 180)
                            .font(.callout)
                    }
                }

                Section("图片附件") {
                    if !attachedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(attachedImages) { item in
                                    imageThumbnail(item)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }

                    HStack(spacing: 12) {
                        PhotosPicker(
                            selection: $selectedPhotos,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("从相册选择")
                                    .font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                        }
                        .buttonStyle(.plain)

                        Button {
                            showCamera = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("拍摄照片")
                                    .font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    // 显性主入口，不藏进菜单：写完就能出图，不必先回列表再点开详情。
                    Button {
                        commit(andShare: true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                            Text("保存并生成分享长图")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            LinearGradient(
                                colors: [Color.red, Color(red: 0.90, green: 0.18, blue: 0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        )
                        .foregroundStyle(.white)
                        .shadow(color: Color.red.opacity(0.25), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("保存并生成分享长图")

                    Text("内容只存在本机。也可以先保存，之后从详情页点「生成长图」；支持图文混排、四套主题与水印。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .themedScrollContentBackground()
            .themedAppBackground()
            .navigationTitle(memo == nil ? "新建文字备忘" : "编辑文字备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit() }.bold()
                }
            }
            .onAppear(perform: load)
            .onChange(of: selectedPhotos) { _, items in
                handlePickedPhotos(items)
            }
            .fullScreenCover(isPresented: $showCamera) {
                ImagePickerView { image in
                    if let data = image.jpegData(compressionQuality: 0.85),
                       let fileName = VoiceMemoImageStorage.save(data: data) {
                        attachedImages.append(AttachedImage(fileName: fileName))
                        Haptic.success()
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showShareSheet, onDismiss: { dismiss() }) {
                if let shareTarget {
                    VoiceMemoShareSheet(memo: shareTarget)
                }
            }
            .alert(alertTitle, isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    @ViewBuilder
    private func imageThumbnail(_ item: AttachedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let data = VoiceMemoImageStorage.loadData(item.fileName),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 80, height: 80)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }

            Button {
                withAnimation(.snappy) {
                    attachedImages.removeAll { $0.id == item.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.red)
            }
            .offset(x: 6, y: -6)
            .iconButton("移除图片")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let fileName = VoiceMemoImageStorage.save(data: data) {
                    await MainActor.run {
                        attachedImages.append(AttachedImage(fileName: fileName))
                    }
                }
            }
            await MainActor.run {
                selectedPhotos = []
                Haptic.success()
            }
        }
    }

    private func load() {
        guard let memo else { return }
        title = memo.displayTitle
        originalTitle = memo.displayTitle
        tag = memo.tag
        bodyText = memo.transcription ?? memo.document.plainText
        attachedImages = memo.document.blocks.compactMap { block in
            guard block.kind == .image, let name = block.imageFileName else { return nil }
            return AttachedImage(fileName: name, caption: block.imageCaption)
        }
    }

    private func commit(andShare: Bool = false) {
        let hasText = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !attachedImages.isEmpty

        // 空内容不该产出一张「暂无可分享的内容」的卡片。
        if andShare && !hasText && !hasImages {
            alertTitle = "还没有内容"
            saveError = "先写点正文或添加图片，再生成分享图。"
            Haptic.warning()
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 标题留空时先用正文首句兜底，没有正文则退回默认标题
        let finalTitle = trimmedTitle.isEmpty
            ? (VoiceMemoTextAnalyzer.suggestedTitle(from: bodyText)
               ?? VoiceMemo.defaultTitle(isTextOnly: true))
            : trimmedTitle

        let target: VoiceMemo
        if let memo {
            target = memo
            target.title = finalTitle
            target.tag = tag
        } else {
            let newMemo = VoiceMemo(title: finalTitle, duration: 0, audioFileName: "", tag: tag)
            newMemo.isTextOnly = true
            context.insert(newMemo)
            target = newMemo
        }

        let titleChanged = trimmedTitle != originalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            target.titleIsUserEdited = false
        } else if titleChanged {
            target.titleIsUserEdited = true
        }

        // 构建完整笔记文档：正文文字块 + 图片块
        var document = MemoBlockBuilder.build(from: bodyText, title: finalTitle)
        for img in attachedImages {
            document.blocks.append(
                MemoBlock(kind: .image, imageFileName: img.fileName, imageCaption: img.caption)
            )
        }
        target.apply(document: document)

        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存文字备忘") }) else {
            Haptic.error()
            alertTitle = "保存失败"
            saveError = "保存失败，内容仍保留在页面上，可以重试。"
            return
        }
        Haptic.success()
        if andShare {
            shareTarget = target
            showShareSheet = true
        } else {
            dismiss()
        }
    }
}
