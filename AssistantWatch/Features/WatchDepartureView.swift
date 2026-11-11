import AssistantCore
import SwiftUI
import WatchKit

struct WatchDepartureView: View {
    @EnvironmentObject private var store: WatchStore

    /// 当手机端尚未初始化自定义清点项时，提供本地「身·手·钥·耳」四字诀交互状态
    @State private var localChecked: Set<String> = []

    private var snap: WidgetSnapshot {
        store.displaySnapshot
    }

    private let fallbackEssentials: [(id: String, title: String, subtitle: String)] = [
        ("shen", "身 · 身份证/工牌", "证件卡包"),
        ("shou", "手 · 手机/电量", "随身电源"),
        ("yao", "钥 · 钥匙/门禁", "玄关挂钩"),
        ("er", "耳 · 耳机/雨具", "通勤随身")
    ]

    var body: some View {
        NavigationStack {
            List {
                // 1. 行程护航卡（若有近期高铁/航班待办）
                if let travel = snap.travelSnapshot {
                    Section {
                        travelCard(travel)
                    } header: {
                        Text("行程护航")
                    }
                }

                // 2. 出门防丢清点清单
                if let dep = snap.departureSnapshot, !dep.items.isEmpty {
                    let uncheckedItems = dep.items.filter { !$0.isChecked }
                    let checkedCount = dep.items.count - uncheckedItems.count

                    Section {
                        if !uncheckedItems.isEmpty {
                            Button {
                                let allIDs = dep.items.map(\.id)
                                store.sendCommand(
                                    .completeAllDeparture(allIDs),
                                    feedbackToast: "随身物品全部带齐 ✓"
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                    Text("全部带齐 (\(uncheckedItems.count)项待核对)")
                                        .font(.footnote.bold())
                                        .foregroundStyle(.green)
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                Text("全部带齐，安心出发！")
                                    .font(.footnote.bold())
                                    .foregroundStyle(.green)
                            }
                        }

                        ForEach(dep.items) { item in
                            departureItemRow(item)
                        }
                    } header: {
                        HStack {
                            Text(dep.sceneName)
                            Spacer()
                            Text("\(checkedCount)/\(dep.items.count)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                } else {
                    // 保底「身·手·钥·耳」出门 3 秒指差确认
                    Section {
                        if localChecked.count < fallbackEssentials.count {
                            Button {
                                WKInterfaceDevice.current().play(.success)
                                localChecked = Set(fallbackEssentials.map(\.id))
                                store.showBanner("四字诀清点完成，安心出发 ✓")
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                    Text("一键确认全部带齐")
                                        .font(.footnote.bold())
                                        .foregroundStyle(.green)
                                }
                            }
                        } else {
                            Button {
                                WKInterfaceDevice.current().play(.click)
                                localChecked.removeAll()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .foregroundStyle(.mint)
                                    Text("已全部确认 · 轻触重置")
                                        .font(.footnote.bold())
                                        .foregroundStyle(.mint)
                                }
                            }
                        }

                        ForEach(fallbackEssentials, id: \.id) { item in
                            let isDone = localChecked.contains(item.id)
                            Button {
                                WKInterfaceDevice.current().play(.click)
                                if isDone {
                                    localChecked.remove(item.id)
                                } else {
                                    localChecked.insert(item.id)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isDone ? .green : .orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.footnote.weight(.medium))
                                            .strikethrough(isDone)
                                        Text(item.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("身·手·钥·耳 指差清点")
                            Spacer()
                            Text("\(localChecked.count)/\(fallbackEssentials.count)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .navigationTitle("出行清点")
        }
    }

    @ViewBuilder
    private func travelCard(_ travel: WatchTravelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(.cyan)
                    .font(.caption)
                Text(travel.title)
                    .font(.footnote.bold())
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let gate = travel.gate, !gate.isEmpty {
                    Text("检票 \(gate)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                }
            }

            HStack(alignment: .firstTextBaseline) {
                // 倒计时口径与 App / 桌面组件同源（Core 的 `TravelCountdownPolicy`）：
                // - 不足 1 天 → 系统计时器逐秒走（HH:MM:SS）；
                // - 超过 1 天 → 走「还有 N 天」，否则 timerInterval 会显示「72:00:00」这种没法读的巨长时分秒。
                if travel.departureDate > .now {
                    if TravelCountdownPolicy.isImminent(departureAt: travel.departureDate, now: .now) {
                        Text(timerInterval: Date.now...travel.departureDate, countsDown: true)
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.cyan)
                    } else {
                        Text(TravelCountdownPolicy.text(departureAt: travel.departureDate, now: .now))
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundStyle(.cyan)
                    }
                } else {
                    Text(TravelCountdownPolicy.text(departureAt: travel.departureDate, now: .now))
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(travel.departureDate, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let summary = travel.ticketSummary, !summary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "chair.lounge.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text(summary)
                        .font(.caption2.monospaced().bold())
                        .lineLimit(1)
                }
            } else if let place = travel.place, !place.isEmpty {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                store.sendCommand(.completeTodo(travel.id), feedbackToast: "祝旅途愉快 ✓")
            } label: {
                HStack {
                    Spacer()
                    Label("已登车 / 结束护航", systemImage: "checkmark.circle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.vertical, 3)
    }

    private func departureItemRow(_ item: WatchDepartureItem) -> some View {
        Button {
            store.sendCommand(
                .toggleDeparture(item.id, !item.isChecked),
                feedbackToast: !item.isChecked ? "已带 \(item.title) ✓" : "取消勾选"
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.footnote)
                    .foregroundStyle(item.isChecked ? .green : (item.isEssential ? .orange : .secondary))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.footnote)
                            .strikethrough(item.isChecked)
                            .lineLimit(1)
                        if item.isEssential && !item.isChecked {
                            Text("必带")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                        }
                    }
                    if let loc = item.locationNote, !loc.isEmpty {
                        Text(loc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
