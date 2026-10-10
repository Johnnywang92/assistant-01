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
    @AppStorage("assistant_custom_name") private var assistantName: String = "助手"
    @State private var selectedMode = AppSettings.currentMode
    @State private var voiceReplyEnabled = AppSettings.voiceReplyEnabled
    @State private var threshold = AppSettings.lowDataThresholdMB

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image("AssistantAppIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(assistantName.isEmpty ? "助手" : assistantName)
                                .font(.headline)
                            Text("专属离线个人 AI 助理")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Text("助手命名")
                        Spacer()
                        TextField("给你的助手起个名字", text: $assistantName)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("助手专属定制")
                } footer: {
                    Text("自定义名称将即时同步至主界面标题、语音对话及系统回复中。")
                }
                Section {
                    Picker("助手模式", selection: $selectedMode) {
                        ForEach(AssistantMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedMode) { _, newMode in
                        AppSettings.currentMode = newMode
                    }

                    Text(selectedMode.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("运行模式面板")
                } footer: {
                    Text("安静模式下不发送横幅/通知声音；记录模式下只收录数据不催办。")
                }

                Section("语音与播报") {
                    Toggle("语音对话回答时朗读 (TTS)", isOn: $voiceReplyEnabled)
                        .onChange(of: voiceReplyEnabled) { _, val in
                            AppSettings.voiceReplyEnabled = val
                        }
                }

                Section("签名有效期（免费账号）") {
                    LabeledContent("剩余天数", value: "\(ExpiryReminder.daysLeft) 天")
                    LabeledContent("到期时间") {
                        Text(ExpiryReminder.expiryDate, format: .dateTime.month().day().hour().minute())
                    }
                }
                Section("生活与情感守护") {
                    NavigationLink {
                        AnniversaryManagementView()
                    } label: {
                        Label("纪念日与生日倒数", systemImage: "gift.fill")
                    }
                    NavigationLink {
                        PainPointManagementView()
                    } label: {
                        Label("防自动续费 & 证件临期预警", systemImage: "shield.lefthalf.filled")
                    }
                }
                Section("财务与记账") {
                    NavigationLink {
                        ExpenseTrackerView()
                    } label: {
                        Label("智能记账与开销账单", systemImage: "yensign.circle.fill")
                    }
                }
                Section("安全与数字资产") {
                    NavigationLink {
                        AppLockSettingsView()
                    } label: {
                        Label("App 访问锁 (Face ID & 密码)", systemImage: "lock.shield.fill")
                    }
                    NavigationLink {
                        IDDocumentVaultView()
                    } label: {
                        Label("重要证件与照片保险箱", systemImage: "person.text.rectangle.fill")
                    }
                    NavigationLink {
                        PasswordVaultView()
                    } label: {
                        Label("离线密码库与安全轮换", systemImage: "key.fill")
                    }
                }
                Section("健康与周期家务") {
                    NavigationLink {
                        HabitAndMedicationView()
                    } label: {
                        Label("周期家务、吃药与智能家居", systemImage: "heart.text.square")
                    }
                }
                Section("智能感知与地点学习") {
                    NavigationLink {
                        LearnedPlacesView()
                    } label: {
                        Label("常用地点自学习 (家/公司)", systemImage: "brain.head.profile")
                    }
                }
                Section("快捷方式与系统联动") {
                    NavigationLink {
                        ShortcutsGuideView()
                    } label: {
                        Label("快捷方式与效率指南 (操作按钮/桌面长按)", systemImage: "bolt.badge.clock.fill")
                    }
                    NavigationLink("短信自动同步快捷指令向导") { SetupGuideView() }
                    Stepper(value: $threshold, in: 256...10240, step: 256) {
                        LabeledContent("流量提醒阈值", value: "\(Int(threshold)) MB")
                    }
                    .onChange(of: threshold) { _, v in AppSettings.lowDataThresholdMB = v }
                }
                Section("数据管理与安全迁移") {
                    NavigationLink {
                        DataMigrationView()
                    } label: {
                        Label("数据备份、跨机迁移与批量导入", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    }
                }
                Section("调试") {
                    NavigationLink("最近收到的消息") { RawMessagesView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

struct SetupGuideView: View {
    static let keywords = ["取件", "取走", "取出", "签收", "提货", "流量"]

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
            Text(text).font(.callout)
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
                    Text(m.parseSummary ?? "").font(.caption).foregroundStyle(.secondary)
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
            Text(title)
                .font(.subheadline.bold())
            Text("— \(desc)")
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
                Label(title, systemImage: icon)
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(copiedURL == url ? "已复制！" : url)
                    .font(.footnote.monospaced())
                    .foregroundStyle(copiedURL == url ? Color.green : Color.secondary)
                Image(systemName: copiedURL == url ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copiedURL == url ? Color.green : Color.secondary)
            }
        }
    }
}

