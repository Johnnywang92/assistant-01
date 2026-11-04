import SwiftData
import SwiftUI

/// 毛孩子档案的长期成长与健康记录页：体重变化、就医门诊、高光里程碑。
struct PetRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let pet: PetProfile

    @State private var recordType: PetRecordType = .growth
    @State private var addingType: PetRecordType? = nil

    init(pet: PetProfile, initialType: PetRecordType = .growth) {
        self.pet = pet
        self._recordType = State(initialValue: initialType)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("记录类型", selection: $recordType) {
                    ForEach(PetRecordType.allCases) { type in
                        Label(L10n.tr(type.rawValue), systemImage: type.icon)
                            .tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch recordType {
                    case .growth:
                        growthList
                    case .medical:
                        medicalList
                    case .milestones:
                        milestoneList
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(pet.name) · 成长档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addingType = recordType
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
            .sheet(item: $addingType) { type in
                AddPetRecordSheet(pet: pet, initialType: type)
            }
        }
    }

    // MARK: - 1. 成长体重列表

    private var growthList: some View {
        let items = pet.records(for: .growth)
        return recordScroll {
            if items.isEmpty {
                emptyRecord(
                    title: "暂无体重记录",
                    subtitle: "记录每次称重，追踪毛孩子的成长与体态变化",
                    icon: "scalemass"
                )
            } else {
                ForEach(items) { record in
                    recordCard(date: record.date, icon: "scalemass", iconColor: .teal, title: record.title) {
                        if let w = record.weightKg {
                            HStack(spacing: 4) {
                                Text("体重：")
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f kg", w))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.teal)
                            }
                        }
                        if let place = record.clinicOrPlace, !place.isEmpty {
                            Text("测量地点：\(place)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let notes = record.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } onDelete: {
                        deleteRecord(record)
                    }
                }
            }
        }
    }

    // MARK: - 2. 医疗健康列表

    private var medicalList: some View {
        let items = pet.records(for: .medical)
        return recordScroll {
            if items.isEmpty {
                emptyRecord(
                    title: "暂无医疗健康记录",
                    subtitle: "记录去宠物医院门诊、生病化验、绝育与用药历史",
                    icon: "cross.case"
                )
            } else {
                ForEach(items) { record in
                    recordCard(date: record.date, icon: "cross.case", iconColor: .blue, title: record.title) {
                        if let clinic = record.clinicOrPlace, !clinic.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "building.2")
                                    .font(.caption2)
                                Text(clinic)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if let notes = record.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    } onDelete: {
                        deleteRecord(record)
                    }
                }
            }
        }
    }

    // MARK: - 3. 高光里程碑列表

    private var milestoneList: some View {
        let items = pet.records(for: .milestones)
        return recordScroll {
            if items.isEmpty {
                emptyRecord(
                    title: "暂无高光足迹",
                    subtitle: "记录到家第一天、第一次学会握手、第一次洗澡等美好瞬间",
                    icon: "sparkles"
                )
            } else {
                ForEach(items) { record in
                    recordCard(date: record.date, icon: "sparkles", iconColor: .orange, title: record.title) {
                        if let notes = record.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } onDelete: {
                        deleteRecord(record)
                    }
                }
            }
        }
    }

    // MARK: - 辅助组件

    private func recordScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                content()
            }
            .padding()
        }
    }

    private func emptyRecord(title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.top, 24)
            Text(L10n.tr(title))
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text(L10n.tr(subtitle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                addingType = recordType
            } label: {
                Label("立即添加", systemImage: "plus")
                    .font(.caption.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: AppRadius.card).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func recordCard<Content: View>(
        date: Date,
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content,
        onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                        .font(.subheadline)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                Spacer()

                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Menu {
                    Button("删除记录", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(4)
                }
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.card).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func deleteRecord(_ record: PetRecord) {
        context.delete(record)
        try? context.save()
        Haptic.light()
    }
}

// MARK: - 添加宠物记录弹窗

struct AddPetRecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let pet: PetProfile

    @State private var type: PetRecordType
    @State private var title: String = ""
    @State private var date: Date = .now
    @State private var weightString: String = ""
    @State private var clinicOrPlace: String = ""
    @State private var notes: String = ""

    init(pet: PetProfile, initialType: PetRecordType = .growth) {
        self.pet = pet
        self._type = State(initialValue: initialType)
        switch initialType {
        case .growth:
            self._title = State(initialValue: "例行体重测量")
            if let w = pet.weightKg {
                self._weightString = State(initialValue: String(format: "%.2f", w))
            }
        case .medical:
            self._title = State(initialValue: "常规身体检查")
        case .milestones:
            self._title = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记录分类") {
                    Picker("分类", selection: $type) {
                        ForEach(PetRecordType.allCases) { t in
                            Text(L10n.tr(t.rawValue)).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: type) { _, newType in
                        if title.isEmpty || title == "例行体重测量" || title == "常规身体检查" {
                            switch newType {
                            case .growth: title = "例行体重测量"
                            case .medical: title = "常规身体检查"
                            case .milestones: title = ""
                            }
                        }
                    }

                    DatePicker("发生日期", selection: $date, displayedComponents: [.date])
                }

                Section("详细信息") {
                    TextField("记录标题（如：体检、绝育、洗澡等）", text: $title)

                    if type == .growth {
                        HStack {
                            Text("体重")
                            TextField("如 4.5", text: $weightString)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("kg")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if type == .medical {
                        TextField("医院/门诊名称（选填）", text: $clinicOrPlace)
                    }

                    if type == .milestones {
                        // 预设高光快捷选项
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(["到家第一天 🎉", "第一次洗澡 🛁", "第一次剪指甲 💅", "学会坐下握手 🐾", "一周岁生日 🎂", "首次户外探险 🌲"], id: \.self) { suggestion in
                                    Button {
                                        title = suggestion
                                        Haptic.selection()
                                    } label: {
                                        Text(suggestion)
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.orange.opacity(0.12), in: Capsule())
                                            .foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("备注说明（选填）") {
                    TextField("记录医嘱、体态评分、心情或表现…", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("添加\(type.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveRecord()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveRecord() {
        let weight = Double(weightString.trimmingCharacters(in: .whitespacesAndNewlines))
        let record = PetRecord(
            date: date,
            type: type,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            weightKg: weight,
            clinicOrPlace: clinicOrPlace.isEmpty ? nil : clinicOrPlace.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines),
            pet: pet
        )
        context.insert(record)

        // 若记录了最新体重，自动同步更新到 PetProfile 上的主体重
        if let w = weight, w > 0 {
            pet.weightKg = w
        }

        try? context.save()
        Haptic.success()
        dismiss()
    }
}
