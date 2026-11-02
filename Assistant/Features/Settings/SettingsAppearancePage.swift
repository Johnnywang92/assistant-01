import SwiftUI

/// 设置子页：个性化与界面（语言、主题导航、无障碍、运行模式、语音）。
/// 自根 SettingsView 拆分而来，所有键名与行为保持不变。
struct SettingsAppearancePage: View {
    @AppStorage("floating_voice_enabled") private var floatingVoiceEnabled: Bool = true
    @AppStorage("floating_voice_norm_x") private var normX: Double = 1.0
    @AppStorage("floating_voice_norm_y") private var normY: Double = 0.68
    @ObservedObject private var tabManager = TabBarManager.shared
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @ObservedObject private var langManager = LanguageManager.shared
    @State private var selectedMode = AppSettings.currentMode
    @State private var voiceReplyEnabled = AppSettings.voiceReplyEnabled
    @State private var showingLifeEventTabAlert: Bool = false
    @State private var lifeEventTabAlertMessage = ""

    var body: some View {
        Form {
            // MARK: - 应用语言切换
            Section {
                NavigationLink {
                    AppLanguageSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "globe", color: .blue)
                        Text("语言 / Language")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(langManager.selectedLanguage.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("语言 / Language", selection: Binding(
                    get: { langManager.selectedLanguage },
                    set: { newLang in
                        Haptic.selection()
                        langManager.selectedLanguage = newLang
                    }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("语言 / Language")
            } footer: {
                Text(L10n.choose("切换后界面与通知立即生效。", "Takes effect immediately."))
            }

            Section {
                NavigationLink {
                    AppBackgroundSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "paintpalette.fill", color: .teal)
                        Text("主题与背景")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(L10n.tr(AppBackgroundManager.shared.currentStyle.rawValue))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    TabBarCustomizationView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "rectangle.bottomthird.inset.filled", color: .indigo)
                        Text("底部导航栏")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(TabBarManager.shared.activeTabs.count) / 5 个板块")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "sparkles", color: .pink)
                    Toggle(isOn: Binding(
                        get: { tabManager.isTabActive(.lifeEvents) },
                        set: { enabled in
                            if enabled {
                                let result = tabManager.addTab(.lifeEvents)
                                if !result.success {
                                    lifeEventTabAlertMessage = L10n.tr(result.message ?? "无法开启人生大事入口")
                                    showingLifeEventTabAlert = true
                                }
                            } else {
                                let result = tabManager.removeTab(.lifeEvents)
                                if !result.success {
                                    lifeEventTabAlertMessage = L10n.tr(result.message ?? "无法关闭人生大事入口")
                                    showingLifeEventTabAlert = true
                                }
                            }
                        }
                    )) {
                        Text("人生大事入口")
                    }
                    .tint(.pink)
                }
            } header: {
                Text("界面")
            }

            // MARK: - 长辈关怀模式 (大字与无障碍)
            Section {
                NavigationLink {
                    SeniorModeSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "figure.walk.motion", color: .orange)

                        Text("大字关怀模式")
                            .foregroundStyle(.primary)

                        Spacer()

                        if seniorManager.isSeniorModeEnabled {
                            Text("已开启")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Toggle("开启大字模式", isOn: $seniorManager.isSeniorModeEnabled)
                    .tint(.orange)
                    .onChange(of: seniorManager.isSeniorModeEnabled) { _, val in
                        if val {
                            Haptic.success()
                        } else {
                            Haptic.warning()
                        }
                    }
            } header: {
                Text("无障碍")
            }

            Section {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "person.badge.shield.checkmark.fill", color: .blue)
                    Picker("助手模式", selection: $selectedMode) {
                        ForEach(AssistantMode.allCases, id: \.self) { mode in
                            Label(L10n.tr(mode.rawValue), systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedMode) { _, newMode in
                        AppSettings.currentMode = newMode
                    }
                }

                Text(L10n.tr(selectedMode.description))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("运行模式")
            }

            Section {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "circle.circle.fill", color: .cyan)
                    Toggle("语音悬浮球", isOn: $floatingVoiceEnabled)
                }

                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "speaker.wave.2.fill", color: .green)
                    Toggle("朗读语音回答", isOn: $voiceReplyEnabled)
                        .onChange(of: voiceReplyEnabled) { _, val in
                            AppSettings.voiceReplyEnabled = val
                        }
                }

                if floatingVoiceEnabled {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            normX = 1.0
                            normY = 0.68
                        }
                        Haptic.light()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(icon: "arrow.counterclockwise", color: .gray)
                            Text("重置悬浮球位置")
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("语音")
            }
        }
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle(L10n.tr("个性化与界面"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("无法修改入口", isPresented: $showingLifeEventTabAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(lifeEventTabAlertMessage)
        }
    }
}
