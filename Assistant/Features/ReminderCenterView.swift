import SwiftData
import SwiftUI

/// 将逾期、今天和近期需要处理的待办集中展示，避免用户在各分类之间来回查找。
struct ReminderCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var todos: [TodoItem]

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

    var body: some View {
        NavigationStack {
            List {
                if reminders.isEmpty {
                    ContentUnavailableView("暂无近期提醒", systemImage: "checkmark.circle", description: Text("未来 7 天没有设定时间的待办。"))
                } else {
                    ForEach(reminders) { item in
                        ReminderCenterRow(item: item, onComplete: complete, onSnooze: snooze)
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
