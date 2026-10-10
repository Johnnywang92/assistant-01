import AssistantCore
import SwiftData
import SwiftUI

enum TodoFilterCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case general = "待办"
    case recurring = "周期"
    case parcel = "快递"
    case life = "生活"
    case alert = "预警"

    var id: String { rawValue }
}

/// 待办单次 O(N) 极速分类存储，避免视图每次刷新时连续发起十余次全量数组 filter
fileprivate struct TodoClassification {
    var active: [TodoItem] = []
    var review: [TodoItem] = []
    var done: [TodoItem] = []
    var recurring: [TodoItem] = []

    var generals: [TodoItem] = []
    var parcels: [TodoItem] = []
    var returnParcels: [TodoItem] = []
    var medications: [TodoItem] = []
    var chargings: [TodoItem] = []
    var houseworks: [TodoItem] = []
    var subscriptions: [TodoItem] = []
    var expiries: [TodoItem] = []
    var anniversaries: [TodoItem] = []
    var passwordTodos: [TodoItem] = []
    var vehicleTodos: [TodoItem] = []
    var others: [TodoItem] = []

    var doneGenerals: [TodoItem] = []
    var doneRecurring: [TodoItem] = []
    var doneParcels: [TodoItem] = []
    var doneLife: [TodoItem] = []
    var doneAlerts: [TodoItem] = []

    init(from items: [TodoItem]) {
        for item in items {
            switch item.status {
            case .pendingReview:
                review.append(item)
            case .done:
                done.append(item)
                if item.isRecurring { doneRecurring.append(item) }
                switch item.type {
                case .general, .event: doneGenerals.append(item)
                case .parcel, .returnParcel: doneParcels.append(item)
                case .medication, .housework, .charging: doneLife.append(item)
                case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare: doneAlerts.append(item)
                default: break
                }
            case .active:
                active.append(item)
                if item.isRecurring { recurring.append(item) }
                switch item.type {
                case .general, .event: generals.append(item)
                case .parcel: parcels.append(item)
                case .returnParcel: returnParcels.append(item)
                case .medication: medications.append(item)
                case .charging: chargings.append(item)
                case .housework: houseworks.append(item)
                case .subscription, .bill: subscriptions.append(item)
                case .itemExpiry: expiries.append(item)
                case .anniversary: anniversaries.append(item)
                case .passwordSecurity: passwordTodos.append(item)
                case .vehicleCare: vehicleTodos.append(item)
                default: others.append(item)
                }
            }
        }
    }
}

struct TodoListView: View {
    @Environment(\.modelContext) private var context
    @Query(
        sort: [
            SortDescriptor(\TodoItem.sortOrder, order: .forward),
            SortDescriptor(\TodoItem.createdAt, order: .reverse)
        ]
    ) private var todos: [TodoItem]

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("all_tab_grouping_mode") private var isGroupedByType: Bool = false
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var weatherAlerts = WeatherAlertService.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @ObservedObject private var anniversaryReminder = AnniversaryReminderManager.shared
    @State private var showAddTodo = false
    @State private var showVoice = false
    @State private var showDone = false
    @State private var showCompletedHistory = false
    @State private var showPeriodicReport = false
    @State private var showBackgroundSettings = false
    @State private var showSeniorSettings = false
    @State private var selectedFilter: TodoFilterCategory = .all
    @State private var showShareSheet = false
    @State private var itemToShare: TodoItem? = nil
    @State private var prepToastMessage: String? = nil
    @State private var isReordering: Bool = false

    // MARK: - 单次 O(N) 极速分类缓存（彻底消除视图树重复全表遍历）
    private var classified: TodoClassification {
        TodoClassification(from: todos)
    }

    private var activeTodos: [TodoItem] { classified.active }
    private var review: [TodoItem] { classified.review }
    private var done: [TodoItem] { classified.done }
    private var recurring: [TodoItem] { classified.recurring }

    private var generals: [TodoItem] { classified.generals }
    private var parcels: [TodoItem] { classified.parcels }
    private var returnParcels: [TodoItem] { classified.returnParcels }
    private var medications: [TodoItem] { classified.medications }
    private var chargings: [TodoItem] { classified.chargings }
    private var houseworks: [TodoItem] { classified.houseworks }
    private var subscriptions: [TodoItem] { classified.subscriptions }
    private var expiries: [TodoItem] { classified.expiries }
    private var anniversaries: [TodoItem] { classified.anniversaries }
    private var passwordTodos: [TodoItem] { classified.passwordTodos }
    private var vehicleTodos: [TodoItem] { classified.vehicleTodos }
    private var otherActive: [TodoItem] { classified.others }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部固定横向分类 Tab 栏（带指示胶囊与角标）
                filterTabBar

                // 上下滑动排序模式开启提示横幅
                if isReordering {
                    reorderingActiveBanner
                }

                // 长辈关怀大字模式顶部状态微胶囊（支持一键调整字号）
                if seniorManager.isSeniorModeEnabled {
                    seniorModeActiveBanner
                }

                // 突发气象预警或气温骤降轻巧胶囊（若有则展示，支持手动划掉关闭）
                if let banner = weatherAlerts.currentBanner {
                    weatherAlertBanner(banner)
                }

                // 临近 5~7 天纪念日浪漫筹备备忘横幅（支持一键加入待办与不再提醒）
                if let upcoming = anniversaryReminder.activeUpcoming {
                    anniversaryPrepBanner(upcoming)
                }

