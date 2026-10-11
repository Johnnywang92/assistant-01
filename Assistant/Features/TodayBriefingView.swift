import SwiftData
import SwiftUI

/// 首页的紧凑日常摘要。只展示最重要的几项，完整列表通过展开查看，避免占用首页空间。
struct TodayBriefingView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.calendar) private var calendar
    @ObservedObject private var calendarService = CalendarAgendaService.shared
    @Query private var habits: [PeriodicHabit]
    @Query private var medications: [MedicationPlan]
    @Query private var anniversaries: [AnniversaryItem]
    @Query private var subscriptions: [SubscriptionItem]
    @Query private var expiries: [ItemExpiryItem]
    @Query private var vehicles: [VehicleProfile]

    let items: [TodoItem]
    @State private var isExpanded = false
    @State private var showReminderCenter = false

    private var prioritizedItems: [TodoItem] {
        items
            .filter { $0.status == .active }
            .sorted { lhs, rhs in
                switch (lhs.reminderOverrideAt ?? lhs.dueAt, rhs.reminderOverrideAt ?? rhs.dueAt) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.createdAt > rhs.createdAt
                }
            }
    }

    private var visibleItems: [TodoItem] {
        isExpanded ? Array(prioritizedItems.prefix(12)) : Array(prioritizedItems.prefix(3))
    }

    private var supplementalItems: [SupplementalAgendaItem] {
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              let horizon = calendar.date(byAdding: .day, value: 7, to: start) else { return [] }
        var result: [SupplementalAgendaItem] = []

        for habit in habits where habit.isEnabled && habit.nextDueAt < end {
            result.append(.init(id: "habit-\(habit.id)", title: habit.title, date: habit.nextDueAt, icon: "repeat", detail: "习惯"))
        }
        for medication in medications where medication.isEnabled {
            for timePoint in medication.dailyTimePoints {
                let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: .now)
                comps.hour = parts[0]
                comps.minute = parts[1]
                if let date = calendar.date(from: comps), date >= start, date < end {
                    result.append(.init(id: "med-\(medication.id)-\(timePoint)", title: "服用\(medication.medName)", date: date, icon: "pills.fill", detail: medication.dosage))
                }
            }
        }
        for anniversary in anniversaries where anniversary.nextAnniversaryDate >= start && anniversary.nextAnniversaryDate < horizon {
            result.append(.init(id: "anniversary-\(anniversary.id)", title: anniversary.title, date: anniversary.nextAnniversaryDate, icon: "gift.fill", detail: "纪念日 · 还有\(anniversary.daysUntilNext)天"))
        }
        for subscription in subscriptions {
            let reminderDate = calendar.date(byAdding: .day, value: -subscription.remindDaysBefore, to: subscription.nextBillingDate) ?? subscription.nextBillingDate
            if reminderDate < end && subscription.nextBillingDate >= start && subscription.nextBillingDate < horizon {
                result.append(.init(id: "subscription-\(subscription.id)", title: "续费：\(subscription.name)", date: subscription.nextBillingDate, icon: "creditcard.and.123", detail: subscription.priceString))
            }
        }
        for expiry in expiries where !expiry.isResolved && expiry.expireDate >= start && expiry.expireDate < horizon {
            result.append(.init(id: "expiry-\(expiry.id)", title: "临期：\(expiry.title)", date: expiry.expireDate, icon: "hourglass.bottomhalf.filled", detail: expiry.category))
        }
        for vehicle in vehicles where vehicle.isReminderEnabled {
            if vehicle.nextMaintenanceDate >= start && vehicle.nextMaintenanceDate < horizon {
                result.append(.init(id: "vehicle-maintenance-\(vehicle.id)", title: "车辆保养：\(vehicle.name)", date: vehicle.nextMaintenanceDate, icon: "car.fill", detail: "定期保养"))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private var overdueCount: Int {
        prioritizedItems.filter { item in
            guard let due = item.dueAt else { return false }
            return due < .now
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(summaryTitle, systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button(isExpanded ? "收起" : "今日安排 · \(prioritizedItems.count)") {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    if isExpanded {
                        Task { await calendarService.loadTodayEvents() }
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
            }

            if visibleItems.isEmpty {
                Text("今天没有待处理事项，需要我帮你记一件吗？")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleItems) { item in
                    TodayBriefingRow(item: item) {
                        // 统一走完成流程，周期待办需要自动生成下一期并取消旧通知。
                        item.markAsCompleted(in: context)
                        try? context.save()
                        Haptic.success()
                    }
                }
                if isExpanded && prioritizedItems.count > visibleItems.count {
                    Text("还有 \(prioritizedItems.count - visibleItems.count) 项，已在待办列表中保留")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }

            if isExpanded {
                supplementalSection
                calendarSection
            }

            HStack {
                Button {
                    showReminderCenter = true
                } label: {
                    Label("提醒中心", systemImage: "bell.badge")
                        .font(.caption.weight(.medium))
                }
                Spacer()
                Text(reminderCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今日摘要，\(prioritizedItems.count) 项待处理")
        .sheet(isPresented: $showReminderCenter) {
            ReminderCenterView()
        }
    }

    private var reminderCountText: String {
        let count = prioritizedItems.filter { item in
            guard let due = item.dueAt else { return false }
            return due < (calendar.date(byAdding: .day, value: 7, to: .now) ?? .distantFuture)
        }.count
        return count == 0 ? "未来 7 天暂无定时待办" : "未来 7 天 \(count) 项"
    }

    @ViewBuilder
    private var supplementalSection: some View {
        if !supplementalItems.isEmpty {
            Divider().padding(.vertical, 2)
            Label("生活提醒", systemImage: "bell.badge")
                .font(.subheadline.weight(.medium))
            ForEach(supplementalItems) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        Divider().padding(.vertical, 2)
        HStack {
            Label("今日系统日程", systemImage: "calendar")
                .font(.subheadline.weight(.medium))
            Spacer()
            if calendarService.isLoading {
                ProgressView().controlSize(.small)
            }
        }

        if calendarService.events.isEmpty {
            switch calendarService.result {
            case .denied:
                Text("日历权限未开启，可在系统设置中允许访问。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("暂时无法读取系统日程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text(calendarService.isLoading ? "正在读取今日安排…" : "今天没有系统日程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(calendarService.events) { event in
                HStack(spacing: 10) {
                    Text(event.isAllDay ? "全天" : event.startDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tint)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "calendar.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summaryTitle: String {
        if overdueCount > 0 { return "现在最该做什么 · \(overdueCount) 项逾期" }
        if prioritizedItems.isEmpty { return "今天的安排" }
        return "现在最该做什么"
    }
}

private struct SupplementalAgendaItem: Identifiable {
    let id: String
    let title: String
    let date: Date
    let icon: String
    let detail: String
}

private struct TodayBriefingRow: View {
    let item: TodoItem
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成\(item.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayConciseTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let due = item.reminderOverrideAt ?? item.dueAt {
                    Text(dueLabel(due))
                        .font(.caption)
                        .foregroundStyle(due < .now ? .red : .secondary)
                } else if let detail = item.displayConciseDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: item.type.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func dueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if date < .now { return "已逾期 · \(date.formatted(date: .abbreviated, time: .omitted))" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
