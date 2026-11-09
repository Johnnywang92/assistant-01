import SwiftUI

struct WatchTodayView: View {
    @EnvironmentObject private var store: WatchStore

    private var snap: WidgetSnapshot {
        store.displaySnapshot
    }

    private var pendingMedications: [WatchMedicationEntry] {
        snap.medications.filter { !$0.isTakenToday }
    }

    private var dueHabits: [WatchHabitEntry] {
        snap.habits.filter(\.isDueToday)
    }

    var body: some View {
        NavigationStack {
            List {
                // 顶部状态：今日支出 + 身心指数/连续练习
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
                        if let health = snap.healthSnapshot,
                           let vitality = health.vitalityScore {
                            Button {
                                store.selectedTab = .health
                            } label: {
                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "bolt.heart.fill")
                                            .foregroundStyle(.green)
                                        Text("活力 \(vitality)")
                                    }
                                    .font(.caption2.bold())
                                    if let pleasure = health.pleasureScore {
                                        Text("愉悦 \(pleasure)分")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.cyan)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        } else if let practice = snap.todayPractice {
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

                // 行程护航 / 出门清点快捷入口（若有近期行程或必带未勾项）
                if let travel = snap.travelSnapshot {
                    Section {
                        Button {
                            store.selectedTab = .departure
                        } label: {
                            HStack {
                                Image(systemName: "ticket.fill")
                                    .foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(travel.title)
                                        .font(.footnote.bold())
                                        .lineLimit(1)
                                    Text([travel.gate.map { "检票 \($0)" }, travel.ticketSummary].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
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

                // 今日服药与周期习惯一键打卡
                if !snap.medications.isEmpty || !dueHabits.isEmpty {
                    Section {
                        ForEach(snap.medications) { med in
                            medicationRow(med)
                        }
                        ForEach(dueHabits) { habit in
                            habitRow(habit)
                        }
                    } header: {
                        Text("服药与习惯")
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

    private func medicationRow(_ med: WatchMedicationEntry) -> some View {
        Button {
            guard !med.isTakenToday else { return }
            store.sendCommand(
                .markMedicationTaken(planID: med.id, todoID: med.activeTodoID),
                feedbackToast: "已服药：\(med.medName) 💊"
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: med.isTakenToday ? "checkmark.circle.fill" : "pills.fill")
                    .font(.footnote)
                    .foregroundStyle(med.isTakenToday ? .green : .pink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(med.medName)
                        .font(.footnote.weight(.medium))
                        .strikethrough(med.isTakenToday)
                        .lineLimit(1)
                    Text("\(med.dosage) · \(med.mealRelationText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if med.isTakenToday {
                    Text("已服")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func habitRow(_ habit: WatchHabitEntry) -> some View {
        Button {
            store.sendCommand(
                .completeHabit(habitID: habit.id),
                feedbackToast: "已完成：\(habit.title) ✓"
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(habit.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Text("\(habit.recurrenceText) · 今日到期")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