                Divider()
                    .opacity(bgManager.isCustomBackgroundActive ? 0.35 : 1.0)

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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isReordering {
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                isReordering = false
                            }
                            Haptic.medium()
                        } label: {
                            Text("完成")
                                .font(.headline.bold())
                                .foregroundStyle(.tint)
                        }
                    } else {
                        Menu {
                            Button {
                                router.activeSheet = .qrScanner
                                Haptic.light()
                            } label: {
                                Label("扫码导入", systemImage: "qrcode.viewfinder")
                            }

                            Button {
                                showShareSheet = true
                                Haptic.light()
                            } label: {
                                Label("分享待办清单", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                showCompletedHistory = true
                                Haptic.light()
                            } label: {
                                Label("已完成历史记录", systemImage: "clock.arrow.circlepath")
                            }

                            Button {
                                showPeriodicReport = true
                                Haptic.light()
                            } label: {
                                Label("日报 · 周报 · 月报", systemImage: "chart.bar.doc.horizontal")
                            }

                            Divider()

                            Button {
                                showBackgroundSettings = true
                                Haptic.light()
                            } label: {
                                Label("更换背景与主题", systemImage: "paintpalette")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                        }
                        .accessibilityLabel("更多功能")

                        Button {
                            showAddTodo = true
                            Haptic.light()
                        } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("新建待办")
                    }
                }
            }
            .sheet(isPresented: $showAddTodo) {
                AddTodoSheet(initialCategory: selectedFilter)
            }
            .sheet(isPresented: $showVoice) { VoiceDialogueView() }
            .sheet(isPresented: $showCompletedHistory) { CompletedTodoHistoryView() }
            .sheet(isPresented: $showPeriodicReport) { PeriodicReportView() }
            .sheet(isPresented: $showShareSheet) {
                TodoShareSheet(
                    allTodos: todos,
                    initialCategory: selectedFilter
                )
            }
            .sheet(item: $itemToShare) { item in
                TodoShareSheet(
                    allTodos: [item],
                    initialCategory: item.type == .parcel ? .parcel : .all,
                    initialSelectedIds: [item.id]
                )
            }
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
            .sheet(isPresented: $showSeniorSettings) {
                NavigationStack {
                    SeniorModeSettingsView()
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
                if activeTodos.isEmpty && review.isEmpty && done.isEmpty {
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
                anniversaryReminder.refreshActiveUpcoming(context: context)
            }
            .onAppear {
                anniversaryReminder.refreshActiveUpcoming(context: context)
            }
            .onChange(of: todos) { _, _ in
                anniversaryReminder.refreshActiveUpcoming(context: context)
            }
            .overlay(alignment: .bottom) {
                if let toast = prepToastMessage {
                    Text(toast)
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - 上下滑动调整顺序核心逻辑

    private func reorder(items: [TodoItem], fromOffsets: IndexSet, toOffset: Int) {
        var mutable = items
        mutable.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, item) in mutable.enumerated() {
            item.sortOrder = index
        }
        try? context.save()
        Haptic.light()
    }

    private func moveItemToTop(_ item: TodoItem, within items: [TodoItem]) {
        var mutable = items
        if let idx = mutable.firstIndex(where: { $0.id == item.id }) {
            mutable.remove(at: idx)
            mutable.insert(item, at: 0)
            for (index, todo) in mutable.enumerated() {
                todo.sortOrder = index
            }
            try? context.save()
            Haptic.success()
        }
    }

    private func moveItemUp(_ item: TodoItem, within items: [TodoItem]) {
        var mutable = items
        guard let idx = mutable.firstIndex(where: { $0.id == item.id }), idx > 0 else { return }
        mutable.swapAt(idx, idx - 1)
        for (index, todo) in mutable.enumerated() {
            todo.sortOrder = index
        }
        try? context.save()
        Haptic.selection()
    }

    private func moveItemDown(_ item: TodoItem, within items: [TodoItem]) {
        var mutable = items
        guard let idx = mutable.firstIndex(where: { $0.id == item.id }), idx < mutable.count - 1 else { return }
        mutable.swapAt(idx, idx + 1)
        for (index, todo) in mutable.enumerated() {
            todo.sortOrder = index
        }
        try? context.save()
        Haptic.selection()
    }

    // MARK: - 排序调整模式顶栏提示胶囊
    @ViewBuilder
    private var reorderingActiveBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.tint)

            Text("滑动排序中：按住右侧三条杠 ≡ 即可上下拖动")
                .font(.caption.bold())
                .foregroundStyle(.primary)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    isReordering = false
                }
                Haptic.medium()
            } label: {
                Text("完成")
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - 长辈关怀模式顶栏胶囊
    @ViewBuilder
    private var seniorModeActiveBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk.motion")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            Text("长辈关怀大字模式")
                .font(.caption.bold())
                .foregroundStyle(.orange)

            Text("(\(seniorManager.fontScale.title))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showSeniorSettings = true
                Haptic.light()
            } label: {
                HStack(spacing: 4) {
                    Text("调整字号")
                    Image(systemName: "textformat.size")
                }
                .font(.caption2.bold())
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
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
    }

    // MARK: - 临近纪念日筹备卡片（鲜花/蛋糕/餐厅一键加入与不再提醒）

    @ViewBuilder
    private func anniversaryPrepBanner(_ upcoming: UpcomingAnniversaryInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.title3)
                        .foregroundStyle(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("临近纪念日筹备")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            Text(upcoming.daysUntil == 0 ? "就在今天!" : "还有 \(upcoming.daysUntil) 天")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.pink.opacity(0.18)))
                                .foregroundStyle(.pink)
                        }

                        Text("「\(upcoming.title)」即将到来，提前备好惊喜让浪漫不留遗憾。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 不再提醒按钮（点击后本年度该纪念日不再重复弹出）
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        anniversaryReminder.dismiss(for: upcoming)
                        showToast("已设置本周期不再提醒该纪念日")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bell.slash")
                            .font(.caption2)
                        Text("不再提醒")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 鲜花、蛋糕、餐厅三合一筹备推荐
            HStack(spacing: 6) {
                Label("💐 备鲜花", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.pink.opacity(0.08)))
                    .foregroundStyle(.pink)

                Label("🎂 订蛋糕", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
                    .foregroundStyle(.orange)

                Label("🍽️ 订餐厅", systemImage: "sparkles")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
                    .foregroundStyle(.purple)

                Spacer()
            }

            // 一键加入待办事项
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    anniversaryReminder.addPreparationTodos(for: upcoming, in: context)
                    showToast("已一键将准备鲜花、订蛋糕与订餐厅加入待办！🎉")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("一键将鲜花/蛋糕/餐厅加入待办")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [Color.pink, Color(red: 0.95, green: 0.35, blue: 0.55)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.pink.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.pink.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring(duration: 0.25)) {
            prepToastMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                prepToastMessage = nil
            }
        }
    }

    // MARK: - 分类渲染器

    @ViewBuilder
    private func renderAllSections() -> some View {
        if activeTodos.isEmpty {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前待办已全部搞定！")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text("暂无未完成事项，可点击下方查看已完成明细，或点击右上角 ➕ 快速添加。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .themedRow()
        } else {
            // 自由排序流 vs 板块分组切换小药丸
            Section {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: isGroupedByType ? "square.grid.2x2.fill" : "list.number")
                            .font(.caption2)
                        Text(isGroupedByType ? "当前为板块分组展示" : "当前为全局自由排序流")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isGroupedByType.toggle()
                        }
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 4) {
                            Text(isGroupedByType ? "切换为自由排序流" : "按板块分类")
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))

            if !isGroupedByType {
                // 自由排序流：所有待办在一个连续列表中，支持任意事项跨类型上下拖动！
                Section("事项清单（\(activeTodos.count)）") {
                    ForEach(activeTodos) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: activeTodos) },
                            onMoveUp: { moveItemUp(item, within: activeTodos) },
                            onMoveDown: { moveItemDown(item, within: activeTodos) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in
                        reorder(items: activeTodos, fromOffsets: from, toOffset: to)
                    }
                }
            } else {
                renderGroupedAllSections()
            }
        }
    }

    @ViewBuilder
    private func renderGroupedAllSections() -> some View {
        if !generals.isEmpty {
            Section("📋 日常待办（\(generals.count)）") {
                ForEach(generals) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: generals) },
                        onMoveUp: { moveItemUp(item, within: generals) },
                        onMoveDown: { moveItemDown(item, within: generals) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: generals, fromOffsets: from, toOffset: to) }
            }
        }
        if !parcels.isEmpty {
            Section("📦 待取快递（\(parcels.count)）") {
                ForEach(parcels) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: parcels) },
                        onMoveUp: { moveItemUp(item, within: parcels) },
                        onMoveDown: { moveItemDown(item, within: parcels) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: parcels, fromOffsets: from, toOffset: to) }
            }
        }
        if !returnParcels.isEmpty {
            Section("↩️ 待退货寄件（\(returnParcels.count)）") {
                ForEach(returnParcels) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: returnParcels) },
                        onMoveUp: { moveItemUp(item, within: returnParcels) },
                        onMoveDown: { moveItemDown(item, within: returnParcels) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: returnParcels, fromOffsets: from, toOffset: to) }
            }
        }
        if !medications.isEmpty {
            Section("💊 服药提醒（\(medications.count)）") {
                ForEach(medications) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: medications) },
                        onMoveUp: { moveItemUp(item, within: medications) },
                        onMoveDown: { moveItemDown(item, within: medications) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: medications, fromOffsets: from, toOffset: to) }
            }
        }
        if !chargings.isEmpty {
            Section("⚡️ 设备充电预警（\(chargings.count)）") {
                ForEach(chargings) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: chargings) },
                        onMoveUp: { moveItemUp(item, within: chargings) },
                        onMoveDown: { moveItemDown(item, within: chargings) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: chargings, fromOffsets: from, toOffset: to) }
            }
        }
        if !houseworks.isEmpty {
            Section("🧹 周期家务（\(houseworks.count)）") {
                ForEach(houseworks) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: houseworks) },
                        onMoveUp: { moveItemUp(item, within: houseworks) },
                        onMoveDown: { moveItemDown(item, within: houseworks) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: houseworks, fromOffsets: from, toOffset: to) }
            }
        }
        if !subscriptions.isEmpty {
            Section("💳 续费与账单（\(subscriptions.count)）") {
                ForEach(subscriptions) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: subscriptions) },
                        onMoveUp: { moveItemUp(item, within: subscriptions) },
                        onMoveDown: { moveItemDown(item, within: subscriptions) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: subscriptions, fromOffsets: from, toOffset: to) }
            }
        }
        if !expiries.isEmpty {
            Section("⚠️ 证件/物品临期（\(expiries.count)）") {
                ForEach(expiries) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: expiries) },
                        onMoveUp: { moveItemUp(item, within: expiries) },
                        onMoveDown: { moveItemDown(item, within: expiries) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: expiries, fromOffsets: from, toOffset: to) }
            }
        }
        if !anniversaries.isEmpty {
            Section("🎁 纪念日（\(anniversaries.count)）") {
                ForEach(anniversaries) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: anniversaries) },
                        onMoveUp: { moveItemUp(item, within: anniversaries) },
                        onMoveDown: { moveItemDown(item, within: anniversaries) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: anniversaries, fromOffsets: from, toOffset: to) }
            }
        }
        if !passwordTodos.isEmpty {
            Section("🔑 密码安全（\(passwordTodos.count)）") {
                ForEach(passwordTodos) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: passwordTodos) },
                        onMoveUp: { moveItemUp(item, within: passwordTodos) },
                        onMoveDown: { moveItemDown(item, within: passwordTodos) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: passwordTodos, fromOffsets: from, toOffset: to) }
            }
        }
        if !vehicleTodos.isEmpty {
            Section("🚗 爱车守护（\(vehicleTodos.count)）") {
                ForEach(vehicleTodos) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: vehicleTodos) },
                        onMoveUp: { moveItemUp(item, within: vehicleTodos) },
                        onMoveDown: { moveItemDown(item, within: vehicleTodos) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: vehicleTodos, fromOffsets: from, toOffset: to) }
            }
        }
        if !otherActive.isEmpty {
            Section("其它事项（\(otherActive.count)）") {
                ForEach(otherActive) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: otherActive) },
                        onMoveUp: { moveItemUp(item, within: otherActive) },
                        onMoveDown: { moveItemDown(item, within: otherActive) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: otherActive, fromOffsets: from, toOffset: to) }
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
                ForEach(generals) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: generals) },
                        onMoveUp: { moveItemUp(item, within: generals) },
                        onMoveDown: { moveItemDown(item, within: generals) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: generals, fromOffsets: from, toOffset: to) }
            }
        }
    }

    @ViewBuilder
    private func renderRecurringSection() -> some View {
        if recurring.isEmpty {
            Section("周期性待办") {
                VStack(spacing: 8) {
                    Image(systemName: "repeat.circle")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                    Text("暂无周期重复事项")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("可在新建或编辑待办时，设置每天、隔天、每3天或每周等重复周期。\n待办完成后将自动生成下一期事项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        } else {
            Section("🔁 周期性待办（\(recurring.count)）") {
                ForEach(recurring) { item in
                    TodoRow(
                        item: item,
                        onMoveToTop: { moveItemToTop(item, within: recurring) },
                        onMoveUp: { moveItemUp(item, within: recurring) },
                        onMoveDown: { moveItemDown(item, within: recurring) },
                        onEnterReorder: { withAnimation { isReordering = true } }
                    )
                }
                .onMove { from, to in reorder(items: recurring, fromOffsets: from, toOffset: to) }
            }
        }
    }

    @ViewBuilder
    private func renderParcelSection() -> some View {
        let totalCount = parcels.count + returnParcels.count
        if totalCount == 0 {
            Section("快递与退货") {
                Text("暂无待取快递或待退货事项，点击右上角 ➕ 可快速添加。")
                    .foregroundStyle(.secondary)
            }
        } else {
            if !parcels.isEmpty {
                Section("📦 待取快递（\(parcels.count)）") {
                    ForEach(parcels) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: parcels) },
                            onMoveUp: { moveItemUp(item, within: parcels) },
                            onMoveDown: { moveItemDown(item, within: parcels) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: parcels, fromOffsets: from, toOffset: to) }
                }
            }
            if !returnParcels.isEmpty {
                Section("↩️ 待退货寄件（\(returnParcels.count)）") {
                    ForEach(returnParcels) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: returnParcels) },
                            onMoveUp: { moveItemUp(item, within: returnParcels) },
                            onMoveDown: { moveItemDown(item, within: returnParcels) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: returnParcels, fromOffsets: from, toOffset: to) }
                }
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
                    ForEach(medications) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: medications) },
                            onMoveUp: { moveItemUp(item, within: medications) },
                            onMoveDown: { moveItemDown(item, within: medications) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: medications, fromOffsets: from, toOffset: to) }
                }
            }
            if !houseworks.isEmpty {
                Section("🧹 周期家务（\(houseworks.count)）") {
                    ForEach(houseworks) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: houseworks) },
                            onMoveUp: { moveItemUp(item, within: houseworks) },
                            onMoveDown: { moveItemDown(item, within: houseworks) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: houseworks, fromOffsets: from, toOffset: to) }
                }
            }
            if !chargings.isEmpty {
                Section("⚡️ 设备充电预警（\(chargings.count)）") {
                    ForEach(chargings) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: chargings) },
                            onMoveUp: { moveItemUp(item, within: chargings) },
                            onMoveDown: { moveItemDown(item, within: chargings) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: chargings, fromOffsets: from, toOffset: to) }
                }
            }
        }
    }

    @ViewBuilder
    private func renderAlertSection() -> some View {
        let count = subscriptions.count + expiries.count + anniversaries.count + passwordTodos.count + vehicleTodos.count
        if count == 0 {
            Section("提醒与预警") {
                Text("暂无预警事项（爱车守护、自动续费、物品临期或密码轮换）").foregroundStyle(.secondary)
            }
        } else {
            if !vehicleTodos.isEmpty {
                Section("🚗 爱车守护（\(vehicleTodos.count)）") {
                    ForEach(vehicleTodos) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: vehicleTodos) },
                            onMoveUp: { moveItemUp(item, within: vehicleTodos) },
                            onMoveDown: { moveItemDown(item, within: vehicleTodos) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: vehicleTodos, fromOffsets: from, toOffset: to) }
                }
            }
            if !subscriptions.isEmpty {
                Section("💳 自动续费与账单（\(subscriptions.count)）") {
                    ForEach(subscriptions) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: subscriptions) },
                            onMoveUp: { moveItemUp(item, within: subscriptions) },
                            onMoveDown: { moveItemDown(item, within: subscriptions) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: subscriptions, fromOffsets: from, toOffset: to) }
                }
            }
            if !expiries.isEmpty {
                Section("⚠️ 证件/物品临期（\(expiries.count)）") {
                    ForEach(expiries) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: expiries) },
                            onMoveUp: { moveItemUp(item, within: expiries) },
                            onMoveDown: { moveItemDown(item, within: expiries) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: expiries, fromOffsets: from, toOffset: to) }
                }
            }
            if !anniversaries.isEmpty {
                Section("🎁 纪念日（\(anniversaries.count)）") {
                    ForEach(anniversaries) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: anniversaries) },
                            onMoveUp: { moveItemUp(item, within: anniversaries) },
                            onMoveDown: { moveItemDown(item, within: anniversaries) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: anniversaries, fromOffsets: from, toOffset: to) }
                }
            }
            if !passwordTodos.isEmpty {
                Section("🔑 密码安全（\(passwordTodos.count)）") {
                    ForEach(passwordTodos) { item in
                        TodoRow(
                            item: item,
                            onMoveToTop: { moveItemToTop(item, within: passwordTodos) },
                            onMoveUp: { moveItemUp(item, within: passwordTodos) },
                            onMoveDown: { moveItemDown(item, within: passwordTodos) },
                            onEnterReorder: { withAnimation { isReordering = true } }
                        )
                    }
                    .onMove { from, to in reorder(items: passwordTodos, fromOffsets: from, toOffset: to) }
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
            case .recurring:
                renderRecurringSection()
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
        .background(Color.clear)
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        .themedRow()
    }

    private func badgeCount(for category: TodoFilterCategory) -> Int {
        switch category {
        case .all: return activeTodos.count
        case .general: return generals.count
        case .recurring: return recurring.count
        case .parcel: return parcels.count + returnParcels.count
        case .life: return medications.count + houseworks.count + chargings.count
        case .alert: return subscriptions.count + expiries.count + anniversaries.count + passwordTodos.count + vehicleTodos.count
        }
    }

    private func badgeColor(for category: TodoFilterCategory) -> Color {
        switch category {
        case .all: return .secondary
        case .general: return .blue
        case .recurring: return .indigo
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
        case .recurring:
            return classified.doneRecurring
        case .parcel:
            return done.filter { [.parcel, .returnParcel].contains($0.type) }
        case .life:
            return done.filter { [.medication, .housework, .charging].contains($0.type) }
        case .alert:
            return done.filter { [.subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare].contains($0.type) }
        }
    }
}

