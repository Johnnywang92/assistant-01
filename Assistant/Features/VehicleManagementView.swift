import SwiftData
import SwiftUI

/// 有车一族 · 爱车管家主视图（加油/充电、常规保养、车险续保、车辆年检智能守护）
struct VehicleManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VehicleProfile.createdAt, order: .reverse) private var vehicles: [VehicleProfile]
    @ObservedObject private var bgManager = AppBackgroundManager.shared

    @State private var showingAddSheet = false
    @State private var vehicleToEdit: VehicleProfile?
    @State private var vehicleForQuickExpense: (vehicle: VehicleProfile, type: String)?

    var body: some View {
        List {
            // 1. 顶部功能介绍横幅
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "car.side.fill")
                        .font(.title)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("有车一族 · 智能管车")
                            .font(.headline)
                        Text("支持燃油车定期加油、纯电车波谷充电提醒；联动常规保养、车险续保与年检防遗忘。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .themedRow()

            // 2. 爱车列表
            if vehicles.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("暂无爱车档案", systemImage: "car.badge.gearshape")
                    } description: {
                        Text("添加你的爱车，设定加油或充电周期、保养日程与车险到期日，小助将为你准时把关。")
                    } actions: {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("添加我的爱车", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 16)
                }
                .themedRow()
            } else {
                ForEach(vehicles) { vehicle in
                    Section {
                        VehicleCardView(
                            vehicle: vehicle,
                            onEdit: { vehicleToEdit = vehicle },
                            onQuickExpense: { type in
                                vehicleForQuickExpense = (vehicle, type)
                            }
                        )
                    }
                    .themedRow()
                }
                .onDelete(perform: deleteVehicles)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedAppBackground()
        .navigationTitle("爱车守护")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                    Haptic.light()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddVehicleSheet()
        }
        .sheet(item: $vehicleToEdit) { vehicle in
            EditVehicleSheet(vehicle: vehicle)
        }
        .sheet(item: Binding(
            get: { vehicleForQuickExpense.map { IdentifiableExpenseWrapper(vehicle: $0.vehicle, category: $0.type) } },
            set: { _ in vehicleForQuickExpense = nil }
        )) { wrapper in
            QuickVehicleExpenseSheet(vehicle: wrapper.vehicle, expenseType: wrapper.category)
        }
    }

    private func deleteVehicles(at offsets: IndexSet) {
        for idx in offsets {
            context.delete(vehicles[idx])
        }
        try? context.save()
        Haptic.warning()
    }
}

// MARK: - 单车仪表盘卡片

private struct VehicleCardView: View {
    @Bindable var vehicle: VehicleProfile
    let onEdit: () -> Void
    let onQuickExpense: (String) -> Void

