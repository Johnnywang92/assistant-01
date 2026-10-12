import AssistantCore
import SwiftData
import SwiftUI

/// 毛孩子 · 宠物健康档案与周期养护管理视图
struct PetManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PetProfile.createdAt, order: .reverse) private var pets: [PetProfile]

    @State private var showAddPet = false
    @State private var editingPet: PetProfile? = nil
    @State private var toastMessage: String? = nil

    private var needingCareCount: Int {
        pets.filter(\.needsAttention).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 顶部总览卡片
                    overviewHeaderCard

                    if pets.isEmpty {
                        emptyStateCard
                    } else {
                        // 2. 宠物卡片列表
                        ForEach(pets) { pet in
                            petCard(pet)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("宠物管家")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddPet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
            .sheet(isPresented: $showAddPet) {
                AddEditPetSheet()
            }
            .sheet(item: $editingPet) { pet in
                AddEditPetSheet(petToEdit: pet)
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(L10n.tr(msg))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - 顶部概览

    private var overviewHeaderCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 50, height: 50)
                Image(systemName: "pawprint.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("毛孩子健康周期")
                        .font(.headline)

                    if needingCareCount > 0 {
                        Text("\(needingCareCount) 项需处理")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }

                Text("自动推算体内外驱虫、联苗狂犬与日常洗澡清洁周期")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 空状态

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.teal.opacity(0.6))
                .padding(.top, 16)

            Text("暂未添加毛孩子")
                .font(.headline)

            Text("点击右上角 ➕ 录入爱宠档案，为您自动守护每月驱虫、每年疫苗与日常养护提醒。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                showAddPet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加宠物档案")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.teal)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.vertical, 12)
    }

    // MARK: - 宠物独立档案卡片

    private func petCard(_ pet: PetProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部基本信息
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(pet.type == .dog ? Color.blue.opacity(0.12) : Color.orange.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: pet.type.icon)
                        .font(.title3)
                        .foregroundStyle(pet.type == .dog ? Color.blue : Color.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pet.name)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(pet.breed)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                            .foregroundStyle(.secondary)

                        Text(L10n.tr(pet.gender))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.teal.opacity(0.12)))
                            .foregroundStyle(.teal)
                    }

                    HStack(spacing: 8) {
                        Text("年龄 \(pet.ageDescription)")
                        if let w = pet.weightKg {
                            Text("· 体重 \(String(format: "%.1f", w)) kg")
                        }
                        if let chip = pet.microchipId, !chip.isEmpty {
                            Text("· 芯片 \(chip)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button("编辑档案", systemImage: "pencil") {
                        editingPet = pet
                    }
                    Button("删除档案", systemImage: "trash", role: .destructive) {
                        deletePet(pet)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }

            Divider()

            // 养护周期打卡区（体外、体内、疫苗）
            VStack(spacing: 10) {
                // 1. 体外驱虫（每30天）
                careStatusRow(
                    title: "体外驱虫",
                    subtitle: "建议每\(pet.externalDewormCycleDays)天一次（预防跳蚤/蜱虫）",
                    daysLeft: pet.daysUntilNextExternalDeworm,
                    icon: "drop.fill",
                    iconColor: .teal
                ) {
                    withAnimation {
                        pet.lastExternalDewormDate = .now
                        try? context.save()
                        showToast("已打卡【\(pet.name)】体外驱虫！下次将于 30 天后提醒 💊")
                    }
                }

                // 2. 体内驱虫（每90天）
                careStatusRow(
                    title: "体内驱虫",
                    subtitle: "建议每\(pet.internalDewormCycleDays)天一次（预防蛔虫/绦虫）",
                    daysLeft: pet.daysUntilNextInternalDeworm,
                    icon: "pills.fill",
                    iconColor: .blue
                ) {
                    withAnimation {
                        pet.lastInternalDewormDate = .now
                        try? context.save()
                        showToast("已打卡【\(pet.name)】体内驱虫！下次将于 90 天后提醒 💊")
                    }
                }

                // 3. 疫苗狂犬（每年）
                careStatusRow(
                    title: "联苗与狂犬",
                    subtitle: "建议每\(pet.vaccineCycleDays)天加强一次",
                    daysLeft: pet.daysUntilNextVaccine,
                    icon: "cross.vial.fill",
                    iconColor: .purple
                ) {
                    withAnimation {
                        pet.lastVaccineDate = .now
                        try? context.save()
                        showToast("已打卡【\(pet.name)】年度疫苗！一年后再次提醒 💉")
                    }
                }
            }

            if let notes = pet.notes, !notes.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 单个养护项目状态行

    private func careStatusRow(
        title: String,
        subtitle: String,
        daysLeft: Int?,
        icon: String,
        iconColor: Color,
        onComplete: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.tr(title))
                        .font(.subheadline.bold())

                    if let days = daysLeft {
                        if days < 0 {
                            Text("已逾期 \(abs(days)) 天")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red.opacity(0.15)))
                                .foregroundStyle(.red)
                        } else if days <= 3 {
                            Text("剩 \(days) 天")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                                .foregroundStyle(.orange)
                        } else {
                            Text("剩 \(days) 天")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("未录入")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(L10n.tr(subtitle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("打卡")
                    .font(.caption.bold())
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.teal.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func deletePet(_ pet: PetProfile) {
        withAnimation {
            context.delete(pet)
            try? context.save()
            showToast("已删除宠物档案")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toastMessage == message {
                withAnimation { toastMessage = nil }
            }
        }
    }
}

// MARK: - 新建 / 编辑宠物弹窗

struct AddEditPetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var petToEdit: PetProfile? = nil

    @State private var name: String = ""
    @State private var type: PetType = .cat
    @State private var breed: String = ""
    @State private var gender: String = "绝育公"
    @State private var birthday: Date = .now
    @State private var hasBirthday: Bool = false
    @State private var weightString: String = ""
    @State private var microchipId: String = ""
    @State private var notes: String = ""

    private let genders = ["弟弟 (未绝育)", "绝育公", "妹妹 (未绝育)", "绝育母", "未知"]

    init(petToEdit: PetProfile? = nil) {
        self.petToEdit = petToEdit
        if let pet = petToEdit {
            _name = State(initialValue: pet.name)
            _type = State(initialValue: pet.type)
            _breed = State(initialValue: pet.breed)
            _gender = State(initialValue: pet.gender)
            _hasBirthday = State(initialValue: pet.birthday != nil)
            _birthday = State(initialValue: pet.birthday ?? .now)
            _weightString = State(initialValue: pet.weightKg.map { String($0) } ?? "")
            _microchipId = State(initialValue: pet.microchipId ?? "")
            _notes = State(initialValue: pet.notes ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("宠物昵称（如：布丁、大黄）", text: $name)

                    Picker("类型", selection: $type) {
                        ForEach(PetType.allCases) { t in
                            Text(L10n.tr(t.rawValue)).tag(t)
                        }
                    }

                    TextField("品种（如：英国短毛猫、柯基、金毛）", text: $breed)

                    Picker("性别与状态", selection: $gender) {
                        ForEach(genders, id: \.self) { g in
                            Text(L10n.tr(g)).tag(g)
                        }
                    }

                    Toggle("记录出生日期", isOn: $hasBirthday)
                    if hasBirthday {
                        DatePicker("生日", selection: $birthday, displayedComponents: .date)
                    }

                    TextField("当前体重（kg，选填）", text: $weightString)
                        .keyboardType(.decimalPad)

                    TextField("芯片号 / 电子犬证号（选填）", text: $microchipId)
                }

                Section("健康备忘") {
                    TextField("过敏史、偏好宠粮或就诊医院（选填）", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(petToEdit == nil ? "录入毛孩子档案" : "编辑档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { savePet() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func savePet() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let weight = Double(weightString.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedBreed = breed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (type == .cat ? "田园猫" : "田园犬") : breed.trimmingCharacters(in: .whitespacesAndNewlines)

        if let pet = petToEdit {
            pet.name = trimmedName
            pet.type = type
            pet.breed = trimmedBreed
            pet.gender = gender
            pet.birthday = hasBirthday ? birthday : nil
            pet.weightKg = weight
            pet.microchipId = microchipId.isEmpty ? nil : microchipId
            pet.notes = notes.isEmpty ? nil : notes
        } else {
            let newPet = PetProfile(
                name: trimmedName,
                type: type,
                breed: trimmedBreed,
                gender: gender,
                birthday: hasBirthday ? birthday : nil,
                weightKg: weight,
                microchipId: microchipId.isEmpty ? nil : microchipId,
                lastExternalDewormDate: .now,
                lastInternalDewormDate: .now,
                lastVaccineDate: .now,
                notes: notes.isEmpty ? nil : notes
            )
            context.insert(newPet)
        }
        try? context.save()
        dismiss()
    }
}
