import SwiftData
import SwiftUI

// MARK: - 生活档案卡片枚举定义

/// 生活档案卡片类型定义（包含全部 16 个核心功能模块）
public enum LifeVaultCardType: String, CaseIterable, Identifiable, Codable, Hashable {
    case lifeEvents = "lifeEvents"         // 人生大事筹备中心
    case documents = "documents"           // 重要证件
    case passwords = "passwords"           // 密码库
    case voiceMemos = "voiceMemos"         // 语音备忘录
    case anniversaries = "anniversaries"   // 纪念日
    case painPoints = "painPoints"         // 续费与物品临期
    case skillPaths = "skillPaths"         // 技能学习路径
    case storage = "storage"               // 物品收纳
    case learnedPlaces = "learnedPlaces"   // 常用地点
    case foodCalorie = "foodCalorie"       // 饮食热量估算
    case healthData = "healthData"         // 健康数据
    case habits = "habits"                 // 运动与药物保健品
    case pets = "pets"                     // 宠物管家
    case children = "children"             // 亲子育儿
    case vehicles = "vehicles"             // 爱车管理
    case departure = "departure"           // 出门清单

    public var id: String { rawValue }

    /// 模块标题
    public var title: String {
        switch self {
        case .lifeEvents: return "人生大事筹备中心"
        case .documents: return "重要证件"
        case .passwords: return "密码库"
        case .voiceMemos: return "语音备忘录"
        case .anniversaries: return "纪念日"
        case .painPoints: return "续费与物品临期"
        case .skillPaths: return "技能学习路径"
        case .storage: return "物品收纳"
        case .learnedPlaces: return "常用地点"
        case .foodCalorie: return "饮食热量估算"
        case .healthData: return "健康数据"
        case .habits: return "运动与药物保健品"
        case .pets: return "宠物管家"
        case .children: return "亲子育儿"
        case .vehicles: return "爱车管理"
        case .departure: return "出门清单"
        }
    }

    /// 所属分类
    public var category: String {
        switch self {
        case .lifeEvents: return "人生大事"
        case .documents, .passwords, .voiceMemos: return "私密资料"
        case .anniversaries, .painPoints: return "生活提醒"
        case .skillPaths: return "学习成长"
        case .storage, .learnedPlaces: return "物品与地点"
        case .foodCalorie, .healthData, .habits: return "健康与习惯"
        case .pets, .children: return "家庭与陪伴"
        case .vehicles, .departure: return "出行"
        }
    }

    /// SF Symbol 图标名称
    public var icon: String {
        switch self {
        case .lifeEvents: return "sparkles"
        case .documents: return "person.text.rectangle.fill"
        case .passwords: return "key.fill"
        case .voiceMemos: return "mic.circle.fill"
        case .anniversaries: return "gift.fill"
        case .painPoints: return "shield.lefthalf.filled"
        case .skillPaths: return "book.fill"
        case .storage: return "archivebox.fill"
        case .learnedPlaces: return "brain.head.profile"
        case .foodCalorie: return "fork.knife.circle.fill"
        case .healthData: return "heart.text.square.fill"
        case .habits: return "figure.run"
        case .pets: return "pawprint.fill"
        case .children: return "figure.and.child.holdinghands"
        case .vehicles: return "car.fill"
        case .departure: return "bag.fill"
        }
    }

    /// 主题色彩
    public var iconColor: Color {
        switch self {
        case .lifeEvents: return .orange
        case .documents: return .blue
        case .passwords: return .teal
        case .voiceMemos: return .red
        case .anniversaries: return .pink
        case .painPoints: return .indigo
        case .skillPaths: return .purple
        case .storage: return .indigo
        case .learnedPlaces: return .orange
        case .foodCalorie: return .orange
        case .healthData: return .red
        case .habits: return .purple
        case .pets: return .teal
        case .children: return .pink
        case .vehicles: return .indigo
        case .departure: return .teal
        }
    }
}

// MARK: - 生活档案卡片管理器

/// 生活档案卡片排序与频次统计管理中心
@MainActor
public final class LifeVaultCardManager: ObservableObject {
    public static let shared = LifeVaultCardManager()

