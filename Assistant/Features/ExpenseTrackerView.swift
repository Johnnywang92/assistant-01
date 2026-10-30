import AssistantCore
import Combine
import SwiftData
import SwiftUI
import PhotosUI
import UIKit

/// 记账单次 O(N) 极速统计算法，避免多次全表重复扫描与高频 Date/Calendar 计算
fileprivate struct ExpenseSummary {
    var todayExpenses: Double = 0
    var currentMonthExpenses: Double = 0
    var currentMonthIncome: Double = 0
    var currentMonthCategoryBreakdown: [(category: ExpenseCategory, amount: Double, ratio: Double)] = []
    var flexibleSpentThisMonth: Double = 0
    var fixedSpentThisMonth: Double = 0
    var yesterdayFlexibleSpend: Double = 0
    var todayFlexibleSpend: Double = 0

    init(records: [ExpenseRecord], calendar: Calendar = .current, now: Date = .now) {
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        var todayExp: Double = 0
        var monthExp: Double = 0
        var monthInc: Double = 0
        var flexibleMonth: Double = 0
        var fixedMonth: Double = 0
        var yesterdayFlex: Double = 0
        var todayFlex: Double = 0
        var categoryMap: [ExpenseCategory: Double] = [:]

        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        for record in records {
            let isToday = calendar.isDate(record.date, inSameDayAs: now)
            let isYesterday = if let startOfYesterday {
                calendar.isDate(record.date, inSameDayAs: startOfYesterday)
            } else {
                false
            }
            let recYear = calendar.component(.year, from: record.date)
            let recMonth = calendar.component(.month, from: record.date)
            let isThisMonth = (recYear == currentYear && recMonth == currentMonth)

            if record.isIncome {
                if isThisMonth {
                    monthInc += record.amount
                }
            } else {
                let isFixed = SafeToSpendCalculator.isFixedExpenseRecord(record.rawText)
                if isToday {
                    todayExp += record.amount
                    if !isFixed {
                        todayFlex += record.amount
                    }
                } else if isYesterday, !isFixed {
                    yesterdayFlex += record.amount
                }
                if isThisMonth {
                    monthExp += record.amount
                    categoryMap[record.category, default: 0] += record.amount
                    if isFixed {
                        fixedMonth += record.amount
                    } else {
                        flexibleMonth += record.amount
                    }
                }
            }
        }

        self.todayExpenses = todayExp
        self.currentMonthExpenses = monthExp
        self.currentMonthIncome = monthInc
        self.flexibleSpentThisMonth = flexibleMonth
        self.fixedSpentThisMonth = fixedMonth
        self.yesterdayFlexibleSpend = yesterdayFlex
        self.todayFlexibleSpend = todayFlex

        if monthExp > 0 {
            self.currentMonthCategoryBreakdown = categoryMap.map { cat, amount in
                (category: cat, amount: amount, ratio: amount / monthExp)
            }.sorted { $0.amount > $1.amount }
        }
    }
}

