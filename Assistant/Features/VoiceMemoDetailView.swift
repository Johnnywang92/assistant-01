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

    private var isCurrent: Bool { audio.playingFileName == memo.audioFileName }
    private var fileMissing: Bool { !VoiceMemoStorage.exists(memo.audioFileName) }

    var body: some View {
        List {
            Section {
                TextField("标题", text: $memo.title)
                    .font(.headline)
                    .onSubmit { try? context.save() }
                HStack {
                    Picker("分类", selection: Binding(get: { memo.tag }, set: { memo.tag = $0; try? context.save() })) {
                        ForEach(VoiceMemoTag.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                }
                LabeledContent("录制时间", value: memo.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section("播放") { playerCard }

            transcriptSection

            if let summary = memo.summary, !summary.isEmpty {
                Section("要点提炼") {
                    Text(summary).font(.callout).textSelection(.enabled)
                }
            }

            if memo.hasTranscription {
                Section {
                    Button {
                        showTodoExtractor = true
                    } label: {
                        Label("从录音内容提取待办", systemImage: "checklist.checked")
                    }
                } footer: {
                    Text("自动识别「明天/记得/需要/提交」等含行动意图的句子，勾选后加入待办清单。")
                }
            }

            Section {
                ShareLink(item: memo.audioURL, preview: SharePreview(memo.title)) {
                    Label("分享音频文件", systemImage: "square.and.arrow.up")
                }
                .disabled(fileMissing)
                if let t = memo.transcription, !t.isEmpty {
                    ShareLink(item: t) { Label("分享转写文字", systemImage: "doc.text") }
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
                    try? context.save()
                    Haptic.light()
                } label: {
                    Image(systemName: memo.isBookmarked ? "star.fill" : "star")
                        .foregroundStyle(memo.isBookmarked ? .yellow : .accentColor)
                }
            }
        }
        .sheet(isPresented: $showTodoExtractor) {
            VoiceMemoTodoExtractorSheet(memo: memo)
        }
        .confirmationDialog("删除这条语音备忘？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                VoiceMemoActions.delete(memo, context: context)
                dismiss()
            }
        }
        .onAppear {
            if !fileMissing { audio.prepare(fileName: memo.audioFileName) }
        }
        .onDisappear {
            try? context.save()
            if isCurrent { audio.stopPlayback() }
        }
    }

    // MARK: - 播放器

    private var playerCard: some View {
        VStack(spacing: 14) {
            if fileMissing {
                Label("音频文件已丢失（仅保留转写文字）", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
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

            HStack(spacing: 36) {
                Button { audio.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Button {
                    audio.togglePlayback(fileName: memo.audioFileName)
                    Haptic.light()
                } label: {
                    Image(systemName: isCurrent && audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.red)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { audio.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title2) }
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
                        try? context.save()
                        isEditingTranscript = false
                        Haptic.success()
                    }
                    .bold()
                }
                .buttonStyle(.borderless)
            } else if let t = memo.transcription, !t.isEmpty {
                Text(t).font(.body).textSelection(.enabled)
            } else {
                Text("尚未转写。转写全程在本机完成，可随时编辑校对。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            if !audio.isTranscribing(memo) && !isEditingTranscript {
                HStack {
                    Button {
                        errorText = nil
                        VoiceMemoActions.transcribeInBackground(memo, context: context) { errorText = $0 }
                    } label: {
                        Label(memo.hasTranscription ? "重新转写" : "离线转写为文字", systemImage: "waveform.and.magnifyingglass")
                    }
                    .disabled(fileMissing)
                    Spacer()
                    Button {
                        transcriptDraft = memo.transcription ?? ""
                        isEditingTranscript = true
                    } label: {
                        Label(memo.hasTranscription ? "编辑" : "手动输入", systemImage: "pencil")
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        } header: {
            Text("转写文字")
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

    struct Candidate: Identifiable {
        let id = UUID()
        var text: String
        var selected: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($items) { $item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.selected ? Color.accentColor : .secondary)
                                .font(.title3)
                                .onTapGesture { item.selected.toggle(); Haptic.selection() }
                            TextField("待办内容", text: $item.text, axis: .vertical)
                        }
                    }
                } header: {
                    Text("识别到的句子（可编辑）")
                } footer: {
                    Text("已为含行动/时间意图的句子默认勾选。")
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

    private func load() {
        guard items.isEmpty else { return }
        let all = VoiceMemoTextAnalyzer.sentences(from: memo.transcription ?? "")
        items = all.map { Candidate(text: $0, selected: VoiceMemoTextAnalyzer.looksLikeTodo($0)) }
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
        try? context.save()
        Haptic.success()
        dismiss()
    }
}
