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
                        Text("把买房、装修、买车、婚礼、生娃、二胎等复杂事项整理成清晰的阶段和分工。")
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
                Text(L10n.tr(project.template.rawValue)).font(.caption).foregroundStyle(.secondary)
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
                ForEach(LifeEventTemplate.groupedSelectableCases) { group in
                    Section(group.category.displayName) {
                        ForEach(group.templates) { template in
                            Button { selectedTemplate = template } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.displayName).foregroundStyle(.primary)
                                        if template != .custom {
                                            Text("自动生成 \(template.defaultStages.count) 个阶段与 \(template.starterTasks.count) 项起步清单")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
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
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedTemplate.displayName : title.trimmingCharacters(in: .whitespacesAndNewlines)
                        _ = LifeEventTemplateFactory.createProject(title: name, template: selectedTemplate, targetDate: targetDate, location: location.isEmpty ? nil : location, budgetLimit: Double(budget) ?? 0, in: context)
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
    @Query private var expenses: [LifeEventExpense]
    @Query private var guests: [LifeEventGuest]
    @State private var showAddPerson = false
    @State private var showAddExpense = false
    @State private var showAddGuest = false
    @State private var taskToEdit: LifeEventTask?
    let project: LifeEventProject

    init(project: LifeEventProject) {
        self.project = project
        let pid = project.id
        _stages = Query(
            filter: #Predicate<LifeEventStage> { $0.projectID == pid },
            sort: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        _tasks = Query(filter: #Predicate<LifeEventTask> { $0.projectID == pid })
        _people = Query(
            filter: #Predicate<LifeEventPerson> { $0.projectID == pid },
            sort: [SortDescriptor(\.name, order: .forward)]
        )
        _expenses = Query(
            filter: #Predicate<LifeEventExpense> { $0.projectID == pid },
            sort: [SortDescriptor(\.title, order: .forward)]
        )
        _guests = Query(
            filter: #Predicate<LifeEventGuest> { $0.projectID == pid },
            sort: [SortDescriptor(\.name, order: .forward)]
        )
    }

    private var projectStages: [LifeEventStage] { stages }
    private var projectTasks: [LifeEventTask] { tasks }
    private var completedCount: Int { projectTasks.filter(\.isDone).count }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.title).font(.title2.bold())
                    Text(project.daysRemaining >= 0 ? "距离目标日期还有 \(project.daysRemaining) 天" : "目标日期已过去 \(abs(project.daysRemaining)) 天")
                        .foregroundStyle(project.daysRemaining < 0 ? Color.red : Color.accentColor)
                    if let location = project.location, !location.isEmpty {
                        Button {
                            MapNavigationService.openDirections(to: location)
                        } label: {
                            Label(location, systemImage: "arrow.triangle.turn.up.right.diamond")
                                .font(.subheadline)
                                .foregroundStyle(.tint)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
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
                            HStack(spacing: 8) {
                                Label(task.title, systemImage: task.isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.isDone ? .secondary : .primary)
                                Spacer()
                                if let dueDate = task.dueDate {
                                    Text(dueDate, format: .dateTime.month().day())
                                        .font(.caption2)
                                        .foregroundStyle(!task.isDone && dueDate < .now ? .red : .secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑任务", systemImage: "pencil") { taskToEdit = task }
                            if !task.isDone {
                                Button("标记已完成", systemImage: "checkmark.circle") {
                                    task.statusRaw = "done"
                                    try? context.save()
                                }
                            }
                        }
                    }
                }
            }
            Section("人物与分工") {
                if projectPeople.isEmpty {
                    Text(project.template.peopleHint)
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
            Section("预算与账本") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已支出").font(.caption).foregroundStyle(.secondary)
                        Text(expensesTotal, format: .currency(code: "CNY")).font(.headline)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("预算上限").font(.caption).foregroundStyle(.secondary)
                        Text(project.budgetLimit > 0 ? project.budgetLimit.formatted(.currency(code: "CNY")) : "未设置").font(.headline)
                    }
                }
                ForEach(projectExpenses) { expense in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(expense.title).font(.subheadline.weight(.medium))
                            let remaining = max(expense.amount - expense.paidAmount, 0)
                            let paymentStatus = expense.paidAmount >= expense.amount ? "已付清" : "待付 \(remaining.formatted(.currency(code: "CNY")))"
                            Text([expense.category, paymentStatus].joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(expense.amount, format: .currency(code: "CNY"))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(projectExpenses[index]) }
                    try? context.save()
                }
                Button("添加开销", systemImage: "plus.circle") { showAddExpense = true }
            }
            if project.template.supportsGuests {
                Section("宾客与邀请") {
                    HStack {
                        Label("已确认", systemImage: "checkmark.circle")
                        Spacer()
                        Text("\(confirmedGuestCount) / \(projectGuests.count)").foregroundStyle(.secondary)
                    }
                    ForEach(projectGuests) { guest in
                        HStack(spacing: 10) {
                            Image(systemName: guest.attendanceRaw == "yes" ? "checkmark.circle.fill" : "person.crop.circle")
                                .foregroundStyle(guest.attendanceRaw == "yes" ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(guest.name).font(.subheadline.weight(.medium))
                                Text([guest.relationship, guest.side, guest.tableNumber.isEmpty ? "" : "桌 \(guest.tableNumber)", guest.attendanceTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contextMenu {
                            Button("标记已确认", systemImage: "checkmark.circle") {
                                guest.attendanceRaw = "yes"
                                try? context.save()
                            }
                            Button("标记待确认", systemImage: "questionmark.circle") {
                                guest.attendanceRaw = "pending"
                                try? context.save()
                            }
                            Button("标记不出席", systemImage: "xmark.circle") {
                                guest.attendanceRaw = "no"
                                try? context.save()
                            }
                            ShareLink(item: invitationText(for: guest), preview: SharePreview("邀请：\(guest.name)")) {
                                Label("分享邀请通知", systemImage: "paperplane")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(projectGuests[index]) }
                        try? context.save()
                    }
                    Button("添加宾客", systemImage: "person.2.badge.plus") { showAddGuest = true }
                }
            }
        }
        .navigationTitle("项目详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加人物", systemImage: "person.badge.plus") { showAddPerson = true }
                    if project.template.supportsGuests {
                        Button("添加宾客", systemImage: "person.2.badge.plus") { showAddGuest = true }
                    }
                    ShareLink(item: shareText, preview: SharePreview(project.title)) {
                        Label("分享筹备摘要", systemImage: "square.and.arrow.up")
                    }
                    ShareLink(item: familyShareText, preview: SharePreview("给家长的筹备全览")) {
                        Label("分享给家长", systemImage: "person.2")
                    }
                    ShareLink(item: teamShareText, preview: SharePreview("执行分工流程")) {
                        Label("分享给执行人员", systemImage: "person.3")
                    }
                    if project.template.supportsGuests {
                        ShareLink(item: guestShareText, preview: SharePreview("宾客通知")) {
                            Label("分享给宾客", systemImage: "envelope")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddPerson) {
            LifeEventAddPersonView(projectID: project.id)
        }
        .sheet(isPresented: $showAddExpense) {
            LifeEventAddExpenseView(projectID: project.id, template: project.template)
        }
        .sheet(isPresented: $showAddGuest) {
            LifeEventAddGuestView(projectID: project.id)
        }
        .sheet(item: $taskToEdit) { task in
            LifeEventTaskEditView(task: task)
        }
    }

    private var projectPeople: [LifeEventPerson] { people }

    private var projectExpenses: [LifeEventExpense] { expenses }

    private var expensesTotal: Double {
        projectExpenses.reduce(0) { $0 + $1.paidAmount }
    }

    private var projectGuests: [LifeEventGuest] { guests }

    private var confirmedGuestCount: Int { projectGuests.filter { $0.attendanceRaw == "yes" }.count }

    private func invitationText(for guest: LifeEventGuest) -> String {
        var text = "邀请：\(guest.name)\n\n诚邀你参加「\(project.title)」。\n时间：\(project.targetDate.formatted(date: .long, time: .omitted))"
        if let location = project.location, !location.isEmpty { text += "\n地点：\(location)" }
        text += "\n\n请回复是否出席，方便我们安排座位和流程。期待见到你！"
        return text
    }

    private var shareText: String {
        let completed = completedCount
        let peopleText = projectPeople.map { person in
            let duty = person.responsibility.isEmpty ? "待分工" : person.responsibility
            return "- \(person.name)（\(person.role.isEmpty ? person.relationship : person.role)）：\(duty)"
        }.joined(separator: "\n")
        let guestLine = project.template.supportsGuests ? "\n宾客：\(confirmedGuestCount) / \(projectGuests.count) 人已确认" : ""
        return "人生大事筹备摘要\n项目：\(project.title)\n目标日期：\(project.targetDate.formatted(date: .long, time: .omitted))\n进度：\(completed) / \(projectTasks.count) 项已完成\(guestLine)\(peopleText.isEmpty ? "" : "\n\n人物与分工：\n\(peopleText)")"
    }

    private var familyShareText: String {
        let guestLine = project.template.supportsGuests ? "\n宾客确认：\(confirmedGuestCount) / \(projectGuests.count) 人" : ""
        return "给家长的筹备全览\n\n项目：\(project.title)\n日期：\(project.targetDate.formatted(date: .long, time: .omitted))\n地点：\(project.location?.isEmpty == false ? project.location! : "待定")\n预算：\(project.budgetLimit > 0 ? project.budgetLimit.formatted(.currency(code: "CNY")) : "待定")\n事项进度：已完成 \(completedCount) / \(projectTasks.count) 项\(guestLine)\n\n请在需要调整日期、预算或分工时及时和我们沟通。"
    }

    private var teamShareText: String {
        let tasksText = projectTasks.filter { !$0.isDone }.prefix(12).map { "- \($0.title)" }.joined(separator: "\n")
        let peopleText = projectPeople.map { person in
            "- \(person.name)：\(person.responsibility.isEmpty ? "待确认分工" : person.responsibility)\(person.phone.isEmpty ? "" : "（\(person.phone)）")"
        }.joined(separator: "\n")
        return "执行人员分工\n项目：\(project.title)\n目标日期：\(project.targetDate.formatted(date: .long, time: .omitted))\n\n人物与职责：\n\(peopleText.isEmpty ? "暂无分工，请先补充人物" : peopleText)\n\n待处理事项：\n\(tasksText.isEmpty ? "暂无未完成事项" : tasksText)"
    }

    private var guestShareText: String {
        var text = "宾客通知\n\n诚邀亲友参加「\(project.title)」！\n日期：\(project.targetDate.formatted(date: .long, time: .omitted))"
        if let location = project.location, !location.isEmpty { text += "\n地点：\(location)" }
        return text + "\n\n请回复是否出席，方便我们安排座位和流程。期待见到你！"
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

private struct LifeEventAddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let projectID: UUID
    let template: LifeEventTemplate
    @State private var title = ""
    @State private var category = ""

    init(projectID: UUID, template: LifeEventTemplate) {
        self.projectID = projectID
        self.template = template
        _category = State(initialValue: template.expenseCategories.first ?? "其他")
    }
    @State private var amount = ""
    @State private var paidAmount = ""
    @State private var payee = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date.now

    private var categories: [String] { template.expenseCategories }

    var body: some View {
        NavigationStack {
            Form {
                Section("开销信息") {
                    TextField("项目名称，例如：酒店定金", text: $title)
                    Picker("分类", selection: $category) { ForEach(categories, id: \.self, content: Text.init) }
                    TextField("总金额", text: $amount).keyboardType(.decimalPad)
                    TextField("已付金额（定金/尾款）", text: $paidAmount).keyboardType(.decimalPad)
                    TextField("收款方（可选）", text: $payee)
                }
                Section {
                    Toggle("设置付款截止日", isOn: $hasDueDate)
                    if hasDueDate { DatePicker("截止日", selection: $dueDate, displayedComponents: .date) }
                }
            }
            .navigationTitle("添加开销")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let total = Double(amount) ?? 0
                        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, total > 0 else { return }
                        context.insert(LifeEventExpense(projectID: projectID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), category: category, amount: total, paidAmount: min(max(Double(paidAmount) ?? 0, 0), total), payee: payee, dueDate: hasDueDate ? dueDate : nil))
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (Double(amount) ?? 0) <= 0)
                }
            }
        }
    }
}

private struct LifeEventAddGuestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let projectID: UUID
    @State private var name = ""
    @State private var relationship = ""
    @State private var side = ""
    @State private var phone = ""
    @State private var tableNumber = ""
    @State private var attendance = "pending"

    var body: some View {
        NavigationStack {
            Form {
                Section("宾客信息") {
                    TextField("姓名", text: $name)
                    TextField("关系，例如：同事、舅舅", text: $relationship)
                    TextField("所属，例如：男方、女方", text: $side)
                    TextField("电话（可选）", text: $phone).keyboardType(.phonePad)
                }
                Section("出席与礼金") {
                    Picker("出席状态", selection: $attendance) {
                        Text("待确认").tag("pending")
                        Text("已确认").tag("yes")
                        Text("不出席").tag("no")
                    }
                    TextField("桌号（可选）", text: $tableNumber)
                }
            }
            .navigationTitle("添加宾客")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanName.isEmpty else { return }
                        context.insert(LifeEventGuest(projectID: projectID, name: cleanName, relationship: relationship, side: side, phone: phone, tableNumber: tableNumber, attendanceRaw: attendance))
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LifeEventTaskEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let task: LifeEventTask
    @State private var title: String
    @State private var ownerName: String
    @State private var detail: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date

    init(task: LifeEventTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _ownerName = State(initialValue: task.ownerName ?? "")
        _detail = State(initialValue: task.detail ?? "")
        _hasDueDate = State(initialValue: task.dueDate != nil)
        _dueDate = State(initialValue: task.dueDate ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称", text: $title)
                    TextField("负责人（可选）", text: $ownerName)
                    TextField("备注（可选）", text: $detail, axis: .vertical)
                }
                Section("截止时间") {
                    Toggle("设置截止日期", isOn: $hasDueDate)
                    if hasDueDate { DatePicker("截止日期", selection: $dueDate, displayedComponents: .date) }
                }
            }
            .navigationTitle("编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanTitle.isEmpty else { return }
                        task.title = cleanTitle
                        task.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerName
                        task.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : detail
                        task.dueDate = hasDueDate ? dueDate : nil
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
