import AssistantCore
import SwiftData
import SwiftUI

/// 周期性运动计划管理视图。
///
/// 药品相关功能（常备药档案、服药提醒、打卡与饮食时效看板）统一在
/// 「物品收纳 → 药品与健康储备」，本页不再承载第二个药品入口。
struct HabitAndMedicationView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PeriodicHabit.nextDueAt) private var habits: [PeriodicHabit]
    @Query(sort: \WaterIntakeRecord.date, order: .reverse) private var waterRecords: [WaterIntakeRecord]

    @State private var showingAddHabitSheet = false
    /// 轻触运动记录进入编辑
    @State private var editingHabit: PeriodicHabit?
    /// 订阅健康服务：打卡页要显示「健康」侧的步数、饮水与睡眠数值
    @ObservedObject private var health = HealthKitService.shared

    private var todayEffectiveWaterML: Double? {
        let cal = Calendar.current
        let today = waterRecords.filter { cal.isDateInToday($0.date) }
        guard !today.isEmpty else { return nil }
        return today.reduce(0.0) { $0 + $1.effectiveHydrationML }
    }

    var body: some View {
        List {
            // MARK: - Apple 健康参考数值
            if HealthKitService.isAvailable {
                Section {
                    healthReferenceSection
                } header: {
                    Text("今日健康参考")
                } footer: {
                    Text("展示健康指标与饮水。轻触「饮水」可快速打卡并查看咖啡/奶茶水分折算。")
                }
            }

            Section {
                Text("助手会自动根据周期推算下次运动时间，并在到期当天生成待办。轻触任意记录可编辑。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // MARK: - 运动
            Section("运动") {
                if habits.isEmpty {
                    Text("暂无运动计划，点击右上角 + 添加").foregroundStyle(.secondary)
                } else {
                    ForEach(habits) { habit in
                        HabitRow(habit: habit)
                            .contentShape(Rectangle())
                            .onTapGesture { editingHabit = habit }
                    }
                    .onDelete(perform: deleteHabits)
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle("运动")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddHabitSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .iconButton("添加运动计划", hint: "新建周期性运动提醒")
            }
        }
        .sheet(isPresented: $showingAddHabitSheet) { HabitEditorSheet(habit: nil) }
        .sheet(item: $editingHabit) { habit in HabitEditorSheet(habit: habit) }
        .task {
            // 进入打卡页时拉一次健康数据；已有快照则跳过，避免重复查询
            guard HealthKitService.isAvailable, health.snapshot == nil else { return }
            await health.refreshToday()
        }
    }

    private func deleteHabits(at offsets: IndexSet) {
        for idx in offsets { context.delete(habits[idx]) }
        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "删除习惯") }
    }

    // MARK: - 健康参考数值

    /// 打卡页的健康侧数值区块。
    ///
    /// **读不到数据时显示引导入口，而不是显示 0**——
    /// 「今天走了 0 步」与「没读到步数」是两回事，混淆会误导用户判断完成情况。
    @ViewBuilder
    private var healthReferenceSection: some View {
        switch health.snapshot?.readState {
        case .hasData:
            ForEach(referenceMetrics, id: \.kind) { metric in
                if metric.kind == .dietaryWater {
                    NavigationLink {
                        WaterTrackerView()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: metric.kind.iconName)
                                .foregroundStyle(AppColor.info)
                                .frame(width: 22)
                            Text(metric.kind.displayName)
                                .font(.subheadline)
                            Spacer()
                            Text(HealthMetrics.format(metric.value, for: metric.kind))
                                .font(.subheadline.bold())
                                .foregroundStyle(AppColor.text)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(metric.kind.displayName) \(HealthMetrics.format(metric.value, for: metric.kind))")
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: metric.kind.iconName)
                            .foregroundStyle(AppColor.info)
                            .frame(width: 22)
                        Text(metric.kind.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text(HealthMetrics.format(metric.value, for: metric.kind))
                            .font(.subheadline.bold())
                            .foregroundStyle(AppColor.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(metric.kind.displayName) \(HealthMetrics.format(metric.value, for: metric.kind))")
                }
            }

        case .requestedNoData:
            VStack(alignment: .leading, spacing: 6) {
                Text("还没有读到健康数据")
                    .font(.subheadline)
                Text("可能是尚未授权读取，或「健康」里今天还没有记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("连接 Apple 健康") {
                    Task {
                        await health.requestAuthorization()
                        await health.refreshToday()
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }

        case .notDetermined, .none:
            VStack(alignment: .leading, spacing: 6) {
                Text("连接 Apple 健康，用真实数值辅助打卡")
                    .font(.subheadline)
                Text("读取步数、运动能量、饮水与睡眠；只读不写，数据不会离开本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("连接 Apple 健康") {
                    Task {
                        await health.requestAuthorization()
                        await health.refreshToday()
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    /// 打卡页展示的三项参考数值：步数（运动）、饮水（喝水）、睡眠（休息）。
    private struct ReferenceMetric {
        let kind: HealthMetricKind
        let value: Double
    }

    private var referenceMetrics: [ReferenceMetric] {
        guard let snapshot = health.snapshot?.overridingDietaryWater(todayEffectiveWaterML) else { return [] }
        let kinds: [HealthMetricKind] = [.stepCount, .dietaryWater, .sleep]
        return kinds.compactMap { kind in
            guard let value = snapshot.value(for: kind)?.value else { return nil }
            return ReferenceMetric(kind: kind, value: value)
        }
    }
}

struct HabitRow: View {
    @Bindable var habit: PeriodicHabit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(habit.title, systemImage: "figure.run")
                    .font(.headline)
                Spacer()
                Text(L10n.tr(habit.recurrence.rawValue))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }

            HStack {
                Text("每天 \(String(format: "%02d:%02d", habit.preferredHour, habit.preferredMinute))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· 下次提醒: \(habit.nextDueAt, format: .dateTime.month().day().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let scene = habit.triggerHomeKitScene, !scene.isEmpty {
                    Text("· 联动: \(scene)")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 运动计划编辑器（新建 / 编辑）

struct HabitEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let habit: PeriodicHabit?

    @State private var title = ""
    @State private var detail = ""
    @State private var recurrence = RecurrenceInterval.weekly
    @State private var preferredTime = Calendar.current.date(from: DateComponents(hour: 10, minute: 0)) ?? .now
    @State private var homeKitScene = ""

    private let workoutPresets: [(title: String, detail: String, recurrence: RecurrenceInterval)] = [
        ("跑步 30分钟", "有氧慢跑，保持心率稳定", .everyOtherDay),
        ("居家瑜伽/拉伸", "全身柔韧性舒展与核心激活", .daily),
        ("力量训练", "哑铃/自重抗阻训练", .everyOtherDay),
        ("晚间散步/快走", "饭后消食快走 4000 步", .daily),
        ("八段锦/冥想", "舒缓肩颈与呼吸调节", .daily),
        ("游泳", "全身低冲击有氧训练", .weekly),
        ("户外骑行", "有氧耐力骑行", .weekly)
    ]

    private var isEditing: Bool { habit != nil }

    init(habit: PeriodicHabit?) {
        self.habit = habit
        if let h = habit {
            _title = State(initialValue: h.title)
            _detail = State(initialValue: h.detail ?? "")
            _recurrence = State(initialValue: h.recurrence)
            _preferredTime = State(initialValue: Calendar.current.date(from: DateComponents(hour: h.preferredHour, minute: h.preferredMinute)) ?? .now)
            _homeKitScene = State(initialValue: h.triggerHomeKitScene ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("运动内容") {
                    TextField("运动名称（如：跑步、瑜伽、力量训练）", text: $title)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(workoutPresets, id: \.title) { preset in
                                let isSelected = title == preset.title
                                Button {
                                    title = preset.title
                                    if detail.isEmpty { detail = preset.detail }
                                    recurrence = preset.recurrence
                                    Haptic.selection()
                                } label: {
                                    Text(preset.title)
                                        .font(.caption.weight(isSelected ? .semibold : .regular))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(isSelected ? Color.purple.opacity(0.18) : Color(.tertiarySystemFill)))
                                        .overlay(Capsule().stroke(isSelected ? Color.purple : Color.clear, lineWidth: 1))
                                        .foregroundStyle(isSelected ? Color.purple : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    TextField("补充备注（可选）", text: $detail)
                    Picker("重复周期", selection: $recurrence) {
                        ForEach(RecurrenceInterval.allCases, id: \.self) { r in
                            Text(L10n.tr(r.rawValue)).tag(r)
                        }
                    }
                }

                // 时间通过滚轮滑动选择，不再手动输入
                Section("提醒时间") {
                    DatePicker("每天提醒时刻", selection: $preferredTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Section("运动备注（可选）") {
                    TextField("训练地点或器械备注", text: $homeKitScene)
                }
            }
            .navigationTitle(isEditing ? "编辑运动计划" : "新建运动计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "更新" : "保存") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: preferredTime)
        let hour = comps.hour ?? 10
        let minute = comps.minute ?? 0

        if let habit {
            habit.title = title
            habit.detail = detail.isEmpty ? nil : detail
            habit.recurrence = recurrence
            habit.preferredHour = hour
            habit.preferredMinute = minute
            habit.triggerHomeKitScene = homeKitScene.isEmpty ? nil : homeKitScene
            habit.nextDueAt = Self.computeNextDueAt(preferredHour: hour, preferredMinute: minute, from: habit.lastCompletedAt ?? .now, recurrence: recurrence)
        } else {
            let new = PeriodicHabit(
                title: title,
                detail: detail.isEmpty ? nil : detail,
                recurrence: recurrence,
                preferredHour: hour,
                preferredMinute: minute,
                triggerHomeKitScene: homeKitScene.isEmpty ? nil : homeKitScene
            )
            new.nextDueAt = Self.computeNextDueAt(preferredHour: hour, preferredMinute: minute, from: .now, recurrence: recurrence)
            context.insert(new)
        }

        // 保存失败时留在表单里让用户重试，不要 dismiss —— 直接关掉会让用户以为已保存。
        guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "保存习惯") }) else {
            Haptic.error()
            return
        }
        dismiss()
    }

    /// 依据提醒时刻与周期推算下一次到期时间
    private static func computeNextDueAt(preferredHour: Int, preferredMinute: Int, from reference: Date, recurrence: RecurrenceInterval) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: reference)
        comps.hour = preferredHour
        comps.minute = preferredMinute
        guard var candidate = cal.date(from: comps) else { return .now }
        if candidate <= .now {
            candidate = cal.date(byAdding: .day, value: recurrence.dayInterval, to: candidate) ?? candidate
        }
        return candidate
    }
}
