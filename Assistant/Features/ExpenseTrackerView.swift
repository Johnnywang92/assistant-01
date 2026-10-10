import SwiftData
import SwiftUI

/// 智能记账本主界面
struct ExpenseTrackerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExpenseRecord.date, order: .reverse) private var records: [ExpenseRecord]
    @StateObject private var voice = VoiceDialogueService.shared

    @State private var quickInputText: String = ""
    @State private var showingManualAddSheet = false
    @State private var feedbackBanner: String?
    @State private var isListeningQuickVoice = false

    private var calendar: Calendar { .current }

    // MARK: - 统计数据
    private var todayExpenses: Double {
        records
            .filter { !$0.isIncome && calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.amount }
    }

    private var currentMonthExpenses: Double {
        let now = Date.now
        let m = calendar.component(.month, from: now)
        let y = calendar.component(.year, from: now)
        return records
            .filter { !$0.isIncome && calendar.component(.month, from: $0.date) == m && calendar.component(.year, from: $0.date) == y }
            .reduce(0) { $0 + $1.amount }
    }

    private var currentMonthIncome: Double {
        let now = Date.now
        let m = calendar.component(.month, from: now)
        let y = calendar.component(.year, from: now)
        return records
            .filter { $0.isIncome && calendar.component(.month, from: $0.date) == m && calendar.component(.year, from: $0.date) == y }
            .reduce(0) { $0 + $1.amount }
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
                // 1. 统计卡片
                Section {
                    HStack(spacing: 16) {
                        statCard(title: "今日支出", amount: todayExpenses, color: .orange)
                        statCard(title: "本月支出", amount: currentMonthExpenses, color: .red)
                        statCard(title: "本月收入", amount: currentMonthIncome, color: .green)
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
                                ExpenseRow(item: item)
                            }
                            .onDelete { offsets in
                                deleteRecords(offsets: offsets, from: group.items)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("智能记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingManualAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                ManualAddExpenseSheet()
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

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            quickInputText = ""

            let amountStr = String(format: "%.2f", result.amount)
            let desc = result.isIncome ? "已记入入账 ¥\(amountStr)" : "已记入 ¥\(amountStr)（\(result.category.rawValue)）"
            showFeedback(desc)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showFeedback("未能识别出金额，请写明金额（如：吃午饭 25 元）")
        }
    }

    private func toggleQuickVoiceInput() {
        if isListeningQuickVoice {
            voice.stopListening()
            isListeningQuickVoice = false
        } else {
            Task {
                let granted = await voice.requestPermissions()
                if granted {
                    isListeningQuickVoice = true
                    try? voice.startListening()
                } else {
                    showFeedback("请开启麦克风与语音识别权限")
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
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 手动记账备用弹窗

struct ManualAddExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var isIncome: Bool = false
    @State private var amountString: String = ""
    @State private var selectedCategory: ExpenseCategory = .food
    @State private var title: String = ""
    @State private var date: Date = .now

    var body: some View {
        NavigationStack {
            Form {
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
                            selectedCategory = .food
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

                Section("分类与项目") {
                    Picker("消费分类", selection: $selectedCategory) {
                        ForEach(ExpenseCategory.allCases.filter { isIncome ? $0.isIncome : !$0.isIncome }, id: \.self) { cat in
                            Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                        }
                    }

                    TextField("备注说明（如：聚餐、打车）", text: $title)
                }

                Section("记账时间") {
                    DatePicker("发生日期", selection: $date)
                }
            }
            .navigationTitle(isIncome ? "记一笔收入" : "记一笔支出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveManualRecord() }
                        .disabled((Double(amountString) ?? 0) <= 0)
                }
            }
        }
    }

    private func saveManualRecord() {
        guard let amount = Double(amountString), amount > 0 else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let record = ExpenseRecord(
            amount: amount,
            isIncome: isIncome,
            category: selectedCategory,
            title: cleanTitle.isEmpty ? selectedCategory.rawValue : cleanTitle,
            date: date
        )
        context.insert(record)
        try? context.save()
        dismiss()
    }
}
