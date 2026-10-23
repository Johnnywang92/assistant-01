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
    @AppStorage("omnibox_clipboard_auto_dismiss_seconds") private var clipboardAutoDismissSeconds: Int = 3
    @AppStorage("omnibox_auto_dismiss_seconds") private var autoDismissSeconds: Int = 3

    @State private var inputText = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachments: [OmniboxImageAttachment] = []
    @State private var phase: Phase = .idle
    @State private var actions: [PlannedAction] = []
    @State private var planEngine = "rules"
    @State private var planFallbackReason: String?
    /// 意图判别把握不足：确认卡顶部给出可读提示，避免把不确定当确定写库。
    @State private var planNeedsClarification = false
    /// 意图分布的可读摘要（如「记账 78%（次选 新建待办 12%）」）。
    @State private var planIntentReason: String?
    @State private var outcomes: [ActionExecutionOutcome] = []
    @State private var errorMessage: String?
    @State private var lastCapture: OmniboxCapture?
    @State private var lastTransaction: OmniboxTransaction?
    @State private var showMemos = false
    @State private var showHistory = false
    @State private var remainingSeconds: Int = 3
    @State private var isCountdownPaused: Bool = false
    @State private var countdownTask: Task<Void, Never>?
    @State private var isClipboardAutoTriggered: Bool = false
    @State private var clipboardRemainingSeconds: Int = 3
    @State private var isClipboardDismissPaused: Bool = false
    @State private var clipboardDismissTask: Task<Void, Never>?

    private var images: [UIImage] { attachments.map(\.image) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isClipboardAutoTriggered && clipboardAutoDismissSeconds > 0 && phase != .executed {
                        clipboardAutoDismissBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

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
            .simultaneousGesture(
                TapGesture().onEnded {
                    if isClipboardAutoTriggered {
                        cancelClipboardDismiss()
                    }
                }
            )
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    if isClipboardAutoTriggered {
                        cancelClipboardDismiss()
                    }
                }
            )
            .onTapGesture {
                dismissKeyboard()
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
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
                    Button(closeButtonTitle) {
                        cancelCountdown()
                        cancelClipboardDismiss()
                        dismiss()
                    }
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
        .onChange(of: inputText) { oldValue, newValue in
            if isClipboardAutoTriggered && !oldValue.isEmpty && oldValue != newValue {
                cancelClipboardDismiss()
            }
        }
        .onChange(of: pickerItems) { _, items in
            if isClipboardAutoTriggered {
                cancelClipboardDismiss()
            }
            Task { await reloadPickerAttachments(items) }
        }
        .onAppear {
            consumePrefillIfPresent()
        }
        .onDisappear {
            cancelCountdown()
            cancelClipboardDismiss()
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

    private var closeButtonTitle: String {
        if isClipboardAutoTriggered && clipboardAutoDismissSeconds > 0 && phase != .executed {
            if isClipboardDismissPaused {
                return "\(L10n.tr("关闭")) (\(L10n.tr("已暂停")))"
            } else if clipboardRemainingSeconds > 0 {
                return "\(L10n.tr("关闭")) (\(clipboardRemainingSeconds)s)"
            }
        } else if phase == .executed && autoDismissSeconds > 0 {
            if isCountdownPaused {
                return "\(L10n.tr("关闭")) (\(L10n.tr("已暂停")))"
            } else if remainingSeconds > 0 {
                return "\(L10n.tr("关闭")) (\(remainingSeconds)s)"
            }
        }
        return L10n.tr("关闭")
    }

    /// 消费路由预填充（剪贴板自动投喂 / 提示条「投喂」按钮带入），并自动跑拆解
    private func consumePrefillIfPresent() {
        guard let payload = router.omniboxPrefill else {
            // 手动打开时若剪贴板有内容，输入区会出现「一键粘贴」按钮，无需处理
            return
        }
        router.omniboxPrefill = nil
        isClipboardAutoTriggered = router.omniboxIsClipboardAutoIngest
        router.omniboxIsClipboardAutoIngest = false
        apply(payload: payload)
        Task { await runPlan() }
        if isClipboardAutoTriggered {
            startClipboardDismissCountdown()
        }
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
                        cancelClipboardDismiss()
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
                cancelClipboardDismiss()
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
        .simultaneousGesture(
            TapGesture().onEnded {
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
        )
        .dropDestination(for: Data.self) { payload, _ in
            cancelClipboardDismiss()
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
        .simultaneousGesture(
            TapGesture().onEnded {
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
        )
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
                    cancelClipboardDismiss()
                    Task { await runPlan(force: true) }
                }
                .font(.caption)
            }

            // 降级原因对用户可见：保证「LLM 失败回落规则」不是静默发生的（原因细节同时进控制台日志）
            if planEngine == "rules", let reason = planFallbackReason {
                Text(L10n.tr("模型输出解析失败，已降级本机规则引擎：") + reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 意图把握度：模型分不清时明说，而不是照样给用户一个看着很确定的错误动作。
            // 这是判别层相对生成式路径最实际的用户可感知收益。
            if planNeedsClarification, let text = planIntentReason {
                Text(L10n.tr("不太确定你要做什么（\(text)），请核对下方参数后再执行。"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            ForEach(actions) { action in
                actionCard(actionBinding(for: action))
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
        .simultaneousGesture(
            TapGesture().onEnded {
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
        )
    }

    private var selectedCount: Int { actions.filter(\.isSelected).count }

    /// 按 ID 安全索引动作 Binding：避免 `actions` 清空或重算过渡帧中，
    /// UIKit `UISwitch` / `TextField` 持有的旧下标 Binding 触发 Array 越界断言闪退。
    private func actionBinding(for fallback: PlannedAction) -> Binding<PlannedAction> {
        Binding(
            get: {
                actions.first(where: { $0.id == fallback.id }) ?? fallback
            },
            set: { updated in
                guard let idx = actions.firstIndex(where: { $0.id == fallback.id }) else { return }
                actions[idx] = updated
            }
        )
    }

    private func actionCard(_ action: Binding<PlannedAction>) -> some View {
        let wrapped = action.wrappedValue
        let lowConfidence = wrapped.needsConfirmation

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { action.isSelected.wrappedValue },
                    set: {
                        cancelClipboardDismiss()
                        action.isSelected.wrappedValue = $0
                    }
                ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.72, anchor: .leading)
                    .frame(width: 46, height: 26)

                // 一键自由切换动作类型（记账/待办/收集箱互转）
                Menu {
                    ForEach(OmniboxCapability.allCases, id: \.self) { cap in
                        Button {
                            switchCapability(action: action, to: cap)
                        } label: {
                            Label(cap.displayName, systemImage: cap.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: wrapped.capability.systemImage)
                            .foregroundStyle(lowConfidence ? Color.orange : Color.purple)
                        Text(wrapped.capability.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }

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

            if lowConfidence {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption2)
                    Text(wrapped.confidenceReason ?? L10n.tr("识别置信度较低，点击上方类型可一键切换或微调内容"))
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 2)
            }

            // 关键字段可直接编辑
            switch wrapped.capability {
            case .expenseCreate:
                let selectedCurrency = ExpenseCurrency(rawValue: action.wrappedValue.params["currency"] ?? "CNY") ?? .cny
                HStack(spacing: 8) {
                    Menu {
                        ForEach(ExpenseCurrency.allCases) { cur in
                            Button(cur.pickerLabel) {
                                switchExpenseCurrency(action: action, to: cur)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(selectedCurrency.flag)
                            Text(selectedCurrency.symbol)
                                .font(.caption.bold())
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    }

                    TextField(L10n.tr("金额"), text: expenseAmountBinding(action, currency: selectedCurrency))
                        .keyboardType(.decimalPad)
                        .frame(width: 84)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))

                    if selectedCurrency != .cny {
                        Text("≈ ¥\(action.wrappedValue.params["amount"] ?? "0.00")")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

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
            case .todoUpdate:
                TextField(L10n.tr("原待办（匹配目标）"), text: textBinding(action, key: "target"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                TextField(L10n.tr("修改后标题（可选）"), text: textBinding(action, key: "newTitle"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            case .todoComplete, .todoCancel:
                TextField(L10n.tr("待办事项目标"), text: textBinding(action, key: "target"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            case .reminderSnooze:
                HStack(spacing: 8) {
                    TextField(L10n.tr("提醒事项"), text: textBinding(action, key: "target"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    TextField(L10n.tr("顺延时长"), text: textBinding(action, key: "duration"))
                        .font(.caption)
                        .frame(width: 80)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                }
            case .expenseUpdate:
                HStack(spacing: 8) {
                    TextField(L10n.tr("修改后金额"), text: numericBinding(action, key: "newAmount"))
                        .keyboardType(.decimalPad)
                        .frame(width: 90)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    TextField(L10n.tr("账目匹配目标"), text: textBinding(action, key: "target"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                }
            case .queryLookup:
                TextField(L10n.tr("查询关键词"), text: textBinding(action, key: "target"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            case .memoInbox:
                TextField(L10n.tr("备忘内容"), text: textBinding(action, key: "memo"), axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(2...4)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            case .foodRecord:
                HStack(spacing: 8) {
                    if let base64 = action.wrappedValue.params["imageDataBase64"],
                       let data = Data(base64Encoded: base64),
                       let uiImg = UIImage(data: data) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    TextField(L10n.tr("食物名称"), text: textBinding(action, key: "foodName"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    TextField(L10n.tr("千卡"), text: numericBinding(action, key: "calories"))
                        .keyboardType(.numberPad)
                        .frame(width: 70)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    Menu {
                        ForEach(["早餐", "午餐", "晚餐", "加餐"], id: \.self) { slot in
                            Button(slot) {
                                action.wrappedValue.params["mealSlot"] = slot
                                action.wrappedValue.summary = OmniboxPlanner.summary(
                                    for: .foodRecord, params: action.wrappedValue.params
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(action.wrappedValue.params["mealSlot"] ?? "餐次")
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
                DatePicker("", selection: dateBinding(action, key: "dateISO"), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(.caption)
            case .waterRecord:
                HStack(spacing: 8) {
                    TextField(L10n.tr("饮品名称"), text: textBinding(action, key: "customName"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    TextField(L10n.tr("毫升"), text: numericBinding(action, key: "volumeML"))
                        .keyboardType(.numberPad)
                        .frame(width: 70)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    Menu {
                        ForEach(["白开水", "黑咖啡", "拿铁", "纯茶", "牛奶", "奶茶", "含糖饮料", "苏打水"], id: \.self) { bev in
                            Button(bev) {
                                action.wrappedValue.params["beverageType"] = bev
                                action.wrappedValue.summary = OmniboxPlanner.summary(
                                    for: .waterRecord, params: action.wrappedValue.params
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(action.wrappedValue.params["beverageType"] ?? "种类")
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
            case .storageRecord:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(L10n.tr("物品名称"), text: textBinding(action, key: "name"))
                            .font(.subheadline)
                            .padding(6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                        Menu {
                            ForEach(["主卧", "次卧", "客厅", "书房", "玄关", "厨房", "阳台", "储物间"], id: \.self) { room in
                                Button(room) {
                                    action.wrappedValue.params["roomArea"] = room
                                    action.wrappedValue.summary = OmniboxPlanner.summary(
                                        for: .storageRecord, params: action.wrappedValue.params
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "door.left.hand.closed")
                                Text(action.wrappedValue.params["roomArea"] ?? "房间")
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
                    TextField(L10n.tr("详细存放位置（如抽屉、顶层收纳盒）"), text: textBinding(action, key: "location"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                }
            case .habitLog:
                HStack(spacing: 8) {
                    TextField(L10n.tr("打卡目标（如晨跑、降压药）"), text: textBinding(action, key: "target"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    Menu {
                        Button("习惯打卡") {
                            action.wrappedValue.params["kind"] = "habit"
                            action.wrappedValue.summary = OmniboxPlanner.summary(
                                for: .habitLog, params: action.wrappedValue.params
                            )
                        }
                        Button("服药打卡") {
                            action.wrappedValue.params["kind"] = "medication"
                            action.wrappedValue.summary = OmniboxPlanner.summary(
                                for: .habitLog, params: action.wrappedValue.params
                            )
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(action.wrappedValue.params["kind"] == "medication" ? "服药" : "习惯")
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            case .anniversaryCreate:
                HStack(spacing: 8) {
                    TextField(L10n.tr("名称（如结婚纪念日、妈妈生日）"), text: textBinding(action, key: "title"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    Menu {
                        ForEach(["纪念日", "生日", "倒数日", "订阅续费", "保质期"], id: \.self) { cat in
                            Button(cat) {
                                action.wrappedValue.params["category"] = cat
                                action.wrappedValue.summary = OmniboxPlanner.summary(
                                    for: .anniversaryCreate, params: action.wrappedValue.params
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(action.wrappedValue.params["category"] ?? "类型")
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            case .departureAdd:
                HStack(spacing: 8) {
                    TextField(L10n.tr("随身物品（如雨伞、工卡）"), text: textBinding(action, key: "title"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    Menu {
                        ForEach(["工作通勤", "运动健身", "出差旅行", "带娃出行", "遛狗随行", "雨雪出行"], id: \.self) { sc in
                            Button(sc) {
                                action.wrappedValue.params["scene"] = sc
                                action.wrappedValue.summary = OmniboxPlanner.summary(
                                    for: .departureAdd, params: action.wrappedValue.params
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(action.wrappedValue.params["scene"] ?? "场景")
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            case .lifeRecord:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(L10n.tr("事项名称"), text: textBinding(action, key: "title"))
                            .font(.subheadline)
                            .padding(6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                        Menu {
                            ForEach([
                                ("pet", "宠物"), ("vehicle", "爱车"), ("child", "育儿"),
                                ("skill", "技能"), ("document", "证件"), ("event", "大事")
                            ], id: \.0) { item in
                                Button(item.1) {
                                    action.wrappedValue.params["domain"] = item.0
                                    action.wrappedValue.summary = OmniboxPlanner.summary(
                                        for: .lifeRecord, params: action.wrappedValue.params
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                let dom = action.wrappedValue.params["domain"] ?? "pet"
                                let label: String = switch dom {
                                case "pet": "宠物"
                                case "vehicle": "爱车"
                                case "child": "育儿"
                                case "skill": "技能"
                                case "document": "证件"
                                case "event": "大事"
                                default: "档案"
                                }
                                Text(label)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    TextField(L10n.tr("详情或数值（如完成驱虫、当前里程、练习45分钟）"), text: textBinding(action, key: "detail"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                }
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

    /// 一键切换动作类型时的平滑兜底迁移
    private func switchCapability(action: Binding<PlannedAction>, to newCap: OmniboxCapability) {
        cancelClipboardDismiss()
        guard action.wrappedValue.capability != newCap else { return }
        var currentParams = action.wrappedValue.params
        switch newCap {
        case .expenseCreate:
            if (currentParams["amount"] ?? "").isEmpty {
                let source = currentParams["memo"] ?? currentParams["title"] ?? ""
                if let extracted = OmniboxPlanner.extractLooseAmount(from: source) {
                    currentParams["amount"] = String(format: "%.2f", extracted)
                } else {
                    currentParams["amount"] = "0.00"
                }
            }
            if (currentParams["title"] ?? "").isEmpty {
                currentParams["title"] = currentParams["memo"] ?? L10n.tr("待记账事项")
            }
            if currentParams["category"] == nil {
                currentParams["category"] = ExpenseCategory.shopping.rawValue
            }
        case .todoCreate:
            if (currentParams["title"] ?? "").isEmpty {
                let memo = currentParams["memo"] ?? currentParams["title"] ?? ""
                currentParams["title"] = memo.isEmpty ? L10n.tr("新建待办") : String(memo.prefix(20))
            }
        case .memoInbox:
            if (currentParams["memo"] ?? "").isEmpty {
                let title = currentParams["title"] ?? ""
                let amt = currentParams["amount"] ?? ""
                currentParams["memo"] = amt.isEmpty ? title : "\(title) ¥\(amt)"
            }
        case .expenseUpdate, .todoUpdate, .todoComplete, .todoCancel, .reminderSnooze, .queryLookup:
            if (currentParams["target"] ?? "").isEmpty {
                let source = currentParams["memo"] ?? currentParams["title"] ?? ""
                currentParams["target"] = source
            }
        case .foodRecord:
            if (currentParams["foodName"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["target"] ?? ""
                currentParams["foodName"] = name.isEmpty ? "食物" : name
            }
            if currentParams["mealSlot"] == nil {
                currentParams["mealSlot"] = "加餐"
            }
            if (currentParams["calories"] ?? "").isEmpty {
                if let estimate = FoodCalorieEstimator.estimateMeal(fromHint: currentParams["foodName"] ?? "") {
                    currentParams["calories"] = "\(Int(estimate.fullPortionCalories))"
                }
            }
        case .waterRecord:
            if (currentParams["customName"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["foodName"] ?? "白开水"
                currentParams["customName"] = name
            }
            if currentParams["volumeML"] == nil {
                currentParams["volumeML"] = "300"
            }
            if currentParams["beverageType"] == nil {
                currentParams["beverageType"] = "白开水"
            }
        case .storageRecord:
            if (currentParams["name"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["target"] ?? "物品"
                currentParams["name"] = name
            }
            if (currentParams["location"] ?? "").isEmpty {
                currentParams["location"] = "主卧抽屉"
            }
            if currentParams["roomArea"] == nil {
                currentParams["roomArea"] = "主卧"
            }
        case .habitLog:
            if (currentParams["target"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["target"] ?? "打卡项"
                currentParams["target"] = name
            }
            if currentParams["kind"] == nil {
                currentParams["kind"] = "habit"
            }
        case .anniversaryCreate:
            if (currentParams["title"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["target"] ?? "重要日子"
                currentParams["title"] = name
            }
            if currentParams["category"] == nil {
                currentParams["category"] = "纪念日"
            }
        case .departureAdd:
            if (currentParams["title"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["target"] ?? "随身物品"
                currentParams["title"] = name
            }
            if currentParams["scene"] == nil {
                currentParams["scene"] = "工作通勤"
            }
        case .lifeRecord:
            if (currentParams["title"] ?? "").isEmpty {
                let name = currentParams["title"] ?? currentParams["memo"] ?? currentParams["target"] ?? "生活记录"
                currentParams["title"] = name
            }
            if currentParams["domain"] == nil {
                currentParams["domain"] = "pet"
            }
        }
        action.wrappedValue.capability = newCap
        action.wrappedValue.params = currentParams
        action.wrappedValue.summary = OmniboxPlanner.summary(for: newCap, params: currentParams)
        Haptic.selection()
    }

    /// 编辑字段后同步刷新 summary 预览
    private func textBinding(_ action: Binding<PlannedAction>, key: String) -> Binding<String> {
        Binding(
            get: { action.wrappedValue.params[key] ?? "" },
            set: { newValue in
                cancelClipboardDismiss()
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
                cancelClipboardDismiss()
                let digits = newValue.filter { "0123456789.".contains($0) }
                action.wrappedValue.params[key] = digits
                action.wrappedValue.summary = OmniboxPlanner.summary(
                    for: action.wrappedValue.capability, params: action.wrappedValue.params
                )
            }
        )
    }

    /// 记账卡片金额绑定：支持外币原币编辑并实时折算为人民币
    private func expenseAmountBinding(_ action: Binding<PlannedAction>, currency: ExpenseCurrency) -> Binding<String> {
        Binding(
            get: {
                if currency == .cny {
                    return action.wrappedValue.params["amount"] ?? ""
                }
                return action.wrappedValue.params["foreignAmount"] ?? action.wrappedValue.params["amount"] ?? ""
            },
            set: { newValue in
                cancelClipboardDismiss()
                let digits = newValue.filter { "0123456789.".contains($0) }
                if currency == .cny {
                    action.wrappedValue.params["amount"] = digits
                } else {
                    action.wrappedValue.params["foreignAmount"] = digits
                    let rate = Double(action.wrappedValue.params["exchangeRate"] ?? "") ?? currency.currentRateToCNY
                    let foreignVal = Double(digits) ?? 0
                    let cnyVal = currency.convertToCNY(foreignVal, rate: rate)
                    action.wrappedValue.params["amount"] = String(format: "%.2f", cnyVal)
                }
                action.wrappedValue.summary = OmniboxPlanner.summary(
                    for: .expenseCreate, params: action.wrappedValue.params
                )
            }
        )
    }

    private func switchExpenseCurrency(action: Binding<PlannedAction>, to newCurrency: ExpenseCurrency) {
        cancelClipboardDismiss()
        let currentForeign = Double(action.wrappedValue.params["foreignAmount"] ?? "")
        let currentCNY = Double(action.wrappedValue.params["amount"] ?? "") ?? 0
        let baseNumber = (currentForeign ?? 0) > 0 ? (currentForeign ?? 0) : currentCNY

        if newCurrency == .cny {
            action.wrappedValue.params.removeValue(forKey: "currency")
            action.wrappedValue.params.removeValue(forKey: "foreignAmount")
            action.wrappedValue.params.removeValue(forKey: "exchangeRate")
            action.wrappedValue.params["amount"] = String(format: "%.2f", baseNumber)
        } else {
            let rate = newCurrency.currentRateToCNY
            let cny = newCurrency.convertToCNY(baseNumber, rate: rate)
            action.wrappedValue.params["currency"] = newCurrency.rawValue
            action.wrappedValue.params["foreignAmount"] = baseNumber.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", baseNumber)
                : String(format: "%.2f", baseNumber)
            action.wrappedValue.params["exchangeRate"] = String(format: "%.6f", rate)
            action.wrappedValue.params["amount"] = String(format: "%.2f", cny)
        }
        action.wrappedValue.summary = OmniboxPlanner.summary(
            for: .expenseCreate, params: action.wrappedValue.params
        )
        Haptic.selection()
    }

    /// 通用日期编辑（记账交易时间 dateISO）
    private func dateBinding(_ action: Binding<PlannedAction>, key: String) -> Binding<Date> {
        Binding(
            get: { OmniboxPlanner.parseParamDate(action.wrappedValue.params[key]) ?? .now },
            set: { newDate in
                cancelClipboardDismiss()
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
                cancelClipboardDismiss()
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
            HStack {
                Label(L10n.tr("已完成"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Spacer()

                if autoDismissSeconds > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: isCountdownPaused ? "pause.circle.fill" : "timer")
                            .font(.caption2)
                        Text(isCountdownPaused
                             ? L10n.tr("倒计时已暂停")
                             : "\(remainingSeconds)s \(L10n.tr("后自动关闭"))")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(isCountdownPaused ? Color.orange : Color.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isCountdownPaused ? Color.orange.opacity(0.12) : Color.purple.opacity(0.1))
                    )
                }
            }

            if autoDismissSeconds > 0 {
                HStack(spacing: 8) {
                    Image(systemName: isCountdownPaused ? "pause.fill" : "hourglass")
                        .font(.caption)
                        .foregroundStyle(isCountdownPaused ? Color.orange : Color.purple)
                    Text(isCountdownPaused
                         ? L10n.tr("倒计时已暂停，您可以仔细核对结果或一键撤销")
                         : String(format: L10n.tr("弹窗将在 %d 秒后自动关闭"), remainingSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if isCountdownPaused {
                            resumeCountdown()
                        } else {
                            pauseCountdown()
                        }
                    } label: {
                        Text(isCountdownPaused ? L10n.tr("恢复倒计时") : L10n.tr("暂停关闭"))
                            .font(.caption.bold())
                            .foregroundStyle(.purple)
                    }
                }
                .padding(10)
                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

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
        .simultaneousGesture(
            TapGesture().onEnded {
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
        )
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
        planFallbackReason = plan.fallbackReason
        planNeedsClarification = plan.needsClarification
        planIntentReason = plan.intentDistribution?.reasonText
        if plan.actions.isEmpty {
            // 纯图片但 OCR 与食物视觉识别均无结果时给出针对性提示
            let hasImages = !images.isEmpty
            errorMessage = (hasImages && plan.normalizedText.isEmpty)
                ? L10n.tr("图片里没认出文字或食物，试试拍清楚一点，或手动输入菜名/金额")
                : L10n.tr("没能从内容里拆出可执行动作，试试补充金额、时间或事项名")
            phase = .idle
            return
        }
        lastCapture = capture
        actions = plan.actions
        phase = .confirm
    }

    private func executeSelected() {
        cancelCountdown()
        cancelClipboardDismiss()
        let selected = actions.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        Haptic.success()
        dismissKeyboard()

        let executed = OmniboxExecutor.executeTopologically(selected, context: context)
        outcomes = executed

        // 落一条事务记录（含原始输入），便于追诉审计
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
        startCountdownIfNeeded()
    }

    private func undoAll() {
        cancelCountdown()
        cancelClipboardDismiss()
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
        cancelCountdown()
        cancelClipboardDismiss()
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

    // MARK: - 剪贴板自动唤起倒计时横幅与控制

    private var clipboardAutoDismissBanner: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.title3)
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.tr("已识别剪贴板内容"))
                            .font(.headline.bold())
                            .foregroundStyle(.primary)

                        Spacer()

                        // 显著加大的粗体倒计时药丸徽章
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.caption.bold())
                            Text("\(clipboardRemainingSeconds)s \(L10n.tr("后自动退出"))")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color.purple, Color.indigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                        .shadow(color: Color.purple.opacity(0.3), radius: 3, x: 0, y: 1.5)
                    }

                    Text(L10n.tr("无操作将自动关闭；轻点页面或查看即保留"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // 醒目操作按钮
            HStack(spacing: 10) {
                Button {
                    cancelClipboardDismiss()
                    Haptic.light()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                        Text(L10n.tr("查看并保留内容"))
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Button(role: .cancel) {
                    cancelClipboardDismiss()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                        Text(L10n.tr("立即关闭"))
                    }
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.purple.opacity(0.12), radius: 8, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            cancelClipboardDismiss()
            Haptic.light()
        }
    }

    private func startClipboardDismissCountdown() {
        cancelClipboardDismiss()
        guard clipboardAutoDismissSeconds > 0 else { return }
        isClipboardAutoTriggered = true
        clipboardRemainingSeconds = clipboardAutoDismissSeconds
        isClipboardDismissPaused = false
        clipboardDismissTask = Task { @MainActor in
            while clipboardRemainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if !isClipboardDismissPaused {
                    clipboardRemainingSeconds -= 1
                }
            }
            if !Task.isCancelled && !isClipboardDismissPaused && phase != .executed {
                dismiss()
            }
        }
    }

    private func cancelClipboardDismiss() {
        clipboardDismissTask?.cancel()
        clipboardDismissTask = nil
        if isClipboardAutoTriggered {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isClipboardAutoTriggered = false
                isClipboardDismissPaused = false
            }
        }
    }

    private func pauseClipboardDismiss() {
        isClipboardDismissPaused = true
    }

    private func resumeClipboardDismiss() {
        if clipboardRemainingSeconds <= 0 {
            clipboardRemainingSeconds = max(1, clipboardAutoDismissSeconds)
        }
        isClipboardDismissPaused = false
    }

    // MARK: - 倒计时自动关闭

    private func startCountdownIfNeeded() {
        cancelCountdown()
        guard autoDismissSeconds > 0 else { return }
        remainingSeconds = autoDismissSeconds
        isCountdownPaused = false
        countdownTask = Task { @MainActor in
            while remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if !isCountdownPaused {
                    remainingSeconds -= 1
                }
            }
            if !Task.isCancelled && !isCountdownPaused && phase == .executed {
                dismiss()
            }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func pauseCountdown() {
        isCountdownPaused = true
    }

    private func resumeCountdown() {
        if remainingSeconds <= 0 {
            remainingSeconds = max(1, autoDismissSeconds)
        }
        isCountdownPaused = false
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
