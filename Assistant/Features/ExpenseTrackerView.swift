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

    init(records: [ExpenseRecord], calendar: Calendar = .current, now: Date = .now) {
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        var todayExp: Double = 0
        var monthExp: Double = 0
        var monthInc: Double = 0
        var categoryMap: [ExpenseCategory: Double] = [:]

        for record in records {
            let isToday = calendar.isDateInToday(record.date)
            let recYear = calendar.component(.year, from: record.date)
            let recMonth = calendar.component(.month, from: record.date)
            let isThisMonth = (recYear == currentYear && recMonth == currentMonth)

            if record.isIncome {
                if isThisMonth {
                    monthInc += record.amount
                }
            } else {
                if isToday {
                    todayExp += record.amount
                }
                if isThisMonth {
                    monthExp += record.amount
                    categoryMap[record.category, default: 0] += record.amount
                }
            }
        }

        self.todayExpenses = todayExp
        self.currentMonthExpenses = monthExp
        self.currentMonthIncome = monthInc

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
    @StateObject private var voice = VoiceDialogueService.shared
    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var quickInputText: String = ""
    @State private var showingManualAddSheet = false
    @State private var recordToEdit: ExpenseRecord? = nil
    @State private var feedbackBanner: String?
    @State private var isListeningQuickVoice = false
    @State private var showingReceiptScanner = false
    @State private var aiExpenseInsight: String? = nil
    @State private var isAnalyzingExpenses = false
    @State private var recordToShare: ExpenseRecord?

    private var calendar: Calendar { .current }

    // MARK: - 统计数据单次 O(N) 极速归集
    private var summary: ExpenseSummary {
        ExpenseSummary(records: records, calendar: calendar)
    }

    private var todayExpenses: Double { summary.todayExpenses }
    private var currentMonthExpenses: Double { summary.currentMonthExpenses }
    private var currentMonthIncome: Double { summary.currentMonthIncome }
    private var currentMonthCategoryBreakdown: [(category: ExpenseCategory, amount: Double, ratio: Double)] {
        summary.currentMonthCategoryBreakdown
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

    // 按日期分组记录
    private var groupedRecords: [(key: String, items: [ExpenseRecord])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

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
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                // 0. 今日安心花动态额度（设置了月预算后显示）
                SafeToSpendCard(records: records)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                // 1. 统计卡片与本月支出构成胶囊条
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            statCard(title: "今日支出", amount: todayExpenses, color: .orange)
                            statCard(title: "本月支出", amount: currentMonthExpenses, color: .red)
                            statCard(title: "本月收入", amount: currentMonthIncome, color: .green)
                        }

                        if !currentMonthCategoryBreakdown.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("本月支出构成")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if LLMModelManager.shared.isModelDownloaded || LLMModelManager.shared.hasValidLocalGGUFFile {
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
                                            .background(Capsule().fill(Color.purple.opacity(0.14)))
                                            .foregroundStyle(.purple)
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
                                            RoundedRectangle(cornerRadius: 3)
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
                                            .foregroundStyle(.purple)
                                            .padding(.top, 2)
                                        Text(L10n.tr(insight))
                                            .font(.caption)
                                            .foregroundStyle(.primary.opacity(0.88))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 2. 一句话极速记账输入栏
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("一句话记账（如：打车花了25.5元）", text: $quickInputText)
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
                                    .foregroundStyle(isListeningQuickVoice ? Color.red : Color.accentColor)
                                    .symbolEffect(.pulse, isActive: isListeningQuickVoice)
                            }
                            .buttonStyle(.plain)

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
                                .foregroundStyle(.red)
                        } else {
                            Text("💡 支持自然语言：麦当劳吃了38、交房租3200、发工资15000等")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("智能极速记账")
                }

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
            .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
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
                ExpenseShareView(record: record)
            }
            .sheet(isPresented: $showingReceiptScanner) {
                ReceiptScannerView { result, rawText, receiptData in
                    let record = ExpenseRecord(
                        amount: result.amount,
                        isIncome: result.isIncome,
                        category: result.category,
                        title: result.title,
                        rawText: rawText,
                        date: result.date
                    )
                    record.receiptImageData = receiptData
                    context.insert(record)
                    try? context.save()
                    showFeedback("已从小票记入 ¥\(String(format: "%.2f", result.amount))")
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
            .onChange(of: voice.isListening) { _, listening in
                if !listening && isListeningQuickVoice {
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - 一句话记账提交
    private func submitQuickText() {
        let text = quickInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let result = ExpenseNaturalLanguageParser.parse(text) {
            let record = ExpenseRecord(
                amount: result.amount,
                isIncome: result.isIncome,
                category: result.category,
                title: result.title,
                rawText: text,
                date: result.date
            )
            record.splitCount = max(result.splitCount, 1)
            record.splitParticipants = result.splitParticipants
            context.insert(record)
            try? context.save()
            Haptic.success()
            quickInputText = ""

            let amountStr = String(format: "%.2f", result.amount)
            let desc = result.isIncome ? "已记入入账 ¥\(amountStr)" : "已记入 ¥\(amountStr)（\(result.category.rawValue)）"
            showFeedback(desc)
        } else {
            Haptic.warning()
            showFeedback("未能识别出金额，请写明金额（如：吃午饭 25 元）")
        }
    }

    private func toggleQuickVoiceInput() {
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
                        try voice.startListening()
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

    private func analyzeExpensesWithAI() {
        isAnalyzingExpenses = true
        Haptic.light()
        let breakdownStr = currentMonthCategoryBreakdown
            .map { "\($0.category.rawValue) ¥\(String(format: "%.0f", $0.amount))（\(Int($0.ratio * 100))%）" }
            .joined(separator: "、")
        let userContent = "今日支出：¥\(String(format: "%.1f", todayExpenses))；本月总支出：¥\(String(format: "%.1f", currentMonthExpenses))；本月总收入：¥\(String(format: "%.1f", currentMonthIncome))；本月分类占比：\(breakdownStr)"
        let sys = "你是贴心的个人财务管家。请根据用户的本月消费结构，用 1 到 2 句温和、精炼的话给出消费结构点评与实用节流建议（80字以内，不要输出标题）。"
        Task {
            let output = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: sys,
                userContent: userContent,
                maxNewTokens: 150
            )
            await MainActor.run {
                isAnalyzingExpenses = false
                if let output, !output.isEmpty {
                    withAnimation {
                        aiExpenseInsight = output
                    }
                    Haptic.success()
                } else {
                    showFeedback("端侧 AI 模型尚未就绪")
                }
            }
        }
    }

    private func showFeedback(_ text: String) {
        withAnimation { feedbackBanner = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { feedbackBanner = nil }
        }
    }

    private func deleteRecord(_ item: ExpenseRecord) {
        context.delete(item)
        try? context.save()
        Haptic.medium()
        showFeedback("已删除 1 笔账目记录")
    }

    private func deleteRecords(offsets: IndexSet, from items: [ExpenseRecord]) {
        for index in offsets {
            let item = items[index]
            context.delete(item)
        }
        try? context.save()
    }
}

// MARK: - 今日安心花动态额度卡片

/// 「今日安心花（Safe-to-Spend）」：月预算扣除固定周期支出后，
/// 按距月底剩余天数均摊出今日可用额度；昨天花剩的钱自动滚入今天。
struct SafeToSpendCard: View {
    let records: [ExpenseRecord]
    @ObservedObject private var recurringManager = RecurringExpenseManager.shared
    @State private var showingBudgetSheet = false

    private var result: SafeToSpendResult? {
        let input = SafeToSpendCalculator.inputFromRecords(
            records: records,
            fixedMonthlyTotal: recurringManager.monthlyEstimatedTotal
        )
        let computed = SafeToSpendCalculator.compute(input: input)
        return computed.isEnabled ? computed : nil
    }

    /// 一次性 O(N) 归集安心花所需的账本快照（逻辑统一在 SafeToSpendCalculator.inputFromRecords）
    static func buildInput(records: [ExpenseRecord], fixedMonthlyTotal: Double) -> SafeToSpendInput {
        SafeToSpendCalculator.inputFromRecords(records: records, fixedMonthlyTotal: fixedMonthlyTotal)
    }

    var body: some View {
        if let result {
            Button {
                showingBudgetSheet = true
                Haptic.light()
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("今日安心花", systemImage: "shield.lefthalf.filled")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("距月底 \(result.daysLeft) 天")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if result.isOverBudget {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("本月弹性预算已超支 ¥\(String(format: "%.0f", -result.remainingThisMonth))，今天尽量少花")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("还可以安心花")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(String(format: "¥%.0f", result.safeToSpendToday))
                                .font(.system(.largeTitle, design: .rounded).bold())
                                .foregroundStyle(result.safeToSpendToday > 0 ? .green : .orange)
                                .contentTransition(.numericText())
                        }
                    }

                    // 弹性预算消耗进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(result.isOverBudget ? Color.red : Color.green)
                                .frame(width: min(1, result.spentRatio) * geo.size.width)
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 12) {
                        Text("月预算 ¥\(String(format: "%.0f", BudgetSettings.monthlyBudget))")
                        Text("固定支出 ¥\(String(format: "%.0f", recurringManager.monthlyEstimatedTotal))")
                        if result.savedYesterday >= 0.5 {
                            Text("昨日省下 ¥\(String(format: "%.0f", result.savedYesterday)) 已滚入 💰")
                                .foregroundStyle(.green)
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
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看或编辑月度预算")
            .sheet(isPresented: $showingBudgetSheet) {
                BudgetEditSheet()
            }
        }
    }
}

// MARK: - 月预算设置弹窗

struct BudgetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recurringManager = RecurringExpenseManager.shared
    @State private var budgetText: String = ""

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

                Section("自动扣除的固定支出（月均）") {
                    let active = recurringManager.items.filter { !$0.isPaused }
                    if active.isEmpty {
                        Text("暂无固定周期支出，可在「生活档案 → 固定支出」中添加房租、订阅等")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(active) { item in
                            HStack {
                                Text(item.title)
                                    .font(.subheadline)
                                Spacer()
                                Text("¥\(String(format: "%.0f", item.monthlyEquivalentAmount))\(item.cycle.displayUnit)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
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
        }
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
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(String(format: "%@¥%.2f", item.isIncome ? "+" : "-", item.amount))
                .font(.system(.body, design: .rounded).bold())
                .foregroundStyle(item.isIncome ? Color.green : Color.primary)

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
                        Text("¥")
                            .font(.title2.bold())
                            .foregroundStyle(isIncome ? Color.green : Color.red)
                        TextField("0.00", text: $amountString)
                            .keyboardType(.decimalPad)
                            .font(.system(.title2, design: .rounded).bold())
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
                                Text(amount / Double(count), format: .currency(code: "CNY")).fontWeight(.semibold)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section("原始单据（可选）") {
                        if let data = receiptImageData, let image = UIImage(data: data) {
                            HStack {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
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
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .onAppear {
                if let record = recordToEdit {
                    isIncome = record.isIncome
                    if record.amount.truncatingRemainder(dividingBy: 1) == 0 {
                        amountString = String(format: "%.0f", record.amount)
                    } else {
                        amountString = String(format: "%.2f", record.amount)
                    }
                    selectedCategory = record.category
                    title = record.title
                    date = record.date
                    receiptImageData = record.receiptImageData
                    linkedItemID = record.linkedItemID
                    splitCountString = String(max(record.splitCount, 1))
                    splitParticipants = record.splitParticipants
                } else {
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
                    .disabled((Double(amountString.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
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
        guard let amount = Double(amountString.trimmingCharacters(in: .whitespaces)), amount > 0 else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)

        if let record = recordToEdit {
            record.amount = amount
            record.isIncome = isIncome
            record.category = selectedCategory
            record.title = cleanTitle.isEmpty ? selectedCategory.rawValue : cleanTitle
            record.date = date
            record.receiptImageData = receiptImageData
            record.linkedItemID = linkedItemID
            record.splitCount = max(Int(splitCountString) ?? 1, 1)
            record.splitParticipants = splitParticipants.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
            Haptic.success()
        } else {
            let record = ExpenseRecord(
                amount: amount,
                isIncome: isIncome,
                category: selectedCategory,
                title: cleanTitle.isEmpty ? selectedCategory.rawValue : cleanTitle,
                date: date
            )
            context.insert(record)
            record.receiptImageData = receiptImageData
            record.linkedItemID = linkedItemID
            record.splitCount = max(Int(splitCountString) ?? 1, 1)
            record.splitParticipants = splitParticipants.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
            Haptic.success()
        }
        dismiss()
    }

    private func deleteCurrentRecord() {
        guard let record = recordToEdit else { return }
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

    private var splitCount: Int { max(record.splitCount, 1) }
    private var shareText: String {
        let kind = record.isIncome ? "收入" : "支出"
        var lines = ["智能记账 · \(kind)", "项目：\(record.title)", "金额：¥\(String(format: "%.2f", record.amount))", "分类：\(record.category.rawValue)", "日期：\(record.date.formatted(date: .abbreviated, time: .shortened))"]
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
                            presentShare(items: [shareText, image])
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
    }

    private func presentShare(items: [Any]) {
        // 将 UIKit 分享面板交给当前窗口层级，避免丢失图片附件。
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        root.present(controller, animated: true)
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: { $0.isKeyWindow }) }
}