    private let customOrderKey = "life_vault_card_custom_order_v2"
    private let usageCountsKey = "life_vault_card_usage_counts_v2"
    private let lastUsedTimestampsKey = "life_vault_card_last_used_timestamps_v2"
    private let dynamicSortEnabledKey = "life_vault_card_dynamic_sort_enabled_v2"

    /// 是否开启按使用频率动态排列（默认关闭）
    @Published public var isDynamicFrequencySortingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDynamicFrequencySortingEnabled, forKey: dynamicSortEnabledKey)
            objectWillChange.send()
        }
    }

    /// 用户自定义排列顺序（当动态排序关闭时展示）
    @Published public var customOrder: [LifeVaultCardType] {
        didSet {
            saveCustomOrder()
            objectWillChange.send()
        }
    }

    /// 累计访问频次字典
    @Published private(set) public var usageCounts: [String: Int] = [:]

    /// 最近使用时间戳（用于频次并列时的平稳降序）
    @Published private(set) public var lastUsedTimestamps: [String: Double] = [:]

    private init() {
        // 1. 读取动态频次开关（严格默认关闭 false）
        self.isDynamicFrequencySortingEnabled = UserDefaults.standard.bool(forKey: dynamicSortEnabledKey)

        // 2. 加载使用频次数据
        if let counts = UserDefaults.standard.dictionary(forKey: usageCountsKey) as? [String: Int] {
            self.usageCounts = counts
        }
        if let timestamps = UserDefaults.standard.dictionary(forKey: lastUsedTimestampsKey) as? [String: Double] {
            self.lastUsedTimestamps = timestamps
        }

        // 3. 加载自定义排序
        if let data = UserDefaults.standard.data(forKey: customOrderKey),
           let saved = try? JSONDecoder().decode([LifeVaultCardType].self, from: data),
           !saved.isEmpty {
            var result: [LifeVaultCardType] = []
            for item in saved {
                if !result.contains(item) {
                    result.append(item)
                }
            }
            // 补齐可能新增的卡片类型
            for card in LifeVaultCardType.allCases {
                if !result.contains(card) {
                    result.append(card)
                }
            }
            self.customOrder = result
        } else {
            self.customOrder = LifeVaultCardType.allCases
        }
    }

    /// 当前最终展示的卡片列表
    public var displayCards: [LifeVaultCardType] {
        if isDynamicFrequencySortingEnabled {
            // 动态频率排列：按使用频次降序；若频次相同，按最后访问时间降序；再相同则保留默认相对顺序
            return customOrder.sorted { lhs, rhs in
                let lhsCount = usageCounts[lhs.rawValue] ?? 0
                let rhsCount = usageCounts[rhs.rawValue] ?? 0
                if lhsCount != rhsCount {
                    return lhsCount > rhsCount
                }
                let lhsTime = lastUsedTimestamps[lhs.rawValue] ?? 0
                let rhsTime = lastUsedTimestamps[rhs.rawValue] ?? 0
                if lhsTime != rhsTime {
                    return lhsTime > rhsTime
                }
                let lhsIndex = customOrder.firstIndex(of: lhs) ?? 0
                let rhsIndex = customOrder.firstIndex(of: rhs) ?? 0
                return lhsIndex < rhsIndex
            }
        } else {
            return customOrder
        }
    }

    /// 获取特定卡片的使用次数
    public func usageCount(for card: LifeVaultCardType) -> Int {
        usageCounts[card.rawValue] ?? 0
    }

    /// 记录某卡片被访问/使用了一次
    public func recordUsage(for card: LifeVaultCardType) {
        let current = usageCounts[card.rawValue] ?? 0
        usageCounts[card.rawValue] = current + 1
        lastUsedTimestamps[card.rawValue] = Date().timeIntervalSince1970

        UserDefaults.standard.set(usageCounts, forKey: usageCountsKey)
        UserDefaults.standard.set(lastUsedTimestamps, forKey: lastUsedTimestampsKey)

        objectWillChange.send()
    }

    /// 拖拽排序
    public func moveCard(from source: IndexSet, to destination: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            // 如果用户在动态排序开启时进行了手动拖拽，自动切换到自定义排序，保证用户拖拽意图生效
            if isDynamicFrequencySortingEnabled {
                var updated = displayCards
                updated.move(fromOffsets: source, toOffset: destination)
                customOrder = updated
                isDynamicFrequencySortingEnabled = false
            } else {
                customOrder.move(fromOffsets: source, toOffset: destination)
            }
        }
        Haptic.selection()
    }

    /// 重置为系统默认推荐排序
    public func resetToDefaultOrder() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            customOrder = LifeVaultCardType.allCases
        }
        Haptic.medium()
    }

    /// 清空频次统计数据
    public func resetUsageCounts() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            usageCounts.removeAll()
            lastUsedTimestamps.removeAll()
            UserDefaults.standard.removeObject(forKey: usageCountsKey)
            UserDefaults.standard.removeObject(forKey: lastUsedTimestampsKey)
        }
        Haptic.medium()
    }

    private func saveCustomOrder() {
        if let data = try? JSONEncoder().encode(customOrder) {
            UserDefaults.standard.set(data, forKey: customOrderKey)
        }
    }
}

