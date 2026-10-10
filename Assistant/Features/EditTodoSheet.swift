import AssistantCore
import SwiftData
import SwiftUI

/// 待办事项全功能编辑面板
struct EditTodoSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Bindable var item: TodoItem

    @State private var title: String
    @State private var type: TodoType
    @State private var detail: String
    @State private var pickupCode: String
    @State private var station: String
    @State private var courier: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var remindBeforeMinutes: Int
    @State private var customRemindBeforeMinutes: Int
    @State private var recurrenceRule: TodoRecurrenceRule
    @State private var customIntervalDays: Int
    @State private var isDone: Bool

    @State private var showingDeleteConfirmation: Bool = false

    init(item: TodoItem) {
        self.item = item
        self._title = State(initialValue: item.title)
        self._type = State(initialValue: item.type)
        self._detail = State(initialValue: item.detail ?? "")
        self._pickupCode = State(initialValue: item.pickupCode ?? "")
        self._station = State(initialValue: item.station ?? item.location ?? "")
        self._courier = State(initialValue: item.courier ?? "")
        self._hasDueDate = State(initialValue: item.dueAt != nil)
        self._dueDate = State(initialValue: item.dueAt ?? (Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now))
        self._remindBeforeMinutes = State(initialValue: [0, 5, 60, 1440].contains(item.remindBeforeMinutes) ? item.remindBeforeMinutes : -1)
        self._customRemindBeforeMinutes = State(initialValue: max(1, item.remindBeforeMinutes))
        let rule = item.recurrenceRule
        self._recurrenceRule = State(initialValue: rule)
        self._customIntervalDays = State(initialValue: item.recurrenceIntervalDays > 0 ? item.recurrenceIntervalDays : (rule.dayInterval() > 0 ? rule.dayInterval() : 3))
        self._isDone = State(initialValue: item.status == .done)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 事项基本信息
                Section("事项内容") {
                    TextField("待办名称", text: $title)

                    Picker("分类类型", selection: $type) {
                        ForEach(TodoType.allCases.filter { $0 != .data }, id: \.self) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }

                    // 快递模式专属输入字段
                    if type == .parcel {
                        TextField("取件码（如：3-2-104 或 5821）", text: $pickupCode)
                            .font(.body.monospaced())

                        TextField("存放驿站/自提柜（选填，如：东门菜鸟驿站、丰巢）", text: $station)

                        TextField("快递公司（选填，如：顺丰速运、京东快递）", text: $courier)
                    } else if type == .returnParcel {
                        TextField("寄件码 / 售后运单号（选填）", text: $pickupCode)
                            .font(.body.monospaced())

                        TextField("寄件方式/网点（选填，如：顺丰上门取件、驿站代寄）", text: $station)

                        TextField("寄件快递（选填，如：顺丰速运、京东生鲜）", text: $courier)
                    }
                }

                // 2. 详情与备注说明
                Section("详情与备注") {
                    TextField("补充备注/详情说明（选填）", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                }

                // 3. 提醒时间与重复周期
                Section("提醒与时间") {
                    Toggle("设置截止/提醒时间", isOn: $hasDueDate)
                        .onChange(of: hasDueDate) { _, enabled in
                            if enabled { Task { await NotificationService.requestAuthorization() } }
                        }
                    if hasDueDate {
                        DatePicker("截止时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                        Picker("提前提醒", selection: $remindBeforeMinutes) {
                            Text("到期时").tag(0)
                            Text("提前 5 分钟").tag(5)
                            Text("提前 1 小时").tag(60)
                            Text("提前 1 天").tag(1440)
                            Text("自定义").tag(-1)
                        }
                        if remindBeforeMinutes == -1 {
                            Stepper("提前 \(customRemindBeforeMinutes) 分钟", value: $customRemindBeforeMinutes, in: 1...10080, step: 5)
                        }
                    }

                    Picker("重复周期", selection: $recurrenceRule) {
                        ForEach(TodoRecurrenceRule.allCases) { rule in
                            Label(rule.rawValue, systemImage: rule.icon).tag(rule)
                        }
                    }

                    if recurrenceRule == .custom {
                        Stepper("每 \(customIntervalDays) 天重复一次", value: $customIntervalDays, in: 1...365)
                    }

                    if recurrenceRule != .none {
                        Text("当标记为此事项完成时，系统将自动按「\(recurrenceRule.displayLabel(customDays: customIntervalDays))」生成下一期事项。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 4. 状态切换
                Section("完成状态") {
                    Toggle("标记为已完成", isOn: $isDone)
                }

                // 5. 危险操作区
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("删除此事项", systemImage: "trash")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("编辑事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("确定删除该事项？", isPresented: $showingDeleteConfirmation) {
                Button("删除", role: .destructive) {
                    deleteItem()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后将无法恢复。")
            }
        }
    }

    private func saveChanges() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        if hasDueDate { Task { await NotificationService.requestAuthorization() } }

        item.title = trimmedTitle
        item.type = type
        item.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : detail.trimmingCharacters(in: .whitespacesAndNewlines)
        item.pickupCode = pickupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStation = station.trimmingCharacters(in: .whitespacesAndNewlines)
        item.station = trimmedStation.isEmpty ? nil : trimmedStation
        item.location = trimmedStation.isEmpty ? nil : trimmedStation
        item.courier = courier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : courier.trimmingCharacters(in: .whitespacesAndNewlines)
        item.dueAt = hasDueDate ? dueDate : nil
        item.remindBeforeMinutes = hasDueDate ? (remindBeforeMinutes == -1 ? customRemindBeforeMinutes : remindBeforeMinutes) : 0
        item.reminderOverrideAt = nil
        item.recurrenceRule = recurrenceRule
        item.recurrenceIntervalDays = recurrenceRule == .custom ? customIntervalDays : recurrenceRule.dayInterval(customDays: customIntervalDays)

        let wasNotDone = (item.status != .done)
        if isDone && wasNotDone {
            item.markAsCompleted(in: context)
        } else {
            item.status = isDone ? .done : .active
            if !isDone {
                TodoNotificationManager.shared.scheduleNotification(for: item)
            } else {
                TodoNotificationManager.shared.cancelNotification(for: item.id)
            }
        }

        try? context.save()
        Haptic.success()
        dismiss()
    }

    private func deleteItem() {
        TodoNotificationManager.shared.cancelNotification(for: item.id)
        context.delete(item)
        try? context.save()
        Haptic.warning()
        dismiss()
    }
}
