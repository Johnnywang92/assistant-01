import SwiftData
import SwiftUI

/// 宝贝档案的长期记录页：每次测量、事件和就医都作为独立记录保存。
struct ChildRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let child: ChildProfile
    @State private var recordType: RecordType = .growth
    @State private var addingType: RecordType?

    enum RecordType: String, CaseIterable, Identifiable {
        case growth = "成长"
        case milestones = "里程碑"
        case health = "健康"
        var id: Self { self }
        var icon: String {
            switch self {
            case .growth: return "ruler"
            case .milestones: return "sparkles"
            case .health: return "cross.case"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("记录类型", selection: $recordType) {
                    ForEach(RecordType.allCases) { type in
                        Label(type.rawValue, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch recordType {
                    case .growth: growthList
                    case .milestones: milestoneList
                    case .health: healthList
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(child.name) · 成长档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { addingType = recordType } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $addingType) { type in
                switch type {
                case .growth: AddGrowthRecordView(child: child)
                case .milestones: AddMilestoneRecordView(child: child)
                case .health: AddHealthVisitView(child: child)
                }
            }
        }
    }

    private var growthList: some View {
        recordScroll {
            if child.sortedGrowthRecords.isEmpty {
                emptyRecord("记录每次身高、体重和头围变化")
            } else {
                ForEach(child.sortedGrowthRecords) { record in
                    recordCard(date: record.date, icon: "ruler", title: "\(record.monthAge) 月龄") {
                        metric("身高", record.heightCm.map { String(format: "%.1f cm", $0) })
                        metric("体重", record.weightKg.map { String(format: "%.1f kg", $0) })
                        metric("头围", record.headCircumferenceCm.map { String(format: "%.1f cm", $0) })
                        if let notes = record.notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private var milestoneList: some View {
        recordScroll {
            if child.sortedMilestones.isEmpty { emptyRecord("记录第一次翻身、说话和每个值得纪念的瞬间") }
            ForEach(child.sortedMilestones) { record in
                recordCard(date: record.date, icon: "sparkles", title: record.title) {
                    Text(record.category.rawValue).font(.caption).foregroundStyle(.pink)
                    if let notes = record.notes, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var healthList: some View {
        recordScroll {
            if child.sortedHealthVisits.isEmpty { emptyRecord("记录每次就诊、诊断和复查安排") }
            ForEach(child.sortedHealthVisits) { record in
                recordCard(date: record.date, icon: "cross.case", title: record.diagnosis) {
                    if let clinic = record.hospitalOrClinic, !clinic.isEmpty { Text(clinic).font(.caption).foregroundStyle(.secondary) }
                    if let advice = record.doctorAdvice, !advice.isEmpty { Text(advice).font(.caption).foregroundStyle(.secondary) }
                    if let followUp = record.followUpDate { Text("复查：\(followUp.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }

    private func recordScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { LazyVStack(spacing: 10, content: content).padding() }
    }

    private func emptyRecord(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("点击右上角 + 随时追加").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity).padding(.vertical, 80)
    }

    private func recordCard<Content: View>(date: Date, icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: icon).foregroundStyle(.pink)
                Text(title).font(.subheadline.bold())
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func metric(_ name: String, _ value: String?) -> some View {
        if let value { return AnyView(Text("\(name)：\(value)").font(.caption)) }
        return AnyView(EmptyView())
    }
}

private struct AddGrowthRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let child: ChildProfile
    @State private var date = Date.now
    @State private var height = ""
    @State private var weight = ""
    @State private var head = ""
    @State private var notes = ""
    var body: some View {
        NavigationStack { Form {
            DatePicker("测量日期", selection: $date, displayedComponents: .date)
            TextField("身高（cm）", text: $height).keyboardType(.decimalPad)
            TextField("体重（kg）", text: $weight).keyboardType(.decimalPad)
            TextField("头围（cm，选填）", text: $head).keyboardType(.decimalPad)
            TextField("备注", text: $notes, axis: .vertical)
        }.navigationTitle("添加成长测量").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(height.isEmpty && weight.isEmpty && head.isEmpty) }
        }}
    }
    private func save() {
        let record = ChildGrowthRecord(date: date, monthAge: child.monthAge(at: date), heightCm: Double(height), weightKg: Double(weight), headCircumferenceCm: Double(head), notes: notes.isEmpty ? nil : notes, child: child)
        context.insert(record); child.growthRecords.append(record); try? context.save(); dismiss()
    }
}

private struct AddMilestoneRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let child: ChildProfile
    @State private var date = Date.now
    @State private var title = ""
    @State private var notes = ""
    var body: some View {
        NavigationStack { Form {
            DatePicker("发生日期", selection: $date, displayedComponents: .date)
            TextField("里程碑标题（如：第一次叫妈妈）", text: $title)
            TextField("记录当时的场景和心情", text: $notes, axis: .vertical)
        }.navigationTitle("添加成长里程碑").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }}
    }
    private func save() { let record = ChildMilestoneRecord(date: date, monthAge: child.monthAge(at: date), title: title, notes: notes.isEmpty ? nil : notes, child: child); context.insert(record); child.milestones.append(record); try? context.save(); dismiss() }
}

private struct AddHealthVisitView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let child: ChildProfile
    @State private var date = Date.now
    @State private var clinic = ""
    @State private var diagnosis = ""
    @State private var advice = ""
    @State private var followUp: Date? = nil
    var body: some View {
        NavigationStack { Form {
            DatePicker("就诊日期", selection: $date, displayedComponents: .date)
            TextField("医院/诊所（选填）", text: $clinic)
            TextField("诊断或就诊原因", text: $diagnosis)
            TextField("医生建议", text: $advice, axis: .vertical)
            Toggle("设置复查日期", isOn: Binding(get: { followUp != nil }, set: { if $0 { followUp = .now } else { followUp = nil } }))
            if followUp != nil { DatePicker("复查日期", selection: Binding(get: { followUp ?? .now }, set: { followUp = $0 }), displayedComponents: .date) }
        }.navigationTitle("添加健康记录").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(diagnosis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }}
    }
    private func save() { let record = ChildHealthVisitRecord(date: date, hospitalOrClinic: clinic.isEmpty ? nil : clinic, diagnosis: diagnosis, doctorAdvice: advice.isEmpty ? nil : advice, followUpDate: followUp, child: child); context.insert(record); child.healthVisits.append(record); try? context.save(); dismiss() }
}
