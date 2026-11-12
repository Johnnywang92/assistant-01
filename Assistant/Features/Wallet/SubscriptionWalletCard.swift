import AssistantCore
import SwiftData
import SwiftUI

// MARK: - Apple Wallet 风格订阅卡片

struct SubscriptionWalletCard: View {
    let sub: SubscriptionItem
    var isExpanded: Bool = false
    var onTap: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onAdvanceCycle: (() -> Void)? = nil

    private var theme: SubscriptionCardTheme {
        SubscriptionCardTheme.theme(for: sub.name)
    }

    /// 距离下次扣费的天数
    private var daysUntilBilling: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let billingDay = calendar.startOfDay(for: sub.nextBillingDate)
        let components = calendar.dateComponents([.day], from: today, to: billingDay)
        return components.day ?? 0
    }

    /// 扣费紧急状态提示
    private var urgencyStatus: (text: String, color: Color, isWarning: Bool) {
        let days = daysUntilBilling
        if days < 0 {
            return ("已逾期 \(abs(days)) 天", Color(.systemRed), true)
        } else if days == 0 {
            return ("今日扣费", Color(.systemRed), true)
        } else if days == 1 {
            return ("明日扣费", Color(.systemOrange), true)
        } else if days <= 3 {
            return ("\(days) 天后扣费", Color(.systemOrange), true)
        } else if days <= 7 {
            return ("\(days) 天后扣费", Color(.systemYellow), false)
        } else {
            return ("\(days) 天后", Color.white.opacity(0.85), false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 主卡面
            ZStack(alignment: .topLeading) {
                // 卡片渐变背景
                RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                    .fill(theme.backgroundGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 5)

                // 拟物微光高光装饰
                GeometryReader { geo in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [theme.accentColor.opacity(0.25), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: geo.size.width * 0.7
                            )
                        )
                        .frame(width: geo.size.width * 1.2, height: geo.size.width * 1.2)
                        .offset(x: geo.size.width * 0.4, y: -geo.size.height * 0.4)
                        .blur(radius: 20)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))

                // 卡面正文
                VStack(alignment: .leading, spacing: 14) {
                    // 1. 顶部：芯片 + 品牌/服务名 + 射频
                    HStack(alignment: .center, spacing: 12) {
                        WalletChipView()

                        WalletContactlessWaveView()

                        Spacer()

                        HStack(spacing: 6) {
                            Image(systemName: theme.iconName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(theme.accentColor)

                            Text(sub.name)
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }

                    // 2. 中部：金额大字 + 自动续费标识
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(sub.priceString)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        if sub.isAutoRenew {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10, weight: .bold))
                                Text("自动续费")
                                    .font(.caption2.bold())
                            }
                            .foregroundStyle(theme.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(theme.accentColor.opacity(0.18))
                            )
                        }

                        Spacer()
                    }

                    // 备忘警示（若有试用或退订备忘）
                    if let notes = sub.notes, !notes.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(notes)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                                .fill(Color.black.opacity(0.35))
                        )
                    }

                    // 3. 底部：扣费日期与倒计时徽标
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("下次扣款日")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(sub.nextBillingDate, format: .dateTime.year().month().day())
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.95))
                        }

                        Spacer()

                        // 状态 Badge
                        let status = urgencyStatus
                        HStack(spacing: 4) {
                            Circle()
                                .fill(status.color)
                                .frame(width: 6, height: 6)
                            Text(status.text)
                                .font(.caption2.bold())
                                .foregroundStyle(status.color)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.45))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(status.color.opacity(0.4), lineWidth: 0.8)
                                )
                        )
                    }
                }
                .padding(18)
            }
            .frame(height: 175)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }

            // MARK: - 展开态详情与操作盘
            if isExpanded {
                VStack(spacing: 12) {
                    Divider()
                        .background(Color(.separator))
                        .padding(.horizontal, 8)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("提前预警")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("提前 \(sub.remindDaysBefore) 天通知")
                                .font(.subheadline.bold())
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("续费方式")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(sub.isAutoRenew ? "周期自动划扣" : "手动单次充值")
                                .font(.subheadline.bold())
                        }

                        Spacer()

                        // 一键顺延至下一周期按钮
                        Button {
                            onAdvanceCycle?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "goforward.plus")
                                Text("顺延下月")
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.indigo.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)

                    // 操作栏：编辑与删除
                    HStack(spacing: 12) {
                        Button {
                            onEdit?()
                        } label: {
                            HStack {
                                Image(systemName: "pencil")
                                Text("修改订阅信息")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .fill(Color(.secondarySystemFill))
                            )
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            onDelete?()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("删除")
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                    .fill(Color(.systemRed).opacity(0.12))
                            )
                            .foregroundStyle(Color(.systemRed))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

