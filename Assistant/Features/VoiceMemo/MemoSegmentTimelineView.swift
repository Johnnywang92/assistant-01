import SwiftUI

/// 合并时间轴：把一条备忘里的多个录音片段按真实时长比例拼成一条。
///
/// 断点用竖线显式标出，播放位置的红线按「前面各段之和 + 当前段内进度」换算，
/// 点某一段直接跳到该段播放——避免用户以为进度条是整条备忘的时间轴。
struct MemoSegmentTimelineView: View {
    let segments: [MemoSegment]
    let activeFileName: String?
    let segmentProgress: TimeInterval
    let onSelect: (MemoSegment) -> Void

    private var total: TimeInterval {
        max(segments.reduce(0) { $0 + $1.duration }, 0.1)
    }

    private func startOffset(for index: Int) -> TimeInterval {
        segments.prefix(index).reduce(0) { $0 + $1.duration }
    }

    private var globalProgress: TimeInterval {
        guard let index = segments.firstIndex(where: { $0.fileName == activeFileName }) else { return 0 }
        return startOffset(for: index) + min(max(segmentProgress, 0), segments[index].duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            let barWidth = max(6, width * (segment.duration / total) - 3)
                            let isSegmentActive = segment.fileName == activeFileName
                            RoundedRectangle(cornerRadius: AppRadius.small)
                                .fill(
                                    isSegmentActive
                                        ? AnyShapeStyle(LinearGradient(colors: [Color.red, Color(red: 0.90, green: 0.20, blue: 0.24)], startPoint: .leading, endPoint: .trailing))
                                        : AnyShapeStyle(Color.red.opacity(0.18))
                                )
                                .frame(width: barWidth, height: 20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.small)
                                        .strokeBorder(isSegmentActive ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(segment) }
                                .accessibilityLabel("播放片段 \(index + 1)，时长 \(formatMemoDuration(segment.duration))")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    if activeFileName != nil {
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 3, height: 26)
                            .shadow(color: Color.black.opacity(0.35), radius: 2)
                            .offset(x: min(width - 3, width * (globalProgress / total)))
                    }
                }
            }
            .frame(height: 26)

            HStack(spacing: 8) {
                Text("\(segments.count) 段 · 共 \(formatMemoDuration(total))")
                Spacer()
                if segments.count > 1 {
                    Text("竖线为断点 · 点段落可单独播放")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}
