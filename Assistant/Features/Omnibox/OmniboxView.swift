import PhotosUI
import SwiftData
import SwiftUI

/// 投喂附件：带来源标记，相册重选时只替换相册部分，不会覆盖拖入/粘贴的图
struct OmniboxImageAttachment: Identifiable {
    let id = UUID()
    let image: UIImage
    /// 非 nil 表示来自 PhotosPicker
    var pickerItem: PhotosPickerItem?
}

/// 万能投喂口：文字粘贴 / 图片拖入选取 / 语音转写 → 单入口自动分流
struct OmniboxView: View {
    enum Phase: Equatable {
        case idle
        case planning
        case confirm
        case executed
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var clipboard = ClipboardIngestionService.shared
    @AppStorage(ClipboardIngestionService.autoIngestKey) private var autoIngest = true

    @State private var inputText = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachments: [OmniboxImageAttachment] = []
    @State private var phase: Phase = .idle
    @State private var actions: [PlannedAction] = []
    @State private var planEngine = "rules"
    @State private var outcomes: [ActionExecutionOutcome] = []
    @State private var errorMessage: String?
    @State private var lastCapture: OmniboxCapture?
    @State private var lastTransaction: OmniboxTransaction?
    @State private var showMemos = false
    @State private var showHistory = false

