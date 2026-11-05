import SwiftUI

// 宝宝档案 / 宠物档案共享视图组件。
//
// 背景（审计 UI-14）：`ChildManagementView` 与 `PetManagementView` 实测 43 个 5 行窗口重复，
// 「空态卡片」「成长记录入口区」「快捷动作按钮」三段布局逐字符相同，只有数据源与主题色不同。
// 这里按「参数注入差异」抽取，组件内部**不判断**当前是宝宝还是宠物。
//
// 约束：这两个页面会随主题/长辈模式变化，组件沿用系统语义色（`.secondary` 等）与调用方传入的 tint。

/// 记录区下方的快捷动作按钮（记成长/记里程碑/记就医…）。
struct ProfileQuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption2.bold())
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                    .fill(color.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

/// 空态卡片：图标 + 标题 + 说明 + 「添加档案」胶囊按钮。
struct ProfileEmptyStateCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let message: String
    let buttonTitle: String
    let buttonColor: Color
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(iconColor.opacity(0.6))
                .padding(.top, 16)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button(action: onAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text(buttonTitle)
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(buttonColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.vertical, 12)
    }
}

/// 记录区里的一个快捷动作（标题/图标/主题色/回调）。
struct ProfileRecordsAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
}

/// 成长记录入口区：整块可点的主入口 + 下方三个快捷动作。
struct ProfileRecordsSection: View {
    let tint: Color
    let title: String
    let subtitle: String
    /// 已有记录条数（>0 时显示「N 项」徽标）
    let count: Int
    var icon: String = "heart.text.square.fill"
    let onOpenAll: () -> Void
    let actions: [ProfileRecordsAction]

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onOpenAll) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(tint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)

                            if count > 0 {
                                Text("\(count) 项")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(tint.opacity(0.15)))
                                    .foregroundStyle(tint)
                            }
                        }

                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .fill(Color(.tertiarySystemGroupedBackground))
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ForEach(actions) { action in
                    ProfileQuickActionButton(
                        title: action.title,
                        icon: action.icon,
                        color: action.color,
                        action: action.action
                    )
                }
            }
        }
    }
}

/// 顶部概览卡：圆形图标 + 标题（可带徽标）+ 副标题。
struct ProfileOverviewHeaderCard: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    /// 可选徽标文案（如「3 项需处理」）。nil 时不显示，标题也不包 HStack —— 保持无徽标时的原始排版。
    var badgeText: String? = nil
    var badgeColor: Color = .orange

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 50, height: 50)
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let badgeText {
                    HStack(spacing: 6) {
                        titleText
                        Text(badgeText)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(badgeColor.opacity(0.15)))
                            .foregroundStyle(badgeColor)
                    }
                } else {
                    titleText
                }

                subtitleText
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
