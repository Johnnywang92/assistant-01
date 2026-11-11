import AssistantCore
import SwiftUI
import WidgetKit

// MARK: - 出门清点小组件（中号 4×2）
//
// 「出门带齐了吗」是每天要问好几次的问题 —— 桌面组件比开 App 快得多。
//
// 数据来自主 App 写入的 `snapshot.departureSnapshot`：
// - 场景判定（通勤/出差/遛狗…）由主 App 用运行时上下文算好写入，
//   扩展拿不到天气/位置，只能被动接受结论；
// - 勾选走既有的 `ToggleDepartureItemIntent`，落库链路与实时活动完全一致。
//
// 汇总数字（已确认 N/M）由 Core 的 `WatchDepartureSnapshot` 给出，
// 扩展不自己数 —— 计数口径只有一份。

struct DepartureChecklistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DepartureChecklistWidget", provider: SnapshotTimelineProvider()) { entry in
            DepartureChecklistWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("出门清点")
        .description("桌面直接勾选随身物品，出门一眼看清还差什么")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct DepartureChecklistWidgetView: View {
    let snapshot: WidgetSnapshot

    private var departure: WatchDepartureSnapshot? {
        snapshot.departureSnapshot
    }

    var body: some View {
        Group {
            if let departure {
                content(departure)
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://departure"))
        .modifier(DepartureAccessoryModifier(departure: departure))
    }

    @ViewBuilder
    private func content(_ departure: WatchDepartureSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：场景名 + 已确认 N/M
            HStack(spacing: 4) {
                Image(systemName: departure.isAllChecked ? "checkmark.seal.fill" : "bag.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(departure.isAllChecked ? WidgetTheme.success : WidgetTheme.primary)
                Text(departure.sceneName)
                    .font(.caption.bold())
                    .foregroundStyle(WidgetTheme.text)
                Spacer(minLength: 0)
                if departure.totalCount > 0 {
                    Text("\(departure.checkedCount)/\(departure.totalCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(departure.isAllChecked ? WidgetTheme.success : WidgetTheme.primary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 4)

            if departure.isAllChecked {
                // 全部带齐
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(WidgetTheme.success)
                    Text("全部带齐")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetTheme.text)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 未勾选的优先显示（快照已排好序：未勾 → 必带 → 创建时间）
                let pending = departure.items.filter { !$0.isChecked }.prefix(5)
                if pending.isEmpty {
                    Text("清单已清空")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pending)) { item in
                        DepartureWidgetRow(item: item)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "bag")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("还没有出门清单")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单条清单项：点圆圈直接勾选。
struct DepartureWidgetRow: View {
    let item: WatchDepartureItem

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: ToggleDepartureItemIntent(itemID: item.id.uuidString, isChecked: true)) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(WidgetTheme.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("确认已带上：\(item.title)")

            Text(item.title)
                .font(.system(size: 12))
                .foregroundStyle(WidgetTheme.text)
                .lineLimit(1)

            // 必带项加一个标记，别和普通项混在一起
            if item.isEssential {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetTheme.warningText)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            if let note = item.locationNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 20)
    }
}

// MARK: - 锁屏 accessory 家族

struct DepartureAccessoryModifier: ViewModifier {
    let departure: WatchDepartureSnapshot?

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
        if let departure {
            VStack(alignment: .leading, spacing: 2) {
                Text(departure.sceneName)
                    .font(.headline)
                if departure.isAllChecked {
                    Text("全部带齐 ✓")
                        .font(.caption)
                } else {
                    Text("已确认 \(departure.checkedCount)/\(departure.totalCount)")
                        .font(.caption)
                    if let next = departure.items.first(where: { !$0.isChecked }) {
                        Text(next.title)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let departure {
            if departure.isAllChecked {
                Text("✓ \(departure.sceneName) 全部带齐")
            } else {
                Text("\(departure.sceneName) \(departure.checkedCount)/\(departure.totalCount)")
            }
        }
    }
}
