import SwiftData
import SwiftUI

/// 设置子页：AI 与数据（端侧模型、万能投喂口、应用锁、对话留存、备份同步）。
/// 自根 SettingsView 拆分而来，所有键名与行为保持不变。
struct SettingsAIDataPage: View {
    @AppStorage(ClipboardIngestionService.autoIngestKey) private var autoIngest: Bool = true
    @AppStorage("omnibox_clipboard_auto_dismiss_seconds") private var clipboardAutoDismissSeconds: Int = 3
    @AppStorage("omnibox_auto_dismiss_seconds") private var autoDismissSeconds: Int = 3
    @Environment(\.modelContext) private var context
    @State private var retentionPolicy = AppSettings.dialogueRetentionPolicy
    @State private var savedDialogueCount: Int = 0
    @State private var showingClearDialogueAlert: Bool = false

    var body: some View {
        Form {
            Section("AI 模型") {
                NavigationLink {
                    LLMModelManagementView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "brain.head.profile", color: .purple)
                        Text("端侧大模型")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(LLMModelManager.shared.isModelDownloaded
                             ? "\(LLMModelManager.shared.selectedPreset.shortName) · \(L10n.tr("已就绪"))"
                             : "\(LLMModelManager.shared.selectedPreset.shortName) · \(L10n.tr("可下载"))")
                            .font(.subheadline)
                            .foregroundStyle(LLMModelManager.shared.isModelDownloaded ? .green : .secondary)
                            .lineLimit(1)
                    }
                }
                NavigationLink {
                    IntentThresholdCalibrationView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "slider.horizontal.3", color: .indigo)
                        Text("判别阈值校准")
                            .foregroundStyle(.primary)
                    }
                }
            }

            // MARK: - 万能投喂口
            Section("万能投喂口") {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "doc.on.clipboard.fill", color: .blue)
                    Toggle("剪贴板检测自动打开投喂口", isOn: $autoIngest)
                }
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "clock.arrow.circlepath", color: .teal)
                    Picker("无操作自动退出", selection: $clipboardAutoDismissSeconds) {
                        Text("不自动退出").tag(0)
                        Text("3 秒（默认）").tag(3)
                        Text("5 秒").tag(5)
                        Text("8 秒").tag(8)
                        Text("10 秒").tag(10)
                    }
                }
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "checkmark.circle.fill", color: .green)
                    Picker("确认执行后自动关闭", selection: $autoDismissSeconds) {
                        Text("不自动关闭").tag(0)
                        Text("1 秒").tag(1)
                        Text("2 秒").tag(2)
                        Text("3 秒（默认）").tag(3)
                        Text("5 秒").tag(5)
                    }
                }
            }

            Section("安全") {
                NavigationLink {
                    AppLockSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "lock.shield.fill", color: .green)
                        Text("应用锁与安全密码")
                            .foregroundStyle(.primary)
                    }
                }
            }

            // MARK: - 对话记录与自动滚动留存 (7天 / 30天)
            Section {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "bubble.left.and.bubble.right.fill", color: .teal)
                    Picker("记录保留时间", selection: $retentionPolicy) {
                        ForEach(DialogueRetentionPolicy.allCases) { policy in
                            Text(L10n.tr(policy.displayName)).tag(policy)
                        }
                    }
                }
                .onChange(of: retentionPolicy) { _, newValue in
                    AppSettings.dialogueRetentionPolicy = newValue
                    DialogueHistoryManager.shared.cleanExpiredRecords(context: context)
                    savedDialogueCount = DialogueHistoryManager.shared.countHistory(context: context)
                    Haptic.light()
                }

                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "tray.fill", color: .gray)
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
                        HStack(spacing: 12) {
                            SettingsIconBadge(icon: "trash.fill", color: .red)
                            Text("清空对话记录")
                                .foregroundStyle(.red)
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("对话记录")
            } footer: {
                Text("到期自动清理；待办和账单不受影响。")
            }

            Section("数据管理与云同步") {
                NavigationLink {
                    WebDAVSyncView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "externaldrive.fill", color: .orange)
                        Text("私有云同步 (WebDAV)")
                            .foregroundStyle(.primary)
                    }
                }

                NavigationLink {
                    DataMigrationView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "arrow.triangle.2.circlepath", color: .blue)
                        Text("备份、迁移与导入")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle(L10n.tr("AI 与数据"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
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
    }
}
