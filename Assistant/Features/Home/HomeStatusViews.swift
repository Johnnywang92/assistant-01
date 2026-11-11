import AssistantCore
import SwiftUI

// MARK: - 方案 C · 状态横幅队列 / 主任务行 / 更多收纳页
//
// 文档 §8.4：存量 10 个条件横幅收敛为**一条优先队列**，
// 首页只显示队列头，其余进「更多 · N」二级页，功能一条不丢。
// 优先级顺序仍需产品确认（设计侧建议 P0 安全时效 → P1 操作态 → P2 信息态）。

struct HomeBannerItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let tone: HomeBannerTone
    /// 所属分组。**排序由 Core 的 `HomeBannerQueueBuilder` 决定**，
    /// 视图不再自己排序，也不自己算「更多 · N」。
    let group: HomeBannerGroup
    let actionLabel: String
    let action: () -> Void
    /// nil 表示该提示不可手动关闭（如进行中的排序模式）
    let dismiss: (() -> Void)?
}

/// 队列头横幅：高 34、圆角 8，只换文案与提示色，不弹 toast。
struct HomeStatusBanner: View {
    let item: HomeBannerItem
    let moreCount: Int
    let onMore: () -> Void

    private var tint: Color {
        switch item.tone {
        case .warning: return HomeColor.warningText
        case .success: return HomeColor.success
        case .neutral: return HomeColor.primary
        }
    }

    private var surface: Color {
        switch item.tone {
        case .warning: return HomeColor.warningSurface
        case .success: return HomeColor.successSurface
        case .neutral: return HomeColor.neutralSurface
        }
    }

    private var iconName: String {
        switch item.tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .neutral: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(item.title)
                .font(HomeTypography.font(.body, weight: .medium))
                .foregroundStyle(HomeColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 4)

            if moreCount > 0 {
                Button(action: onMore) {
                    Text("更多 · \(moreCount)")
                        .font(HomeTypography.font(.auxiliary, weight: .semibold))
                        .foregroundStyle(tint)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .frame(minHeight: 32)
                .accessibilityLabel("查看更多提示，共 \(moreCount) 条")
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .frame(height: 34)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.homeBlock))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 主任务行

/// 首行固定为主任务（Core 判定 `priorityTaskID`），提供一键完成。
/// 勾选圈 20、点击区 ≥44、标题单行截断、时间右对齐。
struct HomePriorityTaskRow: View {
    let title: String
    let timeText: String
    var fontScale: CGFloat = 1
    let onToggle: () -> Void
    let onComplete: () -> Void

    private var isLarge: Bool { fontScale > 1 }

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Button(action: onToggle) {
                Image(systemName: "circle")
                    .font(.system(size: isLarge ? 26 : 20, weight: .regular))
                    .foregroundStyle(HomeColor.primary)
            }
            .buttonStyle(.plain)
            .iconButton("完成 \(title)", hint: "把这件待办标记为已完成")

            VStack(alignment: .leading, spacing: isLarge ? 4 : 2) {
                Text(title)
                    .font(HomeTypography.font(.body, weight: .semibold, scale: fontScale))
                    .foregroundStyle(HomeColor.text)
                    .lineLimit(1)
                Text("优先 · 今天最该做的一件")
                    .font(HomeTypography.font(.auxiliary, scale: fontScale))
                    .foregroundStyle(HomeColor.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(timeText)
                .font(HomeTypography.font(.auxiliary, scale: fontScale))
                .foregroundStyle(HomeColor.tertiaryText)
                .lineLimit(1)

            Button(action: onComplete) {
                Text("完成")
                    .font(HomeTypography.font(.body, weight: .semibold, scale: fontScale))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(HomeColor.primary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成 \(title)")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, isLarge ? AppSpacing.md : AppSpacing.sm + 2)
        .frame(height: isLarge ? 64 : 50)
        .background(HomeColor.priorityRow)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

// MARK: - 更多 · 通知与状态（二级收纳页）

struct HomeMoreBannersView: View {
    let items: [HomeBannerItem]
    @Environment(\.dismiss) private var dismiss

    /// 分组标题由 `HomeBannerPresenter` 统一翻译（App 层测试覆盖）。
    private func groupTitle(_ group: HomeBannerGroup) -> String {
        HomeBannerPresenter.groupTitle(group)
    }

    private var grouped: [(String, [HomeBannerItem])] {
        HomeBannerGroup.allCases.compactMap { group in
            let rows = items.filter { $0.group == group }
            return rows.isEmpty ? nil : (groupTitle(group), rows)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Text("当前 \(items.count) 条待处理 · 首页只显示优先级最高的 1 条")
                    .font(HomeTypography.font(.body))
                    .foregroundStyle(HomeColor.secondaryText)
                    .listRowBackground(Color.clear)

                ForEach(grouped, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: AppSpacing.sm) {
                                    Circle()
                                        .fill(toneColor(item.tone))
                                        .frame(width: 8, height: 8)
                                    Text(item.title)
                                        .font(HomeTypography.font(.body, weight: .semibold))
                                        .foregroundStyle(HomeColor.text)
                                    Spacer()
                                }
                                Text(item.detail)
                                    .font(HomeTypography.font(.auxiliary))
                                    .foregroundStyle(HomeColor.secondaryText)

                                HStack(spacing: AppSpacing.lg) {
                                    Button(item.actionLabel) {
                                        item.action()
                                        dismiss()
                                    }
                                    .buttonStyle(.borderless)
                                    .font(HomeTypography.font(.body, weight: .semibold))
                                    .accessibilityLabel("\(item.actionLabel)：\(item.title)")

                                    if let dismissAction = item.dismiss {
                                        Button("不再提醒") {
                                            dismissAction()
                                        }
                                        .buttonStyle(.borderless)
                                        .font(HomeTypography.font(.auxiliary))
                                        .foregroundStyle(HomeColor.tertiaryText)
                                        .accessibilityLabel("关闭提示：\(item.title)")
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("通知与状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func toneColor(_ tone: HomeBannerTone) -> Color {
        switch tone {
        case .warning: return HomeColor.warning
        case .success: return HomeColor.success
        case .neutral: return HomeColor.primary
        }
    }
}
