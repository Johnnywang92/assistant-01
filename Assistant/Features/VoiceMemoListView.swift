import AssistantCore
import SwiftData
import SwiftUI

/// 语音备忘录列表（离线录音、回放与转写归档）
struct VoiceMemoListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VoiceMemo.createdAt, order: .reverse) private var memos: [VoiceMemo]
    @StateObject private var audio = VoiceMemoAudioService.shared

    private let searchText = ""
    @State private var selectedTag: VoiceMemoTag?
    @State private var showRecorder = false
    @State private var showTextEditor = false
    @State private var memoToDelete: VoiceMemo?
    @State private var showResumeRecorder = false
    @State private var resumeMemo: VoiceMemo?
    /// 旧数据标题修正只跑一次（纯文字备忘却存着「语音备忘 <时间>」）。
    @State private var didNormalizeTitles = false

    /// 恢复卡只认「还能在数据里找到的那条备忘」：备忘被删后不显示，也不撒谎。
    private var pendingMemo: VoiceMemo? {
        guard let marker = audio.pendingResume else { return nil }
        return memos.first { $0.id == marker.memoID }
    }

    private func partitionedMemos() -> (filtered: [VoiceMemo], bookmarked: [VoiceMemo], others: [VoiceMemo]) {
        var filtered: [VoiceMemo] = []
        var bookmarked: [VoiceMemo] = []
        var others: [VoiceMemo] = []
        for m in memos {
            guard (selectedTag == nil || m.tag == selectedTag) &&
                  (searchText.isEmpty
                   || m.title.localizedCaseInsensitiveContains(searchText)
                   || (m.transcription?.localizedCaseInsensitiveContains(searchText) ?? false)) else {
                continue
            }
            filtered.append(m)
            if m.isBookmarked {
                bookmarked.append(m)
            } else {
                others.append(m)
            }
        }
        return (filtered, bookmarked, others)
    }

    var body: some View {
        let partitioned = partitionedMemos()
        let filtered = partitioned.filtered
        let bookmarked = partitioned.bookmarked
        let others = partitioned.others
        List {
            // 中断恢复横幅放进滚动内容流，随列表一起滑出，不固定在外层 VStack。
            if let pending = pendingMemo {
                Section {
                    resumeCard(pending)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !memos.isEmpty {
                tagFilterBar
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if !bookmarked.isEmpty {
                Section("星标") { ForEach(bookmarked) { row($0) } }
            }
            if !others.isEmpty {
                Section(bookmarked.isEmpty ? "全部录音 · \(others.count)" : "其他 · \(others.count)") {
                    ForEach(others) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .overlay {
            if memos.isEmpty {
                ContentUnavailableView(
                    "还没有备忘",
                    systemImage: "note.text.badge.plus",
                    description: Text("点「写文字」记灵感，或点「录语音」开始录音。\n内容仅保存在本机，支持生成长图与一键提取待办。")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("备忘录")
        .task { normalizeLegacyTitles() }
        .safeAreaInset(edge: .bottom) { recordDock }
        .sheet(isPresented: $showRecorder) {
            VoiceMemoRecorderSheet()
        }
        .sheet(isPresented: $showTextEditor) {
            VoiceMemoTextEditorView(memo: nil)
        }
        .sheet(isPresented: $showResumeRecorder, onDismiss: { resumeMemo = nil }) {
            VoiceMemoRecorderSheet(memo: resumeMemo)
        }
        .confirmationDialog(
            memoToDelete?.isTextOnly == true ? "删除这条文字备忘？" : "删除这条语音备忘？",
            isPresented: Binding(
                get: { memoToDelete != nil }, set: { if !$0 { memoToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(memoToDelete?.isTextOnly == true ? "删除备忘" : "删除录音与转写", role: .destructive) {
                if let m = memoToDelete { VoiceMemoActions.delete(m, context: context) }
                memoToDelete = nil
            }
        } message: {
            Text(memoToDelete?.isTextOnly == true
                 ? "文字内容将从本机永久删除，无法恢复。"
                 : "音频文件将从本机永久删除，无法恢复。")
        }
    }

    // MARK: - 子视图

    /// 中断恢复卡。文案只承诺「已落库的片段都在」，不声称能找回未保存的那一段。
    private func resumeCard(_ memo: VoiceMemo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("有一条录音没录完")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Text(memo.displayTitle)
                .font(.headline)
                .lineLimit(1)
            Text("已保存 \(memo.segments.count) 段 · 共 \(formatMemoDuration(memo.totalDuration))，接着录仍在这条备忘里。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    resumeRecording(memo)
                } label: {
                    Label("继续录这条", systemImage: "mic.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("以后再说") { audio.clearPendingResume() }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
            Text("中断时正在录的那一段没有保存，不会被找回")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.banner))
    }

    private func resumeRecording(_ memo: VoiceMemo) {
        // 上一次被中断的录音可能还挂在单例上；先收掉，否则新录音页会因 isRecording 直接不启动。
        if audio.isRecording { audio.cancelRecording() }
        audio.clearPendingResume()
        resumeMemo = memo
        showResumeRecorder = true
    }

    /// 旧记录修正：只处理默认标题，跑一次就够。
    private func normalizeLegacyTitles() {
        guard !didNormalizeTitles else { return }
        didNormalizeTitles = true
        guard VoiceMemoActions.normalizeLegacyTextMemoTitles(memos) else { return }
        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "修正文字备忘标题") }
    }

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", icon: "tray.full.fill", selected: selectedTag == nil) { selectedTag = nil }
                ForEach(VoiceMemoTag.allCases) { tag in
                    chip(title: L10n.tr(tag.rawValue), icon: tag.icon, selected: selectedTag == tag) {
                        selectedTag = (selectedTag == tag) ? nil : tag
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.selection()
            withAnimation(.snappy) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.tr(title))
                    .font(.caption.weight(selected ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(selected ? Color.red : Color(.secondarySystemFill))
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
            .shadow(color: selected ? Color.red.opacity(0.25) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func row(_ memo: VoiceMemo) -> some View {
        NavigationLink {
            VoiceMemoDetailView(memo: memo)
        } label: {
            VoiceMemoRow(memo: memo, audio: VoiceMemoAudioService.shared)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { memoToDelete = memo } label: { Label("删除", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button {
                memo.isBookmarked.toggle()
                context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
                Haptic.light()
            } label: {
                Label(memo.isBookmarked ? "取消星标" : "星标", systemImage: memo.isBookmarked ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
        .themedRow()
    }

    /// 底部并列双入口：悬浮胶囊控制岛，写文字与录音平衡呼应。
    private var recordDock: some View {
        HStack(spacing: 12) {
            Button {
                Haptic.light()
                showTextEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                    Text("写文字")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(.secondarySystemFill).opacity(0.8), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建纯文字备忘")

            Button {
                Haptic.medium()
                showRecorder = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("录语音")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    LinearGradient(
                        colors: [Color.red, Color(red: 0.90, green: 0.18, blue: 0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Capsule()
                )
                .shadow(color: Color.red.opacity(0.28), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("开始录制语音备忘")
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }
}

// MARK: - 列表行

struct VoiceMemoRow: View {
    let memo: VoiceMemo
    @ObservedObject var audio: VoiceMemoAudioService

    private var isCurrent: Bool { audio.playingFileName == memo.audioFileName }

    var body: some View {
        HStack(spacing: 12) {
            // 纯文字备忘没有音频：不显示播放按钮，用优雅的便签标识占位。
            if memo.hasAudio {
                Button {
                    Task { await audio.togglePlayback(fileName: memo.audioFileName) }
                    Haptic.light()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                isCurrent && audio.isPlaying
                                    ? AnyShapeStyle(LinearGradient(colors: [Color.red, Color(red: 0.90, green: 0.18, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.red.opacity(0.12))
                            )
                            .frame(width: 38, height: 38)
                        Image(systemName: isCurrent && audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isCurrent && audio.isPlaying ? Color.white : Color.red)
                            .offset(x: isCurrent && audio.isPlaying ? 0 : 1.5)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(.plain)
                .iconButton(isCurrent && audio.isPlaying ? "暂停播放" : "播放录音")
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel("纯文字备忘")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if memo.isBookmarked {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(memo.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if audio.pendingResume?.memoID == memo.id {
                    Label("录音被中断 · 可继续录", systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(1)
                } else if let t = memo.transcription, !t.isEmpty {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if audio.isTranscribing(memo) {
                    Label("离线转写中…", systemImage: "text.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: memo.tag.icon).font(.system(size: 9))
                        Text(L10n.tr(memo.tag.rawValue)).font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())

                    Text(memo.createdAt, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    // 不在这里解码 document：列表每行都可能被重绘，避免每帧读 JSON。
                    Text(memo.hasAudio
                         ? (isCurrent && audio.playbackTime > 0
                            ? "\(formatMemoDuration(audio.playbackTime)) / \(formatMemoDuration(memo.totalDuration))"
                            : formatMemoDuration(memo.totalDuration))
                         : "文字")
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 录音弹窗

struct VoiceMemoRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    /// nil = 新建一条备忘；非 nil = 在这条备忘后面续录一段。
    var memo: VoiceMemo? = nil
    @StateObject private var audio = VoiceMemoAudioService.shared
    @AppStorage("voice_memo_auto_transcribe") private var autoTranscribe = true

    @State private var tag: VoiceMemoTag = .inspiration
    @State private var errorText: String?
    @State private var showDiscardConfirm = false
    /// 「录完并生成分享图」：先落库 → 等这一段离线转写完 → 再挂分享面板。
    /// 关闭分享面板后才收起录音页，避免同一页面同时 present 两个 sheet。
    @State private var shareTarget: VoiceMemo?
    @State private var showShareSheet = false
    @State private var isPreparingShare = false
    @State private var shareError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Text(formatMemoDuration(audio.recordingDuration))
                    .font(.system(size: 54, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(audio.isPaused ? .secondary : .primary)

                LiveWaveformView(levels: audio.levels, isActive: audio.isRecording && !audio.isPaused)
                    .frame(height: 90)
                    .padding(.horizontal)

                if isPreparingShare {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在离线转写这段录音，完成后自动打开分享卡…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.tr(statusText)).font(.footnote).foregroundStyle(.secondary)
                }

                if let errorText {
                    Text(L10n.tr(errorText)).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Picker("分类", selection: $tag) {
                    ForEach(VoiceMemoTag.allCases) { Text(L10n.tr($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Toggle("录完自动离线转写为文字", isOn: $autoTranscribe)
                    .font(.subheadline)
                    .padding(.horizontal, 24)

                Spacer()

                controls.padding(.bottom, 24)
            }
            .navigationTitle(memo == nil ? "录制语音备忘" : "续录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if audio.isRecording && audio.recordingDuration > 2 {
                            showDiscardConfirm = true
                        } else {
                            audio.cancelRecording()
                            dismiss()
                        }
                    }
                    // 等转写期间不让中途退出：录音已经落库，退出只会留下一个「没出图」的半截状态。
                    .disabled(isPreparingShare)
                }
            }
            .confirmationDialog("放弃本次录音？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                Button("放弃录音", role: .destructive) {
                    audio.cancelRecording()
                    dismiss()
                }
                Button("保存录音") { finishAndSave() }
            }
            .interactiveDismissDisabled(audio.isRecording || isPreparingShare)
            .task { await startIfPossible() }
            .sheet(isPresented: $showShareSheet, onDismiss: { dismiss() }) {
                if let shareTarget {
                    VoiceMemoShareSheet(memo: shareTarget)
                }
            }
            .alert("还没有可分享的文字", isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )) {
                Button("好") {
                    shareError = nil
                    dismiss()
                }
            } message: {
                Text(shareError ?? "")
            }
        }
    }

    private var statusText: String {
        if memo != nil && audio.wasInterruptedBySystem {
            return "录音被中断 · 点「完成」会把这一段接在原备忘后面"
        }
        if !audio.isRecording { return memo == nil ? "准备录音…" : "准备续录…" }
        if audio.isPaused { return "已暂停 · 点「继续」接着录，仍写在这一段里" }
        return memo == nil
            ? "正在录音 · 锁屏也会继续录制"
            : "正在续录 · 仍保存在这条备忘里"
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: 26) {
            // 暂停 / 继续
            VStack(spacing: 8) {
                Button {
                    Haptic.light()
                    if audio.isPaused {
                        Task { await audio.resumeRecording() }
                    } else {
                        audio.pauseRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(audio.isPaused ? Color.red.opacity(0.12) : Color(.secondarySystemFill))
                            .frame(width: 56, height: 56)
                        Image(systemName: audio.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(audio.isPaused ? Color.red : Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!audio.isRecording || isPreparingShare)
                .iconButton(audio.isPaused ? "继续录音" : "暂停录音")

                Text(audio.isPaused ? "继续录" : "暂停")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 完成并保存（主动作）
            VStack(spacing: 8) {
                Button {
                    finishAndSave()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.red.opacity(0.32), lineWidth: 4)
                            .frame(width: 82, height: 82)
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.red, Color(red: 0.90, green: 0.18, blue: 0.22)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 70, height: 70)
                            .shadow(color: Color.red.opacity(0.35), radius: 8, y: 3)
                        Image(systemName: "checkmark")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!audio.isRecording || isPreparingShare)
                .iconButton("完成并保存")

                Text("完成保存")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // 完成并直接出图：与纯文字备忘的「保存并生成分享图」同一套时序。
            VStack(spacing: 8) {
                Button {
                    finishAndSave(andShare: true)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 56, height: 56)
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!audio.isRecording || isPreparingShare)
                .iconButton("完成并生成分享图")

                Text("录完出图")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func startIfPossible() async {
        guard !audio.isRecording else { return }
        // 告诉音频服务这次录音属于哪条备忘（中断提示与落库都靠它）。
        audio.recordingTargetMemoID = memo?.id
        guard await audio.requestMicPermission() else {
            errorText = VoiceMemoError.micDenied.localizedDescription
            return
        }
        do {
            try await audio.startRecording()
            Haptic.medium()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func finishAndSave(andShare: Bool = false) {
        guard let result = audio.finishRecording() else {
            errorText = "录音时间太短，未保存"
            Haptic.warning()
            return
        }

        // 续录：把这一段追加到原备忘，绝不新建条目。
        if let target = memo {
            VoiceMemoActions.appendSegment(
                fileName: result.fileName,
                duration: result.duration,
                reason: audio.wasInterruptedBySystem ? "interruption" : "manual",
                to: target,
                context: context,
                // 出图路径要自己 await 转写，避免同一文件被并发转写两次（busy）或重复追加块。
                autoTranscribe: andShare ? false : autoTranscribe
            )
            Haptic.success()
            if andShare {
                prepareShare(target: target, fileName: result.fileName, isAppended: true)
            } else {
                dismiss()
            }
            return
        }

        let newMemo = VoiceMemo(title: VoiceMemo.defaultTitle(), duration: result.duration, audioFileName: result.fileName, tag: tag)
        context.insert(newMemo)
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存语音备忘") }) else {
            Haptic.error()
            // 落库失败就删掉刚录的文件，不留没人引用的孤儿音频。
            VoiceMemoStorage.delete(result.fileName)
            return
        }
        Haptic.success()
        if andShare {
            prepareShare(target: newMemo, fileName: result.fileName, isAppended: false)
        } else {
            if autoTranscribe {
                VoiceMemoActions.transcribeInBackground(newMemo, context: context)
            }
            dismiss()
        }
    }

    /// 分享卡读的是结构化笔记块，而刚录完时块还没生成（自动转写在后台异步跑）。
    /// 这里先同步等这一段转写完再 present，绝不产出一张「暂无可分享的内容」的空卡。
    private func prepareShare(target: VoiceMemo, fileName: String, isAppended: Bool) {
        isPreparingShare = true
        Task { @MainActor in
            defer { isPreparingShare = false }
            let ready = await VoiceMemoActions.prepareShareContent(
                memo: target,
                fileName: fileName,
                isAppended: isAppended,
                context: context
            )
            guard ready else {
                // 录音已经落库，不丢内容；明确告诉用户去详情页补转写后再出图。
                shareError = "这段录音没有识别出文字，已原样保存。可以先完成离线转写，再从详情页点「生成分享图」。"
                Haptic.warning()
                return
            }
            shareTarget = target
            showShareSheet = true
        }
    }
}

// MARK: - 实时波形

struct LiveWaveformView: View {
    let levels: [CGFloat]
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 3
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(
                            isActive
                                ? AnyShapeStyle(LinearGradient(colors: [Color.red, Color(red: 1.0, green: 0.42, blue: 0.32)], startPoint: .bottom, endPoint: .top))
                                : AnyShapeStyle(Color.secondary.opacity(0.25))
                        )
                        .frame(width: barWidth, height: max(4, level * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.06), value: levels)
        }
    }
}

// MARK: - 共享操作

@MainActor
enum VoiceMemoActions {
    /// 把历史数据里「纯文字备忘却顶着语音备忘默认标题」的记录改回来。
    ///
    /// 旧版本新建文字备忘时调用的是 `VoiceMemo.defaultTitle()`，那时它只会产出
    /// 「语音备忘 <时间>」。文案已经修好，但旧记录里存的就是错的那一串，
    /// 不修就会一直显示成语音备忘，分享卡与备份也会带着它。
    ///
    /// 只改「默认标题」：纯文字备忘 + 语音备忘前缀，用户手写的标题不会长这样。
    /// 返回是否发生了修改，由调用方统一落库，避免逐条 save。
    @discardableResult
    static func normalizeLegacyTextMemoTitles(_ memos: [VoiceMemo]) -> Bool {
        var changed = false
        for memo in memos where memo.isTextOnly && memo.title.hasPrefix("语音备忘 ") {
            memo.title = VoiceMemo.defaultTitle(for: memo.createdAt, isTextOnly: true)
            // 这串标题是系统生成的，不是用户写的：把「手写标题」标记也让出来，
            // 免得详情页的「自动生成标题」开关一直显示成关闭。
            memo.titleIsUserEdited = false
            changed = true
        }
        return changed
    }

    static func delete(_ memo: VoiceMemo, context: ModelContext) {
        let audio = VoiceMemoAudioService.shared
        let fileNames = memo.segmentFileNames
        if let playing = audio.playingFileName, fileNames.contains(playing) { audio.stopPlayback() }
        // 目标备忘都没了，恢复卡不能再留着指向一个不存在的 ID。
        if audio.pendingResume?.memoID == memo.id { audio.clearPendingResume() }
        // 一条备忘可能有多个片段，逐个删；纯文字备忘的集合为空。
        for name in fileNames { VoiceMemoStorage.delete(name) }
        // 一并删除笔记内嵌图片，避免留下孤儿文件占着空间
        for name in memo.document.blocks.compactMap({ block -> String? in
            guard block.kind == .image else { return nil }
            return block.imageFileName
        }) {
            VoiceMemoImageStorage.delete(name)
        }
        context.delete(memo)
        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
    }

    /// 后台离线转写，完成后写回转写文本、要点与标题
    static func transcribeInBackground(_ memo: VoiceMemo, context: ModelContext, onError: ((String) -> Void)? = nil) {
        Task {
            do {
                let text = try await VoiceMemoAudioService.shared.transcribe(memo: memo)
                apply(transcription: text, to: memo)
                context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
                if text.isEmpty { onError?("未识别到有效语音内容") }
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    /// 重新转写第一段，并**只替换这一段归属的块**。
    ///
    /// `transcribeInBackground` 走 `apply(transcription:)` 整篇重建，
    /// 会把多段备忘里其他段的文字全换成第一段的转写、并清空按段归属。
    /// 详情页的「重新转写」应该走这里：其余段的文字、归属，以及用户在块编辑器里
    /// 加的图片/待办/手写块，全都原样保留。
    static func retranscribeFirstSegment(
        _ memo: VoiceMemo,
        context: ModelContext,
        onError: ((String) -> Void)? = nil
    ) {
        guard let first = memo.segments.first else { return }
        Task {
            do {
                let text = try await VoiceMemoAudioService.shared.transcribe(fileName: first.fileName)
                guard !text.isEmpty else {
                    onError?("未识别到有效语音内容")
                    return
                }
                let newBlocks = MemoBlockBuilder.build(from: text, title: "").blocks.filter { !$0.isEmpty }
                let owned = Set(first.transcriptBlockIDs ?? [])
                let hasVisibleBlocks = memo.document.blocks.contains { !$0.isEmpty }

                if owned.isEmpty, memo.segments.count > 1, hasVisibleBlocks {
                    // 多段却没有归属记录时不能猜哪些块属于第一段：
                    // 猜错就会把别段的文字删掉。明确拒绝，让用户在片段页处理。
                    onError?("第一段缺少转写归属记录，请在片段管理页删除该片段后重新续录")
                    return
                }

                if owned.isEmpty {
                    // 空笔记 / 存量单段数据：整篇重建一次，并补齐第一段的归属，
                    // 之后就一直走下面的精确替换路径。
                    apply(transcription: text, to: memo)
                    if memo.segments.count > 1 {
                        var segments = memo.segments
                        segments[0].transcriptBlockIDs = memo.document.blocks.filter { !$0.isEmpty }.map(\.id)
                        memo.setSegments(segments)
                    }
                } else {
                    var document = memo.document
                    // 插回原来的位置，别把第一段的文字挪到别的段后面。
                    let insertAt = document.blocks.firstIndex { owned.contains($0.id) }
                    document.blocks.removeAll { owned.contains($0.id) }
                    let target = insertAt.map { min($0, document.blocks.count) } ?? document.blocks.count
                    document.blocks.insert(contentsOf: newBlocks, at: target)
                    memo.apply(document: document)

                    var segments = memo.segments
                    if let index = segments.firstIndex(where: { $0.id == first.id }) {
                        segments[index].transcriptBlockIDs = newBlocks.map(\.id)
                        memo.setSegments(segments)
                    }
                    // 正文变了，旧摘要是引用着旧内容的陈旧结论。
                    memo.summary = nil
                }
                context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存重新转写结果") }
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    static func apply(transcription text: String, to memo: VoiceMemo) {
        memo.transcription = text
        // 转写完成后自动切分成结构化块。
        // 整段转写没有逐句偏移量，因此这里产出的块**不带时间戳**——
        // 宁可没有时间点，也不要给一个对不上的假时间点。
        let document = MemoBlockBuilder.build(from: text, title: memo.title)
        memo.blocksData = MemoBlockCodec.encode(document)
        let summary = VoiceMemoTextAnalyzer.summarize(text)
        memo.summary = summary.isEmpty ? nil : summary
        // 只有「用户没手改过」且「仍是默认标题」时才用转写首句替换。
        // 手改过就永远不再覆盖——自动标题不能悄悄替用户改掉他写好的标题。
        if !memo.titleIsUserEdited,
           memo.hasDefaultTitle,
           let t = VoiceMemoTextAnalyzer.suggestedTitle(from: text) {
            memo.title = t
        }
        // 整篇重建意味着所有块的 ID 都是新的，旧的按段归属必须重算。
        rebindTranscriptOwnership(memo, document: document)
    }

    /// 整篇重建后重新绑定「哪几个块来自哪一段」。
    ///
    /// 只有单段时能安全地全量归给那一段；多段备忘做整篇重建（例如「重新转写」）
    /// 会把各段原有块全部替换掉，旧 ID 一律失效，此时清空归属而不是硬套，
    /// 否则删 A 段会顺着失效 ID 误删 B 段的文字。
    static func rebindTranscriptOwnership(_ memo: VoiceMemo, document: MemoDocument) {
        var segments = memo.segments
        guard !segments.isEmpty else { return }
        if segments.count == 1 {
            segments[0].transcriptBlockIDs = document.blocks.filter { !$0.isEmpty }.map(\.id)
        } else {
            for index in segments.indices { segments[index].transcriptBlockIDs = nil }
        }
        memo.setSegments(segments)
    }

    /// 把新录的一段追加到已有备忘，**不新建条目**。
    /// 中断自动收尾与「继续录制」都走这里，保证片段只有一条写入路径。
    static func appendSegment(
        fileName: String,
        duration: TimeInterval,
        reason: String?,
        to memo: VoiceMemo,
        context: ModelContext,
        autoTranscribe: Bool = true
    ) {
        var all = memo.segments
        all.append(MemoSegment(
            fileName: fileName,
            duration: duration,
            createdAt: .now,
            interruptionReasonRaw: reason
        ))
        memo.setSegments(all)
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存续录片段") }) else {
            // 落库失败就删掉刚录的文件，不留孤儿音频。
            VoiceMemoStorage.delete(fileName)
            return
        }
        if autoTranscribe {
            Task { _ = await transcribeAppendedSegment(fileName: fileName, memo: memo, context: context) }
        }
    }

    /// 只转写新增的那一段，把新块追加到已有笔记，**不覆盖**用户编辑过的块与图片。
    ///
    /// 后台自动转写与「录完直接出图」共用这一条路径：前者 fire-and-forget，
    /// 后者 await 到内容真正落库后再打开分享面板，保证卡片不会是空的。
    /// 返回是否产出了可用文字。
    private static func transcribeAppendedSegment(
        fileName: String,
        memo: VoiceMemo,
        context: ModelContext
    ) async -> Bool {
        guard let text = try? await VoiceMemoAudioService.shared.transcribe(fileName: fileName),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var document = memo.document
        let newBlocks = MemoBlockBuilder.build(from: text, title: "").blocks.filter { !$0.isEmpty }
        guard !newBlocks.isEmpty else { return false }
        document.blocks.append(contentsOf: newBlocks)
        memo.apply(document: document)

        // 把新块的 ID 记到对应片段上，删段时才能只删这一段的文字。
        var segments = memo.segments
        if let index = segments.firstIndex(where: { $0.fileName == fileName }) {
            var owned = segments[index].transcriptBlockIDs ?? []
            owned.append(contentsOf: newBlocks.map(\.id))
            segments[index].transcriptBlockIDs = owned
            memo.setSegments(segments)
        }
        return context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存续录转写") }
    }

    /// 「录完并生成分享图」前的同步准备：把刚录的这一段转成卡片内容并落库。
    ///
    /// 新建单段走 `apply(transcription:)` 整篇重建（顺带补齐按段归属与自动标题）；
    /// 续录只追加新段的块，不碰其他段的文字、图片与待办。
    /// 返回 false 表示没拿到可用文字，调用方应提示用户而不是出一张空卡。
    static func prepareShareContent(
        memo: VoiceMemo,
        fileName: String,
        isAppended: Bool,
        context: ModelContext
    ) async -> Bool {
        if isAppended {
            return await transcribeAppendedSegment(fileName: fileName, memo: memo, context: context)
        }
        guard let text = try? await VoiceMemoAudioService.shared.transcribe(fileName: fileName),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        apply(transcription: text, to: memo)
        return context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存录音转写") }
    }

    /// 删除单个片段：音频与该段转写文字一起移除，其余段与未归属内容一律保留。
    ///
    /// 删文件放在 save 成功之后：写库失败时 SwiftData 会 rollback，
    /// 音频还在，用户不会「库里说删了、文件却还在」也不会「文件没了、库里还在」。
    static func deleteSegment(_ segment: MemoSegment, from memo: VoiceMemo, context: ModelContext) {
        let original = memo.segments
        let remaining = original.filter { $0.id != segment.id }
        guard remaining.count != original.count else { return }

        let audio = VoiceMemoAudioService.shared
        if audio.playingFileName == segment.fileName || audio.playbackQueue.contains(segment.fileName) {
            audio.stopPlayback()
        }

        // 只删明确归属这一段的块；没有归属记录的历史内容宁可留着。
        if let owned = segment.transcriptBlockIDs, !owned.isEmpty {
            let ownedSet = Set(owned)
            var document = memo.document
            let before = document.blocks.count
            document.blocks.removeAll { ownedSet.contains($0.id) }
            if document.blocks.count != before {
                memo.apply(document: document)
                // 要点是自动生成的，正文变了它就是陈旧结论；清掉让用户重新提炼，
                // 不要留一段引用着已删内容的摘要在详情页。
                memo.summary = nil
            }
        }

        memo.setSegments(remaining)
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "删除录音片段") }) else {
            Haptic.error()
            return
        }
        VoiceMemoStorage.delete(segment.fileName)
        Haptic.success()
    }
}
