import SwiftData
import SwiftUI

/// 将逾期、今天和近期需要处理的待办集中展示，避免用户在各分类之间来回查找。
struct ReminderCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var todos: [TodoItem]
    @Query private var habits: [PeriodicHabit]
    @Query private var medications: [MedicationPlan]
    @Query private var anniversaries: [AnniversaryItem]
    @Query private var subscriptions: [SubscriptionItem]
    @Query private var expiries: [ItemExpiryItem]
    @Query private var vehicles: [VehicleProfile]

    private var reminders: [TodoItem] {
        let start = Calendar.current.startOfDay(for: .now)
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? .distantFuture
        return todos
            .filter { item in
                guard item.status == .active else { return false }
                let reminderDate = item.reminderOverrideAt ?? item.dueAt
                guard let reminderDate else { return false }
                return reminderDate < horizon
            }
            .sorted {
                switch ($0.reminderOverrideAt ?? $0.dueAt, $1.reminderOverrideAt ?? $1.dueAt) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                default: return false
                }
            }
    }

    private var lifeReminders: [LifeReminder] {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .distantFuture
        var result: [LifeReminder] = []

        for habit in habits where habit.isEnabled && habit.nextDueAt < horizon && habit.nextDueAt > start {
            result.append(.init(id: "habit-\(habit.id)", title: habit.title, date: habit.nextDueAt, detail: "习惯", icon: "repeat", actionTitle: "完成") {
                habit.completeOnce()
                try? context.save()
            })
        }
        for medication in medications where medication.isEnabled {
            for timePoint in medication.dailyTimePoints {
                let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                comps.hour = parts[0]
                comps.minute = parts[1]
                guard let date = Calendar.current.date(from: comps), date >= Calendar.current.startOfDay(for: .now), date < horizon else { continue }
                result.append(.init(id: "med-\(medication.id)-\(timePoint)", title: "服用\(medication.medName)", date: date, detail: medication.dosage, icon: "pills.fill"))
            }
        }
        for anniversary in anniversaries where anniversary.nextAnniversaryDate > start && anniversary.nextAnniversaryDate < horizon {
            result.append(.init(id: "anniversary-\(anniversary.id)", title: anniversary.title, date: anniversary.nextAnniversaryDate, detail: "纪念日", icon: "gift.fill"))
        }
        for subscription in subscriptions where subscription.nextBillingDate > start && subscription.nextBillingDate < horizon {
            result.append(.init(id: "subscription-\(subscription.id)", title: "续费：\(subscription.name)", date: subscription.nextBillingDate, detail: subscription.priceString, icon: "creditcard.and.123"))
        }
        for expiry in expiries where !expiry.isResolved && expiry.expireDate > start && expiry.expireDate < horizon {
            result.append(.init(id: "expiry-\(expiry.id)", title: "临期：\(expiry.title)", date: expiry.expireDate, detail: expiry.category, icon: "hourglass.bottomhalf.filled"))
        }
        for vehicle in vehicles where vehicle.isReminderEnabled && vehicle.nextMaintenanceDate > start && vehicle.nextMaintenanceDate < horizon {
            result.append(.init(id: "vehicle-\(vehicle.id)", title: "车辆保养：\(vehicle.name)", date: vehicle.nextMaintenanceDate, detail: "定期保养", icon: "car.fill"))
        }
        return result.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                if reminders.isEmpty && lifeReminders.isEmpty {
                    ContentUnavailableView("暂无近期提醒", systemImage: "checkmark.circle", description: Text("未来 7 天没有设定时间的待办。"))
                } else {
                    ForEach(reminders) { item in
                        ReminderCenterRow(item: item, onComplete: complete, onSnooze: snooze)
                    }
                }

                if !lifeReminders.isEmpty {
                    Section("生活提醒") {
                        ForEach(lifeReminders) { item in
                            LifeReminderRow(item: item)
                        }
                    }
                }
            }
            .navigationTitle("提醒中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func complete(_ item: TodoItem) {
        item.markAsCompleted(in: context)
        try? context.save()
        Haptic.success()
    }

    private func snooze(_ item: TodoItem) {
        item.reminderOverrideAt = Calendar.current.date(byAdding: .hour, value: 1, to: .now)
        TodoNotificationManager.shared.scheduleNotification(for: item)
        try? context.save()
        Haptic.light()
    }
}

private struct LifeReminder: Identifiable {
    let id: String
    let title: String
    let date: Date
    let detail: String
    let icon: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

private struct LifeReminderRow: View {
    let item: LifeReminder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text("\(dateText(item.date)) · \(item.detail)")
                    .font(.caption)
                    .foregroundStyle(item.date < .now ? .red : .secondary)
            }
            Spacer(minLength: 0)
            if let actionTitle = item.actionTitle, let action = item.action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func dateText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天 \(date.formatted(date: .omitted, time: .shortened))" }
        if date < .now { return "已到期" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ReminderCenterRow: View {
    let item: TodoItem
    let onComplete: (TodoItem) -> Void
    let onSnooze: (TodoItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { onComplete(item) } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成\(item.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayConciseTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let due = item.reminderOverrideAt ?? item.dueAt {
                    Text(dueText(due))
                        .font(.caption)
                        .foregroundStyle(due < .now ? .red : .secondary)
                }
            }
            Spacer(minLength: 0)
            Button("稍后") { onSnooze(item) }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .accessibilityLabel("将\(item.title)推迟一小时")
        }
        .padding(.vertical, 4)
    }

    private func dueText(_ date: Date) -> String {
        if date < .now { return "已逾期 · \(date.formatted(date: .abbreviated, time: .shortened))" }
        if Calendar.current.isDateInToday(date) { return "今天 · \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
