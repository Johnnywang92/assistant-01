import AssistantCore
import SwiftUI
import UIKit

/// 心理状态社交分享卡片 (Mental Health & Emotional Status Share Card)
///
/// 专为小红书、朋友圈、即刻等社交媒体设计的竖版身心与情绪分享卡片，
/// 包含情绪能量三维（心情、精力、压力）、心理量表状态（PHQ-9 / GAD-7）、
/// 疏解与小事行动、自主神经身体数据协同，
/// 并按规范展示 App 图标与品牌标识。
public struct PsychShareCardView: View {
    public let date: Date
    public let todayMood: MoodCheckInEntry?
    public let moodEntries: [MoodCheckInEntry]
    public let scaleScores: [PsychScaleScore]
    public let insight: MentalHealthInsight?
    public let physiology: PleasureIndexEvaluation?

    public init(
        date: Date = .now,
        todayMood: MoodCheckInEntry? = nil,
        moodEntries: [MoodCheckInEntry] = [],
        scaleScores: [PsychScaleScore] = [],
        insight: MentalHealthInsight? = nil,
        physiology: PleasureIndexEvaluation? = nil
    ) {
        self.date = date
        self.todayMood = todayMood
        self.moodEntries = moodEntries
        self.scaleScores = scaleScores
        self.insight = insight
        self.physiology = physiology
    }

    // 核心视觉调色
    private let primaryTint = Color(red: 0.38, green: 0.32, blue: 0.88)
    private let moodTint = Color(red: 0.20, green: 0.55, blue: 0.95)
    private let energyTint = Color(red: 0.15, green: 0.68, blue: 0.45)
    private let stressTint = Color(red: 0.92, green: 0.48, blue: 0.18)
    private let ink = Color(red: 0.12, green: 0.14, blue: 0.18)
    private let cardFill = Color.white

    private var phqScore: PsychScaleScore? {
        scaleScores.first { $0.scaleID == .phq9 }
    }

