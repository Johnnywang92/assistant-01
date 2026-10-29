import AssistantCore
import SwiftData
import SwiftUI

/// 日报 · 周报 · 月报复盘数据中心
struct PeriodicReportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var reportManager = PeriodicReportManager.shared
    @AppStorage(AppBackgroundStyle.defaultsKey) private var bgStyleRaw = AppBackgroundStyle.system.rawValue

    private static var recentExpensesDescriptor: FetchDescriptor<ExpenseRecord> {
        var descriptor = FetchDescriptor<ExpenseRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 30
        return descriptor
    }
    private static var recentTodosDescriptor: FetchDescriptor<TodoItem> {
        var descriptor = FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 30
        return descriptor
    }

    @Query(PeriodicReportView.recentExpensesDescriptor) private var recentExpenses: [ExpenseRecord]
    @Query(PeriodicReportView.recentTodosDescriptor) private var recentTodos: [TodoItem]

    @State private var selectedPeriod: ReportPeriodType = .daily
    @State private var currentDate: Date = .now
    @State private var showingSettingsSheet: Bool = false
    @State private var copiedToast: Bool = false
    @State private var isPolishingWithLLM: Bool = false
    @State private var polishedText: String? = nil
    @State private var sharingFileURL: URL? = nil
    @State private var showingShareSheet: Bool = false
    @State private var showingPreviewSheet: Bool = false
    @State private var showingImageShareSheet: Bool = false

    /// 只订阅风格 key，判断是否自定主题底图
    private var isCustomThemedBackground: Bool {
        AppBackgroundStyle(rawValue: bgStyleRaw) != .system
    }

    init(initialPeriod: ReportPeriodType = .daily) {
        _selectedPeriod = State(initialValue: initialPeriod)
    }

    /// 报告引用缓存：body 内 50+ 处 reportData 访问在同一次渲染中只生成一次。
    /// generateReport 包含多次全表 fetch，无缓存时每处访问都会重新拉取全部数据。
    /// 当账本、待办状态发生变动，或切换周期/日期时，自动通过复合指纹感知失效并实时重新计算。
    private final class ReportCache {
        var period: ReportPeriodType?
        var date: Date?
        var dataHash: Int?
        var lastCheckedTime: CFAbsoluteTime = 0
        var data: PeriodicReportData?
    }

    @State private var reportCache = ReportCache()

    /// 包含收支与待办的实时复合指纹，实现变动即刷新的无感响应
    private var dataFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(recentExpenses.count)
        for record in recentExpenses {
            hasher.combine(record.id)
            hasher.combine(record.amount)
        }
        hasher.combine(recentTodos.count)
        for item in recentTodos {
            hasher.combine(item.id)
            hasher.combine(item.status == .done)
            hasher.combine(item.completedAt)
        }
        return hasher.finalize()
    }

    private var reportData: PeriodicReportData {
        let now = CFAbsoluteTimeGetCurrent()
        if reportCache.period == selectedPeriod,
           reportCache.date == currentDate,
           let cached = reportCache.data,
           (now - reportCache.lastCheckedTime) < 0.05 {
            return cached
        }
        let currentHash = dataFingerprint
        if reportCache.period == selectedPeriod,
           reportCache.date == currentDate,
           reportCache.dataHash == currentHash,
           let cached = reportCache.data {
            reportCache.lastCheckedTime = now
            return cached
        }
        let result = reportManager.generateReport(period: selectedPeriod, for: currentDate, context: context)
        reportCache.period = selectedPeriod
        reportCache.date = currentDate
        reportCache.dataHash = currentHash
        reportCache.lastCheckedTime = now
        reportCache.data = result
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 顶部周期切换 (日报 / 周报 / 月报)
                    periodPicker

                    // 2. 日期翻页与导航条
                    dateNavigationBar

                    // 3. 核心指标与成就总览大卡片
                    heroMetricsCard

                    // 日报优先回答“今天还有什么要处理”
                    if selectedPeriod == .daily {
                        dailyActionSummaryCard
                    }

                    // 日报：今日安心花动态额度（仅查看当天且已设月预算时显示）
                    if selectedPeriod == .daily, let sts = reportData.safeToSpend {
                        safeToSpendReportCard(sts)
                    }

                    // 日报：身体活力与健康简报（Apple 健康联动与饮食摄入推测）
                    if selectedPeriod == .daily, let vitality = reportData.vitality {
                        vitalityReportCard(vitality)
                    }

                    // 4. AI 智能复盘解读卡片
                    smartSummaryCard

                    // 4.5 行动建议卡片（基于真实数据的可执行提示）
                    if !reportData.suggestions.isEmpty {
                        suggestionsCard
                    }

                    // 5. 待办完成成果清单卡片
                    todosAccomplishedCard

                    // 6. 财务支出结构卡片
                    expensesBreakdownCard

                    // 周/月/季/年报：趋势分析（多期走势）与变化分析（环比与结构变化）
                    if reportData.trendSummary != nil {
                        trendAnalysisCard
                        changeAnalysisCard
                    }

                    // 月报：月预算执行概览
                    if selectedPeriod == .monthly, let bo = reportData.budgetOverview {
                        budgetOverviewCard(bo)
                    }

                    // 月报/季报/年报：物品日均持有成本榜
                    if selectedPeriod == .monthly || selectedPeriod == .quarterly || selectedPeriod == .yearly, !reportData.itemCostEntries.isEmpty {
                        itemCostReportCard
                    }

                    // 7. 下期前瞻与备忘卡片
                    upcomingOutlookCard

                    // 8. 导出与分享卡片 (导出为 .md 文档与复制 Markdown 源码)
                    exportActionCard

                    Spacer(minLength: 28)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .refreshable {
                reportCache.data = nil
                await HealthKitService.shared.refreshToday()
                Haptic.light()
            }
            .themedScrollContentBackground()
            .background(isCustomThemedBackground ? Color.clear : Color(.systemGroupedBackground))
            .themedAppBackground()
            .navigationTitle("复盘报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Button {
                                showingImageShareSheet = true
                                Haptic.light()
                            } label: {
                                Label("生成图片分享卡片", systemImage: "photo.badge.plus")
                            }

                            Divider()

                            Button {
                                exportAsMarkdownFile()
                            } label: {
                                Label("导出为 .md 文档 (保存/分享)", systemImage: "doc.badge.arrow.up")
                            }

                            Button {
                                exportAndCopy()
                            } label: {
                                Label("复制 Markdown 全文", systemImage: "doc.on.doc")
                            }

                            Button {
                                showingPreviewSheet = true
                                Haptic.light()
                            } label: {
                                Label("预览 Markdown 格式", systemImage: "eye")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("导出并分享报告")

                        Button {
                            showingSettingsSheet = true
                            Haptic.light()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("报告提醒设置")
                    }
                }
            }
            .sheet(isPresented: $showingImageShareSheet) {
                ReportShareSheet(reportData: reportData, polishedSummary: polishedText)
            }
            .sheet(isPresented: $showingSettingsSheet) {
                PeriodicReportSettingsSheet()
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = sharingFileURL {
                    ShareActivityView(activityItems: [url])
                }
            }
            .sheet(isPresented: $showingPreviewSheet) {
                MarkdownPreviewSheet(
                    title: reportData.title,
                    fileName: "\(reportData.suggestedFileName).md",
                    markdownContent: reportData.exportMarkdown(),
                    onExportFile: { exportAsMarkdownFile() },
                    onCopyText: { exportAndCopy() }
                )
            }
            .overlay(alignment: .bottom) {
                if copiedToast {
                    Text("✓ 已将报告完整 Markdown 复制到剪贴板")
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // 回到前台清空缓存，并刷新 HealthKit 与最新数据
                reportCache.data = nil
                Task { await HealthKitService.shared.refreshToday() }
            }
        }
    }

    // MARK: - 1. 周期分段切换器

    private var periodPicker: some View {
        Picker("报告周期", selection: $selectedPeriod) {
            ForEach(ReportPeriodType.allCases) { period in
                Label(L10n.tr(period.rawValue), systemImage: period.icon).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedPeriod) { _, _ in
            polishedText = nil
            Haptic.selection()
        }
    }

    // MARK: - 2. 日期导航条

    private var dateNavigationBar: some View {
        HStack(spacing: 12) {
            Button {
                stepDate(by: -1)
                Haptic.light()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.bold())
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 4) {
                Text(reportData.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(reportData.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    periodStatusBadge
                }
            }

            Spacer()

            Button {
                stepDate(by: 1)
                Haptic.light()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }
            .buttonStyle(.plain)

            // 回到今天快捷按钮
            if !Calendar.current.isDateInToday(currentDate) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        currentDate = .now
                        polishedText = nil
                    }
                    Haptic.medium()
                } label: {
                    Text("今")
                        .font(.caption2.bold())
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var periodStatusBadge: some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(currentDate)

        if selectedPeriod == .daily {
            if isToday {
                let hour = cal.component(.hour, from: .now)
                if hour >= 21 {
                    HStack(spacing: 3) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.indigo)
                        Text("晚盘复盘中")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.indigo)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.12), in: Capsule())
                } else {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("今日实时动态")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
                }
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("历史归档快照")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }

    private func stepDate(by value: Int) {
        let cal = Calendar.current
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            switch selectedPeriod {
            case .daily:
                currentDate = cal.date(byAdding: .day, value: value, to: currentDate) ?? currentDate
            case .weekly:
                currentDate = cal.date(byAdding: .weekOfYear, value: value, to: currentDate) ?? currentDate
            case .monthly:
                currentDate = cal.date(byAdding: .month, value: value, to: currentDate) ?? currentDate
            case .quarterly:
                currentDate = cal.date(byAdding: .month, value: value * 3, to: currentDate) ?? currentDate
            case .yearly:
                currentDate = cal.date(byAdding: .year, value: value, to: currentDate) ?? currentDate
            }
            polishedText = nil
        }
    }

    // MARK: - 3. 核心指标与成就总览大卡片

    private var heroMetricsCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("执行力状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(reportData.achievementLevel)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                }

                Spacer()

                // 完成率环形进度圈
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                        .frame(width: 62, height: 62)

                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(reportData.completionRate, 0), 1)))
                        .stroke(
                            LinearGradient(
                                colors: [Color.accentColor, Color.green],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 62, height: 62)

                    VStack(spacing: 0) {
                        Text("\(Int(reportData.completionRate * 100))%")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
            }

            Divider()

            // 4 维微网格指标
            HStack(spacing: 0) {
                metricGridItem(
                    title: "已完成待办",
                    value: "\(reportData.completedTodos.count)",
                    unit: "件",
                    icon: "checkmark.circle.fill",
                    color: .green
                )

                Divider().frame(height: 36)

                metricGridItem(
                    title: "财务总支出",
                    value: String(format: "%.0f", reportData.totalExpense),
                    unit: "元",
                    icon: "yensign.circle.fill",
                    color: .orange
                )

                Divider().frame(height: 36)

                metricGridItem(
                    title: "收发包裹",
                    value: "\(reportData.parcelCount)",
                    unit: "件",
                    icon: "shippingbox.fill",
                    color: .blue
                )

                Divider().frame(height: 36)

                metricGridItem(
                    title: "周期打卡",
                    value: "\(reportData.habitStreakCount)",
                    unit: "次",
                    icon: "sparkles",
                    color: .purple
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var dailyActionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("今天需要关注", systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.bold())

            HStack(spacing: 8) {
                actionMetric(title: "已逾期", count: reportData.overdueTodos.count, color: .red)
                actionMetric(title: "今天到期", count: reportData.dueTodayTodos.count, color: .orange)
                actionMetric(title: "明天到期", count: reportData.tomorrowTodos.count, color: .blue)
            }

            if let next = reportData.overdueTodos.first ?? reportData.dueTodayTodos.first ?? reportData.tomorrowTodos.first {
                HStack(spacing: 8) {
                    Image(systemName: next.type.icon)
                        .foregroundStyle(.tint)
                    Text(L10n.tr(next.title))
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text((reportData.overdueTodos.contains(where: { $0.id == next.id }) ? "尽快处理" : "优先安排"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("今天和明天没有临近截止事项，按当前节奏推进即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func actionMetric(title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.title3.bold())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private func metricGridItem(title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.headline.bold())
                    .foregroundStyle(.primary)
                Text(L10n.tr(unit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 4. AI 智能复盘解读卡片

    private var smartSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("智能复盘与寄语")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }

                Spacer()

                if LLMModelManager.shared.isModelDownloaded ||
                    (LLMInferenceService.shared.remoteContextConsent && LLMInferenceService.shared.validatedEndpointURL != nil) {
                    Button {
                        polishWithLLM()
                    } label: {
                        HStack(spacing: 3) {
                            if isPolishingWithLLM {
                                ProgressView()
                                    .scaleEffect(0.65)
                            } else {
                                Image(systemName: "brain.head.profile")
                                    .font(.caption2)
                            }
                            Text(isPolishingWithLLM ? "端侧思考中..." : "AI 深度润色")
                                .font(.caption2.bold())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.14)))
                        .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPolishingWithLLM)
                }
            }

            Text(polishedText ?? reportData.smartSummary)
                .font(.subheadline)
                .lineSpacing(4)
                .foregroundStyle(Color.primary.opacity(0.88))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 4.5 行动建议卡片

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("行动建议", systemImage: "target")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text("基于本期真实数据")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 8) {
                ForEach(reportData.suggestions) { suggestion in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: suggestion.icon)
                            .font(.subheadline.bold())
                            .foregroundStyle(suggestionColor(suggestion.tone))
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            Text(suggestion.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .fill(suggestionColor(suggestion.tone).opacity(0.08))
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func suggestionColor(_ tone: ReportSuggestion.Tone) -> Color {
        switch tone {
        case .urgent: return .red
        case .action: return .orange
        case .positive: return .green
        }
    }

    // MARK: - 5. 待办完成成果清单卡片

    private var todosAccomplishedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("完成事项清单（\(reportData.completedTodos.count)）", systemImage: "checklist")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
            }

            if reportData.completedTodos.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(.secondary)
                    Text("该周期内未记录完成事项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(reportData.completedTodos.prefix(6)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr(item.title))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)

                                if let detail = item.detail, !detail.isEmpty {
                                    Text(L10n.tr(detail))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if let comp = item.completedAt {
                                Text(comp, format: .dateTime.hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if item.id != reportData.completedTodos.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 6. 财务支出结构卡片

    private var expensesBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("财务支出结构", systemImage: "chart.pie.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Spacer()

                Text("共支出 ¥\(String(format: "%.2f", reportData.totalExpense))")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            if reportData.categoryStats.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                    Text("该周期内暂无记账支出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(reportData.categoryStats.prefix(4)) { stat in
                        VStack(spacing: 4) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: stat.category.icon)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(L10n.tr(stat.category.rawValue))
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                }

                                Spacer()

                                Text("¥\(String(format: "%.2f", stat.amount))")
                                    .font(.caption.bold())
                                    .foregroundStyle(.primary)

                                Text("(\(Int(stat.ratio * 100))%)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(height: 6)

                                    Capsule()
                                        .fill(Color.orange.opacity(0.85))
                                        .frame(width: geo.size.width * CGFloat(min(max(stat.ratio, 0.02), 1.0)), height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 7. 下期前瞻备忘卡片

    private var upcomingOutlookCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("下一周期前瞻备忘（\(reportData.upcomingTodos.count)）", systemImage: "arrow.forward.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
            }

            if reportData.upcomingTodos.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.green)
                    Text("后续暂无紧迫截止的待办，节奏轻松")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(reportData.upcomingTodos.prefix(4)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.type.icon)
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr(item.title))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)

                                if let due = item.dueAt {
                                    Text("截止: \(due.formatted(date: .numeric, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }
                        if item.id != reportData.upcomingTodos.prefix(4).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 今日安心花卡片（日报）

    private func safeToSpendReportCard(_ sts: SafeToSpendResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("今日安心花", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text("距月底 \(sts.daysLeft) 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if sts.isOverBudget {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("本月弹性预算已超支 ¥\(String(format: "%.0f", -sts.remainingThisMonth))，今天尽量少花")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            } else if sts.isTodayOverspent {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("今日已超额")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "¥%.0f", sts.todayOverspentAmount))
                            .font(.system(.title, design: .rounded).bold())
                            .foregroundStyle(.red)
                    }
                    Text("今日起始额度 ¥\(String(format: "%.0f", sts.todayAllowance)) · 今日已花 ¥\(String(format: "%.0f", sts.todayFlexibleSpend))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("今天还可以安心花")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "¥%.0f", sts.safeToSpendToday))
                            .font(.system(.title, design: .rounded).bold())
                            .foregroundStyle(.green)
                    }
                    if sts.todayFlexibleSpend > 0 {
                        Text("今日额度 ¥\(String(format: "%.0f", sts.todayAllowance)) · 今日已花 ¥\(String(format: "%.0f", sts.todayFlexibleSpend))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 今日额度消耗进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill((sts.isOverBudget || sts.isTodayOverspent) ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(min(max(sts.todaySpentRatio, 0), 1)))
                }
            }
            .frame(height: 6)

            HStack(spacing: 12) {
                Text("弹性预算 ¥\(String(format: "%.0f", sts.disposableBudget))")
                if sts.savedYesterday >= 0.5 {
                    Text("昨日省下 ¥\(String(format: "%.0f", sts.savedYesterday)) 已滚入 💰")
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 身体活力与健康卡片（日报）

    private func vitalityReportCard(_ vitality: VitalityEvaluation) -> some View {
        let levelColor: Color = switch vitality.level {
        case .peak: .orange
        case .good: .green
        case .balanced: .blue
        case .low: .yellow
        case .exhausted: .red
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("身体活力与健康", systemImage: "bolt.heart.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(vitality.level.badge)
                    .font(.caption.bold())
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(levelColor.opacity(0.12), in: Capsule())
            }

            // 核心分数条与精简总结
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(vitality.score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(levelColor)
                        Text("/ 100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("综合活力指数")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 38)

                Text(vitality.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 关键指标精炼速览
            if !vitality.highlights.isEmpty {
                VStack(spacing: 8) {
                    ForEach(vitality.highlights) { h in
                        HStack(spacing: 8) {
                            Image(systemName: h.icon)
                                .font(.caption)
                                .foregroundStyle(h.isPositive ? Color.green : Color.orange)
                                .frame(width: 16)
                            Text(h.title)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            Text(h.valueText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(h.statusText)
                                .font(.caption2)
                                .foregroundStyle(h.isPositive ? Color.secondary : Color.orange)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.medium))
            }

            // 调养建议
            if !vitality.suggestion.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "leaf.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .padding(.top, 1)
                    Text(vitality.suggestion)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(levelColor.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 趋势分析卡片（周/月/季/年报：多期走势）

    /// 多期走势迷你柱图 + 趋势判读。
    private var trendAnalysisCard: some View {
        Group {
            if let trend = reportData.trendSummary, trend.points.count >= 2 {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("趋势分析", systemImage: "chart.xyaxis.line")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                        trendDirectionBadge(trend.expenseTrend)
                    }

                    // 多期走势柱图
                    miniTrendChart(trend: trend)

                    // 趋势判读要点
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(trendInsightRows(trend).enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.icon)
                                    .font(.caption2)
                                    .foregroundStyle(row.tint)
                                    .frame(width: 14)
                                Text(row.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    // 下期目标
                    if let targets = trend.nextTargets {
                        VStack(alignment: .leading, spacing: 6) {
                            Divider()
                            Label("下期目标建议", systemImage: "target")
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            if let cap = targets.expenseCap {
                                targetRow(icon: "arrow.down.right.circle", text: "支出上限", value: "¥\(String(format: "%.0f", cap))")
                            }
                            targetRow(icon: "checkmark.seal", text: "完成事项", value: "\(targets.completedTarget) 项")
                            if let rate = targets.savingsRateTarget {
                                targetRow(icon: "banknote", text: "储蓄率", value: "\(Int(rate * 100))%")
                            }
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
                )
            }
        }
    }

    /// 趋势方向徽章
    private func trendDirectionBadge(_ trend: PeriodReportAnalytics.SeriesTrend) -> some View {
        let (text, icon, tint): (String, String, Color) = {
            switch trend.direction {
            case .rising: return ("上升", "chart.line.uptrend.xyaxis", .red)
            case .falling: return ("下降", "chart.line.downtrend.xyaxis", .green)
            case .flat: return ("平稳", "equal", .secondary)
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }

    /// 多期走势迷你柱图
    private func miniTrendChart(trend: PeriodTrendSummary) -> some View {
        let values = trend.expenseSeries
        let maxValue = max(values.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("近 \(values.count) 期支出走势")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(trend.points.enumerated()), id: \.offset) { index, point in
                    let isCurrent = index == values.count - 1
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: AppRadius.hairline)
                            .fill(
                                LinearGradient(
                                    colors: isCurrent
                                        ? [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.55)]
                                        : [Color.accentColor.opacity(0.42), Color.accentColor.opacity(0.18)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(4, CGFloat(point.expense / maxValue) * 66))
                        Text(point.label)
                            .font(.system(size: 8))
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
    }

    /// 趋势判读要点行
    private struct TrendInsightRow {
        let icon: String
        let text: String
        let tint: Color
    }

    private func trendInsightRows(_ trend: PeriodTrendSummary) -> [TrendInsightRow] {
        var rows: [TrendInsightRow] = []
        let expenseTrend = trend.expenseTrend

        if expenseTrend.streak >= 2 {
            rows.append(TrendInsightRow(
                icon: "chart.line.uptrend.xyaxis",
                text: String(format: "支出已连续 %d 期上升，每期约多花 ¥%.0f", expenseTrend.streak, abs(expenseTrend.slope)),
                tint: .red
            ))
        } else if expenseTrend.streak <= -2 {
            rows.append(TrendInsightRow(
                icon: "chart.line.downtrend.xyaxis",
                text: String(format: "支出已连续 %d 期下降，每期约省下 ¥%.0f", abs(expenseTrend.streak), abs(expenseTrend.slope)),
                tint: .green
            ))
        }

        if expenseTrend.baselineAverage > 0, let deviation = expenseTrend.currentVsBaseline {
            let direction = deviation > 0 ? "高于" : "低于"
            rows.append(TrendInsightRow(
                icon: "equal.circle",
                text: String(format: "本期支出%s历史均值 %.0f%%", direction, abs(deviation * 100)),
                tint: deviation > 0 ? .orange : .green
            ))
        }

        if expenseTrend.volatility >= 0.6 {
            rows.append(TrendInsightRow(
                icon: "waveform.path.ecg",
                text: String(format: "波动系数 %.0f%%，各期起伏偏大", expenseTrend.volatility * 100),
                tint: .orange
            ))
        }

        let completionTrend = trend.completionTrend
        if completionTrend.streak >= 2 {
            rows.append(TrendInsightRow(
                icon: "arrow.up.circle.fill",
                text: String(format: "完成量连续 %d 期上升，执行力在变强", completionTrend.streak),
                tint: .green
            ))
        } else if completionTrend.streak <= -2 {
            rows.append(TrendInsightRow(
                icon: "arrow.down.circle.fill",
                text: String(format: "完成量连续 %d 期回落，需留意节奏", abs(completionTrend.streak)),
                tint: .orange
            ))
        }

        if let p = trend.punctuality, let rate = p.onTimeRate {
            rows.append(TrendInsightRow(
                icon: "clock",
                text: String(format: "待办准时率 %.0f%%", rate * 100),
                tint: rate < 0.7 ? .orange : .green
            ))
        }

        if let pattern = trend.spendingPattern, pattern.weekdayDailyAverage > 0 {
            rows.append(TrendInsightRow(
                icon: "calendar",
                text: String(format: "工作日日均 ¥%.0f · 周末日均 ¥%.0f", pattern.weekdayDailyAverage, pattern.weekendDailyAverage),
                tint: pattern.weekendDailyAverage > pattern.weekdayDailyAverage * 1.5 ? .orange : .secondary
            ))
        }

        return rows
    }

    /// 单个类别结构变化行。
    ///
    /// 拆成独立函数是为了让 SwiftUI 的类型推断有界——
    /// 三元嵌套链写在一行里会让编译器在合理时间内算不出来。
    private func categoryChangeRow(_ change: PeriodReportAnalytics.CategoryChange) -> some View {
        let iconName: String
        let iconTint: Color
        if change.isNew {
            iconName = "plus.circle.fill"
            iconTint = .orange
        } else if change.isGone {
            iconName = "minus.circle"
            iconTint = .secondary
        } else {
            iconName = "circle.fill"
            iconTint = .accentColor
        }

        let detailText: String
        let detailTint: Color
        if change.isNew {
            detailText = String(format: "新增 ¥%.0f", change.current)
            detailTint = .orange
        } else if change.isGone {
            detailText = "已无支出"
            detailTint = .secondary
        } else {
            let deltaSign = change.delta > 0 ? "+" : ""
            let shareSign = change.shareDelta > 0 ? "+" : ""
            detailText = String(format: "%@¥%.0f · %@%.0fpp", deltaSign, change.delta, shareSign, change.shareDelta * 100)
            detailTint = change.shareDelta > 0 ? .red : .green
        }

        let name = ExpenseCategory(rawValue: change.categoryRaw)?.rawValue ?? change.categoryRaw

        return HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption2)
                .foregroundStyle(iconTint)
            Text(name)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(detailText)
                .font(.caption2)
                .foregroundStyle(detailTint)
        }
    }

    private func targetRow(icon: String, text: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(.primary)
        }
    }

    // MARK: - 变化分析卡片（周/月/季/年报：指标环比与结构变化）

    private var changeAnalysisCard: some View {
        Group {
            if let trend = reportData.trendSummary, !trend.metricChanges.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("变化分析", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Spacer()
                    }

                    // 指标环比
                    VStack(spacing: 8) {
                        ForEach(trend.metricChanges, id: \.key) { change in
                            HStack(spacing: 10) {
                                Text(change.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)

                                // 本期
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(String(format: "%.0f", change.current))
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text("本期")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }

                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                // 上期
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(change.previous.map { String(format: "%.0f", $0) } ?? "—")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("上期")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer(minLength: 0)

                                // 变化
                                if let ratio = change.ratio {
                                    let improved = change.verdict > 0
                                    let worsened = change.verdict < 0
                                    Text(String(format: "%@%.0f%%", ratio > 0 ? "+" : "", ratio * 100))
                                        .font(.caption.bold())
                                        .foregroundStyle(improved ? .green : (worsened ? .red : .secondary))
                                } else {
                                    Text("—")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    // 类别结构变化
                    if !trend.categoryChanges.isEmpty {
                        Divider()
                        Text("支出结构变化")
                            .font(.caption.bold())
                            .foregroundStyle(.primary)

                        VStack(spacing: 7) {
                            ForEach(trend.categoryChanges.prefix(5), id: \.categoryRaw) { change in
                                categoryChangeRow(change)
                            }
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - 月预算执行卡片（月报）

    private func budgetOverviewCard(_ bo: BudgetOverviewResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("月预算执行", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(bo.remaining < 0 ? "已超支" : "已使用 \(Int(min(max(bo.spentRatio, 0), 2) * 100))%")
                    .font(.caption.bold())
                    .foregroundStyle(bo.remaining < 0 ? .red : .orange)
            }

            HStack(spacing: 8) {
                budgetMetric("弹性预算", value: bo.monthlyBudget, color: .indigo)
                budgetMetric("固定支出", value: bo.fixedMonthlyTotal, color: .gray)
                budgetMetric("本月已花", value: bo.flexibleSpent, color: .orange)
                budgetMetric("剩余额度", value: bo.remaining, color: bo.remaining >= 0 ? .green : .red)
            }

            if bo.isCurrentMonth {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.day.timeline.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("距月底 \(bo.daysLeft) 天，今天起日均还可以花 ¥\(String(format: "%.0f", bo.dailyAllowance))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.16), lineWidth: 1)
        )
    }

    private func budgetMetric(_ title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "¥%.0f", value))
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    // MARK: - 物品日均持有成本榜卡片（月报/年报）

    private var itemCostReportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("物品日均持有成本", systemImage: "archivebox")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text("累计投入 Top \(reportData.itemCostEntries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(reportData.itemCostEntries) { entry in
                    VStack(spacing: 4) {
                        HStack {
                            HStack(spacing: 6) {
                                Text(L10n.tr(entry.name))
                                    .font(.caption)
                                    .foregroundStyle(.primary)

                                Text(L10n.tr(entry.roomArea))
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.indigo.opacity(0.12)))
                                    .foregroundStyle(.indigo)

                                if entry.summary.isSecondHand {
                                    Text("二手购入")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.teal.opacity(0.14)))
                                        .foregroundStyle(.teal)
                                }
                                if entry.summary.isResold {
                                    Text("已转卖")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.green.opacity(0.14)))
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            if entry.summary.isResold {
                                Text(String(format: "净成本 ¥%.1f/天", entry.summary.netDailyCost))
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            } else {
                                Text(String(format: "¥%.1f/天", entry.summary.dailyCost))
                                    .font(.caption.bold())
                                    .foregroundStyle(.orange)
                            }
                        }

                        HStack(spacing: 8) {
                            if entry.summary.isResold {
                                Text("累计投入 ¥\(String(format: "%.0f", entry.summary.totalCost))")
                                Text("回血 ¥\(String(format: "%.0f", entry.summary.resalePrice))")
                                    .foregroundStyle(.green)
                                Text("持有 \(entry.summary.daysHeld) 天")
                            } else {
                                Text("累计投入 ¥\(String(format: "%.0f", entry.summary.totalCost))")
                                Text("已使用 \(entry.summary.daysHeld) 天")
                            }
                            if let milestone = entry.summary.milestoneText {
                                Text("🏆 " + milestone)
                                    .foregroundStyle(entry.summary.isResold ? .green : .orange)
                            }
                            Spacer()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    if entry.id != reportData.itemCostEntries.last?.id {
                        Divider()
                    }
                }
            }

            // 二手交易与实际持有成本说明
            VStack(alignment: .leading, spacing: 4) {
                Text("💡 二手交易如何影响实际持有成本")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                Text("实际持有成本 = 累计投入 − 转卖回血：不常用的物品转卖为二手后，闲置期间的持有天数不再摊高日均成本，净成本被回血金额直接摊薄；二手购入的物品买入价更低，日均成本从一开始就低于全新购入。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(Color.teal.opacity(0.08)))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - 8. 导出与分享卡片 (支持导出为真实 .md 文件与复制 Markdown 源码)

    private var exportActionCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("报告导出与社交分享", systemImage: "square.and.arrow.up")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(reportData.suggestedFileName).md")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 社交媒体图片分享主操作按钮
            Button {
                showingImageShareSheet = true
                Haptic.light()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                    Text("生成图片分享卡片")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [Color.indigo, Color.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Button {
                    exportAsMarkdownFile()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.arrow.up")
                        Text("导出 .md 文档")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    exportAndCopy()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("复制 Markdown")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                showingPreviewSheet = true
                Haptic.light()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                    Text("预览 Markdown 完整结构与源文本")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - 操作与导出逻辑

    private func exportAsMarkdownFile() {
        if let fileURL = reportData.generateMarkdownFile() {
            sharingFileURL = fileURL
            showingShareSheet = true
            Haptic.success()
        }
    }

    private func exportAndCopy() {
        let md = reportData.exportMarkdown()
        UIPasteboard.general.string = md
        Haptic.success()
        withAnimation(.spring(duration: 0.25)) {
            copiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                copiedToast = false
            }
        }
    }

    private func polishWithLLM() {
        isPolishingWithLLM = true
        let sys = "你是贴心而高效的个人生活管家。请基于用户提供的周期复盘数据，写一段充满温度、鼓励人心、语言凝练的复盘总结与寄语（控制在100字以内，不要输出多余标题或符号）。"
        let userContent = "周期：\(reportData.title)\n已完成待办：\(reportData.completedTodos.count)项，总支出：¥\(String(format: "%.1f", reportData.totalExpense))\n基础摘要：\(reportData.smartSummary)"
        Task {
            let res = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: sys,
                userContent: userContent,
                maxNewTokens: 180
            )
            await MainActor.run {
                isPolishingWithLLM = false
                if let res, !res.isEmpty {
                    polishedText = res.trimmingCharacters(in: .whitespacesAndNewlines)
                    Haptic.success()
                }
            }
        }
    }
}

/// Markdown 源码预览与导出 Sheet
struct MarkdownPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let fileName: String
    let markdownContent: String
    let onExportFile: () -> Void
    let onCopyText: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.headline)
                            .foregroundStyle(.tint)
                        Text(fileName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.bottom, 4)

                    Divider()

                    Text(markdownContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Markdown 源码预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 8) {
                        Button {
                            onCopyText()
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }

                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                onExportFile()
                            }
                        } label: {
                            Label("导出文件", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

/// 定期报告定时推送与偏好设置 Sheet
struct PeriodicReportSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reportManager = PeriodicReportManager.shared

    var body: some View {
        NavigationStack {
            Form {
                // 1. 日报（默认开启）
                Section {
                    Toggle("每日生活日报", isOn: $reportManager.isDailyReportEnabled)
                        .tint(.green)

                    if reportManager.isDailyReportEnabled {
                        DatePicker(
                            "每日提醒时间",
                            selection: $reportManager.dailyTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("日报设置（默认开启）")
                } footer: {
                    Text("每天晚间自动汇总今日完成待办、快递取件及今日收支账单，助你轻松完成一天复盘。")
                }

                // 2. 周报
                Section {
                    Toggle("周度复盘周报", isOn: $reportManager.isWeeklyReportEnabled)
                        .tint(.blue)

                    if reportManager.isWeeklyReportEnabled {
                        Picker("每周提醒日", selection: $reportManager.weeklyReportWeekday) {
                            Text("周日").tag(1)
                            Text("周一").tag(2)
                            Text("周六").tag(7)
                            Text("周五").tag(6)
                        }

                        DatePicker(
                            "提醒时间",
                            selection: $reportManager.weeklyTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("周报设置")
                } footer: {
                    Text("每周定时复盘全周目标达成率、分类开支大头与下周重点日程预告。")
                }

                // 3. 月报
                Section {
                    Toggle("月度成长月报", isOn: $reportManager.isMonthlyReportEnabled)
                        .tint(.purple)

                    if reportManager.isMonthlyReportEnabled {
                        DatePicker(
                            "每月最后一天提醒时间",
                            selection: $reportManager.monthlyTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("月报设置")
                } footer: {
                    Text("每月最后一天盘点当月总完成成果、账单开销与月度资产沉淀，并给出趋势分析。")
                }

                // 4. 季报
                Section {
                    Toggle("季度深度复盘季报", isOn: $reportManager.isQuarterlyReportEnabled)
                        .tint(.orange)

                    if reportManager.isQuarterlyReportEnabled {
                        DatePicker(
                            "季末当天提醒时间",
                            selection: $reportManager.quarterlyTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("季报设置")
                } footer: {
                    Text("每季度最后一天回顾本季度的目标达成、财务结构与习惯坚持情况，为下季度校准方向。")
                }

                // 5. 年报
                Section {
                    Toggle("年度生活全景年报", isOn: $reportManager.isYearlyReportEnabled)
                        .tint(.pink)

                    if reportManager.isYearlyReportEnabled {
                        DatePicker(
                            "年末当天提醒时间",
                            selection: $reportManager.yearlyTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("年报设置")
                } footer: {
                    Text("每年 12 月 31 日生成这一年的目标、财务与健康总览回顾。")
                }
            }
            .navigationTitle("报告推送设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        reportManager.scheduleNotifications()
                        dismiss()
                    }
                }
            }
        }
    }
}
