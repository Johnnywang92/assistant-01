import AssistantCore
import SwiftData
import SwiftUI

/// 运动与药物保健品管理视图
struct HabitAndMedicationView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PeriodicHabit.nextDueAt) private var habits: [PeriodicHabit]
    @Query private var medPlans: [MedicationPlan]
    @Query(sort: \FoodIntakeRecord.date, order: .reverse) private var foodRecords: [FoodIntakeRecord]

    @State private var showingAddHabitSheet = false
    @State private var showingAddMedSheet = false
    /// 轻触记录行进入编辑：nil 表示新建，非 nil 表示编辑已有记录
    @State private var editingHabit: PeriodicHabit?
    @State private var editingMed: MedicationPlan?
    /// 订阅健康服务：打卡页要显示「健康」侧的步数、饮水与睡眠数值
    @ObservedObject private var health = HealthKitService.shared

    // 今日用餐快照（用于用药时效自适应计算）
    private var todayMeals: [RecentMealSnapshot] {
        let calendar = Calendar.current
        return foodRecords
            .filter { calendar.isDateInToday($0.date) }
            .map { record in
                let name = record.foodName.lowercased()
                let hasCaffeine = name.contains("咖啡") || name.contains("拿铁") || name.contains("美式") ||
                                  name.contains("摩卡") || name.contains("卡布") || name.contains("奶茶") ||
                                  name.contains("红茶") || name.contains("绿茶") || name.contains("乌龙") ||
                                  name.contains("红牛") || name.contains("可乐")
                let hasGrapefruit = name.contains("西柚") || name.contains("葡萄柚")
                let hasDairy = name.contains("牛奶") || name.contains("拿铁") || name.contains("酸奶") ||
                               name.contains("奶酪") || name.contains("芝士") || name.contains("乳")
                let hasAlcohol = name.contains("酒") || name.contains("啤酒") || name.contains("白酒") ||
                                 name.contains("红酒") || name.contains("鸡尾酒")
                return RecentMealSnapshot(
                    id: record.id.uuidString,
                    date: record.date,
                    foodName: record.foodName,
                    calories: record.consumedCalories,
                    hasCaffeine: hasCaffeine,
                    hasGrapefruit: hasGrapefruit,
                    hasDairy: hasDairy,
                    hasAlcohol: hasAlcohol
                )
            }
    }

    /// 当前最紧急或具有行动价值的自适应时效评估
    private var topTimingEvaluation: MedicationTimingEvaluation? {
        let evals = medPlans.filter { $0.isEnabled }.map {
            MedicationFoodTimingAdvisor.evaluate(
                plan: $0.toSnapshot(),
                todayMeals: todayMeals,
                now: .now
            )
        }
        // 冲突警示 > 漏服提醒 > 餐后黄金窗口 > 等餐顺延
        if let conflict = evals.first(where: {
            if case .conflictAlert = $0.status { return true }
            return false
        }) {
            return conflict
        }
        if let missed = evals.first(where: {
            if case .missedDoseWarning = $0.status { return true }
            return false
        }) {
            return missed
        }
        if let prime = evals.first(where: {
            if case .primeTimePostMeal = $0.status { return true }
            return false
        }) {
            return prime
        }
        if let waiting = evals.first(where: {
            if case .waitingForMeal = $0.status { return true }
            return false
        }) {
            return waiting
        }
        return nil
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
                Text("助手会自动根据周期推算下次时间，并在到期当天生成待办。运动与药物、保健品提醒可以长期持续记录。轻触任意记录可编辑。")
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

            // MARK: - 药物与保健品
            Section {
                // 饮食时效自适应智能看板横幅
                if let alertEval = topTimingEvaluation {
                    medicationTimingCard(alertEval)
                }

                if medPlans.isEmpty {
                    Text("暂无药物或保健品提醒计划").foregroundStyle(.secondary)
                } else {
                    ForEach(medPlans) { med in
                        let eval = MedicationFoodTimingAdvisor.evaluate(
                            plan: med.toSnapshot(),
                            todayMeals: todayMeals,
                            now: .now
                        )
                        MedicationRow(med: med, evaluation: eval) {
                            editingMed = med
                        } onMarkTaken: {
                            med.markTaken()
                            try? context.save()
                            Haptic.success()
                        }
                    }
                    .onDelete(perform: deleteMeds)
                }
            } header: {
                HStack {
                    Text("药物与保健品")
                    Spacer()
                    Text("饮食时效自适应联动")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle("运动与药物保健品")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加运动计划", systemImage: "figure.run") { showingAddHabitSheet = true }
                    Button("添加药物或保健品", systemImage: "pills") { showingAddMedSheet = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddHabitSheet) { HabitEditorSheet(habit: nil) }
        .sheet(isPresented: $showingAddMedSheet) { MedicationEditorSheet(med: nil) }
        .sheet(item: $editingHabit) { habit in HabitEditorSheet(habit: habit) }
        .sheet(item: $editingMed) { med in MedicationEditorSheet(med: med) }
        .task {
            // 进入打卡页时拉一次健康数据；已有快照则跳过，避免重复查询
            guard HealthKitService.isAvailable, health.snapshot == nil else { return }
            await health.refreshToday()
        }
    }

    private func deleteHabits(at offsets: IndexSet) {
        for idx in offsets { context.delete(habits[idx]) }
        try? context.save()
    }

    private func deleteMeds(at offsets: IndexSet) {
        for idx in offsets { context.delete(medPlans[idx]) }
        try? context.save()
    }

    // MARK: - 饮食时效自适应智能看板

    @ViewBuilder
    private func medicationTimingCard(_ eval: MedicationTimingEvaluation) -> some View {
        let color: Color = {
            switch eval.status {
            case .conflictAlert: return .red
            case .primeTimePostMeal, .primeTimeBeforeMeal: return .green
            case .waitingForMeal, .missedDoseWarning: return .orange
            case .takenToday, .pendingScheduled: return .blue
            }
        }()

        let icon: String = {
            switch eval.status {
            case .conflictAlert: return "exclamationmark.triangle.fill"
            case .primeTimePostMeal: return "sparkles"
            case .primeTimeBeforeMeal: return "fork.knife.circle.fill"
            case .waitingForMeal: return "clock.arrow.circlepath"
            case .missedDoseWarning: return "exclamationmark.circle.fill"
            case .takenToday: return "checkmark.seal.fill"
            case .pendingScheduled: return "clock.fill"
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.subheadline.bold())
                Text(eval.headline)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Spacer()
                Text(eval.medName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.15)))
                    .foregroundStyle(color)
            }

            Text(eval.actionTip)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.vertical, 2)
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

    /// 打卡页展示的三项参考数值：步数（运动）、饮水（喝水）、睡眠（服药/休息）。
    private struct ReferenceMetric {
        let kind: HealthMetricKind
        let value: Double
    }

    private var referenceMetrics: [ReferenceMetric] {
        guard let snapshot = health.snapshot else { return [] }
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

struct MedicationRow: View {
    @Bindable var med: MedicationPlan
    var evaluation: MedicationTimingEvaluation?
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    var onEdit: () -> Void
    var onMarkTaken: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            // 左侧内容区可点击编辑
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Label(med.medName, systemImage: "pills.fill")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .headline)
                        .foregroundStyle(seniorManager.isSeniorModeEnabled ? .green : .primary)

                    // 饮食时效标签
                    HStack(spacing: 3) {
                        Image(systemName: med.mealRelation.iconName)
                        Text(med.mealRelation.shortTitle)
                    }
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                    .foregroundStyle(.blue)

                    Spacer()

                    Text(med.dosage)
                        .font(seniorManager.isSeniorModeEnabled ? .body.bold() : .subheadline)
                        .foregroundStyle(seniorManager.isHighContrastEnabled ? .primary : .secondary)
                }

                // 计划时点与自适应时效状态提示
                HStack(spacing: 6) {
                    Text("每日: \(med.dailyTimePoints.joined(separator: ", "))")
                        .font(seniorManager.isSeniorModeEnabled ? .subheadline : .caption)
                        .foregroundStyle(.secondary)

                    if let eval = evaluation {
                        Text("· \(eval.headline)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(statusColor(eval.status))
                            .lineLimit(1)
                    }
                }

                if let eval = evaluation, eval.isUrgent {
                    Text(eval.actionTip)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor(eval.status))
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }

            // 打卡完成按钮（防漏服防重复）
            let isTaken = isTakenRecently
            Button {
                if !isTaken {
                    onMarkTaken()
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: isTaken ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isTaken ? .green : .secondary)
                    Text(isTaken ? "已服" : "打卡")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isTaken ? .green : .secondary)
                }
                .frame(width: 40)
            }
            .buttonStyle(.plain)

            if seniorManager.isVoiceBroadcastEnabled {
                Button {
                    var speech = "服药提醒：\(med.medName)，\(med.dosage)。要求：\(med.mealRelation.displayName)。"
                    if let eval = evaluation {
                        speech += "当前建议：\(eval.actionTip)。"
                    }
                    if seniorManager.isSpeaking && seniorManager.currentSpeakingId == med.id.uuidString {
                        seniorManager.stopSpeaking()
                    } else {
                        seniorManager.speakSenior(text: speech, id: med.id.uuidString)
                        Haptic.light()
                    }
                } label: {
                    let isCurrentSpeaking = seniorManager.isSpeaking && seniorManager.currentSpeakingId == med.id.uuidString
                    Image(systemName: isCurrentSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .caption)
                        .foregroundStyle(isCurrentSpeaking ? Color.orange : Color.secondary.opacity(0.8))
                        .frame(width: seniorManager.isSeniorModeEnabled ? 38 : 28, height: seniorManager.isSeniorModeEnabled ? 38 : 28)
                        .background(
                            Circle().fill(isCurrentSpeaking ? Color.orange.opacity(0.2) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
    }

    private var isTakenRecently: Bool {
        guard let last = med.lastTakenAt else { return false }
        return Calendar.current.isDateInToday(last) && Date().timeIntervalSince(last) < 4 * 3600
    }

    private func statusColor(_ status: MedicationTimingStatus) -> Color {
        switch status {
        case .primeTimePostMeal, .primeTimeBeforeMeal: return .green
        case .waitingForMeal, .missedDoseWarning: return .orange
        case .conflictAlert: return .red
        case .takenToday, .pendingScheduled: return .secondary
        }
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

        try? context.save()
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

// MARK: - 药物与保健品编辑器（新建 / 编辑）

struct MedicationEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var cabinetMedicines: [MedicineItem]

    let med: MedicationPlan?

    @State private var medName = ""
    @State private var dosageAmount: Double = 1
    @State private var dosageUnit = "片"
    @State private var frequency = 2
    @State private var timePoints: [Date] = []
    @State private var mealRelation: MedicationMealRelation = .afterMeal(minutes: 30)

    private let amountOptions: [Double] = [0.5, 1, 1.5, 2, 3, 4, 6]
    private let unitOptions = ["片", "粒", "颗", "袋", "支", "毫升", "滴", "包", "丸", "勺"]
    private let frequencyOptions = [1, 2, 3, 4, 5, 6]
    private let mealRelationPresets: [MedicationMealRelation] = [
        .afterMeal(minutes: 30),
        .afterMeal(minutes: 15),
        .withMeal,
        .beforeMeal(minutes: 30),
        .bedtime,
        .unrestricted
    ]
    /// 补齐新增时间槽时的默认小时（错开分布）
    private let defaultHours = [8, 20, 13, 16, 10, 22]

    private var activeCabinetMedicines: [MedicineItem] {
        var seen = Set<String>()
        return cabinetMedicines.filter { !$0.isDisposed && seen.insert($0.name).inserted }
    }

    private var isEditing: Bool { med != nil }

    init(med: MedicationPlan?) {
        self.med = med
        if let m = med {
            _medName = State(initialValue: m.medName)
            let (amount, unit) = Self.parseDosage(m.dosage)
            _dosageAmount = State(initialValue: amount)
            _dosageUnit = State(initialValue: unit)
            _mealRelation = State(initialValue: m.mealRelation)
            let points = m.dailyTimePoints.compactMap { Self.date(fromTime: $0) }
            _frequency = State(initialValue: max(1, min(6, points.count)))
            _timePoints = State(initialValue: points.isEmpty ? Self.defaultTimePoints(count: 2) : points)
        } else {
            _timePoints = State(initialValue: Self.defaultTimePoints(count: 2))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("药品信息") {
                    TextField("药品名称（如：维生素C、感冒药）", text: $medName)

                    if !activeCabinetMedicines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("从家庭药箱直接点选（自动带入用法）")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(activeCabinetMedicines) { item in
                                        let isSelected = medName == item.name
                                        Button {
                                            applyCabinetMedicine(item)
                                            Haptic.selection()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "archivebox.fill")
                                                    .font(.caption2)
                                                Text(item.name)
                                                    .font(.caption)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(isSelected ? Color.green.opacity(0.18) : Color(.tertiarySystemFill)))
                                            .overlay(Capsule().stroke(isSelected ? Color.green : Color.clear, lineWidth: 1))
                                            .foregroundStyle(isSelected ? Color.green : Color.primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("常用药快捷预设")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(commonMedicinePresets) { preset in
                                    let isSelected = medName == preset.name
                                    Button {
                                        medName = preset.name
                                        dosageAmount = preset.dosageAmount
                                        dosageUnit = preset.dosageUnit
                                        mealRelation = preset.mealRelation
                                        let count = max(1, min(6, preset.frequencyCount > 0 ? preset.frequencyCount : 1))
                                        frequency = count
                                        var draft = MedicineUsageDraft()
                                        draft.frequencyCount = count
                                        draft.frequencySpecial = preset.frequencySpecial
                                        draft.mealRelation = preset.mealRelation
                                        let parsedDates = draft.defaultTimePoints.compactMap { Self.date(fromTime: $0) }
                                        if !parsedDates.isEmpty {
                                            timePoints = parsedDates
                                        }
                                        Haptic.selection()
                                    } label: {
                                        Text(preset.name)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(isSelected ? Color.blue.opacity(0.18) : Color(.tertiarySystemFill)))
                                            .overlay(Capsule().stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1))
                                            .foregroundStyle(isSelected ? Color.blue : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if let notes = med?.notes {
                        TextField("备注", text: .constant(notes))
                            .disabled(true)
                            .foregroundStyle(.secondary)
                    }
                }

                // 用餐时效关系（滑动点选）
                Section("饮食时效要求（防伤胃与吸收自适应）") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(mealRelationPresets, id: \.self) { rel in
                                let isSelected = mealRelation == rel
                                Button {
                                    mealRelation = rel
                                    Haptic.selection()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: rel.iconName)
                                            .font(.caption)
                                        Text(rel.displayName)
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(isSelected ? Color.blue : Color(.tertiarySystemFill)))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 用量滑动选择，不手动输入
                Section("单次用量（滑动点选）") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("每次用量")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("每次 \(Self.formatAmount(dosageAmount)) \(dosageUnit)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(amountOptions, id: \.self) { a in
                                    let isSelected = abs(dosageAmount - a) < 0.001
                                    Button {
                                        dosageAmount = a
                                        Haptic.selection()
                                    } label: {
                                        Text(Self.formatAmount(a))
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(isSelected ? Color.green.opacity(0.18) : Color(.tertiarySystemFill)))
                                            .overlay(Capsule().stroke(isSelected ? Color.green : Color.clear, lineWidth: 1.5))
                                            .foregroundStyle(isSelected ? Color.green : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(unitOptions, id: \.self) { u in
                                    let isSelected = dosageUnit == u
                                    Button {
                                        dosageUnit = u
                                        Haptic.selection()
                                    } label: {
                                        Text(u)
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(isSelected ? Color.green : Color(.tertiarySystemFill)))
                                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // 频次与服用时间：频次用滑动胶囊选择
                Section("服用频次与时间") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(frequencyOptions, id: \.self) { f in
                                let isSelected = frequency == f
                                Button {
                                    frequency = f
                                    Haptic.selection()
                                } label: {
                                    Text("一日 \(f) 次")
                                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(isSelected ? Color.green : Color(.tertiarySystemFill)))
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    ForEach(timePoints.indices, id: \.self) { idx in
                        DatePicker("第\(idx + 1)次", selection: timePointBinding(at: idx), displayedComponents: .hourAndMinute)
                    }
                }

                Section {
                    let timesText = timePoints.map { Self.string(from: $0) }.joined(separator: "、")
                    Text("预览：\(medName.isEmpty ? "药品" : medName)，每次 \(Self.formatAmount(dosageAmount)) \(dosageUnit)，每天 \(frequency) 次（\(timesText) · \(mealRelation.displayName)）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isEditing ? "编辑服药提醒" : "添加服药提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "更新" : "保存") { save() }
                        .disabled(medName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: frequency) { _, newValue in
                adjustTimePoints(to: newValue)
            }
        }
    }

    private func applyCabinetMedicine(_ item: MedicineItem) {
        medName = item.name
        let draft = MedicineUsageDraft.parse(from: item.usageMethod ?? "")
        dosageAmount = draft.dosageAmount
        dosageUnit = draft.dosageUnit
        mealRelation = draft.mealRelation
        let count = max(1, min(6, draft.frequencyCount > 0 ? draft.frequencyCount : 1))
        frequency = count
        let parsedDates = draft.defaultTimePoints.compactMap { Self.date(fromTime: $0) }
        if !parsedDates.isEmpty {
            timePoints = parsedDates
        }
    }

    private func timePointBinding(at index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard timePoints.indices.contains(index) else { return .now }
                return timePoints[index]
            },
            set: { newDate in
                guard timePoints.indices.contains(index) else { return }
                timePoints[index] = newDate
            }
        )
    }

    private func adjustTimePoints(to count: Int) {
        if count < timePoints.count {
            timePoints.removeLast(timePoints.count - count)
        } else if count > timePoints.count {
            while timePoints.count < count {
                let idx = timePoints.count
                let hour = idx < defaultHours.count ? defaultHours[idx] : 8
                timePoints.append(Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? .now)
            }
        }
    }

    private func save() {
        let dosageStr = "每次 \(Self.formatAmount(dosageAmount)) \(dosageUnit)"
        let points = timePoints.map { Self.string(from: $0) }

        if let med {
            med.medName = medName
            med.dosage = dosageStr
            med.dailyTimePoints = points
            med.mealRelation = mealRelation
        } else {
            let plan = MedicationPlan(
                medName: medName,
                dosage: dosageStr,
                dailyTimePoints: points,
                mealRelation: mealRelation
            )
            context.insert(plan)
        }

        try? context.save()
        let scheduler = HabitAndMedicationScheduler(context: context)
        scheduler.scheduleMedicationReminders()
        dismiss()
    }

    // MARK: - 编解码辅助

    private static func formatAmount(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// 从 "每次 1 片" / "每次1.5毫升" 等文本解析出用量与单位（用于编辑回填）
    private static func parseDosage(_ text: String) -> (amount: Double, unit: String) {
        var num = ""
        for ch in text {
            if ch.isNumber || ch == "." { num.append(ch) }
            else if !num.isEmpty { break }
        }
        let amount = Double(num) ?? 1
        let units = ["毫升", "片", "粒", "颗", "袋", "支", "滴", "勺"]
        let unit = units.first { text.contains($0) } ?? "片"
        return (amount, unit)
    }

    private static func date(fromTime time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1]))
    }

    private static func string(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    private static func defaultTimePoints(count: Int) -> [Date] {
        let hours = [8, 20, 13, 16, 10, 22]
        let cal = Calendar.current
        return (0..<count).map { idx in
            cal.date(from: DateComponents(hour: idx < hours.count ? hours[idx] : 8, minute: 0)) ?? .now
        }
    }
}
