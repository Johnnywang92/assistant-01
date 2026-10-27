import SwiftUI
import WidgetKit

// MARK: - 中号（4×2）：今日高优待办 Top 3 + 取件码，桌面直接打勾

struct TodayTodosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayTodosWidget", provider: SnapshotTimelineProvider()) { entry in
            TodayTodosWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("今日待办")
        .description("高优待办与待取快递速览，点击圆圈直接完成，无需打开 App")
        .supportedFamilies([.systemMedium])
    }
}

struct TodayTodosWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        Group {
            if snapshot.topTodos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("今日待办已清空")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("今日待办", systemImage: "checklist")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !snapshot.parcels.isEmpty {
                            Text("📦 \(snapshot.parcels.count) 件待取")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.bottom, 6)

                    ForEach(Array(snapshot.topTodos.prefix(3).enumerated()), id: \.element.id) { index, todo in
                        if index > 0 { Divider().opacity(0.5) }
                        TodoRow(todo: todo)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://todos"))
    }
}

struct TodoRow: View {
    let todo: WidgetTodoEntry

    private var subtitle: String? {
        if let code = todo.pickupCode, !code.isEmpty {
            return [todo.stationName, "取件码 \(code)"].compactMap { $0 }.joined(separator: " · ")
        }
        return todo.stationName
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: CompleteTodoIntent(todoID: todo.id.uuidString)) {
                Image(systemName: "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成：\(todo.title)")

            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

// MARK: - 小号（2×2）+ 锁屏组件：待取快递码 / 今日支出（长按配置）

struct ParcelGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "ParcelGlanceWidget",
            intent: ParcelGlanceConfigurationIntent.self,
            provider: GlanceProvider()
        ) { entry in
            ParcelGlanceView(entry: entry)
        }
        .configurationDisplayName("小助速览")
        .description("大字显示待取快递码或今日支出，并支持锁屏小组件")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let mode: WidgetGlanceMode
}

