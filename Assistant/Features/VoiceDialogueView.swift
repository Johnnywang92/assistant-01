import SwiftData
import SwiftUI

/// 智能助手对话交互界面（支持离线语音对话与手动打字双模交互）
struct VoiceDialogueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var voice = VoiceDialogueService.shared

    /// 是否在进入页面时自动开启语音聆听录音（例如通过长按悬浮球直接唤起）
    var autoStartListening: Bool = false

    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @AppStorage("voice_use_llm_engine") private var useLLMEngine: Bool = false
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
                    Label(AppSettings.currentMode.rawValue, systemImage: AppSettings.currentMode.icon)
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
                                    }
                                )
                            }

                            // 实时转写中的文字
                            if voice.isListening && !voice.recognizedText.isEmpty {
                                HStack {
                                    Spacer()
                                    Text(voice.recognizedText)
                                        .font(.body)
                                        .padding()
                                        .background(RoundedRectangle(cornerRadius: 16).fill(.tint.opacity(0.2)))
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: dialogueHistory.count) { _, _ in
                        if let last = dialogueHistory.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
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
                                Text(prompt)
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
                    withAnimation {
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
                if !listening && !voice.recognizedText.isEmpty {
                    let query = voice.recognizedText
                    voice.recognizedText = ""
                    processUserQuery(query)
                }
            }
        }
    }

    // MARK: - 语音控制区

    private var voiceInputControlArea: some View {
        VStack(spacing: 12) {
            if let err = voice.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
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
                            .animation(voice.isListening ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: voice.isListening)
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
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))

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
            do {
                try voice.startListening()
            } catch {
                voice.errorMessage = error.localizedDescription
            }
        }
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
            let reply: String
            var options: [DialogueActionOption]? = nil
            var shouldOpenManualSettings: Bool = false
            var planningPlan: TaskPlanningPlan? = nil

            if useLLMEngine {
                // 如果输入命中设置，优先使用 ConversationSettingsEngine 确保零延迟与选项卡片呈现
                if ConversationSettingsEngine.shared.isSettingsQuery(trimmed),
                   let result = ConversationSettingsEngine.shared.processSettingsCommand(trimmed) {
                    reply = result.reply
                    options = result.options
                    shouldOpenManualSettings = result.triggerOpenManualSettings
                } else if TaskPlanningEngine.shared.isPlanningQuery(trimmed),
                          let plan = TaskPlanningEngine.shared.decomposeTask(query: trimmed) {
                    reply = "\(plan.summary)\n我已将分解好的具体待办整理在下方清单卡片中，你可以预览勾选，确认后点击「一键加入待办」即可保存至 App 中。"
                    planningPlan = plan
                } else {
                    reply = await LLMInferenceService.shared.generate(query: trimmed, context: context)
                }
            } else {
                let processor = VoiceIntentProcessor(context: context)
                let result = await processor.processIntent(query: trimmed)
                reply = result.reply
                options = result.options
                shouldOpenManualSettings = result.triggerOpenManualSettings
                planningPlan = result.planningPlan
            }

            let assistantMsg = DialogueMessage(role: .assistant, text: reply, options: options, planningPlan: planningPlan)
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
}

struct DialogueBubble: View {
    let message: DialogueMessage
    var onSelectOption: ((DialogueActionOption) -> Void)? = nil
    var onSavePlan: ((TaskPlanningPlan) -> Void)? = nil
    var onDiscardPlan: (() -> Void)? = nil

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(message.text)
                        .font(.body)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.tint))
                        .foregroundStyle(.white)

                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    // 任务规划卡片（如果存在）
                    if let plan = message.planningPlan {
                        PlanningTaskCardView(plan: plan) { savedPlan in
                            onSavePlan?(savedPlan)
                        } onDiscard: {
                            onDiscardPlan?()
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
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(opt.isPrimary ? Color.accentColor.opacity(0.14) : (opt.actionType == .cancelSettings ? Color.secondary.opacity(0.1) : Color(.systemBackground)))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
                .foregroundStyle(.primary)

                Text(message.timestamp, format: .dateTime.hour().minute())
                    .font(.system(size: 9))
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
                ForEach(plan.subtasks.indices, id: \.self) { idx in
                    let subtask = plan.subtasks[idx]
                    HStack(alignment: .top, spacing: 8) {
                        if plan.isSaved {
                            Image(systemName: subtask.isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.body)
                                .foregroundStyle(subtask.isSelected ? Color.green : Color.secondary)
                                .padding(.top, 2)
                        } else {
                            Button {
                                plan.subtasks[idx].isSelected.toggle()
                                Haptic.light()
                            } label: {
                                Image(systemName: subtask.isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.body)
                                    .foregroundStyle(subtask.isSelected ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(subtask.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(subtask.isSelected ? Color.primary : Color.secondary)
                                .strikethrough(plan.isSaved && !subtask.isSelected)

                            if let detail = subtask.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Text(subtask.type.displayName)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                            )
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
}
