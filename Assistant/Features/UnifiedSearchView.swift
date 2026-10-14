import SwiftData
import SwiftUI

/// 跨模块全景统一搜索视图（扇出 TodoItem / ExpenseRecord / StoredItem / IDDocumentItem / VoiceMemo）
struct UnifiedSearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var searchService = UnifiedSearchService.shared
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject private var router = NavigationRouter.shared

    @State private var query: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("全域跨模块一站式搜索")
                                .font(.headline)
                            Text("支持检索待办日程、快递取件码、记账明细、物品存放位置、重要证件与语音备忘录全文。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                ForEach(UnifiedSearchCategory.allCases) { cat in
                                    Label(cat.rawValue, systemImage: cat.icon)
                                        .font(.caption2.bold())
                                        .foregroundStyle(cat.color)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(cat.color.opacity(0.12), in: Capsule())
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 6)
                    }
                } else if searchService.results.isEmpty {
                    if searchService.isSearching {
                        HStack {
                            Spacer()
                            ProgressView("正在全景检索…")
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 20)
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    // 按模块分类分组
                    ForEach(UnifiedSearchCategory.allCases) { category in
                        let categoryResults = searchService.results.filter { $0.category == category }
                        if !categoryResults.isEmpty {
                            Section {
                                ForEach(categoryResults) { item in
                                    Button {
                                        selectResult(item)
                                    } label: {
                                        resultRow(item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack {
                                    Label(category.rawValue, systemImage: category.icon)
                                        .foregroundStyle(category.color)
                                    Spacer()
                                    Text("\(categoryResults.count) 条")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("全景搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索待办/取件码/账单/收纳/证件/备忘")
            .onChange(of: query) { _, newQuery in
                Task {
                    _ = await searchService.search(
                        query: newQuery,
                        context: context,
                        isLocked: lockManager.isLocked
                    )
                }
            }
            .onAppear {
                if let prefilled = router.prefilledSearchQuery, !prefilled.isEmpty {
                    query = prefilled
                    router.prefilledSearchQuery = nil
                    Task {
                        _ = await searchService.search(
                            query: prefilled,
                            context: context,
                            isLocked: lockManager.isLocked
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func selectResult(_ item: UnifiedSearchResultItem) {
        dismiss()
        router.navigateTo(
            tab: item.targetTab,
            vaultDestination: item.vaultDestination,
            focusTodoID: item.category == .todo ? item.id : nil
        )
    }

    @ViewBuilder
    private func resultRow(_ item: UnifiedSearchResultItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.icon)
                .font(.body.bold())
                .foregroundStyle(item.category.color)
                .frame(width: 32, height: 32)
                .background(item.category.color.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(item.isSensitive && lockManager.isLocked ? Color.secondary : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let date = item.date {
                Text(date, format: .dateTime.month().day())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
