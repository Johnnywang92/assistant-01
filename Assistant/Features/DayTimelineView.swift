import SwiftData
import SwiftUI

// MARK: - 可视化今日时间轴（Visual Day Timeline）
//
// Structured 式竖向时间流：把起床、下班锚点、系统日程、今日定时待办、
// 服药打卡与习惯安排画到同一条时间轴上，并自动标出空闲时段，
// 让用户一眼看出"今天还塞不塞得下一件新事"。
//
// 数据来源：
// - 系统日历日程：CalendarAgendaService（展开时懒加载，避免启动弹权限）
// - 今日定时待办：TodoItem.dueAt（逾期标红）
// - 服药打卡：MedicationPlan.dailyTimePoints
// - 周期习惯：PeriodicHabit.nextDueAt
// - 起床 / 下班锚点：AppStorage 可配置（默认 7:30 / 19:00）

struct DayTimelineView: View {
    let items: [TodoItem]

    @Environment(\.calendar) private var calendar
    @ObservedObject private var calendarService = CalendarAgendaService.shared
    @Query private var habits: [PeriodicHabit]
    @Query private var medications: [MedicationPlan]

    @AppStorage("day_timeline_wake_minutes") private var wakeMinutes: Int = 7 * 60 + 30
    @AppStorage("day_timeline_off_minutes") private var offMinutes: Int = 19 * 60

    @State private var isExpanded = false
    @State private var showTimeSettings = false

    private static let pxPerHour: CGFloat = 64
    private static let minFreeSlotMinutes = 30

    // MARK: - 布局引用缓存（同一渲染内 allEntries/rangeStart/rangeEnd/freeSlots 各只算一次）
    /// TimelineView 每分钟重绘一次，原实现每次绘制都会反复重建并排序全量条目数组
    /// （rangeStart/rangeEnd/画布内两处 filter 各触发一次 allEntries 重算）。
    private final class TimelineLayoutCache {
        var key: Int = -1
        var entries: [DayTimelineView.TimelineEntry]?
        var freeSlots: [DayTimelineView.FreeSlot]?
        var rangeStart: Date?
        var rangeEnd: Date?
    }

    @State private var layoutCache = TimelineLayoutCache()

    /// 内容指纹：日程/待办/习惯/服药/锚点设置 + 归属日 + 分钟粒度。
    /// isOverdue 与空闲时段以“现在”判定，分钟粒度重算与 TimelineView 每分钟重绘节奏一致，
    /// 指纹必须覆盖条目展示依赖的全部字段，否则会留下旧图。
    private var layoutKey: Int {
        var hasher = Hasher()
        let now = Date.now
        hasher.combine(Int(now.timeIntervalSinceReferenceDate / 60))
        hasher.combine(calendar.startOfDay(for: now).timeIntervalSinceReferenceDate)
        hasher.combine(wakeMinutes)
        hasher.combine(offMinutes)
        for event in calendarService.events {
            hasher.combine(event.title)
            hasher.combine(event.startDate.timeIntervalSinceReferenceDate)
            hasher.combine(event.endDate.timeIntervalSinceReferenceDate)
            hasher.combine(event.isAllDay)
        }
        for item in items {
            hasher.combine(item.id.uuidString)
            hasher.combine(item.title)
            hasher.combine(item.dueAt?.timeIntervalSinceReferenceDate ?? -1)
        }
        for habit in habits {
            hasher.combine(habit.id.uuidString)
            hasher.combine(habit.title)
            hasher.combine(habit.isEnabled)
            hasher.combine(habit.nextDueAt.timeIntervalSinceReferenceDate)
        }
        for medication in medications {
            hasher.combine(medication.id.uuidString)
            hasher.combine(medication.medName)
            hasher.combine(medication.isEnabled)
            hasher.combine(medication.dailyTimePoints.joined(separator: ","))
        }
        return hasher.finalize()
    }

