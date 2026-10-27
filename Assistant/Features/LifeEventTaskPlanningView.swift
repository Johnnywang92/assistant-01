import AssistantCore
import SwiftData
import SwiftUI
import UIKit

// MARK: - 芯片换行布局

/// 预设选项芯片的换行布局（问题卡片内多选胶囊用）。
struct LifeEventFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 档案文本装配（模型 → 引擎输入）

enum LifeEventArchiveBuilder {
    /// 把项目下的人物、账本、任务（含需求答案与 AI 摘要）装配成完整档案文本。
    static func makeArchive(
        project: LifeEventProject,
        stages: [LifeEventStage],
        tasks: [LifeEventTask],
        people: [LifeEventPerson],
        expenses: [LifeEventExpense]
    ) -> String {
        let stageTitleByID = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.title) })
        let orderedTasks = tasks.sorted {
            let l = (stageTitleByID[$0.stageID] ?? "", $0.createdAt)
            let r = (stageTitleByID[$1.stageID] ?? "", $1.createdAt)
            return l < r
        }
        let taskItems: [LifeEventArchiveTaskItem] = orderedTasks.map { task in
            let qs = LifeEventTaskPlanningEngine.questions(for: task.title, templateRaw: project.template.rawValue)
            let answers = LifeEventTaskPlanningEngine.decodeAnswers(task.answersJSON)
            return LifeEventArchiveTaskItem(
                stageTitle: stageTitleByID[task.stageID] ?? "未分组",
                title: task.title,
                isDone: task.isDone,
                ownerName: task.ownerName,
                dueText: task.dueDate?.formatted(date: .abbreviated, time: .omitted),
                answerLines: LifeEventTaskPlanningEngine.answerLines(questions: qs, answers: answers),
                aiSummary: task.aiDecisionSummary
            )
        }
        let peopleLines = people.map { person in
            let duty = person.responsibility.isEmpty ? "待分工" : person.responsibility
            return "- \(person.name)（\(person.role.isEmpty ? person.relationship : person.role)）：\(duty)"
        }
        let expenseLines = expenses.map { e in
            let payment = e.paidAmount >= e.amount ? "已付清" : "已付 \(e.paidAmount) / 待付 \(max(e.amount - e.paidAmount, 0))"
            return "- \(e.title)（\(e.category)）：预算 \(e.amount)，\(payment)"
        }
        return LifeEventTaskPlanningEngine.generateProjectArchive(
            LifeEventProjectArchiveInput(
                projectTitle: project.title,
                templateName: project.template.displayName,
                targetDateText: project.targetDate.formatted(date: .long, time: .omitted),
                locationText: project.location,
                budgetText: project.budgetLimit > 0 ? project.budgetLimit.formatted(.currency(code: "CNY")) : nil,
                tasks: taskItems,
                peopleLines: peopleLines,
                expenseLines: expenseLines
            )
        )
    }
}

// MARK: - 首页待办镜像

/// 把导入的 AI 行动项镜像一份到首页待办（来源标注人生大事项目）。
/// 与学习路径镜像同口径：`sourceText` 记来源；`lifeEventTaskID` 软关联
/// 支撑「首页勾完 = 项目任务也完成」的双向联动（见 LifeEventTodoLink）。
enum LifeEventHomeTodoMirror {
    static func insert(actionText: String, projectTitle: String, stageTitle: String, taskID: UUID, into context: ModelContext) {
        let item = TodoItem(
            type: .general,
            status: .active,
            title: actionText,
            detail: "人生大事·\(projectTitle)（\(stageTitle)）· AI 决策建议",
            sourceText: "来自人生大事：\(projectTitle)",
            lifeEventTaskID: taskID
        )
        context.insert(item)
    }
}

// MARK: - 导入候选项

private struct LifeEventImportCandidate: Identifiable {
    let id = UUID()
    let text: String
    var isOn: Bool
}

// MARK: - 任务级需求规划与 AI 咨询

