import AssistantCore
import SwiftData
import SwiftUI

/// 技能学习路径列表：所有进行中的学习路径与进度概览
struct SkillPathListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SkillPath.startedAt, order: .reverse) private var paths: [SkillPath]

    @State private var showingCreateSheet = false
    @State private var progressMap: [UUID: SkillProgress] = [:]

    private var activePaths: [SkillPath] { paths.filter { $0.status == .active } }
    private var finishedPaths: [SkillPath] { paths.filter { $0.status != .active } }

    var body: some View {
        Group {
            if paths.isEmpty {
                emptyState
            } else {
                List {
                    if !activePaths.isEmpty {
                        Section("进行中") {
                            ForEach(activePaths) { path in
                                NavigationLink {
                                    SkillPathDetailView(path: path)
                                } label: {
                                    SkillPathRowCard(
                                        path: path,
                                        progress: progress(for: path)
                                    )
                                }
                            }
                        }
                    }

                    if !finishedPaths.isEmpty {
                        Section("已完成与已暂停") {
                            ForEach(finishedPaths) { path in
                                NavigationLink {
                                    SkillPathDetailView(path: path)
                                } label: {
                                    SkillPathRowCard(
                                        path: path,
                                        progress: progress(for: path)
                                    )
                                }
                            }
                        }
                    }

                    Section {
                        Text("学习路径把一项技能拆成四个阶段，先只展开当前阶段；通关后自动解锁下一阶段。练习打卡是重复待办，每天会提醒。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("学习路径")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建学习路径")
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            SkillPathCreateSheet()
        }
        .onAppear { reload() }
        .onChange(of: paths.count) { _, _ in reload() }
    }

    /// 先推进阶段，再一次性算出全部进度：避免列表每行各扫一次全表
    private func reload() {
        SkillPathManager.shared.refreshAll(context: context)
        progressMap = SkillPathManager.shared.progressByPath(context: context)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有学习路径")
                .font(.headline)
            Text("想学吉他、Python、英语或健身？说一句「我想学 Python，每天半小时」就能自动拆出分阶段的练习计划。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingCreateSheet = true
            } label: {
                Text("手动新建一条")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground))
    }

    private func progress(for path: SkillPath) -> SkillProgress {
        progressMap[path.id] ?? SkillPathManager.shared.progress(for: path, context: context)
    }
}

/// 列表中的一条路径卡片
struct SkillPathRowCard: View {
    let path: SkillPath
    let progress: SkillProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: path.category.icon)
                    .foregroundStyle(Color.accentColor)
                Text(path.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text(path.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress.overallRatio)
                .tint(path.status == .completed ? .green : .accentColor)

            HStack(spacing: 12) {
                Label("第 \(progress.stageIndex + 1) 阶段 · \(progress.stageName)", systemImage: "flag.fill")
                Spacer()
                if progress.streakDays > 0 {
                    Label("连续 \(progress.streakDays) 天", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text("本周 \(progress.minutesThisWeek)/\(progress.weeklyTargetMinutes) 分钟 · 打卡 \(progress.practiceCount) 次")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(path.title)，进度 \(Int(progress.overallRatio * 100))%，连续打卡 \(progress.streakDays) 天")
    }
}

/// 单条学习路径详情：阶段推进、当前阶段任务与打卡统计
struct SkillPathDetailView: View {
    @Environment(\.modelContext) private var context
    let path: SkillPath

    @Query private var stages: [SkillStage]
    @Query private var todos: [TodoItem]

    init(path: SkillPath) {
        self.path = path
        let pid = path.id
        _stages = Query(
            filter: #Predicate<SkillStage> { $0.pathID == pid },
            sort: [SortDescriptor(\.index, order: .forward)]
        )
        _todos = Query(
            filter: #Predicate<TodoItem> { $0.skillPathID == pid }
        )
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(path.goal)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        statItem(title: "每周目标", value: "\(path.weeklyMinutes) 分钟")
                        statItem(title: "预计周期", value: "\(path.totalWeeks) 周")
                        statItem(title: "已开始", value: "\(path.elapsedDays()) 天")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("目标")
            }

            Section("阶段") {
                ForEach(stages) { stage in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: stage.isCompleted ? "checkmark.circle.fill"
                              : (stage.isUnlocked ? "circle.dashed" : "lock.fill"))
                            .foregroundStyle(stage.isCompleted ? .green : (stage.isUnlocked ? Color.accentColor : .secondary))
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(stage.index + 1). \(stage.name)")
                                .font(.subheadline.bold())
                            Text(stage.acceptance)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(stage.isCompleted ? "已通关" : (stage.isUnlocked ? "进行中 · 计划 \(stage.plannedDays) 天" : "未解锁"))
                                .font(.caption2)
                                .foregroundStyle(stage.isCompleted ? .green : .secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("当前阶段任务") {
                let currentTodos = todos
                    .filter { $0.skillStageIndex == path.currentStageIndex }
                    .sorted { ($0.isSkillPractice ? 1 : 0, $0.sortOrder) < ($1.isSkillPractice ? 1 : 0, $1.sortOrder) }

                if currentTodos.isEmpty {
                    Text("当前阶段还没有任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentTodos) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                if item.status != .done {
                                    item.markAsCompleted(in: context)
                                    try? context.save()
                                    SkillPathManager.shared.refresh(path: path, context: context)
                                    // 同步桌面/锁屏「今日练习」快照：打卡后立刻反映「今日已打卡」与连续天数
                                    WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
                                    Haptic.success()
                                }
                            } label: {
                                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.status == .done ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.status == .done)
                            .accessibilityLabel(item.status == .done ? "已完成" : "标记为完成")

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .strikethrough(item.status == .done)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if item.isSkillPractice {
                                    Text("\(item.recurrenceSummaryText) · \(item.skillPracticeMinutes) 分钟")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else if let due = item.dueAt {
                                    Text(due, format: .dateTime.month().day())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                HStack(spacing: 12) {
                    statItem(title: "连续打卡", value: "\(path.practiceStreakDays) 天")
                    statItem(title: "累计打卡", value: "\(path.practiceCount) 次")
                    if let last = path.lastPracticedAt {
                        statItem(title: "最近一次", value: last.formatted(.dateTime.month().day()))
                    }
                }
            } header: {
                Text("练习记录")
            }
        }
        .navigationTitle(path.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            SkillPathManager.shared.refresh(path: path, context: context)
        }
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 手动新建学习路径
struct SkillPathCreateSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var skillName = ""
    @State private var category: SkillCategory = .programming
    @State private var weeklyMinutes = 150
    @State private var weeks = 12

    private var isValid: Bool {
        !skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("学什么") {
                    TextField("例如：Python、英语、马拉松", text: $skillName)
                    Picker("类别", selection: $category) {
                        ForEach(SkillCategory.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }

                Section("投入与周期") {
                    Stepper("每周 \(weeklyMinutes) 分钟", value: $weeklyMinutes, in: 30...1200, step: 30)
                    Stepper("预计 \(weeks) 周", value: $weeks, in: 2...104, step: 1)
                    Text("每周 150 分钟以内按每天打卡安排，超过则改为隔天一次，保证单次练习时长不低于 20 分钟。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("拆解预览")
                }
            }
            .navigationTitle("新建学习路径")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var previewText: String {
        guard isValid else { return "填写技能名后自动生成四阶段计划。" }
        let draft = SkillPathPlanner.build(
            skillName: skillName.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            weeklyMinutes: weeklyMinutes,
            weeks: weeks
        )
        let stageLine = draft.stages.map { "\($0.index + 1).\($0.name)(\($0.plannedDays)天)" }.joined(separator: " → ")
        return "\(draft.title)：\(stageLine)\n目标：\(draft.goal)"
    }

    private func create() {
        let name = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let draft = SkillPathPlanner.build(
            skillName: name,
            category: category,
            weeklyMinutes: weeklyMinutes,
            weeks: weeks
        )
        SkillPathManager.shared.save(draft: draft, context: context)
        // 新路径立即进入桌面/锁屏「今日练习」快照
        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        dismiss()
    }
}
