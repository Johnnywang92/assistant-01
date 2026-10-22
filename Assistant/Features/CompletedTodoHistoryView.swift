import SwiftData
import SwiftUI

/// 已完成待办历史归档与复盘大厅
struct CompletedTodoHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<TodoItem> { $0.statusRaw == "done" },
        sort: \TodoItem.completedAt,
        order: .reverse
    ) private var doneTodos: [TodoItem]

    @State private var searchText: String = ""
    @State private var selectedCategory: TodoFilterCategory = .all
    @State private var showingClearAlert = false

    // 单次遍历缓存分类计数，避免 9 个分类胶囊在每次渲染时各遍历一次全表
    private var categoryCounts: [TodoFilterCategory: Int] {
        var counts: [TodoFilterCategory: Int] = [
            .all: doneTodos.count,
            .general: 0,
            .work: 0,
            .recurring: 0,
            .parcel: 0,
            .life: 0,
            .alert: 0,
            .parenting: 0,
            .pet: 0
        ]
        for item in doneTodos {
            if item.isRecurring {
                counts[.recurring, default: 0] += 1
            }
            switch item.type {
            case .general, .event:
                counts[.general, default: 0] += 1
            case .work:
                counts[.work, default: 0] += 1
            case .parcel, .returnParcel:
                counts[.parcel, default: 0] += 1
            case .medication, .housework, .exercise, .charging:
                counts[.life, default: 0] += 1
            case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare:
                counts[.alert, default: 0] += 1
            case .childVaccine, .childGrowth, .childMilestone, .childHealth:
                counts[.parenting, default: 0] += 1
            case .pet:
                counts[.pet, default: 0] += 1
            default:
                break
            }
        }
        return counts
    }

    // 搜索与分类过滤
    private var filteredItems: [TodoItem] {
        var result = doneTodos

        // 分类过滤
        switch selectedCategory {
        case .all: break
        case .general: result = result.filter { [.general, .event].contains($0.type) }
        case .work: result = result.filter { $0.type == .work }
        case .recurring: result = result.filter { $0.isRecurring }
        case .parcel: result = result.filter { [.parcel, .returnParcel].contains($0.type) }
        case .life: result = result.filter { [.medication, .housework, .exercise, .charging].contains($0.type) }
        case .alert: result = result.filter { [.subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare].contains($0.type) }
        case .parenting: result = result.filter { [.childVaccine, .childGrowth, .childMilestone, .childHealth].contains($0.type) }
        case .pet: result = result.filter { $0.type == .pet }
        }

        // 搜索过滤
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) ||
                ($0.pickupCode?.lowercased().contains(q) ?? false) ||
                ($0.courier?.lowercased().contains(q) ?? false) ||
                ($0.detail?.lowercased().contains(q) ?? false)
            }
        }

        return result
    }

    var body: some View {
        let currentFiltered = filteredItems
        let counts = categoryCounts

        return NavigationStack {
            List {
                // MARK: - 1. 成就统计看板
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.12))
                                .frame(width: 52, height: 52)
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(doneTodos.count)")
                                    .font(.title.bold().monospacedDigit())
                                    .foregroundStyle(.primary)
                                Text("件已完成")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text("每一项打勾都是生活的推进，保持高效！")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - 2. 分类快速过滤条
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(TodoFilterCategory.allCases) { cat in
                                let isSelected = selectedCategory == cat
                                let count = counts[cat] ?? 0
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedCategory = cat
                                    }
                                    Haptic.selection()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(L10n.tr(cat.rawValue))
                                        if count > 0 {
                                            Text("\(count)")
                                                .font(.caption2.bold())
                                        }
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.green : Color(.secondarySystemBackground))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))

                // MARK: - 3. 已完成事项列表
                Section {
                    if currentFiltered.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "暂无该分类已完成事项" : "无匹配搜索结果",
                            systemImage: "checklist.checked",
                            description: Text(searchText.isEmpty ? "完成待办后将自动归档至此处" : "尝试更换关键词搜索")
                        )
                        .padding(.vertical, 12)
                    } else {
                        ForEach(currentFiltered) { item in
                            CompletedHistoryRow(item: item)
                        }
                        .onDelete { offsets in
                            deleteItems(at: offsets, from: currentFiltered)
                        }
                    }
                } header: {
                    HStack {
                        Text("归档明细 (\(currentFiltered.count))")
                        Spacer()
                        if !doneTodos.isEmpty {
                            Button("清空已完成", role: .destructive) {
                                showingClearAlert = true
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .themedScrollContentBackground()
            .themedAppBackground()
            .themedRow()
            .navigationTitle("已完成事项归档")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索已完成标题、取件码或快递...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("清空所有已完成事项？", isPresented: $showingClearAlert) {
                Button("全部清空", role: .destructive) {
                    clearAllDone()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作将永久删除 \(doneTodos.count) 条已完成历史记录，无法撤销。")
            }
        }
    }

    private func countForCategory(_ cat: TodoFilterCategory) -> Int {
        switch cat {
        case .all: return doneTodos.count
        case .general: return doneTodos.filter { [.general, .event].contains($0.type) }.count
        case .work: return doneTodos.filter { $0.type == .work }.count
        case .recurring: return doneTodos.filter { $0.isRecurring }.count
        case .parcel: return doneTodos.filter { [.parcel, .returnParcel].contains($0.type) }.count
        case .life: return doneTodos.filter { [.medication, .housework, .exercise, .charging].contains($0.type) }.count
        case .alert: return doneTodos.filter { [.subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .vehicleCare].contains($0.type) }.count
        case .parenting: return doneTodos.filter { [.childVaccine, .childGrowth, .childMilestone, .childHealth].contains($0.type) }.count
        case .pet: return doneTodos.filter { $0.type == .pet }.count
        }
    }

    private func deleteItems(at offsets: IndexSet, from items: [TodoItem]) {
        for index in offsets {
            context.delete(items[index])
        }
        try? context.save()
        Haptic.light()
    }

    private func clearAllDone() {
        for item in doneTodos {
            context.delete(item)
        }
        try? context.save()
        Haptic.warning()
    }
}

/// 已完成明细单行
struct CompletedHistoryRow: View {
    @Environment(\.modelContext) private var context
    let item: TodoItem
    @State private var isShowingEditSheet = false
    @State private var isShowingQRCodeSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 点击可一键恢复为未完成
            Button {
                Haptic.medium()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    item.status = .active
                }
                try? context.save()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr(item.title))
                        .font(.body)
                        .strikethrough(true, color: .secondary)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 完成时间
                    if let completed = item.completedAt {
                        Text(formatCompletedTime(completed))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let locText = item.displayLocationText, !locText.isEmpty, item.type != .parcel {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        Text(locText)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.tertiary)
                }

                // 快递附加信息
                if item.type == .parcel, let code = item.pickupCode {
                    HStack(spacing: 6) {
                        Text("取件码: \(code)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))

                        if let courier = item.courier {
                            Text(courier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let detail = item.detail, !detail.isEmpty {
                    Text(L10n.tr(detail))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isShowingEditSheet = true
                Haptic.light()
            }

            if item.hasQRCodeOrTicket {
                Button {
                    isShowingQRCodeSheet = true
                    Haptic.light()
                } label: {
                    Image(systemName: item.hasQRCode ? "qrcode" : "photo")
                        .font(.caption.bold())
                        .padding(6)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // 快捷放回未完成按钮
            Button {
                Haptic.light()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    item.status = .active
                }
                try? context.save()
            } label: {
                Text("恢复")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground))
                    .foregroundStyle(.tint)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if item.hasQRCodeOrTicket {
                Button("查看预约二维码 / 凭证", systemImage: "qrcode.viewfinder") {
                    isShowingQRCodeSheet = true
                    Haptic.light()
                }
            }
            Button("编辑事项", systemImage: "pencil") {
                isShowingEditSheet = true
                Haptic.light()
            }
            if let code = item.pickupCode {
                Button("复制取件码", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = code
                    Haptic.light()
                }
            }
        }
        .sheet(isPresented: $isShowingQRCodeSheet) {
            TodoQRCodeQuickSheet(item: item)
        }
        .sheet(isPresented: $isShowingEditSheet) {
            EditTodoSheet(item: item)
        }
        .swipeActions(edge: .leading) {
            Button {
                isShowingEditSheet = true
                Haptic.light()
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .themedRow()
    }

    private func formatCompletedTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "今天 " + date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(date) {
            return "昨天 " + date.formatted(date: .omitted, time: .shortened)
        } else {
            return date.formatted(date: .numeric, time: .omitted)
        }
    }
}