    /// 键变化时同时丢弃全部缓存槽；键未变时保留已算好的其他槽
    private func ensureLayoutCurrent(for key: Int) {
        if layoutCache.key != key {
            layoutCache.key = key
            layoutCache.entries = nil
            layoutCache.freeSlots = nil
            layoutCache.rangeStart = nil
            layoutCache.rangeEnd = nil
        }
    }

    private var dayStart: Date { calendar.startOfDay(for: .now) }

    // MARK: - 时间锚点

    private func dateAt(minutes: Int) -> Date {
        calendar.date(byAdding: .minute, value: minutes, to: dayStart) ?? dayStart
    }

    private var wakeDate: Date { dateAt(minutes: wakeMinutes) }
    private var offDate: Date { dateAt(minutes: max(offMinutes, wakeMinutes + 60)) }

    // MARK: - 数据组装

    private var todayEvents: [CalendarAgendaService.AgendaEvent] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return calendarService.events.filter { event in
            guard !event.isAllDay else { return false }
            return event.startDate < dayEnd && event.endDate > dayStart
        }
    }

    private var todayTimedTodos: [TodoItem] {
        items.filter { item in
            guard let due = item.dueAt else { return false }
            return calendar.isDateInToday(due)
        }
    }

    enum EntryKind {
        case calendarEvent, todo, medication, habit, anchor
    }

    struct TimelineEntry: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let start: Date
        /// nil 表示时间点（打卡 / 截止），非 nil 表示持续日程
        let end: Date?
        let kind: EntryKind
        let isOverdue: Bool

        var icon: String {
            switch kind {
            case .calendarEvent: return "calendar"
            case .todo: return "checkmark.circle"
            case .medication: return "pills.fill"
            case .habit: return "repeat"
            case .anchor: return Calendar.current.component(.hour, from: start) < 12 ? "sunrise.fill" : "house.fill"
            }
        }
    }

    private var allEntries: [TimelineEntry] {
        let key = layoutKey
        ensureLayoutCurrent(for: key)
        if let cached = layoutCache.entries {
            return cached
        }
        let result = buildAllEntries()
        layoutCache.entries = result
        return result
    }

    private func buildAllEntries() -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        for event in todayEvents {
            entries.append(TimelineEntry(
                id: "event-\(event.id)",
                title: event.title,
                detail: event.location,
                start: max(event.startDate, dayStart),
                end: min(event.endDate, dayEnd),
                kind: .calendarEvent,
                isOverdue: false
            ))
        }

        for todo in todayTimedTodos {
            guard let due = todo.dueAt else { continue }
            entries.append(TimelineEntry(
                id: "todo-\(todo.id.uuidString)",
                title: todo.displayConciseTitle,
                detail: nil,
                start: due,
                end: nil,
                kind: .todo,
                isOverdue: due < .now
            ))
        }

        for medication in medications where medication.isEnabled {
            for timePoint in medication.dailyTimePoints {
                let parts = timePoint.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                var comps = calendar.dateComponents([.year, .month, .day], from: dayStart)
                comps.hour = parts[0]
                comps.minute = parts[1]
                guard let date = calendar.date(from: comps) else { continue }
                entries.append(TimelineEntry(
                    id: "med-\(medication.id.uuidString)-\(timePoint)",
                    title: L10n.tr("服用\(medication.medName)"),
                    detail: medication.dosage,
                    start: date,
                    end: nil,
                    kind: .medication,
                    isOverdue: date < .now
                ))
            }
        }

        for habit in habits where habit.isEnabled && calendar.isDateInToday(habit.nextDueAt) {
            entries.append(TimelineEntry(
                id: "habit-\(habit.id.uuidString)",
                title: habit.title,
                detail: L10n.tr("习惯"),
                start: habit.nextDueAt,
                end: nil,
                kind: .habit,
                isOverdue: habit.nextDueAt < .now
            ))
        }

        entries.append(TimelineEntry(
            id: "anchor-wake",
            title: L10n.tr("起床"),
            detail: nil,
            start: wakeDate,
            end: nil,
            kind: .anchor,
            isOverdue: false
        ))
        entries.append(TimelineEntry(
            id: "anchor-off",
            title: L10n.tr("下班"),
            detail: nil,
            start: offDate,
            end: nil,
            kind: .anchor,
            isOverdue: false
        ))

        return entries.sorted { $0.start < $1.start }
    }

    // MARK: - 空闲时段计算
    // 空闲 = 起床 → 下班之间，剔除系统日程占用后剩下的 >= 30 分钟的空档。
    // 定时待办 / 打卡按"时间点"处理，不整段占用时间。

    struct FreeSlot: Identifiable {
        let id: String
        let start: Date
        let end: Date

        var durationMinutes: Int {
            max(0, Int(end.timeIntervalSince(start) / 60))
        }
    }

    private var freeSlots: [FreeSlot] {
        let key = layoutKey
        ensureLayoutCurrent(for: key)
        if let cached = layoutCache.freeSlots {
            return cached
        }
        let result = buildFreeSlots()
        layoutCache.freeSlots = result
        return result
    }

    private func buildFreeSlots() -> [FreeSlot] {
        let anchorEnd = max(offDate, wakeDate.addingTimeInterval(3600))
        var cursor = wakeDate
        var raw: [(Date, Date)] = []

        let busy = todayEvents
            .map { (max($0.startDate, wakeDate), min($0.endDate, anchorEnd)) }
            .filter { $1 > $0 }
            .sorted { $0.0 < $1.0 }

        for (busyStart, busyEnd) in busy {
            if busyStart > cursor { raw.append((cursor, busyStart)) }
            cursor = max(cursor, busyEnd)
        }
        if cursor < anchorEnd { raw.append((cursor, anchorEnd)) }

        // 只保留还有剩余时间的空档，起点对齐到"现在"之后
        let now = Date.now
        return raw.compactMap { start, end in
            let clampedStart = max(start, now)
            guard end.timeIntervalSince(clampedStart) / 60 >= Double(Self.minFreeSlotMinutes) else { return nil }
            return FreeSlot(
                id: "free-\(Int(start.timeIntervalSince1970))",
                start: clampedStart,
                end: end
            )
        }
    }

    private var remainingFreeMinutes: Int {
        freeSlots.reduce(0) { $0 + $1.durationMinutes }
    }

    // MARK: - 时间轴范围

    private var rangeStart: Date {
        let key = layoutKey
        ensureLayoutCurrent(for: key)
        if let cached = layoutCache.rangeStart {
            return cached
        }
        let earliestEntry = allEntries.map(\.start).min() ?? wakeDate
        let earliest = min(earliestEntry, wakeDate)
        let earliestMinutes = Int(earliest.timeIntervalSince(dayStart) / 60)
        let result = dateAt(minutes: max(0, min(earliestMinutes, wakeMinutes)))
        layoutCache.rangeStart = result
        return result
    }

    private var rangeEnd: Date {
        let key = layoutKey
        ensureLayoutCurrent(for: key)
        if let cached = layoutCache.rangeEnd {
            return cached
        }
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var latest = max(offDate, wakeDate.addingTimeInterval(3600))
        for entry in allEntries {
            if let end = entry.end { latest = max(latest, end) }
            latest = max(latest, entry.start)
        }
        latest = latest.addingTimeInterval(30 * 60)
        let result = min(latest, dayEnd)
        layoutCache.rangeEnd = result
        return result
    }

    // MARK: - 文案

    private func durationText(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return L10n.tr("\(m) 分钟") }
        if m == 0 { return L10n.tr("\(h) 小时") }
        return L10n.tr("\(h) 小时 \(m) 分钟")
    }

    private func freeSlotLabel(_ slot: FreeSlot) -> String {
        let text = durationText(minutes: slot.durationMinutes)
        return L10n.tr("空闲") + " \(text)"
    }

    // MARK: - Body

    var body: some View {
        if isExpanded {
            expandedCard
        } else {
            collapsedCard
        }
    }

    private var collapsedCard: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded = true
            }
            Haptic.light()
            Task { await calendarService.loadTodayEvents() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "timeline.calendar")
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("今日时间轴"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(collapsedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityLabel("展开今日时间轴")
    }

    private var collapsedSummary: String {
        let eventCount = todayEvents.count
        let slotCount = freeSlots.count
        if eventCount == 0 && slotCount == 0 {
            return L10n.tr("今天没有日程，时间完全由你安排")
        }
        if eventCount == 0 {
            return L10n.tr("今天没有日程 · 剩余空闲") + " " + durationText(minutes: remainingFreeMinutes)
        }
        let slotText = slotCount > 0
            ? L10n.tr(" · 剩余空闲") + " " + durationText(minutes: remainingFreeMinutes)
            : L10n.tr(" · 空闲时段已被日程占满")
        return L10n.tr("今天 \(eventCount) 个日程") + slotText
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("今日时间轴"), systemImage: "timeline.calendar")
                    .font(.headline)
                Spacer()
                Button {
                    showTimeSettings = true
                } label: {
                    Image(systemName: "alarm")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置起床与下班时间")
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded = false }
                    Haptic.light()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起时间轴")
            }

            if calendarService.result == .denied {
                Text(L10n.tr("日历权限未开启，时间轴暂不包含系统日程。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            timelineCanvas

            if freeSlots.isEmpty {
                Text(L10n.tr("今天已没有可支配的空闲时段了"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                freeSlotSummaryRow
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .sheet(isPresented: $showTimeSettings) {
            DayTimelineSettingsSheet(wakeMinutes: $wakeMinutes, offMinutes: $offMinutes)
                .presentationDetents([.medium])
        }
    }

    private var freeSlotSummaryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(freeSlots) { slot in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(slot.start.formatted(date: .omitted, time: .shortened)) – \(slot.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.medium).monospacedDigit())
                        Text(freeSlotLabel(slot))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.green.opacity(0.14))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.green.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - 时间轴画布

    private var timelineCanvas: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timelineContext in
            let now = timelineContext.date
            let totalMinutes = max(60, Int(rangeEnd.timeIntervalSince(rangeStart) / 60))
            let height = CGFloat(totalMinutes) / 60 * Self.pxPerHour

            ScrollView(.vertical, showsIndicators: false) {
                GeometryReader { geo in
                    let width = geo.size.width
                    let minutesToY: (Date) -> CGFloat = { date in
                        CGFloat(date.timeIntervalSince(rangeStart) / 60) / 60 * Self.pxPerHour
                    }

                    ZStack(alignment: .topLeading) {
                        // 小时网格线
                        ForEach(Array(hourTicks.enumerated()), id: \.offset) { _, tick in
                            let y = minutesToY(tick)
                            HStack(spacing: 6) {
                                Text(tick.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 0.5)
                            }
                            .offset(y: y - 8)
                        }

                        // 日程块
                        ForEach(allEntries.filter { $0.end != nil }) { entry in
                            let y = minutesToY(entry.start)
                            let blockHeight = max(26, minutesToY(entry.end ?? entry.start) - y - 2)
                            eventBlock(entry, height: blockHeight)
                                .offset(x: 56, y: y)
                                .frame(width: max(0, width - 64), alignment: .leading)
                        }

                        // 时间点标记（待办 / 打卡 / 习惯 / 起床下班）
                        ForEach(allEntries.filter { $0.end == nil }) { entry in
                            let y = minutesToY(entry.start)
                            pointMarker(entry)
                                .offset(x: 56, y: y - 12)
                                .frame(width: max(0, width - 64), alignment: .trailing)
                        }

                        // 空闲时段虚线框
                        ForEach(freeSlots) { slot in
                            let y = minutesToY(slot.start)
                            let slotHeight = max(24, minutesToY(slot.end) - y - 2)
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.green.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .background(Color.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    Text(freeSlotLabel(slot))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.green)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .padding(.horizontal, 6)
                                }
                                .frame(height: slotHeight)
                                .frame(width: max(0, width - 64), alignment: .leading)
                                .offset(x: 56, y: y)
                                .allowsHitTesting(false)
                        }

                        // 当前时间指示线
                        if now >= rangeStart && now <= rangeEnd {
                            let y = minutesToY(now)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 7, height: 7)
                                Rectangle()
                                    .fill(Color.red.opacity(0.75))
                                    .frame(height: 1.2)
                            }
                            .offset(y: y)
                            .frame(width: max(0, width - 4), alignment: .leading)
                            .accessibilityLabel("当前时间")
                        }
                    }
                }
                .frame(height: height)
                // 顶部留白：起点锚定的标记胶囊（y-12）与刻度文字（y-8）会越过内容顶边，
                // 不留白会被 ScrollView 裁切，表现为头部闹钟图标下方字符被遮一半
                .padding(.vertical, 16)
            }
            .frame(maxHeight: 420)
        }
    }

    private var hourTicks: [Date] {
        var ticks: [Date] = []
        var cursor = rangeStart
        // 对齐到整点或半点
        let minuteComponent = calendar.component(.minute, from: cursor)
        if minuteComponent != 0 {
            cursor = calendar.date(byAdding: .minute, value: 60 - minuteComponent, to: cursor) ?? cursor
        }
        while cursor <= rangeEnd {
            ticks.append(cursor)
            cursor = calendar.date(byAdding: .minute, value: 60, to: cursor) ?? cursor
        }
        return ticks
    }

    private func kindColor(_ kind: EntryKind, isOverdue: Bool) -> Color {
        if isOverdue { return .red }
        switch kind {
        case .calendarEvent: return .indigo
        case .todo: return .blue
        case .medication: return .green
        case .habit: return .orange
        case .anchor: return .gray
        }
    }

    private func eventBlock(_ entry: TimelineEntry, height: CGFloat) -> some View {
        let color = kindColor(entry.kind, isOverdue: entry.isOverdue)
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if height > 40, let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 0.8)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private func pointMarker(_ entry: TimelineEntry) -> some View {
        let color = kindColor(entry.kind, isOverdue: entry.isOverdue)
        return HStack(spacing: 5) {
            Image(systemName: entry.icon)
                .font(.caption2)
            Text(entry.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.8)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 起床 / 下班设置

private struct DayTimelineSettingsSheet: View {
    @Binding var wakeMinutes: Int
    @Binding var offMinutes: Int
    @Environment(\.dismiss) private var dismiss
    @State private var wakeDate = Date()
    @State private var offDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(L10n.tr("起床时间"), selection: $wakeDate, displayedComponents: .hourAndMinute)
                    DatePicker(L10n.tr("下班时间"), selection: $offDate, displayedComponents: .hourAndMinute)
                } footer: {
                    Text(L10n.tr("这两个锚点决定了时间轴的起点、终点和空闲时段的计算范围。"))
                }
            }
            .navigationTitle(L10n.tr("时间轴锚点"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成")) {
                        let calendar = Calendar.current
                        wakeMinutes = calendar.component(.hour, from: wakeDate) * 60 + calendar.component(.minute, from: wakeDate)
                        offMinutes = calendar.component(.hour, from: offDate) * 60 + calendar.component(.minute, from: offDate)
                        Haptic.success()
                        dismiss()
                    }
                }
            }
            .onAppear {
                let calendar = Calendar.current
                var comps = calendar.dateComponents([.year, .month, .day], from: .now)
                comps.hour = wakeMinutes / 60
                comps.minute = wakeMinutes % 60
                wakeDate = calendar.date(from: comps) ?? .now
                comps.hour = offMinutes / 60
                comps.minute = offMinutes % 60
                offDate = calendar.date(from: comps) ?? .now
            }
        }
    }
}
