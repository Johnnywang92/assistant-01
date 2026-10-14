import SwiftData
import SwiftUI

/// 运动与药物保健品管理视图
struct HabitAndMedicationView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PeriodicHabit.nextDueAt) private var habits: [PeriodicHabit]
    @Query private var medPlans: [MedicationPlan]

    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @State private var showingAddHabitSheet = false
    @State private var showingAddMedSheet = false
    /// 轻触记录行进入编辑：nil 表示新建，非 nil 表示编辑已有记录
    @State private var editingHabit: PeriodicHabit?
    @State private var editingMed: MedicationPlan?

    var body: some View {
        List {
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
            Section("药物与保健品") {
                if medPlans.isEmpty {
                    Text("暂无药物或保健品提醒计划").foregroundStyle(.secondary)
                } else {
                    ForEach(medPlans) { med in
                        MedicationRow(med: med) { editingMed = med }
                    }
                    .onDelete(perform: deleteMeds)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
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
    }

    private func deleteHabits(at offsets: IndexSet) {
        for idx in offsets { context.delete(habits[idx]) }
        try? context.save()
    }

    private func deleteMeds(at offsets: IndexSet) {
        for idx in offsets { context.delete(medPlans[idx]) }
        try? context.save()
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
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // 左侧内容区可点击编辑（与播报按钮分开，避免点击冲突）
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(med.medName, systemImage: "pills.fill")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .headline)
                        .foregroundStyle(seniorManager.isSeniorModeEnabled ? .green : .primary)
                    Spacer()
                    Text(med.dosage)
                        .font(seniorManager.isSeniorModeEnabled ? .body.bold() : .subheadline)
                        .foregroundStyle(seniorManager.isHighContrastEnabled ? .primary : .secondary)
                }
                Text("每日时点: \(med.dailyTimePoints.joined(separator: ", "))")
                    .font(seniorManager.isSeniorModeEnabled ? .subheadline : .caption)
                    .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.8) : .secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }

            if seniorManager.isVoiceBroadcastEnabled {
                Button {
                    let speech = "服药提醒：\(med.medName)，\(med.dosage)。服药时间：\(med.dailyTimePoints.joined(separator: "、"))。"
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

    let med: MedicationPlan?

    @State private var medName = ""
    @State private var dosageAmount: Double = 1
    @State private var dosageUnit = "片"
    @State private var frequency = 2
    @State private var timePoints: [Date] = []

    private let amountOptions: [Double] = [0.5, 1, 1.5, 2, 3, 4, 6]
    private let unitOptions = ["片", "粒", "颗", "袋", "支", "毫升", "滴", "勺"]
    private let frequencyOptions = [1, 2, 3, 4, 5, 6]
    /// 补齐新增时间槽时的默认小时（错开分布）
    private let defaultHours = [8, 20, 13, 16, 10, 22]

    private var isEditing: Bool { med != nil }

    init(med: MedicationPlan?) {
        self.med = med
        if let m = med {
            _medName = State(initialValue: m.medName)
            let (amount, unit) = Self.parseDosage(m.dosage)
            _dosageAmount = State(initialValue: amount)
            _dosageUnit = State(initialValue: unit)
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
                    if let notes = med?.notes {
                        TextField("备注", text: .constant(notes))
                            .disabled(true)
                            .foregroundStyle(.secondary)
                    }
                }

                // 用量滑动选择，不手动输入
                Section("单次用量（滑动选择）") {
                    Picker("用量", selection: $dosageAmount) {
                        ForEach(amountOptions, id: \.self) { a in
                            Text(Self.formatAmount(a)).tag(a)
                        }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)

                    Picker("单位", selection: $dosageUnit) {
                        ForEach(unitOptions, id: \.self) { Text($0).tag($0) }
                    }
                }

                // 频次与服用时间：频次用滑动选择，时间用滚轮
                Section("服用频次与时间") {
                    Picker("每日频次", selection: $frequency) {
                        ForEach(frequencyOptions, id: \.self) { Text("\($0) 次/天").tag($0) }
                    }

                    ForEach(timePoints.indices, id: \.self) { idx in
                        DatePicker("第\(idx + 1)次", selection: $timePoints[idx], displayedComponents: .hourAndMinute)
                    }
                }

                Section {
                    let timesText = timePoints.map { Self.string(from: $0) }.joined(separator: "、")
                    Text("预览：\(medName.isEmpty ? "药品" : medName)，每次 \(Self.formatAmount(dosageAmount)) \(dosageUnit)，每天 \(frequency) 次（\(timesText)）")
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
        } else {
            let plan = MedicationPlan(
                medName: medName,
                dosage: dosageStr,
                dailyTimePoints: points
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
