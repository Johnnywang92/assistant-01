import AssistantCore
import ImageIO
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// 极简物品收纳备忘（解决“我的东西放哪了”翻箱倒柜的痛点）
struct ItemStorageVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredItem.updatedAt, order: .reverse) private var allItems: [StoredItem]
    /// 收纳页只需要关联过物品的支出：谓词下推，避免整本账（含小票附件）物化到主线程
    @Query(filter: #Predicate<ExpenseRecord> { !$0.isIncome && $0.linkedItemID != nil })
    private var allExpenseRecords: [ExpenseRecord]
    /// 家庭常备药与健康储备（物品收纳页内统一管理，重点跟踪有效期与用药方法）
    @Query private var medicines: [MedicineItem]
    @Query private var medPlans: [MedicationPlan]

    @State private var searchText: String = ""
    @State private var selectedArea: String = "全部"
    @State private var showingAddSheet: Bool = false
    @State private var itemToEdit: StoredItem? = nil
    @State private var previewImageData: Data? = nil
    @State private var showingAddMedicineSheet: Bool = false
    @State private var medicineToEdit: MedicineItem? = nil
    @State private var medicinePrefillSource: MedicineItem? = nil
    @State private var reminderTarget: ReminderMedicineTarget? = nil
    @State private var selectedSymptom: MedicineSymptomFilter = .all
    @State private var actionFeedbackToast: String? = nil

    private let roomAreas = ["全部", "玄关", "主卧", "次卧", "客厅", "书房", "阳台", "储物间", "厨房"]

    /// 派生结果引用缓存：linkedTotals / costTrackedSummaries / filteredItems / areaCounts 在同一渲染内各只算一次
    private final class ItemVaultCache {
        var key: Int = -1
        var linkedTotals: [UUID: Double]?
        var costTrackedSummaries: [(item: StoredItem, summary: ItemCostSummary)]?
        var filteredItems: [StoredItem]?
        var areaCounts: [String: Int]?
    }

    @State private var vaultCache = ItemVaultCache()

    /// 键变化时同时丢弃全部缓存槽；键未变时保留已算好的其他槽
    private func ensureVaultCacheCurrent(for key: Int) {
        if vaultCache.key != key {
            vaultCache.key = key
            vaultCache.linkedTotals = nil
            vaultCache.costTrackedSummaries = nil
            vaultCache.filteredItems = nil
            vaultCache.areaCounts = nil
        }
    }

    /// 各区域物品数量缓存：单次循环统计，避免 ForEach(roomAreas) 内重复执行 8 次全量 filter
    private var areaCounts: [String: Int] {
        let key = vaultKey
        ensureVaultCacheCurrent(for: key)
        if let cached = vaultCache.areaCounts {
            return cached
        }
        var counts: [String: Int] = ["全部": allItems.count]
        for item in allItems {
            counts[item.roomArea, default: 0] += 1
        }
        vaultCache.areaCounts = counts
        return counts
    }

    /// 内容指纹：覆盖成本计算与筛选依赖的物品字段、关联记账字段、搜索/筛选词与归属日（跨午夜自动失效）
    private var vaultKey: Int {
        var hasher = Hasher()
        hasher.combine(Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate)
        hasher.combine(searchText)
        hasher.combine(selectedArea)
        for item in allItems {
            hasher.combine(item.updatedAt.timeIntervalSinceReferenceDate)
            hasher.combine(item.name)
            hasher.combine(item.roomArea)
            hasher.combine(item.location)
            hasher.combine(item.notes ?? "")
            hasher.combine(item.purchasePrice ?? -1)
            hasher.combine(item.purchaseDate?.timeIntervalSinceReferenceDate ?? -1)
            hasher.combine(item.isSecondHand)
            hasher.combine(item.resalePrice ?? -1)
            hasher.combine(item.resoldDate?.timeIntervalSinceReferenceDate ?? -1)
        }
        for record in allExpenseRecords {
            hasher.combine(record.linkedItemID?.uuidString ?? "")
            hasher.combine(record.amount)
        }
        return hasher.finalize()
    }

    /// 关联记账金额归集：itemID -> 该物品累计投入（购入价之外的后继投入）
    private var linkedTotals: [UUID: Double] {
        let key = vaultKey
        ensureVaultCacheCurrent(for: key)
        if let cached = vaultCache.linkedTotals {
            return cached
        }
        var totals: [UUID: Double] = [:]
        for record in allExpenseRecords where !record.isIncome {
            if let itemID = record.linkedItemID {
                totals[itemID, default: 0] += record.amount
            }
        }
        vaultCache.linkedTotals = totals
        return totals
    }

    /// 已录入成本数据的物品摘要（用于顶部速览）
    private var costTrackedSummaries: [(item: StoredItem, summary: ItemCostSummary)] {
        let key = vaultKey
        ensureVaultCacheCurrent(for: key)
        if let cached = vaultCache.costTrackedSummaries {
            return cached
        }
        let totals = linkedTotals
        let result = allItems.compactMap { item -> (item: StoredItem, summary: ItemCostSummary)? in
            let summary = ItemCostCalculator.summary(
                purchasePrice: item.purchasePrice,
                purchaseDate: item.purchaseDate,
                fallbackStartDate: item.createdAt,
                linkedExpenseTotal: totals[item.id] ?? 0,
                isSecondHand: item.isSecondHand,
                resalePrice: item.resalePrice,
                resoldDate: item.resoldDate
            )
            return summary.isTracked ? (item, summary) : nil
        }
        .sorted { $0.summary.dailyCost > $1.summary.dailyCost }
        vaultCache.costTrackedSummaries = result
        return result
    }

    private var filteredItems: [StoredItem] {
        let key = vaultKey
        ensureVaultCacheCurrent(for: key)
        if let cached = vaultCache.filteredItems {
            return cached
        }
        let result = allItems.filter { item in
            let matchesArea = selectedArea == "全部" || item.roomArea == selectedArea
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return matchesArea
            }
            let q = searchText.lowercased()
            let matchesQuery = item.name.lowercased().contains(q) ||
                item.location.lowercased().contains(q) ||
                item.roomArea.lowercased().contains(q) ||
                (item.notes?.lowercased().contains(q) ?? false)
            return matchesArea && matchesQuery
        }
        vaultCache.filteredItems = result
        return result
    }

    /// 当前筛选/搜索下的药品，按有效截止日升序（最易过期的排最前，无有效期排最后）
    private var filteredMedicines: [MedicineItem] {
        let areaMatched = selectedArea == "全部" ? medicines : medicines.filter { $0.roomArea == selectedArea }
        let symptomMatched = selectedSymptom == .all ? areaMatched : areaMatched.filter { selectedSymptom.matches($0) }
        let matched: [MedicineItem]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matched = symptomMatched
        } else {
            let q = searchText.lowercased()
            matched = symptomMatched.filter {
                $0.name.lowercased().contains(q) ||
                $0.storageLocation.lowercased().contains(q) ||
                ($0.usageMethod?.lowercased().contains(q) ?? false) ||
                ($0.indications?.lowercased().contains(q) ?? false) ||
                $0.categoryRaw.lowercased().contains(q)
            }
        }
        return matched.sorted {
            // 已处理（用完/丢弃）的沉底
            if $0.isDisposed != $1.isDisposed { return !$0.isDisposed }
            switch ($0.effectiveExpiryDate, $1.effectiveExpiryDate) {
            case (nil, nil): return $0.name < $1.name
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?): return a < b
            }
        }
    }

    private func showFeedback(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            actionFeedbackToast = text
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            if actionFeedbackToast == text {
                withAnimation {
                    actionFeedbackToast = nil
                }
            }
        }
    }

    /// 需要关注的药品：已过期或 30 天内到期且未处理
    private var attentionMedicines: [MedicineItem] {
        medicines.filter { !$0.isDisposed && ($0.isExpired || $0.isExpiringSoon) }
    }

    /// 批次排序：未处理优先，再按实际到期日升序（先进先出），无到期日排最后
    private func compareBatchExpiry(_ a: MedicineItem, _ b: MedicineItem) -> Bool {
        if a.isDisposed != b.isDisposed { return !a.isDisposed }
        switch (a.effectiveExpiryDate, b.effectiveExpiryDate) {
        case (nil, nil): return a.name < b.name
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x < y
        }
    }

    /// 按“同种药品”（名称+类别）分组，组内多批次按到期日升序；
    /// 组间按最早到期批次升序，全组已处理的排最后。
    private var groupedMedicines: [MedicineGroup] {
        let dict = Dictionary(grouping: filteredMedicines, by: { $0.batchKey })
        let groups = dict.map { key, items -> MedicineGroup in
            let sorted = items.sorted(by: compareBatchExpiry)
            return MedicineGroup(
                id: key,
                name: sorted.first?.name ?? "",
                category: sorted.first?.category ?? .other,
                batches: sorted
            )
        }
        return groups.sorted { g1, g2 in
            if g1.allDisposed != g2.allDisposed { return !g1.allDisposed }
            switch (g1.earliestActiveDate, g2.earliestActiveDate) {
            case (nil, nil): return g1.name < g2.name
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?): return a < b
            }
        }
    }

    /// 药品批次行：单批次直接显示，多批次内级于 DisclosureGroup 中；
    /// 左滑“再买一批”可快速录入同种药的新批次（带不同有效期）。
    @ViewBuilder
    private func batchRow(_ med: MedicineItem, showsChevron: Bool) -> some View {
        let hasActiveReminder = medPlans.contains { $0.medName == med.name && $0.isEnabled }

        MedicineItemRow(
            medicine: med,
            showsChevron: showsChevron,
            onTakeDose: (!med.isDisposed && !med.isExpired) ? {
                let msg = MedicineStockHelper.takeOneDose(medicine: med, context: context)
                showFeedback("\(med.name)：\(msg)")
            } : nil,
            onEditReminder: {
                let draft = MedicineUsageDraft.parse(from: med.usageMethod ?? "")
                reminderTarget = ReminderMedicineTarget(medicine: med, usageDraft: draft)
                Haptic.light()
            },
            onStopReminder: {
                _ = MedicineStockHelper.stopReminder(for: med.name, context: context)
                showFeedback("已停止「\(med.name)」服药提醒，常备药档案已保留")
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            medicineToEdit = med
            Haptic.light()
        }
        .swipeActions(edge: .leading) {
            if !med.isDisposed && !med.isExpired {
                Button {
                    let msg = MedicineStockHelper.takeOneDose(medicine: med, context: context)
                    showFeedback("\(med.name)：\(msg)")
                } label: {
                    Label("吃1次", systemImage: "checkmark.circle.fill")
                }
                .tint(.teal)
            }
            Button {
                medicinePrefillSource = med
                showingAddMedicineSheet = true
                Haptic.light()
            } label: {
                Label("再买一批", systemImage: "plus.circle")
            }
            .tint(.green)

            if hasActiveReminder {
                Button {
                    _ = MedicineStockHelper.stopReminder(for: med.name, context: context)
                    showFeedback("已停止「\(med.name)」服药提醒，常备药档案已保留")
                } label: {
                    Label("停止提醒", systemImage: "bell.slash.fill")
                }
                .tint(.orange)
            } else {
                Button {
                    let draft = MedicineUsageDraft.parse(from: med.usageMethod ?? "")
                    reminderTarget = ReminderMedicineTarget(medicine: med, usageDraft: draft)
                    Haptic.light()
                } label: {
                    Label("用药提醒", systemImage: "bell.badge.fill")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Haptic.warning()
                context.delete(med)
                try? context.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                if !med.isDisposed && (med.isExpired || med.isExpiringSoon) {
                    _ = MedicineStockHelper.disposeAndCreateRestockTodo(medicines: [med], context: context)
                    showFeedback("已标记处理「\(med.name)」并加入买药待办")
                } else {
                    med.isDisposed.toggle()
                    med.updatedAt = .now
                    try? context.save()
                    Haptic.light()
                }
            } label: {
                Label(
                    med.isDisposed ? "恢复" : ((med.isExpired || med.isExpiringSoon) ? "处理并补货" : "标记处理"),
                    systemImage: med.isDisposed ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(med.isDisposed ? .blue : .green)
        }
    }

    var body: some View {
        List {
            // 1. 顶部场景引导与房间区域快速筛选栏
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox.fill")
                            .font(.title2)
                            .foregroundStyle(.indigo)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("物品收纳备忘")
                                .font(.headline)
                            Text("随手记下贵重物、换季衣物或备用件存放位置，告别翻箱倒柜。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        let counts = areaCounts
                        HStack(spacing: 6) {
                            ForEach(roomAreas, id: \.self) { area in
                                let isSelected = selectedArea == area
                                let count = counts[area] ?? 0
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedArea = area
                                    }
                                    Haptic.selection()
                                } label: {
                                    HStack(spacing: 3) {
                                        Text(L10n.tr(area))
                                        if count > 0 {
                                            Text("\(count)")
                                                .font(.caption2.bold())
                                        }
                                    }
                                    .font(.subheadline)
                                    .fontWeight(isSelected ? .bold : .regular)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(isSelected ? Color.indigo : Color(.secondarySystemFill))
                                    )
                                    .foregroundStyle(isSelected ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 2. 持有成本速览（有成本数据的物品才显示）
            if !costTrackedSummaries.isEmpty {
                Section("日均持有成本速览") {
                    let totalValue = costTrackedSummaries.reduce(0.0) { $0 + $1.summary.totalCost }
                    let totalResale = costTrackedSummaries.reduce(0.0) { $0 + $1.summary.resalePrice }
                    let topItem = costTrackedSummaries[0]
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("跟踪物品")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(costTrackedSummaries.count) 件")
                                .font(.system(.subheadline, design: .rounded).bold())
                                .foregroundStyle(.indigo)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("累计投入")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "¥%.0f", totalValue))
                                .font(.system(.subheadline, design: .rounded).bold())
                                .foregroundStyle(.indigo)
                        }
                        if totalResale > 0 {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("转卖回血")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "¥%.0f", totalResale))
                                    .font(.system(.subheadline, design: .rounded).bold())
                                    .foregroundStyle(.green)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("最高日均")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(topItem.item.name)")
                                .font(.caption.bold())
                                .lineLimit(1)
                            Text(String(format: "¥%.1f/天", topItem.summary.dailyCost))
                                .font(.system(.subheadline, design: .rounded).bold())
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 3. 物品清单列表
            if filteredItems.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("未找到相关物品", systemImage: "shippingbox")
                    } description: {
                        Text(searchText.isEmpty ? "点击右上角 + 随手记下物品与存放柜子" : "换个搜索词试试，如：钥匙、羽绒服、工具箱")
                    }
                    .padding(.vertical, 16)
                }
            } else {
                Section("收纳明细 (\(filteredItems.count))") {
                    ForEach(filteredItems) { item in
                        StoredItemRow(item: item, linkedExpenseTotal: linkedTotals[item.id] ?? 0, onPreviewImage: { data in
                            previewImageData = data
                        })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            itemToEdit = item
                            Haptic.light()
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                itemToEdit = item
                                Haptic.light()
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Haptic.warning()
                                context.delete(item)
                                try? context.save()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            // 4. 药品与健康储备（重点跟踪有效期与用药方法）
            Section {
                if let toast = actionFeedbackToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(toast)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }

                if !medicines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "stethoscope")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text("按症状快速找药")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if selectedSymptom != .all {
                                Button("重置筛选") {
                                    selectedSymptom = .all
                                    Haptic.light()
                                }
                                .font(.caption2)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(MedicineSymptomFilter.allCases) { symptom in
                                    let isSelected = selectedSymptom == symptom
                                    let matchCount = symptom == .all
                                        ? medicines.filter { !$0.isDisposed }.count
                                        : medicines.filter { !$0.isDisposed && symptom.matches($0) }.count
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            selectedSymptom = (selectedSymptom == symptom && symptom != .all) ? .all : symptom
                                        }
                                        Haptic.selection()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: symptom.icon)
                                                .font(.caption2)
                                            Text(symptom.rawValue)
                                                .font(.caption.weight(isSelected ? .bold : .regular))
                                            if matchCount > 0 {
                                                Text("\(matchCount)")
                                                    .font(.caption2.bold())
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(isSelected ? Color.green : Color(.secondarySystemFill))
                                        )
                                        .foregroundStyle(isSelected ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !attentionMedicines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("\(attentionMedicines.count) 种药品已过期或临近有效期，注意及时更换处理")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        Button {
                            let targetNames = attentionMedicines.map(\.name).joined(separator: "、")
                            let count = MedicineStockHelper.disposeAndCreateRestockTodo(
                                medicines: attentionMedicines,
                                context: context
                            )
                            showFeedback("已清理 \(count) 种过期/临期药（\(targetNames)），并生成补充买药待办")
                        } label: {
                            Label("一键标记已清理并加入买药待办", systemImage: "cart.fill.badge.plus")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(.vertical, 2)
                }

                if groupedMedicines.isEmpty {
                    Text(medicines.isEmpty ? "暂无常备药，可点击右上角 + 添加并记录有效期与用法；同种药多次购买可逐批录入不同保质期" : "当前「\(selectedSymptom.rawValue)」筛选下暂无常备药")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupedMedicines) { group in
                        if group.batches.count == 1 {
                            batchRow(group.batches[0], showsChevron: true)
                        } else {
                            DisclosureGroup {
                                ForEach(group.batches) { batch in
                                    batchRow(batch, showsChevron: false)
                                }
                            } label: {
                                MedicineGroupHeader(group: group)
                            }
                            .tint(.green)
                        }
                    }
                }
            } header: {
                Label("药品与健康储备", systemImage: "pills.fill")
            }
        }
        .listStyle(.insetGrouped)
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle("物品收纳找物")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text(L10n.tr("搜索物品名称、存放位置、常备药或适应症…")))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("添加收纳物品", systemImage: "archivebox.fill") {
                        showingAddSheet = true
                        Haptic.light()
                    }
                    Button("添加常备药", systemImage: "pills.fill") {
                        medicinePrefillSource = nil
                        showingAddMedicineSheet = true
                        Haptic.light()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.indigo)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("添加收纳物品或常备药")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddOrEditStoredItemSheet(itemToEdit: nil)
        }
        .sheet(item: $itemToEdit) { item in
            AddOrEditStoredItemSheet(itemToEdit: item)
        }
        .sheet(isPresented: $showingAddMedicineSheet) {
            MedicineEditorSheet(medicine: nil, prefillFrom: medicinePrefillSource)
        }
        .sheet(item: $medicineToEdit) { med in
            MedicineEditorSheet(medicine: med)
        }
        .sheet(item: $reminderTarget) { target in
            AddMedicationReminderPopupSheet(medicine: target.medicine, usageDraft: target.usageDraft)
        }
        .sheet(isPresented: Binding(
            get: { previewImageData != nil },
            set: { if !$0 { previewImageData = nil } }
        )) {
            if let data = previewImageData, let uiImage = UIImage(data: data) {
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding()
                    }
                    .navigationTitle("收纳位置照片")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { previewImageData = nil }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 单行展示卡片

private struct StoredItemRow: View {
    let item: StoredItem
    var linkedExpenseTotal: Double = 0
    var onPreviewImage: ((Data) -> Void)? = nil

    private var costSummary: ItemCostSummary {
        ItemCostCalculator.summary(
            purchasePrice: item.purchasePrice,
            purchaseDate: item.purchaseDate,
            fallbackStartDate: item.createdAt,
            linkedExpenseTotal: linkedExpenseTotal,
            isSecondHand: item.isSecondHand,
            resalePrice: item.resalePrice,
            resoldDate: item.resoldDate
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            // 实物或收纳柜照片缩略图：降采样 + 进程内缓存，避免行重绘时反复整图解码卡住滚动
            if let data = item.imageData, let uiImg = RowThumbnailCache.thumbnail(id: item.id, updatedAt: item.updatedAt, data: data) {
                Button {
                    onPreviewImage?(data)
                } label: {
                    Image(uiImage: uiImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(Color.indigo.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "archivebox.fill")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.bold())
                        .foregroundStyle(.primary)

                    Text(L10n.tr(item.roomArea))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.indigo.opacity(0.14)))
                        .foregroundStyle(.indigo)

                    if item.isSecondHand {
                        Text("二手购入")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.teal.opacity(0.14)))
                            .foregroundStyle(.teal)
                    }

                    if costSummary.isResold {
                        Text("已转卖")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.location)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // 日均持有成本（已录入购入价或有关联投入时显示）
                if costSummary.isTracked {
                    if costSummary.isResold {
                        Text(String(format: "持有 %d 天 · 回血 ¥%.0f · 净成本 ¥%.2f（净日均 ¥%.1f/天）", costSummary.daysHeld, costSummary.resalePrice, costSummary.netCost, costSummary.netDailyCost))
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    } else {
                        Text(String(format: "已使用 %d 天 · 日均 ¥%.1f/天", costSummary.daysHeld, costSummary.dailyCost))
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 新建 / 编辑收纳物品表单

struct AddOrEditStoredItemSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let itemToEdit: StoredItem?

    @State private var name: String = ""
    @State private var roomArea: String = "主卧"
    @State private var location: String = ""
    @State private var notes: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var showingCamera: Bool = false
    @State private var isRecognizingItemOCR: Bool = false
    @State private var ocrItemHint: String? = nil
    @State private var purchasePriceString: String = ""
    @State private var purchaseDate: Date = .now
    @State private var isSecondHand: Bool = false
    @State private var resalePriceString: String = ""
    @State private var resoldDate: Date = .now

    // 编辑模式：关联记账投入归集
    @State private var linkedExpenseTotal: Double = 0
    @State private var linkedExpenseCount: Int = 0

    private var parsedPurchasePrice: Double? {
        let value = Double(purchasePriceString.replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
        return value > 0 ? value : nil
    }

    private var parsedResalePrice: Double? {
        let value = Double(resalePriceString.replacingOccurrences(of: "，", with: ".").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
        return value > 0 ? value : nil
    }

    private var liveCostSummary: ItemCostSummary {
        guard let item = itemToEdit else {
            return ItemCostCalculator.summary(
                purchasePrice: parsedPurchasePrice,
                purchaseDate: purchaseDate,
                fallbackStartDate: .now,
                isSecondHand: isSecondHand,
                resalePrice: parsedResalePrice,
                resoldDate: parsedResalePrice != nil ? resoldDate : nil
            )
        }
        return ItemCostCalculator.summary(
            purchasePrice: parsedPurchasePrice ?? item.purchasePrice,
            purchaseDate: item.purchaseDate ?? (parsedPurchasePrice == nil ? nil : purchaseDate),
            fallbackStartDate: item.createdAt,
            linkedExpenseTotal: linkedExpenseTotal,
            isSecondHand: isSecondHand,
            resalePrice: parsedResalePrice ?? item.resalePrice,
            resoldDate: parsedResalePrice != nil ? resoldDate : item.resoldDate
        )
    }

    private let roomAreas = ["玄关", "主卧", "次卧", "客厅", "书房", "储物间", "阳台", "厨房", "卫生间"]
    private let commonItemSuggestions = ["备用钥匙", "冬季羽绒服", "露营户外帐篷", "发票与保修卡", "五金工具箱", "重要证件原件", "换季床单被罩", "行李箱"]
    private let commonLocationSuggestions = ["衣柜顶层收纳箱", "床底储物抽屉", "鞋柜抽屉木盒", "书柜底层内侧", "玄关托盘", "阳台金属架"]

    init(itemToEdit: StoredItem?) {
        self.itemToEdit = itemToEdit
        if let item = itemToEdit {
            self._name = State(initialValue: item.name)
            self._roomArea = State(initialValue: item.roomArea)
            self._location = State(initialValue: item.location)
            self._notes = State(initialValue: item.notes ?? "")
            self._selectedImageData = State(initialValue: item.imageData)
            if let price = item.purchasePrice {
                self._purchasePriceString = State(initialValue: price.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", price) : String(format: "%.2f", price))
            }
            if let date = item.purchaseDate {
                self._purchaseDate = State(initialValue: date)
            }
            self._isSecondHand = State(initialValue: item.isSecondHand)
            if let resale = item.resalePrice {
                self._resalePriceString = State(initialValue: resale.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", resale) : String(format: "%.2f", resale))
            }
            if let date = item.resoldDate {
                self._resoldDate = State(initialValue: date)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 物品基本信息
                Section("物品名称") {
                    TextField("例如：备用钥匙、冬季羽绒服、帐篷", text: $name)

                    // 常用高频物品快捷预设标签
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(commonItemSuggestions, id: \.self) { s in
                                Button {
                                    name = s
                                    Haptic.light()
                                } label: {
                                    Text(L10n.tr(s))
                                        .font(.caption)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 2. 存放房间与位置
                Section("存放位置") {
                    Picker("所在房间/区域", selection: $roomArea) {
                        ForEach(roomAreas, id: \.self) { area in
                            Text(L10n.tr(area)).tag(area)
                        }
                    }

                    TextField("详细位置（如：大衣柜顶层左侧真空袋、内侧抽屉）", text: $location)

                    // 常用收纳位置快捷标签
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(commonLocationSuggestions, id: \.self) { loc in
                                Button {
                                    location = loc
                                    Haptic.light()
                                } label: {
                                    Text(loc)
                                        .font(.caption)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 3. 现场实拍照片（开箱开柜即认出，支持文字标签自动识别）
                Section("收纳实景照片与智能识物（选填）") {
                    if let data = selectedImageData, let uiImage = UIImage(data: data) {
                        HStack {
                            Spacer()
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        selectedImageData = nil
                                        selectedPhotoItem = nil
                                        ocrItemHint = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white, Color.black.opacity(0.6))
                                            .padding(6)
                                    }
                                }
                            Spacer()
                        }
                    }

                    if isRecognizingItemOCR {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在识别物品标签/包装文字…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let hint = ocrItemHint {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.indigo)
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.indigo)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            showingCamera = true
                            Haptic.light()
                        } label: {
                            Label("直接拍照识物", systemImage: "camera.fill")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Color.indigo.opacity(0.12)))
                                .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.plain)

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label(selectedImageData == nil ? "从相册选图" : "更换照片", systemImage: "photo.on.rectangle")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Color(.tertiarySystemFill)))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                selectedImageData = data
                                if let img = UIImage(data: data) {
                                    await recognizeStoredItemText(from: img)
                                }
                            }
                        }
                    }
                }

                // 3.5 购入信息（选填，打通记账计算日均持有成本）
                Section {
                    HStack {
                        Text("购入价格")
                            .foregroundStyle(.secondary)
                        TextField("如 6999", text: $purchasePriceString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("¥")
                            .foregroundStyle(.secondary)
                    }

                    if parsedPurchasePrice != nil || (itemToEdit?.purchasePrice != nil) {
                        DatePicker("购入日期", selection: $purchaseDate, displayedComponents: .date)
                        Toggle("二手购入", isOn: $isSecondHand)
                    }

                    if liveCostSummary.isTracked {
                        VStack(alignment: .leading, spacing: 4) {
                            if liveCostSummary.isResold {
                                Text(String(format: "转卖回血 ¥%.0f · 净成本 ¥%.2f · 净日均 ¥%.1f/天", liveCostSummary.resalePrice, liveCostSummary.netCost, liveCostSummary.netDailyCost))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.green)
                            } else {
                                Text(String(format: "已使用 %d 天 · 累计投入 ¥%.2f · 日均 ¥%.1f/天", liveCostSummary.daysHeld, liveCostSummary.totalCost, liveCostSummary.dailyCost))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.orange)
                            }
                            if let milestone = liveCostSummary.milestoneText {
                                Text(L10n.tr(milestone))
                                    .font(.caption)
                                    .foregroundStyle(liveCostSummary.isResold ? .green : .orange)
                            }
                            if itemToEdit != nil && linkedExpenseCount > 0 {
                                Text("含 \(linkedExpenseCount) 笔关联记账投入 ¥\(String(format: "%.2f", linkedExpenseTotal))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("购入信息（选填）")
                } footer: {
                    Text("填写购入价格后，自动计算持有天数与日均持有成本；记账时可把保养、配件等后续投入关联到该物品。二手购入的物品买入价更低，日均成本起点也更低。")
                }

                // 3.6 转卖回血（选填，闲置出二手后记录实际净持有成本）
                Section {
                    HStack {
                        Text("转卖所得")
                            .foregroundStyle(.secondary)
                        TextField("如 3500", text: $resalePriceString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("¥")
                            .foregroundStyle(.secondary)
                    }

                    if parsedResalePrice != nil {
                        DatePicker("转卖日期", selection: $resoldDate, displayedComponents: .date)
                    }

                    if let item = itemToEdit, item.resoldDate != nil, parsedResalePrice == nil, item.resalePrice != nil {
                        Button(role: .destructive) {
                            resalePriceString = ""
                            item.resalePrice = nil
                            item.resoldDate = nil
                            item.updatedAt = .now
                            try? context.save()
                        } label: {
                            Label("撤销转卖记录", systemImage: "arrow.uturn.backward")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("转卖回血（选填）")
                } footer: {
                    Text("不常用的物品转卖为二手后，在此记录回血金额：实际持有成本 = 累计投入 − 转卖所得，持有天数截至转卖日。")
                }

                // 4. 补充说明
                Section("补充备注（选填）") {
                    TextField("例如：共2件、防尘袋包装、密码是1234", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .onAppear {
                loadLinkedExpenses()
            }
            .navigationTitle(itemToEdit == nil ? "新建收纳备忘" : "编辑收纳备忘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveItem()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingCamera) {
                VaultCameraPicker { captured in
                    selectedImageData = captured.jpegData(compressionQuality: 0.78)
                    Task {
                        await recognizeStoredItemText(from: captured)
                    }
                }
            }
        }
    }

    @MainActor
    private func recognizeStoredItemText(from image: UIImage) async {
        isRecognizingItemOCR = true
        defer { isRecognizingItemOCR = false }
        guard let text = try? await OCRService.shared.recognizeText(from: image) else { return }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 24 }
        guard let firstMeaningful = lines.first(where: { line in
            !line.allSatisfy({ $0.isNumber || $0.isPunctuation })
        }) else { return }

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = firstMeaningful
            ocrItemHint = "已自动填入物品名称：「\(firstMeaningful)」"
            Haptic.success()
        } else {
            ocrItemHint = "识别到标签：「\(firstMeaningful)」"
        }
    }

    /// 编辑模式下归集该物品的关联记账投入
    private func loadLinkedExpenses() {
        guard let item = itemToEdit else { return }
        let pid: UUID? = item.id
        // 按关联物品 ID 谓词定向取数，不再为几笔关联记账物化整本账
        let descriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { !$0.isIncome && $0.linkedItemID == pid }
        )
        let linked = (try? context.fetch(descriptor)) ?? []
        linkedExpenseTotal = linked.reduce(0) { $0 + $1.amount }
        linkedExpenseCount = linked.count
    }

    private func saveItem() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = itemToEdit {
            existing.name = trimmedName
            existing.roomArea = roomArea
            existing.location = trimmedLocation
            existing.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
            existing.imageData = selectedImageData
            existing.purchasePrice = parsedPurchasePrice
            existing.purchaseDate = parsedPurchasePrice != nil ? purchaseDate : existing.purchaseDate
            existing.isSecondHand = isSecondHand
            existing.resalePrice = parsedResalePrice
            existing.resoldDate = parsedResalePrice != nil ? resoldDate : existing.resoldDate
            existing.updatedAt = .now
        } else {
            let newItem = StoredItem(
                name: trimmedName,
                location: trimmedLocation,
                roomArea: roomArea,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                imageData: selectedImageData,
                purchasePrice: parsedPurchasePrice,
                purchaseDate: parsedPurchasePrice != nil ? purchaseDate : nil,
                isSecondHand: isSecondHand,
                resalePrice: parsedResalePrice,
                resoldDate: parsedResalePrice != nil ? resoldDate : nil
            )
            context.insert(newItem)
        }

        try? context.save()
        Haptic.success()
        dismiss()
    }
}

/// 行级图片数据缩略图缓存：ImageIO 降采样 + 进程内缓存，
/// 避免列表行每次重绘都整图解码原图卡住滚动。
/// 键为（行 ID、字节数、updatedAt）：换图或编辑保存都会换键重新生成，不会串旧图。
enum RowThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    static func thumbnail(id: UUID, updatedAt: Date, data: Data, maxPixelSize: CGFloat = 140) -> UIImage? {
        let key = "\(id.uuidString)-\(data.count)-\(Int(updatedAt.timeIntervalSince1970))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        let image: UIImage?
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            image = UIImage(cgImage: cg)
        } else {
            // 格式不被 ImageIO 识别时退回整图解码一次并缓存结果
            image = UIImage(data: data)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// 常备药批次行：突出展示有效期状态，兼顾用法、购买批次与存放位置，并提供一键服药打卡与扣减余量
private struct MedicineItemRow: View {
    let medicine: MedicineItem
    var showsChevron: Bool = true
    var onTakeDose: (() -> Void)? = nil
    var onEditReminder: (() -> Void)? = nil
    var onStopReminder: (() -> Void)? = nil
    @Query private var medPlans: [MedicationPlan]
    @Environment(\.modelContext) private var context

    private var linkedPlan: MedicationPlan? {
        medPlans.first { $0.medName == medicine.name && $0.isEnabled }
    }

    private var pausedPlan: MedicationPlan? {
        medPlans.first { $0.medName == medicine.name && !$0.isEnabled }
    }

    private var takenRecentlyToday: Bool {
        guard let last = linkedPlan?.lastTakenAt else { return false }
        return Calendar.current.isDateInToday(last) && Date().timeIntervalSince(last) < 3 * 3600
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 52, height: 52)
                if let data = medicine.imageData,
                   let thumb = RowThumbnailCache.thumbnail(id: medicine.id, updatedAt: medicine.updatedAt, data: data) {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                } else {
                    Image(systemName: medicine.category.icon)
                        .font(.title3)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(medicine.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    Text(medicine.category.displayName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                        .foregroundStyle(.green)
                    if let plan = linkedPlan {
                        Menu {
                            Button(role: .destructive) {
                                if let onStopReminder {
                                    onStopReminder()
                                } else {
                                    _ = MedicineStockHelper.stopReminder(for: medicine.name, context: context)
                                }
                            } label: {
                                Label("一键停止提醒（病愈停服）", systemImage: "bell.slash.fill")
                            }
                            if let onEditReminder {
                                Button {
                                    onEditReminder()
                                } label: {
                                    Label("修改提醒排期", systemImage: "clock")
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "bell.badge.fill")
                                Text("每日\(plan.dailyTimePoints.count)次提醒")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                            .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    } else if pausedPlan != nil {
                        if let onEditReminder {
                            Button {
                                onEditReminder()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "bell.slash")
                                    Text("提醒已停用")
                                }
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if medicine.isDisposed {
                        Text("已处理")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                            .foregroundStyle(.secondary)
                    }
                }

                expiryLine

                batchMetaLine

                if let usage = medicine.usageMethod, !usage.isEmpty {
                    Label(usage, systemImage: "text.book.closed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(L10n.tr(medicine.roomArea)) · \(medicine.storageLocation)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                if let onTakeDose {
                    Button {
                        onTakeDose()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: takenRecentlyToday ? "checkmark.circle.fill" : "pills.fill")
                                .font(.caption2)
                            Text(takenRecentlyToday ? "已服" : "吃1次")
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(takenRecentlyToday ? Color.green.opacity(0.18) : Color.teal.opacity(0.14))
                        )
                        .foregroundStyle(takenRecentlyToday ? .green : .teal)
                    }
                    .buttonStyle(.plain)
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 批次元信息文本：购买日 + 剩余数量（普通计算属性，避免在 ViewBuilder 里做变量累加）
    private var batchMetaText: String {
        var parts: [String] = []
        if let p = medicine.purchaseDate {
            parts.append("购于 \(p.formatted(date: .abbreviated, time: .omitted))")
        }
        if let q = medicine.remainingQuantity, !q.isEmpty {
            parts.append("余 \(q)")
        }
        return parts.joined(separator: " · ")
    }

    /// 同种药多批次时用于区分先后与余量
    @ViewBuilder private var batchMetaLine: some View {
        let meta = batchMetaText
        if !meta.isEmpty {
            Text(meta)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var expiryLine: some View {
        if medicine.isDisposed {
            Text("已用完或丢弃")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let days = medicine.daysUntilExpiry {
            if days < 0 {
                Label("已过期 \(abs(days)) 天", systemImage: "xmark.octagon.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            } else if days <= 30 {
                Label("剩 \(days) 天到期", systemImage: "clock.badge.exclamationmark")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            } else if let date = medicine.effectiveExpiryDate {
                Text("有效至 \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("未设置有效期")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 同种药品分组（名称+类别），一个组可含多个批次（不同保质期）
private struct MedicineGroup: Identifiable {
    let id: String
    let name: String
    let category: MedicineCategory
    let batches: [MedicineItem]

    var count: Int { batches.count }
    var activeBatches: [MedicineItem] { batches.filter { !$0.isDisposed } }
    var allDisposed: Bool { batches.allSatisfy { $0.isDisposed } }
    var earliestActiveDate: Date? { activeBatches.compactMap { $0.effectiveExpiryDate }.min() }
    var needsAttention: Bool { activeBatches.contains { $0.isExpired || $0.isExpiringSoon } }
    /// 代展示批次：优先取最先到期的未处理批次
    var representative: MedicineItem? { activeBatches.first ?? batches.first }
}

/// 药品分组头部：展示药名、批次数与最先到期状态（多批次时可展开）
private struct MedicineGroupHeader: View {
    let group: MedicineGroup

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 52, height: 52)
                if let rep = group.representative, let data = rep.imageData,
                   let thumb = RowThumbnailCache.thumbnail(id: rep.id, updatedAt: rep.updatedAt, data: data) {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                } else {
                    Image(systemName: group.category.icon)
                        .font(.title3)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.body.bold())
                        .lineLimit(1)
                    Text(group.category.displayName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                        .foregroundStyle(.green)
                    Text("共 \(group.count) 批")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                        .foregroundStyle(.secondary)
                }

                if group.needsAttention, let rep = group.representative, rep.isExpired {
                    Label("最早一批已过期 \(abs(rep.daysUntilExpiry ?? 0)) 天", systemImage: "xmark.octagon.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else if group.needsAttention, let rep = group.representative {
                    Label("最早一批剩 \(rep.daysUntilExpiry ?? 0) 天到期", systemImage: "clock.badge.exclamationmark")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else if let date = group.earliestActiveDate {
                    Text("最早一批有效至 \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未设置有效期")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// 新建/编辑常备药：手滑动选择用法用量、丰富常用药预设、有效期智能管理与自动弹出服药提醒
struct MedicineEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let medicine: MedicineItem?

    @State private var name: String = ""
    @State private var category: MedicineCategory = .otc
    @State private var indications: String = ""
    @State private var usageDraft: MedicineUsageDraft = MedicineUsageDraft()
    @State private var showCustomUsageText: Bool = false
    @State private var remainingQuantity: String = ""
    @State private var precautions: String = ""
    @State private var roomArea: String = "储物间"
    @State private var storageLocation: String = "家庭药箱"
    @State private var hasPurchaseDate: Bool = false
    @State private var purchaseDate: Date = .now
    @State private var hasExpiry: Bool = true
    @State private var expiryDate: Date = Calendar.current.date(byAdding: .year, value: 2, to: .now) ?? .now
    @State private var isOpened: Bool = false
    @State private var openedDate: Date = .now
    @State private var afterOpenDaysChoice: Int? = nil
    @State private var isDisposed: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var showingMedicineCamera: Bool = false
    @State private var isRecognizingMedicineOCR: Bool = false
    @State private var ocrBannerText: String? = nil

    // 提醒弹窗联动
    @State private var enablePostAddReminder: Bool = true
    @State private var newlySavedMedicine: MedicineItem? = nil
    @State private var showingReminderPopup: Bool = false

    private let roomAreas = ["玄关", "主卧", "次卧", "客厅", "书房", "储物间", "阳台", "厨房", "卫生间"]
    private let afterOpenDayOptions = [7, 14, 28, 30, 60, 90, 180]

    private let frequencyChoices: [FrequencyChoice] = [
        FrequencyChoice(title: "一日 1 次", count: 1, special: ""),
        FrequencyChoice(title: "一日 2 次", count: 2, special: ""),
        FrequencyChoice(title: "一日 3 次", count: 3, special: ""),
        FrequencyChoice(title: "一日 4 次", count: 4, special: ""),
        FrequencyChoice(title: "每晚睡前", count: 1, special: "每晚睡前"),
        FrequencyChoice(title: "晨起空腹", count: 1, special: "晨起空腹"),
        FrequencyChoice(title: "每隔 8 小时", count: 3, special: "每隔8小时"),
        FrequencyChoice(title: "每隔 12 小时", count: 2, special: "每隔12小时"),
        FrequencyChoice(title: "必要时/按需", count: 0, special: "必要时/按需")
    ]

    private let amountPresets: [Double] = [0.5, 1, 1.5, 2, 3, 4, 5, 10]
    private let unitPresets = ["片", "粒", "颗", "袋", "支", "毫升", "滴", "包", "丸", "贴", "喷", "勺"]
    private let mealRelationPresets: [MedicationMealRelation] = [
        .afterMeal(minutes: 30),
        .afterMeal(minutes: 15),
        .withMeal,
        .beforeMeal(minutes: 30),
        .bedtime,
        .unrestricted
    ]
    private let routePresets = ["口服", "温水冲服", "舌下含服", "外用涂抹", "滴眼", "滴鼻", "喷雾吸入"]

    private let commonLocations = [
        (area: "储物间", location: "家庭药箱"),
        (area: "客厅", location: "电视柜抽屉"),
        (area: "主卧", location: "床头柜"),
        (area: "厨房", location: "冰箱冷藏室"),
        (area: "玄关", location: "随身包"),
        (area: "书房", location: "办公桌抽屉"),
        (area: "卫生间", location: "洗漱台镜柜")
    ]

    private let quantityChips = ["整盒", "半盒", "剩 10 片", "剩 5 片", "1 支", "1 瓶", "余量不多"]
    private let precautionChips = ["避免空腹", "胃溃疡慎用", "服药忌酒", "服后易嗜睡", "避光冷藏", "青霉素过敏禁用", "开封后28天用完", "与其他药间隔2小时"]

    init(medicine: MedicineItem?, prefillFrom: MedicineItem? = nil) {
        self.medicine = medicine
        if let m = medicine {
            self._name = State(initialValue: m.name)
            self._category = State(initialValue: m.category)
            self._indications = State(initialValue: m.indications ?? "")
            let draft = MedicineUsageDraft.parse(from: m.usageMethod ?? "")
            self._usageDraft = State(initialValue: draft)
            self._remainingQuantity = State(initialValue: m.remainingQuantity ?? "")
            self._precautions = State(initialValue: m.precautions ?? "")
            self._roomArea = State(initialValue: m.roomArea)
            self._storageLocation = State(initialValue: m.storageLocation)
            self._hasPurchaseDate = State(initialValue: m.purchaseDate != nil)
            if let d = m.purchaseDate { self._purchaseDate = State(initialValue: d) }
            self._hasExpiry = State(initialValue: m.expiryDate != nil)
            if let d = m.expiryDate { self._expiryDate = State(initialValue: d) }
            self._isOpened = State(initialValue: m.isOpened)
            if let d = m.openedDate { self._openedDate = State(initialValue: d) }
            self._afterOpenDaysChoice = State(initialValue: m.afterOpenValidDays)
            self._isDisposed = State(initialValue: m.isDisposed)
            self._selectedImageData = State(initialValue: m.imageData)
            self._enablePostAddReminder = State(initialValue: false)
        } else if let src = prefillFrom {
            self._name = State(initialValue: src.name)
            self._category = State(initialValue: src.category)
            self._indications = State(initialValue: src.indications ?? "")
            let draft = MedicineUsageDraft.parse(from: src.usageMethod ?? "")
            self._usageDraft = State(initialValue: draft)
            self._precautions = State(initialValue: src.precautions ?? "")
            self._roomArea = State(initialValue: src.roomArea)
            self._storageLocation = State(initialValue: src.storageLocation)
            self._hasPurchaseDate = State(initialValue: true)
            self._purchaseDate = State(initialValue: .now)
            self._enablePostAddReminder = State(initialValue: true)
        } else {
            self._enablePostAddReminder = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 顶部一键拍药盒/说明书智能填入
                Section {
                    HStack(spacing: 10) {
                        Button {
                            showingMedicineCamera = true
                            Haptic.light()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.body.bold())
                                Text("拍药盒智能填入")
                                    .font(.subheadline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).fill(Color.green))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.badge.magnifyingglass")
                                    .font(.body.bold())
                                Text("从相册识药")
                                    .font(.subheadline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous).fill(Color.green.opacity(0.14)))
                            .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)

                    if isRecognizingMedicineOCR {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在识别药盒名称、一日几次用法与有效期…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let banner = ocrBannerText {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.green)
                            Text(banner)
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("智能识药（免手输）")
                } footer: {
                    Text("对准药盒正面或说明书拍照，自动识别药名、一日几次用量及保质期。")
                }

                // MARK: - 药品名称与常用药预设
                Section("药品名称") {
                    TextField("例如：布洛芬、维生素C、眼药水", text: $name)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(commonMedicinePresets) { preset in
                                Button {
                                    applyPreset(preset)
                                    Haptic.selection()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: preset.category.icon)
                                            .font(.caption2)
                                        Text(preset.name)
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(name == preset.name ? Color.green.opacity(0.18) : Color(.tertiarySystemFill))
                                    .overlay(
                                        Capsule().stroke(name == preset.name ? Color.green : Color.clear, lineWidth: 1)
                                    )
                                    .foregroundStyle(name == preset.name ? Color.green : Color.primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - 类别与用途
                Section("分类与用途") {
                    Picker("类别", selection: $category) {
                        ForEach(MedicineCategory.allCases, id: \.self) { c in
                            Label(c.rawValue, systemImage: c.icon).tag(c)
                        }
                    }
                    TextField("用途/主治（如：退烧止痛、抗过敏）", text: $indications)
                }

                // MARK: - 用药方法（滑动点选）
                Section {
                    // 1. 每日频次滑动选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每日频次")
                            .font(.subheadline.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(frequencyChoices) { choice in
                                    let isSelected = usageDraft.matchesFrequency(choice)
                                    Button {
                                        usageDraft.applyFrequency(choice)
                                        Haptic.selection()
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.caption2.bold())
                                            }
                                            Text(choice.title)
                                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(isSelected ? Color.green : Color(.tertiarySystemFill)))
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // 2. 每次剂量与单位
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("每次用量")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("每次 \(usageDraft.formattedAmount) \(usageDraft.dosageUnit)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.green)
                        }

                        // 剂量数值胶囊
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(amountPresets, id: \.self) { amt in
                                    let isSelected = abs(usageDraft.dosageAmount - amt) < 0.001
                                    Button {
                                        usageDraft.dosageAmount = amt
                                        Haptic.selection()
                                    } label: {
                                        Text(amt == amt.rounded() ? String(Int(amt)) : String(format: "%g", amt))
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(isSelected ? Color.green.opacity(0.18) : Color(.tertiarySystemFill)))
                                            .overlay(Capsule().stroke(isSelected ? Color.green : Color.clear, lineWidth: 1.5))
                                            .foregroundStyle(isSelected ? Color.green : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        Stepper("数值精确微调: \(usageDraft.formattedAmount)", value: $usageDraft.dosageAmount, in: 0.5...30, step: 0.5)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider().padding(.vertical, 2)

                        Text("剂量单位")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        // 剂量单位胶囊
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(unitPresets, id: \.self) { unit in
                                    let isSelected = usageDraft.dosageUnit == unit
                                    Button {
                                        usageDraft.dosageUnit = unit
                                        Haptic.selection()
                                    } label: {
                                        Text(unit)
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(isSelected ? Color.green : Color(.tertiarySystemFill)))
                                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // 3. 服药时机/时效关系
                    VStack(alignment: .leading, spacing: 6) {
                        Text("服药时机（防伤胃与吸收）")
                            .font(.subheadline.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(mealRelationPresets, id: \.self) { rel in
                                    let isSelected = usageDraft.mealRelation == rel
                                    Button {
                                        usageDraft.mealRelation = rel
                                        Haptic.selection()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: rel.iconName)
                                                .font(.caption)
                                            Text(rel.displayName)
                                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                        }
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(isSelected ? Color.blue : Color(.tertiarySystemFill)))
                                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // 4. 给药途径
                    VStack(alignment: .leading, spacing: 6) {
                        Text("给药途径")
                            .font(.subheadline.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(routePresets, id: \.self) { r in
                                    let isSelected = usageDraft.route == r
                                    Button {
                                        usageDraft.route = r
                                        Haptic.selection()
                                    } label: {
                                        Text(r)
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 6)
                                            .background(Capsule().fill(isSelected ? Color.indigo : Color(.tertiarySystemFill)))
                                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // 5. 实时生成的标准用法预览
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("用法预览")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                showCustomUsageText.toggle()
                                Haptic.light()
                            } label: {
                                Label(showCustomUsageText ? "收起补充" : "补充微调", systemImage: showCustomUsageText ? "chevron.up" : "square.and.pencil")
                                    .font(.caption2)
                            }
                        }

                        Text(usageDraft.formattedUsage)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .fill(Color.green.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                            .stroke(Color.green.opacity(0.2), lineWidth: 1)
                                    )
                            )

                        if showCustomUsageText {
                            TextField("补充说明（如：发热超过38.5℃时服用）", text: $usageDraft.customNote)
                                .font(.subheadline)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } header: {
                    Text("用药方法（滑动点选）")
                } footer: {
                    Text("手滑点选频次、剂量与时机，系统将自动生成规范用药指令，并联动用于定时提醒排期。")
                }

                // MARK: - 剩余数量与注意事项
                Section("库存与注意事项") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("剩余数量（如：约8片、半盒、1支）", text: $remainingQuantity)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(quantityChips, id: \.self) { chip in
                                    Button {
                                        remainingQuantity = chip
                                        Haptic.light()
                                    } label: {
                                        Text(chip)
                                            .font(.caption)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(remainingQuantity == chip ? Color.green.opacity(0.18) : Color(.tertiarySystemFill))
                                            .foregroundStyle(remainingQuantity == chip ? Color.green : Color.primary)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("注意事项/禁忌（如：司机忌服、避光冷藏）", text: $precautions, axis: .vertical)
                            .lineLimit(2...3)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(precautionChips, id: \.self) { chip in
                                    Button {
                                        if precautions.isEmpty {
                                            precautions = chip
                                        } else if !precautions.contains(chip) {
                                            precautions += "，" + chip
                                        }
                                        Haptic.light()
                                    } label: {
                                        Text("+ \(chip)")
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // MARK: - 存放位置
                Section("存放位置") {
                    Picker("所在房间/区域", selection: $roomArea) {
                        ForEach(roomAreas, id: \.self) { area in
                            Text(L10n.tr(area)).tag(area)
                        }
                    }
                    TextField("详细位置（如：家庭药箱第二层、电视柜抽屉）", text: $storageLocation)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(commonLocations, id: \.location) { loc in
                                Button {
                                    roomArea = loc.area
                                    storageLocation = loc.location
                                    Haptic.light()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.caption2)
                                        Text("\(loc.area) · \(loc.location)")
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(storageLocation == loc.location ? Color.green.opacity(0.18) : Color(.tertiarySystemFill))
                                    .overlay(
                                        Capsule().stroke(storageLocation == loc.location ? Color.green : Color.clear, lineWidth: 1)
                                    )
                                    .foregroundStyle(storageLocation == loc.location ? Color.green : Color.primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - 有效期
                Section {
                    Toggle("记录购买/获得日期", isOn: $hasPurchaseDate)
                    if hasPurchaseDate {
                        DatePicker("购买日期", selection: $purchaseDate, displayedComponents: .date)
                    }
                    Toggle("设置有效期", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("包装到期日", selection: $expiryDate, displayedComponents: .date)
                        HStack(spacing: 8) {
                            Text("快速顺延：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach([1, 2, 3], id: \.self) { yrs in
                                Button("+\(yrs) 年") {
                                    if let newDate = Calendar.current.date(byAdding: .year, value: yrs, to: .now) {
                                        expiryDate = newDate
                                        Haptic.light()
                                    }
                                }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                        }
                    }
                    Toggle("已开封", isOn: $isOpened)
                    if isOpened {
                        DatePicker("开封日期", selection: $openedDate, displayedComponents: .date)
                        Picker("开封后有效", selection: $afterOpenDaysChoice) {
                            Text("不设开封期限").tag(Int?.none)
                            ForEach(afterOpenDayOptions, id: \.self) { days in
                                Text("开封后 \(days) 天").tag(Int?.some(days))
                            }
                        }
                    }
                } header: {
                    Text("有效期（防过期重点）")
                } footer: {
                    Text("开封后使用期通常比包装有效期更短（如眼药水开封后约 28 天），系统会取两者较早者作为实际到期日。同种药多次购买会按“最先到期优先”分组排列。")
                }

                // MARK: - 药盒照片
                Section("药盒/说明书照片（选填）") {
                    if let data = selectedImageData, let uiImage = UIImage(data: data) {
                        HStack {
                            Spacer()
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        selectedImageData = nil
                                        selectedPhotoItem = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title2)
                                            .foregroundStyle(.white, Color.black.opacity(0.6))
                                            .padding(6)
                                    }
                                }
                            Spacer()
                        }
                    }
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        HStack {
                            Image(systemName: "camera.fill")
                                .foregroundStyle(.green)
                            Text(selectedImageData == nil ? "拍照或从相册添加药盒照片" : "更换药盒照片")
                                .foregroundStyle(.primary)
                        }
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                selectedImageData = data
                                if let uiImage = UIImage(data: data) {
                                    await recognizeMedicineBox(from: uiImage)
                                }
                            }
                        }
                    }
                }

                // MARK: - 提醒联动设置
                Section {
                    Toggle(isOn: $enablePostAddReminder) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保存后弹出设置服药提醒")
                                .font(.body)
                            Text("系统将根据「\(usageDraft.frequencyCount > 0 ? "一日\(usageDraft.frequencyCount)次" : "用药频次")」自动适配每日提醒时刻")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if medicine != nil {
                    Section {
                        Toggle("已用完/丢弃", isOn: $isDisposed)
                    } footer: {
                        Text("标记后不再计入过期提醒，列表中沉底显示。")
                    }
                }
            }
            .navigationTitle(medicine == nil ? "新建常备药" : "编辑常备药")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveMedicine() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || storageLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showingMedicineCamera) {
                VaultCameraPicker { captured in
                    selectedImageData = captured.jpegData(compressionQuality: 0.78)
                    Task {
                        await recognizeMedicineBox(from: captured)
                    }
                }
            }
            .sheet(isPresented: $showingReminderPopup) {
                if let item = newlySavedMedicine {
                    AddMedicationReminderPopupSheet(
                        medicine: item,
                        usageDraft: usageDraft,
                        onComplete: {
                            dismiss()
                        }
                    )
                }
            }
        }
    }

    @MainActor
    private func recognizeMedicineBox(from image: UIImage) async {
        isRecognizingMedicineOCR = true
        defer { isRecognizingMedicineOCR = false }

        guard let text = try? await OCRService.shared.recognizeText(from: image),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ocrBannerText = "未能从照片中识别出清晰文字，可点击下方预设或滑动选择"
            return
        }

        let parsed = MedicineBoxOCRParser.parse(from: text)
        guard parsed.hasAnyField else {
            ocrBannerText = "已附加照片，可点选常用药标签或手滑设置用法"
            return
        }

        if let preset = parsed.matchedPreset {
            applyPreset(preset)
        }
        if let n = parsed.name, !n.isEmpty {
            name = n
        }
        if let c = parsed.category {
            category = c
        }
        if let ind = parsed.indications, !ind.isEmpty {
            indications = ind
        }
        if let u = parsed.usageDraft {
            usageDraft = u
        }
        if let qty = parsed.remainingQuantity, !qty.isEmpty {
            remainingQuantity = qty
        }
        if let prec = parsed.precautions, !prec.isEmpty, precautions.isEmpty {
            precautions = prec
        }
        if let exp = parsed.expiryDate {
            hasExpiry = true
            expiryDate = exp
        }
        if let openDays = parsed.afterOpenDays {
            afterOpenDaysChoice = openDays
        }

        ocrBannerText = "已智能识别填入：\(parsed.summaryText)"
        Haptic.success()
    }

    private func applyPreset(_ preset: CommonMedicinePreset) {
        name = preset.name
        category = preset.category
        indications = preset.indications
        usageDraft.frequencyCount = preset.frequencyCount
        usageDraft.frequencySpecial = preset.frequencySpecial
        usageDraft.dosageAmount = preset.dosageAmount
        usageDraft.dosageUnit = preset.dosageUnit
        usageDraft.mealRelation = preset.mealRelation
        usageDraft.route = preset.route
        precautions = preset.precautions
        roomArea = preset.recommendedArea
        storageLocation = preset.recommendedLocation
        if let days = preset.afterOpenDays {
            isOpened = true
            afterOpenDaysChoice = days
        }
    }

    private func nilIfEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func saveMedicine() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = storageLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedExpiry = hasExpiry ? expiryDate : nil
        let resolvedPurchaseDate = hasPurchaseDate ? purchaseDate : nil
        let resolvedOpenedDate = isOpened ? openedDate : nil
        let resolvedAfterOpenDays = isOpened ? afterOpenDaysChoice : nil
        let resolvedUsage = usageDraft.formattedUsage

        let targetItem: MedicineItem
        if let existing = medicine {
            existing.name = trimmedName
            existing.category = category
            existing.indications = nilIfEmpty(indications)
            existing.usageMethod = nilIfEmpty(resolvedUsage)
            existing.remainingQuantity = nilIfEmpty(remainingQuantity)
            existing.precautions = nilIfEmpty(precautions)
            existing.roomArea = roomArea
            existing.storageLocation = trimmedLocation
            existing.purchaseDate = resolvedPurchaseDate
            existing.expiryDate = resolvedExpiry
            existing.isOpened = isOpened
            existing.openedDate = resolvedOpenedDate
            existing.afterOpenValidDays = resolvedAfterOpenDays
            existing.isDisposed = isDisposed
            existing.imageData = selectedImageData
            existing.updatedAt = .now
            targetItem = existing
        } else {
            let item = MedicineItem(
                name: trimmedName,
                category: category,
                indications: nilIfEmpty(indications),
                usageMethod: nilIfEmpty(resolvedUsage),
                storageLocation: trimmedLocation,
                roomArea: roomArea,
                purchaseDate: resolvedPurchaseDate,
                expiryDate: resolvedExpiry,
                isOpened: isOpened,
                openedDate: resolvedOpenedDate,
                afterOpenValidDays: resolvedAfterOpenDays,
                remainingQuantity: nilIfEmpty(remainingQuantity),
                precautions: nilIfEmpty(precautions),
                imageData: selectedImageData,
                isDisposed: false
            )
            context.insert(item)
            targetItem = item
        }

        try? context.save()
        Haptic.success()

        if enablePostAddReminder {
            newlySavedMedicine = targetItem
            showingReminderPopup = true
        } else {
            dismiss()
        }
    }
}
