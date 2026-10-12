import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

enum TodoFilterCategory: String, CaseIterable, Identifiable, Hashable {
    case all = "全部"
    case general = "待办"
    case recurring = "周期"
    case parcel = "快递"
    case life = "生活"
    case alert = "预警"
    case parenting = "育儿"
    case pet = "宠物"

    var id: String { rawValue }
}

enum TodoCategoryPreferences {
    private static let key = "todo_home_category_order_v1"

    static func load() -> [TodoFilterCategory] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return TodoFilterCategory.allCases
        }
        var categories = rawValues.compactMap { TodoFilterCategory(rawValue: $0) }.uniqued()
        if !categories.contains(.all) { categories.insert(.all, at: 0) }
        return categories
    }

    static func save(_ categories: [TodoFilterCategory]) {
        let rawValues = categories.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawValues) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
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
    var parentingTodos: [TodoItem] = []
    var petTodos: [TodoItem] = []
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
                case .general, .event, .travelBooking: doneGenerals.append(item)
                case .skillLearning: doneGenerals.append(item)
                case .parcel, .returnParcel: doneParcels.append(item)
                case .medication, .housework, .exercise, .charging: doneLife.append(item)
                case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare: doneAlerts.append(item)
                default: break
                }
            case .active:
                active.append(item)
                if item.isRecurring { recurring.append(item) }
                switch item.type {
                case .general, .event, .travelBooking: generals.append(item)
                case .skillLearning: generals.append(item)
                case .parcel: parcels.append(item)
                case .returnParcel: returnParcels.append(item)
                case .medication: medications.append(item)
                case .charging: chargings.append(item)
                case .housework, .exercise: houseworks.append(item)
                case .subscription, .bill: subscriptions.append(item)
                case .itemExpiry: expiries.append(item)
                case .anniversary: anniversaries.append(item)
                case .passwordSecurity: passwordTodos.append(item)
                case .vehicleCare: vehicleTodos.append(item)
                case .childVaccine, .childGrowth, .childMilestone, .childHealth: parentingTodos.append(item)
                case .pet: petTodos.append(item)
                default: others.append(item)
                }
            }
        }
        // 所有活跃分组统一按“紧急性 60% + 重要性 40%”排序，sortOrder 仅作为同分时的手动顺序。
        TodoPriority.sort(&active)
        TodoPriority.sort(&recurring)
        TodoPriority.sort(&generals)
        TodoPriority.sort(&parcels)
        TodoPriority.sort(&returnParcels)
        TodoPriority.sort(&medications)
        TodoPriority.sort(&chargings)
        TodoPriority.sort(&houseworks)
        TodoPriority.sort(&subscriptions)
        TodoPriority.sort(&expiries)
        TodoPriority.sort(&anniversaries)
        TodoPriority.sort(&passwordTodos)
        TodoPriority.sort(&vehicleTodos)
        TodoPriority.sort(&parentingTodos)
        TodoPriority.sort(&petTodos)
        TodoPriority.sort(&others)
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
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @AppStorage("all_tab_grouping_mode") private var isGroupedByType: Bool = false
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var weatherAlerts = WeatherAlertService.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @ObservedObject private var anniversaryReminder = AnniversaryReminderManager.shared
    @ObservedObject private var ticketReminder = TravelTicketReminderManager.shared
    @State private var showAddTodo = false
    @State private var showVoice = false
    @State private var showDone = false
    @State private var showCompletedHistory = false
    @State private var showPeriodicReport = false
    @State private var showSeniorSettings = false
    @State private var selectedFilter: TodoFilterCategory = .all
    @State private var highlightedTodoID: UUID?
    @State private var homeCategories: [TodoFilterCategory] = TodoCategoryPreferences.load()
    @State private var showCategoryCustomization = false
    @State private var itemToShare: TodoItem? = nil
    @State private var confirmingTicketInfo: UpcomingTravelTicketInfo? = nil
    @State private var prepToastMessage: String? = nil
    @State private var isReordering: Bool = false
    @State private var searchText: String = ""
    @State private var showOverdueTriage = false
    @AppStorage("overdue_triage_last_date") private var lastTriageDateKey = ""

    // MARK: - 单次 O(N) 极速分类缓存（彻底消除视图树重复全表遍历）
    private var classified: TodoClassification {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return TodoClassification(from: todos) }
        return TodoClassification(from: todos.filter { matchesSearch($0, query: query) })
    }

    private func matchesSearch(_ item: TodoItem, query: String) -> Bool {
        let fields = [
            item.title,
            item.detail,
            item.pickupCode,
            item.courier,
            item.station,
            item.location,
            item.sourceText
        ]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    private func category(for item: TodoItem) -> TodoFilterCategory {
        switch item.type {
        case .parcel, .returnParcel: return .parcel
        case .medication, .charging, .housework, .exercise, .hydration: return .life
        case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare: return .alert
        case .childVaccine, .childGrowth, .childMilestone, .childHealth: return .parenting
        case .pet: return .pet
        case .general, .event, .travelBooking: return .general
        case .skillLearning: return .general
        case .data: return .all
        }
    }

    private var activeTodos: [TodoItem] { classified.active }

    /// 逾期事项：截止时间已过且仍未完成（与 TodayBriefingView 的逾期口径一致）
    private var overdueTodos: [TodoItem] {
        todos.filter { item in
            guard item.status == .active, let due = item.dueAt else { return false }
            return due < .now
        }
        .sorted { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }
    }

    /// 早间逾期清道夫：每天首次进入待办页时，若有逾期事项则弹出发牌器
    private func maybePresentOverdueTriage() {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        let key = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
        guard lastTriageDateKey != key, !overdueTodos.isEmpty else { return }
        lastTriageDateKey = key
        // 延迟弹出，避免抢在页面转场动画与其他首次弹窗之前
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if !showOverdueTriage {
                showOverdueTriage = true
            }
        }
    }
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
    private var parentingTodos: [TodoItem] { classified.parentingTodos }
    private var petTodos: [TodoItem] { classified.petTodos }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HomeGreetingCard(activeCount: todos.filter { $0.status == .active }.count)
                // 万能投喂口固定入口：丢进文字/截图，自动记账、建待办、存收集箱
                OmniboxEntryCard {
                    Haptic.light()
                    router.activeSheet = .omnibox
                }
                LifeEventHomeBanner()

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

                // 临近节假日或出差旅游出行前购票提醒横幅（火车票提前15天、机票提前15-30天）
                if let ticketInfo = ticketReminder.activeUpcomingTicket {
                    travelTicketPrepBanner(ticketInfo)
                }

                Divider()
                    .opacity(bgManager.isCustomBackgroundActive ? 0.35 : 1.0)

                // 支持横向滑动的分页容器
                ScrollViewReader { proxy in
                    TabView(selection: $selectedFilter) {
                        ForEach(homeCategories) { category in
                            renderPageContent(for: category)
                                .tag(category)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: router.focusedTodoID) { _, id in
                        guard let id else { return }
                        highlightedTodoID = id
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if highlightedTodoID == id {
                                highlightedTodoID = nil
                                if router.focusedTodoID == id { router.focusedTodoID = nil }
                            }
                        }
                    }
                    .onAppear {
                        if let id = router.focusedTodoID {
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemGroupedBackground))
            .themedAppBackground()
            .navigationTitle(assistantName.isEmpty ? "小助" : assistantName)
            .searchable(text: $searchText, prompt: "搜索待办、详情、取件码或驿站")
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
            .sheet(isPresented: $showOverdueTriage) {
                OverdueTriageSheet(items: overdueTodos)
            }
            .onAppear {
                maybePresentOverdueTriage()
            }
            .sheet(isPresented: $showVoice) { VoiceDialogueView() }
            .sheet(isPresented: $showCompletedHistory) { CompletedTodoHistoryView() }
            .sheet(isPresented: $showPeriodicReport) {
                PeriodicReportView(initialPeriod: .daily)
            }
            .sheet(item: $itemToShare) { item in
                TodoShareSheet(
                    allTodos: [item],
                    initialCategory: item.type == .parcel ? .parcel : .all,
                    initialSelectedIds: [item.id]
                )
            }
            .sheet(item: $confirmingTicketInfo) { info in
                TravelTicketConfirmationSheet(ticketInfo: info) { count in
                    showToast("已确认添加 \(count) 项出行前待办！🎫")
                }
            }
            .sheet(isPresented: $showSeniorSettings) {
                NavigationStack {
                    SeniorModeSettingsView()
                }
            }
            .sheet(isPresented: $showCategoryCustomization) {
                TodoCategoryCustomizationView(categories: homeCategories) { updated in
                    homeCategories = updated
                    TodoCategoryPreferences.save(updated)
                    if !updated.contains(selectedFilter) {
                        selectedFilter = .all
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
                case .periodicReport:
                    showPeriodicReport = true
                default:
                    break
                }
                router.activeSheet = nil
            }
            .onChange(of: router.requestedFilter) { _, filterName in
                guard let filterName else { return }
                if let cat = TodoFilterCategory.allCases.first(where: { $0.rawValue == filterName }) {
                    selectedFilter = homeCategories.contains(cat) ? cat : .all
                }
                router.requestedFilter = nil
            }
            .onChange(of: router.focusedTodoID) { _, id in
                guard let id, let item = todos.first(where: { $0.id == id }) else { return }
                let target = category(for: item)
                selectedFilter = homeCategories.contains(target) ? target : .all
            }
            .onChange(of: searchText) { _, query in
                if !query.isEmpty { selectedFilter = .all }
            }
            .overlay {
                if activeTodos.isEmpty && review.isEmpty && done.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
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
            .task {
                await weatherAlerts.checkAlertsIfNeeded()
                anniversaryReminder.refreshActiveUpcoming(context: context)
                ticketReminder.refreshUpcomingTickets(context: context)
            }
            .onAppear {
                anniversaryReminder.refreshActiveUpcoming(context: context)
                ticketReminder.refreshUpcomingTickets(context: context)
                if let id = router.focusedTodoID, let item = todos.first(where: { $0.id == id }) {
                    let target = category(for: item)
                    selectedFilter = homeCategories.contains(target) ? target : .all
                    highlightedTodoID = id
                }
            }
            .onChange(of: todos) { _, _ in
                anniversaryReminder.refreshActiveUpcoming(context: context)
                ticketReminder.refreshUpcomingTickets(context: context)
            }
            .overlay(alignment: .bottom) {
                if let toast = prepToastMessage {
                    Text(L10n.tr(toast))
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

    // MARK: - 节假日与出差旅行出行前购票备忘卡片（火车票提前15天、机票提前15-30天）

    @ViewBuilder
    private func travelTicketPrepBanner(_ info: UpcomingTravelTicketInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "ticket.fill")
                        .font(.title3)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(info.title + (info.isHoliday ? "出行购票提醒" : "购票提醒"))
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            Text(info.stageBadgeText)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.indigo.opacity(0.18)))
                                .foregroundStyle(.indigo)
                        }

                        Text("出行日期 \(info.departureFormatted) · \(info.recommendationDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 不再提醒按钮
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        ticketReminder.dismiss(for: info)
                        showToast("已设置本周期不再提醒该出行购票")
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

            // 火车票、文博景区与机票三大关键时间节点胶囊
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Label("🚄 火车票起售：\(info.trainSaleFormatted) (提前15天)", systemImage: "train.side.front.car")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
                        .foregroundStyle(.blue)

                    Label("🏛️ 场馆景区预约：\(info.scenicBookingFormatted) (提前7天)", systemImage: "building.columns.fill")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.08)))
                        .foregroundStyle(.purple)

                    Label("✈️ 机票黄金预订：提前15-30天", systemImage: "airplane")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.teal.opacity(0.08)))
                        .foregroundStyle(.teal)
                }
            }

            // 目的地文博场馆放票规则指南提示
            if let guide = info.destinationGuide {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text(guide)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 4)
            }

            // 用户确认式加入待办事项
            Button {
                confirmingTicketInfo = info
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.badge.questionmark.fill")
                    Text("查看并确认新增待办 (3项推荐)")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [Color.indigo, Color.blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.indigo.opacity(0.25), radius: 4, y: 2)
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
                .strokeBorder(Color.indigo.opacity(0.25), lineWidth: 1)
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
        if !parentingTodos.isEmpty {
            renderParentingSection()
        }
        if !petTodos.isEmpty {
            renderPetSection()
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

    @ViewBuilder
    private func renderParentingSection() -> some View {
        Section("亲子育儿（(parentingTodos.count)）") {
            if parentingTodos.isEmpty {
                Text("暂无育儿待办，可添加疫苗、成长测量或健康随访提醒。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(parentingTodos) { item in
                    TodoRow(item: item,
                            onMoveToTop: { moveItemToTop(item, within: parentingTodos) },
                            onMoveUp: { moveItemUp(item, within: parentingTodos) },
                            onMoveDown: { moveItemDown(item, within: parentingTodos) },
                            onEnterReorder: { withAnimation { isReordering = true } })
                }
                .onMove { from, to in reorder(items: parentingTodos, fromOffsets: from, toOffset: to) }
            }
        }
    }

    @ViewBuilder
    private func renderPetSection() -> some View {
        Section("宠物照护（\(petTodos.count)）") {
            if petTodos.isEmpty {
                Text("暂无宠物待办，可添加喂食、驱虫、洗护或就医提醒。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(petTodos) { item in
                    TodoRow(item: item,
                            onMoveToTop: { moveItemToTop(item, within: petTodos) },
                            onMoveUp: { moveItemUp(item, within: petTodos) },
                            onMoveDown: { moveItemDown(item, within: petTodos) },
                            onEnterReorder: { withAnimation { isReordering = true } })
                }
                .onMove { from, to in reorder(items: petTodos, fromOffsets: from, toOffset: to) }
            }
        }
    }

    // MARK: - 页面与顶部 Tab 栏组件

    @ViewBuilder
    private var filterTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(homeCategories) { category in
                        let isSelected = selectedFilter == category
                        let count = badgeCount(for: category)

                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                selectedFilter = category
                            }
                            Haptic.selection()
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.tr(category.rawValue))
                                    .font(.subheadline)
                                    .fontWeight(isSelected ? .bold : .medium)

                                if count > 0 {
                                    Text(count > 99 ? "99+" : "\(count)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(
                                            isSelected ? Color.white.opacity(0.25) : badgeColor(for: category).opacity(0.16)
                                        ))
                                        .foregroundStyle(isSelected ? Color.white : badgeColor(for: category))
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                                    .shadow(color: isSelected ? Color.accentColor.opacity(0.22) : .clear, radius: 4, y: 2)
                            }
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(category.rawValue)，\(count) 项")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        .id(category)
                    }
                    Button {
                        showCategoryCustomization = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline.bold())
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("定制首页分类")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedFilter) { _, category in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(category, anchor: .center) }
            }
        }
        .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemBackground))
    }

    @ViewBuilder
    private func renderPageContent(for category: TodoFilterCategory) -> some View {
        List {
            // 放进列表头部，使“今日安排”可以随首页内容向上滚动，不占用固定屏幕空间。
            Section {
                EmptyView()
            } header: {
                VStack(spacing: 4) {
                    TodayBriefingView(items: todos.filter { $0.status == .active })
                    // Structured 式今日时间轴：起床/下班锚点 + 日程 + 定时待办 + 打卡，
                    // 自动标出空闲时段，一眼判断"今天塞不塞得下一件新事"。
                    DayTimelineView(items: todos.filter { $0.status == .active })
                }
                .textCase(nil)
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
            case .recurring:
                renderRecurringSection()
            case .parcel:
                renderParcelSection()
            case .life:
                renderLifeSection()
            case .alert:
                renderAlertSection()
            case .parenting:
                renderParentingSection()
            case .pet:
                renderPetSection()
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
        case .parenting: return parentingTodos.count
        case .pet: return petTodos.count
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
        case .parenting: return .pink
        case .pet: return .orange
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
            return done.filter { [.medication, .housework, .exercise, .charging].contains($0.type) }
        case .alert:
            return done.filter { [.subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare].contains($0.type) }
        case .parenting:
            return done.filter { [.childVaccine, .childGrowth, .childMilestone, .childHealth].contains($0.type) }
        case .pet:
            return done.filter { $0.type == .pet }
        }
    }
}

