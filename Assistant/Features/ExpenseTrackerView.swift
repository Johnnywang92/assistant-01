import SwiftData
import SwiftUI

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
                                            Text("\(item.category.rawValue) \(Int(item.ratio * 100))%")
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
                                        Text(insight)
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
                    HStack(spacing: 14) {
                        Button {
                            showingReceiptScanner = true
                        } label: {
                            Image(systemName: "doc.viewfinder")
                        }
                        .accessibilityLabel("拍小票记账")

                        Button {
                            showingManualAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                AddOrEditExpenseSheet(recordToEdit: nil)
            }
            .sheet(item: $recordToEdit) { record in
                AddOrEditExpenseSheet(recordToEdit: record)
            }
            .sheet(isPresented: $showingReceiptScanner) {
                ReceiptScannerView { result, rawText in
                    let record = ExpenseRecord(
                        amount: result.amount,
                        isIncome: result.isIncome,
                        category: result.category,
                        title: result.title,
                        rawText: rawText,
                        date: result.date
                    )
                    context.insert(record)
                    try? context.save()
                    showFeedback("已从小票记入 ¥\(String(format: "%.2f", result.amount))")
                }
            }
            .overlay(alignment: .bottom) {
                if let feedback = feedbackBanner {
                    Text(feedback)
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
    private func statCard(title: String, amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
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
                Text(item.title)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(item.category.rawValue)
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

    var recordToEdit: ExpenseRecord? = nil

    @State private var isIncome: Bool = false
    @State private var amountString: String = ""
    @State private var selectedCategory: ExpenseCategory = .food
    @State private var title: String = ""
    @State private var date: Date = .now
    @State private var showingDeleteConfirm = false

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
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }

                    TextField("备注说明（如：麦当劳、打车、工资）", text: $title)
                }

                // 3. 记账时间
                Section("记账时间") {
                    DatePicker("发生日期与时间", selection: $date)
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
