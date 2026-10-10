import SwiftUI

/// 首页 Tab 栏自定义界面（板块增删、拖拽排序、最多 5 个）
struct TabBarCustomizationView: View {
    @ObservedObject private var tabManager = TabBarManager.shared
    @State private var noticeMessage: String?
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            // MARK: - 1. 仿真实时预览卡片
            Section {
                VStack(spacing: 12) {
                    HStack {
                        Label("实时底部 Tab 栏预览", systemImage: "sparkles")
                            .font(.subheadline.bold())
                            .foregroundStyle(.tint)
                        Spacer()
                        Text("\(tabManager.activeTabs.count) / \(TabBarManager.maxTabsCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(tabManager.activeTabs.count == TabBarManager.maxTabsCount ? Color.green.opacity(0.15) : Color.blue.opacity(0.15)))
                            .foregroundStyle(tabManager.activeTabs.count == TabBarManager.maxTabsCount ? .green : .blue)
                    }

                    // 仿真 Tab 栏
                    HStack(spacing: 0) {
                        ForEach(Array(tabManager.activeTabs.enumerated()), id: \.element) { index, tab in
                            VStack(spacing: 4) {
                                Image(systemName: tab.systemImage)
                                    .font(.system(size: 18))
                                Text(tab.title)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(index == 0 ? Color.blue : Color.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
                    )

                    Text("按住右侧三道杠手柄上下拖动即可排序，修改即时生效保存。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Tab 栏外观效果")
            }

            // MARK: - 2. 当前启用的 Tab 列表（支持排序与移除）
            Section {
                ForEach(Array(tabManager.activeTabs.enumerated()), id: \.element) { index, tab in
                    HStack(spacing: 12) {
                        // 移除按钮
                        Button {
                            let result = tabManager.removeTab(tab)
                            if !result.success {
                                noticeMessage = result.message
                            } else {
                                noticeMessage = nil
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(tabManager.activeTabs.count <= TabBarManager.minTabsCount ? .secondary : .red)
                        }
                        .buttonStyle(.plain)
                        .disabled(tabManager.activeTabs.count <= TabBarManager.minTabsCount)

                        // 图标
                        Image(systemName: tab.systemImage)
                            .font(.body.bold())
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(colorForTab(tab)))

                        // 名称与副标题
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(tab.title)
                                    .font(.body.weight(.medium))
                                Text("第 \(index + 1) 位")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(tab.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        // 便捷微调上下移按钮
                        HStack(spacing: 8) {
                            Button {
                                tabManager.moveUp(tab)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.caption.bold())
                                    .padding(6)
                                    .background(Circle().fill(Color(.tertiarySystemFill)))
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            .opacity(index == 0 ? 0.3 : 1.0)

                            Button {
                                tabManager.moveDown(tab)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.caption.bold())
                                    .padding(6)
                                    .background(Circle().fill(Color(.tertiarySystemFill)))
                            }
                            .buttonStyle(.plain)
                            .disabled(index == tabManager.activeTabs.count - 1)
                            .opacity(index == tabManager.activeTabs.count - 1 ? 0.3 : 1.0)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onMove { source, destination in
                    tabManager.moveTabs(from: source, to: destination)
                }
            } header: {
                HStack {
                    Text("当前展示板块 (\(tabManager.activeTabs.count) / \(TabBarManager.maxTabsCount))")
                    Spacer()
                    Text("拖动排序")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("首页 Tab 栏最多允许放置 5 个板块（最少保留 2 个）。")
            }

            // MARK: - 3. 候选板块（可添加）
            Section {
                if tabManager.inactiveTabs.isEmpty {
                    Text("全部功能板块均已添加至首页 Tab 栏")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tabManager.inactiveTabs) { tab in
                        HStack(spacing: 12) {
                            Button {
                                let result = tabManager.addTab(tab)
                                if !result.success {
                                    noticeMessage = result.message
                                } else {
                                    noticeMessage = nil
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(tabManager.activeTabs.count >= TabBarManager.maxTabsCount ? .secondary : .green)
                            }
                            .buttonStyle(.plain)
                            .disabled(tabManager.activeTabs.count >= TabBarManager.maxTabsCount)

                            Image(systemName: tab.systemImage)
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(colorForTab(tab).opacity(0.8)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title)
                                    .font(.body.weight(.medium))
                                Text(tab.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button("添加") {
                                tabManager.addTab(tab)
                            }
                            .font(.caption.bold())
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(tabManager.activeTabs.count >= TabBarManager.maxTabsCount)
                        }
                        .padding(.vertical, 3)
                    }
                }
            } header: {
                Text("未放置的候选板块")
            } footer: {
                if tabManager.activeTabs.count >= TabBarManager.maxTabsCount {
                    Text("⚠️ 已达到 5 个板块上限。如需添加新板块，请先点击上方红减号移除一个现有板块。")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: - 4. 快捷恢复默认
            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("恢复默认排列 (待办·防丢·记账·档案·设置)", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .environment(\.editMode, .constant(.active)) // 始终激活拖拽排序手柄
        .navigationTitle("首页 Tab 栏自定义")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { noticeMessage != nil },
            set: { if !$0 { noticeMessage = nil } }
        )) {
            Button("好", role: .cancel) { noticeMessage = nil }
        } message: {
            Text(noticeMessage ?? "")
        }
        .confirmationDialog("恢复默认排列？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("恢复默认 (5 个板块)", role: .destructive) {
                tabManager.resetToDefault()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将恢复为官方推荐排列：待办、出门防丢、记账、生活档案、设置。")
        }
    }

    // MARK: - 颜色映射

    private func colorForTab(_ tab: NavigationRouter.AppTab) -> Color {
        switch tab {
        case .todos: return .blue
        case .departure: return .indigo
        case .expenses: return .green
        case .vault: return .purple
        case .passwords: return .orange
        case .documents: return .teal
        case .memos: return .red
        case .settings: return .gray
        }
    }
}
