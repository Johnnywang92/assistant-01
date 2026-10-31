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
    /// 财务隐私敏感块，由分享面板逐次勾选，默认不上卡
    var showExpenseBreakdown: Bool
    var showSafeToSpend: Bool

    init(reportData: PeriodicReportData, polishedSummary: String? = nil,
         showExpenseBreakdown: Bool = false, showSafeToSpend: Bool = false) {
        self.reportData = reportData
        self.polishedSummary = polishedSummary
        self.showExpenseBreakdown = showExpenseBreakdown
        self.showSafeToSpend = showSafeToSpend
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

    /// 前瞻清单数据源：日报看明天，其余周期看下一期
    private var outlookTodos: [TodoItem] {
        reportData.period == .daily ? reportData.tomorrowTodos : reportData.upcomingTodos
    }

    private func suggestionTint(_ tone: ReportSuggestion.Tone) -> Color {
        switch tone {
        case .urgent: return Color.red
        case .action: return Color.orange
        case .positive: return Color.green
        }
    }

    /// 健康一行胶囊：步数 / 睡眠 / 活动能量，缺哪项跳过哪项，全缺整行不出现
    private var healthCapsules: [(icon: String, label: String, value: String)] {
        guard let snapshot = reportData.healthSnapshot else { return [] }
        var capsules: [(icon: String, label: String, value: String)] = []
        if let steps = snapshot.values[.stepCount]?.value, steps > 0 {
            capsules.append(("figure.walk", "步数", String(format: "%.0f", steps)))
        }
        if let sleep = snapshot.values[.sleep]?.value, sleep > 0 {
            capsules.append(("bed.double.fill", "睡眠", String(format: "%.1f h", sleep)))
        }
        if let energy = snapshot.values[.activeEnergy]?.value, energy > 0 {
            capsules.append(("flame.fill", "活动", String(format: "%.0f kcal", energy)))
        }
        return capsules
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
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
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
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

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

            // 3.5 健康一行胶囊 (步数 / 睡眠 / 活动能量)
            if !healthCapsules.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(healthCapsules.enumerated()), id: \.offset) { _, capsule in
                        HStack(spacing: 4) {
                            Image(systemName: capsule.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(themeColor)
                            Text(capsule.label)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.white.opacity(0.6))
                            Text(capsule.value)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }

            // 4. 重点完成清单 (最多展示 3 项)
            if !reportData.completedTodos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KEY ACCOMPLISHMENTS · 重点成果")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .tracking(0.5)

                    VStack(spacing: 5) {
                        ForEach(Array(reportData.completedTodos.prefix(3))) { todo in
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
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        }
                    }
                }
            }

            // 5. 行动建议 (最多 2 条；只上标题，detail 可能含金额与健康细节，不进社交卡片)
            if !reportData.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NEXT ACTIONS · 行动建议")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .tracking(0.5)

                    VStack(spacing: 5) {
                        ForEach(Array(reportData.suggestions.prefix(2))) { suggestion in
                            HStack(spacing: 6) {
                                Image(systemName: suggestion.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(suggestionTint(suggestion.tone))
                                Text(suggestion.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        }
                    }
                }
            }

            // 6. 明日 / 下期前瞻 (真实待办标题，最多 2 条)
            if !outlookTodos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reportData.period == .daily ? "UP NEXT · 明日前瞻" : "UP NEXT · 下期前瞻")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .tracking(0.5)

                    VStack(spacing: 5) {
                        ForEach(Array(outlookTodos.prefix(2))) { todo in
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.cyan)
                                Text(todo.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        }
                    }
                }
            }

            // 7. 支出构成 (可选块：类别 top3 + 最大单笔)
            if showExpenseBreakdown, !reportData.categoryStats.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPENDING MIX · 支出构成")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .tracking(0.5)

                    VStack(spacing: 5) {
                        ForEach(Array(reportData.categoryStats.prefix(3))) { stat in
                            HStack(spacing: 6) {
                                Image(systemName: stat.category.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.orange)
                                Text(L10n.tr(stat.category.rawValue))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("¥\(AmountFormatter.format(stat.amount))")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("\(Int((stat.ratio * 100).rounded()))%")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        }

                        if let maxItem = reportData.maxExpenseItem {
                            HStack(spacing: 6) {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.yellow.opacity(0.85))
                                Text(maxItem.title)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.7))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("最大单笔 ¥\(AmountFormatter.format(maxItem.amount))")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.white.opacity(0.45))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                    }
                }
            }

            // 8. 今日安心花 (可选块；仅日报且预算开启时有数据)
            if showSafeToSpend, let sts = reportData.safeToSpend, sts.isEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "yensign.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                    Text("今日安心花剩余")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                    Spacer(minLength: 6)
                    if sts.isTodayOverspent {
                        Text("已超额 ¥\(AmountFormatter.format(sts.todayOverspentAmount))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.red)
                    } else {
                        Text("¥\(AmountFormatter.format(sts.safeToSpendToday))")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
            }

            // 9. 底部品牌与专属网站标识
            VStack(spacing: 12) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.8)

                HStack(alignment: .center, spacing: 10) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
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
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous)
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
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
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
    @State private var showExpenseBreakdown = false
    @State private var showSafeToSpend = false

    init(reportData: PeriodicReportData, polishedSummary: String? = nil) {
        self.reportData = reportData
        self.polishedSummary = polishedSummary
    }

    private var cardView: ReportShareCardView {
        ReportShareCardView(reportData: reportData, polishedSummary: polishedSummary,
                            showExpenseBreakdown: showExpenseBreakdown,
                            showSafeToSpend: showSafeToSpend)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.top, 10)

                    // 可选内容：财务明细默认不上卡，分享前逐次勾选
                    if !reportData.categoryStats.isEmpty || reportData.safeToSpend?.isEnabled == true {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("可选内容（含财务明细，默认不展示）")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if !reportData.categoryStats.isEmpty {
                                Toggle("展示支出构成与最大单笔", isOn: $showExpenseBreakdown)
                                    .font(.subheadline)
                            }
                            if reportData.safeToSpend?.isEnabled == true {
                                Toggle("展示今日安心花剩余", isOn: $showSafeToSpend)
                                    .font(.subheadline)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        .padding(.horizontal, 24)
                    }

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
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
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
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
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