    private var gadScore: PsychScaleScore? {
        scaleScores.first { $0.scaleID == .gad7 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            emotionCardsSection
            if let insight {
                insightBannerSection(insight)
            }
            subStatusGridSection
            if !moodEntries.isEmpty {
                recentMoodSection
            }
            brandFooterSection
        }
        .padding(18)
        .frame(width: 340)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.99),
                    Color(red: 0.93, green: 0.96, blue: 0.99)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous)
                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 14, y: 6)
    }

    // MARK: - 子视图拆分（避免单一闭包过于庞大导致 Swift 编译器类型推断超时）

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MENTAL & EMOTION")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(primaryTint)
                .tracking(1.2)

            HStack(alignment: .firstTextBaseline) {
                Text("今日身心情绪日签")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(ink)
                Spacer(minLength: 8)
                Text(Self.compactDateText(date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.opacity(0.5))
            }
        }
    }

    private var emotionCardsSection: some View {
        HStack(spacing: 10) {
            emotionMetricTile(
                title: "心情感受",
                score: todayMood?.moodScore,
                label: moodDescriptor(todayMood?.moodScore),
                icon: "face.smiling.fill",
                tint: moodTint
            )
            emotionMetricTile(
                title: "身体精力",
                score: todayMood?.energyScore,
                label: energyDescriptor(todayMood?.energyScore),
                icon: "bolt.fill",
                tint: energyTint
            )
            emotionMetricTile(
                title: "压力负荷",
                score: todayMood?.stressScore,
                label: stressDescriptor(todayMood?.stressScore),
                icon: "wind",
                tint: stressTint
            )
        }
    }

    private func insightBannerSection(_ insight: MentalHealthInsight) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryTint)
                Text("身心洞察")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(primaryTint)
                Spacer()
                if let band = insight.band {
                    Text(band.displayName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(primaryTint.opacity(0.12), in: Capsule())
                        .foregroundStyle(primaryTint)
                }
            }

            Text(insight.headline)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if let action = insight.primaryAction {
                HStack(spacing: 6) {
                    Text("小建议：")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ink.opacity(0.6))
                    Text(PsychReliefCopy.title(for: action))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.opacity(0.85))
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(ink.opacity(0.06), lineWidth: 0.8)
        )
    }

    private var subStatusGridSection: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            subStatusTile(
                icon: "heart.text.square.fill",
                tint: primaryTint,
                title: "情绪量表 (PHQ-9)",
                value: phqScore?.totalScore != nil ? "\(phqScore!.totalScore!) 分" : "近期未测",
                subtitle: phqScore?.band?.displayName ?? "筛查情绪与精力"
            )

            subStatusTile(
                icon: "waveform.path.ecg",
                tint: Color(red: 0.25, green: 0.65, blue: 0.85),
                title: "状态评估 (GAD-7)",
                value: gadScore?.totalScore != nil ? "\(gadScore!.totalScore!) 分" : "近期未测",
                subtitle: gadScore?.band?.displayName ?? "评估紧张与放松"
            )

            subStatusTile(
                icon: "waveform.path",
                tint: energyTint,
                title: "自主神经张力",
                value: physiology?.stressScore != nil ? "压力 \(physiology!.stressScore)" : "待同步",
                subtitle: physiology?.autonomicBalance.rawValue ?? "生理负荷状态"
            )

            subStatusTile(
                icon: "bed.double.fill",
                tint: Color(red: 0.45, green: 0.40, blue: 0.80),
                title: "睡眠修复储备",
                value: physiology?.sleepRecoveryScore != nil ? "\(physiology!.sleepRecoveryScore) 分" : "待分析",
                subtitle: physiology?.state.badge ?? "夜间情绪修复"
            )
        }
    }

    private var recentMoodSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("近期情绪微波")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ink.opacity(0.5))
                Spacer()
                Text("近 \(min(moodEntries.count, 7)) 天打卡记录")
                    .font(.system(size: 9))
                    .foregroundStyle(ink.opacity(0.4))
            }

            HStack(spacing: 6) {
                ForEach(Array(moodEntries.prefix(7).reversed()), id: \.day) { entry in
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [moodTint, moodTint.opacity(0.4)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: CGFloat(entry.moodScore) * 6.5)

                        Text(compactDayString(entry.day))
                            .font(.system(size: 7.5))
                            .foregroundStyle(ink.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: 42, alignment: .bottom)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous)
                    .strokeBorder(ink.opacity(0.06), lineWidth: 0.8)
            )
        }
    }

    private var brandFooterSection: some View {
        VStack(spacing: 12) {
            Rectangle()
                .fill(ink.opacity(0.08))
                .frame(height: 0.8)

            HStack(alignment: .center, spacing: 10) {
                Image("AssistantAppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                    .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("小助 · 个人智能生活助理")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ink)
                        .lineLimit(1)

                    Text("关注内心，温和前行")
                        .font(.system(size: 9))
                        .foregroundStyle(ink.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(primaryTint)
                    Text("心理守护")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(primaryTint)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(primaryTint.opacity(0.1))
                .clipShape(Capsule())
            }
        }
    }

    private func emotionMetricTile(
        title: String,
        score: Int?,
        label: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ink.opacity(0.55))
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(score.map { "\($0)" } ?? "—")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(score != nil ? tint : ink.opacity(0.3))
                if score != nil {
                    Text("/ 5")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ink.opacity(0.4))
                }
            }

            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(ink.opacity(0.85))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(ink.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func subStatusTile(icon: String, tint: Color, title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ink.opacity(0.55))
            }
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(ink.opacity(0.45))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(ink.opacity(0.06), lineWidth: 0.8)
        )
    }

    private func moodDescriptor(_ score: Int?) -> String {
        guard let score else { return "待记录" }
        switch score {
        case 5: return "很轻快"
        case 4: return "较轻快"
        case 3: return "平稳"
        case 2: return "偏低落"
        default: return "很低落"
        }
    }

    private func energyDescriptor(_ score: Int?) -> String {
        guard let score else { return "待记录" }
        switch score {
        case 5: return "充沛"
        case 4: return "良好"
        case 3: return "正常"
        case 2: return "疲惫"
        default: return "耗尽"
        }
    }

    private func stressDescriptor(_ score: Int?) -> String {
        guard let score else { return "待记录" }
        switch score {
        case 1: return "很放松"
        case 2: return "温和"
        case 3: return "中等"
        case 4: return "偏大"
        default: return "极大"
        }
    }

    private func compactDayString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今" }
        let comps = cal.dateComponents([.day], from: date)
        return "\(comps.day ?? 0)日"
    }

    private static let compactDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    private static func compactDateText(_ date: Date) -> String {
        compactDateFormatter.string(from: date)
    }
}

