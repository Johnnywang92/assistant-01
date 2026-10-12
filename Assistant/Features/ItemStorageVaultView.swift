import PhotosUI
import SwiftData
import SwiftUI

/// 极简物品收纳备忘（解决“我的东西放哪了”翻箱倒柜的痛点）
struct ItemStorageVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredItem.updatedAt, order: .reverse) private var allItems: [StoredItem]
    @Query private var allExpenseRecords: [ExpenseRecord]

    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @State private var searchText: String = ""
    @State private var selectedArea: String = "全部"
    @State private var showingAddSheet: Bool = false
    @State private var itemToEdit: StoredItem? = nil
    @State private var previewImageData: Data? = nil

    private let roomAreas = ["全部", "玄关", "主卧", "次卧", "客厅", "书房", "阳台", "储物间", "厨房"]

    /// 关联记账金额归集：itemID -> 该物品累计投入（购入价之外的后继投入）
    private var linkedTotals: [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for record in allExpenseRecords where !record.isIncome {
            if let itemID = record.linkedItemID {
                totals[itemID, default: 0] += record.amount
            }
        }
        return totals
    }

    /// 已录入成本数据的物品摘要（用于顶部速览）
    private var costTrackedSummaries: [(item: StoredItem, summary: ItemCostSummary)] {
        let totals = linkedTotals
        return allItems.compactMap { item in
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
    }

    private var filteredItems: [StoredItem] {
        allItems.filter { item in
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
                        HStack(spacing: 6) {
                            ForEach(roomAreas, id: \.self) { area in
                                let isSelected = selectedArea == area
                                let count = area == "全部" ? allItems.count : allItems.filter { $0.roomArea == area }.count
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
                    } actions: {
                        Button {
                            showingAddSheet = true
                        } label: {
                            Label("添加收纳物品", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
        .themedAppBackground()
        .themedRow()
        .navigationTitle("物品收纳找物")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索物品、存放位置或房间...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                    Haptic.light()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddOrEditStoredItemSheet(itemToEdit: nil)
        }
        .sheet(item: $itemToEdit) { item in
            AddOrEditStoredItemSheet(itemToEdit: item)
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
            // 实物或收纳柜照片缩略图
            if let data = item.imageData, let uiImg = UIImage(data: data) {
                Button {
                    onPreviewImage?(data)
                } label: {
                    Image(uiImage: uiImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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

                // 3. 现场实拍照片（开箱开柜即认出）
                Section("收纳实景照片（选填）") {
                    if let data = selectedImageData, let uiImage = UIImage(data: data) {
                        HStack {
                            Spacer()
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                                .foregroundStyle(.indigo)
                            Text(selectedImageData == nil ? "拍照或从相册添加收纳柜照片" : "更换收纳照片")
                                .foregroundStyle(.primary)
                        }
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                selectedImageData = data
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
        }
    }

    /// 编辑模式下归集该物品的关联记账投入
    private func loadLinkedExpenses() {
        guard let item = itemToEdit else { return }
        let descriptor = FetchDescriptor<ExpenseRecord>()
        let records = (try? context.fetch(descriptor)) ?? []
        let linked = records.filter { !$0.isIncome && $0.linkedItemID == item.id }
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