/// 要点任务的需求问答 + 大模型决策回填闭环。
/// 流程：填写引导问题 → 一键复制咨询 Prompt（或完整档案）→ 去任意
/// 大模型获得决策 → 粘贴回复解析 → 保存决策摘要并把行动项导入为待办。
struct LifeEventTaskPlanningView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let task: LifeEventTask
    let project: LifeEventProject
    let stageTitle: String

    @State private var answers: [String: LifeEventTaskAnswer]
    @State private var aiReplyText = ""
    @State private var parsedSummary = ""
    @State private var candidates: [LifeEventImportCandidate] = []
    @State private var showParsedPreview = false
    @State private var copiedHint: String?
    @State private var mirrorToHome = true

    init(task: LifeEventTask, project: LifeEventProject, stageTitle: String) {
        self.task = task
        self.project = project
        self.stageTitle = stageTitle
        _answers = State(initialValue: LifeEventTaskPlanningEngine.decodeAnswers(task.answersJSON))
    }

    private var questions: [LifeEventTaskQuestion] {
        LifeEventTaskPlanningEngine.questions(for: task.title, templateRaw: project.template.rawValue)
    }

    private var filledCount: Int {
        LifeEventTaskPlanningEngine.filledCount(questions: questions, answers: answers)
    }

    var body: some View {
        NavigationStack {
            Form {
                taskHeaderSection
                questionsSection
                aiConsultSection
                if task.aiDecisionSummary != nil {
                    savedDecisionSection
                }
            }
            .navigationTitle("需求规划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        persistAnswers()
                        dismiss()
                    }
                }
            }
            .onChange(of: answers) {
                persistAnswers()
            }
        }
    }

    // MARK: 任务概览

    private var taskHeaderSection: some View {
        Section("要点任务") {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title).font(.headline)
                HStack(spacing: 8) {
                    Text(stageTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let dueDate = task.dueDate {
                        Text(dueDate, format: .dateTime.month().day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let owner = task.ownerName, !owner.isEmpty {
                        Text(owner).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { task.isDone },
                    set: { newValue in
                        task.statusRaw = newValue ? "done" : "active"
                        try? context.save()
                        Haptic.light()
                    }
                )) {
                    Label("标记为已完成", systemImage: task.isDone ? "checkmark.circle.fill" : "circle")
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 需求引导问答

    private var questionsSection: some View {
        Section {
            ForEach(questions) { question in
                QuestionCard(question: question, answer: binding(for: question.id))
            }
        } header: {
            Text("需求梳理")
        } footer: {
            Text("已填写 \(filledCount) / \(questions.count) 项。填得越具体，大模型给出的决策越贴合你的情况。")
        }
    }

    private func binding(for id: String) -> Binding<LifeEventTaskAnswer> {
        Binding(
            get: { answers[id] ?? LifeEventTaskAnswer() },
            set: { newValue in
                if newValue.isEmpty {
                    answers[id] = nil
                } else {
                    answers[id] = newValue
                }
            }
        )
    }

    // MARK: AI 决策咨询

    private var aiConsultSection: some View {
        Section {
            Button {
                copyToClipboard(consultationPrompt(), hint: "已复制咨询 Prompt，去粘贴给任意 AI 助手")
            } label: {
                Label("复制咨询 Prompt（含需求答案）", systemImage: "doc.on.doc")
            }

            Button {
                copyToClipboard(projectArchiveText(), hint: "已复制完整项目档案")
            } label: {
                Label("复制完整项目档案（全局规划）", systemImage: "folder.doc.badge.gearshape")
            }

            HStack(spacing: 12) {
                Button {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        aiReplyText = clip
                        copiedHint = "已粘贴剪贴板内容"
                    } else {
                        copiedHint = "剪贴板为空"
                    }
                } label: {
                    Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    parseReply()
                } label: {
                    Text("解析 AI 回复")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(aiReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("把大模型的决策回复粘贴到这里…", text: $aiReplyText, axis: .vertical)
                .lineLimit(4...10)
                .font(.subheadline)

            if showParsedPreview {
                parsedPreviewRows
            }
        } header: {
            Text("大模型决策咨询")
        } footer: {
            if let copiedHint {
                Text(copiedHint).foregroundStyle(.tint)
            } else {
                Text("复制后可发给 ChatGPT、Claude、豆包、Kimi 等任意助手；把回复粘贴回来，自动拆出行动待办导入本项目。")
            }
        }
    }

    @ViewBuilder
    private var parsedPreviewRows: some View {
        if !parsedSummary.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("决策摘要").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(parsedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            .padding(.vertical, 2)
        }
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("识别到的行动待办（可勾选导入）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach($candidates) { $candidate in
                    Toggle(isOn: $candidate.isOn) {
                        Text(candidate.text).font(.subheadline)
                    }
                }
                Toggle("同步一份到首页待办", isOn: $mirrorToHome)
                    .font(.subheadline)
                Button {
                    importSelectedItems()
                } label: {
                    Label("导入选中项为待办", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidates.allSatisfy { !$0.isOn })
            }
            .padding(.vertical, 2)
        } else if showParsedPreview {
            Text("没有识别出格式化的行动待办，可整理成「- 待办内容」一行一条后再解析。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 已保存的决策

    private var savedDecisionSection: some View {
        Section {
            if let summary = task.aiDecisionSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let itemsJSON = task.aiActionItemsJSON,
               let data = itemsJSON.data(using: .utf8),
               let items = try? JSONDecoder().decode([String].self, from: data),
               !items.isEmpty {
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                }
            }
            if let consultedAt = task.aiConsultedAt {
                Text("咨询于 \(consultedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button(role: .destructive) {
                task.aiDecisionSummary = nil
                task.aiActionItemsJSON = nil
                task.aiConsultedAt = nil
                try? context.save()
                Haptic.light()
            } label: {
                Label("清除决策记录", systemImage: "trash")
            }
        } header: {
            Text("已记录的 AI 决策")
        }
    }

    // MARK: 动作

    private func persistAnswers() {
        let encoded = LifeEventTaskPlanningEngine.encodeAnswers(answers)
        if task.answersJSON != encoded {
            task.answersJSON = encoded
            try? context.save()
        }
    }

    private func consultationPrompt() -> String {
        LifeEventTaskPlanningEngine.generateConsultationPrompt(
            projectTitle: project.title,
            templateName: project.template.displayName,
            targetDateText: project.targetDate.formatted(date: .long, time: .omitted),
            locationText: project.location,
            taskTitle: task.title,
            stageTitle: stageTitle,
            answers: LifeEventTaskPlanningEngine.promptAnswerMap(questions: questions, answers: answers)
        )
    }

    private func projectArchiveText() -> String {
        let pid = project.id
        var stageDescriptor = FetchDescriptor<LifeEventStage>(predicate: #Predicate { $0.projectID == pid })
        stageDescriptor.sortBy = [SortDescriptor(\.sortOrder, order: .forward)]
        let stages = (try? context.fetch(stageDescriptor)) ?? []
        let tasks = (try? context.fetch(FetchDescriptor<LifeEventTask>(
            predicate: #Predicate { $0.projectID == pid }
        ))) ?? []
        let people = (try? context.fetch(FetchDescriptor<LifeEventPerson>(
            predicate: #Predicate { $0.projectID == pid }
        ))) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<LifeEventExpense>(
            predicate: #Predicate { $0.projectID == pid }
        ))) ?? []
        return LifeEventArchiveBuilder.makeArchive(
            project: project, stages: stages, tasks: tasks, people: people, expenses: expenses
        )
    }

    private func parseReply() {
        let trimmed = aiReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = LifeEventTaskPlanningEngine.parseAIDecisionOutput(rawOutput: trimmed)
        parsedSummary = result.summary
        candidates = result.actionItems.map { LifeEventImportCandidate(text: $0, isOn: true) }
        showParsedPreview = true
        copiedHint = candidates.isEmpty ? "解析完成，未识别出行动待办" : "解析完成，识别到 \(candidates.count) 条行动待办"
        Haptic.light()
    }

    private func importSelectedItems() {
        let selected = candidates.filter(\.isOn).map(\.text)
        guard !selected.isEmpty else { return }
        persistAnswers()
        for text in selected {
            let newTask = LifeEventTask(projectID: task.projectID, stageID: task.stageID, title: text)
            context.insert(newTask)
            if mirrorToHome {
                LifeEventHomeTodoMirror.insert(
                    actionText: text,
                    projectTitle: project.title,
                    stageTitle: stageTitle,
                    taskID: newTask.id,
                    into: context
                )
            }
        }
        if let data = try? JSONEncoder().encode(selected),
           let itemsJSON = String(data: data, encoding: .utf8) {
            task.aiActionItemsJSON = itemsJSON
        }
        task.aiDecisionSummary = aiReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        task.aiConsultedAt = .now
        try? context.save()
        Haptic.success()
        copiedHint = mirrorToHome
            ? "已导入 \(selected.count) 条待办到「\(stageTitle)」，并同步到首页待办"
            : "已导入 \(selected.count) 条待办到「\(stageTitle)」"
        showParsedPreview = false
        candidates = []
        aiReplyText = ""
    }

    private func copyToClipboard(_ text: String, hint: String) {
        UIPasteboard.general.string = text
        copiedHint = hint
        Haptic.success()
    }
}

// MARK: - 单条问题卡片

private struct QuestionCard: View {
    let question: LifeEventTaskQuestion
    @Binding var answer: LifeEventTaskAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.title)
                .font(.subheadline.weight(.semibold))
            if let help = question.helpText, !help.isEmpty {
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !question.presetOptions.isEmpty {
                LifeEventFlowLayout(spacing: 8) {
                    ForEach(question.presetOptions, id: \.self) { option in
                        let isOn = answer.presets.contains(option)
                        Button {
                            togglePreset(option)
                        } label: {
                            Text(option)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                    in: Capsule()
                                )
                                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option)
                        .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    }
                }
            }
            TextField(question.placeholder, text: $answer.note, axis: .vertical)
                .lineLimit(2...6)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }

    private func togglePreset(_ option: String) {
        if let index = answer.presets.firstIndex(of: option) {
            answer.presets.remove(at: index)
        } else {
            answer.presets.append(option)
        }
        Haptic.light()
    }
}

// MARK: - 项目级 AI 全局决策导入

/// 把大模型对整个项目的全局规划回复粘贴回来，拆出行动项批量导入指定阶段。
struct LifeEventAIDecisionImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let project: LifeEventProject
    let stages: [LifeEventStage]

    @State private var aiReplyText = ""
    @State private var parsedSummary = ""
    @State private var candidates: [LifeEventImportCandidate] = []
    @State private var showParsedPreview = false
    @State private var targetStageID: UUID
    @State private var statusHint: String?
    @State private var mirrorToHome = true

    init(project: LifeEventProject, stages: [LifeEventStage]) {
        self.project = project
        self.stages = stages
        _targetStageID = State(initialValue: stages.first?.id ?? UUID())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("把大模型的全局规划回复粘贴到这里…", text: $aiReplyText, axis: .vertical)
                        .lineLimit(5...12)
                        .font(.subheadline)
                    HStack(spacing: 12) {
                        Button {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                aiReplyText = clip
                                statusHint = "已粘贴剪贴板内容"
                            } else {
                                statusHint = "剪贴板为空"
                            }
                        } label: {
                            Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button {
                            parseReply()
                        } label: {
                            Text("解析 AI 回复").font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(aiReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("粘贴大模型输出")
                } footer: {
                    if let statusHint {
                        Text(statusHint).foregroundStyle(.tint)
                    } else {
                        Text("建议用「复制完整项目档案」生成的提示词咨询，回复中带上「- 待办」列表时识别最准。")
                    }
                }

                if showParsedPreview {
                    if !parsedSummary.isEmpty {
                        Section("决策摘要") {
                            Text(parsedSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                    }
                    Section("行动待办（可勾选导入）") {
                        if candidates.isEmpty {
                            Text("没有识别出格式化的行动待办，可整理成「- 待办内容」一行一条后再解析。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach($candidates) { $candidate in
                                Toggle(isOn: $candidate.isOn) {
                                    Text(candidate.text).font(.subheadline)
                                }
                            }
                            if !stages.isEmpty {
                                Picker("导入到阶段", selection: $targetStageID) {
                                    ForEach(stages) { stage in
                                        Text(stage.title).tag(stage.id)
                                    }
                                }
                            }
                            Toggle("同步一份到首页待办", isOn: $mirrorToHome)
                                .font(.subheadline)
                            Button {
                                importSelectedItems()
                            } label: {
                                Label("导入选中项为待办", systemImage: "square.and.arrow.down")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(candidates.allSatisfy { !$0.isOn } || stages.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("导入 AI 决策")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func parseReply() {
        let trimmed = aiReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = LifeEventTaskPlanningEngine.parseAIDecisionOutput(rawOutput: trimmed)
        parsedSummary = result.summary
        candidates = result.actionItems.map { LifeEventImportCandidate(text: $0, isOn: true) }
        showParsedPreview = true
        statusHint = candidates.isEmpty ? "解析完成，未识别出行动待办" : "解析完成，识别到 \(candidates.count) 条行动待办"
        Haptic.light()
    }

    private func importSelectedItems() {
        let selected = candidates.filter(\.isOn).map(\.text)
        guard !selected.isEmpty, let targetStage = stages.first(where: { $0.id == targetStageID }) else { return }
        for text in selected {
            let newTask = LifeEventTask(projectID: project.id, stageID: targetStageID, title: text)
            context.insert(newTask)
            if mirrorToHome {
                LifeEventHomeTodoMirror.insert(
                    actionText: text,
                    projectTitle: project.title,
                    stageTitle: targetStage.title,
                    taskID: newTask.id,
                    into: context
                )
            }
        }
        project.aiDecisionSummary = aiReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
        project.aiDecisionAt = .now
        try? context.save()
        Haptic.success()
        dismiss()
    }
}
