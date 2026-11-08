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
    /// 保存失败的提示：失败时不关闭页面，保留用户正在编辑的内容
    @State private var saveError: String?

    private var fileMissing: Bool { !memo.hasAudio || !VoiceMemoStorage.exists(memo.audioFileName) }

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
            .navigationTitle(memo.isTextOnly ? "排版编辑" : "编辑转写")
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
            // 标题以备忘标题为准：document.title 是写入时冻结的快照，
            // 用户在详情页改过标题后不该继续显示旧值。
            document.title = memo.title
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - 播放条

    @ViewBuilder
    private var playbackBar: some View {
        if memo.hasAudio {
            audioPlaybackBar
        }
    }

    private var audioPlaybackBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await audio.togglePlayback(fileName: memo.audioFileName) }
                Haptic.light()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .iconButton(isPlaying ? "暂停播放" : "播放录音")
            .disabled(fileMissing)

            VStack(alignment: .leading, spacing: 2) {
                Text("原声对齐播放")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(playbackText)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer()

            if !fileMissing {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                    Text("点段落时间戳可跳转")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
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
            Image(systemName: "hand.tap")
                .font(.caption)
            Text("点按选择段落，再次点按或长按就地编辑；通过下方工具栏切换排版样式")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    // MARK: - 块画布

    private var blocksCanvas: some View {
        VStack(alignment: .leading, spacing: 8) {
            if document.blocks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 24)
                    Text("暂无段落内容")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("点击下方「添加新段落」开始排版编辑")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            } else {
                ForEach(document.blocks) { block in
                    blockView(block)
                }
            }
        }
        .padding(14)
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
        let isSelected = selectedBlockID == block.id
        return HStack(alignment: .top, spacing: 8) {
            if let range = block.timeRange, range.isValid {
                Button {
                    seek(to: range)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(MemoShareCardContent.format(range.start))
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(block.isSeekable ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                switch block.kind {
                case .heading:
                    HStack(alignment: .center, spacing: 8) {
                        RoundedRectangle(cornerRadius: AppRadius.hairline)
                            .fill(Color.accentColor)
                            .frame(width: 3.5, height: 18)
                        Text(block.text)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.primary)
                    }
                case .bullet:
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)
                        Text(block.text)
                            .font(.body)
                    }
                case .todo:
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            toggleTodo(block)
                        } label: {
                            Image(systemName: block.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.body)
                                .foregroundStyle(block.isDone ? Color.green : Color.secondary)
                                .padding(.top, 1)
                        }
                        .buttonStyle(.plain)
                        .iconButton(block.isDone ? "标记为未完成" : "标记为已完成")

                        Text(block.text)
                            .font(.body)
                            .strikethrough(block.isDone)
                            .foregroundStyle(block.isDone ? Color.secondary : Color.primary)
                    }
                case .quote:
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: AppRadius.hairline)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                        Text(block.text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                    .padding(6)
                    .background(Color(.tertiarySystemFill).opacity(0.4), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                default:
                    Text(block.text)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if selectedBlockID == block.id {
                    beginEditing(block)
                } else {
                    if let range = block.timeRange, range.isValid, block.isSeekable {
                        seek(to: range)
                    }
                    select(block)
                }
            }
            .onLongPressGesture {
                beginEditing(block)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.08)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }

    /// 就地编辑中的块。
    private func editingBlockView(_ block: MemoBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                    Text("编辑\(kindLabel(block.kind))")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("取消") {
                    editingBlockID = nil
                    editingText = ""
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button {
                    commitEditing(block)
                } label: {
                    Text("保存")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                }
            }

            TextEditor(text: $editingText)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    /// 图片块。
    private func imageBlockView(_ block: MemoBlock) -> some View {
        let isSelected = selectedBlockID == block.id
        return VStack(alignment: .leading, spacing: 6) {
            if let name = block.imageFileName,
               let data = VoiceMemoImageStorage.loadData(name),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                            .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
                    )
            } else {
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
        .padding(8)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(block) }
        .onLongPressGesture { beginEditing(block) }
    }

    /// 语音片段块。
    private func audioBlockView(_ block: MemoBlock) -> some View {
        let isSelected = selectedBlockID == block.id
        return HStack(spacing: 12) {
            Button {
                if let range = block.timeRange, range.isValid {
                    seek(to: range)
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .iconButton("播放片段")

            VStack(alignment: .leading, spacing: 2) {
                Text(MemoShareCardContent.audioCaption(for: block.timeRange))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("引用原声录音片段 · 点按跳转播放")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(block) }
    }

    private var addBlockButton: some View {
        Button {
            let block = MemoBlock(kind: currentKind, text: "")
            document.blocks.append(block)
            beginEditing(block)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text("添加新段落")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 10) {
                toolbarButton("bold", label: "加粗", active: isSelectedBold) { toggleStyle(.bold) }
                toolbarButton("italic", label: "斜体", active: isSelectedItalic) { toggleStyle(.highlight) }
                if memo.hasAudio {
                    toolbarButton("clock", label: "插入当前时间戳") { insertTimestampChip() }
                }
                Button {
                    showInsertSheet = true
                    Haptic.light()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("插入")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if selectedBlockID != nil {
                    HStack(spacing: 6) {
                        toolbarButton("arrow.up", label: "上移段落") { moveSelectionUp() }
                        toolbarButton("arrow.down", label: "下移段落") { moveSelectionDown() }
                        toolbarButton("trash", label: "删除段落", tint: .red) { deleteSelection() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var isSelectedBold: Bool {
        guard let id = selectedBlockID,
              let block = document.blocks.first(where: { $0.id == id }) else { return false }
        return block.style == .bold
    }

    private var isSelectedItalic: Bool {
        guard let id = selectedBlockID,
              let block = document.blocks.first(where: { $0.id == id }) else { return false }
        return block.style == .highlight
    }

    private func kindChip(_ kind: MemoBlockKind) -> some View {
        let isSelected = currentKind == kind
        return Button {
            currentKind = kind
            applyKindToSelection(kind)
            Haptic.selection()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kindIcon(kind))
                    .font(.caption2)
                Text(kindLabel(kind))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor : Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func kindIcon(_ kind: MemoBlockKind) -> String {
        switch kind {
        case .paragraph: return "text.alignleft"
        case .heading: return "textformat.size"
        case .bullet: return "list.bullet"
        case .todo: return "checklist"
        case .quote: return "quote.opening"
        case .image: return "photo"
        case .audio: return "waveform"
        }
    }

    private func toolbarButton(
        _ systemName: String,
        label: String,
        active: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptic.light()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: active ? .bold : .medium))
                .frame(width: 32, height: 32)
                .background(
                    active ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                )
                .foregroundStyle(active ? Color.accentColor : (tint ?? Color.primary))
        }
        .buttonStyle(.plain)
        .iconButton(label)
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

    private func moveSelectionUp() {
        guard let id = selectedBlockID,
              let index = document.blocks.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.swapAt(index, index - 1)
        }
        Haptic.light()
    }

    private func moveSelectionDown() {
        guard let id = selectedBlockID,
              let index = document.blocks.firstIndex(where: { $0.id == id }),
              index < document.blocks.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.swapAt(index, index + 1)
        }
        Haptic.light()
    }

    private func deleteSelection() {
        guard let id = selectedBlockID,
              let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.remove(at: index)
        }
        selectedBlockID = nil
        editingBlockID = nil
        Haptic.medium()
    }

    private func toggleTodo(_ block: MemoBlock) {
        guard let index = document.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        document.blocks[index].isDone.toggle()
        Haptic.selection()
    }

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
        commitEditing(blockID: block.id)
        Haptic.success()
    }

    private func commitEditing(blockID: UUID) {
        if let index = document.blocks.firstIndex(where: { $0.id == blockID }) {
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
        // 顶层「完成」必须先把就地编辑中的草稿写回文档，否则刚改的文字会被静默丢弃
        if let editingBlockID {
            commitEditing(blockID: editingBlockID)
        }
        memo.apply(document: document)
        do {
            try context.save()
        } catch {
            // 落库失败就留在编辑页并如实提示，不假装保存成功
            saveError = L10n.choose(
                "保存失败：\(error.localizedDescription)",
                "Failed to save: \(error.localizedDescription)"
            )
            return
        }
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
                        tint: .blue
                    ) {
                        showPhotoPicker = true
                        showInsertSheet = false
                    }
                    insertOption(
                        title: "拍摄图片",
                        subtitle: "现场拍照，直接嵌入当前段落",
                        systemImage: "camera",
                        tint: .green
                    ) {
                        showCamera = true
                        showInsertSheet = false
                    }
                    if memo.hasAudio {
                        insertOption(
                            title: "引用原声片段",
                            subtitle: "截取本条录音的一段，保留原声与时间点",
                            systemImage: "waveform",
                            tint: .purple
                        ) {
                            showClipPicker = true
                            showInsertSheet = false
                        }
                    }
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

    private var fileMissing: Bool { !memo.hasAudio || !VoiceMemoStorage.exists(memo.audioFileName) }

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
                    .tint(.accentColor)

                    Slider(value: $end, in: 0...max(duration, 1)) { editing in
                        if !editing { end = max(end, start + 1) }
                    }
                    .tint(.accentColor)

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
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
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
