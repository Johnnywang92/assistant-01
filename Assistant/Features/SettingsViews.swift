import SwiftData
import SwiftUI

/// 手动粘贴导入（也用于在没配自动化前测试规则）。
struct ManualImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var resultText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                } header: {
                    Text("粘贴短信或聊天内容")
                } footer: {
                    Text("可以一次粘贴多条短信，用空行分隔。")
                }
                if let resultText {
                    Section("结果") { Text(resultText) }
                }
            }
            .navigationTitle("导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { runImport() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                        text = UIPasteboard.general.string ?? ""
                    }
                }
            }
        }
    }

    private func runImport() {
        let service = ImportService(context: context)
        let chunks = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var lines: [String] = []
        for chunk in chunks {
            do {
                lines.append(try service.ingest(chunk, source: "manual").summary)
            } catch {
                lines.append("失败：\(error.localizedDescription)")
            }
        }
        resultText = lines.joined(separator: "\n")
        text = ""
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistant_custom_name") private var assistantName: String = "小助"
    @AppStorage("user_preferred_title") private var userTitle: String = "你"
    @AppStorage("floating_voice_enabled") private var floatingVoiceEnabled: Bool = true
    @AppStorage("floating_voice_norm_x") private var normX: Double = 1.0
    @AppStorage("floating_voice_norm_y") private var normY: Double = 0.68
    @AppStorage("weather_alerts_enabled") private var weatherAlertsEnabled: Bool = true
    @AppStorage("todo_notification_show_sensitive_details") private var showSensitiveTodoNotifications: Bool = false
    @AppStorage("user_lifestyle_profile") private var lifestyleProfile: UserLifestyleProfile = .officeWorker
    @AppStorage("user_off_work_minutes") private var offWorkMinutes: Int = 18 * 60
    @AppStorage("context_adaptive_sorting_enabled") private var isAdaptiveSortingEnabled: Bool = true
    @AppStorage(ClipboardIngestionService.autoIngestKey) private var autoIngest: Bool = true
    @AppStorage("omnibox_clipboard_auto_dismiss_seconds") private var clipboardAutoDismissSeconds: Int = 5
    @AppStorage("omnibox_auto_dismiss_seconds") private var autoDismissSeconds: Int = 3
    @AppStorage("expense_monthly_budget") private var monthlyBudget: Double = 0
    @ObservedObject private var tabManager = TabBarManager.shared
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @ObservedObject private var reportManager = PeriodicReportManager.shared
    @ObservedObject private var langManager = LanguageManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var context
    @State private var selectedMode = AppSettings.currentMode
    @State private var voiceReplyEnabled = AppSettings.voiceReplyEnabled
    @State private var retentionPolicy = AppSettings.dialogueRetentionPolicy
    @State private var savedDialogueCount: Int = 0
    @State private var showingClearDialogueAlert: Bool = false
    @State private var showingPermissionOnboarding: Bool = false
    @State private var showingLifeEventTabAlert: Bool = false
    @State private var showingBudgetSheet: Bool = false
    @State private var lifeEventTabAlertMessage = ""

    var isSheet: Bool = false

    private var offWorkTimeBinding: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                return calendar.date(bySettingHour: offWorkMinutes / 60,
                                     minute: offWorkMinutes % 60,
                                     second: 0,
                                     of: .now) ?? .now
            },
            set: { newValue in
                let calendar = Calendar.current
                let hour = calendar.component(.hour, from: newValue)
                let minute = calendar.component(.minute, from: newValue)
                offWorkMinutes = hour * 60 + minute
            }
        )
    }

    private func migrateLegacyOffWorkTimeIfNeeded() {
        guard UserDefaults.standard.object(forKey: "user_off_work_minutes") == nil,
              let legacyHour = UserDefaults.standard.object(forKey: "user_off_work_hour") as? Int else { return }
        offWorkMinutes = min(max(legacyHour * 60, 0), 23 * 60 + 59)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image("AssistantAppIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text((assistantName.isEmpty || assistantName == "小助") ? L10n.tr("小助") : assistantName)
                                .font(.subheadline.weight(.semibold))
                            Text("称呼：\((userTitle.isEmpty || userTitle == "你") ? L10n.tr("你") : userTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 0)

                    HStack {
                        Text("助手命名")
                        Spacer()
                        TextField("名称", text: $assistantName)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.primary)
                            .submitLabel(.done)

                        if !assistantName.isEmpty && assistantName != "小助" {
                            Button {
                                assistantName = "小助"
                                Haptic.light()
                            } label: {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 对我的称呼
                    HStack {
                        Text("对我的称呼")
                        Spacer()
                        TextField("称呼", text: $userTitle)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.primary)
                            .submitLabel(.done)

                        if !userTitle.isEmpty && userTitle != "你" {
                            Button {
                                userTitle = "你"
                                Haptic.light()
                            } label: {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("助手与称呼")
                }

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

                // MARK: - 核心权限健康度检查
                Section {
                    Button {
                        showingPermissionOnboarding = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(PermissionManager.shared.areAllCorePermissionsReady ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                    .frame(width: 36, height: 36)

                                Image(systemName: PermissionManager.shared.areAllCorePermissionsReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                    .foregroundStyle(PermissionManager.shared.areAllCorePermissionsReady ? Color.green : Color.orange)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("权限检查")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)

                            }

                            Spacer()

                            Text("\(PermissionManager.shared.readyCount) / 4 项")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(PermissionManager.shared.areAllCorePermissionsReady ? Color.green.opacity(0.12) : Color.orange.opacity(0.15)))
                                .foregroundStyle(PermissionManager.shared.areAllCorePermissionsReady ? Color.green : Color.orange)

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("系统权限")
                } footer: {
                    Text("局域网模型启用后，生活摘要会发送至指定端点。")
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
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
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

                // MARK: - 对话记录与自动滚动留存 (7天 / 30天)
                Section {
                    Picker("记录保留时间", selection: $retentionPolicy) {
                        ForEach(DialogueRetentionPolicy.allCases) { policy in
                            Text(L10n.tr(policy.displayName)).tag(policy)
                        }
                    }
                    .onChange(of: retentionPolicy) { _, newValue in
                        AppSettings.dialogueRetentionPolicy = newValue
                        DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
                        savedDialogueCount = DialogueHistoryManager.shared.countHistory(context: context)
                        Haptic.light()
                    }

                    HStack {
                        Text("本地对话")
                        Spacer()
                        Text("\(savedDialogueCount) 条")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if savedDialogueCount > 0 {
                        Button(role: .destructive) {
                            showingClearDialogueAlert = true
                        } label: {
                            HStack {
                                Label("清空对话记录", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("对话记录")
                } footer: {
                    Text("到期自动清理；待办和账单不受影响。")
                }

                // MARK: - 月预算（今日安心花）
                Section {
                    Button {
                        showingBudgetSheet = true
                        Haptic.light()
                    } label: {
                        HStack {
                            Text("月预算")
                            Spacer()
                            Text(monthlyBudget > 0
                                 ? "¥\(String(format: "%.0f", monthlyBudget))"
                                 : "未设置")
                                .font(.subheadline)
                                .foregroundStyle(monthlyBudget > 0 ? .secondary : Color.orange)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showingBudgetSheet) {
                        BudgetEditSheet()
                    }
                } header: {
                    Text("消费预算")
                } footer: {
                    Text("设置后每天在「智能记账」页顶部计算今日安心花额度，房租、订阅等固定支出自动扣除。")
                }

                // MARK: - 定期复盘报告 (日报 / 周报 / 月报 / 年报)
                Section {
                    NavigationLink {
                        PeriodicReportView()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.blue.opacity(0.14))
                                    .frame(width: 36, height: 36)

                                Image(systemName: "chart.bar.doc.horizontal.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("生活报告")
                                        .font(.body.bold())
                                        .foregroundStyle(.primary)

                                    if reportManager.isDailyReportEnabled {
                                        Text("日报已开启")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.green.opacity(0.18)))
                                            .foregroundStyle(.green)
                                    }
                                }

                                Text("日报时间：\(reportManager.dailyTime.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }

                    Toggle("每日日报提醒", isOn: $reportManager.isDailyReportEnabled)
                        .tint(.green)
                } header: {
                    Text("定期报告")
                }

                Section {
                    Picker("作息习惯与身份", selection: $lifestyleProfile) {
                        ForEach(UserLifestyleProfile.allCases) { profile in
                            Label(L10n.tr(profile.rawValue), systemImage: profile.icon).tag(profile)
                        }
                    }

                    if lifestyleProfile == .officeWorker {
                        DatePicker("常规下班时间", selection: offWorkTimeBinding, displayedComponents: .hourAndMinute)
                    }

                    Toggle("情境动态排序", isOn: $isAdaptiveSortingEnabled)

                    Toggle("天气预警与添衣提醒", isOn: $weatherAlertsEnabled)
                    Toggle("在锁屏通知中显示待办详情", isOn: $showSensitiveTodoNotifications)
                        .onChange(of: showSensitiveTodoNotifications) { _, _ in
                            TodoNotificationManager.shared.syncAllTodoNotifications(context: context)
                        }
                } header: {
                    Text("生活习惯")
                }

                // MARK: - 万能投喂口
                Section {
                    Toggle("剪贴板检测自动打开投喂口", isOn: $autoIngest)
                    Picker("剪贴板唤起后无操作自动退出", selection: $clipboardAutoDismissSeconds) {
                        Text("不自动退出").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒（默认）").tag(5)
                        Text("8 秒").tag(8)
                        Text("10 秒").tag(10)
                    }
                    Picker("确认执行后自动关闭弹窗", selection: $autoDismissSeconds) {
                        Text("不自动关闭").tag(0)
                        Text("1 秒").tag(1)
                        Text("2 秒").tag(2)
                        Text("3 秒（默认）").tag(3)
                        Text("5 秒").tag(5)
                    }
                } header: {
                    Text("万能投喂口")
                } footer: {
                    Text("检测到剪贴板有内容自动唤起投喂口时，若您无意添加到 App，无需任何操作，弹窗将在指定秒数后自动关闭退出；期间点击任意位置或操作可暂停倒计时。")
                }

                Section("AI 模型") {
                    NavigationLink {
                        LLMModelManagementView()
                    } label: {
                        HStack {
                            Label("AI 端侧大模型 (Qwen3 / Qwen2.5)", systemImage: "brain.head.profile")
                            Spacer()
                            Text(LLMModelManager.shared.isModelDownloaded
                                 ? "\(LLMModelManager.shared.selectedPreset.shortName) · \(L10n.tr("GGUF 已就绪"))"
                                 : "\(LLMModelManager.shared.selectedPreset.shortName) · \(L10n.tr("可下载"))")
                                .font(.caption2)
                                .foregroundStyle(LLMModelManager.shared.isModelDownloaded ? .green : .secondary)
                        }
                    }
                }

                Section("安全") {
                    NavigationLink {
                        AppLockSettingsView()
                    } label: {
                        Label("应用锁", systemImage: "lock.shield.fill")
                    }
                }

                Section("快捷方式") {
                    NavigationLink {
                        ShortcutsGuideView()
                    } label: {
                        Label("快捷方式指南", systemImage: "bolt.badge.clock.fill")
                    }
                    NavigationLink("短信同步向导") { SetupGuideView() }
                }

                Section("数据管理") {
                    NavigationLink {
                        DataMigrationView()
                    } label: {
                        Label("备份、迁移与导入", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    }
                }

                Section("系统信息") {
                    LabeledContent("证书签名有效期", value: L10n.isEnglish ? "\(ExpiryReminder.daysLeft) days" : "\(ExpiryReminder.daysLeft) 天")
                    NavigationLink("最近收到的原生消息") { RawMessagesView() }
                }
            }
            .themedScrollContentBackground()
            .themedAppBackground()
            .themedRow()
            .navigationTitle("助手设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .task {
                migrateLegacyOffWorkTimeIfNeeded()
                savedDialogueCount = DialogueHistoryManager.shared.countHistory(context: context)
            }
            .alert("清空本地对话记录", isPresented: $showingClearDialogueAlert) {
                Button("取消", role: .cancel) {}
                Button("确认清空", role: .destructive) {
                    DialogueHistoryManager.shared.clearAll(context: context)
                    savedDialogueCount = 0
                    Haptic.success()
                }
            } message: {
                Text("确定要彻底清空本地保存的所有历史对话消息吗？此操作不可撤销（已提取的待办事项和账单不会受到影响）。")
            }
            .alert("无法修改入口", isPresented: $showingLifeEventTabAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(lifeEventTabAlertMessage)
            }
            .sheet(isPresented: $showingPermissionOnboarding) {
                PermissionOnboardingView()
            }
        }
    }
}

struct SetupGuideView: View {
    static let keywords = ["取件", "取走", "取出", "签收", "提货"]

    var body: some View {
        List {
            Section {
                Text("iOS 不允许 App 读取短信，需要用「快捷指令」在收到短信时把内容交给助手。每个关键词建一个自动化，约 3 分钟配完。")
                    .font(.callout)
            }
            Section("需要添加的关键词（点击复制）") {
                ForEach(Self.keywords, id: \.self) { k in
                    Button {
                        UIPasteboard.general.string = k
                    } label: {
                        HStack {
                            Text(k).font(.body.monospaced())
                            Spacer()
                            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("每个关键词的配置步骤") {
                step(1, "打开「快捷指令」→ 底部「自动化」→ 右上角 + →「信息」")
                step(2, "「信息包含」填入关键词，选择「立即运行」，关闭「运行时通知」")
                step(3, "下一步 →「新建空白快捷指令」")
                step(4, "搜索并添加「导入短信」（助手），把「短信内容」设为变量「快捷指令输入」")
                step(5, "完成。可在信息 App 给自己发一条含「取件码 1-2-3456」的短信测试")
            }
            Section {
                step(6, "在「导入短信」之前加一个「附加到文本文件」操作：内容为 ===MSG=== 换行 + 快捷指令输入，文件选「我的 iPhone › 助手 › inbox.txt」")
            } header: {
                Text("可选：防丢（签名过期期间）")
            } footer: {
                Text("App 过期时「导入短信」会失败，但短信已写入 inbox.txt，下次打开 App 自动补录，重复的不会重复添加。")
            }
            Section("一条短信触发多个自动化？") {
                Text("没关系，助手会按原文自动去重。")
                    .font(.callout)
            }
            Section("信用卡账单与还款提醒（短信自动化）") {
                step(1, "在快捷指令自动化中选择「信息」→「信息包含」填入「账单」或「还款」")
                step(2, "动作同样添加「导入短信」（助手），设置短信内容为「快捷指令输入」")
                step(3, "银行发送还款提醒短信时，助手自动解析出银行名、应还金额与还款日，生成高优还款待办")
            }
            Section("微信一键提取（方案一：轻点背面复制导入）") {
                step(1, "在「快捷指令」App 新建一个快捷指令，命名为「助手剪贴板导入」")
                step(2, "添加操作：从助理中选择「从剪贴板导入」")
                step(3, "打开系统「设置」→「辅助功能」→「触控」→「轻点背面」")
                step(4, "选择「轻点两下」或「轻点三下」，勾选刚才创建的「助手剪贴板导入」")
                step(5, "在微信中长按聊天文字点击「复制」，然后轻敲手机背面两下，即可离线提取并弹出通知")
            }
            Section("微信一键提取（方案二：截屏离线识别）") {
                step(1, "在「快捷指令」App 新建一个快捷指令，命名为「助手截屏提取」")
                step(2, "添加操作 1：「拍摄屏幕快照」")
                step(3, "添加操作 2：选择「截屏识别并导入」（助手），把文件参数设为步骤 1 的屏幕快照")
                step(4, "同样可绑定到「轻点背面」或 iPhone 15 Pro Max 的「操作按钮」（Action Button）")
                step(5, "聊天界面直接触发，全自动截图 → 离线 OCR → 解析待办")
            }
            Section("环境联动智能提醒（Wi-Fi / 定位 / 时间点 / 天气）") {
                step(1, "出门/断开Wi-Fi：在快捷指令自动化中选择「离开Wi-Fi(家庭网络)」，动作添加「触发情境智能提醒」，情景选择「离开家/断开家庭Wi-Fi」")
                step(2, "到家/连接Wi-Fi：选择「加入Wi-Fi(家庭网络)」，动作添加「触发情境智能提醒」，情景选择「到家/连接家庭Wi-Fi」，到家时若有未取件将弹窗预警")
                step(3, "定时简报（时间点+天气）：选择「特定时间(如早上 8:00)」，情景选择「早晨出门简报」，自动联动天气带伞提醒与全天待办")
            }
            Section("设备电量与充电提醒（手表/耳机/手机）") {
                step(1, "Apple Watch 低电量：在快捷指令中新建自动化 →「电池电量低于 20%」→ 执行「汇报设备电量」（设备选 Apple Watch 手表）")
                step(2, "iPhone 本机低电量：App 每次在前台运行时会自动检测 iPhone 电量，低于 20% 自动入库充电待办，充电后自动闭环打勾")
            }
        }
        .navigationTitle("自动化向导")
        .onAppear { InboxService.ensureFile() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.15)))
            Text(L10n.tr(text)).font(.callout)
        }
    }
}

struct RawMessagesView: View {
    @Query(sort: \RawMessage.receivedAt, order: .reverse) private var messages: [RawMessage]

    var body: some View {
        List(messages.prefix(100)) { m in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(m.source).font(.caption.bold())
                    Text(L10n.tr(m.parseSummary ?? "")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(m.receivedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(m.content).font(.callout)
            }
            .contextMenu {
                Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = m.content }
            }
        }
        .navigationTitle("最近消息")
        .overlay {
            if messages.isEmpty { ContentUnavailableView("暂无消息", systemImage: "message") }
        }
    }
}

// MARK: - 快捷方式与效率指南页面

struct ShortcutsGuideView: View {
    @State private var copiedURL: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.tap.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("主屏幕长按快捷菜单")
                                .font(.headline)
                            Text("无需打开 App，在 iPhone 桌面上长按应用图标即可弹出快捷菜单：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        shortcutItemRow(icon: "waveform.circle.fill", color: .purple, title: "语音对话", desc: "立刻开始与助手离线对话")
                        shortcutItemRow(icon: "plus.circle.fill", color: .blue, title: "新建待办", desc: "快速记录日常琐事与日程")
                        shortcutItemRow(icon: "yensign.circle.fill", color: .green, title: "一句话记账", desc: "语音或文字自动记账")
                        shortcutItemRow(icon: "shippingbox.fill", color: .orange, title: "待取快递", desc: "一键直达所有取件码")
                        shortcutItemRow(icon: "person.text.rectangle.fill", color: .red, title: "证件保险箱", desc: "人脸解锁调取重要证件")
                    }
                }
            } header: {
                Text("桌面触感触控 (Haptic Touch)")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("设置 iPhone 15 Pro 操作按钮 (Action Button)", systemImage: "button.programmable")
                        .font(.headline)
                    Text("1. 打开 iPhone 系统 **设置** → **操作按钮**。\n2. 滑动选择 **快捷指令**。\n3. 选择 **打开 URL** 操作，填入下方对应的快捷链接（如 `assistant://voice`）。\n4. 随时长按机身左侧操作按钮，即可秒速呼起助手！")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Label("设置轻点背面 (Back Tap)", systemImage: "iphone.gen3")
                        .font(.headline)
                    Text("打开 iPhone 系统 **设置** → **辅助功能** → **触控** → **轻点背面**，设置「轻点两下」或「轻点三下」运行快捷指令打开链接。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("硬件按键与手势联动")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("系统分享导入 (Share Extension)", systemImage: "square.and.arrow.up")
                        .font(.headline)
                    Text("在微信、相册、Safari 等任意 App 里，长按消息或图片选择「分享」，再点「发送到小助」，即可把截图/文本/链接一键丢给助手：\n• 微信支付、转账、账单截图 → 自动记账\n• 含时间、地点、二维码的截图 → 自动建待办\n• 普通文本 → 自动提取待办与快递\n\n内容先进入 App Group 中转区，回到小助（或点「已收到分享」通知）即自动识别入库。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("系统分享导入")
            } footer: {
                Text("若分享面板里没看到「发送到小助」，点分享面板右上角「⋯」在「编辑操作」中启用它。")
            }

            Section {
                urlRow(title: "呼起语音助手", url: "assistant://voice", icon: "waveform")
                urlRow(title: "新建待办事项", url: "assistant://add-todo", icon: "plus.circle")
                urlRow(title: "一句话快速记账", url: "assistant://expense", icon: "yensign.circle")
                urlRow(title: "查看待取快递", url: "assistant://parcels", icon: "shippingbox")
                urlRow(title: "打开证件保险箱", url: "assistant://vault", icon: "person.text.rectangle")
            } header: {
                Text("快速打开 URL Scheme (支持快捷指令 App)")
            } footer: {
                Text("点击即可复制 URL 链接，可在苹果官方「快捷指令」App 中添加「打开 URL」动作创建自定义自动化。")
            }
        }
        .navigationTitle("快捷方式与效率指南")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shortcutItemRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(L10n.tr(title))
                .font(.subheadline.bold())
            Text("— \(L10n.tr(desc))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func urlRow(title: String, url: String, icon: String) -> some View {
        Button {
            UIPasteboard.general.string = url
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            copiedURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedURL == url { copiedURL = nil }
            }
        } label: {
            HStack {
                Label(L10n.tr(title), systemImage: icon)
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(copiedURL == url ? L10n.tr("已复制！") : url)
                    .font(.footnote.monospaced())
                    .foregroundStyle(copiedURL == url ? Color.green : Color.secondary)
                Image(systemName: copiedURL == url ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copiedURL == url ? Color.green : Color.secondary)
            }
        }
    }
}

/// 应用语言切换独立设置页
struct AppLanguageSettingsView: View {
    @ObservedObject private var langManager = LanguageManager.shared

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { lang in
                    let isSelected = langManager.selectedLanguage == lang
                    Button {
                        Haptic.selection()
                        langManager.selectedLanguage = lang
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: lang.icon)
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(lang.displayName)
                                    .font(.body.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                Text(lang.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(L10n.choose("选择应用显示语言", "Select App Language"))
            } footer: {
                Text(L10n.choose(
                    "支持跟随系统语言或手动指定简体中文 / English。切换后全应用界面、系统通知与语音识别/播报将立即同步切换。",
                    "Choose Follow System or manually select Simplified Chinese / English. Interface, notifications, and voice recognition/TTS update immediately."
                ))
            }
        }
        .listStyle(.insetGrouped)
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle(L10n.choose("语言 / Language", "Language"))
        .navigationBarTitleDisplayMode(.inline)
    }
}


