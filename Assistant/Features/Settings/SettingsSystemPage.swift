import SwiftUI

/// 设置子页：系统（权限健康度、快捷方式与多端协同、系统信息）。
/// 自根 SettingsView 拆分而来，所有键名与行为保持不变。
struct SettingsSystemPage: View {
    @State private var showingPermissionOnboarding: Bool = false

    var body: some View {
        Form {
            // MARK: - 核心权限健康度检查
            Section("系统权限") {
                Button {
                    showingPermissionOnboarding = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(
                            icon: PermissionManager.shared.areAllCorePermissionsReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                            color: PermissionManager.shared.areAllCorePermissionsReady ? .green : .orange
                        )

                        Text("权限检查与配置")
                            .foregroundStyle(.primary)

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
            }

            Section("快捷方式与多端协同") {
                NavigationLink {
                    WatchIntegrationGuideView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "applewatch", color: .orange)
                        Text("Apple Watch 腕上协同")
                            .foregroundStyle(.primary)
                    }
                }
                NavigationLink {
                    ShortcutsGuideView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "bolt.fill", color: .purple)
                        Text("快捷指令指南")
                            .foregroundStyle(.primary)
                    }
                }
                NavigationLink {
                    SetupGuideView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "message.fill", color: .green)
                        Text("短信同步向导")
                            .foregroundStyle(.primary)
                    }
                }
            }

            Section("系统信息") {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "signature", color: .blue)
                    Text("证书签名有效期")
                    Spacer()
                    Text(ExpiryReminder.displayDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    RawMessagesView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "tray.full.fill", color: .gray)
                        Text("最近收到的原生消息")
                            .foregroundStyle(.primary)
                    }
                }
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
