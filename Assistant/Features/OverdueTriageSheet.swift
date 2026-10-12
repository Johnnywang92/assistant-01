import SwiftData
import SwiftUI

// MARK: - 早间逾期清道夫（Overdue Triage）
//
// 满屏红字容易让人产生逃避心理（Things 3 / Sunsama 重点解决的痛点）。
// 每天首次打开待办页时，若存在逾期事项，弹出极简"发牌器"：
// 每张卡只需一个动作——今天做 / 推到本周末 / 改期 / 算了不做，
// 10 秒钟让列表恢复清爽。右滑 = 今天做，左滑 = 推到本周末。

struct OverdueTriageSheet: View {
    /// 逾期事项队列（由调用方筛选后传入）
    let items: [TodoItem]

    @Environment(\.modelContext) private var context
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    @State private var dragOffset: CGFloat = 0
    @State private var showReschedulePicker = false
    @State private var rescheduleDate = Date()
    @State private var processedCount = 0

    private static let swipeThreshold: CGFloat = 110

    private var isFinished: Bool { index >= items.count }

    var body: some View {
        VStack(spacing: 20) {
            if isFinished {
                summaryView
            } else {
                header
                cardStack
                if showReschedulePicker {
                    reschedulePanel
                } else {
                    actionButtons
                    swipeHint
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .interactiveDismissDisabled(!isFinished)
    }

    // MARK: - 顶部进度

    private var header: some View {
        VStack(spacing: 6) {
            Text(L10n.tr("有 \(items.count) 件逾期事项"))
                .font(.title3.weight(.semibold))
            Text(L10n.tr("花 10 秒给它们安排个去处，让列表先清爽下来"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(index), total: Double(items.count))
                .tint(.orange)
                .padding(.horizontal, 30)
                .padding(.top, 4)
        }
    }

    // MARK: - 卡片

    private var currentCard: OverdueCardData? {
        guard index < items.count else { return nil }
        return OverdueCardData(item: items[index])
    }

    private var cardStack: some View {
        ZStack {
            if let card = currentCard {
                // 底层预告下一张卡，营造"发牌"层次感
                if index + 1 < items.count {
                    cardFace(OverdueCardData(item: items[index + 1]))
                        .scaleEffect(0.94)
                        .offset(y: 14)
                        .opacity(0.5)
                        .allowsHitTesting(false)
                }
                cardFace(card)
                    .offset(x: dragOffset)
                    .rotationEffect(.degrees(dragOffset / 18))
                    .gesture(dragGesture)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .id(card.id)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: index)
        .frame(maxHeight: 320)
    }

    private func cardFace(_ card: OverdueCardData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(card.overdueText, systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.red, in: Capsule())
                Spacer()
                Image(systemName: card.icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
            }

            Text(card.title)
                .font(.title2.weight(.semibold))
                .lineLimit(3)

            if let due = card.dueAt {
                Text(L10n.tr("原定") + " " + due.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            // 右滑提示（今天做）
            swipeBadge(text: L10n.tr("今天做"), color: .green, rotation: -12)
                .opacity(dragOffset > 40 ? min(1, dragOffset / 110) : 0)
        }
        .overlay(alignment: .topTrailing) {
            // 左滑提示（推到周末）
            swipeBadge(text: L10n.tr("推到周末"), color: .orange, rotation: 12)
                .opacity(dragOffset < -40 ? min(1, -dragOffset / 110) : 0)
        }
    }

    private func swipeBadge(text: String, color: Color, rotation: Double) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay {
                Capsule().strokeBorder(color, lineWidth: 2)
            }
            .rotationEffect(.degrees(rotation))
            .padding(18)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let width = value.translation.width
                if width > Self.swipeThreshold {
                    apply(.doToday)
                } else if width < -Self.swipeThreshold {
                    apply(.pushToWeekend)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        dragOffset = 0
                    }
                }
            }
    }

    // MARK: - 操作按钮

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                showReschedulePicker = true
                rescheduleDate = nextRescheduleDefault
                Haptic.light()
            } label: {
                Label(L10n.tr("改期到指定时间"), systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            HStack(spacing: 10) {
                triageButton(L10n.tr("今天做"), icon: "checkmark.circle.fill", color: .green) {
                    apply(.doToday)
                }
                triageButton(L10n.tr("推到周末"), icon: "calendar", color: .orange) {
                    apply(.pushToWeekend)
                }
                triageButton(L10n.tr("算了不做"), icon: "xmark.bin.fill", color: .gray) {
                    apply(.giveUp)
                }
            }
        }
    }

    private func triageButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private var swipeHint: some View {
        Text(L10n.tr("右滑 = 今天做 · 左滑 = 推到周末"))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - 改期面板

    private var nextRescheduleDefault: Date {
        calendar.date(byAdding: .hour, value: 2, to: .now) ?? .now
    }

    private var reschedulePanel: some View {
        VStack(spacing: 12) {
            DatePicker(
                L10n.tr("改到什么时候？"),
                selection: $rescheduleDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            HStack(spacing: 10) {
                Button(L10n.tr("返回")) {
                    showReschedulePicker = false
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button {
                    apply(.reschedule(rescheduleDate))
                } label: {
                    Text(L10n.tr("确定改期"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(.horizontal, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - 完成摘要

    private var summaryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(L10n.tr("处理完毕"))
                .font(.title.weight(.semibold))
            Text(L10n.tr("已安排 \(processedCount) 项，列表清爽了。剩下的事，交给今天的时间轴就好。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.tr("开始今天")) {
                dismiss()
                Haptic.light()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(.horizontal, 30)
        .onAppear {
            // 完成后 2.5 秒自动收起，避免多一次点击
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if isFinished { dismiss() }
            }
        }
    }

    // MARK: - 分诊动作

    private enum TriageAction: Equatable {
        case doToday
        case pushToWeekend
        case reschedule(Date)
        case giveUp
    }

    private func apply(_ action: TriageAction) {
        guard index < items.count else { return }
        let item = items[index]

        switch action {
        case .doToday:
            item.dueAt = todayDueDate(for: item)
            item.reminderOverrideAt = nil
            Haptic.success()
        case .pushToWeekend:
            item.dueAt = weekendDate(for: item)
            item.reminderOverrideAt = nil
            Haptic.medium()
        case .reschedule(let date):
            item.dueAt = date
            item.reminderOverrideAt = nil
            Haptic.light()
        case .giveUp:
            if item.isRecurring {
                // 周期性待办不能"不做"，只跳过这一期
                item.dueAt = item.nextRecurringDueDate(from: .now)
                item.reminderOverrideAt = nil
                Haptic.warning()
            } else {
                item.status = .done
                TodoNotificationManager.shared.cancelNotification(for: item.id)
                Haptic.warning()
            }
        }

        // 除"算了"终结流程外，统一重排提醒通知
        if !(action == .giveUp && !item.isRecurring) {
            TodoNotificationManager.shared.scheduleNotification(for: item)
        }

        try? context.save()
        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        processedCount += 1

        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dragOffset = 0
            showReschedulePicker = false
            index += 1
        }
    }

    /// "今天做"：保留原定时刻；若已过点，则顺延到 2 小时后（取整到 5 分钟）
    private func todayDueDate(for item: TodoItem) -> Date {
        guard let due = item.dueAt else { return roundedUpTwoHours() }
        let timeComps = calendar.dateComponents([.hour, .minute], from: due)
        var target = dateTodayKeepingTime(timeComps) ?? .now
        if target <= .now {
            target = roundedUpTwoHours()
        }
        return target
    }

    /// 合并"今天的年月日 + 原定的时分"（DateComponents 无 merging，需手动拼）
    private func dateTodayKeepingTime(_ timeComps: DateComponents) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: .now)
        comps.hour = timeComps.hour
        comps.minute = timeComps.minute
        return calendar.date(from: comps)
    }

    private func roundedUpTwoHours() -> Date {
        let raw = calendar.date(byAdding: .hour, value: 2, to: .now) ?? .now
        let minute = calendar.component(.minute, from: raw)
        let roundBy = 5
        let roundedMinute = ((minute / roundBy) + 1) * roundBy
        if roundedMinute >= 60 {
            return calendar.date(byAdding: .minute, value: 60 - minute, to: raw) ?? raw
        }
        return calendar.date(byAdding: .minute, value: roundedMinute - minute, to: raw) ?? raw
    }

    /// "推到本周末"：下一个周六（今天若是周六则推到下周六），保留原定时刻，默认 10:00
    private func weekendDate(for item: TodoItem) -> Date {
        guard let saturday = calendar.nextDate(
            after: .now,
            matching: DateComponents(weekday: 7),
            matchingPolicy: .nextTime
        ) else { return calendar.date(byAdding: .day, value: 7, to: .now) ?? .now }

        var comps = calendar.dateComponents([.year, .month, .day], from: saturday)
        if let due = item.dueAt {
            comps.hour = calendar.component(.hour, from: due)
            comps.minute = calendar.component(.minute, from: due)
        } else {
            comps.hour = 10
            comps.minute = 0
        }
        return calendar.date(from: comps) ?? saturday
    }
}

// MARK: - 卡片数据

private struct OverdueCardData: Identifiable {
    let item: TodoItem

    var id: UUID { item.id }
    var title: String { item.displayConciseTitle }
    var detail: String? { item.displayConciseDetail }
    var dueAt: Date? { item.dueAt }
    var icon: String { item.type.icon }

    var overdueText: String {
        guard let due = item.dueAt else { return L10n.tr("逾期") }
        let hours = Int(Date.now.timeIntervalSince(due) / 3600)
        if hours < 1 {
            let minutes = max(1, Int(Date.now.timeIntervalSince(due) / 60))
            return L10n.tr("逾期 \(minutes) 分钟")
        }
        if hours < 24 { return L10n.tr("逾期 \(hours) 小时") }
        return L10n.tr("逾期 \(hours / 24) 天")
    }
}
