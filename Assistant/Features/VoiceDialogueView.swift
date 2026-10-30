import AssistantCore
import SwiftData
import SwiftUI

/// 智能助手对话交互界面（支持离线语音对话与手动打字双模交互）
struct VoiceDialogueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var voice = VoiceDialogueService.shared
    @StateObject private var llmService = LLMInferenceService.shared

    /// 是否在进入页面时自动开启语音聆听录音（例如通过长按悬浮球直接唤起）
    var autoStartListening: Bool = false

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @AppStorage("voice_use_llm_engine") private var useLLMEngine: Bool = true
    @State private var dialogueHistory: [DialogueMessage] = []
    @State private var hasPermission = false
    @State private var showingManualSettingsSheet: Bool = false
    @State private var showingClearConfirm: Bool = false
    @State private var showingPermissionSheet: Bool = false
    @State private var currentSessionID: UUID = UUID()

    // 手动打字输入状态
    @State private var isTextInputMode: Bool = false
    @State private var manualInputText: String = ""
    @State private var isMuted: Bool = !AppSettings.voiceReplyEnabled
    @FocusState private var isInputFocused: Bool

    // 语音聆听动画三阶段状态机（聆听中 -> 识别中 -> 识别结果）
    @State private var voicePhase: VoiceVisualPhase = .idle
    @State private var voicePhaseChangedAt = Date()
    @State private var typedResultText = ""
    @State private var recognitionSequenceTask: Task<Void, Never>? = nil

    // 快捷推荐问题（根据工作日/节假日/周末情境动态适配，并附带规划与设置快捷入口）
    private var quickPrompts: [String] {
        var prompts = SituationalContextEngine.shared.dynamicVoicePrompts()
        prompts.insert("⛺️ 露营出行规划", at: 0)
        prompts.insert("📦 搬家任务规划", at: 1)
        prompts.insert("⚙️ 基础设置向导", at: 2)
        return prompts
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部运行模式、推理引擎与静音控制指示条
                HStack {
                    Label(L10n.tr(AppSettings.currentMode.rawValue), systemImage: AppSettings.currentMode.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 对话记录保留周期快捷选择
                    Menu {
                        Button {
                            AppSettings.dialogueRetentionPolicy = .sevenDays
                            DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
                            Haptic.light()
                        } label: {
                            Label("自动保留 7 天", systemImage: AppSettings.dialogueRetentionPolicy == .sevenDays ? "checkmark" : "")
                        }

                        Button {
                            AppSettings.dialogueRetentionPolicy = .thirtyDays
                            DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
                            Haptic.light()
                        } label: {
                            Label("自动保留 30 天", systemImage: AppSettings.dialogueRetentionPolicy == .thirtyDays ? "checkmark" : "")
                        }

                        Button {
                            AppSettings.dialogueRetentionPolicy = .none
                            DialogueHistoryManager.shared.clearAll(context: context)
                            Haptic.light()
                        } label: {
                            Label("不保留 (即用即走)", systemImage: AppSettings.dialogueRetentionPolicy == .none ? "checkmark" : "")
                        }

                        Button {
                            AppSettings.dialogueRetentionPolicy = .forever
                            Haptic.light()
                        } label: {
                            Label("永久保留", systemImage: AppSettings.dialogueRetentionPolicy == .forever ? "checkmark" : "")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text(AppSettings.dialogueRetentionPolicy.shortTitle)
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(.secondarySystemFill)))
                        .foregroundStyle(.secondary)
                    }

                    // TTS 朗读静音开关
                    Button {
                        isMuted.toggle()
                        if isMuted {
                            voice.stopSpeaking()
                        }
                        Haptic.light()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.caption2.bold())
                            .padding(6)
                            .background(Circle().fill(Color(.secondarySystemFill)))
                            .foregroundStyle(isMuted ? Color.secondary : Color.accentColor)
                    }

                    // 极速规则引擎 vs 端侧本地大模型切换
                    Button {
                        useLLMEngine.toggle()
                        Haptic.light()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: useLLMEngine ? "brain.head.profile" : "bolt.fill")
                            Text(useLLMEngine ? "扩展问答" : "规则助手")
                        }
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(useLLMEngine ? Color.purple.opacity(0.18) : Color.blue.opacity(0.15)))
                        .foregroundStyle(useLLMEngine ? Color.purple : Color.blue)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // 消息滚动历史
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(dialogueHistory) { msg in
                                DialogueBubble(
                                    message: msg,
                                    onSelectOption: { option in
                                        handleOptionSelected(option)
                                    },
                                    onSavePlan: { plan in
                                        handleSavePlan(messageId: msg.id, plan: plan)
                                    },
                                    onDiscardPlan: {
                                        handleDiscardPlan(messageId: msg.id)
                                    },
                                    onSaveSkillPlan: { draft in
                                        handleSaveSkillPlan(messageId: msg.id, draft: draft)
                                    },
                                    onRefineSubtask: { subtask in
                                        handleRefineSubtask(messageId: msg.id, subtask: subtask)
                                    }
                                )
                            }

                            // 端侧大模型实时流式生成气泡
                            if llmService.isGenerating {
                                HStack {
                                    HStack(spacing: 8) {
                                        if llmService.currentOutput.isEmpty {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text(llmService.localEngineStatus)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(llmService.currentOutput)
                                                .font(.body)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: AppRadius.large).fill(Color(UIColor.secondarySystemGroupedBackground)))
                                    Spacer()
                                }
                                .id("llm-streaming-bubble")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: dialogueHistory.count) { _, _ in
                        if let last = dialogueHistory.last {
                            AppMotion.animate {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: llmService.currentOutput) { _, _ in
                        if llmService.isGenerating {
                            proxy.scrollTo("llm-streaming-bubble", anchor: .bottom)
                        }
                    }
                }

                // 快捷提示气泡横向滚动条
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.self) { prompt in
                            Button {
                                processUserQuery(prompt)
                            } label: {
                                Text(L10n.tr(prompt))
                                    .font(.caption2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color(.secondarySystemFill)))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 6)

                Divider()

                // 语音聆听 / 识别动画可视化（根据 voicePhase 三阶段切换）
                if voicePhase != .idle {
                    VoiceListeningVisualizer(
                        phase: voicePhase,
                        level: CGFloat(voice.audioLevel),
                        changedAt: voicePhaseChangedAt,
                        liveText: voice.recognizedText,
                        resultText: typedResultText,
                        tint: .accentColor
                    )
                    .padding(.top, 8)
                }

                // 底部双模交互区（语音麦克风 / 键盘手动打字）
                if isTextInputMode {
                    textInputControlBar
                } else {
                    voiceInputControlArea
                }
            }
            .navigationTitle(assistantName.isEmpty ? "语音助手" : "\(assistantName) · 对话交互")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        voice.stopListening()
                        voice.stopSpeaking()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingManualSettingsSheet = true
                            Haptic.light()
                        } label: {
                            Label("手动详细设置", systemImage: "gearshape")
                        }

                        Button {
                            showingPermissionSheet = true
                            Haptic.light()
                        } label: {
                            Label("核心权限健康度检查", systemImage: "checkmark.shield")
                        }

                        Menu {
                            Button {
                                AppSettings.dialogueRetentionPolicy = .sevenDays
                                DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
                                Haptic.light()
                            } label: {
                                Label("自动保留 7 天", systemImage: AppSettings.dialogueRetentionPolicy == .sevenDays ? "checkmark" : "")
                            }

                            Button {
                                AppSettings.dialogueRetentionPolicy = .thirtyDays
                                DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
                                Haptic.light()
                            } label: {
                                Label("自动保留 30 天", systemImage: AppSettings.dialogueRetentionPolicy == .thirtyDays ? "checkmark" : "")
                            }

                            Button {
                                AppSettings.dialogueRetentionPolicy = .none
                                DialogueHistoryManager.shared.clearAll(context: context)
                                dialogueHistory.removeAll()
                                Haptic.light()
                            } label: {
                                Label("不保留 (即用即走)", systemImage: AppSettings.dialogueRetentionPolicy == .none ? "checkmark" : "")
                            }

                            Button {
                                AppSettings.dialogueRetentionPolicy = .forever
                                Haptic.light()
                            } label: {
                                Label("永久保留", systemImage: AppSettings.dialogueRetentionPolicy == .forever ? "checkmark" : "")
                            }
                        } label: {
                            Label("保留周期: \(AppSettings.dialogueRetentionPolicy.shortTitle)", systemImage: "clock.arrow.circlepath")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showingClearConfirm = true
                        } label: {
                            Label("清空对话历史", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                    }
                }
            }
            .sheet(isPresented: $showingManualSettingsSheet) {
                SettingsView(isSheet: true)
            }
            .sheet(isPresented: $showingPermissionSheet) {
                PermissionOnboardingView()
            }
            .alert("清空对话记录", isPresented: $showingClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("确认清空", role: .destructive) {
                    DialogueHistoryManager.shared.clearAll(context: context)
                    AppMotion.animate {
                        dialogueHistory.removeAll()
                    }
                    Haptic.success()
                }
            } message: {
                Text("确定要清空本地历史对话记录吗？已提取的待办事项不受影响。")
            }
            .task {
                DialogueHistoryManager.shared.cleanExpiredRecords(context: context)

                if dialogueHistory.isEmpty {
                    let savedList = DialogueHistoryManager.shared.fetchRecentMessages(context: context)
                    if !savedList.isEmpty {
                        for record in savedList {
                            dialogueHistory.append(
                                DialogueMessage(
                                    id: record.id,
                                    role: record.isUser ? .user : .assistant,
                                    text: record.text,
                                    timestamp: record.timestamp
                                )
                            )
                        }
                    } else {
                        let name = assistantName.isEmpty ? "小助" : assistantName
                        let titlePrefix = userTitle.isEmpty || userTitle == "你" ? "" : "\(userTitle)，"
                        dialogueHistory.append(
                            DialogueMessage(
                                role: .assistant,
                                text: "\(titlePrefix)你好！我是你的个人离线助理「\(name)」。随时对我说出指令、打字输入，或对我说「设置」进行偏好配置。",
                                options: [
                                    DialogueActionOption(label: "⚙️ 基础设置向导 (逐项问答)", icon: "slider.horizontal.3", payload: "wizard:start"),
                                    DialogueActionOption(label: "⚙️ 手动详细设置", icon: "gearshape.fill", payload: "manual_settings", actionType: .openManualSettings)
                                ]
                            )
                        )
                    }
                }
                hasPermission = await voice.requestPermissions()
                if autoStartListening && hasPermission && !voice.isListening {
                    // 延时等待 sheet 弹出过渡动效就绪后，平滑开启离线语音拾音
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    toggleListening()
                }
            }
            .onDisappear {
                ConversationSettingsEngine.shared.currentWizardStep = nil
            }
            .onChange(of: voice.isListening) { _, listening in
                if listening {
                    // 重新开始时取消上一个未完成的结果动画序列
                    recognitionSequenceTask?.cancel()
                    typedResultText = ""
                    setVoicePhase(.listening)
                } else {
                    let finalText = voice.recognizedText
                    voice.recognizedText = ""
                    guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setVoicePhase(.idle)
                        return
                    }
                    // 进入「识别中」短暂跳动，再逐字打出「识别结果」，最后提交到对话
                    setVoicePhase(.recognizing)
                    recognitionSequenceTask = Task { [finalText] in
                        do {
                            try await Task.sleep(nanoseconds: 650_000_000)
                        } catch { return }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            setVoicePhase(.result)
                            typedResultText = ""
                        }
                        for ch in finalText {
                            guard !Task.isCancelled else { return }
                            do {
                                try await Task.sleep(nanoseconds: 70_000_000)
                            } catch { return }
                            typedResultText.append(ch)
                        }
                        do {
                            try await Task.sleep(nanoseconds: 900_000_000)
                        } catch { return }
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            setVoicePhase(.idle)
                            processUserQuery(finalText)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 语音控制区

    private var voiceInputControlArea: some View {
        VStack(spacing: 12) {
            if let err = voice.errorMessage {
                Text(L10n.tr(err)).font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 24) {
                // 语音录制麦克风按钮
                Button {
                    toggleListening()
                } label: {
                    ZStack {
                        Circle()
                            .fill(voice.isListening ? Color.red : Color.accentColor)
                            .frame(width: 68, height: 68)
                            .scaleEffect(voice.isListening ? 1.08 : 1.0)
                            .responsiveAnimation(voice.isListening ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: voice.isListening)
                            .shadow(color: (voice.isListening ? Color.red : Color.accentColor).opacity(0.4), radius: 8)

                        Image(systemName: voice.isListening ? "stop.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }

                if voice.isSpeaking {
                    Button {
                        voice.stopSpeaking()
                    } label: {
                        Label("停止朗读", systemImage: "speaker.slash.fill")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.secondary.opacity(0.18)))
                    }
                }
            }
            .padding(.top, 4)

            HStack(spacing: 14) {
                Text(voice.isListening ? "正在倾听中... 说完后点击停止" : "点击麦克风说话")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // 快捷切换至键盘打字
                Button {
                    isTextInputMode = true
                    isInputFocused = true
                    Haptic.light()
                } label: {
                    Label("打字输入", systemImage: "keyboard")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            .opacity(voicePhase == .idle ? 1 : 0)
        }
        .padding(.bottom, 14)
    }

    // MARK: - 手动键盘输入栏

    private var textInputControlBar: some View {
        HStack(spacing: 10) {
            // 切回麦克风语音模式
            Button {
                isTextInputMode = false
                isInputFocused = false
                Haptic.light()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.body)
                    .foregroundStyle(.tint)
                    .padding(8)
                    .background(Circle().fill(Color(.secondarySystemFill)))
            }

            // 文本输入框
            TextField("不方便语音？在此输入指令或问题...", text: $manualInputText)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitManualInput()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: AppRadius.panel).fill(Color(.secondarySystemGroupedBackground)))

            // 发送按钮
            Button {
                submitManualInput()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(manualInputText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)
            }
            .disabled(manualInputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - 业务逻辑

    private func toggleListening() {
        if voice.isListening {
            voice.stopListening()
        } else {
            Task {
                do {
                    try await voice.startListening()
                } catch {
                    voice.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func setVoicePhase(_ p: VoiceVisualPhase) {
        voicePhase = p
        voicePhaseChangedAt = Date()
    }

    private func submitManualInput() {
        let text = manualInputText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        manualInputText = ""
        processUserQuery(text)
    }

    private func processUserQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = DialogueMessage(role: .user, text: trimmed)
        dialogueHistory.append(userMsg)
        DialogueHistoryManager.shared.saveMessage(role: "user", text: trimmed, sessionID: currentSessionID, context: context)
        Haptic.light()

        Task {
            // 规划背景追问进行中：本条输入优先作为追问回答，不再走常规意图路由
            if PlanningClarificationEngine.shared.isActive {
                if trimmed.contains("算了") || trimmed.contains("不规划") || trimmed.contains("取消规划") {
                    PlanningClarificationEngine.shared.cancelSession()
                    appendAssistantMessage("好的，已退出背景追问。需要重新规划时随时叫我。")
                    return
                }
                await respondPlanningClarification(answer: trimmed)
                return
            }

            let reply: String
            var options: [DialogueActionOption]? = nil
            var shouldOpenManualSettings: Bool = false
            var planningPlan: TaskPlanningPlan? = nil
            var skillPlan: SkillPathDraft? = nil

            if useLLMEngine {
                // 如果输入命中设置，优先使用 ConversationSettingsEngine 确保零延迟与选项卡片呈现
                if ConversationSettingsEngine.shared.isSettingsQuery(trimmed),
                   let result = ConversationSettingsEngine.shared.processSettingsCommand(trimmed) {
                    reply = result.reply
                    options = result.options
                    shouldOpenManualSettings = result.triggerOpenManualSettings
                } else if SkillPathPlanner.isLearningQuery(trimmed),
                          let draft = SkillPathPlanner.build(query: trimmed) {
                    reply = draft.summaryText
                    skillPlan = draft
                } else if TaskPlanningEngine.shared.isPlanningQuery(trimmed) {
                    // 先追问确认背景信息（同行人/时间/预算等），已说明过的维度不重复问；陌生领域由端侧模型就地出题
                    switch await PlanningClarificationEngine.shared.begin(query: trimmed) {
                    case .question(let prompt, let askOptions):
                        reply = prompt
                        options = askOptions
                    case .ready(let background):
                        if let plan = await TaskPlanningEngine.shared.decomposeTaskWithAI(query: trimmed, backgroundContext: background.isEmpty ? nil : background) {
                            reply = planningCardReply(plan: plan, usedBackground: !background.isEmpty)
                            planningPlan = plan
                        } else {
                            reply = await LLMInferenceService.shared.generate(query: trimmed, sessionID: currentSessionID, context: context)
                        }
                    case .cancelled:
                        reply = "好的，需要规划时随时叫我。"
                    }
                } else {
                    reply = await LLMInferenceService.shared.generate(query: trimmed, sessionID: currentSessionID, context: context)
                }
            } else {
                let processor = VoiceIntentProcessor(context: context)
                let result = await processor.processIntent(query: trimmed)
                reply = result.reply
                options = result.options
                shouldOpenManualSettings = result.triggerOpenManualSettings
                planningPlan = result.planningPlan
                skillPlan = result.skillPlan
            }

            let assistantMsg = DialogueMessage(role: .assistant, text: reply, options: options, planningPlan: planningPlan, skillPlan: skillPlan)
            dialogueHistory.append(assistantMsg)
            DialogueHistoryManager.shared.saveMessage(role: "assistant", text: reply, sessionID: currentSessionID, context: context)

            if shouldOpenManualSettings {
                voice.stopListening()
                voice.stopSpeaking()
                showingManualSettingsSheet = true
            }

            // 若未静音且开启了朗读偏好，进行 TTS 语音输出
            if !isMuted {
                voice.speak(text: reply)
            }
            Haptic.success()
        }
    }

    private func handleOptionSelected(_ option: DialogueActionOption) {
        switch option.actionType {
        case .planningAnswer:
            dialogueHistory.append(DialogueMessage(role: .user, text: option.label))
            DialogueHistoryManager.shared.saveMessage(role: "user", text: option.label, sessionID: currentSessionID, context: context)
            Task {
                await respondPlanningClarification(answer: option.payload)
            }
        case .openManualSettings:
            voice.stopListening()
            voice.stopSpeaking()
            showingManualSettingsSheet = true
            let msg = "已为你中断对话向导，打开系统手动详细设置。"
            dialogueHistory.append(DialogueMessage(role: .assistant, text: msg))
            DialogueHistoryManager.shared.saveMessage(role: "assistant", text: msg, sessionID: currentSessionID, context: context)
        case .cancelSettings:
            dialogueHistory.append(DialogueMessage(role: .user, text: option.label))
            DialogueHistoryManager.shared.saveMessage(role: "user", text: option.label, sessionID: currentSessionID, context: context)
            let msg = "好的，已退出设置向导。有任何生活琐事随时叫我！"
            dialogueHistory.append(DialogueMessage(role: .assistant, text: msg))
            DialogueHistoryManager.shared.saveMessage(role: "assistant", text: msg, sessionID: currentSessionID, context: context)
            Haptic.light()
        case .applySetting:
            dialogueHistory.append(DialogueMessage(role: .user, text: option.label))
            DialogueHistoryManager.shared.saveMessage(role: "user", text: option.label, sessionID: currentSessionID, context: context)
            let result = ConversationSettingsEngine.shared.applyOption(payload: option.payload)
            dialogueHistory.append(DialogueMessage(role: .assistant, text: result.reply, options: result.options))
            DialogueHistoryManager.shared.saveMessage(role: "assistant", text: result.reply, sessionID: currentSessionID, context: context)
            if result.triggerOpenManualSettings {
                voice.stopListening()
                voice.stopSpeaking()
                showingManualSettingsSheet = true
            }
            if !isMuted {
                voice.speak(text: result.reply)
            }
            Haptic.success()
        }
    }

    // MARK: - 规划背景追问辅助

    /// 规划卡片回复文案（usedBackground 标记是否结合了追问确认的背景信息）
    private func planningCardReply(plan: TaskPlanningPlan, usedBackground: Bool) -> String {
        let prefix = usedBackground ? "已结合你确认的背景信息，" : ""
        return "\(plan.summary)\n\(prefix)我已将分解好的具体待办整理在下方清单卡片中，你可以预览勾选，确认后点击「一键加入待办」即可保存至 App 中。"
    }

    /// 提交一条追问回答：未满问数继续下一问，问完/提前生成则结合背景产出规划卡片
    private func respondPlanningClarification(answer: String) async {
        let outcome = PlanningClarificationEngine.shared.submit(answer: answer)
        var reply = ""
        var askOptions: [DialogueActionOption]?
        var plan: TaskPlanningPlan?
        switch outcome {
        case .question(let prompt, let options):
            reply = prompt
            askOptions = options
        case .ready(let background):
            if let generated = await TaskPlanningEngine.shared.decomposeTaskWithAI(
                query: PlanningClarificationEngine.shared.originalQuery,
                backgroundContext: background.isEmpty ? nil : background
            ) {
                plan = generated
                reply = planningCardReply(plan: generated, usedBackground: !background.isEmpty)
            } else {
                reply = "端侧模型暂时不可用，稍后对我说「帮我规划」重试一下。"
            }
        case .cancelled:
            reply = "好的，已退出背景追问。需要重新规划时随时叫我。"
        }
        appendAssistantMessage(reply, options: askOptions, planningPlan: plan)
    }

    private func appendAssistantMessage(_ text: String, options: [DialogueActionOption]? = nil, planningPlan: TaskPlanningPlan? = nil) {
        let assistantMsg = DialogueMessage(role: .assistant, text: text, options: options, planningPlan: planningPlan)
        dialogueHistory.append(assistantMsg)
        DialogueHistoryManager.shared.saveMessage(role: "assistant", text: text, sessionID: currentSessionID, context: context)
        if !isMuted {
            voice.speak(text: text)
        }
        Haptic.success()
    }

    /// 对规划卡片中某个仍太笼统的步骤发起细化：结合父目标与已确认背景，生成微步骤子卡片
    private func handleRefineSubtask(messageId: UUID, subtask: PlannedSubtask) {
        guard let parentPlan = dialogueHistory.first(where: { $0.id == messageId })?.planningPlan else { return }
        let userText = "细化步骤：\(subtask.title)"
        dialogueHistory.append(DialogueMessage(role: .user, text: userText))
        DialogueHistoryManager.shared.saveMessage(role: "user", text: userText, sessionID: currentSessionID, context: context)
        Haptic.light()

        Task {
            if let refined = await TaskPlanningEngine.shared.refineSubtaskWithAI(parentPlan: parentPlan, subtask: subtask) {
                appendAssistantMessage(
                    "\(refined.summary)\n微步骤已单独成卡，确认后勾选加入待办即可；原大步骤如已被覆盖，不再勾选可避免重复。如还有哪步太大，继续点「细化」。",
                    planningPlan: refined
                )
            } else {
                appendAssistantMessage("端侧模型暂时不可用，这条步骤稍后无法细化，你可以再点一次「细化」重试。")
            }
        }
    }

    private func handleSavePlan(messageId: UUID, plan: TaskPlanningPlan) {
        let count = TaskPlanningEngine.shared.savePlanToTodos(plan: plan, context: context)
        if let idx = dialogueHistory.firstIndex(where: { $0.id == messageId }) {
            var updated = dialogueHistory[idx]
            if var p = updated.planningPlan {
                p.isSaved = true
                updated.planningPlan = p
                dialogueHistory[idx] = updated
            }
        }
        let successMsg = DialogueMessage(
            role: .assistant,
            text: "🎉 太棒了！已成功为你将 \(count) 项「\(plan.topic)」拆解任务保存至待办列表中。可在首页「待办」或生活板块中查看并逐项打钩完成。"
        )
        dialogueHistory.append(successMsg)
        DialogueHistoryManager.shared.saveMessage(role: "assistant", text: successMsg.text, sessionID: currentSessionID, context: context)
        if !isMuted {
            voice.speak(text: "已成功将 \(count) 项任务写入待办列表！")
        }
    }

    private func handleSaveSkillPlan(messageId: UUID, draft: SkillPathDraft) {
        let path = SkillPathManager.shared.save(draft: draft, context: context)
        // 新路径立即进入桌面/锁屏「今日练习」快照
        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
        if let idx = dialogueHistory.firstIndex(where: { $0.id == messageId }) {
            var updated = dialogueHistory[idx]
            updated.isSkillPlanSaved = true
            dialogueHistory[idx] = updated
        }
        let firstStageName = draft.stages.first?.name ?? "启动期"
        let text = "已开启学习路径「\(path.title)」，共 \(draft.stages.count) 个阶段、约 \(draft.totalWeeks) 周。"
            + "第一阶段「\(firstStageName)」的 \(draft.stages.first?.tasks.count ?? 0) 条任务已写入待办，"
            + "练习打卡会每天自动提醒。可在「生活 → 学习路径」查看进度。"
        let successMsg = DialogueMessage(role: .assistant, text: text)
        dialogueHistory.append(successMsg)
        DialogueHistoryManager.shared.saveMessage(role: "assistant", text: text, sessionID: currentSessionID, context: context)
        if !isMuted {
            voice.speak(text: "已开启学习路径，第一阶段的任务已写入待办。")
        }
    }

    private func handleDiscardPlan(messageId: UUID) {
        let discardMsg = DialogueMessage(
            role: .assistant,
            text: "好的，该方案仅作参考，未写入待办事项。随时对我说出新任务！"
        )
        dialogueHistory.append(discardMsg)
        DialogueHistoryManager.shared.saveMessage(role: "assistant", text: discardMsg.text, sessionID: currentSessionID, context: context)
    }
}

enum MessageRole {
    case user, assistant
}

struct DialogueMessage: Identifiable {
    var id: UUID = UUID()
    let role: MessageRole
    let text: String
    var timestamp: Date = .now
    var options: [DialogueActionOption]? = nil
    var planningPlan: TaskPlanningPlan? = nil
    var skillPlan: SkillPathDraft? = nil
    var isSkillPlanSaved: Bool = false
}

struct DialogueBubble: View {
    let message: DialogueMessage
    var onSelectOption: ((DialogueActionOption) -> Void)? = nil
    var onSavePlan: ((TaskPlanningPlan) -> Void)? = nil
    var onDiscardPlan: (() -> Void)? = nil
    var onSaveSkillPlan: ((SkillPathDraft) -> Void)? = nil
    var onRefineSubtask: ((PlannedSubtask) -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.text)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: AppRadius.large).fill(.tint))
                        .foregroundStyle(.white)

                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    // 任务规划卡片（如果存在）
                    if let plan = message.planningPlan {
                        PlanningTaskCardView(plan: plan, onRefine: onRefineSubtask) { savedPlan in
                            onSavePlan?(savedPlan)
                        } onDiscard: {
                            onDiscardPlan?()
                        }
                    }

                    // 技能学习路径卡片（如果存在）
                    if let draft = message.skillPlan {
                        SkillPlanCardView(draft: draft, isSaved: message.isSkillPlanSaved) { savedDraft in
                            onSaveSkillPlan?(savedDraft)
                        }
                    }

                    if let options = message.options, !options.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(options) { opt in
                                Button {
                                    onSelectOption?(opt)
                                } label: {
                                    HStack(spacing: 6) {
                                        if let icon = opt.icon {
                                            Image(systemName: icon)
                                                .font(.caption2)
                                        }
                                        Text(opt.label)
                                            .font(.caption.weight(opt.isPrimary ? .semibold : .medium))
                                        Spacer()
                                        if opt.actionType == .openManualSettings {
                                            Image(systemName: "arrow.up.right.square")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                            .fill(opt.isPrimary ? Color.accentColor.opacity(0.14) : (opt.actionType == .cancelSettings ? Color.secondary.opacity(0.1) : Color(.systemBackground)))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                            .stroke(opt.isPrimary ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 0.8)
                                    )
                                    .foregroundStyle(opt.isPrimary ? Color.accentColor : (opt.actionType == .cancelSettings ? Color.secondary : Color.primary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: AppRadius.large).fill(Color(UIColor.secondarySystemGroupedBackground)))
                .foregroundStyle(.primary)

                Text(message.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }

            Spacer()
        }
    }
}

/// 任务规划与拆解交互式卡片
struct PlanningTaskCardView: View {
    @State var plan: TaskPlanningPlan
    var onRefine: ((PlannedSubtask) -> Void)? = nil
    var onSave: (TaskPlanningPlan) -> Void
    var onDiscard: () -> Void

    var selectedCount: Int {
        plan.subtasks.filter { $0.isSelected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 卡片头部
            HStack(spacing: 8) {
                Image(systemName: plan.icon)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)

                Text(plan.topic)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Spacer()

                if !plan.isSaved && !plan.subtasks.isEmpty {
                    Button {
                        let allSelected = plan.subtasks.allSatisfy { $0.isSelected }
                        for idx in plan.subtasks.indices {
                            plan.subtasks[idx].isSelected = !allSelected
                        }
                        Haptic.light()
                    } label: {
                        Text(plan.subtasks.allSatisfy { $0.isSelected } ? "取消全选" : "全选")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(plan.subtasks.count) 项待办")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }

            Divider()

            // 任务拆分子项
            VStack(spacing: 6) {
                ForEach(plan.subtasks) { subtask in
                    HStack(alignment: .top, spacing: 8) {
                        if plan.isSaved {
                            Image(systemName: subtask.isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.body)
                                .foregroundStyle(subtask.isSelected ? Color.green : Color.secondary)
                                .padding(.top, 2)
                        } else {
                            Button {
                                if let idx = plan.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                                    plan.subtasks[idx].isSelected.toggle()
                                }
                                Haptic.light()
                            } label: {
                                Image(systemName: subtask.isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.body)
                                    .foregroundStyle(subtask.isSelected ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(subtask.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(subtask.isSelected ? Color.primary : Color.secondary)
                                .strikethrough(plan.isSaved && !subtask.isSelected)

                            if let detail = subtask.detail, !detail.isEmpty {
                                Text(L10n.tr(detail))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                // 执行阶段标签
                                HStack(spacing: 2) {
                                    Image(systemName: subtask.phase.icon)
                                    Text(subtask.phase.rawValue)
                                }
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                                .foregroundStyle(Color.accentColor)

                                // 类型标签
                                HStack(spacing: 2) {
                                    Image(systemName: subtask.type.icon)
                                    Text(subtask.type.displayName)
                                }
                                .font(.system(size: 8, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                                .foregroundStyle(.secondary)
                            }

                            // 步骤仍太笼统时，逐条细化为可照着做的微步骤
                            if let onRefine, !plan.isSaved {
                                Button {
                                    Haptic.light()
                                    onRefine(subtask)
                                } label: {
                                    HStack(spacing: 2) {
                                        Image(systemName: "list.bullet.indent")
                                        Text("细化")
                                    }
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                            .fill(subtask.isSelected ? Color.accentColor.opacity(0.06) : Color(.systemBackground))
                    )
                }
            }

            // 底部操作区
            if plan.isSaved {
                HStack {
                    Spacer()
                    Label("已成功加入待办列表 ✓", systemImage: "checkmark.seal.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                        .fill(Color.green.opacity(0.12))
                )
            } else {
                HStack(spacing: 8) {
                    Button {
                        onSave(plan)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("一键加入待办 (\(selectedCount))")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                .fill(selectedCount > 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(selectedCount == 0)

                    Button {
                        onDiscard()
                    } label: {
                        Text("不用了")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                            )
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
}

/// 技能学习路径卡片：四阶段概览 + 第一阶段任务预览
struct SkillPlanCardView: View {
    let draft: SkillPathDraft
    var isSaved: Bool = false
    var onStart: (SkillPathDraft) -> Void

    private var firstStage: PlannedSkillStage? { draft.stages.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: draft.category.icon)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)

                Text(draft.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(draft.stages.count) 阶段 · \(draft.totalWeeks) 周")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }

            Text("目标：\(draft.goal)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 四阶段概览条
            HStack(spacing: 4) {
                ForEach(draft.stages) { stage in
                    VStack(spacing: 2) {
                        Text("\(stage.index + 1)")
                            .font(.caption2.bold())
                        Text(stage.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(stage.index == 0 ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                    )
                    .foregroundStyle(stage.index == 0 ? Color.accentColor : Color.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("共 \(draft.stages.count) 个阶段，当前展开第一阶段")

            Divider()

            if let stage = firstStage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("第一阶段 · \(stage.name)")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)

                    Text("通关标准：\(stage.acceptance)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(stage.tasks) { task in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: task.kind == .practice ? "repeat" : "flag.fill")
                                .font(.caption)
                                .foregroundStyle(task.kind == .practice ? Color.orange : Color.accentColor)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = task.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if task.kind == .practice {
                                    Text("每\(task.recurrenceDays == 1 ? "天" : " \(task.recurrenceDays) 天") · \(task.minutes) 分钟")
                                        .font(.caption2)
                                        .foregroundStyle(Color.orange)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }

            Button {
                Haptic.light()
                onStart(draft)
            } label: {
                HStack {
                    Image(systemName: isSaved ? "checkmark.circle.fill" : "play.fill")
                    Text(isSaved ? "已开启学习路径" : "开启学习路径")
                        .font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(isSaved ? Color.green.opacity(0.18) : Color.accentColor))
                .foregroundStyle(isSaved ? Color.green : Color.white)
            }
            .buttonStyle(.plain)
            .disabled(isSaved)
            .accessibilityLabel(isSaved ? "学习路径已开启" : "开启学习路径，写入第一阶段任务")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(Color(UIColor.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.8)
        )
    }
}