// MARK: - 弹窗 Sheet 容器

/// 心理状态分享海报弹窗 Sheet
public struct PsychShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let date: Date
    public let todayMood: MoodCheckInEntry?
    public let moodEntries: [MoodCheckInEntry]
    public let scaleScores: [PsychScaleScore]
    public let insight: MentalHealthInsight?
    public let physiology: PleasureIndexEvaluation?

    @State private var toastMessage: String?
    @State private var renderedImage: UIImage?
    @State private var showSystemShareSheet = false
    @State private var showNearbySheet = false
    @State private var showAirDropSheet = false
    @State private var airdropItems: [Any] = []

    public init(
        date: Date = .now,
        todayMood: MoodCheckInEntry? = nil,
        moodEntries: [MoodCheckInEntry] = [],
        scaleScores: [PsychScaleScore] = [],
        insight: MentalHealthInsight? = nil,
        physiology: PleasureIndexEvaluation? = nil
    ) {
        self.date = date
        self.todayMood = todayMood
        self.moodEntries = moodEntries
        self.scaleScores = scaleScores
        self.insight = insight
        self.physiology = physiology
    }

    private var emotionEnvelope: UniversalShareEnvelope {
        let score = todayMood?.moodScore ?? 3
        let energy = todayMood?.energyScore ?? 3
        let stress = todayMood?.stressScore ?? 2
        let tag = insight?.band?.displayName ?? "平和"
        let note = insight?.headline ?? "身心节奏平稳，安住当下。"
        return UniversalShareEnvelope.forEmotion(
            moodScore: score,
            energyScore: energy,
            stressScore: stress,
            moodTag: tag,
            note: note
        )
    }

    private var cardView: PsychShareCardView {
        PsychShareCardView(
            date: date,
            todayMood: todayMood,
            moodEntries: moodEntries,
            scaleScores: scaleScores,
            insight: insight,
            physiology: physiology
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.top, 10)

                    // 导出操作按钮组
                    VStack(spacing: 12) {
                        // 碰一碰面对面交换心情名片
                        Button {
                            showNearbySheet = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wave.3.forward.circle.fill")
                                Text("碰一碰 · 面对面交换心情名片")
                            }
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.38, green: 0.32, blue: 0.88))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存卡片到相册")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            Button {
                                copyEmotionToken()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.on.doc")
                                    Text("复制微信口令")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button {
                                shareViaAirDrop()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "airdrop")
                                    Text("AirDrop 文件")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            shareViaSystem()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("直接分享图片")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享心理状态卡片")
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
        .fullScreenCover(isPresented: $showNearbySheet) {
            NearbyInteractionSheet(envelope: emotionEnvelope)
        }
        .sheet(isPresented: $showAirDropSheet, onDismiss: { airdropItems = [] }) {
            ShareActivityView(activityItems: airdropItems)
        }
    }

    private func copyEmotionToken() {
        UIPasteboard.general.string = emotionEnvelope.generateShareText()
        Haptic.success()
        showToast("已复制小助心情名片口令 💌")
    }

    private func shareViaAirDrop() {
        if let fileURL = AssistantPackageService.createPackageFile(for: emotionEnvelope) {
            self.airdropItems = [fileURL]
            self.showAirDropSheet = true
            Haptic.selection()
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
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存情绪卡片至相册 📸"))
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
