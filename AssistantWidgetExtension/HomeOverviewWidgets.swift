import AssistantCore
import SwiftUI
import WidgetKit

// MARK: - 今日概览小组件（中号 4×2）
//
// 与 App 首页同源：完成环数字、空闲时长、今日节奏、主任务
// 全部来自主 App 写入的 `snapshot.homeOverview`，**扩展不自己算**。
//
// 为什么值得单独做一个小组件：
// App 首页的概览卡回答的是「今天还剩多少、节奏如何、接下来做什么」，
// 这三件事恰恰是桌面上一瞥就该知道的信息。

struct HomeOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HomeOverviewWidget", provider: SnapshotTimelineProvider()) { entry in
            HomeOverviewWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("今日概览")
        .description("完成进度、今日空闲与接下来的主任务，与 App 首页一致")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct HomeOverviewWidgetView: View {
    let snapshot: WidgetSnapshot

    private var overview: WidgetHomeOverview {
        snapshot.homeOverview ?? .empty
    }

    var body: some View {
        Group {
            if let entry = snapshot.homeOverview {
                content(entry)
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://todos"))
        .modifier(HomeOverviewAccessoryModifier(overview: overview))
    }

    // MARK: 中号（4×2）

    @ViewBuilder
    private func content(_ entry: WidgetHomeOverview) -> some View {
        HStack(spacing: 14) {
            // 完成环
            ZStack {
                WidgetProgressRing(fraction: entry.progressFraction, lineWidth: 8, tint: WidgetTheme.primary)
                VStack(spacing: 0) {
                    Text("\(entry.done)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetTheme.text)
                    Text("/ \(entry.total)")
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetTheme.secondaryText)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetTheme.primary)
                    Text(entry.freeTimeText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetTheme.text)
                    Text("空闲")
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetTheme.secondaryText)
                }

                WidgetRhythmBar(freeRatio: entry.freeRatio, busyRatio: entry.busyRatio)
                    .frame(height: 6)
                    .clipShape(Capsule())

                if let title = entry.priorityTaskTitle, !title.isEmpty {
                    HStack(spacing: 4) {
                        Text("接下来")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(WidgetTheme.primary)
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetTheme.text)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(WidgetTheme.success)
            Text("还没有今日数据")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("打开 App 后自动同步")
                .font(.caption2)
                .foregroundStyle(WidgetTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 锁屏 accessory 家族

/// 按 `widgetFamily` 分派到锁屏形态。
/// 与既有 `GlanceAccessoryModifier` 同模式：`widgetAccessoryCircular` 等是
/// `View` 扩展，不能在 `ViewModifier.body` 内部对 `Content` 调用。
struct HomeOverviewAccessoryModifier: ViewModifier {
    let overview: WidgetHomeOverview

    @Environment(\.widgetFamily) private var family

    @ViewBuilder
    func body(content: Content) -> some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            content
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            WidgetProgressRing(fraction: overview.progressFraction, lineWidth: 4, tint: .white)
            Text("\(overview.done)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日 \(overview.done)/\(overview.total)")
                .font(.headline)
            Text("\(overview.freeTimeText)空闲")
                .font(.caption)
            if let title = overview.priorityTaskTitle, !title.isEmpty {
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    private var inline: some View {
        Text("今日 \(overview.done)/\(overview.total) · 空闲 \(overview.freeTimeText)")
    }
}

// MARK: - 纪念日倒计时小组件（中号 4×2 + 锁屏）

/// 纪念日倒计时。
///
/// 数据来自主 App 写入的 `snapshot.anniversaries`，农历换算由 Core 统一处理
/// （`AnniversaryCountdown`），扩展只渲染。
struct AnniversaryCountdownWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AnniversaryCountdownWidget", provider: SnapshotTimelineProvider()) { entry in
            AnniversaryCountdownWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("纪念日倒数")
        .description("下一个纪念日还有多少天，支持农历")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct AnniversaryCountdownWidgetView: View {
    let snapshot: WidgetSnapshot

    private var entries: [WidgetAnniversaryEntry] {
        snapshot.anniversaries
    }

    var body: some View {
        Group {
            if let first = entries.first {
                content(first)
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://anniversaries"))
        .modifier(AnniversaryAccessoryModifier(entry: entries.first))
    }

    @ViewBuilder
    private func content(_ first: WidgetAnniversaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetTheme.warningText)
                Text("纪念日")
                    .font(.caption2.bold())
                    .foregroundStyle(WidgetTheme.secondaryText)
                if first.isLunar {
                    Text("农历")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(WidgetTheme.warningText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(WidgetTheme.warning.opacity(0.25)))
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 4)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(first.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WidgetTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(first.daysUntil == 0 ? "就是今天" : "\(first.daysUntil)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetTheme.warningText)
                Text(first.daysUntil == 0 ? "" : "天后")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetTheme.secondaryText)
                Spacer(minLength: 0)
            }

            if first.yearsCount > 1 {
                Text("第 \(first.yearsCount) 年 · 已相伴 \(first.passedDays) 天")
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetTheme.tertiaryText)
            }

            // 次要的两个纪念日
            let others = entries.dropFirst().prefix(2)
            if !others.isEmpty {
                Divider().opacity(0.4).padding(.vertical, 4)
                ForEach(Array(others)) { item in
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(WidgetTheme.tertiaryText)
                        Text(item.title)
                            .font(.system(size: 11))
                            .foregroundStyle(WidgetTheme.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(item.countdownText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(WidgetTheme.tertiaryText)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "gift")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("还没有纪念日")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AnniversaryAccessoryModifier: ViewModifier {
    let entry: WidgetAnniversaryEntry?

    @Environment(\.widgetFamily) private var family

    @ViewBuilder
    func body(content: Content) -> some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            content
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if let entry {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.countdownText)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let entry {
            Text("\(entry.title) · \(entry.countdownText)")
        }
    }
}
