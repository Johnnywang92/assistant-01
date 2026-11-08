import SwiftData
import SwiftUI

/// 录音片段管理（对应设计稿「03 · 续录完成 · 片段管理」）。
///
/// 详情页只留播放器与一个入口，重活都在这里：合并时间轴、逐段播放、
/// 删除单段（连同该段转写文字）、再续录一段。始终操作同一条备忘，不新建条目。
struct VoiceMemoSegmentListView: View {
    @Environment(\.modelContext) private var context
    @Bindable var memo: VoiceMemo
    @StateObject private var audio = VoiceMemoAudioService.shared

    @State private var segmentToDelete: MemoSegment?
    @State private var showRecorder = false

    private var segments: [MemoSegment] { memo.segments }
    /// 只把还在磁盘上的文件送进串播队列，避免中途因缺文件而断掉。
    private var playableFileNames: [String] {
        segments.filter { VoiceMemoStorage.exists($0.fileName) }.map(\.fileName)
    }
    private var activeFileName: String? {
        segments.contains { $0.fileName == audio.playingFileName } ? audio.playingFileName : nil
    }

    var body: some View {
        List {
            Section {
                summaryCard
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    segmentRow(index: index, segment: segment)
                }
            } header: {
                Text("全部片段 · 按录制顺序")
            } footer: {
                Text("删除片段会同步移除这一段转写的文字；没有归属记录的历史内容会保留。总时长按剩余片段重算。")
            }

            Section {
                Button {
                    showRecorder = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                        Text("再续录一段")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.card))
                }
                .buttonStyle(.plain)
            } footer: {
                Text("新内容仍保存在这条备忘里，不会多出一条。要点与待办可在详情页重新提炼。")
            }
        }
        .listStyle(.insetGrouped)
        .themedScrollContentBackground()
        .themedAppBackground()
        .navigationTitle("录音片段")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRecorder) {
            VoiceMemoRecorderSheet(memo: memo)
        }
        .confirmationDialog("删除这个片段？", isPresented: Binding(
            get: { segmentToDelete != nil }, set: { if !$0 { segmentToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除片段", role: .destructive) {
                if let segment = segmentToDelete {
                    VoiceMemoActions.deleteSegment(segment, from: memo, context: context)
                }
                segmentToDelete = nil
            }
        } message: {
            Text("对应音频与这一段转写的文字会一起删除；没有归属记录的历史内容保留。")
        }
    }

    // MARK: - 汇总卡

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(memo.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(segments.count) 段 · \(formatMemoDuration(memo.totalDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            MemoSegmentTimelineView(
                segments: segments,
                activeFileName: activeFileName,
                segmentProgress: audio.playbackTime
            ) { segment in
                // 点单段要退出合并播放，否则播完会接着跳到队列里的下一段。
                if !audio.playbackQueue.isEmpty { audio.stopPlayback() }
                Task { await audio.togglePlayback(fileName: segment.fileName) }
            }

            Button {
                if audio.isPlaying && activeFileName != nil {
                    audio.stopPlayback()
                } else {
                    Task { await audio.playSequence(fileNames: playableFileNames) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: audio.isPlaying && activeFileName != nil ? "stop.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                    Text(audio.isPlaying && activeFileName != nil ? "停止播放" : "合并播放全部片段")
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
                .shadow(color: Color.red.opacity(0.28), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(playableFileNames.isEmpty)
            .accessibilityLabel(audio.isPlaying && activeFileName != nil ? "停止播放" : "合并播放全部片段")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card))
    }

    // MARK: - 片段行

    @ViewBuilder
    private func segmentRow(index: Int, segment: MemoSegment) -> some View {
        let exists = VoiceMemoStorage.exists(segment.fileName)
        let playingThis = audio.playingFileName == segment.fileName
        // 只显示「有没有归属」而不数块数：块编辑器里删掉的块 ID 仍留在归属里，
        // 精确计数会与正文不符，而且每行解码 document 是列表帧里的重活。
        let hasOwnedTranscript = !(segment.transcriptBlockIDs?.isEmpty ?? true)
        HStack(spacing: 12) {
            Button {
                Task { await audio.togglePlayback(fileName: segment.fileName) }
                Haptic.light()
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            playingThis && audio.isPlaying
                                ? AnyShapeStyle(Color.red)
                                : (exists ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(Color(.tertiarySystemFill)))
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: playingThis && audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(playingThis && audio.isPlaying ? Color.white : (exists ? Color.red : Color.secondary))
                        .offset(x: playingThis && audio.isPlaying ? 0 : 1)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .disabled(!exists)
            .iconButton(playingThis && audio.isPlaying ? "暂停片段 \(index + 1)" : "播放片段 \(index + 1)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("片段 \(index + 1)")
                    if segment.interruptionReasonRaw == "interruption" {
                        Text("中断后续录").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if !exists {
                    Text("音频文件已丢失").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("\(segment.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(hasOwnedTranscript ? "已转写" : "无归属文字")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(formatMemoDuration(segment.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                segmentToDelete = segment
            } label: {
                Label("删除片段", systemImage: "trash")
            }
        }
    }
}
