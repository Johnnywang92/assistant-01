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
    /// 判别层完整分布：用于「按可能性排序」的候选条与反馈快照。
    @State private var planDistribution: IntentDistribution?
    /// 用户点选的意图（可能性排序候选切换）；nil 表示按模型判别的 top1 预填。
    @State private var forcedCapability: ActionCapability?
    /// 本条拆解已收到点赞/点踩：收到后隐藏按钮，避免重复记录。
    @State private var feedbackRecorded = false
    @State private var feedbackHint: String?
    /// 最近一条点踩记录：随后点选候选 chip 切换意图时，把该标签回填为「正确意图」，
    /// 构成实锤混淆对（判成 X、实际是 Y），供识别质量统计。
    @State private var lastDownFeedback: OmniboxJudgmentFeedback?
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
    /// 剪贴板带入内容的指纹：关闭时若最终未执行，记入拒绝记忆，同内容不再唤起
    @State private var clipboardPrefillKey: String?
    /// 用户点过「查看并保留内容」→ 明确想要这条内容，关闭时不记拒绝
    @State private var clipboardContentKept = false
    /// 本次会话执行过写库 → 内容已被采纳，关闭时不记拒绝
    @State private var clipboardDidExecute = false
    /// AI 决策导入已执行：回执区给「关联到人生大事」入口
    @State private var showAIDecisionArchive = false
    /// 归档完成提示（如「已关联 3 条待办到「购车」」）
    @State private var archiveHint: String?
    /// 投喂口内麦克风（缺口 4）：复用 VoiceDialogueService，转写实时进输入框
    @ObservedObject private var voiceService = VoiceDialogueService.shared
    @State private var isVoiceListening = false
    /// 开听前输入框已有内容：实时转写 = 基底 + 空格 + 识别文本，避免覆盖用户手输
    @State private var preSpeechBase = ""

    private var images: [UIImage] { attachments.map(\.image) }

    /// 趋势问句执行后应跳转的图表页（expense → 记账页趋势卡；diet → 健康数据饮食趋势卡）
    private var trendNavigationDomain: String? {
        for outcome in outcomes where outcome.succeeded {
            if outcome.action.capability == .queryLookup,
               outcome.action.params["kind"] == "trend" {
                return outcome.action.params["domain"] ?? "expense"
            }
        }
        return nil
    }

    /// 本次执行里来自 AI 决策导入的待办（回执区挂「关联到人生大事」用）
    private var aiDecisionImportedCount: Int {
        outcomes.filter {
            $0.succeeded
                && $0.action.capability == .todoCreate
                && $0.action.params["fromAIDecision"] == "1"
        }.count
    }

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
        .onChange(of: voiceService.recognizedText) { _, transcript in
            guard isVoiceListening else { return }
            let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            inputText = clean.isEmpty ? preSpeechBase : (preSpeechBase.isEmpty ? clean : preSpeechBase + " " + clean)
        }
        .onChange(of: voiceService.isListening) { _, listening in
            // 引擎侧自行收尾（识别结束/被其他语音入口抢占）时同步本地状态
            if !listening && isVoiceListening {
                isVoiceListening = false
            }
        }
        .onAppear {
            consumePrefillIfPresent()
        }
        .onDisappear {
            stopVoiceListening()
            recordClipboardRejectionIfNeeded()
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
        .sheet(isPresented: $showAIDecisionArchive) {
            AIDecisionArchivePicker(
                onPick: { project in
                    archiveDecision(to: project)
                    showAIDecisionArchive = false
                },
                onCancel: { showAIDecisionArchive = false }
            )
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
        // 记下内容指纹：关闭时若未执行，记入拒绝记忆（见 recordClipboardRejectionIfNeeded）
        clipboardPrefillKey = ClipboardIngestionService.contentKey(of: payload)
        clipboardContentKept = false
        clipboardDidExecute = false
        apply(payload: payload)
        Task { await runPlan() }
        if isClipboardAutoTriggered {
            startClipboardDismissCountdown()
        }
    }

    /// 剪贴板带入的内容被「看过就关」且从未执行 → 记住这条内容不需要，下次不再唤起。
    /// 「查看并保留内容」或执行过写库的不记——用户已经表达了需要它。
    private func recordClipboardRejectionIfNeeded() {
        guard let key = clipboardPrefillKey, !key.isEmpty,
              !clipboardContentKept, !clipboardDidExecute else { return }
        clipboardPrefillKey = nil
        ClipboardIngestionService.shared.markContentKeyRejected(key)
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
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            Image(uiImage: attachment.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
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

            // 语音聆听态：实时声波 + 提示。说完再点一次麦克风结束并保留转写。
            if isVoiceListening {
                HStack(spacing: 8) {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<5, id: \.self) { index in
                            Capsule()
                                .fill(Color.red.opacity(0.75))
                                .frame(width: 3, height: 6 + CGFloat(voiceLevel(at: index)) * 16)
                        }
                    }
                    Text(L10n.tr("正在聆听…说完再点一次结束"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 5, matching: .images) {
                    Label(L10n.tr("图片"), systemImage: "photo.on.rectangle")
                        .font(.subheadline)
                }
                Button {
                    cancelClipboardDismiss()
                    toggleVoiceListening()
                } label: {
                    Label(
                        L10n.tr("语音"),
                        systemImage: isVoiceListening ? "stop.circle.fill" : "mic"
                    )
                    .font(.subheadline)
                    .foregroundStyle(isVoiceListening ? .red : .primary)
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
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

    // MARK: - 投喂口内语音输入

    private func toggleVoiceListening() {
        if isVoiceListening {
            stopVoiceListening()
            Haptic.light()
        } else {
            startVoiceListening()
        }
    }

    private func startVoiceListening() {
        Task {
            let granted = await voiceService.requestPermissions()
            guard granted else {
                errorMessage = L10n.tr("需要麦克风与语音识别权限才能语音投喂")
                return
            }
            do {
                // 基底取当前输入框内容：转写在其后追加，不覆盖手输/粘贴的内容
                preSpeechBase = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                try await voiceService.startListening()
                isVoiceListening = voiceService.isListening
                Haptic.medium()
            } catch {
                isVoiceListening = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopVoiceListening() {
        guard isVoiceListening else { return }
        isVoiceListening = false
        voiceService.stopListening()
        preSpeechBase = ""
    }

    /// 声波条各柱的相对高度（0~1）：按 audioLevel 加一点相位差，避免五根同高
    private func voiceLevel(at index: Int) -> Float {
        let level = voiceService.audioLevel
        let phase = [0.0, 0.35, 0.7, 0.35, 0.0][index % 5]
        return min(1, max(0.12, level * Float(1.0 - phase * 0.6)))
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
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
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

            // 按可能性排序的意图候选：点选切换即按该意图重新拆解并预填写。
            if let distribution = planDistribution, distribution.ranked.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("按可能性排序 · 点选切换意图重新预填"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(distribution.ranked.prefix(3), id: \.label) { score in
                                let isForced = forcedCapability == score.label.capability
                                let isTop = forcedCapability == nil && score.label == distribution.top
                                Button {
                                    cancelClipboardDismiss()
                                    recordIntentCorrection(to: score.label)
                                    forcedCapability = score.label.capability
                                    Task { await runPlan(force: true, forcedCapability: score.label.capability) }
                                } label: {
                                    Text("\(score.label.displayName) \(Int((score.probability * 100).rounded()))%")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule().fill((isForced || isTop) ? Color.purple.opacity(0.18) : Color(.tertiarySystemGroupedBackground))
                                        )
                                        .foregroundStyle((isForced || isTop) ? Color.purple : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            ForEach(actions) { action in
                actionCard(actionBinding(for: action))
            }

            judgmentFeedbackBar

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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
        .simultaneousGesture(
            TapGesture().onEnded {
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
        )
    }

    private var selectedCount: Int { actions.filter(\.isSelected).count }

    // MARK: - 判断反馈（点赞/点踩）

    /// 「这次理解准确吗」的点赞/点踩条。反馈落库后回流到判别：
    /// 被点踩的输入下次强制进确认，被点赞的意图下次优先预填。
    private var judgmentFeedbackBar: some View {
        HStack(spacing: 10) {
            if feedbackRecorded {
                Label(feedbackHint ?? L10n.tr("已记录你的反馈，下次会更准"), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(L10n.tr("这次理解准确吗？"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    recordFeedback(.up)
                } label: {
                    Image(systemName: "hand.thumbsup")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Button {
                    recordFeedback(.down)
                } label: {
                    Image(systemName: "hand.thumbsdown")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                if let feedbackHint {
                    Text(feedbackHint)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    /// 记录一次判别反馈。label 取判别层 top1（判别不可用时退化为首个动作的能力标签），
    /// 同时快照 topProbability/margin 与次选标签，为阈值校准与识别质量统计积累真实语料。
    private func recordFeedback(_ verdict: JudgmentFeedback.Verdict) {
        let labelRaw = planDistribution?.top?.rawValue
            ?? actions.first.flatMap { action in
                OmniboxIntentLabel.allCases.first { $0.capability == action.capability }?.rawValue
            }
            ?? ""
        let record = JudgmentFeedback(
            inputText: IntentFeedbackMemory.normalize(lastCapture?.payloads.compactMap { payload -> String? in
                switch payload {
                case .text(let t), .audioTranscript(let t): return t
                case .image: return nil
                }
            }.joined(separator: " ") ?? inputText),
            labelRaw: labelRaw,
            verdict: verdict,
            topProbability: planDistribution?.topProbability ?? 0,
            margin: planDistribution?.margin ?? 0,
            runnerUpLabelRaw: planDistribution.flatMap { dist in
                dist.ranked.count > 1 ? dist.ranked[1].label.rawValue : nil
            }
        )
        let stored = OmniboxJudgmentFeedback(record)
        context.insert(stored)
        try? context.save()
        feedbackRecorded = true
        lastDownFeedback = verdict == .down ? stored : nil
        feedbackHint = verdict == .down
            ? L10n.tr("下次同类输入会让你先确认；可点上方候选切换意图")
            : nil
        Haptic.selection()
    }

    /// 点踩后点选候选 chip = 用户给出了正确意图 → 回填 correctedLabelRaw，
    /// 与原判别标签构成实锤混淆对（缺口 7 识别质量统计的核心语料）。
    private func recordIntentCorrection(to label: OmniboxIntentLabel) {
        guard let down = lastDownFeedback, down.correctedLabelRaw == nil,
              label.rawValue != down.labelRaw else { return }
        down.correctedLabelRaw = label.rawValue
        try? context.save()
    }

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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    }

                    TextField(L10n.tr("金额"), text: expenseAmountBinding(action, currency: selectedCurrency))
                        .keyboardType(.decimalPad)
                        .frame(width: 84)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))

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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    }
                }
                TextField(L10n.tr("事项名"), text: textBinding(action, key: "title"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                DatePicker("", selection: dateBinding(action, key: "dateISO"), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(.caption)
            case .todoCreate:
                TextField(L10n.tr("待办标题"), text: textBinding(action, key: "title"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                DatePicker("", selection: dueDateBinding(action), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(.caption)
            case .todoUpdate:
                TextField(L10n.tr("原待办（匹配目标）"), text: textBinding(action, key: "target"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                TextField(L10n.tr("修改后标题（可选）"), text: textBinding(action, key: "newTitle"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
            case .todoComplete, .todoCancel:
                TextField(L10n.tr("待办事项目标"), text: textBinding(action, key: "target"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
            case .reminderSnooze:
                HStack(spacing: 8) {
                    TextField(L10n.tr("提醒事项"), text: textBinding(action, key: "target"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    TextField(L10n.tr("顺延时长"), text: textBinding(action, key: "duration"))
                        .font(.caption)
                        .frame(width: 80)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                }
            case .expenseUpdate:
                HStack(spacing: 8) {
                    TextField(L10n.tr("修改后金额"), text: numericBinding(action, key: "newAmount"))
                        .keyboardType(.decimalPad)
                        .frame(width: 90)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    TextField(L10n.tr("账目匹配目标"), text: textBinding(action, key: "target"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                }
            case .queryLookup:
                TextField(L10n.tr("查询关键词"), text: textBinding(action, key: "target"))
                    .font(.subheadline)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
            case .memoInbox:
                TextField(L10n.tr("备忘内容"), text: textBinding(action, key: "memo"), axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(2...4)
                    .padding(6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
            case .foodRecord:
                HStack(spacing: 8) {
                    if let base64 = action.wrappedValue.params["imageDataBase64"],
                       let data = Data(base64Encoded: base64),
                       let uiImg = UIImage(data: data) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                    }
                    TextField(L10n.tr("食物名称"), text: textBinding(action, key: "foodName"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    TextField(L10n.tr("千卡"), text: numericBinding(action, key: "calories"))
                        .keyboardType(.numberPad)
                        .frame(width: 70)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    TextField(L10n.tr("毫升"), text: numericBinding(action, key: "volumeML"))
                        .keyboardType(.numberPad)
                        .frame(width: 70)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    }
                }
            case .storageRecord:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(L10n.tr("物品名称"), text: textBinding(action, key: "name"))
                            .font(.subheadline)
                            .padding(6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                        }
                    }
                    TextField(L10n.tr("详细存放位置（如抽屉、顶层收纳盒）"), text: textBinding(action, key: "location"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                }
            case .habitLog:
                HStack(spacing: 8) {
                    TextField(L10n.tr("打卡目标（如晨跑、降压药）"), text: textBinding(action, key: "target"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    }
                }
            case .anniversaryCreate:
                HStack(spacing: 8) {
                    TextField(L10n.tr("名称（如结婚纪念日、妈妈生日）"), text: textBinding(action, key: "title"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    }
                }
            case .departureAdd:
                HStack(spacing: 8) {
                    TextField(L10n.tr("随身物品（如雨伞、工卡）"), text: textBinding(action, key: "title"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                    }
                }
            case .lifeRecord:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(L10n.tr("事项名称"), text: textBinding(action, key: "title"))
                            .font(.subheadline)
                            .padding(6)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
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
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                        }
                    }
                    TextField(L10n.tr("详情或数值（如完成驱虫、当前里程、练习45分钟）"), text: textBinding(action, key: "detail"))
                        .font(.subheadline)
                        .padding(6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.chip))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(lowConfidence ? Color.orange.opacity(0.05) : Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
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
                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
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
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            }

            // 趋势问句 → 一键跳趋势图表页（缺口 6：趋势问句路由到趋势查询）
            if let domain = trendNavigationDomain {
                Button {
                    openTrendChart(domain: domain)
                } label: {
                    Label(
                        domain == "diet" ? L10n.tr("查看饮食趋势图") : L10n.tr("查看消费趋势图"),
                        systemImage: "chart.line.uptrend.xyaxis"
                    )
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
            }

            // AI 决策导入 → 可归档到人生大事项目（复用导入解析器的项目关联语义）
            if let archiveHint {
                Label(archiveHint, systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if aiDecisionImportedCount > 0 {
                Button {
                    showAIDecisionArchive = true
                } label: {
                    Label(
                        L10n.tr("关联到人生大事项目") + "（\(aiDecisionImportedCount)）",
                        systemImage: "sparkles"
                    )
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            judgmentFeedbackBar

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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
        .simultaneousGesture(
            TapGesture().onEnded {
                if isClipboardAutoTriggered {
                    cancelClipboardDismiss()
                }
            }
        )
    }

    // MARK: - 流程

    private func runPlan(force: Bool = false, forcedCapability: ActionCapability? = nil) async {
        guard force || canSubmit else { return }
        Haptic.selection()
        dismissKeyboard()
        phase = .planning
        errorMessage = nil
        feedbackRecorded = false
        feedbackHint = nil
        archiveHint = nil
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

        // 反馈回流：被点踩的输入强制进确认，被点赞的意图优先预填
        let feedback = loadFeedbackMemory()
        let plan = await OmniboxPlanner().plan(
            capture: capture,
            forcedCapability: forcedCapability ?? self.forcedCapability,
            feedback: feedback
        )
        planEngine = plan.engine
        planFallbackReason = plan.fallbackReason
        planNeedsClarification = plan.needsClarification
        planIntentReason = plan.intentDistribution?.reasonText
        planDistribution = plan.intentDistribution
        if plan.actions.isEmpty {
            // P0-2：拆解失败的投喂也要留痕（planned 状态事务），历史页可追溯原文
            let trace = OmniboxTransaction(capture: capture, actions: [], engine: plan.engine)
            context.insert(trace)
            try? context.save()
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

    /// 从持久化的点赞/点踩记录构建判别回流记忆
    private func loadFeedbackMemory() -> IntentFeedbackMemory {
        let records = ((try? context.fetch(FetchDescriptor<OmniboxJudgmentFeedback>())) ?? [])
            .map(\.feedback)
        return IntentFeedbackMemory(records: records)
    }

    private func executeSelected() {
        cancelCountdown()
        cancelClipboardDismiss()
        let selected = actions.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        clipboardDidExecute = true
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
        stopVoiceListening()
        cancelCountdown()
        cancelClipboardDismiss()
        lastDownFeedback = nil
        inputText = ""
        attachments = []
        pickerItems = []
        actions = []
        outcomes = []
        errorMessage = nil
        archiveHint = nil
        lastCapture = nil
        lastTransaction = nil
        phase = .idle
    }

    // MARK: - 趋势问句跳转图表页（缺口 6）

    private func openTrendChart(domain: String) {
        cancelCountdown()
        cancelClipboardDismiss()
        if domain == "diet" {
            // 饮食趋势卡在「生活档案 → 健康数据」
            NavigationRouter.shared.navigateTo(tab: .vault, vaultDestination: "healthData")
        } else {
            // 消费趋势卡在「记账」页
            NavigationRouter.shared.selectedTab = .expenses
        }
        dismiss()
    }

    // MARK: - AI 决策归档到人生大事项目（缺口 6）

    /// 把本次导入的 AI 决策待办软关联到所选人生大事项目：
    /// 存项目级决策摘要 + 建 LifeEventTask + 回填 TodoItem.lifeEventTaskID（双向联动）。
    /// 与 `LifeEventHomeTodoMirror` 同口径，但不再重复建首页待办（执行时已建）。
    private func archiveDecision(to project: LifeEventProject) {
        let pid = project.id
        let stages = ((try? context.fetch(
            FetchDescriptor<LifeEventStage>(predicate: #Predicate { $0.projectID == pid })
        )) ?? []).sorted { $0.sortOrder < $1.sortOrder }

        let stage: LifeEventStage
        if let existing = stages.first {
            stage = existing
        } else {
            // 项目还没有阶段时补一个默认筹备阶段，避免 stageID 悬空
            stage = LifeEventStage(projectID: project.id, title: "筹备", sortOrder: 0)
            context.insert(stage)
        }

        project.aiDecisionSummary = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        project.aiDecisionAt = .now

        var linked = 0
        for outcome in outcomes
        where outcome.succeeded
            && outcome.action.capability == .todoCreate
            && outcome.action.params["fromAIDecision"] == "1" {
            guard let todoID = outcome.undo.recordID else { continue }
            let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == todoID })
            guard let todo = (try? context.fetch(descriptor))?.first else { continue }

            let task = LifeEventTask(projectID: project.id, stageID: stage.id, title: todo.title)
            context.insert(task)
            todo.lifeEventTaskID = task.id
            todo.detail = "人生大事·\(project.title)（\(stage.title)）· AI 决策建议"
            todo.sourceText = "来自人生大事：\(project.title)"
            linked += 1
        }

        try? context.save()
        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        Haptic.success()
        archiveHint = "已关联 \(linked) 条待办到「\(project.title)」"
    }

    // MARK: - 剪贴板自动唤起倒计时横幅与控制

    private var clipboardAutoDismissBanner: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
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
                    clipboardContentKept = true
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
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.purple.opacity(0.12), radius: 8, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
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

// MARK: - AI 决策归档项目选择器

/// 从投喂口把 AI 决策待办关联到人生大事项目时的轻量项目选择器。
/// 选中项目即回调，归档逻辑在 OmniboxView.archiveDecision（建任务 + 软关联 + 存摘要）。
private struct AIDecisionArchivePicker: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let onPick: (LifeEventProject) -> Void
    let onCancel: () -> Void

    @State private var projects: [LifeEventProject] = []

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("还没有人生大事项目"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("先在「人生大事」里创建项目，再把 AI 决策归档进来"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(projects) { project in
                        Button {
                            onPick(project)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if let summary = project.aiDecisionSummary, !summary.isEmpty {
                                        Text(L10n.tr("已有关联决策"))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("关联到人生大事"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            let descriptor = FetchDescriptor<LifeEventProject>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            projects = ((try? context.fetch(descriptor)) ?? [])
                .filter { $0.statusRaw == "active" }
        }
    }
}