private struct HomeGreetingCard: View {
    let activeCount: Int
    @State private var weatherSymbol = "cloud.sun.fill"
    @State private var weatherText = "天气稍后更新"
    @State private var isLoadingWeather = true
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @ObservedObject private var locationService = LocationReminderService.shared

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        case 18..<24: return "晚上好"
        default: return "夜深了"
        }
    }

    private var statusText: String {
        if activeCount == 0 { return "现在没有什么着急的事需要处理，可以放松一下" }
        if activeCount == 1 { return "今天还有 1 件事，按自己的节奏处理就好" }
        return "今天还有 \(activeCount) 件事，先处理最重要的一件就好"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(greeting)，\(userTitle.isEmpty || userTitle == "你" ? "朋友" : userTitle)")
                    .font(.headline.weight(.semibold))
                Text(L10n.tr(statusText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Haptic.light()
                Task { await loadWeather(force: true, requestPermission: true) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: weatherSymbol)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                    Text(weatherText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 62)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .task { await loadWeather() }
        .onChange(of: locationService.authorizationStatus) { _, _ in
            Task { await loadWeather(force: true) }
        }
    }

    @MainActor
    private func loadWeather(force: Bool = false, requestPermission: Bool = false) async {
        guard force || isLoadingWeather else { return }

        if let cached = WeatherAlertService.shared.cachedWeatherSnapshot, weatherText == "天气稍后更新" {
            weatherSymbol = cached.symbolName
            weatherText = "\(cached.conditionDescription) \(cached.formattedTemperature)"
        }

        var location = locationService.lastKnownLocation
        if location == nil {
            _ = await locationService.requestSingleLocationSample(requestPermissionIfNeeded: requestPermission)
            location = locationService.lastKnownLocation
        }
        guard let location else {
            if let cached = WeatherAlertService.shared.cachedWeatherSnapshot {
                weatherSymbol = cached.symbolName
                weatherText = "\(cached.conditionDescription) \(cached.formattedTemperature)"
            } else {
                weatherText = locationService.authorizationStatus == .denied || locationService.authorizationStatus == .restricted
                    ? "请开启定位"
                    : "点击获取天气"
            }
            isLoadingWeather = false
            return
        }
        isLoadingWeather = true
        if let snapshot = await WeatherAlertService.shared.fetchCurrentWeather(for: location) {
            weatherSymbol = snapshot.symbolName
            weatherText = "\(snapshot.conditionDescription) \(snapshot.formattedTemperature)"
        } else {
            weatherText = "天气不可用"
        }
        isLoadingWeather = false
    }
}

/// 首页固定入口卡：万能投喂口（文字 / 小票截图丢进来，自动记账、建待办、存收集箱）
private struct OmniboxEntryCard: View {
    var onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.purple))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("万能投喂口"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr("丢进文字、小票截图，自动记账、建待办、存收集箱"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TodoCategoryCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [TodoFilterCategory]
    let onSave: ([TodoFilterCategory]) -> Void

    init(categories: [TodoFilterCategory], onSave: @escaping ([TodoFilterCategory]) -> Void) {
        self._categories = State(initialValue: categories)
        self.onSave = onSave
    }

    private var hiddenCategories: [TodoFilterCategory] {
        TodoFilterCategory.allCases.filter { !categories.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("首页显示顺序") {
                    ForEach(categories) { category in
                        HStack(spacing: 10) {
                            Image(systemName: categoryIcon(category))
                                .foregroundStyle(categoryColor(category))
                                .frame(width: 24)
                            Text(L10n.tr(category.rawValue))
                            Spacer()
                            if category == .all {
                                Text("固定")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        categories.move(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { offsets in
                        categories.remove(atOffsets: offsets)
                        if !categories.contains(.all) { categories.insert(.all, at: 0) }
                    }
                }

                if !hiddenCategories.isEmpty {
                    Section("添加分类") {
                        ForEach(hiddenCategories) { category in
                            Button {
                                categories.append(category)
                            } label: {
                                Label(L10n.tr(category.rawValue), systemImage: categoryIcon(category))
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("定制首页分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(categories)
                        dismiss()
                    }
                }
            }
        }
    }

    private func categoryIcon(_ category: TodoFilterCategory) -> String {
        switch category {
        case .all: return "square.grid.2x2.fill"
        case .general: return "checkmark.circle"
        case .recurring: return "repeat"
        case .parcel: return "shippingbox.fill"
        case .life: return "heart.fill"
        case .alert: return "exclamationmark.triangle.fill"
        case .parenting: return "figure.and.child.holdinghands"
        case .pet: return "pawprint.fill"
        }
    }

    private func categoryColor(_ category: TodoFilterCategory) -> Color {
        switch category {
        case .all: return .secondary
        case .general: return .blue
        case .recurring: return .indigo
        case .parcel: return .orange
        case .life: return .green
        case .alert: return .red
        case .parenting: return .pink
        case .pet: return .orange
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
    @ObservedObject private var router = NavigationRouter.shared
    @State private var isCopied: Bool = false
    @State private var isAnimatingCompletion: Bool = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.0
    @State private var isShowingShareSheet: Bool = false
    @State private var isShowingEditSheet: Bool = false
    @State private var isShowingQRCodeSheet: Bool = false

    private var isEffectivelyDone: Bool {
        item.status == .done || isAnimatingCompletion
    }

    private var isNotificationFocused: Bool {
        router.focusedTodoID == item.id
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
        case .exercise: return .green
        case .childVaccine, .childGrowth, .childMilestone, .childHealth: return .pink
        case .pet: return .orange
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
                        // 同步桌面/锁屏组件快照（含技能练习的「今日已打卡」状态）
                        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
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
                        Text(L10n.tr(text))
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

                        Text(L10n.tr(item.title))
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

                    if let detail = item.displayConciseDetail, !detail.isEmpty {
                        Text(L10n.tr(detail))
                            .font(.footnote)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(typeColor.opacity(isEffectivelyDone ? 0.08 : 0.16))
                                .frame(width: seniorManager.isSeniorModeEnabled ? 28 : 24, height: seniorManager.isSeniorModeEnabled ? 28 : 24)
                            Image(systemName: item.type.icon)
                                .font(.caption.bold())
                                .foregroundStyle(isEffectivelyDone ? .secondary : typeColor)
                        }
                        .padding(.top, 1)

                        Text(item.displayConciseTitle)
                            .font(.body.weight(isEffectivelyDone ? .regular : (seniorManager.isHighContrastEnabled ? .bold : .semibold)))
                            .strikethrough(isEffectivelyDone)
                            .foregroundStyle(isEffectivelyDone ? .secondary : .primary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 6)

                        rowTrailingButtons
                    }

                    if let locText = item.displayLocationText, !locText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.85))
                            Text(locText)
                                .font(.caption)
                                .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                MapNavigationService.openDirections(to: locText)
                            } label: {
                                Label("导航", systemImage: "arrow.triangle.turn.up.right.diamond")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let detail = item.displayConciseDetail, !detail.isEmpty {
                        Text(L10n.tr(detail))
                            .font(.footnote)
                            .foregroundStyle(seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : .secondary)
                            .lineLimit(2)
                            .lineSpacing(3)
                    }
                }

                HStack(spacing: 8) {
                    if let due = item.dueAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                            Text(due.formatted(date: .numeric, time: .shortened))
                        }
                        .font(.caption2)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(due < .now && !isEffectivelyDone ? Color.red : (seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.7) : Color.secondary))
                    } else {
                        Text(item.createdAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(Color.primary.opacity(seniorManager.isHighContrastEnabled ? 0.65 : 0.4))
                    }

                    if item.isRecurring {
                        HStack(spacing: 3) {
                            Image(systemName: "repeat")
                            Text(item.recurrenceSummaryText)
                        }
                        .font(.caption2.bold())
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isEffectivelyDone ? Color.secondary.opacity(0.12) : Color.blue.opacity(0.12))
                        )
                    }

                    Spacer(minLength: 0)

                    if item.type == .parcel || item.type == .returnParcel {
                        rowTrailingButtons
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                isShowingEditSheet = true
                Haptic.light()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isNotificationFocused ? Color.orange.opacity(0.20) : .clear)
                .overlay {
                    if isNotificationFocused {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.orange.opacity(0.75), lineWidth: 2)
                    }
                }
        )
        .animation(.easeInOut(duration: 0.25), value: isNotificationFocused)
        .id(item.id)
        .opacity(isEffectivelyDone ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.25), value: isEffectivelyDone)
        .animation(.easeInOut(duration: 0.2), value: item.status)
        .padding(.vertical, 5)
        .contextMenu {
            if item.hasQRCodeOrTicket {
                Button("出示预约二维码 / 凭证", systemImage: "qrcode.viewfinder") {
                    isShowingQRCodeSheet = true
                    Haptic.medium()
                }
            }

            // 一键把取件码/行程倒计时推上灵动岛，并自动同步到 Apple Watch 智能叠放
            if item.status == .active,
               item.type == .parcel || item.type == .returnParcel || item.type == .travelBooking || item.type == .event {
                Button("🏝️ 上灵动岛（同步手表）", systemImage: "platter.filled.top.iphone") {
                    let started: Bool
                    if item.type == .travelBooking || item.type == .event {
                        started = LiveActivityService.startTravelActivity(for: item)
                    } else {
                        started = LiveActivityService.startPickupActivity(for: [item])
                    }
                    if started { Haptic.success() } else { Haptic.warning() }
                }
            }

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
        .sheet(isPresented: $isShowingQRCodeSheet) {
            TodoQRCodeQuickSheet(item: item)
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

    @ViewBuilder
    private var rowTrailingButtons: some View {
        HStack(spacing: 6) {
            if item.hasQRCodeOrTicket {
                Button {
                    isShowingQRCodeSheet = true
                    Haptic.medium()
                } label: {
                    Image(systemName: item.hasQRCode ? "qrcode" : "photo")
                        .font(seniorManager.isSeniorModeEnabled ? .title3.bold() : .subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: seniorManager.isSeniorModeEnabled ? 38 : 30, height: seniorManager.isSeniorModeEnabled ? 38 : 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快速调出预约二维码")
            }

            if seniorManager.isVoiceBroadcastEnabled {
                Button {
                    let speechText: String = {
                        if item.type == .parcel, let code = item.pickupCode {
                            let station = item.location ?? item.station ?? ""
                            return "快递取件码：\(code)，\(item.displayConciseTitle)。\(station)"
                        } else if item.type == .returnParcel {
                            let codeStr = item.pickupCode.map { "，寄件码：\($0)" } ?? ""
                            return "退货待办：\(item.displayConciseTitle)\(codeStr)。\(item.displayConciseDetail ?? "")"
                        } else {
                            let detail = item.displayConciseDetail ?? ""
                            return "\(item.displayConciseTitle)。\(detail)"
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
                        .frame(width: seniorManager.isSeniorModeEnabled ? 38 : 26, height: seniorManager.isSeniorModeEnabled ? 38 : 26)
                        .background(
                            Circle()
                                .fill(isCurrentSpeaking ? Color.orange.opacity(0.2) : (seniorManager.isSeniorModeEnabled ? Color.orange.opacity(0.12) : Color.clear))
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
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

    @State private var tab: Int = 0 // 0: 手动新建, 1: 短信/图片智能导入
    @State private var selectedCategory: TodoFilterCategory

    // 手动新建表单
    @State private var title: String = ""
    @State private var type: TodoType
    @State private var detail: String = ""
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var remindBeforeMinutes: Int = 0
    @State private var customRemindBeforeMinutes: Int = 120
    @State private var recurrenceRule: TodoRecurrenceRule = .none
    @State private var customIntervalDays: Int = 3
    @State private var pickupCode: String = ""
    @State private var station: String = ""

    // 图片/预约截图识别状态
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var isRecognizingImage: Bool = false
    @State private var imageRecognitionError: String? = nil
    @State private var qrCodePayload: String? = nil
    @State private var qrCodeImageData: Data? = nil
    @State private var attachmentImageData: Data? = nil
    @State private var showingQRPreviewInAdd: Bool = false
    @State private var recognizedTravelPickup: TravelPickupMetadata? = nil
    @State private var recognizedRawText: String? = nil

    // 出行前购票与文博景区预约确认项
    @State private var addCompanionTickets: Bool = false
    @State private var includeTrainReminder: Bool = true
    @State private var includeFlightReminder: Bool = true
    @State private var includeScenicReminder: Bool = true
    @State private var customTrainDate: Date? = nil
    @State private var customScenicDate: Date? = nil

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
        case .parenting:
            defaultType = .childVaccine
            defaultHasDueDate = true
            defaultDue = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        case .pet:
            defaultType = .pet
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
            return [.general, .travelBooking, .parcel, .medication, .housework, .exercise, .charging, .subscription, .vehicleCare, .bill, .itemExpiry, .anniversary, .hydration, .event, .childVaccine, .childGrowth, .childMilestone, .childHealth, .pet]
        case .general:
            return [.general, .travelBooking, .event]
        case .recurring:
            return [.general, .medication, .housework, .charging, .hydration, .bill, .event]
        case .parcel:
            return [.parcel, .returnParcel]
        case .life:
            return [.medication, .exercise, .charging, .hydration]
        case .alert:
            return [.bill, .travelBooking, .vehicleCare, .subscription, .itemExpiry, .anniversary, .passwordSecurity]
        case .parenting:
            return [.childVaccine, .childGrowth, .childMilestone, .childHealth]
        case .pet:
            return [.pet]
        }
    }

    /// 切换大板块时自动适配子类型
    private func onCategoryChanged(_ newCat: TodoFilterCategory) {
        selectedCategory = newCat
        let candidates = availableTypesForCategory
        if !candidates.contains(type) {
            type = candidates.first ?? .general
        }
        if newCat == .life || newCat == .alert || newCat == .recurring || newCat == .parenting || newCat == .pet {
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
        case .travelBooking:
            return "出行与购票（如：国庆返乡高铁票、下周上海出差机票、假期旅行）"
        case .exercise:
            return "运动事项（如：晚间跑步、瑜伽训练、球类活动）"
        case .childVaccine:
            return "疫苗接种（如：宝宝 6 月龄疫苗预约）"
        case .childGrowth:
            return "成长测量（如：记录宝宝身高体重）"
        case .childMilestone:
            return "成长里程碑（如：记录宝宝第一次走路）"
        case .childHealth:
            return "健康随访（如：宝宝儿保复查）"
        case .pet:
            return "宠物事项（如：喂食、驱虫、洗护或宠物就医）"
        case .skillLearning:
            return "学习任务（如：练 20 分钟和弦切换、读完第 3 章并做笔记）"
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
        case .travelBooking:
            return [
                QuickSuggestion(title: "抢购往返高铁票（提前15天）", detail: "12306 开售首日准点抢票并候补", defaultHourOffset: 360),
                QuickSuggestion(title: "预订假期往返机票（提前15-30天）", detail: "比对各大航司特惠早鸟票并锁定酒店", defaultHourOffset: 720),
                QuickSuggestion(title: "热门博物馆/特展预约（提前7天）", detail: "关注故宫、国博、省博等放票时间实名分时段预约", defaultHourOffset: 168),
                QuickSuggestion(title: "5A景区门票/游船预约（提前7-14天）", detail: "提前分时段锁定景区入场名额与索道特展票", defaultHourOffset: 168),
                QuickSuggestion(title: "出差往返机票预订", detail: "确认航班班次与行程报销凭证", defaultHourOffset: 120),
                QuickSuggestion(title: "长假节假日火车票抢票", detail: "提前设置开售提醒闹钟与候补", defaultHourOffset: 360)
            ]
        case .exercise:
            return [
                QuickSuggestion(title: "晚间跑步训练", detail: "热身后进行 30 分钟有氧运动", defaultHourOffset: 4),
                QuickSuggestion(title: "瑜伽或拉伸", detail: "放松肩颈和腰背，保持规律活动", defaultHourOffset: 24)
            ]
        case .childVaccine:
            return [QuickSuggestion(title: "预约宝宝疫苗接种", detail: "核对月龄和接种本，提前预约门诊", defaultHourOffset: 72)]
        case .childGrowth:
            return [QuickSuggestion(title: "记录宝宝身高体重", detail: "同步记录测量日期和月龄", defaultHourOffset: 168)]
        case .childMilestone:
            return [QuickSuggestion(title: "记录宝宝成长里程碑", detail: "记下发生日期、场景和当时的心情", defaultHourOffset: nil)]
        case .childHealth:
            return [QuickSuggestion(title: "宝宝儿保复查", detail: "带好既往测量记录和就诊资料", defaultHourOffset: 168)]
        case .pet:
            return [
                QuickSuggestion(title: "给宠物喂食", detail: "准备好每日粮食和饮水", defaultHourOffset: 8),
                QuickSuggestion(title: "宠物驱虫", detail: "按周期完成体内外驱虫", defaultHourOffset: 720),
                QuickSuggestion(title: "预约宠物洗护", detail: "确认时间并准备牵引绳或航空箱", defaultHourOffset: 72),
                QuickSuggestion(title: "宠物就医复查", detail: "带好病历、用药记录和检查结果", defaultHourOffset: 48)
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
                        Text("短信/图片智能导入").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))

                // 图片/预约截图识别与二维码提取区（手动新建与智能导入均支持）
                Section {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.blue.opacity(0.14))
                                    .frame(width: 36, height: 36)
                                if isRecognizingImage {
                                    ProgressView()
                                } else {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.body.bold())
                                        .foregroundStyle(.blue)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isRecognizingImage ? "正在识别时间、地点与票务信息…" : "从相册选择电影票 / 门票 / 预约截图 / 取件图")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    Text("自动提取事件名称、活动时间、场馆地址与核销二维码")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .onChange(of: selectedPhotoItem) { _, newItem in
                            guard let newItem else { return }
                            Task { await loadAndRecognizePhoto(newItem) }
                        }

                        if UIPasteboard.general.hasImages {
                            Button {
                                if let clipImg = UIPasteboard.general.image {
                                    Task { await recognizeFromUIImage(clipImg) }
                                }
                            } label: {
                                Label("识别剪贴板中的截图", systemImage: "doc.on.clipboard.fill")
                                    .font(.subheadline)
                            }
                        }

                        if let err = imageRecognitionError {
                            Text(L10n.tr(err))
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        // 已识别出的预约二维码与原图凭证预览卡片
                        if qrCodeImageData != nil || (qrCodePayload != nil && !(qrCodePayload?.isEmpty ?? true)) || attachmentImageData != nil {
                            HStack(spacing: 12) {
                                if let qrData = qrCodeImageData, let uiImg = UIImage(data: qrData) {
                                    Image(uiImage: uiImg)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 64, height: 64)
                                        .padding(4)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                                } else if let payload = qrCodePayload, let genImg = QRCodeService.generateQRCode(from: payload, targetSize: 200) {
                                    Image(uiImage: genImg)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 64, height: 64)
                                        .padding(4)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else if let attachData = attachmentImageData, let uiImg = UIImage(data: attachData) {
                                    Image(uiImage: uiImg)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                        Text(qrCodeImageData != nil || qrCodePayload != nil ? "已提取预约二维码" : "已关联截图凭证")
                                            .font(.subheadline.bold())
                                    }
                                    if let payload = qrCodePayload, !payload.isEmpty {
                                        Text("码号：\(payload)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 8) {
                                        Button {
                                            showingQRPreviewInAdd = true
                                            Haptic.light()
                                        } label: {
                                            Label("预览亮码", systemImage: "qrcode.viewfinder")
                                                .font(.caption2.bold())
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.mini)

                                        Button(role: .destructive) {
                                            qrCodePayload = nil
                                            qrCodeImageData = nil
                                            attachmentImageData = nil
                                            recognizedTravelPickup = nil
                                        } label: {
                                            Text("清除")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text(tab == 1 ? "图片 / 预约截图识别" : "快捷识图建待办")
                    }

                if let pickup = recognizedTravelPickup {
                    Section {
                        TravelTicketPickupConfigView(
                            pickup: Binding(
                                get: { pickup },
                                set: { updated in
                                    recognizedTravelPickup = updated
                                    title = updated.resolvedTitle
                                    station = updated.resolvedLocation
                                    hasDueDate = true
                                    dueDate = updated.plannedTargetTime
                                    detail = updated.resolvedDetail
                                }
                            )
                        )
                    } header: {
                        Text("火车票 / 机票接人时间与汇合地点")
                    } footer: {
                        Text("已根据票面到站时间（\(pickup.arrivalAt.formatted(date: .omitted, time: .shortened))）扣除提前量（\(pickup.advanceMinutes)分钟），将到达「\(pickup.resolvedLocation)」的目标时间设为 \(pickup.plannedTargetTime.formatted(date: .omitted, time: .shortened))。")
                    }
                }

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
                                Text(L10n.tr(cat.rawValue)).tag(cat)
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
                    Section("待办内容与地点") {
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
                                                Text(L10n.tr(s.title))
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

                        // 快递/退货模式专属快捷输入字段 vs 日程场馆地点
                        if type == .parcel {
                            TextField("取件码（如：3-2-104 或 5821）", text: $pickupCode)
                                .font(.body.monospaced())

                            TextField("存放驿站/自提柜（选填，如：菜鸟驿站、丰巢）", text: $station)
                        } else if type == .returnParcel {
                            TextField("寄件码 / 售后运单号（选填）", text: $pickupCode)
                                .font(.body.monospaced())

                            TextField("寄件方式/网点（选填，如：顺丰上门取件、驿站代寄）", text: $station)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundStyle(.red.opacity(0.8))
                                TextField("场馆 / 地点（选填，如：西岸国际会展中心）", text: $station)
                            }
                        }
                    }

                    // 4. 详情与提醒时间
                    Section("详情与提醒时间") {
                        TextField("补充备注/详情说明（选填）", text: $detail, axis: .vertical)
                            .lineLimit(2...4)

                        Toggle("设置提醒时间", isOn: $hasDueDate)
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

                            if recognizedTravelPickup == nil && TravelTicketReminderManager.shouldSuggestCrossCityTickets(
                                title: title,
                                station: station,
                                location: station,
                                detail: detail,
                                hasQRCodeOrTicket: qrCodeImageData != nil || qrCodePayload != nil || attachmentImageData != nil,
                                type: type
                            ) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle(isOn: $addCompanionTickets) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "ticket.fill")
                                                .foregroundStyle(.indigo)
                                            Text("同时添加出行前购票与预约待办")
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.indigo)
                                        }
                                    }

                                    let cal = Calendar.current
                                    let trainDate = cal.date(byAdding: .day, value: -15, to: dueDate) ?? dueDate
                                    let scenicDate = cal.date(byAdding: .day, value: -7, to: dueDate) ?? dueDate
                                    let f: DateFormatter = {
                                        let df = DateFormatter()
                                        df.dateFormat = "M月d日"
                                        return df
                                    }()

                                    if addCompanionTickets {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .top, spacing: 6) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                                Text("政策兜底提示：票务与场馆预约政策常变动，请以官方最新公告为准，可自主核对并微调提醒时间：")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.vertical, 2)

                                            VStack(alignment: .leading, spacing: 4) {
                                                Toggle(isOn: $includeTrainReminder) {
                                                    Label("🚄 火车票起售提醒（提前15天）", systemImage: "train.side.front.car")
                                                        .font(.caption.bold())
                                                }
                                                if includeTrainReminder {
                                                    DatePicker(
                                                        "确认放票提醒时间",
                                                        selection: Binding(
                                                            get: { customTrainDate ?? trainDate },
                                                            set: { customTrainDate = $0 }
                                                        ),
                                                        displayedComponents: [.date, .hourAndMinute]
                                                    )
                                                    .datePickerStyle(.compact)
                                                    .font(.caption2)
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Toggle(isOn: $includeScenicReminder) {
                                                    Label("🏛️ 场馆景区预约提醒（提前7天）", systemImage: "building.columns.fill")
                                                        .font(.caption.bold())
                                                }
                                                if includeScenicReminder {
                                                    DatePicker(
                                                        "确认预约提醒时间",
                                                        selection: Binding(
                                                            get: { customScenicDate ?? scenicDate },
                                                            set: { customScenicDate = $0 }
                                                        ),
                                                        displayedComponents: [.date, .hourAndMinute]
                                                    )
                                                    .datePickerStyle(.compact)
                                                    .font(.caption2)
                                                }
                                            }

                                            Toggle(isOn: $includeFlightReminder) {
                                                Label("✈️ 提前15-30天 机票酒店黄金预订期", systemImage: "airplane")
                                                    .font(.caption.bold())
                                            }
                                        }
                                        .padding(.leading, 6)
                                        .padding(.vertical, 4)
                                    } else {
                                        HStack(spacing: 4) {
                                            Label("🚄 火车票：\(f.string(from: trainDate))起售（提前15天）", systemImage: "train.side.front.car")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                        HStack(spacing: 4) {
                                            Label("🏛️ 场馆景区：\(f.string(from: scenicDate))预约（提前7天）", systemImage: "building.columns.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.purple)
                                        }
                                        HStack(spacing: 4) {
                                            Label("✈️ 机票预订：提前15-30天黄金期", systemImage: "airplane")
                                                .font(.caption2)
                                                .foregroundStyle(.teal)
                                        }
                                    }

                                    if let guide = TravelTicketReminderManager.detectDestinationGuide(for: title) {
                                        Text("【放票指南】\(guide)")
                                            .font(.caption2)
                                            .foregroundStyle(.purple)
                                            .padding(.top, 2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        Picker("重复周期", selection: $recurrenceRule) {
                            ForEach(TodoRecurrenceRule.allCases) { rule in
                                Label(L10n.tr(rule.rawValue), systemImage: rule.icon).tag(rule)
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
                        Text("或粘贴短信 / 聊天文本")
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
            .sheet(isPresented: $showingQRPreviewInAdd) {
                TodoQRCodeQuickSheet(
                    title: title.isEmpty ? "预约凭证预览" : title,
                    locationText: station.isEmpty ? nil : station,
                    dueAt: hasDueDate ? dueDate : nil,
                    detail: detail.isEmpty ? nil : detail,
                    qrCodePayload: qrCodePayload,
                    qrCodeImageData: qrCodeImageData,
                    attachmentImageData: attachmentImageData
                )
            }
            .onAppear {
                checkClipboard()
            }
        }
    }

    private func loadAndRecognizePhoto(_ pickerItem: PhotosPickerItem) async {
        await MainActor.run {
            isRecognizingImage = true
            imageRecognitionError = nil
        }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run {
                isRecognizingImage = false
                imageRecognitionError = "无法读取所选图片，请重试"
            }
            return
        }
        await recognizeFromUIImage(image)
    }

    private func recognizeFromUIImage(_ image: UIImage) async {
        await MainActor.run {
            isRecognizingImage = true
            imageRecognitionError = nil
        }
        do {
            let result = try await OCRService.shared.recognizeTodo(from: image)
            await MainActor.run {
                isRecognizingImage = false
                recognizedTravelPickup = result.travelPickup
                recognizedRawText = result.rawText.isEmpty ? nil : result.rawText
                title = result.title
                type = result.type
                if result.type == .parcel || result.type == .returnParcel {
                    selectedCategory = .parcel
                } else {
                    selectedCategory = .general
                }
                if let code = result.pickupCode, !code.isEmpty {
                    pickupCode = code
                }
                if let loc = result.location ?? result.station, !loc.isEmpty {
                    station = loc
                }
                if let recognizedDue = result.dueAt {
                    hasDueDate = true
                    dueDate = recognizedDue
                    remindBeforeMinutes = result.travelPickup != nil ? 0 : 60
                }
                if let recDetail = result.detail, !recDetail.isEmpty {
                    detail = recDetail
                }
                qrCodePayload = result.qrCodePayload
                qrCodeImageData = result.qrCodeImageData
                attachmentImageData = result.attachmentImageData
                withAnimation {
                    tab = 0
                }
                Haptic.success()
            }
        } catch {
            await MainActor.run {
                isRecognizingImage = false
                imageRecognitionError = "图片识别出错：\(error.localizedDescription)"
            }
        }
    }

    private func createTodo() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        if hasDueDate { Task { await NotificationService.requestAuthorization() } }

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
            sourceText: recognizedRawText,
            sortOrder: minOrder - 1,
            recurrenceRuleRaw: recurrenceRule == .none ? nil : recurrenceRule.rawValue,
            recurrenceIntervalDays: recurrenceRule == .custom ? customIntervalDays : recurrenceRule.dayInterval(customDays: customIntervalDays),
            remindBeforeMinutes: remindBeforeMinutes == -1 ? customRemindBeforeMinutes : remindBeforeMinutes,
            qrCodePayload: qrCodePayload,
            qrCodeImageData: qrCodeImageData,
            attachmentImageData: attachmentImageData
        )
        context.insert(item)
        TodoNotificationManager.shared.scheduleNotification(for: item)

        // 用户显式勾选并确认的出行配套购票与文博景区预约待办
        if addCompanionTickets && hasDueDate {
            let proposed = TravelTicketReminderManager.shared.generateProposedTicketTodos(
                title: trimmedTitle,
                departureDate: dueDate
            )
            var offset = 2
            for var p in proposed {
                var shouldAdd = false
                if p.categoryKey == "train" && includeTrainReminder {
                    shouldAdd = true
                    if let cDate = customTrainDate {
                        p.dueAt = cDate
                        p.isCustomized = true
                    }
                }
                else if p.categoryKey == "flight" && includeFlightReminder {
                    shouldAdd = true
                }
                else if p.categoryKey == "scenic" && includeScenicReminder {
                    shouldAdd = true
                    if let cDate = customScenicDate {
                        p.dueAt = cDate
                        p.isCustomized = true
                    }
                }

                if shouldAdd {
                    let noteSuffix = p.isCustomized ? "\n（注：预约时间已由用户核对并手动确认）" : ""
                    let compItem = TodoItem(
                        type: .travelBooking,
                        status: .active,
                        title: p.title,
                        detail: p.detail + noteSuffix,
                        dueAt: p.dueAt,
                        sortOrder: minOrder - offset,
                        remindBeforeMinutes: p.remindBeforeMinutes
                    )
                    context.insert(compItem)
                    TodoNotificationManager.shared.scheduleNotification(for: compItem)
                    offset += 1
                }
            }
        }

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
