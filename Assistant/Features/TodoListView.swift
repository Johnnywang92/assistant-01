import AssistantCore
import SwiftData
import SwiftUI

enum TodoFilterCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case general = "待办"
    case parcel = "快递"
    case life = "生活"
    case alert = "预警"

    var id: String { rawValue }
}

struct TodoListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TodoItem.createdAt, order: .reverse) private var todos: [TodoItem]
    @Query(sort: \DataUsageRecord.recordedAt, order: .reverse) private var usage: [DataUsageRecord]

    @AppStorage("assistant_custom_name") private var assistantName: String = "助手"
    @ObservedObject private var router = NavigationRouter.shared
    @State private var showAddTodo = false
    @State private var showVoice = false
    @State private var showDone = false
    @State private var selectedFilter: TodoFilterCategory = .all

    private var activeTodos: [TodoItem] { todos.filter { $0.status == .active } }
    private var review: [TodoItem] { todos.filter { $0.status == .pendingReview } }
    private var done: [TodoItem] { todos.filter { $0.status == .done } }

    private var generals: [TodoItem] { activeTodos.filter { [.general, .event].contains($0.type) } }
    private var parcels: [TodoItem] { activeTodos.filter { $0.type == .parcel } }
    private var medications: [TodoItem] { activeTodos.filter { $0.type == .medication } }
    private var chargings: [TodoItem] { activeTodos.filter { $0.type == .charging } }
    private var houseworks: [TodoItem] { activeTodos.filter { $0.type == .housework } }
    private var subscriptions: [TodoItem] { activeTodos.filter { $0.type == .subscription || $0.type == .bill } }
    private var expiries: [TodoItem] { activeTodos.filter { $0.type == .itemExpiry } }
    private var anniversaries: [TodoItem] { activeTodos.filter { $0.type == .anniversary } }
    private var passwordTodos: [TodoItem] { activeTodos.filter { $0.type == .passwordSecurity } }
    private var otherActive: [TodoItem] {
        activeTodos.filter {
            ![.general, .event, .parcel, .medication, .charging, .housework, .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity].contains($0.type)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // 顶部流量卡片（如有）
                if let latest = usage.first {
                    Section { DataUsageCard(record: latest) }
                }

                // 顶部分类筛选器
                Section {
                    Picker("分类筛选", selection: $selectedFilter) {
                        ForEach(TodoFilterCategory.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))

                // 待确认事项
                if !review.isEmpty && (selectedFilter == .all || selectedFilter == .general) {
                    Section("待确认（\(review.count)）") {
                        ForEach(review) { ReviewRow(item: $0) }
                    }
                }

                // 动态分类展示
                switch selectedFilter {
                case .all:
                    renderAllSections()
                case .general:
                    renderGeneralSection()
                case .parcel:
                    renderParcelSection()
                case .life:
                    renderLifeSection()
                case .alert:
                    renderAlertSection()
                }

                // 已完成事项（可折叠）
                let currentDone = filteredDoneItems
                if !currentDone.isEmpty {
                    Section(isExpanded: $showDone) {
                        ForEach(currentDone.prefix(50)) { TodoRow(item: $0) }
                    } header: {
                        Text("已完成（\(currentDone.count)）")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(assistantName.isEmpty ? "助手" : assistantName)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showVoice = true } label: {
                        Image(systemName: "waveform.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    Button { showAddTodo = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddTodo) { AddTodoSheet() }
            .sheet(isPresented: $showVoice) { VoiceDialogueView() }
            .onChange(of: router.activeSheet) { _, newSheet in
                guard let newSheet else { return }
                switch newSheet {
                case .addTodo:
                    showAddTodo = true
                case .voice:
                    showVoice = true
                default:
                    break
                }
                router.activeSheet = nil
            }
            .onChange(of: router.requestedFilter) { _, filterName in
                guard let filterName else { return }
                if let cat = TodoFilterCategory.allCases.first(where: { $0.rawValue == filterName }) {
                    selectedFilter = cat
                }
                router.requestedFilter = nil
            }
            .overlay {
                if activeTodos.isEmpty && review.isEmpty && usage.isEmpty {
                    ContentUnavailableView {
                        Label("暂无待办事项", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("待办不仅支持快递，还涵盖日常日程、服药提醒、周期家务与防扣款预警。\n点击右上角 ➕ 快速添加。")
                    } actions: {
                        Button {
                            showAddTodo = true
                        } label: {
                            Label("新建待办", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: - 分类渲染器

    @ViewBuilder
    private func renderAllSections() -> some View {
        if !generals.isEmpty {
            Section("📋 日常待办（\(generals.count)）") {
                ForEach(generals) { TodoRow(item: $0) }
            }
        }
        if !parcels.isEmpty {
            Section("📦 待取快递（\(parcels.count)）") {
                ForEach(parcels) { TodoRow(item: $0) }
            }
        }
        if !medications.isEmpty {
            Section("💊 服药提醒（\(medications.count)）") {
                ForEach(medications) { TodoRow(item: $0) }
            }
        }
        if !chargings.isEmpty {
            Section("⚡️ 设备充电预警（\(chargings.count)）") {
                ForEach(chargings) { TodoRow(item: $0) }
            }
        }
        if !houseworks.isEmpty {
            Section("🧹 周期家务（\(houseworks.count)）") {
                ForEach(houseworks) { TodoRow(item: $0) }
            }
        }
        if !subscriptions.isEmpty {
            Section("💳 续费与账单（\(subscriptions.count)）") {
                ForEach(subscriptions) { TodoRow(item: $0) }
            }
        }
        if !expiries.isEmpty {
            Section("⚠️ 证件/物品临期（\(expiries.count)）") {
                ForEach(expiries) { TodoRow(item: $0) }
            }
        }
        if !anniversaries.isEmpty {
            Section("🎁 纪念日（\(anniversaries.count)）") {
                ForEach(anniversaries) { TodoRow(item: $0) }
            }
        }
        if !passwordTodos.isEmpty {
            Section("🔑 密码安全（\(passwordTodos.count)）") {
                ForEach(passwordTodos) { TodoRow(item: $0) }
            }
        }
        if !otherActive.isEmpty {
            Section("其它事项（\(otherActive.count)）") {
                ForEach(otherActive) { TodoRow(item: $0) }
            }
        }
    }

    @ViewBuilder
    private func renderGeneralSection() -> some View {
        Section(generals.isEmpty ? "日常待办" : "日常待办（\(generals.count)）") {
            if generals.isEmpty {
                Text("暂无日常待办，点击右上角 ➕ 即可快速添加。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(generals) { TodoRow(item: $0) }
            }
        }
    }

    @ViewBuilder
    private func renderParcelSection() -> some View {
        Section(parcels.isEmpty ? "待取快递" : "待取快递（\(parcels.count)）") {
            if parcels.isEmpty {
                Text("暂无待取快递").foregroundStyle(.secondary)
            } else {
                ForEach(parcels) { TodoRow(item: $0) }
            }
        }
    }

    @ViewBuilder
    private func renderLifeSection() -> some View {
        let count = medications.count + houseworks.count + chargings.count
        if count == 0 {
            Section("生活与健康") {
                Text("暂无生活提醒（服药、家务或充电预警）").foregroundStyle(.secondary)
            }
        } else {
            if !medications.isEmpty {
                Section("💊 服药提醒（\(medications.count)）") {
                    ForEach(medications) { TodoRow(item: $0) }
                }
            }
            if !houseworks.isEmpty {
                Section("🧹 周期家务（\(houseworks.count)）") {
                    ForEach(houseworks) { TodoRow(item: $0) }
                }
            }
            if !chargings.isEmpty {
                Section("⚡️ 设备充电预警（\(chargings.count)）") {
                    ForEach(chargings) { TodoRow(item: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private func renderAlertSection() -> some View {
        let count = subscriptions.count + expiries.count + anniversaries.count + passwordTodos.count
        if count == 0 {
            Section("提醒与预警") {
                Text("暂无预警事项（自动续费、物品临期或密码轮换）").foregroundStyle(.secondary)
            }
        } else {
            if !subscriptions.isEmpty {
                Section("💳 自动续费与账单（\(subscriptions.count)）") {
                    ForEach(subscriptions) { TodoRow(item: $0) }
                }
            }
            if !expiries.isEmpty {
                Section("⚠️ 证件/物品临期（\(expiries.count)）") {
                    ForEach(expiries) { TodoRow(item: $0) }
                }
            }
            if !anniversaries.isEmpty {
                Section("🎁 纪念日（\(anniversaries.count)）") {
                    ForEach(anniversaries) { TodoRow(item: $0) }
                }
            }
            if !passwordTodos.isEmpty {
                Section("🔑 密码安全（\(passwordTodos.count)）") {
                    ForEach(passwordTodos) { TodoRow(item: $0) }
                }
            }
        }
    }

    private var filteredDoneItems: [TodoItem] {
        switch selectedFilter {
        case .all:
            return done
        case .general:
            return done.filter { [.general, .event].contains($0.type) }
        case .parcel:
            return done.filter { $0.type == .parcel }
        case .life:
            return done.filter { [.medication, .housework, .charging].contains($0.type) }
        case .alert:
            return done.filter { [.subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity].contains($0.type) }
        }
    }
}

struct TodoRow: View {
    @Environment(\.modelContext) private var context
    let item: TodoItem

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { item.status = item.status == .done ? .active : .done }
                try? context.save()
            } label: {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.status == .done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                if item.type == .parcel, let code = item.pickupCode {
                    Text(code)
                        .font(.title3.monospaced().bold())
                        .strikethrough(item.status == .done)
                    let placeText: String? = {
                        if let loc = item.location, let st = item.station, !loc.contains(st) {
                            return "\(st) · \(loc)"
                        }
                        return item.location ?? item.station
                    }()
                    Text([item.courier, placeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label(item.title, systemImage: item.type.icon)
                        .strikethrough(item.status == .done)
                    if let detail = item.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let due = item.dueAt {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.clock")
                        Text("截止: \(due.formatted(date: .numeric, time: .shortened))")
                    }
                    .font(.caption2)
                    .foregroundStyle(due < .now && item.status != .done ? Color.red : Color.secondary)
                }
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            if let code = item.pickupCode {
                Button("复制取件码", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }
            }
            if let src = item.sourceText {
                Button("复制原文", systemImage: "text.quote") { UIPasteboard.general.string = src }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                context.delete(item)
                try? context.save()
            } label: { Label("删除", systemImage: "trash") }
        }
    }
}

struct ReviewRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: TodoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("标题", text: $item.title, axis: .vertical)
                .font(.body)
            if let src = item.sourceText, src != item.title {
                Text(src).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Button("加入待办") {
                    item.status = .active
                    try? context.save()
                }
                .buttonStyle(.borderedProminent)
                Button("忽略", role: .destructive) {
                    context.delete(item)
                    try? context.save()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct DataUsageCard: View {
    let record: DataUsageRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(record.operatorName ?? "流量", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text(record.recordedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let remain = record.remainingMB {
                Text("剩余 \(TodoFormatter.formatMB(remain))")
                    .font(.title2.bold())
            }
            if let p = percent {
                ProgressView(value: min(p, 100), total: 100)
                    .tint(p >= 90 ? .red : p >= 70 ? .orange : .green)
                Text(String(format: "已使用 %.0f%%", p)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var percent: Double? {
        if let p = record.usedPercent { return p }
        if let u = record.usedMB, let r = record.remainingMB, u + r > 0 { return u / (u + r) * 100 }
        return nil
    }
}

// MARK: - 新建待办 / 智能导入弹窗

struct AddTodoSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Int = 0 // 0: 手动新建, 1: 智能识别导入

    // 手动新建表单
    @State private var title: String = ""
    @State private var type: TodoType = .general
    @State private var detail: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
    @State private var pickupCode: String = ""

    // 智能识别文本
    @State private var importText: String = ""
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("添加模式", selection: $tab) {
                        Text("手动新建").tag(0)
                        Text("短信/文本智能导入").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))

                if tab == 0 {
                    Section("待办内容") {
                        TextField("待办名称（如：去超市买牛奶、下午团队开会）", text: $title)

                        Picker("分类类型", selection: $type) {
                            ForEach([TodoType.general, .parcel, .medication, .housework, .charging, .subscription, .itemExpiry, .anniversary, .bill, .event], id: \.self) { t in
                                Label(t.displayName, systemImage: t.icon).tag(t)
                            }
                        }

                        if type == .parcel {
                            TextField("取件码（选填，如：3-2-104）", text: $pickupCode)
                        }
                    }

                    Section("详情与提醒时间") {
                        TextField("补充备注/详情说明（选填）", text: $detail, axis: .vertical)
                            .lineLimit(2...4)

                        Toggle("设置提醒时间", isOn: $hasDueDate)
                        if hasDueDate {
                            DatePicker("截止时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                } else {
                    Section {
                        TextEditor(text: $importText)
                            .frame(minHeight: 140)
                    } header: {
                        Text("粘贴短信或聊天文本")
                    } footer: {
                        Text("系统将自动识别取件码、驿站、话费流量、信用卡账单并自动建档。可一次粘贴多条，用换行隔开。")
                    }

                    if let importResult {
                        Section("解析结果") {
                            Text(importResult)
                        }
                    }
                }
            }
            .navigationTitle(tab == 0 ? "新建待办" : "智能导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if tab == 0 {
                            createTodo()
                        } else {
                            runImport()
                        }
                    }
                    .disabled(tab == 0 ? title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if tab == 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                            importText = UIPasteboard.general.string ?? ""
                        }
                    }
                }
            }
        }
    }

    private func createTodo() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)

        let item = TodoItem(
            type: type,
            status: .active,
            title: trimmedTitle,
            detail: trimmedDetail.isEmpty ? nil : trimmedDetail,
            pickupCode: trimmedCode.isEmpty ? nil : trimmedCode,
            dueAt: hasDueDate ? dueDate : nil
        )
        context.insert(item)
        try? context.save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private func runImport() {
        let service = ImportService(context: context)
        let chunks = importText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var lines: [String] = []
        for chunk in chunks {
            do {
                lines.append(try service.ingest(chunk, source: "manual").summary)
            } catch {
                lines.append("失败：\(error.localizedDescription)")
            }
        }
        importResult = lines.joined(separator: "\n")
        importText = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }
}
