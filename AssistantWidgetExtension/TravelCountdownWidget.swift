import AssistantCore
import SwiftUI
import WidgetKit

// MARK: - 行程倒计时小组件（中号 4×2 / 小号 / 锁屏）
//
// 「还有多久发车」是临近出行时最想知道的一件事，桌面组件比开 App 快得多。
//
// 数据全部来自主 App 写入的 `snapshot.travelSnapshot`，扩展**只渲染不计算**：
// - 选哪一趟行程、窗口多长、有没有可靠发车时刻，全部由主 App 用 Core 的
//   `TravelCountdownBuilder` 决定；
// - 扩展只负责把**倒计时文案**渲染出来，措辞同样取自 Core 的
//   `TravelCountdownPolicy.text`，保证桌面 / 手表 / 灵动岛三处完全一致。
//
// 关键：**没有可靠发车时刻时主 App 不会写入快照**，所以这里不会出现
// 「1 小时后发车」这种凭空编造的倒计时——宁可空态，也不谎报。

struct TravelCountdownWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TravelCountdownWidget", provider: SnapshotTimelineProvider()) { entry in
            TravelCountdownWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("行程倒计时")
        .description("距离发车还有多久，车次与检票口一眼看清")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct TravelCountdownWidgetView: View {
    let snapshot: WidgetSnapshot

    private var travel: WatchTravelSnapshot? {
        snapshot.travelSnapshot
    }

    var body: some View {
        Group {
            if let travel {
                content(travel)
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://todos"))
        .modifier(TravelCountdownAccessoryModifier(travel: travel))
    }

    // MARK: 中号（4×2）

    @ViewBuilder
    private func content(_ travel: WatchTravelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetTheme.primary)
                Text("行程倒计时")
                    .font(.caption2.bold())
                    .foregroundStyle(WidgetTheme.secondaryText)
                Spacer(minLength: 0)
                if let gate = travel.gate, !gate.isEmpty {
                    Text("检票 \(gate)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WidgetTheme.warningText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(WidgetTheme.warning.opacity(0.25)))
                }
            }
            .padding(.bottom, 4)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(travel.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WidgetTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            // 倒计时文案：Core 唯一口径，与手表/灵动岛一致
            Text(countdownText(travel.departureDate))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetTheme.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(travel.departureDate, format: .dateTime.month().day().hour().minute())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WidgetTheme.tertiaryText)

            if let summary = travel.ticketSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WidgetTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
    }

    /// 倒计时文案。走 Core 口径，措辞三端一致。
    private func countdownText(_ departure: Date) -> String {
        TravelCountdownPolicy.text(departureAt: departure, now: Date.now)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "ticket")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("暂无行程")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 锁屏 accessory 家族

struct TravelCountdownAccessoryModifier: ViewModifier {
    let travel: WatchTravelSnapshot?

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
        if let travel {
            VStack(alignment: .leading, spacing: 2) {
                Text(travel.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(TravelCountdownPolicy.text(departureAt: travel.departureDate, now: Date.now))
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let travel {
            Text("🚄 \(travel.title) · \(TravelCountdownPolicy.text(departureAt: travel.departureDate, now: Date.now))")
        }
    }
}
