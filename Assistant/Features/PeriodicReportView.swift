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

    private var reportData: PeriodicReportData {
        reportManager.generateReport(period: selectedPeriod, for: currentDate, context: context)
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

                    // 4. AI 智能复盘解读卡片
                    smartSummaryCard

                    // 5. 待办完成成果清单卡片
                    todosAccomplishedCard

                    // 6. 财务支出结构卡片
                    expensesBreakdownCard

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
                Label(period.rawValue, systemImage: period.icon).tag(period)
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

    private func metricGridItem(title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.headline.bold())
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(title)
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

                if LLMModelManager.shared.isModelDownloaded {
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
                            Text(isPolishingWithLLM ? "思考中..." : "端侧大模型润色")
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
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)

                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail)
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
                                    Text(stat.category.rawValue)
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
                                Text(item.title)
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
        guard LLMModelManager.shared.isModelDownloaded else { return }
        isPolishingWithLLM = true
        let prompt = "请作为贴心而高效的个人生活管家，基于以下数据为我写一段充满温度、鼓励人心、语言凝练的复盘金句（120字以内）：\n\(reportData.smartSummary)"
        Task {
            let res = await LLMInferenceService.shared.generate(query: prompt, context: context)
            await MainActor.run {
                isPolishingWithLLM = false
                if !res.isEmpty {
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
