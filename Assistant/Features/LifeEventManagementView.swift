import SwiftData
import SwiftUI

struct LifeEventManagementView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\LifeEventProject.targetDate, order: .forward)]) private var projects: [LifeEventProject]
    @State private var showCreate = false
    @State private var selectedProject: LifeEventProject?

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("还没有人生大事项目", systemImage: "sparkles")
                    } description: {
                        Text("把订婚、婚礼、乔迁、升学宴等复杂事项整理成清晰的阶段和分工。")
                    } actions: {
                        Button("创建人生大事", systemImage: "plus") { showCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(projects) { project in
                                Button { selectedProject = project } label: {
                                    LifeEventProjectCard(project: project)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                for index in offsets { context.delete(projects[index]) }
                                try? context.save()
                            }
                        } header: {
                            Text("进行中的人生大事")
                        }
                    }
                }
            }
            .navigationTitle("人生大事")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新建", systemImage: "plus") { showCreate = true }
                }
            }
            .sheet(isPresented: $showCreate) { LifeEventCreateView() }
            .sheet(item: $selectedProject) { project in LifeEventProjectDetailView(project: project) }
        }
    }
}

private struct LifeEventProjectCard: View {
    let project: LifeEventProject

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: project.template.icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).font(.headline).lineLimit(1)
                Text(project.template.rawValue).font(.caption).foregroundStyle(.secondary)
                Text(project.daysRemaining >= 0 ? "还有 \(project.daysRemaining) 天" : "已过目标日期 \(abs(project.daysRemaining)) 天")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(project.daysRemaining < 0 ? Color.red : Color.accentColor)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

struct LifeEventCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selectedTemplate: LifeEventTemplate = .engagementWedding
    @State private var title = ""
    @State private var targetDate = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var location = ""
    @State private var budget = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("选择模板") {
                    ForEach(LifeEventTemplate.allCases) { template in
                        Button { selectedTemplate = template } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.rawValue).foregroundStyle(.primary)
                                    if template != .custom { Text("自动生成阶段与起步清单").font(.caption).foregroundStyle(.secondary) }
                                }
                            } icon: {
                                Image(systemName: template.icon).foregroundStyle(.tint)
                            }
                            Spacer()
                            if selectedTemplate == template { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("基本信息") {
                    TextField("项目名称，例如：我的婚礼", text: $title)
                    DatePicker("目标日期", selection: $targetDate, displayedComponents: [.date])
                    TextField("地点（可选）", text: $location)
                    TextField("预算上限（可选）", text: $budget).keyboardType(.decimalPad)
                }
            }
            .navigationTitle("创建人生大事")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedTemplate.rawValue : title.trimmingCharacters(in: .whitespacesAndNewlines)
                        LifeEventTemplateFactory.createProject(title: name, template: selectedTemplate, targetDate: targetDate, location: location.isEmpty ? nil : location, budgetLimit: Double(budget) ?? 0, in: context)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedTemplate == .custom)
                }
            }
        }
    }
}

struct LifeEventProjectDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var stages: [LifeEventStage]
    @Query private var tasks: [LifeEventTask]
    @Query private var people: [LifeEventPerson]
    @State private var showAddPerson = false
    let project: LifeEventProject

    private var projectStages: [LifeEventStage] { stages.filter { $0.projectID == project.id }.sorted { $0.sortOrder < $1.sortOrder } }
    private var projectTasks: [LifeEventTask] { tasks.filter { $0.projectID == project.id } }
    private var completedCount: Int { projectTasks.filter(\.isDone).count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.title).font(.title2.bold())
                    Text(project.daysRemaining >= 0 ? "距离目标日期还有 \(project.daysRemaining) 天" : "目标日期已过去 \(abs(project.daysRemaining)) 天")
                        .foregroundStyle(project.daysRemaining < 0 ? Color.red : Color.accentColor)
                    ProgressView(value: Double(completedCount), total: Double(max(projectTasks.count, 1)))
                    Text("已完成 \(completedCount) / \(projectTasks.count) 项")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            ForEach(projectStages) { stage in
                let stageTasks = projectTasks.filter { $0.stageID == stage.id }
                Section(stage.title) {
                    ForEach(stageTasks) { task in
                        Button {
                            task.statusRaw = task.isDone ? "active" : "done"
                            try? context.save()
                            Haptic.light()
                        } label: {
                            Label(task.title, systemImage: task.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isDone ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("人物与分工") {
                if projectPeople.isEmpty {
                    Text("添加双方父母、亲友或供应商，明确每个人负责的事情。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(projectPeople) { person in
                        LifeEventPersonRow(person: person)
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(projectPeople[index]) }
                        try? context.save()
                    }
                }
                Button("添加人物", systemImage: "person.badge.plus") { showAddPerson = true }
            }
        }
        .navigationTitle("项目详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加人物", systemImage: "person.badge.plus") { showAddPerson = true }
            }
        }
        .sheet(isPresented: $showAddPerson) {
            LifeEventAddPersonView(projectID: project.id)
        }
    }

    private var projectPeople: [LifeEventPerson] {
        people.filter { $0.projectID == project.id }.sorted { $0.name < $1.name }
    }
}

private struct LifeEventPersonRow: View {
    let person: LifeEventPerson

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3).foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.name).font(.subheadline.weight(.medium))
                    if !person.role.isEmpty { Text(person.role).font(.caption).foregroundStyle(.secondary) }
                }
                if !person.responsibility.isEmpty {
                    Text(person.responsibility).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if !person.phone.isEmpty {
                    Text(person.phone).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

private struct LifeEventAddPersonView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let projectID: UUID
    @State private var name = ""
    @State private var role = ""
    @State private var relationship = ""
    @State private var phone = ""
    @State private var responsibility = ""
    @State private var side = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("姓名", text: $name)
                    TextField("角色，例如：伴郎、酒店经理", text: $role)
                    TextField("关系，例如：男方父亲、朋友", text: $relationship)
                    TextField("电话", text: $phone).keyboardType(.phonePad)
                }
                Section("分工") {
                    TextField("负责事项", text: $responsibility, axis: .vertical)
                    TextField("所属，例如：男方、女方、供应商", text: $side)
                }
            }
            .navigationTitle("添加人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        context.insert(LifeEventPerson(projectID: projectID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role, relationship: relationship, phone: phone, responsibility: responsibility, side: side))
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct LifeEventHomeBanner: View {
    @Query(sort: [SortDescriptor(\LifeEventProject.targetDate, order: .forward)]) private var projects: [LifeEventProject]
    @ObservedObject private var router = NavigationRouter.shared

    var body: some View {
        if let project = projects.first(where: { $0.statusRaw == "active" }) {
            Button { router.selectedTab = .lifeEvents } label: {
                HStack(spacing: 10) {
                    Image(systemName: project.template.icon).foregroundStyle(.tint)
                    Text(project.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(project.daysRemaining >= 0 ? "还有 \(project.daysRemaining) 天" : "已过期")
                        .font(.caption.weight(.medium)).foregroundStyle(project.daysRemaining < 0 ? Color.red : Color.accentColor)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }
}