    private var images: [UIImage] { attachments.map(\.image) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    inputCard

                    switch phase {
                    case .idle:
                        emptyHint
                    case .planning:
                        planningCard
                    case .confirm:
                        confirmSection
                    case .executed:
                        receiptSection
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { dismissKeyboard() }
            .navigationTitle(L10n.tr("万能投喂口"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        showMemos = true
                    } label: {
                        Label(L10n.tr("收集箱"), systemImage: "tray.full")
                    }
                    Button {
                        showHistory = true
                    } label: {
                        Label(L10n.tr("历史"), systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.tr("关闭")) { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        dismissKeyboard()
                    } label: {
                        Label(L10n.tr("收起键盘"), systemImage: "keyboard.chevron.compact.down")
                            .font(.subheadline)
                    }
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            Task { await reloadPickerAttachments(items) }
        }
        .onAppear {
            consumePrefillIfPresent()
        }
        .sheet(isPresented: $showMemos) {
            OmniboxMemoListView()
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(isPresented: $showHistory) {
            OmniboxHistoryView()
                .environment(\.locale, LanguageManager.shared.locale)
        }
    }

    /// 消费路由预填充（剪贴板自动投喂 / 提示条「投喂」按钮带入），并自动跑拆解
    private func consumePrefillIfPresent() {
        guard let payload = router.omniboxPrefill else {
            // 手动打开时若剪贴板有内容，输入区会出现「一键粘贴」按钮，无需处理
            return
        }
        router.omniboxPrefill = nil
        apply(payload: payload)
        Task { await runPlan() }
    }

    private func apply(payload: OmniboxPayload) {
        switch payload {
        case .text(let text), .audioTranscript(let text):
            inputText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image(let data):
            if let image = UIImage(data: data) {
                appendManualImage(image)
            }
        }
    }

    private func appendManualImage(_ image: UIImage) {
        attachments = Array((attachments + [OmniboxImageAttachment(image: image)]).prefix(5))
    }

    // MARK: - 顶部说明

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.purple))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("万物皆可丢进来"))
                    .font(.headline)
                Text(L10n.tr("文字、短信、小票、订单截图——自动拆解成记账、待办和备忘"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    capabilityChip(icon: "yensign.circle.fill", label: L10n.tr("记账"), color: .green)
                    capabilityChip(icon: "checklist", label: L10n.tr("待办"), color: .blue)
                    capabilityChip(icon: "tray.full.fill", label: L10n.tr("收集箱"), color: .orange)
                    Spacer()
                }
                .padding(.top, 6)
                HStack(spacing: 4) {
                    Text(L10n.tr("自动投喂：检测到剪贴板新内容时自动打开"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: $autoIngest)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.62, anchor: .trailing)
                        .frame(width: 36, height: 22)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func capabilityChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2.bold())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - 投喂输入区

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .frame(minHeight: 72, maxHeight: 130)
                    .scrollContentBackground(.hidden)
                if inputText.isEmpty {
                    Text(L10n.tr("粘贴订单内容、随手记一句，或直接拖入截图…"))
                        .font(.subheadline)
                        .foregroundStyle(Color(.placeholderText))
                        .padding(.top, 8)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            Image(uiImage: attachment.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        if let pickerItem = attachment.pickerItem {
                                            pickerItems.removeAll { $0 == pickerItem }
                                        }
                                        attachments.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.body)
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 5, matching: .images) {
                    Label(L10n.tr("图片"), systemImage: "photo.on.rectangle")
                        .font(.subheadline)
                }
                if inputText.isEmpty && images.isEmpty && clipboard.hasIngestibleContent {
                    Button {
                        if let payload = clipboard.resolvePayload() {
                            apply(payload: payload)
                            Haptic.selection()
                        }
                    } label: {
                        Label(L10n.tr("一键粘贴"), systemImage: "doc.on.clipboard")
                            .font(.subheadline.bold())
                            .foregroundStyle(.purple)
                    }
                }
                Text(L10n.tr("支持把截图直接拖到本页"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                Task { await runPlan() }
            } label: {
                Label(L10n.tr("智能拆解"), systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(!canSubmit)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .dropDestination(for: Data.self) { payload, _ in
            let dropped = payload.compactMap(UIImage.init(data:))
            guard !dropped.isEmpty else { return false }
            for image in dropped {
                appendManualImage(image)
            }
            Haptic.selection()
            return true
        }
    }

    private var canSubmit: Bool {
        phase != .planning &&
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("示例：粘贴「买电饭煲 ¥599，3 天后预计收货，保修 1 年」→ 自动记一笔支出 + 建收货与保修提醒"))
            Text(L10n.tr("丢入扣款短信或订单截图，会自动提取商户、金额和交易时间，并按商户完成分类记账"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var planningCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(images.isEmpty ? L10n.tr("正在拆解内容…") : L10n.tr("正在识别图片文字并拆解…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 确认卡（可勾选可编辑，永不静默执行）

    private var confirmSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("拆解结果"))
                    .font(.headline)
                Text(planEngine == "llm" ? "AI" : L10n.tr("规则"))
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                    .foregroundStyle(.purple)
                Spacer()
                Button(L10n.tr("重新拆解")) {
                    Task { await runPlan(force: true) }
                }
                .font(.caption)
            }

            ForEach($actions) { $action in
                actionCard($action)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                executeSelected()
            } label: {
                Label(
                    L10n.tr("执行所选 %d 项".replacingOccurrences(of: "%d", with: "\(selectedCount)")),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(selectedCount == 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var selectedCount: Int { actions.filter(\.isSelected).count }

    private func actionCard(_ action: Binding<PlannedAction>) -> some View {
        let wrapped = action.wrappedValue
        let lowConfidence = wrapped.needsConfirmation

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: action.isSelected)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.72, anchor: .leading)
                    .frame(width: 46, height: 26)
                Image(systemName: wrapped.capability.systemImage)
                    .foregroundStyle(lowConfidence ? Color.orange : Color.purple)
                Text(wrapped.capability.displayName)
                    .font(.subheadline.bold())
                if lowConfidence {
                    Text(L10n.tr("待确认"))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            // 关键字段可直接编辑
            switch wrapped.capability {
            case .expenseCreate:
                HStack(spacing: 8) {
                    TextField(L10n.tr("金额"), text: numericBinding(action, key: "amount"))
                        .keyboardType(.decimalPad)
                        .frame(width: 84)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    Menu {
                        ForEach(ExpenseCategory.allCases, id: \.rawValue) { category in
                            Button(category.rawValue) {
                                action.wrappedValue.params["category"] = category.rawValue
                                action.wrappedValue.summary = OmniboxPlanner.summary(
                                    for: .expenseCreate, params: action.wrappedValue.params
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tag")
                            Text(action.wrappedValue.params["category"] ?? L10n.tr("分类"))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                TextField(L10n.tr("事项名"), text: textBinding(action, key: "title"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                DatePicker("", selection: dateBinding(action, key: "dateISO"), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(.caption)
            case .todoCreate:
                TextField(L10n.tr("待办标题"), text: textBinding(action, key: "title"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                DatePicker("", selection: dueDateBinding(action), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(.caption)
            case .memoInbox:
                TextField(L10n.tr("备忘内容"), text: textBinding(action, key: "memo"), axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(2...4)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(lowConfidence ? Color.orange.opacity(0.05) : Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(lowConfidence ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .opacity(action.isSelected.wrappedValue ? 1 : 0.55)
    }

    /// 编辑字段后同步刷新 summary 预览
    private func textBinding(_ action: Binding<PlannedAction>, key: String) -> Binding<String> {
        Binding(
            get: { action.wrappedValue.params[key] ?? "" },
            set: { newValue in
                action.wrappedValue.params[key] = newValue
                action.wrappedValue.summary = OmniboxPlanner.summary(
                    for: action.wrappedValue.capability, params: action.wrappedValue.params
                )
            }
        )
    }

    private func numericBinding(_ action: Binding<PlannedAction>, key: String) -> Binding<String> {
        Binding(
            get: { action.wrappedValue.params[key] ?? "" },
            set: { newValue in
                let digits = newValue.filter { "0123456789.".contains($0) }
                action.wrappedValue.params[key] = digits
                action.wrappedValue.summary = OmniboxPlanner.summary(
                    for: action.wrappedValue.capability, params: action.wrappedValue.params
                )
            }
        )
    }

    /// 通用日期编辑（记账交易时间 dateISO）
    private func dateBinding(_ action: Binding<PlannedAction>, key: String) -> Binding<Date> {
        Binding(
            get: { OmniboxPlanner.parseParamDate(action.wrappedValue.params[key]) ?? .now },
            set: { newDate in
                action.wrappedValue.params[key] = OmniboxPlanner.dateTimeFormatter.string(from: newDate)
                action.wrappedValue.summary = OmniboxPlanner.summary(
                    for: action.wrappedValue.capability, params: action.wrappedValue.params
                )
            }
        )
    }

    /// 待办截止时间编辑：统一写回 dueAtISO 并清掉相对时间参数（执行器优先读 dueAtISO）
    private func dueDateBinding(_ action: Binding<PlannedAction>) -> Binding<Date> {
        Binding(
            get: {
                OmniboxExecutor.resolveDueAt(params: action.wrappedValue.params)
                    ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)
                    ?? .now
            },
            set: { newDate in
                action.wrappedValue.params["dueAtISO"] = OmniboxPlanner.dateTimeFormatter.string(from: newDate)
                action.wrappedValue.params.removeValue(forKey: "dueAtDays")
                action.wrappedValue.params.removeValue(forKey: "dueAtTime")
                action.wrappedValue.summary = OmniboxPlanner.summary(
                    for: .todoCreate, params: action.wrappedValue.params
                )
            }
        )
    }

    // MARK: - 回执（事务 + 一键撤销）

    private var receiptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.tr("已完成"), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            ForEach(outcomes) { outcome in
                HStack(spacing: 10) {
                    Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.action.capability.displayName)
                            .font(.subheadline.bold())
                        Text(outcome.succeeded ? (outcome.summary ?? "") : (outcome.errorText ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    undoAll()
                } label: {
                    Label(L10n.tr("一键撤销"), systemImage: "arrow.uturn.backward")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button {
                    resetForNextFeed()
                } label: {
                    Label(L10n.tr("继续投喂"), systemImage: "plus")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 流程

    private func runPlan(force: Bool = false) async {
        guard canSubmit else { return }
        Haptic.selection()
        dismissKeyboard()
        phase = .planning
        errorMessage = nil
        if force { actions = [] }

        var payloads: [OmniboxPayload] = []
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { payloads.append(.text(text)) }
        for image in images {
            if let data = image.jpegData(compressionQuality: 0.85) {
                payloads.append(.image(data))
            }
        }
        let capture = OmniboxCapture(
            payloads: payloads,
            source: images.isEmpty ? .paste : .mixed
        )

        let plan = await OmniboxPlanner().plan(capture: capture)
        planEngine = plan.engine
        if plan.actions.isEmpty {
            // 纯图片但 OCR 颗粒无收时给出针对性提示
            let hasImages = !images.isEmpty
            errorMessage = (hasImages && plan.normalizedText.isEmpty)
                ? L10n.tr("图片里没认出文字，试试拍清楚一点，或手动输入金额和事项")
                : L10n.tr("没能从内容里拆出可执行动作，试试补充金额、时间或事项名")
            phase = .idle
            return
        }
        lastCapture = capture
        actions = plan.actions
        phase = .confirm
    }

    private func executeSelected() {
        let selected = actions.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        Haptic.success()
        dismissKeyboard()

        let executed = OmniboxExecutor.executeTopologically(selected, context: context)
        outcomes = executed

        // 落一条事务记录（含原始输入），便于追溯审计
        let transaction = OmniboxTransaction(
            capture: lastCapture ?? OmniboxCapture(source: images.isEmpty ? .paste : .mixed),
            actions: selected,
            engine: planEngine
        )
        transaction.status = .executed
        transaction.executedAt = .now
        // 撤销令牌持久化：跨启动后仍可在历史页撤销
        transaction.undoJSON = try? JSONEncoder().encode(executed.filter(\.succeeded).map(\.undo))
        context.insert(transaction)
        try? context.save()
        lastTransaction = transaction

        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        phase = .executed
    }

    private func undoAll() {
        do {
            try OmniboxExecutor.undo(outcomes, context: context)
            lastTransaction?.status = .undone
            try? context.save()
            WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
            resetForNextFeed()
        } catch {
            // 回执区也要能看到失败原因
            errorMessage = error.localizedDescription
        }
    }

    private func resetForNextFeed() {
        inputText = ""
        attachments = []
        pickerItems = []
        actions = []
        outcomes = []
        errorMessage = nil
        lastCapture = nil
        lastTransaction = nil
        phase = .idle
    }

    /// 只重建相册来源的附件，保留拖入/一键粘贴的手动图
    private func reloadPickerAttachments(_ items: [PhotosPickerItem]) async {
        var loaded: [OmniboxImageAttachment] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                loaded.append(OmniboxImageAttachment(image: image, pickerItem: item))
            }
        }
        attachments = Array((attachments.filter { $0.pickerItem == nil } + loaded).prefix(5))
    }
}

// MARK: - 键盘收起（数字小键盘没有回车键，必须主动 resign）

private extension View {
    func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
