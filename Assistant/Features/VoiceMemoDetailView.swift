import SwiftData
import SwiftUI

/// 语音备忘详情：播放控制、转写文本编辑、要点提炼、一键提取待办
struct VoiceMemoDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var memo: VoiceMemo
    @StateObject private var audio = VoiceMemoAudioService.shared

    @State private var transcriptDraft = ""
    @State private var isEditingTranscript = false
    @State private var errorText: String?
    @State private var showTodoExtractor = false
    @State private var showDeleteConfirm = false
    @State private var scrubbingTime: TimeInterval?

    @State private var isGeneratingAISummary = false
    @State private var showBlockEditor = false
    @State private var showShareSheet = false
    @State private var showRecorder = false

    /// 播放的是这条备忘里的任意一段（串播时会切换文件）。
    private var isCurrent: Bool { memo.segmentFileNames.contains(audio.playingFileName ?? "") }
    /// 第一段缺失时主播放器不可用；其余段缺失在片段管理页里逐段标出。
    private var fileMissing: Bool { memo.hasAudio && !VoiceMemoStorage.exists(memo.audioFileName) }
    private var hasPendingResume: Bool { audio.pendingResume?.memoID == memo.id }

    var body: some View {
        List {
            // 恢复卡放进滚动内容流，不固定在容器外——与首页横幅同一条约定。
            if hasPendingResume {
                Section {
                    resumeCard
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                // 用 displayTitle 显示：旧数据里纯文字备忘却存着「语音备忘 <时间>」，
                // 直接绑 memo.title 会让详情页和列表显示两套标题。
                TextField("标题", text: Binding(
                    get: { memo.displayTitle },
                    set: { memo.title = $0 }
                ))
                    .font(.headline)
                    .onSubmit {
                        // 用户手改过标题后，转写完成不再用自动标题覆盖。
                        memo.titleIsUserEdited = true
                        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存语音备忘标题") }
                    }
                // 纯文字备忘没有转写，标题是在保存时从正文首句得来的，
                // 这个开关对它不产生任何效果——不放一个点了没反应的开关。
                if !memo.isTextOnly {
                    Toggle("自动生成标题", isOn: Binding(
                        get: { !memo.titleIsUserEdited },
                        set: { enabled in
                            memo.titleIsUserEdited = !enabled
                            context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存标题生成设置") }
                        }
                    ))
                    .font(.subheadline)
                }
                HStack {
                    Picker("分类", selection: Binding(get: { memo.tag }, set: { memo.tag = $0; context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存语音备忘分类") } })) {
                        ForEach(VoiceMemoTag.allCases) { Label(L10n.tr($0.rawValue), systemImage: $0.icon).tag($0) }
                    }
                }
                LabeledContent(memo.isTextOnly ? "创建时间" : "录制时间", value: memo.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("播放") { playerCard }

            Section {
                // 中断恢复期间只留恢复卡这一个主动作，避免两个「继续录制」并排。
                if !hasPendingResume {
                    Button {
                        showRecorder = true
                    } label: {
                        Label(
                            memo.isTextOnly ? "补录一段录音" : "继续录制（仍在这条备忘里）",
                            systemImage: "mic.badge.plus"
                        )
                    }
                    .foregroundStyle(.red)
                }

                if memo.hasAudio {
                    // 片段的时间轴、逐段播放、删除与再续录都收进独立页，
                    // 详情页保持「一屏一个主动作」，不把六件事堆在同一层 List 里。
                    NavigationLink {
                        VoiceMemoSegmentListView(memo: memo)
                    } label: {
                        HStack {
                            Label("录音片段", systemImage: "waveform")
                            Spacer()
                            Text("\(memo.segments.count) 段 · \(formatMemoDuration(memo.totalDuration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("录音")
            } footer: {
                Text(memo.hasAudio
                     ? "每段都是独立文件。在「录音片段」里可逐段播放、合并播放、删除或再续录一段。"
                     : "这条是纯文字备忘，补录后也不会多出一条。")
            }

            transcriptSection

            if memo.hasTranscription || (memo.summary != nil && !(memo.summary ?? "").isEmpty) {
                Section {
                    if let summary = memo.summary, !summary.isEmpty {
                        Text(summary).font(.callout).textSelection(.enabled)
                    } else {
                        Text("可点击下方按钮使用端侧 AI 提炼核心要点。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if memo.hasTranscription {
                        Button {
                            generateAISummary()
                        } label: {
                            HStack(spacing: 6) {
                                if isGeneratingAISummary {
                                    ProgressView().controlSize(.small)
                                    Text("端侧 AI 正在提炼要点…")
                                } else {
                                    Image(systemName: "sparkles")
                                    Text("AI 端侧提炼核心要点")
                                }
                            }
                            .foregroundStyle(.purple)
                        }
                        .disabled(isGeneratingAISummary)
                    }
                } header: {
                    Text("要点提炼")
                }
            }

            if memo.hasTranscription {
                Section {
                    Button {
                        showTodoExtractor = true
                    } label: {
                        Label("从录音内容提取待办 (支持 AI 提炼)", systemImage: "checklist.checked")
                    }
                } footer: {
                    Text("支持规则分句或调用端侧 AI 自动提炼录音中的行动事项，勾选后加入待办清单。")
                }
            }

            Section {
                // 一条备忘可能有多段音频，逐段都带出去，别只分享第一段。
                if memo.hasAudio {
                    let urls = memo.segments
                        .filter { VoiceMemoStorage.exists($0.fileName) }
                        .map { VoiceMemoStorage.url(for: $0.fileName) }
                    ShareLink(items: urls) {
                        Label(
                            urls.count > 1 ? "分享全部 \(urls.count) 段音频" : "分享音频文件",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(urls.isEmpty)
                }
                if let t = memo.transcription, !t.isEmpty {
                    ShareLink(item: t) {
                        Label(memo.isTextOnly ? "分享文字内容" : "分享转写文字", systemImage: "doc.text")
                    }
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("删除语音备忘", systemImage: "trash")
                }
            }
        }
        .navigationTitle("备忘详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    memo.isBookmarked.toggle()
                    context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
                    Haptic.light()
                } label: {
                    Image(systemName: memo.isBookmarked ? "star.fill" : "star")
                        .foregroundStyle(memo.isBookmarked ? .yellow : .accentColor)
                }
                .iconButton(memo.isBookmarked ? "取消收藏" : "收藏")
            }
        }
        .sheet(isPresented: $showTodoExtractor) {
            VoiceMemoTodoExtractorSheet(memo: memo)
        }
        .fullScreenCover(isPresented: $showBlockEditor) {
            VoiceMemoBlockEditorView(memo: memo)
        }
        .sheet(isPresented: $showRecorder) {
            VoiceMemoRecorderSheet(memo: memo)
        }
        .sheet(isPresented: $showShareSheet) {
            VoiceMemoShareSheet(memo: memo)
        }
        .confirmationDialog("删除这条语音备忘？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                VoiceMemoActions.delete(memo, context: context)
                dismiss()
            }
        }
        .onAppear {
            if memo.hasAudio && !fileMissing { audio.prepare(fileName: memo.audioFileName) }
        }
        .onDisappear {
            context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
            if isCurrent { audio.stopPlayback() }
        }
    }

    // MARK: - 中断恢复与片段管理

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("录音被中断", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text("已保存的 \(memo.segments.count) 段都在（共 \(formatMemoDuration(memo.totalDuration))），可以接着录下一段，仍在这条备忘里。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    resumeRecording()
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

    private func resumeRecording() {
        // 上一次被中断的录音可能还挂在单例上；先收掉，否则新录音页会因 isRecording 直接不启动。
        if audio.isRecording { audio.cancelRecording() }
        audio.clearPendingResume()
        showRecorder = true
    }

    // MARK: - 播放器

    @ViewBuilder
    private var playerCard: some View {
        if memo.isTextOnly {
            textOnlyPlayerCard
        } else {
            audioPlayerCard
        }
    }

    /// 纯文字备忘没有播放器，给一个补录入口，避免显示「音频文件已丢失」误导用户。
    private var textOnlyPlayerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("这是一条纯文字备忘", systemImage: "doc.text")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showRecorder = true
            } label: {
                Label("补录一段录音", systemImage: "mic.badge.plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var audioPlayerCard: some View {
        VStack(spacing: 14) {
            if fileMissing {
                Label("音频文件已丢失（仅保留转写文字）", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            // 多段时给一条合并时间轴：断点可见、点段落可单独播放。
            // 滑块仍然只控制「当前这一段」，两者语义要在文案里说清，别让用户以为滑块是全局进度。
            if memo.segments.count > 1 {
                MemoSegmentTimelineView(
                    segments: memo.segments,
                    activeFileName: isCurrent ? audio.playingFileName : nil,
                    segmentProgress: audio.playbackTime
                ) { segment in
                    // 点单段要退出合并播放，否则播完会接着跳到队列里的下一段。
                    if !audio.playbackQueue.isEmpty { audio.stopPlayback() }
                    Task { await audio.togglePlayback(fileName: segment.fileName) }
                }
            }

            let duration = isCurrent && audio.playbackDuration > 0 ? audio.playbackDuration : memo.duration
            let current = scrubbingTime ?? (isCurrent ? audio.playbackTime : 0)

            Slider(
                value: Binding(get: { current }, set: { scrubbingTime = $0 }),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if !editing, let t = scrubbingTime {
                        if !isCurrent { audio.prepare(fileName: memo.audioFileName) }
                        audio.seek(to: t)
                        scrubbingTime = nil
                    }
                }
            )
            .tint(.red)
            .disabled(fileMissing)

            HStack {
                Text(formatMemoDuration(current))
                Spacer()
                Text("-" + formatMemoDuration(max(0, duration - current)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if memo.segments.count > 1 {
                Text("滑块控制当前片段 · 上方时间轴是整条备忘（共 \(formatMemoDuration(memo.totalDuration))）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 36) {
                Button { audio.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                .iconButton("后退 15 秒")
                Button {
                    // 合并播放到某一段时，主按钮暂停/继续的应该是当前段，不是永远第一段。
                    let fileName = isCurrent ? (audio.playingFileName ?? memo.audioFileName) : memo.audioFileName
                    Task { await audio.togglePlayback(fileName: fileName) }
                    Haptic.light()
                } label: {
                    Image(systemName: isCurrent && audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.red)
                        .contentTransition(.symbolEffect(.replace))
                }
                .iconButton(isCurrent && audio.isPlaying ? "暂停播放" : "播放录音")
                Button { audio.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title2) }
                .iconButton("前进 15 秒")
            }
            .buttonStyle(.plain)
            .disabled(fileMissing)

            Picker("倍速", selection: $audio.playbackRate) {
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Text(r == 1.0 ? "1x" : String(format: "%gx", r)).tag(r)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 转写

    @ViewBuilder
    private var transcriptSection: some View {
        Section {
            if audio.isTranscribing(memo) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在设备端离线转写，不会上传任何音频…").font(.callout).foregroundStyle(.secondary)
                }
            } else if isEditingTranscript {
                TextEditor(text: $transcriptDraft)
                    .frame(minHeight: 160)
                HStack {
                    Button("取消") { isEditingTranscript = false }
                    Spacer()
                    Button("保存") {
                        VoiceMemoActions.apply(transcription: transcriptDraft, to: memo)
                        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存转写文本") }) else {
                            Haptic.error()
                            return
                        }
                        isEditingTranscript = false
                        Haptic.success()
                    }
                    .bold()
                }
                .buttonStyle(.borderless)
            } else if memo.document.blocks.contains(where: { !$0.isEmpty }) {
                // 结构化预览：转写不再是「一大坨文字」，而是分好块的笔记
                transcriptBlocksPreview
            } else {
                Text(memo.isTextOnly
                     ? "还没有正文，点「手动输入」开始写。"
                     : "尚未转写。转写全程在本机完成，可随时编辑校对。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let errorText {
                Text(L10n.tr(errorText)).font(.caption).foregroundStyle(.red)
            }

            if !audio.isTranscribing(memo) && !isEditingTranscript {
                HStack {
                    Button {
                        errorText = nil
                        VoiceMemoActions.retranscribeFirstSegment(memo, context: context) { errorText = $0 }
                    } label: {
                        Label(
                            memo.hasTranscription
                                ? (memo.segments.count > 1 ? "重新转写第 1 段" : "重新转写")
                                : "离线转写为文字",
                            systemImage: "waveform.and.magnifyingglass"
                        )
                    }
                    // 纯文字备忘没有音频可转写，别让它去请求一个目录路径。
                    .disabled(!memo.hasAudio || fileMissing)
                    Spacer()
                    // 多段备忘不给「编辑全文」：TextEditor 会把整篇重新分块，
                    // 块 ID 全换、按段归属随之失效。改用下面的「编辑转写」逐块改。
                    if memo.segments.count <= 1 {
                        Button {
                            transcriptDraft = memo.transcription ?? ""
                            isEditingTranscript = true
                        } label: {
                            Label(
                                memo.hasTranscription
                                    ? (memo.isTextOnly ? "编辑正文" : "编辑全文")
                                    : "手动输入",
                                systemImage: "pencil"
                            )
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)

                if memo.hasTranscription {
                    HStack(spacing: 12) {
                        Button {
                            showBlockEditor = true
                        } label: {
                            Label("编辑转写", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)

                        Spacer()

                        Button {
                            showShareSheet = true
                        } label: {
                            Label("生成分享图", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    }
                }

                if memo.segments.count > 1 {
                    Text("重新转写只替换第 1 段的文字，其他段的内容与归属不变；改文字请用「编辑转写」逐块修改。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack {
                Text(memo.isTextOnly ? "正文" : "转写文字")
                Spacer()
                if memo.hasTranscription {
                    Text("段落化 · \(memo.document.blocks.filter { !$0.isEmpty }.count) 段")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 结构化转写预览。
    ///
    /// 只渲染文字块与标题/列表/待办的区别；
    /// 图片块与语音片段块在详情页用简化形态展示，避免塞进 List 里太重。
    @ViewBuilder
    private var transcriptBlocksPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(memo.document.blocks) { block in
                if block.isEmpty { EmptyView() }
                else {
                    switch block.kind {
                    case .heading:
                        HStack(alignment: .center, spacing: 8) {
                            RoundedRectangle(cornerRadius: AppRadius.hairline).fill(Color.red).frame(width: 3, height: 15)
                            Text(block.text).font(.headline)
                        }
                    case .bullet:
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Color.red).frame(width: 5, height: 5).padding(.top, 7)
                            Text(block.text).font(.callout)
                        }
                    case .todo:
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: block.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(block.isDone ? Color.green : Color.secondary)
                            Text(block.text).font(.callout).strikethrough(block.isDone)
                        }
                    case .quote:
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: AppRadius.hairline).fill(Color.secondary.opacity(0.5)).frame(width: 2)
                            Text(block.text).font(.callout).foregroundStyle(.secondary).italic()
                        }
                    case .image:
                        Label("图片 · \(block.imageCaption ?? "会议现场")", systemImage: "photo")
                            .font(.caption).foregroundStyle(.secondary)
                    case .audio:
                        Label(MemoShareCardContent.audioCaption(for: block.timeRange), systemImage: "waveform")
                            .font(.caption).foregroundStyle(.red)
                    default:
                        Text(block.text).font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func generateAISummary() {
        guard let text = memo.transcription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        isGeneratingAISummary = true
        Haptic.light()
        Task {
            let sys = "你是高效的会议与语音笔记提炼助手。请将用户的语音转写内容提炼为 2 到 4 条简明扼要的核心要点，直接输出要点内容，不要说废话。"
            let output = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: sys,
                userContent: text,
                maxNewTokens: 200
            )
            await MainActor.run {
                isGeneratingAISummary = false
                if let output, !output.isEmpty {
                    memo.summary = output
                    guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存 AI 摘要") }) else {
                        Haptic.error()
                        return
                    }
                    Haptic.success()
                } else {
                    errorText = "端侧 AI 模型尚未下载或未就绪，请先在「设置 → AI 模型」中下载。"
                }
            }
        }
    }
}

// MARK: - 提取待办

struct VoiceMemoTodoExtractorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let memo: VoiceMemo

    @State private var items: [Candidate] = []
    @State private var customText = ""
    @State private var isExtractingWithAI = false

    struct Candidate: Identifiable {
        let id = UUID()
        var text: String
        var selected: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        extractWithAI()
                    } label: {
                        HStack(spacing: 6) {
                            if isExtractingWithAI {
                                ProgressView().controlSize(.small)
                                Text("端侧 AI 正在从录音提炼待办…")
                            } else {
                                Image(systemName: "sparkles")
                                Text("使用端侧 AI 智能提炼行动待办")
                            }
                        }
                        .foregroundStyle(.purple)
                    }
                    .disabled(isExtractingWithAI)
                }

                Section {
                    ForEach(items) { item in
                        let binding = itemBinding(for: item)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: binding.wrappedValue.selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(binding.wrappedValue.selected ? Color.accentColor : .secondary)
                                .font(.title3)
                                .onTapGesture { binding.wrappedValue.selected.toggle(); Haptic.selection() }
                            TextField("待办内容", text: binding.text, axis: .vertical)
                        }
                    }
                } header: {
                    Text("识别到的待办事项（可编辑）")
                } footer: {
                    Text("已为含行动/时间意图的事项默认勾选。")
                }

                Section("补充一条") {
                    HStack {
                        TextField("手动添加待办", text: $customText)
                        Button {
                            let t = customText.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            items.append(Candidate(text: t, selected: true))
                            customText = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                        .iconButton("添加待办")
                    }
                }
            }
            .navigationTitle("提取为待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入 \(selectedCount) 项") { commit() }
                        .disabled(selectedCount == 0)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedCount: Int {
        items.filter { $0.selected && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private func itemBinding(for fallback: Candidate) -> Binding<Candidate> {
        Binding(
            get: {
                items.first(where: { $0.id == fallback.id }) ?? fallback
            },
            set: { updated in
                guard let idx = items.firstIndex(where: { $0.id == fallback.id }) else { return }
                items[idx] = updated
            }
        )
    }

    private func load() {
        guard items.isEmpty else { return }
        let all = VoiceMemoTextAnalyzer.sentences(from: memo.transcription ?? "")
        items = all.map { Candidate(text: $0, selected: VoiceMemoTextAnalyzer.looksLikeTodo($0)) }
    }

    private func extractWithAI() {
        guard let text = memo.transcription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        isExtractingWithAI = true
        Haptic.light()
        Task {
            let sys = "你是待办事项提取助手。请从用户的语音转写文本中提取出需要执行的待办事项，每行输出一条简明待办标题（15字以内），不要输出编号或多余解释。"
            let output = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: sys,
                userContent: text,
                maxNewTokens: 180
            )
            await MainActor.run {
                isExtractingWithAI = false
                if let output, !output.isEmpty {
                    let lines = output
                        .components(separatedBy: .newlines)
                        .map {
                            $0.replacingOccurrences(
                                of: #"^[\d一二三四五六七八九十]+[\.、\s\)\）\-•]+"#,
                                with: "",
                                options: .regularExpression
                            ).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .filter { $0.count >= 2 }
                    if !lines.isEmpty {
                        items = lines.map { Candidate(text: $0, selected: true) }
                        Haptic.success()
                    }
                }
            }
        }
    }

    private func commit() {
        for item in items where item.selected {
            let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let todo = TodoItem(
                type: .general,
                title: title,
                detail: "来自语音备忘「\(memo.title)」",
                sourceText: item.text
            )
            context.insert(todo)
        }
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "提取待办") }) else {
            Haptic.error()
            return
        }
        Haptic.success()
        dismiss()
    }
}
