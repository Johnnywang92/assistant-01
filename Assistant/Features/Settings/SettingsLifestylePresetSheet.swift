import SwiftUI
import AssistantCore

/// 身份徽标图标。批 1 下沉枚举时这个成员因无调用点被删掉，差异清单的页头是它第一个真实消费者。
extension UserLifestyleProfile {
    var personaIcon: String {
        switch self {
        case .officeWorker: return "briefcase.fill"
        case .flexible: return "laptopcomputer"
        case .student: return "graduationcap.fill"
        }
    }
}

/// 预设字段的 app 侧展示与落笔。
/// Core 的 `LifestyleProfilePreset` 只给「键名 → 带类型的值」，本地化行名与落笔副作用都在这里。
/// 写值本身不够：睡前与早间天气两组改完必须让各自的 scheduler 重排，
/// 否则用户看到的只是数字变了、今晚的提醒时刻没变。
extension LifestylePresetField {

    // 未写过的键按各自视图的 @AppStorage 默认值呈现，否则「现状」会显示成 0 或空串。
    // 下面两个常量镜像 DayTimelineView 的默认锚点；那里改了默认值这里要跟着改
    // （时间轴锚点没有对外 getter，只有视图内的 @AppStorage）。
    private static let defaultWakeMinutes = 7 * 60 + 30
    private static let defaultOffMinutes = 19 * 60

    var presetTitle: String {
        switch self {
        case .dayTimelineWake: return "时间轴起床锚点"
        case .dayTimelineOff: return "时间轴收工锚点"
        case .weatherMorningPushTime: return "早间天气推送时间"
        case .sleepWindDownMinutes: return "睡前提醒提前缓冲"
        case .sleepGoalMinutes: return "睡眠目标时长"
        case .spendingRhythmMode: return "今日安心花节奏"
        }
    }

    var presetIcon: String {
        switch self {
        case .dayTimelineWake: return "sunrise.fill"
        case .dayTimelineOff: return "sunset.fill"
        case .weatherMorningPushTime: return "bell.badge.fill"
        case .sleepWindDownMinutes: return "hourglass"
        case .sleepGoalMinutes: return "target"
        case .spendingRhythmMode: return "yensign.circle.fill"
        }
    }

    var presetIconColor: Color {
        switch self {
        case .dayTimelineWake: return .orange
        case .dayTimelineOff: return .indigo
        case .weatherMorningPushTime: return .blue
        case .sleepWindDownMinutes: return .teal
        case .sleepGoalMinutes: return .green
        case .spendingRhythmMode: return .green
        }
    }

    /// 这一行的「为什么」：只讲它影响什么，不替用户判断值该不该采纳。
    var presetPurpose: String {
        switch self {
        case .dayTimelineWake, .dayTimelineOff:
            return "决定今日时间轴的起止与空闲时段计算范围"
        case .weatherMorningPushTime:
            return "早间主动推送天气的时刻，需开启天气预警"
        case .sleepWindDownMinutes:
            return "就寝建议往前多久开始提示收工"
        case .sleepGoalMinutes:
            return "推算建议入睡时刻时倒推的目标睡眠时长"
        case .spendingRhythmMode:
            return "把月预算摊成每日安心花时，工作日与周末的权重分配"
        }
    }

    /// 当前生效值。类型标签必须与 Core 表里的建议值同形，否则读出来的是默认值。
    @MainActor
    var presetCurrentValue: SettingsValue {
        let defaults = UserDefaults.standard
        switch self {
        case .dayTimelineWake:
            return .int((defaults.object(forKey: rawValue) as? Int) ?? Self.defaultWakeMinutes)
        case .dayTimelineOff:
            return .int((defaults.object(forKey: rawValue) as? Int) ?? Self.defaultOffMinutes)
        case .weatherMorningPushTime:
            return .string(WeatherAlertService.shared.morningPushTime)
        case .sleepWindDownMinutes:
            return .int(SleepReminderScheduler.shared.windDownMinutes)
        case .sleepGoalMinutes:
            return .int(SleepReminderScheduler.shared.sleepGoalMinutes)
        case .spendingRhythmMode:
            return .string(defaults.string(forKey: rawValue)
                           ?? SpendingRhythmMode.weekendLeisure.rawValue)
        }
    }

    /// 单个字段的可读文本；值类型与本字段不符时不硬凑。
    func presetText(for value: SettingsValue) -> String {
        switch (self, value) {
        case (.dayTimelineWake, .int(let minutes)), (.dayTimelineOff, .int(let minutes)):
            return String(format: "%02d:%02d", minutes / 60, minutes % 60)
        case (.weatherMorningPushTime, .string(let text)):
            return text
        case (.sleepWindDownMinutes, .int(let minutes)):
            return "提前 \(minutes) 分钟"
        case (.sleepGoalMinutes, .int(let minutes)):
            return Self.sleepGoalText(minutes)
        case (.spendingRhythmMode, .string(let raw)):
            return SpendingRhythmMode(rawValue: raw)?.shortTitle ?? raw
        default:
            return "值类型不符"
        }
    }

    /// 与设置页睡眠目标 Picker 的档位文案逐字对齐
    private static func sleepGoalText(_ minutes: Int) -> String {
        switch minutes {
        case 360: return "6 小时"
        case 390: return "6.5 小时"
        case 420: return "7 小时"
        case 450: return "7.5 小时"
        case 480: return "8 小时"
        default: return String(format: "%g 小时", Double(minutes) / 60)
        }
    }

