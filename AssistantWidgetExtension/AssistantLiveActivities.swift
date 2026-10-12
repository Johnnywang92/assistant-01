import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 场景 1：快递取件实时活动（灵动岛 + 锁屏 + 手表智能叠放）
//
// ⚠️ 关于 Apple Watch 的交互边界（决定本文件的排版方式）：
// watchOS 11 起，iPhone 的实时活动会自动出现在 Apple Watch 智能叠放，且不需要 watchOS App。
// 但「没有 watchOS App」时它**不可交互**——整张卡片是单一点击目标，点击后系统展开全屏视图并提供
// 「在 iPhone 上打开」（WWDC24 Session 10098《Design Live Activities for Apple Watch》）。
// 因此 `.small`（手表）分支里放 Button(intent:) 是无效的，只会给用户一个点不动的假按钮。
// 分工：本文件负责「抬腕就看得到大字码」，动手销号交给 PickupCheckoutService 的可交互通知。

struct PickupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PickupActivityAttributes.self) { context in
            PickupLockScreenView(context: context)
                .activitySystemActionForegroundColor(.primary)
                .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.station, systemImage: "shippingbox.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(PickupProgress.remainingCount(parcels: context.attributes.parcels, completedIDs: context.state.completedIDs)) 件待取")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PickupCodeList(context: context, compact: false)
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                // 必须取「下一个未取」，不能用 parcels.first：
                // 否则取完第一件后，灵动岛会一直挂着已取件包裹的旧码。
                let next = PickupProgress.nextPending(parcels: context.attributes.parcels,
                                                      completedIDs: context.state.completedIDs)
                Text(next?.code ?? "已取齐")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(next == nil ? Color.green : Color.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } minimal: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.orange)
            }
            .widgetURL(URL(string: "assistant://todos"))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// 取件码列表。只在 iPhone（锁屏 .medium / 灵动岛展开态）使用带按钮的版本。
struct PickupCodeList: View {
    let context: ActivityViewContext<PickupActivityAttributes>
    let compact: Bool

