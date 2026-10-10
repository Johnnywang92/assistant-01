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

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var weatherAlerts = WeatherAlertService.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddTodo = false
    @State private var showVoice = false
    @State private var showDone = false
    @State private var showCompletedHistory = false
    @State private var showBackgroundSettings = false
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
            VStack(spacing: 0) {
                // 顶部固定横向分类 Tab 栏（带指示胶囊与角标）
                filterTabBar

                // 突发气象预警或气温骤降轻巧胶囊（若有则展示，支持手动划掉关闭）
                if let banner = weatherAlerts.currentBanner {
                    weatherAlertBanner(banner)
                }

                Divider()

                // 支持横向滑动的分页容器
                TabView(selection: $selectedFilter) {
                    ForEach(TodoFilterCategory.allCases) { category in
                        renderPageContent(for: category)
                            .tag(category)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemGroupedBackground))
            .themedAppBackground()
            .navigationTitle(assistantName.isEmpty ? "小助" : assistantName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showBackgroundSettings = true
                        Haptic.light()
                    } label: {
                        Image(systemName: "paintpalette")
                            .foregroundStyle(.tint)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showCompletedHistory = true
                        Haptic.light()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }

                    Button { showAddTodo = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddTodo) { AddTodoSheet() }
            .sheet(isPresented: $showVoice) { VoiceDialogueView() }
            .sheet(isPresented: $showCompletedHistory) { CompletedTodoHistoryView() }
            .sheet(isPresented: $showBackgroundSettings) {
                NavigationStack {
                    AppBackgroundSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showBackgroundSettings = false }
                            }
                        }
                }
            }
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
            .task {
                await weatherAlerts.checkAlertsIfNeeded()
            }
        }
    }

    // MARK: - 气象预警轻量胶囊卡片

    @ViewBuilder
    private func weatherAlertBanner(_ banner: WeatherAlertService.AlertBanner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: banner.icon)
                .font(.subheadline.bold())
                .foregroundStyle(banner.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(banner.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                weatherAlerts.dismissCurrentBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(banner.color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(banner.color.opacity(0.32), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
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

    // MARK: - 页面与顶部 Tab 栏组件

    @ViewBuilder
    private var filterTabBar: some View {
        HStack(spacing: 6) {
            ForEach(TodoFilterCategory.allCases) { category in
                let isSelected = selectedFilter == category
                let count = badgeCount(for: category)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        selectedFilter = category
                    }
                    Haptic.selection()
                } label: {
                    HStack(spacing: 4) {
                        Text(category.rawValue)
                            .font(.subheadline)
                            .fontWeight(isSelected ? .bold : .medium)

                        if count > 0 {
                            Text(count > 99 ? "99+" : "\(count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        isSelected
                                            ? Color.white.opacity(0.25)
                                            : badgeColor(for: category).opacity(0.16)
                                    )
                                )
                                .foregroundStyle(isSelected ? Color.white : badgeColor(for: category))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        ZStack {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor)
                                    .shadow(color: Color.accentColor.opacity(0.22), radius: 4, y: 2)
                            } else {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(bgManager.isCustomBackgroundActive ? Color(.secondarySystemBackground).opacity(0.7) : Color(.secondarySystemBackground))
                            }
                        }
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemBackground))
    }

    @ViewBuilder
    private func renderPageContent(for category: TodoFilterCategory) -> some View {
        List {
            // 顶部流量卡片（仅在全部页面，若有流量记录）
            if category == .all, let latest = usage.first {
                Section { DataUsageCard(record: latest) }
            }

            // 待确认事项（在全部和日常待办页面显示）
            if !review.isEmpty && (category == .all || category == .general) {
                Section("待确认（\(review.count)）") {
                    ForEach(review) { ReviewRow(item: $0) }
                }
            }

            // 分类具体列表
            switch category {
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

            // 已完成事项（显式可折叠卡片 + 归档入口）
            let currentDone = filteredDoneItems(for: category)
            if !currentDone.isEmpty {
                Section {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showDone.toggle()
                        }
                        Haptic.light()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)

                            Text("已完成事项")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            Text("\(currentDone.count)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                .foregroundStyle(.green)

                            Spacer()

                            Text(showDone ? "收起" : "展开查看")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Image(systemName: showDone ? "chevron.up" : "chevron.down")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showDone {
                        ForEach(currentDone.prefix(50)) { doneItem in
                            CompletedHistoryRow(item: doneItem)
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                context.delete(currentDone[idx])
                            }
                            try? context.save()
                        }

                        Button {
                            showCompletedHistory = true
                            Haptic.light()
                        } label: {
                            HStack {
                                Spacer()
                                Text("进入完整已完成归档大厅")
                                Image(systemName: "chevron.right")
                                Spacer()
                            }
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedRow()
    }

    private func badgeCount(for category: TodoFilterCategory) -> Int {
        switch category {
        case .all: return activeTodos.count
        case .general: return generals.count
        case .parcel: return parcels.count
        case .life: return medications.count + houseworks.count + chargings.count
        case .alert: return subscriptions.count + expiries.count + anniversaries.count + passwordTodos.count
        }
    }

    private func badgeColor(for category: TodoFilterCategory) -> Color {
        switch category {
        case .all: return .secondary
        case .general: return .blue
        case .parcel: return .orange
        case .life: return .green
        case .alert: return .red
        }
    }

    private func filteredDoneItems(for category: TodoFilterCategory) -> [TodoItem] {
        switch category {
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
    @State private var isCopied: Bool = false
    @State private var isAnimatingCompletion: Bool = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.0

    private var isEffectivelyDone: Bool {
        item.status == .done || isAnimatingCompletion
    }

    private var typeColor: Color {
        switch item.type {
        case .parcel: return .orange
        case .general, .event: return .blue
        case .medication: return .green
        case .housework: return .purple
        case .charging: return .yellow
        case .subscription, .bill: return .indigo
        case .itemExpiry: return .red
        case .anniversary: return .pink
        case .passwordSecurity: return .teal
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if item.status == .active {
                    // 1. 播放成功震动与波纹动效
                    Haptic.success()
                    isAnimatingCompletion = true
                    ringScale = 0.6
                    ringOpacity = 1.0
                    withAnimation(.easeOut(duration: 0.45)) {
                        ringScale = 2.0
                        ringOpacity = 0.0
                    }
                    // 2. 延迟 0.45 秒平滑移入已完成列表
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            item.status = .done
                            isAnimatingCompletion = false
                            ringScale = 0.5
                            ringOpacity = 0.0
                        }
                        try? context.save()
                    }
                } else {
                    // 反选/恢复为未完成
                    Haptic.medium()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        item.status = .active
                        isAnimatingCompletion = false
                    }
                    try? context.save()
                }
            } label: {
                ZStack {
                    // 绿色波纹动效光环
                    Circle()
                        .stroke(Color.green, lineWidth: 2)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                        .frame(width: 24, height: 24)

                    Image(systemName: isEffectivelyDone ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isEffectivelyDone ? Color.green : Color.secondary)
                        .scaleEffect(isAnimatingCompletion ? 1.25 : 1.0)
                        .animation(.spring(response: 0.28, dampingFraction: 0.5), value: isAnimatingCompletion)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                if item.type == .parcel, let code = item.pickupCode {
                    HStack(spacing: 8) {
                        Text(code)
                            .font(.title3.monospaced().bold())
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                            .strikethrough(isEffectivelyDone)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isEffectivelyDone ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.15))
                            )

                        Button {
                            UIPasteboard.general.string = code
                            Haptic.light()
                            withAnimation(.spring(duration: 0.2)) {
                                isCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                withAnimation { isCopied = false }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "已复制" : "复制")
                            }
                            .font(.caption2.bold())
                            .foregroundStyle(isCopied ? .green : .orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(isCopied ? Color.green.opacity(0.15) : Color.orange.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    let placeText: String? = {
                        if let loc = item.location, let st = item.station, !loc.contains(st) {
                            return "\(st) · \(loc)"
                        }
                        return item.location ?? item.station
                    }()
                    if let text = [item.courier, placeText].compactMap({ $0 }).joined(separator: " · ") as String?, !text.isEmpty {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(typeColor.opacity(isEffectivelyDone ? 0.08 : 0.16))
                                .frame(width: 24, height: 24)
                            Image(systemName: item.type.icon)
                                .font(.caption.bold())
                                .foregroundStyle(isEffectivelyDone ? .secondary : typeColor)
                        }

                        Text(item.title)
                            .font(.body.weight(isEffectivelyDone ? .regular : .medium))
                            .strikethrough(isEffectivelyDone)
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                    }

                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                    }
                }

                HStack(spacing: 12) {
                    if let due = item.dueAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text("截止: \(due.formatted(date: .numeric, time: .shortened))")
                        }
                        .font(.caption2)
                        .foregroundStyle(due < .now && !isEffectivelyDone ? Color.red : Color.secondary)
                    }

                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, item.type == .parcel ? 0 : 32)
            }
        }
        .opacity(isEffectivelyDone ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: isEffectivelyDone)
        .animation(.easeInOut(duration: 0.2), value: item.status)
        .padding(.vertical, 3)
        .contextMenu {
            if let code = item.pickupCode {
                Button("复制取件码", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = code
                    Haptic.light()
                }
            }
            if let src = item.sourceText {
                Button("复制原文", systemImage: "text.quote") {
                    UIPasteboard.general.string = src
                    Haptic.light()
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                Haptic.warning()
                context.delete(item)
                try? context.save()
            } label: { Label("删除", systemImage: "trash") }
        }
        .themedRow()
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
        .themedRow()
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
        .themedRow()
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