    /// 只写值、不触发重排（重排由 `LifestylePresetApplier` 在一批写完后统一做一次）。
    /// 值形状与本字段不符时不写并返回 false，让清单如实报「应用了几项」。
    @MainActor
    func writePresetValue(_ value: SettingsValue) -> Bool {
        switch (self, value) {
        case (.dayTimelineWake, .int(let minutes)), (.dayTimelineOff, .int(let minutes)):
            UserDefaults.standard.set(minutes, forKey: rawValue)
            return true
        case (.weatherMorningPushTime, .string(let text)):
            // 走服务自己的 @AppStorage，早间推送的观察者才能即时刷新
            WeatherAlertService.shared.morningPushTime = text
            return true
        case (.sleepWindDownMinutes, .int(let minutes)):
            SleepReminderScheduler.shared.windDownMinutes = minutes
            return true
        case (.sleepGoalMinutes, .int(let minutes)):
            SleepReminderScheduler.shared.sleepGoalMinutes = minutes
            return true
        case (.spendingRhythmMode, .string(let raw)):
            guard SpendingRhythmMode(rawValue: raw) != nil else { return false }
            UserDefaults.standard.set(raw, forKey: rawValue)
            return true
        default:
            return false
        }
    }
}

/// 把勾选的字段落到偏好里，并按改到的键族各做一次重排（两项睡前键只重排一次）。
@MainActor
enum LifestylePresetApplier {

    struct Outcome: Equatable {
        var appliedFields: [LifestylePresetField]
        var rejectedFields: [LifestylePresetField]
    }

    static func apply(_ fields: [LifestylePresetField],
                      for profile: UserLifestyleProfile) async -> Outcome {
        let entries = LifestyleProfilePreset.entries(for: profile)
        var applied: [LifestylePresetField] = []
        var rejected: [LifestylePresetField] = []

        // 按 allCases 顺序写，展示顺序与落笔顺序一致
        for field in LifestylePresetField.allCases where fields.contains(field) {
            guard let value = entries[field.rawValue] else { continue }
            if field.writePresetValue(value) {
                applied.append(field)
            } else {
                rejected.append(field)
            }
        }

        if applied.contains(where: { $0 == .sleepWindDownMinutes || $0 == .sleepGoalMinutes }) {
            await SleepReminderScheduler.shared.syncSleepReminders()
        }
        if applied.contains(.weatherMorningPushTime) {
            await WeatherAlertService.shared.checkAlertsIfNeeded()
        }
        return Outcome(appliedFields: applied, rejectedFields: rejected)
    }
}

/// 身份建议清单：逐项「现状 → 建议」，勾了才写。
/// 这一屏存在的意义就是不静默覆盖用户手工调过的值。
struct LifestylePresetDiffSheet: View {
    let profile: UserLifestyleProfile
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<LifestylePresetField>
    @State private var outcome: LifestylePresetApplier.Outcome?

    private let fields: [LifestylePresetField]

    init(profile: UserLifestyleProfile) {
        self.profile = profile
        let suggested = LifestyleProfilePreset.fields(for: profile)
        self.fields = suggested
        _selected = State(initialValue: Set(suggested))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields, id: \.self) { field in
                        presetRow(field)
                    }
                } header: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: profile.personaIcon, color: .indigo)
                        Text("\(profile.shortTitle)的推荐节奏")
                    }
                } footer: {
                    Text("只应用你勾选的项。每一项之后都能在提醒与报告页、时间轴锚点或安心花面板里单独改回来。")
                }

                if let outcome, !outcome.rejectedFields.isEmpty {
                    Section {
                        Label("有 \(outcome.rejectedFields.count) 项与预设表的值类型不符，已保持现状",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(AppColor.warning)
                    }
                }

                Section {
                    Button(action: applySelection) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(icon: "checkmark.circle.fill", color: .green)
                            Text(buttonTitle)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(outcome != nil || selected.isEmpty)

                    Button("保留身份，这些先不改") {
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .themedScrollContentBackground()
            .themedAppBackground()
            .themedRow()
            .navigationTitle("作息建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var buttonTitle: String {
        if let outcome {
            return "已应用 \(outcome.appliedFields.count) 项"
        }
        return "应用所选 \(selected.count) 项"
    }

    private func presetRow(_ field: LifestylePresetField) -> some View {
        let suggestion = LifestyleProfilePreset.entries(for: profile)[field.rawValue]
        return Toggle(isOn: Binding(
            get: { selected.contains(field) },
            set: { isOn in
                Haptic.selection()
                if isOn { selected.insert(field) } else { selected.remove(field) }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SettingsIconBadge(icon: field.presetIcon,
                                      color: field.presetIconColor,
                                      size: 24,
                                      iconSize: 12)
                    Text(field.presetTitle)
                        .font(.subheadline.weight(.medium))
                }
                HStack(spacing: 6) {
                    Text(field.presetText(for: field.presetCurrentValue))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(suggestion.map { field.presetText(for: $0) } ?? "—")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppColor.primary)
                }
                .font(.footnote)
                Text(field.presetPurpose)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }

    private func applySelection() {
        Haptic.light()
        let chosen = selected
        Task {
            let result = await LifestylePresetApplier.apply(Array(chosen), for: profile)
            outcome = result
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        }
    }
}