struct GlanceProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, snapshot: .empty, mode: .parcels)
    }

    func snapshot(for intent: ParcelGlanceConfigurationIntent, in context: Context) async -> GlanceEntry {
        GlanceEntry(date: .now, snapshot: WidgetSnapshotStore.load(), mode: intent.mode)
    }

    func timeline(for intent: ParcelGlanceConfigurationIntent, in context: Context) async -> Timeline<GlanceEntry> {
        let entry = GlanceEntry(date: .now, snapshot: WidgetSnapshotStore.load(), mode: intent.mode)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct ParcelGlanceView: View {
    let entry: GlanceEntry

    var body: some View {
        switch entry.mode {
        case .parcels:
            parcelContent
        case .spending:
            spendingContent
        case .practice:
            practiceContent
        }
    }

    private var firstParcel: WidgetTodoEntry? {
        entry.snapshot.parcels.first
    }

    @ViewBuilder
    private var parcelContent: some View {
        let count = entry.snapshot.parcels.count
        Group {
            if let first = firstParcel {
                VStack(alignment: .leading, spacing: 4) {
                    Label(count > 1 ? "\(count) 件待取" : "待取快递", systemImage: "shippingbox.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Text(first.pickupCode ?? "")
                        .font(.title2.monospaced().bold())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    if let station = first.stationName {
                        Text(station)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if count > 1 {
                        Text("还有 \(count - 1) 件在列表里")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("暂无待取快递")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://todos"))
        // 锁屏 accessory 家族下替换为紧凑视图
        .modifier(GlanceAccessoryModifier(entry: entry))
    }

    @ViewBuilder
    private var spendingContent: some View {
        let amount = entry.snapshot.todayExpense
        let text = amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", amount)
            : String(format: "%.1f", amount)
        VStack(alignment: .leading, spacing: 4) {
            Label("今日支出", systemImage: "yensign.circle.fill")
                .font(.caption2.bold())
                .foregroundStyle(.teal)
            Spacer(minLength: 0)
            Text("¥\(text)")
                .font(.title.bold())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("放宽心，慢慢花")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://expenses"))
        .modifier(GlanceAccessoryModifier(entry: entry))
    }

    @ViewBuilder
    private var practiceContent: some View {
        if let practice = entry.snapshot.todayPractice {
            VStack(alignment: .leading, spacing: 4) {
                Label("今日练习", systemImage: "figure.walk")
                    .font(.caption2.bold())
                    .foregroundStyle(.purple)
                Spacer(minLength: 0)
                Text(practice.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(practice.stageName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if practice.streakDays > 0 {
                        Label("连续 \(practice.streakDays) 天", systemImage: "flame.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Text("本周 \(practice.minutesThisWeek)/\(practice.weeklyTargetMinutes) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(practice.isPracticedToday ? "今天已打卡 ✓" : "今天还没练")
                    .font(.caption2.bold())
                    .foregroundStyle(practice.isPracticedToday ? Color.green : Color.purple)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetContainerBackground()
            .widgetURL(URL(string: "assistant://skills"))
            .modifier(GlanceAccessoryModifier(entry: entry))
        } else {
            VStack(spacing: 4) {
                Image(systemName: "book")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("暂无学习路径")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetContainerBackground()
            .widgetURL(URL(string: "assistant://skills"))
        }
    }
}

/// 锁屏与表盘 accessory 家族视图（圆形 / 矩形 / 行内）
struct GlanceAccessoryModifier: ViewModifier {
    let entry: GlanceEntry

    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        switch family {
        case .accessoryCircular:
            switch entry.mode {
            case .practice:
                practiceCircular
            case .spending:
                spendingCircular
            case .parcels:
                parcelCircular
            }
        case .accessoryRectangular:
            switch entry.mode {
            case .practice:
                practiceRectangular
            case .spending:
                spendingRectangular
            case .parcels:
                parcelRectangular
            }
        case .accessoryInline:
            switch entry.mode {
            case .practice:
                Text(practiceInlineText)
                    .widgetURL(URL(string: "assistant://skills"))
            case .spending:
                Text(spendingInlineText)
                    .widgetURL(URL(string: "assistant://expenses"))
            case .parcels:
                if let code = entry.snapshot.parcels.first?.pickupCode {
                    Text("📦 待取 · \(code)")
                        .widgetURL(URL(string: "assistant://todos"))
                } else {
                    Text("暂无待取快递")
                }
            }
        default:
            // 桌面尺寸（small/medium…）保留原内容，不套锁屏视图
            content
        }
    }

    // MARK: - 练习模式

    private var practiceCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                Text("\(entry.snapshot.todayPractice?.streakDays ?? 0)")
                    .font(.headline.monospaced())
            }
        }
        .widgetURL(URL(string: "assistant://skills"))
    }

    private var practiceRectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.snapshot.todayPractice?.title ?? "今日练习")
                .font(.headline)
                .lineLimit(1)
            Text(practiceSubtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "assistant://skills"))
    }

    private var practiceSubtitleText: String {
        guard let practice = entry.snapshot.todayPractice else { return "暂无学习路径" }
        if practice.isPracticedToday {
            return "今日已打卡 · 连续 \(practice.streakDays) 天"
        }
        return practice.streakDays > 0 ? "连续 \(practice.streakDays) 天 · 今天待练" : "今天待练"
    }

    private var practiceInlineText: String {
        guard let practice = entry.snapshot.todayPractice else { return "🎯 今日练习" }
        return practice.isPracticedToday ? "🎯 已打卡 · 连续 \(practice.streakDays) 天" : "🎯 今日练习待完成"
    }

    // MARK: - 支出模式

    private var spendingCircular: some View {
        let amount = entry.snapshot.todayExpense
        let formatted = amount >= 1000 ? String(format: "%.1fk", amount / 1000.0) : String(format: "%.0f", amount)
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "yensign")
                    .font(.caption2.bold())
                Text(formatted)
                    .font(.system(.subheadline, design: .rounded).bold())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .widgetURL(URL(string: "assistant://expenses"))
    }

    private var spendingRectangular: some View {
        let amount = entry.snapshot.todayExpense
        let text = amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", amount)
            : String(format: "%.1f", amount)
        return VStack(alignment: .leading, spacing: 2) {
            Label("今日支出", systemImage: "yensign.circle")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text("¥\(text)")
                .font(.headline.monospaced().bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("放宽心，慢慢花")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "assistant://expenses"))
    }

    private var spendingInlineText: String {
        let amount = entry.snapshot.todayExpense
        let text = amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", amount)
            : String(format: "%.1f", amount)
        return "¥\(text) · 今日支出"
    }

    // MARK: - 快递模式

    private var parcelCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption2)
                Text("\(entry.snapshot.parcels.count)")
                    .font(.headline.monospaced())
            }
        }
        .widgetURL(URL(string: "assistant://todos"))
    }

    private var parcelRectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("待取快递 \(entry.snapshot.parcels.count) 件")
                .font(.headline)
            if let code = entry.snapshot.parcels.first?.pickupCode {
                Text(code)
                    .font(.headline.monospaced())
                    .foregroundStyle(.orange)
            } else {
                Text("暂无取件码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "assistant://todos"))
    }
}
