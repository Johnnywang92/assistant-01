import SwiftUI

struct WatchTodayView: View {
    @EnvironmentObject private var store: WatchStore

    private var snap: WidgetSnapshot {
        store.displaySnapshot
    }

    var body: some View {
        NavigationStack {
            List {
                // 顶部状态：今日支出 + 练习 + 同步状态
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("今日支出")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(formatAmount(snap.todayExpense))
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if let practice = snap.todayPractice {
                            VStack(alignment: .trailing, spacing: 2) {
                                HStack(spacing: 2) {
                                    Image(systemName: "flame.fill")
                                        .foregroundStyle(.purple)
                                    Text("\(practice.streakDays)天")
                                }
                                .font(.caption2.bold())
                                Text(practice.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // 待取快递快捷入口（若有包裹）
                if !snap.parcels.isEmpty {
                    Section {
                        Button {
                            store.selectedTab = .parcels
                        } label: {
                            HStack {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("待取快递 \(snap.parcels.count) 件")
                                        .font(.footnote.bold())
                                    if let firstCode = snap.parcels.first?.pickupCode {
                                        Text("首件码：\(firstCode)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // 今日高优待办 Top 6
                Section {
                    if snap.topTodos.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("今日待办已清空")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(snap.topTodos) { item in
                            todoRow(item)
                        }
                    }
                } header: {
                    HStack {
                        Text("今日待办")
                        Spacer()
                        if !store.pendingEnvelopes.isEmpty {
                            Text(store.stalePendingCount > 0 ? "未同步(\(store.pendingEnvelopes.count))" : "待同步(\(store.pendingEnvelopes.count))")
                                .font(.system(size: 10))
                                .foregroundStyle(store.stalePendingCount > 0 ? Color.red : Color.secondary)
                        }
                    }
                }
            }
            .navigationTitle("今天")
        }
    }

    private func todoRow(_ item: WidgetTodoEntry) -> some View {
        Button {
            store.sendCommand(.completeTodo(item.id), feedbackToast: "已完成 ✓")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.footnote)
                        .lineLimit(2)
                    if let code = item.pickupCode, !code.isEmpty {
                        Text(code)
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.orange)
                    } else if let due = item.dueAt {
                        Text(due, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                store.sendCommand(.snoozeTodo(item.id, 10), feedbackToast: "延后 10 分钟")
            } label: {
                Label("10分", systemImage: "clock")
            }
            .tint(.indigo)

            Button {
                store.sendCommand(.snoozeTomorrow(item.id), feedbackToast: "延后至明早")
            } label: {
                Label("明天", systemImage: "sunrise.fill")
            }
            .tint(.orange)
        }
    }

    private func formatAmount(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "¥%.0f", value)
        }
        return String(format: "¥%.2f", value)
    }
}
