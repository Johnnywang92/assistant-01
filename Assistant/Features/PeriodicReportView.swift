import SwiftData
import SwiftUI

/// 日报 · 周报 · 月报复盘数据中心
struct PeriodicReportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reportManager = PeriodicReportManager.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared

    @State private var selectedPeriod: ReportPeriodType = .daily
    @State private var currentDate: Date = .now
    @State private var showingSettingsSheet: Bool = false
    @State private var copiedToast: Bool = false
    @State private var isPolishingWithLLM: Bool = false
    @State private var polishedText: String? = nil
    @State private var sharingFileURL: URL? = nil
    @State private var showingShareSheet: Bool = false
    @State private var showingPreviewSheet: Bool = false

    init(initialPeriod: ReportPeriodType = .daily) {
        _selectedPeriod = State(initialValue: initialPeriod)
    }

    /// 报告引用缓存：body 内 50+ 处 reportData 访问在同一次渲染中只生成一次。
    /// generateReport 包含多次全表 fetch，无缓存时每处访问都会重新拉取全部数据。
    /// 页面为只读展示，仅在切换周期/日期时重新生成。
    private final class ReportCache {
        var period: ReportPeriodType?
        var date: Date?
        var data: PeriodicReportData?
    }

    @State private var reportCache = ReportCache()

    private var reportData: PeriodicReportData {
        if reportCache.period == selectedPeriod, reportCache.date == currentDate, let cached = reportCache.data {
            return cached
        }
        let result = reportManager.generateReport(period: selectedPeriod, for: currentDate, context: context)
        reportCache.period = selectedPeriod
        reportCache.date = currentDate
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

                    // 月/季/年报：周期回顾（与上期环比对比）
                    if reportData.comparison != nil {
                        periodReviewCard
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
            .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
            .background(bgManager.isCustomBackgroundActive ? Color.clear : Color(.systemGroupedBackground))
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

            VStack(spacing: 2) {
                Text(reportData.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(reportData.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(L10n.tr(title))
                .font(.system(size: 10))
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
                    LLMModelManager.shared.hasValidLocalGGUFFile ||
                    (LLMInferenceService.shared.remoteContextConsent && !LLMInferenceService.shared.developerEndpoint.isEmpty) {
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(suggestionColor(suggestion.tone).opacity(0.08))
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("今天还可以安心花")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(String(format: "¥%.0f", sts.safeToSpendToday))
                        .font(.system(.title, design: .rounded).bold())
                        .foregroundStyle(.green)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(sts.isOverBudget ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(min(max(sts.spentRatio, 0), 1)))
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 周期回顾卡片（月/季/年报：与上一等长周期环比）

    private var periodReviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("周期回顾 · 与上期对比", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
            }

            if let cmp = reportData.comparison {
                let diff = reportData.totalExpense - cmp.prevExpense

                // 支出环比
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本期支出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("¥\(String(format: "%.0f", reportData.totalExpense))")
                            .font(.system(.title3, design: .rounded).bold())
                        Text("\(reportData.expenseCount) 笔")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上期支出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("¥\(String(format: "%.0f", cmp.prevExpense))")
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundStyle(.secondary)
                        Text("\(cmp.prevExpenseCount) 笔")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if cmp.prevExpense > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(diff >= 0 ? "+¥\(String(format: "%.0f", diff))" : "-¥\(String(format: "%.0f", -diff))")
                                .font(.system(.subheadline, design: .rounded).bold())
                                .foregroundStyle(diff >= 0 ? Color.red : .green)
                            Text(diff >= 0
                                 ? "环比 +\(Int(cmp.expenseChangeRatio * 100))%"
                                 : "环比 -\(Int(-cmp.expenseChangeRatio * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                )

                // 完成事项环比
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("完成事项：本期 \(reportData.completedTodos.count) 项 · 上期 \(cmp.prevCompletedCount) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                // 类别结构变化
                if let g = cmp.growingCategory {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Text("增长最快：**\(g.category.rawValue)** ¥\(String(format: "%.0f", g.from)) → ¥\(String(format: "%.0f", g.to))（+¥\(String(format: "%.0f", g.to - g.from))）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                if let s = cmp.shrinkingCategory {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.downtrend.xyaxis")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                        Text("降温最明显：**\(s.category.rawValue)** ¥\(String(format: "%.0f", s.from)) → ¥\(String(format: "%.0f", s.to))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
        )
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.teal.opacity(0.08)))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - 8. 导出与分享卡片 (支持导出为真实 .md 文件与复制 Markdown 源码)

    private var exportActionCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("报告导出与存档", systemImage: "doc.badge.arrow.up")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(reportData.suggestedFileName).md")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    exportAsMarkdownFile()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出为 .md 文档")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                            "每月1日提醒时间",
                            selection: $reportManager.monthlyTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("月报设置")
                } footer: {
                    Text("每月 1 日盘点上月总完成成果、账单开销与月度资产沉淀。")
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
