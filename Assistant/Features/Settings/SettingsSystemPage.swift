import SwiftUI

/// 设置子页：系统（权限健康度、快捷方式与多端协同、系统信息）。
/// 自根 SettingsView 拆分而来，所有键名与行为保持不变。
struct SettingsSystemPage: View {
    @State private var showingPermissionOnboarding: Bool = false

    var body: some View {
        Form {
            // MARK: - 核心权限健康度检查
            Section {
                Button {
                    showingPermissionOnboarding = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                .fill(PermissionManager.shared.areAllCorePermissionsReady ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: PermissionManager.shared.areAllCorePermissionsReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(PermissionManager.shared.areAllCorePermissionsReady ? Color.green : Color.orange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("权限检查与配置")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("集中检查与一键开启所有系统功能权限")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("\(PermissionManager.shared.readyCount) / \(PermissionManager.shared.totalCount) 项")
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

            Section("快捷方式与多端协同") {
                NavigationLink {
                    WatchIntegrationGuideView()
                } label: {
                    Label("Apple Watch 腕上协同指南", systemImage: "applewatch")
                }
                NavigationLink {
                    ShortcutsGuideView()
                } label: {
                    Label("快捷方式指南", systemImage: "bolt.badge.clock.fill")
                }
                NavigationLink("短信同步向导") { SetupGuideView() }
            }

            Section("系统信息") {
                LabeledContent("证书签名有效期", value: ExpiryReminder.displayDescription)
                NavigationLink("最近收到的原生消息") { RawMessagesView() }
            }
        }
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle(L10n.tr("系统"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPermissionOnboarding) {
            PermissionOnboardingView()
        }
    }
}
