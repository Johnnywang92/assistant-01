import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

struct TodoListView: View {
    @Environment(\.modelContext) private var context
    /// 性能：首页只订阅未完成（活跃/待确认）事项；历史已完成事项单独限量订阅，
    /// 避免随着归档累积，每次状态变化都对全部历史待办做指纹哈希与分类。
    @Query(
        filter: #Predicate<TodoItem> { $0.statusRaw != "done" },
        sort: [
            SortDescriptor(\TodoItem.sortOrder, order: .forward),
            SortDescriptor(\TodoItem.createdAt, order: .reverse)
        ]
    ) private var todos: [TodoItem]

    /// 首页「已完成事项」折叠卡片只展示最近完成的一批，完整历史在归档大厅中查看
    static let recentDoneLimit = 300
    private static var recentDoneDescriptor: FetchDescriptor<TodoItem> {
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate<TodoItem> { $0.statusRaw == "done" },
            sortBy: [
                SortDescriptor(\TodoItem.completedAt, order: .reverse),
                SortDescriptor(\TodoItem.createdAt, order: .reverse)
            ]
        )
        descriptor.fetchLimit = recentDoneLimit
        return descriptor
    }
    @Query(TodoListView.recentDoneDescriptor) private var recentDoneTodos: [TodoItem]

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @AppStorage("all_tab_grouping_mode") private var isGroupedByType: Bool = false
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var weatherAlerts = WeatherAlertService.shared
    @AppStorage(AppBackgroundStyle.defaultsKey) private var bgStyleRaw = AppBackgroundStyle.system.rawValue
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
    @State private var selectedTagFilter: String? = nil
    @State private var highlightedTodoID: UUID?
    @State private var homeCategories: [TodoFilterCategory] = TodoCategoryPreferences.load()
    @State private var showCategoryCustomization = false
    @State private var itemToShare: TodoItem? = nil
    @State private var itemToEdit: TodoItem? = nil
    @State private var itemForQRCode: TodoItem? = nil
    @State private var confirmingTicketInfo: UpcomingTravelTicketInfo? = nil
    @State private var prepToastMessage: String? = nil
    @State private var isReordering: Bool = false
    @State private var crossModuleSearchText: String = ""
    @State private var showOverdueTriage = false
    @AppStorage("overdue_triage_last_date") private var lastTriageDateKey = ""
    /// 时间聚合条：当前展开的桶（逾期/今天/本周）详情弹层
    @State private var selectedTimeBucket: TodoTimeBucketKind?
    /// 一键整理逾期时指定的队列（取时间桶口径，与 chip 计数同源）；
    /// nil 时回落到分类器口径（早间自动清道夫路径）
    @State private var triageItemsOverride: [TodoItem]?

    /// 只订阅风格 key：壁纸预渲染完成或调参时不再重建整个待办页
    private var isCustomBackgroundActive: Bool {
        AppBackgroundStyle(rawValue: bgStyleRaw) != .system
    }

    /// 当前是否处于搜索输入状态
    private var isSearching: Bool {
        !crossModuleSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 单次 O(N) 极速分类缓存（彻底消除视图树重复全表遍历）
    /// 分类结果引用缓存：视图树内 200+ 处转发属性访问在同一次渲染中只真正计算一次。
    /// 增加渲染脉冲（50ms）节流保护，单次视图树评估内只哈希校验一次，消除卡顿。
    private final class TodoClassificationCache {
        var key: Int = -1
        var query: String = ""
        var activeCount: Int = -1
        var doneCount: Int = -1
        var lastComputedTime: CFAbsoluteTime = 0
        var value: TodoClassification?
    }

    @State private var classificationCache = TodoClassificationCache()

    /// 纪念日 / 出行购票横幅刷新的防抖任务：合并首帧挂载与连续待办变更触发的多次刷新
    @State private var reminderRefreshTask: Task<Void, Never>?

    private func scheduleReminderRefresh(delayMilliseconds: UInt64) {
        reminderRefreshTask?.cancel()
        reminderRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            anniversaryReminder.refreshActiveUpcoming(context: context)
            StartupMetrics.markOnce("todoList.task anniversariesDone")
            ticketReminder.refreshUpcomingTickets(context: context)
            StartupMetrics.markOnce("todoList.task ticketsDone")
        }
    }

    private var classified: TodoClassification {
        let now = CFAbsoluteTimeGetCurrent()
        let query = crossModuleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = classificationCache.value,
           classificationCache.query == query,
           classificationCache.activeCount == todos.count,
           classificationCache.doneCount == recentDoneTodos.count,
           (now - classificationCache.lastComputedTime) < 0.05 {
            return cached
        }

        let fingerprintBegin = CFAbsoluteTimeGetCurrent()
        let key = Self.classificationKey(for: todos, done: recentDoneTodos)
        StartupMetrics.markOnce("todoList.fingerprint", "n=\(todos.count)+\(recentDoneTodos.count) cost=\(Int((CFAbsoluteTimeGetCurrent() - fingerprintBegin) * 1000))ms")
        if let cached = classificationCache.value,
           classificationCache.key == key,
           classificationCache.query == query,
           classificationCache.activeCount == todos.count,
           classificationCache.doneCount == recentDoneTodos.count {
            classificationCache.lastComputedTime = now
            return cached
        }
        // 活跃与已完成分开过滤：省掉「先合并上万条、再整体过滤」的一次全量拷贝
        let filteredActive: [TodoItem]
        let filteredDone: [TodoItem]
        if query.isEmpty {
            filteredActive = todos
            filteredDone = recentDoneTodos
        } else {
            filteredActive = todos.filter { matchesSearch($0, query: query) }
            filteredDone = recentDoneTodos.filter { matchesSearch($0, query: query) }
        }
        let classifyBegin = CFAbsoluteTimeGetCurrent()
        let result = TodoClassification(active: filteredActive, done: filteredDone)
        StartupMetrics.markOnce("todoList.classify", "n=\(todos.count + recentDoneTodos.count) cost=\(Int((CFAbsoluteTimeGetCurrent() - classifyBegin) * 1000))ms")
        classificationCache.key = key
        classificationCache.query = query
        classificationCache.activeCount = todos.count
        classificationCache.doneCount = recentDoneTodos.count
        classificationCache.lastComputedTime = now
        classificationCache.value = result
        return result
    }

    /// 轻量内容指纹：覆盖 TodoClassification 分桶、搜索匹配与 TodoPriority 排序所依赖的字段。
    private static func classificationKey(for items: [TodoItem], done doneItems: [TodoItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.statusRaw)
            hasher.combine(item.typeRaw)
            hasher.combine(item.isRecurring)
            hasher.combine(item.sortOrder)
            hasher.combine(item.dueAt?.timeIntervalSinceReferenceDate ?? -1)
            hasher.combine(item.title)
            hasher.combine(item.detail ?? "")
            hasher.combine(item.pickupCode ?? "")
            hasher.combine(item.station ?? "")
            hasher.combine(item.location ?? "")
        }
        // 已完成事项只影响「已完成」分桶，按身份 + 状态/类型做轻量指纹即可
        hasher.combine(doneItems.count)
        for item in doneItems {
            hasher.combine(item.id)
            hasher.combine(item.statusRaw)
            hasher.combine(item.typeRaw)
            hasher.combine(item.isRecurring)
            hasher.combine(item.title)
        }
        return hasher.finalize()
    }

    /// 在已订阅的活跃/最近完成列表中查找待办，未命中时（例如很久以前完成的事项）回退到按 ID 精确查询
    private func findTodo(id: UUID) -> TodoItem? {
        if let item = todos.first(where: { $0.id == id }) { return item }
        if let item = recentDoneTodos.first(where: { $0.id == id }) { return item }
        var descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func matchesSearch(_ item: TodoItem, query: String) -> Bool {
        // 逐字段直接比较：原写法每条待办都要分配一个 7 元素数组，
        // 一万条待办 = 七万个临时数组，逐字输入时全程在制造垃圾
        if item.title.localizedCaseInsensitiveContains(query) { return true }
        if let detail = item.detail, detail.localizedCaseInsensitiveContains(query) { return true }
        if let pickupCode = item.pickupCode, pickupCode.localizedCaseInsensitiveContains(query) { return true }
        if let courier = item.courier, courier.localizedCaseInsensitiveContains(query) { return true }
        if let station = item.station, station.localizedCaseInsensitiveContains(query) { return true }
        if let location = item.location, location.localizedCaseInsensitiveContains(query) { return true }
        if let sourceText = item.sourceText, sourceText.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    private func category(for item: TodoItem) -> TodoFilterCategory {
        switch item.type {
        case .parcel, .returnParcel: return .parcel
        case .work: return .work
        case .medication, .charging, .housework, .exercise, .hydration: return .life
        case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare: return .alert
        case .childVaccine, .childGrowth, .childMilestone, .childHealth: return .parenting
        case .pet: return .pet
        case .other: return .other
        case .general, .event, .travelBooking: return .general
        case .skillLearning: return .general
        case .data: return .all
        }
    }

    private var allActiveTags: [String] {
        var set: Set<String> = []
        var result: [String] = []
        for todo in classified.active {
            for tag in todo.tags {
                if !set.contains(tag) {
                    set.insert(tag)
                    result.append(tag)
                }
            }
        }
        return result.sorted()
    }

    private var activeTodos: [TodoItem] {
        if let tag = selectedTagFilter {
            return classified.active.filter { $0.tags.contains(tag) }
        }
        return classified.active
    }

    /// 逾期事项：由分类器单次 O(N) 遍历统一收集，无需重复全表 filter + sort
    private var overdueTodos: [TodoItem] { classified.overdue }

    /// 时间聚合三桶（逾期/今天/本周）：与详情弹层同一分桶结果，chip 计数恒等于列表长度。
    /// 口径见 `TodoTimeAggregator`：日粒度、改期优先、完成不计。
    private var timeBuckets: TodoTimeBuckets {
        TodoTimeAggregator.bucket(
            activeTodos.map {
                TodoTimeSnapshot(
                    id: $0.id,
                    dueAt: $0.dueAt,
                    reminderOverrideAt: $0.reminderOverrideAt,
                    createdAt: $0.createdAt,
                    isDone: false
                )
            }
        )
    }

    /// 把桶内 ID 还原成待办，保持分桶排序（生效时间升序）
    private func bucketTodoItems(for kind: TodoTimeBucketKind) -> [TodoItem] {
        let ids = timeBuckets.ids(for: kind)
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(activeTodos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// 当天的逾期整理键，写入与读取口径必须同源
    private var todayTriageKey: String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    /// 早间逾期清道夫：每天首次进入待办页时，若有逾期事项则弹出发牌器。
    ///
    /// 日期键只在整理卡**真正出现**时写入（见 .sheet 的 onAppear）。
    /// 旧实现先写键再延时 0.9s 弹层：一旦转场被其他 sheet 抢占、或用户中途切 Tab，
    /// 弹层没呈现，当天却已被标记成「已整理」，用户整天都收不到提醒。
    private func maybePresentOverdueTriage() {
        let key = todayTriageKey
        guard lastTriageDateKey != key, !overdueTodos.isEmpty else { return }
        // 延迟弹出，避免抢在页面转场动画与其他首次弹窗之前
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard lastTriageDateKey != key, !showOverdueTriage else { return }
            showOverdueTriage = true
        }
    }
    private var review: [TodoItem] { classified.review }
    private var done: [TodoItem] { classified.done }
    private var recurring: [TodoItem] { classified.recurring }

    /// 搜索/深链直达待办详情：等搜索弹层 dismiss 动画结束再叠弹层，避免两个 sheet 撞呈现时序
    private func presentTodoDetail(for id: UUID?) {
        guard let id else { return }
        router.requestedTodoDetailID = nil
        let item = findTodo(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            itemToEdit = item
        }
    }

    private var todayTodos: [TodoItem] { classified.todayTodos }
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
            ScrollViewReader { proxy in
                renderPageContent(for: selectedFilter)
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
            .background(isCustomBackgroundActive ? Color.clear : Color(.systemGroupedBackground))
            .themedAppBackground()
            .navigationTitle(assistantName.isEmpty ? "小助" : assistantName)
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
            // 首页搜索栏：输入时实时筛选当前页待办（支持完整中文拼音输入），按键盘「搜索」或点击横幅唤起跨模块全景搜索。
            // 列表滑动时随用户手势自然收起或下拉展开。
            .searchable(
                text: $crossModuleSearchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: Text(L10n.tr("搜索待办、记录、数据、证件或设置…"))
            )
            .onSubmit(of: .search) {
                let trimmed = crossModuleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                router.prefilledSearchQuery = trimmed
                router.activeSheet = .unifiedSearch
                crossModuleSearchText = ""
            }
            .task {
                // 首屏渲染优先：延迟启动全域 16 表倒排索引构建，避免冷启动首帧抢占主线程。
                // SVC-09：重建触发已改成「按需」——服务内先比较数据变更令牌（各表行数 + 最新时间戳），
                // 已有索引且数据未变时直接返回，不会重复全表拉取；手动刷新走 force: true。
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                await SearchIndexService.shared.rebuildIndex(context: context)
            }
            .sheet(isPresented: $showAddTodo) {
                AddTodoSheet(initialCategory: selectedFilter)
            }
            .sheet(isPresented: $showOverdueTriage) {
                OverdueTriageSheet(items: triageItemsOverride ?? overdueTodos)
                    // 只有卡片真正呈现才消耗「今天已整理」，避免留下假状态。
                    .onAppear { lastTriageDateKey = todayTriageKey }
                    .onDisappear { triageItemsOverride = nil }
            }
            .sheet(item: $selectedTimeBucket) { kind in
                TodoTimeBucketSheet(kind: kind, items: bucketTodoItems(for: kind))
            }
            .onAppear {
                maybePresentOverdueTriage()
            }
            .sheet(isPresented: $showVoice) { VoiceDialogueView() }
            .sheet(isPresented: $showCompletedHistory) { CompletedTodoHistoryView() }
            .sheet(isPresented: $showPeriodicReport) {
                PeriodicReportView(initialPeriod: router.requestedReportPeriod ?? .daily)
            }
            .sheet(item: $itemToShare) { item in
                TodoShareSheet(
                    allTodos: [item],
                    initialCategory: (item.type == .parcel || item.type == .returnParcel) ? .parcel : .all,
                    initialSelectedIds: [item.id]
                )
            }
            .sheet(item: $itemToEdit) { item in
                EditTodoSheet(item: item) {
                    AppMotion.animate { isReordering = true }
                }
            }
            .fullScreenCover(item: $itemForQRCode) { item in
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
                    router.activeSheet = nil
                case .voice:
                    showVoice = true
                    router.activeSheet = nil
                case .periodicReport:
                    showPeriodicReport = true
                    router.activeSheet = nil
                default:
                    break
                }
            }
            .onChange(of: showPeriodicReport) { _, isPresented in
                // 报告关闭后清掉透传的周期，避免下次打开沿用上一次通知的周期
                if !isPresented {
                    router.requestedReportPeriod = nil
                }
            }
            .onChange(of: router.requestedFilter) { _, filterName in
                guard let filterName else { return }
                if let cat = TodoFilterCategory.allCases.first(where: { $0.rawValue == filterName }) {
                    selectedFilter = homeCategories.contains(cat) ? cat : .all
                }
                router.requestedFilter = nil
            }
            .onChange(of: router.focusedTodoID) { _, id in
                guard let id, let item = findTodo(id: id) else { return }
                let target = category(for: item)
                selectedFilter = homeCategories.contains(target) ? target : .all
            }
            // 统一搜索/深链命中待办：在滚动定位之外直达详情弹层
            .onChange(of: router.requestedTodoDetailID) { _, id in
                presentTodoDetail(for: id)
            }
            .task {
                StartupMetrics.markOnce("todoList.task begin", "n=\(todos.count)")
                // 纪念日/出行购票横幅：首帧之后再刷新，不阻塞首屏；同时不必等待天气网络请求
                scheduleReminderRefresh(delayMilliseconds: 250)
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await weatherAlerts.checkAlertsIfNeeded()
                StartupMetrics.markOnce("todoList.task weatherDone")
            }
            .onAppear {
                StartupMetrics.markOnce("todoList.onAppear")
                if let id = router.focusedTodoID, let item = findTodo(id: id) {
                    let target = category(for: item)
                    selectedFilter = homeCategories.contains(target) ? target : .all
                    highlightedTodoID = id
                }
                // 搜索弹层先于本页挂载时 onChange 不触发，这里兜底消费直达详情的请求
                presentTodoDetail(for: router.requestedTodoDetailID)
            }
            .onChange(of: todos) { _, _ in
                // 勾选/编辑/拖拽排序可能连续触发多次，合并为一次轻量刷新
                scheduleReminderRefresh(delayMilliseconds: 400)
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
        context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
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
            guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "调整待办顺序") }) else {
                Haptic.error()
                return
            }
            Haptic.success()
        }
    }

    @ViewBuilder
    private func todoRow(_ item: TodoItem, within items: [TodoItem]) -> some View {
        TodoRow(
            item: item,
            isHighlighted: highlightedTodoID == item.id,
            onMoveToTop: { moveItemToTop(item, within: items) },
            onEdit: { itemToEdit = item },
            onShowQRCode: { itemForQRCode = item },
            onShare: { itemToShare = item }
        )
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

    // MARK: - 首页全域搜索实时预览卡片

    @ViewBuilder
    private func homeSearchIndexPreview(query: String) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let matches = SearchIndexService.shared.engine.search(query: trimmed, limit: 4)
            VStack(spacing: 6) {
                Button {
                    router.prefilledSearchQuery = trimmed
                    router.activeSheet = .unifiedSearch
                    crossModuleSearchText = ""
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .foregroundStyle(.tint)
                        Text("全景索引检索「\(trimmed)」(支持全拼/首字母)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("全景大厅 ›")
                            .font(.caption2.bold())
                            .foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                }
                .buttonStyle(.plain)

                if !matches.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(matches.prefix(3)) { match in
                            Button {
                                router.navigateToSearchRoute(match.document.route)
                                crossModuleSearchText = ""
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: match.document.category.icon)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.tint)
                                        .frame(width: 22, height: 22)
                                        .background(Color.accentColor.opacity(0.12), in: Circle())

                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(match.document.title)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if let badge = match.document.badge {
                                                Text(badge)
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                            }
                                        }
                                        if let sub = match.document.subtitle {
                                            Text(sub)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - 分类渲染器

    @ViewBuilder
    private func renderAllSections() -> some View {
        if activeTodos.isEmpty {
            Section {
                if isSearching {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("待办中未找到与「\(crossModuleSearchText.trimmingCharacters(in: .whitespacesAndNewlines))」匹配的事项")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text("可轻点上方全景搜索卡片直达全景搜索大厅查找")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
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
        if !todayTodos.isEmpty {
            Section("📋 今日待办（\(todayTodos.count)）") {
                ForEach(todayTodos) { item in
                    todoRow(item, within: todayTodos)
                }
                .onMove { from, to in reorder(items: todayTodos, fromOffsets: from, toOffset: to) }
            }
        }
        let remainingGenerals = generals.filter { !todayTodos.contains($0) }
        if !remainingGenerals.isEmpty {
            Section("📋 日常待办（\(remainingGenerals.count)）") {
                ForEach(remainingGenerals) { item in
                    todoRow(item, within: remainingGenerals)
                }
                .onMove { from, to in reorder(items: remainingGenerals, fromOffsets: from, toOffset: to) }
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
        Section(todayTodos.isEmpty ? "今日待办" : "今日待办（\(todayTodos.count)）") {
            if todayTodos.isEmpty {
                if isSearching {
                    searchEmptyRow(for: "今日待办")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 38))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Text("今日暂无待办事项")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text("点击右上角 ➕ 即可快速添加今日待办。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                ForEach(todayTodos) { item in
                    todoRow(item, within: todayTodos)
                }
                .onMove { from, to in reorder(items: todayTodos, fromOffsets: from, toOffset: to) }
            }
        }
    }

    @ViewBuilder
    private func renderWorkSection() -> some View {
        Section(works.isEmpty ? "工作待办" : "💼 工作待办（\(works.count)）") {
            if works.isEmpty {
                if isSearching {
                    searchEmptyRow(for: "工作待办")
                } else {
                    Text("暂无工作待办，点击右上角 ➕ 即可快速添加会议、周报或项目事项。")
                        .foregroundStyle(.secondary)
                }
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
                if isSearching {
                    searchEmptyRow(for: "周期性待办")
                } else {
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
                if isSearching {
                    searchEmptyRow(for: "快递与退货")
                } else {
                    Text("暂无待取快递或待退货事项，点击右上角 ➕ 可快速添加。")
                        .foregroundStyle(.secondary)
                }
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
                if isSearching {
                    searchEmptyRow(for: "生活与健康")
                } else {
                    Text("暂无生活提醒（服药、家务或充电预警）").foregroundStyle(.secondary)
                }
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
                if isSearching {
                    searchEmptyRow(for: "提醒与预警")
                } else {
                    Text("暂无预警事项（爱车守护、自动续费、物品临期或密码轮换）").foregroundStyle(.secondary)
                }
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
                if isSearching {
                    searchEmptyRow(for: "亲子育儿")
                } else {
                    Text("暂无育儿待办，可添加疫苗、成长测量或健康随访提醒。")
                        .foregroundStyle(.secondary)
                }
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
                if isSearching {
                    searchEmptyRow(for: "宠物照护")
                } else {
                    Text("暂无宠物待办，可添加喂食、驱虫、洗护或就医提醒。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(petTodos) { item in
                    todoRow(item, within: petTodos)
                }
                .onMove { from, to in reorder(items: petTodos, fromOffsets: from, toOffset: to) }
            }
        }
    }

    @ViewBuilder
    private func renderOtherSection() -> some View {
        Section(otherActive.isEmpty ? "其它事项" : "其它事项（\(otherActive.count)）") {
            if otherActive.isEmpty {
                if isSearching {
                    searchEmptyRow(for: "其它事项")
                } else {
                    Text("暂无其它事项，点击右上角 ➕ 即可快速添加。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(otherActive) { item in
                    todoRow(item, within: otherActive)
                }
                .onMove { from, to in reorder(items: otherActive, fromOffsets: from, toOffset: to) }
            }
        }
    }

    // MARK: - 页面与顶部 Tab 栏组件

    /// 时间聚合条：逾期 / 今天 / 本周三个互斥入口 + 逾期一键整理。
    /// chip 计数由 `TodoTimeAggregator` 单源给出，点开的详情列表就是同一分桶结果——
    /// 不存在「角标 3、点进去 5 条」的口径漂移。
    private var timeAggregationBar: some View {
        let buckets = timeBuckets
        return HStack(spacing: 8) {
            ForEach(TodoTimeBucketKind.allCases) { kind in
                let count = buckets.count(for: kind)
                if count > 0 {
                    Button {
                        Haptic.selection()
                        selectedTimeBucket = kind
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.systemImage)
                                .font(.caption2.bold())
                            Text(kind.title)
                                .font(.caption.bold())
                            Text("\(count)")
                                .font(.caption2.bold().monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(timeBucketTint(kind).opacity(0.18)))
                                .foregroundStyle(timeBucketTint(kind))
                        }
                        .foregroundStyle(timeBucketTint(kind))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(timeBucketTint(kind).opacity(0.10), in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(timeBucketTint(kind).opacity(0.25), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            if buckets.count(for: .overdue) > 0 {
                Button {
                    Haptic.medium()
                    triageItemsOverride = bucketTodoItems(for: .overdue)
                    showOverdueTriage = true
                } label: {
                    Label("整理", systemImage: "wand.and.stars")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func timeBucketTint(_ kind: TodoTimeBucketKind) -> Color {
        switch kind {
        case .overdue: return .red
        case .today: return .blue
        case .thisWeek: return .indigo
        }
    }

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
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
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
                            .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Color(.secondarySystemBackground)))
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
        .background(Color.clear)
    }

    @ViewBuilder
    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.82)) {
                        selectedTagFilter = nil
                    }
                    Haptic.selection()
                } label: {
                    Text("全部")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selectedTagFilter == nil ? Color.accentColor : Color(.secondarySystemBackground)))
                        .foregroundStyle(selectedTagFilter == nil ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)

                ForEach(allActiveTags, id: \.self) { tag in
                    let isSelected = selectedTagFilter == tag
                    let count = classified.active.filter { $0.tags.contains(tag) }.count
                    Button {
                        AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.82)) {
                            selectedTagFilter = (selectedTagFilter == tag ? nil : tag)
                        }
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                                .font(.caption2.bold())
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2)
                                    .opacity(0.8)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(isSelected ? Color.indigo : Color.indigo.opacity(0.12)))
                        .foregroundStyle(isSelected ? Color.white : Color.indigo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func searchEmptyRow(for categoryName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("未在「\(categoryName)」中找到匹配事项")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - 首页头部可滑动区域（卡片、分类栏、筛选栏、横幅）

    @ViewBuilder
    private var homeHeaderSection: some View {
        Section {
            VStack(spacing: 0) {
                if !isSearching {
                    // 顶部快捷卡片支持左右滑动，避免欢迎信息和投喂入口同时占用首页高度。
                    HomeTopCardsCarousel(activeCount: activeTodos.count) {
                        Haptic.light()
                        router.activeSheet = .omnibox
                    }
                    LifeEventHomeBanner()
                }

                // 横向分类 Tab 栏（带指示胶囊与角标）
                filterTabBar
                    .wallpaperReadableText()

                // 标签快速筛选栏：仅在库内存在标签时自适应展示，支持按项目/客户/标签聚焦
                if !isSearching && !allActiveTags.isEmpty {
                    tagFilterBar
                        .wallpaperReadableText()
                }

                // 时间聚合条：按时间组织的逾期/今天/本周入口 + 逾期一键整理
                // （与类型分类正交；三桶互斥，chip 计数即详情列表长度）
                if !isSearching && !timeBuckets.isEmpty {
                    timeAggregationBar
                }

                // 搜索词非空时，展示全域索引实时匹配卡片，支持直接跳转任意模块/设置或进入全景搜索
                if isSearching {
                    homeSearchIndexPreview(query: crossModuleSearchText)
                }

                if !isSearching {
                    // 上下滑动排序模式开启提示横幅
                    if isReordering {
                        TodoReorderingBanner {
                            AppMotion.animate(.spring(response: 0.32, dampingFraction: 0.8)) {
                                isReordering = false
                            }
                            Haptic.medium()
                        }
                    }

                    // 长辈关怀大字模式顶部状态微胶囊（支持一键调整字号）
                    if seniorManager.isSeniorModeEnabled {
                        TodoSeniorModeBanner(fontScaleTitle: seniorManager.fontScale.title) {
                            showSeniorSettings = true
                            Haptic.light()
                        }
                    }

                    // 突发气象预警或气温骤降轻巧胶囊（若有则展示，支持手动划掉关闭）
                    if let banner = weatherAlerts.currentBanner {
                        TodoWeatherAlertBanner(banner: banner) {
                            weatherAlerts.dismissCurrentBanner()
                        }
                    }

                    // 临近 5~7 天纪念日浪漫筹备备忘横幅（支持一键加入待办与不再提醒）
                    if let upcoming = anniversaryReminder.activeUpcoming {
                        TodoAnniversaryPrepBanner(
                            upcoming: upcoming,
                            onDismiss: {
                                AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    anniversaryReminder.dismiss(for: upcoming)
                                    showToast("已设置本周期不再提醒该纪念日")
                                }
                            },
                            onAddTodos: {
                                AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    // 返回 false = 落库失败（已回滚 + 全局失败横幅），
                                    // 不能再 toast「已加入待办」。
                                    if anniversaryReminder.addPreparationTodos(for: upcoming, in: context) {
                                        showToast("已一键将准备鲜花、订蛋糕与订餐厅加入待办！🎉")
                                    }
                                }
                            }
                        )
                    }

                    // 临近节假日或出差旅游出行前购票提醒横幅（火车票提前15天、机票提前15-30天）
                    if let ticketInfo = ticketReminder.activeUpcomingTicket {
                        TodoTravelTicketPrepBanner(
                            info: ticketInfo,
                            onDismiss: {
                                AppMotion.animate(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    ticketReminder.dismiss(for: ticketInfo)
                                    showToast("已设置本周期不再提醒该出行购票")
                                }
                            },
                            onConfirm: {
                                confirmingTicketInfo = ticketInfo
                            }
                        )
                    }
                }

                Divider()
                    .opacity(isCustomBackgroundActive ? 0.35 : 1.0)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func renderPageContent(for category: TodoFilterCategory) -> some View {
        List {
            homeHeaderSection
            // 放进列表内普通行，使“今日安排”可以随首页内容向上滚动，同时避免空 Section + 超高自定义 Header 引发 UICollectionView 布局死锁与白屏
            if category == .all && !isSearching {
                Section {
                    VStack(spacing: 4) {
                        TodayBriefingView(items: activeTodos)
                        // Structured 式今日时间轴：起床/下班锚点 + 日程 + 定时待办 + 打卡，
                        // 自动标出空闲时段，一眼判断"今天塞不塞得下一件新事"。
                        DayTimelineView(items: activeTodos)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
            case .other:
                renderOtherSection()
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

                            Text(recentDoneTodos.count >= Self.recentDoneLimit ? "\(currentDone.count)+" : "\(currentDone.count)")
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
                            context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "保存") }
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
        .scrollContentBackground(isCustomBackgroundActive ? .hidden : .automatic)
        .background(Color.clear)
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        .themedRow()
    }

    private func badgeCount(for category: TodoFilterCategory) -> Int {
        switch category {
        case .all: return activeTodos.count
        case .general: return todayTodos.count
        case .work: return works.count
        case .recurring: return recurring.count
        case .parcel: return parcels.count + returnParcels.count
        case .life: return medications.count + houseworks.count + chargings.count
        case .alert: return subscriptions.count + expiries.count + anniversaries.count + passwordTodos.count + vehicleTodos.count
        case .parenting: return parentingTodos.count
        case .pet: return petTodos.count
        case .other: return otherActive.count
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
        case .other: return .secondary
        }
    }

    private func filteredDoneItems(for category: TodoFilterCategory) -> [TodoItem] {
        switch category {
        case .all:
            return done
        case .general:
            return done.filter { item in
                if let comp = item.completedAt {
                    return Calendar.current.isDateInToday(comp)
                }
                return false
            }
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
        case .other:
            return done.filter { $0.type == .other }
        }
    }
}
