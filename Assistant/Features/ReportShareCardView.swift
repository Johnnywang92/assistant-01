import AssistantCore
import SwiftUI
import UIKit

/// 周期复盘报告社交分享卡片 (Periodic Report Share Card)
///
/// 专为小红书、朋友圈、即刻等社交媒体设计的 4:5 比例复盘报告卡片，
/// 涵盖日报、周报、月报的待办成果、财务支出、身体活力与智能摘要，
/// 并按规范展示 App 图标与 JohnnyBoyStudio 品牌标识。
struct ReportShareCardView: View {
    let reportData: PeriodicReportData
    let polishedSummary: String?

    init(reportData: PeriodicReportData, polishedSummary: String? = nil) {
        self.reportData = reportData
        self.polishedSummary = polishedSummary
    }

    private var themeColor: Color {
        switch reportData.period {
        case .daily:
            return Color(red: 0.38, green: 0.65, blue: 1.0) // 电光蓝
        case .weekly:
            return Color(red: 0.22, green: 0.85, blue: 0.58) // 翡翠绿
        case .monthly, .quarterly, .yearly:
            return Color(red: 1.0, green: 0.78, blue: 0.35) // 耀金琥珀
        }
    }

    private var gradientBackground: [Color] {
        switch reportData.period {
        case .daily:
            return [
                Color(red: 0.05, green: 0.07, blue: 0.16),
                Color(red: 0.08, green: 0.11, blue: 0.22),
                Color(red: 0.04, green: 0.05, blue: 0.12)
            ]
        case .weekly:
            return [
                Color(red: 0.04, green: 0.10, blue: 0.08),
                Color(red: 0.06, green: 0.15, blue: 0.12),
                Color(red: 0.03, green: 0.07, blue: 0.06)
            ]
        case .monthly, .quarterly, .yearly:
            return [
                Color(red: 0.12, green: 0.08, blue: 0.05),
                Color(red: 0.18, green: 0.12, blue: 0.07),
                Color(red: 0.08, green: 0.05, blue: 0.03)
            ]
        }
    }

    private var periodTag: String {
        switch reportData.period {
        case .daily: return "DAILY REVIEW · 每日复盘"
        case .weekly: return "WEEKLY SUMMARY · 周度总结"
        case .monthly: return "MONTHLY OVERVIEW · 月度盘点"
        case .quarterly: return "QUARTERLY REPORT · 季度回顾"
        case .yearly: return "YEARLY ARCHIVE · 年度成果"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. 顶部 Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(periodTag)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(themeColor)
                        .tracking(0.8)

                    Text(reportData.title)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text(reportData.subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Spacer()

                // 成就等级徽标
                Text(reportData.achievementLevel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(themeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(themeColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(themeColor.opacity(0.3), lineWidth: 0.8)
                    )
            }

            // 2. AI 智能复盘摘要
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(themeColor)
                    .padding(.top, 2)

                Text(polishedSummary ?? reportData.smartSummary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // 3. 核心 4 大成果网格 (2x2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                // 待办达成
                statTile(
                    icon: "checkmark.circle.fill",
                    tint: themeColor,
                    title: "待办成果",
                    value: "\(reportData.completedTodos.count) 项已完成",
                    subtitle: "达成率 \(Int((reportData.completionRate * 100).rounded()))%"
                )

                // 财务支出
                statTile(
                    icon: "creditcard.fill",
                    tint: Color.orange,
                    title: "周期支出",
                    value: "¥\(String(format: "%.1f", reportData.totalExpense))",
                    subtitle: "记账 \(reportData.expenseCount) 笔"
                )

                // 身体活力 / 习惯
                if let vitality = reportData.vitality {
                    statTile(
                        icon: "bolt.heart.fill",
                        tint: Color.red,
                        title: "身体活力",
                        value: "\(vitality.score) 分 · \(vitality.level.rawValue)",
                        subtitle: "体征与代谢平稳"
                    )
                } else {
                    statTile(
                        icon: "flame.fill",
                        tint: Color.red,
                        title: "习惯打卡",
                        value: "连续 \(reportData.habitStreakCount) 天",
                        subtitle: "坚持日常节奏"
                    )
                }

                // 进行中与前瞻
                statTile(
                    icon: "arrow.forward.circle.fill",
                    tint: Color.cyan,
                    title: "事项推进",
                    value: "\(reportData.pendingTodos.count) 项进行中",
                    subtitle: "下期关注 \(reportData.upcomingTodos.count) 项"
                )
            }

            // 4. 重点完成清单 (最多展示 2 项)
            if !reportData.completedTodos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KEY ACCOMPLISHMENTS · 重点成果")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .tracking(0.5)

                    VStack(spacing: 5) {
                        ForEach(Array(reportData.completedTodos.prefix(2))) { todo in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(themeColor)
                                Text(todo.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }

            // 5. 底部品牌与专属网站标识
            VStack(spacing: 12) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.8)

                HStack(alignment: .center, spacing: 10) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.black.opacity(0.2), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("小助 · 个人智能生活助理")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text("记所想，助所行")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 专属网站标识胶囊
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 9))
                        Text("JohnnyBoyStudio")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(themeColor.opacity(0.18))
                    .foregroundStyle(themeColor)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(themeColor.opacity(0.3), lineWidth: 0.6)
                    )
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 350)
        .background(
            LinearGradient(
                colors: gradientBackground,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(themeColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
    }

    private func statTile(icon: String, tint: Color, title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
        )
    }
}

/// 周期复盘报告社交分享弹窗
struct ReportShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reportData: PeriodicReportData
    let polishedSummary: String?

    @State private var toastMessage: String?
    @State private var showSystemShareSheet: Bool = false
    @State private var renderedImage: UIImage?

    init(reportData: PeriodicReportData, polishedSummary: String? = nil) {
        self.reportData = reportData
        self.polishedSummary = polishedSummary
    }

    private var cardView: ReportShareCardView {
        ReportShareCardView(reportData: reportData, polishedSummary: polishedSummary)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.top, 10)

                    // 导出操作按钮组
                    VStack(spacing: 12) {
                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存复盘卡片至相册 (社交分享)")
                            }
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [Color.white, Color(white: 0.9)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        Button {
                            shareViaSystem()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("直接发送到社交平台")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享复盘报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
        .sheet(isPresented: $showSystemShareSheet, onDismiss: { renderedImage = nil }) {
            if let renderedImage {
                ShareActivityView(activityItems: [renderedImage])
            }
        }
    }

    @MainActor
    private func renderImage() -> UIImage? {
        ShareCardActions.render(cardView)
    }

    private func saveToPhotos() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存高清复盘卡片至相册 📸"))
        }
    }

    private func shareViaSystem() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }

        renderedImage = image
        showSystemShareSheet = true
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == msg { toastMessage = nil }
        }
    }
}