struct TodoRow: View {
    @Environment(\.modelContext) private var context
    let item: TodoItem
    var onMoveToTop: (() -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onEnterReorder: (() -> Void)? = nil
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @State private var isCopied: Bool = false
    @State private var isAnimatingCompletion: Bool = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.0
    @State private var isShowingShareSheet: Bool = false
    @State private var isShowingEditSheet: Bool = false

    private var isEffectivelyDone: Bool {
        item.status == .done || isAnimatingCompletion
    }

    private var typeColor: Color {
        switch item.type {
        case .parcel: return .orange
        case .returnParcel: return .indigo
        case .general, .event: return .blue
        case .medication: return .green
        case .housework: return .purple
        case .charging: return .yellow
        case .subscription, .bill: return .indigo
        case .itemExpiry: return .red
        case .anniversary: return .pink
        case .passwordSecurity: return .teal
        case .vehicleCare: return .indigo
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
                            item.markAsCompleted(in: context)
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
                        TodoNotificationManager.shared.scheduleNotification(for: item)
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
                        .frame(width: seniorManager.isSeniorModeEnabled ? 34 : 24, height: seniorManager.isSeniorModeEnabled ? 34 : 24)

                    Image(systemName: isEffectivelyDone ? "checkmark.circle.fill" : "circle")
                        .font(seniorManager.isSeniorModeEnabled ? .title : .title2)
                        .foregroundStyle(isEffectivelyDone ? Color.green : (seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.65) : Color.secondary))
                        .scaleEffect(isAnimatingCompletion ? 1.25 : 1.0)
                        .animation(.spring(response: 0.28, dampingFraction: 0.5), value: isAnimatingCompletion)
                }
                .frame(width: seniorManager.isSeniorModeEnabled ? 44 : 28, height: seniorManager.isSeniorModeEnabled ? 44 : 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                if item.type == .parcel, let code = item.pickupCode {
                    HStack(spacing: 8) {
                        Text(code)
                            .font((seniorManager.isSeniorModeEnabled ? Font.title2 : Font.title3).monospaced().bold())
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                            .strikethrough(isEffectivelyDone)
                            .padding(.horizontal, seniorManager.isSeniorModeEnabled ? 10 : 8)
                            .padding(.vertical, seniorManager.isSeniorModeEnabled ? 5 : 3)
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
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                    }
                } else if item.type == .returnParcel {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.indigo.opacity(isEffectivelyDone ? 0.08 : 0.16))
                                .frame(width: seniorManager.isSeniorModeEnabled ? 28 : 24, height: seniorManager.isSeniorModeEnabled ? 28 : 24)
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.indigo)
                        }

