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

    var body: some View {
        List {
            Section {
                Text("助手会自动根据周期推算下次时间，并在到期当天生成待办。运动与药物、保健品提醒可以长期持续记录。")
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
                        MedicationRow(med: med)
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
        .sheet(isPresented: $showingAddHabitSheet) { AddHabitSheet() }
        .sheet(isPresented: $showingAddMedSheet) { AddMedSheet() }
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
    @Environment(\.modelContext) private var context
    @Bindable var habit: PeriodicHabit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(habit.title, systemImage: "figure.run")
                    .font(.headline)
                Spacer()
                Text(habit.recurrence.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }

            HStack {
                Text("下次提醒: \(habit.nextDueAt, format: .dateTime.month().day().hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let scene = habit.triggerHomeKitScene, !scene.isEmpty {
                    Text("· 联动: \(scene)")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct MedicationRow: View {
    @Bindable var med: MedicationPlan
    @ObservedObject private var seniorManager = SeniorModeManager.shared

    var body: some View {
        HStack(spacing: 8) {
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

struct AddHabitSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var detail = ""
    @State private var recurrence = RecurrenceInterval.weekly
    @State private var homeKitScene = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("运动内容") {
                    TextField("运动名称（如：跑步、瑜伽、力量训练）", text: $title)
                    TextField("补充备注（可选）", text: $detail)
                    Picker("重复周期", selection: $recurrence) {
                        ForEach(RecurrenceInterval.allCases, id: \.self) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                }

                Section("运动备注（可选）") {
                    TextField("训练地点或器械备注", text: $homeKitScene)
                }
            }
            .navigationTitle("新建运动计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let habit = PeriodicHabit(
                            title: title,
                            detail: detail.isEmpty ? nil : detail,
                            recurrence: recurrence,
                            triggerHomeKitScene: homeKitScene.isEmpty ? nil : homeKitScene
                        )
                        context.insert(habit)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}

struct AddMedSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var medName = ""
    @State private var dosage = "每次 1 片"
    @State private var timeString = "08:00, 20:00"

    var body: some View {
        NavigationStack {
            Form {
                Section("药品信息") {
                    TextField("药品名称（如：维生素C、感冒药）", text: $medName)
                    TextField("剂量（如：每次1粒、饭后服用）", text: $dosage)
                    TextField("每日时点（用逗号隔开，如 08:00, 20:00）", text: $timeString)
                }
            }
            .navigationTitle("添加服药提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let points = timeString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        let plan = MedicationPlan(
                            medName: medName,
                            dosage: dosage,
                            dailyTimePoints: points
                        )
                        context.insert(plan)
                        try? context.save()

                        let scheduler = HabitAndMedicationScheduler(context: context)
                        scheduler.scheduleMedicationReminders()

                        dismiss()
                    }
                    .disabled(medName.isEmpty)
                }
            }
        }
    }
}