// MARK: - 主视图

/// 生活档案与数字资产大厅 (Tab 3: 生活档案)
struct LifeVaultView: View {
    @Environment(\.modelContext) private var context
    @Query private var storedItems: [StoredItem]
    @Query private var documents: [IDDocumentItem]
    @Query private var passwords: [PasswordVaultItem]
    @Query private var anniversaries: [AnniversaryItem]
    @Query private var habits: [PeriodicHabit]
    @Query private var medications: [MedicationPlan]
    @Query private var subscriptions: [SubscriptionItem]
    @Query private var expiries: [ItemExpiryItem]
    @Query private var places: [LearnedPlace]
    @Query private var departureItems: [DepartureCheckItem]
    @Query private var voiceMemos: [VoiceMemo]
    @Query private var vehicles: [VehicleProfile]
    @Query private var pets: [PetProfile]
    @Query private var children: [ChildProfile]
    @Query(sort: [SortDescriptor(\LifeEventProject.targetDate, order: .forward)]) private var lifeProjects: [LifeEventProject]
    @Query private var skillPaths: [SkillPath]
    @Query(sort: \FoodIntakeRecord.date, order: .reverse) private var foodRecords: [FoodIntakeRecord]
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedDestination: LifeVaultCardType?
    @ObservedObject private var router = NavigationRouter.shared
    /// 订阅健康服务，快照状态变化时健康数据入口的摘要能实时刷新
    @ObservedObject private var health = HealthKitService.shared
    /// 卡片排序与频次管理器
    @ObservedObject private var cardManager = LifeVaultCardManager.shared
    /// 饮食偏好与时段建议画像
    @ObservedObject private var dietaryService = DietaryPreferenceService.shared

    /// 拖拽排序编辑状态
    @State private var editMode: EditMode = .inactive
    /// 恢复默认顺序确认弹窗
    @State private var showResetOrderConfirmation = false
    /// 清空频次统计确认弹窗
    @State private var showResetCountsConfirmation = false
    /// 顶部轻量提示信息
    @State private var bannerTipMessage: String?

    /// 单次渲染窗口内只算一遍的看板统计快照（与 ExpenseTrackerView 同款的 0.05s 访问窗口缓存）
    private struct VaultStats {
        var uncheckedDeparture = 0
        var needCareVehicles = 0
        var nearestAnniversary: (item: AnniversaryItem, days: Int)?
        var expiringDocs = 0
        var activeMeds = 0
        var needAttentionPets = 0
        var pendingVaccineDoses = 0
    }

    private final class VaultStatsCache {
        var stats: VaultStats?
        var lastComputed: CFAbsoluteTime = 0
    }

    @State private var statsCache = VaultStatsCache()