    var body: some View {
        let remaining = context.attributes.parcels.filter { !context.state.completedIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            ForEach(remaining.prefix(compact ? 1 : 4)) { parcel in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(parcel.code)
                            .font(Font.system(compact ? Font.TextStyle.callout : Font.TextStyle.title2, design: .monospaced).bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if !compact {
                            Text([parcel.courier, parcel.title].compactMap { $0 }.prefix(1).joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(intent: CompleteTodoIntent(todoID: parcel.id.uuidString)) {
                        Label("已取件", systemImage: "checkmark.circle.fill")
                            .font(compact ? .caption2 : .footnote.bold())
                    }
                    .buttonStyle(.borderless)
                    .tint(.green)
                }
            }
        }
    }
}

struct PickupLockScreenView: View {
    let context: ActivityViewContext<PickupActivityAttributes>

    @Environment(\.activityFamily) private var activityFamily
    /// 抬腕后手腕放下时系统会降亮度（Always-On），此时去掉高饱和色块，避免刺眼与耗电。
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        Group {
            if activityFamily == .small {
                pickupWristCard
            } else {
                pickupLockCard
            }
        }
    }

    // MARK: Apple Watch 智能叠放：纯展示，大字取件码
    @ViewBuilder
    private var pickupWristCard: some View {
        let next = PickupProgress.nextPending(parcels: context.attributes.parcels,
                                              completedIDs: context.state.completedIDs)
        let remaining = PickupProgress.remainingCount(parcels: context.attributes.parcels,
                                                      completedIDs: context.state.completedIDs)
        VStack(alignment: .leading, spacing: 3) {
            Label(context.attributes.station, systemImage: "shippingbox.fill")
                .font(.caption2.bold())
                .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.orange)
                .lineLimit(1)

            if let next {
                Text(next.code)
                    .font(.largeTitle.monospaced().bold())
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                Text(remaining > 1 ? "还剩 \(remaining) 件 · 取到就去通知点「已取件」"
                                   : "取到就去通知点「已取件」")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("全部已取件 ✓")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: iPhone 锁屏：大字 + 逐件销号按钮（这里按钮是真的能点）
    private var pickupLockCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.station, systemImage: "shippingbox.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                let remaining = PickupProgress.remainingCount(parcels: context.attributes.parcels,
                                                              completedIDs: context.state.completedIDs)
                Text(remaining > 0 ? "待取 \(remaining) 件" : "全部完成 ✓")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PickupCodeList(context: context, compact: false)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 场景 2：行程护航实时活动

struct TravelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TravelActivityAttributes.self) { context in
            TravelLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let summary = context.attributes.ticketSummary {
                            Text(summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let place = context.attributes.place {
                            Text(place)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TravelCountdown(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let gate = context.attributes.gate {
                            Label("检票口 \(gate)", systemImage: "signpost.right")
                                .font(.caption.bold())
                                .lineLimit(1)
                        }
                        if let note = context.state.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button(intent: EndTravelActivityIntent()) {
                            Label("已出发，结束护航", systemImage: "checkmark.circle.fill")
                                .font(.footnote.bold())
                        }
                        .buttonStyle(.borderless)
                        .tint(.green)
                    }
                }
            } compactLeading: {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                TravelCountdown(context: context, compact: true)
            } minimal: {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(.blue)
            }
            .widgetURL(URL(string: "assistant://todos"))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// 发车倒计时。用 Text(timerInterval:) 由系统驱动刷新，不额外消耗 update 预算。
struct TravelCountdown: View {
    let context: ActivityViewContext<TravelActivityAttributes>
    var compact: Bool = false

    var body: some View {
        let range = Date.now...max(Date.now, context.state.departureDate)
        Text(timerInterval: range, countsDown: true)
            .font(compact ? .caption2.monospaced() : .title3.monospaced().bold())
            .multilineTextAlignment(.trailing)
            .frame(width: compact ? 44 : nil)
    }
}

struct TravelLockScreenView: View {
    let context: ActivityViewContext<TravelActivityAttributes>

    @Environment(\.activityFamily) private var activityFamily
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        Group {
            if activityFamily == .small {
                travelWristCard
            } else {
                travelLockCard
            }
        }
    }

    // MARK: 手表：车次 + 倒计时 + 座位/检票口，一次抬腕全看到
    @ViewBuilder
    private var travelWristCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(context.attributes.title)
                .font(.headline)
                .lineLimit(1)
            TravelCountdown(context: context)
                .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.blue)
            if let summary = context.attributes.ticketSummary {
                Text(summary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let place = context.attributes.place {
                Text(place)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let gate = context.attributes.gate {
                Text("检票口 \(gate)")
                    .font(.caption2.bold())
                    .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var travelLockCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                if let summary = context.attributes.ticketSummary {
                    Text(summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let place = context.attributes.place {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let gate = context.attributes.gate {
                    Label("检票口 \(gate)", systemImage: "signpost.right")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if let note = context.state.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                TravelCountdown(context: context)
                    .foregroundStyle(.blue)
                Button(intent: EndTravelActivityIntent()) {
                    Label("已出发", systemImage: "checkmark")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderless)
                .tint(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 场景 2：出门防丢清点实时活动

struct DepartureChecklistLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DepartureChecklistActivityAttributes.self) { context in
            DepartureLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("出门清点 · \(context.attributes.sceneName)", systemImage: "checklist")
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    let unchecked = context.attributes.items.count - context.state.checkedIDs.count
                    Text(unchecked > 0 ? "\(unchecked) 项未带" : "已带齐 ✓")
                        .font(.caption2)
                        .foregroundStyle(unchecked > 0 ? Color.orange : Color.green)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DepartureItemList(context: context, compact: false, interactive: true)
                }
            } compactLeading: {
                Image(systemName: "checklist")
                    .foregroundStyle(.mint)
            } compactTrailing: {
                let unchecked = context.attributes.items.count - context.state.checkedIDs.count
                Text(unchecked > 0 ? "\(unchecked)" : "✓")
                    .font(.caption2.bold())
            } minimal: {
                Image(systemName: "checklist")
                    .foregroundStyle(.mint)
            }
            .widgetURL(URL(string: "assistant://checklist"))
        }
        .supplementalActivityFamilies([.small])
    }
}

struct DepartureItemList: View {
    let context: ActivityViewContext<DepartureChecklistActivityAttributes>
    let compact: Bool
    /// 手表上的智能叠放卡片不可交互，interactive = false 时只渲染状态圆点，不放按钮。
    var interactive: Bool = true

    var body: some View {
        let items = compact ? Array(context.attributes.items.prefix(3)) : context.attributes.items
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            ForEach(items) { item in
                let checked = context.state.checkedIDs.contains(item.id)
                departureRow(item: item, checked: checked)
            }
        }
    }

    @ViewBuilder
    private func departureRow(item: DepartureChecklistActivityAttributes.Item, checked: Bool) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? .green : .secondary)
            Text(item.title)
                .font(compact ? .caption2 : .footnote)
                .strikethrough(checked)
                .lineLimit(1)
            if item.isEssential && !checked {
                Text("必带")
                    .font(.caption2.bold())
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        if interactive {
            Button(intent: ToggleDepartureItemIntent(itemID: item.id.uuidString, isChecked: !checked)) {
                label
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
        } else {
            label
        }
    }
}

struct DepartureLockScreenView: View {
    let context: ActivityViewContext<DepartureChecklistActivityAttributes>

    @Environment(\.activityFamily) private var activityFamily
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        Group {
            if activityFamily == .small {
                departureWristCard
            } else {
                departureLockCard
            }
        }
    }

    // MARK: 手表：只回答「我还差什么」，打勾在 iPhone 锁屏/灵动岛做
    @ViewBuilder
    private var departureWristCard: some View {
        let pending = context.attributes.items.filter { !context.state.checkedIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 3) {
            Label("出门清点", systemImage: "checklist")
                .font(.caption2.bold())
                .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.mint)
                .lineLimit(1)
            if pending.isEmpty {
                Text("已全部带齐 ✓")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(pending.prefix(3))) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .strokeBorder(.secondary, lineWidth: 1)
                            .frame(width: 8, height: 8)
                        Text(item.title)
                            .font(.caption2)
                            .lineLimit(1)
                        if item.isEssential {
                            Text("必带")
                                .font(.caption2.bold())
                                .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.red)
                        }
                    }
                }
                if pending.count > 3 {
                    Text("还有 \(pending.count - 3) 项…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var departureLockCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("出门清点 · \(context.attributes.sceneName)", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                let unchecked = context.attributes.items.count - context.state.checkedIDs.count
                Text(unchecked > 0 ? "还有 \(unchecked) 项未带" : "全部确认 ✓")
                    .font(.caption)
                    .foregroundStyle(unchecked > 0 ? Color.orange : Color.green)
            }
            DepartureItemList(context: context, compact: false, interactive: true)
        }
        .padding(.vertical, 4)
    }
}
