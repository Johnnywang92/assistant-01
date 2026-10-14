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
/// 整行包进 Button：只把右侧小字「已取件」当热区时，锁屏上要点得很准，
/// Mac 通知中心镜像卡片时更是难点中；整行可点后热区高度和宽度都翻倍以上。
struct PickupCodeList: View {
    let context: ActivityViewContext<PickupActivityAttributes>
    let compact: Bool

    var body: some View {
        let remaining = context.attributes.parcels.filter { !context.state.completedIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            ForEach(remaining.prefix(compact ? 1 : 4)) { parcel in
                Button(intent: CompleteTodoIntent(todoID: parcel.id.uuidString)) {
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
                        Label("已取件", systemImage: "checkmark.circle.fill")
                            .font(compact ? .caption2 : .footnote.bold())
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, compact ? 4 : 10)
                    .padding(.horizontal, compact ? 4 : 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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
    // 多件时再垫一个通栏「全部取齐」：不想逐件点时，一次就能把卡片关掉。
    private var pickupLockCard: some View {
        let remaining = PickupProgress.remainingCount(parcels: context.attributes.parcels,
                                                      completedIDs: context.state.completedIDs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.station, systemImage: "shippingbox.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
                Text(remaining > 0 ? "待取 \(remaining) 件" : "全部完成 ✓")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PickupCodeList(context: context, compact: false)
            if remaining > 1 {
                let pendingIDs = context.attributes.parcels
                    .filter { !context.state.completedIDs.contains($0.id) }
                    .map { $0.id.uuidString }
                    .joined(separator: ",")
                Button(intent: CompleteAllParcelsIntent(parcelIDs: pendingIDs)) {
                    Label("全部取齐，关闭卡片", systemImage: "checkmark.seal.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
            }
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
                        // 通栏胶囊大按钮：结束护航是这张卡最常见的「关闭」动作，
                        // 热区不能只贴着文字那一条。
                        Button(intent: EndTravelActivityIntent()) {
                            Label("已出发，关闭卡片", systemImage: "checkmark.circle.fill")
                                .font(.footnote.bold())
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.borderless)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
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
                TravelCountdown(context: context)
                    .foregroundStyle(.blue)
            }
            // 「已出发」从右侧小按钮改成通栏底部大按钮：Mac/锁屏上都是一眼就能看到、一下就能点中的关闭入口。
            Button(intent: EndTravelActivityIntent()) {
                Label("已出发，关闭卡片", systemImage: "checkmark.circle.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
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
                    let unchecked = context.attributes.items.filter { !context.state.checkedIDs.contains($0.id) }.count
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
                let unchecked = context.attributes.items.filter { !context.state.checkedIDs.contains($0.id) }.count
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
        // 未确认项置顶、已勾项排后，并限制总行数：锁屏/灵动岛卡片高度有限，
        // 条目不封顶会把末尾清单项和收卡按钮直接裁掉，用户真正关心的只有「还差什么」。
        let pending = context.attributes.items.filter { !context.state.checkedIDs.contains($0.id) }
        let checked = context.attributes.items.filter { context.state.checkedIDs.contains($0.id) }
        let visibleCap = compact ? 3 : 4
        let visiblePending = Array(pending.prefix(visibleCap))
        let visibleChecked = Array(checked.prefix(max(0, visibleCap - visiblePending.count)))
        let hiddenCount = context.attributes.items.count - visiblePending.count - visibleChecked.count
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            ForEach(visiblePending) { item in
                departureRow(item: item, checked: false)
            }
            ForEach(visibleChecked) { item in
                departureRow(item: item, checked: true)
            }
            if hiddenCount > 0 {
                Text("还有 \(hiddenCount) 项已收起")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, compact ? 2 : 6)
            }
        }
    }

    @ViewBuilder
    private func departureRow(item: DepartureChecklistActivityAttributes.Item, checked: Bool) -> some View {
        // 垂直 padding + contentShape 把整行变成热区；灵动岛底部放不下太高，非 compact 只加适度留白
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
        .padding(.vertical, compact ? 2 : 4)
        .padding(.horizontal, compact ? 2 : 6)
        .contentShape(Rectangle())
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
        let allPending = context.attributes.items.filter { !context.state.checkedIDs.contains($0.id) }
        // 必带项永远排在前面：小方屏只放得下 3 行，被折进「还有 N 项」的应该只能是次要物品
        let pending = allPending.filter(\.isEssential) + allPending.filter { !$0.isEssential }
        let totalCount = context.attributes.items.count
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Label("出门清点", systemImage: "checklist")
                    .font(.caption2.bold())
                    .foregroundStyle(isLuminanceReduced ? Color.secondary : Color.mint)
                    .lineLimit(1)
                Spacer(minLength: 2)
                // 进度一目了然：抬腕先知道「带到哪了」再知道「还差什么」
                Text("\(totalCount - allPending.count)/\(totalCount)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
            }
            if pending.isEmpty {
                Text("已全部带齐 ✓")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(pending.prefix(3))) { item in
                    HStack(spacing: 4) {
                        // 用红色感叹号圆点替代「必带」文字胶囊：窄屏上文字标签会把标题挤截断
                        Image(systemName: item.isEssential ? "exclamationmark.circle.fill" : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(item.isEssential && !isLuminanceReduced ? Color.red : Color.secondary)
                        Text(item.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                if pending.count > 3 {
                    Text("还有 \(pending.count - 3) 项未带")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var departureLockCard: some View {
        let pending = context.attributes.items.filter { !context.state.checkedIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("出门清点 · \(context.attributes.sceneName)", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Text(pending.isEmpty ? "全部确认 ✓" : "还有 \(pending.count) 项未带")
                    .font(.caption)
                    .foregroundStyle(pending.isEmpty ? Color.green : Color.orange)
            }
            if pending.isEmpty {
                // 全部带齐时不再堆一串划线条目，总结一行 + 通栏关闭按钮，
                // 避免锁屏上出现关不掉的「死卡」
                Label("随身物品已全部带齐，可以出发了", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .padding(.vertical, 2)
                Button(intent: EndDepartureActivityIntent()) {
                    Label("关闭卡片", systemImage: "checkmark.circle.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
            } else {
                DepartureItemList(context: context, compact: false, interactive: true)
                if pending.count > 1 {
                    // 通栏一键收卡：赶时间时不用逐行点对勾，也解决「找不到关闭」
                    let allIDs = context.attributes.items.map { $0.id.uuidString }.joined(separator: ",")
                    Button(intent: CheckAllDepartureItemsIntent(itemIDs: allIDs)) {
                        Label("全部带齐，关闭卡片", systemImage: "checkmark.seal.fill")
                            .font(.footnote.bold())
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