/// 智能记账本主界面
struct ExpenseTrackerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExpenseRecord.date, order: .reverse) private var records: [ExpenseRecord]
    @Environment(\.colorScheme) private var colorScheme

    @State private var quickInputText: String = ""
    @AppStorage(ExpenseCurrency.preferredCurrencyKey) private var preferredCurrencyRaw: String = ExpenseCurrency.cny.rawValue
    @State private var showingManualAddSheet = false
    @State private var recordToEdit: ExpenseRecord? = nil
    @State private var feedbackBanner: String?
    @State private var isListeningQuickVoice = false
    @State private var showingReceiptScanner = false
    @State private var aiExpenseInsight: String? = nil
    @State private var isAnalyzingExpenses = false
    /// AI 洞察生成时所依据的「本月账本数据指纹」，数据未变时复用缓存结果、避免重复推理
    @State private var aiInsightDataFingerprint: Int? = nil
    @State private var recordToShare: ExpenseRecord?

    private var calendar: Calendar { .current }

    private var preferredCurrency: ExpenseCurrency {
        get { ExpenseCurrency(rawValue: preferredCurrencyRaw) ?? .cny }
        nonmutating set { preferredCurrencyRaw = newValue.rawValue }
    }

    // MARK: - 统计数据单次 O(N) 极速归集（引用缓存：同一渲染内多处访问只算一次）
    private final class ExpenseAnalysisCache {
        var key: Int = -1
        var recordCount: Int = -1
        var lastCheckedTime: CFAbsoluteTime = 0
        var summary: ExpenseSummary?
        var grouped: [(key: String, items: [ExpenseRecord])]?
    }

    @State private var analysisCache = ExpenseAnalysisCache()

    /// 覆盖统计/分组所依赖的字段 + 归属日（跨午夜自动失效）的轻量内容指纹（带 50ms 渲染脉冲节流）。
    private var analysisKey: Int {
        let now = CFAbsoluteTimeGetCurrent()
        if analysisCache.key != -1,
           analysisCache.recordCount == records.count,
           (now - analysisCache.lastCheckedTime) < 0.05 {
            return analysisCache.key
        }
        var hasher = Hasher()
        hasher.combine(Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate)
        hasher.combine(records.count)
        for record in records {
            hasher.combine(record.id)
            hasher.combine(record.date.timeIntervalSinceReferenceDate)
            hasher.combine(record.amount)
            hasher.combine(record.isIncome)
            hasher.combine(record.categoryRaw)
            hasher.combine(record.currencyCode)
            hasher.combine(record.foreignAmount)
            hasher.combine(record.rawText)
        }
        let computed = hasher.finalize()
        analysisCache.lastCheckedTime = now
        analysisCache.recordCount = records.count
        return computed
    }

    /// 键变化时同时丢弃两份缓存；键未变时保留另一份已算结果。
    private func ensureCacheCurrent(for key: Int) {
        if analysisCache.key != key {
            analysisCache.key = key
            analysisCache.summary = nil
            analysisCache.grouped = nil
        }
    }

    private var summary: ExpenseSummary {
        let key = analysisKey
        ensureCacheCurrent(for: key)
        if let cached = analysisCache.summary {
            return cached
        }
        let result = ExpenseSummary(records: records, calendar: calendar)
        analysisCache.summary = result
        return result
    }

    private var todayExpenses: Double { summary.todayExpenses }
    private var currentMonthExpenses: Double { summary.currentMonthExpenses }
    private var currentMonthIncome: Double { summary.currentMonthIncome }
    private var currentMonthCategoryBreakdown: [(category: ExpenseCategory, amount: Double, ratio: Double)] {
        summary.currentMonthCategoryBreakdown
    }

    /// 近 6 个月消费趋势（O(N) 归集，纯函数在 AssistantCore.TrendAnalytics）
    private var expenseTrend: TrendAnalytics.ExpenseTrend {
        TrendAnalytics.expenseTrend(
            entries: records.map {
                TrendAnalytics.ExpenseEntry(
                    date: $0.date,
                    amount: $0.amount,
                    isIncome: $0.isIncome,
                    categoryRaw: $0.categoryRaw
                )
            },
            monthCount: 6
        )
    }

    /// 本月支出指纹：新增 / 编辑 / 删除账目都会改变它。
    /// 用它触发预算提醒复算——只盯 `records.count` 的话，改金额不会重新判定超支。
    private var monthlySpendFingerprint: Double {
        records
            .filter { !$0.isIncome && calendar.isDate($0.date, equalTo: .now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private func categoryColor(_ cat: ExpenseCategory) -> Color {
        switch cat {
        case .food: return .orange
        case .transport: return .blue
        case .living: return .teal
        case .shopping: return .pink
        case .entertainment: return .purple
        case .medical: return .red
        case .pets: return .yellow
        case .digital: return .indigo
        case .social: return .mint
        default: return .gray
        }
    }

    // 按日期分组记录（与 summary 共用内容指纹缓存，避免每次 body 重算全量分组）
    private var groupedRecords: [(key: String, items: [ExpenseRecord])] {
        let key = analysisKey
        ensureCacheCurrent(for: key)
        if let cached = analysisCache.grouped {
            return cached
        }

        let grouped = Dictionary(grouping: records) { item in
            if calendar.isDateInToday(item.date) {
                return "今天"
            } else if calendar.isDateInYesterday(item.date) {
                return "昨天"
            } else {
                return item.date.formatted(date: .abbreviated, time: .omitted)
            }
        }

        // 保持时间倒序
        var result: [(key: String, items: [ExpenseRecord])] = []
        let todayItems = grouped["今天"] ?? []
        if !todayItems.isEmpty { result.append(("今天", todayItems)) }

        let yesterdayItems = grouped["昨天"] ?? []
        if !yesterdayItems.isEmpty { result.append(("昨天", yesterdayItems)) }

        let otherKeys = grouped.keys
            .filter { $0 != "今天" && $0 != "昨天" }
            .sorted { (key1, key2) -> Bool in
                guard let first = grouped[key1]?.first?.date,
                      let second = grouped[key2]?.first?.date else { return false }
                return first > second
            }

        for k in otherKeys {
            if let items = grouped[k] {
                result.append((k, items))
            }
        }
        analysisCache.grouped = result
        return result
    }

    var body: some View {
        let currentSummary = summary
        NavigationStack {
            List {
                // 0. 一句话极速记账输入栏
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(ExpenseCurrency.allCases) { cur in
                                    Button {
                                        preferredCurrency = cur
                                        Haptic.selection()
                                    } label: {
                                        HStack {
                                            Text(cur.pickerLabel)
                                            if cur == preferredCurrency {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(preferredCurrency.flag)
                                        .font(.caption)
                                    Text(preferredCurrency.rawValue)
                                        .font(.caption2.bold())
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(
                                        preferredCurrency == .cny
                                            ? Color(.tertiarySystemFill)
                                            : Color.orange.opacity(0.16)
                                    )
                                )
                                .foregroundStyle(preferredCurrency == .cny ? Color.secondary : Color.orange)
                            }
                            .accessibilityLabel("默认记账币种 \(preferredCurrency.displayName)")

                            TextField("一句话记账（如：麦当劳38、拉面1200日元、$15）", text: $quickInputText)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .onSubmit { submitQuickText() }

                            if !quickInputText.isEmpty {
                                Button {
                                    quickInputText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }

                            // 语音输入按钮
                            Button {
                                toggleQuickVoiceInput()
                            } label: {
                                Image(systemName: isListeningQuickVoice ? "waveform.circle.fill" : "mic.fill")
                                    .font(.title3)
                                    .foregroundStyle(isListeningQuickVoice ? AppColor.danger : AppColor.primary)
                                    .symbolEffect(.pulse, isActive: isListeningQuickVoice)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isListeningQuickVoice ? "停止语音记账" : "语音记账")
                            .accessibilityHint("点击后说出账目，如“麦当劳吃了38”，自动识别记账")

                            // 提交记账按钮
                            Button("记一笔") {
                                submitQuickText()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(quickInputText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        if isListeningQuickVoice {
                            Text("正在聆听... 说完点击话筒即可自动识别记账")
                                .font(.caption2)
                                .foregroundStyle(AppColor.danger)
                        } else if preferredCurrency != .cny {
                            Text("🌏 出国游模式：未写币种时默认按 \(preferredCurrency.flag) \(preferredCurrency.displayName)（\(preferredCurrency.rateDisplayString())）自动折算人民币；也可直接说“1200日元 / 25美元”")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else {
                            Text("💡 支持自然语言与多国货币：麦当劳38、拉面1200日元、星巴克$6.5、打车300泰铢等，自动折算人民币")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("智能极速记账")
                }

                // 1. 今日安心花动态额度（未设月预算时显示设置入口）
                SafeToSpendCard(
                    flexibleSpentThisMonth: currentSummary.flexibleSpentThisMonth,
                    fixedSpentThisMonth: currentSummary.fixedSpentThisMonth,
                    yesterdayFlexibleSpend: currentSummary.yesterdayFlexibleSpend,
                    todayFlexibleSpend: currentSummary.todayFlexibleSpend
                )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                // 2. 统计卡片与本月支出构成胶囊条
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            statCard(title: "今日支出", amount: currentSummary.todayExpenses, color: AppColor.warning)
                            statCard(title: "本月支出", amount: currentSummary.currentMonthExpenses, color: AppColor.danger)
                            statCard(title: "本月收入", amount: currentSummary.currentMonthIncome, color: AppColor.success)
                        }

                        if !currentMonthCategoryBreakdown.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("本月支出构成")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if LLMModelManager.shared.isModelDownloaded {
                                        Button {
                                            analyzeExpensesWithAI()
                                        } label: {
                                            HStack(spacing: 3) {
                                                if isAnalyzingExpenses {
                                                    ProgressView().controlSize(.mini)
                                                } else {
                                                    Image(systemName: "sparkles")
                                                        .font(.caption2)
                                                }
                                                Text(isAnalyzingExpenses ? "分析中..." : "AI 消费洞察")
                                                    .font(.caption2.bold())
                                            }
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Capsule().fill(AppColor.softFill(AppColor.feature, opacity: 0.14)))
                                            .foregroundStyle(AppColor.feature)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isAnalyzingExpenses)
                                    } else {
                                        Text("共 \(currentMonthCategoryBreakdown.count) 类别")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                // 分类彩色多段胶囊条
                                GeometryReader { geo in
                                    HStack(spacing: 2) {
                                        ForEach(currentMonthCategoryBreakdown, id: \.category) { item in
                                            RoundedRectangle(cornerRadius: AppRadius.hairline)
                                                .fill(categoryColor(item.category))
                                                .frame(width: max((geo.size.width - CGFloat(currentMonthCategoryBreakdown.count - 1) * 2) * CGFloat(item.ratio), 4))
                                        }
                                    }
                                }
                                .frame(height: 8)
                                .clipShape(Capsule())

                                // 图例标签
                                HStack(spacing: 10) {
                                    ForEach(currentMonthCategoryBreakdown.prefix(4), id: \.category) { item in
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(categoryColor(item.category))
                                                .frame(width: 6, height: 6)
                                            Text("\(L10n.tr(item.category.rawValue)) \(Int(item.ratio * 100))%")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                if let insight = aiExpenseInsight, !insight.isEmpty {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "brain.head.profile")
                                            .font(.caption)
                                            .foregroundStyle(AppColor.feature)
                                            .padding(.top, 2)
                                        Text(insight)
                                            .font(.caption)
                                            .foregroundStyle(.primary.opacity(0.88))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(AppColor.softFill(AppColor.feature, opacity: 0.08)))
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 2.5 消费趋势（近 6 个月柱状图 + 环比与类别变化）
                ExpenseTrendCard(trend: expenseTrend)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)

                // 3. 消费流水列表
                if records.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "暂无记账明细",
                            systemImage: "creditcard",
                            description: Text("试着在上方输入或点击麦克风说一句话记一笔")
                        )
                    }
                } else {
                    ForEach(groupedRecords, id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.items) { item in
                                Button {
                                    recordToEdit = item
                                    Haptic.light()
                                } label: {
                                    ExpenseRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .leading) {
                                    Button {
                                        recordToEdit = item
                                        Haptic.light()
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    .tint(.indigo)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        recordToShare = item
                                    } label: {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.blue)
                                }
                                .contextMenu {
                                    Button {
                                        recordToEdit = item
                                    } label: {
                                        Label("编辑这笔账目", systemImage: "pencil")
                                    }

                                    Button(role: .destructive) {
                                        deleteRecord(item)
                                    } label: {
                                        Label("删除这笔账目", systemImage: "trash")
                                    }
                                    Button {
                                        recordToShare = item
                                    } label: {
                                        Label("分享账单", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                            .onDelete { offsets in
                                deleteRecords(offsets: offsets, from: group.items)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .themedScrollContentBackground()
            .themedAppBackground()
            .themedRow()
            .navigationTitle("智能记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingManualAddSheet = true
                        } label: {
                            Label("手动记一笔", systemImage: "pencil")
                        }

                        Button {
                            showingReceiptScanner = true
                        } label: {
                            Label("拍小票记账", systemImage: "doc.viewfinder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增记账")
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                AddOrEditExpenseSheet(recordToEdit: nil)
            }
            .sheet(item: $recordToEdit) { record in
                AddOrEditExpenseSheet(recordToEdit: record)
            }
            .sheet(item: $recordToShare) { record in
                ExpenseCardShareSheet(record: record)
            }
            .expenseCalorieConfirmation()
            .task {
                ExpenseCalorieService.reconcileOrphans(context: context)
                ExpenseWaterService.reconcileOrphans(context: context)
                // 进入记账页先复算一次预算告警：上次超支提醒可能是在别的入口触发的，
                // 这里保证状态与当前账本一致（跨月自动重置也在这里生效）
                BudgetAlertService.shared.evaluateAndNotify(records: records)
            }
            // 账目变动（新增 / 编辑 / 删除）后实时复算预算告警
            .onChange(of: monthlySpendFingerprint) { _, _ in
                BudgetAlertService.shared.evaluateAndNotify(records: records)
            }
            .sheet(isPresented: $showingReceiptScanner) {
                ReceiptScannerView { result, rawText, receiptData in
                    let record = ExpenseRecord(
                        amount: result.amount,
                        isIncome: result.isIncome,
                        category: result.category,
                        title: result.title,
                        rawText: rawText,
                        date: result.date,
                        currencyCode: result.isForeignCurrency ? result.currency.rawValue : nil,
                        foreignAmount: result.foreignAmount,
                        exchangeRateToCNY: result.exchangeRateToCNY
                    )
                    record.receiptImageData = receiptData
                    context.insert(record)
                    try? context.save()
                    ExpenseCalorieService.handleSaved(record, propose: true, context: context)
                    ExpenseWaterService.handleSaved(record, context: context)
                    if let badge = record.formattedForeignBadge {
                        showFeedback("已从小票记入 ¥\(String(format: "%.2f", result.amount))（\(badge)）")
                    } else {
                        showFeedback("已从小票记入 ¥\(String(format: "%.2f", result.amount))")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let feedback = feedbackBanner {
                    Text(L10n.tr(feedback))
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 24)
                }
            }
            .onReceive(VoiceDialogueService.shared.$isListening.removeDuplicates()) { listening in
                if !listening && isListeningQuickVoice {
                    let voice = VoiceDialogueService.shared
                    isListeningQuickVoice = false
                    if !voice.recognizedText.isEmpty {
                        quickInputText = voice.recognizedText
                        voice.recognizedText = ""
                        submitQuickText()
                    }
                }
            }
        }
    }

    // MARK: - 统计卡片辅助视图
    private func statCard(title: String, amount: Double, color: Color) -> some View {        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "¥%.1f", amount))
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(color)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.medium).fill(AppColor.surface))
        // VoiceOver：统计卡整体播报「标题 + 金额」
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)")
        .accessibilityValue(String(format: "%.1f 元", amount))
    }

    // MARK: - 一句话记账提交
    private func submitQuickText() {
        let text = quickInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let results = ExpenseNaturalLanguageParser.parseMulti(text, defaultCurrency: preferredCurrency)
        guard !results.isEmpty else {
            Haptic.warning()
            showFeedback("未能识别出金额，请写明金额（如：吃午饭 25 元）")
            return
        }

        var totalExpense = 0.0
        var titles: [String] = []
        var savedRecords: [ExpenseRecord] = []
        for result in results {
            let record = ExpenseRecord(
                amount: result.amount,
                isIncome: result.isIncome,
                category: result.category,
                title: result.title,
                rawText: text,
                date: result.date,
                currencyCode: result.isForeignCurrency ? result.currency.rawValue : nil,
                foreignAmount: result.foreignAmount,
                exchangeRateToCNY: result.exchangeRateToCNY
            )
            record.splitCount = max(result.splitCount, 1)
            record.splitParticipants = result.splitParticipants
            context.insert(record)
            savedRecords.append(record)
            if !result.isIncome { totalExpense += result.amount }
            titles.append(result.title)
            ExpenseCalorieService.handleSaved(record, propose: results.count == 1, context: context)
            ExpenseWaterService.handleSaved(record, context: context)
        }
        try? context.save()
        Haptic.success()
        quickInputText = ""

        if results.count == 1, let result = results.first {
            let amountStr = String(format: "%.2f", result.amount)
            let foreignSuffix: String = {
                guard let badge = savedRecords.first?.formattedForeignBadge else { return "" }
                return " · 原币 \(badge)"
            }()
            let desc = result.isIncome
                ? "已记入入账 ¥\(amountStr)\(foreignSuffix)"
                : "已记入 ¥\(amountStr)（\(result.category.rawValue)\(foreignSuffix)）"
            showFeedback(desc)
        } else {
            let totalStr = String(format: "%.2f", totalExpense)
            showFeedback("已记入 \(results.count) 笔 · 合计 ¥\(totalStr)（\(titles.joined(separator: " / "))）")
        }
    }

    private func toggleQuickVoiceInput() {
        let voice = VoiceDialogueService.shared
        if isListeningQuickVoice {
            // 让 isListening 的 onChange 回调统一接收最终识别文本并提交记账。
            // 这里不能提前将 isListeningQuickVoice 置 false，否则回调会误以为不是一次完整录音而直接丢弃文本。
            voice.stopListening()
        } else {
            Task {
                let granted = await voice.requestPermissions()
                if granted {
                    isListeningQuickVoice = true
                    do {
                        try await voice.startListening()
                        isListeningQuickVoice = voice.isListening
                    } catch {
                        isListeningQuickVoice = false
                        showFeedback(error.localizedDescription)
                    }
                } else {
                    showFeedback("请开启麦克风与语音识别权限")
                }
            }
        }
    }

    /// 「本月账本数据指纹」：仅覆盖影响洞察的本月支出字段 + 月预算 + 固定支出月额 + 归属年月。
    /// 数据未变化时指纹一致，可复用缓存的洞察结果，避免重复端侧推理。
    private var currentMonthAIFingerprint: Int {
        let cal = calendar
        let now = Date.now
        var hasher = Hasher()
        hasher.combine(cal.component(.year, from: now))
        hasher.combine(cal.component(.month, from: now))
        for record in records {
            guard !record.isIncome,
                  cal.component(.year, from: record.date) == cal.component(.year, from: now),
                  cal.component(.month, from: record.date) == cal.component(.month, from: now) else { continue }
            hasher.combine(record.date.timeIntervalSinceReferenceDate)
            hasher.combine(record.amount)
            hasher.combine(record.categoryRaw)
        }
        hasher.combine(BudgetSettings.monthlyBudget)
        hasher.combine(RecurringExpenseManager.shared.monthlyEstimatedTotal)
        return hasher.finalize()
    }

    /// 汇总本月支出、上月支出、本月 Top-3 大额、安心花预算与时间进度，一次 O(N) 归集，拼接为喂给模型的上下文
    private func makeAIInsightUserContent() -> String {
        let cal = calendar
        let now = Date.now
        let curYear = cal.component(.year, from: now)
        let curMonth = cal.component(.month, from: now)
        let prevRef = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let prevYear = cal.component(.year, from: prevRef)
        let prevMonth = cal.component(.month, from: prevRef)

        var prevMonthTotal = 0.0
        var currentMonthExpensesList: [ExpenseRecord] = []
        for record in records where !record.isIncome {
            let ry = cal.component(.year, from: record.date)
            let rm = cal.component(.month, from: record.date)
            if ry == curYear && rm == curMonth {
                currentMonthExpensesList.append(record)
            } else if ry == prevYear && rm == prevMonth {
                prevMonthTotal += record.amount
            }
        }

        var lines: [String] = []
        lines.append("今日支出：¥\(String(format: "%.1f", todayExpenses))；本月总支出：¥\(String(format: "%.1f", currentMonthExpenses))；本月总收入：¥\(String(format: "%.1f", currentMonthIncome))")

        let breakdownStr = currentMonthCategoryBreakdown
            .map { "\($0.category.rawValue) ¥\(String(format: "%.0f", $0.amount))（\(Int($0.ratio * 100))%）" }
            .joined(separator: "、")
        lines.append("本月分类占比：\(breakdownStr)")

        // 环比（本月 vs 上月）
        let momDelta = currentMonthExpenses - prevMonthTotal
        if prevMonthTotal > 0 {
            let pct = Int((momDelta / prevMonthTotal * 100).rounded())
            let dir = momDelta >= 0 ? "增加" : "减少"
            lines.append("环比上月（¥\(String(format: "%.0f", prevMonthTotal))）：\(dir) \(abs(pct))%（¥\(String(format: "%.0f", abs(momDelta)))）")
        } else {
            lines.append("上月支出：¥\(String(format: "%.0f", prevMonthTotal))（无环比基准）")
        }

        // 预算 / 已用 / 剩余 + 时间进度
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeft = max(1, daysInMonth - dayOfMonth + 1)
        let fixedMonthly = RecurringExpenseManager.shared.monthlyEstimatedTotal
        let input = SafeToSpendCalculator.inputFromRecords(records: records, fixedMonthlyTotal: fixedMonthly, calendar: cal, now: now)
        let safe = SafeToSpendCalculator.compute(input: input, now: now, calendar: cal)
        if safe.isEnabled {
            lines.append("月弹性预算：¥\(String(format: "%.0f", safe.disposableBudget))；本月弹性已用 ¥\(String(format: "%.0f", input.flexibleSpentThisMonth))（占 \(Int((safe.spentRatio * 100).rounded()))%）；剩余 ¥\(String(format: "%.0f", safe.remainingThisMonth))\(safe.isOverBudget ? "（已超支）" : "")")
        } else {
            lines.append("未设置月预算")
        }
        lines.append("时间进度：今天是本月第 \(dayOfMonth)/\(daysInMonth) 天，距月底还有 \(daysLeft) 天")

        // 本月 Top-3 大额单笔消费
        let top3 = currentMonthExpensesList.sorted { $0.amount > $1.amount }.prefix(3)
        if !top3.isEmpty {
            let top3Str = top3.map { "\($0.title)（\($0.category.rawValue) ¥\(String(format: "%.0f", $0.amount))）" }.joined(separator: "、")
            lines.append("本月最大三笔支出：\(top3Str)")
        }

        // 固定周期支出（月均 Top-3）
        if fixedMonthly > 0 {
            let recurringStr = RecurringExpenseManager.shared.items
                .filter { !$0.isPaused }
                .sorted { $0.monthlyEquivalentAmount > $1.monthlyEquivalentAmount }
                .prefix(3)
                .map { "\($0.title) ¥\(String(format: "%.0f", $0.monthlyEquivalentAmount))" }
                .joined(separator: "、")
            if !recurringStr.isEmpty {
                lines.append("固定周期支出（月均合计 ¥\(String(format: "%.0f", fixedMonthly))）：\(recurringStr)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func analyzeExpensesWithAI() {
        // 命中缓存：数据指纹未变且已有洞察结果，直接复用，不重复推理
        let fingerprint = currentMonthAIFingerprint
        if let insight = aiExpenseInsight, !insight.isEmpty, aiInsightDataFingerprint == fingerprint {
            Haptic.light()
            showFeedback("消费洞察已是最新")
            return
        }

        isAnalyzingExpenses = true
        Haptic.light()
        let userContent = makeAIInsightUserContent()
        let sys = "你是贴心的个人财务管家。请基于用户给出的本月消费数据（含预算/时间进度/环比/大额/固定支出），严格按以下三行结构化输出，不要标题、不要额外解释：\n结论：<一句话概括本月消费结构与预算健康度>\n风险：<最值得关注的单个消费风险或超支隐患>\n建议：<一条具体可执行的节流建议>\n每行不超过 40 字，整体控制在 120 字以内。"
        Task {
            let output = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: sys,
                userContent: userContent,
                maxNewTokens: 250
            )
            await MainActor.run {
                isAnalyzingExpenses = false
                if let output, !output.isEmpty {
                    AppMotion.animate {
                        aiExpenseInsight = output
                        aiInsightDataFingerprint = fingerprint
                    }
                    Haptic.success()
                } else {
                    showFeedback("端侧 AI 模型尚未就绪")
                }
            }
        }
    }

    private func showFeedback(_ text: String) {
        AppMotion.animate { feedbackBanner = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            AppMotion.animate { feedbackBanner = nil }
        }
    }

    private func deleteRecord(_ item: ExpenseRecord) {
        ExpenseCalorieService.handleDeleted(expenseID: item.id, context: context)
        ExpenseWaterService.handleDeleted(expenseID: item.id, context: context)
        context.delete(item)
        try? context.save()
        Haptic.medium()
        showFeedback("已删除 1 笔账目记录")
    }

    private func deleteRecords(offsets: IndexSet, from items: [ExpenseRecord]) {
        for index in offsets {
            let item = items[index]
            ExpenseCalorieService.handleDeleted(expenseID: item.id, context: context)
            ExpenseWaterService.handleDeleted(expenseID: item.id, context: context)
            context.delete(item)
        }
        try? context.save()
    }
}

// MARK: - 今日安心花动态额度卡片

/// 「今日安心花（Safe-to-Spend）」：月预算扣除固定周期支出后，
/// 按距月底剩余天数均摊出今日可用额度；随今日记账实时扣减，昨天花剩的钱自动滚入今天。
struct SafeToSpendCard: View {
    var flexibleSpentThisMonth: Double
    var fixedSpentThisMonth: Double
    var yesterdayFlexibleSpend: Double
    var todayFlexibleSpend: Double
    @AppStorage("expense_monthly_budget") private var monthlyBudget: Double = 0
    @AppStorage("safe_to_spend_rhythm_mode") private var rhythmModeRaw: String = SpendingRhythmMode.weekendLeisure.rawValue
    @ObservedObject private var recurringManager = RecurringExpenseManager.shared
    @State private var showingBudgetSheet = false

    private var rhythmMode: SpendingRhythmMode {
        SpendingRhythmMode(rawValue: rhythmModeRaw) ?? .weekendLeisure
    }

    init(
        flexibleSpentThisMonth: Double,
        fixedSpentThisMonth: Double = 0,
        yesterdayFlexibleSpend: Double,
        todayFlexibleSpend: Double
    ) {
        self.flexibleSpentThisMonth = flexibleSpentThisMonth
        self.fixedSpentThisMonth = fixedSpentThisMonth
        self.yesterdayFlexibleSpend = yesterdayFlexibleSpend
        self.todayFlexibleSpend = todayFlexibleSpend
    }

    init(records: [ExpenseRecord], rhythmMode: SpendingRhythmMode = .weekendLeisure) {
        let input = SafeToSpendCalculator.inputFromRecords(
            records: records,
            fixedMonthlyTotal: RecurringExpenseManager.shared.monthlyEstimatedTotal,
            rhythmMode: rhythmMode
        )
        self.flexibleSpentThisMonth = input.flexibleSpentThisMonth
        self.fixedSpentThisMonth = input.fixedSpentThisMonth
        self.yesterdayFlexibleSpend = input.yesterdayFlexibleSpend
        self.todayFlexibleSpend = input.todayFlexibleSpend
    }

    private var result: SafeToSpendResult? {
        let budget = monthlyBudget > 0 ? monthlyBudget : BudgetSettings.monthlyBudget
        let input = SafeToSpendInput(
            monthlyBudget: budget,
            fixedMonthlyTotal: recurringManager.monthlyEstimatedTotal,
            flexibleSpentThisMonth: flexibleSpentThisMonth,
            fixedSpentThisMonth: fixedSpentThisMonth,
            yesterdayFlexibleSpend: yesterdayFlexibleSpend,
            todayFlexibleSpend: todayFlexibleSpend,
            rhythmMode: rhythmMode
        )
        let computed = SafeToSpendCalculator.compute(input: input)
        return computed.isEnabled ? computed : nil
    }

    /// 一次性 O(N) 归集安心花所需的账本快照（逻辑统一在 SafeToSpendCalculator.inputFromRecords）
    static func buildInput(records: [ExpenseRecord], fixedMonthlyTotal: Double) -> SafeToSpendInput {
        SafeToSpendCalculator.inputFromRecords(records: records, fixedMonthlyTotal: fixedMonthlyTotal)
    }

    var body: some View {
        Button {
            showingBudgetSheet = true
            Haptic.light()
        } label: {
            if let result {
                configuredCard(result)
            } else {
                setUpCard
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看或编辑月度预算")
        .sheet(isPresented: $showingBudgetSheet) {
            BudgetEditSheet()
        }
    }

    /// 未设置月预算时的引导态：保证「月预算设置」入口始终可达
    private var setUpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("今日安心花", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("设置月预算，开始计算今日安心花")
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.primary)

            Text("填写每月弹性消费上限后，房租、订阅等固定支出会自动扣除，今天省下的钱会滚入明天。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard(cornerRadius: AppRadius.banner)
    }

    @ViewBuilder
    private func configuredCard(_ result: SafeToSpendResult) -> some View {
        let budget = monthlyBudget > 0 ? monthlyBudget : BudgetSettings.monthlyBudget
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("今日安心花", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                if result.rhythmMode == .weekendLeisure {
                    Text(result.isWeekend ? "🎉 周末充裕池" : "💼 工作日蓄水")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(result.isWeekend ? Color.purple.opacity(0.12) : AppColor.primary.opacity(0.12))
                        .foregroundStyle(result.isWeekend ? .purple : AppColor.primary)
                        .clipShape(Capsule())
                }
                Spacer()
                Text("距月底 \(result.daysLeft) 天")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if result.isOverBudget {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.danger)
                    Text("本月弹性预算已超支 ¥\(String(format: "%.0f", -result.remainingThisMonth))，今天尽量少花")
                        .font(.subheadline)
                        .foregroundStyle(AppColor.danger)
                }
            } else if result.isTodayOverspent {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("今日已超额")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "¥%.0f", result.todayOverspentAmount))
                            .font(.system(.largeTitle, design: .rounded).bold())
                            .foregroundStyle(AppColor.danger)
                            .contentTransition(.numericText())
                    }
                    Text("今日起始额度 ¥\(String(format: "%.0f", result.todayAllowance)) · 今日已花 ¥\(String(format: "%.0f", result.todayFlexibleSpend))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("还可以安心花")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "¥%.0f", result.safeToSpendToday))
                            .font(.system(.largeTitle, design: .rounded).bold())
                            .foregroundStyle(result.safeToSpendToday > 0 ? AppColor.success : AppColor.warning)
                            .contentTransition(.numericText())
                    }
                    if result.todayFlexibleSpend > 0 {
                        Text("今日基准额度 ¥\(String(format: "%.0f", result.todayAllowance)) · 今日已花 ¥\(String(format: "%.0f", result.todayFlexibleSpend))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 今日额度消耗进度条（随今日记账实时反映今日起始额度的消耗进度）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.fillTertiary)
                    Capsule()
                        .fill(result.isOverBudget || result.isTodayOverspent ? AppColor.danger : AppColor.success)
                        .frame(width: min(1, max(0, result.todaySpentRatio)) * geo.size.width)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("今日额度消耗进度")
            .accessibilityValue(String(format: "已用 %.0f%%", min(1, max(0, result.todaySpentRatio)) * 100))

            if let advice = result.rhythmAdviceText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(AppColor.primary)
                        .padding(.top, 1)
                    Text(advice)
                        .font(.caption2)
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 12) {
                Text("月预算 ¥\(String(format: "%.0f", budget))")
                Text("固定支出 ¥\(String(format: "%.0f", recurringManager.monthlyEstimatedTotal))")
                if result.savedYesterday >= 0.5 {
                    Text("昨日省下 ¥\(String(format: "%.0f", result.savedYesterday)) 已滚入 💰")
                        .foregroundStyle(.green)
                } else if result.weekendReservoirTotal >= 10 && !result.isWeekend {
                    Text("本周已蓄水 ¥\(String(format: "%.0f", result.weekendReservoirTotal)) 🌊")
                        .foregroundStyle(AppColor.primary)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard(cornerRadius: AppRadius.banner)
    }
}

// MARK: - 月预算设置弹窗

struct BudgetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @ObservedObject private var recurringManager = RecurringExpenseManager.shared
    @AppStorage("safe_to_spend_rhythm_mode") private var rhythmModeRaw: String = SpendingRhythmMode.weekendLeisure.rawValue
    @State private var budgetText: String = ""
    /// 正在编辑的固定支出；nil 表示当前处于「新增」流程。
    @State private var editingItem: RecurringExpenseItem?
    @State private var isAddingItem = false

    private var disposableBudget: Double {
        let budget = Double(budgetText) ?? 0
        return budget - recurringManager.monthlyEstimatedTotal
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("月预算")
                            .foregroundStyle(.secondary)
                        TextField("如 5000", text: $budgetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.title3, design: .rounded).bold())
                        Text("¥")
                            .foregroundStyle(.secondary)
                    }
                    Text("预算指本月弹性消费上限。房租、订阅等固定支出会自动扣除，不再占预算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("设定月度弹性预算")
                } footer: {
                    if disposableBudget > 0 {
                        Text("扣除固定支出后，本月弹性可用约 ¥\(String(format: "%.0f", disposableBudget))")
                    } else if Double(budgetText) ?? 0 > 0 {
                        Text("预算低于固定支出月额，请调高预算或精简固定支出")
                    }
                }

                Section {
                    Picker("消费节奏分配", selection: $rhythmModeRaw) {
                        ForEach(SpendingRhythmMode.allCases, id: \.rawValue) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    if rhythmModeRaw == SpendingRhythmMode.weekendLeisure.rawValue {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(AppColor.primary)
                                .padding(.top, 1)
                            Text("推荐模式：周一至周五工作日轻量消费，省下的额度自动蓄水至周六日（额度提升约 1.8 倍），周末聚餐娱乐更从容；周一平稳复原。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("传统模式：将本月可用弹性额度均摊到每一天。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("消费节奏分配模式")
                }

                Section {
                    // 暂停项也要展示：否则用户不知道「这条为什么没被扣预算」，
                    // 也没法在这里把它恢复。合计只统计未暂停项。
                    if recurringManager.items.isEmpty {
                        Text("暂无固定周期支出，点下方按钮添加房租、订阅等月度刚性开销。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recurringManager.items) { item in
                            Button {
                                editingItem = item
                            } label: {
                                RecurringExpenseRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    recurringManager.delete(id: item.id)
                                    Haptic.impact(style: .light)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button(item.isPaused ? "恢复" : "暂停", systemImage: item.isPaused ? "play.fill" : "pause.fill") {
                                    recurringManager.togglePause(for: item)
                                    Haptic.impact(style: .light)
                                }
                                .tint(item.isPaused ? AppColor.success : AppColor.warning)
                            }
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { editingItem = item }
                                Button(item.isPaused ? "恢复扣除" : "暂停扣除",
                                       systemImage: item.isPaused ? "play.fill" : "pause.fill") {
                                    recurringManager.togglePause(for: item)
                                }
                                Button("立即记一笔", systemImage: "plus.circle") {
                                    recurringManager.recordNow(item: item, in: context)
                                    Haptic.success()
                                }
                                Divider()
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    recurringManager.delete(id: item.id)
                                }
                            }
                        }

                        HStack {
                            Text("合计").bold()
                            Spacer()
                            Text("¥\(String(format: "%.0f", recurringManager.monthlyEstimatedTotal))")
                                .bold()
                                .foregroundStyle(.indigo)
                        }
                    }

                    Button {
                        isAddingItem = true
                    } label: {
                        Label("添加固定支出", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("自动扣除的固定支出")
                } footer: {
                    if !recurringManager.items.filter({ $0.isPaused }).isEmpty || !recurringManager.items.isEmpty {
                        Text("点按任意一项可修改金额、周期与提醒。暂停的项目不计入扣除合计。")
                    }
                }
            }
            .navigationTitle("月预算设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        BudgetSettings.monthlyBudget = Double(budgetText) ?? 0
                        Haptic.success()
                        dismiss()
                    }
                    .disabled((Double(budgetText) ?? 0) < 0)
                }
            }
            .onAppear {
                let budget = BudgetSettings.monthlyBudget
                budgetText = budget > 0 ? String(format: "%.0f", budget) : ""
            }
            .sheet(isPresented: $isAddingItem) {
                RecurringExpenseEditorSheet(itemToEdit: nil)
            }
            // 用 item: nil 表达 dismiss，避免 UUID 被误当"可编辑"标记。
            .sheet(item: $editingItem) { item in
                RecurringExpenseEditorSheet(itemToEdit: item)
            }
        }
    }
}

// MARK: - 固定支出列表行

private struct RecurringExpenseRow: View {
    let item: RecurringExpenseItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.icon)
                .font(.subheadline)
                .foregroundStyle(item.isPaused ? Color.secondary : AppColor.primary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundStyle(item.isPaused ? .secondary : .primary)
                    if item.isPaused {
                        Text("已暂停")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppColor.fillTertiary))
                            .foregroundStyle(.secondary)
                    }
                }
                // 折算口径必须写清：年费 ÷12、周费 ×52/12 与用户心里的「每月多少」不同源，
                // 不说明会让「¥15000/年」和列表里其他项无法横向比较。
                Text("¥\(String(format: "%.0f", item.amount))\(item.cycle.displayUnit) · 月均 ¥\(String(format: "%.0f", item.monthlyEquivalentAmount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("¥\(String(format: "%.0f", item.monthlyEquivalentAmount))")
                .font(.subheadline)
                .foregroundStyle(item.isPaused ? .secondary : .primary)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 新增 / 编辑固定支出

private struct RecurringExpenseEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// nil = 新增；非 nil = 编辑该条目。
    let itemToEdit: RecurringExpenseItem?

    @State private var title = ""
    @State private var amountText = ""
    @State private var category: ExpenseCategory = .living
    @State private var cycle: RecurringExpenseCycle = .monthly
    @State private var customDaysText = "30"
    @State private var nextDueDate = Date.now
    @State private var isAutoRecord = true
    @State private var isReminderEnabled = true
    @State private var reminderDaysText = "2"
    @State private var notes = ""

    private var isEditing: Bool { itemToEdit != nil }

    private var parsedAmount: Double? {
        let cleaned = amountText.replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    /// 自定义周期间隔需 ≥1，否则 advanceToNextCycleDate 会退化成不推进。
    private var customDaysInterval: Int {
        max(1, Int(customDaysText) ?? 30)
    }

    private var reminderDays: Int {
        min(60, max(0, Int(reminderDaysText) ?? 2))
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedAmount != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如：房租、Netflix 会员", text: $title)
                    HStack {
                        Text("每次扣费金额").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .rounded).bold())
                        Text("¥").foregroundStyle(.secondary)
                    }
                    Picker("消费类别", selection: $category) {
                        ForEach(ExpenseCategory.allCases.filter { !$0.isIncome }, id: \.self) { c in
                            Label(L10n.tr(c.rawValue), systemImage: c.icon).tag(c)
                        }
                    }
                } header: {
                    Text("基本信息")
                } footer: {
                    if !canSave && !title.isEmpty {
                        Text("金额需为大于 0 的数字")
                            .foregroundStyle(AppColor.danger)
                    }
                }

                Section("周期与排期") {
                    Picker("周期", selection: $cycle) {
                        ForEach(RecurringExpenseCycle.allCases) { c in
                            Label(L10n.tr(c.rawValue), systemImage: c.icon).tag(c)
                        }
                    }
                    if cycle == .customDays {
                        HStack {
                            Text("间隔天数").foregroundStyle(.secondary)
                            Spacer()
                            TextField("30", text: $customDaysText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("天").foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("下次扣费", selection: $nextDueDate, displayedComponents: [.date])
                }

                Section {
                    Toggle("到期自动记入账本", isOn: $isAutoRecord)
                    Toggle("扣费前提醒", isOn: $isReminderEnabled)
                    if isReminderEnabled {
                        HStack {
                            Text("提前天数").foregroundStyle(.secondary)
                            Spacer()
                            TextField("2", text: $reminderDaysText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("天").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("记账与提醒")
                } footer: {
                    // 提前天数大于扣费周期时，这次提醒毫无意义（提醒日已过扣费日），
                    // 所以在表单层就说明，不让用户自己撞这个坑。
                    if isReminderEnabled && cycle == .customDays && reminderDays >= customDaysInterval {
                        Text("提醒提前 \(reminderDays) 天不少于扣费间隔 \(customDaysInterval) 天，这次提醒会落在下个周期之后，实际不会触发。")
                            .foregroundStyle(AppColor.warning)
                    } else if isReminderEnabled && cycle == .monthly && reminderDays > 31 {
                        Text("按月扣费最多提前 30 天提醒更有效。")
                            .foregroundStyle(AppColor.warning)
                    }
                }

                Section("备注") {
                    TextField("可选，例如：自动扣款银行卡尾号 1234", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(isEditing ? "编辑固定支出" : "添加固定支出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    /// 只在首次出现时回填。复用同一个 sheet 时若每次 onAppear 都重置，
    /// 用户滚动导致的重新呈现会抹掉刚输入的内容。
    private func loadIfNeeded() {
        guard title.isEmpty, amountText.isEmpty else { return }
        guard let item = itemToEdit else {
            // 新增时默认给一个月后的今天，比「今天」更符合下期扣费的直觉。
            nextDueDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
            return
        }
        title = item.title
        amountText = String(format: "%.2f", item.amount)
        category = item.category
        cycle = item.cycle
        customDaysText = String(item.customDaysInterval)
        nextDueDate = item.nextDueDate
        isAutoRecord = item.isAutoRecord
        isReminderEnabled = item.isReminderEnabled
        reminderDaysText = String(item.reminderDaysBefore)
        notes = item.notes ?? ""
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // 以原条目为基底改写：这样 id / createdAt / lastRecordedDate
        // 这些不属于用户可编辑范围的状态不会被抹掉，也不会因漏写而丢历史。
        var item = itemToEdit ?? RecurringExpenseItem(
            title: trimmedTitle,
            amount: amount,
            category: category,
            cycle: cycle,
            customDaysInterval: customDaysInterval,
            nextDueDate: nextDueDate
        )
        item.title = trimmedTitle
        item.amount = amount
        item.category = category
        item.cycle = cycle
        item.customDaysInterval = customDaysInterval
        item.nextDueDate = nextDueDate
        item.isAutoRecord = isAutoRecord
        item.isReminderEnabled = isReminderEnabled
        item.reminderDaysBefore = reminderDays
        item.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        if isEditing {
            RecurringExpenseManager.shared.update(item: item)
        } else {
            RecurringExpenseManager.shared.add(item: item)
        }
        Haptic.success()
        dismiss()
    }
}

// MARK: - 单笔明细行视图

struct ExpenseRow: View {
    let item: ExpenseRecord

    var body: some View {
        HStack(spacing: 12) {
            // 分类图标
            ZStack {
                Circle()
                    .fill(item.isIncome ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: item.category.icon)
                    .font(.subheadline)
                    .foregroundStyle(item.isIncome ? Color.green : Color.orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr(item.title))
                    .font(.body)
                HStack(spacing: 6) {
                    Text(L10n.tr(item.category.rawValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let foreignBadge = item.formattedForeignBadge {
                        Text(foreignBadge)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                            .foregroundStyle(.orange)
                    }
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%@¥%.2f", item.isIncome ? "+" : "-", item.amount))
                    .font(.system(.body, design: .rounded).bold())
                    .foregroundStyle(item.isIncome ? Color.green : Color.primary)
                if let foreignText = item.formattedForeignAmount {
                    Text(foreignText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - 手动记账与编辑记录弹窗

struct AddOrEditExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredItem.name) private var storedItems: [StoredItem]

    var recordToEdit: ExpenseRecord? = nil

    @State private var isIncome: Bool = false
    @State private var amountString: String = ""
    @State private var selectedCurrency: ExpenseCurrency = .cny
    @State private var exchangeRateString: String = "1.0"
    @State private var isSyncingOnlineRates: Bool = false
    @State private var rateStatusMessage: String? = nil
    @State private var selectedCategory: ExpenseCategory = .food
    @State private var title: String = ""
    @State private var date: Date = .now
    @State private var receiptImageData: Data?
    @State private var selectedReceiptItem: PhotosPickerItem?
    @State private var splitCountString = "1"
    @State private var splitParticipants = ""
    @State private var showingDeleteConfirm = false
    @State private var linkedItemID: UUID? = nil

    private var isEditing: Bool {
        recordToEdit != nil
    }

    private var parsedInputAmount: Double {
        Double(amountString.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private var parsedExchangeRate: Double {
        guard selectedCurrency != .cny else { return 1.0 }
        if let val = Double(exchangeRateString.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), val > 0 {
            return val
        }
        return selectedCurrency.currentRateToCNY
    }

    /// 最终落库的人民币金额（CNY）
    private var convertedCNYAmount: Double {
        guard parsedInputAmount > 0 else { return 0 }
        if selectedCurrency == .cny {
            return (parsedInputAmount * 100).rounded() / 100
        }
        return selectedCurrency.convertToCNY(parsedInputAmount, rate: parsedExchangeRate)
    }

    private var availableCategories: [ExpenseCategory] {
        if isIncome {
            return [.income, .otherIncome]
        } else {
            return SituationalContextEngine.shared.prioritizedExpenseCategories()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 收支类型与金额
                Section {
                    Picker("收支类型", selection: $isIncome) {
                        Text("支出").tag(false)
                        Text("收入").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: isIncome) { _, income in
                        if income {
                            selectedCategory = .income
                        } else {
                            if selectedCategory.isIncome {
                                selectedCategory = availableCategories.first ?? .food
                            }
                        }
                    }

                    HStack {
                        Menu {
                            ForEach(ExpenseCurrency.allCases) { cur in
                                Button {
                                    selectedCurrency = cur
                                    exchangeRateString = cur.formatRateInput()
                                    rateStatusMessage = nil
                                    Haptic.selection()
                                } label: {
                                    HStack {
                                        Text(cur.pickerLabel)
                                        if cur == selectedCurrency {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedCurrency.flag)
                                Text(selectedCurrency.symbol)
                                    .font(.title3.bold())
                                    .foregroundStyle(isIncome ? Color.green : Color.red)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                        }

                        TextField("0.00", text: $amountString)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .rounded).bold())
                    }

                    if selectedCurrency != .cny {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("折合人民币")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "¥%.2f", convertedCNYAmount))
                                    .font(.system(.headline, design: .rounded).bold())
                                    .foregroundStyle(isIncome ? Color.green : Color.orange)
                            }

                            HStack(spacing: 8) {
                                Text("汇率 (1 \(selectedCurrency.rawValue) = )")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField(selectedCurrency.formatRateInput(), text: $exchangeRateString)
                                    .keyboardType(.decimalPad)
                                    .font(.caption.monospacedDigit().bold())
                                    .multilineTextAlignment(.trailing)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.small))
                                    .frame(minWidth: 68, idealWidth: 96, maxWidth: 96)
                                Text("CNY")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    syncOnlineExchangeRates()
                                } label: {
                                    HStack(spacing: 3) {
                                        if isSyncingOnlineRates {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                        }
                                        Text("实时汇率")
                                    }
                                    .font(.caption2.bold())
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(isSyncingOnlineRates)
                            }

                            HStack {
                                Text(selectedCurrency.rateDisplayString(rate: parsedExchangeRate))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if selectedCurrency.hasCustomRate() || abs(parsedExchangeRate - selectedCurrency.defaultRateToCNY) > 0.00001 {
                                    Button("恢复参考汇率") {
                                        selectedCurrency.resetRateToDefault()
                                        exchangeRateString = selectedCurrency.formatRateInput(selectedCurrency.defaultRateToCNY)
                                        rateStatusMessage = nil
                                        Haptic.light()
                                    }
                                    .font(.caption2)
                                }
                            }

                            if let rateStatusMessage {
                                Text(rateStatusMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                // 2. 分类与项目
                Section("分类与项目") {
                    Picker("分类", selection: $selectedCategory) {
                        ForEach(availableCategories, id: \.self) { cat in
                            Label(L10n.tr(cat.rawValue), systemImage: cat.icon).tag(cat)
                        }
                    }

                    TextField("备注说明（如：麦当劳、打车、工资）", text: $title)
                }

                // 2.5 关联收纳物品（计入该物品的日均持有成本）
                if !isIncome && !storedItems.isEmpty {
                    Section("关联收纳物品（可选）") {
                        Picker("计入物品投入", selection: $linkedItemID) {
                            Text("不关联").tag(UUID?.none)
                            ForEach(storedItems) { item in
                                Text(item.name).tag(UUID?.some(item.id))
                            }
                        }
                        if linkedItemID != nil {
                            Text("这笔支出将计入对应物品的累计投入，日均持有成本随之更新。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 3. 记账时间
                Section("记账时间") {
                    DatePicker("发生日期与时间", selection: $date)
                }

                if !isIncome {
                    Section("AA 分摊（可选）") {
                        TextField("参与人数", text: $splitCountString).keyboardType(.numberPad)
                        TextField("参与人姓名（可选，用逗号分隔）", text: $splitParticipants)
                        if let amount = Double(amountString), amount > 0, let count = Int(splitCountString), count > 1 {
                            HStack {
                                Text("每人应付")
                                Spacer()
                                Text(convertedCNYAmount / Double(count), format: .currency(code: "CNY")).fontWeight(.semibold)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section("原始单据（可选）") {
                        if let data = receiptImageData, let image = UIImage(data: data) {
                            HStack {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: AppRadius.chip))
                                Text("已附上小票，分享时可选择发送").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Button("移除", role: .destructive) { receiptImageData = nil; selectedReceiptItem = nil }
                                    .font(.caption)
                            }
                        }
                        PhotosPicker(selection: $selectedReceiptItem, matching: .images) {
                            Label(receiptImageData == nil ? "选择小票或原始单据" : "更换单据", systemImage: "photo")
                        }
                        .onChange(of: selectedReceiptItem) { _, item in
                            guard let item else { return }
                            Task {
                                if let data = try? await item.loadTransferable(type: Data.self) {
                                    await MainActor.run { receiptImageData = data }
                                }
                            }
                        }
                    }
                }

                // 4. 编辑模式下提供删除账目入口
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("删除这笔账目记录", systemImage: "trash")
                                    .foregroundStyle(AppColor.danger)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .onAppear {
                if let record = recordToEdit {
                    isIncome = record.isIncome
                    selectedCurrency = record.currency
                    let displayAmt = record.isForeignCurrency ? (record.foreignAmount ?? record.amount) : record.amount
                    if displayAmt.truncatingRemainder(dividingBy: 1) == 0 {
                        amountString = String(format: "%.0f", displayAmt)
                    } else {
                        amountString = String(format: "%.2f", displayAmt)
                    }
                    let rate = record.exchangeRateToCNY ?? record.currency.currentRateToCNY
                    exchangeRateString = record.currency.formatRateInput(rate)
                    selectedCategory = record.category
                    title = record.title
                    date = record.date
                    receiptImageData = record.receiptImageData
                    linkedItemID = record.linkedItemID
                    splitCountString = String(max(record.splitCount, 1))
                    splitParticipants = record.splitParticipants
                } else {
                    let pref = ExpenseCurrency.preferred()
                    selectedCurrency = pref
                    exchangeRateString = pref.formatRateInput()
                    if !isIncome {
                        selectedCategory = availableCategories.first ?? .food
                    }
                }
            }
            .navigationTitle(isEditing ? (isIncome ? "编辑收入" : "编辑支出") : (isIncome ? "记一笔收入" : "记一笔支出"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存修改" : "保存") {
                        saveRecord()
                    }
                    .disabled(convertedCNYAmount <= 0)
                }
            }
            .alert("确认删除账目", isPresented: $showingDeleteConfirm) {
                Button("确认删除", role: .destructive) {
                    deleteCurrentRecord()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后无法恢复，确认删除这笔账目明细吗？")
            }
        }
    }

    private func saveRecord() {
        let inputAmount = parsedInputAmount
        let cnyAmount = convertedCNYAmount
        guard inputAmount > 0, cnyAmount > 0 else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let isForeign = selectedCurrency != .cny
        let rate = parsedExchangeRate
        if isForeign {
            selectedCurrency.setCustomRateToCNY(rate)
        }

        if let record = recordToEdit {
            // 同步热量记录需要知道账单改动前的状态
            let oldTitle = record.title
            let wasFoodExpense = record.category == .food && !record.isIncome
            record.amount = cnyAmount
            record.isIncome = isIncome
            record.category = selectedCategory
            record.title = cleanTitle.isEmpty ? selectedCategory.rawValue : cleanTitle
            record.date = date
            record.currencyCode = isForeign ? selectedCurrency.rawValue : nil
            record.foreignAmount = isForeign ? inputAmount : nil
            record.exchangeRateToCNY = isForeign ? rate : nil
            record.receiptImageData = receiptImageData
            record.linkedItemID = linkedItemID
            record.splitCount = max(Int(splitCountString) ?? 1, 1)
            record.splitParticipants = splitParticipants.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
            ExpenseCalorieService.handleSaved(
                record,
                propose: record.title != oldTitle || !wasFoodExpense,
                context: context
            )
            ExpenseWaterService.handleSaved(record, context: context)
            Haptic.success()
        } else {
            let record = ExpenseRecord(
                amount: cnyAmount,
                isIncome: isIncome,
                category: selectedCategory,
                title: cleanTitle.isEmpty ? selectedCategory.rawValue : cleanTitle,
                date: date,
                currencyCode: isForeign ? selectedCurrency.rawValue : nil,
                foreignAmount: isForeign ? inputAmount : nil,
                exchangeRateToCNY: isForeign ? rate : nil
            )
            context.insert(record)
            record.receiptImageData = receiptImageData
            record.linkedItemID = linkedItemID
            record.splitCount = max(Int(splitCountString) ?? 1, 1)
            record.splitParticipants = splitParticipants.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
            ExpenseCalorieService.handleSaved(record, propose: true, context: context)
            ExpenseWaterService.handleSaved(record, context: context)
            Haptic.success()
        }
        dismiss()
    }

    private func syncOnlineExchangeRates() {
        isSyncingOnlineRates = true
        rateStatusMessage = nil
        Task {
            let ok = await ExpenseCurrency.refreshOnlineRates()
            await MainActor.run {
                isSyncingOnlineRates = false
                if ok {
                    exchangeRateString = selectedCurrency.formatRateInput()
                    rateStatusMessage = "已同步最新汇率"
                    Haptic.success()
                } else {
                    rateStatusMessage = "当前离线或网络受限，已使用本地汇率（支持手动调整）"
                    Haptic.warning()
                }
            }
        }
    }

    private func deleteCurrentRecord() {
        guard let record = recordToEdit else { return }
        ExpenseCalorieService.handleDeleted(expenseID: record.id, context: context)
        ExpenseWaterService.handleDeleted(expenseID: record.id, context: context)
        context.delete(record)
        try? context.save()
        Haptic.warning()
        dismiss()
    }
}

typealias ManualAddExpenseSheet = AddOrEditExpenseSheet

/// 账单分享：默认分享文字，可选择把已保存的原始小票一起发送。
private struct ExpenseShareView: View {
    @Environment(\.dismiss) private var dismiss
    let record: ExpenseRecord
    @State private var includeReceipt = false
    @State private var showSystemShareSheet = false
    @State private var shareItems: [Any] = []

    private var splitCount: Int { max(record.splitCount, 1) }
    private var shareText: String {
        let kind = record.isIncome ? "收入" : "支出"
        var lines = ["智能记账 · \(kind)", "项目：\(record.title)", "金额：¥\(String(format: "%.2f", record.amount))", "分类：\(record.category.rawValue)", "日期：\(record.date.formatted(date: .abbreviated, time: .shortened))"]
        if let foreignBadge = record.formattedForeignBadge {
            let rateText = record.exchangeRateToCNY.map { String(format: "（汇率 1 %@ = %.4f CNY）", record.currency.rawValue, $0) } ?? ""
            lines.insert("外币原额：\(foreignBadge)\(rateText)", at: 3)
        }
        if !record.isIncome && splitCount > 1 {
            lines.append("AA：\(splitCount) 人，每人 ¥\(String(format: "%.2f", record.amount / Double(splitCount)))")
            let participants = record.splitParticipants.trimmingCharacters(in: .whitespacesAndNewlines)
            if !participants.isEmpty {
                lines.append("参与人：\(participants)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("分享内容") {
                    Text(shareText).font(.subheadline).textSelection(.enabled)
                    if record.receiptImageData != nil {
                        Toggle("附上原始单据/小票", isOn: $includeReceipt)
                    } else {
                        Text("这笔账单没有保存原始单据").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ShareLink(item: shareText, preview: SharePreview("\(record.title) · ¥\(String(format: "%.2f", record.amount))")) {
                        Label("分享账单文字", systemImage: "doc.text")
                    }
                    if includeReceipt, let data = record.receiptImageData, let image = UIImage(data: data) {
                        Button {
                            // 由系统分享面板同时发送文字和原始图片。
                            shareItems = [shareText, image]
                            showSystemShareSheet = true
                        } label: {
                            Label("分享文字和原始单据", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }
            }
            .navigationTitle("分享账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $showSystemShareSheet, onDismiss: { shareItems = [] }) {
            ShareActivityView(activityItems: shareItems)
        }
    }
}
