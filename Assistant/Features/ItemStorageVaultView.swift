import PhotosUI
import SwiftData
import SwiftUI

/// 极简物品收纳备忘（解决“我的东西放哪了”翻箱倒柜的痛点）
struct ItemStorageVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredItem.updatedAt, order: .reverse) private var allItems: [StoredItem]

    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @State private var searchText: String = ""
    @State private var selectedArea: String = "全部"
    @State private var showingAddSheet: Bool = false
    @State private var itemToEdit: StoredItem? = nil
    @State private var previewImageData: Data? = nil

    private let roomAreas = ["全部", "玄关", "主卧", "次卧", "客厅", "书房", "阳台", "储物间", "厨房"]

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
                                        Text(area)
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

            // 2. 物品清单列表
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
                        StoredItemRow(item: item, onPreviewImage: { data in
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
    var onPreviewImage: ((Data) -> Void)? = nil

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

                    Text(item.roomArea)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.indigo.opacity(0.14)))
                        .foregroundStyle(.indigo)
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
                                    Text(s)
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
                            Text(area).tag(area)
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

                // 4. 补充说明
                Section("补充备注（选填）") {
                    TextField("例如：共2件、防尘袋包装、密码是1234", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
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
            existing.updatedAt = .now
        } else {
            let newItem = StoredItem(
                name: trimmedName,
                location: trimmedLocation,
                roomArea: roomArea,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                imageData: selectedImageData
            )
            context.insert(newItem)
        }

        try? context.save()
        Haptic.success()
        dismiss()
    }
}
