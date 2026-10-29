import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// 语音备忘的**块级编辑器**（锤子笔记式）。
///
/// 交互模型（与设计稿一致）：
/// - 点按段落 → 跳回录音对应时间点并高亮该段
/// - 长按段落 → 就地进入编辑，单段独立保存
/// - 底部样式栏 → 切换段落类型（正文 / 标题 / 列表 / 待办 / 引用）
/// - 「插入」→ 从相册选图、拍摄图片、引用原声片段
///
/// 两条实现纪律：
/// 1. **时间戳不可臆造**：只有块自带有效区间时才会显示时间戳标签，
///    点按跳转也只在有区间时生效。
/// 2. **图片存文件、块里存文件名**：不在 SwiftData 里塞二进制。
struct VoiceMemoBlockEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var memo: VoiceMemo
    @StateObject private var audio = VoiceMemoAudioService.shared

    /// 编辑中的文档副本。离开时才写回模型，避免每次按键都落库。
    @State private var document: MemoDocument = MemoDocument()
    /// 正在就地编辑的块 ID
    @State private var editingBlockID: UUID?
    /// 正在编辑的块文本
    @State private var editingText: String = ""
    /// 选中的段落（用于高亮 + 样式切换的作用对象）
    @State private var selectedBlockID: UUID?
    /// 当前块类型（样式栏选中项）
    @State private var currentKind: MemoBlockKind = .paragraph
    /// 显示插入菜单
    @State private var showInsertSheet = false
    /// 图片选择器
    @State private var showPhotoPicker = false
    /// 相机
    @State private var showCamera = false
    /// 引用原声片段（选择区间）
    @State private var showClipPicker = false

    private var fileMissing: Bool { !VoiceMemoStorage.exists(memo.audioFileName) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    playbackBar
                    hintBar
                    blocksCanvas
                    addBlockButton
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("编辑转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }.bold()
                }
            }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    styleToolbar
                }
            }
            .sheet(isPresented: $showInsertSheet) {
                insertMenu
            }
            .sheet(isPresented: $showPhotoPicker) {
                photoPicker
            }
            .fullScreenCover(isPresented: $showCamera) {
                cameraPicker
            }
            .sheet(isPresented: $showClipPicker) {
                VoiceMemoClipPickerSheet(memo: memo) { range in
                    insertAudioClip(range)
                }
            }
        }
        .onAppear {
            document = memo.document
            if document.title.isEmpty { document.title = memo.title }
        }
    }

    // MARK: - 播放条

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Button {
                audio.togglePlayback(fileName: memo.audioFileName)
                Haptic.light()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(fileMissing)

            Text(playbackText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if !fileMissing {
                Text("点段落可跳转")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    private var isPlaying: Bool {
        audio.playingFileName == memo.audioFileName && audio.isPlaying
    }

    private var playbackText: String {
        let current = audio.playingFileName == memo.audioFileName ? audio.playbackTime : 0
        return "\(formatMemoDuration(current)) / \(formatMemoDuration(memo.duration))"
    }

    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
            Text("点按段落跳回录音，长按段落就地编辑")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    // MARK: - 块画布

    private var blocksCanvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
    }

    @ViewBuilder
    private func blockView(_ block: MemoBlock) -> some View {
        if editingBlockID == block.id {
            editingBlockView(block)
        } else {
            switch block.kind {
            case .image:
                imageBlockView(block)
            case .audio:
                audioBlockView(block)
            default:
                textBlockView(block)
            }
        }
    }

    /// 文字类块（正文 / 标题 / 列表 / 待办 / 引用）。
    private func textBlockView(_ block: MemoBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let range = block.timeRange, range.isValid {
                // 只有真实区间才显示时间戳——没有区间就不显示，绝不编一个
                Button {
                    seek(to: range)
                } label: {
                    Text(MemoShareCardContent.format(range.start))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(block.isSeekable ? Color.red : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                switch block.kind {
                case .heading:
                    HStack(alignment: .center, spacing: 8) {
                        RoundedRectangle(cornerRadius: AppRadius.hairline)
                            .fill(Color.red)
                            .frame(width: 3, height: 17)
                        Text(block.text)
                            .font(.headline)
                    }
                case .bullet:
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 7)
                        Text(block.text).font(.body)
                    }
                case .todo:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: block.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(block.isDone ? Color.green : Color.secondary)
                            .padding(.top, 1)
                        Text(block.text)
                            .font(.body)
                            .strikethrough(block.isDone)
                            .foregroundStyle(block.isDone ? Color.secondary : Color.primary)
                    }
                case .quote:
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: AppRadius.hairline)
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 2)
                        Text(block.text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                default:
                    Text(block.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // 点按：跳回录音。带区间的才跳，否则只是选中。
                if let range = block.timeRange, range.isValid, block.isSeekable {
                    seek(to: range)
                } else {
                    select(block)
                }
            }
            .onLongPressGesture {
                beginEditing(block)
            }
        }
        .padding(.vertical, 2)
        .background(selectedBlockID == block.id ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    /// 就地编辑中的块。
    private func editingBlockView(_ block: MemoBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editingText)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
            HStack {
                Button("取消") {
                    editingBlockID = nil
                    editingText = ""
                }
                .font(.subheadline)
                Spacer()
                Button("保存") {
                    commitEditing(block)
                }
                .font(.subheadline.bold())
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    /// 图片块。
    private func imageBlockView(_ block: MemoBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = block.imageFileName,
               let data = VoiceMemoImageStorage.loadData(name),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            } else {
                // 图片文件丢了：明确告知，不留空白框
                Label("图片已丢失", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            if let caption = block.imageCaption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(block) }
        .onLongPressGesture { beginEditing(block) }
    }

    /// 语音片段块。
    private func audioBlockView(_ block: MemoBlock) -> some View {
        HStack(spacing: 10) {
            Button {
                if let range = block.timeRange, range.isValid {
                    seek(to: range)
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(MemoShareCardContent.audioCaption(for: block.timeRange))
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("引用本条录音 · 点击可跳转播放")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { select(block) }
    }

    private var addBlockButton: some View {
        Button {
            let block = MemoBlock(kind: currentKind, text: "")
            document.blocks.append(block)
            beginEditing(block)
        } label: {
            Label("添加段落", systemImage: "plus")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    // MARK: - 底部样式栏

    private var styleToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach([MemoBlockKind.paragraph, .heading, .bullet, .todo, .quote], id: \.self) { kind in
                    kindChip(kind)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                toolbarButton("bold", label: "加粗") { toggleStyle(.bold) }
                toolbarButton("italic", label: "斜体") { toggleStyle(.highlight) }
                toolbarButton("clock", label: "时间戳") { insertTimestampChip() }
                toolbarButton("photo", label: "插入") { showInsertSheet = true }
                Spacer(minLength: 0)
                Button {
                    showInsertSheet = true
                } label: {
                    Label("生成分享图", systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func kindChip(_ kind: MemoBlockKind) -> some View {
        let isSelected = currentKind == kind
        return Button {
            currentKind = kind
            applyKindToSelection(kind)
            Haptic.selection()
        } label: {
            Text(kindLabel(kind))
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.red : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func toolbarButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptic.light()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func kindLabel(_ kind: MemoBlockKind) -> String {
        switch kind {
        case .paragraph: return "正文"
        case .heading: return "标题"
        case .bullet: return "列表"
        case .todo: return "待办"
        case .quote: return "引用"
        case .image: return "图片"
        case .audio: return "语音"
        }
    }

    // MARK: - 行为

    private func select(_ block: MemoBlock) {
        selectedBlockID = block.id
        currentKind = block.kind
    }

    private func beginEditing(_ block: MemoBlock) {
        editingBlockID = block.id
        editingText = block.kind.carriesText ? block.text : ""
        selectedBlockID = block.id
        currentKind = block.kind
        Haptic.light()
    }

    private func commitEditing(_ block: MemoBlock) {
        if let index = document.blocks.firstIndex(where: { $0.id == block.id }) {
            let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空段落直接删掉，不留空壳
            if trimmed.isEmpty {
                document.blocks.remove(at: index)
            } else {
                document.blocks[index].text = editingText
            }
        }
        editingBlockID = nil
        editingText = ""
        Haptic.success()
    }

    /// 把当前选中的段落改成指定类型。
    private func applyKindToSelection(_ kind: MemoBlockKind) {
        guard let id = selectedBlockID,
              let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        document.blocks[index].kind = kind
    }

    /// 切换选中段落的强调样式。
    private func toggleStyle(_ style: MemoBlockStyle) {
        guard let id = selectedBlockID,
              let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        document.blocks[index].style = document.blocks[index].style == style ? .plain : style
    }

    /// 在末尾插入一个带时间戳的段落。
    ///
    /// 时间戳取当前播放位置——这是**真实**位置，不是估算。
    private func insertTimestampChip() {
        guard audio.playingFileName == memo.audioFileName, audio.playbackTime > 0 else {
            Haptic.warning()
            return
        }
        let range = MemoTimeRange(start: audio.playbackTime, end: audio.playbackTime)
        document.blocks.append(
            MemoBlock(kind: .paragraph, text: "", timeRange: range)
        )
        Haptic.light()
    }

    private func seek(to range: MemoTimeRange) {
        guard !fileMissing else { return }
        if audio.playingFileName != memo.audioFileName {
            audio.prepare(fileName: memo.audioFileName)
        }
        audio.seek(to: range.start)
        Haptic.light()
    }

    private func save() {
        memo.apply(document: document)
        try? context.save()
        Haptic.success()
        dismiss()
    }

    // MARK: - 插入

    private var insertMenu: some View {
        NavigationStack {
            List {
                Section {
                    insertOption(
                        title: "从相册选图",
                        subtitle: "会议白板、文档截图、实物照片",
                        systemImage: "photo",
                        tint: .red
                    ) {
                        showPhotoPicker = true
                        showInsertSheet = false
                    }
                    insertOption(
                        title: "拍摄图片",
                        subtitle: "边讲边拍，直接嵌入当前段落",
                        systemImage: "camera",
                        tint: .green
                    ) {
                        showCamera = true
                        showInsertSheet = false
                    }
                    insertOption(
                        title: "引用原声片段",
                        subtitle: "截取本条录音的一段，保留原声与时间点",
                        systemImage: "waveform",
                        tint: .red
                    ) {
                        showClipPicker = true
                        showInsertSheet = false
                    }
                    // 外部音频导入：项目当前没有该能力，明确置灰并说明原因，
                    // 不做一个点了没反应的入口。
                    HStack(spacing: 14) {
                        Image(systemName: "doc")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("导入音频文件（暂不支持）")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text("当前仅能引用本条录音，暂不支持外部音频导入")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .opacity(0.5)
                }
            }
            .navigationTitle("插入到笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showInsertSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func insertOption(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $pickerItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Text("选择图片")
        }
        .onChange(of: pickerItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let fileName = VoiceMemoImageStorage.save(data: data) {
                    appendImageBlock(fileName: fileName, caption: nil)
                }
            }
        }
    }

    @State private var pickerItem: PhotosPickerItem?

    private var cameraPicker: some View {
        ImagePickerView { image in
            if let data = image.jpegData(compressionQuality: 0.85),
               let fileName = VoiceMemoImageStorage.save(data: data) {
                appendImageBlock(fileName: fileName, caption: nil)
            }
        }
        .ignoresSafeArea()
    }

    private func appendImageBlock(fileName: String, caption: String?) {
        document.blocks.append(
            MemoBlock(kind: .image, imageFileName: fileName, imageCaption: caption)
        )
        Haptic.success()
    }

    /// 插入语音片段：引用同一条录音的区间，**不复制音频文件**。
    private func insertAudioClip(_ range: MemoTimeRange) {
        document.blocks.append(
            MemoBlock(kind: .audio, text: "原声片段", timeRange: range)
        )
        Haptic.success()
    }
}

/// 极简相机取景器（`UIImagePickerController` 的 SwiftUI 包装）。
struct ImagePickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

/// 选取原声片段：从录音里挑一段区间插入笔记。
///
/// 区间选择基于**真实音频时长**，不估算。
struct VoiceMemoClipPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let memo: VoiceMemo
    let onPick: (MemoTimeRange) -> Void

    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    private var fileMissing: Bool { !VoiceMemoStorage.exists(memo.audioFileName) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if fileMissing {
                    ContentUnavailableView(
                        "音频文件已丢失",
                        systemImage: "exclamationmark.triangle",
                        description: Text("无法截取原声片段。")
                    )
                } else {
                    Text("选择要引用的原声区间")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("\(MemoShareCardContent.format(start)) – \(MemoShareCardContent.format(end))")
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .monospacedDigit()

                    Slider(value: $start, in: 0...max(duration, 1)) { editing in
                        if !editing { end = max(end, start + 1) }
                    }
                    .tint(.red)

                    Slider(value: $end, in: 0...max(duration, 1)) { editing in
                        if !editing { end = max(end, start + 1) }
                    }
                    .tint(.red)

                    HStack {
                        Text("起点 \(MemoShareCardContent.format(start))")
                        Spacer()
                        Text("终点 \(MemoShareCardContent.format(end))")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button {
                        onPick(MemoTimeRange(start: start, end: end))
                        dismiss()
                    } label: {
                        Text("插入这段原声")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(end <= start)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("引用原声片段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                duration = memo.duration
                end = min(duration, 30)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
