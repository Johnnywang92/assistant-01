import AssistantCore
import SwiftUI
import UIKit

// MARK: - 方案 C · 今日概览卡 / 完成环 / 今日节奏卡
//
// 视图只消费 Core 的 `HomeSnapshot`，不自行计算任何数字。
// 颜色走 HomeColor 语义色、圆角走 AppRadius 令牌、字号走 HomeTypography。
// 详见 docs/home-redesign-handoff.md §2 / §3 / §5。

struct HomeOverviewCard: View {
    let snapshot: HomeSnapshot
    var fontScale: CGFloat = 1
    var onRingTap: () -> Void = {}

    private var freeText: String {
        if snapshot.isAllDayFree { return "全天空闲" }
        let hours = snapshot.freeMinutes / 60
        let minutes = snapshot.freeMinutes % 60
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    private var accessibilitySummary: String {
        "已完成 \(snapshot.done) 件，共 \(snapshot.total) 件；剩余空闲 \(freeText)；待处理提醒 \(snapshot.reminderCount) 条"
    }

    var body: some View {
        Button(action: onRingTap) {
            HStack(spacing: AppSpacing.lg) {
                ProgressRing(
                    fraction: snapshot.progressFraction,
                    done: snapshot.done,
                    total: snapshot.total,
                    isAllDone: snapshot.state == .allDone,
                    fontScale: fontScale
                )

                VStack(alignment: .leading, spacing: fontScale > 1 ? 8 : 6) {
                    Text("今日概览")
                        .font(HomeTypography.font(.metric, scale: fontScale))
                        .foregroundStyle(HomeColor.tertiaryText)

                    metric("\(snapshot.total) 件", "今日待办")
                    metric(freeText, "剩余空闲")
                    metric("\(snapshot.reminderCount) 条", "待处理提醒",
                           emphasis: snapshot.reminderCount > 0 ? HomeColor.warningText : nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(fontScale > 1 ? 20 : AppSpacing.lg)
            .background(HomeColor.card)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.homeCard))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: fontScale > 1 ? nil : 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("展开当日清单")
        .accessibilityAddTraits(.isButton)
        .onChange(of: snapshot.done) { _, newValue in
            // 数字变化发 announcement，VoiceOver 用户不必手动重新聚焦
            UIAccessibility.post(
                notification: .announcement,
                argument: "已完成 \(newValue) 件，共 \(snapshot.total) 件"
            )
        }
    }

    @ViewBuilder
    private func metric(_ value: String, _ label: String, emphasis: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(HomeTypography.font(.metric, weight: .semibold, scale: fontScale))
                .foregroundStyle(emphasis ?? HomeColor.text)
            Text(label)
                .font(HomeTypography.font(.metric, scale: fontScale))
                .foregroundStyle(HomeColor.secondaryText)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

/// 完成环：96×96 固定，不随文字伸缩；空态也不隐藏。
struct ProgressRing: View {
    let fraction: Double
    let done: Int
    let total: Int
    let isAllDone: Bool
    var fontScale: CGFloat = 1

    private var ringColor: Color {
        isAllDone ? HomeColor.success : HomeColor.primary
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(HomeColor.ringTrack, lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(done)/\(total)")
                    .font(.system(size: 25 * max(1, fontScale), weight: .bold))
                    .foregroundStyle(ringColor)
                    .minimumScaleFactor(0.8)
                Text("已完成")
                    .font(HomeTypography.font(.auxiliary, scale: fontScale))
                    .foregroundStyle(HomeColor.tertiaryText)
            }
        }
        .frame(width: 96, height: 96)
        .accessibilityHidden(true) // 整卡已给合并 label，避免重复朗读
    }
}

// MARK: - 今日节奏卡

struct HomeRhythmCard: View {
    let snapshot: HomeSnapshot
    let windowText: String
    var fontScale: CGFloat = 1

    private var legend: String {
        if snapshot.isAllDayFree { return "全天空闲" }
        let hours = snapshot.freeMinutes / 60
        let minutes = snapshot.freeMinutes % 60
        return hours > 0 ? "剩余空闲 \(hours) 小时 \(minutes) 分钟" : "剩余空闲 \(minutes) 分钟"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fontScale > 1 ? 8 : 6) {
            HStack {
                Text("今日节奏")
                    .font(HomeTypography.font(.cardTitle, weight: .semibold, scale: fontScale))
                    .foregroundStyle(HomeColor.text)
                Spacer()
                Text(windowText)
                    .font(HomeTypography.font(.auxiliary, scale: fontScale))
                    .foregroundStyle(HomeColor.tertiaryText)
            }

            RhythmTimelineBar(segments: snapshot.segments)

            Text(legend)
                .font(HomeTypography.font(.body, scale: fontScale))
                .foregroundStyle(HomeColor.secondaryText)
        }
        .padding(fontScale > 1 ? 16 : 14)
        .background(HomeColor.card)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.homeCard))
        .frame(height: fontScale > 1 ? nil : 100)
    }
}

/// 时间带：色块宽度按当日窗口比例算，**禁止硬编码像素**。
struct RhythmTimelineBar: View {
    let segments: [HomeTimelineSlice]

    private func color(for segment: HomeTimelineSegment) -> Color {
        switch segment {
        case .free: return HomeColor.ringTrack
        case .busy: return HomeColor.primary
        case .reminder: return HomeColor.warning
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(color(for: segments[index].segment))
                        .frame(width: geo.size.width * segments[index].weight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.homeBlock))
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日节奏时间带")
    }
}
