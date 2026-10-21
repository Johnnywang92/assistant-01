import SwiftData
import SwiftUI

/// 语音备忘录列表（离线录音、回放与转写归档）
struct VoiceMemoListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VoiceMemo.createdAt, order: .reverse) private var memos: [VoiceMemo]

    @State private var searchText = ""
    @State private var selectedTag: VoiceMemoTag?
    @State private var showRecorder = false
    @State private var memoToDelete: VoiceMemo?

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
                    "还没有语音备忘",
                    systemImage: "mic.badge.plus",
                    description: Text("点击下方红色按钮开始录音。\n音频仅保存在本机，可离线转写为文字并一键提取待办。")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "搜索标题或转写内容")
        .navigationTitle("语音备忘")
        .safeAreaInset(edge: .bottom) { recordButton }
        .sheet(isPresented: $showRecorder) {
            VoiceMemoRecorderSheet()
        }
        .confirmationDialog("删除这条语音备忘？", isPresented: Binding(
            get: { memoToDelete != nil }, set: { if !$0 { memoToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除录音与转写", role: .destructive) {
                if let m = memoToDelete { VoiceMemoActions.delete(m, context: context) }
                memoToDelete = nil
            }
        } message: {
            Text("音频文件将从本机永久删除，无法恢复。")
        }
    }

    // MARK: - 子视图

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
            Label(L10n.tr(title), systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.red.opacity(0.18) : Color(.secondarySystemFill)))
                .foregroundStyle(selected ? Color.red : Color.primary)
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
                try? context.save()
                Haptic.light()
            } label: {
                Label(memo.isBookmarked ? "取消星标" : "星标", systemImage: memo.isBookmarked ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
        .themedRow()
    }

    private var recordButton: some View {
        Button {
            Haptic.medium()
            showRecorder = true
        } label: {
            ZStack {
                Circle().fill(Color.white).frame(width: 70, height: 70)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                Circle().fill(Color.red).frame(width: 56, height: 56)
                Image(systemName: "mic.fill").font(.title2).foregroundStyle(.white)
            }
        }
        .accessibilityLabel("开始录制语音备忘")
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
            Button {
                audio.togglePlayback(fileName: memo.audioFileName)
                Haptic.light()
            } label: {
                Image(systemName: isCurrent && audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if memo.isBookmarked {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(memo.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                if let t = memo.transcription, !t.isEmpty {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if audio.isTranscribing(memo) {
                    Label("离线转写中…", systemImage: "text.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Label(L10n.tr(memo.tag.rawValue), systemImage: memo.tag.icon)
                    Text(memo.createdAt, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Text(isCurrent && audio.playbackTime > 0
                         ? "\(formatMemoDuration(audio.playbackTime)) / \(formatMemoDuration(memo.duration))"
                         : formatMemoDuration(memo.duration))
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
    @StateObject private var audio = VoiceMemoAudioService.shared
    @AppStorage("voice_memo_auto_transcribe") private var autoTranscribe = true

    @State private var tag: VoiceMemoTag = .inspiration
    @State private var errorText: String?
    @State private var showDiscardConfirm = false

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

                Text(L10n.tr(statusText)).font(.footnote).foregroundStyle(.secondary)

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
            .navigationTitle("录制语音备忘")
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
                }
            }
            .confirmationDialog("放弃本次录音？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                Button("放弃录音", role: .destructive) {
                    audio.cancelRecording()
                    dismiss()
                }
                Button("保存录音") { finishAndSave() }
            }
            .interactiveDismissDisabled(audio.isRecording)
            .task { await startIfPossible() }
        }
    }

    private var statusText: String {
        if !audio.isRecording { return "准备录音…" }
        return audio.isPaused ? "已暂停 · 点击继续" : "正在录音 · 锁屏也会继续录制"
    }

    private var controls: some View {
        HStack(spacing: 48) {
            // 暂停 / 继续
            Button {
                Haptic.light()
                audio.isPaused ? audio.resumeRecording() : audio.pauseRecording()
            } label: {
                Image(systemName: audio.isPaused ? "play.fill" : "pause.fill")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }
            .disabled(!audio.isRecording)

            // 完成
            Button {
                finishAndSave()
            } label: {
                ZStack {
                    Circle().strokeBorder(Color.red.opacity(0.35), lineWidth: 4).frame(width: 84, height: 84)
                    RoundedRectangle(cornerRadius: 8).fill(Color.red).frame(width: 34, height: 34)
                }
            }
            .disabled(!audio.isRecording)
            .accessibilityLabel("完成并保存")

            // 占位以保持居中
            Color.clear.frame(width: 56, height: 56)
        }
        .foregroundStyle(.primary)
    }

    private func startIfPossible() async {
        guard !audio.isRecording else { return }
        guard await audio.requestMicPermission() else {
            errorText = VoiceMemoError.micDenied.localizedDescription
            return
        }
        do {
            try audio.startRecording()
            Haptic.medium()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func finishAndSave() {
        guard let result = audio.finishRecording() else {
            errorText = "录音时间太短，未保存"
            Haptic.warning()
            return
        }
        let memo = VoiceMemo(title: VoiceMemo.defaultTitle(), duration: result.duration, audioFileName: result.fileName, tag: tag)
        context.insert(memo)
        try? context.save()
        Haptic.success()
        if autoTranscribe {
            VoiceMemoActions.transcribeInBackground(memo, context: context)
        }
        dismiss()
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
                        .fill(isActive ? Color.red : Color.secondary.opacity(0.5))
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
    static func delete(_ memo: VoiceMemo, context: ModelContext) {
        let audio = VoiceMemoAudioService.shared
        if audio.playingFileName == memo.audioFileName { audio.stopPlayback() }
        VoiceMemoStorage.delete(memo.audioFileName)
        context.delete(memo)
        try? context.save()
    }

    /// 后台离线转写，完成后写回转写文本、要点与标题
    static func transcribeInBackground(_ memo: VoiceMemo, context: ModelContext, onError: ((String) -> Void)? = nil) {
        Task {
            do {
                let text = try await VoiceMemoAudioService.shared.transcribe(memo: memo)
                apply(transcription: text, to: memo)
                try? context.save()
                if text.isEmpty { onError?("未识别到有效语音内容") }
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }

    static func apply(transcription text: String, to memo: VoiceMemo) {
        memo.transcription = text
        let summary = VoiceMemoTextAnalyzer.summarize(text)
        memo.summary = summary.isEmpty ? nil : summary
        // 仍是默认标题时，用转写首句替换
        if memo.title.hasPrefix("语音备忘 "), let t = VoiceMemoTextAnalyzer.suggestedTitle(from: text) {
            memo.title = t
        }
    }
}
