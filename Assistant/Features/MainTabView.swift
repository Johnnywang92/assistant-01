import AssistantCore
import Combine
import SwiftData
import SwiftUI

/// 主应用底部 Tab 栏导航（支持用户自定义板块增删与顺序排列，最多 5 个板块）
struct MainTabView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var router = NavigationRouter.shared
    @ObservedObject private var tabManager = TabBarManager.shared
    @Query(filter: #Predicate<TodoItem> { $0.statusRaw == "active" }) private var activeTodos: [TodoItem]
    @State private var showVoice = false
    @State private var showScanner = false
    @State private var scannerInitialMode: QRCodeScannerView.ReceiverMode = .camera
    @State private var showOmnibox = false
    @State private var showUnifiedSearch = false
    @State private var showSettings = false
    @State private var showClipboardReadError = false
    @State private var autoStartListening = false
    @ObservedObject private var clipboard = ClipboardIngestionService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var directVoiceStatus = ""
    @State private var isDirectVoiceConversation = false
    @AppStorage("has_completed_permission_onboarding_v1") private var hasCompletedPermissionOnboarding: Bool = false
    @State private var showPermissionOnboarding = false
    @ObservedObject private var pinManager = MigrationPinManager.shared
    /// 懒加载已访问过的 Tab：冷启动首帧仅挂载当前选中 Tab（默认首页待办），
    /// 避免首帧同时实例化百宝箱（19 个全表 @Query）、记账与设置页造成主线程白屏卡顿。
    @State private var loadedTabs: Set<NavigationRouter.AppTab> = [NavigationRouter.shared.selectedTab]

    var body: some View {
        ZStack {
            // 全局个性化背景底色层
            AppBackgroundView()

            TabView(selection: $router.selectedTab) {
                ForEach(tabManager.activeTabs) { tab in
                    Group {
                        if loadedTabs.contains(tab) || router.selectedTab == tab {
                            tabContentView(for: tab)
                        } else {
                            Color.clear
                        }
                    }
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
                    .badge(badgeCount(for: tab))
                }
            }

            // 剪贴板新内容提示条（检测到截图/复制文字后回到 App 时从顶部滑入）
            VStack {
                if let suggestion = clipboard.suggestion {
                    ClipboardSuggestionBanner(
                        suggestion: suggestion,
                        onIngest: { ingestClipboard(suggestion) },
                        onOpenManual: {
                            clipboard.markHandled(suggestion.changeCount)
                            router.activeSheet = .omnibox
                        },
                        onDismiss: { clipboard.markRejectedAndHandled(suggestion.changeCount) }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .responsiveAnimation(.spring(response: 0.35, dampingFraction: 0.85), value: clipboard.suggestion)

            // 单手自由拖拽吸边语音悬浮球（支持单击唤起、长按直启语音输入）
            DraggableVoiceFloatingBall(showVoice: $showVoice, autoStartListening: $autoStartListening) {
                startDirectVoiceConversation()
            }
            if !directVoiceStatus.isEmpty {
                VStack {
                    Spacer()
                    Text(directVoiceStatus)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.78), in: Capsule())
                        .padding(.bottom, 78)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showVoice, onDismiss: {
            autoStartListening = false
            isDirectVoiceConversation = false
        }) {
            VoiceDialogueView(autoStartListening: autoStartListening)
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRCodeScannerView(initialMode: scannerInitialMode)
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(isPresented: $showOmnibox) {
            OmniboxView()
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(item: $router.pendingImportPayload) { payload in
            TodoImportPreviewSheet(payload: payload) {
                router.pendingImportPayload = nil
            }
            .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(item: $router.pendingUniversalEnvelope) { envelope in
            UniversalImportPreviewSheet(envelope: envelope) {
                router.pendingUniversalEnvelope = nil
            }
            .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(isPresented: $showPermissionOnboarding) {
            PermissionOnboardingView()
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(isPresented: $showUnifiedSearch) {
            UnifiedSearchView()
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(isSheet: true)
                .environment(\.locale, LanguageManager.shared.locale)
        }
        .onChange(of: router.activeSheet) { _, newSheet in
            if newSheet == .voice {
                autoStartListening = false
                showVoice = true
                router.activeSheet = nil
            } else if newSheet == .qrScanner {
                scannerInitialMode = .camera
                showScanner = true
                router.activeSheet = nil
            } else if newSheet == .nearbyReceiver {
                scannerInitialMode = .nearby
                showScanner = true
                router.activeSheet = nil
            } else if newSheet == .omnibox {
                showOmnibox = true
                router.activeSheet = nil
            } else if newSheet == .unifiedSearch {
                showUnifiedSearch = true
                router.activeSheet = nil
            } else if newSheet == .settings {
                showSettings = true
                router.activeSheet = nil
            }
        }
        .onReceive(VoiceDialogueService.shared.$isListening.removeDuplicates()) { listening in
            let voice = VoiceDialogueService.shared
            guard isDirectVoiceConversation, !listening, !voice.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let query = voice.recognizedText
            voice.recognizedText = ""
            Task { @MainActor in
                directVoiceStatus = L10n.isEnglish ? "Processing: \(query)" : "正在处理：\(query)"
                let result = await VoiceIntentProcessor(context: context).processIntent(query: query)
                directVoiceStatus = result.reply
                voice.speak(text: result.reply)
                isDirectVoiceConversation = false
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if directVoiceStatus == result.reply { directVoiceStatus = "" }
            }
        }
        .onAppear {
            StartupMetrics.markOnce("mainTab.onAppear", "activeTodos=\(activeTodos.count) tab=\(router.selectedTab)")
            // 首次启动时引导用户完成核心权限配置：仅在已配置 PIN 门禁后才触发，避免与首次安全设置页冲突
            if !hasCompletedPermissionOnboarding && pinManager.isConfigured {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    showPermissionOnboarding = true
                }
            }

            // 确保当前选中的 Tab 存在于活跃列表中
            if !tabManager.activeTabs.contains(router.selectedTab) {
                router.selectedTab = tabManager.activeTabs.first ?? .todos
            }
            loadedTabs.insert(router.selectedTab)
        }
        .onChange(of: router.selectedTab) { _, newTab in
            loadedTabs.insert(newTab)
        }
        .onChange(of: pinManager.isConfigured) { _, isConfigured in
            if isConfigured && !hasCompletedPermissionOnboarding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showPermissionOnboarding = true
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台：检测剪贴板是否有新内容（截图/复制文字）
            guard phase == .active else { return }
            handleClipboardOnActive()
        }
        .alert(L10n.tr("无法读取剪贴板"), isPresented: $showClipboardReadError) {
            Button(L10n.tr("好"), role: .cancel) {}
        } message: {
            Text(L10n.tr("可能未获授权。可打开投喂口，用「一键粘贴」手动带入"))
        }
        // 全局落库失败提示：任何页面 save 失败都在这里给一条可见反馈，
        // 避免「UI 播成功、数据没落库」的静默失败（审计报告 UI-01）。
        .overlay(alignment: .top) {
            SaveFailureBanner()
        }
    }

    // MARK: - 剪贴板投喂（检测 → 引导 → 自动分流）

    private func handleClipboardOnActive() {
        clipboard.checkOnBecomeActive()
        // 自动投喂开启时：跳过提示条直接进入投喂口（读取内容时系统会弹一次粘贴授权）
        guard clipboard.autoIngestEnabled,
              let suggestion = clipboard.suggestion,
              suggestion.kind != .unsupported else { return }
        ingestClipboard(suggestion)
    }

    private func ingestClipboard(_ suggestion: ClipboardIngestionService.Suggestion) {
        Haptic.selection()
        guard let payload = clipboard.resolvePayload() else {
            // 用户拒绝粘贴授权或内容为空：保留提示条，引导手动路径
            showClipboardReadError = true
            return
        }

        // 优先检查：若剪贴板内容为小助离线口令或分享链接，直接唤起统一互联确认面板，不进普通投喂
        if case .text(let rawText) = payload {
            if let envelope = QRCodeService.decodeEnvelope(from: rawText) {
                router.pendingUniversalEnvelope = envelope
                clipboard.markHandled(suggestion.changeCount)
                return
            } else if let legacyPayload = QRCodeService.decodePayload(from: rawText) {
                router.pendingImportPayload = legacyPayload
                clipboard.markHandled(suggestion.changeCount)
                return
            }
        }

        // 拒绝记忆：同一条内容被用户拒绝过一次就不再唤起万能投喂
        if clipboard.isContentRejected(payload) {
            clipboard.markHandled(suggestion.changeCount)
            return
        }
        router.omniboxPrefill = payload
        router.omniboxIsClipboardAutoIngest = true
        router.activeSheet = .omnibox
        clipboard.markHandled(suggestion.changeCount)
    }

    private func startDirectVoiceConversation() {
        let voice = VoiceDialogueService.shared
        guard !voice.isListening else {
            voice.stopListening()
            return
        }
        isDirectVoiceConversation = true
        directVoiceStatus = L10n.tr("请说话…")
        Task { @MainActor in
            guard await voice.requestPermissions() else {
                isDirectVoiceConversation = false
                directVoiceStatus = L10n.tr("需要允许语音识别和麦克风权限")
                return
            }
            do {
                try await voice.startListening()
                // 激活会话期间被再次点击取消时不会开麦，别继续显示「请说话…」
                guard voice.isListening else {
                    isDirectVoiceConversation = false
                    return
                }
            } catch {
                isDirectVoiceConversation = false
                directVoiceStatus = error.localizedDescription
            }
        }
    }

    // MARK: - 板块内容视图分发

    @ViewBuilder
    private func tabContentView(for tab: NavigationRouter.AppTab) -> some View {
        ModuleViewRegistry.tabView(for: tab.moduleID)
    }

    // MARK: - 动态角标徽标

    private func badgeCount(for tab: NavigationRouter.AppTab) -> Int {
        switch tab {
        case .todos:
            return activeTodos.isEmpty ? 0 : activeTodos.count
        default:
            return 0
        }
    }
}
