import AssistantCore
import SwiftData
import SwiftUI

/// 亲子育儿 · 宝贝成长与健康疫苗档案视图
struct ChildManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ChildProfile.createdAt, order: .reverse) private var children: [ChildProfile]

    @State private var showAddChild = false
    @State private var editingChild: ChildProfile? = nil
    @State private var recordsChild: ChildProfile? = nil
    @State private var toastMessage: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 顶部总览卡片
                    overviewHeaderCard

                    if children.isEmpty {
                        emptyStateCard
                    } else {
                        // 2. 宝贝成长卡片列表
                        ForEach(children) { child in
                            childCard(child)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("亲子成长档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddChild = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
            .sheet(isPresented: $showAddChild) {
                AddEditChildSheet()
            }
            .sheet(item: $editingChild) { child in
                AddEditChildSheet(childToEdit: child)
            }
            .sheet(item: $recordsChild) { child in
                ChildRecordsView(child: child)
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
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
                    .fill(Color.pink.opacity(0.12))
                    .frame(width: 50, height: 50)
                Image(systemName: "figure.and.child.holdinghands")
                    .font(.title2)
                    .foregroundStyle(.pink)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("国家免疫规划疫苗与成长记录")
                    .font(.headline)

                Text("按月龄自动推算计划免疫接种节点，过敏史与身体指标关怀")
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
            Image(systemName: "figure.child.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.pink.opacity(0.6))
                .padding(.top, 16)

            Text("暂未录入宝贝档案")
                .font(.headline)

            Text("录入宝宝生日后，系统将为您按月龄智能排期《国家免疫规划》17 剂核心疫苗并设置适龄接种提醒。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                showAddChild = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加宝贝档案")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.pink)
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

    // MARK: - 宝贝独立卡片

    private func childCard(_ child: ChildProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部基本信息
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(child.gender == .girl ? Color.pink.opacity(0.12) : Color.blue.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: child.gender == .girl ? "figure.child" : "figure.child")
                        .font(.title3)
                        .foregroundStyle(child.gender == .girl ? Color.pink : Color.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(child.name)
                            .font(.headline)

                        if let real = child.realName, !real.isEmpty {
                            Text("(\(real))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Text(child.gender.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(child.gender == .girl ? Color.pink.opacity(0.12) : Color.blue.opacity(0.12)))
                            .foregroundStyle(child.gender == .girl ? Color.pink : Color.blue)
                    }

                    HStack(spacing: 8) {
                        Text("当前年龄 \(child.ageDescription)（\(child.currentMonthAge)月龄）")
                        if let h = child.heightCm {
                            Text("· 身高 \(String(format: "%.1f", h))cm")
                        }
                        if let w = child.weightKg {
                            Text("· 体重 \(String(format: "%.1f", w))kg")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if !child.growthRecords.isEmpty || !child.milestones.isEmpty || !child.healthVisits.isEmpty {
                        Text("已累计 (child.growthRecords.count) 次测量 · (child.milestones.count) 个里程碑 · (child.healthVisits.count) 条健康记录")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                }

                Spacer()

                Button {
                    recordsChild = child
                } label: {
                    Label("成长记录", systemImage: "chart.xyaxis.line")
                        .font(.caption.bold())
                        .foregroundStyle(.pink)
                }
                .buttonStyle(.plain)

                Menu {
                    Button("编辑档案", systemImage: "pencil") {
                        editingChild = child
                    }
                    Button("删除档案", systemImage: "trash", role: .destructive) {
                        deleteChild(child)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }

            // 过敏史警示标签
            if let allergy = child.allergyInfo, !allergy.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text("特别警示/过敏原：\(allergy)")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
            }

            Divider()

            // 疫苗接种进度条
            let totalVaccines = ChildVaccineTemplateItem.standardSchedule.count
            let completed = child.completedVaccineCount
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("《国家免疫规划》疫苗进度")
                        .font(.subheadline.bold())

                    Spacer()

                    Text("\(completed) / \(totalVaccines) 剂完成")
                        .font(.caption.bold())
                        .foregroundStyle(.pink)
                }

                ProgressView(value: Double(completed), total: Double(totalVaccines))
                    .tint(.pink)
            }

            // 适龄与待接种疫苗列表
            VStack(alignment: .leading, spacing: 8) {
                Text("适龄接种计划（点击勾选打卡）：")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                let schedule = ChildVaccineTemplateItem.standardSchedule
                ForEach(schedule.prefix(6)) { item in
                    vaccineRow(item: item, child: child)
                }

                if schedule.count > 6 {
                    Text("已收录至 2 周岁全部 17 剂免费免疫程序")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func vaccineRow(item: ChildVaccineTemplateItem, child: ChildProfile) -> some View {
        let isDone = child.completedVaccineIds.contains(item.id)
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                child.toggleVaccineCompletion(id: item.id)
                try? context.save()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if !isDone {
                    showToast("已完成打卡【\(item.vaccineName)】！")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isDone ? Color.pink : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.vaccineName)
                            .font(.caption.bold())
                            .foregroundStyle(isDone ? .secondary : .primary)
                            .strikethrough(isDone)

                        Text(item.monthLabel)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                            .foregroundStyle(.secondary)
                    }

                    Text("预防：\(item.targetDisease)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func deleteChild(_ child: ChildProfile) {
        withAnimation {
            context.delete(child)
            try? context.save()
            showToast("已删除宝贝档案")
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

// MARK: - 新建 / 编辑宝贝弹窗

struct AddEditChildSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var childToEdit: ChildProfile? = nil

    @State private var name: String = ""
    @State private var realName: String = ""
    @State private var gender: ChildGender = .boy
    @State private var birthday: Date = .now
    @State private var bloodType: String = "A型"
    @State private var idCardNumber: String = ""
    @State private var allergyInfo: String = ""
    @State private var heightString: String = ""
    @State private var weightString: String = ""
    @State private var notes: String = ""

    private let bloodTypes = ["A型", "B型", "AB型", "O型", "Rh阳性", "暂不清楚"]

    init(childToEdit: ChildProfile? = nil) {
        self.childToEdit = childToEdit
        if let child = childToEdit {
            _name = State(initialValue: child.name)
            _realName = State(initialValue: child.realName ?? "")
            _gender = State(initialValue: child.gender)
            _birthday = State(initialValue: child.birthday)
            _bloodType = State(initialValue: child.bloodType ?? "A型")
            _idCardNumber = State(initialValue: child.idCardNumber ?? "")
            _allergyInfo = State(initialValue: child.allergyInfo ?? "")
            _heightString = State(initialValue: child.heightCm.map { String($0) } ?? "")
            _weightString = State(initialValue: child.weightKg.map { String($0) } ?? "")
            _notes = State(initialValue: child.notes ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("宝贝基本信息") {
                    TextField("宝宝小名/昵称（如：安安、糯米）", text: $name)
                    TextField("大名/真实姓名（选填）", text: $realName)

                    Picker("性别", selection: $gender) {
                        ForEach(ChildGender.allCases) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }

                    DatePicker("出生日期", selection: $birthday, displayedComponents: .date)

                    Picker("血型", selection: $bloodType) {
                        ForEach(bloodTypes, id: \.self) { b in
                            Text(b).tag(b)
                        }
                    }

                    TextField("出生证号/身份证号（选填）", text: $idCardNumber)
                }

                Section("健康与安全") {
                    TextField("食物/药物过敏史（如鸡蛋蛋白过敏、蚕豆病等）", text: $allergyInfo, axis: .vertical)
                        .lineLimit(2...3)

                    HStack {
                        Text("当前身高 (cm)")
                        Spacer()
                        TextField("如 85.5", text: $heightString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("当前体重 (kg)")
                        Spacer()
                        TextField("如 12.0", text: $weightString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    TextField("日常备忘（常去儿保医院、奶粉辅食品牌等）", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(childToEdit == nil ? "录入宝贝档案" : "编辑宝贝档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveChild() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveChild() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let h = Double(heightString.trimmingCharacters(in: .whitespacesAndNewlines))
        let w = Double(weightString.trimmingCharacters(in: .whitespacesAndNewlines))

        if let child = childToEdit {
            child.name = trimmedName
            child.realName = realName.isEmpty ? nil : realName
            child.gender = gender
            child.birthday = birthday
            child.bloodType = bloodType
            child.idCardNumber = idCardNumber.isEmpty ? nil : idCardNumber
            child.allergyInfo = allergyInfo.isEmpty ? nil : allergyInfo
            child.heightCm = h
            child.weightKg = w
            child.notes = notes.isEmpty ? nil : notes
        } else {
            let newChild = ChildProfile(
                name: trimmedName,
                realName: realName.isEmpty ? nil : realName,
                gender: gender,
                birthday: birthday,
                bloodType: bloodType,
                idCardNumber: idCardNumber.isEmpty ? nil : idCardNumber,
                allergyInfo: allergyInfo.isEmpty ? nil : allergyInfo,
                heightCm: h,
                weightKg: w,
                notes: notes.isEmpty ? nil : notes
            )
            context.insert(newChild)
        }
        try? context.save()
        dismiss()
    }
}