                        Text(item.title)
                            .font(.body.weight(isEffectivelyDone ? .regular : (seniorManager.isHighContrastEnabled ? .bold : .medium)))
                            .strikethrough(isEffectivelyDone)
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)

                        // 智能退货截止倒数预警胶囊
                        if let due = item.dueAt, !isEffectivelyDone {
                            let daysRemaining = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: due)).day ?? 0
                            HStack(spacing: 3) {
                                Image(systemName: daysRemaining <= 1 ? "exclamationmark.triangle.fill" : "clock.fill")
                                    .font(.system(size: 9))
                                Text(daysRemaining < 0 ? "已逾期" : (daysRemaining == 0 ? "今天截止!" : (daysRemaining == 1 ? "仅剩1天" : "退货剩\(daysRemaining)天")))
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    daysRemaining <= 0 ? Color.red.opacity(0.18) :
                                    (daysRemaining <= 1 ? Color.orange.opacity(0.2) : Color.indigo.opacity(0.15))
                                )
                            )
                            .foregroundStyle(
                                daysRemaining <= 0 ? Color.red :
                                (daysRemaining <= 1 ? Color.orange : Color.indigo)
                            )
                        }
                    }

                    if let code = item.pickupCode, !code.isEmpty {
                        HStack(spacing: 6) {
                            Text("寄件码: \(code)")
                                .font((seniorManager.isSeniorModeEnabled ? Font.subheadline : Font.caption).monospaced().bold())
                                .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color(.secondarySystemFill)))

                            Button {
                                UIPasteboard.general.string = code
                                Haptic.light()
                                withAnimation(.spring(duration: 0.2)) { isCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation { isCopied = false }
                                }
                            } label: {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(isCopied ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    let stationOrCourier = [item.station, item.courier].compactMap({ $0 }).joined(separator: " · ")
                    if !stationOrCourier.isEmpty {
                        Text(stationOrCourier)
                            .font(.caption)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                    }

                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                            .padding(.leading, seniorManager.isSeniorModeEnabled ? 36 : 32)
                    }
                } else {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(typeColor.opacity(isEffectivelyDone ? 0.08 : 0.16))
                                .frame(width: seniorManager.isSeniorModeEnabled ? 28 : 24, height: seniorManager.isSeniorModeEnabled ? 28 : 24)
                            Image(systemName: item.type.icon)
                                .font(.caption.bold())
                                .foregroundStyle(isEffectivelyDone ? .secondary : typeColor)
                        }

                        Text(item.title)
                            .font(.body.weight(isEffectivelyDone ? .regular : (seniorManager.isHighContrastEnabled ? .bold : .medium)))
                            .strikethrough(isEffectivelyDone)
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                    }

                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                            .padding(.leading, seniorManager.isSeniorModeEnabled ? 36 : 32)
                    }
                }

                HStack(spacing: 8) {
                    if let due = item.dueAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text("截止: \(due.formatted(date: .numeric, time: .shortened))")
                        }
                        .font(.caption2)
                        .foregroundStyle(due < .now && !isEffectivelyDone ? Color.red : (seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.7) : Color.secondary))
                    }

                    if item.isRecurring {
                        HStack(spacing: 3) {
                            Image(systemName: "repeat")
                            Text(item.recurrenceSummaryText)
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isEffectivelyDone ? Color.secondary.opacity(0.12) : Color.blue.opacity(0.12))
                        )
                    }

                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(Color.primary.opacity(seniorManager.isHighContrastEnabled ? 0.65 : 0.4))
                }
                .padding(.leading, (item.type == .parcel || item.type == .returnParcel) ? 0 : (seniorManager.isSeniorModeEnabled ? 36 : 32))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isShowingEditSheet = true
                Haptic.light()
            }

            Spacer(minLength: 4)

            // 长辈关怀：专属一键清晰大声朗读按钮
            if seniorManager.isVoiceBroadcastEnabled {
                Button {
                    let speechText: String = {
                        if item.type == .parcel, let code = item.pickupCode {
                            let station = item.location ?? item.station ?? ""
                            return "快递取件码：\(code)，\(item.title)。\(station)"
                        } else if item.type == .returnParcel {
                            let codeStr = item.pickupCode.map { "，寄件码：\($0)" } ?? ""
                            return "退货待办：\(item.title)\(codeStr)。\(item.detail ?? "")"
                        } else {
                            let detail = item.detail ?? ""
                            return "\(item.title)。\(detail)"
                        }
                    }()

                    if seniorManager.isSpeaking && seniorManager.currentSpeakingId == item.id.uuidString {
                        seniorManager.stopSpeaking()
                    } else {
                        seniorManager.speakSenior(text: speechText, id: item.id.uuidString)
                        Haptic.light()
                    }
                } label: {
                    let isCurrentSpeaking = seniorManager.isSpeaking && seniorManager.currentSpeakingId == item.id.uuidString
                    Image(systemName: isCurrentSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .caption)
                        .foregroundStyle(isCurrentSpeaking ? Color.orange : (seniorManager.isSeniorModeEnabled ? Color.orange : Color.secondary.opacity(0.7)))
                        .frame(width: seniorManager.isSeniorModeEnabled ? 42 : 28, height: seniorManager.isSeniorModeEnabled ? 42 : 28)
                        .background(
                            Circle()
                                .fill(isCurrentSpeaking ? Color.orange.opacity(0.2) : (seniorManager.isSeniorModeEnabled ? Color.orange.opacity(0.12) : Color.clear))
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .opacity(isEffectivelyDone ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: isEffectivelyDone)
        .animation(.easeInOut(duration: 0.2), value: item.status)
        .padding(.vertical, 3)
        .contextMenu {
            Button("编辑事项", systemImage: "pencil") {
                isShowingEditSheet = true
                Haptic.light()
            }

            Divider()

            Section("调整排序") {
                if let onMoveToTop {
                    Button("移至顶部 (置顶)", systemImage: "arrow.up.to.line") {
                        onMoveToTop()
                    }
                }
                if let onMoveUp {
                    Button("上移一位", systemImage: "arrow.up") {
                        onMoveUp()
                    }
                }
                if let onMoveDown {
                    Button("下移一位", systemImage: "arrow.down") {
                        onMoveDown()
                    }
                }
                if let onEnterReorder {
                    Button("进入拖拽排序模式", systemImage: "arrow.up.arrow.down") {
                        onEnterReorder()
                    }
                }
            }

            Divider()

            if let code = item.pickupCode {
                Button(item.type == .returnParcel ? "复制寄件码" : "复制取件码", systemImage: "doc.on.doc") {
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
            Button("分享此待办卡片", systemImage: "square.and.arrow.up") {
                isShowingShareSheet = true
                Haptic.light()
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            TodoShareSheet(
                allTodos: [item],
                initialCategory: (item.type == .parcel || item.type == .returnParcel) ? .parcel : .all,
                initialSelectedIds: [item.id]
            )
        }
        .sheet(isPresented: $isShowingEditSheet) {
            EditTodoSheet(item: item)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let onMoveToTop {
                Button {
                    onMoveToTop()
                } label: {
                    Label("置顶", systemImage: "arrow.up.to.line")
                }
                .tint(.orange)
            }

            if let onMoveUp {
                Button {
                    onMoveUp()
                } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .tint(.blue)
            }

            if let onMoveDown {
                Button {
                    onMoveDown()
                } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .tint(.indigo)
            }

            if let onEnterReorder {
                Button {
                    onEnterReorder()
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .tint(.teal)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Haptic.warning()
                TodoNotificationManager.shared.cancelNotification(for: item.id)
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

// MARK: - 新建待办 / 智能导入弹窗

/// 常用高频待办预设胶囊数据模型
fileprivate struct QuickSuggestion: Hashable {
    let title: String
    let detail: String?
    let defaultHourOffset: Int?
}

struct AddTodoSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let initialCategory: TodoFilterCategory

    @State private var tab: Int = 0 // 0: 手动新建, 1: 智能识别导入
    @State private var selectedCategory: TodoFilterCategory

    // 手动新建表单
    @State private var title: String = ""
    @State private var type: TodoType
    @State private var detail: String = ""
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var recurrenceRule: TodoRecurrenceRule = .none
    @State private var customIntervalDays: Int = 3
    @State private var pickupCode: String = ""
    @State private var station: String = ""

    // 智能剪贴板侦测
    @State private var detectedClipboardText: String?
    @State private var detectedClipboardType: TodoType?
    @State private var detectedPickupCode: String?
    @State private var detectedStation: String?

    // 智能识别文本
    @State private var importText: String = ""
    @State private var importResult: String?

    init(initialCategory: TodoFilterCategory = .all) {
        self.initialCategory = initialCategory
        self._selectedCategory = State(initialValue: initialCategory)

        // 根据首页当前选中的分类，自动匹配最合适的默认分类类型与提醒时间
        let defaultType: TodoType
        let defaultHasDueDate: Bool
        let defaultDue: Date

        switch initialCategory {
        case .all, .general:
            defaultType = .general
            defaultHasDueDate = false
            defaultDue = Calendar.current.date(byAdding: .hour, value: 2, to: .now) ?? .now
        case .parcel:
            defaultType = .parcel
            defaultHasDueDate = false
            defaultDue = Calendar.current.date(byAdding: .hour, value: 3, to: .now) ?? .now
        case .life:
            defaultType = .medication
            defaultHasDueDate = true
            let calendar = Calendar.current
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
            defaultDue = tonight > .now ? tonight : (calendar.date(byAdding: .day, value: 1, to: tonight) ?? .now)
        case .alert:
            defaultType = .bill
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        case .recurring:
            defaultType = .general
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        }

        self._type = State(initialValue: defaultType)
        self._hasDueDate = State(initialValue: defaultHasDueDate)
        self._dueDate = State(initialValue: defaultDue)
        if initialCategory == .recurring {
            self._recurrenceRule = State(initialValue: .weekly)
        }
    }

    // MARK: - 分类对应候选子类型集合

    /// 当前选中的大板块所涵盖的具体待办类型
    private var availableTypesForCategory: [TodoType] {
        switch selectedCategory {
        case .all:
            return [.general, .parcel, .medication, .housework, .charging, .subscription, .vehicleCare, .bill, .itemExpiry, .anniversary, .hydration, .event]
        case .general:
            return [.general, .event]
        case .recurring:
            return [.general, .medication, .housework, .charging, .hydration, .bill, .event]
        case .parcel:
            return [.parcel, .returnParcel]
        case .life:
            return [.medication, .housework, .charging, .hydration]
        case .alert:
            return [.bill, .vehicleCare, .subscription, .itemExpiry, .anniversary, .passwordSecurity]
        }
    }

    /// 切换大板块时自动适配子类型
    private func onCategoryChanged(_ newCat: TodoFilterCategory) {
        selectedCategory = newCat
        let candidates = availableTypesForCategory
        if !candidates.contains(type) {
            type = candidates.first ?? .general
        }
        if newCat == .life || newCat == .alert || newCat == .recurring {
            hasDueDate = true
            if newCat == .recurring && recurrenceRule == .none {
                recurrenceRule = .weekly
            }
        }
        Haptic.selection()
    }

    // MARK: - 动态情境占位符

    private var contextualPlaceholder: String {
        switch type {
        case .parcel:
            return "快递名称（如：顺丰快递、京东生鲜、天猫超市）"
        case .returnParcel:
            return "退货/售后事项（如：网购衣服7天退货、数码产品售后寄回）"
        case .medication:
            return "用药名称（如：按时吃降压药、早晚维生素、滴眼药水）"
        case .housework:
            return "家务项目（如：洗被罩床单、全屋扫地拖地、阳台浇花）"
        case .charging:
            return "设备名称（如：给蓝牙耳机充电、给备用手机充电）"
        case .hydration:
            return "喝水作息（如：下午喝一杯温水、起身走动拉伸）"
        case .bill:
            return "账单名称（如：信用卡账单还款、缴纳房租水电）"
        case .vehicleCare:
            return "爱车事项（如：汽车加油/加电、5000公里小保养、车险续约）"
        case .subscription:
            return "订阅服务（如：iCloud+ 自动续费、视频VIP续约防扣款）"
        case .itemExpiry:
            return "保质期预警（如：鲜牛奶到期、家庭常备药有效期、换驾照）"
        case .anniversary:
            return "重要纪念日（如：妈妈生日、结婚纪念日、好友聚会）"
        case .passwordSecurity:
            return "安全提醒（如：定期轮换平台密码、更新路由器管理密码）"
        case .event:
            return "日程事项（如：周五下午团队例会、拜访重要客户）"
        case .general, .data:
            return "待办名称（如：去超市买牛奶、准备工作周报、下午开会）"
        }
    }

    // MARK: - 高频快捷预设胶囊（一键免手动打字）

    private var quickSuggestionsForType: [QuickSuggestion] {
        switch type {
        case .parcel:
            return [
                QuickSuggestion(title: "顺丰速运", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "京东快递", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "菜鸟驿站包裹", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "丰巢柜包裹", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "中通快递", detail: nil, defaultHourOffset: nil),
                QuickSuggestion(title: "天猫超市生鲜", detail: nil, defaultHourOffset: nil)
            ]
        case .returnParcel:
            return [
                QuickSuggestion(title: "七天无理由退货", detail: "保持包装吊牌完好，联系快递上门取件", defaultHourOffset: 168),
                QuickSuggestion(title: "衣服鞋帽尺码退换", detail: "商品完好，附退换货清单", defaultHourOffset: 72),
                QuickSuggestion(title: "网购数码售后返修寄件", detail: "原包装防震保护好寄回", defaultHourOffset: 120),
                QuickSuggestion(title: "快递员预约上门取件", detail: "提前打包好包裹", defaultHourOffset: 24)
            ]
        case .medication:
            return [
                QuickSuggestion(title: "按时吃降压药", detail: "温水送服，饭后半小时", defaultHourOffset: 2),
                QuickSuggestion(title: "早晚复合维生素", detail: "饭后随餐服用", defaultHourOffset: 4),
                QuickSuggestion(title: "睡前滴眼药水", detail: "两眼各一滴，闭目5分钟", defaultHourOffset: 6),
                QuickSuggestion(title: "补钙咀嚼片", detail: "睡前咀嚼服用", defaultHourOffset: 6)
            ]
        case .housework:
            return [
                QuickSuggestion(title: "全屋扫地拖地", detail: "客厅、卧室及走廊吸尘除灰", defaultHourOffset: 24),
                QuickSuggestion(title: "清洗更换床单被罩", detail: "高温洗烘除螨", defaultHourOffset: 48),
                QuickSuggestion(title: "阳台绿植浇水", detail: "浇透盆底见湿", defaultHourOffset: 24),
                QuickSuggestion(title: "清理冰箱过期食品", detail: "检查冷藏层保质期", defaultHourOffset: 72),
                QuickSuggestion(title: "清洗油烟机滤网", detail: "温水去油污浸泡", defaultHourOffset: 168)
            ]
        case .charging:
            return [
                QuickSuggestion(title: "给蓝牙耳机充电", detail: "放回充电盒充满", defaultHourOffset: 3),
                QuickSuggestion(title: "给备用手机/手表充电", detail: "保持电量充足", defaultHourOffset: 2),
                QuickSuggestion(title: "充电宝蓄电", detail: "为明日外出备电", defaultHourOffset: 4)
            ]
        case .hydration:
            return [
                QuickSuggestion(title: "下午喝一杯温水", detail: "补充水分 300ml", defaultHourOffset: 1),
                QuickSuggestion(title: "起身活动拉伸5分钟", detail: "放松肩颈腰椎", defaultHourOffset: 1)
            ]
        case .bill:
            return [
                QuickSuggestion(title: "信用卡账单还款", detail: "核对本期应还款额", defaultHourOffset: 72),
                QuickSuggestion(title: "房租水电费缴纳", detail: "按时缴费避免断供滞纳", defaultHourOffset: 48),
                QuickSuggestion(title: "宽带话费充值", detail: "检查剩余话费", defaultHourOffset: 48)
            ]
        case .vehicleCare:
            return [
                QuickSuggestion(title: "爱车加油/加电", detail: "关注续航里程与电量/油量", defaultHourOffset: 24),
                QuickSuggestion(title: "汽车常规小保养", detail: "更换机油机滤与胎压检查", defaultHourOffset: 168),
                QuickSuggestion(title: "车险到期续约", detail: "比对车险报价及商业险", defaultHourOffset: 720),
                QuickSuggestion(title: "车辆年检/违章核查", detail: "交管12123查验", defaultHourOffset: 360)
            ]
        case .subscription:
            return [
                QuickSuggestion(title: "iCloud+ 自动续费", detail: "检查当月账单扣款", defaultHourOffset: 72),
                QuickSuggestion(title: "视频VIP连续包月防扣款", detail: "如不继续使用请提前关闭", defaultHourOffset: 48),
                QuickSuggestion(title: "音乐平台会员续费", detail: "自动扣费确认", defaultHourOffset: 72)
            ]
        case .itemExpiry:
            return [
                QuickSuggestion(title: "鲜牛奶食品保质期", detail: "冷藏保鲜临期预警", defaultHourOffset: 48),
                QuickSuggestion(title: "常备药品有效期核对", detail: "清理家庭小药箱", defaultHourOffset: 720),
                QuickSuggestion(title: "身份证/驾照换证提醒", detail: "期满前90日内申请换证", defaultHourOffset: 2160)
            ]
        case .anniversary:
            return [
                QuickSuggestion(title: "家人长辈生日", detail: "提前准备生日礼物与祝福", defaultHourOffset: 168),
                QuickSuggestion(title: "结婚/恋爱纪念日", detail: "订餐厅与纪念礼物", defaultHourOffset: 168)
            ]
        case .passwordSecurity:
            return [
                QuickSuggestion(title: "重要平台密码定期轮换", detail: "更新核心账号强密码", defaultHourOffset: 720)
            ]
        case .general:
            return [
                QuickSuggestion(title: "下班去超市采买", detail: "购买生活必需品", defaultHourOffset: 4),
                QuickSuggestion(title: "整理本周工作周报", detail: "总结核心交付物与下周规划", defaultHourOffset: 24),
                QuickSuggestion(title: "给家里通电话问候", detail: "关心父母近况", defaultHourOffset: 6)
            ]
        case .event:
            return [
                QuickSuggestion(title: "团队项目进度例会", detail: "会议室对齐本周阻塞项", defaultHourOffset: 24),
                QuickSuggestion(title: "客户拜访洽谈", detail: "准备方案与演示文稿", defaultHourOffset: 48)
            ]
        default:
            return []
        }
    }

    private func applyQuickSuggestion(_ s: QuickSuggestion) {
        title = s.title
        if detail.isEmpty, let d = s.detail {
            detail = d
        }
        if let offset = s.defaultHourOffset {
            hasDueDate = true
            dueDate = Calendar.current.date(byAdding: .hour, value: offset, to: .now) ?? dueDate
        }
        Haptic.light()
    }

    // MARK: - 剪贴板极速识别

    private func checkClipboard() {
        guard let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty else { return }
        guard clip.count <= 350 else { return }

        let isReturn = clip.contains("退货") || clip.contains("寄件") || clip.contains("售后") || clip.contains("上门取件") || clip.contains("换货") || clip.contains("退款")
        let isParcel = clip.contains("取件") || clip.contains("驿站") || clip.contains("丰巢") || clip.contains("自提") || clip.contains("快递") || clip.contains("包裹")
        let isBill = clip.contains("账单") || clip.contains("还款") || clip.contains("扣款") || clip.contains("应还")

        if isReturn {
            detectedClipboardText = clip
            detectedClipboardType = .returnParcel
            if let regex = try? NSRegularExpression(pattern: "([0-9A-Za-z]{6,})", options: []) {
                if let match = regex.firstMatch(in: clip, options: [], range: NSRange(location: 0, length: clip.utf16.count)) {
                    if let range = Range(match.range(at: 1), in: clip) {
                        detectedPickupCode = String(clip[range])
                    }
                }
            }
            if clip.contains("顺丰") { detectedStation = "顺丰速运" }
            else if clip.contains("京东") { detectedStation = "京东快递" }
            else if clip.contains("菜鸟") { detectedStation = "菜鸟驿站" }
        } else if isParcel {
            detectedClipboardText = clip
            detectedClipboardType = .parcel
            if let regex = try? NSRegularExpression(pattern: "([0-9A-Za-z]+[-号][0-9A-Za-z]+[-号]?[0-9A-Za-z]*)", options: []) {
                if let match = regex.firstMatch(in: clip, options: [], range: NSRange(location: 0, length: clip.utf16.count)) {
                    if let range = Range(match.range(at: 1), in: clip) {
                        detectedPickupCode = String(clip[range])
                    }
                }
            }
            if clip.contains("菜鸟") { detectedStation = "菜鸟驿站" }
            else if clip.contains("丰巢") { detectedStation = "丰巢快递柜" }
        } else if isBill {
            detectedClipboardText = clip
            detectedClipboardType = .bill
        }
    }

    private func applyClipboardAutofill() {
        guard let clip = detectedClipboardText else { return }
        if detectedClipboardType == .returnParcel {
            onCategoryChanged(.parcel)
            type = .returnParcel
            if let code = detectedPickupCode {
                pickupCode = code
                title = "网购退货寄件"
            } else {
                title = "网购待退货"
            }
            if let st = detectedStation {
                station = st
            }
            detail = clip
            hasDueDate = true
            dueDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        } else if detectedClipboardType == .parcel {
            onCategoryChanged(.parcel)
            type = .parcel
            if let code = detectedPickupCode {
                pickupCode = code
                if clip.contains("顺丰") { title = "顺丰快递" }
                else if clip.contains("京东") { title = "京东快递" }
                else if clip.contains("中通") { title = "中通快递" }
                else if clip.contains("圆通") { title = "圆通快递" }
                else { title = "待取快递包裹" }
            } else {
                title = "待取快递"
            }
            if let st = detectedStation {
                station = st
            }
            detail = clip
        } else if detectedClipboardType == .bill {
            onCategoryChanged(.alert)
            type = .bill
            title = "信用卡账单还款"
            detail = clip
            hasDueDate = true
        } else {
            title = String(clip.prefix(25))
            detail = clip
        }
        detectedClipboardText = nil
        Haptic.success()
    }

    // MARK: - 主视图

    var body: some View {
        NavigationStack {
            Form {
                // 1. 添加模式分段选择
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
                    // 智能剪贴板侦测卡片（极简一键填入）
                    if let clipSnippet = detectedClipboardText {
                        Section {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.tint)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text("识别到剪贴板有相关通知")
                                        .font(.subheadline.bold())

                                    Text(clipSnippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)

                                    Button {
                                        applyClipboardAutofill()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down.doc.fill")
                                            Text("一键识别填入表单")
                                        }
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor)
                                        .clipShape(Capsule())
                                    }
                                    .padding(.top, 2)
                                }

                                Spacer()

                                Button {
                                    withAnimation { detectedClipboardText = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // 2. 所属板块分段选择（自动对应首页当前分类）
                    Section("事项所属板块") {
                        Picker("所属板块", selection: Binding(
                            get: { selectedCategory },
                            set: { onCategoryChanged($0) }
                        )) {
                            ForEach(TodoFilterCategory.allCases) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)

                        // 具体类型选择（根据板块智能收敛选项）
                        if availableTypesForCategory.count > 1 {
                            Picker("具体类型", selection: $type) {
                                ForEach(availableTypesForCategory, id: \.self) { t in
                                    Label(t.displayName, systemImage: t.icon).tag(t)
                                }
                            }
                        } else if type == .parcel {
                            HStack {
                                Label("快递取件", systemImage: "shippingbox.fill")
                                Spacer()
                                Text("已自动匹配快递模式")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // 3. 待办内容填写与高频快捷胶囊
                    Section("待办内容") {
                        TextField(contextualPlaceholder, text: $title)

                        // 常用快捷预设横向滑动标签
                        let suggestions = quickSuggestionsForType
                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestions, id: \.self) { s in
                                        Button {
                                            applyQuickSuggestion(s)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.tint)
                                                Text(s.title)
                                                    .font(.caption)
                                                    .foregroundStyle(.primary)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }

                        // 快递/退货模式专属快捷输入字段
                        if type == .parcel {
                            TextField("取件码（如：3-2-104 或 5821）", text: $pickupCode)
                                .font(.body.monospaced())

                            TextField("存放驿站/自提柜（选填，如：菜鸟驿站、丰巢）", text: $station)
                        } else if type == .returnParcel {
                            TextField("寄件码 / 售后运单号（选填）", text: $pickupCode)
                                .font(.body.monospaced())

                            TextField("寄件方式/网点（选填，如：顺丰上门取件、驿站代寄）", text: $station)
                        }
                    }

                    // 4. 详情与提醒时间
                    Section("详情与提醒时间") {
                        TextField("补充备注/详情说明（选填）", text: $detail, axis: .vertical)
                            .lineLimit(2...4)

                        Toggle("设置提醒时间", isOn: $hasDueDate)
                        if hasDueDate {
                            DatePicker("截止时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
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
                            Text("完成此待办后，将自动按「\(recurrenceRule.displayLabel(customDays: customIntervalDays))」生成下一期事项。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        TextEditor(text: $importText)
                            .frame(minHeight: 140)
                    } header: {
                        Text("粘贴短信或聊天文本")
                    } footer: {
                        Text("系统将自动识别取件码、驿站、重要账单并自动建档。可一次粘贴多条，用换行隔开。")
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
            .onAppear {
                checkClipboard()
            }
        }
    }

    private func createTodo() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStation = station.trimmingCharacters(in: .whitespacesAndNewlines)

        let minOrder = (try? context.fetch(FetchDescriptor<TodoItem>()))?.map(\.sortOrder).min() ?? 0

        let item = TodoItem(
            type: type,
            status: .active,
            title: trimmedTitle,
            detail: trimmedDetail.isEmpty ? nil : trimmedDetail,
            pickupCode: trimmedCode.isEmpty ? nil : trimmedCode,
            courier: (type == .parcel || type == .returnParcel) ? (trimmedTitle.contains("快递") || trimmedTitle.contains("速递") || trimmedTitle.contains("顺丰") ? trimmedTitle : nil) : nil,
            station: trimmedStation.isEmpty ? nil : trimmedStation,
            location: trimmedStation.isEmpty ? nil : trimmedStation,
            dueAt: hasDueDate ? dueDate : nil,
            sortOrder: minOrder - 1,
            recurrenceRuleRaw: recurrenceRule == .none ? nil : recurrenceRule.rawValue,
            recurrenceIntervalDays: recurrenceRule == .custom ? customIntervalDays : recurrenceRule.dayInterval(customDays: customIntervalDays)
        )
        context.insert(item)
        TodoNotificationManager.shared.scheduleNotification(for: item)
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
