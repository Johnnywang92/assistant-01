import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

/// 待办单次 O(N) 极速分类存储，避免视图每次刷新时连续发起十余次全量数组 filter
fileprivate struct TodoClassification {
    var active: [TodoItem] = []
    var review: [TodoItem] = []
    var done: [TodoItem] = []
    var recurring: [TodoItem] = []
    var overdue: [TodoItem] = []

    var generals: [TodoItem] = []
    var works: [TodoItem] = []
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
        let now = Date.now
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
                if let due = item.dueAt, due < now {
                    overdue.append(item)
                }
            }
        }
        // 先对所有活跃待办按“紧急性 60% + 重要性 40%”进行单次全局排序，逾期事项按截止时间升序
        TodoPriority.sort(&active)
        overdue.sort { ($0.dueAt ?? .now) < ($1.dueAt ?? .now) }

        // 各活跃分组直接沿用已排好序的 active 流进行分发，天然保持正确优先级，避免 15 次冗余全量排序
        for item in active {
            if item.isRecurring { recurring.append(item) }
            switch item.type {
            case .general, .event, .travelBooking: generals.append(item)
            case .skillLearning: generals.append(item)
            case .work: works.append(item)
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
    @State private var itemToEdit: TodoItem? = nil
    @State private var itemForQRCode: TodoItem? = nil
    @State private var confirmingTicketInfo: UpcomingTravelTicketInfo? = nil
    @State private var prepToastMessage: String? = nil
    @State private var isReordering: Bool = false
    @State private var searchText: String = ""
    @State private var showOverdueTriage = false
    @AppStorage("overdue_triage_last_date") private var lastTriageDateKey = ""

    // MARK: - 单次 O(N) 极速分类缓存（彻底消除视图树重复全表遍历）
    /// 分类结果引用缓存：视图树内 200+ 处转发属性访问在同一次渲染中只真正计算一次。
    /// 增加渲染脉冲（50ms）节流保护，单次视图树评估内只哈希校验一次，消除卡顿。
    private final class TodoClassificationCache {
        var key: Int = -1
        var query: String = ""
        var lastComputedTime: CFAbsoluteTime = 0
        var value: TodoClassification?
    }

    @State private var classificationCache = TodoClassificationCache()

    private var classified: TodoClassification {
        let now = CFAbsoluteTimeGetCurrent()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = classificationCache.value,
           classificationCache.query == query,
           (now - classificationCache.lastComputedTime) < 0.05 {
            return cached
        }

        let key = Self.classificationKey(for: todos)
        if let cached = classificationCache.value, classificationCache.key == key, classificationCache.query == query {
            classificationCache.lastComputedTime = now
            return cached
        }
        let source: [TodoItem]
        if query.isEmpty {
            source = todos
        } else {
            source = todos.filter { matchesSearch($0, query: query) }
        }
        let result = TodoClassification(from: source)
        classificationCache.key = key
        classificationCache.query = query
        classificationCache.lastComputedTime = now
        classificationCache.value = result
        return result
    }

    /// 轻量内容指纹：覆盖 TodoClassification 分桶与 TodoPriority 排序所依赖的字段。
    private static func classificationKey(for items: [TodoItem]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.statusRaw)
            hasher.combine(item.typeRaw)
            hasher.combine(item.isRecurring)
            hasher.combine(item.sortOrder)
            hasher.combine(item.dueAt?.timeIntervalSinceReferenceDate ?? -1)
            hasher.combine(item.title)
            hasher.combine(item.detail ?? "")
        }
        return hasher.finalize()
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
        case .work: return .work
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

    /// 逾期事项：由分类器单次 O(N) 遍历统一收集，无需重复全表 filter + sort
    private var overdueTodos: [TodoItem] { classified.overdue }

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

    /// 搜索/深链直达待办详情：等搜索弹层 dismiss 动画结束再叠弹层，避免两个 sheet 撞呈现时序
    private func presentTodoDetail(for id: UUID?) {
        guard let id else { return }
        router.requestedTodoDetailID = nil
        let item = todos.first(where: { $0.id == id })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            itemToEdit = item
        }
    }

    private var generals: [TodoItem] { classified.generals }
    private var works: [TodoItem] { classified.works }
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
                HomeGreetingCard(activeCount: activeTodos.count)
                    .wallpaperReadableText()
                // 万能投喂口固定入口：丢进文字/截图，自动记账、建待办、存收集箱
                OmniboxEntryCard {
                    Haptic.light()
                    router.activeSheet = .omnibox
                }
                LifeEventHomeBanner()

                // 顶部固定横向分类 Tab 栏（带指示胶囊与角标）
                filterTabBar
                    .wallpaperReadableText()

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
                        AppMotion.animate(.easeInOut(duration: 0.35)) {
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
                                AppMotion.animate(.easeInOut(duration: 0.35)) {
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
                            AppMotion.animate(.spring(response: 0.32, dampingFraction: 0.8)) {
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
                            router.prefilledSearchQuery = searchText.isEmpty ? nil : searchText
                            router.activeSheet = .unifiedSearch
                            Haptic.light()
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("全景搜索")

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
                    initialCategory: (item.type == .parcel || item.type == .returnParcel) ? .parcel : .all,
                    initialSelectedIds: [item.id]
                )
            }
            .sheet(item: $itemToEdit) { item in
                EditTodoSheet(item: item)
            }
            .sheet(item: $itemForQRCode) { item in
                TodoQRCodeQuickSheet(item: item)
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
            // 统一搜索/深链命中待办：在滚动定位之外直达详情弹层
            .onChange(of: router.requestedTodoDetailID) { _, id in
                presentTodoDetail(for: id)
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
                // 搜索弹层先于本页挂载时 onChange 不触发，这里兜底消费直达详情的请求
                presentTodoDetail(for: router.requestedTodoDetailID)
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

    @ViewBuilder
    private func todoRow(_ item: TodoItem, within items: [TodoItem]) -> some View {
        TodoRow(
            item: item,
            isHighlighted: highlightedTodoID == item.id,
            onMoveToTop: { moveItemToTop(item, within: items) },
            onMoveUp: { moveItemUp(item, within: items) },
            onMoveDown: { moveItemDown(item, within: items) },
            onEnterReorder: { AppMotion.animate { isReordering = true } },
            onEdit: { itemToEdit = item },
            onShowQRCode: { itemForQRCode = item },
            onShare: { itemToShare = item }
        )
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
                AppMotion.animate(.spring(response: 0.32, dampingFraction: 0.8)) {
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
                .foregroundStyle(AppColor.warning)

            Text("长辈关怀大字模式")
                .font(.caption.bold())
                .foregroundStyle(AppColor.warning)

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
                .background(Capsule().fill(AppColor.softFill(AppColor.warning, opacity: 0.18)))
                .foregroundStyle(AppColor.warning)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(AppColor.softFill(AppColor.warning, opacity: 0.08))
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
                    AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
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
                AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
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
                    AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
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
        AppMotion.animate(.spring(duration: 0.25)) {
            prepToastMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            AppMotion.animate(.easeInOut(duration: 0.25)) {
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
                    .wallpaperReadableText()

                    Spacer()

                    Button {
                        AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isGroupedByType.toggle()
                        }
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 4) {
                            Text(isGroupedByType ? "切换为自由排序流" : "按板块分类")
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AppColor.softFill(AppColor.primary)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("切换待办的展示方式：板块分组或全局自由排序")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))

            if !isGroupedByType {
                // 自由排序流：所有待办在一个连续列表中，支持任意事项跨类型上下拖动！
                Section("事项清单（\(activeTodos.count)）") {
                    ForEach(activeTodos) { item in
                        todoRow(item, within: activeTodos)
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
                    todoRow(item, within: generals)
                }
                .onMove { from, to in reorder(items: generals, fromOffsets: from, toOffset: to) }
            }
        }
        if !works.isEmpty {
            Section("💼 工作待办（\(works.count)）") {
                ForEach(works) { item in
                    todoRow(item, within: works)
                }
                .onMove { from, to in reorder(items: works, fromOffsets: from, toOffset: to) }
            }
        }
        if !parcels.isEmpty {
            Section("📦 待取快递（\(parcels.count)）") {
                ForEach(parcels) { item in
                    todoRow(item, within: parcels)
                }
                .onMove { from, to in reorder(items: parcels, fromOffsets: from, toOffset: to) }
            }
        }
        if !returnParcels.isEmpty {
            Section("↩️ 待退货寄件（\(returnParcels.count)）") {
                ForEach(returnParcels) { item in
                    todoRow(item, within: returnParcels)
                }
                .onMove { from, to in reorder(items: returnParcels, fromOffsets: from, toOffset: to) }
            }
        }
        if !medications.isEmpty {
            Section("💊 服药提醒（\(medications.count)）") {
                ForEach(medications) { item in
                    todoRow(item, within: medications)
                }
                .onMove { from, to in reorder(items: medications, fromOffsets: from, toOffset: to) }
            }
        }
        if !chargings.isEmpty {
            Section("⚡️ 设备充电预警（\(chargings.count)）") {
                ForEach(chargings) { item in
                    todoRow(item, within: chargings)
                }
                .onMove { from, to in reorder(items: chargings, fromOffsets: from, toOffset: to) }
            }
        }
        if !houseworks.isEmpty {
            Section("🧹 周期家务（\(houseworks.count)）") {
                ForEach(houseworks) { item in
                    todoRow(item, within: houseworks)
                }
                .onMove { from, to in reorder(items: houseworks, fromOffsets: from, toOffset: to) }
            }
        }
        if !subscriptions.isEmpty {
            Section("💳 续费与账单（\(subscriptions.count)）") {
                ForEach(subscriptions) { item in
                    todoRow(item, within: subscriptions)
                }
                .onMove { from, to in reorder(items: subscriptions, fromOffsets: from, toOffset: to) }
            }
        }
        if !expiries.isEmpty {
            Section("⚠️ 证件/物品临期（\(expiries.count)）") {
                ForEach(expiries) { item in
                    todoRow(item, within: expiries)
                }
                .onMove { from, to in reorder(items: expiries, fromOffsets: from, toOffset: to) }
            }
        }
        if !anniversaries.isEmpty {
            Section("🎁 纪念日（\(anniversaries.count)）") {
                ForEach(anniversaries) { item in
                    todoRow(item, within: anniversaries)
                }
                .onMove { from, to in reorder(items: anniversaries, fromOffsets: from, toOffset: to) }
            }
        }
        if !passwordTodos.isEmpty {
            Section("🔑 密码安全（\(passwordTodos.count)）") {
                ForEach(passwordTodos) { item in
                    todoRow(item, within: passwordTodos)
                }
                .onMove { from, to in reorder(items: passwordTodos, fromOffsets: from, toOffset: to) }
            }
        }
        if !vehicleTodos.isEmpty {
            Section("🚗 爱车守护（\(vehicleTodos.count)）") {
                ForEach(vehicleTodos) { item in
                    todoRow(item, within: vehicleTodos)
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
                    todoRow(item, within: otherActive)
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
                    todoRow(item, within: generals)
                }
                .onMove { from, to in reorder(items: generals, fromOffsets: from, toOffset: to) }
            }
        }
    }

    @ViewBuilder
    private func renderWorkSection() -> some View {
        Section(works.isEmpty ? "工作待办" : "💼 工作待办（\(works.count)）") {
            if works.isEmpty {
                Text("暂无工作待办，点击右上角 ➕ 即可快速添加会议、周报或项目事项。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(works) { item in
                    todoRow(item, within: works)
                }
                .onMove { from, to in reorder(items: works, fromOffsets: from, toOffset: to) }
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
                    todoRow(item, within: recurring)
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
                        todoRow(item, within: parcels)
                    }
                    .onMove { from, to in reorder(items: parcels, fromOffsets: from, toOffset: to) }
                }
            }
            if !returnParcels.isEmpty {
                Section("↩️ 待退货寄件（\(returnParcels.count)）") {
                    ForEach(returnParcels) { item in
                        todoRow(item, within: returnParcels)
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
                        todoRow(item, within: medications)
                    }
                    .onMove { from, to in reorder(items: medications, fromOffsets: from, toOffset: to) }
                }
            }
            if !houseworks.isEmpty {
                Section("🧹 周期家务（\(houseworks.count)）") {
                    ForEach(houseworks) { item in
                        todoRow(item, within: houseworks)
                    }
                    .onMove { from, to in reorder(items: houseworks, fromOffsets: from, toOffset: to) }
                }
            }
            if !chargings.isEmpty {
                Section("⚡️ 设备充电预警（\(chargings.count)）") {
                    ForEach(chargings) { item in
                        todoRow(item, within: chargings)
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
                        todoRow(item, within: vehicleTodos)
                    }
                    .onMove { from, to in reorder(items: vehicleTodos, fromOffsets: from, toOffset: to) }
                }
            }
            if !subscriptions.isEmpty {
                Section("💳 自动续费与账单（\(subscriptions.count)）") {
                    ForEach(subscriptions) { item in
                        todoRow(item, within: subscriptions)
                    }
                    .onMove { from, to in reorder(items: subscriptions, fromOffsets: from, toOffset: to) }
                }
            }
            if !expiries.isEmpty {
                Section("⚠️ 证件/物品临期（\(expiries.count)）") {
                    ForEach(expiries) { item in
                        todoRow(item, within: expiries)
                    }
                    .onMove { from, to in reorder(items: expiries, fromOffsets: from, toOffset: to) }
                }
            }
            if !anniversaries.isEmpty {
                Section("🎁 纪念日（\(anniversaries.count)）") {
                    ForEach(anniversaries) { item in
                        todoRow(item, within: anniversaries)
                    }
                    .onMove { from, to in reorder(items: anniversaries, fromOffsets: from, toOffset: to) }
                }
            }
            if !passwordTodos.isEmpty {
                Section("🔑 密码安全（\(passwordTodos.count)）") {
                    ForEach(passwordTodos) { item in
                        todoRow(item, within: passwordTodos)
                    }
                    .onMove { from, to in reorder(items: passwordTodos, fromOffsets: from, toOffset: to) }
                }
            }
        }
    }

    @ViewBuilder
    private func renderParentingSection() -> some View {
        Section("亲子育儿（\(parentingTodos.count)）") {
            if parentingTodos.isEmpty {
                Text("暂无育儿待办，可添加疫苗、成长测量或健康随访提醒。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(parentingTodos) { item in
                    todoRow(item, within: parentingTodos)
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
                    todoRow(item, within: petTodos)
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
                            AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.82)) {
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
                AppMotion.animate(.easeInOut(duration: 0.2)) { proxy.scrollTo(category, anchor: .center) }
            }
        }
        .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemBackground))
    }

    @ViewBuilder
    private func renderPageContent(for category: TodoFilterCategory) -> some View {
        List {
            // 放进列表头部，使“今日安排”可以随首页内容向上滚动，仅在全部总览页挂载以大幅减少后台多页面重复查询
            if category == .all {
                Section {
                    EmptyView()
                } header: {
                    VStack(spacing: 4) {
                        TodayBriefingView(items: activeTodos)
                        // Structured 式今日时间轴：起床/下班锚点 + 日程 + 定时待办 + 打卡，
                        // 自动标出空闲时段，一眼判断"今天塞不塞得下一件新事"。
                        DayTimelineView(items: activeTodos)
                    }
                    .textCase(nil)
                }
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
            case .work:
                renderWorkSection()
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
                        AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
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
                                .background(Capsule().fill(AppColor.softFill(AppColor.success, opacity: 0.15)))
                                .foregroundStyle(AppColor.success)

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
        case .work: return works.count
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
        case .work: return .brown
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
        case .work:
            return done.filter { $0.type == .work }
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