    @State private var justRefilled = false
    @State private var justMaintained = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 车名、车牌与能源标签
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vehicle.name)
                        .font(.title3.bold())

                    HStack(spacing: 8) {
                        // 车牌仿真小徽章
                        Text(vehicle.plateNumber)
                            .font(.system(.caption, design: .monospaced).bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(vehicle.powerType == .electric ? Color.green.opacity(0.18) : Color.blue.opacity(0.15))
                            )
                            .foregroundStyle(vehicle.powerType == .electric ? Color.green : Color.blue)

                        // 能源类型胶囊
                        Label(L10n.tr(vehicle.powerType.rawValue), systemImage: vehicle.powerType.icon)
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    onEdit()
                    Haptic.light()
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 4 大管车核心指标网格
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                // 指标 1：加油 / 加电补能
                energyMetricCard

                // 指标 2：常规保养
                maintenanceMetricCard

                // 指标 3：车险到期
                insuranceMetricCard

                // 指标 4：车辆年检
                inspectionMetricCard
            }

            // 底部操作栏：一键记车务开销
            HStack(spacing: 8) {
                Button {
                    onQuickExpense(vehicle.powerType.energyVerb)
                    Haptic.light()
                } label: {
                    Label("记\(vehicle.powerType.energyVerb)", systemImage: vehicle.powerType.icon)
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    onQuickExpense("保养")
                    Haptic.light()
                } label: {
                    Label("记保养", systemImage: "wrench.and.screwdriver")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.12))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    onQuickExpense("停车/洗车")
                    Haptic.light()
                } label: {
                    Label("记杂项", systemImage: "parkingsign")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    // 补能状态卡片
    private var energyMetricCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(vehicle.powerType.energyVerb, systemImage: vehicle.powerType.icon)
                    .font(.caption2.bold())
                    .foregroundStyle(vehicle.powerType == .electric ? .green : .blue)
                Spacer()
                Button(justRefilled ? "已打卡" : "打卡") {
                    vehicle.completeEnergyRefill()
                    Haptic.success()
                    AppMotion.animate { justRefilled = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        AppMotion.animate { justRefilled = false }
                    }
                }
                .font(.caption2.bold())
                .buttonStyle(.bordered)
                .tint(vehicle.powerType == .electric ? .green : .blue)
                .controlSize(.mini)
            }

            let days = vehicle.daysUntilNextEnergyRefill
            if days <= 0 {
                Text("建议今天\(vehicle.powerType.energyVerb)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
            } else {
                Text("还剩 \(days) 天")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
            }

            Text("周期 \(vehicle.energyCycleDays) 天一次")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // 保养状态卡片
    private var maintenanceMetricCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("常规保养", systemImage: "wrench.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Button(justMaintained ? "已打卡" : "打卡") {
                    vehicle.completeMaintenance()
                    Haptic.success()
                    AppMotion.animate { justMaintained = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        AppMotion.animate { justMaintained = false }
                    }
                }
                .font(.caption2.bold())
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.mini)
            }

            let days = vehicle.daysUntilNextMaintenance
            if days <= 0 {
                Text("已逾期 \(abs(days)) 天")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
            } else {
                Text("还剩 \(days) 天")
                    .font(.subheadline.bold())
                    .foregroundStyle(days <= 15 ? .orange : .primary)
            }

            Text("每 \(vehicle.maintenanceIntervalMonths) 个月常规检查")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // 车险到期卡片
    private var insuranceMetricCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("车险到期", systemImage: "shield.checkerboard")
                .font(.caption2.bold())
                .foregroundStyle(.indigo)

            if let days = vehicle.daysUntilInsuranceExpiry {
                if days <= 0 {
                    Text("已脱保 \(abs(days)) 天！")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                } else {
                    Text("剩余 \(days) 天")
                        .font(.subheadline.bold())
                        .foregroundStyle(days <= 30 ? .red : .primary)
                }
                if let date = vehicle.insuranceExpiryDate {
                    Text(date.formatted(date: .numeric, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("未设置到期日")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text("点击编辑补充")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // 车辆年检卡片
    private var inspectionMetricCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("车辆年检", systemImage: "doc.text.magnifyingglass")
                .font(.caption2.bold())
                .foregroundStyle(.teal)

            if let days = vehicle.daysUntilAnnualInspection {
                if days <= 0 {
                    Text("已逾期 \(abs(days)) 天！")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                } else {
                    Text("剩余 \(days) 天")
                        .font(.subheadline.bold())
                        .foregroundStyle(days <= 60 ? .orange : .primary)
                }
                if let date = vehicle.annualInspectionDate {
                    Text(date.formatted(date: .numeric, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("未设置年检日")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text("六年免检/上线")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 添加爱车弹窗

private struct AddVehicleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String = ""
    @State private var plateNumber: String = ""
    @State private var powerType: VehiclePowerType = .gasoline
    @State private var energyCycleDays: Int = 7
    @State private var maintenanceIntervalMonths: Int = 6

    @State private var hasInsuranceExpiry: Bool = false
    @State private var insuranceExpiryDate: Date = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now

    @State private var hasAnnualInspection: Bool = false
    @State private var annualInspectionDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now

    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基础车况档案") {
                    TextField("爱车昵称（如：我的特斯拉 Model Y、高尔夫）", text: $name)

                    TextField("车牌号码（如：粤B·88888）", text: $plateNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)

                    Picker("能源类型", selection: $powerType) {
                        ForEach(VehiclePowerType.allCases) { type in
                            Label(L10n.tr(type.rawValue), systemImage: type.icon).tag(type)
                        }
                    }
                }

                Section("补能（\(powerType.energyVerb)）与保养周期") {
                    Stepper("\(powerType.energyVerb)周期：每 \(energyCycleDays) 天提醒一次", value: $energyCycleDays, in: 2...60)

                    Stepper("常规保养：每 \(maintenanceIntervalMonths) 个月提醒一次", value: $maintenanceIntervalMonths, in: 3...36)
                }

                Section("车险与年检合规防坑") {
                    Toggle("开启车险到期预警", isOn: $hasInsuranceExpiry)
                    if hasInsuranceExpiry {
                        DatePicker("车险到期日期", selection: $insuranceExpiryDate, displayedComponents: .date)
                    }

                    Toggle("开启车辆年检预警", isOn: $hasAnnualInspection)
                    if hasAnnualInspection {
                        DatePicker("检验有效截止期", selection: $annualInspectionDate, displayedComponents: .date)
                    }
                }

                Section("辅助备注（选填）") {
                    TextField("车架号/保险单号/机油标号等备忘", text: $notes)
                }
            }
            .navigationTitle("添加我的爱车")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveVehicle()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || plateNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func saveVehicle() {
        let vehicle = VehicleProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            plateNumber: plateNumber.trimmingCharacters(in: .whitespaces),
            powerType: powerType,
            energyCycleDays: energyCycleDays,
            maintenanceIntervalMonths: maintenanceIntervalMonths,
            insuranceExpiryDate: hasInsuranceExpiry ? insuranceExpiryDate : nil,
            annualInspectionDate: hasAnnualInspection ? annualInspectionDate : nil,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes
        )
        context.insert(vehicle)
        try? context.save()
        Haptic.success()
        dismiss()
    }
}

// MARK: - 编辑爱车弹窗

private struct EditVehicleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var vehicle: VehicleProfile

    @State private var hasInsuranceExpiry: Bool
    @State private var insuranceExpiryDate: Date

    @State private var hasAnnualInspection: Bool
    @State private var annualInspectionDate: Date

    init(vehicle: VehicleProfile) {
        self.vehicle = vehicle
        self._hasInsuranceExpiry = State(initialValue: vehicle.insuranceExpiryDate != nil)
        self._insuranceExpiryDate = State(initialValue: vehicle.insuranceExpiryDate ?? .now)
        self._hasAnnualInspection = State(initialValue: vehicle.annualInspectionDate != nil)
        self._annualInspectionDate = State(initialValue: vehicle.annualInspectionDate ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基础车况档案") {
                    TextField("爱车昵称", text: $vehicle.name)

                    TextField("车牌号码", text: $vehicle.plateNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)

                    Picker("能源类型", selection: $vehicle.powerType) {
                        ForEach(VehiclePowerType.allCases) { type in
                            Label(L10n.tr(type.rawValue), systemImage: type.icon).tag(type)
                        }
                    }
                }

                Section("补能（\(vehicle.powerType.energyVerb)）与保养周期") {
                    Stepper("\(vehicle.powerType.energyVerb)周期：每 \(vehicle.energyCycleDays) 天提醒一次", value: $vehicle.energyCycleDays, in: 2...60)

                    Stepper("常规保养：每 \(vehicle.maintenanceIntervalMonths) 个月提醒一次", value: $vehicle.maintenanceIntervalMonths, in: 3...36)
                }

                Section("车险与年检合规防坑") {
                    Toggle("开启车险到期预警", isOn: $hasInsuranceExpiry)
                    if hasInsuranceExpiry {
                        DatePicker("车险到期日期", selection: $insuranceExpiryDate, displayedComponents: .date)
                    }

                    Toggle("开启车辆年检预警", isOn: $hasAnnualInspection)
                    if hasAnnualInspection {
                        DatePicker("检验有效截止期", selection: $annualInspectionDate, displayedComponents: .date)
                    }
                }

                Section("辅助备注（选填）") {
                    TextField("车架号/保险单号/机油标号等备忘", text: Binding(
                        get: { vehicle.notes ?? "" },
                        set: { vehicle.notes = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .navigationTitle("编辑爱车信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        vehicle.insuranceExpiryDate = hasInsuranceExpiry ? insuranceExpiryDate : nil
                        vehicle.annualInspectionDate = hasAnnualInspection ? annualInspectionDate : nil
                        try? context.save()
                        Haptic.success()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 车务一键记账弹窗

private struct IdentifiableExpenseWrapper: Identifiable {
    let id = UUID()
    let vehicle: VehicleProfile
    let category: String
}

private struct QuickVehicleExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let vehicle: VehicleProfile
    let expenseType: String

    @State private var amountString: String = ""
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("开销信息") {
                    HStack {
                        Text("消费类型")
                        Spacer()
                        Text("爱车 · \(expenseType)")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("关联车辆")
                        Spacer()
                        Text("\(vehicle.name) (\(vehicle.plateNumber))")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("金额 (¥)")
                        TextField("0.00", text: $amountString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("备注") {
                    TextField("如：加满 95 号汽油 / 国家电网快充", text: $note)
                }
            }
            .navigationTitle("记录车务支出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("入账") {
                        saveExpense()
                    }
                    .disabled(Double(amountString) == nil || (Double(amountString) ?? 0) <= 0)
                }
            }
        }
    }

    private func saveExpense() {
        guard let amount = Double(amountString), amount > 0 else { return }
        let title = "爱车\(expenseType) - \(vehicle.name)"
        let fullNote = note.isEmpty ? "车牌：\(vehicle.plateNumber)" : "\(note)（车牌：\(vehicle.plateNumber)）"

        let record = ExpenseRecord(
            amount: amount,
            isIncome: false,
            category: .transport,
            title: title,
            rawText: fullNote,
            date: .now
        )
        context.insert(record)

        // 若是补能或保养，同步打卡更新车辆状态
        if expenseType.contains("油") || expenseType.contains("电") {
            vehicle.completeEnergyRefill()
        } else if expenseType.contains("保养") {
            vehicle.completeMaintenance()
        }

        try? context.save()
        Haptic.success()
        dismiss()
    }
}
