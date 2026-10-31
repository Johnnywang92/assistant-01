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

    var isSheet: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image("AssistantAppIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
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
                        HStack(spacing: 6) {
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
                            } else {
                                Color.clear.frame(width: 22, height: 22)
                            }
                        }
                    }

                    // 对我的称呼
                    HStack {
                        Text("对我的称呼")
                        Spacer()
                        HStack(spacing: 6) {
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
                            } else {
                                Color.clear.frame(width: 22, height: 22)
                            }
                        }
                    }
                } header: {
                    Text("助手与称呼")
                }

                Section {
                    NavigationLink {
                        SettingsAppearancePage()
                    } label: {
                        HStack {
                            Label("个性化与界面", systemImage: "paintpalette.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("语言、主题、大字模式、语音")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        SettingsRemindersPage()
                    } label: {
                        HStack {
                            Label("提醒与报告", systemImage: "bell.badge.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("作息、睡前提醒、日报、月预算")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        SettingsAIDataPage()
                    } label: {
                        HStack {
                            Label("AI 与数据", systemImage: "brain.head.profile")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("模型、投喂口、应用锁、备份")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        SettingsSystemPage()
                    } label: {
                        HStack {
                            Label("系统", systemImage: "gearshape.2.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("权限、快捷方式、多端协同")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
        }
    }
}

struct SetupGuideView: View {
    static let keywords = ["取件", "取走", "取出", "签收", "提货", "账单", "还款"]
    @State private var copiedKeyword: String?

    var body: some View {
        List {
            // 引导总览卡片
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "message.badge.filled.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("短信自动同步待办")
                            .font(.headline)
                        Text("借助系统「快捷指令」自动化，收到快递或还款短信时无感自动解析生成待办。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // 触发关键词（横向流式胶囊，点击直接复制）
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("常用触发关键词")
                            .font(.subheadline.bold())
                        Spacer()
                        if let copiedKeyword {
                            Text("已复制「\(copiedKeyword)」")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        } else {
                            Text("点击任一即可复制")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                        ForEach(Self.keywords, id: \.self) { k in
                            Button {
                                UIPasteboard.general.string = k
                                Haptic.selection()
                                withAnimation(.spring(response: 0.25)) {
                                    copiedKeyword = k
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedKeyword == k { copiedKeyword = nil }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(k)
                                        .font(.subheadline.weight(.medium))
                                    Image(systemName: copiedKeyword == k ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                        .fill(copiedKeyword == k ? Color.green.opacity(0.15) : Color(.tertiarySystemFill))
                                )
                                .foregroundStyle(copiedKeyword == k ? Color.green : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("匹配关键词")
            }

            // 4 步极简配置流程
            Section("配置步骤（约 1 分钟）") {
                guideStepRow(
                    step: 1,
                    title: "新建信息自动化",
                    desc: "打开「快捷指令」App → 底部「自动化」→ 点右上角「+」→ 选择「信息」。"
                )
                guideStepRow(
                    step: 2,
                    title: "设置触发条件",
                    desc: "「信息包含」填入上方关键词（如取件），勾选「立即运行」，并关闭「运行时通知」。"
                )
                guideStepRow(
                    step: 3,
                    title: "添加导入动作",
                    desc: "下一步选「新建空白快捷指令」，搜索并添加「导入短信」（小助），内容设为「快捷指令输入」。"
                )
                guideStepRow(
                    step: 4,
                    title: "完成并发送测试",
                    desc: "可在信息中给自己发一条含取件码（如 3-2-104）的短信，小助将自动识别并生成待办。"
                )
            }

            // 实用技巧与保障
            Section("实用提示") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.body)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全自动智能去重")
                            .font(.subheadline.bold())
                        Text("同一条短信即使匹配多个关键词，助手也会自动基于原文校验去重，不会产生重复事项。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "creditcard.fill")
                        .foregroundStyle(.blue)
                        .font(.body)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支持信用卡账单与还款")
                            .font(.subheadline.bold())
                        Text("关键词填入「账单」或「还款」，收到银行短信时将自动解析还款日、应还金额并创建提醒。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("短信同步向导")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { InboxService.ensureFile() }
    }

    private func guideStepRow(step: Int, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 24, height: 24)
                Text("\(step)")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr(title))
                    .font(.subheadline.bold())
                Text(L10n.tr(desc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 3)
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
            // 桌面触感触控快捷菜单
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .foregroundStyle(.tint)
                        Text("长按 App 图标快速直达")
                            .font(.subheadline.bold())
                    }

                    VStack(spacing: 6) {
                        shortcutItemRow(icon: "waveform.circle.fill", color: .purple, title: "语音对话", desc: "立刻开始离线对话")
                        shortcutItemRow(icon: "plus.circle.fill", color: .blue, title: "新建待办", desc: "快速记录日程琐事")
                        shortcutItemRow(icon: "yensign.circle.fill", color: .green, title: "一句话记账", desc: "语音或文字记账")
                        shortcutItemRow(icon: "shippingbox.fill", color: .orange, title: "待取快递", desc: "直达所有取件码")
                        shortcutItemRow(icon: "person.text.rectangle.fill", color: .red, title: "证件保险箱", desc: "安全调取重要证件")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("桌面快捷方式")
            }

            // 硬件按键与快捷手势
            Section("按键与手势联动") {
                gestureCard(
                    icon: "button.programmable",
                    title: "iPhone 操作按钮 (Action Button)",
                    desc: "系统设置 → 操作按钮 → 快捷指令 → 打开 URL（填 assistant://voice），随时秒速呼起语音对话。"
                )

                gestureCard(
                    icon: "iphone.gen3",
                    title: "轻点背面 (Back Tap)",
                    desc: "系统设置 → 辅助功能 → 触控 → 轻点背面，绑定快捷指令打开链接或投喂口。"
                )

                gestureCard(
                    icon: "square.and.arrow.up.fill",
                    title: "系统分享一键投喂 (Share Sheet)",
                    desc: "在微信、相册、Safari 长按内容点「分享」→「发送到小助」，自动识别账单、待办或二维码。"
                )
            }

            // URL Schemes 一键复制
            Section {
                urlRow(title: "呼起语音助手", url: "assistant://voice", icon: "waveform")
                urlRow(title: "新建待办事项", url: "assistant://add-todo", icon: "plus.circle")
                urlRow(title: "一句话快速记账", url: "assistant://expense", icon: "yensign.circle")
                urlRow(title: "查看待取快递", url: "assistant://parcels", icon: "shippingbox")
                urlRow(title: "打开证件保险箱", url: "assistant://vault", icon: "person.text.rectangle")
            } header: {
                Text("快速打开 URL Scheme")
            } footer: {
                Text("点击即可复制 URL，可在「快捷指令」App 中添加「打开 URL」动作创建自动化。")
            }
        }
        .navigationTitle("快捷方式指南")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shortcutItemRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(L10n.tr(title))
                .font(.subheadline.bold())
            Spacer()
            Text(L10n.tr(desc))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func gestureCard(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr(title))
                    .font(.subheadline.bold())
                Text(L10n.tr(desc))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 3)
    }

    private func urlRow(title: String, url: String, icon: String) -> some View {
        Button {
            UIPasteboard.general.string = url
            Haptic.selection()
            copiedURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedURL == url { copiedURL = nil }
            }
        } label: {
            HStack {
                Label(L10n.tr(title), systemImage: icon)
                    .font(.subheadline)
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