    /// 一次遍历产出全部看板统计，body 里 24 处引用在同一渲染窗口内共享
    private var stats: VaultStats {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = statsCache.stats, now - statsCache.lastComputed < 0.05 {
            return cached
        }
        var s = VaultStats()
        s.uncheckedDeparture = departureItems.reduce(0) { $0 + ($1.isEssential && !$1.isChecked ? 1 : 0) }
        s.needCareVehicles = vehicles.reduce(0) { $0 + ($1.needsAttention ? 1 : 0) }
        s.nearestAnniversary = anniversaries
            .map { (item: $0, days: $0.daysUntilNext) }
            .sorted { $0.days < $1.days }
            .first
        s.expiringDocs = documents.reduce(0) { $0 + ($1.isExpiringSoon || $1.isExpired ? 1 : 0) }
        s.activeMeds = medications.reduce(0) { $0 + ($1.isEnabled ? 1 : 0) }
        s.needAttentionPets = pets.reduce(0) { $0 + ($1.needsAttention ? 1 : 0) }
        s.pendingVaccineDoses = children.reduce(0) { $0 + $1.pendingVaccines.count }
        statsCache.stats = s
        statsCache.lastComputed = now
        return s
    }

    // 随身防丢未清点核心件（统计来自 stats 快照）
    private var uncheckedDepartureCount: Int { stats.uncheckedDeparture }

    // 爱车需要关注补能或保养/保险/年检的数量
    private var needCareVehicleCount: Int { stats.needCareVehicles }

    // 最近即将到来的纪念日
    private var nearestAnniversary: (item: AnniversaryItem, days: Int)? { stats.nearestAnniversary }

    // 临期证件数量
    private var expiringDocCount: Int { stats.expiringDocs }

    // 活跃服药计划
    private var activeMedCount: Int { stats.activeMeds }

    // 人生大事状态摘要
    private var lifeEventsSummary: String {
        if let first = lifeProjects.first {
            let daysText = first.daysRemaining >= 0 ? "还有 \(first.daysRemaining) 天" : "已过 \(abs(first.daysRemaining)) 天"
            if lifeProjects.count == 1 {
                return "\(first.title) · \(daysText)"
            } else {
                return "\(first.title)（\(daysText)）等 \(lifeProjects.count) 项"
            }
        }
        return "订婚结婚 · 乔迁装修 · 满月升学 · 亲友共享全流程"
    }

    // 学习路径摘要
    private var skillPathsSummary: String {
        let active = skillPaths.filter { $0.status == .active }
        if active.isEmpty { return "学吉他 · 学 Python · 练口语，自动拆成阶段计划" }
        let total = skillPaths.count
        if let first = active.first {
            let stageText = "第 \(first.currentStageIndex + 1) 阶段"
            return total == 1 ? "\(first.title) · \(stageText)" : "\(first.title)（\(stageText)）等 \(total) 条"
        }
        return "\(total) 条学习路径"
    }

