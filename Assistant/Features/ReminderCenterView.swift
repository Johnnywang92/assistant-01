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
    @State private var actionRevision = 0

    private var reminders: [TodoItem] {
        let start = Calendar.current.startOfDay(for: .now)
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? .distantFuture
        let filtered = todos.filter { item in
            guard item.status == .active else { return false }
            let reminderDate = item.reminderOverrideAt ?? item.dueAt
            guard let reminderDate else { return false }
            return reminderDate < horizon
        }
        let scored = filtered.map { (item: $0, score: TodoPriority.score(for: $0)) }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            switch ($0.item.reminderOverrideAt ?? $0.item.dueAt, $1.item.reminderOverrideAt ?? $1.item.dueAt) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            default: return false
            }
        }.map(\.item)
    }

    private var lifeReminders: [LifeReminder] {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .distantFuture
        var result: [LifeReminder] = []

        for habit in habits where habit.isEnabled && habit.nextDueAt < horizon && habit.nextDueAt > start {
            result.append(makeLifeReminder(kind: .habit, sourceID: habit.id, date: habit.nextDueAt, title: habit.title, detail: "习惯", icon: "repeat"))
        }
        for medication in medications where medication.isEnabled {
            for timePoint in medication.dailyTimePoints {
                let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                comps.hour = parts[0]
                comps.minute = parts[1]
                guard let date = Calendar.current.date(from: comps), date >= Calendar.current.startOfDay(for: .now), date < horizon else { continue }
                    result.append(makeLifeReminder(kind: .medication, sourceID: medication.id, date: date, title: "服用\(medication.medName)", detail: medication.dosage, icon: "pills.fill"))
            }
        }
        for anniversary in anniversaries where anniversary.nextAnniversaryDate > start && anniversary.nextAnniversaryDate < horizon {
            result.append(makeLifeReminder(kind: .anniversary, sourceID: anniversary.id, date: anniversary.nextAnniversaryDate, title: anniversary.title, detail: "纪念日", icon: "gift.fill"))
        }
        for subscription in subscriptions where subscription.nextBillingDate > start && subscription.nextBillingDate < horizon {
            result.append(makeLifeReminder(kind: .subscription, sourceID: subscription.id, date: subscription.nextBillingDate, title: "续费：\(subscription.name)", detail: subscription.priceString, icon: "creditcard.and.123"))
        }
        for expiry in expiries where !expiry.isResolved && expiry.expireDate > start && expiry.expireDate < horizon {
            result.append(makeLifeReminder(kind: .expiry, sourceID: expiry.id, date: expiry.expireDate, title: "临期：\(expiry.title)", detail: expiry.category, icon: "hourglass.bottomhalf.filled"))
        }
        for vehicle in vehicles where vehicle.isReminderEnabled && vehicle.nextMaintenanceDate > start && vehicle.nextMaintenanceDate < horizon {
            result.append(makeLifeReminder(kind: .vehicle, sourceID: vehicle.id, date: vehicle.nextMaintenanceDate, title: "车辆保养：\(vehicle.name)", detail: "定期保养", icon: "car.fill"))
        }
        return result.filter { !$0.isCompleted }.sorted { $0.effectiveDate < $1.effectiveDate }
    }

    private func makeLifeReminder(kind: LifeReminderKind, sourceID: UUID, date: Date, title: String, detail: String, icon: String) -> LifeReminder {
        let action = LifeReminderActionStore.action(kind: kind, sourceID: sourceID, occurrenceDate: date, in: context)
        return LifeReminder(kind: kind, sourceID: sourceID, occurrenceDate: date, id: "\(kind.rawValue)-\(sourceID.uuidString)-\(date.timeIntervalSince1970)", title: title, date: date, detail: detail, icon: icon, snoozedUntil: action?.snoozedUntil, isCompleted: action?.isCompleted ?? false, onComplete: {
            if kind == .habit, let habit = habits.first(where: { $0.id == sourceID }) { habit.completeOnce() }
            LifeReminderActionStore.complete(kind: kind, sourceID: sourceID, occurrenceDate: date, in: context)
            actionRevision += 1
            Haptic.success()
        }, onSnooze: {
            LifeReminderActionStore.snooze(kind: kind, sourceID: sourceID, occurrenceDate: date, in: context)
            actionRevision += 1
            Haptic.light()
        })
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

    private func snooze(_ item: TodoItem, interval: TimeInterval) {
        item.reminderOverrideAt = Date.now.addingTimeInterval(interval)
        TodoNotificationManager.shared.scheduleNotification(for: item)
        try? context.save()
        Haptic.light()
    }
}

private struct LifeReminder: Identifiable {
    let kind: LifeReminderKind
    let sourceID: UUID
    let occurrenceDate: Date
    let id: String
    let title: String
    let date: Date
    let detail: String
    let icon: String
    let snoozedUntil: Date?
    let isCompleted: Bool
    let onComplete: () -> Void
    let onSnooze: () -> Void

    var effectiveDate: Date { snoozedUntil ?? date }
}

private struct LifeReminderRow: View {
    let item: LifeReminder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr(item.title)).font(.subheadline.weight(.medium)).lineLimit(2)
                Text("\(dateText(item.effectiveDate)) · \(item.detail)")
                    .font(.caption)
                    .foregroundStyle(item.date < .now ? .red : .secondary)
            }
            Spacer(minLength: 0)
            Button("完成", action: item.onComplete)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
            Button("稍后", action: item.onSnooze)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
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
    let onSnooze: (TodoItem, TimeInterval) -> Void

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
            Menu {
                Button("10 分钟后") { onSnooze(item, 10 * 60) }
                Button("1 小时后") { onSnooze(item, 60 * 60) }
                Button("明早 9 点") {
                    var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                    components.day = (components.day ?? 0) + 1
                    components.hour = 9
                    components.minute = 0
                    if let date = Calendar.current.date(from: components) {
                        onSnooze(item, date.timeIntervalSinceNow)
                    }
                }
            } label: {
                Text("稍后")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("推迟\(item.title)的提醒")
        }
        .padding(.vertical, 4)
    }

    private func dueText(_ date: Date) -> String {
        if date < .now { return "已逾期 · \(date.formatted(date: .abbreviated, time: .shortened))" }
        if Calendar.current.isDateInToday(date) { return "今天 · \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
