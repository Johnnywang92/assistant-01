import AssistantCore
import SwiftUI
import WidgetKit

// MARK: - 用药与打卡小组件（中号 4×2 / 小号 / 锁屏）
//
// 「今天该吃药了吗」「今天还有几个运动没打卡」是每天要问的问题。
// 桌面组件比开 App 快得多，尤其在锁屏 glance 上——抬手就看一眼。
//
// 数据全部来自主 App 写入的快照，扩展**只渲染不计算**：
// - 逐条状态（是否已服 / 是否待打卡）由主 App 用 Core 的
//   `MedicationHabitDoseResolver` 算好；
// - 汇总数字（待服 N 项 / 待打卡 M 项）由主 App 写入 `medicationSummary` /
//   `habitSummary`——**扩展不能自己 sum**，因为快照里的条目是 `prefix(6)`
//   截断的，自己聚合会把「10 个药服了 6 个」显示成「全部服完」。
//
// 打卡复用既有的 `WidgetCommand.markMedicationTaken` / `completeHabit`，
// 落库链路与手表端完全一致。

struct MedicationHabitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MedicationHabitWidget", provider: SnapshotTimelineProvider()) { entry in
            MedicationHabitWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("用药与打卡")
        .description("今日待服药品与待打卡运动，一眼看清还差什么")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct MedicationHabitWidgetView: View {
    let snapshot: WidgetSnapshot

    /// 待服的药品（主 App 已排好序：未服优先）
    private var pendingMedications: [WatchMedicationEntry] {
        snapshot.medications.filter { !$0.isTakenToday }
    }

    /// 待打卡的习惯
    private var dueHabits: [WatchHabitEntry] {
        snapshot.habits.filter(\.isDueToday)
    }

    private var hasContent: Bool {
        !snapshot.medications.isEmpty || !snapshot.habits.isEmpty
    }

    var body: some View {
        Group {
            if hasContent {
                content
            } else {
                emptyState
            }
        }
        .widgetContainerBackground()
        .widgetURL(URL(string: "assistant://medication"))
        .modifier(MedicationHabitAccessoryModifier(
            medicationSummary: snapshot.medicationSummary,
            habitSummary: snapshot.habitSummary,
            nextMedication: pendingMedications.first,
            dueHabitCount: dueHabits.count
        ))
    }

    // MARK: 中号（4×2）

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "pills.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetTheme.primary)
                Text("今日用药")
                    .font(.caption2.bold())
                    .foregroundStyle(WidgetTheme.secondaryText)
                Spacer(minLength: 0)
                if let summary = snapshot.medicationSummary {
                    Text(summary.isAllSatisfied ? "已服完 ✓" : "待服 \(summary.pendingDoseCount) 次")
                        .font(.caption2.bold())
                        .foregroundStyle(summary.isAllSatisfied ? WidgetTheme.success : WidgetTheme.primary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 3)

            if pendingMedications.isEmpty {
                // 「已服完」必须看**全量汇总**，不能看截断后的列表。
                //
                // 快照里的 `medications` 是 `prefix(6)`：用户有 10 个药时，
                // 前 6 个都服完了、第 7 个还没吃 → 列表为空 → 若据此判「已服完」
                // 就是**谎报** → 用户漏服。
                let summary = snapshot.medicationSummary
                if summary?.isAllSatisfied == true || (summary == nil && pendingMedications.isEmpty) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(WidgetTheme.success)
                        Text("今日用药已服完")
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetTheme.text)
                        Spacer(minLength: 0)
                    }
                } else {
                    // 还有药没吃，但不在展示的前 6 条里 → 明说，别让用户以为全吃完了
                    HStack(spacing: 4) {
                        Image(systemName: "pills.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(WidgetTheme.primary)
                        Text("还有 \(summary?.pendingPlanCount ?? 0) 种药待服")
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetTheme.text)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                ForEach(pendingMedications.prefix(3)) { med in
                    MedicationWidgetRow(entry: med)
                }
                // 列表被截断时明说总数，避免用户以为只有这几条
                if pendingMedications.count > 3 {
                    Text("还有 \(pendingMedications.count - 3) 种")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetTheme.tertiaryText)
                }
            }

            // 打卡区
            //
            // 「待打卡 N」用**全量汇总**（summary.dueCount），不用截断后的
            // `dueHabits.count` —— 后者最多 6，会少报。
            let dueCount = snapshot.habitSummary?.dueCount ?? dueHabits.count
            if !dueHabits.isEmpty {
                Divider().opacity(0.35).padding(.vertical, 3)
                HStack(spacing: 4) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetTheme.warningText)
                    Text("待打卡 \(dueCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(WidgetTheme.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)

                ForEach(dueHabits.prefix(2)) { habit in
                    HabitWidgetRow(entry: habit)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "pills")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("还没有用药计划")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("打开 App 后自动同步")
                .font(.caption2)
                .foregroundStyle(WidgetTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单条药品：点药丸图标直接打卡。
struct MedicationWidgetRow: View {
    let entry: WatchMedicationEntry

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: MarkMedicationTakenIntent(
                planID: entry.id.uuidString,
                todoID: entry.activeTodoID?.uuidString
            )) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(WidgetTheme.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("标记已服用：\(entry.medName)")

            Text(entry.medName)
                .font(.system(size: 12))
                .foregroundStyle(WidgetTheme.text)
                .lineLimit(1)

            if !entry.dosage.isEmpty {
                Text(entry.dosage)
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // 右侧时刻：**漏服优先**显示。
            // 只显示「下一顿 13:00」会让用户以为 08:00 那顿不用管 → 默默漏服。
            if let missed = entry.missedSlotText {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                    Text("漏 \(missed)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(WidgetTheme.warningText)
            } else if let next = entry.nextDueText {
                Text(next)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetTheme.primary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 20)
    }
}

/// 单条习惯：点圆圈直接打卡。
struct HabitWidgetRow: View {
    let entry: WatchHabitEntry

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: CompleteHabitIntent(habitID: entry.id.uuidString)) {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(WidgetTheme.warningText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成打卡：\(entry.title)")

            Text(entry.title)
                .font(.system(size: 12))
                .foregroundStyle(WidgetTheme.text)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let next = entry.nextDueText {
                Text(next)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(WidgetTheme.tertiaryText)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 20)
    }
}

// MARK: - 锁屏 accessory 家族

struct MedicationHabitAccessoryModifier: ViewModifier {
    let medicationSummary: WidgetMedicationSummary?
    let habitSummary: WidgetHabitSummary?
    let nextMedication: WatchMedicationEntry?
    let dueHabitCount: Int

    @Environment(\.widgetFamily) private var family

    @ViewBuilder
    func body(content: Content) -> some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            content
        }
    }

    /// 圆形：待服次数（0 时显示对勾）。
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let summary = medicationSummary {
                if summary.isAllSatisfied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                } else {
                    VStack(spacing: 0) {
                        Text("\(summary.pendingDoseCount)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("待服")
                            .font(.system(size: 8))
                    }
                }
            } else {
                Image(systemName: "pills")
                    .font(.system(size: 14))
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary = medicationSummary {
                if summary.isAllSatisfied {
                    Text("用药已服完 ✓")
                        .font(.headline)
                } else {
                    Text("待服 \(summary.pendingDoseCount) 次")
                        .font(.headline)
                }
            } else {
                Text("今日用药")
                    .font(.headline)
            }

            if let next = nextMedication {
                Text(next.medName)
                    .font(.caption)
                    .lineLimit(1)
            }

            if dueHabitCount > 0 {
                Text("待打卡 \(dueHabitCount) 项")
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    private var inline: some View {
        if let summary = medicationSummary {
            if summary.isAllSatisfied {
                Text("用药已服完")
            } else {
                Text("待服 \(summary.pendingDoseCount) 次 · 待打卡 \(dueHabitCount)")
            }
        } else {
            Text("待打卡 \(dueHabitCount) 项")
        }
    }
}