    var body: some View {
        NavigationStack {
            List {
                // 顶部快速看板统计（保留 Button 跳转入口与彩色标识，2026-10-14 按用户要求回退只读化改动）
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        Button {
                            navigateTo(.lifeEvents)
                        } label: {
                            statPill(title: "人生大事", count: "\(lifeProjects.count)", icon: "sparkles", color: .orange)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.documents)
                        } label: {
                            statPill(title: "证件", count: "\(documents.count)", icon: "person.text.rectangle.fill", color: .blue, badgeCount: expiringDocCount)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.passwords)
                        } label: {
                            statPill(title: "密码", count: "\(passwords.count)", icon: "key.fill", color: .teal)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.storage)
                        } label: {
                            statPill(title: "收纳", count: "\(storedItems.count)", icon: "archivebox.fill", color: .indigo)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.vehicles)
                        } label: {
                            statPill(title: "爱车", count: "\(vehicles.count)", icon: "car.fill", color: .indigo, badgeCount: needCareVehicleCount)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.departure)
                        } label: {
                            statPill(title: "防丢", count: "\(departureItems.count)", icon: "bag.fill", color: .teal, badgeCount: uncheckedDepartureCount)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.anniversaries)
                        } label: {
                            statPill(title: "纪念日", count: "\(anniversaries.count)", icon: "gift.fill", color: .pink)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            navigateTo(.habits)
                        } label: {
                            statPill(title: "习惯", count: "\(habits.count + activeMedCount)", icon: "heart.fill", color: .purple)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .disabled(editMode == .active)

                // MARK: - 动态频次排序 / 拖拽提示状态横幅
                if cardManager.isDynamicFrequencySortingEnabled {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(AppColor.feature)
                                .font(.subheadline)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("已开启按使用频率动态排列")
                                    .font(.subheadline.weight(.semibold))
                                Text("高频模块置顶展示，低频模块顺延")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("关闭") {
                                withAnimation {
                                    cardManager.isDynamicFrequencySortingEnabled = false
                                }
                            }
                            .font(.caption.bold())
                            .foregroundStyle(AppColor.primary)
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                } else if editMode == .active {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.and.down.circle.fill")
                                .foregroundStyle(AppColor.info)
                                .font(.subheadline)
                            Text("按住右侧三道杠手柄上下拖动即可排序，修改即时生效。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - 功能卡片列表（支持频次动态排序与手动拖拽排序）
                Section {
                    ForEach(cardManager.displayCards) { card in
                        if editMode == .active {
                            // 编辑拖拽模式下不作为 NavigationLink 响应跳转，保证拖拽流畅
                            vaultCardRow(for: card)
                        } else {
                            NavigationLink {
                                destinationView(for: card)
                            } label: {
                                vaultCardRow(for: card)
                            }
                        }
                    }
                    .onMove { source, destination in
                        let wasDynamic = cardManager.isDynamicFrequencySortingEnabled
                        cardManager.moveCard(from: source, to: destination)
                        if wasDynamic {
                            withAnimation {
                                bannerTipMessage = "已按拖拽顺序切换为自定义排序"
                            }
                        }
                    }
                    .deleteDisabled(true) // 纯排序列表，禁用删除按钮以保持界面纯净
                } header: {
                    HStack {
                        Text("功能模块 (\(cardManager.displayCards.count))")
                        Spacer()
                        if cardManager.isDynamicFrequencySortingEnabled {
                            Label("高频优先", systemImage: "arrow.up.and.down.text.horizontal")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(AppColor.primary.opacity(0.12)))
                                .foregroundStyle(AppColor.primary)
                        } else {
                            Text("自定义排序")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .themedScrollContentBackground()
            .themedAppBackground()
            .themedRow()
            .navigationTitle("生活档案")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode == .active {
                        Button("完成") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editMode = .inactive
                            }
                        }
                        .fontWeight(.semibold)
                    } else {
                        Menu {
                            Toggle(isOn: $cardManager.isDynamicFrequencySortingEnabled) {
                                Label("按使用频率动态排列", systemImage: "sparkles")
                            }

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    editMode = .active
                                }
                            } label: {
                                Label("自定义拖拽排序", systemImage: "arrow.up.and.down.circle")
                            }

                            Divider()

                            Button {
                                showResetOrderConfirmation = true
                            } label: {
                                Label("恢复默认卡片排列", systemImage: "arrow.counterclockwise")
                            }

                            Button(role: .destructive) {
                                showResetCountsConfirmation = true
                            } label: {
                                Label("清空使用频次统计", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                                .font(.body.weight(.medium))
                        }
                    }
                }
            }
            .confirmationDialog("恢复默认排列？", isPresented: $showResetOrderConfirmation, titleVisibility: .visible) {
                Button("恢复官方推荐顺序", role: .destructive) {
                    cardManager.resetToDefaultOrder()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将卡片恢复为默认推荐分类顺序。")
            }
            .confirmationDialog("清空使用频次统计？", isPresented: $showResetCountsConfirmation, titleVisibility: .visible) {
                Button("清空统计", role: .destructive) {
                    cardManager.resetUsageCounts()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("重置后所有卡片的累计访问次数将被清零。")
            }
            .overlay(alignment: .top) {
                if let msg = bannerTipMessage {
                    Text(msg)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation {
                                    bannerTipMessage = nil
                                }
                            }
                        }
                }
            }
            .navigationDestination(item: $selectedDestination) { destination in
                destinationView(for: destination)
            }
            // 深链（如小组件「今日练习」点击）：直接推入技能学习路径列表
            .onChange(of: router.requestedSkillPathList) { _, requested in
                if requested {
                    navigateTo(.skillPaths)
                    router.requestedSkillPathList = false
                }
            }
            .onChange(of: router.requestedVaultDestination) { _, dest in
                guard let dest else { return }
                switch dest {
                case "storage": navigateTo(.storage)
                case "documents": navigateTo(.documents)
                case "voiceMemos", "memos": navigateTo(.voiceMemos)
                case "passwords": navigateTo(.passwords)
                case "departure": navigateTo(.departure)
                case "lifeEvents": navigateTo(.lifeEvents)
                case "anniversaries": navigateTo(.anniversaries)
                case "habits": navigateTo(.habits)
                case "vehicles": navigateTo(.vehicles)
                case "pets": navigateTo(.pets)
                case "children": navigateTo(.children)
                case "skillPaths": navigateTo(.skillPaths)
                case "foodCalorie", "food": navigateTo(.foodCalorie)
                case "painPoints", "subscriptions": navigateTo(.painPoints)
                case "health", "healthData": navigateTo(.healthData)
                case "places", "learnedPlaces": navigateTo(.learnedPlaces)
                default: break
                }
                router.requestedVaultDestination = nil
            }
            .onAppear {
                dietaryService.refresh(with: context)
            }
            .onChange(of: foodRecords) { _, _ in
                dietaryService.refresh(with: context)
            }
        }
    }

    // MARK: - 页面导航辅助

    private func navigateTo(_ destination: LifeVaultCardType) {
        selectedDestination = destination
    }

    // MARK: - 辅助子视图

    @ViewBuilder
    private func destinationView(for destination: LifeVaultCardType) -> some View {
        Group {
            switch destination {
            case .lifeEvents:
                LifeEventManagementView()
            case .documents:
                IDDocumentVaultView()
            case .passwords:
                PasswordVaultView()
            case .storage:
                ItemStorageVaultView()
            case .vehicles:
                VehicleManagementView()
            case .departure:
                DepartureChecklistView()
            case .anniversaries:
                AnniversaryManagementView()
            case .habits:
                HabitAndMedicationView()
            case .voiceMemos:
                VoiceMemoListView()
            case .pets:
                PetManagementView()
            case .children:
                ChildManagementView()
            case .skillPaths:
                SkillPathListView()
            case .foodCalorie:
                FoodPhotoCalorieView()
            case .painPoints:
                PainPointManagementView()
            case .learnedPlaces:
                LearnedPlacesView()
            case .healthData:
                HealthDataView()
            }
        }
        .onAppear {
            cardManager.recordUsage(for: destination)
        }
    }

    private var foodStatusSummary: String {
        let cal = Calendar.current
        let today = foodRecords.filter { cal.isDateInToday($0.date) }
        let topTag = dietaryService.profile.tags.first
        if today.isEmpty {
            if let topTag {
                return "\(topTag) · 拍照估算热量与时段建议"
            }
            return "拍照推测食物热量 · 学习偏好与建议"
        }
        let total = Int(today.reduce(0.0) { $0 + $1.consumedCalories }.rounded())
        if let topTag {
            return "\(topTag) · 今日已记 \(today.count) 餐（约 \(total) 千卡）"
        }
        return "今日已记 \(today.count) 餐 · 共摄入约 \(total) 千卡"
    }

    private var vehicleStatusSummary: String {
        if vehicles.isEmpty {
            return "尚未添加车辆"
        } else if needCareVehicleCount > 0 {
            return "\(needCareVehicleCount) 辆车需关注"
        } else {
            return "\(vehicles.count) 辆车"
        }
    }

    /// 健康数据入口的状态摘要。
    private var healthStatusSummary: String {
        guard HealthKitService.isAvailable else { return "此设备不支持健康数据" }
        switch health.snapshot?.readState {
        case .hasData:
            return "今日步数、能量、饮水与睡眠可查看"
        case .requestedNoData:
            return "已请求读取，暂未读到数据"
        case .notDetermined:
            return "未连接 · 可读取步数与睡眠"
        case nil:
            return "未连接 · 可读取步数与睡眠"
        }
    }

    private var nearestAnniversarySummary: String {
        if let next = nearestAnniversary {
            if next.days == 0 {
                return "今天：\(next.item.title)"
            } else {
                return "\(next.item.title) · 还有 \(next.days) 天"
            }
        }
        return "\(anniversaries.count) 个纪念日"
    }

    @ViewBuilder
    private func statPill(title: String, count: String, icon: String, color: Color, badgeCount: Int = 0) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)

                if badgeCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -2)
                }
            }

            Text(count)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(L10n.tr(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(badgeCount > 0 ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) 统计")
        .accessibilityValue(badgeCount > 0 ? "\(count) 项，\(badgeCount) 项需关注" : "\(count) 项")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 卡片内容与数据映射

    @ViewBuilder
    private func vaultCardRow(for card: LifeVaultCardType) -> some View {
        let (title, status, isAlert) = cardInfo(for: card)
        let usage = cardManager.usageCount(for: card)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(card.iconColor.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: card.icon)
                    .font(.body.bold())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L10n.tr(title))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    // 类别胶囊
                    Text(L10n.tr(card.category))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // 动态频次排序激活且有访问时显示轻量常用胶囊
                    if cardManager.isDynamicFrequencySortingEnabled && usage > 0 {
                        Text("常用 · \(usage)次")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(Color.orange)
                            .lineLimit(1)
                    }
                }

                Text(L10n.tr(status))
                    .font(.caption)
                    .foregroundStyle(isAlert ? AppColor.danger : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        }
    }

    private func cardInfo(for card: LifeVaultCardType) -> (title: String, status: String, isAlert: Bool) {
        switch card {
        case .lifeEvents:
            return ("人生大事筹备中心", lifeEventsSummary, false)
        case .documents:
            return ("重要证件", expiringDocCount > 0 ? "\(expiringDocCount) 张即将到期" : "\(documents.count) 张证件", expiringDocCount > 0)
        case .passwords:
            return ("密码库", "\(passwords.count) 组账号", false)
        case .voiceMemos:
            return ("语音备忘录", "\(voiceMemos.count) 条录音", false)
        case .anniversaries:
            return ("纪念日", nearestAnniversarySummary, false)
        case .painPoints:
            return ("续费与物品临期", "\(subscriptions.count) 项续费 · \(expiries.count) 项临期", false)
        case .skillPaths:
            return ("技能学习路径", skillPathsSummary, false)
        case .storage:
            return ("物品收纳", "\(storedItems.count) 件物品", false)
        case .learnedPlaces:
            let placeStatus = places.isEmpty ? "尚未记录地点" : places.map(\.name).prefix(2).joined(separator: "、") + (places.count > 2 ? " 等 \(places.count) 处" : "")
            return ("常用地点", placeStatus, false)
        case .foodCalorie:
            return ("饮食热量估算", foodStatusSummary, false)
        case .healthData:
            return ("健康数据", healthStatusSummary, false)
        case .habits:
            return ("运动与药物保健品", "\(habits.count) 项运动 · \(activeMedCount) 项药物与保健品", false)
        case .pets:
            let attentionSuffix = stats.needAttentionPets > 0 ? " · \(stats.needAttentionPets) 项待处理" : ""
            let petStatus = pets.isEmpty ? "未录入爱宠 · 每月驱虫/疫苗提醒" : "\(pets.count) 只毛孩子\(attentionSuffix)"
            return ("宠物管家", petStatus, stats.needAttentionPets > 0)
        case .children:
            let vaccineSuffix = stats.pendingVaccineDoses > 0 ? " · \(stats.pendingVaccineDoses) 剂适龄疫苗" : ""
            let childStatus = children.isEmpty ? "未录入宝贝 · 国家免疫规划疫苗追踪" : "\(children.count) 位宝贝\(vaccineSuffix)"
            return ("亲子育儿", childStatus, false)
        case .vehicles:
            return ("爱车管理", vehicleStatusSummary, needCareVehicleCount > 0)
        case .departure:
            let departureStatus = uncheckedDepartureCount > 0 ? "\(uncheckedDepartureCount) 件未确认" : "\(departureItems.count) 件随身物品"
            return ("出门清单", departureStatus, uncheckedDepartureCount > 0)
        }
    }
}
