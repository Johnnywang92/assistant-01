import AssistantCore
import SwiftData
import SwiftUI

/// 拟真社交搭子与离线群体共鸣交互卡片
struct CompanionEchoCard: View {
    @AppStorage("selected_companion_persona") private var selectedPersonaRaw: String = CompanionPersonaType.warmRoommate.rawValue
    @State private var showPersonaPicker: Bool = false
    @State private var showTreeholeSheet: Bool = false
    @State private var refreshIndex: Int = 0

    let moodRecord: MoodCheckInRecord?
    let completedTodosCount: Int
    let pendingTodosCount: Int
    let todayExpenseAmount: Double

    private var currentPersona: CompanionPersonaType {
        CompanionPersonaType(rawValue: selectedPersonaRaw) ?? .warmRoommate
    }

    private var insight: CohortResonanceInsight {
        // refreshIndex 参与依赖以触发刷新重新计算
        _ = refreshIndex
        return CohortResonanceEngine.evaluate(
            moodScore: moodRecord?.moodScore,
            energyScore: moodRecord?.energyScore,
            stressScore: moodRecord?.stressScore,
            completedTodosCount: completedTodosCount,
            pendingTodosCount: pendingTodosCount,
            todayExpenseAmount: todayExpenseAmount,
            persona: currentPersona
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 搭子身份标头与切换入口
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(currentPersona.accentColor.opacity(0.15))
                        .frame(width: 38, height: 38)

                    Image(systemName: currentPersona.avatarIcon)
                        .font(.subheadline)
                        .foregroundStyle(currentPersona.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(currentPersona.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)

                        Text(currentPersona.roleTitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(currentPersona.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(currentPersona.accentColor.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    Text("离线心智陪伴 · 懂你的同温层")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 搭子切换菜单
                Menu {
                    ForEach(CompanionPersonaType.allCases) { persona in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                selectedPersonaRaw = persona.rawValue
                                Haptic.selection()
                            }
                        } label: {
                            Label(persona.name + " (" + persona.roleTitle + ")", systemImage: persona.avatarIcon)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("换搭子")
                            .font(.caption2.bold())
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                }
            }

            // 2. 搭子私语温情气泡
            VStack(alignment: .leading, spacing: 8) {
                Text(insight.companionEcho)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .stroke(Color(.systemGray5), lineWidth: 0.8)
            )

            // 3. 离线群体常模共鸣基线（Benchmarking）
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.3.sequence.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)

                    Text(insight.statTag)
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)

                    Spacer()

                    Text(insight.sampleContext)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Text(insight.cohortStatistic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))

            // 4. 底部微交互：倾诉树洞
            HStack {
                Button {
                    refreshIndex += 1
                    Haptic.light()
                } label: {
                    Label("换句评语", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showTreeholeSheet = true
                    Haptic.selection()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        Text("向\(currentPersona.name)倾诉心声")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(currentPersona.accentColor)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .sheet(isPresented: $showTreeholeSheet) {
            OfflineTreeholeSheet(persona: currentPersona, todayMood: moodRecord)
        }
    }
}

/// 纯离线树洞与搭子暖心倾诉面板
struct OfflineTreeholeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let persona: CompanionPersonaType
    let todayMood: MoodCheckInRecord?

    @State private var userText: String = ""
    @State private var companionReply: String? = nil
    @State private var isThinking: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 顶部说明
                    HStack(spacing: 10) {
                        Image(systemName: persona.avatarIcon)
                            .font(.title2)
                            .foregroundStyle(persona.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("向「\(persona.name)」倾诉")
                                .font(.headline)
                            Text("这里是你的绝对离线安全树洞，字句绝不上云。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                    // 输入区域
                    VStack(alignment: .trailing, spacing: 8) {
                        TextEditor(text: $userText)
                            .frame(minHeight: 120, maxHeight: 180)
                            .padding(8)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))

                        Button {
                            submitToTreehole()
                        } label: {
                            HStack(spacing: 6) {
                                if isThinking {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text(isThinking ? "搭子正在思考..." : "投入树洞并倾听")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : persona.accentColor)
                            .clipShape(Capsule())
                        }
                        .disabled(userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
                    }

                    // 回复气泡
                    if let reply = companionReply {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(persona.name) 的回响：")
                                    .font(.caption.bold())
                                    .foregroundStyle(persona.accentColor)
                                Spacer()
                            }
                            Text(reply)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineSpacing(4)
                        }
                        .padding()
                        .background(persona.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("无声心智树洞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func submitToTreehole() {
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isThinking = true
        Haptic.medium()

        // 尝试使用端侧本地 LLM 推理生成，如果未安装则回落到高情商规则库
        Task {
            if let customReply = await LLMInferenceService.shared.generateCustomTask(
                systemInstruction: persona.systemPrompt,
                userContent: "我对你倾诉说：“\(userText)”。请以一两句贴心真诚的话回复我：",
                maxNewTokens: 120
            ), !customReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run {
                    self.companionReply = customReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.isThinking = false
                    Haptic.success()
                }
                return
            }

            // 规则情景回落
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                self.companionReply = fallbackTreeholeReply(for: userText, persona: persona)
                self.isThinking = false
                Haptic.success()
            }
        }
    }

    private func fallbackTreeholeReply(for text: String, persona: CompanionPersonaType) -> String {
        switch persona {
        case .warmRoommate:
            return "收到你的心里话啦！能把这些说出来本身就很勇敢。别把委屈和劳累一个人憋在心里，今晚把手机放一边，无论发生什么，我都一直陪着你。"
        case .wittyMentor:
            return "听见你的吐槽了！生活嘛，偶尔搞人心态也是常事。骂两句痛快了就翻篇，咱们有手有脚脑子在线，还能被这道坎给难倒了？振作起来！"
        case .zenMaster:
            return "此番心念，皆是因缘际会。如水汽聚散，来去有时。且将心事付于清风，安住当下，便得自在一隅。"
        }
    }
}
