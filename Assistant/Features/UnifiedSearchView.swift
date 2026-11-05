import AssistantCore
import SwiftData
import SwiftUI

/// 跨模块全域索引搜索视图（支持全应用数据、健康体征与系统全量设置）
struct UnifiedSearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var searchIndex = SearchIndexService.shared
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject private var router = NavigationRouter.shared

    @State private var query: String = ""
    @State private var selectedCategory: SearchIndexCategory = .all
    @State private var searchTask: Task<Void, Never>?

    private let quickSuggestions = [
        "睡眠提醒", "快递取件", "月度预算", "常用密码", "深色模式", "数据备份", "用药计划", "车辆维保"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部分类切换滑块
                categoryFilterBar

                List {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 1. 空搜索态：展示全域索引健康徽章、最近搜索历史与快捷标签
                        emptyStateView
                    } else if searchIndex.searchResults.isEmpty {
                        // 2. 无结果
                        if searchIndex.isIndexing {
                            HStack {
                                Spacer()
                                ProgressView("正在全域倒排索引检索…")
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 24)
                        } else {
                            ContentUnavailableView.search(text: query)
                        }
                    } else {
                        // 3. 搜索结果
                        if SearchPrivacyGate.hidesSensitiveDetails {
                            Section {
                                Label(L10n.tr("部分敏感信息已开启隐私保护脱敏，解锁后可查看完整内容"), systemImage: "lock.shield")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if selectedCategory == .all {
                            ForEach(activeResultCategories, id: \.self) { cat in
                                let catMatches = searchIndex.searchResults.filter { $0.document.category == cat }
                                Section {
                                    ForEach(catMatches) { match in
                                        Button {
                                            selectMatch(match)
                                        } label: {
                                            resultRow(match)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } header: {
                                    HStack {
                                        Label(cat.rawValue, systemImage: cat.icon)
                                            .foregroundStyle(categoryColor(for: cat))
                                        Spacer()
                                        Text("\(catMatches.count) 项")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            Section {
                                ForEach(searchIndex.searchResults) { match in
                                    Button {
                                        selectMatch(match)
                                    } label: {
                                        resultRow(match)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("全景索引搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索待办/记录/数据/证件/密码/设置…")
            .onChange(of: query) { _, newQuery in
                runSearch(newQuery)
            }
            .onChange(of: selectedCategory) { _, _ in
                runSearch(query)
            }
            .onChange(of: lockManager.isLocked) { _, _ in
                runSearch(query)
            }
            .task {
                await searchIndex.rebuildIndex(context: context)
                if let prefilled = router.prefilledSearchQuery, !prefilled.isEmpty {
                    query = prefilled
                    router.prefilledSearchQuery = nil
                    runSearch(prefilled)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // 手动刷新 = 强制重建；打开搜索的 `.task` 走「数据未变则跳过」的增量路径。
                        Task { await searchIndex.rebuildIndex(context: context, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(searchIndex.isIndexing)
                }
            }
        }
    }

    // MARK: - 分类横滑胶囊条

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchIndexCategory.allCases) { cat in
                    let isSelected = selectedCategory == cat
                    Button {
                        selectedCategory = cat
                        Haptic.selection()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: cat.icon)
                                .font(.caption2)
                            Text(cat.rawValue)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                            if !query.isEmpty {
                                let count = cat == .all
                                    ? searchIndex.searchResults.count
                                    : searchIndex.searchResults.filter { $0.document.category == cat }.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .background(
                            isSelected ? categoryColor(for: cat) : Color(.secondarySystemFill),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 空搜索初始态

    private var emptyStateView: some View {
        Group {
            // 索引就绪状态横幅
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.badge.checkmark.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全域倒排索引已就绪")
                                .font(.headline)
                            Text("已索引 \(searchIndex.totalIndexedCount) 项应用数据与系统设置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Text("支持拼音首字母检索（如输入 sm 搜「睡眠提醒」、zd 搜「账单」、sz 搜「设置」），毫秒级直达全应用功能与数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            // 最近搜索
            if !searchIndex.recentSearches.isEmpty {
                Section {
                    ForEach(searchIndex.recentSearches, id: \.self) { item in
                        HStack {
                            Button {
                                query = item
                                runSearch(item)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(item)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                searchIndex.removeRecentSearch(item)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    HStack {
                        Text("最近搜索")
                        Spacer()
                        Button("清空") {
                            searchIndex.clearRecentSearches()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // 热门推荐快捷搜索
            Section("推荐快速检索") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(quickSuggestions, id: \.self) { sug in
                        Button {
                            query = sug
                            runSearch(sug)
                        } label: {
                            Text(sug)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(Color(.secondarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 结果列表条目渲染

    @ViewBuilder
    private func resultRow(_ match: SearchIndexMatch) -> some View {
        let doc = match.document
        let isHidingSensitive = SearchPrivacyGate.hidesSensitiveDetails && doc.isSensitive

        HStack(spacing: 12) {
            Image(systemName: doc.category.icon)
                .font(.body.bold())
                .foregroundStyle(categoryColor(for: doc.category))
                .frame(width: 32, height: 32)
                .background(categoryColor(for: doc.category).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(doc.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .layoutPriority(1)

                    if let badge = doc.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(categoryColor(for: doc.category))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(categoryColor(for: doc.category).opacity(0.12), in: Capsule())
                    }
                }

                if let subtitle = doc.subtitle {
                    Text(isHidingSensitive ? "🔒 内容已受保护隐藏" : subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let date = doc.date {
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

    // MARK: - 辅助计算与事件分发

    private var activeResultCategories: [SearchIndexCategory] {
        var set = Set<SearchIndexCategory>()
        for r in searchIndex.searchResults {
            set.insert(r.document.category)
        }
        return SearchIndexCategory.allCases.filter { set.contains($0) }
    }

    private func categoryColor(for cat: SearchIndexCategory) -> Color {
        switch cat {
        case .all: return .primary
        case .todo: return .blue
        case .expense: return .orange
        case .storage: return .indigo
        case .document: return .purple
        case .memo: return .teal
        case .password: return .yellow
        case .diet: return .green
        case .habitMed: return .pink
        case .anniversary: return .red
        case .lifeVault: return .brown
        case .health: return .red
        case .setting: return .gray
        }
    }

    private func runSearch(_ text: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }
            _ = searchIndex.search(query: trimmed, category: selectedCategory)
        }
    }

    private func selectMatch(_ match: SearchIndexMatch) {
        searchIndex.addRecentSearch(query)
        dismiss()
        router.navigateToSearchRoute(match.document.route)
    }
}
