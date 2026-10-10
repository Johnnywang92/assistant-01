import SwiftData
import SwiftUI

/// 智能语音对话交互界面（完全离线语音交互）
struct VoiceDialogueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @StateObject private var voice = VoiceDialogueService.shared

    @AppStorage("assistant_custom_name") private var assistantName: String = "助手"
    @State private var dialogueHistory: [DialogueMessage] = []
    @State private var hasPermission = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 运行模式指示条
                HStack {
                    Label(AppSettings.currentMode.rawValue, systemImage: AppSettings.currentMode.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("完全离线运行")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
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

                Divider()

                // 底部语音录制与控制区
                VStack(spacing: 16) {
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
                                    .frame(width: 72, height: 72)
                                    .scaleEffect(voice.isListening ? 1.08 : 1.0)
                                    .animation(voice.isListening ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: voice.isListening)
                                    .shadow(color: (voice.isListening ? Color.red : Color.accentColor).opacity(0.4), radius: 8)

                                Image(systemName: voice.isListening ? "stop.fill" : "mic.fill")
                                    .font(.title)
                                    .foregroundStyle(.white)
                            }
                        }

                        if voice.isSpeaking {
                            Button {
                                voice.stopSpeaking()
                            } label: {
                                Label("静音", systemImage: "speaker.slash.fill")
                                    .font(.caption)
                                    .padding(8)
                                    .background(Capsule().fill(.secondary.opacity(0.2)))
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    Text(voice.isListening ? "正在倾听中... 说完后点击停止" : "点击麦克风开始对话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 16)
            }
            .navigationTitle(assistantName.isEmpty ? "语音助手" : "\(assistantName) · 语音对话")
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
                    let name = assistantName.isEmpty ? "助手" : assistantName
                    dialogueHistory.append(DialogueMessage(role: .assistant, text: "你好！我是你的个人离线助理「\(name)」。你可以问我「有哪些快递？」、「流量还剩多少？」或说「记一下明天下午开会」。"))
                }
                hasPermission = await voice.requestPermissions()
            }
            .onChange(of: voice.isListening) { _, listening in
                if !listening && !voice.recognizedText.isEmpty {
                    let query = voice.recognizedText
                    voice.recognizedText = ""
                    handleUserSpeechCompleted(query: query)
                }
            }
        }
    }

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

    private func handleUserSpeechCompleted(query: String) {
        let userMsg = DialogueMessage(role: .user, text: query)
        dialogueHistory.append(userMsg)

        Task {
            let processor = VoiceIntentProcessor(context: context)
            let reply = await processor.process(query: query)
            let assistantMsg = DialogueMessage(role: .assistant, text: reply)
            dialogueHistory.append(assistantMsg)

            // TTS 语音朗读
            voice.speak(text: reply)
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
