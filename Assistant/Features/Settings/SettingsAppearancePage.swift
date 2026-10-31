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
            // MARK: - 应用语言切换 (支持跟随系统 / 简体中文 / English)
            Section {
                NavigationLink {
                    AppLanguageSettingsView()
                } label: {
                    HStack {
                        Label("语言 / Language", systemImage: "globe")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(langManager.selectedLanguage.displayName)
                            .font(.caption)
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
                Text(L10n.choose(
                    "切换后界面、通知与语音助手将立即生效，无需重启 App。",
                    "Interface, notifications, and voice assistant update immediately without restarting."
                ))
            }

            Section {
                NavigationLink {
                    AppBackgroundSettingsView()
                } label: {
                    HStack {
                        Label("主题与背景", systemImage: "paintpalette.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(L10n.tr(AppBackgroundManager.shared.currentStyle.rawValue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    TabBarCustomizationView()
                } label: {
                    HStack {
                        Label("底部导航栏", systemImage: "rectangle.bottomthird.inset.filled")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(TabBarManager.shared.activeTabs.count) / 5 个板块")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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
                    Label("人生大事入口", systemImage: "sparkles")
                }
                .tint(.pink)
            } header: {
                Text("界面")
            }

            // MARK: - 长辈关怀模式 (大字与无障碍)
            Section {
                NavigationLink {
                    SeniorModeSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .fill(seniorManager.isSeniorModeEnabled ? Color.orange.opacity(0.2) : Color.orange.opacity(0.12))
                                .frame(width: 36, height: 36)

                            Image(systemName: "figure.walk.motion")
                                .font(.title3)
                                .foregroundStyle(.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("大字关怀模式")
                                    .font(.body.bold())
                                    .foregroundStyle(.primary)

                                if seniorManager.isSeniorModeEnabled {
                                    Text("已开启")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                                        .foregroundStyle(.orange)
                                }
                            }

                            if seniorManager.isSeniorModeEnabled {
                                Text(seniorManager.fontScale.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
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
                Picker("助手模式", selection: $selectedMode) {
                    ForEach(AssistantMode.allCases, id: \.self) { mode in
                        Label(L10n.tr(mode.rawValue), systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedMode) { _, newMode in
                    AppSettings.currentMode = newMode
                }

                Text(L10n.tr(selectedMode.description))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("运行模式")
            }

            Section {
                Toggle("语音悬浮球", isOn: $floatingVoiceEnabled)

                Toggle("朗读语音回答", isOn: $voiceReplyEnabled)
                    .onChange(of: voiceReplyEnabled) { _, val in
                        AppSettings.voiceReplyEnabled = val
                    }

                if floatingVoiceEnabled {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            normX = 1.0
                            normY = 0.68
                        }
                        Haptic.light()
                    } label: {
                        HStack {
                            Text("重置悬浮球位置")
                            Spacer()
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .font(.subheadline)
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
