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
    @AppStorage("voice_use_llm_engine") private var useLLMEngine: Bool = false
    @State private var dialogueHistory: [DialogueMessage] = []
    @State private var hasPermission = false

    // 手动打字输入状态
    @State private var isTextInputMode: Bool = false
    @State private var manualInputText: String = ""
    @State private var isMuted: Bool = !AppSettings.voiceReplyEnabled
    @FocusState private var isInputFocused: Bool

    // 快捷推荐问题
    private let quickPrompts = [
        "今天有哪些待办？",
        "出门防丢该带什么？",
        "今天花了多少钱？",
        "查一下待取快递",
        "记一下明天下午开会"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部运行模式、推理引擎与静音控制指示条
                HStack {
                    Label(AppSettings.currentMode.rawValue, systemImage: AppSettings.currentMode.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

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
                            .foregroundStyle(isMuted ? .secondary : .tint)
                    }

                    // 极速规则引擎 vs 端侧本地大模型切换
                    Button {
                        useLLMEngine.toggle()
                        Haptic.light()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: useLLMEngine ? "brain.head.profile" : "bolt.fill")
                            Text(useLLMEngine ? "Qwen2.5-1.5B" : "极速规则引擎")
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
                                DialogueBubble(message: msg)
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
            }
            .task {
                if dialogueHistory.isEmpty {
                    let name = assistantName.isEmpty ? "小助" : assistantName
                    dialogueHistory.append(DialogueMessage(role: .assistant, text: "你好！我是你的个人离线助理「\(name)」。随时对我说出指令，或在下方打字输入问题。"))
                }
                hasPermission = await voice.requestPermissions()
                if autoStartListening && hasPermission && !voice.isListening {
                    // 延时等待 sheet 弹出过渡动效就绪后，平滑开启离线语音拾音
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    toggleListening()
                }
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
                    .foregroundStyle(manualInputText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.4) : Color.tint)
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
        Haptic.light()

        Task {
            let reply: String
            if useLLMEngine {
                reply = await LLMInferenceService.shared.generate(query: trimmed, context: context)
            } else {
                let processor = VoiceIntentProcessor(context: context)
                reply = await processor.process(query: trimmed)
            }
            let assistantMsg = DialogueMessage(role: .assistant, text: reply)
            dialogueHistory.append(assistantMsg)

            // 若未静音且开启了朗读偏好，进行 TTS 语音输出
            if !isMuted {
                voice.speak(text: reply)
            }
            Haptic.success()
        }
    }
}

enum MessageRole {
    case user, assistant
}

struct DialogueMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let text: String
}

struct DialogueBubble: View {
    let message: DialogueMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
                Text(message.text)
                    .font(.body)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.tint))
                    .foregroundStyle(.white)
            } else {
                Text(message.text)
                    .font(.body)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
    }
}
